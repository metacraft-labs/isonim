import isonim/editor/views/view_lifecycle
## IsoNim Editor — Storyboard canvas View.
##
## Default landing view: shows user flows as connected screen sequences.
## Only flow items appear on the canvas — foundations, components, and
## pages are accessed via the sidebar. This follows the Figma/Overflow
## pattern: canvas shows spatial relationships, sidebar shows details.

import std/[math, strutils]
import isonim/core/[signals, computation]
from isonim/core/batch import untrack
import isonim/core/nondet as nondet
when defined(js):
  import std/jsffi
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

const
  storyboardMinZoom* = 0.25
  storyboardMaxZoom* = 4.0
  storyboardZoomStep* = 1.2
    ## Editor spec "Canvas Features": one Zoom in / Zoom out press
    ## multiplies / divides the zoom by this factor about the canvas centre.
  storyboardFitMargin* = 24.0
    ## Fit leaves this many pixels between the cards and the canvas edge.
  flowCardWidth = 520.0
  flowCardHeight = 420.0
  flowCardBorder = 1.0
  flowCardGapX = 48.0
  flowHeaderHeight = 40.0
  flowRowGap = 56.0
  headlessCanvasWidth = 1280.0
  headlessCanvasHeight = 720.0
    ## Canvas extent assumed off the browser (MockRenderer), where nothing
    ## is laid out; the browser reads the canvas element's client size.

type
  FlowRow = object
    ## A single user flow rendered as a horizontal sequence of cards.
    flowName: string
    flowDesc: string
    cards: seq[FlowCard]
    firstStep: int
      ## The flow player's index of this flow's first step, or -1 when the
      ## workspace's flow steps do not include this flow (see
      ## ``flowStepRun``).
  FlowCard = object
    x, y, w, h: float
    label: string
    stepNum: int
    story: StoryRef

proc renderGenericMiniPreview[R, E](r: R; label: string): E =
  ## Project-neutral thumbnail used by the editor framework. Dark-themed
  ## designed snapshot — NOT a raw wireframe skeleton. The previous
  ## skeleton form (grey rectangles with no semantic content) read as
  ## placeholder boxes in the storyboard empty-state; M-EVP-12
  ## fix-cycle 3 (Finding A) replaces it with an authored mini-snapshot
  ## that mirrors the visual rhythm of the demo apps (top bar with
  ## status pill + window dots, a hero title row, list rows with
  ## leading dot indicators and trailing value chips, a small chart
  ## bar group, and the action label at the bottom).
  ui(r):
    tdiv(display = "flex", flex_direction = "column",
          width = "100%", height = "100%",
          background_color = bgCard, color = textPrimary,
          font_family = "-apple-system, BlinkMacSystemFont, 'Inter', 'Segoe UI', system-ui, sans-serif"):
      # Window chrome: traffic-light dots + status pill
      tdiv(height = "26px", display = "flex", align_items = "center",
            justify_content = "space-between", gap = "6px",
            padding = "0 10px",
            background_color = bgSurface,
            border_bottom = "1px solid " & border):
        tdiv(display = "flex", gap = "4px", align_items = "center"):
          for i in 0 .. 2:
            tdiv(width = "6px", height = "6px", border_radius = "999px",
                  background_color = border)
        tdiv(display = "flex", align_items = "center", gap = "4px",
              padding = "1px 7px", border_radius = "999px",
              background_color = accentSoft,
              border = "1px solid " & border):
          tdiv(width = "5px", height = "5px", border_radius = "999px",
                background_color = accent)
          span(font_size = "9px", color = textSecondary,
                font_weight = "600", letter_spacing = "0.4px"):
            text "LIVE"
      tdiv(flex = "1", display = "flex", flex_direction = "column",
            gap = "10px", padding = "14px 14px 10px 14px"):
        # Hero header: title + subtitle
        tdiv(display = "flex", flex_direction = "column", gap = "5px"):
          tdiv(width = "62%", height = "11px", border_radius = "3px",
                background_color = textSecondary, opacity = "0.85")
          tdiv(width = "44%", height = "7px", border_radius = "3px",
                background_color = textMuted, opacity = "0.55")
        # Three list rows, each with a leading dot + label bar +
        # trailing value chip. Reads as a "list of items with state"
        # rather than a generic grid.
        tdiv(display = "flex", flex_direction = "column", gap = "6px",
              margin_top = "2px"):
          for i in 0 .. 2:
            tdiv(display = "flex", align_items = "center", gap = "8px",
                  padding = "5px 7px", border_radius = "5px",
                  background_color = (if i == 0: accentSoft else: bgSurface),
                  border = "1px solid " & (if i == 0: accent else: border)):
              tdiv(width = "7px", height = "7px", border_radius = "999px",
                    background_color = (
                        if i == 0: accent
                        elif i == 1: textSecondary
                        else: textMuted),
                    opacity = (if i == 0: "1" else: "0.55"))
              tdiv(flex = "1", height = "6px", border_radius = "3px",
                    background_color = textMuted,
                    opacity = (if i == 0: "0.7" else: "0.35"))
              tdiv(width = "26px", height = "10px", border_radius = "999px",
                    background_color = (
                        if i == 0: accent else: borderFaint),
                    opacity = (if i == 0: "0.7" else: "1"))
        # Mini-chart strip: small bars suggesting "activity" rather
        # than empty placeholder space.
        tdiv(display = "flex", align_items = "flex-end", gap = "3px",
              height = "22px", margin_top = "4px"):
          const heights = [9, 14, 7, 18, 12, 20, 11, 16, 13, 22]
          for h in heights:
            tdiv(flex = "1", border_radius = "2px 2px 0 0",
                  background_color = accent, opacity = "0.55",
                  height = $h & "px")
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
  ##
  ## CHRM-M5b: the iframe-srcdoc/documentHtml path is Web-only. For
  ## non-Web backends a flow-card thumbnail showing HTML-with-CSS
  ## misrepresents what the actual backend renders (e.g. a TUI
  ## backend draws character cells, not an HTML body). The
  ## thumbnails fall through to the project-neutral mini preview
  ## (`renderGenericMiniPreview`) instead, matching the CHRM-M5
  ## invariant locked in across the page/foundations/component
  ## detail views.
  let capturedStory = story
  let initialPreview = vm.preview.hook(capturedStory, vm.platform.val)
  if vm.platform.val != pbWeb or initialPreview.documentHtml.len == 0:
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
    # CHRM-M5b: srcdoc only repaints while the active backend is
    # Web. A backend-chip flip to non-Web blanks the srcdoc; the
    # storyboard rebuilds the card via the platform-gated branch
    # above on the next render pass.
    let nextSrcdoc =
      if vm.platform.val == pbWeb and preview.documentHtml.len > 0:
        preview.documentHtml
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

func runMatches(steps: seq[FlowStep]; start: int; items: seq[StoryItem];
    whole: bool): bool =
  let n = if whole: items.len else: 1
  if start < 0 or start + n > steps.len:
    return false
  for k in 0 ..< n:
    if steps[start + k].action != items[k].name:
      return false
  true

func flowStepRun(group: StoryGroup; steps: seq[FlowStep];
    cursor: int): int =
  ## Where this flow's steps start in the workspace's flow steps (every
  ## flow's steps in canvas order; ``FlowStep`` carries no flow identity).
  ## A flow is its whole run of item names, searched from ``cursor`` -- the
  ## end of the previous flow's run -- so two flows whose steps share names
  ## (even all of them) each get their own run; a run before the cursor is
  ## the fallback, then a run of just the first name. -1 when none matches.
  if group.items.len == 0:
    return -1
  for whole in [true, false]:
    for i in max(cursor, 0) ..< steps.len:
      if runMatches(steps, i, group.items, whole):
        return i
    for i in 0 ..< min(max(cursor, 0), steps.len):
      if runMatches(steps, i, group.items, whole):
        return i
  -1

proc layoutFlows(groups: seq[StoryGroup]; steps: seq[FlowStep]): seq[FlowRow] =
  ## Arrange only user flow groups as horizontal card sequences.
  var cursor = 0
  for group in groups:
    if group.kind == skFlow:
      let firstStep = flowStepRun(group, steps, cursor)
      if firstStep >= 0:
        cursor = firstStep + group.items.len
      var row = FlowRow(flowName: group.name, flowDesc: group.description,
        firstStep: firstStep)
      var x = 0.0
      # v3: enlarge flow cards so each one reads as a proper preview rather
      # than a thumbnail. The shell-laptop reviewer flagged the previous
      # 400x520 cards as "small/two-per-row".
      # M-EVP-12 fix-cycle 3 (Finding A): the previous 520×620 card was
      # too tall — the iframe rasterises at 1280×900 scaled by 0.395,
      # so the actual preview region was 506×356 followed by ~250 px
      # of empty dark space inside each card. That void was the
      # "raw wireframe placeholder" the P3 reviewer flagged. Tighten
      # the card so the iframe fills it; the bottom row is just the
      # step-label band.
      let cardW = flowCardWidth
      let cardH = flowCardHeight
      let gapX = flowCardGapX
      for i, item in group.items:
        # A card opens its own flow's step when the run is known, so a step
        # name shared by two flows opens the right screen.
        let own = firstStep + i
        let story =
          if firstStep >= 0 and own < steps.len and
              steps[own].action == item.name and
              steps[own].screenRef.hasConcreteScreenRef:
            steps[own].screenRef
          else:
            resolveFlowCardStory(item, i, steps)
        row.cards.add FlowCard(x: x, y: 0, w: cardW, h: cardH,
                                label: item.name, stepNum: i + 1,
                                story: story)
        x += cardW + gapX
      result.add row

proc storyClickHandler(vm: EditorVM; story: StoryRef): proc() =
  let captured = story
  result = proc() = discard vm.selectStory(captured)

proc clampZoom(value: float): float =
  min(storyboardMaxZoom, max(storyboardMinZoom, value))

func storyboardFitTransform*(contentWidth, contentHeight, canvasWidth,
    canvasHeight: float): tuple[zoom, panX, panY: float] =
  ## Editor spec "Canvas Features" / "Canvas Navigation": Fit zooms so every
  ## card is inside the canvas with ``storyboardFitMargin`` to spare, never
  ## above 100% (the cards are already drawn at their designed size) and
  ## never below the 25% zoom floor, and centres the cards. Nothing to fit
  ## (no flows) or no laid-out canvas returns the 100% origin view.
  if contentWidth <= 0 or contentHeight <= 0 or canvasWidth <= 0 or
      canvasHeight <= 0:
    return (1.0, 0.0, 0.0)
  let availableWidth = max(1.0, canvasWidth - 2 * storyboardFitMargin)
  let availableHeight = max(1.0, canvasHeight - 2 * storyboardFitMargin)
  let zoom = clampZoom(min(1.0, min(availableWidth / contentWidth,
    availableHeight / contentHeight)))
  (zoom, (canvasWidth - contentWidth * zoom) / 2,
    (canvasHeight - contentHeight * zoom) / 2)

func flowsExtent(flows: seq[FlowRow]): tuple[width, height: float] =
  ## The cards' bounding box in canvas-content coordinates (flow headers
  ## start at 0, cards are absolutely placed from 0 including borders).
  var rowY = 0.0
  for flow in flows:
    for card in flow.cards:
      result.width = max(result.width, card.x + card.w + 2 * flowCardBorder)
    result.height = rowY + flowHeaderHeight + flowCardHeight + 2 * flowCardBorder
    rowY += flowHeaderHeight + flowCardHeight + flowRowGap

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

proc measured[E](node: E): nondet.Rect =
  ## A laid-out box through the platform layout seam.
  when isDomViewHost(E):
    nondet.measure(cast[JsObject](node))
  else:
    nondet.Rect()

proc canvasExtent[R, E](r: R; canvas: E): tuple[width, height: float] =
  ## The canvas viewport's laid-out size, read when a control is used.
  when isDomViewHost(E):
    let box = measured(canvas)
    (box.width, box.height)
  else:
    (headlessCanvasWidth, headlessCanvasHeight)

proc headerRight[R, E](r: R; vm: EditorVM; canvas, header: E): float =
  ## Right edge of a flow header (title, description, Play) in canvas-content
  ## coordinates; its width is its text's, known only once laid out. The
  ## measured box is on screen (panned and zoomed), so it is mapped back.
  ## Off the browser the header's inline ``width`` (if any) stands in for
  ## layout.
  when isDomViewHost(E):
    let zoom = vm.storyboard.zoom.val
    if zoom <= 0:
      return 0.0
    let box = measured(header)
    let area = measured(canvas)
    (box.x + box.width - area.x - vm.storyboard.panX.val) / zoom
  elif compiles(header.styles):
    let width = header.styles.getOrDefault("width")
    if width.endsWith("px"):
      try: parseFloat(width[0 ..< ^2]) except ValueError: 0.0
    else: 0.0
  else:
    0.0

proc zoomStoryboardFromCenter(vm: EditorVM; nextZoom, canvasWidth,
    canvasHeight: float) =
  zoomStoryboardAt(vm, nextZoom, canvasWidth / 2, canvasHeight / 2)

proc panStoryboard(vm: EditorVM; dx, dy: float) =
  vm.storyboard.panX.val = vm.storyboard.panX.val + dx
  vm.storyboard.panY.val = vm.storyboard.panY.val + dy

proc fitStoryboard(vm: EditorVM; contentWidth, contentHeight, canvasWidth,
    canvasHeight: float) =
  let fit = storyboardFitTransform(contentWidth, contentHeight, canvasWidth,
    canvasHeight)
  vm.storyboard.zoom.val = fit.zoom
  vm.storyboard.panX.val = fit.panX
  vm.storyboard.panY.val = fit.panY

proc installFigmaCanvasNavigation[R, E](r: R; viewport, content: E;
    vm: EditorVM) =
  ## Browser-only wheel and drag navigation for the flow canvas. MockRenderer
  ## receives stable attributes so headless tests can assert the contract.
  r.setAttribute(viewport, "data-figma-canvas", "true")
  r.setAttribute(content, "data-figma-canvas-content", "true")

  when isDomViewHost(E):
    ownViewResources(viewport)
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
          if (target?.closest('[data-flow-card="true"], [role="button"], button')) return;
          dragging = true;
          lastX = event.clientX;
          lastY = event.clientY;
          host.style.cursor = 'grabbing';
          event.preventDefault();
        });
        const move = (event) => {
          if (!dragging) return;
          """, panBy,
        """(event.clientX - lastX, event.clientY - lastY);
          lastX = event.clientX;
          lastY = event.clientY;
          event.preventDefault();
        };
        const stop = () => {
          if (!dragging) return;
          dragging = false;
          host.style.cursor = 'grab';
        };
        window.addEventListener('mousemove', move);
        window.addEventListener('mouseup', stop);
        globalThis.__isonimViewCleanup(host, () => {
          stop(); window.removeEventListener('mousemove', move);
          window.removeEventListener('mouseup', stop);
        });
      }
    """].}

proc toggleFlowPlayback*(vm: EditorVM) =
  ## Play enters step-through playback at the current step (selecting its
  ## card and story); pressed again it pauses there.
  if vm.flowPlayer.playState.val == psPlaying:
    vm.flowPlayer.pause()
  else:
    discard vm.selectFlowStep(vm.flowPlayer.currentStep.val)
    vm.flowPlayer.play()

proc playFlowHandler(vm: EditorVM; stepIndex: int): proc() =
  ## A flow's own Play button: playback starts at that flow's first step.
  ## (A proc of its own so each flow's closure keeps its own index.)
  let captured = stepIndex
  result = proc() =
    discard vm.selectFlowStep(captured)
    vm.flowPlayer.play()

proc storyboardControlButton[R, E](r: R; label, glyph: string;
    onPress: proc()): E =
  ## A native button: Enter and Space activate it, Tab reaches it, and the
  ## canvas pan gesture ignores presses on it.
  result = ui(r):
    button(`type` = "button", `aria-label` = label, title = label,
           display = "inline-flex", align_items = "center",
           justify_content = "center",
           min_width = "26px", height = "26px", padding = "0 6px",
           border = "0", border_radius = "4px",
           background_color = "transparent", color = textSecondary,
           font_size = "12px", font_family = "inherit",
           cursor = "pointer"):
      text glyph
  r.addEventListener(result, "click", onPress)

proc renderStoryboardCanvas*[R, E](r: R; vm: EditorVM): E =
  ## M-EVP-6 removed the storyboard's inner top toolbar; its zoom, Fit and
  ## flow playback controls live in the shared chrome bar
  ## (``renderFlowControls`` in shell.nim). This canvas carries out their
  ## zoom and Fit requests and shows the current step's annotation (editor
  ## spec "Canvas Features", "Canvas Navigation", "Interactive Play Mode").
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

  # Flow headers, measured by Fit (a header can be wider than its cards).
  var headers: seq[E]
  # Render each flow as a labeled row of connected cards
  var rowY = 0.0
  for fi, flow in flows:
    let fName = flow.flowName
    let fDesc = flow.flowDesc
    let rowTop = int(rowY)

    # Flow title + description
    var titleRow: E
    let flowHeader = ui(r):
      tdiv(position = "absolute", left = "0px",
            display = "flex", flex_direction = "column", gap = "2px"):
        tdiv(ref = titleRow, display = "flex", align_items = "center",
              gap = "8px"):
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
    r.setAttribute(flowHeader, "data-flow-header", fName)
    # Editor spec "Interactive Play Mode": each user flow has a Play
    # button; it starts playback at the flow's first step.
    let flowStart = flow.firstStep
    if flowStart >= 0:
      let flowPlay = storyboardControlButton[R, E](r, "Play flow " & fName,
        "\xE2\x96\xB6 Play", playFlowHandler(vm, flowStart))
      r.setAttribute(flowPlay, "data-flow-play", fName)
      # Editor spec "Canvas Navigation": double-clicking a flow enters flow
      # playback. The flow's header is the flow (a single click on a step
      # card already opens that step's story).
      r.addEventListener(flowHeader, "dblclick", playFlowHandler(vm, flowStart))
      r.setAttribute(flowHeader, "title", "Double-click to play " & fName)
      r.setStyle(flowPlay, "background-color", bgSurface)
      r.setStyle(flowPlay, "margin-left", "8px")
      # The title row's own height, so the header stays inside its 40 px
      # slot above the cards.
      r.setStyle(flowPlay, "height", "20px")
      r.setStyle(flowPlay, "font-size", "11px")
      r.appendChild(titleRow, flowPlay)
    r.appendChild(inner, flowHeader)
    headers.add flowHeader

    # Cards start below the header
    let cardsTop = rowY + flowHeaderHeight
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

    rowY = cardsTop + flowCardHeight + flowRowGap

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

  # The chrome bar's zoom and Fit controls (``renderFlowControls`` in
  # shell.nim) ask this canvas, which alone knows its laid-out size and its
  # content, to act (``StoryboardVM.command``).
  let capturedArea = canvasArea
  let extent = flowsExtent(flows)
  var lastCommand = untrack(proc(): int = vm.storyboard.command.val.serial)
  createRenderEffect proc() =
    let command = vm.storyboard.command.val
    if command.serial == lastCommand:
      return
    lastCommand = command.serial
    untrack proc() =
      let size = r.canvasExtent(capturedArea)
      case command.kind
      of sckZoomIn:
        # At the 400% ceiling ``clampZoom`` keeps the zoom and the pan.
        vm.zoomStoryboardFromCenter(vm.storyboard.zoom.val *
          storyboardZoomStep, size.width, size.height)
      of sckZoomOut:
        vm.zoomStoryboardFromCenter(vm.storyboard.zoom.val /
          storyboardZoomStep, size.width, size.height)
      of sckFit:
        var width = extent.width
        for header in headers:
          width = max(width, r.headerRight(vm, capturedArea, header))
        vm.fitStoryboard(width, extent.height, size.width, size.height)
      of sckNone:
        discard

  # Step annotation (editor spec "Interactive Play Mode" mock-up: "Step 1/4:
  # Empty State" over "-> User types ... and taps +"): a read-only caption
  # at the canvas's bottom-left (the minimap holds the bottom-right). The
  # playback controls live in the chrome bar, whose fixed 44 px row has no
  # room for free text of any length; the caption carries no control.
  let annotation = ui(r):
    tdiv(`data-storyboard-step-annotation` = "true",
          position = "absolute", left = "12px", bottom = "12px",
          z_index = "20", display = "flex", gap = "6px",
          padding = "4px 8px", font_size = "11px",
          max_width = "calc(100% - 188px)",
          background_color = bgCard, border = "1px solid " & border,
          border_radius = "6px", pointer_events = "none")
  let stepLabel = ui(r):
    span(`data-storyboard-step` = "true", color = textMuted, flex_shrink = "0",
          max_width = "30%", overflow = "hidden",
          text_overflow = "ellipsis", white_space = "nowrap")
  let stepAction = ui(r):
    span(`data-storyboard-step-action` = "true", color = textPrimary,
          flex_shrink = "0", max_width = "50%", overflow = "hidden",
          text_overflow = "ellipsis", white_space = "nowrap")
  let stepNote = ui(r):
    span(`data-storyboard-step-description` = "true", color = textMuted,
          min_width = "0", overflow = "hidden",
          text_overflow = "ellipsis", white_space = "nowrap")
  for node in [stepLabel, stepAction, stepNote]:
    r.appendChild(annotation, node)
  createRenderEffect proc() =
    let total = vm.flowPlayer.totalSteps.val
    r.setStyle(annotation, "display", if total > 0: "flex" else: "none")
    let index = min(vm.flowPlayer.currentStep.val, max(total - 1, 0))
    let stepText = "Step " & $(index + 1) & " / " & $total
    r.setTextContent(stepLabel, stepText)
    r.setAttribute(stepLabel, "title", stepText)
    let steps = vm.flowPlayer.steps.val
    let action = if index < steps.len: steps[index].action else: ""
    let note =
      if index < steps.len and steps[index].description.len > 0:
        "\xE2\x86\x92 " & steps[index].description
      else: ""
    r.setTextContent(stepAction, action)
    r.setAttribute(stepAction, "title", action)
    r.setTextContent(stepNote, note)
    r.setAttribute(stepNote, "title", note)
  r.appendChild(canvasArea, annotation)

  r.appendChild(canvas, canvasArea)
  canvas
