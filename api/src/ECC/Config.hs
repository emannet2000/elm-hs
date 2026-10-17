{-# LANGUAGE OverloadedStrings #-}

-- | Environment-driven configuration.
module ECC.Config
  ( Config(..)
  , loadConfig
  ) where

import Data.ByteString (ByteString)
import Data.Text.Encoding (encodeUtf8)
import qualified Data.Text as T
import System.Environment (lookupEnv)

data Config = Config
  { cfgPort       :: Int
  , cfgDatabase   :: ByteString
  , cfgJwtSecret  :: ByteString
  , cfgSeedDemo   :: Bool
  , cfgDbPoolSize :: Int
  }

-- | Minimum length for a signing secret.  32 bytes is the block size of
-- HMAC-SHA256, below which the key is repeated and offers no extra strength.
minSecretLength :: Int
minSecretLength = 32

loadConfig :: IO Config
loadConfig = do
  port <- maybe 4000 read <$> lookupEnv "PORT"
  dbUrl <- lookupEnv "DATABASE_URL"
  msecret <- lookupEnv "JWT_SECRET"
  insecure <- maybe False parseTrue <$> lookupEnv "ALLOW_INSECURE_DEV"
  seed <- maybe True parseTrue <$> lookupEnv "SEED_DEMO"
  poolSize <- maybe 10 read <$> lookupEnv "DB_POOL_SIZE"
  secret <- resolveSecret insecure msecret
  pure Config
    { cfgPort = port
    , cfgDatabase =
        maybe "host=localhost dbname=ecc_crm user=postgres password=postgres"
          (encodeUtf8 . T.pack) dbUrl
    , cfgJwtSecret = secret
    , cfgSeedDemo = seed
    , cfgDbPoolSize = max 1 poolSize
    }

-- | A signing secret must be present and reasonably long.  The old behaviour
-- was to silently fall back to a well-known constant, which made every token
-- forgeable if the environment variable was forgotten; now the process refuses
-- to start unless @ALLOW_INSECURE_DEV=1@ explicitly opts into the fallback.
resolveSecret :: Bool -> Maybe String -> IO ByteString
resolveSecret insecure msecret =
  case msecret of
    Just s
      | length s >= minSecretLength -> pure (encodeUtf8 (T.pack s))
      | insecure -> warn "JWT_SECRET is shorter than 32 characters" >> pure (encodeUtf8 (T.pack s))
      | otherwise -> die ("JWT_SECRET must be at least " ++ show minSecretLength
                          ++ " characters (got " ++ show (length s) ++ ")")
    Nothing
      | insecure -> warn "JWT_SECRET is not set" >> pure devFallback
      | otherwise -> die ("JWT_SECRET is not set. Generate one with e.g. "
                          ++ "`openssl rand -hex 32`, or set ALLOW_INSECURE_DEV=1 "
                          ++ "for local development.")
  where
    devFallback = "dev-secret-change-me-not-for-production"
    warn why =
      putStrLn ("[config] WARNING: " ++ why
                ++ "; using an insecure development secret because ALLOW_INSECURE_DEV=1")
    die msg = fail ("[config] " ++ msg)

parseTrue :: String -> Bool
parseTrue v = v `notElem` ["0", "false", "no", ""]
