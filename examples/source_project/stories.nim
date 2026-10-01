## A real source-authored catalog used by the reusable editor source bridge.
## New fixture declarations are inserted at the marker by the project adapter.
import std/json
import isonim/dsl/ui
import isonim/ssr/escape

proc card(title: string): string =
  ui:
    html:
      head:
        title: text title
      body:
        main:
          h1: text title
          button(id = "action", `data-isonim-element-id` = "action"): text "Continue"

var stories = newJArray()
stories.add(%* {"group": "Card", "name": "default ready", "kind": "component", "documentHtml": card("Ready card")})
# ISONIM_STORY_FIXTURES

echo $(%* {"stories": stories})
