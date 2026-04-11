## IsoNim Editor — Storyboard canvas View.
##
## Default landing view: freeform canvas showing screen thumbnails
## connected by flow arrows. Fully dogfoods the ui DSL with
## if/for/case inside the body. Manual setStyle only for dynamic
## pixel coordinates from layoutScreens().

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
  ScreenLayout = object
    x, y, w, h: float
    label: string
    kind: StoryKind
    groupName: string

proc layoutScreens(groups: seq[StoryGroup]): seq[ScreenLayout] =
  var x = 40.0
  var y = 40.0
  let cardW = 240.0
  let cardH = 160.0
  let gapX = 32.0
  let gapY = 48.0

  for group in groups:
    if group.kind == skFoundation:
      for item in group.items:
        result.add ScreenLayout(x: x, y: y, w: 210, h: 100,
                                label: item.name, kind: skFoundation,
                                groupName: "Foundations")
        x += 210 + gapX
  if x > 40.0: y += 100 + gapY + 20; x = 40.0

  for group in groups:
    if group.kind == skComponent:
      for item in group.items:
        result.add ScreenLayout(x: x, y: y, w: cardW, h: cardH,
                                label: group.name & " / " & item.name,
                                kind: skComponent, groupName: group.name)
        x += cardW + gapX
        if x > 1200: x = 40.0; y += cardH + gapY
  if x > 40.0: y += cardH + gapY; x = 40.0

  for group in groups:
    if group.kind == skPage:
      for item in group.items:
        result.add ScreenLayout(x: x, y: y, w: 280, h: 200,
                                label: item.name, kind: skPage,
                                groupName: "Pages")
        x += 280 + gapX
  if x > 40.0: y += 200 + gapY; x = 40.0

  for group in groups:
    if group.kind == skFlow:
      for item in group.items:
        result.add ScreenLayout(x: x, y: y, w: 200, h: 140,
                                label: item.name, kind: skFlow,
                                groupName: group.name)
        x += 200 + gapX
      y += 140 + gapY; x = 40.0

proc renderStoryboardCanvas*[R, E](r: R; vm: EditorVM): E =
  let canvas = ui(r):
    tdiv(class = "editor-preview",
         flex = "1", display = "flex", flex_direction = "column",
         min_width = "0", height = "100%",
         background_color = bgBase):

      # Toolbar — fully inline with DSL
      tdiv(display = "flex", align_items = "center",
           justify_content = "space-between",
           height = "44px", min_height = "44px", padding = "0 16px",
           background_color = bgCard,
           border_bottom = "1px solid " & border):
        span(font_size = "13px", font_weight = "600", color = textPrimary):
          text "Storyboard"
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

  # Canvas area — needs ref for appending positioned children
  let canvasArea = ui(r):
    tdiv(flex = "1", overflow = "auto", position = "relative",
         background_color = bgBase,
         background_image = "radial-gradient(circle, " & borderFaint & " 1px, transparent 1px)",
         background_size = "24px 24px")

  # Inner scrollable canvas with positioned cards
  let inner = ui(r):
    tdiv(position = "relative", min_width = "1400px",
         min_height = "1000px", padding = "20px")

  let screens = layoutScreens(vm.sidebar.groups.val)

  # Section labels — positioned absolutely, need dynamic top
  var drawnSections: seq[StoryKind] = @[]
  for sc in screens:
    if sc.kind notin drawnSections:
      drawnSections.add sc.kind
      let sectionName = case sc.kind
        of skFoundation: "FOUNDATIONS"
        of skComponent: "COMPONENTS"
        of skPage: "PAGES"
        of skFlow: "USER FLOWS"
      let sLabel = ui(r):
        tdiv(position = "absolute", left = "20px",
             font_size = "10px", font_weight = "700",
             color = textDim, letter_spacing = "1.5px"):
          text sectionName
      # Dynamic coordinate — legitimate setStyle usage
      r.setStyle(sLabel, "top", $(int(sc.y) - 28) & "px")
      r.appendChild(inner, sLabel)

  # Screen cards — positioned absolutely with dynamic coordinates
  for i, sc in screens:
    let kindIcon = case sc.kind
      of skFoundation:
        if "Color" in sc.label: "\xF0\x9F\x8E\xA8"
        elif "Typo" in sc.label: "Aa"
        else: "\xE2\x97\xBB"
      of skComponent: "\xF0\x9F\xA7\xA9"
      of skPage: "\xF0\x9F\x93\xB1"
      of skFlow: "\xE2\x96\xB6"

    let card = ui(r):
      tdiv(position = "absolute",
           background_color = bgCard,
           border = "1px solid " & border,
           border_radius = "8px", cursor = "pointer",
           transition = "border-color 0.15s, box-shadow 0.15s",
           overflow = "hidden", display = "flex", flex_direction = "column"):

        # Card preview content area
        tdiv(flex = "1", display = "flex", flex_direction = "column",
             align_items = "center", justify_content = "center",
             background_color = bgBase, gap = "4px",
             margin = "8px 8px 0 8px", border_radius = "4px",
             width = "auto", height = "auto"):
          # Wireframes — if/for inside DSL
          if sc.kind == skComponent:
            tdiv(display = "flex", flex_direction = "column",
                 gap = "6px", padding = "10px 16px", width = "100%"):
              for j in 0..1:
                tdiv(display = "flex", align_items = "center", gap = "8px"):
                  tdiv(width = "10px", height = "10px", border_radius = "2px",
                       border = "1.5px solid " & textMuted)
                  tdiv(height = "5px", flex = "1", border_radius = "3px",
                       background_color = textDim,
                       opacity = (if j == 0: "0.4" else: "0.25"))
          elif sc.kind == skPage:
            tdiv(display = "flex", flex_direction = "column",
                 gap = "5px", padding = "10px 16px", width = "100%"):
              tdiv(height = "8px", width = "45%", border_radius = "4px",
                   background_color = gold, opacity = "0.3")
              tdiv(height = "10px", width = "85%", border_radius = "5px",
                   background_color = textDim, opacity = "0.2")
              for j in 0..2:
                tdiv(height = "6px", width = "90%", border_radius = "3px",
                     background_color = textDim, opacity = "0.15")
          elif sc.kind == skFlow:
            span(font_size = "20px", opacity = "0.3"):
              text "\xE2\x96\xB6"
          else:
            span(font_size = "24px", opacity = "0.3"):
              text kindIcon

        # Card label
        tdiv(padding = "6px 10px", font_size = "11px",
             font_weight = "500", color = textSecondary,
             overflow = "hidden"):
          text sc.label

    # Dynamic positioning — the only setStyle needed per card
    r.setStyle(card, "left", $int(sc.x) & "px")
    r.setStyle(card, "top", $int(sc.y) & "px")
    r.setStyle(card, "width", $int(sc.w) & "px")
    r.setStyle(card, "height", $int(sc.h) & "px")
    r.appendChild(inner, card)

  # Flow arrows — positioned with dynamic coordinates
  var prevFlowX: int = 0
  var prevFlowY: int = 0
  var prevFlowW: int = 0
  var prevFlowH: int = 0
  var currentFlowGroup = ""
  for i, sc in screens:
    if sc.kind == skFlow:
      let scx = int(sc.x)
      let scy = int(sc.y)
      let scw = int(sc.w)
      let sch = int(sc.h)
      if sc.groupName == currentFlowGroup and prevFlowW > 0:
        let ax = prevFlowX + prevFlowW
        let aw = scx - ax
        let ay = scy + sch div 2 - 12
        if aw > 4:
          let arrow = ui(r):
            tdiv(position = "absolute", height = "24px",
                 display = "flex", align_items = "center",
                 justify_content = "center", z_index = "10"):
              tdiv(flex = "1", height = "2px",
                   background_color = accent)
              # CSS triangle arrowhead
              tdiv(width = "0", height = "0",
                   border_top = "6px solid transparent",
                   border_bottom = "6px solid transparent",
                   border_left = "8px solid " & accent)
          r.setStyle(arrow, "left", $ax & "px")
          r.setStyle(arrow, "top", $ay & "px")
          r.setStyle(arrow, "width", $aw & "px")
          r.appendChild(inner, arrow)
      currentFlowGroup = sc.groupName
      prevFlowX = scx; prevFlowY = scy
      prevFlowW = scw; prevFlowH = sch
    else:
      currentFlowGroup = ""; prevFlowW = 0

  r.appendChild(canvasArea, inner)

  # Minimap
  let minimap = ui(r):
    tdiv(position = "absolute", bottom = "12px", right = "12px",
         width = "140px", height = "90px",
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
