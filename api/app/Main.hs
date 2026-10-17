{-# LANGUAGE OverloadedStrings #-}

-- | Entry point: load config, open PostgreSQL, run migrations, seed demo
-- data, then serve the API (and, in production, the compiled Elm SPA).
module Main (main) where

import Control.Concurrent (forkIO)
import Control.Monad (void)
import ECC.Operations (reminderWorker)
import Control.Exception (catch, try, SomeException, fromException)
import Database.PostgreSQL.Simple (Connection, close, connectPostgreSQL, SqlError(..))
import qualified Data.Aeson as A
import qualified Data.Text.Encoding as TE
import Data.List (isSuffixOf)
import qualified Data.Text as T
import Data.Maybe (fromMaybe)
import Network.HTTP.Types.Status (status200, status400, status500)
import qualified Network.Wai as Wai
import qualified Network.Wai.Handler.Warp as Warp
import Network.Wai.Middleware.RequestLogger (logStdoutDev)
import System.Directory (doesFileExist)
import System.Environment (getArgs, lookupEnv)
import System.IO (hPutStrLn, stderr)
import qualified Web.Scotty as Scotty

import ECC.Config (Config (..), loadConfig)
import qualified ECC.DB
import ECC.DB (Env (..))
import ECC.Migrations (runMigrations)
import ECC.Pool (newPool, withResource)
import ECC.RateLimit (newRateLimiter)
import ECC.Routes (app)
import ECC.Seed (seedIfEmpty)

main :: IO ()
main = do
  args <- getArgs
  case args of
    "adduser" : email : name : role : pw : _ ->
      adminCmd $ \_ conn -> do
        ECC.DB.addUser conn (T.pack email) (T.pack name) (T.pack role) (T.pack pw)
        putStrLn ("[cli] user " ++ email ++ " created/updated")
    "reset-password" : email : pw : _ ->
      adminCmd $ \_ conn -> do
        ok <- ECC.DB.setPassword conn (T.pack email) (T.pack pw)
        if ok then putStrLn ("[cli] password updated for " ++ email)
              else error ("[cli] no such user: " ++ email)
    "wipe-data" : rest ->
      -- Destructive: require an explicit --yes so it cannot be run by accident.
      if "--yes" `elem` rest
        then adminCmd $ \_ conn -> do
          ECC.DB.wipeCrmData conn
          putStrLn "[cli] all CRM data wiped (users kept)"
        else do
          putStrLn "[cli] refusing to wipe data without --yes"
          putStrLn "[cli] usage: ecc-crm-api wipe-data --yes"
    _ -> serve

-- | Shared plumbing for CLI subcommands: connect, run migrations, no seed.
adminCmd :: (Config -> Connection -> IO ()) -> IO ()
adminCmd action = do
  cfg <- loadConfig
  econn <- try (connectPostgreSQL (cfgDatabase cfg))
  case econn of
    Right conn -> do
      runMigrations conn "migrations"
      action cfg conn
    Left e -> error ("could not connect to database: " ++ show (e :: SomeException))

serve :: IO ()
serve = do
  cfg <- loadConfig
  putStrLn "[api] connecting to database…"
  -- Fail fast (with a clear message) if the database is unreachable.
  econn <- try (connectPostgreSQL (cfgDatabase cfg))
  case econn of
    Right conn -> close conn
    Left e -> error ("could not connect to database: " ++ show (e :: SomeException))
  -- One pooled connection per in-flight request; libpq connections must not
  -- be shared between Warp's worker threads.
  pool <- newPool (cfgDbPoolSize cfg)
                 (connectPostgreSQL (cfgDatabase cfg))
                 close
  limiter <- newRateLimiter 10 900  -- 10 failed sign-ins per 15 minutes
  withResource pool $ \conn -> do
    runMigrations conn "migrations"
    seedIfEmpty conn (cfgSeedDemo cfg)
  distDir <- fromMaybe "../web/dist" <$> lookupEnv "WEB_DIST"
  let env = Env { envPool = pool, envSecret = cfgJwtSecret cfg, envLimiter = limiter }
      port = cfgPort cfg
  void $ forkIO (reminderWorker env)
  origin <- lookupEnv "CORS_ORIGIN"
  waiApp <- Scotty.scottyApp (app env origin)
  putStrLn ("[api] listening on :" ++ show port)
  Warp.run port (logStdoutDev (securityHeaders (jsonErrors (staticFiles distDir waiApp))))

-- Portal bearer tokens must not leak through referrers or browser caches.
securityHeaders :: Wai.Middleware
securityHeaders inner req respond = inner req $ respond . Wai.mapResponseHeaders
  ([("X-Content-Type-Options","nosniff"),("Referrer-Policy","no-referrer"),("X-Frame-Options","SAMEORIGIN"),("Cache-Control","no-store")] ++)

-- | Never leak an HTML stack trace to an API client: log the exception and
-- answer with a JSON 500.
jsonErrors :: Wai.Middleware
jsonErrors inner req respond =
  inner req respond `catch` handle
  where
    handle :: SomeException -> IO Wai.ResponseReceived
    handle e = do
      hPutStrLn stderr ("[api] unhandled exception: " ++ show e)
      case fromException e :: Maybe SqlError of
        Just se | sqlState se `elem` ["P0001","23505","23503","23514","23502"] ->
          respond (Wai.responseLBS status400 [("Content-Type","application/json")]
            (A.encode (A.object ["error" A..= (if sqlState se == "P0001" then TE.decodeUtf8 (sqlErrorMsg se) else "Invalid or duplicate record")])))
        _ -> respond (Wai.responseLBS status500
          [("Content-Type", "application/json")]
          "{\"error\":\"Internal server error\",\"status\":500}")

-- | Serve the compiled Elm SPA from WEB_DIST for anything that is not an
-- @/api@ request; unknown paths fall back to index.html (client routing).
staticFiles :: FilePath -> Wai.Middleware
staticFiles root nextApp req respond =
  case Wai.pathInfo req of
    ("api":_) -> nextApp req respond
    segments -> do
      let rel = T.unpack (T.intercalate "/" segments)
          unsafe = any (\segment -> segment == ".." || segment == "." || T.any (\c -> c == '/' || c == '\\') segment) segments
          candidate = if null rel || unsafe then indexHtml else root ++ "/" ++ rel
      isFile <- doesFileExist candidate
      let fp = if isFile then candidate else indexHtml
      respond $ Wai.responseFile status200 [contentType fp] fp Nothing
  where
    indexHtml = root ++ "/index.html"
    contentType fp
      | ".html" `isSuffixOf` fp = ("Content-Type", "text/html; charset=utf-8")
      | ".css"  `isSuffixOf` fp = ("Content-Type", "text/css; charset=utf-8")
      | ".js"   `isSuffixOf` fp = ("Content-Type", "application/javascript")
      | ".svg"  `isSuffixOf` fp = ("Content-Type", "image/svg+xml")
      | ".png"  `isSuffixOf` fp = ("Content-Type", "image/png")
      | ".ico"  `isSuffixOf` fp = ("Content-Type", "image/x-icon")
      | otherwise               = ("Content-Type", "application/octet-stream")
