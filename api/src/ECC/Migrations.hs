{-# LANGUAGE OverloadedStrings #-}

-- | Applies SQL migrations from the @migrations/@ directory, tracking applied
-- versions in a @schema_migrations@ table.
module ECC.Migrations (runMigrations) where

import Control.Monad (forM_, unless)

import qualified Data.ByteString as B
import qualified Data.Text as T
import Data.List (sort, isSuffixOf)
import Database.PostgreSQL.Simple
import Database.PostgreSQL.Simple.Types (Query (..))
import System.Directory (listDirectory)
import System.FilePath ((</>))

runMigrations :: Connection -> FilePath -> IO ()
runMigrations conn dir = do
  _ <- execute_ conn
    "CREATE TABLE IF NOT EXISTS schema_migrations (version TEXT PRIMARY KEY, applied_at TIMESTAMPTZ NOT NULL DEFAULT NOW())"
  files <- listDirectory dir
  let sqls = sort [f | f <- files, ".sql" `isSuffixOf` f]
  applied <- map fromOnly <$>
    query_ conn "SELECT version FROM schema_migrations" :: IO [T.Text]
  forM_ sqls $ \f -> do
    let ver = T.pack f
    unless (ver `elem` applied) $ do
      contents <- B.readFile (dir </> f)
      withTransaction conn $ do
        _ <- execute_ conn (Query contents)
        _ <- execute conn "INSERT INTO schema_migrations (version) VALUES (?)" (Only ver)
        pure ()
      putStrLn ("[migrate] applied " ++ f)
