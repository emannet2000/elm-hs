{-# LANGUAGE OverloadedStrings #-}
module ECC.Operations (operations, sessionValid, revokeSession, registerSession, reminderWorker, canAccess, validUpload) where

import Control.Concurrent (threadDelay)
import Control.Exception (catch, SomeException)
import Control.Monad (forever, void)
import Control.Monad.IO.Class (liftIO)
import qualified Crypto.Hash.SHA256 as SHA
import qualified Data.Aeson as A
import qualified Data.Aeson.KeyMap as KM
import qualified Data.ByteString as B
import qualified Data.ByteString.Lazy as BL
import qualified Data.Text as T
import qualified Data.Text.Encoding as TE
import qualified Data.Text.Encoding.Error as TEE
import Data.Maybe (listToMaybe)
import Database.PostgreSQL.Simple
import Network.HTTP.Types (status400, status403)
import Network.Wai.Parse (FileInfo(..))
import qualified Web.Scotty as S
import ECC.DB (Env, withConn, insertDocument)
import ECC.Models (User(..), Document(..))

sessionValid :: Env -> B.ByteString -> IO Bool
sessionValid env tok = withConn env $ \c -> do
  [Only ok] <- query c "SELECT EXISTS(SELECT 1 FROM auth_sessions WHERE token_hash=? AND revoked_at IS NULL AND expires_at>now())" (Only (Binary (SHA.hash tok)))
  pure ok

registerSession :: Env -> Int -> B.ByteString -> IO ()
registerSession env uid tok = withConn env $ \c -> void $ execute c "INSERT INTO auth_sessions(token_hash,user_id) VALUES (?,?) ON CONFLICT(token_hash) DO UPDATE SET revoked_at=NULL" (Binary (SHA.hash tok),uid)

revokeSession :: Env -> B.ByteString -> IO ()
revokeSession env tok = withConn env $ \c -> void $ execute c "UPDATE auth_sessions SET revoked_at=now() WHERE token_hash=?" (Only (Binary (SHA.hash tok)))

canAccess :: Env -> User -> T.Text -> Int -> IO Bool
canAccess env u kind rid = withConn env $ \c -> do
  [Only ok] <- query c "SELECT crm_can_access(?,?,?)" (userId u,kind,rid)
  pure ok

reminderWorker :: Env -> IO ()
reminderWorker env = forever $ do
  (withConn env $ \c -> void (execute_ c "DO $$ BEGIN PERFORM crm_generate_reminders(); END $$")) `catch` logFailure
  threadDelay (60 * 1000000)
  where logFailure :: SomeException -> IO ()
        logFailure e = putStrLn ("[reminders] " ++ show e)

-- SQL produces a single JSON value; decode text to avoid coupling row instances to aeson.
jsonQuery :: ToRow a => Connection -> Query -> a -> IO A.Value
jsonQuery c q args = do
  rows <- query c q args :: IO [Only T.Text]
  pure $ maybe A.Null (maybe A.Null id . A.decodeStrict' . TE.encodeUtf8 . fromOnly) (listToMaybe rows)

sqlResult :: IO A.Value -> S.ActionM ()
sqlResult action = do
  result <- liftIO $ (Right <$> action) `catch` handle
  case result of
    Right v -> S.json v
    Left msg -> S.status status400 >> S.json (A.object ["error" A..= msg])
  where
    handle :: SqlError -> IO (Either T.Text A.Value)
    handle e
      | sqlState e `elem` ["P0001","23505","23503","23514","23502","22P02","22007","22008"] =
          pure (Left (if sqlState e == "P0001" then TE.decodeUtf8 (sqlErrorMsg e) else "Invalid value, duplicate reference, or missing related record"))
      | otherwise = ioError (userError (show e))

operations :: Env -> ((User -> S.ActionM ()) -> S.ActionM ()) -> S.ScottyM ()
operations env authenticated = do
  S.get "/api/operations" $ authenticated $ \u ->
    sqlResult $ withConn env $ \c -> jsonQuery c "SELECT crm_snapshot(?)::text" (Only (userId u))
  S.post "/api/operations/:operation" $ authenticated $ \u -> do
    op <- S.pathParam "operation" :: S.ActionM T.Text
    body <- S.jsonData :: S.ActionM A.Value
    sqlResult $ withConn env $ \c -> withTransaction c $
      jsonQuery c "SELECT crm_command(?,?,?::jsonb)::text" (userId u,op,TE.decodeUtf8 (BL.toStrict (A.encode body)))
  S.get "/api/portal" $ do
    tok <- S.header "X-Portal-Token"
    case tok of
      Nothing -> S.status status403 >> S.json (A.object ["error" A..= ("Portal token required" :: T.Text)])
      Just token -> sqlResult $ withConn env $ \c -> jsonQuery c "SELECT crm_portal(?)::text" (Only token)
  S.post "/api/portal/messages" $ do
    tok <- S.header "X-Portal-Token"
    body <- S.jsonData :: S.ActionM A.Value
    case (tok, body) of
      (Just token,A.Object o) | Just (A.String msg) <- KM.lookup "body" o, not (T.null (T.strip msg)), T.length msg <= 10000 ->
        sqlResult $ withConn env $ \c -> withTransaction c $ do
          _ <- jsonQuery c "SELECT crm_portal(?)::text" (Only token)
          void $ execute c "INSERT INTO communications(client_id,kind,body) SELECT client_id,'Message',? FROM portal_access WHERE token_hash=sha256(convert_to(?,'UTF8')) AND revoked_at IS NULL AND expires_at>now()" (msg,token)
          pure (A.object ["sent" A..= True])
      _ -> S.status status400 >> S.json (A.object ["error" A..= ("A valid portal token and message are required" :: T.Text)])
  S.post "/api/portal/documents" $ do
    tok <- S.header "X-Portal-Token"
    fs <- S.files
    params <- S.formParams
    case (tok,[f | ("file",f)<-fs]) of
      (Just token,f:_) | validUpload f ->
        sqlResult $ withConn env $ \c -> withTransaction c $ do
          _ <- jsonQuery c "SELECT crm_portal(?)::text" (Only token)
          [Only cid] <- query c "SELECT client_id FROM portal_access WHERE token_hash=sha256(convert_to(?,'UTF8')) AND revoked_at IS NULL AND expires_at>now() FOR SHARE" (Only token) :: IO [Only Int]
          did <- insertDocument c Nothing (Just cid) (safeFilename (fileName f)) (TE.decodeUtf8 (fileContentType f)) (BL.toStrict (fileContent f)) Nothing
          void $ execute c "UPDATE documents SET category=coalesce(nullif(?,''),'Other') WHERE id=?" (lookup "category" params,documentId did)
          pure (A.object ["uploaded" A..= True])
      _ -> S.status status400 >> S.json (A.object ["error" A..= ("Upload a PDF, JPEG or PNG up to 25 MB with a valid portal token" :: T.Text)])

validUpload :: FileInfo BL.ByteString -> Bool
validUpload f = let bytes=BL.toStrict (fileContent f) in
  not (B.null bytes) && B.length bytes<=25*1024*1024 &&
  ((fileContentType f=="application/pdf" && "%PDF-" `B.isPrefixOf` bytes) ||
   (fileContentType f=="image/png" && B.pack [137,80,78,71,13,10,26,10] `B.isPrefixOf` bytes) ||
   (fileContentType f=="image/jpeg" && B.pack [255,216,255] `B.isPrefixOf` bytes))

safeFilename :: B.ByteString -> T.Text
safeFilename = T.take 200 . T.filter (\c -> c>=' ' && c/='"') . last . T.splitOn "/" . T.replace "\\" "/" . TE.decodeUtf8With TEE.lenientDecode
