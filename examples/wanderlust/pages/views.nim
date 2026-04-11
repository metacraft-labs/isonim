## Wanderlust — Page Views
##
## Full page compositions using components + mock data.

import isonim/core/computation
import isonim/dsl/ui
import examples/wanderlust/foundations/tokens
import examples/wanderlust/components/viewmodels
import examples/wanderlust/components/views
import examples/wanderlust/mock_data

# ===========================================================================
# Home / Discover Page
# ===========================================================================

proc renderHomePage*[R, E](r: R): E =
  let dests = allDestinations()
  let trips = allTrips()
  let activeT = activeTrip()

  let page = ui(r):
    tdiv(width = "100%", min_height = "100%",
         background_color = colorBgSecondary,
         font_family = fontFamilyBody)

  # Nav bar
  let nav = ui(r):
    tdiv(display = "flex", align_items = "center",
         justify_content = "space-between",
         padding = space4 & "px " & space6 & "px",
         background_color = colorBgPrimary,
         box_shadow = elevationSm):
      span(font_family = fontFamilyDisplay, font_size = fontSizeXl & "px",
           font_weight = fontWeightBold, color = colorPrimary):
        text "Wanderlust"
      tdiv(display = "flex", align_items = "center", gap = space4 & "px"):
        span(font_size = fontSizeSm & "px", color = colorTextSecondary,
             cursor = "pointer"):
          text "Explore"
        span(font_size = fontSizeSm & "px", color = colorTextSecondary,
             cursor = "pointer"):
          text "My Trips"
        tdiv(width = "32px", height = "32px", border_radius = "16px",
             background_color = colorPrimarySubtle,
             display = "flex", align_items = "center", justify_content = "center",
             font_size = fontSizeSm & "px", font_weight = fontWeightBold,
             color = colorPrimary, cursor = "pointer"):
          text "A"
  r.appendChild(page, nav)

  # Search bar
  let searchSection = ui(r):
    tdiv(padding = space6 & "px " & space6 & "px " & space4 & "px")
  let searchBar = renderSearchBar[R, E](r)
  r.appendChild(searchSection, searchBar)
  r.appendChild(page, searchSection)

  # Active trip banner
  let banner = ui(r):
    tdiv(margin = "0 " & space6 & "px " & space4 & "px",
         padding = space4 & "px",
         background = "linear-gradient(135deg, " & colorPrimary & ", " & colorPrimaryDark & ")",
         border_radius = radiusLg & "px",
         display = "flex", align_items = "center",
         justify_content = "space-between"):
      tdiv:
        span(font_size = fontSizeXs & "px", color = colorTextInverse,
             opacity = "0.8", text_transform = "uppercase",
             letter_spacing = "1px", font_weight = fontWeightSemibold):
          text "CURRENTLY TRAVELING"
        tdiv(font_family = fontFamilyDisplay, font_size = fontSizeLg & "px",
             font_weight = fontWeightBold, color = colorTextInverse,
             margin_top = space1 & "px"):
          text activeT.name
        span(font_size = fontSizeSm & "px", color = colorTextInverse,
             opacity = "0.8"):
          text activeT.destination
      tdiv(padding = space2 & "px " & space4 & "px",
           border_radius = radiusMd & "px",
           background_color = "rgba(255,255,255,0.2)",
           color = colorTextInverse, font_size = fontSizeSm & "px",
           font_weight = fontWeightMedium, cursor = "pointer"):
        text "View Itinerary \xE2\x86\x92"
  r.appendChild(page, banner)

  # Trending section header
  let trendingHeader = ui(r):
    tdiv(display = "flex", justify_content = "space-between",
         align_items = "center", padding = space4 & "px " & space6 & "px"):
      span(font_family = fontFamilyDisplay, font_size = fontSizeLg & "px",
           font_weight = fontWeightBold, color = colorTextPrimary):
        text "Trending Destinations"
      span(font_size = fontSizeSm & "px", color = colorSecondary,
           cursor = "pointer", font_weight = fontWeightMedium):
        text "See all \xE2\x86\x92"
  r.appendChild(page, trendingHeader)

  # Destination cards
  let destGrid = ui(r):
    tdiv(display = "flex", gap = space4 & "px", padding = "0 " & space6 & "px",
         overflow_x = "auto")
  for i in 0 ..< min(4, dests.len):
    let card = renderDestinationCard[R, E](r, dests[i])
    r.appendChild(destGrid, card)
  r.appendChild(page, destGrid)

  # Trips section
  let tripsHeader = ui(r):
    tdiv(padding = space6 & "px " & space6 & "px " & space4 & "px"):
      span(font_family = fontFamilyDisplay, font_size = fontSizeLg & "px",
           font_weight = fontWeightBold, color = colorTextPrimary):
        text "Your Trips"
  r.appendChild(page, tripsHeader)

  let tripsGrid = ui(r):
    tdiv(display = "flex", gap = space4 & "px", padding = "0 " & space6 & "px " & space6 & "px",
         flex_wrap = "wrap")
  for trip in trips:
    let card = renderTripCard[R, E](r, trip)
    r.appendChild(tripsGrid, card)
  r.appendChild(page, tripsGrid)

  page

# ===========================================================================
# Destination Detail Page
# ===========================================================================

proc renderDestinationDetailPage*[R, E](r: R): E =
  let dest = santoriniDest()
  let reviews = santoriniReviews()
  let weather = santoriniWeather()

  let page = ui(r):
    tdiv(width = "100%", min_height = "100%",
         background_color = colorBgSecondary,
         font_family = fontFamilyBody)

  # Hero
  let hero = ui(r):
    tdiv(height = "200px", position = "relative",
         background = "linear-gradient(135deg, " & colorPrimary & " 0%, " & colorSecondary & " 50%, " & colorPrimaryDark & " 100%)"):
      tdiv(position = "absolute", top = space3 & "px", left = space3 & "px",
           width = "32px", height = "32px", border_radius = "16px",
           background_color = "rgba(0,0,0,0.3)",
           display = "flex", align_items = "center", justify_content = "center",
           color = colorTextInverse, cursor = "pointer"):
        text "\xE2\x86\x90"
      tdiv(position = "absolute", bottom = "0", left = "0", right = "0",
           padding = space5 & "px",
           background = "linear-gradient(transparent, rgba(0,0,0,0.7))"):
        span(font_family = fontFamilyDisplay, font_size = fontSize2xl & "px",
             font_weight = fontWeightBold, color = colorTextInverse):
          text dest.name
        tdiv(display = "flex", align_items = "center", gap = space2 & "px",
             margin_top = space1 & "px"):
          span(font_size = fontSizeMd & "px", color = colorTextInverse, opacity = "0.9"):
            text dest.country
          span(font_size = "12px", color = colorAccent):
            text "\xE2\x98\x85"
          span(font_size = fontSizeSm & "px", color = colorTextInverse):
            text $dest.rating & " (" & $dest.reviewCount & ")"
  r.appendChild(page, hero)

  # Quick stats
  let stats = ui(r):
    tdiv(display = "flex", gap = space3 & "px",
         padding = space4 & "px " & space5 & "px"):
      tdiv(flex = "1", padding = space3 & "px",
           background_color = colorBgPrimary,
           border_radius = radiusMd & "px",
           box_shadow = elevationSm, text_align = "center"):
        span(font_size = fontSizeLg & "px", font_weight = fontWeightBold,
             color = colorPrimary):
          text "$" & $dest.pricePerNight
        tdiv(font_size = fontSizeXs & "px", color = colorTextTertiary):
          text "per night"
      tdiv(flex = "1", padding = space3 & "px",
           background_color = colorBgPrimary,
           border_radius = radiusMd & "px",
           box_shadow = elevationSm, text_align = "center"):
        tdiv(display = "flex", justify_content = "center", gap = "2px"):
          for w in weather[0..2]:
            let ww = w
            span(font_size = "16px"):
              text ww.icon
        tdiv(font_size = fontSizeXs & "px", color = colorTextTertiary):
          text $weather[0].temp & "\xC2\xB0C avg"
  r.appendChild(page, stats)

  # Tags
  let tagsRow = ui(r):
    tdiv(display = "flex", gap = space2 & "px", flex_wrap = "wrap",
         padding = "0 " & space5 & "px " & space4 & "px")
  for tag in dest.tags:
    let chip = renderFilterChip[R, E](r, tag, false)
    r.appendChild(tagsRow, chip)
  r.appendChild(page, tagsRow)

  # CTA
  let cta = ui(r):
    tdiv(margin = "0 " & space5 & "px " & space4 & "px",
         padding = space4 & "px",
         background_color = colorPrimary,
         border_radius = radiusLg & "px",
         text_align = "center", cursor = "pointer",
         box_shadow = elevationMd):
      span(font_size = fontSizeMd & "px", font_weight = fontWeightSemibold,
           color = colorTextInverse):
        text "Plan a Trip \xE2\x86\x92"
  r.appendChild(page, cta)

  # Reviews
  let reviewHeader = ui(r):
    tdiv(padding = space4 & "px " & space5 & "px"):
      span(font_family = fontFamilyDisplay, font_size = fontSizeLg & "px",
           font_weight = fontWeightBold, color = colorTextPrimary):
        text "Reviews"
  r.appendChild(page, reviewHeader)

  let reviewList = ui(r):
    tdiv(display = "flex", flex_direction = "column",
         gap = space3 & "px", padding = "0 " & space5 & "px " & space5 & "px")
  for rev in reviews:
    let card = renderReviewCard[R, E](r, rev)
    r.appendChild(reviewList, card)
  r.appendChild(page, reviewList)

  page

# ===========================================================================
# Trip Day View
# ===========================================================================

proc renderTripDayPage*[R, E](r: R): E =
  let trip = activeTrip()
  let activities = moroccoDay3Activities()

  let page = ui(r):
    tdiv(width = "100%", min_height = "100%",
         background_color = colorBgSecondary,
         font_family = fontFamilyBody)

  # Header
  let header = ui(r):
    tdiv(padding = space4 & "px " & space5 & "px",
         background_color = colorBgPrimary,
         box_shadow = elevationSm):
      tdiv(display = "flex", align_items = "center", gap = space3 & "px"):
        span(font_size = "18px", color = colorTextSecondary, cursor = "pointer"):
          text "\xE2\x86\x90"
        tdiv(flex = "1"):
          span(font_family = fontFamilyDisplay, font_size = fontSizeLg & "px",
               font_weight = fontWeightBold, color = colorTextPrimary):
            text "Day 3 \xC2\xB7 Marrakech"
          tdiv(font_size = fontSizeSm & "px", color = colorTextTertiary):
            text trip.destination
        tdiv(padding = space2 & "px " & space3 & "px",
             border_radius = radiusMd & "px",
             background_color = colorPrimarySubtle,
             font_size = fontSizeSm & "px", color = colorPrimary,
             font_weight = fontWeightMedium):
          text "Edit Day"
  r.appendChild(page, header)

  # Budget summary
  let budget = ui(r):
    tdiv(margin = space4 & "px " & space5 & "px",
         padding = space3 & "px " & space4 & "px",
         background_color = colorBgPrimary,
         border_radius = radiusMd & "px",
         display = "flex", justify_content = "space-between",
         align_items = "center", box_shadow = elevationSm):
      tdiv:
        span(font_size = fontSizeXs & "px", color = colorTextTertiary,
             text_transform = "uppercase", letter_spacing = "0.5px"):
          text "DAY BUDGET"
        tdiv(font_size = fontSizeLg & "px", font_weight = fontWeightBold,
             color = colorTextPrimary):
          text "$174"
      span(font_size = fontSizeXs & "px", color = colorTextTertiary):
        text "6 activities"
  r.appendChild(page, budget)

  # Activities
  let actList = ui(r):
    tdiv(display = "flex", flex_direction = "column",
         gap = space2 & "px", padding = "0 " & space5 & "px " & space5 & "px")
  for act in activities:
    let item = renderActivityItem[R, E](r, act)
    r.appendChild(actList, item)
  r.appendChild(page, actList)

  page
