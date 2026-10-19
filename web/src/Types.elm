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



-- ---------- domain constants ----------


leadStages : List String
leadStages =
    [ "Lead"
    , "Qualified"
    , "Consultation"
    , "Application/Deal"
    , "Student/Client"
    , "Completed"
    , "Lost"
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
    [ "Submitted", "Processing", "Approved", "Completed", "Cancelled", "Lost" ]


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


type alias Client =
    { id : Int
    , number : String
    , fullName : String
    , email : Maybe String
    , phone : Maybe String
    , consultantId : Maybe Int
    , consultantName : Maybe String
    , createdAt : String
    , updatedAt : String
    }


clientDecoder : Decoder Client
clientDecoder =
    D.succeed Client
        |> required "clientId" int
        |> required "clientNumber" string
        |> required "fullName" string
        |> required "email" maybeString
        |> required "phone" maybeString
        |> required "consultantId" maybeInt
        |> required "consultantName" maybeString
        |> required "createdAt" dateStr
        |> required "updatedAt" dateStr


type alias CaseRow =
    { id : Int
    , caseNumber : String
    , service : String
    , destination : Maybe String
    , stage : String
    , nextDeadline : Maybe String
    , totalFee : Float
    , paidAmount : Float
    , balance : Float
    }


caseDecoder : Decoder CaseRow
caseDecoder =
    D.succeed CaseRow
        |> required "caseId" int
        |> required "caseNumber" string
        |> required "service" string
        |> required "destination" maybeString
        |> required "stage" string
        |> required "nextDeadline" (nullable dateStr)
        |> required "totalFee" D.float
        |> required "paidAmount" D.float
        |> required "balance" D.float


type alias Document =
    { id : Int
    , name : String
    , docType : String
    , status : String
    , createdAt : String
    }


documentDecoder : Decoder Document
documentDecoder =
    D.succeed Document
        |> required "documentId" int
        |> required "name" string
        |> required "docType" string
        |> required "status" string
        |> required "createdAt" dateStr


type alias Task =
    { id : Int
    , title : String
    , description : Maybe String
    , dueDate : Maybe String
    , priority : String
    , status : String
    , assignedTo : Maybe Int
    , assignedName : Maybe String
    , leadId : Maybe Int
    , clientId : Maybe Int
    , createdAt : String
    }


taskDecoder : Decoder Task
taskDecoder =
    D.succeed Task
        |> required "taskId" int
        |> required "title" string
        |> required "description" maybeString
        |> required "dueDate" (nullable dateStr)
        |> required "priority" string
        |> required "status" string
        |> required "assignedTo" maybeInt
        |> required "assignedName" maybeString
        |> required "leadId" maybeInt
        |> required "clientId" maybeInt
        |> required "createdAt" dateStr


type alias Activity =
    { id : Int
    , action : String
    , details : Maybe String
    , actorName : Maybe String
    , createdAt : String
    }


activityDecoder : Decoder Activity
activityDecoder =
    D.succeed Activity
        |> required "activityId" int
        |> required "action" string
        |> required "details" maybeString
        |> required "actorName" maybeString
        |> required "createdAt" dateStr


type alias LeadDetail =
    { lead : Lead
    , tasks : List Task
    , documents : List Document
    , activities : List Activity
    }


leadDetailDecoder : Decoder LeadDetail
leadDetailDecoder =
    D.succeed LeadDetail
        |> required "lead" leadDecoder
        |> required "tasks" (list taskDecoder)
        |> required "documents" (list documentDecoder)
        |> required "activities" (list activityDecoder)


type alias ClientDetail =
    { client : Client
    , cases : List CaseRow
    , tasks : List Task
    , documents : List Document
    , activities : List Activity
    }


clientDetailDecoder : Decoder ClientDetail
clientDetailDecoder =
    D.succeed ClientDetail
        |> required "client" clientDecoder
        |> required "cases" (list caseDecoder)
        |> required "tasks" (list taskDecoder)
        |> required "documents" (list documentDecoder)
        |> required "activities" (list activityDecoder)


type alias StageCount =
    { stage : String
    , count : Int
    }


stageCountDecoder : Decoder StageCount
stageCountDecoder =
    D.succeed StageCount
        |> required "stage" string
        |> required "count" int


type alias SourceCount =
    { source : String
    , count : Int
    }


sourceCountDecoder : Decoder SourceCount
sourceCountDecoder =
    D.succeed SourceCount
        |> required "source" string
        |> required "count" int


type alias Stats =
    { totalLeads : Int
    , activeClients : Int
    , pendingTasks : Int
    , overdueTasks : Int
    , leadsByStage : List StageCount
    , leadsBySource : List SourceCount
    }


statsDecoder : Decoder Stats
statsDecoder =
    D.succeed Stats
        |> required "totalLeads" int
        |> required "activeClients" int
        |> required "pendingTasks" int
        |> required "overdueTasks" int
        |> required "leadsByStage" (list stageCountDecoder)
        |> required "leadsBySource" (list sourceCountDecoder)


type alias AuditEntry =
    { id : Int
    , actorName : Maybe String
    , action : String
    , entityType : String
    , entityId : Maybe Int
    , details : Maybe String
    , createdAt : String
    }


auditDecoder : Decoder AuditEntry
auditDecoder =
    D.succeed AuditEntry
        |> required "auditId" int
        |> required "actorName" maybeString
        |> required "action" string
        |> required "entityType" string
        |> required "entityId" maybeInt
        |> required "details" maybeString
        |> required "createdAt" dateStr


type alias ImportRowError =
    { row : Int
    , message : String
    }


type alias ImportResult =
    { inserted : Int
    , skipped : Int
    , errors : List ImportRowError
    }


importRowErrorDecoder : Decoder ImportRowError
importRowErrorDecoder =
    D.succeed ImportRowError
        |> required "row" int
        |> required "message" string


importResultDecoder : Decoder ImportResult
importResultDecoder =
    D.succeed ImportResult
        |> required "inserted" int
        |> required "skipped" int
        |> required "errors" (list importRowErrorDecoder)


type alias LeadPage =
    { items : List Lead
    , page : Int
    , pageSize : Int
    , total : Int
    }


leadPageDecoder : Decoder LeadPage
leadPageDecoder =
    D.succeed LeadPage
        |> required "items" (list leadDecoder)
        |> required "page" int
        |> required "pageSize" int
        |> required "total" int


type alias ClientPage =
    { items : List Client
    , page : Int
    , pageSize : Int
    , total : Int
    }


clientPageDecoder : Decoder ClientPage
clientPageDecoder =
    D.succeed ClientPage
        |> required "items" (list clientDecoder)
        |> required "page" int
        |> required "pageSize" int
        |> required "total" int


-- ---------- encoders ----------


encodeNewLead :
    { fullName : String
    , email : String
    , phone : String
    , source : String
    , consultantId : Maybe Int
    , quality : String
    , stage : String
    , destination : String
    , service : String
    , notes : String
    , nextFollowup : String
    }
    -> E.Value
encodeNewLead x =
    E.object
        [ ( "fullName", E.string x.fullName )
        , ( "email", nullableString x.email )
        , ( "phone", nullableString x.phone )
        , ( "source", nullableString x.source )
        , ( "consultantId", maybeIntValue x.consultantId )
        , ( "quality", nullableString x.quality )
        , ( "stage", nullableString x.stage )
        , ( "destination", nullableString x.destination )
        , ( "service", nullableString x.service )
        , ( "notes", nullableString x.notes )
        , ( "nextFollowup", nullableString x.nextFollowup )
        ]


encodeUpdateLead :
    { fullName : Maybe String
    , email : Maybe String
    , phone : Maybe String
    , source : Maybe String
    , consultantId : Maybe Int
    , quality : Maybe String
    , stage : Maybe String
    , destination : Maybe String
    , service : Maybe String
    , notes : Maybe String
    , lastContact : Maybe String
    , nextFollowup : Maybe String
    }
    -> E.Value
encodeUpdateLead x =
    E.object
        [ ( "fullName", maybeStringValue x.fullName )
        , ( "email", maybeStringValue x.email )
        , ( "phone", maybeStringValue x.phone )
        , ( "source", maybeStringValue x.source )
        , ( "consultantId", maybeIntValue x.consultantId )
        , ( "quality", maybeStringValue x.quality )
        , ( "stage", maybeStringValue x.stage )
        , ( "destination", maybeStringValue x.destination )
        , ( "service", maybeStringValue x.service )
        , ( "notes", maybeStringValue x.notes )
        , ( "lastContact", maybeStringValue x.lastContact )
        , ( "nextFollowup", maybeStringValue x.nextFollowup )
        ]


encodeNewClient :
    { fullName : String, email : String, phone : String, consultantId : Maybe Int }
    -> E.Value
encodeNewClient x =
    E.object
        [ ( "fullName", E.string x.fullName )
        , ( "email", nullableString x.email )
        , ( "phone", nullableString x.phone )
        , ( "consultantId", maybeIntValue x.consultantId )
        ]


encodeCaseInput :
    { service : String, destination : String, stage : String, deadline : String }
    -> E.Value
encodeCaseInput x =
    E.object
        [ ( "service", E.string x.service )
        , ( "destination", nullableString x.destination )
        , ( "stage", E.string x.stage )
        , ( "nextDeadline", nullableString x.deadline )
        ]


encodeNewTask :
    { title : String
    , description : String
    , dueDate : String
    , priority : String
    , assignedTo : Maybe Int
    , leadId : Maybe Int
    , clientId : Maybe Int
    }
    -> E.Value
encodeNewTask x =
    E.object
        [ ( "title", E.string x.title )
        , ( "description", nullableString x.description )
        , ( "dueDate", nullableString x.dueDate )
        , ( "priority", E.string x.priority )
        , ( "assignedTo", maybeIntValue x.assignedTo )
        , ( "leadId", maybeIntValue x.leadId )
        , ( "clientId", maybeIntValue x.clientId )
        ]


encodeTaskStatus : String -> E.Value
encodeTaskStatus s =
    E.object [ ( "status", E.string s ) ]


encodeNote : String -> E.Value
encodeNote body =
    E.object [ ( "body", E.string body ) ]


type alias BulkSpec =
    { action : String
    , ids : List Int
    , assigneeId : Maybe Int
    , stage : Maybe String
    }


encodeBulkRequest : BulkSpec -> E.Value
encodeBulkRequest x =
    E.object
        [ ( "action", E.string x.action )
        , ( "ids", E.list E.int x.ids )
        , ( "assigneeId", maybeIntValue x.assigneeId )
        , ( "stage", maybeStringValue x.stage )
        ]


encodeNewUser : { email : String, name : String, role : String, password : String } -> E.Value
encodeNewUser x =
    E.object
        [ ( "email", E.string x.email )
        , ( "name", E.string x.name )
        , ( "role", E.string x.role )
        , ( "password", E.string x.password )
        ]


encodeUpdateUser : { email : String, name : String, role : String } -> E.Value
encodeUpdateUser x =
    E.object
        [ ( "email", E.string x.email )
        , ( "name", E.string x.name )
        , ( "role", E.string x.role )
        ]


encodePasswordChange : String -> E.Value
encodePasswordChange password =
    E.object [ ( "password", E.string password ) ]


nullableString : String -> E.Value
nullableString s =
    if String.trim s == "" then
        E.null
    else
        E.string s


maybeStringValue : Maybe String -> E.Value
maybeStringValue m =
    case m of
        Nothing -> E.null
        Just s -> E.string s


maybeIntValue : Maybe Int -> E.Value
maybeIntValue m =
    case m of
        Nothing -> E.null
        Just n -> E.int n
