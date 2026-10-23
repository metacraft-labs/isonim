## Editor shell controls: the storyboard's zoom / Fit / flow playback
## controls and the sidebars' resize handles (isonim-pm issues
## 2026-10-14-storyboard-zoom-fit-and-flow-play-controls-are-specified-but-absent
## and 2026-10-14-dragging-the-right-sidebar-resize-handle-does-not-resize-it;
## editor spec "Canvas Features", "Canvas Navigation", "Interactive Play Mode"
## and "Resizable sidebars").
##
## Mock boundary: MockRenderer (isonim/testing/mock_dom) stands in for the
## DOM so the production views and EditorVM reducers run headless. It has no
## layout, so the storyboard's canvas extent is the views' documented
## headless size (1280 x 720), card geometry is read from the inline
## styles the view sets, and a flow header's width is the inline width a
## case sets on it (the view's documented headless stand-in for layout).
## Pointer drags, pointer capture over an iframe, real keyboard focus and
## localStorage persistence are browser behaviour; they are proven by the
## metacraft-web consumer Playwright cases
## (tests/browser/specs/metacraft-web-editor.spec.ts) and not claimed here.
## Nothing else is substituted.

import std/[unittest, strutils, tables, math]
import isonim/core/[signals, computation, owner]
import isonim/testing/mock_dom
import isonim/editor/viewmodels
import isonim/editor/types
import isonim/editor/views/shell
import isonim/editor/views/storyboard

proc findByAttr(node: MockNode; name, value: string): MockNode =
  if node.kind == mnkElement and name in node.attributes and
      node.attributes[name] == value:
    return node
  for child in node.children:
    let found = findByAttr(child, name, value)
    if found != nil:
      return found

proc collectByAttr(node: MockNode; name, value: string;
    found: var seq[MockNode]) =
  if node.kind == mnkElement and name in node.attributes and
      node.attributes[name] == value:
    found.add node
  for child in node.children:
    collectByAttr(child, name, value, found)

proc pageRef(name: string): StoryRef =
  StoryRef(group: "Pages", name: name, kind: skPage)

proc flowGroup(name: string; items: openArray[string]): StoryGroup =
  result = StoryGroup(name: name, kind: skFlow, description: name & " steps",
    expanded: true)
  for item in items:
    result.items.add StoryItem(name: item, description: item, kind: skFlow,
      group: name)

proc storyboardFixture(vm: EditorVM) =
  ## Two mapped flows of two steps each, and a third flow the workspace's
  ## flow steps do not include.
  vm.sidebar.groups.val = @[
    flowGroup("Checkout flow", ["Opens cart", "Pays"]),
    flowGroup("Returns flow", ["Starts return", "Gets refund"]),
    flowGroup("Unmapped flow", ["Somewhere"]),
    StoryGroup(name: "Pages", kind: skPage, description: "Pages",
      expanded: true, items: @[
        StoryItem(name: "Cart", description: "", kind: skPage, group: "Pages"),
        StoryItem(name: "Payment", description: "", kind: skPage,
          group: "Pages"),
        StoryItem(name: "Return", description: "", kind: skPage,
          group: "Pages"),
        StoryItem(name: "Refund", description: "", kind: skPage,
          group: "Pages")])]
  vm.flowPlayer.steps.val = @[
    FlowStep(screenRef: pageRef("Cart"), action: "Opens cart"),
    FlowStep(screenRef: pageRef("Payment"), action: "Pays"),
    FlowStep(screenRef: pageRef("Return"), action: "Starts return"),
    FlowStep(screenRef: pageRef("Refund"), action: "Gets refund")]

proc button(root: MockNode; label: string): MockNode =
  result = findByAttr(root, "aria-label", label)
  doAssert result != nil, "no control labelled " & label

proc parsePx(value: string): float =
  parseFloat(value.replace("px", ""))

proc transformOf(vm: EditorVM): string =
  "translate(" & $vm.storyboard.panX.val & "px, " & $vm.storyboard.panY.val &
    "px) scale(" & $vm.storyboard.zoom.val & ")"

proc near(a, b: float): bool = abs(a - b) < 1e-9

suite "storyboard zoom and Fit controls (editor spec Canvas Features)":
  test "the chrome bar carries zoom out, a zoom readout, zoom in and Fit as native buttons":
    createRoot do (dispose: proc()):
      let r = MockRenderer()
      let vm = createEditorVM()
      vm.storyboardFixture()
      let storyboard = renderEditorShell[MockRenderer, MockNode](r, vm)
      # The operator's 2026-10-22 decision: the controls live in the shared
      # chrome bar (``data-flow-controls``), not on the canvas.
      let chrome = findByAttr(storyboard, "data-preview-chrome-bar", "true")
      check chrome != nil
      let controls = findByAttr(chrome, "data-flow-controls", "true")
      check controls != nil
      for label in ["Zoom storyboard out", "Zoom storyboard in",
          "Fit storyboard", "Play flow", "Stop flow", "Previous flow step",
          "Next flow step"]:
        let control = controls.button(label)
        check control.tag == "button"
        check control.attributes.getOrDefault("type") == "button"
      check findByAttr(storyboard, "data-storyboard-controls", "true") == nil
      let level = findByAttr(controls, "data-storyboard-zoom-level", "true")
      check level != nil
      check level.textContent == "100%"
      check controls.button("Zoom storyboard out").attributes.getOrDefault(
        "aria-disabled") == "false"
      dispose()

  test "zoom in and out step by 1.2 about the canvas centre and stop at 25% and 400%":
    createRoot do (dispose: proc()):
      let r = MockRenderer()
      let vm = createEditorVM()
      vm.storyboardFixture()
      let storyboard = renderEditorShell[MockRenderer, MockNode](r, vm)
      let content = findByAttr(storyboard, "data-figma-canvas-content", "true")
      let level = findByAttr(storyboard, "data-storyboard-zoom-level", "true")
      let zoomIn = storyboard.button("Zoom storyboard in")
      let zoomOut = storyboard.button("Zoom storyboard out")
      zoomIn.fireEvent("click")
      check near(vm.storyboard.zoom.val, 1.2)
      # The point under the canvas centre (640, 360) stays put.
      check near(vm.storyboard.panX.val, 640.0 - 640.0 * 1.2)
      check near(vm.storyboard.panY.val, 360.0 - 360.0 * 1.2)
      check content.styles.getOrDefault("transform") == vm.transformOf
      check level.textContent == "120%"
      zoomOut.fireEvent("click")
      check near(vm.storyboard.zoom.val, 1.0)
      check abs(vm.storyboard.panX.val) < 1e-9
      check abs(vm.storyboard.panY.val) < 1e-9
      check level.textContent == "100%"

      for _ in 0 ..< 20:
        zoomIn.fireEvent("click")
      check vm.storyboard.zoom.val == 4.0
      check level.textContent == "400%"
      check zoomIn.attributes.getOrDefault("aria-disabled") == "true"
      check zoomOut.attributes.getOrDefault("aria-disabled") == "false"
      let panAtMax = vm.storyboard.panX.val
      zoomIn.fireEvent("click")
      check vm.storyboard.zoom.val == 4.0
      check vm.storyboard.panX.val == panAtMax

      for _ in 0 ..< 30:
        zoomOut.fireEvent("click")
      check vm.storyboard.zoom.val == 0.25
      check level.textContent == "25%"
      check zoomOut.attributes.getOrDefault("aria-disabled") == "true"
      check zoomIn.attributes.getOrDefault("aria-disabled") == "false"
      dispose()

  test "Fit zooms so every card is inside the canvas, centred, from any view":
    createRoot do (dispose: proc()):
      let r = MockRenderer()
      let vm = createEditorVM()
      vm.storyboardFixture()
      let storyboard = renderEditorShell[MockRenderer, MockNode](r, vm)
      let content = findByAttr(storyboard, "data-figma-canvas-content", "true")
      vm.storyboard.zoom.val = 2.7
      vm.storyboard.panX.val = -900
      vm.storyboard.panY.val = 333
      storyboard.button("Fit storyboard").fireEvent("click")

      var cards: seq[MockNode]
      collectByAttr(storyboard, "data-flow-card", "true", cards)
      check cards.len == 5
      # Bounding box of the cards as laid out (1 px borders included).
      var right, bottom = 0.0
      for card in cards:
        right = max(right, card.styles.getOrDefault("left").parsePx +
          card.styles.getOrDefault("width").parsePx + 2)
        bottom = max(bottom, card.styles.getOrDefault("top").parsePx +
          card.styles.getOrDefault("height").parsePx + 2)
      let expected = storyboardFitTransform(right, bottom, 1280, 720)
      check near(vm.storyboard.zoom.val, expected.zoom)
      check near(vm.storyboard.panX.val, expected.panX)
      check near(vm.storyboard.panY.val, expected.panY)
      check vm.storyboard.zoom.val < 1.0
      check content.styles.getOrDefault("transform") == vm.transformOf
      let zoom = vm.storyboard.zoom.val
      for card in cards:
        let x0 = vm.storyboard.panX.val + card.styles.getOrDefault("left").parsePx * zoom
        let y0 = vm.storyboard.panY.val + card.styles.getOrDefault("top").parsePx * zoom
        let x1 = x0 + (card.styles.getOrDefault("width").parsePx + 2) * zoom
        let y1 = y0 + (card.styles.getOrDefault("height").parsePx + 2) * zoom
        check x0 >= storyboardFitMargin - 1e-6
        check y0 >= storyboardFitMargin - 1e-6
        check x1 <= 1280 - storyboardFitMargin + 1e-6
        check y1 <= 720 - storyboardFitMargin + 1e-6
      # Centred: equal space on both sides of the bounding box.
      check near(vm.storyboard.panX.val, 1280 - (vm.storyboard.panX.val +
        right * zoom))
      check near(vm.storyboard.panY.val, 720 - (vm.storyboard.panY.val +
        bottom * zoom))
      # Fit is idempotent.
      storyboard.button("Fit storyboard").fireEvent("click")
      check near(vm.storyboard.zoom.val, expected.zoom)
      check near(vm.storyboard.panX.val, expected.panX)
      dispose()

  test "Fit includes a flow header that is wider than its cards":
    createRoot do (dispose: proc()):
      let r = MockRenderer()
      let vm = createEditorVM()
      vm.storyboardFixture()
      let storyboard = renderEditorShell[MockRenderer, MockNode](r, vm)
      # Off the browser a header's inline width stands in for its laid-out
      # width (the browser reads offsetLeft + offsetWidth).
      let header = findByAttr(storyboard, "data-flow-header", "Returns flow")
      check header != nil
      storyboard.button("Fit storyboard").fireEvent("click")
      let cardsOnly = vm.storyboard.zoom.val
      header.styles["width"] = "4000px"
      storyboard.button("Fit storyboard").fireEvent("click")
      var cards: seq[MockNode]
      collectByAttr(storyboard, "data-flow-card", "true", cards)
      var bottom = 0.0
      for card in cards:
        bottom = max(bottom, card.styles.getOrDefault("top").parsePx +
          card.styles.getOrDefault("height").parsePx + 2)
      let expected = storyboardFitTransform(4000, bottom, 1280, 720)
      check near(vm.storyboard.zoom.val, expected.zoom)
      check near(vm.storyboard.panX.val, expected.panX)
      check vm.storyboard.zoom.val < cardsOnly
      # The header's right edge is inside the canvas with the margin.
      check vm.storyboard.panX.val + 4000 * vm.storyboard.zoom.val <=
        1280 - storyboardFitMargin + 1e-6
      dispose()

  test "Fit never magnifies past 100%, never goes below 25%, and resets an empty storyboard":
    let small = storyboardFitTransform(100, 50, 1280, 720)
    check small.zoom == 1.0
    check near(small.panX, 590)
    check near(small.panY, 335)
    let huge = storyboardFitTransform(100_000, 100_000, 1280, 720)
    check huge.zoom == 0.25
    check near(huge.panX, (1280 - 25_000) / 2)
    let exact = storyboardFitTransform(1232, 300, 1280, 720)
    check exact.zoom == 1.0
    check near(exact.panX, 24)
    check storyboardFitTransform(0, 0, 1280, 720) == (1.0, 0.0, 0.0)
    check storyboardFitTransform(500, 500, 0, 0) == (1.0, 0.0, 0.0)
    createRoot do (dispose: proc()):
      let r = MockRenderer()
      let vm = createEditorVM()
      vm.sidebar.groups.val = @[]
      let storyboard = renderEditorShell[MockRenderer, MockNode](r, vm)
      vm.storyboard.zoom.val = 1.7
      vm.storyboard.panX.val = 40
      vm.storyboard.panY.val = -40
      storyboard.button("Fit storyboard").fireEvent("click")
      check vm.storyboard.zoom.val == 1.0
      check vm.storyboard.panX.val == 0
      check vm.storyboard.panY.val == 0
      dispose()

suite "flow playback controls (editor spec Interactive Play Mode)":
  test "Play enters step-through playback at the current step and becomes Pause":
    createRoot do (dispose: proc()):
      let r = MockRenderer()
      let vm = createEditorVM()
      vm.storyboardFixture()
      let storyboard = renderEditorShell[MockRenderer, MockNode](r, vm)
      let step = findByAttr(storyboard, "data-storyboard-step", "true")
      let play = storyboard.button("Play flow")
      check play.tag == "button"
      check play.attributes.getOrDefault("aria-pressed") == "false"
      check step.textContent == "Step 1 / 4"
      check vm.selectedStory.val != pageRef("Cart")
      play.fireEvent("click")
      check vm.flowPlayer.playState.val == psPlaying
      check play.attributes.getOrDefault("aria-label") == "Pause flow"
      check play.attributes.getOrDefault("aria-pressed") == "true"
      check vm.selectedStory.val == pageRef("Cart")
      check vm.activeView.val == evStoryboard
      check findByAttr(storyboard, "aria-label", "Play flow") == nil
      play.fireEvent("click")
      check vm.flowPlayer.playState.val == psPaused
      check play.attributes.getOrDefault("aria-label") == "Play flow"
      check play.attributes.getOrDefault("aria-pressed") == "false"
      check vm.flowPlayer.currentStep.val == 0
      dispose()

  test "Next and Previous step through the flow and wrap; Stop returns to step 1":
    createRoot do (dispose: proc()):
      let r = MockRenderer()
      let vm = createEditorVM()
      vm.storyboardFixture()
      let storyboard = renderEditorShell[MockRenderer, MockNode](r, vm)
      let step = findByAttr(storyboard, "data-storyboard-step", "true")
      storyboard.button("Play flow").fireEvent("click")
      storyboard.button("Next flow step").fireEvent("click")
      check vm.flowPlayer.currentStep.val == 1
      check vm.selectedStory.val == pageRef("Payment")
      check step.textContent == "Step 2 / 4"
      storyboard.button("Previous flow step").fireEvent("click")
      check vm.flowPlayer.currentStep.val == 0
      storyboard.button("Previous flow step").fireEvent("click")
      check vm.flowPlayer.currentStep.val == 3
      check vm.selectedStory.val == pageRef("Refund")
      check step.textContent == "Step 4 / 4"
      storyboard.button("Next flow step").fireEvent("click")
      check vm.flowPlayer.currentStep.val == 0
      storyboard.button("Next flow step").fireEvent("click")
      storyboard.button("Stop flow").fireEvent("click")
      check vm.flowPlayer.playState.val == psStopped
      check vm.flowPlayer.currentStep.val == 0
      check vm.selectedStory.val == pageRef("Cart")
      check step.textContent == "Step 1 / 4"
      check storyboard.button("Play flow").attributes.getOrDefault("aria-pressed") == "false"
      dispose()

  test "each mapped flow has its own Play button that starts at its first step":
    createRoot do (dispose: proc()):
      let r = MockRenderer()
      let vm = createEditorVM()
      vm.storyboardFixture()
      let storyboard = renderEditorShell[MockRenderer, MockNode](r, vm)
      let checkout = storyboard.button("Play flow Checkout flow")
      let returns = storyboard.button("Play flow Returns flow")
      check checkout.tag == "button"
      check returns.attributes.getOrDefault("data-flow-play") == "Returns flow"
      check findByAttr(storyboard, "aria-label", "Play flow Unmapped flow") == nil
      returns.fireEvent("click")
      check vm.flowPlayer.playState.val == psPlaying
      check vm.flowPlayer.currentStep.val == 2
      check vm.selectedStory.val == pageRef("Return")
      check storyboard.button("Pause flow").attributes.getOrDefault("aria-pressed") == "true"
      checkout.fireEvent("click")
      check vm.flowPlayer.currentStep.val == 0
      check vm.selectedStory.val == pageRef("Cart")
      check vm.flowPlayer.playState.val == psPlaying
      dispose()

  test "flows that share step names each play their own run of steps":
    createRoot do (dispose: proc()):
      let r = MockRenderer()
      let vm = createEditorVM()
      # Both flows start with "Opens cart" (and the third shares all of its
      # names with the first); FlowStep carries no flow identity.
      vm.sidebar.groups.val = @[
        flowGroup("Checkout flow", ["Opens cart", "Pays"]),
        flowGroup("Reorder flow", ["Opens cart", "Reorders"]),
        flowGroup("Checkout again", ["Opens cart", "Pays"]),
        StoryGroup(name: "Pages", kind: skPage, description: "Pages",
          expanded: true, items: @[
            StoryItem(name: "Cart", description: "", kind: skPage,
              group: "Pages"),
            StoryItem(name: "Payment", description: "", kind: skPage,
              group: "Pages"),
            StoryItem(name: "Return", description: "", kind: skPage,
              group: "Pages"),
            StoryItem(name: "Refund", description: "", kind: skPage,
              group: "Pages")])]
      vm.flowPlayer.steps.val = @[
        FlowStep(screenRef: pageRef("Cart"), action: "Opens cart"),
        FlowStep(screenRef: pageRef("Payment"), action: "Pays"),
        FlowStep(screenRef: pageRef("Return"), action: "Opens cart"),
        FlowStep(screenRef: pageRef("Refund"), action: "Reorders"),
        FlowStep(screenRef: pageRef("Payment"), action: "Opens cart"),
        FlowStep(screenRef: pageRef("Cart"), action: "Pays")]
      let storyboard = renderEditorShell[MockRenderer, MockNode](r, vm)
      storyboard.button("Play flow Reorder flow").fireEvent("click")
      check vm.flowPlayer.currentStep.val == 2
      check vm.selectedStory.val == pageRef("Return")
      storyboard.button("Play flow Checkout again").fireEvent("click")
      check vm.flowPlayer.currentStep.val == 4
      check vm.selectedStory.val == pageRef("Payment")
      storyboard.button("Play flow Checkout flow").fireEvent("click")
      check vm.flowPlayer.currentStep.val == 0
      check vm.selectedStory.val == pageRef("Cart")
      # A card opens its own flow's step, not the first step of that name.
      var cards: seq[MockNode]
      collectByAttr(storyboard, "aria-label", "Select flow step Opens cart",
        cards)
      check cards.len == 3
      cards[1].fireEvent("click")
      check vm.selectedStory.val == pageRef("Return")
      cards[2].fireEvent("click")
      check vm.selectedStory.val == pageRef("Payment")
      dispose()

  test "double-clicking a flow enters playback at its first step":
    createRoot do (dispose: proc()):
      let r = MockRenderer()
      let vm = createEditorVM()
      vm.storyboardFixture()
      let storyboard = renderEditorShell[MockRenderer, MockNode](r, vm)
      let header = findByAttr(storyboard, "data-flow-header", "Returns flow")
      check header != nil
      header.fireEvent("dblclick")
      check vm.flowPlayer.playState.val == psPlaying
      check vm.flowPlayer.currentStep.val == 2
      check vm.selectedStory.val == pageRef("Return")
      check vm.activeView.val == evStoryboard
      # A flow the workspace's steps do not include has nothing to play.
      let unmapped = findByAttr(storyboard, "data-flow-header", "Unmapped flow")
      unmapped.fireEvent("dblclick")
      check vm.flowPlayer.currentStep.val == 2
      dispose()

  test "the current step's action and description are annotated":
    createRoot do (dispose: proc()):
      let r = MockRenderer()
      let vm = createEditorVM()
      vm.storyboardFixture()
      var steps = vm.flowPlayer.steps.val
      steps[1].description = "Card charged, receipt shown"
      vm.flowPlayer.steps.val = steps
      let storyboard = renderEditorShell[MockRenderer, MockNode](r, vm)
      let action = findByAttr(storyboard, "data-storyboard-step-action", "true")
      let note = findByAttr(storyboard, "data-storyboard-step-description",
        "true")
      check action.textContent == "Opens cart"
      check note.textContent == ""
      storyboard.button("Next flow step").fireEvent("click")
      check action.textContent == "Pays"
      check note.textContent == "\xE2\x86\x92 Card charged, receipt shown"
      check note.attributes.getOrDefault("title") == note.textContent
      # Each part is truncated with its full text as a tooltip.
      let stepText = findByAttr(storyboard, "data-storyboard-step", "true")
      check stepText.attributes.getOrDefault("title") == "Step 2 / 4"
      for part in [stepText, action, note]:
        check part.styles.getOrDefault("text-overflow") == "ellipsis"
        check part.styles.getOrDefault("white-space") == "nowrap"
        check part.attributes.getOrDefault("title") == part.textContent
      dispose()

  test "without flow steps the playback buttons and annotation are hidden":
    createRoot do (dispose: proc()):
      let r = MockRenderer()
      let vm = createEditorVM()
      vm.storyboardFixture()
      let storyboard = renderEditorShell[MockRenderer, MockNode](r, vm)
      let playback = findByAttr(storyboard, "data-flow-playback", "true")
      check playback.styles.getOrDefault("display") == "inline-flex"
      let annotation = findByAttr(storyboard, "data-storyboard-step-annotation",
        "true")
      check annotation.styles.getOrDefault("display") == "flex"
      vm.flowPlayer.steps.val = @[]
      check playback.styles.getOrDefault("display") == "none"
      check annotation.styles.getOrDefault("display") == "none"
      # Zoom and Fit stay available.
      check storyboard.button("Fit storyboard") != nil
      dispose()

proc keydown(node: MockNode; key: string): MockEvent =
  result = MockEvent(`type`: "keydown", key: key, target: node,
    currentTarget: node)
  node.fireEventWith("keydown", result)

proc checkSeparator(handle: MockNode; label: string; minWidth, maxWidth,
    now: int) =
  # A touch or pen drag must not be taken over by the browser's panning.
  check handle.styles.getOrDefault("touch-action") == "none"
  check handle.attributes.getOrDefault("role") == "separator"
  check handle.attributes.getOrDefault("aria-orientation") == "vertical"
  check handle.attributes.getOrDefault("tabindex") == "0"
  check handle.attributes.getOrDefault("aria-label") == label
  check handle.attributes.getOrDefault("aria-valuemin") == $minWidth
  check handle.attributes.getOrDefault("aria-valuemax") == $maxWidth
  check handle.attributes.getOrDefault("aria-valuenow") == $now
  check "aria-hidden" notin handle.attributes

suite "resizable sidebars (editor spec Resizable sidebars)":
  test "the right sidebar width is clamped to 240..420 by every path":
    createRoot do (dispose: proc()):
      let vm = createEditorVM()
      check vm.rightPanelWidth.val == 320
      vm.setRightPanelWidth(100)
      check vm.rightPanelWidth.val == 240
      vm.setRightPanelWidth(239)
      check vm.rightPanelWidth.val == 240
      vm.setRightPanelWidth(241)
      check vm.rightPanelWidth.val == 241
      vm.adjustRightPanelWidth(-300)
      check vm.rightPanelWidth.val == 240
      vm.adjustRightPanelWidth(9_999)
      check vm.rightPanelWidth.val == 420
      check clampRightPanelWidth(200) == 240
      check clampLeftSidebarWidth(10) == 180
      check clampLeftSidebarWidth(9_999) == 420
      dispose()

  test "both right-sidebar surfaces render the 240..420 bounds the VM clamps to":
    createRoot do (dispose: proc()):
      let r = MockRenderer()
      let vm = createEditorVM()
      for panel in [renderAiAssistantPanel[MockRenderer, MockNode](r, vm),
          renderInspectorPanel[MockRenderer, MockNode](r, vm)]:
        check panel.styles.getOrDefault("min-width") == "240px"
        check panel.styles.getOrDefault("max-width") == "420px"
      dispose()

  test "each right-sidebar resize handle is a keyboard-operable separator":
    createRoot do (dispose: proc()):
      let r = MockRenderer()
      let vm = createEditorVM()
      for surface in ["ai-assistant", "inspector"]:
        vm.setRightPanelWidth(320)
        let panel =
          if surface == "ai-assistant":
            renderAiAssistantPanel[MockRenderer, MockNode](r, vm)
          else:
            renderInspectorPanel[MockRenderer, MockNode](r, vm)
        let handle = findByAttr(panel, "data-resize-handle", "right-panel")
        check handle != nil
        handle.checkSeparator("Resize right sidebar", 240, 420, 320)
        # The handle sits on the panel's left edge: moving it left widens.
        let widen = handle.keydown("ArrowLeft")
        check widen.defaultPrevented
        check vm.rightPanelWidth.val == 336
        check handle.attributes.getOrDefault("aria-valuenow") == "336"
        check panel.styles.getOrDefault("width") == "336px"
        check panel.attributes.getOrDefault("data-right-panel-width") == "336"
        discard handle.keydown("ArrowRight")
        check vm.rightPanelWidth.val == 320
        discard handle.keydown("Home")
        check vm.rightPanelWidth.val == 240
        check handle.attributes.getOrDefault("aria-valuenow") == "240"
        discard handle.keydown("ArrowRight")
        check vm.rightPanelWidth.val == 240
        discard handle.keydown("End")
        check vm.rightPanelWidth.val == 420
        discard handle.keydown("ArrowLeft")
        check vm.rightPanelWidth.val == 420
        let other = handle.keydown("a")
        check not other.defaultPrevented
        check vm.rightPanelWidth.val == 420
        let tab = handle.keydown("Tab")
        check not tab.defaultPrevented
        check vm.rightPanelWidth.val == 420
      dispose()

  test "the left sidebar resize handle is a keyboard-operable separator":
    createRoot do (dispose: proc()):
      let r = MockRenderer()
      let vm = createEditorVM()
      let shellRoot = renderEditorShell[MockRenderer, MockNode](r, vm)
      let handle = findByAttr(shellRoot, "data-resize-handle", "left-sidebar")
      check handle != nil
      handle.checkSeparator("Resize left sidebar", 180, 420, 260)
      # The handle sits on the sidebar's right edge: moving it right widens.
      let widen = handle.keydown("ArrowRight")
      check widen.defaultPrevented
      check vm.leftSidebarWidth.val == 276
      check handle.attributes.getOrDefault("aria-valuenow") == "276"
      let sidebar = findByAttr(shellRoot, "data-left-sidebar-width", "276")
      check sidebar != nil
      check sidebar.styles.getOrDefault("width") == "276px"
      discard handle.keydown("ArrowLeft")
      discard handle.keydown("ArrowLeft")
      check vm.leftSidebarWidth.val == 244
      discard handle.keydown("Home")
      check vm.leftSidebarWidth.val == 180
      discard handle.keydown("End")
      check vm.leftSidebarWidth.val == 420
      check handle.attributes.getOrDefault("aria-valuenow") == "420"
      dispose()

  test "the right sidebar keeps one width across its two surfaces":
    createRoot do (dispose: proc()):
      let r = MockRenderer()
      let vm = createEditorVM()
      let shellRoot = renderEditorShell[MockRenderer, MockNode](r, vm)
      let aiHandle = findByAttr(findByAttr(shellRoot, "data-sidebar-content",
        "ai-assistant"), "data-resize-handle", "right-panel")
      discard aiHandle.keydown("ArrowLeft")
      discard aiHandle.keydown("ArrowLeft")
      check vm.rightPanelWidth.val == 352
      vm.setEditMode(emEdit)
      let inspector = findByAttr(shellRoot, "data-sidebar-content", "inspector")
      check inspector != nil
      check inspector.attributes.getOrDefault("data-right-panel-width") == "352"
      check findByAttr(inspector, "data-resize-handle",
        "right-panel").attributes.getOrDefault("aria-valuenow") == "352"
      dispose()
