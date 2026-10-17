{-# LANGUAGE OverloadedStrings #-}

-- | PostgreSQL data access: every SQL statement in the application lives
-- here.  Row parsers are positional, so SELECT column order must match the
-- tuple order used when reading rows.
module ECC.DB
  ( Env(..)
  , withConn
  , leadStages
  , LeadFilter(..)
  , LeadQuery(..)
  , getUserByEmailWithHash
  , getUserById
  , listUsers
  , addUser
  , insertUser
  , patchUser
  , deleteUser
  , countAdminsExcluding
  , getPasswordHash
  , updatePassword
  , setPassword
  , wipeCrmData
  , listLeads
  , listLeadsPaged
  , getLead
  , getLeadDetail
  , insertLead
  , patchLead
  , deleteLead
  , advanceStage
  , convertToClient
  , addNote
  , bulkLeads
  , importLeads
  , listTasks
  , insertTask
  , setTaskStatus
  , deleteTask
  , listActivities
  , listActivitiesFor
  , activitiesForLead
  , listClients
  , listClientsPaged
  , getClientDetail
  , insertClient
  , patchClient
  , deleteClient
  , upsertCase
  , deleteCase
  , documentsForLead
  , documentsForClient
  , insertDocument
  , getDocumentContent
  , deleteDocument
  , listAuditEntries
  , getStats
  ) where

import Control.Exception (try)
import Data.Either (partitionEithers)
import Control.Monad (forM, forM_, unless, void)
import qualified Data.Aeson as A
import qualified Data.Aeson.Key as AK
import qualified Data.ByteString as B
import Data.Maybe (listToMaybe, maybeToList)
import Data.Text (Text)
import qualified Data.Text as T
import qualified Data.Text.Encoding as TE
import Data.Time.Clock (getCurrentTime, utctDay, UTCTime)
import Data.Time.Calendar (Day)
import Data.Time.Format (defaultTimeLocale, parseTimeM)
import Database.PostgreSQL.Simple
import Database.PostgreSQL.Simple.ToField (ToField)
import Database.PostgreSQL.Simple.Types (Query (..))

import ECC.Auth (hashPassword)
import ECC.Models
import ECC.Pool (Pool, withResource)
import ECC.RateLimit (RateLimiter)

data Env = Env
  { envPool    :: Pool Connection
  , envSecret  :: B.ByteString
  , envLimiter :: RateLimiter
  }

-- | Borrow a pooled connection for the duration of one handler.
withConn :: Env -> (Connection -> IO a) -> IO a
withConn = withResource . envPool

leadStages :: [Text]
leadStages =
  [ "New Lead", "Contacted", "Initial Assessment", "Qualified"
  , "Consultation Booked", "Proposal Sent", "Converted", "Closed/Lost" ]

nonEmpty :: Maybe Text -> Maybe Text
nonEmpty t = t >>= \v -> if T.null (T.strip v) then Nothing else Just v

-- | Generates PREFIX-YEAR-NUMBER without reusing numbers.
--
-- The suffix is taken with @split_part(col,'-',3)@ rather than
-- @right(col,pad)@: the latter silently truncated once the counter exceeded
-- the padding width (lead 10000 looked like 0000), which made the next
-- allocation collide with an existing row and fail the UNIQUE constraint.
--
-- Allocation itself goes through a @counters@ row with an atomic
-- @INSERT ... ON CONFLICT ... RETURNING@, so two concurrent requests can never
-- compute the same next number.
nextNumber :: Connection -> Text -> Text -> Text -> Int -> IO Text
nextNumber conn prefix table col pad = do
  (Only year:_) <- query_ conn "SELECT date_part('year', CURRENT_DATE)::int"
    :: IO [Only Int]
  let key = prefix <> "-" <> T.pack (show (year :: Int))
      like = key <> "-%"
      seedQ = Query ("SELECT COALESCE(MAX(split_part("
                     <> TE.encodeUtf8 col <> ", '-', 3)::int), 0) FROM "
                     <> TE.encodeUtf8 table <> " WHERE " <> TE.encodeUtf8 col
                     <> " LIKE ?")
  (Only seed:_) <- query conn seedQ (Only like) :: IO [Only Int]
  (Only n:_) <- query conn
    "INSERT INTO counters (name, n) VALUES (?, ?) \
    \ON CONFLICT (name) DO UPDATE SET n = counters.n + 1 RETURNING n"
    (key, seed + 1) :: IO [Only Int]
  let s = T.pack (show (n :: Int))
      padded = T.replicate (max 0 (pad - T.length s)) "0" <> s
  pure (prefix <> "-" <> T.pack (show (year :: Int)) <> "-" <> padded)

logActivity :: Connection -> Int -> Text -> Text -> IO ()
logActivity conn leadId kind desc = void $ execute conn
  "INSERT INTO activities (lead_id, type, description, date) VALUES (?,?,?,CURRENT_DATE)"
  (leadId, kind, desc)

-- | Append one audit-trail row.  @changes@ is @{"Field":{"from":…,"to":…}}@
-- for updates; Nothing for deletes.  Best-effort: failures must not abort
-- the operation being audited.
logAuditEntry :: Connection -> Text -> Int -> Maybe Text -> Text
              -> Maybe A.Value -> Maybe Int -> IO ()
logAuditEntry conn etype eid ename action changes actorId =
  void $ execute conn
    "INSERT INTO audit_log (entity_type, entity_id, entity_name, action, changes, actor_id) VALUES (?,?,?,?,?,?)"
    (etype, eid, ename, action, changes, actorId)

-- | A @{"from":…,"to":…}@ pair when the two optional values differ.
auditPair :: A.ToJSON a => Text -> Maybe a -> Maybe a -> [(A.Key, A.Value)]
auditPair label old neu
  | fmap A.toJSON old == fmap A.toJSON neu = []
  | otherwise =
      [ ( AK.fromText label
        , A.object [ ("from", maybe A.Null A.toJSON old)
                   , ("to",   maybe A.Null A.toJSON neu) ]
        )
      ]

-- | Effective new value under COALESCE(NULLIF(?,''),col) semantics:
-- empty or missing input means "keep the old value".
touchLastContact :: Connection -> Int -> IO ()
touchLastContact conn leadId = void $ execute conn
  "UPDATE leads SET last_contact = CURRENT_DATE WHERE id = ?" (Only leadId)

-- ---------- users ----------

getUserByEmailWithHash :: Connection -> Text -> IO (Maybe (User, Text))
getUserByEmailWithHash conn email = do
  rows <- query conn
    "SELECT id, email, name, role, password_hash FROM users WHERE lower(email) = lower(?)"
    (Only email) :: IO [(Int, Text, Text, Text, Text)]
  pure $ case rows of
    [(i, e, n, r, h)] -> Just (User i e n r, h)
    _ -> Nothing

getUserById :: Connection -> Int -> IO (Maybe User)
getUserById conn uid = do
  rows <- query conn "SELECT id, email, name, role FROM users WHERE id = ?"
    (Only uid) :: IO [(Int, Text, Text, Text)]
  pure $ case rows of
    [(i, e, n, r)] -> Just (User i e n r)
    _ -> Nothing

listUsers :: Connection -> IO [User]
listUsers conn = map (\(i, e, n, r) -> User i e n r)
  <$> query_ conn "SELECT id, email, name, role FROM users ORDER BY name"

-- | CLI: create a user or update name\/role\/password on email conflict.
addUser :: Connection -> Text -> Text -> Text -> Text -> IO ()
addUser conn email name role pw = do
  h <- hashPassword (TE.encodeUtf8 pw)
  void $ execute conn
    "INSERT INTO users (email, password_hash, name, role) VALUES (?,?,?,?) \
    \ON CONFLICT (email) DO UPDATE SET password_hash = EXCLUDED.password_hash, \
    \name = EXCLUDED.name, role = EXCLUDED.role"
    (email, h, name, role)

-- | CLI: set a new password for an existing user; False when user missing.
setPassword :: Connection -> Text -> Text -> IO Bool
setPassword conn email pw = do
  h <- hashPassword (TE.encodeUtf8 pw)
  n <- execute conn "UPDATE users SET password_hash = ? WHERE lower(email) = lower(?)"
    (h, email)
  pure (n > 0)

-- | API: create a user; Nothing when the email is already taken.
insertUser :: Connection -> NewUser -> IO (Maybe User)
insertUser conn nu = do
  taken <- getUserByEmailWithHash conn (nuEmail nu)
  case taken of
    Just _  -> pure Nothing
    Nothing -> do
      h <- hashPassword (TE.encodeUtf8 (nuPassword nu))
      ids <- returning conn
        "INSERT INTO users (email, password_hash, name, role) VALUES (?,?,?,?) RETURNING id"
        [ (nuEmail nu, h, nuName nu, nuRole nu) ] :: IO [[Int]]
      getUserById conn (head (concat ids))

-- | API: partial update; empty\/missing password keeps the current one.
patchUser :: Connection -> Int -> UpdateUser -> IO Bool
patchUser conn uid uu = do
  mhp <- case filter (not . T.null) (maybeToList (uuPassword uu)) of
    []    -> pure Nothing
    (pw:_) -> Just . TE.decodeUtf8 <$> hashPassword (TE.encodeUtf8 pw)
  n <- execute conn
    "UPDATE users SET name=COALESCE(NULLIF(?,''),name), role=COALESCE(NULLIF(?,''),role), \
    \password_hash=COALESCE(?,password_hash) WHERE id=?"
    (uuName uu, uuRole uu, mhp, uid)
  pure (n > 0)

deleteUser :: Connection -> Int -> IO Bool
deleteUser conn uid = (> 0) <$> execute conn "DELETE FROM users WHERE id = ?" (Only uid)

-- | Number of admins other than @uid@ — used to protect the last admin.
countAdminsExcluding :: Connection -> Int -> IO Int
countAdminsExcluding conn uid = do
  rs <- query conn
    "SELECT COUNT(*) FROM users WHERE role = 'admin' AND id <> ?" (Only uid)
    :: IO [Only Int]
  pure (maybe 0 fromOnly (listToMaybe rs))

-- | Stored bcrypt hash for the given user (for verifying the current
-- password during a self-service change).
getPasswordHash :: Connection -> Int -> IO (Maybe Text)
getPasswordHash conn uid = do
  rs <- query conn "SELECT password_hash FROM users WHERE id = ?" (Only uid)
    :: IO [Only Text]
  pure $ listToMaybe rs >>= Just . fromOnly

-- | Set a password by user id; False when the user does not exist.
updatePassword :: Connection -> Int -> Text -> IO Bool
updatePassword conn uid pw = do
  h <- hashPassword (TE.encodeUtf8 pw)
  n <- execute conn "UPDATE users SET password_hash = ? WHERE id = ?" (h, uid)
  pure (n > 0)

-- | CLI: remove all CRM records but keep user accounts.
wipeCrmData :: Connection -> IO ()
wipeCrmData conn =
  execute_ conn
    "TRUNCATE audit_log, documents, activities, tasks, cases, clients, leads RESTART IDENTITY CASCADE"
  >> pure ()

-- ---------- leads ----------

type LeadRow = ( Int, Text, Text, Maybe Text, Maybe Text, Maybe Text
               , Maybe Int, Maybe Text, Maybe Text, Text
               , Maybe Text, Maybe Text, Maybe Text
               , Maybe Day, Maybe Day, UTCTime, UTCTime )

toLead :: LeadRow -> Lead
toLead (i, num, nm, em, ph, src, cid, cname, q, st, dst, sv, notes, lc, fu, ca, ua) =
  Lead i num nm em ph src cid cname q st dst sv notes lc fu ca ua

leadSelect :: Query
leadSelect =
  "SELECT l.id, l.lead_number, l.full_name, l.email, l.phone, l.source, \
  \l.consultant_id, c.name AS consultant_name, l.quality, l.stage, \
  \l.destination, l.service, l.notes, l.last_contact, l.next_followup, \
  \l.created_at, l.updated_at \
  \FROM leads l LEFT JOIN users c ON c.id = l.consultant_id"

-- | Interpolate a small parameter tuple into a SQL fragment as properly
-- quoted literals.  Used to assemble optional WHERE clauses, which sidesteps
-- postgresql-simple's fixed-arity tuples.  @formatQuery@ escapes values, so
-- nothing user-supplied is ever concatenated raw.
fmtText :: ToRow p => Connection -> Query -> p -> IO Text
fmtText conn q p = TE.decodeUtf8 <$> formatQuery conn q p

-- | Server-side filtering for the leads list.
data LeadFilter = LeadFilter
  { lfQ       :: Maybe Text
  , lfStage   :: Maybe Text
  , lfQuality :: Maybe Text
  , lfActor   :: Int
  , lfSource  :: Maybe Text
  } deriving (Show, Eq)

-- | One page of leads: filter + sort column + direction + window.
data LeadQuery = LeadQuery
  { lqFilter :: LeadFilter
  , lqSort   :: Text
  , lqAsc    :: Bool
  , lqLimit  :: Int
  , lqOffset :: Int
  } deriving (Show, Eq)

leadWhere :: Connection -> LeadFilter -> IO Text
leadWhere conn lf = do
  c1 <- fmtText conn "(?::text IS NULL OR l.stage = ?::text)"
                 (lfStage lf, lfStage lf)
  c2 <- fmtText conn "(?::text IS NULL OR COALESCE(l.quality,'') = ?::text)"
                 (lfQuality lf, lfQuality lf)
  c3 <- fmtText conn "(?::text IS NULL OR COALESCE(l.source,'') = ?::text)"
                 (lfSource lf, lfSource lf)
  c4 <- case lfQ lf of
    Nothing -> pure "TRUE"
    Just raw -> fmtText conn
      "(l.full_name ILIKE ? OR COALESCE(l.email,'') ILIKE ? \
      \OR COALESCE(l.phone,'') ILIKE ? OR l.lead_number ILIKE ?)"
      (pat raw, pat raw, pat raw, pat raw)
  c5 <- fmtText conn "crm_can_access(?,'lead',l.id)" (Only (lfActor lf))
  pure (" WHERE " <> T.intercalate " AND " [c1, c2, c3, c4, c5])
  where
    pat raw = "%" <> raw <> "%"

-- | One page of leads plus the total number of rows matching the filter
-- (ignoring LIMIT\/OFFSET), for the pager.
listLeadsPaged :: Connection -> LeadQuery -> IO ([Lead], Int)
listLeadsPaged conn lq = do
  whereSql <- leadWhere conn (lqFilter lq)
  (Only total:_) <- query_ conn
    (Query (TE.encodeUtf8 ("SELECT COUNT(*) FROM leads l" <> whereSql)))
    :: IO [Only Int]
  let orderCol = case T.toLower (lqSort lq) of
        "stage"    -> "l.stage"
        "quality"  -> "CASE l.quality WHEN 'Hot' THEN 0 WHEN 'Warm' THEN 1 \
                      \WHEN 'Cold' THEN 2 ELSE 3 END"
        "followup" -> "l.next_followup"
        "created"  -> "l.created_at"
        _          -> "lower(l.full_name)"
      dir = if lqAsc lq then " ASC" else " DESC"
      sql = fromQuery leadSelect <> TE.encodeUtf8
              (whereSql <> " ORDER BY " <> orderCol <> dir <> " NULLS LAST"
               <> " LIMIT " <> T.pack (show (max 1 (lqLimit lq)))
               <> " OFFSET " <> T.pack (show (max 0 (lqOffset lq))))
  rows <- query_ conn (Query sql) :: IO [LeadRow]
  pure (map toLead rows, total)

listLeads :: Connection -> IO [Lead]
listLeads conn = do
  rows <- query_ conn (leadSelect <> " ORDER BY l.id DESC") :: IO [LeadRow]
  pure (map toLead rows)

getLead :: Connection -> Int -> IO (Maybe Lead)
getLead conn lid = do
  rows <- query conn (leadSelect <> " WHERE l.id = ?") (Only lid) :: IO [LeadRow]
  pure (toLead <$> listToMaybe rows)

getLeadDetail :: Connection -> Int -> IO (Maybe LeadDetail)
getLeadDetail conn lid = do
  ml <- getLead conn lid
  case ml of
    Nothing -> pure Nothing
    Just l -> do
      ts <- tasksForLead conn lid
      acts <- activitiesForLead conn lid
      docs <- documentsForLead conn lid
      pure (Just (LeadDetail l ts acts docs))

insertLead :: Connection -> NewLead -> Int -> IO Lead
insertLead conn nl actorId = do
  num <- nextNumber conn "L" "leads" "lead_number" 4
  today <- utctDay <$> getCurrentTime
  ids <- returning conn
    "INSERT INTO leads (lead_number, full_name, email, phone, source, consultant_id, quality, stage, destination, service, notes, next_followup, last_contact) VALUES (?,?,?,?,?,?,?,?,?,?,?,?,?) RETURNING id"
    [ ( num, nlFullName nl, nonEmpty (nlEmail nl), nonEmpty (nlPhone nl)
      , nonEmpty (nlSource nl), maybe (Just actorId) Just (nlConsultantId nl)
      , nonEmpty (nlQuality nl), maybe "New Lead" id (nlStage nl)
      , nonEmpty (nlDestination nl), nonEmpty (nlService nl), nonEmpty (nlNotes nl)
      , nlNextFollowup nl, Just today ) ]
  let lid = head (concat ids)
  logActivity conn lid "created" ("Lead created: " <> num <> " — " <> nlFullName nl)
  mlead <- getLead conn lid
  maybe (error "lead vanished after insert") pure mlead

-- | Render one value as a properly escaped SQL literal.
sqlLit :: ToField a => Connection -> a -> IO Text
sqlLit conn v = TE.decodeUtf8 <$> formatQuery conn "?" (Only v)

-- | One @col = …@ assignment honouring the tri-state patch: absent keeps the
-- stored value, @null@ writes NULL, a value overwrites.
setPatch :: ToField a => Connection -> Text -> Patch a -> IO Text
setPatch conn col p = case p of
  Clear -> pure (col <> " = NULL")
  Keep  -> pure (col <> " = " <> col)
  Set v -> do
    l <- sqlLit conn v
    pure (col <> " = " <> l)

patchLead :: Connection -> Int -> UpdateLead -> Maybe Int -> IO (Maybe Lead)
patchLead conn lid ul actorId = do
  existing <- getLead conn lid
  case existing of
    Nothing -> pure Nothing
    Just old -> do
      let newStage = applyRequired (stage old) (ulStage ul)
      unless (newStage == stage old) $
        logActivity conn lid "stage_change" ("Moved to " <> newStage)
      sets <- sequence
        [ pure ("full_name = " <>) <*> sqlLit conn (applyRequired (fullName old) (ulFullName ul))
        , setPatch conn "email" (ulEmail ul)
        , setPatch conn "phone" (ulPhone ul)
        , setPatch conn "source" (ulSource ul)
        , setPatch conn "consultant_id" (ulConsultantId ul)
        , setPatch conn "quality" (ulQuality ul)
        , pure ("stage = " <>) <*> sqlLit conn newStage
        , setPatch conn "destination" (ulDestination ul)
        , setPatch conn "service" (ulService ul)
        , setPatch conn "notes" (ulNotes ul)
        , setPatch conn "last_contact" (ulLastContact ul)
        , setPatch conn "next_followup" (ulNextFollowup ul)
        ]
      void $ execute_ conn . Query . TE.encodeUtf8 $
        "UPDATE leads SET " <> T.intercalate ", " sets
          <> ", updated_at = NOW() WHERE id = " <> T.pack (show lid)
      -- audit trail: field-level diff of what actually changed
      let pairs = concat
            [ auditPair "Full Name"     (Just (fullName old))
                        (Just (applyRequired (fullName old) (ulFullName ul)))
            , auditPair "Email"         (email old)         (applyPatch (ulEmail ul) (email old))
            , auditPair "Phone"         (phone old)         (applyPatch (ulPhone ul) (phone old))
            , auditPair "Source"        (source old)        (applyPatch (ulSource ul) (source old))
            , auditPair "Quality"       (quality old)       (applyPatch (ulQuality ul) (quality old))
            , auditPair "Stage"         (Just (stage old))  (Just newStage)
            , auditPair "Destination"   (destination old)   (applyPatch (ulDestination ul) (destination old))
            , auditPair "Service"       (service old)       (applyPatch (ulService ul) (service old))
            , auditPair "Notes"         (notes old)         (applyPatch (ulNotes ul) (notes old))
            , auditPair "Last Contact"  (lastContact old)   (applyPatch (ulLastContact ul) (lastContact old))
            , auditPair "Next Follow-up"(nextFollowup old)  (applyPatch (ulNextFollowup ul) (nextFollowup old))
            ]
          effConsultant = applyPatch (ulConsultantId ul) (consultantId old)
      consultPairs <-
        if fmap A.toJSON (consultantId old) /= fmap A.toJSON effConsultant
          then do
            fromN <- traverse (userNameFor conn) (consultantId old)
            toN <- traverse (userNameFor conn) effConsultant
            pure (auditPair "Consultant" fromN toN)
          else pure []
      unless (null pairs && null consultPairs) $
        logAuditEntry conn "lead" lid
          (Just (leadNumber old <> " — " <> fullName old))
          "updated"
          (Just (A.object (pairs ++ consultPairs)))
          actorId
      getLead conn lid

-- | Display name for a user id, for audit diffs.
userNameFor :: Connection -> Int -> IO (Maybe Text)
userNameFor conn uid = fmap userName <$> getUserById conn uid

deleteLead :: Connection -> Int -> Maybe Int -> IO Bool
deleteLead conn lid actorId = do
  ml <- getLead conn lid
  n <- execute conn "DELETE FROM leads WHERE id = ?" (Only lid)
  let ok = n > 0
  case ml of
    Just l | ok ->
      logAuditEntry conn "lead" lid
        (Just (leadNumber l <> " — " <> fullName l))
        "deleted" Nothing actorId
    _ -> pure ()
  pure ok

advanceStage :: Connection -> Int -> IO (Either Text (Maybe Lead))
advanceStage conn lid = do
  mlead <- getLead conn lid
  case mlead of
    Nothing -> pure (Right Nothing)
    Just l -> case nextOf (stage l) of
      Nothing -> pure (Left ("Already at terminal stage: " <> stage l))
      Just nxt -> do
        void $ execute conn "UPDATE leads SET stage=?, updated_at=NOW() WHERE id=?"
          (nxt, lid)
        logActivity conn lid "stage_change" ("Moved to " <> nxt)
        Right <$> getLead conn lid
  where
    nextOf s = case break (== s) leadStages of
      (_, (_:after)) -> listToMaybe after
      _              -> Nothing

-- | Convert a lead into a client without destroying its history.
--
-- The old implementation deleted the lead row, which cascaded away the
-- lead's tasks, activities and uploaded documents.  Now the lead is kept
-- (stage @Converted@) and linked to the new client via @converted_client_id@;
-- documents move across so they appear on the client, while tasks and
-- activities stay with the lead. Client-linked tasks remain available after conversion.
convertToClient :: Connection -> Int -> Int -> IO (Maybe Client)
convertToClient conn lid officerId = withTransaction conn $ do
  void (query conn "SELECT set_config('ecc.converting',?,true)" (Only (T.pack (show lid))) :: IO [Only Text])
  void (query conn "SELECT set_config('ecc.actor',?,true)" (Only (T.pack (show officerId))) :: IO [Only Text])
  void $ execute_ conn "DO $$ BEGIN PERFORM pg_advisory_xact_lock(718441); END $$"
  locked <- query conn "SELECT id FROM leads WHERE id=? AND converted_client_id IS NULL FOR UPDATE" (Only lid) :: IO [Only Int]
  mlead <- if null locked then pure Nothing else getLead conn lid
  case mlead of
    Nothing -> pure Nothing
    Just l -> do
      client <- insertClientRaw conn (fullName l) (email l) (phone l) (Just officerId)
      case (service l, destination l) of
        (Nothing, Nothing) -> pure ()
        _ -> void $ execute conn
          "INSERT INTO cases (client_id, service_category, destination, stage) VALUES (?,?,?,'Documents Under Review')"
          (clientId client, service l, destination l)
      void $ execute conn
        "UPDATE documents SET client_id = ?, lead_id = NULL WHERE lead_id = ?"
        (clientId client, lid)
      void $ execute conn
        "UPDATE leads SET stage = 'Converted', converted_client_id = ?, updated_at = NOW() WHERE id = ?"
        (clientId client, lid)
      logActivity conn lid "stage_change" ("Converted to client " <> clientNumber client)
      logAuditEntry conn "lead" lid
        (Just (leadNumber l <> " — " <> fullName l))
        "updated"
        (Just (A.object
          [ ("Stage", A.object [ ("from", A.String (stage l))
                               , ("to", A.String "Converted") ])
          , ("Client", A.object [ ("from", A.Null)
                                , ("to", A.String (clientNumber client)) ])
          ]))
        (Just officerId)
      pure (Just client)

addNote :: Connection -> Int -> Text -> IO ()
addNote conn lid note = do
  logActivity conn lid "note" ("Added note: " <> note)
  touchLastContact conn lid

bulkLeads :: Connection -> BulkRequest -> Int -> IO Int
bulkLeads conn br actorId = do
  results <- forM (brIds br) $ \lid -> case brOp br of
    BulkDelete -> boolToInt <$> deleteLead conn lid (Just actorId)
    BulkAssign -> do
      void $ execute conn
        "UPDATE leads SET consultant_id=?, updated_at=NOW() WHERE id=?"
        (brConsultantId br, lid)
      pure 1
    BulkAdvance -> either (const 0) (maybe 0 (const 1)) <$> advanceStage conn lid
  pure (sum results)
  where
    boolToInt b = if b then 1 else 0

-- | Import leads from parsed CSV rows (first row = header).  Columns are
-- matched by header name; unknown columns are ignored, so files exported by
-- this same API round-trip cleanly.  Valid rows are inserted, invalid ones
-- are reported per row.  \"Consultant\" is matched against user display
-- names (case-insensitive).
importLeads :: Connection -> [[Text]] -> Int -> IO ImportResult
importLeads conn allRows actorId =
  case allRows of
    (hdr : dataRows) | not (null dataRows) -> do
      users <- listUsers conn
      let consultants = [ (T.toLower (userName u), userId u) | u :: User <- users ]
          hdrMap = [ (norm h, k) | (k, h) <- zip [0 ..] hdr ]
          norm = T.toLower . T.strip
          pick r name = lookup (norm name) hdrMap >>= \k -> listToMaybe (drop k r)
          val r name = T.strip <$> pick r name >>= nonEmptyT
          dateCell r name =
            case val r name of
              Nothing -> Right Nothing
              Just s -> case parseTimeM False defaultTimeLocale "%Y-%m-%d"
                               (T.unpack s) of
                Just d -> Right (Just (d :: Day))
                Nothing -> Left ("\"" <> name <> "\" must be YYYY-MM-DD")
          build n r =
            case val r "Full Name" of
              Nothing -> Left (n, "Full Name is required")
              Just nm ->
                let mConsultant =
                      case val r "Consultant" of
                        Nothing -> Right Nothing
                        Just cname ->
                          case lookup (T.toLower cname) consultants of
                            Just uid -> Right (Just uid)
                            Nothing -> Left ("Unknown consultant: " <> cname)
                    mDates = (,) <$> dateCell r "Last Contact"
                                 <*> dateCell r "Next Follow-up"
                 in case mConsultant of
                      Left err -> Left (n, err)
                      Right mcid -> case mDates of
                        Left err -> Left (n, err)
                        Right (mlc, mnf) ->
                          Right ( n, NewLead
                                    { nlFullName = nm
                                    , nlEmail = val r "Email"
                                    , nlPhone = val r "Phone"
                                    , nlSource = val r "Source"
                                    , nlQuality = val r "Quality"
                                    , nlStage = val r "Stage"
                                    , nlDestination = val r "Destination"
                                    , nlService = val r "Service"
                                    , nlNotes = val r "Notes"
                                    , nlNextFollowup = mnf
                                    , nlConsultantId = mcid
                                    }
                                , mlc )
          results = zipWith build [1 ..] dataRows
          failures = [ ImportRowError n e | Left (n, e) <- results ]
          goods = [ g | Right g <- results ]
      outcomes <- forM goods $ \(rowNum, nl, mlc) -> do
        outcome <- try $ withTransaction conn $ do
          l <- insertLead conn nl actorId
          forM_ mlc $ \d ->
            void $ execute conn "UPDATE leads SET last_contact=? WHERE id=?" (Just d, leadId l)
        pure $ case outcome of
          Right () -> Right ()
          Left err -> Left (ImportRowError rowNum (TE.decodeUtf8 (sqlErrorMsg (err :: SqlError))))
      let (writeErrors, successes) = partitionEithers outcomes
      pure (ImportResult (length successes) (failures ++ writeErrors))
    _ -> pure (ImportResult 0 [])
  where
    nonEmptyT t = if T.null (T.strip t) then Nothing else Just t


-- ---------- clients / cases ----------

clientSelect :: Query
clientSelect =
  "SELECT cl.id, cl.client_number, cl.full_name, cl.email, cl.phone, \
  \cl.case_officer_id, u.name AS case_officer_name, cl.created_at \
  \FROM clients cl LEFT JOIN users u ON u.id = cl.case_officer_id"

toClient :: (Int, Text, Text, Maybe Text, Maybe Text, Maybe Int, Maybe Text, UTCTime) -> Client
toClient (i, num, nm, em, ph, officer, oname, ca) =
  Client i num nm em ph officer oname ca

listClients :: Connection -> IO [Client]
listClients conn = do
  rows <- query_ conn (clientSelect <> " ORDER BY cl.id DESC")
    :: IO [(Int, Text, Text, Maybe Text, Maybe Text, Maybe Int, Maybe Text, UTCTime)]
  pure (map toClient rows)

-- | One page of clients matching an optional free-text search, plus the total
-- number of matches for the pager.
listClientsPaged :: Connection -> Maybe Text -> Int -> Int -> Int -> IO ([Client], Int)
listClientsPaged conn mq limit offset actor = do
  access <- fmtText conn "crm_can_access(?,'client',cl.id)" (Only actor)
  filters <- case mq of
    Nothing -> pure " WHERE TRUE"
    Just raw -> do
      let pat = "%" <> raw <> "%"
      c <- fmtText conn
        "(cl.full_name ILIKE ? OR COALESCE(cl.email,'') ILIKE ? \
        \OR COALESCE(cl.phone,'') ILIKE ? OR cl.client_number ILIKE ?)"
        (pat, pat, pat, pat)
      pure (" WHERE " <> c)
  let whereSql = filters <> " AND " <> access
  (Only total:_) <- query_ conn
    (Query (TE.encodeUtf8 ("SELECT COUNT(*) FROM clients cl" <> whereSql)))
    :: IO [Only Int]
  rows <- query_ conn
    (Query (fromQuery clientSelect <> TE.encodeUtf8
      (whereSql <> " ORDER BY cl.id DESC LIMIT " <> T.pack (show (max 1 limit))
       <> " OFFSET " <> T.pack (show (max 0 offset)))))
    :: IO [(Int, Text, Text, Maybe Text, Maybe Text, Maybe Int, Maybe Text, UTCTime)]
  pure (map toClient rows, total)

getClientDetail :: Connection -> Int -> IO (Maybe ClientDetail)
getClientDetail conn cid = do
  rows <- query conn (clientSelect <> " WHERE cl.id = ?") (Only cid)
    :: IO [(Int, Text, Text, Maybe Text, Maybe Text, Maybe Int, Maybe Text, UTCTime)]
  case rows of
    [] -> pure Nothing
    (r:_) -> do
      casesRows <- query conn
        "SELECT id, client_id, service_category, destination, stage, next_deadline, created_at FROM cases WHERE client_id = ? ORDER BY id"
        (Only cid) :: IO [(Int, Int, Maybe Text, Maybe Text, Text, Maybe Day, UTCTime)]
      let cases = map (\(i, c, sc, d, st, dl, ca) -> CaseRow i c sc d st dl ca) casesRows
      docs <- documentsForClient conn cid
      pure (Just (ClientDetail (toClient r) cases docs))

insertClientRaw :: Connection -> Text -> Maybe Text -> Maybe Text -> Maybe Int -> IO Client
insertClientRaw conn nm em ph officer = do
  num <- nextNumber conn "ECC" "clients" "client_number" 5
  ids <- returning conn
    "INSERT INTO clients (client_number, full_name, email, phone, case_officer_id) VALUES (?,?,?,?,?) RETURNING id"
    [ (num, nm, em, ph, officer) ]
  detail <- getClientDetail conn (head (concat ids))
  maybe (error "client vanished after insert") (pure . cdClient) detail

insertClient :: Connection -> NewClient -> IO Client
insertClient conn nc =
  insertClientRaw conn (ncFullName nc) (ncEmail nc) (ncPhone nc) (ncCaseOfficer nc)

patchClient :: Connection -> Int -> UpdateClient -> Maybe Int -> IO Bool
patchClient conn cid uc actorId = withTransaction conn $ do
  void (query conn "SELECT set_config('ecc.actor',?,true)" (Only (maybe "" (T.pack . show) actorId)) :: IO [Only Text])
  existing <- getClientDetail conn cid
  case existing of
    Nothing -> pure False
    Just old -> do
      let c = cdClient old
      sets <- sequence
        [ pure ("full_name = " <>) <*> sqlLit conn (applyRequired (clientFullName c) (ucFullName uc))
        , setPatch conn "email" (ucEmail uc)
        , setPatch conn "phone" (ucPhone uc)
        , setPatch conn "case_officer_id" (ucCaseOfficer uc)
        ]
      void $ execute_ conn . Query . TE.encodeUtf8 $
        "UPDATE clients SET " <> T.intercalate ", " sets
          <> " WHERE id = " <> T.pack (show cid)
      -- audit trail: field-level diff of what actually changed
      let pairs = concat
            [ auditPair "Full Name" (Just (clientFullName c))
                        (Just (applyRequired (clientFullName c) (ucFullName uc)))
            , auditPair "Email" (clientEmail c) (applyPatch (ucEmail uc) (clientEmail c))
            , auditPair "Phone" (clientPhone c) (applyPatch (ucPhone uc) (clientPhone c))
            ]
          effOfficer = applyPatch (ucCaseOfficer uc) (caseOfficerId c)
      officerPairs <-
        if fmap A.toJSON (caseOfficerId c) /= fmap A.toJSON effOfficer
          then do
            fromN <- traverse (userNameFor conn) (caseOfficerId c)
            toN <- traverse (userNameFor conn) effOfficer
            pure (auditPair "Case Officer" fromN toN)
          else pure []
      unless (null pairs && null officerPairs) $
        logAuditEntry conn "client" cid
          (Just (clientNumber c <> " — " <> clientFullName c))
          "updated"
          (Just (A.object (pairs ++ officerPairs)))
          actorId
      pure True

deleteClient :: Connection -> Int -> Maybe Int -> IO Bool
deleteClient conn cid actorId = do
  existing <- getClientDetail conn cid
  n <- execute conn "DELETE FROM clients WHERE id = ?" (Only cid)
  let ok = n > 0
  case existing of
    Just cd | ok ->
      logAuditEntry conn "client" cid
        (Just (clientNumber (cdClient cd) <> " — " <> clientFullName (cdClient cd)))
        "deleted" Nothing actorId
    _ -> pure ()
  pure ok

upsertCase :: Connection -> Int -> CaseInput -> IO ()
upsertCase conn cid ci = case ciCaseId ci of
  Just caseId -> void $ execute conn
    "UPDATE cases SET service_category=COALESCE(?,service_category), \
    \destination=COALESCE(?,destination), stage=COALESCE(?,stage), \
    \next_deadline=COALESCE(?,next_deadline) WHERE id=? AND client_id=?"
    (ciServiceCategory ci, ciDestination ci, ciStage ci, ciNextDeadline ci, caseId, cid)
  Nothing -> void $ execute conn
    "INSERT INTO cases (client_id, service_category, destination, stage, next_deadline) VALUES (?,?,?,?,?)"
    (cid, ciServiceCategory ci, ciDestination ci,
     maybe "Documents Under Review" id (ciStage ci), ciNextDeadline ci)

deleteCase :: Connection -> Int -> IO Bool
deleteCase conn caseId = (> 0) <$> execute conn "DELETE FROM cases WHERE id = ?" (Only caseId)

-- ---------- documents ----------

type DocRowT = (Int, Maybe Int, Maybe Int, Text, Text, Int, Maybe Text, UTCTime)

docSelect :: Query
docSelect =
  "SELECT d.id, d.lead_id, d.client_id, d.filename, d.mime_type, d.size, \
  \u.name AS uploader_name, d.created_at \
  \FROM documents d LEFT JOIN users u ON u.id = d.uploaded_by"

toDoc :: DocRowT -> Document
toDoc (i, lid, cid, fname, mime, sz, up, ca) =
  Document i lid cid fname mime sz up ca

documentsForLead :: Connection -> Int -> IO [Document]
documentsForLead conn lid = do
  rows <- query conn (docSelect <> " WHERE d.lead_id = ? ORDER BY d.id DESC")
    (Only lid) :: IO [DocRowT]
  pure (map toDoc rows)

documentsForClient :: Connection -> Int -> IO [Document]
documentsForClient conn cid = do
  rows <- query conn (docSelect <> " WHERE d.client_id = ? ORDER BY d.id DESC")
    (Only cid) :: IO [DocRowT]
  pure (map toDoc rows)

-- | Stores the raw bytes; exactly one of lead\/client id must be Just.
insertDocument :: Connection -> Maybe Int -> Maybe Int -> Text -> Text
               -> B.ByteString -> Maybe Int -> IO Document
insertDocument conn mlid mcid fname mime content uploaderId = do
  ids <- returning conn
    "INSERT INTO documents (lead_id, client_id, filename, mime_type, size, content, uploaded_by) VALUES (?,?,?,?,?,?,?) RETURNING id"
    [ (mlid, mcid, fname, mime, B.length content, Binary content, uploaderId) ]
    :: IO [[Int]]
  let did = head (concat ids)
  rows <- query conn (docSelect <> " WHERE d.id = ?") (Only did) :: IO [DocRowT]
  pure (toDoc (head rows))

-- | Filename + content-type + bytes for a download.
getDocumentContent :: Connection -> Int -> IO (Maybe (Text, Text, B.ByteString))
getDocumentContent conn did = do
  rows <- query conn
    "SELECT filename, mime_type, content FROM documents WHERE id = ?"
    (Only did) :: IO [(Text, Text, Binary B.ByteString)]
  pure $ case rows of
    [(fname, mime, Binary bs)] -> Just (fname, mime, bs)
    _                          -> Nothing

deleteDocument :: Connection -> Int -> IO Bool
deleteDocument conn did = (> 0) <$> execute conn "DELETE FROM documents WHERE id = ?" (Only did)

-- ---------- tasks ----------

taskSelect :: Query
taskSelect =
  "SELECT t.id, COALESCE(t.lead_id,0), l.full_name AS lead_name, t.title, t.description, \
  \t.due_date, t.priority, t.status, t.assigned_to_id, u.name AS assignee_name, \
  \t.created_at \
  \FROM tasks t LEFT JOIN leads l ON l.id = t.lead_id \
  \LEFT JOIN users u ON u.id = t.assigned_to_id"

listTasks :: Connection -> Int -> IO [Task]
listTasks conn actor = do
  rows <- query conn (taskSelect <> " WHERE crm_can_access(?,CASE WHEN t.client_id IS NOT NULL THEN 'client' ELSE 'lead' END,coalesce(t.client_id,t.lead_id)) ORDER BY t.due_date NULLS LAST, t.id DESC") (Only actor)
    :: IO [TaskRowT]
  pure (map toTask rows)

tasksForLead :: Connection -> Int -> IO [Task]
tasksForLead conn lid = do
  rows <- query conn (taskSelect <> " WHERE t.lead_id = ? ORDER BY t.id DESC")
    (Only lid) :: IO [TaskRowT]
  pure (map toTask rows)

type TaskRowT = ( Int, Int, Maybe Text, Text, Maybe Text, Maybe Day
                , Text, Text, Maybe Int, Maybe Text, UTCTime )

toTask :: TaskRowT -> Task
toTask (i, lid, lname, title, desc, due, prio, st, aid, aname, ca) =
  Task i lid lname title desc due prio st aid aname ca

insertTask :: Connection -> NewTask -> Int -> IO Task
insertTask conn nt actorId = do
  ids <- returning conn
    "INSERT INTO tasks (lead_id, title, description, due_date, priority, status, assigned_to_id) VALUES (?,?,?,?,?,?,?) RETURNING id"
    [ (ntLeadId nt, ntTitle nt, ntDescription nt, ntDueDate nt,
       maybe "Medium" id (ntPriority nt), "Pending" :: Text, actorId) ] :: IO [[Int]]
  let tid = head (concat ids)
  logActivity conn (ntLeadId nt) "task" ("Task added: " <> ntTitle nt)
  touchLastContact conn (ntLeadId nt)
  rows <- query conn (taskSelect <> " WHERE t.id = ?") (Only tid) :: IO [TaskRowT]
  pure (toTask (head rows))

setTaskStatus :: Connection -> Int -> Text -> IO Bool
setTaskStatus conn tid st = do
  n <- execute conn "UPDATE tasks SET status=? WHERE id=?" (st, tid)
  pure (n > 0)

deleteTask :: Connection -> Int -> IO Bool
deleteTask conn tid = (> 0) <$> execute conn "DELETE FROM tasks WHERE id=?" (Only tid)

-- ---------- activities ----------

type ActRowT = (Int, Int, Maybe Text, Text, Maybe Text, Day)

actSelect :: Query
actSelect =
  "SELECT a.id, a.lead_id, l.full_name AS lead_name, a.type, a.description, a.date \
  \FROM activities a JOIN leads l ON l.id = a.lead_id"

listActivities :: Connection -> Int -> IO [Activity]
listActivities conn limit = do
  rows <- query conn (actSelect <> " ORDER BY a.id DESC LIMIT ?") (Only limit)
    :: IO [ActRowT]
  pure (map toAct rows)

activitiesForLead :: Connection -> Int -> IO [Activity]
activitiesForLead conn lid = do
  rows <- query conn (actSelect <> " WHERE a.lead_id = ? ORDER BY a.id DESC")
    (Only lid) :: IO [ActRowT]
  pure (map toAct rows)

toAct :: ActRowT -> Activity
toAct (i, lid, lname, kind, desc, day) = Activity i lid lname kind desc day

-- ---------- stats ----------

-- ---------- audit trail ----------

type AuditRowT = (Int, Text, Int, Maybe Text, Text, Maybe A.Value, Maybe Text, UTCTime)

toAudit :: AuditRowT -> AuditEntry
toAudit (i, etype, eid, ename, action, changes, actor, ca) =
  AuditEntry i etype eid ename action changes actor ca

auditSelect :: Query
auditSelect =
  "SELECT a.id, a.entity_type, a.entity_id, a.entity_name, a.action, \
  \a.changes, u.name AS actor_name, a.created_at \
  \FROM audit_log a LEFT JOIN users u ON u.id = a.actor_id"

-- | Latest audit entries, optionally filtered by entity type and\/or id.
listAuditEntries :: Connection -> Maybe Text -> Maybe Int -> Int -> IO [AuditEntry]
listAuditEntries conn mType mId limit
  | Just t <- mType, Just i <- mId = do
      rows <- query conn (auditSelect <>
        " WHERE a.entity_type = ? AND a.entity_id = ? ORDER BY a.id DESC LIMIT ?")
        (t, i, limit) :: IO [AuditRowT]
      pure (map toAudit rows)
  | Just t <- mType = do
      rows <- query conn (auditSelect <>
        " WHERE a.entity_type = ? ORDER BY a.id DESC LIMIT ?") (t, limit)
        :: IO [AuditRowT]
      pure (map toAudit rows)
  | otherwise = do
      rows <- query conn (auditSelect <> " ORDER BY a.id DESC LIMIT ?") (Only limit)
        :: IO [AuditRowT]
      pure (map toAudit rows)

-- ---------- stats ----------

getStats :: Connection -> Int -> IO Stats
getStats conn actor = do
  total <- scalar "SELECT COUNT(*) FROM leads WHERE crm_can_access(?,'lead',id)"
  hot <- scalar "SELECT COUNT(*) FROM leads WHERE crm_can_access(?,'lead',id) AND quality='Hot'"
  clients <- scalar "SELECT COUNT(*) FROM clients WHERE crm_can_access(?,'client',id)"
  openT <- scalar "SELECT COUNT(*) FROM tasks WHERE crm_can_access(?,CASE WHEN client_id IS NOT NULL THEN 'client' ELSE 'lead' END,coalesce(client_id,lead_id)) AND status<>'Done'"
  overdue <-
    scalar "SELECT COUNT(*) FROM tasks WHERE crm_can_access(?,CASE WHEN client_id IS NOT NULL THEN 'client' ELSE 'lead' END,coalesce(client_id,lead_id)) AND status<>'Done' AND due_date<CURRENT_DATE"
  stages <- query conn
    "SELECT COALESCE(stage,'Unknown') AS stage, COUNT(*)::int FROM leads WHERE crm_can_access(?,'lead',id) GROUP BY stage" (Only actor)
    :: IO [(Text, Int)]
  sources <- query conn
    "SELECT COALESCE(source,'Unknown') AS source, COUNT(*)::int FROM leads WHERE crm_can_access(?,'lead',id) GROUP BY source ORDER BY count DESC" (Only actor)
    :: IO [(Text, Int)]
  upcomingRows <- query conn (taskSelect <>
    " WHERE crm_can_access(?,CASE WHEN t.client_id IS NOT NULL THEN 'client' ELSE 'lead' END,coalesce(t.client_id,t.lead_id)) AND t.status<>'Done' ORDER BY t.due_date NULLS LAST LIMIT 6") (Only actor) :: IO [TaskRowT]
  recent <- listActivitiesFor conn actor 8
  pure Stats
    { stTotalLeads = total
    , stHotLeads = hot
    , stTotalClients = clients
    , stOpenTasks = openT
    , stOverdueTasks = overdue
    , stStageCounts = map (uncurry StageCount) stages
    , stSourceCounts = map (uncurry SourceCount) sources
    , stUpcomingTasks = map toTask upcomingRows
    , stRecentActivity = recent
    }
  where
    scalar q = do
      rs <- query conn q (Only actor) :: IO [Only Int]
      pure (maybe 0 fromOnly (listToMaybe rs))

listActivitiesFor :: Connection -> Int -> Int -> IO [Activity]
listActivitiesFor conn actor limit = do
  rows <- query conn (actSelect <> " WHERE crm_can_access(?,'lead',a.lead_id) ORDER BY a.created_at DESC LIMIT ?") (actor,limit) :: IO [ActRowT]
  pure (map toAct rows)
