port module Main exposing (main)

{-| ECC CRM — Elm frontend entry point.

Routing, authentication flow, data loading, and the update loop live here;
page markup lives in Views.elm.
-}

import Browser
import Browser.Navigation as Nav
import Date
import Html exposing (Html, a, button, div, span, strong, text, aside, nav, img, iframe, h2)
import Html.Attributes exposing (class, href, src, alt, title, style, attribute)
import Html.Events exposing (onClick)
import Http
import Json.Encode as E
import Process
import Task
import Time
import Url
import Url exposing (Url)
import Set exposing (Set)

import Api
import State exposing (..)
import Types
import Ui
import Views


main : Program () Model Msg
main =
    Browser.application
        { init = init
        , view = view
        , update = update
        , subscriptions = subscriptions
        , onUrlRequest = LinkClicked
        , onUrlChange = UrlChanged
        }



-- ---------- ports ----------


port saveToken : Maybe String -> Cmd msg
port loadToken : (Maybe String -> msg) -> Sub msg
port saveDark : Bool -> Cmd msg
port loadDark : (Bool -> msg) -> Sub msg



-- ---------- init ----------


init : () -> Url -> Nav.Key -> ( Model, Cmd Msg )
init _ url key =
    let
        proto =
            case url.protocol of
                Url.Http ->
                    "http"

                Url.Https ->
                    "https"

        base =
            Api.computeBase { protocol = proto, host = url.host, port_ = url.port_ }
    in
    ( State.initialModel key url |> (\m -> { m | apiBase = base })
    , Cmd.batch
        [ Task.perform (TodayChanged << toIsoDay) Time.now ]
    )


toIsoDay : Time.Posix -> String
toIsoDay posix =
    Date.toIsoString (Date.fromPosix Time.utc posix)


-- ---------- routing helpers ----------


routeCmd : Model -> Route -> Cmd Msg
routeCmd model route =
    let
        ctx =
            { base = model.apiBase, token = model.token }
    in
    case route of
        Dashboard ->
            Api.fetchStats ctx StatsLoaded

        LeadsPage ->
            Cmd.batch
                [ leadsCmd model
                , Api.fetchUsers ctx UsersLoaded
                ]

        LeadDetailPage id ->
            Cmd.batch
                [ Api.fetchLeadDetail ctx id DetailLoaded
                , Api.fetchUsers ctx UsersLoaded
                ]

        ClientsPage ->
            Cmd.batch
                [ clientsCmd model
                , Api.fetchUsers ctx UsersLoaded
                ]

        ClientDetailPage id ->
            Cmd.batch
                [ Api.fetchClientDetail ctx id ClientDetailLoaded
                , Api.fetchUsers ctx UsersLoaded
                ]

        TasksPage ->
            -- the global "add task" picker needs a lead list to choose from
            Cmd.batch
                [ Api.fetchTasks ctx TasksLoaded
                , leadsCmdWith model 500 0
                ]

        UsersPage ->
            Api.fetchUsers ctx UsersLoaded

        AuditPage ->
            Api.fetchAudit ctx 200 AuditLoaded

        OperationsPage ->
            Cmd.none


{-| Fetch the leads page described by the model's current filters, sort and
offset.  Filtering/sorting/paging are done by the API.
-}
leadsCmd : Model -> Cmd Msg
leadsCmd model =
    leadsCmdWith model model.leadsLimit model.leadsOffset


leadsCmdWith : Model -> Int -> Int -> Cmd Msg
leadsCmdWith model limit offset =
    Api.fetchLeadPage
        { base = model.apiBase, token = model.token }
        { q = model.q
        , stage = model.fStage
        , quality = model.fQuality
        , source = model.fSource
        , sort = model.sortBy
        , dir =
            if model.sortAsc then
                "asc"

            else
                "desc"
        , limit = limit
        , offset = offset
        }
        LeadsPageLoaded


clientsCmd : Model -> Cmd Msg
clientsCmd model =
    Api.fetchClientPage
        { base = model.apiBase, token = model.token }
        { q = model.clientQ
        , limit = model.clientsLimit
        , offset = model.clientsOffset
        }
        ClientsPageLoaded



-- ---------- update ----------


update : Msg -> Model -> ( Model, Cmd Msg )
update msg model =
    let
        ctx =
            { base = model.apiBase, token = model.token }
    in
    case msg of
        NoOp ->
            ( model, Cmd.none )

        LinkClicked request ->
            case request of
                Browser.Internal url ->
                    ( model, Nav.pushUrl model.key (Url.toString url) )

                Browser.External href ->
                    ( model, Nav.load href )

        UrlChanged url ->
            ( { model
                | url = url
                , notifOpen = False
                , detail = Nothing
                , clientDetail = Nothing
                , pendingDoc = Nothing
                , pendingImport = Nothing
              }
            , if model.user == Nothing then
                Cmd.none

              else
                routeCmd model (State.routeOf url)
            )

        GotStoredToken t ->
            if t == Nothing then
                ( { model | authChecked = True }, Cmd.none )

            else
                ( { model | token = t }, Api.me { base = model.apiBase, token = t } MeDone )

        GotStoredDark flag ->
            ( { model | darkMode = flag }, Cmd.none )

        ToggleDarkMode ->
            let
                newFlag =
                    not model.darkMode
            in
            ( { model | darkMode = newFlag }, saveDark newFlag )

        TodayChanged iso ->
            ( { model | today = iso }, Cmd.none )

        -- ----- auth -----
        LoginEmailChanged v ->
            ( { model | loginEmail = v, loginError = "" }, Cmd.none )

        LoginPasswordChanged v ->
            ( { model | loginPassword = v, loginError = "" }, Cmd.none )

        LoginClicked ->
            ( model
            , Api.login ctx model.loginEmail model.loginPassword LoginDone
            )

        LoginDone (Ok resp) ->
            ( { model
                | token = Just resp.token
                , user = Just resp.user
                , loginError = ""
              }
            , Cmd.batch
                [ saveToken (Just resp.token)
                , toast "success" ("Welcome back, " ++ resp.user.name)
                , routeCmd { model | token = Just resp.token } (State.routeOf model.url)
                ]
            )

        LoginDone (Err e) ->
            ( { model | loginError = httpError e }, Cmd.none )

        MeDone (Ok u) ->
            ( { model | user = Just u, authChecked = True }
            , routeCmd model (State.routeOf model.url)
            )

        MeDone (Err e) ->
            ( { model | user = Nothing, authChecked = True, token = Nothing }
            , saveToken Nothing
            )

        LogoutClicked ->
            ( { model | user = Nothing, token = Nothing, authChecked = False }
            , Cmd.batch [ saveToken Nothing, Nav.pushUrl model.key "/" ]
            )

        -- ----- data loads -----
        LeadsPageLoaded result ->
            ( { model
                | leads = Result.withDefault model.leads (Result.map .items result)
                , leadsTotal = Result.withDefault model.leadsTotal (Result.map .total result)
              }
            , toastResultError result
            )

        UsersLoaded result ->
            ( { model | users = Result.withDefault model.users result }, Cmd.none )

        TasksLoaded result ->
            ( { model | tasks = Result.withDefault model.tasks result }, Cmd.none )

        ClientsPageLoaded result ->
            ( { model
                | clients = Result.withDefault model.clients (Result.map .items result)
                , clientsTotal = Result.withDefault model.clientsTotal (Result.map .total result)
              }
            , toastResultError result
            )

        ClientDetailLoaded result ->
            ( { model | clientDetail = justOf result }, Cmd.none )

        DetailLoaded result ->
            ( { model | detail = justOf result }, Cmd.none )

        StatsLoaded result ->
            ( { model | stats = justOf result }, Cmd.none )

        AuditLoaded result ->
            ( { model | audit = Result.withDefault model.audit result }
            , Cmd.none
            )

        -- ----- lead CRUD -----
        OpenAddLead ->
            ( { model | showAddLead = True, addLead = State.emptyAddLead }, Cmd.none )

        CloseAddLead ->
            ( { model | showAddLead = False }, Cmd.none )

        UpdateAddLead f ->
            ( { model | addLead = f model.addLead }, Cmd.none )

        SubmitAddLead ->
            ( model
            , Api.createLead ctx (Types.encodeNewLead model.addLead) AddLeadDone
            )

        AddLeadDone (Ok lead) ->
            ( { model
                | showAddLead = False
                , leads = lead :: model.leads
                , leadsTotal = model.leadsTotal + 1
              }
            , Cmd.batch
                [ toast "success" ("Lead " ++ lead.number ++ " created")
                , navigateTo model.key "/leads"
                ]
            )

        AddLeadDone (Err e) ->
            ( model, toast "error" (httpError e) )

        EditLeadToggled ->
            case model.detail of
                Nothing ->
                    ( model, Cmd.none )

                Just d ->
                    ( { model
                        | editLeadOpen = not model.editLeadOpen
                        , editLead = State.editLeadOf d.lead
                      }
                    , Cmd.none
                    )

        UpdateEditLead f ->
            ( { model | editLead = f model.editLead }, Cmd.none )

        SubmitEditLead ->
            case model.detail of
                Nothing ->
                    ( model, Cmd.none )

                Just d ->
                    ( model
                    , Api.updateLead ctx d.lead.id (Types.encodeUpdateLead model.editLead) EditLeadDone
                    )

        EditLeadDone (Ok lead) ->
            ( { model | editLeadOpen = False }
            , Cmd.batch
                [ toast "success" "Lead updated"
                  -- refresh detail + list quietly
                , reloadCurrent model
                ]
            )

        EditLeadDone (Err e) ->
            ( model, toast "error" (httpError e) )

        DeleteLeadConfirmed id ->
            ( model, Api.deleteLead ctx id DeleteLeadDone )

        DeleteLeadDone (Ok _) ->
            ( model
            , Cmd.batch [ toast "success" "Lead deleted", navigateTo model.key "/leads" ]
            )

        DeleteLeadDone (Err e) ->
            ( model, toast "error" (httpError e) )

        AdvanceClicked id ->
            ( model, Api.advanceLead ctx id AdvanceDone )

        AdvanceDone (Ok lead) ->
            ( model
            , Cmd.batch
                [ toast "success" ("Advanced to " ++ lead.stage)
                , reloadCurrent model
                ]
            )

        AdvanceDone (Err e) ->
            ( model, toast "error" (httpError e) )

        ConvertClicked id ->
            ( model, Api.convertLead ctx id ConvertDone )

        ConvertDone (Ok client) ->
            ( model
            , Cmd.batch
                [ toast "success" ("Converted to client " ++ client.number)
                , navigateTo model.key ("/clients/" ++ String.fromInt client.id)
                ]
            )

        ConvertDone (Err e) ->
            ( model, toast "error" (httpError e) )

        NoteDraftChanged v ->
            ( { model | noteDraft = v }, Cmd.none )

        NoteSubmitted id ->
            if String.trim model.noteDraft == "" then
                ( model, Cmd.none )

            else
                ( model, Api.addNote ctx id model.noteDraft NoteDone )

        NoteDone (Ok _) ->
            ( { model | noteDraft = "" }
            , Cmd.batch [ toast "success" "Note added", reloadCurrent model ]
            )

        NoteDone (Err e) ->
            ( model, toast "error" (httpError e) )

        -- ----- filters / bulk -----
        SearchChanged v ->
            let
                seq =
                    model.searchSeq + 1

                m2 =
                    { model | q = v, leadsOffset = 0, searchSeq = seq }
            in
            ( m2
            , Task.perform (\_ -> LeadsSearchSettled seq) (Process.sleep 300)
            )

        StageFilterChanged v ->
            let
                m2 =
                    { model | fStage = v, leadsOffset = 0, selected = Set.empty }
            in
            ( m2, leadsCmd m2 )

        QualityFilterChanged v ->
            let
                m2 =
                    { model | fQuality = v, leadsOffset = 0, selected = Set.empty }
            in
            ( m2, leadsCmd m2 )

        SourceFilterChanged v ->
            let
                m2 =
                    { model | fSource = v, leadsOffset = 0, selected = Set.empty }
            in
            ( m2, leadsCmd m2 )

        SortByChanged v ->
            let
                m2 =
                    { model | sortBy = v, leadsOffset = 0 }
            in
            ( m2, leadsCmd m2 )

        SortDirToggled ->
            let
                m2 =
                    { model | sortAsc = not model.sortAsc, leadsOffset = 0 }
            in
            ( m2, leadsCmd m2 )

        ClearFilters ->
            let
                m2 =
                    { model
                        | q = ""
                        , fStage = "All"
                        , fQuality = "All"
                        , fSource = "All"
                        , leadsOffset = 0
                        , selected = Set.empty
                    }
            in
            ( m2, leadsCmd m2 )

        -- ----- paging -----
        LeadsOffsetChanged off ->
            let
                m2 =
                    { model | leadsOffset = max 0 off }
            in
            ( m2, leadsCmd m2 )

        ClientsOffsetChanged off ->
            let
                m2 =
                    { model | clientsOffset = max 0 off }
            in
            ( m2, clientsCmd m2 )

        LeadsSearchSettled seq ->
            if seq == model.searchSeq then
                ( model, leadsCmd model )

            else
                ( model, Cmd.none )

        ClientsSearchSettled seq ->
            if seq == model.searchSeq then
                ( model, clientsCmd model )

            else
                ( model, Cmd.none )

        RowChecked id flag ->
            ( { model
                | selected =
                    if flag then
                        Set.insert id model.selected

                    else
                        Set.remove id model.selected
              }
            , Cmd.none
            )

        SelectAllChecked flag ->
            ( { model
                | selected =
                    if flag then
                        Set.fromList (List.map .id (Views.visibleLeads model))

                    else
                        Set.empty
              }
            , Cmd.none
            )

        BulkAdvanceClicked ->
            ( model
            , Api.bulkLeads ctx
                { op = "advance", ids = Set.toList model.selected, consultantId = Nothing }
                BulkDone
            )

        BulkAssignPicked userIdStr ->
            case String.toInt userIdStr of
                Nothing ->
                    ( model, Cmd.none )

                Just uid ->
                    ( model
                    , Api.bulkLeads ctx
                        { op = "assign", ids = Set.toList model.selected, consultantId = Just uid }
                        BulkDone
                    )

        BulkDeleteClicked ->
            ( model
            , Api.bulkLeads ctx
                { op = "delete", ids = Set.toList model.selected, consultantId = Nothing }
                BulkDone
            )

        BulkDone (Ok _) ->
            ( { model | selected = Set.empty }
            , Cmd.batch [ toast "success" "Bulk action applied", reloadCurrent model ]
            )

        BulkDone (Err e) ->
            ( model, toast "error" (httpError e) )

        -- ----- tasks -----
        TaskStatusPicked id status ->
            ( model, Api.setTaskStatus ctx id status TaskStatusDone )

        TaskStatusDone (Ok _) ->
            ( model, Cmd.batch [ toast "success" "Task updated", reloadCurrent model ] )

        TaskStatusDone (Err e) ->
            ( model, toast "error" (httpError e) )

        TaskDeleted id ->
            ( model, Api.deleteTask ctx id TaskDeleteDone )

        TaskDeleteDone (Ok _) ->
            ( model, Cmd.batch [ toast "success" "Task deleted", reloadCurrent model ] )

        TaskDeleteDone (Err e) ->
            ( model, toast "error" (httpError e) )

        ToggleGlobalAddTask ->
            ( { model
                | showGlobalAddTask = not model.showGlobalAddTask
                , addTask = State.emptyAddTask
              }
            , Cmd.none
            )

        UpdateAddTask f ->
            ( { model | addTask = f model.addTask }, Cmd.none )

        SubmitAddTaskFor leadId ->
            submitTask model ctx leadId

        SubmitAddTaskGlobal ->
            case String.toInt model.addTask.leadId of
                Nothing ->
                    ( model, toast "error" "Pick a lead first" )

                Just leadId ->
                    submitTask model ctx leadId

        AddTaskDone (Ok task) ->
            ( { model | showGlobalAddTask = False, addTask = State.emptyAddTask }
            , Cmd.batch
                [ toast "success" "Task created"
                , reloadCurrent model
                ]
            )

        AddTaskDone (Err e) ->
            ( model, toast "error" (httpError e) )

        -- ----- clients -----
        ClientSearchChanged v ->
            let
                seq =
                    model.searchSeq + 1

                m2 =
                    { model | clientQ = v, clientsOffset = 0, searchSeq = seq }
            in
            ( m2
            , Task.perform (\_ -> ClientsSearchSettled seq) (Process.sleep 300)
            )

        OpenAddClient ->
            ( { model
                | showClientForm = True
                , clientEditingId = Nothing
                , clientForm = State.emptyClientForm
              }
            , Cmd.none
            )

        OpenClientEditor _ ->
            case model.clientDetail of
                Nothing ->
                    ( model, Cmd.none )

                Just cd ->
                    ( { model
                        | showClientForm = True
                        , clientEditingId = Just cd.client.id
                        , clientForm = State.clientFormOf cd.client
                      }
                    , Cmd.none
                    )

        CloseClientForm ->
            ( { model | showClientForm = False }, Cmd.none )

        UpdateClientForm f ->
            ( { model | clientForm = f model.clientForm }, Cmd.none )

        SubmitClientForm ->
            case model.clientEditingId of
                Just cid ->
                    ( model
                    , Api.updateClient ctx cid (clientPayload model) ClientUpdated
                    )

                Nothing ->
                    ( model
                    , Api.createClient ctx (clientPayload model) ClientFormSaved
                    )

        ClientUpdated (Ok _) ->
            ( { model | showClientForm = False }
            , Cmd.batch [ toast "success" "Client saved", reloadCurrent model ]
            )

        ClientUpdated (Err e) ->
            ( model, toast "error" (httpError e) )

        ClientFormSaved (Ok _) ->
            ( { model | showClientForm = False }
            , Cmd.batch [ toast "success" "Client saved", reloadCurrent model ]
            )

        ClientFormSaved (Err e) ->
            ( model, toast "error" (httpError e) )

        DeleteClientConfirmed id ->
            ( model
            , Api.deleteClient ctx id DeleteClientDone
            )

        DeleteClientDone (Ok _) ->
            ( model
            , Cmd.batch [ toast "success" "Client deleted", navigateTo model.key "/clients" ]
            )

        DeleteClientDone (Err e) ->
            ( model, toast "error" (httpError e) )

        OpenCaseForm mcase ->
            ( { model
                | caseForm =
                    Just
                        (Maybe.map State.caseFormOf mcase
                            |> Maybe.withDefault State.emptyCaseForm
                        )
              }
            , Cmd.none
            )

        CloseCaseForm ->
            ( { model | caseForm = Nothing }, Cmd.none )

        UpdateCaseForm f ->
            ( { model | caseForm = Maybe.map f model.caseForm }, Cmd.none )

        SubmitCaseForm clientId ->
            case model.caseForm of
                Nothing ->
                    ( model, Cmd.none )

                Just cf ->
                    ( model
                    , Api.upsertCase ctx clientId
                        (Types.encodeCaseInput
                            { category = cf.category
                            , destination = cf.destination
                            , stage = cf.stage
                            , deadline = cf.deadline
                            , caseId = cf.caseId
                            }
                        )
                        CaseFormSaved
                    )

        CaseFormSaved (Ok cd) ->
            ( { model | caseForm = Nothing, clientDetail = Just cd }
            , toast "success" "Case saved"
            )

        CaseFormSaved (Err e) ->
            ( model, toast "error" (httpError e) )

        DeleteCaseClicked caseId ->
            ( model, Api.deleteCase ctx caseId DeleteCaseDone )

        DeleteCaseDone (Ok _) ->
            ( model, Cmd.batch [ toast "success" "Case deleted", reloadCurrent model ] )

        DeleteCaseDone (Err e) ->
            ( model, toast "error" (httpError e) )

        -- ----- documents -----
        DocPicked file ->
            ( { model | pendingDoc = Just file }, Cmd.none )

        DocCleared ->
            ( { model | pendingDoc = Nothing }, Cmd.none )

        UploadLeadDocClicked id ->
            case model.pendingDoc of
                Nothing ->
                    ( model, toast "error" "Choose a file first" )

                Just file ->
                    ( model, Api.uploadLeadDocument ctx id file LeadDocUploaded )

        UploadClientDocClicked id ->
            case model.pendingDoc of
                Nothing ->
                    ( model, toast "error" "Choose a file first" )

                Just file ->
                    ( model, Api.uploadClientDocument ctx id file ClientDocUploaded )

        LeadDocUploaded (Ok detail) ->
            ( { model | detail = Just detail, pendingDoc = Nothing }
            , toast "success" "Document uploaded"
            )

        LeadDocUploaded (Err e) ->
            ( model, toast "error" (httpError e) )

        ClientDocUploaded (Ok cd) ->
            ( { model | clientDetail = Just cd, pendingDoc = Nothing }
            , toast "success" "Document uploaded"
            )

        ClientDocUploaded (Err e) ->
            ( model, toast "error" (httpError e) )

        DocDeleted id ->
            ( model, Api.deleteDocument ctx id DocDeleteDone )

        DocDeleteDone (Ok _) ->
            ( model
            , Cmd.batch [ toast "success" "Document deleted", reloadCurrent model ]
            )

        DocDeleteDone (Err e) ->
            ( model, toast "error" (httpError e) )

        -- ----- csv import -----
        ImportFilePicked file ->
            ( { model | pendingImport = Just file }, Cmd.none )

        LeadImportClicked ->
            case model.pendingImport of
                Nothing ->
                    ( model, toast "error" "Choose a CSV file first" )

                Just file ->
                    ( model, Api.importLeads ctx file LeadsImported )

        LeadsImported (Ok res) ->
            let
                failCount =
                    List.length res.failed

                failureSummary =
                    res.failed
                        |> List.take 3
                        |> List.map (\fe -> "row " ++ String.fromInt fe.row ++ ": " ++ fe.error)
                        |> String.join "; "

                failToast =
                    if failCount == 0 then
                        Cmd.none

                    else
                        toast "error"
                            ("Rows failed ("
                                ++ String.fromInt failCount
                                ++ ") — "
                                ++ failureSummary
                            )
            in
            ( { model | pendingImport = Nothing }
            , Cmd.batch
                [ toast "success"
                    ("Imported "
                        ++ String.fromInt res.imported
                        ++ " lead"
                        ++ (if res.imported == 1 then
                                ""

                            else
                                "s"
                           )
                    )
                , failToast
                , reloadCurrent model
                ]
            )

        LeadsImported (Err e) ->
            ( model, toast "error" (httpError e) )

        -- ----- users / account -----
        OpenAddUser ->
            ( { model | showUserForm = True, userForm = State.emptyUserForm }
            , Cmd.none
            )

        OpenUserEditor uid ->
            case List.filter (\u -> u.id == uid) model.users of
                (u :: _) ->
                    ( { model | showUserForm = True, userForm = State.userFormOf u }
                    , Cmd.none
                    )

                [] ->
                    ( model, Cmd.none )

        CloseUserForm ->
            ( { model | showUserForm = False }, Cmd.none )

        UpdateUserForm f ->
            ( { model | userForm = f model.userForm }, Cmd.none )

        SubmitUserForm ->
            let
                f =
                    model.userForm
            in
            case f.userId of
                Nothing ->
                    if String.length f.password < 8 then
                        ( model, toast "error" "Password must be at least 8 characters" )

                    else
                        ( model
                        , Api.createUser ctx
                            (Types.encodeNewUser
                                { name = f.name
                                , email = f.email
                                , role = f.role
                                , password = f.password
                                }
                            )
                            UserSaved
                        )

                Just uid ->
                    ( model
                    , Api.updateUser ctx uid
                        (Types.encodeUpdateUser
                            { name = f.name
                            , role = f.role
                            , password = f.password
                            }
                        )
                        UserUpdatedDone
                    )

        UserSaved (Ok u) ->
            ( { model | showUserForm = False, users = model.users ++ [ u ] }
            , Cmd.batch [ toast "success" ("User " ++ u.name ++ " created"), reloadCurrent model ]
            )

        UserSaved (Err e) ->
            ( model, toast "error" (httpError e) )

        UserUpdatedDone (Ok _) ->
            ( { model | showUserForm = False }
            , Cmd.batch [ toast "success" "User saved", reloadCurrent model ]
            )

        UserUpdatedDone (Err e) ->
            ( model, toast "error" (httpError e) )

        DeleteUserConfirmed uid ->
            ( model, Api.deleteUser ctx uid DeleteUserDone )

        DeleteUserDone (Ok _) ->
            ( model
            , Cmd.batch [ toast "success" "User deleted", reloadCurrent model ]
            )

        DeleteUserDone (Err e) ->
            ( model, toast "error" (httpError e) )

        TogglePwModal ->
            ( { model
                | showPwModal = not model.showPwModal
                , pwCurrent = ""
                , pwNew = ""
                , pwConfirm = ""
              }
            , Cmd.none
            )

        PwCurrentChanged v ->
            ( { model | pwCurrent = v }, Cmd.none )

        PwNewChanged v ->
            ( { model | pwNew = v }, Cmd.none )

        PwConfirmChanged v ->
            ( { model | pwConfirm = v }, Cmd.none )

        SubmitPasswordChange ->
            let
                validationError =
                    if String.length model.pwNew < 8 then
                        "New password must be at least 8 characters"

                    else if model.pwNew /= model.pwConfirm then
                        "Passwords do not match"

                    else
                        ""
            in
            if validationError /= "" then
                ( model, toast "error" validationError )

            else
                ( model
                , Api.changePassword ctx model.pwCurrent model.pwNew PasswordChangeDone
                )

        PasswordChangeDone (Ok _) ->
            ( { model
                | showPwModal = False
                , pwCurrent = ""
                , pwNew = ""
                , pwConfirm = ""
              }
            , toast "success" "Password updated"
            )

        PasswordChangeDone (Err e) ->
            ( model, toast "error" (httpError e) )

        -- ----- chrome -----
        NotifBellClicked ->
            ( { model | notifOpen = not model.notifOpen }, Cmd.none )

        NavigateTo path ->
            ( { model | notifOpen = False }, Nav.pushUrl model.key path )

        ToastPushed kind textMsg ->
            pushToast model kind textMsg

        ToastExpired id ->
            ( { model | toasts = List.filter (\t -> t.id /= id) model.toasts }
            , Cmd.none
            )



-- ---------- small helpers used by update ----------


submitTask : Model -> Api.Ctx -> Int -> ( Model, Cmd Msg )
submitTask model ctx leadId =
    if String.trim model.addTask.title == "" then
        ( model, Cmd.none )

    else
        ( model
        , Api.createTask ctx
            (Types.encodeNewTask
                { leadId = leadId
                , title = model.addTask.title
                , description = model.addTask.description
                , dueDate = model.addTask.dueDate
                , priority = model.addTask.priority
                }
            )
            AddTaskDone
        )


reloadCurrent : Model -> Cmd Msg
reloadCurrent model =
    routeCmd model (State.routeOf model.url)


clientPayload : Model -> E.Value
clientPayload model =
    Types.encodeNewClient
        { fullName = model.clientForm.fullName
        , email = model.clientForm.email
        , phone = model.clientForm.phone
        , officerId = String.toInt model.clientForm.officerId
        }


justOf : Result Http.Error a -> Maybe a
justOf r =
    Result.toMaybe r


{-| Surface a load failure as an error toast while callers keep any stale data.
-}
toastResultError : Result Http.Error a -> Cmd Msg
toastResultError result =
    case result of
        Ok _ ->
            Cmd.none

        Err e ->
            toast "error" (httpError e)


toast : String -> String -> Cmd Msg
toast kind textMsg =
    Task.perform identity
        (Task.succeed (ToastPushed kind textMsg))


pushToast : Model -> String -> String -> ( Model, Cmd Msg )
pushToast model kind textMsg =
    let
        id =
            model.toastSeq + 1

        newToast =
            { id = id, kind = kind, msg = textMsg }
    in
    ( { model | toasts = model.toasts ++ [ newToast ], toastSeq = id }
    , Task.perform (always (ToastExpired id))
        (Process.sleep 3500)
    )


httpError : Http.Error -> String
httpError err =
    case err of
        Http.BadUrl url ->
            "Bad URL: " ++ url

        Http.Timeout ->
            "Request timed out"

        Http.NetworkError ->
            "Network error — is the API running?"

        Http.BadStatus code ->
            case code of
                401 ->
                    "Not authenticated — sign in again"

                403 ->
                    "You don't have permission for that"

                404 ->
                    "Not found"

                _ ->
                    "Server error (" ++ String.fromInt code ++ ")"

        Http.BadBody body ->
            if String.startsWith "API: " body then
                String.dropLeft 5 body
            else
                "Unexpected response: " ++ String.left 80 body



-- ---------- view ----------


view : Model -> Browser.Document Msg
view model =
    { title = "ECC CRM"
    , body =
        [ div
            [ class
                (if model.darkMode then
                    (if model.user == Nothing then "app-root dark-mode" else "app-root app-shell app-shell--dark")

                 else
                    (if model.user == Nothing then "app-root" else "app-root app-shell")
                )
            ]
            (bodyView model)
        ]
    }


bodyView : Model -> List (Html Msg)
bodyView model =
    if not model.authChecked then
        [ div [ class "login-wrap" ] [ Ui.spinner ] ]

    else if model.user == Nothing then
        [ Views.loginView model ]

    else
        List.concat
            [ [ headerBar model
              , div [ class "workspace-main" ]
                    [ div [ class "topbar" ]
                        [ span [ class "workspace-breadcrumb" ] [ text "ECC / Client workspace" ]
                        , Views.notificationsDropdown model
                        , button [ class "btn btn-outline", onClick ToggleDarkMode ] [ text (if model.darkMode then "Light mode" else "Dark mode") ]
                        , button [ class "btn btn-outline", onClick TogglePwModal ] [ text "Password" ]
                        ]
                    , div [ class "container workspace-content" ] [ pageView model ]
                    ]
              ]
            , if model.showUserForm then
                [ Views.userFormModal model ]

              else
                []
            , if model.showPwModal then
                [ Views.passwordModal model ]

              else
                []
            , [ Views.toastStack model ]
            ]


pageView : Model -> Html Msg
pageView model =
    case State.routeOf model.url of
        Dashboard ->
            Views.dashboardView model

        LeadsPage ->
            Views.leadsView model

        LeadDetailPage id ->
            Views.leadDetailView model id

        ClientsPage ->
            Views.clientsView model

        ClientDetailPage id ->
            Views.clientDetailView model id

        TasksPage ->
            Views.tasksView model

        UsersPage ->
            Views.usersView model

        AuditPage ->
            Views.auditView model

        OperationsPage ->
            iframe [ src ("/operations.html?" ++ Maybe.withDefault "" model.url.query ++ (if model.darkMode then "&dark=1" else "")), title "Client workflow workspace", class "workflow-frame" ] []


headerBar : Model -> Html Msg
headerBar model =
    let
        user_ =
            Maybe.withDefault { id = 0, email = "", name = "", role = "" } model.user

        item path label =
            a
                [ class ("nav-item" ++ (if model.url.path == path then " nav-item--active" else ""))
                , href path
                , attribute "aria-current" (if model.url.path == path then "page" else "false")
                ]
                [ span [ class "nav-item__icon" ] [ text "◇" ]
                , span [ class "nav-item__label" ] [ text label ]
                ]
    in
    aside [ class "sidebar", attribute "aria-label" "Workspace navigation" ]
        [ div [ class "sidebar__brand" ]
            [ img [ class "sidebar-brand-logo", src "/icons/ecc-192.png", alt "ECC Consulting Global emblem" ] []
            , div [ class "sidebar__wordmark" ]
                [ strong [ class "sidebar__name" ] [ text "ECC" ]
                , span [ class "sidebar__product" ] [ text "Client workspace" ]
                ]
            ]
        , nav [ class "sidebar__nav" ]
            ([ item "/" "My work today"
             , item "/leads" "Leads"
             , item "/clients" "Clients & applications"
             , item "/tasks" "Tasks"
             , item "/workflow" "Workflow & billing"
             , item "/workflow?tab=reminders" "Reminder inbox"
             , item "/workflow?tab=reports" "Reports"
             ]
                ++ (if user_.role == "admin" then
                        [ item "/users" "System administration", item "/audit" "Audit history" ]
                    else []
                   )
            )
        , div [ class "sidebar__user" ]
            [ div [ class "sidebar__avatar" ] [ text (String.left 1 user_.name) ]
            , div [ class "sidebar__user-info" ]
                [ span [ class "sidebar__user-name" ] [ text user_.name ]
                , span [ class "sidebar__user-email" ] [ text user_.email ]
                ]
            ]
        , button [ class "sidebar__signout-btn", onClick LogoutClicked ] [ text "Sign out" ]
        ]


-- ---------- subscriptions ----------


subscriptions : Model -> Sub Msg
subscriptions _ =
    Sub.batch
        [ loadToken GotStoredToken
        , loadDark GotStoredDark
        ]



-- ports for JS glue (defined above; repeated imports kept minimal)


navigateTo : Nav.Key -> String -> Cmd msg
navigateTo key path =
    Nav.pushUrl key path
