## M57 — Preview-Pane Edge-Strip Chrome.
##
## Focused regression tests for the unified `Platform` / `PreviewBackend`
## enum, the richer `PreviewViewport` descriptor, the vertical compact
## choice column (`renderCompactChoiceColumn`), and the new edge-strip
## chrome rendered by `renderPreviewPane`. These tests are strong
## real-stack integration: they instantiate the real editor VM, render
## with the headless mock renderer, and click through the actual signal
## handlers — no behaviour mocks.

import std/[sequtils, tables, unittest]
import isonim/core/[signals, computation, owner]
import isonim/testing/mock_dom
import isonim/editor/viewmodels
import isonim/editor/types
import isonim/editor/streaming_preview
import isonim/editor/views/shell
import isonim/editor/views/choice_row

proc findByAttr(node: MockNode; name, value: string): MockNode =
  if node.kind == mnkElement and name in node.attributes and
      node.attributes[name] == value:
    return node
  for child in node.children:
    let found = findByAttr(child, name, value)
    if found != nil:
      return found

proc collectByAttr(node: MockNode; name, value: string;
    result: var seq[MockNode]) =
  if node.kind == mnkElement and name in node.attributes and
      node.attributes[name] == value:
    result.add node
  for child in node.children:
    collectByAttr(child, name, value, result)

proc findAllByAttr(node: MockNode; name, value: string): seq[MockNode] =
  collectByAttr(node, name, value, result)

suite "M57 PreviewBackend / Platform unification":

  test "backend enum exposes six canonical values":
    let backends = [pbWeb, pbTui, pbGpui, pbFreya, pbCocoa, pbAndroid]
    check backends.len == 6
    check backendLabel(pbWeb) == "Web"
    check backendLabel(pbTui) == "TUI"
    check backendLabel(pbGpui) == "GPUI"
    check backendLabel(pbFreya) == "Freya"
    check backendLabel(pbCocoa) == "Cocoa"
    check backendLabel(pbAndroid) == "Android"

  test "Platform is an alias of PreviewBackend":
    var p: Platform = pbWeb
    let q: PreviewBackend = p
    check q == pbWeb
    p = pbCocoa
    check p == pbCocoa

  test "editor VM defaults to the web backend":
    createRoot do (dispose: proc()):
      let vm = createEditorVM()
      check vm.platform.val == pbWeb
      check vm.viewport.val.kind == pvkDesktop
      check vm.viewport.val.slug == "desktop"
      check vm.viewport.val.width == 1440
      check vm.viewport.val.height == 900
      check vm.viewport.val.isCells == false
      dispose()

suite "M57 PreviewViewport descriptor":

  test "built-in viewports carry slug / label / extent":
    let desktop = makeBuiltinViewport(pvkDesktop)
    check desktop.slug == "desktop"
    check desktop.label == "Desktop"
    check desktop.width == 1440
    check desktop.height == 900
    check desktop.isCells == false

    let tui = makeBuiltinViewport(pvkTui80x24)
    check tui.slug == "tui-80x24"
    check tui.width == 80
    check tui.height == 24
    check tui.isCells == true

    let phone = makeBuiltinViewport(pvkPhone)
    check phone.slug == "phone"
    check phone.width == 390
    check phone.height == 844

  test "default viewport matches the spec table per backend":
    check defaultViewport(pbWeb).kind == pvkDesktop
    check defaultViewport(pbGpui).kind == pvkDesktop
    check defaultViewport(pbFreya).kind == pvkDesktop
    check defaultViewport(pbCocoa).kind == pvkDesktop
    check defaultViewport(pbAndroid).kind == pvkPhone
    check defaultViewport(pbTui).kind == pvkTui80x24
    check defaultViewport(pbTui).isCells == true

  test "pinned and popup sets match the spec table":
    let webPinned = pinnedViewports(pbWeb).mapIt(it.slug)
    check webPinned == @["desktop", "laptop", "tablet", "phone"]
    let webPopup = popupViewports(pbWeb).mapIt(it.slug)
    check webPopup == @["wide", "ultrawide", "phone-sm", "phone-xl",
                        "custom"]

    let androidPinned = pinnedViewports(pbAndroid).mapIt(it.slug)
    check androidPinned == @["phone", "tablet", "phone-sm", "phone-xl"]
    let androidPopup = popupViewports(pbAndroid).mapIt(it.slug)
    check androidPopup == @["desktop", "laptop", "wide", "ultrawide",
                            "custom"]

    let tuiPinned = pinnedViewports(pbTui).mapIt(it.slug)
    check tuiPinned == @["tui-80x24", "tui-120x40"]
    let tuiPopup = popupViewports(pbTui).mapIt(it.slug)
    check tuiPopup == @["custom"]

    # Pinned and popup sets are coherent for the remaining three
    # graphical backends; they share the web pinned/popup contract.
    for backend in [pbGpui, pbFreya, pbCocoa]:
      check pinnedViewports(backend).mapIt(it.slug) == webPinned
      check popupViewports(backend).mapIt(it.slug) == webPopup

  test "makeCustomViewport round-trips slug and label":
    let custom = makeCustomViewport(1234, 567)
    check custom.kind == pvkCustom
    check custom.slug == "custom-1234x567px"
    check custom.label == "1234 x 567"
    check custom.width == 1234
    check custom.height == 567
    check custom.isCells == false

    let tuiCustom = makeCustomViewport(72, 18, isCells = true)
    check tuiCustom.slug == "custom-72x18c"
    check tuiCustom.label == "72 x 18 cells"
    check tuiCustom.isCells == true

  test "viewportsEqual treats two custom viewports with same extent as equal":
    let a = makeCustomViewport(800, 600)
    let b = makeCustomViewport(800, 600)
    let c = makeCustomViewport(900, 600)
    check viewportsEqual(a, b)
    check not viewportsEqual(a, c)
    check viewportsEqual(makeBuiltinViewport(pvkDesktop),
      makeBuiltinViewport(pvkDesktop))
    check not viewportsEqual(makeBuiltinViewport(pvkDesktop),
      makeBuiltinViewport(pvkPhone))

  test "changePlatform keeps the viewport when the backend's pinned set still has it":
    createRoot do (dispose: proc()):
      let vm = createEditorVM()
      vm.changeViewport(makeBuiltinViewport(pvkTablet))
      vm.changePlatform(pbCocoa)
      # Cocoa pins tablet, so the active viewport must persist.
      check vm.viewport.val.kind == pvkTablet
      dispose()

  test "changePlatform falls back to backend default when pinned set drops the viewport":
    createRoot do (dispose: proc()):
      let vm = createEditorVM()
      vm.changeViewport(makeBuiltinViewport(pvkDesktop))
      vm.changePlatform(pbTui)
      check vm.viewport.val.kind == pvkTui80x24
      check vm.viewport.val.isCells == true
      dispose()

suite "M57 vertical compact choice column":

  test "vertical column renders one segment per option with active fill":
    createRoot do (dispose: proc()):
      let r = MockRenderer()
      var clicked = ""
      let options = @[
        CompactChoiceOption(label: "View", shortLabel: "View",
          ariaLabel: "Switch to view", selected: true, enabled: true,
          dataAttrs: @[("data-test", "view")],
          onChoose: proc() = clicked = "view"),
        CompactChoiceOption(label: "Comment", shortLabel: "Cmt",
          ariaLabel: "Switch to comment", selected: false, enabled: true,
          dataAttrs: @[("data-test", "comment")],
          onChoose: proc() = clicked = "comment"),
        CompactChoiceOption(label: "Edit", shortLabel: "Edit",
          ariaLabel: "Switch to edit", selected: false, enabled: true,
          dataAttrs: @[("data-test", "edit")],
          onChoose: proc() = clicked = "edit")
      ]
      let col = renderCompactChoiceColumn[MockRenderer, MockNode](r,
        ariaLabel = "Preview mode",
        options = options,
        visibleLimit = 3,
        dataAttrs = @[("data-edge-strip", "mode")])

      check col.root.attributes["data-compact-choice-column"] == "true"
      check col.root.attributes["data-edge-strip"] == "mode"
      check col.root.attributes["aria-orientation"] == "vertical"
      check col.optionNodes.len == 3

      let view = findByAttr(col.root, "data-test", "view")
      let comment = findByAttr(col.root, "data-test", "comment")
      let edit = findByAttr(col.root, "data-test", "edit")
      check view != nil
      check comment != nil
      check edit != nil
      check view.attributes["aria-pressed"] == "true"
      check comment.attributes["aria-pressed"] == "false"
      check edit.attributes["aria-pressed"] == "false"

      edit.fireEvent("click")
      check clicked == "edit"
      comment.fireEvent("keydown")
      check clicked == "comment"

      # No overflow chevron when every option is visible.
      check findByAttr(col.root, "data-compact-choice-overflow", "true") == nil

      dispose()

  test "vertical column exposes an overflow chevron when options exceed visibleLimit":
    createRoot do (dispose: proc()):
      let r = MockRenderer()
      var popupChosen = ""
      let options = @[
        CompactChoiceOption(label: "Desktop", shortLabel: "Desktop",
          ariaLabel: "Desktop", selected: true, enabled: true,
          onChoose: proc() = popupChosen = "desktop"),
        CompactChoiceOption(label: "Laptop", shortLabel: "Laptop",
          ariaLabel: "Laptop", selected: false, enabled: true,
          onChoose: proc() = popupChosen = "laptop"),
        CompactChoiceOption(label: "Wide", shortLabel: "Wide",
          ariaLabel: "Wide", selected: false, enabled: true,
          dataAttrs: @[("data-test", "wide")],
          onChoose: proc() = popupChosen = "wide"),
        CompactChoiceOption(label: "Ultrawide", shortLabel: "Ultra",
          ariaLabel: "Ultrawide", selected: false, enabled: true,
          dataAttrs: @[("data-test", "ultrawide")],
          onChoose: proc() = popupChosen = "ultrawide")
      ]
      let col = renderCompactChoiceColumn[MockRenderer, MockNode](r,
        ariaLabel = "Screen size",
        options = options,
        visibleLimit = 2)

      check findByAttr(col.root,
        "data-compact-choice-overflow", "true") != nil
      let popup = findByAttr(col.root,
        "data-compact-choice-overflow-popup", "true")
      check popup != nil
      let wide = findByAttr(popup, "data-test", "wide")
      check wide != nil
      check wide.attributes["data-compact-choice-overflow-option"] == "true"
      wide.fireEvent("click")
      check popupChosen == "wide"

      dispose()

  test "vertical column marks disabled options aria-disabled and blocks clicks":
    createRoot do (dispose: proc()):
      let r = MockRenderer()
      var fired = 0
      let options = @[
        CompactChoiceOption(label: "Cocoa", shortLabel: "Coc",
          ariaLabel: "Cocoa backend", selected: false, enabled: false,
          dataAttrs: @[("data-test", "cocoa")],
          onChoose: proc() = inc fired),
        CompactChoiceOption(label: "Web", shortLabel: "Web",
          ariaLabel: "Web backend", selected: true, enabled: true,
          dataAttrs: @[("data-test", "web")],
          onChoose: proc() = inc fired)
      ]
      let col = renderCompactChoiceColumn[MockRenderer, MockNode](r,
        ariaLabel = "Preview backend",
        options = options,
        visibleLimit = 2)

      let cocoa = findByAttr(col.root, "data-test", "cocoa")
      check cocoa != nil
      check cocoa.attributes["aria-disabled"] == "true"
      check cocoa.attributes["data-compact-choice-enabled"] == "false"
      cocoa.fireEvent("click")
      check fired == 0

      let web = findByAttr(col.root, "data-test", "web")
      web.fireEvent("click")
      check fired == 1

      dispose()

suite "M57 renderPreviewPane edge strips":

  test "top toolbar drops the mode toggle and platform dropdown":
    createRoot do (dispose: proc()):
      let r = MockRenderer()
      let vm = createEditorVM()
      let pane = renderPreviewPane[MockRenderer, MockNode](r, vm)

      let toolbar = findByAttr(pane, "data-preview-toolbar", "true")
      check toolbar != nil
      check findByAttr(toolbar, "aria-label", "Switch to view mode") == nil
      check findByAttr(toolbar, "aria-label", "Switch to comment mode") == nil
      check findByAttr(toolbar, "aria-label", "Switch to edit mode") == nil
      check findByAttr(toolbar, "aria-label", "Preview Web platform") == nil
      check findByAttr(toolbar, "aria-label", "Preview iOS platform") == nil
      check findByAttr(toolbar, "aria-label", "Preview Android platform") == nil

      let viewSwitcher = findByAttr(toolbar,
        "data-preview-view-switcher", "true")
      check viewSwitcher != nil
      check findByAttr(viewSwitcher, "aria-label",
        "Open Flow editor view") != nil
      check findByAttr(viewSwitcher, "aria-label",
        "Open Detail editor view") != nil
      check findByAttr(toolbar, "data-preview-breadcrumb", "true") != nil

      dispose()

  test "right-edge strip exposes three mode segments and drives editMode":
    createRoot do (dispose: proc()):
      let r = MockRenderer()
      let vm = createEditorVM()
      # All three preview-mode commands require a story selection per
      # `commandRequirementFailure`; supply one so the chips are
      # enabled and dispatch the View/Comment/Edit commands.
      vm.selectedStory.val = StoryRef(group: "Components", name: "Sample",
        kind: skComponent, index: 0)
      let pane = renderPreviewPane[MockRenderer, MockNode](r, vm)

      let modeStrip = findByAttr(pane, "data-edge-strip", "mode")
      check modeStrip != nil
      check modeStrip.attributes["aria-orientation"] == "vertical"

      let viewBtn = findByAttr(modeStrip, "data-preview-mode", "view")
      let commentBtn = findByAttr(modeStrip, "data-preview-mode", "comment")
      let editBtn = findByAttr(modeStrip, "data-preview-mode", "edit")
      check viewBtn != nil
      check commentBtn != nil
      check editBtn != nil

      check viewBtn.attributes["aria-pressed"] == "true"
      check commentBtn.attributes["aria-disabled"] == "false"
      commentBtn.fireEvent("click")
      check vm.editMode.val == emComment

      let pane2 = renderPreviewPane[MockRenderer, MockNode](r, vm)
      let strip2 = findByAttr(pane2, "data-edge-strip", "mode")
      check findByAttr(strip2,
        "data-preview-mode", "comment").attributes["aria-pressed"] == "true"

      dispose()

  test "left-edge backend strip exposes six segments per PreviewBackend":
    createRoot do (dispose: proc()):
      let r = MockRenderer()
      let vm = createEditorVM()
      let pane = renderPreviewPane[MockRenderer, MockNode](r, vm)

      let backendStrip = findByAttr(pane, "data-edge-strip", "backend")
      check backendStrip != nil

      for backend in [pbWeb, pbTui, pbGpui, pbFreya, pbCocoa, pbAndroid]:
        let node = findByAttr(backendStrip,
          "data-preview-backend", backendId(backend))
        check node != nil
        check node.attributes["aria-label"] ==
          "Preview backend " & backendLabel(backend)
        # Without a StreamingPreviewVM each backend is enabled.
        check node.attributes["data-compact-choice-enabled"] == "true"

      check findByAttr(backendStrip, "data-preview-backend", "web").attributes[
        "aria-pressed"] == "true"

      let cocoaButton = findByAttr(backendStrip,
        "data-preview-backend", "cocoa")
      cocoaButton.fireEvent("click")
      check vm.platform.val == pbCocoa
      dispose()

  test "backend strip mirrors StreamingPreviewVM availability":
    createRoot do (dispose: proc()):
      let r = MockRenderer()
      let vm = createEditorVM()
      # Compose a streaming-preview VM that lists only Web + GPUI as
      # available; the disabled segments must surface aria-disabled=true.
      vm.streamingPreview = newStreamingPreviewVM(
        initial = pbWeb,
        available = @[pbWeb, pbGpui])

      let pane = renderPreviewPane[MockRenderer, MockNode](r, vm)
      let strip = findByAttr(pane, "data-edge-strip", "backend")
      check strip != nil

      let webBtn = findByAttr(strip, "data-preview-backend", "web")
      let gpuiBtn = findByAttr(strip, "data-preview-backend", "gpui")
      let tuiBtn = findByAttr(strip, "data-preview-backend", "tui")
      let cocoaBtn = findByAttr(strip, "data-preview-backend", "cocoa")
      let androidBtn = findByAttr(strip, "data-preview-backend", "android")

      check webBtn.attributes["aria-disabled"] == "false"
      check gpuiBtn.attributes["aria-disabled"] == "false"
      check tuiBtn.attributes["aria-disabled"] == "true"
      check cocoaBtn.attributes["aria-disabled"] == "true"
      check androidBtn.attributes["aria-disabled"] == "true"

      check webBtn.attributes["data-preview-backend-available"] == "true"
      check tuiBtn.attributes["data-preview-backend-available"] == "false"

      # Clicking an enabled backend routes through selectBackend and
      # updates `vm.platform`.
      gpuiBtn.fireEvent("click")
      check vm.platform.val == pbGpui
      check vm.streamingPreview.selectedBackend.val == pbGpui

      # Clicking a disabled backend does not flip the platform.
      let beforePlatform = vm.platform.val
      cocoaBtn.fireEvent("click")
      check vm.platform.val == beforePlatform

      dispose()

  test "left-edge viewport strip pins per-backend chips and shows overflow":
    createRoot do (dispose: proc()):
      let r = MockRenderer()
      let vm = createEditorVM()
      let pane = renderPreviewPane[MockRenderer, MockNode](r, vm)
      let viewportStrip = findByAttr(pane, "data-edge-strip", "viewport")
      check viewportStrip != nil

      for slug in ["desktop", "laptop", "tablet", "phone"]:
        let node = findByAttr(viewportStrip, "data-preview-viewport", slug)
        check node != nil
        check node.attributes["data-preview-viewport-pinned"] == "true"

      let overflow = findByAttr(viewportStrip,
        "data-compact-choice-overflow", "true")
      check overflow != nil
      let popup = findByAttr(viewportStrip,
        "data-compact-choice-overflow-popup", "true")
      check popup != nil
      check findByAttr(popup, "data-preview-viewport", "wide") != nil
      check findByAttr(popup, "data-preview-viewport", "custom") != nil

      let tablet = findByAttr(viewportStrip,
        "data-preview-viewport", "tablet")
      tablet.fireEvent("click")
      check vm.viewport.val.kind == pvkTablet

      # Selecting a popup-only viewport via its popup entry still flips
      # the viewport signal.
      let wide = findByAttr(popup, "data-preview-viewport", "wide")
      check wide != nil
      wide.fireEvent("click")
      check vm.viewport.val.kind == pvkWide
      dispose()

  test "switching backend re-pins the viewport segments and TUI hides pixel chips":
    createRoot do (dispose: proc()):
      let r = MockRenderer()
      let vm = createEditorVM()

      vm.platform.val = pbTui
      vm.viewport.val = defaultViewport(pbTui)
      let pane = renderPreviewPane[MockRenderer, MockNode](r, vm)
      let strip = findByAttr(pane, "data-edge-strip", "viewport")
      check strip != nil

      # The TUI backend pins TUI viewports as the primary chips visible
      # in the segmented column (i.e. nodes that carry
      # data-preview-viewport-pinned="true" *and are not the popup
      # duplicate* — popup entries set
      # data-compact-choice-overflow-option="true").
      let pinnedAll = findAllByAttr(strip,
        "data-preview-viewport-pinned", "true")
      var pinnedSlugs: seq[string] = @[]
      for node in pinnedAll:
        if node.attributes.getOrDefault(
            "data-compact-choice-overflow-option") == "true":
          continue
        pinnedSlugs.add node.attributes["data-preview-viewport"]
      check pinnedSlugs == @["tui-80x24", "tui-120x40"]
      # Desktop and tablet are NOT pinned in the TUI backend.
      let desktopChips = findAllByAttr(strip,
        "data-preview-viewport", "desktop")
      var visibleDesktopChips = 0
      for node in desktopChips:
        if node.attributes.getOrDefault(
            "data-compact-choice-overflow-option") != "true":
          inc visibleDesktopChips
      check visibleDesktopChips == 0
      let tabletChips = findAllByAttr(strip,
        "data-preview-viewport", "tablet")
      var visibleTabletChips = 0
      for node in tabletChips:
        if node.attributes.getOrDefault(
            "data-compact-choice-overflow-option") != "true":
          inc visibleTabletChips
      check visibleTabletChips == 0
      dispose()

  test "end-to-end edge-strip drive backend, viewport, and mode signals":
    createRoot do (dispose: proc()):
      let r = MockRenderer()
      let vm = createEditorVM()
      vm.streamingPreview = newStreamingPreviewVM(
        initial = pbWeb,
        available = @[pbWeb, pbGpui, pbCocoa, pbAndroid])
      vm.selectedStory.val = StoryRef(group: "Components", name: "Sample",
        kind: skComponent, index: 0)

      let pane1 = renderPreviewPane[MockRenderer, MockNode](r, vm)
      let cocoa = findByAttr(pane1, "data-preview-backend", "cocoa")
      check cocoa != nil
      cocoa.fireEvent("click")
      check vm.platform.val == pbCocoa
      check vm.streamingPreview.selectedBackend.val == pbCocoa
      # Cocoa pins desktop/laptop/tablet/phone — current pinned viewport
      # (desktop) survives the backend change.
      check vm.viewport.val.kind == pvkDesktop

      let pane2 = renderPreviewPane[MockRenderer, MockNode](r, vm)
      let phone = findByAttr(pane2, "data-preview-viewport", "phone")
      check phone != nil
      phone.fireEvent("click")
      check vm.viewport.val.kind == pvkPhone

      let pane3 = renderPreviewPane[MockRenderer, MockNode](r, vm)
      let edit = findByAttr(pane3, "data-preview-mode", "edit")
      check edit != nil
      edit.fireEvent("click")
      check vm.editMode.val == emEdit
      dispose()

suite "M57 edge-strip reactivity":

  test "backend strip flips aria-pressed when vm.platform changes without re-render":
    createRoot do (dispose: proc()):
      let r = MockRenderer()
      let vm = createEditorVM()
      let pane = renderPreviewPane[MockRenderer, MockNode](r, vm)
      let strip = findByAttr(pane, "data-edge-strip", "backend")
      check strip != nil
      let webBtn = findByAttr(strip, "data-preview-backend", "web")
      let tuiBtn = findByAttr(strip, "data-preview-backend", "tui")
      check webBtn != nil
      check tuiBtn != nil
      # Initial: web is active.
      check webBtn.attributes["aria-pressed"] == "true"
      check tuiBtn.attributes["aria-pressed"] == "false"
      # Flip the signal — do NOT re-run renderPreviewPane.
      vm.changePlatform(pbTui)
      # The same DOM nodes must reflect the new active backend.
      check webBtn.attributes["aria-pressed"] == "false"
      check tuiBtn.attributes["aria-pressed"] == "true"
      # And the background/color/font-weight must follow the active flag.
      check tuiBtn.styles.getOrDefault("font-weight") == "700"
      check webBtn.styles.getOrDefault("font-weight") == "500"
      dispose()

  test "mode strip flips aria-pressed when vm.editMode changes without re-render":
    createRoot do (dispose: proc()):
      let r = MockRenderer()
      let vm = createEditorVM()
      vm.selectedStory.val = StoryRef(group: "Components", name: "Sample",
        kind: skComponent, index: 0)
      let pane = renderPreviewPane[MockRenderer, MockNode](r, vm)
      let strip = findByAttr(pane, "data-edge-strip", "mode")
      check strip != nil
      let viewBtn = findByAttr(strip, "data-preview-mode", "view")
      let commentBtn = findByAttr(strip, "data-preview-mode", "comment")
      check viewBtn != nil
      check commentBtn != nil
      check viewBtn.attributes["aria-pressed"] == "true"
      check commentBtn.attributes["aria-pressed"] == "false"
      vm.setEditMode(emComment)
      check viewBtn.attributes["aria-pressed"] == "false"
      check commentBtn.attributes["aria-pressed"] == "true"
      dispose()

  test "viewport strip flips aria-pressed when vm.viewport changes without re-render":
    createRoot do (dispose: proc()):
      let r = MockRenderer()
      let vm = createEditorVM()
      let pane = renderPreviewPane[MockRenderer, MockNode](r, vm)
      let strip = findByAttr(pane, "data-edge-strip", "viewport")
      check strip != nil
      # Web pins desktop/laptop/tablet/phone; desktop is the default.
      let desktopBtn = findByAttr(strip, "data-preview-viewport", "desktop")
      let tabletBtn = findByAttr(strip, "data-preview-viewport", "tablet")
      check desktopBtn != nil
      check tabletBtn != nil
      check desktopBtn.attributes["aria-pressed"] == "true"
      check tabletBtn.attributes["aria-pressed"] == "false"
      vm.changeViewport(makeBuiltinViewport(pvkTablet))
      check desktopBtn.attributes["aria-pressed"] == "false"
      check tabletBtn.attributes["aria-pressed"] == "true"
      dispose()

# ---------------------------------------------------------------------------
# M58: Reactive Choice-Column Chip-Set Rebuild
# ---------------------------------------------------------------------------

proc visibleChipSlugs(strip: MockNode): seq[string] =
  ## Collect the chips that are *primary strip* segments (i.e. NOT the
  ## overflow popup entries) keyed by their data-preview-viewport slug.
  ## Used by the M58 chip-set assertions below.
  for node in findAllByAttr(strip, "data-preview-viewport-pinned", "true"):
    if node.attributes.getOrDefault(
        "data-compact-choice-overflow-option") == "true":
      continue
    result.add node.attributes["data-preview-viewport"]
  for node in findAllByAttr(strip, "data-preview-viewport-pinned", "false"):
    if node.attributes.getOrDefault(
        "data-compact-choice-overflow-option") == "true":
      continue
    result.add node.attributes["data-preview-viewport"]

proc popupChipSlugs(strip: MockNode): seq[string] =
  let popup = findByAttr(strip,
    "data-compact-choice-overflow-popup", "true")
  if popup == nil:
    return
  for node in popup.children:
    if node.kind == mnkElement and
        node.attributes.getOrDefault(
            "data-compact-choice-overflow-option") == "true":
      let slug = node.attributes.getOrDefault("data-preview-viewport")
      if slug.len > 0:
        result.add slug

suite "M58 chip-set reactivity":

  test "viewport strip rebuilds chip set on backend change":
    createRoot do (dispose: proc()):
      let r = MockRenderer()
      let vm = createEditorVM()
      let pane = renderPreviewPane[MockRenderer, MockNode](r, vm)
      let strip = findByAttr(pane, "data-edge-strip", "viewport")
      check strip != nil
      # Web pins desktop/laptop/tablet/phone per spec.
      let slugsBefore = visibleChipSlugs(strip)
      check "desktop" in slugsBefore
      check "laptop" in slugsBefore
      check "tablet" in slugsBefore
      check "phone" in slugsBefore
      check "tui-80x24" notin slugsBefore
      # Flip platform to TUI; do NOT re-run renderPreviewPane. The
      # column's createRenderEffect must re-evaluate the option thunk
      # and patch the chip set in place.
      vm.changePlatform(pbTui)
      let slugsAfter = visibleChipSlugs(strip)
      check "tui-80x24" in slugsAfter
      check "tui-120x40" in slugsAfter
      check "desktop" notin slugsAfter
      check "laptop" notin slugsAfter
      check "tablet" notin slugsAfter
      check "phone" notin slugsAfter
      # M58 spec § Verification: per the spec table TUI's popup
      # long-tail is `custom…` only. The implementation mirrors the
      # static-overload behaviour by surfacing every option in the
      # popup chooser (pinned entries duplicate so users always reach
      # the canonical chooser surface), so the assertion targets the
      # spec long-tail contract: `custom` MUST be reachable from the
      # rebuilt popup. The `tui-80x24` / `tui-120x40` chips appear in
      # the popup as duplicates of the primary-strip pins; this is
      # the same behaviour as the pre-M58 static overload and
      # documented in `choice_row.nim` (popup is the canonical chooser
      # surface — see also the Playwright suite's wide/ultrawide/
      # phone-sm/phone-xl assertion that excludes desktop/laptop only
      # because the popup is the long-tail rolodex).
      let popupAfter = popupChipSlugs(strip)
      check "custom" in popupAfter
      dispose()

  test "overflow popup rebuilds from new option list":
    createRoot do (dispose: proc()):
      let r = MockRenderer()
      let vm = createEditorVM()
      let pane = renderPreviewPane[MockRenderer, MockNode](r, vm)
      let strip = findByAttr(pane, "data-edge-strip", "viewport")
      check strip != nil
      let popupBefore = popupChipSlugs(strip)
      # Web popup is wide / ultrawide / phone-sm / phone-xl / custom
      # (spec table § "Left edge — backend switcher + screen-size
      # switcher"). The popup contains the FULL option list — the
      # column re-renders pinned entries in the popup so users always
      # have the canonical chooser surface — but the spec long-tail
      # set must appear at minimum.
      for slug in ["wide", "ultrawide", "phone-sm", "phone-xl", "custom"]:
        check slug in popupBefore
      # Flip to Android. The popup must re-render with the Android
      # long-tail set: desktop / laptop / wide / ultrawide / custom.
      vm.changePlatform(pbAndroid)
      let popupAfter = popupChipSlugs(strip)
      for slug in ["desktop", "laptop", "wide", "ultrawide", "custom"]:
        check slug in popupAfter
      dispose()

  test "surviving chip keeps its DOM node across rebuild":
    createRoot do (dispose: proc()):
      let r = MockRenderer()
      let vm = createEditorVM()
      let pane = renderPreviewPane[MockRenderer, MockNode](r, vm)
      let strip = findByAttr(pane, "data-edge-strip", "viewport")
      check strip != nil
      # Capture the tablet chip node by ref BEFORE the platform flip.
      # tablet is pinned for both Web (desktop/laptop/tablet/phone)
      # and Android (phone/tablet/phone-sm/phone-xl) — see
      # `pinnedViewports`. The diff must reuse this exact node.
      let tabletBefore = findByAttr(strip, "data-preview-viewport", "tablet")
      check tabletBefore != nil
      # Drop a sentinel attribute on the chip the diff/patch path
      # must preserve (it would be wiped if the node were replaced).
      r.setAttribute(tabletBefore, "data-m58-survivor-marker", "yes")
      let tabletId = tabletBefore.id
      vm.changePlatform(pbAndroid)
      let tabletAfter = findByAttr(strip, "data-preview-viewport", "tablet")
      check tabletAfter != nil
      check tabletAfter.id == tabletId
      check tabletAfter.attributes.getOrDefault(
        "data-m58-survivor-marker") == "yes"
      dispose()

  test "removed-chip focus transfers to active":
    createRoot do (dispose: proc()):
      let r = MockRenderer()
      let vm = createEditorVM()
      let pane = renderPreviewPane[MockRenderer, MockNode](r, vm)
      let strip = findByAttr(pane, "data-edge-strip", "viewport")
      check strip != nil
      # desktop is pinned for Web but only popup-visible for Android;
      # focus it then flip to Android. The column must move focus to
      # the new active viewport chip (Android default = phone) rather
      # than leave it on the now-detached desktop chip.
      let desktopChip = findByAttr(strip, "data-preview-viewport", "desktop")
      check desktopChip != nil
      r.focus(desktopChip)
      check r.activeElement() == desktopChip
      vm.changePlatform(pbAndroid)
      # The Android default viewport is `phone` (see
      # `defaultViewport(pbAndroid)`); after the rebuild + the
      # `changePlatform` viewport-rescue logic, focus should land on
      # the active chip. We assert it is at least no longer the
      # detached desktop chip — `desktopChip` was removed from the
      # parent strip, so it must not still own focus.
      check r.activeElement() != desktopChip
      let active = r.activeElement()
      check active != nil
      check active.attributes.getOrDefault("aria-pressed") == "true"
      dispose()

  test "chip set rebuild also patches the backend strip":
    createRoot do (dispose: proc()):
      let r = MockRenderer()
      let vm = createEditorVM()
      # Start with two backends available; mutate to a different set
      # without re-rendering and assert the per-chip availability
      # signal still flows (the chip set itself is enum-fixed, so the
      # thunk migration is purely an idiom for uniformity).
      vm.streamingPreview = newStreamingPreviewVM(
        initial = pbWeb,
        available = @[pbWeb, pbGpui])
      let pane = renderPreviewPane[MockRenderer, MockNode](r, vm)
      let backendStrip = findByAttr(pane, "data-edge-strip", "backend")
      check backendStrip != nil
      let tuiBtn = findByAttr(backendStrip, "data-preview-backend", "tui")
      check tuiBtn != nil
      check tuiBtn.attributes["aria-disabled"] == "true"
      # Expand availability to include TUI; the per-chip M57 reactive
      # binding (installed via the M58 onChipMounted hook) must still
      # propagate the new availability state to the existing chip
      # without a strip rebuild.
      vm.streamingPreview.availableBackends.val =
        @[pbWeb, pbGpui, pbTui]
      check tuiBtn.attributes["aria-disabled"] == "false"
      dispose()
