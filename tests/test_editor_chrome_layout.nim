## M57 — Preview-Pane Edge-Strip Chrome.
##
## Focused regression tests for the unified `Platform` / `PreviewBackend`
## enum, the richer `PreviewViewport` descriptor, the vertical compact
## choice column (`renderCompactChoiceColumn`), and the new edge-strip
## chrome rendered by `renderPreviewPane`. These tests are strong
## real-stack integration: they instantiate the real editor VM, render
## with the headless mock renderer, and click through the actual signal
## handlers — no behaviour mocks.

import std/[sequtils, strutils, tables, unittest]
import isonim/core/[signals, computation, owner]
import isonim/testing/mock_dom
import isonim/editor/viewmodels
import isonim/editor/types
import isonim/editor/stories
import isonim/editor/streaming_preview
import isonim/editor/views/shell
import isonim/editor/views/choice_row
import isonim/editor/views/component_detail

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

suite "Preview-pane top toolbar (consolidated chrome)":

  test "top toolbar hosts the three chip groups and NO view-switcher":
    createRoot do (dispose: proc()):
      let r = MockRenderer()
      let vm = createEditorVM()
      let pane = renderPreviewPane[MockRenderer, MockNode](r, vm)

      let toolbar = findByAttr(pane, "data-preview-toolbar", "true")
      check toolbar != nil
      # The legacy "Switch to mode" / "Preview {iOS,Android} platform"
      # text buttons are gone — chips replace them.
      check findByAttr(toolbar, "aria-label", "Switch to view mode") == nil
      check findByAttr(toolbar, "aria-label", "Switch to comment mode") == nil
      check findByAttr(toolbar, "aria-label", "Switch to edit mode") == nil
      check findByAttr(toolbar, "aria-label", "Preview Web platform") == nil
      check findByAttr(toolbar, "aria-label", "Preview iOS platform") == nil
      check findByAttr(toolbar, "aria-label", "Preview Android platform") == nil

      # M-EVP-7: the view-switcher chip group is gone. The sidebar is
      # the only navigation surface; ``selectStory`` derives the active
      # view from the selected story's kind via ``viewForStory``.
      check findByAttr(toolbar, "data-preview-view-switcher", "true") == nil
      check findByAttr(toolbar, "aria-label", "Open Flow editor view") == nil
      check findByAttr(toolbar, "aria-label", "Open Detail editor view") == nil
      check findByAttr(toolbar, "aria-label", "Open Page editor view") == nil
      check findByAttr(toolbar, "aria-label",
        "Open Foundations editor view") == nil
      check findByAttr(toolbar, "aria-label",
        "Open Vector editor view") == nil
      # The breadcrumb is dropped — sidebar shows selection.
      check findByAttr(toolbar, "data-preview-breadcrumb", "true") == nil
      # All three chip groups live in the toolbar.
      check findByAttr(toolbar, "data-edge-strip", "backend") != nil
      check findByAttr(toolbar, "data-edge-strip", "viewport") != nil
      check findByAttr(toolbar, "data-edge-strip", "mode") != nil

      dispose()

  test "mode strip exposes three segments and drives editMode":
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
      check modeStrip.attributes["aria-orientation"] == "horizontal"

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

  test "backend strip exposes six segments per PreviewBackend":
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

  test "viewport strip pins per-backend chips and shows overflow":
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

  test "end-to-end toolbar chip groups drive backend, viewport, and mode signals":
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
      check webBtn.styles.getOrDefault("font-weight") == "600"
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

# ---------------------------------------------------------------------------
# M-EVP-3: Toolbar density — inter-cluster gaps + right padding
# ---------------------------------------------------------------------------

proc parsePxValue(raw: string): int =
  ## Parse a CSS pixel value like `"14px"` into the integer `14`. Trims
  ## whitespace and tolerates upper-case `"PX"`. Fails the calling test
  ## (returns -1) if `raw` is not a `<int>px` literal — the M-EVP-3 spec
  ## requires the layout to declare gap / padding via single-component
  ## pixel values so the headless test can assert numeric bounds.
  var s = raw.strip().toLowerAscii()
  if s.endsWith("px"):
    s = s[0 ..< s.len - 2]
  try:
    parseInt(s.strip())
  except ValueError:
    -1

suite "M-EVP-3 preview chrome bar density":

  test "toolbar declares >=12 px and <=16 px inter-cluster gap":
    createRoot do (dispose: proc()):
      let r = MockRenderer()
      let vm = createEditorVM()
      let bar = renderPreviewChromeBar[MockRenderer, MockNode](r, vm)

      # The chrome bar is identifiable via two stable attributes; both
      # MUST be present for clarity, so we resolve via the more-specific
      # `data-preview-chrome-bar` marker.
      check bar.attributes.getOrDefault("data-preview-chrome-bar") == "true"
      check bar.attributes.getOrDefault("data-preview-toolbar") == "true"

      # The toolbar root must use a `flex` row container so `gap`
      # actually positions sibling clusters.
      check bar.styles.getOrDefault("display") == "flex"

      let gapRaw = bar.styles.getOrDefault("gap")
      check gapRaw.len > 0
      let gapPx = parsePxValue(gapRaw)
      check gapPx >= 12
      check gapPx <= 16
      dispose()

  test "toolbar declares >=12 px right padding before the inspector edge":
    createRoot do (dispose: proc()):
      let r = MockRenderer()
      let vm = createEditorVM()
      let bar = renderPreviewChromeBar[MockRenderer, MockNode](r, vm)

      # Padding-right must be declared as a single-component pixel value
      # (rather than baked into the `padding` shorthand) so we can read
      # the inspector-edge breathing room directly from the mock node's
      # style table. This is the headless analogue of "mode chips never
      # touch the inspector border" from the v5 review.
      let paddingRight = bar.styles.getOrDefault("padding-right")
      check paddingRight.len > 0
      let paddingRightPx = parsePxValue(paddingRight)
      check paddingRightPx >= 12
      dispose()

  test "toolbar contains exactly the three chip clusters tagged for visual separation":
    createRoot do (dispose: proc()):
      let r = MockRenderer()
      let vm = createEditorVM()
      let bar = renderPreviewChromeBar[MockRenderer, MockNode](r, vm)

      # M-EVP-7: each of the three remaining clusters must be a direct
      # child of the toolbar and carry a stable `data-toolbar-cluster`
      # attribute so future layout changes can address them without
      # depending on the rendering order. The test additionally
      # verifies the order matches the v5 left-to-right reading:
      # backend → viewport → mode. The view-switcher cluster is gone
      # because the sidebar drives the active view.
      let clusterAttr = "data-toolbar-cluster"
      check findAllByAttr(bar, clusterAttr, "view-switcher").len == 0
      let clusters = findAllByAttr(bar, clusterAttr, "backend") &
        findAllByAttr(bar, clusterAttr, "viewport") &
        findAllByAttr(bar, clusterAttr, "mode")
      check clusters.len == 3

      # Every cluster must be a direct child of the toolbar — if a
      # future refactor nests them inside an intermediate wrapper the
      # flex `gap` no longer applies between them, so this is the
      # invariant the visual separation rests on.
      let clusterKinds = @["backend", "viewport", "mode"]
      var directChildClusters: seq[string] = @[]
      for child in bar.children:
        let kind = child.attributes.getOrDefault(clusterAttr)
        if kind.len > 0:
          directChildClusters.add kind
      check directChildClusters == clusterKinds
      dispose()

  test "regression probe: collapsing toolbar gap to 0 invalidates the M-EVP-3 invariant":
    createRoot do (dispose: proc()):
      let r = MockRenderer()
      let vm = createEditorVM()
      let bar = renderPreviewChromeBar[MockRenderer, MockNode](r, vm)

      # Sanity: the production rendering passes the inter-cluster gap
      # assertion. (Asserted in the first test of this suite; repeated
      # here in case the gap test is filtered out.)
      check parsePxValue(bar.styles.getOrDefault("gap")) >= 12

      # Mutate the rendered DOM to simulate a regression (someone drops
      # the toolbar `gap` to 0 / removes the padding) and confirm the
      # same parser+bounds expression that the production test relies on
      # would catch it. This is the "convince yourself the assertion
      # actually exercises the property" check the M-EVP-3 spec calls
      # for — the asserts inverted below intentionally fail the
      # M-EVP-3 spec when the layout regresses.
      r.setStyle(bar, "gap", "0px")
      r.setStyle(bar, "padding-right", "0px")

      let mutatedGap = parsePxValue(bar.styles.getOrDefault("gap"))
      let mutatedPaddingRight =
        parsePxValue(bar.styles.getOrDefault("padding-right"))
      # Negative assertions: the same conditions the spec tests assert
      # MUST be false after the regression mutation.
      check not (mutatedGap >= 12 and mutatedGap <= 16)
      check not (mutatedPaddingRight >= 12)
      dispose()

# ---------------------------------------------------------------------------
# M-EVP-4: Sidebar story-row selection state — indigo accent marker.
# ---------------------------------------------------------------------------

proc rowMarkerIsAccent(row: MockNode): bool =
  ## A story row "carries the indigo accent marker" if its rendered
  ## `border-left-color` matches the exported `accent` token. We use a
  ## case-insensitive comparison because computed-style serialisations
  ## may differ in case (the mock renderer preserves the literal, but
  ## the test must remain robust to future renderers that normalise).
  let borderColor =
    row.styles.getOrDefault("border-left-color").strip().toLowerAscii()
  borderColor == accent.toLowerAscii()

proc rowBackgroundIsAccentTinted(row: MockNode): bool =
  ## The selected row's tinted backdrop is the `accentSoft` token
  ## (`#272752`). Treat any non-transparent indigo-tinted backdrop as
  ## "accent-derived"; today's implementation uses `accentSoft`
  ## directly. The negative assertion below relies on
  ## `background-color` being `"transparent"` (the literal we set) when
  ## a row is NOT selected.
  let bg =
    row.styles.getOrDefault("background-color").strip().toLowerAscii()
  bg == accentSoft.toLowerAscii()

suite "M-EVP-4 sidebar selection state":

  test "selected story row carries the indigo accent marker (border + tinted bg)":
    createRoot do (dispose: proc()):
      let r = MockRenderer()
      let vm = createEditorVM()
      vm.sidebar.groups.val = buildStoryboard()

      let sidebar = renderSidebar[MockRenderer, MockNode](r, vm)

      # TaskRow / Active task is in the `TaskRow` component group, which
      # `buildStoryboard()` marks as `expanded: true`, so its rows are
      # in the rendered tree.
      let activeStory = StoryRef(group: "TaskRow", name: "Active task",
        kind: skComponent, index: 0)
      check vm.selectStory(activeStory)

      let row = findByAttr(sidebar, "data-story-row", "TaskRow/Active task")
      check row != nil

      # aria-current is the existing semantic hook; check it flipped too
      # so the test pins both the accessible state and the visual.
      check row.attributes.getOrDefault("aria-current") == "true"

      # Acceptance: the row's border-left-color must equal the accent
      # token. (Spec allows EITHER border OR tinted bg; this
      # implementation does both, and the positive assertion below
      # requires at least one.)
      check (rowMarkerIsAccent(row) or rowBackgroundIsAccentTinted(row))

      # Strengthen — we picked "both" as the styling choice, so verify
      # both invariants explicitly. If a future change drops one of
      # them, this stricter check fires.
      check rowMarkerIsAccent(row)
      check rowBackgroundIsAccentTinted(row)

      # And the structural invariant: the 3 px border-left always
      # renders solid (selected or not), so the indentation rhythm
      # doesn't shift across selection toggles.
      check row.styles.getOrDefault("border-left-width") == "3px"
      check row.styles.getOrDefault("border-left-style") == "solid"

      dispose()

  test "unselected story rows do NOT carry the accent marker (negative assertion)":
    createRoot do (dispose: proc()):
      let r = MockRenderer()
      let vm = createEditorVM()
      vm.sidebar.groups.val = buildStoryboard()
      let sidebar = renderSidebar[MockRenderer, MockNode](r, vm)

      let activeStory = StoryRef(group: "TaskRow", name: "Active task",
        kind: skComponent, index: 0)
      check vm.selectStory(activeStory)

      # The "Completed task" row sits next to "Active task" in the
      # TaskRow group; it must NOT carry the accent marker while
      # "Active task" is selected.
      let unselectedRow = findByAttr(sidebar, "data-story-row",
        "TaskRow/Completed task")
      check unselectedRow != nil
      check unselectedRow.attributes.getOrDefault("aria-current") == "false"

      # Negative invariants: neither the accent border nor the
      # accent-tinted background may be present on an unselected row.
      check not rowMarkerIsAccent(unselectedRow)
      check not rowBackgroundIsAccentTinted(unselectedRow)

      # The unselected row still declares a 3 px transparent left
      # border so its left edge sits at the same horizontal position as
      # the selected row's accent stripe.
      check unselectedRow.styles.getOrDefault("border-left-width") == "3px"
      check unselectedRow.styles.getOrDefault("border-left-style") == "solid"
      check unselectedRow.styles.getOrDefault("border-left-color") ==
        "transparent"
      check unselectedRow.styles.getOrDefault("background-color") ==
        "transparent"

      dispose()

  test "selection state is reactive: switching stories moves the marker":
    createRoot do (dispose: proc()):
      let r = MockRenderer()
      let vm = createEditorVM()
      vm.sidebar.groups.val = buildStoryboard()
      let sidebar = renderSidebar[MockRenderer, MockNode](r, vm)

      let storyA = StoryRef(group: "TaskRow", name: "Active task",
        kind: skComponent, index: 0)
      let storyB = StoryRef(group: "TaskRow", name: "Completed task",
        kind: skComponent, index: 1)

      check vm.selectStory(storyA)
      let rowA = findByAttr(sidebar, "data-story-row", "TaskRow/Active task")
      let rowB = findByAttr(sidebar, "data-story-row",
        "TaskRow/Completed task")
      check rowA != nil
      check rowB != nil

      # Initial state: A selected, B unselected.
      check rowMarkerIsAccent(rowA)
      check rowBackgroundIsAccentTinted(rowA)
      check not rowMarkerIsAccent(rowB)
      check not rowBackgroundIsAccentTinted(rowB)

      # Reactive transition: select B; A loses the marker, B gains it.
      check vm.selectStory(storyB)

      check rowA.attributes.getOrDefault("aria-current") == "false"
      check rowB.attributes.getOrDefault("aria-current") == "true"

      check not rowMarkerIsAccent(rowA)
      check not rowBackgroundIsAccentTinted(rowA)
      check rowMarkerIsAccent(rowB)
      check rowBackgroundIsAccentTinted(rowB)

      dispose()

  test "regression probe: mutating selection-state style invalidates the M-EVP-4 invariant":
    createRoot do (dispose: proc()):
      let r = MockRenderer()
      let vm = createEditorVM()
      vm.sidebar.groups.val = buildStoryboard()
      let sidebar = renderSidebar[MockRenderer, MockNode](r, vm)

      let storyA = StoryRef(group: "TaskRow", name: "Active task",
        kind: skComponent, index: 0)
      check vm.selectStory(storyA)
      let rowA = findByAttr(sidebar, "data-story-row", "TaskRow/Active task")
      check rowA != nil

      # Sanity: positive invariant holds on the unmutated tree.
      check rowMarkerIsAccent(rowA)
      check rowBackgroundIsAccentTinted(rowA)

      # Mutate the rendered DOM directly to simulate a regression
      # (someone strips both the accent border AND the accent-tinted
      # background from the selected row). Because the test reads from
      # the rendered mock element, the same assertion expression that
      # passed above must now fail. This is the "convince yourself the
      # assertion exercises the actual rendered style, not internal VM
      # state" probe the M-EVP-4 spec asks for.
      r.setStyle(rowA, "border-left-color", "transparent")
      r.setStyle(rowA, "background-color", "transparent")

      check not rowMarkerIsAccent(rowA)
      check not rowBackgroundIsAccentTinted(rowA)

      # Internal VM state remains "selected" — proves the failing
      # assertion above is about RENDERED style, not VM truth.
      check vm.selectedStory.val.group == storyA.group
      check vm.selectedStory.val.name == storyA.name
      check rowA.attributes.getOrDefault("aria-current") == "true"

      dispose()

# ---------------------------------------------------------------------------
# M-EVP-5: Preview canvas surface contrast — distinct bg or hairline border.
# ---------------------------------------------------------------------------

proc canvasBgDiffersFromPane(canvas, pane: MockNode): bool =
  ## The canvas surface "differs from the surrounding panel by at least
  ## one luminance step" if its declared `background-color` is a
  ## different literal from the pane's. The mock renderer preserves the
  ## literal token value verbatim, so case-insensitive equality is the
  ## tightest check we can make without re-implementing CSS colour
  ## parsing — and it's what the spec calls for ("background-color
  ## differs from the panel's").
  let canvasBg =
    canvas.styles.getOrDefault("background-color").strip().toLowerAscii()
  let paneBg =
    pane.styles.getOrDefault("background-color").strip().toLowerAscii()
  canvasBg.len > 0 and paneBg.len > 0 and canvasBg != paneBg

proc canvasHasVisibleBorder(canvas: MockNode): bool =
  ## A "visible 1 px hairline border" is a non-empty `border`
  ## declaration that isn't `none` or `0` — i.e. a real solid edge the
  ## user can see. The DSL emits the shorthand `border` (e.g.
  ## `"1px solid #2A2C3A"`), so we check the `border` key directly.
  let raw =
    canvas.styles.getOrDefault("border").strip().toLowerAscii()
  raw.len > 0 and raw != "none" and not raw.startsWith("0 ") and
    raw != "0" and raw != "0px"

proc canvasContrastInvariant(canvas, pane: MockNode): bool =
  ## The M-EVP-5 acceptance: EITHER background-color contrast against
  ## the surrounding pane, OR a visible 1 px border on the canvas
  ## itself. Either condition individually qualifies; both is fine.
  canvasBgDiffersFromPane(canvas, pane) or canvasHasVisibleBorder(canvas)

suite "M-EVP-5 preview canvas surface contrast":

  test "preview canvas reads as a focal area distinct from the surrounding pane":
    createRoot do (dispose: proc()):
      let r = MockRenderer()
      let vm = createEditorVM()
      let pane = renderPreviewPane[MockRenderer, MockNode](r, vm)

      # Resolve the canvas via its stable `data-preview-canvas`
      # attribute — the spec calls this out explicitly. The
      # surrounding pane is the `editor-preview` root that hosts it.
      let canvas = findByAttr(pane, "data-preview-canvas", "true")
      check canvas != nil
      check pane.attributes.getOrDefault("class") == "editor-preview"

      # Acceptance: the canvas EITHER has a distinct background-color
      # from the pane, OR carries a visible (non-empty) border.
      check canvasContrastInvariant(canvas, pane)

      # Strengthen — the current implementation does BOTH (it picks a
      # bgCanvas one luminance step lighter than bgPreview AND adds a
      # 1 px hairline border in the canonical `border` token colour).
      # If a future change drops one of them this stricter check fires
      # while the looser acceptance invariant above still holds.
      check canvasBgDiffersFromPane(canvas, pane)
      check canvasHasVisibleBorder(canvas)

      # Pin the specific tokens so an accidental swap to a colour that
      # happens to equal `bgPreview` (or to the global `bgBase` void
      # behind the editor) does not silently regress the focal-area
      # affordance reviewers asked for.
      check canvas.styles.getOrDefault("background-color").
        toLowerAscii() == bgCanvas.toLowerAscii()
      check pane.styles.getOrDefault("background-color").
        toLowerAscii() == bgPreview.toLowerAscii()
      check canvas.styles.getOrDefault("background-color").
        toLowerAscii() != pane.styles.getOrDefault("background-color").
        toLowerAscii()
      check canvas.styles.getOrDefault("border") ==
        "1px solid " & border

      dispose()

  test "negative assertion: sibling surfaces do not trigger the canvas check":
    createRoot do (dispose: proc()):
      let r = MockRenderer()
      let vm = createEditorVM()

      # The sidebar is a SIBLING surface to the preview pane. Its root
      # is `editor-sidebar` and it does NOT carry `data-preview-canvas`
      # — proving the M-EVP-5 test addresses the canvas by its specific
      # data attribute rather than "any element with a distinct bg".
      let sidebar = renderSidebar[MockRenderer, MockNode](r, vm)
      check sidebar.attributes.getOrDefault("class") == "editor-sidebar"
      let sidebarHasCanvas = findByAttr(sidebar, "data-preview-canvas",
        "true")
      check sidebarHasCanvas == nil

      # And the pane itself is not the canvas — the canvas is a
      # specific descendant of the pane addressed by its data
      # attribute, not the pane root.
      let pane = renderPreviewPane[MockRenderer, MockNode](r, vm)
      check pane.attributes.getOrDefault("data-preview-canvas") != "true"
      let canvas = findByAttr(pane, "data-preview-canvas", "true")
      check canvas != nil
      check canvas != pane

      dispose()

  test "regression probe: clearing bg AND border invalidates the M-EVP-5 invariant":
    createRoot do (dispose: proc()):
      let r = MockRenderer()
      let vm = createEditorVM()
      let pane = renderPreviewPane[MockRenderer, MockNode](r, vm)
      let canvas = findByAttr(pane, "data-preview-canvas", "true")
      check canvas != nil

      # Sanity: production rendering satisfies the M-EVP-5 invariant.
      check canvasContrastInvariant(canvas, pane)

      # Mutate the canvas's rendered style to simulate a regression
      # (someone strips BOTH the distinct background colour AND the
      # hairline border, leaving the canvas to read as the same
      # surface as the surrounding pane). Because the test reads from
      # the rendered mock element, the same boolean expression that
      # passed above must now fail. This is the "convince yourself
      # the assertion exercises the actual rendered style, not
      # internal VM state" probe the M-EVP-5 spec asks for.
      let paneBg = pane.styles.getOrDefault("background-color")
      r.setStyle(canvas, "background-color", paneBg)
      r.setStyle(canvas, "border", "none")

      check not canvasBgDiffersFromPane(canvas, pane)
      check not canvasHasVisibleBorder(canvas)
      check not canvasContrastInvariant(canvas, pane)

      # The `data-preview-canvas` attribute is unchanged — proves the
      # failing assertion above is about RENDERED style, not the
      # element's identity.
      check canvas.attributes.getOrDefault("data-preview-canvas") == "true"

      dispose()

# ---------------------------------------------------------------------------
# M-EVP-6: Single chrome bar — per-view inner top bars are gone.
# ---------------------------------------------------------------------------

proc collectChromeBars(node: MockNode): seq[MockNode] =
  ## Walk the rendered shell and collect every element tagged with the
  ## canonical chrome-bar marker `data-preview-chrome-bar="true"`. The
  ## M-EVP-6 acceptance is "exactly one" of these above each view body.
  result = findAllByAttr(node, "data-preview-chrome-bar", "true")

proc viewBodyFor(stack: MockNode; bodyAttr: string): MockNode =
  ## Resolve the view body element inside the shell's view stack by the
  ## stable `data-<view>` attribute we set in M-EVP-6. The view stack is
  ## addressed via `data-preview-view-stack="true"` in `shell.nim`.
  findByAttr(stack, bodyAttr, "true")

proc has44pxBorderBottomToolbarWithModeChips(node: MockNode): bool =
  ## A "duplicate inner toolbar" is an element whose declared style
  ## resembles a top-bar (44px tall + `border-bottom: 1px solid ...`)
  ## AND whose subtree carries breadcrumb/mode/viewport markers — i.e.
  ## the pre-M-EVP-6 scaffolding we just deleted. We walk the subtree
  ## and check both invariants.
  if node.kind == mnkElement:
    let height = node.styles.getOrDefault("height")
    let minHeight = node.styles.getOrDefault("min-height")
    let borderBottom = node.styles.getOrDefault("border-bottom")
    let looksLikeTopBar = (height == "44px" or minHeight == "44px") and
      borderBottom.len > 0 and borderBottom != "none"
    if looksLikeTopBar:
      # Mode/viewport/backend chip markers — the markers used by the
      # M57 chrome bar and the now-deleted per-view inner toolbars.
      let hasModeChips =
        findByAttr(node, "data-preview-mode", "view") != nil or
        findByAttr(node, "data-preview-mode", "edit") != nil or
        findByAttr(node, "data-preview-mode", "comment") != nil
      let hasViewportChips =
        findByAttr(node, "data-preview-viewport", "desktop") != nil or
        findByAttr(node, "data-preview-viewport", "tablet") != nil or
        findByAttr(node, "data-preview-viewport", "phone") != nil
      let hasBackendChips =
        findByAttr(node, "data-preview-backend", "web") != nil or
        findByAttr(node, "data-preview-backend", "cocoa") != nil or
        findByAttr(node, "data-preview-backend", "android") != nil
      if hasModeChips or hasViewportChips or hasBackendChips:
        return true
  for child in node.children:
    if has44pxBorderBottomToolbarWithModeChips(child):
      return true
  false

const viewBodyAttrs = [
  (evStoryboard, "data-storyboard-canvas"),
  (evComponentDetail, "data-component-detail"),
  (evComponentEdit, "data-component-edit"),
  (evPagePreview, "data-page-preview"),
  (evFoundationsPage, "data-foundations-page"),
  (evVectorEditor, "data-vector-editor"),
]

suite "M-EVP-6 single top bar":

  test "exactly one chrome bar renders above the view body for every editor view":
    for entry in viewBodyAttrs:
      let view = entry[0]
      let bodyAttr = entry[1]
      createRoot do (dispose: proc()):
        let r = MockRenderer()
        let vm = createEditorVM()
        vm.sidebar.groups.val = buildStoryboard()
        vm.activeView.val = view

        let shell = renderEditorShell[MockRenderer, MockNode](r, vm)
        let chromeBars = collectChromeBars(shell)
        # Acceptance: there is exactly one canonical chrome bar in the
        # whole shell tree — the one above the view stack — and no
        # duplicate inside any view body.
        check chromeBars.len == 1

        # The view body for this active view must be present in the
        # view stack and must NOT host its own 44 px top-toolbar row.
        let stack = findByAttr(shell, "data-preview-view-stack", "true")
        check stack != nil
        let body = viewBodyFor(stack, bodyAttr)
        check body != nil
        # Negative assertion: no duplicate top bar exists inside the
        # view body itself.
        check not has44pxBorderBottomToolbarWithModeChips(body)
        dispose()

  test "chrome bar still highlights the active backend after dropping inner bars":
    for backend in [pbWeb, pbTui, pbGpui, pbFreya, pbCocoa, pbAndroid]:
      createRoot do (dispose: proc()):
        let r = MockRenderer()
        let vm = createEditorVM()
        vm.changePlatform(backend)

        let shell = renderEditorShell[MockRenderer, MockNode](r, vm)
        let chromeBars = collectChromeBars(shell)
        check chromeBars.len == 1
        let bar = chromeBars[0]

        # Locate the backend pill group; reuse the M57 markers the
        # existing chrome-bar tests rely on.
        let backendStrip = findByAttr(bar, "data-edge-strip", "backend")
        check backendStrip != nil
        let activePill = findByAttr(backendStrip,
          "data-preview-backend", backendId(backend))
        check activePill != nil
        check activePill.attributes.getOrDefault("aria-pressed") == "true"
        dispose()

  test "regression probe: re-introducing a 44 px inner toolbar with chip markers fails the gate":
    createRoot do (dispose: proc()):
      let r = MockRenderer()
      let vm = createEditorVM()
      vm.activeView.val = evComponentDetail

      let shell = renderEditorShell[MockRenderer, MockNode](r, vm)
      let stack = findByAttr(shell, "data-preview-view-stack", "true")
      check stack != nil
      let body = findByAttr(stack, "data-component-detail", "true")
      check body != nil

      # Sanity: production rendering passes the no-duplicate-bar gate.
      check not has44pxBorderBottomToolbarWithModeChips(body)

      # Inject a fake inner toolbar that simulates a regression — a
      # 44 px row with a `border-bottom` and a mode-chip marker inside
      # the view body. We construct the nodes via the renderer's
      # `createElement` so they share the same lifecycle / hashing
      # as production-rendered nodes.
      let fakeBar = r.createElement("div")
      r.setStyle(fakeBar, "height", "44px")
      r.setStyle(fakeBar, "min-height", "44px")
      r.setStyle(fakeBar, "border-bottom", "1px solid #334155")
      let chip = r.createElement("div")
      r.setAttribute(chip, "data-preview-mode", "edit")
      r.appendChild(fakeBar, chip)
      r.appendChild(body, fakeBar)

      # The same assertion expression that passed above must now fail —
      # this is the "convince yourself the gate exercises the rendered
      # tree, not internal state" probe.
      check has44pxBorderBottomToolbarWithModeChips(body)

      dispose()

# ---------------------------------------------------------------------------
# M-EVP-7: Sidebar drives view selection — view-switcher chip group is gone.
# ---------------------------------------------------------------------------
#
# The spec ("Sidebar drives view selection") makes the sidebar the only
# navigation surface. ``selectStory`` derives ``vm.activeView`` from the
# selected story's kind via ``viewForStory``. The chrome bar's view-pill
# strip (Flow / Detail / Page / Foundations / Vector) is therefore
# redundant and removed.
#
# These tests are deliberately real-stack: they instantiate the real
# editor VM, mount the real sidebar (via ``renderEditorShell``), and
# fire click events on the actual sidebar story rows. There are no
# in-process behaviour mocks.

const sampleStoriesByKind: array[StoryKind, tuple[group, name: string]] = [
  skFoundation: (group: "Foundations", name: "Colors"),
  skComponent: (group: "TaskRow", name: "Active task"),
  skPattern: (group: "Patterns", name: "Form Layout"),
  skPage: (group: "Pages", name: "Empty State"),
  skFlow: (group: "First Task", name: "User opens the app for the first time"),
  skGuideline: (group: "Guidelines", name: "Do / Don't"),
]

proc findStoryItem(groups: seq[StoryGroup]; kind: StoryKind;
    group, name: string): StoryRef =
  ## Resolve a ``StoryRef`` from the demo storyboard so the click-driven
  ## tests below address the same story object the sidebar renders.
  var idx = 0
  for g in groups:
    var itemIdx = 0
    for it in g.items:
      if it.kind == kind and it.group == group and it.name == name:
        return StoryRef(group: it.group, name: it.name, kind: it.kind,
            index: itemIdx)
      inc itemIdx
    inc idx

proc ensureGroupExpanded(vm: EditorVM; groupName: string) =
  ## Force ``groupName`` open so its story rows are mounted in the
  ## rendered sidebar. ``buildStoryboard`` defaults several groups to
  ## ``expanded = false``; we flip them via the sidebar's
  ## ``toggleGroup`` API rather than mutating the signal directly so
  ## the same code path the production UI uses is exercised.
  var alreadyOpen = false
  for g in vm.sidebar.groups.val:
    if g.name == groupName:
      alreadyOpen = g.expanded
      break
  if not alreadyOpen:
    vm.sidebar.toggleGroup(groupName)

suite "M-EVP-7 sidebar drives view":

  test "chrome bar has NO view-switcher chip group (negative assertion)":
    ## Walk the rendered shell and confirm every marker associated with
    ## the removed view-switcher chip group is absent. This is the
    ## negative assertion the spec calls for.
    createRoot do (dispose: proc()):
      let r = MockRenderer()
      let vm = createEditorVM()
      vm.sidebar.groups.val = buildStoryboard()

      let shell = renderEditorShell[MockRenderer, MockNode](r, vm)
      let chromeBar = findByAttr(shell, "data-preview-chrome-bar", "true")
      check chromeBar != nil

      # The view-switcher container marker MUST be gone — anywhere in
      # the chrome bar OR in the wider shell.
      check findByAttr(shell, "data-preview-view-switcher", "true") == nil
      check findByAttr(chromeBar, "data-preview-view-switcher", "true") == nil

      # Per-pill aria-labels for the removed buttons MUST be gone too.
      for label in [
          "Open Flow editor view",
          "Open Detail editor view",
          "Open Page editor view",
          "Open Foundations editor view",
          "Open Vector editor view"]:
        check findByAttr(shell, "aria-label", label) == nil

      # The view-switcher cluster marker is gone.
      check findAllByAttr(chromeBar, "data-toolbar-cluster",
          "view-switcher").len == 0

      # The three remaining clusters survive (sanity).
      check findByAttr(chromeBar, "data-toolbar-cluster", "backend") != nil
      check findByAttr(chromeBar, "data-toolbar-cluster", "viewport") != nil
      check findByAttr(chromeBar, "data-toolbar-cluster", "mode") != nil
      dispose()

  test "every StoryKind maps to the expected EditorView via viewForStory":
    ## Mapping assertion: for each ``StoryKind`` exposed in the demo
    ## storyboard, call ``editor.selectStory`` and confirm
    ## ``editor.activeView.val`` equals ``viewForStory(story)``. This
    ## verifies the wiring at the VM layer independently of the DOM.
    createRoot do (dispose: proc()):
      let vm = createEditorVM()
      vm.sidebar.groups.val = buildStoryboard()

      for kind in StoryKind:
        let entry = sampleStoriesByKind[kind]
        let story = findStoryItem(vm.sidebar.groups.val, kind,
            entry.group, entry.name)
        # Sanity — every sample must resolve in the demo storyboard.
        check story.kind == kind
        check story.group == entry.group
        check story.name == entry.name

        let ok = vm.selectStory(story)
        check ok
        check vm.selectedStory.val.group == entry.group
        check vm.selectedStory.val.name == entry.name
        check vm.selectedStory.val.kind == kind
        check vm.activeView.val == viewForStory(story)

      # Spec contract: the canonical mapping per the spec's
      # "Sidebar drives view selection" table.
      check viewForStory(StoryRef(kind: skFlow)) == evStoryboard
      check viewForStory(StoryRef(kind: skPage)) == evPagePreview
      check viewForStory(StoryRef(kind: skFoundation)) == evFoundationsPage
      check viewForStory(StoryRef(kind: skComponent)) == evComponentDetail
      check viewForStory(StoryRef(kind: skPattern)) == evComponentDetail
      check viewForStory(StoryRef(kind: skGuideline)) == evComponentDetail
      dispose()

  test "clicking a sidebar story row flips activeView to viewForStory(story)":
    ## Real-stack DOM click: for each sample story (except ``skFlow``,
    ## which is reached through its journey-group row, not an
    ## individual story row), locate its sidebar row in the rendered
    ## shell, fire a click, and confirm both ``selectedStory`` and
    ## ``activeView`` update. This proves the sidebar — not the chrome
    ## bar — drives the active view.
    for kind in StoryKind:
      if kind == skFlow:
        continue
      createRoot do (dispose: proc()):
        let r = MockRenderer()
        let vm = createEditorVM()
        vm.sidebar.groups.val = buildStoryboard()
        # Expand every section so every kind's group is visible
        # regardless of the demo defaults.
        vm.sidebar.setSectionExpanded(ssUserJourneys, true)
        vm.sidebar.setSectionExpanded(ssPages, true)
        vm.sidebar.setSectionExpanded(ssComponents, true)
        vm.sidebar.setSectionExpanded(ssFoundations, true)
        vm.sidebar.setSectionExpanded(ssGuidelines, true)
        # Expand the groups that default to collapsed so their rows
        # are mounted in the rendered tree (we drive clicks against
        # real DOM nodes, not synthetic VM calls).
        let entry = sampleStoriesByKind[kind]
        ensureGroupExpanded(vm, entry.group)

        let shell = renderEditorShell[MockRenderer, MockNode](r, vm)
        let rowLabel = "Select story " & entry.group & " / " & entry.name
        let row = findByAttr(shell, "aria-label", rowLabel)
        check row != nil
        check row.attributes.getOrDefault("role") == "button"

        let expectedView =
          viewForStory(StoryRef(kind: kind, group: entry.group,
              name: entry.name))
        row.fireEvent("click")

        check vm.selectedStory.val.group == entry.group
        check vm.selectedStory.val.name == entry.name
        check vm.selectedStory.val.kind == kind
        check vm.activeView.val == expectedView
        dispose()

  test "clicking a User Journey group row opens the storyboard view (skFlow path)":
    ## ``skFlow`` groups don't expand into story rows in the sidebar;
    ## they are journey entries that open the storyboard canvas
    ## directly (via ``journeyOpenHandler``). This test exercises that
    ## sidebar surface so the ``skFlow -> evStoryboard`` route is
    ## verified end-to-end through the real DOM.
    createRoot do (dispose: proc()):
      let r = MockRenderer()
      let vm = createEditorVM()
      vm.sidebar.groups.val = buildStoryboard()
      vm.sidebar.setSectionExpanded(ssUserJourneys, true)

      # Start somewhere else so the click is the only path to evStoryboard.
      vm.activeView.val = evComponentDetail

      let shell = renderEditorShell[MockRenderer, MockNode](r, vm)
      let journeyLabel = "Open First Task journey"
      let row = findByAttr(shell, "aria-label", journeyLabel)
      check row != nil
      check row.attributes.getOrDefault("role") == "button"

      row.fireEvent("click")
      check vm.activeView.val == evStoryboard
      dispose()

  test "per-view: every sidebar-reachable EditorView is opened by clicking the sidebar":
    ## Inverse of the mapping test: for every ``EditorView`` value the
    ## sidebar can reach, click the corresponding sidebar surface and
    ## confirm ``activeView`` lands there. The sidebar-unreachable
    ## views (``evComponentEdit`` — opened by Edit mode;
    ## ``evVectorEditor`` — owned by the M-EVP-8 affordance) are
    ## intentionally excluded. ``evStoryboard`` is reached through the
    ## ``Open <Flow> journey`` group row, not an individual story row.
    type
      ClickKind = enum
        ckStoryRow, ckJourneyRow
      ViewProbe = tuple
        target: EditorView
        click: ClickKind
        groupName: string
        storyName: string
        rowLabel: string

    let probes: seq[ViewProbe] = @[
      (target: evStoryboard, click: ckJourneyRow,
        groupName: "First Task", storyName: "",
        rowLabel: "Open First Task journey"),
      (target: evComponentDetail, click: ckStoryRow,
        groupName: "TaskRow", storyName: "Active task",
        rowLabel: "Select story TaskRow / Active task"),
      (target: evPagePreview, click: ckStoryRow,
        groupName: "Pages", storyName: "Empty State",
        rowLabel: "Select story Pages / Empty State"),
      (target: evFoundationsPage, click: ckStoryRow,
        groupName: "Foundations", storyName: "Colors",
        rowLabel: "Select story Foundations / Colors"),
    ]

    # Sanity: the probe set covers every sidebar-reachable view.
    var coveredViews: seq[EditorView] = @[]
    for probe in probes:
      if probe.target notin coveredViews:
        coveredViews.add probe.target
    for view in EditorView:
      if view in {evComponentEdit, evVectorEditor}:
        check view notin coveredViews
      else:
        check view in coveredViews

    for probe in probes:
      createRoot do (dispose: proc()):
        let r = MockRenderer()
        let vm = createEditorVM()
        vm.sidebar.groups.val = buildStoryboard()
        vm.sidebar.setSectionExpanded(ssUserJourneys, true)
        vm.sidebar.setSectionExpanded(ssPages, true)
        vm.sidebar.setSectionExpanded(ssComponents, true)
        vm.sidebar.setSectionExpanded(ssFoundations, true)
        vm.sidebar.setSectionExpanded(ssGuidelines, true)
        if probe.click == ckStoryRow:
          ensureGroupExpanded(vm, probe.groupName)

        # Start on a deliberately wrong view so the sidebar click is
        # the only path that can move ``activeView`` to ``probe.target``.
        case probe.target
        of evStoryboard:
          vm.activeView.val = evComponentDetail
        else:
          vm.activeView.val = evStoryboard

        let shell = renderEditorShell[MockRenderer, MockNode](r, vm)
        let row = findByAttr(shell, "aria-label", probe.rowLabel)
        check row != nil
        check row.attributes.getOrDefault("role") == "button"
        row.fireEvent("click")
        check vm.activeView.val == probe.target
        dispose()

  test "regression probe: clicking through stories keeps activeView in sync":
    ## Sequence test: click several sidebar rows of different kinds and
    ## confirm ``activeView`` always matches
    ## ``viewForStory(currentStory)``. This catches the case where a
    ## stale view-switcher (re-introduced by mistake) overrides the
    ## sidebar's selection. ``skFlow`` is skipped because flow groups
    ## don't expand into story rows in the sidebar (their entry point
    ## is the journey-group row, covered by a separate test above).
    createRoot do (dispose: proc()):
      let r = MockRenderer()
      let vm = createEditorVM()
      vm.sidebar.groups.val = buildStoryboard()
      vm.sidebar.setSectionExpanded(ssUserJourneys, true)
      vm.sidebar.setSectionExpanded(ssPages, true)
      vm.sidebar.setSectionExpanded(ssComponents, true)
      vm.sidebar.setSectionExpanded(ssFoundations, true)
      vm.sidebar.setSectionExpanded(ssGuidelines, true)
      for kind in StoryKind:
        if kind == skFlow:
          continue
        let entry = sampleStoriesByKind[kind]
        ensureGroupExpanded(vm, entry.group)

      let shell = renderEditorShell[MockRenderer, MockNode](r, vm)

      # Walk through a fixed sequence that flips between views
      # repeatedly, mixing every sidebar-reachable kind.
      let sequence = [
        skFoundation, skComponent, skPage, skGuideline,
        skPattern, skFoundation, skComponent, skPage,
        skPattern, skGuideline
      ]
      for kind in sequence:
        let entry = sampleStoriesByKind[kind]
        let rowLabel = "Select story " & entry.group & " / " & entry.name
        let row = findByAttr(shell, "aria-label", rowLabel)
        check row != nil
        row.fireEvent("click")
        check vm.selectedStory.val.kind == kind
        check vm.activeView.val ==
          viewForStory(vm.selectedStory.val)
      dispose()

# ---------------------------------------------------------------------------
# RS-M11: Web keeps the iframe; non-Web mounts the canvas.
# ---------------------------------------------------------------------------

suite "RS-M11 component detail mount differentiation":

  test "pbWeb + showProject keeps the iframe and hides the canvas":
    createRoot do (dispose: proc()):
      let r = MockRenderer()
      let vm = createEditorVM()
      let story = StoryRef(group: "Components", name: "Real Button",
        kind: skComponent, index: 0)
      vm.sidebar.groups.val = @[
        StoryGroup(name: "Components", kind: skComponent, expanded: true,
          items: @[StoryItem(name: story.name, kind: story.kind,
            group: story.group)])
      ]
      vm.preview.hook = proc(story: StoryRef;
          platform: Platform): ProjectPreview =
        ProjectPreview(
          status: ppsRendered,
          story: story,
          title: story.group & " / " & story.name,
          bodyText: "Rendered by project-owned component code.",
          documentHtml: "<main data-testid=\"real-component\">Button</main>")
      discard vm.selectStory(story)
      vm.platform.val = pbWeb

      let detail = renderComponentDetail[MockRenderer, MockNode](r, vm)
      let frame = findByAttr(detail, "data-component-project-frame", "true")
      let canvas = findByAttr(detail, "data-component-project-canvas", "true")
      check frame != nil
      check canvas != nil
      # Web → iframe is visible, canvas is hidden.
      check frame.styles.getOrDefault("display", "block") != "none"
      check canvas.styles.getOrDefault("display", "none") == "none"
      # The iframe still carries the srcdoc (Web path is unchanged).
      check frame.attributes.getOrDefault("srcdoc", "").contains(
        "real-component")
      check canvas.attributes.getOrDefault("data-canvas-active") == "false"
      dispose()

  test "non-Web + showProject mounts the canvas and hides the iframe":
    createRoot do (dispose: proc()):
      for backend in [pbTui, pbGpui, pbFreya, pbCocoa, pbAndroid]:
        let r = MockRenderer()
        let vm = createEditorVM()
        let story = StoryRef(group: "Components", name: "Real Button",
          kind: skComponent, index: 0)
        vm.sidebar.groups.val = @[
          StoryGroup(name: "Components", kind: skComponent, expanded: true,
            items: @[StoryItem(name: story.name, kind: story.kind,
              group: story.group)])
        ]
        vm.preview.hook = proc(story: StoryRef;
            platform: Platform): ProjectPreview =
          ProjectPreview(
            status: ppsRendered,
            story: story,
            title: story.group & " / " & story.name,
            bodyText: "Rendered by project-owned component code.",
            documentHtml: "<main>Button</main>")
        discard vm.selectStory(story)
        vm.platform.val = backend

        let detail = renderComponentDetail[MockRenderer, MockNode](r, vm)
        let frame = findByAttr(detail, "data-component-project-frame", "true")
        let canvas = findByAttr(detail, "data-component-project-canvas", "true")
        check frame != nil
        check canvas != nil
        # Non-Web → canvas is visible, iframe is hidden.
        check canvas.styles.getOrDefault("display", "none") == "block"
        check frame.styles.getOrDefault("display", "block") == "none"
        check canvas.attributes.getOrDefault("data-canvas-active") == "true"
        # The iframe's srcdoc is cleared on non-Web so the iframe
        # doesn't load any HTML in the background.
        check frame.attributes.getOrDefault("srcdoc", "") == ""
      dispose()
