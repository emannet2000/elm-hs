module Ui exposing
    ( spinner
    , modal
    , qualityTag
    , stageTag
    , statusTag
    , priorityBadge
    , fmtDate
    , fmtDateTime
    , inputField
    , selectField
    , emptyNote
    )

{-| Small shared view helpers.
-}

import Html exposing (Html, div, span, text)
import Html.Attributes exposing (class, placeholder, selected, type_, value)
import Html.Events exposing (onInput)


spinner : Html msg
spinner =
    div [ class "text-center", Html.Attributes.style "padding" "40px" ]
        [ span [ class "spinner" ] [] ]


modal : String -> Html msg -> Html msg
modal title content =
    div [ class "modal-overlay" ]
        [ div [ class "modal-content" ]
            [ div [ class "section-head" ]
                [ Html.h3 [] [ text title ]
                ]
            , content
            ]
        ]


qualityTag : Maybe String -> Html msg
qualityTag q =
    case q of
        Just quality ->
            let
                cls =
                    case String.toLower quality of
                        "hot" -> "tag tag-hot"

                        "warm" -> "tag tag-warm"

                        "cold" -> "tag tag-cold"

                        _ -> "tag tag-cold"
            in
            span [ class cls ] [ text quality ]

        Nothing ->
            span [] []


stageClass : String -> String
stageClass stage =
    case stage of
        "Converted" -> "tag tag-converted"

        "Closed/Lost" -> "tag tag-lost"

        _ -> "tag tag-stage-blue"


stageTag : String -> Html msg
stageTag stage =
    span [ class (stageClass stage) ] [ text stage ]


statusTag : String -> Html msg
statusTag status =
    let
        cls =
            case status of
                "Done" -> "task-status Done"

                "In Progress" -> "task-status task-progress tag-progress"

                _ -> "task-status Pending"
    in
    span [ class cls ] [ text status ]


priorityBadge : String -> Html msg
priorityBadge priority =
    span [ class ("task-priority-badge " ++ String.toLower priority) ]
        [ text priority ]


fmtDate : Maybe String -> String
fmtDate md =
    Maybe.map (String.left 10) md |> Maybe.withDefault "—"


fmtDateTime : String -> String
fmtDateTime iso =
    String.slice 0 10 iso


inputField : String -> String -> String -> (String -> msg) -> Html msg
inputField label val typ onInputMsg =
    div [ class "form-group" ]
        [ Html.label [] [ text label ]
        , Html.input
            [ type_ typ
            , class "input"
            , value val
            , onInput onInputMsg
            ]
            []
        ]


selectField :
    String
    -> List String
    -> String
    -> (String -> msg)
    -> Html msg
selectField label opts current onInputMsg =
    div [ class "form-group" ]
        [ Html.label [] [ text label ]
        , Html.select [ onInput onInputMsg ]
            (List.map
                (\o ->
                    Html.option
                        [ Html.Attributes.value o
                        , selected (o == current)
                        ]
                        [ text o ]
                )
                opts
            )
        ]


emptyNote : String -> Html msg
emptyNote msg =
    div [ class "empty-note" ] [ text msg ]
