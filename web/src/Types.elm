module Types exposing
    ( Activity
    , AuditEntry
    , CaseRow
    , Client
    , ClientDetail
    , Document
    , Lead
    , LeadDetail
    , Stats
    , StageCount
    , SourceCount
    , Task
    , User
    , activityDecoder
    , clientDecoder
    , clientDetailDecoder
    , documentDecoder
    , leadDecoder
    , leadDetailDecoder
    , LeadPage
    , leadPageDecoder
    , ClientPage
    , clientPageDecoder
    , statsDecoder
    , taskDecoder
    , userDecoder
    , auditDecoder
    , ImportRowError
    , ImportResult
    , importResultDecoder
    , LoginResponse
    , loginResponseDecoder
    , encodeNewClient
    , encodeCaseInput
    , encodeNewLead
    , encodeUpdateLead
    , encodeNewTask
    , encodeTaskStatus
    , encodeNote
    , encodeBulkRequest
    , encodeNewUser
    , encodeUpdateUser
    , encodePasswordChange
    , BulkSpec
    , leadStages
    , sources
    , qualities
    , destinations
    , services
    , priorities
    , taskStatuses
    , caseStages
    , roles
    )

{-| Domain entities and JSON codecs.  Field names mirror the Haskell API
exactly (see elm-hs/api/src/ECC/Models.hs).
-}

import Json.Decode as D exposing (Decoder, int, list, nullable, oneOf, string,
                                   succeed)
import Json.Decode.Pipeline exposing (custom, required)
import Json.Encode as E



-- ---------- domain constants (mirrored from the original CRM) ----------


leadStages : List String
leadStages =
    [ "New Lead"
    , "Contacted"
    , "Initial Assessment"
    , "Qualified"
    , "Consultation Booked"
    , "Proposal Sent"
    , "Converted"
    , "Closed/Lost"
    ]


sources : List String
sources =
    [ "Website", "Facebook", "Instagram", "WhatsApp", "Referring Agent"
    , "School Partner", "Walk-in", "Referral"
    ]


qualities : List String
qualities =
    [ "Hot", "Warm", "Cold" ]


destinations : List String
destinations =
    [ "Canada", "Australia", "New Zealand", "UAE", "UK", "Schengen" ]


services : List String
services =
    [ "Student Visa", "Work Visa", "Tourist Visa"
    , "Immigration Consultation", "School Admission"
    ]


priorities : List String
priorities =
    [ "Low", "Medium", "High" ]


taskStatuses : List String
taskStatuses =
    [ "Pending", "In Progress", "Done" ]


caseStages : List String
caseStages =
    [ "Documents Under Review", "Submitted", "Decision Pending", "Approved", "Rejected" ]


roles : List String
roles =
    [ "admin", "consultant", "viewer" ]



-- ---------- decoders ----------


maybeString : Decoder (Maybe String)
maybeString =
    oneOf [ D.map Just string, D.null Nothing ]


maybeInt : Decoder (Maybe Int)
maybeInt =
    oneOf [ D.map Just int, D.null Nothing ]


dateStr : Decoder String
dateStr =
    -- dates arrive as "YYYY-MM-DD"; timestamps as ISO strings — keep raw
    string


type alias User =
    { id : Int
    , email : String
    , name : String
    , role : String
    }


userDecoder : Decoder User
userDecoder =
    D.succeed User
        |> required "id" int
        |> required "email" string
        |> required "name" string
        |> required "role" string


type alias LoginResponse =
    { token : String
    , user : User
    }


loginResponseDecoder : Decoder LoginResponse
loginResponseDecoder =
    D.succeed LoginResponse
        |> required "token" string
        |> required "user" userDecoder


type alias Lead =
    { id : Int
    , number : String
    , fullName : String
    , email : Maybe String
    , phone : Maybe String
    , source : Maybe String
    , consultantId : Maybe Int
    , consultantName : Maybe String
    , quality : Maybe String
    , stage : String
    , destination : Maybe String
    , service : Maybe String
    , notes : Maybe String
    , lastContact : Maybe String
    , nextFollowup : Maybe String
    , createdAt : String
    , updatedAt : String
    }


leadDecoder : Decoder Lead
leadDecoder =
    D.succeed Lead
        |> required "leadId" int
        |> required "leadNumber" string
        |> required "fullName" string
        |> required "email" maybeString
        |> required "phone" maybeString
        |> required "source" maybeString
        |> required "consultantId" maybeInt
        |> required "consultantName" maybeString
        |> required "quality" maybeString
        |> required "stage" string
        |> required "destination" maybeString
        |> required "service" maybeString
        |> required "notes" maybeString
        |> required "lastContact" (nullable dateStr)
        |> required "nextFollowup" (nullable dateStr)
        |> required "createdAt" dateStr
        |> required "updatedAt" dateStr


type alias Task =
    { id : Int
    , leadId : Int
    , leadName : Maybe String
    , title : String
    , description : Maybe String
    , dueDate : Maybe String
    , priority : String
    , status : String
    , assignedTo : Maybe Int
    , assigneeName : Maybe String
    , createdAt : String
    }


taskDecoder : Decoder Task
taskDecoder =
    D.succeed Task
        |> required "id" int
        |> required "leadId" int
        |> required "leadName" maybeString
        |> required "title" string
        |> required "description" maybeString
        |> required "dueDate" (nullable dateStr)
        |> required "priority" string
        |> required "status" string
        |> required "assignedTo" maybeInt
        |> required "assigneeName" maybeString
        |> required "createdAt" dateStr


type alias Activity =
    { id : Int
    , leadId : Int
    , leadName : Maybe String
    , kind : String
    , description : Maybe String
    , date : String
    }


activityDecoder : Decoder Activity
activityDecoder =
    D.succeed Activity
        |> required "id" int
        |> required "leadId" int
        |> required "leadName" maybeString
        |> required "kind" string
        |> required "description" maybeString
        |> required "date" dateStr


type alias Client =
    { id : Int
    , number : String
    , fullName : String
    , email : Maybe String
    , phone : Maybe String
    , caseOfficerId : Maybe Int
    , caseOfficerName : Maybe String
    , createdAt : String
    }


clientDecoder : Decoder Client
clientDecoder =
    D.succeed Client
        |> required "id" int
        |> required "number" string
        |> required "fullName" string
        |> required "email" maybeString
        |> required "phone" maybeString
        |> required "caseOfficerId" maybeInt
        |> required "caseOfficerName" maybeString
        |> required "createdAt" dateStr


type alias CaseRow =
    { id : Int
    , clientId : Int
    , category : Maybe String
    , destination : Maybe String
    , stage : String
    , deadline : Maybe String
    , createdAt : String
    }


caseDecoder : Decoder CaseRow
caseDecoder =
    D.succeed CaseRow
        |> required "id" int
        |> required "clientId" int
        |> required "category" maybeString
        |> required "destination" maybeString
        |> required "stage" string
        |> required "deadline" (nullable dateStr)
        |> required "createdAt" dateStr


type alias ClientDetail =
    { client : Client
    , cases : List CaseRow
    , documents : List Document
    }


clientDetailDecoder : Decoder ClientDetail
clientDetailDecoder =
    D.succeed ClientDetail
        |> required "client" clientDecoder
        |> required "cases" (list caseDecoder)
        |> required "documents" (list documentDecoder)


type alias LeadDetail =
    { lead : Lead
    , tasks : List Task
    , activities : List Activity
    , documents : List Document
    }


{-| The lead detail endpoint returns
@{"lead":…,"tasks":[…],"activities":[…],"documents":[…]}@.
-}
leadDetailDecoder : Decoder LeadDetail
leadDetailDecoder =
    D.succeed LeadDetail
        |> required "lead" leadDecoder
        |> required "tasks" (list taskDecoder)
        |> required "activities" (list activityDecoder)
        |> required "documents" (list documentDecoder)


{-| An uploaded file's metadata; bytes are fetched via the download URL.
-}
type alias Document =
    { id : Int
    , leadId : Maybe Int
    , clientId : Maybe Int
    , filename : String
    , mimeType : String
    , size : Int
    , uploaderName : Maybe String
    , createdAt : String
    }


documentDecoder : Decoder Document
documentDecoder =
    D.succeed Document
        |> required "id" int
        |> required "leadId" maybeInt
        |> required "clientId" maybeInt
        |> required "filename" string
        |> required "mimeType" string
        |> required "size" int
        |> required "uploader" maybeString
        |> required "createdAt" dateStr


{-| One audit-trail row.  @changes@ holds @{"Field":{"from":…,"to":…}}@ for
updates and is Nothing for deletes; it stays as raw JSON here and is
rendered by the view.
-}
type alias AuditEntry =
    { id : Int
    , entityType : String
    , entityId : Int
    , entityName : Maybe String
    , action : String
    , changes : Maybe D.Value
    , actorName : Maybe String
    , createdAt : String
    }


auditDecoder : Decoder AuditEntry
auditDecoder =
    D.succeed AuditEntry
        |> required "id" int
        |> required "entityType" string
        |> required "entityId" int
        |> required "entityName" maybeString
        |> required "action" string
        |> required "changes" (nullable D.value)
        |> required "actorName" maybeString
        |> required "createdAt" dateStr


{-| Result of a bulk CSV import: how many rows were created and which
data rows failed, with the server's reason.
-}
type alias ImportRowError =
    { row : Int
    , error : String
    }


type alias ImportResult =
    { imported : Int
    , failed : List ImportRowError
    }


importResultDecoder : Decoder ImportResult
importResultDecoder =
    D.succeed ImportResult
        |> required "imported" int
        |> required "failed"
            (list
                (D.succeed ImportRowError
                    |> required "row" int
                    |> required "error" string
                )
            )


type alias StageCount =
    { stage : String, count : Int }


type alias SourceCount =
    { source : String, count : Int }


type alias Stats =
    { totalLeads : Int
    , hotLeads : Int
    , totalClients : Int
    , openTasks : Int
    , overdueTasks : Int
    , stageCounts : List StageCount
    , sourceCounts : List SourceCount
    , upcomingTasks : List Task
    , recentActivity : List Activity
    }


statsDecoder : Decoder Stats
statsDecoder =
    let
        stageCount =
            D.map2 (\s c -> { stage = s, count = c })
                (D.field "scStage" string)
                (D.field "scCount" int)

        sourceCount =
            D.map2 (\s c -> { source = s, count = c })
                (D.field "srcSource" string)
                (D.field "srcCount" int)
    in
    D.succeed Stats
        |> required "stTotalLeads" int
        |> required "stHotLeads" int
        |> required "stTotalClients" int
        |> required "stOpenTasks" int
        |> required "stOverdueTasks" int
        |> required "stStageCounts" (list stageCount)
        |> required "stSourceCounts" (list sourceCount)
        |> required "stUpcomingTasks" (list taskDecoder)
        |> required "stRecentActivity" (list activityDecoder)



{-| One page of leads from the paginated/filtered @/api/leads@ endpoint.
-}
type alias LeadPage =
    { items : List Lead
    , total : Int
    }


leadPageDecoder : Decoder LeadPage
leadPageDecoder =
    D.succeed LeadPage
        |> required "items" (list leadDecoder)
        |> required "total" int


{-| One page of clients from the paginated/searchable @/api/clients@ endpoint.
-}
type alias ClientPage =
    { items : List Client
    , total : Int
    }


clientPageDecoder : Decoder ClientPage
clientPageDecoder =
    D.succeed ClientPage
        |> required "items" (list clientDecoder)
        |> required "total" int



-- ---------- encoders ----------


encodeNonEmpty : String -> E.Value
encodeNonEmpty s =
    if String.trim s == "" then
        E.null

    else
        E.string s


maybeDate : String -> E.Value
maybeDate s =
    if String.trim s == "" then
        E.null

    else
        E.string s


type alias BulkSpec =
    { op : String
    , ids : List Int
    , consultantId : Maybe Int
    }


encodeNewLead :
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
    -> E.Value
encodeNewLead f =
    E.object
        [ ("nlFullName", E.string f.fullName)
        , ("nlEmail", encodeNonEmpty f.email)
        , ("nlPhone", encodeNonEmpty f.phone)
        , ("nlSource", encodeNonEmpty f.source)
        , ("nlQuality", encodeNonEmpty f.quality)
        , ("nlStage", encodeNonEmpty f.stage)
        , ("nlDestination", encodeNonEmpty f.destination)
        , ("nlService", encodeNonEmpty f.service)
        , ("nlNotes", encodeNonEmpty f.notes)
        , ("nlNextFollowup", maybeDate f.nextFollowup)
        , ("nlConsultantId", E.null)
        ]


encodeUpdateLead :
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
    -> E.Value
encodeUpdateLead f =
    E.object
        [ ("ulFullName", encodeNonEmpty f.fullName)
        , ("ulEmail", encodeNonEmpty f.email)
        , ("ulPhone", encodeNonEmpty f.phone)
        , ("ulSource", encodeNonEmpty f.source)
        , ("ulQuality", encodeNonEmpty f.quality)
        , ("ulStage", encodeNonEmpty f.stage)
        , ("ulDestination", encodeNonEmpty f.destination)
        , ("ulService", encodeNonEmpty f.service)
        , ("ulNotes", encodeNonEmpty f.notes)
        , ("ulLastContact", maybeDate f.lastContact)
        , ("ulNextFollowup", maybeDate f.nextFollowup)
        , ("ulConsultantId", Maybe.map E.int f.consultantId |> Maybe.withDefault E.null)
        ]


encodeNewTask :
    { leadId : Int
    , title : String
    , description : String
    , dueDate : String
    , priority : String
    }
    -> E.Value
encodeNewTask f =
    E.object
        [ ("ntLeadId", E.int f.leadId)
        , ("ntTitle", E.string f.title)
        , ("ntDescription", encodeNonEmpty f.description)
        , ("ntDueDate", maybeDate f.dueDate)
        , ("ntPriority", encodeNonEmpty f.priority)
        ]


encodeTaskStatus : String -> E.Value
encodeTaskStatus status =
    E.object [ ("tsrStatus", E.string status) ]


encodeNote : String -> E.Value
encodeNote note =
    E.object [ ("nrNote", E.string note) ]


encodeNewClient :
    { fullName : String
    , email : String
    , phone : String
    , officerId : Maybe Int
    }
    -> E.Value
encodeNewClient f =
    E.object
        [ ("ncFullName", E.string f.fullName)
        , ("ncEmail", encodeNonEmpty f.email)
        , ("ncPhone", encodeNonEmpty f.phone)
        , ("ncCaseOfficer", Maybe.map E.int f.officerId |> Maybe.withDefault E.null)
        ]


encodeCaseInput :
    { category : String
    , destination : String
    , stage : String
    , deadline : String
    , caseId : Maybe Int
    }
    -> E.Value
encodeCaseInput f =
    E.object
        [ ("ciServiceCategory", encodeNonEmpty f.category)
        , ("ciDestination", encodeNonEmpty f.destination)
        , ("ciStage", encodeNonEmpty f.stage)
        , ("ciNextDeadline", maybeDate f.deadline)
        , ("ciCaseId", Maybe.map E.int f.caseId |> Maybe.withDefault E.null)
        ]


encodeBulkRequest : BulkSpec -> E.Value
encodeBulkRequest b =
    E.object
        [ ("brOp", E.string b.op)
        , ("brIds", E.list E.int b.ids)
        , ("brConsultantId", Maybe.map E.int b.consultantId |> Maybe.withDefault E.null)
        ]


{-| Passwords are only sent on create; updates use encodeUpdateUser.
-}
encodeNewUser :
    { name : String
    , email : String
    , role : String
    , password : String
    }
    -> E.Value
encodeNewUser f =
    E.object
        [ ("nuName", E.string f.name)
        , ("nuEmail", E.string f.email)
        , ("nuRole", E.string f.role)
        , ("nuPassword", E.string f.password)
        ]


{-| Empty password keeps the current one.
-}
encodeUpdateUser :
    { name : String
    , role : String
    , password : String
    }
    -> E.Value
encodeUpdateUser f =
    E.object
        [ ("uuName", E.string f.name)
        , ("uuRole", E.string f.role)
        , ("uuPassword", encodeNonEmpty f.password)
        ]


encodePasswordChange : { current : String, new : String } -> E.Value
encodePasswordChange f =
    E.object
        [ ("pcCurrent", E.string f.current)
        , ("pcNew", E.string f.new)
        ]
