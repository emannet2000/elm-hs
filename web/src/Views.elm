module Views exposing
    ( visibleLeads
    , loginView
    , dashboardView
    , leadsView
    , leadDetailView
    , clientsView
    , clientDetailView
    , tasksView
    , usersView
    , auditView
    , userFormModal
    , passwordModal
    , notificationsDropdown
    , toastStack
    )

{-| All page views.  They are pure functions of the central Model.
-}

import Date
import File exposing (File)
import Html exposing (Html, a, button, div, h2, h3, h4, input, label, li,
                      option, select, span, strong, table, tbody, td, text,
                      th, thead, tr, ul)
import Html.Attributes exposing (checked, class, href, placeholder, selected,
                                 type_, value)
import Html.Events exposing (on, onClick, onCheck, onInput)
import Json.Decode as D
import Json.Encode as E
import Set exposing (Set)

import Api
import State exposing (..)
import Types exposing (..)
import Ui exposing
    ( emptyNote
    , fmtDate
    , fmtDateTime
    , inputField
    , modal
    , priorityBadge
    , qualityTag
    , selectField
    , spinner
    , stageTag
    , statusTag
    )



-- ---------- login ----------


loginView : Model -> Html Msg
loginView model =
    div [ class "ecc-split login-wrap" ]
        [ div [ class "motif-line", Html.Attributes.attribute "aria-hidden" "true" ] []
        , div [ class "motif-orb", Html.Attributes.attribute "aria-hidden" "true" ] []
        , div [ class "motif-dots", Html.Attributes.attribute "aria-hidden" "true" ] []
        , Html.aside [ class "brand-panel" ]
            [ div [ class "brand-panel__glow brand-panel__glow--1" ] []
            , div [ class "brand-panel__glow brand-panel__glow--2" ] []
            , div [ class "brand-panel__inner" ]
                [ div [ class "brand-panel__header" ]
                    [ Html.img [ class "brand-panel__logo", Html.Attributes.src "/icons/ecc-192.png", Html.Attributes.alt "ECC Consulting Global emblem" ] []
                    , div [ class "brand-panel__wordmark" ]
                        [ span [ class "brand-panel__name" ] [ text "ECC" ]
                        , span [ class "brand-panel__product" ] [ text "CRM" ]
                        ]
                    ]
                , div [ class "brand-panel__hero" ]
                    [ h2 [ class "brand-panel__headline" ]
                        [ text "Customer relationships, "
                        , span [ class "brand-panel__headline-accent" ] [ text "secured." ]
                        ]
                    , Html.p [ class "brand-panel__lede" ] [ text "The unified workspace for your team to manage clients, applications and conversations — with access controls and an auditable history." ]
                    ]
                , ul [ class "trust-list" ]
                    (List.map (\line -> li [ class "trust-item" ] [ span [ class "trust-check" ] [ text "✓" ], text line ])
                        [ "Organization and role permissions", "Private document storage", "Secure, revocable sessions" ])
                , div [ class "brand-panel__footer" ] [ text "© 2026 ECC. All rights reserved." ]
                ]
            ]
        , div [ class "auth-panel" ]
            [ div [ class "auth-panel__inner" ]
                [ div [ class "auth-header" ]
                    [ Html.h1 [ class "auth-title" ] [ text "Welcome back" ]
                    , Html.p [ class "auth-subtitle" ] [ text "Sign in to your ECC workspace." ]
                    ]
                , Html.form [ Html.Events.onSubmit LoginClicked ]
                    [ inputField "Work email" model.loginEmail "email" LoginEmailChanged
                    , div [ Html.Attributes.style "height" "18px" ] []
                    , inputField "Password" model.loginPassword "password" LoginPasswordChanged
                    , if model.loginError /= "" then div [ class "login-error", Html.Attributes.attribute "role" "alert" ] [ text model.loginError ] else text ""
                    , button [ class "ecc-btn", type_ "submit", Html.Attributes.style "margin-top" "24px" ] [ text "Sign in" ]
                    ]
                , Html.p [ class "auth-subtitle", Html.Attributes.style "margin-top" "24px" ] [ text "Need access or a password reset? Contact your administrator." ]
                ]
            ]
        ]


-- ---------- dashboard ----------


statCard : String -> String -> String -> Html msg
statCard label sub value =
    div [ class "stat" ]
        [ div [ class "stat-label" ] [ text label ]
        , div [ class "stat-value" ] [ text value ]
        , div [ class "stat-sub" ] [ text sub ]
        ]


dashboardView : Model -> Html Msg
dashboardView model =
    case model.stats of
        Nothing ->
            Ui.spinner

        Just stats ->
            let
                maxStage =
                    List.map (\s -> s.count) stats.stageCounts
                        |> List.maximum
                        |> Maybe.withDefault 1

                stageRow sc =
                    div [ class "stage-row" ]
                        [ span [ class "stage-name" ] [ text sc.stage ]
                        , div [ class "stage-bar" ]
                            [ div
                                [ class "stage-fill"
                                , Html.Attributes.style "width"
                                    (String.fromInt
                                        (if maxStage == 0 then
                                            0

                                         else
                                            round ((toFloat sc.count / toFloat maxStage) * 100)
                                        )
                                        ++ "%"
                                    )
                                ]
                                []
                            ]
                        , span [ class "stage-count" ] [ text (String.fromInt sc.count) ]
                        ]

                sourceRow sc =
                    div [ class "lead-item" ]
                        [ span [ class "lead-name" ] [ text sc.source ]
                        , span [ class "lead-count" ] [ text (String.fromInt sc.count) ]
                        ]

                upcomingRow t =
                    div
                        [ class "task-compact-item clickable"
                        , onClick (NavigateTo (if t.leadId > 0 then "/leads/" ++ String.fromInt t.leadId else "/workflow?tab=tasks"))
                        ]
                        [ span [ class "task-title" ] [ text t.title ]
                        , span [ class "task-lead" ] [ text (Maybe.withDefault "" t.leadName) ]
                        , Ui.priorityBadge t.priority
                        , span [ class "activity-date" ] [ text (Ui.fmtDate t.dueDate) ]
                        ]

                activityRow act =
                    div
                        [ class "activity-compact-item clickable"
                        , onClick (NavigateTo ("/leads/" ++ String.fromInt act.leadId))
                        ]
                        [ span [ class "activity-date" ] [ text (Ui.fmtDate (Just act.date)) ]
                        , span [ class "activity-type" ] [ text act.kind ]
                        , span [ class "activity-desc" ] [ text (Maybe.withDefault "" act.description) ]
                        , span [ class "activity-lead" ] [ text (Maybe.withDefault "" act.leadName) ]
                        ]
            in
            div []
                [ div [ class "stats" ]
                    [ statCard "Total Leads" (String.fromInt stats.hotLeads ++ " hot") (String.fromInt stats.totalLeads)
                    , statCard "Clients" "" (String.fromInt stats.totalClients)
                    , statCard "Open Tasks" (String.fromInt stats.overdueTasks ++ " overdue") (String.fromInt stats.openTasks)
                    ]
                , div [ class "main-grid" ]
                    [ div [ class "card" ]
                        [ div [ class "card-title" ] [ text "Pipeline by Stage" ]
                        , div [] (List.map stageRow stats.stageCounts)
                        ]
                    , div [ class "card" ]
                        [ div [ class "card-title" ] [ text "Lead Sources" ]
                        , div [] (List.map sourceRow stats.sourceCounts)
                        ]
                    , div [ class "card dashboard-tasks" ]
                        [ div [ class "card-title" ] [ text "Upcoming Tasks" ]
                        , div [ class "task-list-compact" ] (List.map upcomingRow stats.upcomingTasks)
                        ]
                    , div [ class "card dashboard-activity" ]
                        [ div [ class "card-title" ] [ text "Recent Activity" ]
                        , div [ class "activity-list-compact" ] (List.map activityRow stats.recentActivity)
                        ]
                    ]
                ]



-- ---------- leads list ----------


{-| The lead rows currently on screen.  Filtering, sorting and paging are
done by the API, so this is simply the page the server returned.
-}
visibleLeads : Model -> List Lead
visibleLeads model =
    model.leads


{-| Prev/Next control with a "showing X–Y of N" summary.  Rendered only when
there is more than one page.
-}
pager :
    { count : Int, total : Int, limit : Int, offset : Int }
    -> (Int -> Msg)
    -> Html Msg
pager info onChange =
    if info.total <= info.limit then
        span [] []

    else
        let
            from =
                if info.count == 0 then
                    0

                else
                    info.offset + 1

            to =
                info.offset + info.count

            hasPrev =
                info.offset > 0

            hasNext =
                info.offset + info.count < info.total
        in
        div [ class "pager" ]
            [ span [ class "pager-info" ]
                [ text
                    ("Showing "
                        ++ String.fromInt from
                        ++ "–"
                        ++ String.fromInt to
                        ++ " of "
                        ++ String.fromInt info.total
                    )
                ]
            , div [ class "pager-buttons" ]
                [ button
                    [ class "btn btn-sm btn-outline"
                    , Html.Attributes.disabled (not hasPrev)
                    , onClick (onChange (max 0 (info.offset - info.limit)))
                    ]
                    [ text "‹ Prev" ]
                , button
                    [ class "btn btn-sm btn-outline"
                    , Html.Attributes.disabled (not hasNext)
                    , onClick (onChange (info.offset + info.limit))
                    ]
                    [ text "Next ›" ]
                ]
            ]


leadsToolbar : Model -> Html Msg
leadsToolbar model =
    let
        ctx =
            { base = model.apiBase, token = model.token }
    in
    div [ class "search-container" ]
        [ div [ class "search-row" ]
            [ div [ class "search-input-wrapper" ]
                [ input
                    [ class "search-input"
                    , placeholder "Search name, email, phone, lead number…"
                    , value model.q
                    , onInput SearchChanged
                    ]
                    []
                ]
            , a
                [ class "btn btn-outline"
                , href (Api.exportCsvUrl ctx "leads")
                , Html.Attributes.download ""
                ]
                [ text "Export CSV" ]
            , div [ class "import-group" ]
                [ input
                    [ type_ "file"
                    , Html.Attributes.attribute "accept" ".csv,text/csv"
                    , Html.Attributes.title "Pick a CSV of leads to import"
                    , on
                        "change"
                        (D.map ImportFilePicked
                            (D.at [ "target", "files" ] (D.index 0 File.decoder))
                        )
                    ]
                    []
                , button
                    [ class "btn btn-outline"
                    , Html.Attributes.title
                        (case model.pendingImport of
                            Just f ->
                                "Import " ++ File.name f

                            Nothing ->
                                "Import leads from the selected CSV file"
                        )
                    , onClick LeadImportClicked
                    ]
                    [ text
                        (case model.pendingImport of
                            Just f ->
                                "Import (" ++ File.name f ++ ")"

                            Nothing ->
                                "Import"
                        )
                    ]
                ]
            , button [ class "btn btn-primary", onClick OpenAddLead ] [ text "+ Add Lead" ]
            ]
        , div [ class "filter-row" ]
            [ selectFieldMsg "Stage" (plainOptions ("All" :: Types.leadStages)) model.fStage StageFilterChanged
            , selectFieldMsg "Quality" (plainOptions ("All" :: Types.qualities)) model.fQuality QualityFilterChanged
            , selectFieldMsg "Source" (plainOptions ("All" :: Types.sources)) model.fSource SourceFilterChanged
            , selectFieldMsg "Sort By"
                [ ( "name", "Name" ), ( "stage", "Stage" ), ( "quality", "Quality" ), ( "followup", "Follow-up" ) ]
                model.sortBy
                SortByChanged
            , div [ class "filter-group" ]
                [ label [] [ text "Direction" ]
                , button
                    [ class "btn btn-outline"
                    , Html.Attributes.style "width" "100%"
                    , onClick SortDirToggled
                    ]
                    [ text
                        (if model.sortAsc then
                            "↑ Ascending"

                         else
                            "↓ Descending"
                        )
                    ]
                ]
            ]
        ]


selectFieldMsg :
    String
    -> List ( String, String )
    -> String
    -> (String -> Msg)
    -> Html Msg
selectFieldMsg lbl opts current onChange =
    div [ class "filter-group" ]
        [ if lbl == "" then
            span [] []

          else
            Html.label [] [ text lbl ]
        , select [ onInput onChange ]
            (List.map
                (\( v, optLbl ) ->
                    option [ value v, selected (v == current) ] [ text optLbl ]
                )
                opts
            )
        ]


plainOptions : List String -> List ( String, String )
plainOptions =
    List.map (\s -> ( s, s ))


bulkBar : Model -> Html Msg
bulkBar model =
    if Set.isEmpty model.selected then
        div [] []

    else
        div [ class "bulk-actions" ]
        [ strong [] [ text (String.fromInt (Set.size model.selected) ++ " selected") ]
        , button [ class "btn btn-sm btn-success", onClick BulkAdvanceClicked ] [ text "Advance" ]
        , select [ onInput BulkAssignPicked ]
            (option [ value "" ] [ text "Assign consultant…" ]
                :: List.map
                    (\u -> option [ value (String.fromInt u.id) ] [ text u.name ])
                    model.users
            )
        , button [ class "btn btn-sm btn-danger", onClick BulkDeleteClicked ] [ text "Delete" ]
        ]


leadsTable : Model -> Html Msg
leadsTable model =
    let
        leads =
            visibleLeads model

        allChecked =
            not (List.isEmpty leads)
                && List.all (\l -> Set.member l.id model.selected) leads

        row l =
            tr
                [ class "clickable"
                , onClick (NavigateTo ("/leads/" ++ String.fromInt l.id))
                ]
                [ td []
                    [ input
                        [ type_ "checkbox"
                        , class "row-check"
                        , checked (Set.member l.id model.selected)
                        , Html.Events.stopPropagationOn "click"
                            (D.succeed
                                ( RowChecked l.id (not (Set.member l.id model.selected))
                                , True
                                )
                            )
                        ]
                        []
                    ]
                , td []
                    [ div [ class "lead-name" ] [ text l.fullName ]
                    , div [ class "lead-source" ] [ text (Maybe.withDefault "" l.email) ]
                    ]
                , td [] [ text l.number ]
                , td [] [ Ui.stageTag l.stage ]
                , td [] [ Ui.qualityTag l.quality ]
                , td [ class "lead-source" ] [ text (Maybe.withDefault "—" l.source) ]
                , td [] [ text (Maybe.withDefault "—" l.consultantName) ]
                , td [] [ text (Ui.fmtDate l.nextFollowup) ]
                ]
    in
    if List.isEmpty leads then
        Ui.emptyNote "No leads match your filters."

    else
        table [ class "data-table" ]
            [ thead []
                [ tr []
                    [ th [] [ input [ type_ "checkbox", class "row-check", checked allChecked, onCheck SelectAllChecked ] [] ]
                    , th [] [ text "Lead" ]
                    , th [] [ text "Number" ]
                    , th [] [ text "Stage" ]
                    , th [] [ text "Quality" ]
                    , th [] [ text "Source" ]
                    , th [] [ text "Consultant" ]
                    , th [] [ text "Follow-up" ]
                    ]
                ]
            , tbody [] (List.map row leads)
            ]


addLeadModal : Model -> Html Msg
addLeadModal model =
    let
        f =
            model.addLead
    in
    Ui.modal "Add Lead"
        (div []
            [ inputField "Full Name *" f.fullName "text" (\v -> UpdateAddLead (\g -> { g | fullName = v }))
            , inputField "Email" f.email "email" (\v -> UpdateAddLead (\g -> { g | email = v }))
            , inputField "Phone" f.phone "text" (\v -> UpdateAddLead (\g -> { g | phone = v }))
            , selectField "Source" Types.sources f.source (\v -> UpdateAddLead (\g -> { g | source = v }))
            , selectField "Quality" Types.qualities f.quality (\v -> UpdateAddLead (\g -> { g | quality = v }))
            , selectField "Stage" Types.leadStages f.stage (\v -> UpdateAddLead (\g -> { g | stage = v }))
            , selectField "Destination" Types.destinations f.destination (\v -> UpdateAddLead (\g -> { g | destination = v }))
            , selectField "Service" Types.services f.service (\v -> UpdateAddLead (\g -> { g | service = v }))
            , inputField "Next Follow-up" f.nextFollowup "date" (\v -> UpdateAddLead (\g -> { g | nextFollowup = v }))
            , inputField "Notes" f.notes "text" (\v -> UpdateAddLead (\g -> { g | notes = v }))
            , div [ class "flex", Html.Attributes.style "margin-top" "14px" ]
                [ button [ class "btn btn-primary", onClick SubmitAddLead ] [ text "Save Lead" ]
                , button [ class "btn btn-outline", onClick CloseAddLead ] [ text "Cancel" ]
                ]
            ]
        )


leadsView : Model -> Html Msg
leadsView model =
    div []
        [ div [ class "page-head" ]
            [ h2 [] [ text "Leads" ]
            , div [ class "results-summary" ]
                [ text
                    (String.fromInt model.leadsTotal
                        ++ (if model.leadsTotal == 1 then
                                " lead"

                            else
                                " leads"
                           )
                    )
                ]
            ]
        , leadsToolbar model
        , bulkBar model
        , div [ class "card table-card", Html.Attributes.style "margin-top" "12px" ]
            [ leadsTable model ]
        , pager
            { count = List.length model.leads
            , total = model.leadsTotal
            , limit = model.leadsLimit
            , offset = model.leadsOffset
            }
            LeadsOffsetChanged
        , if model.showAddLead then
            addLeadModal model

          else
            div [] []
        ]



-- ---------- lead detail ----------


leadDetailView : Model -> Int -> Html Msg
leadDetailView model id =
    case model.detail of
        Nothing ->
            Ui.spinner

        Just detail ->
            let
                l =
                    detail.lead
            in
            div []
                [ a [ class "back-link", href "#", onClick (NavigateTo "/leads") ] [ text "← Back to Leads" ]
                , div [ class "page-head" ]
                    [ div []
                        [ h2 [] [ text l.fullName ]
                        , div [ class "lead-detail-badges" ]
                            [ span [ class "tag tag-id" ] [ text l.number ]
                            , Ui.stageTag l.stage
                            , Ui.qualityTag l.quality
                            ]
                        ]
                    , div [ class "flex" ]
                        [ button [ class "btn", onClick EditLeadToggled ]
                            [ text
                                (if model.editLeadOpen then
                                    "Close Editor"

                                 else
                                    "Edit"
                                )
                            ]
                        , button [ class "btn", onClick (AdvanceClicked l.id) ] [ text "Advance ▸" ]
                        , button [ class "btn btn-success", onClick (ConvertClicked l.id) ] [ text "Convert to Client" ]
                        , button [ class "btn btn-danger", onClick (DeleteLeadConfirmed l.id) ] [ text "Delete" ]
                        ]
                    ]
                , div [ class "detail-grid" ]
                    [ div [ class "card" ]
                        [ div [ class "section-head" ] [ h3 [] [ text "Contact & Pipeline" ] ]
                        , if model.editLeadOpen then
                            editLeadForm model.editLead

                          else
                            contactGrid detail
                        ]
                    , div [ class "card" ]
                        [ div [ class "section-head" ]
                            [ h3 [] [ text "Tasks" ]
                            , button [ class "btn btn-sm btn-outline", onClick (UpdateAddTask (\f -> { f | title = f.title })) ]
                                [ text "+" ]
                            ]
                        , addTaskInline model id
                        , taskRows detail.tasks
                        ]
                    ]
                , div [ class "detail-grid", Html.Attributes.style "margin-top" "16px" ]
                    [ documentsCard model detail.documents (UploadLeadDocClicked id)
                    ]
                , div [ class "card", Html.Attributes.style "margin-top" "16px" ]
                    [ div [ class "section-head" ] [ h3 [] [ text "Activity Timeline" ] ]
                    , noteComposer model id
                    , timeline detail.activities
                    ]
                ]


contactGrid : LeadDetail -> Html msg
contactGrid detail =
    let
        l =
            detail.lead

        kv k v =
            div [ class "kv" ]
                [ div [] [ text k ]
                , div [] [ text v ]
                ]
    in
    div [ class "kv-grid" ]
        [ kv "Email" (Maybe.withDefault "—" l.email)
        , kv "Phone" (Maybe.withDefault "—" l.phone)
        , kv "Source" (Maybe.withDefault "—" l.source)
        , kv "Destination" (Maybe.withDefault "—" l.destination)
        , kv "Service" (Maybe.withDefault "—" l.service)
        , kv "Consultant" (Maybe.withDefault "—" l.consultantName)
        , kv "Last Contact" (Ui.fmtDate l.lastContact)
        , kv "Next Follow-up" (Ui.fmtDate l.nextFollowup)
        , kv "Notes" (Maybe.withDefault "—" l.notes)
        ]


editLeadForm : EditLeadForm -> Html Msg
editLeadForm f =
    div []
        [ inputField "Full Name" f.fullName "text" (\v -> UpdateEditLead (\g -> { g | fullName = v }))
        , inputField "Email" f.email "email" (\v -> UpdateEditLead (\g -> { g | email = v }))
        , inputField "Phone" f.phone "text" (\v -> UpdateEditLead (\g -> { g | phone = v }))
        , selectField "Stage" Types.leadStages f.stage (\v -> UpdateEditLead (\g -> { g | stage = v }))
        , selectField "Quality" Types.qualities f.quality (\v -> UpdateEditLead (\g -> { g | quality = v }))
        , selectField "Source" Types.sources f.source (\v -> UpdateEditLead (\g -> { g | source = v }))
        , selectField "Destination" Types.destinations f.destination (\v -> UpdateEditLead (\g -> { g | destination = v }))
        , selectField "Service" Types.services f.service (\v -> UpdateEditLead (\g -> { g | service = v }))
        , inputField "Last Contact" f.lastContact "date" (\v -> UpdateEditLead (\g -> { g | lastContact = v }))
        , inputField "Next Follow-up" f.nextFollowup "date" (\v -> UpdateEditLead (\g -> { g | nextFollowup = v }))
        , div [ class "form-group", Html.Attributes.style "grid-column" "1 / -1" ]
            [ label [] [ text "Notes" ]
            , Html.textarea
                [ class "input"
                , Html.Attributes.rows 3
                , value f.notes
                , onInput (\v -> UpdateEditLead (\g -> { g | notes = v }))
                ]
                []
            ]
        , div [ class "flex", Html.Attributes.style "grid-column" "1 / -1", Html.Attributes.style "margin-top" "8px" ]
            [ button [ class "btn btn-primary", onClick SubmitEditLead ] [ text "Save Changes" ]
            , button [ class "btn btn-outline", onClick EditLeadToggled ] [ text "Cancel" ]
            ]
        ]


addTaskInline : Model -> Int -> Html Msg
addTaskInline model leadId =
    div [ class "inline-form", Html.Attributes.style "margin-bottom" "10px" ]
        [ div [ class "form-group", Html.Attributes.style "flex" "2" ]
            [ input
                [ class "input"
                , placeholder "New task title…"
                , value model.addTask.title
                , onInput (\v -> UpdateAddTask (\f -> { f | title = v }))
                ]
                []
            ]
        , div [ class "form-group" ]
            [ input
                [ type_ "date"
                , class "input"
                , value model.addTask.dueDate
                , onInput (\v -> UpdateAddTask (\f -> { f | dueDate = v }))
                ]
                []
            ]
        , selectFieldMsg "" (plainOptions Types.priorities) model.addTask.priority
            (\v -> UpdateAddTask (\f -> { f | priority = v }))
        , button [ class "btn btn-sm btn-primary", onClick (SubmitAddTaskFor leadId) ]
            [ text "Add Task" ]
        ]


taskRows : List Task -> Html Msg
taskRows tasks =
    if List.isEmpty tasks then
        Ui.emptyNote "No tasks yet."

    else
        div []
            (List.map
                (\t ->
                    div [ class "task-row" ]
                        [ select
                            [ Html.Attributes.style "padding" "4px"
                            , Html.Attributes.style "border-radius" "6px"
                            , onInput (TaskStatusPicked t.id)
                            ]
                            (List.map
                                (\s ->
                                    option [ value s, selected (s == t.status) ] [ text s ]
                                )
                                Types.taskStatuses
                            )
                        , span
                            [ class
                                (if t.status == "Done" then
                                    "done-title"

                                 else
                                    ""
                                )
                            ]
                            [ text t.title ]
                        , Ui.priorityBadge t.priority
                        , span [ class "activity-date" ] [ text (Ui.fmtDate t.dueDate) ]
                        , button
                            [ class "btn btn-sm btn-outline"
                            , onClick (TaskDeleted t.id)
                            ]
                            [ text "✕" ]
                        ]
                )
                tasks
            )


noteComposer : Model -> Int -> Html Msg
noteComposer model leadId =
    div [ class "add-note", Html.Attributes.style "margin-bottom" "12px" ]
        [ input
            [ class "input"
            , placeholder "Log a note, call summary…"
            , value model.noteDraft
            , onInput NoteDraftChanged
            ]
            []
        , button [ class "btn btn-sm btn-primary", onClick (NoteSubmitted leadId) ]
            [ text "Add Note" ]
        ]


timeline : List Activity -> Html Msg
timeline activities =
    if List.isEmpty activities then
        Ui.emptyNote "No activity recorded."

    else
        div []
            (List.map
                (\act ->
                    div [ class "tl-item" ]
                        [ span [ class "tl-date" ] [ text act.date ]
                        , span [ class "tl-type" ] [ text act.kind ]
                        , span [ class "activity-desc" ] [ text (Maybe.withDefault "" act.description) ]
                        ]
                )
                activities
            )



-- ---------- documents ----------


{-| File picker + list of uploaded documents.  @uploadMsg@ decides whether
the file attaches to the lead or the client shown on the current page.
-}
documentsCard : Model -> List Document -> Msg -> Html Msg
documentsCard model docs uploadMsg =
    div [ class "card" ]
        [ div [ class "section-head" ]
            [ h3 [] [ text "Documents" ]
            , span [ class "lead-count" ] [ text (String.fromInt (List.length docs)) ]
            ]
        , div [ class "inline-form", Html.Attributes.style "margin-bottom" "10px" ]
            [ input
                [ type_ "file"
                , on
                    "change"
                    (D.map DocPicked
                        (D.at [ "target", "files" ] (D.index 0 File.decoder))
                    )
                ]
                []
            , span [ class "empty-note" ]
                [ text
                    (case model.pendingDoc of
                        Just file ->
                            File.name file

                        Nothing ->
                            "No file chosen"
                    )
                ]
            , button [ class "btn btn-sm btn-primary", onClick uploadMsg ]
                [ text "Upload" ]
            ]
        , documentRows model docs
        ]


documentRows : Model -> List Document -> Html Msg
documentRows model docs =
    if List.isEmpty docs then
        Ui.emptyNote "No documents yet — upload a passport, form, or scan."

    else
        div [] (List.map (documentRow model) docs)


documentRow : Model -> Document -> Html Msg
documentRow model d =
    let
        ctx =
            { base = model.apiBase, token = model.token }
    in
    div [ class "task-row" ]
        [ span [ Html.Attributes.title d.filename ]
            [ strong [] [ text d.filename ] ]
        , span [ class "activity-date" ] [ text (fmtSize d.size) ]
        , span [ class "activity-date" ] [ text (String.left 10 d.createdAt) ]
        , span [] [ text (Maybe.withDefault "" d.uploaderName) ]
        , a
            [ class "btn btn-sm btn-outline"
            , href (Api.documentDownloadUrl ctx d.id)
            , Html.Attributes.download ""
            ]
            [ text "Download" ]
        , button [ class "btn btn-sm btn-danger", onClick (DocDeleted d.id) ]
            [ text "Delete" ]
        ]



-- ---------- clients list ----------


clientsView : Model -> Html Msg
clientsView model =
    let
        visible =
            model.clients

        row c =
            tr
                [ class "clickable"
                , onClick (NavigateTo ("/clients/" ++ String.fromInt c.id))
                ]
                [ td []
                    [ div [ class "lead-name" ] [ text c.fullName ]
                    , div [ class "lead-source" ] [ text (Maybe.withDefault "" c.email) ]
                    ]
                , td [] [ text c.number ]
                , td [] [ text (Maybe.withDefault "—" c.phone) ]
                , td [] [ text (Maybe.withDefault "—" c.caseOfficerName) ]
                , td [ class "lead-source" ] [ text (Ui.fmtDateTime c.createdAt) ]
                ]
    in
    div []
        [ div [ class "page-head" ]
            [ h2 [] [ text "Clients" ]
            , div [ class "flex" ]
                [ a
                    [ class "btn btn-outline"
                    , href (Api.exportCsvUrl
                                { base = model.apiBase, token = model.token }
                                "clients")
                    , Html.Attributes.download ""
                    ]
                    [ text "Export CSV" ]
                , button [ class "btn btn-primary", onClick OpenAddClient ] [ text "+ Add Client" ]
                ]
            ]
        , div [ class "search-container" ]
            [ div [ class "search-row" ]
                [ div [ class "search-input-wrapper" ]
                    [ input
                        [ class "search-input"
                        , placeholder "Search clients…"
                        , value model.clientQ
                        , onInput ClientSearchChanged
                        ]
                        []
                    ]
                ]
            ]
        , div [ class "card table-card", Html.Attributes.style "margin-top" "12px" ]
            [ if List.isEmpty visible then
                Ui.emptyNote "No clients found."

              else
                table [ class "data-table" ]
                    [ thead []
                        [ tr []
                            [ th [] [ text "Client" ]
                            , th [] [ text "Number" ]
                            , th [] [ text "Phone" ]
                            , th [] [ text "Case Officer" ]
                            , th [] [ text "Since" ]
                            ]
                        ]
                    , tbody [] (List.map row visible)
                    ]
            ]
        , pager
            { count = List.length visible
            , total = model.clientsTotal
            , limit = model.clientsLimit
            , offset = model.clientsOffset
            }
            ClientsOffsetChanged
        , if model.showClientForm then
            clientFormModal model

          else
            div [] []
        ]


clientFormModal : Model -> Html Msg
clientFormModal model =
    let
        f =
            model.clientForm

        title =
            case model.clientEditingId of
                Just _ ->
                    "Edit Client"

                Nothing ->
                    "Add Client"
    in
    Ui.modal title
        (div []
            [ inputField "Full Name *" f.fullName "text" (\v -> UpdateClientForm (\g -> { g | fullName = v }))
            , inputField "Email" f.email "email" (\v -> UpdateClientForm (\g -> { g | email = v }))
            , inputField "Phone" f.phone "text" (\v -> UpdateClientForm (\g -> { g | phone = v }))
            , div [ class "form-group" ]
                [ label [] [ text "Case Officer" ]
                , select
                    [ onInput (\v -> UpdateClientForm (\g -> { g | officerId = v })) ]
                    (option [ value "" ] [ text "— none —" ]
                        :: List.map
                            (\u -> option
                                [ value (String.fromInt u.id)
                                , selected (Maybe.withDefault "" (Maybe.map String.fromInt (Just u.id)) == f.officerId)
                                ]
                                [ text u.name ]
                            )
                            model.users
                    )
                ]
            , div [ class "flex", Html.Attributes.style "margin-top" "14px" ]
                [ button [ class "btn btn-primary", onClick SubmitClientForm ] [ text "Save" ]
                , button [ class "btn btn-outline", onClick CloseClientForm ] [ text "Cancel" ]
                ]
            ]
        )



-- ---------- client detail ----------


clientDetailView : Model -> Int -> Html Msg
clientDetailView model cid =
    case model.clientDetail of
        Nothing ->
            Ui.spinner

        Just cd ->
            let
                c =
                    cd.client

                caseRow cr =
                    tr []
                        [ td [] [ text (Maybe.withDefault "—" cr.category) ]
                        , td [] [ text (Maybe.withDefault "—" cr.destination) ]
                        , td [] [ span [ class "tag tag-stage-blue" ] [ text cr.stage ] ]
                        , td [] [ text (Ui.fmtDate cr.deadline) ]
                        , td []
                            [ button
                                [ class "btn btn-sm btn-outline"
                                , onClick (OpenCaseForm (Just cr))
                                ]
                                [ text "Edit" ]
                            , a [ class "btn btn-sm btn-outline", href ("/workflow?case=" ++ String.fromInt cr.id) ] [ text "Checklist" ]
                            ]
                        , td []
                            [ button
                                [ class "btn btn-sm btn-danger"
                                , onClick (DeleteCaseClicked cr.id)
                                ]
                                [ text "Delete" ]
                            ]
                        ]
            in
            div []
                [ a [ class "back-link", href "#", onClick (NavigateTo "/clients") ] [ text "← Back to Clients" ]
                , div [ class "page-head" ]
                    [ div []
                        [ h2 [] [ text c.fullName ]
                        , div [ class "lead-detail-badges" ]
                            [ span [ class "tag tag-id" ] [ text c.number ]
                            ]
                        ]
                    , div [ class "flex" ]
                        [ button [ class "btn", onClick (OpenCaseForm Nothing) ] [ text "+ Add Case" ]
                        , button
                            [ class "btn"
                            , onClick (OpenClientEditor c.id)
                            ]
                            [ text "Edit" ]
                        , button [ class "btn btn-danger", onClick (DeleteClientConfirmed c.id) ] [ text "Delete" ]
                        ]
                    ]
                , div [ class "detail-grid" ]
                    [ div [ class "card" ]
                        [ div [ class "section-head" ] [ h3 [] [ text "Details" ] ]
                        , div [ class "kv-grid" ]
                            [ div [ class "kv" ] [ div [] [ text "Email" ], div [] [ text (Maybe.withDefault "—" c.email) ] ]
                            , div [ class "kv" ] [ div [] [ text "Phone" ], div [] [ text (Maybe.withDefault "—" c.phone) ] ]
                            , div [ class "kv" ] [ div [] [ text "Case Officer" ], div [] [ text (Maybe.withDefault "—" c.caseOfficerName) ] ]
                            , div [ class "kv" ] [ div [] [ text "Since" ], div [] [ text (Ui.fmtDateTime c.createdAt) ] ]
                            ]
                        ]
                    , div [ class "card table-card" ]
                        [ div [ class "section-head" ] [ h3 [] [ text "Cases" ] ]
                        , if List.isEmpty cd.cases then
                            Ui.emptyNote "No cases yet — add one."

                          else
                            table [ class "data-table" ]
                                [ thead []
                                    [ tr []
                                        [ th [] [ text "Service" ]
                                        , th [] [ text "Destination" ]
                                        , th [] [ text "Stage" ]
                                        , th [] [ text "Deadline" ]
                                        , th [] []
                                        , th [] []
                                        ]
                                    ]
                                , tbody [] (List.map caseRow cd.cases)
                                ]
                        ]
                    ]
                , div [ class "detail-grid", Html.Attributes.style "margin-top" "16px" ]
                    [ documentsCard model cd.documents (UploadClientDocClicked cd.client.id)
                    ]
                , case model.caseForm of
                    Just cf ->
                        caseModal cf cd

                    Nothing ->
                        div [] []
                ]


{-| Human-readable file size, rounded down to the nearest unit.
-}
fmtSize : Int -> String
fmtSize bytes =
    if bytes >= 1048576 then
        String.fromInt (bytes // 1048576) ++ " MB"

    else if bytes >= 1024 then
        String.fromInt (bytes // 1024) ++ " KB"

    else
        String.fromInt bytes ++ " B"


caseModal : CaseForm -> ClientDetail -> Html Msg
caseModal cf cd =
    Ui.modal
        (if cf.caseId == Nothing then
            "Add Case"

         else
            "Edit Case"
        )
        (div []
            [ selectField "Service Category" Types.services cf.category
                (\v -> UpdateCaseForm (\f -> { f | category = v }))
            , selectField "Destination" Types.destinations cf.destination
                (\v -> UpdateCaseForm (\f -> { f | destination = v }))
            , selectField "Stage" Types.caseStages cf.stage
                (\v -> UpdateCaseForm (\f -> { f | stage = v }))
            , inputField "Next Deadline" cf.deadline "date"
                (\v -> UpdateCaseForm (\f -> { f | deadline = v }))
            , div [ class "flex", Html.Attributes.style "margin-top" "14px" ]
                [ button [ class "btn btn-primary", onClick (SubmitCaseForm cd.client.id) ] [ text "Save Case" ]
                , button [ class "btn btn-outline", onClick CloseCaseForm ] [ text "Cancel" ]
                ]
            ]
        )



-- ---------- tasks page ----------


tasksView : Model -> Html Msg
tasksView model =
    let
        section status =
            let
                items =
                    List.filter (\t -> t.status == status) model.tasks
            in
            div [ class "card" ]
                [ div [ class "section-head" ]
                    [ h3 [] [ text status ]
                    , span [ class "lead-count" ] [ text (String.fromInt (List.length items)) ]
                    ]
                , if List.isEmpty items then
                    Ui.emptyNote "Nothing here."

                  else
                    div []
                        (List.map
                            (\t ->
                                div [ class "task-row" ]
                                    [ select
                                        [ Html.Attributes.style "padding" "4px"
                                        , onInput (TaskStatusPicked t.id)
                                        ]
                                        (List.map
                                            (\s ->
                                                option [ value s, selected (s == t.status) ]
                                                    [ text s ]
                                            )
                                            Types.taskStatuses
                                        )
                                    , span
                                        [ class
                                            (if t.status == "Done" then
                                                "done-title"

                                             else
                                                ""
                                            )
                                        ]
                                        [ strong [] [ text t.title ] ]
                                    , a
                                        [ class "task-lead"
                                        , href "#"
                                        , onClick (NavigateTo (if t.leadId > 0 then "/leads/" ++ String.fromInt t.leadId else "/workflow?tab=tasks"))
                                        ]
                                        [ text (Maybe.withDefault "" t.leadName) ]
                                    , Ui.priorityBadge t.priority
                                    , span [ class "activity-date" ] [ text (Ui.fmtDate t.dueDate) ]
                                    , button [ class "btn btn-sm btn-outline", onClick (TaskDeleted t.id) ]
                                        [ text "✕" ]
                                    ]
                            )
                            items
                        )
                ]
    in
    div []
        [ div [ class "page-head" ]
            [ h2 [] [ text "Tasks" ]
            , button [ class "btn btn-primary", onClick ToggleGlobalAddTask ]
                [ text
                    (if model.showGlobalAddTask then
                        "Close"

                     else
                        "+ New Task"
                    )
                ]
            ]
        , if model.showGlobalAddTask then
            globalAddTaskForm model

          else
            div [] []
        , div [ class "main-grid" ]
            [ section "Pending"
            , section "In Progress"
            ]
        , div [ class "card", Html.Attributes.style "margin-top" "16px" ]
            [ section "Done" ]
        ]


globalAddTaskForm : Model -> Html Msg
globalAddTaskForm model =
    div [ class "card", Html.Attributes.style "margin-bottom" "16px" ]
        [ div [ class "inline-form" ]
            [ div [ class "form-group", Html.Attributes.style "flex" "1.5" ]
                [ label [] [ text "Lead" ]
                , select
                    [ onInput (\v -> UpdateAddTask (\f -> { f | leadId = v })) ]
                    (option [ value "" ] [ text "Choose a lead…" ]
                        :: List.map
                            (\l ->
                                option
                                    [ value (String.fromInt l.id)
                                    , selected (model.addTask.leadId == String.fromInt l.id)
                                    ]
                                    [ text (l.number ++ " — " ++ l.fullName) ]
                            )
                            model.leads
                    )
                ]
            , div [ class "form-group", Html.Attributes.style "flex" "2" ]
                [ input
                    [ class "input"
                    , placeholder "Task title…"
                    , value model.addTask.title
                    , onInput (\v -> UpdateAddTask (\f -> { f | title = v }))
                    ]
                    []
                ]
            , div [ class "form-group" ]
                [ input
                    [ type_ "date"
                    , class "input"
                    , value model.addTask.dueDate
                    , onInput (\v -> UpdateAddTask (\f -> { f | dueDate = v }))
                    ]
                    []
                ]
            , selectFieldMsg "" (plainOptions Types.priorities) model.addTask.priority
                (\v -> UpdateAddTask (\f -> { f | priority = v }))
            , button [ class "btn btn-primary", onClick SubmitAddTaskGlobal ] [ text "Create" ]
            ]
        ]



-- ---------- users & account ----------


{-| Admin-only user management page.
-}
usersView : Model -> Html Msg
usersView model =
    let
        me_ =
            Maybe.withDefault { id = 0, email = "", name = "", role = "" } model.user
    in
    if me_.role /= "admin" then
        div [ class "card" ]
            [ Ui.emptyNote "Admin access required." ]

    else
        let
            userRow u =
                tr []
                    [ td [] [ text u.name ]
                    , td [] [ text u.email ]
                    , td []
                        [ span
                            [ class
                                (if u.role == "admin" then
                                    "tag tag-hot"

                                 else if u.role == "viewer" then
                                    "tag tag-cold"

                                 else
                                    "tag tag-warm"
                                )
                            ]
                            [ text u.role ]
                        ]
                    , td []
                        [ button
                            [ class "btn btn-sm btn-outline"
                            , onClick (OpenUserEditor u.id)
                            ]
                            [ text "Edit" ]
                        ]
                    , td []
                        [ button
                            [ class "btn btn-sm btn-danger"
                            , onClick (DeleteUserConfirmed u.id)
                            , Html.Attributes.disabled (u.id == me_.id)
                            ]
                            [ text
                                (if u.id == me_.id then
                                    "You"

                                 else
                                    "Delete"
                                )
                            ]
                        ]
                    ]
        in
        div []
            [ div [ class "page-head" ]
                [ div []
                    [ h2 [] [ text "Users" ]
                    , span [ class "empty-note" ]
                        [ text "Admins manage accounts. Viewers are read-only." ]
                    ]
                , div [ class "flex" ]
                    [ button [ class "btn btn-primary", onClick OpenAddUser ]
                        [ text "+ Add User" ]
                    ]
                ]
            , div [ class "card table-card" ]
                [ table [ class "data-table" ]
                    [ thead []
                        [ tr []
                            [ th [] [ text "Name" ]
                            , th [] [ text "Email" ]
                            , th [] [ text "Role" ]
                            , th [] []
                            , th [] []
                            ]
                        ]
                    , tbody [] (List.map userRow model.users)
                    ]
                ]
            ]


userFormModal : Model -> Html Msg
userFormModal model =
    let
        f =
            model.userForm

        editing =
            f.userId /= Nothing

        pwField =
            if editing then
                inputField "Password (leave blank to keep current)" f.password "password"
                    (\v -> UpdateUserForm (\g -> { g | password = v }))

            else
                inputField "Password (min 8 characters)" f.password "password"
                    (\v -> UpdateUserForm (\g -> { g | password = v }))
    in
    Ui.modal
        (if editing then
            "Edit User"

         else
            "Add User"
        )
        (div []
            [ inputField "Full Name" f.name "text"
                (\v -> UpdateUserForm (\g -> { g | name = v }))
            , if editing then
                div [ class "form-group" ]
                    [ label [] [ text "Email" ]
                    , div [ class "input", Html.Attributes.style "color" "#5B6572" ]
                        [ text f.email ]
                    ]

              else
                inputField "Email" f.email "email"
                    (\v -> UpdateUserForm (\g -> { g | email = v }))
            , selectField "Role" Types.roles f.role
                (\v -> UpdateUserForm (\g -> { g | role = v }))
            , pwField
            , div [ class "flex", Html.Attributes.style "margin-top" "14px" ]
                [ button [ class "btn btn-primary", onClick SubmitUserForm ] [ text "Save" ]
                , button [ class "btn btn-outline", onClick CloseUserForm ] [ text "Cancel" ]
                ]
            ]
        )


{-| Self-service password change, available to every signed-in role via the
header button.
-}
passwordModal : Model -> Html Msg
passwordModal model =
    Ui.modal "Change Password"
        (div []
            [ inputField "Current Password" model.pwCurrent "password" PwCurrentChanged
            , inputField "New Password (min 8 characters)" model.pwNew "password" PwNewChanged
            , inputField "Confirm New Password" model.pwConfirm "password" PwConfirmChanged
            , div [ class "flex", Html.Attributes.style "margin-top" "14px" ]
                [ button [ class "btn btn-primary", onClick SubmitPasswordChange ]
                    [ text "Update Password" ]
                , button [ class "btn btn-outline", onClick TogglePwModal ] [ text "Cancel" ]
                ]
            ]
        )



-- ---------- audit trail ----------


{-| Admin-only "who changed what and when" page.
-}
auditView : Model -> Html Msg
auditView model =
    let
        me_ =
            Maybe.withDefault { id = 0, email = "", name = "", role = "" } model.user
    in
    if me_.role /= "admin" then
        div [ class "card" ]
            [ Ui.emptyNote "Admin access required." ]

    else
        let
            actionTag action =
                span
                    [ class
                        (if action == "deleted" then
                            "tag tag-lost"

                         else if action == "created" then
                            "tag tag-converted"

                         else
                            "tag tag-stage-blue"
                        )
                    ]
                    [ text action ]

            entityLink e =
                case entityHref e of
                    Just path ->
                        a [ class "tag tag-id", href path ]
                            [ text (e.entityType ++ " #" ++ String.fromInt e.entityId) ]

                    Nothing ->
                        span [ class "tag tag-id" ] [ text e.entityType ]

            auditRow e =
                tr []
                    [ td [] [ text (Ui.fmtDateTime e.createdAt) ]
                    , td [] [ text (Maybe.withDefault "—" e.actorName) ]
                    , td [] [ actionTag e.action ]
                    , td [] [ text (Maybe.withDefault "" e.entityName) ]
                    , td [] [ entityLink e ]
                    , td [] (changeLines e.changes)
                    ]
        in
        div []
            [ div [ class "page-head" ]
                [ div []
                    [ h2 [] [ text "Audit Trail" ]
                    , span [ class "empty-note" ]
                        [ text "Every lead and client edit and deletion, with before/after values." ]
                    ]
                ]
            , div [ class "card table-card" ]
                [ if List.isEmpty model.audit then
                    Ui.emptyNote "No changes recorded yet."

                  else
                    table [ class "data-table" ]
                        [ thead []
                            [ tr []
                                [ th [] [ text "When" ]
                                , th [] [ text "Who" ]
                                , th [] [ text "Action" ]
                                , th [] [ text "Record" ]
                                , th [] [ text "Entity" ]
                                , th [] [ text "Changes" ]
                                ]
                            ]
                        , tbody [] (List.map auditRow model.audit)
                        ]
                ]
            ]


entityHref : AuditEntry -> Maybe String
entityHref e =
    case e.entityType of
        "lead" ->
            Just ("/leads/" ++ String.fromInt e.entityId)

        "client" ->
            Just ("/clients/" ++ String.fromInt e.entityId)

        _ ->
            Nothing


{-| Render the JSONB @{"Field":{"from":…,"to":…}}@ blob as one line per
changed field.
-}
changeLines : Maybe D.Value -> List (Html msg)
changeLines mv =
    case mv of
        Nothing ->
            []

        Just v ->
            case D.decodeValue (D.keyValuePairs changeEntry) v of
                Ok pairs ->
                    List.map
                        (\( field, diff ) ->
                            div [ class "activity-desc" ] [ text (field ++ ": " ++ diff) ]
                        )
                        pairs

                Err _ ->
                    [ div [ class "activity-desc" ] [ text (E.encode 0 v) ] ]


changeEntry : D.Decoder String
changeEntry =
    D.map2 (\from to -> from ++ " → " ++ to)
        (D.field "from" auditValueStr)
        (D.field "to" auditValueStr)


auditValueStr : D.Decoder String
auditValueStr =
    D.oneOf
        [ D.string
        , D.null "—"
        , D.map String.fromInt D.int
        , D.map (\b -> if b then "yes" else "no") D.bool
        ]



-- ---------- notifications & toasts ----------


overdueTasks : Model -> List Task
overdueTasks model =
    List.filter
        (\t ->
            t.status /= "Done"
                && t.dueDate
                /= Nothing
                && Maybe.withDefault True (Maybe.map (\d -> d < model.today) t.dueDate)
        )
        model.tasks


dueSoonTasks : Model -> List Task
dueSoonTasks model =
    List.filter
        (\t ->
            t.status /= "Done"
                && t.dueDate
                /= Nothing
                && Maybe.withDefault False
                    (Maybe.map
                        (\d -> d >= model.today && d <= addDaysStr model.today 3)
                        t.dueDate
                    )
        )
        model.tasks


addDaysStr : String -> Int -> String
addDaysStr iso days =
    case Date.fromIsoString iso of
        Ok d ->
            Date.toIsoString (Date.add Date.Days days d)

        Err _ ->
            iso


notificationsDropdown : Model -> Html Msg
notificationsDropdown model =
    let
        overdue =
            overdueTasks model

        dueSoon =
            dueSoonTasks model

        item t suffix =
            div
                [ class "notification-item unread"
                , onClick (NavigateTo (if t.leadId > 0 then "/leads/" ++ String.fromInt t.leadId else "/workflow?tab=tasks"))
                ]
                [ span [ class "notification-icon" ] [ text "⏰" ]
                , div [ class "notification-content" ]
                    [ div [ class "notification-title" ] [ text t.title ]
                    , div [ class "notification-subtitle" ]
                        [ text
                            (suffix
                                ++ " · "
                                ++ Maybe.withDefault "" t.leadName
                            )
                        ]
                    ]
                , span [ class "notification-dot" ] []
                ]
    in
    div [ class "notification-wrapper" ]
        [ button
            [ class
                ("notification-bell "
                    ++ (if not (List.isEmpty overdue) || not (List.isEmpty dueSoon) then
                            "has-notifications"

                        else
                            ""
                       )
                )
            , onClick NotifBellClicked
            ]
            [ text "🔔"
            , if not (List.isEmpty overdue) then
                span [ class "notification-badge" ]
                    [ text (String.fromInt (List.length overdue)) ]

              else
                span [] []
            ]
        , if model.notifOpen then
            div [ class "notification-dropdown" ]
                [ div [ class "notification-header" ]
                    [ text "Notifications" ]
                , div [ class "notification-list" ]
                    (List.map (\t -> item t "Overdue") overdue
                        ++ List.map (\t -> item t "Due soon") dueSoon
                        ++ (if List.isEmpty overdue && List.isEmpty dueSoon then
                                [ div [ class "notification-empty" ]
                                    [ text "Nothing needs your attention 🎉" ]
                                ]

                            else
                                []
                           )
                    )
                ]

          else
            span [] []
        ]


toastStack : Model -> Html Msg
toastStack model =
    if List.isEmpty model.toasts then
        span [] []

    else
        div [ class "toast-container" ]
            (List.map
                (\t ->
                    div
                        [ class
                            ("toast toast-"
                                ++ (case t.kind of
                                        "success" ->
                                            "success"

                                        "error" ->
                                            "error"

                                        _ ->
                                            "info"
                                   )
                            )
                        ]
                        [ text t.msg ]
                )
                model.toasts
            )
