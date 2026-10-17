{-# LANGUAGE OverloadedStrings #-}

-- | All HTTP routes (Scotty).  Every endpoint lives under @/api@ and speaks
-- camelCase JSON.  Protected endpoints require @Authorization: Bearer <jwt>@;
-- viewers are read-only.
--
-- Every handler borrows a connection from the pool for the duration of one
-- request (@withConn@); nothing shares a raw libpq connection across threads.
module ECC.Routes (app) where

import Control.Monad (void)
import Control.Monad.Catch (Handler(..))
import Control.Monad.IO.Class (liftIO)
import qualified Data.Aeson as A
import Data.Aeson ((.=))
import qualified Data.ByteString as B
import qualified Data.ByteString.Lazy as BL
import Data.Maybe (fromMaybe)
import qualified Data.Text as T
import qualified Data.Text.Encoding as TE
import qualified Data.Text.Encoding.Error as TEE
import qualified Data.Text.Lazy as TL
import Data.Time.Clock (getCurrentTime)
import Network.HTTP.Types (status200, status400, status401, status403,
                           status404, status429, status500)
import qualified Network.Wai as Wai
import Network.Wai.Middleware.Cors (cors, simpleCorsResourcePolicy, CorsResourcePolicy(..))
import Network.Wai.Parse (FileInfo (..))
import qualified Web.Scotty as S

import ECC.Operations (operations, sessionValid, revokeSession, registerSession, canAccess, validUpload)
import Database.PostgreSQL.Simple (query, query_, withTransaction, Only(..), SqlError(..))
import ECC.Auth (bearerToken, checkPassword, makeToken, verifyToken)
import ECC.Csv (clientsCsv, leadsCsv, parseCsv)
import ECC.DB
import ECC.Models
import ECC.RateLimit (clearFailures, isThrottled, recordFailure)

errJson :: Int -> T.Text -> A.Value
errJson code msg =
  A.object ["error" .= msg, "status" .= code]

unauthorized :: T.Text -> S.ActionM ()
unauthorized msg = S.status status401 >> S.json (errJson 401 msg)

forbidden :: T.Text -> S.ActionM ()
forbidden msg = S.status status403 >> S.json (errJson 403 msg)

notFound :: T.Text -> S.ActionM ()
notFound msg = S.status status404 >> S.json (errJson 404 msg)

badRequest :: T.Text -> S.ActionM ()
badRequest msg = S.status status400 >> S.json (errJson 400 msg)

tooManyRequests :: T.Text -> S.ActionM ()
tooManyRequests msg = S.status status429 >> S.json (errJson 429 msg)

serverError :: T.Text -> S.ActionM ()
serverError msg = S.status status500 >> S.json (errJson 500 msg)

-- ---------- auth plumbing ----------

currentUser :: Env -> S.ActionM (Maybe User)
currentUser env = do
  req <- S.request
  case bearerToken (Wai.requestHeaders req) of
    Nothing -> pure Nothing
    Just tok -> do
      valid <- liftIO $ sessionValid env tok
      muid <- liftIO $ verifyToken (envSecret env) tok
      case (if valid then muid else Nothing) of
        Nothing -> pure Nothing
        Just uid -> liftIO $ withConn env $ \conn -> getUserById conn uid

withUser :: Env -> (User -> S.ActionM ()) -> S.ActionM ()
withUser env act = do
  mu <- currentUser env
  case mu of
    Just u -> do
      req <- S.request
      allowed <- liftIO $ requestAccess env u (Wai.pathInfo req)
      if allowed then act u else forbidden "Record unavailable or access denied"
    Nothing -> unauthorized "Not authenticated"

withWriter :: Env -> (User -> S.ActionM ()) -> S.ActionM ()
withWriter env act = withUser env $ \u ->
  if userRole u == "viewer"
    then forbidden "Read-only account — ask an admin for write access"
    else act u

-- Access is checked on every legacy record endpoint as well as the operations API.
requestAccess :: Env -> User -> [T.Text] -> IO Bool
requestAccess env u path = case path of
  ("api":"leads":raw:_) | Just rid <- readMaybeT raw -> canAccess env u "lead" rid
  ("api":"clients":raw:_) | Just rid <- readMaybeT raw -> canAccess env u "client" rid
  ("api":"cases":raw:_) | Just rid <- readMaybeT raw -> canAccess env u "case" rid
  ("api":"documents":raw:_) | Just rid <- (readMaybeT raw :: Maybe Int) -> withConn env $ \c -> do
    rows <- query c "SELECT crm_can_access(?,CASE WHEN client_id IS NOT NULL THEN 'client' ELSE 'lead' END,coalesce(client_id,lead_id)) FROM documents WHERE id=?" (userId u,rid) :: IO [Only Bool]
    pure (rows == [Only True])
  ("api":"tasks":raw:_) | Just rid <- (readMaybeT raw :: Maybe Int) -> withConn env $ \c -> do
    rows <- query c "SELECT crm_can_access(?,CASE WHEN client_id IS NOT NULL THEN 'client' ELSE 'lead' END,coalesce(client_id,lead_id)) FROM tasks WHERE id=?" (userId u,rid) :: IO [Only Bool]
    pure (rows == [Only True])
  ["api","bulk","leads"] -> unrestricted env u
  _ -> pure True

unrestricted :: Env -> User -> IO Bool
unrestricted env u = withConn env $ \c -> do
  [Only scope] <- query_ c "SELECT consultant_scope FROM access_settings" :: IO [Only T.Text]
  pure (userRole u /= "consultant" || scope == "all")

-- | Admin-only endpoints (user management).
withAdmin :: Env -> (User -> S.ActionM ()) -> S.ActionM ()
withAdmin env act = withUser env $ \u ->
  if userRole u /= "admin"
    then forbidden "Admin access required"
    else act u

-- | Optional query-string parameter.
qparam :: T.Text -> S.ActionM (Maybe T.Text)
qparam name = lookup name <$> S.queryParams

-- | Like 'currentUser', but also accepts the JWT as a @?token=@ query
-- parameter — needed for plain @<a href>@ downloads, which cannot set
-- an Authorization header.
currentUserWithQueryToken :: Env -> S.ActionM (Maybe User)
currentUserWithQueryToken env = do
  req <- S.request
  qtok <- qparam "token"
  let mtok = case bearerToken (Wai.requestHeaders req) of
        Just t  -> Just t
        Nothing -> TE.encodeUtf8 <$> qtok
  case mtok of
    Nothing -> pure Nothing
    Just tok -> do
      valid <- liftIO $ sessionValid env tok
      muid <- liftIO $ verifyToken (envSecret env) tok
      case (if valid then muid else Nothing) of
        Nothing -> pure Nothing
        Just uid -> liftIO $ withConn env $ \conn -> getUserById conn uid

-- ---------- query-string helpers ----------

-- | Blank and the sentinel @All@ both mean "no filter".
filterParam :: Maybe T.Text -> Maybe T.Text
filterParam t = case t of
  Just v | not (T.null (T.strip v)), T.toLower (T.strip v) /= "all" -> Just (T.strip v)
  _ -> Nothing

pageLimit :: Maybe T.Text -> Int
pageLimit m = clamp 1 500 (maybe 100 id (m >>= readMaybeT))

pageOffset :: Maybe T.Text -> Int
pageOffset m = max 0 (fromMaybe 0 (m >>= readMaybeT))

clamp :: Ord a => a -> a -> a -> a
clamp lo hi x = max lo (min hi x)

-- ---------- the application ----------

app :: Env -> Maybe String -> S.ScottyM ()
app env origin = do
  S.defaultHandler (Handler handleSqlError)
  case origin of
    Nothing -> pure ()
    Just value -> S.middleware $ cors (const (Just simpleCorsResourcePolicy { corsOrigins = Just ([TE.encodeUtf8 (T.pack value)], False), corsRequestHeaders = ["Authorization", "Content-Type", "X-Portal-Token"], corsMethods = ["GET", "POST", "PUT", "PATCH", "DELETE", "OPTIONS"] }))

  operations env (withUser env)

  S.post "/api/auth/logout" $ withUser env $ \_ -> do
    req <- S.request
    case bearerToken (Wai.requestHeaders req) of
      Just tok -> liftIO (revokeSession env tok)
      Nothing -> pure ()
    S.json (A.object ["loggedOut" .= True])

  -- ---- health ----
  S.get "/api/health" $
    S.json (A.object ["status" .= ("ok" :: T.Text)])

  -- ---- auth ----
  S.post "/api/auth/login" $ do
    LoginRequest email password <- S.jsonData
    now <- liftIO getCurrentTime
    let key = T.toLower (T.strip email)
    throttled <- liftIO (isThrottled (envLimiter env) now key)
    if throttled
      then tooManyRequests "Too many failed sign-in attempts — try again later"
      else do
        mrow <- liftIO $ withConn env $ \conn -> getUserByEmailWithHash conn email
        case mrow of
          Just (u, hash)
            | checkPassword (TE.encodeUtf8 password) (TE.encodeUtf8 hash) -> do
                liftIO (clearFailures (envLimiter env) key)
                tok <- liftIO $ makeToken (envSecret env) (userId u)
                liftIO $ registerSession env (userId u) tok
                S.json (LoginResponse (TE.decodeUtf8 tok) u)
          _ -> do
            liftIO (recordFailure (envLimiter env) now key)
            unauthorized "Invalid email or password"

  S.get "/api/auth/me" $
    withUser env S.json

  -- ---- users ----
  S.get "/api/users" $
    withUser env $ \_ -> S.json =<< liftIO (withConn env listUsers)

  S.post "/api/users" $
    withAdmin env $ \_ -> do
      nu <- S.jsonData
      if not (validRole (nuRole nu))
        then badRequest "Role must be admin, consultant, or viewer"
        else if T.null (T.strip (nuEmail nu)) || T.null (T.strip (nuName nu))
                || T.length (nuPassword nu) < 8
          then badRequest "Name, email, and a password of at least 8 characters are required"
          else do
            mu <- liftIO $ withConn env $ \conn -> insertUser conn nu
            case mu of
              Just u  -> S.status status200 >> S.json u
              Nothing -> badRequest "Email is already registered"

  S.patch "/api/users/:id" $ do
    uid <- S.pathParam "id"
    withAdmin env $ \actor -> do
      uu <- S.jsonData
      case uuPassword uu of
        Just pw | not (T.null pw) && T.length pw < 8 -> badRequest "Password must be at least 8 characters" >> S.finish
        _ -> pure ()
      case uuRole uu of
        Just r | not (validRole r) ->
          badRequest "Role must be admin, consultant, or viewer"
        _ -> do
          outcome <- liftIO $ withConn env $ \conn -> do
            mt <- getUserById conn uid
            case mt of
              Nothing -> pure (Left NotFound)
              Just t -> do
                let demoting = maybe False (/= "admin") (uuRole uu)
                               && userRole t == "admin"
                admins <- if demoting
                            then countAdminsExcluding conn uid
                            else pure 1
                if demoting && admins == 0
                  then pure (Left (Invalid "Cannot remove the last admin"))
                  else if uid == userId actor && demoting
                    then pure (Left (Invalid "You cannot change your own role"))
                    else do
                      ok <- patchUser conn uid uu
                      pure (if ok then Right () else Left NotFound)
          case outcome of
            Right () -> S.json (A.object ["updated" .= True])
            Left NotFound -> notFound "User not found"
            Left (Invalid m) -> badRequest m

  S.delete "/api/users/:id" $ do
    uid <- S.pathParam "id"
    withAdmin env $ \actor ->
      if uid == userId actor
        then badRequest "You cannot delete your own account"
        else do
          outcome <- liftIO $ withConn env $ \conn -> do
            mt <- getUserById conn uid
            case mt of
              Nothing -> pure (Left NotFound)
              Just t -> do
                admins <- if userRole t == "admin"
                            then countAdminsExcluding conn uid
                            else pure 1
                if admins == 0
                  then pure (Left (Invalid "Cannot delete the last admin"))
                  else do
                    ok <- deleteUser conn uid
                    pure (if ok then Right () else Left NotFound)
          case outcome of
            Right () -> S.json (A.object ["deleted" .= True])
            Left NotFound -> notFound "User not found"
            Left (Invalid m) -> badRequest m

  -- change own password (any role)
  S.put "/api/auth/password" $
    withUser env $ \u -> do
      pc <- S.jsonData
      mhash <- liftIO $ withConn env $ \conn -> getPasswordHash conn (userId u)
      let okPw = maybe False (\h -> checkPassword (TE.encodeUtf8 (pcCurrent pc))
                                                  (TE.encodeUtf8 h)) mhash
      if not okPw
        then unauthorized "Current password is incorrect"
        else if T.length (pcNew pc) < 8
          then badRequest "New password must be at least 8 characters"
          else do
            ok <- liftIO $ withConn env $ \conn -> updatePassword conn (userId u) (pcNew pc)
            if ok then do
              req <- S.request
              case bearerToken (Wai.requestHeaders req) of
                Just tok -> liftIO $ registerSession env (userId u) tok
                Nothing -> pure ()
              S.json (A.object ["updated" .= True])
            else serverError "Could not update password"

  -- ---- leads ----

  -- Paginated + filterable list: ?q=&stage=&quality=&source=&sort=&dir=
  -- &limit=&offset=  ->  {"items":[…],"total":N}
  S.get "/api/leads" $
    withUser env $ \actor -> do
      q <- qparam "q"
      stage <- qparam "stage"
      quality <- qparam "quality"
      source <- qparam "source"
      sort <- qparam "sort"
      dir <- qparam "dir"
      mlimit <- qparam "limit"
      moffset <- qparam "offset"
      let spec = LeadQuery
            { lqFilter = LeadFilter
                { lfQ = filterParam q
                , lfStage = filterParam stage
                , lfQuality = filterParam quality
                , lfActor = userId actor
                , lfSource = filterParam source
                }
            , lqSort = fromMaybe "name" sort
            , lqAsc = fmap T.toLower dir /= Just "desc"
            , lqLimit = pageLimit mlimit
            , lqOffset = pageOffset moffset
            }
      (items, total) <- liftIO $ withConn env $ \conn -> listLeadsPaged conn spec
      S.json (A.object ["items" .= items, "total" .= total])

  S.post "/api/leads" $
    withWriter env $ \u -> do
      nl <- S.jsonData
      if userRole u /= "admin" && maybe False (/= userId u) (nlConsultantId nl) then forbidden "Admin access required to assign another consultant" >> S.finish else pure ()
      if T.null (T.strip (nlFullName nl))
        then badRequest "Full name is required"
        else do
          l <- liftIO $ withConn env $ \conn -> insertLead conn nl (userId u)
          S.status status200 >> S.json l

  S.get "/api/leads/:id" $ do
    lid <- S.pathParam "id"
    withUser env $ \_ -> do
      md <- liftIO $ withConn env $ \conn -> getLeadDetail conn lid
      case md of
        Just d -> S.json d
        Nothing -> notFound "Lead not found"

  S.patch "/api/leads/:id" $ do
    lid <- S.pathParam "id"
    withWriter env $ \u -> do
      ul <- S.jsonData
      old <- liftIO $ withConn env $ \conn -> getLead conn lid
      let reassigned = maybe False (\l -> applyPatch (ulConsultantId ul) (consultantId l) /= consultantId l) old
      if userRole u /= "admin" && reassigned then forbidden "Admin access required to reassign records" >> S.finish else pure ()
      ml <- liftIO $ withConn env $ \conn -> patchLead conn lid ul (Just (userId u))
      case ml of
        Just l -> S.json l
        Nothing -> notFound "Lead not found"

  S.delete "/api/leads/:id" $ do
    lid <- S.pathParam "id"
    withWriter env $ \u -> do
      ok <- liftIO $ withConn env $ \conn -> deleteLead conn lid (Just (userId u))
      if ok then S.json (A.object ["deleted" .= True])
            else notFound "Lead not found"

  S.post "/api/leads/:id/advance" $ do
    lid <- S.pathParam "id"
    withWriter env $ \_ -> do
      res <- liftIO $ withConn env $ \conn -> advanceStage conn lid
      case res of
        Right (Just l) -> S.json l
        Right Nothing -> notFound "Lead not found"
        Left why -> badRequest why

  S.post "/api/leads/:id/convert" $ do
    lid <- S.pathParam "id"
    withWriter env $ \u -> do
      outcome <- liftIO $ withConn env $ \conn -> do
        ml <- getLead conn lid
        case ml of
          Nothing -> pure ConvertMissing
          Just l
            | stage l == "Converted" -> pure ConvertAlready
            | otherwise -> do
                let officer = maybe (userId u) id (consultantId l)
                mc <- convertToClient conn lid officer
                pure (maybe ConvertMissing ConvertOk mc)
      case outcome of
        ConvertOk c -> S.json c
        ConvertAlready -> badRequest "Lead has already been converted"
        ConvertMissing -> notFound "Lead not found"

  S.post "/api/leads/:id/notes" $ do
    lid <- S.pathParam "id"
    withWriter env $ \_ -> do
      NoteRequest note <- S.jsonData
      if T.null (T.strip note)
        then badRequest "Note cannot be empty"
        else do
          liftIO $ withConn env $ \conn -> addNote conn lid note
          S.json (A.object ["added" .= True])

  S.post "/api/bulk/leads" $
    withAdmin env $ \u -> do
      br <- S.jsonData
      n <- liftIO $ withConn env $ \conn -> bulkLeads conn br (userId u)
      S.json (A.object ["affected" .= n])

  S.post "/api/import/leads" $
    withAdmin env $ \u -> do
      fs <- S.files
      case pickFile fs of
        Nothing -> badRequest "No file provided — attach a CSV as the \"file\" part"
        Just fi -> do
          let bytes = BL.toStrict (fileContent fi)
          if B.length bytes > maxImportBytes
            then badRequest "File too large (max 2 MB)"
            else case TE.decodeUtf8' bytes of
              Left _ -> badRequest "File is not valid UTF-8"
              Right csvText ->
                let rows = parseCsv csvText
                in if length rows > maxImportRows + 1
                     then badRequest ("Too many rows (max "
                                       <> T.pack (show (maxImportRows :: Int))
                                       <> " leads per import)")
                     else do
                       res <- liftIO $
                         withConn env $ \conn -> importLeads conn rows (userId u)
                       S.json res

  -- ---- tasks ----
  S.get "/api/tasks" $
    withUser env $ \actor -> S.json =<< liftIO (withConn env (\c -> listTasks c (userId actor)))

  S.post "/api/tasks" $
    withWriter env $ \u -> do
      nt <- S.jsonData
      allowed <- liftIO $ canAccess env u "lead" (ntLeadId nt)
      if not allowed then forbidden "Lead access denied" >> S.finish else pure ()
      if T.null (T.strip (ntTitle nt))
        then badRequest "Task title is required"
        else do
          t <- liftIO $ withConn env $ \conn -> insertTask conn nt (userId u)
          S.status status200 >> S.json t

  S.patch "/api/tasks/:id" $ do
    tid <- S.pathParam "id"
    withWriter env $ \_ -> do
      TaskStatusRequest st <- S.jsonData
      if st `notElem` taskStatuses
        then badRequest "Status must be Pending, In Progress, or Done"
        else do
          ok <- liftIO $ withConn env $ \conn -> setTaskStatus conn tid st
          if ok then S.json (A.object ["updated" .= True])
                else notFound "Task not found"

  S.delete "/api/tasks/:id" $ do
    tid <- S.pathParam "id"
    withWriter env $ \_ -> do
      ok <- liftIO $ withConn env $ \conn -> deleteTask conn tid
      if ok then S.json (A.object ["deleted" .= True])
            else notFound "Task not found"

  -- ---- activities ----
  S.get "/api/activities" $
    withUser env $ \actor -> do
      mlead <- qparam "leadId"
      mlimit <- qparam "limit"
      let limit = clamp 1 200 (maybe 20 id (mlimit >>= readMaybeT))
      acts <- liftIO $ withConn env $ \conn -> case mlead >>= readMaybeT of
        Just lid -> filter ((==lid) . activityLeadId) <$> listActivitiesFor conn (userId actor) 200
        Nothing -> listActivitiesFor conn (userId actor) limit
      S.json acts

  -- ---- clients ----

  -- Paginated + searchable list: ?q=&limit=&offset= -> {"items":[…],"total":N}
  S.get "/api/clients" $
    withUser env $ \actor -> do
      q <- qparam "q"
      mlimit <- qparam "limit"
      moffset <- qparam "offset"
      (items, total) <- liftIO $ withConn env $ \conn ->
        listClientsPaged conn (filterParam q) (pageLimit mlimit) (pageOffset moffset) (userId actor)
      S.json (A.object ["items" .= items, "total" .= total])

  S.post "/api/clients" $
    withWriter env $ \actor -> do
      nc <- S.jsonData
      if userRole actor /= "admin" && ncCaseOfficer nc /= Just (userId actor) then forbidden "Assign new clients to yourself" >> S.finish else pure ()
      if T.null (T.strip (ncFullName nc))
        then badRequest "Full name is required"
        else do
          c <- liftIO $ withConn env $ \conn -> insertClient conn nc
          S.status status200 >> S.json c

  S.get "/api/clients/:id" $ do
    cid <- S.pathParam "id"
    withUser env $ \_ -> do
      mc <- liftIO $ withConn env $ \conn -> getClientDetail conn cid
      case mc of
        Just cd -> S.json cd
        Nothing -> notFound "Client not found"

  S.patch "/api/clients/:id" $ do
    cid <- S.pathParam "id"
    withWriter env $ \u -> do
      uc <- S.jsonData
      old <- liftIO $ withConn env $ \conn -> getClientDetail conn cid
      let reassigned = maybe False (\d -> applyPatch (ucCaseOfficer uc) (caseOfficerId (cdClient d)) /= caseOfficerId (cdClient d)) old
      if userRole u /= "admin" && reassigned then forbidden "Admin access required to reassign records" >> S.finish else pure ()
      ok <- liftIO $ withConn env $ \conn -> patchClient conn cid uc (Just (userId u))
      if ok then S.json (A.object ["updated" .= True])
            else notFound "Client not found"

  S.delete "/api/clients/:id" $ do
    cid <- S.pathParam "id"
    withWriter env $ \u -> do
      ok <- liftIO $ withConn env $ \conn -> deleteClient conn cid (Just (userId u))
      if ok then S.json (A.object ["deleted" .= True])
            else notFound "Client not found"

  S.post "/api/clients/:id/cases" $ do
    cid <- S.pathParam "id"
    withWriter env $ \actor -> do
      ci <- S.jsonData
      case ciCaseId ci of
        Just kid -> do
          allowed <- liftIO $ canAccess env actor "case" kid
          if not allowed then forbidden "Case access denied" >> S.finish else pure ()
        Nothing -> pure ()
      mc <- liftIO $ withConn env $ \conn -> withTransaction conn $ do
        void (query conn "SELECT set_config('ecc.actor',?,true)" (Only (T.pack (show (userId actor)))) :: IO [Only T.Text])
        void $ upsertCase conn cid ci
        getClientDetail conn cid
      case mc of
        Just cd -> S.json cd
        Nothing -> notFound "Client not found"

  S.delete "/api/cases/:id" $ do
    caseId <- S.pathParam "id"
    withWriter env $ \_ -> do
      ok <- liftIO $ withConn env $ \conn -> deleteCase conn caseId
      if ok then S.json (A.object ["deleted" .= True])
            else notFound "Case not found"

  -- ---- documents ----
  -- Uploads are multipart/form-data with a \"file\" part; the owner record
  -- (lead or client) comes from the path.  Responds with the refreshed
  -- detail payload so clients can re-render in one round trip.

  S.post "/api/leads/:id/documents" $ do
    lid <- S.pathParam "id"
    withWriter env $ \u -> do
      r <- storeUpload env (Just lid) Nothing (userId u)
      case r of
        Left why -> badRequest why
        Right () -> do
          md <- liftIO $ withConn env $ \conn -> getLeadDetail conn lid
          maybe (serverError "Lead vanished") S.json md

  S.post "/api/clients/:id/documents" $ do
    cid <- S.pathParam "id"
    withWriter env $ \u -> do
      r <- storeUpload env Nothing (Just cid) (userId u)
      case r of
        Left why -> badRequest why
        Right () -> do
          md <- liftIO $ withConn env $ \conn -> getClientDetail conn cid
          maybe (serverError "Client vanished") S.json md

  S.get "/api/documents/:id/download" $ do
    did <- S.pathParam "id"
    mu <- currentUserWithQueryToken env
    case mu of
      Nothing -> unauthorized "Not authenticated"
      Just u -> do
        allowed <- liftIO $ requestAccess env u ["api","documents",T.pack (show (did :: Int))]
        if not allowed then forbidden "Record unavailable or access denied" >> S.finish else pure ()
        mdoc <- liftIO $ withConn env $ \conn -> getDocumentContent conn did
        case mdoc of
          Nothing -> notFound "Document not found"
          Just (fname, mime, bs) -> do
            let safeName = T.take 200 (T.filter (\c -> c /= '"' && c /= '\r' && c /= '\n') fname)
            S.setHeader "Content-Type" (TL.fromStrict (sanitizeMime mime))
            S.setHeader "Content-Disposition"
              ("attachment; filename=\""
                <> TL.fromStrict safeName <> "\"")
            S.raw (BL.fromStrict bs)

  S.delete "/api/documents/:id" $ do
    did <- S.pathParam "id"
    withWriter env $ \_ -> do
      ok <- liftIO $ withConn env $ \conn -> deleteDocument conn did
      if ok then S.json (A.object ["deleted" .= True])
            else notFound "Document not found"

  -- ---- audit trail (admin) ----
  S.get "/api/audit" $
    withAdmin env $ \_ -> do
      mType <- qparam "entityType"
      mId <- qparam "entityId"
      mLimit <- qparam "limit"
      let limit = clamp 1 500 (maybe 100 id (mLimit >>= readMaybeT))
      entries <- liftIO $ withConn env $ \conn ->
        listAuditEntries conn (filterParam mType) (mId >>= readMaybeT) limit
      S.json entries

  -- ---- stats ----
  S.get "/api/stats" $
    withUser env $ \actor -> S.json =<< liftIO (withConn env (\c -> getStats c (userId actor)))

  -- ---- csv export ----
  -- Accepts the JWT as a query parameter too, so the SPA can use plain
  -- <a href download> links (anchors cannot set an Authorization header).

  S.get "/api/export/leads.csv" $ do
    mu <- currentUserWithQueryToken env
    case mu of
      Nothing -> unauthorized "Not authenticated"
      Just actor -> do
        allRecords <- liftIO $ unrestricted env actor
        if not allRecords then forbidden "Full export requires unrestricted access" >> S.finish else pure ()
        ls <- liftIO $ withConn env listLeads
        csvAttachment "leads.csv" (leadsCsv ls)

  S.get "/api/export/clients.csv" $ do
    mu <- currentUserWithQueryToken env
    case mu of
      Nothing -> unauthorized "Not authenticated"
      Just actor -> do
        allRecords <- liftIO $ unrestricted env actor
        if not allRecords then forbidden "Full export requires unrestricted access" >> S.finish else pure ()
        cs <- liftIO $ withConn env listClients
        csvAttachment "clients.csv" (clientsCsv cs)

-- | A failed pre-check inside one pooled block; distinguishes 404 from 400.
data Failure = NotFound | Invalid T.Text

-- | Outcome of a lead conversion attempt.
data ConvertOutcome = ConvertOk Client | ConvertAlready | ConvertMissing

csvAttachment :: T.Text -> BL.ByteString -> S.ActionM ()
csvAttachment name body = do
  S.setHeader "Content-Type" "text/csv; charset=utf-8"
  S.setHeader "Content-Disposition"
    ("attachment; filename=\"" <> TL.fromStrict name <> "\"")
  S.raw body

readMaybeT :: Read a => T.Text -> Maybe a
readMaybeT s = case reads (T.unpack s) of
  [(v, "")] -> Just v
  _         -> Nothing

validRole :: T.Text -> Bool
validRole r = r `elem` ["admin", "consultant", "viewer"]

taskStatuses :: [T.Text]
taskStatuses = ["Pending", "In Progress", "Done"]

-- ---------- upload plumbing ----------

maxUploadBytes :: Int
maxUploadBytes = 25 * 1024 * 1024  -- 25 MB

maxImportBytes :: Int
maxImportBytes = 2 * 1024 * 1024   -- 2 MB

maxImportRows :: Int
maxImportRows = 5000

-- | Decode a header value (filename, content-type) that may not be valid
-- UTF-8.  @decodeUtf8@ would throw on such bytes and turn a bad upload into
-- a 500; the lenient decoder substitutes U+FFFD instead.
lenient :: B.ByteString -> T.Text
lenient = TE.decodeUtf8With TEE.lenientDecode

-- | Validates and stores the uploaded file from a multipart body; exactly
-- one of the lead\/client ids must be @Just@.  @Left@ is a client-facing
-- error message.
storeUpload :: Env -> Maybe Int -> Maybe Int -> Int -> S.ActionM (Either T.Text ())
storeUpload env mlead mclient uploaderId = do
  fs <- S.files
  case pickFile fs of
    Nothing -> pure (Left "No file provided")
    Just fi -> do
      let bytes = BL.toStrict (fileContent fi)
      if B.length bytes > maxUploadBytes
        then pure (Left "File too large (max 25 MB)")
        else if not (validUpload fi)
          then pure (Left "Upload a valid PDF, JPEG or PNG file")
        else do
          liftIO $ withConn env $ \conn -> void $
            insertDocument conn mlead mclient
              (sanitizeFilename (lenient (fileName fi)))
              (sanitizeMime (lenient (fileContentType fi)))
              bytes
              (Just uploaderId)
          pure (Right ())

-- | The uploaded part must be named @file@.
pickFile :: [S.File BL.ByteString] -> Maybe (FileInfo BL.ByteString)
pickFile fs = case [fi | ("file", fi) <- fs] of
  (fi:_) -> Just fi
  []     -> Nothing

-- | Strip any client-supplied path components and cap the length.
sanitizeFilename :: T.Text -> T.Text
sanitizeFilename raw =
  let segments = T.split (\c -> c == '/' || c == '\\') raw
      base = case reverse segments of
        (x:_) -> T.filter (\c -> c >= ' ' && c /= '\DEL' && c /= '"') x
        [] -> ""
  in T.take 255 (if T.null base then "untitled" else base)

-- | Keep a client-supplied content type from injecting header bytes; fall
-- back to the generic type when nothing usable remains.
sanitizeMime :: T.Text -> T.Text
sanitizeMime raw =
  let cleaned = T.take 120 (T.filter ok raw)
  in if T.null cleaned then "application/octet-stream" else cleaned
  where
    ok c = c >= ' ' && c /= '"' && c /= '\\'


handleSqlError :: SqlError -> S.ActionM ()
handleSqlError err
  | sqlState err `elem` ["P0001","23505","23503","23514","23502","22P02","22007","22008"] =
      badRequest (if sqlState err == "P0001" then lenient (sqlErrorMsg err) else "Invalid value, duplicate contact, or missing related record")
  | otherwise = do
      liftIO $ putStrLn ("[database] " ++ show err)
      serverError "Internal server error"
