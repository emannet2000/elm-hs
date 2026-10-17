{-# LANGUAGE BangPatterns #-}

-- | A tiny, dependency-free connection pool.
--
-- Every request borrows a connection for the duration of one handler, then
-- hands it back.  A 'QSem' caps the number of simultaneous checkouts at the
-- configured size, so the process never opens more than @size@ database
-- connections even under load.
--
-- This replaces the previous design, which shared a single libpq connection
-- across all of Warp's worker threads.  A libpq connection must only be used
-- by one thread at a time, so sharing it could interleave protocol messages
-- and mix transactions.
module ECC.Pool
  ( Pool
  , newPool
  , withResource
  , destroyPool
  ) where

import Control.Concurrent.MVar (MVar, modifyMVar, modifyMVar_, newMVar)
import Control.Concurrent.QSem (QSem, newQSem, signalQSem, waitQSem)
import Control.Exception (bracket, bracket_)
import Control.Monad (forM_)

data Pool a = Pool
  { poolSem     :: QSem
  , poolIdle    :: MVar [a]
  , poolCreate  :: IO a
  , poolDestroy :: a -> IO ()
  }

-- | Create a pool of at most @size@ resources.  Resources are created lazily
-- on first use and destroyed by 'destroyPool'.
newPool :: Int -> IO a -> (a -> IO ()) -> IO (Pool a)
newPool size create destroy = do
  sem <- newQSem (max 1 size)
  idle <- newMVar []
  pure Pool
    { poolSem = sem
    , poolIdle = idle
    , poolCreate = create
    , poolDestroy = destroy
    }

-- | Borrow a resource for the duration of the action and return it
-- afterwards (even if the action throws).
withResource :: Pool a -> (a -> IO r) -> IO r
withResource p = bracket_ (waitQSem (poolSem p)) (signalQSem (poolSem p)) . use
  where
    use act = bracket (takeResource p) (putResource p) act

takeResource :: Pool a -> IO a
takeResource p = do
  m <- modifyMVar (poolIdle p) $ \xs -> case xs of
    (x : rest) -> pure (rest, Just x)
    []         -> pure ([], Nothing)
  maybe (poolCreate p) pure m

putResource :: Pool a -> a -> IO ()
putResource p x = modifyMVar_ (poolIdle p) (pure . (x :))

-- | Close every idle resource.  In-flight checkouts are not interrupted.
destroyPool :: Pool a -> IO ()
destroyPool p = do
  xs <- modifyMVar (poolIdle p) (\xs -> pure ([], xs))
  forM_ xs (poolDestroy p)
