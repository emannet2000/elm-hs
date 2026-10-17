{-# LANGUAGE OverloadedStrings #-}

-- | Domain types shared by the DB layer and the HTTP routes.
--
-- Wire format is camelCase JSON.  Types whose fields share a common Haskell
-- prefix (user, task, activity, client, case) get that prefix stripped and
-- the remainder lower-cased, e.g. @taskDueDate -> "dueDate"@.
module ECC.Models
  ( User(..)
  , Lead(..)
  , LeadDetail(..)
  , NewLead(..)
  , UpdateLead(..)
  , Patch(..)
  , patchClear
  , patchValue
  , applyPatch
  , applyRequired
  , Task(..)
  , NewTask(..)
  , Activity(..)
  , Client(..)
  , ClientDetail(..)
  , NewClient(..)
  , UpdateClient(..)
  , CaseRow(..)
  , CaseInput(..)
  , Document(..)
  , StageCount(..)
  , SourceCount(..)
  , Stats(..)
  , LoginRequest(..)
  , LoginResponse(..)
  , NoteRequest(..)
  , TaskStatusRequest(..)
  , NewUser(..)
  , UpdateUser(..)
  , PasswordChange(..)
  , AuditEntry(..)
  , BulkOp(..)
  , BulkRequest(..)
  , ImportRowError(..)
  , ImportResult(..)
  ) where

import Data.Aeson (ToJSON (..), FromJSON (..), Value (..), Key, Object, object,
                   (.=), genericToJSON, withText, withObject, genericToEncoding,
                   genericParseJSON, defaultOptions, Options (..))
import qualified Data.Aeson.KeyMap as KM
import Data.Aeson.Types (Parser)
import Data.Char (toLower)
import Data.List (isPrefixOf)
import GHC.Generics (Generic)
import Data.Text (Text)
import qualified Data.Text as T
import Data.Time (Day, UTCTime)

-- | @taskDueDate@ -> "dueDate": drop the prefix when present and lower-case
-- the first letter of what remains.
prefixOpts :: String -> Options
prefixOpts p = defaultOptions { fieldLabelModifier = modifyLabel }
  where
    modifyLabel f
      | p `isPrefixOf` f = lowerFirst (drop (length p) f)
      | otherwise        = f
    lowerFirst [] = []
    lowerFirst (c:cs) = toLower c : cs

-- | Users of the CRM. Roles: "admin" > "consultant" > "viewer" (read-only).
data User = User
  { userId    :: Int
  , userEmail :: Text
  , userName  :: Text
  , userRole  :: Text
  } deriving (Show, Eq, Generic)

instance ToJSON User where
  toEncoding = genericToEncoding (prefixOpts "user")
  toJSON = genericToJSON (prefixOpts "user")
instance FromJSON User where parseJSON = genericParseJSON (prefixOpts "user")

data Lead = Lead
  { leadId            :: Int
  , leadNumber        :: Text
  , fullName          :: Text
  , email             :: Maybe Text
  , phone             :: Maybe Text
  , source            :: Maybe Text
  , consultantId      :: Maybe Int
  , consultantName    :: Maybe Text
  , quality           :: Maybe Text
  , stage             :: Text
  , destination       :: Maybe Text
  , service           :: Maybe Text
  , notes             :: Maybe Text
  , lastContact       :: Maybe Day
  , nextFollowup      :: Maybe Day
  , createdAt         :: UTCTime
  , updatedAt         :: UTCTime
  } deriving (Show, Eq, Generic, ToJSON, FromJSON)

-- | Composite payload for the lead detail page.
data LeadDetail = LeadDetail
  { ldLead         :: Lead
  , ldTasks        :: [Task]
  , ldActivities   :: [Activity]
  , ldDocuments    :: [Document]
  } deriving (Show, Eq, Generic)

instance ToJSON LeadDetail where
  toJSON ld = object
    [ "lead" .= ldLead ld
    , "tasks" .= ldTasks ld
    , "activities" .= ldActivities ld
    , "documents" .= ldDocuments ld
    ]

data NewLead = NewLead
  { nlFullName     :: Text
  , nlEmail        :: Maybe Text
  , nlPhone        :: Maybe Text
  , nlSource       :: Maybe Text
  , nlQuality      :: Maybe Text
  , nlStage        :: Maybe Text
  , nlDestination  :: Maybe Text
  , nlService      :: Maybe Text
  , nlNotes        :: Maybe Text
  , nlNextFollowup :: Maybe Day
  , nlConsultantId :: Maybe Int
  } deriving (Show, Eq, Generic, FromJSON)

-- | Tri-state update field, allowing a client to distinguish "leave this
-- alone" from "clear this":
--
--   * key absent from the JSON object -> 'Keep'  (COALESCE semantics)
--   * key present and @null@          -> 'Clear' (write NULL)
--   * key present with a value        -> 'Set'
--
-- The old code used @COALESCE(NULLIF(?,\'\'), col)@ everywhere, which made it
-- impossible to ever remove an email address, phone number or note once set.
data Patch a = Keep | Clear | Set a
  deriving (Show, Eq)

-- | True when the patch asks for an explicit NULL.
patchClear :: Patch a -> Bool
patchClear Clear = True
patchClear _     = False

-- | The value supplied by the patch, if any.
patchValue :: Patch a -> Maybe a
patchValue (Set x) = Just x
patchValue _       = Nothing

-- | Effective value after applying a patch to the stored value.
applyPatch :: Patch a -> Maybe a -> Maybe a
applyPatch Keep old     = old
applyPatch Clear _      = Nothing
applyPatch (Set x) _    = Just x

-- | Effective value for a NOT NULL column: an explicit clear is ignored and
-- an empty string keeps the stored value.
applyRequired :: Text -> Patch Text -> Text
applyRequired old p = case applyPatch p (Just old) of
  Just v | not (T.null (T.strip v)) -> v
  _                                 -> old

-- | Read one field, distinguishing absent / null / value.
patchField :: FromJSON a => Object -> Key -> Parser (Patch a)
patchField o k = case KM.lookup k o of
  Nothing     -> pure Keep
  Just Null   -> pure Clear
  Just v      -> Set <$> parseJSON v

data UpdateLead = UpdateLead
  { ulFullName     :: Patch Text
  , ulEmail        :: Patch Text
  , ulPhone        :: Patch Text
  , ulSource       :: Patch Text
  , ulConsultantId :: Patch Int
  , ulQuality      :: Patch Text
  , ulStage        :: Patch Text
  , ulDestination  :: Patch Text
  , ulService      :: Patch Text
  , ulNotes        :: Patch Text
  , ulLastContact  :: Patch Day
  , ulNextFollowup :: Patch Day
  } deriving (Show, Eq)

instance FromJSON UpdateLead where
  parseJSON = withObject "UpdateLead" $ \o ->
    UpdateLead
      <$> patchField o "ulFullName"
      <*> patchField o "ulEmail"
      <*> patchField o "ulPhone"
      <*> patchField o "ulSource"
      <*> patchField o "ulConsultantId"
      <*> patchField o "ulQuality"
      <*> patchField o "ulStage"
      <*> patchField o "ulDestination"
      <*> patchField o "ulService"
      <*> patchField o "ulNotes"
      <*> patchField o "ulLastContact"
      <*> patchField o "ulNextFollowup"

-- | Partial client update: absent keeps, null clears, value sets.
data UpdateClient = UpdateClient
  { ucFullName    :: Patch Text
  , ucEmail       :: Patch Text
  , ucPhone       :: Patch Text
  , ucCaseOfficer :: Patch Int
  } deriving (Show, Eq)

instance FromJSON UpdateClient where
  parseJSON = withObject "UpdateClient" $ \o ->
    UpdateClient
      <$> patchField o "ncFullName"
      <*> patchField o "ncEmail"
      <*> patchField o "ncPhone"
      <*> patchField o "ncCaseOfficer"

data Task = Task
  { taskId           :: Int
  , taskLeadId       :: Int
  , taskLeadName     :: Maybe Text
  , taskTitle        :: Text
  , taskDescription  :: Maybe Text
  , taskDueDate      :: Maybe Day
  , taskPriority     :: Text
  , taskStatus       :: Text
  , taskAssignedTo   :: Maybe Int
  , taskAssigneeName :: Maybe Text
  , taskCreatedAt    :: UTCTime
  } deriving (Show, Eq, Generic)

instance ToJSON Task where
  toEncoding = genericToEncoding (prefixOpts "task")
  toJSON = genericToJSON (prefixOpts "task")
instance FromJSON Task where parseJSON = genericParseJSON (prefixOpts "task")

data NewTask = NewTask
  { ntLeadId      :: Int
  , ntTitle       :: Text
  , ntDescription :: Maybe Text
  , ntDueDate     :: Maybe Day
  , ntPriority    :: Maybe Text
  } deriving (Show, Eq, Generic, FromJSON)

data Activity = Activity
  { activityId          :: Int
  , activityLeadId      :: Int
  , activityLeadName    :: Maybe Text
  , activityKind        :: Text
  , activityDescription :: Maybe Text
  , activityDate        :: Day
  } deriving (Show, Eq, Generic)

instance ToJSON Activity where
  toEncoding = genericToEncoding (prefixOpts "activity")
  toJSON = genericToJSON (prefixOpts "activity")
instance FromJSON Activity where parseJSON = genericParseJSON (prefixOpts "activity")

data Client = Client
  { clientId        :: Int
  , clientNumber    :: Text
  , clientFullName  :: Text
  , clientEmail     :: Maybe Text
  , clientPhone     :: Maybe Text
  , caseOfficerId   :: Maybe Int
  , caseOfficerName :: Maybe Text
  , clientCreatedAt :: UTCTime
  } deriving (Show, Eq, Generic)

instance ToJSON Client where
  toEncoding = genericToEncoding (prefixOpts "client")
  toJSON = genericToJSON (prefixOpts "client")
instance FromJSON Client where parseJSON = genericParseJSON (prefixOpts "client")

data CaseRow = CaseRow
  { caseId         :: Int
  , caseClientId   :: Int
  , caseCategory   :: Maybe Text
  , caseDestination:: Maybe Text
  , caseStage      :: Text
  , caseDeadline   :: Maybe Day
  , caseCreatedAt  :: UTCTime
  } deriving (Show, Eq, Generic)

instance ToJSON CaseRow where
  toEncoding = genericToEncoding (prefixOpts "case")
  toJSON = genericToJSON (prefixOpts "case")
instance FromJSON CaseRow where parseJSON = genericParseJSON (prefixOpts "case")

data ClientDetail = ClientDetail
  { cdClient    :: Client
  , cdCases     :: [CaseRow]
  , cdDocuments :: [Document]
  } deriving (Show, Eq, Generic)

-- | Nested payload: {client: {...}, cases: [...], documents: [...]}
instance ToJSON ClientDetail where
  toJSON cd = object
    [ "client" .= cdClient cd
    , "cases" .= cdCases cd
    , "documents" .= cdDocuments cd
    ]

data NewClient = NewClient
  { ncFullName    :: Text
  , ncEmail       :: Maybe Text
  , ncPhone       :: Maybe Text
  , ncCaseOfficer :: Maybe Int
  } deriving (Show, Eq, Generic, FromJSON)

data CaseInput = CaseInput
  { ciServiceCategory :: Maybe Text
  , ciDestination     :: Maybe Text
  , ciStage           :: Maybe Text
  , ciNextDeadline    :: Maybe Day
  , ciCaseId          :: Maybe Int  -- ^ present => update that case instead of insert
  } deriving (Show, Eq, Generic, FromJSON)

-- | Metadata for an uploaded file; the raw bytes never reach the JSON layer.
data Document = Document
  { documentId        :: Int
  , documentLeadId    :: Maybe Int
  , documentClientId  :: Maybe Int
  , documentFilename  :: Text
  , documentMimeType  :: Text
  , documentSize      :: Int
  , documentUploader  :: Maybe Text  -- ^ uploader display name
  , documentCreatedAt :: UTCTime
  } deriving (Show, Eq, Generic)

instance ToJSON Document where
  toEncoding = genericToEncoding (prefixOpts "document")
  toJSON = genericToJSON (prefixOpts "document")

data StageCount = StageCount { scStage :: Text, scCount :: Int }
  deriving (Show, Eq, Generic, ToJSON)

data SourceCount = SourceCount { srcSource :: Text, srcCount :: Int }
  deriving (Show, Eq, Generic, ToJSON)

data Stats = Stats
  { stTotalLeads     :: Int
  , stHotLeads       :: Int
  , stTotalClients   :: Int
  , stOpenTasks      :: Int
  , stOverdueTasks   :: Int
  , stStageCounts    :: [StageCount]
  , stSourceCounts   :: [SourceCount]
  , stUpcomingTasks  :: [Task]
  , stRecentActivity :: [Activity]
  } deriving (Show, Eq, Generic, ToJSON)

data LoginRequest = LoginRequest { lrEmail :: Text, lrPassword :: Text }
  deriving (Show, Eq, Generic, FromJSON)

data LoginResponse = LoginResponse { token :: Text, user :: User }
  deriving (Show, Eq, Generic, ToJSON)

data NoteRequest = NoteRequest { nrNote :: Text }
  deriving (Show, Eq, Generic, FromJSON)

data TaskStatusRequest = TaskStatusRequest { tsrStatus :: Text }
  deriving (Show, Eq, Generic, FromJSON)

-- | Admin-only user creation.
data NewUser = NewUser
  { nuEmail    :: Text
  , nuName     :: Text
  , nuRole     :: Text
  , nuPassword :: Text
  } deriving (Show, Eq, Generic, FromJSON)

-- | Partial update; empty password means "keep current".
data UpdateUser = UpdateUser
  { uuName     :: Maybe Text
  , uuRole     :: Maybe Text
  , uuPassword :: Maybe Text
  } deriving (Show, Eq, Generic, FromJSON)

-- | Self-service password change: current password must match.
data PasswordChange = PasswordChange
  { pcCurrent :: Text
  , pcNew     :: Text
  } deriving (Show, Eq, Generic, FromJSON)

-- | One audit-trail row.  @auditChanges@ holds @{"Field":{"from":…,"to":…}}@
-- for updates and is Nothing for deletes.
data AuditEntry = AuditEntry
  { auditId         :: Int
  , auditEntityType :: Text
  , auditEntityId   :: Int
  , auditEntityName :: Maybe Text
  , auditAction     :: Text        -- ^ "created" | "updated" | "deleted"
  , auditChanges    :: Maybe Value
  , auditActorName  :: Maybe Text
  , auditCreatedAt  :: UTCTime
  } deriving (Show, Eq, Generic)

instance ToJSON AuditEntry where
  toEncoding = genericToEncoding (prefixOpts "audit")
  toJSON = genericToJSON (prefixOpts "audit")

data BulkOp = BulkAdvance | BulkAssign | BulkDelete
  deriving (Show, Eq, Generic)

instance ToJSON BulkOp where
  toJSON op = toJSON (case op of
    BulkAdvance -> "advance" :: Text
    BulkAssign  -> "assign"
    BulkDelete  -> "delete")

instance FromJSON BulkOp where
  parseJSON = withText "BulkOp" $ \t -> case t of
    "advance" -> pure BulkAdvance
    "assign"  -> pure BulkAssign
    "delete"  -> pure BulkDelete
    _         -> fail ("unknown bulk op: " <> show t)

data BulkRequest = BulkRequest
  { brOp           :: BulkOp
  , brIds          :: [Int]
  , brConsultantId :: Maybe Int
  } deriving (Show, Eq, Generic, FromJSON)

data ImportRowError = ImportRowError
  { ireRow   :: Int    -- ^ 1-based data-row number (header excluded)
  , ireError :: Text
  } deriving (Show, Eq, Generic)

instance ToJSON ImportRowError where
  toEncoding = genericToEncoding (prefixOpts "ire")
  toJSON = genericToJSON (prefixOpts "ire")

data ImportResult = ImportResult
  { imrImported :: Int
  , imrFailed   :: [ImportRowError]
  } deriving (Show, Eq, Generic)

instance ToJSON ImportResult where
  toEncoding = genericToEncoding (prefixOpts "imr")
  toJSON = genericToJSON (prefixOpts "imr")
