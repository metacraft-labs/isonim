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
      let cardW = 220.0
      let cardH = 150.0
      let gapX = 48.0  # wider gap to fit arrows
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
        # Zoom controls
        tdiv(display = "flex", align_items = "center", gap = "8px"):
          tdiv(width = "28px", height = "28px",
               display = "flex", align_items = "center", justify_content = "center",
               border_radius = "4px", background_color = bgSurface,
               color = textSecondary, font_size = "14px", cursor = "pointer"):
            text "\xE2\x88\x92"
          span(font_size = "11px", color = textMuted,
               min_width = "36px", text_align = "center"):
            text "100%"
          tdiv(width = "28px", height = "28px",
               display = "flex", align_items = "center", justify_content = "center",
               border_radius = "4px", background_color = bgSurface,
               color = textSecondary, font_size = "14px", cursor = "pointer"):
            text "+"
        tdiv(padding = "4px 12px", border_radius = "4px",
             font_size = "11px", font_weight = "500",
             background_color = bgSurface, color = textMuted,
             cursor = "pointer"):
          text "Fit"

  # Canvas area
  let canvasArea = ui(r):
    tdiv(flex = "1", overflow = "auto", position = "relative",
         background_color = bgBase,
         background_image = "radial-gradient(circle, " & borderFaint & " 1px, transparent 1px)",
         background_size = "24px 24px")

  # Inner scrollable content
  let inner = ui(r):
    tdiv(position = "relative", min_width = "1200px",
         min_height = "600px", padding = "32px 40px")

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
             overflow = "hidden", display = "flex", flex_direction = "column"):

          # Card content: step number + contextual wireframe
          let stepNum = card.stepNum
          let lbl = stepLabel.toLowerAscii()
          let hasInput = "type" in lbl or "input" in lbl
          let hasTask = "tap" in lbl or "click" in lbl or "button" in lbl
          let isEmpty = "open" in lbl or "first" in lbl or "empty" in lbl
          let isFilter = "filter" in lbl or "active" in lbl or "completed" in lbl
          tdiv(flex = "1", display = "flex", flex_direction = "column",
               background_color = bgBase, gap = "0px",
               margin = "8px 8px 0 8px", border_radius = "4px",
               overflow = "hidden"):
            # Top: step number bar
            tdiv(display = "flex", align_items = "center", gap = "6px",
                 padding = "6px 10px",
                 background_color = bgSurface):
              tdiv(width = "18px", height = "18px", border_radius = "9px",
                   background_color = accent, opacity = "0.3",
                   display = "flex", align_items = "center",
                   justify_content = "center"):
                span(font_size = "9px", color = textPrimary, font_weight = "700"):
                  text $stepNum
              tdiv(height = "4px", width = "50%", border_radius = "2px",
                   background_color = gold, opacity = "0.3")
            # Body: contextual wireframe
            tdiv(display = "flex", flex_direction = "column",
                 gap = "4px", padding = "6px 10px", flex = "1"):
              # Input row (highlighted if typing step)
              tdiv(display = "flex", align_items = "center", gap = "4px"):
                tdiv(flex = "1", height = "10px", border_radius = "4px",
                     background_color = (if hasInput: bgSurface else: bgBase),
                     border = (if hasInput: "1px solid " & accent else: "1px solid " & border),
                     opacity = (if hasInput: "0.8" else: "0.4"))
                tdiv(width = "10px", height = "10px", border_radius = "5px",
                     background_color = (if hasTask: accent else: textDim),
                     opacity = (if hasTask: "0.6" else: "0.2"))
              # Task rows (shown/hidden based on step context)
              if not isEmpty:
                for j in 0..1:
                  tdiv(display = "flex", align_items = "center", gap = "4px"):
                    tdiv(width = "7px", height = "7px", border_radius = "2px",
                         border = "1px solid " & textDim, opacity = "0.3")
                    tdiv(height = "4px", flex = "1", border_radius = "2px",
                         background_color = textDim,
                         opacity = (if j == 0: "0.25" else: "0.15"))
              else:
                # Empty state indicator
                tdiv(display = "flex", align_items = "center",
                     justify_content = "center", flex = "1",
                     opacity = "0.2"):
                  span(font_size = "14px", color = textDim):
                    text "\xE2\x88\x85"  # empty set symbol
              # Filter bar (highlighted if filter step)
              if isFilter:
                tdiv(display = "flex", gap = "3px", margin_top = "2px"):
                  for k in 0..2:
                    tdiv(height = "5px", width = "20px", border_radius = "3px",
                         background_color = (if k == 1: accent else: textDim),
                         opacity = (if k == 1: "0.4" else: "0.15"))

          # Card label (the user action)
          tdiv(padding = "6px 10px", font_size = "10px",
               color = textSecondary, overflow = "hidden",
               line_height = "1.3"):
            text stepLabel

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

    rowY = cardsTop + 150 + 48  # card height + gap between flow rows

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
