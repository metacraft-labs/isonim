## Wanderlust — Component Views
##
## Renders travel app components using IsoNim's ui DSL.
## All styling uses Wanderlust design tokens from foundations/tokens.nim.

import isonim/core/computation
import isonim/dsl/ui
import examples/wanderlust/foundations/tokens
import examples/wanderlust/components/viewmodels

# ===========================================================================
# DestinationCard
# ===========================================================================

proc renderDestinationCard*[R, E](r: R; dest: Destination): E =
  let saved = dest.isSaved
  ui(r):
    tdiv(width = "280px", border_radius = radiusLg & "px",
         overflow = "hidden", background_color = colorBgPrimary,
         box_shadow = elevationMd, cursor = "pointer",
         transition = "box-shadow " & durationNormal & " " & easingDefault):

      # Image placeholder (colored gradient based on destination)
      tdiv(height = "160px", position = "relative",
           background = "linear-gradient(135deg, " & colorPrimary & ", " & colorSecondary & ")"):
        # Destination name overlay
        tdiv(position = "absolute", bottom = "0", left = "0", right = "0",
             padding = space4 & "px " & space4 & "px",
             background = "linear-gradient(transparent, rgba(0,0,0,0.6))"):
          span(font_family = fontFamilyDisplay, font_size = fontSizeXl & "px",
               font_weight = fontWeightBold, color = colorTextInverse,
               line_height = lineHeightTight):
            text dest.name
          tdiv(font_size = fontSizeXs & "px", color = colorTextInverse,
               opacity = "0.8", margin_top = space1 & "px"):
            text dest.country
        # Save heart icon
        tdiv(position = "absolute", top = space3 & "px", right = space3 & "px",
             width = "32px", height = "32px", border_radius = radiusFull & "px",
             background_color = (if saved: colorPrimary else: "rgba(255,255,255,0.8)"),
             display = "flex", align_items = "center", justify_content = "center",
             font_size = "14px", cursor = "pointer"):
          text(if saved: "\xE2\x9D\xA4" else: "\xE2\x99\xA1")

      # Card body
      tdiv(padding = space4 & "px"):
        # Tagline
        span(font_size = fontSizeSm & "px", color = colorTextSecondary,
             line_height = lineHeightNormal,
             font_style = "italic"):
          text dest.tagline

        # Tags row
        tdiv(display = "flex", gap = space2 & "px", margin_top = space3 & "px",
             flex_wrap = "wrap"):
          for tag in dest.tags:
            let t = tag
            tdiv(padding = space1 & "px " & space2 & "px",
                 border_radius = radiusFull & "px",
                 background_color = colorSecondarySubtle,
                 font_size = fontSizeXs & "px", color = colorSecondary,
                 font_weight = fontWeightMedium):
              text t

        # Bottom row: rating + price
        tdiv(display = "flex", justify_content = "space-between",
             align_items = "center", margin_top = space3 & "px"):
          # Rating
          tdiv(display = "flex", align_items = "center", gap = space1 & "px"):
            span(font_size = "12px", color = colorAccentDark):
              text "\xE2\x98\x85"
            span(font_size = fontSizeSm & "px", font_weight = fontWeightSemibold,
                 color = colorTextPrimary):
              text $dest.rating
            span(font_size = fontSizeXs & "px", color = colorTextTertiary):
              text "(" & $dest.reviewCount & ")"
          # Price
          tdiv(display = "flex", align_items = "baseline", gap = "2px"):
            span(font_size = fontSizeLg & "px", font_weight = fontWeightBold,
                 color = colorTextPrimary):
              text "$" & $dest.pricePerNight
            span(font_size = fontSizeXs & "px", color = colorTextTertiary):
              text "/night"

# ===========================================================================
# TripCard
# ===========================================================================

proc renderTripCard*[R, E](r: R; trip: Trip): E =
  let statusColor = case trip.status
    of tsPlanning: colorAccent
    of tsUpcoming: colorSecondary
    of tsActive: colorPrimary
    of tsCompleted: colorSuccess
    of tsCancelled: colorNeutral400

  let statusLabel = case trip.status
    of tsPlanning: "Planning"
    of tsUpcoming: "Upcoming"
    of tsActive: "In Progress"
    of tsCompleted: "Completed"
    of tsCancelled: "Cancelled"

  let budgetPct = if trip.totalBudget > 0:
    (trip.spentBudget * 100) div trip.totalBudget else: 0

  ui(r):
    tdiv(width = "320px", border_radius = radiusLg & "px",
         overflow = "hidden", background_color = colorBgPrimary,
         box_shadow = elevationSm, border = "1px solid " & colorNeutral200):

      # Header with gradient
      tdiv(height = "80px", position = "relative",
           background = "linear-gradient(135deg, " & colorSecondaryDark & ", " & colorSecondary & ")"):
        tdiv(position = "absolute", bottom = space3 & "px", left = space4 & "px"):
          span(font_family = fontFamilyDisplay, font_size = fontSizeLg & "px",
               font_weight = fontWeightBold, color = colorTextInverse):
            text trip.name
        # Status badge
        tdiv(position = "absolute", top = space3 & "px", right = space3 & "px",
             padding = space1 & "px " & space2 & "px",
             border_radius = radiusFull & "px",
             background_color = statusColor, font_size = fontSizeXs & "px",
             font_weight = fontWeightSemibold, color = colorTextInverse):
          text statusLabel

      # Body
      tdiv(padding = space4 & "px", display = "flex",
           flex_direction = "column", gap = space3 & "px"):
        # Destination + dates
        tdiv:
          span(font_size = fontSizeSm & "px", color = colorTextSecondary):
            text trip.destination
          tdiv(font_size = fontSizeXs & "px", color = colorTextTertiary,
               margin_top = space1 & "px"):
            text trip.startDate & " \xE2\x86\x92 " & trip.endDate

        # Budget progress bar
        tdiv(display = "flex", flex_direction = "column", gap = space1 & "px"):
          tdiv(display = "flex", justify_content = "space-between",
               font_size = fontSizeXs & "px"):
            span(color = colorTextSecondary):
              text "Budget"
            span(color = colorTextTertiary):
              text "$" & $trip.spentBudget & " / $" & $trip.totalBudget
          tdiv(height = "6px", background_color = colorNeutral200,
               border_radius = "3px", overflow = "hidden"):
            tdiv(height = "100%", border_radius = "3px",
                 background_color = statusColor,
                 width = $budgetPct & "%")

        # Footer: travelers count
        tdiv(display = "flex", align_items = "center", gap = space2 & "px"):
          tdiv(display = "flex"):
            for i in 0 ..< trip.travelerCount:
              tdiv(width = "24px", height = "24px", border_radius = "12px",
                   background_color = colorNeutral300,
                   border = "2px solid " & colorBgPrimary,
                   margin_left = (if i > 0: "-8px" else: "0"))
          span(font_size = fontSizeXs & "px", color = colorTextTertiary):
            text $trip.travelerCount & " traveler" & (if trip.travelerCount > 1: "s" else: "")

# ===========================================================================
# ActivityItem
# ===========================================================================

proc renderActivityItem*[R, E](r: R; act: Activity): E =
  let catColor = case act.category
    of "Sightseeing": colorSecondary
    of "Food": colorPrimary
    of "Rest": colorAccentDark
    of "Transport": colorNeutral500
    else: colorNeutral400

  let catIcon = case act.category
    of "Sightseeing": "\xF0\x9F\x8F\x9B"
    of "Food": "\xF0\x9F\x8D\xBD"
    of "Rest": "\xF0\x9F\x92\x86"
    of "Transport": "\xF0\x9F\x9A\x97"
    else: "\xF0\x9F\x93\x8D"

  ui(r):
    tdiv(display = "flex", gap = space3 & "px", padding = space3 & "px " & space4 & "px",
         background_color = colorBgPrimary, border_radius = radiusMd & "px",
         border = "1px solid " & colorNeutral200):

      # Time column
      tdiv(display = "flex", flex_direction = "column", align_items = "center",
           min_width = "48px"):
        span(font_size = fontSizeSm & "px", font_weight = fontWeightSemibold,
             color = colorTextPrimary):
          text act.time
        span(font_size = fontSizeXs & "px", color = colorTextTertiary):
          text act.duration

      # Category dot + line
      tdiv(display = "flex", flex_direction = "column", align_items = "center",
           gap = "2px", padding_top = "4px"):
        tdiv(width = "10px", height = "10px", border_radius = "5px",
             background_color = catColor)
        tdiv(width = "2px", flex = "1", min_height = "20px",
             background_color = colorNeutral200)

      # Content
      tdiv(flex = "1", display = "flex", flex_direction = "column",
           gap = space1 & "px"):
        tdiv(display = "flex", align_items = "center", gap = space2 & "px"):
          span(font_size = "14px"):
            text catIcon
          span(font_size = fontSizeMd & "px", font_weight = fontWeightMedium,
               color = colorTextPrimary):
            text act.name
        span(font_size = fontSizeSm & "px", color = colorTextSecondary):
          text act.location
        if act.notes.len > 0:
          span(font_size = fontSizeXs & "px", color = colorTextTertiary,
               font_style = "italic"):
            text act.notes
        # Price + booked status
        tdiv(display = "flex", align_items = "center", gap = space2 & "px",
             margin_top = space1 & "px"):
          if act.price > 0:
            span(font_size = fontSizeSm & "px", font_weight = fontWeightSemibold,
                 color = colorTextPrimary):
              text "$" & $act.price
          if act.isBooked:
            tdiv(padding = "2px 6px", border_radius = radiusFull & "px",
                 background_color = colorSuccess, font_size = fontSizeXs & "px",
                 color = colorTextInverse, font_weight = fontWeightMedium,
                 opacity = "0.9"):
              text "\xE2\x9C\x93 Booked"

# ===========================================================================
# ReviewCard
# ===========================================================================

proc renderReviewCard*[R, E](r: R; rev: Review): E =
  let fullStars = int(rev.rating)
  ui(r):
    tdiv(padding = space4 & "px", background_color = colorBgPrimary,
         border_radius = radiusMd & "px",
         border = "1px solid " & colorNeutral200):
      # Author row
      tdiv(display = "flex", align_items = "center", gap = space3 & "px"):
        tdiv(width = "36px", height = "36px", border_radius = "18px",
             background_color = colorSecondarySubtle,
             display = "flex", align_items = "center", justify_content = "center",
             font_size = fontSizeSm & "px", font_weight = fontWeightBold,
             color = colorSecondary):
          text $rev.authorName[0]
        tdiv(flex = "1"):
          span(font_size = fontSizeSm & "px", font_weight = fontWeightSemibold,
               color = colorTextPrimary):
            text rev.authorName
          tdiv(font_size = fontSizeXs & "px", color = colorTextTertiary):
            text rev.date
        # Stars
        tdiv(display = "flex", gap = "1px"):
          for i in 1..5:
            span(font_size = "12px",
                 color = (if i <= fullStars: colorAccentDark else: colorNeutral300)):
              text "\xE2\x98\x85"

      # Review text
      tdiv(margin_top = space3 & "px", font_size = fontSizeSm & "px",
           color = colorTextSecondary, line_height = lineHeightRelaxed):
        text rev.text

      # Helpful count
      tdiv(display = "flex", align_items = "center", gap = space2 & "px",
           margin_top = space3 & "px"):
        tdiv(padding = space1 & "px " & space2 & "px",
             border_radius = radiusSm & "px", border = "1px solid " & colorNeutral200,
             font_size = fontSizeXs & "px", color = colorTextTertiary,
             cursor = "pointer"):
          text "\xF0\x9F\x91\x8D " & $rev.helpfulCount & " helpful"

# ===========================================================================
# SearchBar
# ===========================================================================

proc renderSearchBar*[R, E](r: R; query: string = "";
                             suggestions: seq[string] = @[]): E =
  let hasQuery = query.len > 0
  ui(r):
    tdiv(display = "flex", flex_direction = "column", width = "100%",
         position = "relative"):
      # Search input row
      tdiv(display = "flex", align_items = "center", gap = space3 & "px",
           height = "48px", padding = "0 " & space4 & "px",
           background_color = colorBgPrimary, border_radius = radiusLg & "px",
           border = "2px solid " & (if hasQuery: colorSecondary else: colorNeutral200),
           box_shadow = (if hasQuery: elevationMd else: elevationSm)):
        span(font_size = "18px", color = colorNeutral400):
          text "\xF0\x9F\x94\x8D"
        tdiv(flex = "1", font_size = fontSizeMd & "px",
             color = (if hasQuery: colorTextPrimary else: colorTextTertiary)):
          text(if hasQuery: query else: "Where do you want to go?")
        if hasQuery:
          tdiv(width = "24px", height = "24px", border_radius = "12px",
               background_color = colorNeutral200,
               display = "flex", align_items = "center", justify_content = "center",
               font_size = "12px", color = colorTextSecondary, cursor = "pointer"):
            text "\xC3\x97"

      # Suggestions dropdown
      if suggestions.len > 0:
        tdiv(position = "absolute", top = "52px", left = "0", right = "0",
             background_color = colorBgPrimary, border_radius = radiusMd & "px",
             box_shadow = elevationLg, border = "1px solid " & colorNeutral200,
             overflow = "hidden", z_index = "100"):
          for s in suggestions:
            let sug = s
            tdiv(padding = space3 & "px " & space4 & "px",
                 font_size = fontSizeSm & "px", color = colorTextSecondary,
                 cursor = "pointer"):
              text sug

# ===========================================================================
# FilterChip
# ===========================================================================

proc renderFilterChip*[R, E](r: R; label: string; selected: bool): E =
  ui(r):
    tdiv(padding = space2 & "px " & space3 & "px",
         border_radius = radiusFull & "px",
         background_color = (if selected: colorSecondary else: colorBgPrimary),
         color = (if selected: colorTextInverse else: colorTextSecondary),
         border = "1px solid " & (if selected: colorSecondary else: colorNeutral300),
         font_size = fontSizeSm & "px", font_weight = fontWeightMedium,
         cursor = "pointer",
         transition = "all " & durationFast & " " & easingDefault):
      text label

# ===========================================================================
# WeatherBadge
# ===========================================================================

proc renderWeatherBadge*[R, E](r: R; weather: WeatherInfo): E =
  ui(r):
    tdiv(display = "flex", align_items = "center", gap = space1 & "px",
         padding = space1 & "px " & space2 & "px",
         border_radius = radiusMd & "px",
         background_color = colorAccentSubtle):
      span(font_size = "14px"):
        text weather.icon
      span(font_size = fontSizeSm & "px", font_weight = fontWeightMedium,
           color = colorTextPrimary):
        text $weather.temp & "\xC2\xB0"
