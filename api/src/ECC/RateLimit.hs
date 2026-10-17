{-# LANGUAGE OverloadedStrings #-}

-- | A small in-memory throttle for failed sign-in attempts, used to slow down
-- online password guessing against @/api/auth/login@.
--
-- State lives in an 'MVar', so it is safe to share across Warp's worker
-- threads.  It is intentionally per-process: for a multi-instance deployment
-- put a real limiter (or a reverse proxy) in front of the API.
module ECC.RateLimit
  ( RateLimiter
  , newRateLimiter
  , isThrottled
  , recordFailure
  , clearFailures
  ) where

import Control.Concurrent.MVar (MVar, modifyMVar_, newMVar, readMVar)
import qualified Data.Map.Strict as M
import Data.Text (Text)
import Data.Time.Clock (NominalDiffTime, UTCTime, diffUTCTime)

data RateLimiter = RateLimiter
  { rlState  :: MVar (M.Map Text (Int, UTCTime))
  , rlMax    :: Int
  , rlWindow :: NominalDiffTime
  }

-- | Allow @maxAttempts@ failed attempts per key (e.g. a lower-cased email)
-- inside a rolling @window@.
newRateLimiter :: Int -> NominalDiffTime -> IO RateLimiter
newRateLimiter maxAttempts window =
  RateLimiter <$> newMVar M.empty <*> pure maxAttempts <*> pure window

-- | True when the key has reached the failure limit inside the current window.
isThrottled :: RateLimiter -> UTCTime -> Text -> IO Bool
isThrottled rl now key = do
  m <- readMVar (rlState rl)
  pure $ case M.lookup key m of
    Just (n, first) -> n >= rlMax rl && diffUTCTime now first < rlWindow rl
    Nothing         -> False

-- | Count one failure, dropping entries that have aged out of the window so
-- the map cannot grow without bound.
recordFailure :: RateLimiter -> UTCTime -> Text -> IO ()
recordFailure rl now key =
  modifyMVar_ (rlState rl) $ \m ->
    let live = M.filter (\(_, first) -> diffUTCTime now first < rlWindow rl) m
        next = case M.lookup key live of
          Just (n, first) -> (n + 1, first)
          Nothing         -> (1, now)
    in pure (M.insert key next live)

-- | Forget the failures for a key (called after a successful sign-in).
clearFailures :: RateLimiter -> Text -> IO ()
clearFailures rl key = modifyMVar_ (rlState rl) (pure . M.delete key)
