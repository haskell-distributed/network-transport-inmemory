{-# LANGUAGE RecursiveDo #-}
{-# OPTIONS_GHC -fno-warn-deprecations #-}

-- | In-memory implementation of the Transport API.
module Network.Transport.Chan (createTransport) where

import Network.Transport
import Network.Transport.Internal ( mapIOException )
import Control.Applicative
import Control.Concurrent.Chan (Chan, newChan, readChan, writeChan, isEmptyChan)
import Control.Category ((>>>))
import Control.Concurrent.MVar
  ( MVar
  , newMVar
  , modifyMVar
  , modifyMVar_
  , readMVar
  , withMVar
  , swapMVar
  )
import Control.Exception (handle, throw, throwIO, evaluate, mask_)
import Control.Monad (forM, when)
import Data.Map (Map)
import Data.Maybe (fromMaybe, fromJust)
import Data.Foldable (forM_)
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
  , _nextLocalEndPointId :: !Int
  }

data LocalEndPoint = LocalEndPoint
  { localEndPointAddress :: !EndPointAddress
  , localEndPointChannel :: !(ClosingChan Event)
  , localEndPointState   :: !(MVar LocalEndPointState)
  }

data LocalEndPointState
  = LocalEndPointValid {-# UNPACK #-} !ValidLocalEndPointState
  | LocalEndPointClosed

data ValidLocalEndPointState = ValidLocalEndPointState
  { _nextConnectionId :: !ConnectionId
  , _connections :: !(Map (EndPointAddress,ConnectionId) LocalConnection)
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
  | LocalConnectionFailed

-- | Create a new Transport.
--
-- Only a single transport should be created per Haskell process
-- (threads can, and should, create their own endpoints though).
createTransport :: IO Transport
createTransport = do
  state <- newMVar $ TransportValid $ ValidTransportState
    { _localEndPoints = Map.empty
    , _nextLocalEndPointId = 0
    }
  return Transport
    { newEndPoint    = apiNewEndPoint state
    , closeTransport = do
        old <- swapMVar state TransportClosed
        case old of
          TransportClosed -> return ()
          TransportValid tvst ->
            forM_ (tvst ^. localEndPoints) $ \l -> do
              lpOld <- swapMVar (localEndPointState l) LocalEndPointClosed
              case lpOld of
                LocalEndPointClosed -> return ()
                LocalEndPointValid lvst -> do
                  forM_ (Map.elems (lvst ^. connections)) $ \con ->
                    swapMVar (localConnectionState con) LocalConnectionClosed
              writeClosingChan (localEndPointChannel l) EndPointClosed
              closeClosingChan (localEndPointChannel l)
    }

-- | Create a new end point.
apiNewEndPoint :: MVar TransportState -> IO (Either (TransportError NewEndPointErrorCode) EndPoint)
apiNewEndPoint state = handle (return . Left) $ do
  chan <- newClosingChan
  addr <- modifyMVar state $ \st -> case st of
    TransportValid vst -> do
      lepState <- newMVar $ LocalEndPointValid $ ValidLocalEndPointState
        { _nextConnectionId = 1
        , _connections = Map.empty
        , _multigroups = Map.empty
        }
      let r = nextLocalEndPointId ^: (+ 1) $ vst
          addr = EndPointAddress . BSC.pack . show $ r ^. nextLocalEndPointId
          lep = LocalEndPoint
            { localEndPointAddress = addr
            , localEndPointChannel = chan
            , localEndPointState = lepState
            }
      return (TransportValid $ localEndPointAt addr ^= Just lep $ r, addr)
    TransportClosed -> throwIO $ TransportError NewEndPointFailed "Transport closed"
  return $ Right $ EndPoint
    { receive       = readClosingChan chan
    , address       = addr
    , connect       = apiConnect addr state
    , closeEndPoint = apiCloseEndPoint state addr
    , newMulticastGroup     = apiNewMulticastGroup state addr
    , resolveMulticastGroup = apiResolveMulticastGroup state addr
    }

apiCloseEndPoint :: MVar TransportState -> EndPointAddress -> IO ()
apiCloseEndPoint state addr = mask_ $ modifyMVar_ state $ \st -> case st of
    TransportValid vst -> do
      case vst ^. localEndPointAt addr of
        Nothing -> return $ TransportValid vst
        Just lep -> do
          old <- swapMVar (localEndPointState lep) LocalEndPointClosed
          case old of
            LocalEndPointClosed -> return ()
            LocalEndPointValid lepvst -> do
              acts <- forM (Map.elems (lepvst ^. connections)) $ \lconn -> do
                  modifyMVar (localConnectionState lconn) $ \_ -> do
                     let finalize = case (vst ^. localEndPointAt (localConnectionRemoteAddress lconn)) of
                          Nothing -> return ()
                          Just thep -> withMVar (localEndPointState thep) $ \thepst -> case thepst of
                            LocalEndPointValid _ -> writeClosingChan (localEndPointChannel thep)
                                                     $ ConnectionClosed (localConnectionId lconn)
                            _ -> return ()
                     return (LocalConnectionClosed, finalize)
              sequence_ acts
              writeClosingChan (localEndPointChannel lep) EndPointClosed
              closeClosingChan (localEndPointChannel lep)
          return $ TransportValid $! (localEndPoints ^: Map.delete addr) vst
    TransportClosed -> return TransportClosed

apiBreakConnection :: MVar TransportState -> EndPointAddress -> EndPointAddress -> String -> IO ()
apiBreakConnection state us them msg = withMVar state $ \st -> case st of
    TransportValid vst -> breakOne vst us them >> breakOne vst them us
    TransportClosed -> return ()
  where
    breakOne vst a b = do
      case vst ^. localEndPointAt a of
        Nothing -> return ()
        Just lep -> do
          modifyMVar_ (localEndPointState lep) $ \lepst -> case lepst of
            LocalEndPointClosed -> return LocalEndPointClosed
            LocalEndPointValid lepvst -> do
              let (cl, other) = Map.partitionWithKey (\(addr,_) _ -> addr == b)
                                                     (lepvst ^.connections)
              forM_ cl $ \c -> swapMVar (localConnectionState c) LocalConnectionFailed
              writeClosingChan (localEndPointChannel lep)
                               (ErrorEvent (TransportError (EventConnectionLost b) msg))
              return $! LocalEndPointValid $! (connections ^= other) lepvst


-- | Create a new connection
apiConnect :: EndPointAddress
           -> MVar TransportState
           -> EndPointAddress
           -> Reliability
           -> ConnectHints
           -> IO (Either (TransportError ConnectErrorCode) Connection)
apiConnect ourAddress state theirAddress _reliability _hints = do
    handle (return . Left) $ fmap Right $ do
      (chan, lconn) <- do
        withMVar state $ \st -> case st of
          TransportValid vst -> do
            ourlep <- case vst ^. localEndPointAt ourAddress of
                        Nothing -> throwIO $ TransportError ConnectFailed "Endpoint closed"
                        Just x  -> evaluate x
            theirlep <- case vst ^. localEndPointAt theirAddress of
                          Nothing -> throwIO $ TransportError ConnectNotFound "Endpoint not found"
                          Just x  -> evaluate x
            -- No masking necessary, because we don't need atomicity here.
            conid <- modifyMVar (localEndPointState theirlep) $ \lepst -> case lepst of
              LocalEndPointValid lepvst -> do
                let r = nextConnectionId ^: (+ 1) $ lepvst
                return ( LocalEndPointValid r
                       , r ^. nextConnectionId
                       )
              LocalEndPointClosed ->
                throwIO $ TransportError ConnectFailed "endpoint closed"
            modifyMVar (localEndPointState ourlep) $ \lepst -> case lepst of
              LocalEndPointValid lepvst -> do
                lconnState <- newMVar LocalConnectionValid
                let lconn = LocalConnection
                             { localConnectionId = conid
                             , localConnectionLocalAddress = ourAddress
                             , localConnectionRemoteAddress = theirAddress
                             , localConnectionState = lconnState
                             }
                return ( LocalEndPointValid $ connectionAt (theirAddress, conid) ^= lconn $ lepvst
                       , ( localEndPointChannel theirlep
                         , lconn
                         )
                       )
              LocalEndPointClosed ->
                throwIO $ TransportError ConnectFailed "Endpoint closed"
          TransportClosed ->
            throwIO $ TransportError ConnectFailed "Transport closed"
      writeClosingChan chan $
        ConnectionOpened (localConnectionId lconn) ReliableOrdered ourAddress
      return $ Connection
        { send  = apiSend chan state lconn
        , close = apiClose chan state lconn
        }

-- | Send a message over a connection
apiSend :: ClosingChan Event
        -> MVar TransportState
        -> LocalConnection
        -> [ByteString]
        -> IO (Either (TransportError SendErrorCode) ())
apiSend chan state lconn msg = mask_ $ handle handleFailure  $ mapIOException sendFailed $
    withMVar (localConnectionState lconn) $ \connst -> case connst of
      LocalConnectionValid -> do
        foldr seq () msg `seq` writeClosingChan chan (Received (localConnectionId lconn) msg)
        return $ Right ()
      LocalConnectionClosed -> do
        -- If the local connection was closed, check why.
        withMVar state $ \st -> case st of
          TransportValid vst -> do
            let addr = localConnectionLocalAddress lconn
                mblep = vst ^. localEndPointAt addr
            case mblep of
              Nothing -> throwIO $ TransportError SendFailed "Endpoint closed"
              Just lep -> do
                withMVar (localEndPointState lep) $ \lepst -> case lepst of
                  LocalEndPointValid _ -> do
                    return $ Left $ TransportError SendClosed "Connection closed"
                  LocalEndPointClosed -> do
                    throwIO $ TransportError SendFailed "Endpoint closed"
          _ -> return $ Left $ TransportError SendFailed "Transport is closed"
      LocalConnectionFailed -> return $ Left $ TransportError SendFailed "Endpoint closed"
    where
      sendFailed = TransportError SendFailed . show
      handleFailure ex@(TransportError SendFailed reason) = do
        apiBreakConnection state (localConnectionLocalAddress lconn)
                                 (localConnectionRemoteAddress lconn)
                                 reason
        return (Left ex)
      handleFailure ex = return (Left ex)

-- | Close a connection
apiClose :: ClosingChan Event
         -> MVar TransportState
         -> LocalConnection
         -> IO ()
apiClose chan state lconn = do
  modifyMVar_ (localConnectionState lconn) $ \connst -> case connst of
    LocalConnectionValid -> do
      writeClosingChan chan $ ConnectionClosed (localConnectionId lconn)
      return LocalConnectionClosed
    _ -> return LocalConnectionClosed
  withMVar state $ \st -> case st of
    TransportValid vst -> do
      let mblep = vst ^. localEndPointAt (localConnectionLocalAddress lconn)
          theirAddress = localConnectionRemoteAddress lconn
      case mblep of
        Nothing -> return ()
        Just lep -> do
          modifyMVar_ (localEndPointState lep) $ \lepst -> case lepst of
            LocalEndPointValid lepvst -> do
              return $ LocalEndPointValid $ (connections ^: Map.delete (theirAddress, localConnectionId lconn))
                                          lepvst
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
              writeClosingChan ch (ReceivedMulticast groupAddress payload)
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

nextLocalEndPointId :: Accessor ValidTransportState Int
nextLocalEndPointId = accessor _nextLocalEndPointId (\eid st -> st{ _nextLocalEndPointId = eid} )

localEndPoints :: Accessor ValidTransportState (Map EndPointAddress LocalEndPoint)
localEndPoints = accessor _localEndPoints (\leps st -> st { _localEndPoints = leps })

nextConnectionId :: Accessor ValidLocalEndPointState ConnectionId
nextConnectionId = accessor _nextConnectionId (\cid st -> st { _nextConnectionId = cid })

connections :: Accessor ValidLocalEndPointState (Map (EndPointAddress,ConnectionId) LocalConnection)
connections = accessor _connections (\conns st -> st { _connections = conns })

multigroups :: Accessor ValidLocalEndPointState (Map MulticastAddress (MVar (Set EndPointAddress)))
multigroups = accessor _multigroups (\gs st -> st { _multigroups = gs })

at :: Ord k => k -> String -> Accessor (Map k v) v
at k err = accessor (Map.findWithDefault (error err) k) (Map.insert k)

localEndPointAt :: EndPointAddress -> Accessor ValidTransportState (Maybe LocalEndPoint)
localEndPointAt addr = localEndPoints >>> DAC.mapMaybe addr

connectionAt :: (EndPointAddress, ConnectionId) -> Accessor ValidLocalEndPointState LocalConnection
connectionAt addr = connections >>> at addr "Invalid connection"

multigroupAt :: MulticastAddress -> Accessor ValidLocalEndPointState (MVar (Set EndPointAddress))
multigroupAt addr = multigroups >>> at addr "Invalid multigroup"


---------------------------------------------------------------------------------
-- Closing chan
---------------------------------------------------------------------------------

data ClosingChan a = ClosingChan !(MVar ()) (MVar Bool) (Chan a)

newClosingChan :: IO (ClosingChan a)
newClosingChan = ClosingChan <$> newMVar ()
                             <*> newMVar True
                             <*> newChan

writeClosingChan :: ClosingChan a -> a -> IO ()
writeClosingChan (ClosingChan _ cl ch) m = do
  withMVar cl $ \s ->
    if s then writeChan ch m
         else return ()

readClosingChan :: ClosingChan a -> IO a
readClosingChan (ClosingChan b cl ch) =
  withMVar b $ \_ -> do
    s <- readMVar cl
    if s then readChan ch
         else do mx <- isEmptyChan ch                -- XXX isEmptyChan is deprecated because it's not
                 if mx                               -- possible to implement it in a right way, however
                    then error "Channel is closed"   -- actions here are serialized by lock, so we are
                    else readChan ch                 -- safe here

closeClosingChan :: ClosingChan a -> IO ()
closeClosingChan (ClosingChan _ cl ch) = mask_ $ do
  old <- swapMVar cl False
  when old (writeChan ch (error "channel is closed"))
