{-# LANGUAGE OverloadedStrings #-}
import ECC.Auth
import Control.Monad (unless)
import qualified Data.ByteString as B
main :: IO ()
main = do
  let secret = "a-test-secret-at-least-thirty-two-bytes"
  a <- makeToken secret 42
  b <- makeToken secret 42
  unless (a /= b) (fail "Tokens must have independent session nonces")
  uid <- verifyToken secret a
  unless (uid == Just 42) (fail "Signed token rejected")
  invalid <- verifyToken "another-secret-at-least-thirty-two-bytes" a
  unless (invalid == Nothing) (fail "Wrong signing key accepted")
  malformed <- verifyToken secret (B.take 10 a)
  unless (malformed == Nothing) (fail "Malformed token accepted")
  putStrLn "PASS: session token roundtrip, independent nonces, invalid signatures and malformed tokens"
