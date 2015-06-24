-- |
-- Module: Main
-- Copyright: (c) 2015, Tweag I/O
--
module Main where

import Criterion.Main
import Control.Exception (throw)
import Control.Monad (replicateM)
import Control.DeepSeq
import Network.Transport
import Network.Transport.Chan
import Network.Transport.Benchmark

data FakeNF a = FakeNF a

instance NFData (FakeNF a) where
  rnf x = x `seq` ()

setupEnv :: IO (FakeNF [EndPoint], FakeNF [EndPoint])
setupEnv = do
  transport <- createTransport
  small <- replicateM 2 $ either throw id <$>  newEndPoint transport
  big   <- replicateM 10 $ either throw id <$>  newEndPoint transport
  return (FakeNF small, FakeNF big)

main :: IO ()
main = defaultMain
    [ env setupEnv $ \ ~(FakeNF small, FakeNF big) -> bgroup "local"
        [ bgroup "2 endpoints"
              [ bench "100 bytes 1 chunk"  $ whnfIO (benchmarkPingLocal small (BenchmarkOptions 1000 100 1))
              , bench "10 bytes 10 chunks" $ whnfIO (benchmarkPingLocal small (BenchmarkOptions 1000 10 10))
              , bench "1 byte 100 chunks"  $ whnfIO (benchmarkPingLocal small (BenchmarkOptions 1000 1 100))
              ]
        , bgroup "10 endpoints"
              [ bench "100 bytes 1 chunk"  $ whnfIO (benchmarkPingLocal big (BenchmarkOptions 1000 100 1))
              , bench "10 bytes 10 chunks" $ whnfIO (benchmarkPingLocal big (BenchmarkOptions 1000 10 10))
              , bench "1 byte 100 chunks"  $ whnfIO (benchmarkPingLocal big (BenchmarkOptions 1000 1 100))
              ]
        ]
    ]
