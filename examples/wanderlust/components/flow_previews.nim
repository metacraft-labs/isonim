## Wanderlust — Mini page previews for storyboard flow cards.
##
## Tiny renderings of actual Wanderlust pages shown inside flow cards.
## Each is a compact version of a real page, not an abstract wireframe.

import isonim/core/computation
import isonim/dsl/ui
import examples/wanderlust/foundations/tokens

# These render at roughly 200x130px scale inside flow cards.
# They use the real Wanderlust tokens but simplified layouts.

proc renderMiniHome*[R, E](r: R): E =
  ## Mini Home page: nav + search + 2 destination cards.
  ui(r):
    tdiv(width = "100%", height = "100%", background_color = colorBgSecondary,
         font_family = fontFamilyBody, overflow = "hidden",
         display = "flex", flex_direction = "column"):
      # Mini nav
      tdiv(display = "flex", align_items = "center",
           justify_content = "space-between",
           padding = "4px 8px", background_color = colorBgPrimary):
        span(font_family = fontFamilyDisplay, font_size = "7px",
             font_weight = fontWeightBold, color = colorPrimary):
          text "Wanderlust"
        tdiv(width = "8px", height = "8px", border_radius = "4px",
             background_color = colorPrimarySubtle)
      # Mini search
      tdiv(margin = "4px 8px",
           height = "10px", border_radius = "5px",
           background_color = colorBgPrimary,
           border = "1px solid " & colorNeutral200)
      # Mini destination cards
      tdiv(display = "flex", gap = "4px", padding = "4px 8px", flex = "1"):
        for i in 0..1:
          tdiv(flex = "1", border_radius = "4px", overflow = "hidden",
               background_color = colorBgPrimary, box_shadow = elevationSm):
            tdiv(height = "20px",
                 background = (if i == 0: "linear-gradient(135deg, " & colorPrimary & ", " & colorSecondary & ")" else: "linear-gradient(135deg, " & colorAccent & ", " & colorSecondaryDark & ")"))
            tdiv(padding = "2px 4px"):
              tdiv(height = "3px", width = "60%", border_radius = "1px",
                   background_color = colorTextPrimary, opacity = "0.3")
              tdiv(height = "2px", width = "40%", border_radius = "1px",
                   background_color = colorTextTertiary, opacity = "0.3",
                   margin_top = "2px")

proc renderMiniDetail*[R, E](r: R): E =
  ## Mini Destination Detail: hero + stats + reviews.
  ui(r):
    tdiv(width = "100%", height = "100%", background_color = colorBgSecondary,
         font_family = fontFamilyBody, overflow = "hidden",
         display = "flex", flex_direction = "column"):
      # Mini hero
      tdiv(height = "36px", position = "relative",
           background = "linear-gradient(135deg, " & colorPrimary & ", " & colorSecondary & ")"):
        tdiv(position = "absolute", bottom = "2px", left = "6px"):
          tdiv(height = "4px", width = "40px", border_radius = "2px",
               background_color = colorTextInverse, opacity = "0.9")
          tdiv(height = "2px", width = "24px", border_radius = "1px",
               background_color = colorTextInverse, opacity = "0.5",
               margin_top = "1px")
      # Stats bar
      tdiv(display = "flex", gap = "3px", padding = "4px 6px"):
        tdiv(flex = "1", height = "14px", border_radius = "3px",
             background_color = colorBgPrimary, box_shadow = elevationSm,
             display = "flex", align_items = "center", justify_content = "center"):
          span(font_size = "5px", font_weight = fontWeightBold, color = colorPrimary):
            text "$185"
        tdiv(flex = "1", height = "14px", border_radius = "3px",
             background_color = colorBgPrimary, box_shadow = elevationSm,
             display = "flex", align_items = "center", justify_content = "center"):
          span(font_size = "5px", color = colorTextSecondary):
            text "\xE2\x98\x80 26\xC2\xB0"
      # Tags
      tdiv(display = "flex", gap = "2px", padding = "2px 6px"):
        for tag in ["Beach", "Romance"]:
          tdiv(padding = "1px 4px", border_radius = "6px",
               background_color = colorSecondarySubtle,
               font_size = "4px", color = colorSecondary):
            text tag
      # CTA button
      tdiv(margin = "3px 6px", padding = "3px",
           background_color = colorPrimary, border_radius = "3px",
           text_align = "center"):
        span(font_size = "4px", color = colorTextInverse, font_weight = fontWeightSemibold):
          text "Plan a Trip \xE2\x86\x92"

proc renderMiniPlanner*[R, E](r: R): E =
  ## Mini Trip Planner: header + empty day slots.
  ui(r):
    tdiv(width = "100%", height = "100%", background_color = colorBgSecondary,
         font_family = fontFamilyBody, overflow = "hidden",
         display = "flex", flex_direction = "column"):
      # Header
      tdiv(padding = "4px 8px", background_color = colorBgPrimary):
        tdiv(height = "3px", width = "50%", border_radius = "1px",
             background_color = colorTextPrimary, opacity = "0.3")
        tdiv(height = "2px", width = "30%", border_radius = "1px",
             background_color = colorTextTertiary, opacity = "0.3",
             margin_top = "2px")
      # Date picker
      tdiv(display = "flex", gap = "2px", padding = "4px 8px"):
        for i in 0..4:
          tdiv(width = "16px", height = "16px", border_radius = "8px",
               display = "flex", align_items = "center", justify_content = "center",
               background_color = (if i == 0: colorPrimary else: colorBgPrimary),
               border = "1px solid " & (if i == 0: colorPrimary else: colorNeutral200)):
            span(font_size = "4px",
                 color = (if i == 0: colorTextInverse else: colorTextSecondary)):
              text $(15 + i)
      # Empty day slots
      tdiv(display = "flex", flex_direction = "column", gap = "3px",
           padding = "4px 8px", flex = "1"):
        for i in 0..2:
          tdiv(height = "12px", border_radius = "3px",
               border = "1px dashed " & colorNeutral300,
               display = "flex", align_items = "center", justify_content = "center"):
            span(font_size = "4px", color = colorTextTertiary):
              text "+ Add activity"

proc renderMiniDayView*[R, E](r: R): E =
  ## Mini Day View: header + activity timeline.
  ui(r):
    tdiv(width = "100%", height = "100%", background_color = colorBgSecondary,
         font_family = fontFamilyBody, overflow = "hidden",
         display = "flex", flex_direction = "column"):
      # Header
      tdiv(padding = "4px 8px", background_color = colorBgPrimary):
        tdiv(display = "flex", align_items = "center", gap = "3px"):
          span(font_size = "6px", color = colorTextSecondary):
            text "\xE2\x86\x90"
          span(font_family = fontFamilyDisplay, font_size = "6px",
               font_weight = fontWeightBold, color = colorTextPrimary):
            text "Day 3"
      # Activities
      tdiv(display = "flex", flex_direction = "column", gap = "2px",
           padding = "4px 6px", flex = "1"):
        for i, act in [(colorSecondary, "Jardin Majorelle"),
                        (colorPrimary, "Lunch at Nomad"),
                        (colorAccentDark, "Hammam Spa")]:
          let c = act[0]; let n = act[1]
          tdiv(display = "flex", align_items = "center", gap = "3px",
               padding = "2px 4px", background_color = colorBgPrimary,
               border_radius = "2px"):
            tdiv(width = "4px", height = "4px", border_radius = "2px",
                 background_color = c)
            span(font_size = "4px", color = colorTextPrimary):
              text n

proc renderMiniSearch*[R, E](r: R): E =
  ## Mini Search Results: search bar + filter chips + card grid.
  ui(r):
    tdiv(width = "100%", height = "100%", background_color = colorBgSecondary,
         font_family = fontFamilyBody, overflow = "hidden",
         display = "flex", flex_direction = "column"):
      # Active search bar
      tdiv(margin = "4px 6px", height = "10px", border_radius = "5px",
           background_color = colorBgPrimary,
           border = "2px solid " & colorSecondary,
           display = "flex", align_items = "center", padding = "0 4px"):
        span(font_size = "4px", color = colorTextPrimary):
          text "beach"
      # Filter chips
      tdiv(display = "flex", gap = "2px", padding = "0 6px 3px"):
        for i, chip in ["Beach", "Budget", "Rating"]:
          tdiv(padding = "1px 4px", border_radius = "6px",
               background_color = (if i == 0: colorSecondary else: colorBgPrimary),
               border = "1px solid " & (if i == 0: colorSecondary else: colorNeutral300),
               font_size = "4px",
               color = (if i == 0: colorTextInverse else: colorTextSecondary)):
            text chip
      # Result cards
      tdiv(display = "flex", gap = "3px", padding = "0 6px", flex = "1"):
        for i in 0..1:
          tdiv(flex = "1", border_radius = "3px", overflow = "hidden",
               background_color = colorBgPrimary):
            tdiv(height = "16px",
                 background = "linear-gradient(135deg, " & colorAccent & ", " & colorSecondary & ")")
            tdiv(padding = "2px 3px"):
              tdiv(height = "2px", width = "70%", border_radius = "1px",
                   background_color = colorTextPrimary, opacity = "0.3")

proc renderMiniSaved*[R, E](r: R): E =
  ## Mini card with save heart animation.
  ui(r):
    tdiv(width = "100%", height = "100%", background_color = colorBgSecondary,
         font_family = fontFamilyBody, overflow = "hidden",
         display = "flex", align_items = "center", justify_content = "center"):
      tdiv(width = "80%", border_radius = "4px", overflow = "hidden",
           background_color = colorBgPrimary, box_shadow = elevationSm):
        tdiv(height = "28px", position = "relative",
             background = "linear-gradient(135deg, " & colorAccent & ", " & colorSecondaryDark & ")"):
          # Prominent save heart
          tdiv(position = "absolute", top = "3px", right = "3px",
               width = "12px", height = "12px", border_radius = "6px",
               background_color = colorPrimary,
               display = "flex", align_items = "center", justify_content = "center"):
            span(font_size = "6px", color = colorTextInverse):
              text "\xE2\x9D\xA4"
        tdiv(position = "absolute", bottom = "2px", left = "4px"):
          span(font_size = "5px", font_weight = fontWeightBold,
               color = colorTextInverse):
            text "Lisbon"
      tdiv(padding = "3px 4px"):
        tdiv(height = "2px", width = "60%", border_radius = "1px",
             background_color = colorTextSecondary, opacity = "0.3")

proc renderMiniBudget*[R, E](r: R): E =
  ## Mini trip summary with budget breakdown.
  ui(r):
    tdiv(width = "100%", height = "100%", background_color = colorBgSecondary,
         font_family = fontFamilyBody, overflow = "hidden",
         display = "flex", flex_direction = "column"):
      # Header
      tdiv(padding = "4px 8px", background_color = colorBgPrimary):
        span(font_family = fontFamilyDisplay, font_size = "6px",
             font_weight = fontWeightBold, color = colorTextPrimary):
          text "Trip Summary"
      # Budget bar
      tdiv(padding = "4px 8px"):
        tdiv(display = "flex", justify_content = "space-between",
             font_size = "4px", color = colorTextSecondary, margin_bottom = "2px"):
          text "$2,400 / $3,200"
        tdiv(height = "4px", background_color = colorNeutral200,
             border_radius = "2px"):
          tdiv(height = "100%", width = "75%", border_radius = "2px",
               background_color = colorSecondary)
      # Category breakdown
      tdiv(display = "flex", flex_direction = "column", gap = "2px",
           padding = "3px 8px"):
        for cat in [("Flights", "40%"), ("Hotels", "35%"), ("Activities", "25%")]:
          let cName = cat[0]; let cPct = cat[1]
          tdiv(display = "flex", align_items = "center", gap = "3px"):
            tdiv(width = "3px", height = "3px", border_radius = "1px",
                 background_color = colorSecondary)
            span(font_size = "4px", color = colorTextSecondary):
              text cName
            span(font_size = "4px", color = colorTextTertiary,
                 margin_left = "auto"):
              text cPct
