## IsoNim Editor — Component Detail View.
##
## Shows actual Wanderlust components with the standard design system
## component page anatomy: hero, variants, props, guidelines, a11y.

import isonim/core/[signals, computation]
import isonim/dsl/ui
import isonim/editor/viewmodels
import isonim/editor/types
import examples/wanderlust/components/views as wViews
import examples/wanderlust/components/viewmodels as wVMs
import examples/wanderlust/mock_data as wData
import examples/wanderlust/foundations/tokens as wTokens

const
  bgBase = "#0B1120"
  bgSurface = "#1E293B"
  bgSidebar = "#111827"
  bgCard = "#151D2E"
  border = "#334155"
  borderFaint = "#1E293B"
  textPrimary = "#F1F5F9"
  textSecondary = "#94A3B8"
  textMuted = "#64748B"
  textDim = "#475569"
  accent = "#3B82F6"
  green = "#22C55E"
  red = "#EF4444"
  gold = "#F59E0B"

proc sectionLabel[R, E](r: R; title: string): E =
  ui(r):
    span(font_size = "11px", font_weight = "700", color = textSecondary,
         text_transform = "uppercase", letter_spacing = "1px"):
      text title

proc renderComponentDetail*[R, E](r: R; vm: EditorVM): E =
  let page = ui(r):
    tdiv(class = "editor-preview",
         flex = "1", display = "flex", flex_direction = "column",
         min_width = "0", height = "100%",
         background_color = bgBase, overflow_y = "auto")

  # Header bar
  let header = ui(r):
    tdiv(display = "flex", align_items = "center",
         justify_content = "space-between",
         height = "44px", min_height = "44px", padding = "0 20px",
         background_color = bgCard,
         border_bottom = "1px solid " & border):
      tdiv(display = "flex", align_items = "center", gap = "8px"):
        span(font_size = "11px", color = textDim):
          text "Components"
        span(font_size = "11px", color = textDim):
          text "\xE2\x80\xBA"
        span(font_size = "13px", font_weight = "600", color = textPrimary):
          text "DestinationCard"
      tdiv(display = "flex", align_items = "center", gap = "8px"):
        tdiv(padding = "4px 12px", border_radius = "4px",
             font_size = "11px", font_weight = "500",
             background_color = accent, color = textPrimary,
             cursor = "pointer"):
          text "Edit"
        tdiv(padding = "4px 12px", border_radius = "4px",
             font_size = "11px", font_weight = "500",
             background_color = bgSurface, color = textMuted,
             cursor = "pointer"):
          text "Code"
  r.appendChild(page, header)

  # Scrollable content
  let content = ui(r):
    tdiv(padding = "24px 32px", display = "flex",
         flex_direction = "column", gap = "32px")

  # === Section 1: Hero Example ===
  let heroSection = ui(r):
    tdiv(display = "flex", flex_direction = "column", gap = "12px")
  let heroLabel = sectionLabel[R, E](r, "DEFAULT STATE")
  r.appendChild(heroSection, heroLabel)
  # Real DestinationCard
  let heroCard = wViews.renderDestinationCard[R, E](r, wData.santoriniDest())
  r.appendChild(heroSection, heroCard)
  r.appendChild(content, heroSection)

  # === Section 2: Variants Gallery ===
  let variantsSection = ui(r):
    tdiv(display = "flex", flex_direction = "column", gap = "12px")
  let varLabel = sectionLabel[R, E](r, "VARIANTS")
  r.appendChild(variantsSection, varLabel)

  let varGrid = ui(r):
    tdiv(display = "flex", gap = "16px", flex_wrap = "wrap")
  # Render each destination as a variant
  let destinations = wData.allDestinations()
  for dest in destinations:
    let card = wViews.renderDestinationCard[R, E](r, dest)
    r.appendChild(varGrid, card)
  r.appendChild(variantsSection, varGrid)
  r.appendChild(content, variantsSection)

  # === Section 3: Props / API Table ===
  let propsSection = ui(r):
    tdiv(display = "flex", flex_direction = "column", gap = "12px")
  let propsLabel = sectionLabel[R, E](r, "PROPERTIES")
  r.appendChild(propsSection, propsLabel)

  let propsTable = ui(r):
    tdiv(background_color = bgCard, border = "1px solid " & border,
         border_radius = "8px", overflow = "hidden"):
      # Table header
      tdiv(display = "flex", padding = "8px 16px",
           background_color = bgSurface,
           border_bottom = "1px solid " & border):
        span(width = "120px", font_size = "10px", font_weight = "600",
             color = textSecondary):
          text "Name"
        span(width = "100px", font_size = "10px", font_weight = "600",
             color = textSecondary):
          text "Type"
        span(width = "80px", font_size = "10px", font_weight = "600",
             color = textSecondary):
          text "Default"
        span(flex = "1", font_size = "10px", font_weight = "600",
             color = textSecondary):
          text "Description"
  r.appendChild(propsSection, propsTable)

  # Props rows
  let propDefs = @[
    ("name", "string", "\"\"", "Destination display name"),
    ("country", "string", "\"\"", "Country name"),
    ("tagline", "string", "\"\"", "Short description shown below name"),
    ("rating", "float", "0.0", "Star rating (0.0 - 5.0)"),
    ("reviewCount", "int", "0", "Number of user reviews"),
    ("pricePerNight", "int", "0", "Average price per night in USD"),
    ("tags", "seq[string]", "@[]", "Category tags (Beach, Culture, Adventure, etc.)"),
    ("isSaved", "bool", "false", "Whether user has saved this destination"),
  ]
  for (pName, pType, pDefault, pDesc) in propDefs:
    let n = pName; let t = pType; let d = pDefault; let desc = pDesc
    let row = ui(r):
      tdiv(display = "flex", padding = "8px 16px",
           border_bottom = "1px solid " & borderFaint):
        span(width = "120px", font_size = "12px", color = accent,
             font_family = "'JetBrains Mono', monospace"):
          text n
        span(width = "100px", font_size = "11px", color = textMuted,
             font_family = "monospace"):
          text t
        span(width = "80px", font_size = "11px", color = textDim,
             font_family = "monospace"):
          text d
        span(flex = "1", font_size = "11px", color = textSecondary):
          text desc
    r.appendChild(propsTable, row)
  r.appendChild(content, propsSection)

  # === Section 4: Usage Guidelines (Do/Don't) ===
  let guidelinesSection = ui(r):
    tdiv(display = "flex", flex_direction = "column", gap = "12px")
  let guideLabel = sectionLabel[R, E](r, "USAGE GUIDELINES")
  r.appendChild(guidelinesSection, guideLabel)

  let guidelines = @[
    (true, "Use DestinationCard in a scrollable grid or carousel for discovery"),
    (false, "Use DestinationCard for trip itinerary items — use TripCard instead"),
    (true, "Show the save heart icon on all cards to encourage wishlisting"),
    (false, "Truncate the tagline — let it wrap to 2 lines naturally"),
    (true, "Show tags relevant to the user's search filters"),
    (false, "Show more than 4 tags — it clutters the card"),
  ]
  for guideline in guidelines:
    let isDo = guideline[0]; let gdesc = guideline[1]
    let rule = ui(r):
      tdiv(display = "flex", align_items = "center", gap = "10px",
           padding = "10px 16px", background_color = bgCard,
           border_radius = "6px",
           border_left = (if isDo: "3px solid " & green else: "3px solid " & red)):
        span(font_size = "12px", font_weight = "600",
             color = (if isDo: green else: red)):
          text(if isDo: "\xE2\x9C\x93 Do" else: "\xC3\x97 Don't")
        span(font_size = "12px", color = textSecondary):
          text gdesc
    r.appendChild(guidelinesSection, rule)
  r.appendChild(content, guidelinesSection)

  # === Section 5: Accessibility ===
  let a11ySection = ui(r):
    tdiv(display = "flex", flex_direction = "column", gap = "12px")
  let a11yLabel = sectionLabel[R, E](r, "ACCESSIBILITY")
  r.appendChild(a11ySection, a11yLabel)

  let a11yNotes = @[
    ("Keyboard", "Tab focuses the card, Enter opens destination detail, Space toggles save"),
    ("ARIA", "role=\"article\" with aria-label containing destination name and rating"),
    ("Screen Reader", "Announces: name, country, rating, price, saved status"),
    ("Color", "Rating stars use both color and shape; saved state uses both fill and icon change"),
  ]
  for a11yNote in a11yNotes:
    let atopic = a11yNote[0]; let adesc = a11yNote[1]
    let note = ui(r):
      tdiv(display = "flex", align_items = "flex-start", gap = "10px",
           padding = "10px 16px", background_color = bgCard,
           border_radius = "6px"):
        tdiv(padding = "2px 8px", border_radius = "4px",
             background_color = bgSurface, font_size = "10px",
             font_weight = "600", color = textSecondary,
             white_space = "nowrap"):
          text atopic
        span(font_size = "12px", color = textSecondary,
             line_height = "1.4"):
          text adesc
    r.appendChild(a11ySection, note)
  r.appendChild(content, a11ySection)

  # === Section 6: Related Components ===
  let relatedSection = ui(r):
    tdiv(display = "flex", flex_direction = "column", gap = "12px")
  let relLabel = sectionLabel[R, E](r, "RELATED")
  r.appendChild(relatedSection, relLabel)

  let relGrid = ui(r):
    tdiv(display = "flex", gap = "12px"):
      for rel in ["TripCard", "SearchBar", "FilterChip", "ReviewCard"]:
        tdiv(padding = "10px 16px", background_color = bgCard,
             border = "1px solid " & border, border_radius = "6px",
             cursor = "pointer"):
          span(font_size = "12px", color = accent):
            text rel
  r.appendChild(relatedSection, relGrid)
  r.appendChild(content, relatedSection)

  r.appendChild(page, content)
  page
