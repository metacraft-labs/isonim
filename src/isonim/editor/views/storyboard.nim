## IsoNim Editor — Storyboard canvas View.
##
## Default landing view: shows user flows as connected screen sequences.
## Only flow items appear on the canvas — foundations, components, and
## pages are accessed via the sidebar. This follows the Figma/Overflow
## pattern: canvas shows spatial relationships, sidebar shows details.

import std/strutils
import isonim/core/[signals, computation]
import isonim/dsl/[ui, components]
import isonim/editor/viewmodels
import isonim/editor/types
import examples/wanderlust/components/flow_previews as flowPreviews

const
  bgBase = "#0B1120"
  bgSurface = "#1E293B"
  bgCard = "#151D2E"
  border = "#334155"
  borderFaint = "#1E293B"
  textPrimary = "#F1F5F9"
  textSecondary = "#94A3B8"
  textMuted = "#64748B"
  textDim = "#475569"
  accent = "#3B82F6"
  gold = "#F59E0B"

type
  FlowRow = object
    ## A single user flow rendered as a horizontal sequence of cards.
    flowName: string
    flowDesc: string
    cards: seq[FlowCard]
  FlowCard = object
    x, y, w, h: float
    label: string
    stepNum: int

proc layoutFlows(groups: seq[StoryGroup]): seq[FlowRow] =
  ## Arrange only user flow groups as horizontal card sequences.
  for group in groups:
    if group.kind == skFlow:
      var row = FlowRow(flowName: group.name, flowDesc: group.description)
      var x = 0.0
      let cardW = 400.0
      let cardH = 520.0
      let gapX = 56.0
      for i, item in group.items:
        row.cards.add FlowCard(x: x, y: 0, w: cardW, h: cardH,
                               label: item.name, stepNum: i + 1)
        x += cardW + gapX
      result.add row

proc renderStoryboardCanvas*[R, E](r: R; vm: EditorVM): E =
  let flows = layoutFlows(vm.sidebar.groups.val)

  let canvas = ui(r):
    tdiv(class = "editor-preview",
         flex = "1", display = "flex", flex_direction = "column",
         min_width = "0", height = "100%",
         background_color = bgBase):

      # Toolbar
      tdiv(display = "flex", align_items = "center",
           justify_content = "space-between",
           height = "44px", min_height = "44px", padding = "0 16px",
           background_color = bgCard,
           border_bottom = "1px solid " & border):
        tdiv(display = "flex", align_items = "center", gap = "10px"):
          span(font_size = "13px", font_weight = "600", color = textPrimary):
            text "User Flows"
          span(font_size = "11px", color = textDim):
            text $(flows.len) & " flows"
        # Zoom controls (Figma-style)
        tdiv(display = "flex", align_items = "center", gap = "4px",
             background_color = bgSurface, border_radius = "6px",
             padding = "3px"):
          tdiv(width = "26px", height = "26px",
               display = "flex", align_items = "center", justify_content = "center",
               border_radius = "4px",
               color = textSecondary, font_size = "14px", cursor = "pointer"):
            text "\xE2\x88\x92"
          # Zoom slider track
          tdiv(width = "80px", height = "4px", border_radius = "2px",
               background_color = bgBase, position = "relative",
               cursor = "pointer"):
            # Slider thumb
            tdiv(position = "absolute", left = "50%", top = "-4px",
                 width = "12px", height = "12px", border_radius = "6px",
                 background_color = accent, margin_left = "-6px",
                 cursor = "grab", box_shadow = "0 1px 3px rgba(0,0,0,0.3)")
          tdiv(width = "26px", height = "26px",
               display = "flex", align_items = "center", justify_content = "center",
               border_radius = "4px",
               color = textSecondary, font_size = "14px", cursor = "pointer"):
            text "+"
          # Percentage label
          tdiv(padding = "0 6px", min_width = "36px", text_align = "center",
               font_size = "11px", color = textMuted,
               border_left = "1px solid " & border, margin_left = "2px"):
            text "100%"
        # Fit + Pan hint
        tdiv(display = "flex", align_items = "center", gap = "4px"):
          tdiv(padding = "4px 10px", border_radius = "4px",
               font_size = "11px", font_weight = "500",
               background_color = bgSurface, color = textMuted,
               cursor = "pointer"):
            text "Fit"
          span(font_size = "10px", color = textDim):
            text "Scroll to pan"

  # Canvas area
  let canvasArea = ui(r):
    tdiv(flex = "1", overflow = "auto", position = "relative",
         background_color = bgBase,
         background_image = "radial-gradient(circle, " & borderFaint & " 1px, transparent 1px)",
         background_size = "24px 24px")

  # Inner scrollable content
  let inner = ui(r):
    tdiv(position = "relative", min_width = "2400px",
         min_height = "1800px", padding = "32px 40px")

  # Render each flow as a labeled row of connected cards
  var rowY = 0.0
  for fi, flow in flows:
    let fName = flow.flowName
    let fDesc = flow.flowDesc
    let rowTop = int(rowY)

    # Flow title + description
    let flowHeader = ui(r):
      tdiv(position = "absolute", left = "0px",
           display = "flex", flex_direction = "column", gap = "2px"):
        tdiv(display = "flex", align_items = "center", gap = "8px"):
          tdiv(width = "20px", height = "20px", border_radius = "10px",
               background_color = accent, opacity = "0.2",
               display = "flex", align_items = "center", justify_content = "center"):
            span(font_size = "10px", color = accent, font_weight = "700"):
              text $(fi + 1)
          span(font_size = "13px", font_weight = "600", color = textPrimary):
            text fName
        span(font_size = "11px", color = textMuted, margin_left = "28px"):
          text fDesc
    r.setStyle(flowHeader, "top", $rowTop & "px")
    r.appendChild(inner, flowHeader)

    # Cards start below the header
    let cardsTop = rowY + 40
    for ci, card in flow.cards:
      let cx = int(card.x)
      let cy = int(cardsTop)
      let cw = int(card.w)
      let ch = int(card.h)
      let stepLabel = card.label

      let cardEl = ui(r):
        tdiv(position = "absolute",
             background_color = bgCard,
             border = "1px solid " & border,
             border_radius = "8px", cursor = "pointer",
             transition = "border-color 0.15s, box-shadow 0.15s",
             overflow = "hidden", display = "flex", flex_direction = "column")

      # Card content area: full mini preview (no overlay badge)
      let stepNum = card.stepNum
      let lbl = stepLabel.toLowerAscii()
      let cardContent = ui(r):
        tdiv(flex = "1", position = "relative",
             margin = "8px 8px 0 8px", border_radius = "8px",
             overflow = "hidden", background_color = "#FAFAF9",
             box_shadow = "inset 0 0 0 1px rgba(0,0,0,0.06)")
      r.appendChild(cardEl, cardContent)

      # Choose and render mini-preview based on step keywords
      let preview =
        if "home" in lbl or "browse" in lbl or "trending" in lbl or "opens" in lbl:
          flowPreviews.renderMiniHome[R, E](r)
        elif "detail" in lbl or ("taps" in lbl and "card" in lbl):
          flowPreviews.renderMiniDetail[R, E](r)
        elif "plan" in lbl or "building" in lbl or "date" in lbl:
          flowPreviews.renderMiniPlanner[R, E](r)
        elif "day" in lbl or "itinerary" in lbl or "view" in lbl or "timeline" in lbl:
          flowPreviews.renderMiniDayView[R, E](r)
        elif "search" in lbl or "type" in lbl or "beach" in lbl:
          flowPreviews.renderMiniSearch[R, E](r)
        elif "save" in lbl or "heart" in lbl or "favorite" in lbl:
          flowPreviews.renderMiniSaved[R, E](r)
        elif "budget" in lbl or "confirm" in lbl or "review" in lbl:
          flowPreviews.renderMiniBudget[R, E](r)
        elif "filter" in lbl or "applies" in lbl:
          flowPreviews.renderMiniSearch[R, E](r)
        elif "check" in lbl or "complete" in lbl or "mark" in lbl:
          flowPreviews.renderMiniDayView[R, E](r)
        elif "add" in lbl or "spontaneous" in lbl:
          flowPreviews.renderMiniDayView[R, E](r)
        else:
          flowPreviews.renderMiniHome[R, E](r)
      r.setStyle(preview, "position", "absolute")
      r.setStyle(preview, "inset", "0")
      r.appendChild(cardContent, preview)

      # Card label: "N. Action description"
      let cardLabel = ui(r):
        tdiv(padding = "8px 12px", font_size = "11px",
             color = textSecondary, overflow = "hidden",
             line_height = "1.4"):
          span(font_weight = "700", color = accent, font_size = "12px"):
            text $stepNum & ". "
          text stepLabel
      r.appendChild(cardEl, cardLabel)

      r.setStyle(cardEl, "left", $cx & "px")
      r.setStyle(cardEl, "top", $cy & "px")
      r.setStyle(cardEl, "width", $cw & "px")
      r.setStyle(cardEl, "height", $ch & "px")
      r.appendChild(inner, cardEl)

      # Arrow to next card (if not last)
      if ci < flow.cards.len - 1:
        let ax = cx + cw
        let nextX = int(flow.cards[ci + 1].x)
        let aw = nextX - ax
        let ay = cy + ch div 2 - 12
        if aw > 8:
          let arrow = ui(r):
            tdiv(position = "absolute", height = "24px",
                 display = "flex", align_items = "center",
                 z_index = "10"):
              # Line
              tdiv(flex = "1", height = "2px",
                   background_color = accent, opacity = "0.5")
              # Triangle arrowhead
              tdiv(width = "0", height = "0",
                   border_top = "6px solid transparent",
                   border_bottom = "6px solid transparent",
                   border_left = "8px solid " & accent,
                   opacity = "0.5")
          r.setStyle(arrow, "left", $ax & "px")
          r.setStyle(arrow, "top", $ay & "px")
          r.setStyle(arrow, "width", $aw & "px")
          r.appendChild(inner, arrow)

    rowY = cardsTop + 520 + 64  # card height + gap between flow rows

  # Empty state if no flows
  if flows.len == 0:
    let empty = ui(r):
      tdiv(position = "absolute", left = "0", right = "0",
           top = "0", bottom = "0",
           display = "flex", flex_direction = "column",
           align_items = "center", justify_content = "center",
           gap = "12px"):
        tdiv(font_size = "40px", opacity = "0.2"):
          text "\xF0\x9F\x8E\xAC"
        span(font_size = "14px", color = textMuted, font_weight = "500"):
          text "No user flows defined"
        span(font_size = "12px", color = textDim):
          text "The AI agent will generate flows from your components"
    r.appendChild(inner, empty)

  r.appendChild(canvasArea, inner)

  # Minimap
  let minimap = ui(r):
    tdiv(position = "absolute", bottom = "12px", right = "12px",
         width = "140px", height = "80px",
         background_color = bgCard,
         border = "1px solid " & border,
         border_radius = "6px", overflow = "hidden",
         box_shadow = "0 2px 8px rgba(0,0,0,0.3)"):
      span(font_size = "8px", color = textDim, padding = "4px",
           display = "block"):
        text "minimap"
  r.appendChild(canvasArea, minimap)

  r.appendChild(canvas, canvasArea)
  canvas
