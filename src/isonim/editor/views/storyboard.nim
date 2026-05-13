## IsoNim Editor — Storyboard canvas View.
##
## Default landing view: shows user flows as connected screen sequences.
## Only flow items appear on the canvas — foundations, components, and
## pages are accessed via the sidebar. This follows the Figma/Overflow
## pattern: canvas shows spatial relationships, sidebar shows details.

import isonim/core/[signals, computation]
import isonim/dsl/ui
import isonim/editor/viewmodels
import isonim/editor/types

const
  bgBase = "#0D0E14"
  bgSurface = "#1A1B26"
  bgCard = "#15161F"
  border = "#2A2C3A"
  borderFaint = "#1F212C"
  textPrimary = "#ECEDF3"
  textSecondary = "#9CA0B0"
  textMuted = "#6B6F80"
  textDim = "#4A4D5C"
  accent = "#7C7AED"
  accentSoft = "#272752"

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
    story: StoryRef

proc renderGenericMiniPreview[R, E](r: R; label: string): E =
  ## Project-neutral thumbnail used by the editor framework. Dark-themed
  ## skeleton card that blends with the canvas — never the bright white
  ## block from the earlier baseline.
  ui(r):
    tdiv(display = "flex", flex_direction = "column",
          width = "100%", height = "100%",
          background_color = bgCard, color = textPrimary,
          font_family = "-apple-system, BlinkMacSystemFont, 'Inter', 'Segoe UI', system-ui, sans-serif"):
      tdiv(height = "24px", display = "flex", align_items = "center",
            gap = "4px", padding = "0 8px",
            background_color = bgSurface,
            border_bottom = "1px solid " & border):
        for i in 0 .. 2:
          tdiv(width = "5px", height = "5px", border_radius = "999px",
                background_color = border)
      tdiv(flex = "1", display = "flex", flex_direction = "column",
            gap = "10px", padding = "16px"):
        tdiv(width = "52%", height = "10px", border_radius = "999px",
              background_color = borderFaint)
        tdiv(width = "78%", height = "28px", border_radius = "8px",
              background_color = bgSurface, border = "1px solid " & border)
        tdiv(display = "grid", grid_template_columns = "1fr 1fr", gap = "8px"):
          for i in 0 .. 3:
            tdiv(height = "26px", border_radius = "6px",
                  background_color = (if i == 0: accentSoft else: bgSurface),
                  border = "1px solid " & border)
        tdiv(margin_top = "auto", font_size = "10px", font_weight = "600",
              color = textMuted, line_height = "1.3"):
          text label

proc renderProjectMiniPreview[R, E](r: R; vm: EditorVM; story: StoryRef;
    label: string): E =
  ## Flow cards render the project-owned preview document when available.
  ## M-EVP-1: the srcdoc assignment is wrapped in a `createRenderEffect`
  ## so clicking a backend chip (which flips `vm.platform`) repaints every
  ## flow-card iframe with the new per-backend documentHtml. We resolve
  ## the initial preview once to decide whether to show the iframe or
  ## the placeholder card; subsequent backend-chip clicks reuse the same
  ## iframe via the reactive effect below.
  let capturedStory = story
  let initialPreview = vm.preview.hook(capturedStory, vm.platform.val)
  if initialPreview.documentHtml.len == 0:
    return renderGenericMiniPreview[R, E](r, label)

  let frame = ui(r):
    iframe(title = "Flow preview " & label,
        width = "1280",
        height = "900",
        border = "0",
        `data-flow-mini-preview` = "true")
  r.setStyle(frame, "position", "absolute")
  r.setStyle(frame, "left", "0")
  r.setStyle(frame, "top", "0")
  r.setStyle(frame, "width", "1280px")
  r.setStyle(frame, "height", "900px")
  r.setStyle(frame, "transform", "scale(0.395)")
  r.setStyle(frame, "transform-origin", "top left")
  r.setStyle(frame, "pointer-events", "none")
  var lastSrcdoc = ""
  createRenderEffect proc() =
    let preview = vm.preview.hook(capturedStory, vm.platform.val)
    let nextSrcdoc =
      if preview.documentHtml.len > 0: preview.documentHtml
      else: ""
    if nextSrcdoc != lastSrcdoc:
      r.setAttribute(frame, "srcdoc", nextSrcdoc)
      lastSrcdoc = nextSrcdoc
  frame

func hasConcreteScreenRef(story: StoryRef): bool =
  story.group.len > 0 and story.name.len > 0 and story.kind != skFlow

func resolveFlowCardStory(item: StoryItem; index: int;
    steps: seq[FlowStep]): StoryRef =
  ## Flow sidebar items are journey steps. The canvas card should open the
  ## concrete page/component story for that step when the workspace provides
  ## a matching FlowStep.
  for step in steps:
    if step.action == item.name and step.screenRef.hasConcreteScreenRef:
      return step.screenRef
  StoryRef(group: item.group, name: item.name, kind: item.kind, index: index)

proc layoutFlows(groups: seq[StoryGroup]; steps: seq[FlowStep]): seq[FlowRow] =
  ## Arrange only user flow groups as horizontal card sequences.
  for group in groups:
    if group.kind == skFlow:
      var row = FlowRow(flowName: group.name, flowDesc: group.description)
      var x = 0.0
      # v3: enlarge flow cards so each one reads as a proper preview rather
      # than a thumbnail. The shell-laptop reviewer flagged the previous
      # 400x520 cards as "small/two-per-row".
      let cardW = 520.0
      let cardH = 620.0
      let gapX = 48.0
      for i, item in group.items:
        let story = resolveFlowCardStory(item, i, steps)
        row.cards.add FlowCard(x: x, y: 0, w: cardW, h: cardH,
                                label: item.name, stepNum: i + 1,
                                story: story)
        x += cardW + gapX
      result.add row

proc storyClickHandler(vm: EditorVM; story: StoryRef): proc() =
  let captured = story
  result = proc() = discard vm.selectStory(captured)

proc clampZoom(value: float): float =
  min(4.0, max(0.25, value))

proc zoomStoryboardAt(vm: EditorVM; nextZoom, localX, localY: float) =
  let oldZoom = vm.storyboard.zoom.val
  let zoom = clampZoom(nextZoom)
  if oldZoom <= 0 or zoom == oldZoom:
    vm.storyboard.zoom.val = zoom
    return

  let contentX = (localX - vm.storyboard.panX.val) / oldZoom
  let contentY = (localY - vm.storyboard.panY.val) / oldZoom
  vm.storyboard.zoom.val = zoom
  vm.storyboard.panX.val = localX - contentX * zoom
  vm.storyboard.panY.val = localY - contentY * zoom

proc zoomStoryboardFromCenter(vm: EditorVM; nextZoom: float) =
  zoomStoryboardAt(vm, nextZoom, 640.0, 360.0)

proc panStoryboard(vm: EditorVM; dx, dy: float) =
  vm.storyboard.panX.val = vm.storyboard.panX.val + dx
  vm.storyboard.panY.val = vm.storyboard.panY.val + dy

proc resetStoryboardView(vm: EditorVM) =
  vm.storyboard.zoom.val = 1.0
  vm.storyboard.panX.val = 0
  vm.storyboard.panY.val = 0

proc installFigmaCanvasNavigation[R, E](r: R; viewport, content: E;
    vm: EditorVM) =
  ## Browser-only wheel and drag navigation for the flow canvas. MockRenderer
  ## receives stable attributes so headless tests can assert the contract.
  r.setAttribute(viewport, "data-figma-canvas", "true")
  r.setAttribute(content, "data-figma-canvas-content", "true")

  when defined(js):
    let panBy = proc(dx, dy: float) =
      vm.panStoryboard(dx, dy)
    let zoomBy = proc(factor, localX, localY: float) =
      vm.zoomStoryboardAt(vm.storyboard.zoom.val * factor, localX, localY)
    let host = viewport
    let inner = content
    {.emit: ["""
      if (!""", host, """.__isonimFlowPanZoomInstalled) {
        const host = """, host, """;
        const inner = """, inner,
        """;
        host.__isonimFlowPanZoomInstalled = true;
        host.style.cursor = 'grab';
        host.style.overflow = 'hidden';
        host.style.touchAction = 'none';
        inner.style.willChange = 'transform';

        host.addEventListener('wheel', (event) => {
          const rect = host.getBoundingClientRect();
          const localX = event.clientX - rect.left;
          const localY = event.clientY - rect.top;
          if (event.ctrlKey || event.metaKey) {
            const factor = Math.exp(-event.deltaY * 0.0015);
            """, zoomBy,
        """(factor, localX, localY);
          } else {
            """, panBy,
        """(-event.deltaX, -event.deltaY);
          }
          event.preventDefault();
        }, { passive: false });

        let dragging = false;
        let lastX = 0;
        let lastY = 0;
        host.addEventListener('mousedown', (event) => {
          if (event.button !== 0 && event.button !== 1) return;
          const target = event.target instanceof Element
            ? event.target
            : event.target?.parentElement;
          if (target?.closest('[data-flow-card="true"], [role="button"]')) return;
          dragging = true;
          lastX = event.clientX;
          lastY = event.clientY;
          host.style.cursor = 'grabbing';
          event.preventDefault();
        });
        window.addEventListener('mousemove', (event) => {
          if (!dragging) return;
          """, panBy,
        """(event.clientX - lastX, event.clientY - lastY);
          lastX = event.clientX;
          lastY = event.clientY;
          event.preventDefault();
        });
        window.addEventListener('mouseup', () => {
          if (!dragging) return;
          dragging = false;
          host.style.cursor = 'grab';
        });
      }
    """].}

proc renderStoryboardCanvas*[R, E](r: R; vm: EditorVM): E =
  ## M-EVP-6: per-view inner toolbar (User Journeys label + flow
  ## playback + zoom + Fit) removed. The canonical chrome bar lives
  ## above the view stack; the storyboard body starts directly at the
  ## canvas area. Flow playback and zoom controls remain reachable via
  ## the underlying VM operations (`vm.prevFlowStep`,
  ## `vm.nextFlowStep`, `vm.stopFlow`, `vm.zoomStoryboardFromCenter`,
  ## `vm.resetStoryboardView`); their visual affordances are tracked
  ## under the broader chrome consolidation series (M-EVP-7..M-EVP-9).
  let flows = layoutFlows(vm.sidebar.groups.val, vm.flowPlayer.steps.val)

  let canvas = ui(r):
    tdiv(class = "editor-preview",
          `data-storyboard-canvas` = "true",
          flex = "1", display = "flex", flex_direction = "column",
          min_width = "0", height = "100%",
          background_color = bgBase):
      discard

  # Canvas area
  let canvasArea = ui(r):
    tdiv(flex = "1", overflow = "hidden", position = "relative",
          background_color = bgBase,
          background_image = "radial-gradient(circle, " & borderFaint &
          " 1px, transparent 1px)",
          background_size = "24px 24px")

  # Inner scrollable content
  let inner = ui(r):
    tdiv(position = "relative", min_width = "2400px",
          min_height = "1800px", padding = "32px 40px",
          transform_origin = "0 0")
  createRenderEffect proc() =
    let zoom = vm.storyboard.zoom.val
    let panX = vm.storyboard.panX.val
    let panY = vm.storyboard.panY.val
    r.setStyle(inner, "transform",
      "translate(" & $panX & "px, " & $panY & "px) scale(" & $zoom & ")")

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
                display = "flex", align_items = "center",
                justify_content = "center"):
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
              `data-flow-card` = "true",
              background_color = bgCard,
              border = "1px solid " & border,
              border_radius = "8px", cursor = "pointer",
              transition = "border-color 0.15s, box-shadow 0.15s",
              overflow = "hidden", display = "flex", flex_direction = "column")

      # Card content area: full mini preview (no overlay badge)
      let stepNum = card.stepNum
      let story = card.story
      let selectCard = storyClickHandler(vm, story)
      let cardContent = ui(r):
        tdiv(flex = "1", position = "relative",
              margin = "8px 8px 0 8px", border_radius = "8px",
              overflow = "hidden", background_color = bgBase,
              box_shadow = "inset 0 0 0 1px " & borderFaint)
      r.appendChild(cardEl, cardContent)

      let preview = renderProjectMiniPreview[R, E](r, vm, story, stepLabel)
      r.setStyle(preview, "position", "absolute")
      r.appendChild(cardContent, preview)

      # Card label: "N. Action description"
      # v4: bump horizontal padding to 16px so the caption aligns with the
      # inner content frame (the preview iframe uses an 8px outer margin +
      # 8px iframe inset). Previous 12px caused the caption to read as
      # flush-left under cards with no indent.
      let cardLabel = ui(r):
        tdiv(padding = "10px 16px 12px 16px", font_size = "11px",
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
      r.setAttribute(cardEl, "role", "button")
      r.setAttribute(cardEl, "tabindex", "0")
      r.setAttribute(cardEl, "aria-label", "Select flow step " & stepLabel)
      r.addEventListener(cardEl, "click", selectCard)
      r.addEventListener(cardEl, "keydown", selectCard)
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

    rowY = cardsTop + 620 + 56 # card height + gap between flow rows

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
  r.installFigmaCanvasNavigation(canvasArea, inner, vm)

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
