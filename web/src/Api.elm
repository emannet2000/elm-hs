module Api exposing
    ( Ctx
    , computeBase
    , login
    , me
    , fetchUsers
    , fetchLeadPage
    , fetchLeadDetail
    , createLead
    , updateLead
    , deleteLead
    , advanceLead
    , convertLead
    , addNote
    , bulkLeads
    , fetchTasks
    , createTask
    , setTaskStatus
    , deleteTask
    , fetchActivities
    , fetchClientPage
    , fetchClientDetail
    , createClient
    , updateClient
    , deleteClient
    , upsertCase
    , deleteCase
    , uploadLeadDocument
    , uploadClientDocument
    , deleteDocument
    , documentDownloadUrl
    , exportCsvUrl
    , importLeads
    , createUser
    , updateUser
    , deleteUser
    , changePassword
    , fetchAudit
    , fetchStats
    )

{-| Thin wrappers over elm/http for every API endpoint.  All requests carry
the JWT bearer token when one is available.
-}

import File exposing (File)
import Http
import Json.Decode as D
import Json.Encode as E
import Url

import Types exposing (..)


{-| The Reactor dev server runs on :8000 while the API runs on :4000.
When the app is served by the API binary itself (production), relative URLs
are used instead.
-}
computeBase : { protocol : String, host : String, port_ : Maybe Int } -> String
computeBase loc =
    case loc.port_ of
        Just p ->
            if p == 4000 then
                loc.protocol ++ "://" ++ loc.host ++ ":" ++ String.fromInt p

            else if p == 80 || p == 443 then
                ""

            else
                "http://localhost:4000"

        Nothing ->
            ""


type alias Ctx =
    { base : String, token : Maybe String }


authedRequest :
    Ctx
    -> String
    -> String
    -> Maybe Http.Body
    -> D.Decoder a
    -> (Result Http.Error a -> msg)
    -> Cmd msg
authedRequest ctx method path body decoder toMsg =
    Http.request
        { method = method
        , headers =
            case ctx.token of
                Just t ->
                    [ Http.header "Authorization" ("Bearer " ++ t) ]

                Nothing ->
                    []
        , url = ctx.base ++ path
        , body = Maybe.withDefault Http.emptyBody body
        , expect = expectApi decoder toMsg
        , timeout = Nothing
        , tracker = Nothing
        }



-- ---------- auth ----------


type alias LoginResult =
    Result Http.Error LoginResponse


login : Ctx -> String -> String -> (LoginResult -> msg) -> Cmd msg
login ctx email password toMsg =
    Http.post
        { url = ctx.base ++ "/api/auth/login"
        , body = Http.jsonBody (loginBody email password)
        , expect = expectApi loginResponseDecoder toMsg
        }


me : Ctx -> (Result Http.Error User -> msg) -> Cmd msg
me ctx toMsg =
    authedRequest ctx "GET" "/api/auth/me" Nothing userDecoder toMsg



-- ---------- users / leads / tasks / clients / stats ----------


fetchUsers : Ctx -> (Result Http.Error (List User) -> msg) -> Cmd msg
fetchUsers ctx =
    authedRequest ctx "GET" "/api/users" Nothing (D.list userDecoder)


{-| One page of leads.  Filtering, sorting and paging all happen on the
server, so the client no longer downloads the whole table.
-}
fetchLeadPage :
    Ctx
    ->
        { q : String
        , stage : String
        , quality : String
        , source : String
        , sort : String
        , dir : String
        , limit : Int
        , offset : Int
        }
    -> (Result Http.Error LeadPage -> msg)
    -> Cmd msg
fetchLeadPage ctx f =
    authedRequest ctx "GET"
        ("/api/leads?" ++ queryString
            [ ( "q", f.q )
            , ( "stage", f.stage )
            , ( "quality", f.quality )
            , ( "source", f.source )
            , ( "sort", f.sort )
            , ( "dir", f.dir )
            , ( "limit", String.fromInt f.limit )
            , ( "offset", String.fromInt f.offset )
            ]
        )
        Nothing
        leadPageDecoder


{-| One page of clients with an optional search term.
-}
fetchClientPage :
    Ctx
    -> { q : String, limit : Int, offset : Int }
    -> (Result Http.Error ClientPage -> msg)
    -> Cmd msg
fetchClientPage ctx f =
    authedRequest ctx "GET"
        ("/api/clients?" ++ queryString
            [ ( "q", f.q )
            , ( "limit", String.fromInt f.limit )
            , ( "offset", String.fromInt f.offset )
            ]
        )
        Nothing
        clientPageDecoder


{-| Percent-encoded @key=value&…@ query string; blank values are dropped.
-}
queryString : List ( String, String ) -> String
queryString pairs =
    pairs
        |> List.filter (\( _, v ) -> String.trim v /= "" && v /= "All")
        |> List.map (\( k, v ) -> k ++ "=" ++ Url.percentEncode v)
        |> String.join "&"


fetchLeadDetail : Ctx -> Int -> (Result Http.Error LeadDetail -> msg) -> Cmd msg
fetchLeadDetail ctx id =
    authedRequest ctx "GET" ("/api/leads/" ++ String.fromInt id) Nothing leadDetailDecoder


createLead : Ctx -> E.Value -> (Result Http.Error Lead -> msg) -> Cmd msg
createLead ctx body =
    authedRequest ctx "POST" "/api/leads" (Just <| Http.jsonBody body) leadDecoder


updateLead : Ctx -> Int -> E.Value -> (Result Http.Error Lead -> msg) -> Cmd msg
updateLead ctx id body =
    authedRequest ctx "PATCH" ("/api/leads/" ++ String.fromInt id) (Just <| Http.jsonBody body) leadDecoder


deleteLead : Ctx -> Int -> (Result Http.Error () -> msg) -> Cmd msg
deleteLead ctx id =
    authedRequest ctx "DELETE" ("/api/leads/" ++ String.fromInt id) Nothing ignoreDecoder


advanceLead : Ctx -> Int -> (Result Http.Error Lead -> msg) -> Cmd msg
advanceLead ctx id =
    authedRequest ctx "POST" ("/api/leads/" ++ String.fromInt id ++ "/advance") Nothing leadDecoder


convertLead : Ctx -> Int -> (Result Http.Error Client -> msg) -> Cmd msg
convertLead ctx id =
    authedRequest ctx "POST" ("/api/leads/" ++ String.fromInt id ++ "/convert") Nothing clientDecoder


addNote : Ctx -> Int -> String -> (Result Http.Error () -> msg) -> Cmd msg
addNote ctx id note =
    authedRequest ctx
        "POST"
        ("/api/leads/" ++ String.fromInt id ++ "/notes")
        (Just <| Http.jsonBody (encodeNote note))
        ignoreDecoder


bulkLeads : Ctx -> BulkSpec -> (Result Http.Error () -> msg) -> Cmd msg
bulkLeads ctx spec =
    authedRequest ctx "POST" "/api/bulk/leads" (Just <| Http.jsonBody (encodeBulkRequest spec)) ignoreDecoder


fetchTasks : Ctx -> (Result Http.Error (List Task) -> msg) -> Cmd msg
fetchTasks ctx =
    authedRequest ctx "GET" "/api/tasks" Nothing (D.list taskDecoder)


createTask : Ctx -> E.Value -> (Result Http.Error Task -> msg) -> Cmd msg
createTask ctx body =
    authedRequest ctx "POST" "/api/tasks" (Just <| Http.jsonBody body) taskDecoder


setTaskStatus : Ctx -> Int -> String -> (Result Http.Error () -> msg) -> Cmd msg
setTaskStatus ctx id status =
    authedRequest ctx
        "PATCH"
        ("/api/tasks/" ++ String.fromInt id)
        (Just <| Http.jsonBody (encodeTaskStatus status))
        ignoreDecoder


deleteTask : Ctx -> Int -> (Result Http.Error () -> msg) -> Cmd msg
deleteTask ctx id =
    authedRequest ctx "DELETE" ("/api/tasks/" ++ String.fromInt id) Nothing ignoreDecoder


fetchActivities : Ctx -> Int -> (Result Http.Error (List Activity) -> msg) -> Cmd msg
fetchActivities ctx limit =
    authedRequest ctx "GET" ("/api/activities?limit=" ++ String.fromInt limit) Nothing (D.list activityDecoder)


fetchClientDetail : Ctx -> Int -> (Result Http.Error ClientDetail -> msg) -> Cmd msg
fetchClientDetail ctx id =
    authedRequest ctx "GET" ("/api/clients/" ++ String.fromInt id) Nothing clientDetailDecoder


createClient : Ctx -> E.Value -> (Result Http.Error Client -> msg) -> Cmd msg
createClient ctx body =
    authedRequest ctx "POST" "/api/clients" (Just <| Http.jsonBody body) clientDecoder


updateClient : Ctx -> Int -> E.Value -> (Result Http.Error () -> msg) -> Cmd msg
updateClient ctx id body =
    authedRequest ctx "PATCH" ("/api/clients/" ++ String.fromInt id) (Just <| Http.jsonBody body) ignoreDecoder


deleteClient : Ctx -> Int -> (Result Http.Error () -> msg) -> Cmd msg
deleteClient ctx id =
    authedRequest ctx "DELETE" ("/api/clients/" ++ String.fromInt id) Nothing ignoreDecoder


upsertCase : Ctx -> Int -> E.Value -> (Result Http.Error ClientDetail -> msg) -> Cmd msg
upsertCase ctx clientId body =
    authedRequest ctx "POST" ("/api/clients/" ++ String.fromInt clientId ++ "/cases") (Just <| Http.jsonBody body) clientDetailDecoder


deleteCase : Ctx -> Int -> (Result Http.Error () -> msg) -> Cmd msg
deleteCase ctx id =
    authedRequest ctx "DELETE" ("/api/cases/" ++ String.fromInt id) Nothing ignoreDecoder



-- ---------- documents ----------


{-| Multipart upload of one file attached to a lead; responds with the
refreshed lead detail (including the new documents list).
-}
uploadLeadDocument : Ctx -> Int -> File -> (Result Http.Error LeadDetail -> msg) -> Cmd msg
uploadLeadDocument ctx id file =
    uploadDocument ctx
        ("/api/leads/" ++ String.fromInt id ++ "/documents")
        file
        leadDetailDecoder


{-| Same as 'uploadLeadDocument' but attached to a client.
-}
uploadClientDocument : Ctx -> Int -> File -> (Result Http.Error ClientDetail -> msg) -> Cmd msg
uploadClientDocument ctx id file =
    uploadDocument ctx
        ("/api/clients/" ++ String.fromInt id ++ "/documents")
        file
        clientDetailDecoder


uploadDocument : Ctx -> String -> File -> D.Decoder a -> (Result Http.Error a -> msg) -> Cmd msg
uploadDocument ctx path file decoder toMsg =
    Http.request
        { method = "POST"
        , headers =
            case ctx.token of
                Just t ->
                    [ Http.header "Authorization" ("Bearer " ++ t) ]

                Nothing ->
                    []
        , url = ctx.base ++ path
        , body = Http.multipartBody [ Http.filePart "file" file ]
        , expect = expectApi decoder toMsg
        , timeout = Nothing
        , tracker = Nothing
        }


deleteDocument : Ctx -> Int -> (Result Http.Error () -> msg) -> Cmd msg
deleteDocument ctx id =
    authedRequest ctx "DELETE" ("/api/documents/" ++ String.fromInt id) Nothing ignoreDecoder


{-| Direct download link for an @<a>@ — the API also accepts the token
as a query parameter because anchors cannot set headers.
-}
documentDownloadUrl : Ctx -> Int -> String
documentDownloadUrl ctx id =
    let
        tokenPart =
            case ctx.token of
                Just t ->
                    "?token=" ++ Url.percentEncode t

                Nothing ->
                    ""
    in
    ctx.base ++ "/api/documents/" ++ String.fromInt id ++ "/download" ++ tokenPart


{-| Direct download link for a CSV export (leads\/clients) — same
query-token mechanism as document downloads.
-}
exportCsvUrl : Ctx -> String -> String
exportCsvUrl ctx kind =
    let
        tokenPart =
            case ctx.token of
                Just t ->
                    "?token=" ++ Url.percentEncode t

                Nothing ->
                    ""
    in
    ctx.base ++ "/api/export/" ++ kind ++ ".csv" ++ tokenPart


{-| Upload a CSV file for bulk lead import.  The server parses the file and
answers with per-row success\/failure counts.
-}
importLeads : Ctx -> File -> (Result Http.Error ImportResult -> msg) -> Cmd msg
importLeads ctx file toMsg =
    Http.request
        { method = "POST"
        , headers =
            case ctx.token of
                Just t ->
                    [ Http.header "Authorization" ("Bearer " ++ t) ]

                Nothing ->
                    []
        , url = ctx.base ++ "/api/import/leads"
        , body = Http.multipartBody [ Http.filePart "file" file ]
        , expect = expectApi importResultDecoder toMsg
        , timeout = Nothing
        , tracker = Nothing
        }



-- ---------- users / account ----------


createUser : Ctx -> E.Value -> (Result Http.Error User -> msg) -> Cmd msg
createUser ctx body =
    authedRequest ctx "POST" "/api/users" (Just <| Http.jsonBody body) userDecoder


updateUser : Ctx -> Int -> E.Value -> (Result Http.Error () -> msg) -> Cmd msg
updateUser ctx id body =
    authedRequest ctx "PATCH" ("/api/users/" ++ String.fromInt id) (Just <| Http.jsonBody body) ignoreDecoder


deleteUser : Ctx -> Int -> (Result Http.Error () -> msg) -> Cmd msg
deleteUser ctx id =
    authedRequest ctx "DELETE" ("/api/users/" ++ String.fromInt id) Nothing ignoreDecoder


{-| Change the signed-in user's own password.
-}
changePassword : Ctx -> String -> String -> (Result Http.Error () -> msg) -> Cmd msg
changePassword ctx current new =
    authedRequest ctx "PUT" "/api/auth/password"
        (Just <| Http.jsonBody (encodePasswordChange { current = current, new = new }))
        ignoreDecoder


fetchStats : Ctx -> (Result Http.Error Stats -> msg) -> Cmd msg
fetchStats ctx =
    authedRequest ctx "GET" "/api/stats" Nothing statsDecoder


{-| Latest audit-trail entries (admin-only endpoint).
-}
fetchAudit : Ctx -> Int -> (Result Http.Error (List AuditEntry) -> msg) -> Cmd msg
fetchAudit ctx limit =
    authedRequest ctx "GET" ("/api/audit?limit=" ++ String.fromInt limit)
        Nothing
        (D.list auditDecoder)



-- ---------- helpers ----------


ignoreDecoder : D.Decoder ()
ignoreDecoder =
    D.oneOf
        [ D.map (\_ -> ()) (D.dict D.value)
        , D.succeed ()
        ]


loginBody : String -> String -> E.Value
loginBody email password =
    E.object
        [ ( "lrEmail", E.string email )
        , ( "lrPassword", E.string password )
        ]

{-| Preserve server validation messages so blockers and duplicate warnings are actionable. -}
expectApi : D.Decoder a -> (Result Http.Error a -> msg) -> Http.Expect msg
expectApi decoder toMsg =
    Http.expectStringResponse toMsg
        (\response ->
            case response of
                Http.BadUrl_ url ->
                    Err (Http.BadUrl url)

                Http.Timeout_ ->
                    Err Http.Timeout

                Http.NetworkError_ ->
                    Err Http.NetworkError

                Http.BadStatus_ metadata body ->
                    if List.member metadata.statusCode [ 401, 403, 404 ] then
                        Err (Http.BadStatus metadata.statusCode)
                    else
                        case D.decodeString (D.field "error" D.string) body of
                            Ok message ->
                                Err (Http.BadBody ("API: " ++ message))
                            Err _ ->
                                Err (Http.BadStatus metadata.statusCode)

                Http.GoodStatus_ _ body ->
                    D.decodeString decoder body
                        |> Result.mapError (D.errorToString >> Http.BadBody)
        )
