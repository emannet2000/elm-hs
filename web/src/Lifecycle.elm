module Lifecycle exposing
    ( leadStages
    , caseStages
    , nextLeadStage
    , leadCanAdvance
    , leadCanConvert
    , leadIsTerminal
    , allowedCaseTransitions
    , caseCanTransitionTo
    )

{-| Canonical ECC CRM lifecycle rules used by the Elm UI.

The database remains the final authority.  Keeping these rules in one frontend
module lets views present only valid actions instead of offering transitions
that PostgreSQL will reject.
-}


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


caseStages : List String
caseStages =
    [ "Submitted"
    , "Processing"
    , "Approved"
    , "Completed"
    , "Cancelled"
    , "Lost"
    ]


nextLeadStage : String -> Maybe String
nextLeadStage stage =
    case stage of
        "Lead" ->
            Just "Qualified"

        "Qualified" ->
            Just "Consultation"

        "Consultation" ->
            Just "Application/Deal"

        -- Conversion is a business action, not a plain stage edit.
        "Application/Deal" ->
            Nothing

        "Student/Client" ->
            Just "Completed"

        _ ->
            Nothing


leadCanAdvance : String -> Bool
leadCanAdvance stage =
    nextLeadStage stage /= Nothing


leadCanConvert : String -> Bool
leadCanConvert stage =
    stage == "Application/Deal"


leadIsTerminal : String -> Bool
leadIsTerminal stage =
    stage == "Completed" || stage == "Lost"


allowedCaseTransitions : String -> List String
allowedCaseTransitions stage =
    case stage of
        "Submitted" ->
            [ "Processing", "Cancelled", "Lost" ]

        "Processing" ->
            [ "Approved", "Cancelled", "Lost" ]

        "Approved" ->
            [ "Completed", "Cancelled", "Lost" ]

        _ ->
            []


caseCanTransitionTo : String -> String -> Bool
caseCanTransitionTo from to =
    from == to || List.member to (allowedCaseTransitions from)
