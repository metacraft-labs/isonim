import std/[json, strutils]
import isonim/dsl/ui
import isonim/ssr/escape
const cardStyles* = """
#action { width:120px; height:48px; padding:8px; padding-top:1em; padding-right:2px; padding-bottom:3px; padding-left:4px; border-radius:4px; border-top-left-radius:1em; border-top-right-radius:2px; border-bottom-right-radius:3px; border-bottom-left-radius:4px; background-color:#112233; color:#FFFFFF; }
#reused-card { width:110px; height:40px; background-color:#224466; }
#secondary-action { width:160px; height:52px; padding:12px; border-radius:6px; background-color:#334455; color:#FFFFFF; }
"""
const alternateStyles* = """
#reused-alternate { width:210px; height:40px; background-color:#446688; }
#alternate-action { width:180px; height:56px; padding:10px; border-radius:8px; background-color:#556677; color:#FFFFFF; }
"""
# Deliberate project constraint used as a real compiler failure control. The
# native source transaction must restore the file/catalog after this assertion.
static:
  doAssert "width:777px" notin cardStyles
proc card(title, css, target: string): string =
  ui:
    html:
      head:
        title: text title
        style: raw css
      body:
        main:
          h1: text title
          button(id = target, `data-isonim-element-id` = target): text "Continue"
          button(id = (if target == "action": "reused-card" else: "reused-alternate"), `data-isonim-element-id` = "reused"): text "Shared authored identity"
          if target == "action":
            button(id = "secondary-action", `data-isonim-element-id` = "secondary-action"): text "Review"
var stories = newJArray()
stories.add(%* {"group":"Card", "name":"default ready", "kind":"component", "documentHtml":card("Ready card", cardStyles, "action")})
stories.add(%* {"group":"Alternate", "name":"default ready", "kind":"component", "documentHtml":card("Alternate card", alternateStyles, "alternate-action")})
echo $(%* {"stories":stories})
