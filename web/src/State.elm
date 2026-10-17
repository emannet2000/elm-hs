module State exposing
    ( Model
    , Msg(..)
    , Route(..)
    , Toast
    , AddLeadForm
    , EditLeadForm
    , AddTaskForm
    , ClientForm
    , CaseForm
    , UserForm
    , emptyAddLead
    , emptyEditLeadFrom
    , emptyAddTask
    , emptyClientForm
    , emptyCaseForm
    , emptyUserForm
    , caseFormOf
    , editLeadOf
    , clientFormOf
    , userFormOf
    , routeOf
    , initialModel
    )

{-| Central application state and messages.
-}

import Browser
import Browser.Navigation exposing (Key)
import File exposing (File)
import Http
import Set exposing (Set)
import Url exposing (Url)
import Url.Parser as P exposing ((</>), int, s, top)

import Types exposing (..)


-- ---------- routing ----------


type Route
    = Dashboard
    | LeadsPage
    | LeadDetailPage Int
    | ClientsPage
    | ClientDetailPage Int
    | TasksPage
    | UsersPage
    | AuditPage
    | OperationsPage


routeParser : P.Parser (Route -> a) a
routeParser =
    P.oneOf
        [ P.map Dashboard top
        , P.map LeadsPage (s "leads")
        , P.map LeadDetailPage (s "leads" </> int)
        , P.map ClientsPage (s "clients")
        , P.map ClientDetailPage (s "clients" </> int)
        , P.map TasksPage (s "tasks")
        , P.map UsersPage (s "users")
        , P.map AuditPage (s "audit")
        , P.map OperationsPage (s "workflow")
        ]


routeOf : Url -> Route
routeOf url =
    Maybe.withDefault Dashboard (P.parse routeParser url)



-- ---------- forms & ui state ----------


type alias AddLeadForm =
    { fullName : String
    , email : String
    , phone : String
    , source : String
    , quality : String
    , stage : String
    , destination : String
    , service : String
    , notes : String
    , nextFollowup : String
    }


emptyAddLead : AddLeadForm
emptyAddLead =
    { fullName = ""
    , email = ""
    , phone = ""
    , source = "Website"
    , quality = "Warm"
    , stage = "New Lead"
    , destination = "Canada"
    , service = "Student Visa"
    , notes = ""
    , nextFollowup = ""
    }


type alias EditLeadForm =
    { fullName : String
    , email : String
    , phone : String
    , source : String
    , quality : String
    , stage : String
    , destination : String
    , service : String
    , notes : String
    , lastContact : String
    , nextFollowup : String
    , consultantId : Maybe Int
    }


emptyEditLeadFrom : EditLeadForm
emptyEditLeadFrom =
    { fullName = ""
    , email = ""
    , phone = ""
    , source = "Website"
    , quality = "Warm"
    , stage = "New Lead"
    , destination = "Canada"
    , service = "Student Visa"
    , notes = ""
    , lastContact = ""
    , nextFollowup = ""
    , consultantId = Nothing
    }


editLeadOf : Lead -> EditLeadForm
editLeadOf l =
    { fullName = l.fullName
    , email = Maybe.withDefault "" l.email
    , phone = Maybe.withDefault "" l.phone
    , source = Maybe.withDefault "Website" l.source
    , quality = Maybe.withDefault "Warm" l.quality
    , stage = l.stage
    , destination = Maybe.withDefault "Canada" l.destination
    , service = Maybe.withDefault "Student Visa" l.service
    , notes = Maybe.withDefault "" l.notes
    , lastContact = Maybe.withDefault "" l.lastContact
    , nextFollowup = Maybe.withDefault "" l.nextFollowup
    , consultantId = l.consultantId
    }


type alias AddTaskForm =
    { leadId : String
    , title : String
    , description : String
    , dueDate : String
    , priority : String
    }


emptyAddTask : AddTaskForm
emptyAddTask =
    { leadId = "", title = "", description = "", dueDate = "", priority = "Medium" }


type alias ClientForm =
    { fullName : String
    , email : String
    , phone : String
    , officerId : String
    }


emptyClientForm : ClientForm
emptyClientForm =
    { fullName = "", email = "", phone = "", officerId = "" }


clientFormOf : Client -> ClientForm
clientFormOf c =
    { fullName = c.fullName
    , email = Maybe.withDefault "" c.email
    , phone = Maybe.withDefault "" c.phone
    , officerId = Maybe.map String.fromInt c.caseOfficerId |> Maybe.withDefault ""
    }


type alias CaseForm =
    { caseId : Maybe Int
    , category : String
    , destination : String
    , stage : String
    , deadline : String
    }


{-| Create \/ edit form for the admin Users page.  @userId == Nothing@ means
"create"; on edit an empty password keeps the current one.
-}
type alias UserForm =
    { userId : Maybe Int
    , name : String
    , email : String
    , role : String
    , password : String
    }


emptyUserForm : UserForm
emptyUserForm =
    { userId = Nothing, name = "", email = "", role = "consultant", password = "" }


userFormOf : User -> UserForm
userFormOf u =
    { userId = Just u.id
    , name = u.name
    , email = u.email
    , role = u.role
    , password = ""
    }


emptyCaseForm : CaseForm
emptyCaseForm =
    { caseId = Nothing, category = "Student Visa", destination = "Canada"
    , stage = "Documents Under Review", deadline = ""
    }


caseFormOf : CaseRow -> CaseForm
caseFormOf cr =
    { caseId = Just cr.id
    , category = Maybe.withDefault "Student Visa" cr.category
    , destination = Maybe.withDefault "Canada" cr.destination
    , stage = cr.stage
    , deadline = Maybe.withDefault "" cr.deadline
    }


type alias Toast =
    { id : Int, kind : String, msg : String }



-- ---------- model ----------


type alias Model =
    { key : Key
    , url : Url
    , apiBase : String
    , token : Maybe String
    , user : Maybe User
    , authChecked : Bool
    , darkMode : Bool

    -- login form
    , loginEmail : String
    , loginPassword : String
    , loginError : String

    -- data caches
    , stats : Maybe Stats
    , leads : List Lead
    , leadsTotal : Int
    , leadsLimit : Int
    , leadsOffset : Int
    , users : List User
    , tasks : List Task
    , clients : List Client
    , clientsTotal : Int
    , clientsLimit : Int
    , clientsOffset : Int
    , searchSeq : Int
    , clientDetail : Maybe ClientDetail
    , detail : Maybe LeadDetail

    -- leads filters / selection
    , q : String
    , fStage : String
    , fQuality : String
    , fSource : String
    , sortBy : String
    , sortAsc : Bool
    , selected : Set Int

    -- modals & forms
    , showAddLead : Bool
    , addLead : AddLeadForm
    , editLeadOpen : Bool
    , editLead : EditLeadForm
    , noteDraft : String
    , addTask : AddTaskForm
    , showGlobalAddTask : Bool

    , clientQ : String
    , showClientForm : Bool
    , clientEditingId : Maybe Int
    , clientForm : ClientForm

    , caseForm : Maybe CaseForm

    -- users / account
    , showUserForm : Bool
    , userForm : UserForm
    , showPwModal : Bool
    , pwCurrent : String
    , pwNew : String
    , pwConfirm : String

    -- audit trail
    , audit : List AuditEntry

    -- document upload
    , pendingDoc : Maybe File

    -- csv import (leads)
    , pendingImport : Maybe File

    -- chrome
    , notifOpen : Bool
    , toasts : List Toast
    , toastSeq : Int
    , today : String
    }


initialModel : Key -> Url -> Model
initialModel key url =
    { key = key
    , url = url
    , apiBase = ""
    , token = Nothing
    , user = Nothing
    , authChecked = False
    , darkMode = False
    , loginEmail = ""
    , loginPassword = ""
    , loginError = ""

    , stats = Nothing
    , leads = []
    , leadsTotal = 0
    , leadsLimit = 25
    , leadsOffset = 0
    , users = []
    , tasks = []
    , clients = []
    , clientsTotal = 0
    , clientsLimit = 25
    , clientsOffset = 0
    , searchSeq = 0
    , clientDetail = Nothing
    , detail = Nothing

    , q = ""
    , fStage = "All"
    , fQuality = "All"
    , fSource = "All"
    , sortBy = "name"
    , sortAsc = True
    , selected = Set.empty

    , showAddLead = False
    , addLead = emptyAddLead
    , editLeadOpen = False
    , editLead = emptyEditLeadFrom
    , noteDraft = ""
    , addTask = emptyAddTask
    , showGlobalAddTask = False

    , clientQ = ""
    , showClientForm = False
    , clientEditingId = Nothing
    , clientForm = emptyClientForm

    , caseForm = Nothing

    , showUserForm = False
    , userForm = emptyUserForm
    , showPwModal = False
    , pwCurrent = ""
    , pwNew = ""
    , pwConfirm = ""

    , audit = []

    , pendingDoc = Nothing

    , pendingImport = Nothing

    , notifOpen = False
    , toasts = []
    , toastSeq = 0
    , today = ""
    }



-- ---------- messages ----------


type Msg
    = NoOp
    | LinkClicked Browser.UrlRequest
    | UrlChanged Url
    | GotStoredToken (Maybe String)
    | GotStoredDark Bool
    | ToggleDarkMode
      -- auth
    | LoginEmailChanged String
    | LoginPasswordChanged String
    | LoginClicked
    | LoginDone (Result Http.Error LoginResponse)
    | MeDone (Result Http.Error User)
    | LogoutClicked
      -- data loads
    | LeadsPageLoaded (Result Http.Error LeadPage)
    | UsersLoaded (Result Http.Error (List User))
    | TasksLoaded (Result Http.Error (List Task))
    | ClientsPageLoaded (Result Http.Error ClientPage)
    | ClientDetailLoaded (Result Http.Error ClientDetail)
    | DetailLoaded (Result Http.Error LeadDetail)
    | StatsLoaded (Result Http.Error Stats)
    | AuditLoaded (Result Http.Error (List AuditEntry))
      -- paging
    | LeadsOffsetChanged Int
    | ClientsOffsetChanged Int
    | LeadsSearchSettled Int
    | ClientsSearchSettled Int
      -- lead CRUD
    | OpenAddLead
    | CloseAddLead
    | UpdateAddLead (AddLeadForm -> AddLeadForm)
    | SubmitAddLead
    | AddLeadDone (Result Http.Error Lead)
    | EditLeadToggled
    | UpdateEditLead (EditLeadForm -> EditLeadForm)
    | SubmitEditLead
    | EditLeadDone (Result Http.Error Lead)
    | DeleteLeadConfirmed Int
    | DeleteLeadDone (Result Http.Error ())
    | AdvanceClicked Int
    | AdvanceDone (Result Http.Error Lead)
    | ConvertClicked Int
    | ConvertDone (Result Http.Error Client)
    | NoteDraftChanged String
    | NoteSubmitted Int
    | NoteDone (Result Http.Error ())
      -- filters / bulk
    | SearchChanged String
    | StageFilterChanged String
    | QualityFilterChanged String
    | SourceFilterChanged String
    | SortByChanged String
    | SortDirToggled
    | ClearFilters
    | RowChecked Int Bool
    | SelectAllChecked Bool
    | BulkAdvanceClicked
    | BulkAssignPicked String
    | BulkDeleteClicked
    | BulkDone (Result Http.Error ())
      -- tasks
    | TaskStatusPicked Int String
    | TaskStatusDone (Result Http.Error ())
    | TaskDeleted Int
    | TaskDeleteDone (Result Http.Error ())
    | ToggleGlobalAddTask
    | UpdateAddTask (AddTaskForm -> AddTaskForm)
    | SubmitAddTaskFor Int
    | SubmitAddTaskGlobal
    | AddTaskDone (Result Http.Error Task)
      -- clients
    | ClientSearchChanged String
    | OpenAddClient
    | CloseClientForm
    | UpdateClientForm (ClientForm -> ClientForm)
    | SubmitClientForm
    | ClientFormSaved (Result Http.Error Client)
    | ClientUpdated (Result Http.Error ())
    | DeleteClientConfirmed Int
    | DeleteClientDone (Result Http.Error ())
    | OpenCaseForm (Maybe CaseRow)
    | CloseCaseForm
    | UpdateCaseForm (CaseForm -> CaseForm)
    | SubmitCaseForm Int
    | CaseFormSaved (Result Http.Error ClientDetail)
    | DeleteCaseClicked Int
    | DeleteCaseDone (Result Http.Error ())
      -- documents
    | DocPicked File
    | DocCleared
    | UploadLeadDocClicked Int
    | UploadClientDocClicked Int
    | LeadDocUploaded (Result Http.Error LeadDetail)
    | ClientDocUploaded (Result Http.Error ClientDetail)
    | DocDeleted Int
    | DocDeleteDone (Result Http.Error ())
      -- csv import (leads)
    | ImportFilePicked File
    | LeadImportClicked
    | LeadsImported (Result Http.Error ImportResult)
      -- users / account
    | OpenAddUser
    | OpenUserEditor Int
    | CloseUserForm
    | UpdateUserForm (UserForm -> UserForm)
    | SubmitUserForm
    | UserSaved (Result Http.Error User)
    | UserUpdatedDone (Result Http.Error ())
    | DeleteUserConfirmed Int
    | DeleteUserDone (Result Http.Error ())
    | TogglePwModal
    | PwCurrentChanged String
    | PwNewChanged String
    | PwConfirmChanged String
    | SubmitPasswordChange
    | PasswordChangeDone (Result Http.Error ())
      -- chrome
    | NotifBellClicked
    | NavigateTo String
    | TodayChanged String
    | OpenClientEditor Int
    | ToastPushed String String
    | ToastExpired Int
