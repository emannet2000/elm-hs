{-# LANGUAGE OverloadedStrings #-}

-- | Minimal HS256 JSON Web Tokens (sign \/ verify), bcrypt password hashing
-- helpers and bearer-token extraction.
--
-- Only @sub@ and @exp@ claims are used; enough for this API without pulling
-- in a full JWT framework.
module ECC.Auth
  ( makeToken
  , verifyToken
  , bearerToken
  , hashPassword
  , checkPassword
  ) where

import Control.Monad (guard)
import Crypto.Hash.SHA256 (hash)
import Data.Aeson (ToJSON (..), FromJSON (..), object, withObject, encode,
                   decode', (.=), (.:))
import System.IO (withBinaryFile, IOMode(ReadMode))
import qualified Data.Text.Encoding as TE
import Data.Bits (xor, (.|.))
import qualified Crypto.BCrypt as Bcrypt
import Data.ByteString (ByteString)
import qualified Data.ByteString as B
import qualified Data.ByteString.Base64.URL as B64
import qualified Data.ByteString.Char8 as BC
import qualified Data.ByteString.Lazy as BL
import qualified Data.List as L
import Data.Time.Clock.POSIX (getPOSIXTime)
import Data.Word (Word8)
import Network.HTTP.Types.Header (HeaderName, hAuthorization)

b64url :: ByteString -> ByteString
b64url = B.filter (/= 61 {- '=' -}) . B64.encode

unb64url :: ByteString -> ByteString
unb64url t = B64.decodeLenient padded
  where
    r = B.length t `mod` 4
    padding = BC.replicate (if r == 0 then 0 else 4 - r) '='
    padded = B.append t padding

signPayload :: ByteString -> ByteString -> ByteString
signPayload secret payload = b64url (hmacSha256 secret payload)

-- | HMAC-SHA256 (RFC 2104) built directly on the raw SHA-256 primitive.
hmacSha256 :: ByteString -> ByteString -> ByteString
hmacSha256 key msg = hash (B.append opad (hash (B.append ipad msg)))
  where
    k = if B.length key > blockSize then hash key else key
    kPadded = B.append k (B.replicate (blockSize - B.length k) 0)
    ipad = B.map (xor 0x36) kPadded
    opad = B.map (xor 0x5c) kPadded
    blockSize = 64

data Claims = Claims { cSub :: Int, cExp :: Int }

instance ToJSON Claims where
  toJSON c = object [("sub" .= cSub c), ("exp" .= cExp c)]

instance FromJSON Claims where
  parseJSON = withObject "Claims" $ \o ->
    Claims <$> o .: "sub" <*> o .: "exp"

-- | Mint a token valid for one week for the given user id.
makeToken :: ByteString -> Int -> IO ByteString
makeToken secret uid = do
  now <- floor <$> getPOSIXTime :: IO Int
  nonce <- withBinaryFile "/dev/urandom" ReadMode (\h -> B.hGet h 32)
  let headerP = b64url "{\"alg\":\"HS256\",\"typ\":\"JWT\"}"
      claimsP = b64url (BL.toStrict (encode (object ["sub" .= uid, "exp" .= (now + 7 * 24 * 3600), "nonce" .= TE.decodeUtf8 (b64url nonce)])))
      payload = B.concat [headerP, ".", claimsP]
  pure (B.concat [payload, ".", signPayload secret payload])

-- | Check signature + expiry; return the subject user id on success.
verifyToken :: ByteString -> ByteString -> IO (Maybe Int)
verifyToken secret tok = do
  now <- floor <$> getPOSIXTime :: IO Int
  pure $ case BC.split '.' tok of
    [h, p, s] | not (B.null h), not (B.null p) -> check now h p s
    _ -> Nothing
  where
    check now h p s = do
      let payload = B.concat [h, ".", p]
      guard (constTimeEq (signPayload secret payload) s)
      claims <- decode' (BL.fromStrict (unb64url p)) :: Maybe Claims
      guard (cExp claims > now)
      pure (cSub claims)

-- | Compare two byte strings without leaking where they first differ.
--
-- The previous implementation used @and (B.zipWith (==) a b)@, but @and@
-- short-circuits on the first 'False', so the running time depended on the
-- position of the first differing byte — a classic timing side channel on the
-- HMAC comparison.  Here every byte pair is always folded, and the result is
-- computed from an accumulated bitwise-OR of the differences.
constTimeEq :: ByteString -> ByteString -> Bool
constTimeEq a b =
  B.length a == B.length b
    && L.foldl' (\acc (x, y) -> acc .|. (x `xor` y)) (0 :: Word8) (B.zip a b) == 0

-- | Extract the raw JWT from an @Authorization: Bearer …@ header list.
bearerToken :: [(HeaderName, ByteString)] -> Maybe ByteString
bearerToken hdrs = lookup hAuthorization hdrs >>= B.stripPrefix "Bearer "

-- | Hash with bcrypt (cost 10).
hashPassword :: ByteString -> IO ByteString
hashPassword pw = do
    mh <- Bcrypt.hashPasswordUsingPolicy policy pw
    pure (maybe "" id mh)
  where
    policy = Bcrypt.HashingPolicy { Bcrypt.preferredHashCost = 10
                                  , Bcrypt.preferredHashAlgorithm = "$2a$"
                                  }

-- | Arguments: password attempt, then the stored hash.
checkPassword :: ByteString -> ByteString -> Bool
checkPassword pw h = Bcrypt.validatePassword h pw
