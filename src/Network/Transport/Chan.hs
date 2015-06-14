{-# LANGUAGE RecursiveDo #-}

-- | In-memory implementation of the Transport API.
module Network.Transport.Chan (createTransport) where

import Network.Transport
import Control.Concurrent.Chan (Chan, newChan, readChan, writeChan)
import Control.Category ((>>>))
import Control.Concurrent.MVar
  ( MVar
  , newMVar
  , modifyMVar
  , modifyMVar_
  , readMVar
  , withMVar
  )
import Control.Exception (handle, throw, throwIO)
import Control.Monad (forM_)
import Data.Map (Map)
import Data.Maybe (fromMaybe, fromJust)
import qualified Data.Map as Map
import Data.Set (Set)
import qualified Data.Set as Set
import Data.ByteString (ByteString)
import qualified Data.ByteString.Char8 as BSC (pack)
import Data.Accessor (Accessor, accessor, (^.), (^=), (^:))
import qualified Data.Accessor.Container as DAC (mapMaybe)

data TransportState
  = TransportValid {-# UNPACK #-} !ValidTransportState
  | TransportClosed

data ValidTransportState = ValidTransportState
  { _localEndPoints :: !(Map EndPointAddress LocalEndPoint)
  }

data LocalEndPoint = LocalEndPoint
  { localEndPointAddress :: !EndPointAddress
  , localEndPointChannel :: !(Chan Event)
  , localEndPointState   :: !(MVar LocalEndPointState)
  }

data LocalEndPointState
  = LocalEndPointValid {-# UNPACK #-} !ValidLocalEndPointState
  | LocalEndPointClosed

data ValidLocalEndPointState = ValidLocalEndPointState
  { _nextConnectionId :: !ConnectionId
  , _connections :: !(Map EndPointAddress LocalConnection)
  , _multigroups :: Map MulticastAddress (MVar (Set EndPointAddress))
  }

data LocalConnection = LocalConnection
  { localConnectionId :: !ConnectionId
  , localConnectionLocalAddress :: !EndPointAddress
  , localConnectionRemoteAddress :: !EndPointAddress
  , localConnectionState :: !(MVar LocalConnectionState)
  }

data LocalConnectionState
  = LocalConnectionValid
  | LocalConnectionClosed

-- | Create a new Transport.
--
-- Only a single transport should be created per Haskell process
-- (threads can, and should, create their own endpoints though).
createTransport :: IO Transport
createTransport = do
  state <- newMVar $ TransportValid $ ValidTransportState
    { _localEndPoints = Map.empty
    }
  return Transport
    { newEndPoint    = apiNewEndPoint state
    , closeTransport = throwIO (userError "closeTransport not implemented")
    }

-- | Create a new end point.
apiNewEndPoint :: MVar TransportState -> IO (Either (TransportError NewEndPointErrorCode) EndPoint)
apiNewEndPoint state = handle (return . Left) $ do
  chan <- newChan
  addr <- modifyMVar state $ \st -> case st of
    TransportValid vst -> do
      lepState <- newMVar $ LocalEndPointValid $ ValidLocalEndPointState
        { _nextConnectionId = 1
        , _connections = Map.empty
        , _multigroups = Map.empty
        }
      let addr = EndPointAddress . BSC.pack . show . Map.size $ vst ^. localEndPoints
          lep = LocalEndPoint
            { localEndPointAddress = addr
            , localEndPointChannel = chan
            , localEndPointState = lepState
            }
      return (TransportValid $ localEndPointAt addr ^= Just lep $ vst, addr)
    TransportClosed -> throwIO $ TransportError NewEndPointFailed "Transport closed"
  return $ Right $ EndPoint
    { receive       = readChan chan
    , address       = addr
    , connect       = apiConnect addr state
    , closeEndPoint = apiCloseEndPoint state addr
    , newMulticastGroup     = apiNewMulticastGroup state addr
    , resolveMulticastGroup = apiResolveMulticastGroup state addr
    }

apiCloseEndPoint :: MVar TransportState -> EndPointAddress -> IO ()
apiCloseEndPoint state addr = modifyMVar_ state $ \st -> case st of
    TransportValid vst -> do
      case vst ^. localEndPointAt addr of
        Nothing -> return $ TransportValid vst
        Just lep -> do
          modifyMVar_ (localEndPointState lep) $ \lepst -> case lepst of
            LocalEndPointValid lepvst -> do
              forM_ (Map.elems (lepvst ^. connections)) $ \lconn -> do
                modifyMVar_ (localConnectionState lconn) $ \_ ->
                  return LocalConnectionClosed
              return LocalEndPointClosed
            LocalEndPointClosed -> return LocalEndPointClosed
          return $ TransportValid $
            (localEndPoints ^: Map.delete addr) $
            vst
    TransportClosed -> return TransportClosed

-- | Create a new connection
apiConnect :: EndPointAddress
           -> MVar TransportState
           -> EndPointAddress
           -> Reliability
           -> ConnectHints
           -> IO (Either (TransportError ConnectErrorCode) Connection)
apiConnect ourAddress state theirAddress _reliability _hints =
    handle (return . Left) $ fmap Right $ mdo
      ~(chan, lconn) <- do
        withMVar state $ \st -> case st of
          TransportValid vst -> do
            let err = throw $ TransportError ConnectFailed "Endpoint closed"
                ourlep = fromMaybe err $ vst ^. localEndPointAt ourAddress
                theirlep = fromMaybe err $ vst ^. localEndPointAt theirAddress
            -- No masking necessary, because we don't need atomicity here.
            conid <- modifyMVar (localEndPointState theirlep) $ \lepst -> case lepst of
              LocalEndPointValid lepvst -> do
                return ( LocalEndPointValid $ nextConnectionId ^: (+ 1) $ lepvst
                       , lepvst ^. nextConnectionId
                       )
              LocalEndPointClosed ->
                throwIO $ TransportError ConnectFailed "endpoint closed"
            modifyMVar (localEndPointState ourlep) $ \lepst -> case lepst of
              LocalEndPointValid lepvst -> do
                lconnState <- newMVar LocalConnectionValid
                return ( LocalEndPointValid $ connectionAt theirAddress ^= lconn $ lepvst
                       , ( localEndPointChannel theirlep
                         , LocalConnection
                             { localConnectionId = conid
                             , localConnectionLocalAddress = ourAddress
                             , localConnectionRemoteAddress = theirAddress
                             , localConnectionState = lconnState
                             }
                         )
                       )
              LocalEndPointClosed ->
                throwIO $ TransportError ConnectFailed "Endpoint closed"
          TransportClosed ->
            throwIO $ TransportError ConnectFailed "Transport closed"
      writeChan chan $
        ConnectionOpened (localConnectionId lconn) ReliableOrdered ourAddress
      return $ Connection
        { send  = apiSend chan state lconn
        , close = apiClose chan state lconn
        }

-- | Send a message over a connection
apiSend :: Chan Event
        -> MVar TransportState
        -> LocalConnection
        -> [ByteString]
        -> IO (Either (TransportError SendErrorCode) ())
apiSend chan state lconn msg = do
    withMVar (localConnectionState lconn) $ \connst -> case connst of
      LocalConnectionValid -> do
        writeChan chan (Received (localConnectionId lconn) msg)
        return $ Right ()
      LocalConnectionClosed -> do
        -- If the local connection was closed, check why.
        withMVar state $ \st -> case st of
          TransportValid vst -> do
            let addr = localConnectionLocalAddress lconn
                mblep = vst ^. localEndPointAt addr
            case mblep of
              Nothing ->
                return $ Left $ TransportError SendFailed "Endpoint closed"
              Just lep -> do
                withMVar (localEndPointState lep) $ \lepst -> case lepst of
                  LocalEndPointValid _ -> do
                    return $ Left $ TransportError SendClosed "Connection closed"
                  LocalEndPointClosed ->
                    return $ Left $ TransportError SendFailed "Endpoint closed"
          TransportClosed ->
            return $ Left $ TransportError SendFailed "Transport closed"

-- | Close a connection
apiClose :: Chan Event
         -> MVar TransportState
         -> LocalConnection
         -> IO ()
apiClose chan state lconn = do
  modifyMVar_ (localConnectionState lconn) $ \connst -> case connst of
    LocalConnectionValid -> do
      writeChan chan $ ConnectionClosed (localConnectionId lconn)
      return LocalConnectionClosed
    LocalConnectionClosed -> return LocalConnectionClosed
  withMVar state $ \st -> case st of
    TransportValid vst -> do
      let mblep = vst ^. localEndPointAt (localConnectionLocalAddress lconn)
          theirAddress = localConnectionRemoteAddress lconn
      case mblep of
        Nothing -> return ()
        Just lep -> do
          modifyMVar_ (localEndPointState lep) $ \lepst -> case lepst of
            LocalEndPointValid lepvst -> do
              return $ LocalEndPointValid $ (connections ^: Map.delete theirAddress) lepvst
            LocalEndPointClosed -> return LocalEndPointClosed
    TransportClosed -> return ()

-- | Create a new multicast group
apiNewMulticastGroup :: MVar TransportState -> EndPointAddress -> IO (Either (TransportError NewMulticastGroupErrorCode) MulticastGroup)
apiNewMulticastGroup state ourAddress = handle (return . Left) $ do
  group <- newMVar Set.empty
  groupAddr <- withMVar state $ \st -> case st of
    TransportValid vst -> do
      let err = throw $ TransportError NewMulticastGroupFailed "Endpoint closed"
          lep = fromMaybe err $ vst ^. localEndPointAt ourAddress
      modifyMVar (localEndPointState lep) $ \lepst -> case lepst of
        LocalEndPointValid lepvst -> do
          let addr =
                MulticastAddress . BSC.pack . show . Map.size $ lepvst ^. multigroups
          return (LocalEndPointValid $ multigroupAt addr ^= group $ lepvst, addr)
        LocalEndPointClosed -> do
          throwIO $ TransportError NewMulticastGroupFailed "Endpoint closed"
    TransportClosed ->
      throwIO $ TransportError NewMulticastGroupFailed "Transport closed"
  return . Right $ createMulticastGroup state ourAddress groupAddr group

-- | Construct a multicast group
--
-- When the group is deleted some endpoints may still receive messages, but
-- subsequent calls to resolveMulticastGroup will fail. This mimicks the fact
-- that some multicast messages may still be in transit when the group is
-- deleted.
createMulticastGroup :: MVar TransportState -> EndPointAddress -> MulticastAddress -> MVar (Set EndPointAddress) -> MulticastGroup
createMulticastGroup state ourAddress groupAddress group = MulticastGroup
    { multicastAddress     = groupAddress
    , deleteMulticastGroup = withMVar state $ \st -> case st of
        TransportValid vst -> do
          -- XXX best we can do given current broken API, which needs fixing.
          let lep = fromJust $ vst ^. localEndPointAt ourAddress
          modifyMVar_ (localEndPointState lep) $ \lepst -> case lepst of
            LocalEndPointValid lepvst ->
              return $ LocalEndPointValid $ multigroups ^: Map.delete groupAddress $ lepvst
            LocalEndPointClosed -> return LocalEndPointClosed
        TransportClosed -> return ()
    , maxMsgSize           = Nothing
    , multicastSend        = \payload -> do
        withMVar state $ \st -> case st of
          TransportValid vst -> do
            es <- readMVar group
            forM_ (Set.elems es) $ \ep -> do
              let ch = localEndPointChannel $ fromJust $ vst ^. localEndPointAt ep
              writeChan ch (ReceivedMulticast groupAddress payload)
          TransportClosed ->
            throwIO $ TransportError SendFailed "Transport closed"
    , multicastSubscribe   = modifyMVar_ group $ return . Set.insert ourAddress
    , multicastUnsubscribe = modifyMVar_ group $ return . Set.delete ourAddress
    , multicastClose       = return ()
    }

-- | Resolve a multicast group
apiResolveMulticastGroup :: MVar TransportState
                         -> EndPointAddress
                         -> MulticastAddress
                         -> IO (Either (TransportError ResolveMulticastGroupErrorCode) MulticastGroup)
apiResolveMulticastGroup state ourAddress groupAddress = handle (return . Left) $ do
  st <- readMVar state
  case st of
    TransportValid vst -> do
      let err = throw $ TransportError ResolveMulticastGroupFailed "Endpoint closed"
      let lep = fromMaybe err $ vst ^. localEndPointAt ourAddress
      withMVar (localEndPointState lep) $ \lepst -> case lepst of
        LocalEndPointValid lepvst -> do
          let group = lepvst ^. (multigroups >>> DAC.mapMaybe groupAddress)
          case group of
            Nothing ->
              return . Left $
                TransportError ResolveMulticastGroupNotFound
                  ("Group " ++ show groupAddress ++ " not found")
            Just mvar ->
              return . Right $ createMulticastGroup state ourAddress groupAddress mvar
        LocalEndPointClosed ->
          throwIO $ TransportError ResolveMulticastGroupFailed "Endpoint closed"
    TransportClosed -> do
      throwIO $ TransportError ResolveMulticastGroupFailed "Transport closed"

--------------------------------------------------------------------------------
-- Lens definitions                                                           --
--------------------------------------------------------------------------------

localEndPoints :: Accessor ValidTransportState (Map EndPointAddress LocalEndPoint)
localEndPoints = accessor _localEndPoints (\leps st -> st { _localEndPoints = leps })

nextConnectionId :: Accessor ValidLocalEndPointState ConnectionId
nextConnectionId = accessor _nextConnectionId (\cid st -> st { _nextConnectionId = cid })

connections :: Accessor ValidLocalEndPointState (Map EndPointAddress LocalConnection)
connections = accessor _connections (\conns st -> st { _connections = conns })

multigroups :: Accessor ValidLocalEndPointState (Map MulticastAddress (MVar (Set EndPointAddress)))
multigroups = accessor _multigroups (\gs st -> st { _multigroups = gs })

at :: Ord k => k -> String -> Accessor (Map k v) v
at k err = accessor (Map.findWithDefault (error err) k) (Map.insert k)

localEndPointAt :: EndPointAddress -> Accessor ValidTransportState (Maybe LocalEndPoint)
localEndPointAt addr = localEndPoints >>> DAC.mapMaybe addr

connectionAt :: EndPointAddress -> Accessor ValidLocalEndPointState LocalConnection
connectionAt addr = connections >>> at addr "Invalid connection"

multigroupAt :: MulticastAddress -> Accessor ValidLocalEndPointState (MVar (Set EndPointAddress))
multigroupAt addr = multigroups >>> at addr "Invalid multigroup"
