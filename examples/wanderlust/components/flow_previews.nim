## Wanderlust — Polished mini page previews for flow cards.
##
## At 400x480px these are legible app screens, not abstract wireframes.
## Uses real Wanderlust design tokens and realistic content.

import isonim/core/computation
import isonim/dsl/ui
import examples/wanderlust/foundations/tokens

# These render inside 400x~480px flow cards — large enough for real text.

proc renderMiniHome*[R, E](r: R): E =
  ## Home page: nav + search + active trip banner + destination cards.
  ui(r):
    tdiv(width = "100%", height = "100%", background_color = colorBgSecondary,
         font_family = fontFamilyBody, overflow = "hidden",
         display = "flex", flex_direction = "column"):
      # Nav bar
      tdiv(display = "flex", align_items = "center",
           justify_content = "space-between",
           padding = "8px 16px", background_color = colorBgPrimary,
           border_bottom = "1px solid " & colorNeutral200):
        span(font_family = fontFamilyDisplay, font_size = "13px",
             font_weight = fontWeightBold, color = colorPrimary):
          text "Wanderlust"
        tdiv(display = "flex", align_items = "center", gap = "10px"):
          span(font_size = "10px", color = colorTextSecondary):
            text "Explore"
          span(font_size = "10px", color = colorTextSecondary):
            text "My Trips"
          tdiv(width = "18px", height = "18px", border_radius = "9px",
               background_color = colorPrimarySubtle,
               display = "flex", align_items = "center", justify_content = "center",
               font_size = "8px", font_weight = fontWeightBold, color = colorPrimary):
            text "A"
      # Search bar
      tdiv(padding = "10px 16px"):
        tdiv(display = "flex", align_items = "center", gap = "8px",
             height = "28px", padding = "0 10px",
             background_color = colorBgPrimary, border_radius = "8px",
             border = "1px solid " & colorNeutral200):
          span(font_size = "11px", color = colorNeutral400):
            text "\xF0\x9F\x94\x8D"
          span(font_size = "10px", color = colorTextTertiary):
            text "Where do you want to go?"
      # Active trip banner
      tdiv(margin = "0 16px 8px",
           padding = "10px 12px",
           background = "linear-gradient(135deg, " & colorPrimary & ", " & colorPrimaryDark & ")",
           border_radius = "8px",
           display = "flex", align_items = "center",
           justify_content = "space-between"):
        tdiv:
          span(font_size = "7px", color = colorTextInverse, opacity = "0.7",
               text_transform = "uppercase", letter_spacing = "0.5px"):
            text "CURRENTLY TRAVELING"
          tdiv(font_family = fontFamilyDisplay, font_size = "11px",
               font_weight = fontWeightBold, color = colorTextInverse):
            text "Morocco Discovery"
          span(font_size = "8px", color = colorTextInverse, opacity = "0.7"):
            text "Marrakech & Sahara"
        span(font_size = "8px", color = colorTextInverse, opacity = "0.8"):
          text "View \xE2\x86\x92"
      # Section header
      tdiv(display = "flex", justify_content = "space-between",
           align_items = "center", padding = "6px 16px"):
        span(font_family = fontFamilyDisplay, font_size = "11px",
             font_weight = fontWeightBold, color = colorTextPrimary):
          text "Trending Destinations"
        span(font_size = "8px", color = colorSecondary):
          text "See all \xE2\x86\x92"
      # Destination cards row
      tdiv(display = "flex", gap = "8px", padding = "0 16px", flex = "1",
           overflow = "hidden"):
        for i, dest in [("Santorini", "Greece", "$185", "4.8"),
                         ("Kyoto", "Japan", "$142", "4.9")]:
          let dName = dest[0]; let dCountry = dest[1]
          let dPrice = dest[2]; let dRating = dest[3]
          tdiv(flex = "1", border_radius = "8px", overflow = "hidden",
               background_color = colorBgPrimary, box_shadow = elevationSm):
            tdiv(height = "50px",
                 background = (if i == 0: "linear-gradient(135deg, " & colorPrimary & ", " & colorSecondary & ")" else: "linear-gradient(135deg, " & colorAccent & ", " & colorSecondaryDark & ")"),
                 position = "relative"):
              tdiv(position = "absolute", bottom = "4px", left = "6px"):
                span(font_family = fontFamilyDisplay, font_size = "10px",
                     font_weight = fontWeightBold, color = colorTextInverse):
                  text dName
                tdiv(font_size = "7px", color = colorTextInverse, opacity = "0.8"):
                  text dCountry
            tdiv(padding = "6px 8px"):
              tdiv(display = "flex", justify_content = "space-between",
                   align_items = "center"):
                tdiv(display = "flex", align_items = "center", gap = "2px"):
                  span(font_size = "7px", color = colorAccentDark):
                    text "\xE2\x98\x85"
                  span(font_size = "8px", font_weight = fontWeightSemibold,
                       color = colorTextPrimary):
                    text dRating
                span(font_size = "9px", font_weight = fontWeightBold,
                     color = colorTextPrimary):
                  text dPrice

proc renderMiniDetail*[R, E](r: R): E =
  ## Destination Detail: hero + stats + tags + CTA + reviews header.
  ui(r):
    tdiv(width = "100%", height = "100%", background_color = colorBgSecondary,
         font_family = fontFamilyBody, overflow = "hidden",
         display = "flex", flex_direction = "column"):
      # Hero
      tdiv(height = "100px", position = "relative",
           background = "linear-gradient(135deg, " & colorPrimary & " 0%, " & colorSecondary & " 50%, " & colorPrimaryDark & " 100%)"):
        tdiv(position = "absolute", top = "8px", left = "10px",
             width = "20px", height = "20px", border_radius = "10px",
             background_color = "rgba(0,0,0,0.3)",
             display = "flex", align_items = "center", justify_content = "center",
             font_size = "10px", color = colorTextInverse):
          text "\xE2\x86\x90"
        tdiv(position = "absolute", bottom = "0", left = "0", right = "0",
             padding = "10px 14px",
             background = "linear-gradient(transparent, rgba(0,0,0,0.7))"):
          span(font_family = fontFamilyDisplay, font_size = "16px",
               font_weight = fontWeightBold, color = colorTextInverse):
            text "Santorini"
          tdiv(display = "flex", align_items = "center", gap = "6px",
               margin_top = "2px"):
            span(font_size = "9px", color = colorTextInverse, opacity = "0.9"):
              text "Greece"
            span(font_size = "8px", color = colorAccent):
              text "\xE2\x98\x85 4.8"
            span(font_size = "8px", color = colorTextInverse, opacity = "0.6"):
              text "(2,847 reviews)"
      # Stats
      tdiv(display = "flex", gap = "6px", padding = "8px 14px"):
        tdiv(flex = "1", padding = "6px", background_color = colorBgPrimary,
             border_radius = "6px", box_shadow = elevationSm, text_align = "center"):
          span(font_size = "12px", font_weight = fontWeightBold, color = colorPrimary):
            text "$185"
          tdiv(font_size = "7px", color = colorTextTertiary):
            text "per night"
        tdiv(flex = "1", padding = "6px", background_color = colorBgPrimary,
             border_radius = "6px", box_shadow = elevationSm, text_align = "center"):
          span(font_size = "12px"):
            text "\xE2\x98\x80"
          tdiv(font_size = "7px", color = colorTextTertiary):
            text "26\xC2\xB0C avg"
      # Tags
      tdiv(display = "flex", gap = "4px", padding = "4px 14px"):
        for tag in ["Beach", "Romance", "Photography"]:
          tdiv(padding = "2px 6px", border_radius = "8px",
               background_color = colorSecondarySubtle,
               font_size = "7px", color = colorSecondary):
            text tag
      # CTA
      tdiv(margin = "6px 14px", padding = "8px",
           background_color = colorPrimary, border_radius = "6px",
           text_align = "center"):
        span(font_size = "9px", font_weight = fontWeightSemibold,
             color = colorTextInverse):
          text "Plan a Trip to Santorini \xE2\x86\x92"
      # Reviews header
      tdiv(padding = "8px 14px"):
        span(font_family = fontFamilyDisplay, font_size = "11px",
             font_weight = fontWeightBold, color = colorTextPrimary):
          text "Reviews"
        # Mini review
        tdiv(margin_top = "6px", padding = "6px 8px",
             background_color = colorBgPrimary, border_radius = "6px",
             border = "1px solid " & colorNeutral200):
          tdiv(display = "flex", align_items = "center", gap = "4px"):
            tdiv(width = "16px", height = "16px", border_radius = "8px",
                 background_color = colorSecondarySubtle,
                 display = "flex", align_items = "center", justify_content = "center",
                 font_size = "7px", font_weight = fontWeightBold, color = colorSecondary):
              text "S"
            span(font_size = "8px", font_weight = fontWeightSemibold,
                 color = colorTextPrimary):
              text "Sarah Chen"
            tdiv(display = "flex", gap = "1px"):
              for j in 0..4:
                span(font_size = "6px", color = colorAccentDark):
                  text "\xE2\x98\x85"
          tdiv(font_size = "7px", color = colorTextSecondary,
               margin_top = "3px", line_height = "1.4"):
            text "Absolutely magical. The sunset from Oia was everything we dreamed of..."

proc renderMiniPlanner*[R, E](r: R): E =
  ## Trip Planner: header + date selector + empty day slots.
  ui(r):
    tdiv(width = "100%", height = "100%", background_color = colorBgSecondary,
         font_family = fontFamilyBody, overflow = "hidden",
         display = "flex", flex_direction = "column"):
      # Header
      tdiv(padding = "8px 14px", background_color = colorBgPrimary,
           border_bottom = "1px solid " & colorNeutral200):
        tdiv(display = "flex", align_items = "center", gap = "6px"):
          span(font_size = "12px", color = colorTextSecondary):
            text "\xE2\x86\x90"
          span(font_family = fontFamilyDisplay, font_size = "13px",
               font_weight = fontWeightBold, color = colorTextPrimary):
            text "Plan: Santorini Escape"
        tdiv(font_size = "8px", color = colorTextTertiary, margin_top = "2px",
             margin_left = "18px"):
          text "June 15 \xE2\x80\x93 June 22, 2026 \xC2\xB7 7 days"
      # Date row
      tdiv(display = "flex", gap = "4px", padding = "10px 14px"):
        for i in 0..6:
          let isActive = (i == 0)
          tdiv(width = "32px", height = "36px", border_radius = "8px",
               display = "flex", flex_direction = "column",
               align_items = "center", justify_content = "center",
               background_color = (if isActive: colorPrimary else: colorBgPrimary),
               border = (if isActive: "none" else: "1px solid " & colorNeutral200)):
            span(font_size = "6px",
                 color = (if isActive: colorTextInverse else: colorTextTertiary)):
              text ["Mon", "Tue", "Wed", "Thu", "Fri", "Sat", "Sun"][i]
            span(font_size = "10px", font_weight = fontWeightSemibold,
                 color = (if isActive: colorTextInverse else: colorTextPrimary)):
              text $(15 + i)
      # Empty day content
      tdiv(padding = "0 14px", flex = "1",
           display = "flex", flex_direction = "column", gap = "6px"):
        span(font_family = fontFamilyDisplay, font_size = "11px",
             font_weight = fontWeightBold, color = colorTextPrimary):
          text "Day 1 \xC2\xB7 Arrival"
        for i in 0..2:
          tdiv(height = "28px", border_radius = "6px",
               border = "1px dashed " & colorNeutral300,
               display = "flex", align_items = "center", justify_content = "center"):
            span(font_size = "8px", color = colorTextTertiary):
              text "+ Add activity"
        # Budget footer
        tdiv(margin_top = "auto", padding = "8px 0",
             display = "flex", justify_content = "space-between",
             border_top = "1px solid " & colorNeutral200):
          span(font_size = "8px", color = colorTextTertiary):
            text "Day budget"
          span(font_size = "9px", font_weight = fontWeightSemibold,
               color = colorTextPrimary):
            text "$0 / $450"

proc renderMiniDayView*[R, E](r: R): E =
  ## Day View: header + budget + activity timeline.
  ui(r):
    tdiv(width = "100%", height = "100%", background_color = colorBgSecondary,
         font_family = fontFamilyBody, overflow = "hidden",
         display = "flex", flex_direction = "column"):
      # Header
      tdiv(padding = "8px 14px", background_color = colorBgPrimary,
           border_bottom = "1px solid " & colorNeutral200):
        tdiv(display = "flex", align_items = "center", gap = "6px"):
          span(font_size = "12px", color = colorTextSecondary):
            text "\xE2\x86\x90"
          tdiv(flex = "1"):
            span(font_family = fontFamilyDisplay, font_size = "13px",
                 font_weight = fontWeightBold, color = colorTextPrimary):
              text "Day 3 \xC2\xB7 Marrakech"
            tdiv(font_size = "8px", color = colorTextTertiary):
              text "Marrakech & Sahara"
          tdiv(padding = "3px 8px", border_radius = "4px",
               background_color = colorPrimarySubtle,
               font_size = "8px", color = colorPrimary):
            text "Edit"
      # Budget bar
      tdiv(margin = "8px 14px", padding = "6px 10px",
           background_color = colorBgPrimary, border_radius = "6px",
           display = "flex", justify_content = "space-between",
           align_items = "center", box_shadow = elevationSm):
        tdiv:
          span(font_size = "7px", color = colorTextTertiary,
               text_transform = "uppercase"):
            text "DAY BUDGET"
          tdiv(font_size = "12px", font_weight = fontWeightBold,
               color = colorTextPrimary):
            text "$174"
        span(font_size = "8px", color = colorTextTertiary):
          text "6 activities"
      # Activity timeline
      tdiv(display = "flex", flex_direction = "column", gap = "4px",
           padding = "4px 14px", flex = "1", overflow = "hidden"):
        for act in [(colorSecondary, "09:30", "Jardin Majorelle", "2h", true),
                     (colorPrimary, "12:00", "Lunch at Nomad", "1.5h", false),
                     (colorNeutral500, "14:00", "Souk Shopping", "3h", false),
                     (colorAccentDark, "17:30", "Hammam Spa", "1.5h", true)]:
          let c = act[0]; let time = act[1]; let name = act[2]
          let dur = act[3]; let booked = act[4]
          tdiv(display = "flex", gap = "8px", padding = "4px 6px",
               background_color = colorBgPrimary, border_radius = "6px",
               border = "1px solid " & colorNeutral200):
            # Time + dot
            tdiv(display = "flex", flex_direction = "column",
                 align_items = "center", min_width = "30px"):
              span(font_size = "8px", font_weight = fontWeightSemibold,
                   color = colorTextPrimary):
                text time
              tdiv(width = "6px", height = "6px", border_radius = "3px",
                   background_color = c, margin_top = "2px")
            # Content
            tdiv(flex = "1"):
              span(font_size = "9px", font_weight = fontWeightMedium,
                   color = colorTextPrimary):
                text name
              tdiv(display = "flex", align_items = "center", gap = "4px",
                   margin_top = "1px"):
                span(font_size = "7px", color = colorTextTertiary):
                  text dur
                if booked:
                  span(font_size = "6px", color = colorSuccess,
                       font_weight = fontWeightMedium):
                    text "\xE2\x9C\x93 Booked"

proc renderMiniSearch*[R, E](r: R): E =
  ## Search Results: active search + filters + result cards.
  ui(r):
    tdiv(width = "100%", height = "100%", background_color = colorBgSecondary,
         font_family = fontFamilyBody, overflow = "hidden",
         display = "flex", flex_direction = "column"):
      # Active search bar
      tdiv(padding = "8px 14px"):
        tdiv(display = "flex", align_items = "center", gap = "6px",
             height = "28px", padding = "0 10px",
             background_color = colorBgPrimary, border_radius = "8px",
             border = "2px solid " & colorSecondary):
          span(font_size = "11px", color = colorNeutral400):
            text "\xF0\x9F\x94\x8D"
          span(font_size = "10px", color = colorTextPrimary):
            text "beach"
          tdiv(margin_left = "auto", width = "14px", height = "14px",
               border_radius = "7px", background_color = colorNeutral200,
               display = "flex", align_items = "center", justify_content = "center",
               font_size = "8px", color = colorTextSecondary):
            text "\xC3\x97"
      # Filter chips
      tdiv(display = "flex", gap = "4px", padding = "0 14px 8px"):
        for i, chip in ["Beach", "Budget", "\xE2\x98\x85 4+"]:
          let isActive = (i == 0)
          tdiv(padding = "3px 8px", border_radius = "10px",
               background_color = (if isActive: colorSecondary else: colorBgPrimary),
               border = "1px solid " & (if isActive: colorSecondary else: colorNeutral300),
               font_size = "8px",
               color = (if isActive: colorTextInverse else: colorTextSecondary)):
            text chip
      # Results count
      tdiv(padding = "0 14px 6px"):
        span(font_size = "8px", color = colorTextTertiary):
          text "12 destinations found"
      # Result cards grid
      tdiv(display = "flex", flex_wrap = "wrap", gap = "8px",
           padding = "0 14px", flex = "1"):
        for i, dest in [("Santorini", "$185", "4.8"),
                         ("Lisbon", "$95", "4.6"),
                         ("Bali", "$72", "4.7"),
                         ("Marrakech", "$78", "4.5")]:
          let dName = dest[0]; let dPrice = dest[1]; let dRating = dest[2]
          tdiv(width = "calc(50% - 4px)", border_radius = "6px",
               overflow = "hidden", background_color = colorBgPrimary,
               box_shadow = elevationSm):
            tdiv(height = "36px",
                 background = "linear-gradient(135deg, " & colorPrimary & ", " & colorSecondary & ")",
                 position = "relative"):
              tdiv(position = "absolute", bottom = "2px", left = "6px"):
                span(font_size = "8px", font_weight = fontWeightBold,
                     color = colorTextInverse):
                  text dName
            tdiv(padding = "4px 6px", display = "flex",
                 justify_content = "space-between", align_items = "center"):
              span(font_size = "8px", font_weight = fontWeightBold,
                   color = colorTextPrimary):
                text dPrice
              tdiv(display = "flex", align_items = "center", gap = "1px"):
                span(font_size = "6px", color = colorAccentDark):
                  text "\xE2\x98\x85"
                span(font_size = "7px", color = colorTextSecondary):
                  text dRating

proc renderMiniSaved*[R, E](r: R): E =
  ## Card with save heart animation — showing the moment of saving.
  ui(r):
    tdiv(width = "100%", height = "100%", background_color = colorBgSecondary,
         font_family = fontFamilyBody, overflow = "hidden",
         display = "flex", flex_direction = "column"):
      # Same search results context but with Lisbon card highlighted
      tdiv(padding = "8px 14px"):
        tdiv(height = "28px", padding = "0 10px",
             background_color = colorBgPrimary, border_radius = "8px",
             border = "2px solid " & colorSecondary,
             display = "flex", align_items = "center"):
          span(font_size = "10px", color = colorTextPrimary):
            text "\xF0\x9F\x94\x8D beach"
      # Cards — Lisbon highlighted with saved heart
      tdiv(display = "flex", flex_wrap = "wrap", gap = "8px",
           padding = "10px 14px", flex = "1"):
        for i, dest in [("Santorini", false), ("Lisbon", true),
                         ("Bali", false), ("Marrakech", false)]:
          let dName = dest[0]; let isSaved = dest[1]
          tdiv(width = "calc(50% - 4px)", border_radius = "6px",
               overflow = "hidden", background_color = colorBgPrimary,
               box_shadow = (if isSaved: elevationLg else: elevationSm),
               border = (if isSaved: "2px solid " & colorPrimary else: "none")):
            tdiv(height = "44px", position = "relative",
                 background = "linear-gradient(135deg, " & colorAccent & ", " & colorSecondaryDark & ")"):
              # Save heart
              tdiv(position = "absolute", top = "4px", right = "4px",
                   width = "18px", height = "18px", border_radius = "9px",
                   background_color = (if isSaved: colorPrimary else: "rgba(255,255,255,0.7)"),
                   display = "flex", align_items = "center", justify_content = "center",
                   font_size = "8px"):
                text(if isSaved: "\xE2\x9D\xA4" else: "\xE2\x99\xA1")
              tdiv(position = "absolute", bottom = "3px", left = "6px"):
                span(font_size = "9px", font_weight = fontWeightBold,
                     color = colorTextInverse):
                  text dName
            tdiv(padding = "4px 6px"):
              tdiv(height = "3px", width = "60%", border_radius = "2px",
                   background_color = colorTextSecondary, opacity = "0.2")

proc renderMiniBudget*[R, E](r: R): E =
  ## Trip summary with budget breakdown.
  ui(r):
    tdiv(width = "100%", height = "100%", background_color = colorBgSecondary,
         font_family = fontFamilyBody, overflow = "hidden",
         display = "flex", flex_direction = "column"):
      # Header
      tdiv(padding = "8px 14px", background_color = colorBgPrimary,
           border_bottom = "1px solid " & colorNeutral200):
        span(font_family = fontFamilyDisplay, font_size = "13px",
             font_weight = fontWeightBold, color = colorTextPrimary):
          text "Trip Summary"
        tdiv(font_size = "8px", color = colorTextTertiary, margin_top = "2px"):
          text "Santorini Escape \xC2\xB7 7 days \xC2\xB7 2 travelers"
      # Budget overview
      tdiv(padding = "10px 14px"):
        tdiv(display = "flex", justify_content = "space-between",
             align_items = "baseline"):
          span(font_size = "8px", color = colorTextTertiary):
            text "Total Budget"
          span(font_size = "16px", font_weight = fontWeightBold,
               color = colorTextPrimary):
            text "$3,200"
        # Progress bar
        tdiv(height = "6px", background_color = colorNeutral200,
             border_radius = "3px", margin_top = "6px"):
          tdiv(height = "100%", width = "75%", border_radius = "3px",
               background_color = colorSecondary)
        tdiv(display = "flex", justify_content = "space-between",
             font_size = "7px", color = colorTextTertiary, margin_top = "3px"):
          text "$2,400 spent"
          text "$800 remaining"
      # Category breakdown
      tdiv(padding = "8px 14px",
           display = "flex", flex_direction = "column", gap = "6px"):
        span(font_size = "9px", font_weight = fontWeightSemibold,
             color = colorTextPrimary):
          text "Breakdown"
        for cat in [("Flights", "$980", "31%", colorPrimary),
                     ("Accommodation", "$840", "26%", colorSecondary),
                     ("Activities", "$380", "12%", colorAccentDark),
                     ("Food & Dining", "$200", "6%", colorSuccess)]:
          let cName = cat[0]; let cAmount = cat[1]
          let cPct = cat[2]; let cColor = cat[3]
          tdiv(display = "flex", align_items = "center", gap = "6px"):
            tdiv(width = "6px", height = "6px", border_radius = "3px",
                 background_color = cColor)
            span(font_size = "8px", color = colorTextPrimary, flex = "1"):
              text cName
            span(font_size = "8px", color = colorTextSecondary):
              text cAmount
            span(font_size = "7px", color = colorTextTertiary):
              text cPct
      # Confirm button
      tdiv(margin = "auto 14px 10px",
           padding = "8px",
           background_color = colorPrimary, border_radius = "6px",
           text_align = "center"):
        span(font_size = "9px", font_weight = fontWeightSemibold,
             color = colorTextInverse):
          text "Confirm Trip \xE2\x9C\x93"
