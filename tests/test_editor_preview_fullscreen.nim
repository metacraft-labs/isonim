## PSZ-M2 (Preview-Sizing-And-Zoom): full-screen preview of the web page preview.
##
## Mocks, and why each is here:
## - ``MockRenderer`` / ``MockNode`` (isonim/testing/mock_dom) stand in for the
##   DOM only, as in test_editor_preview_zoom.nim. The shell is rendered and the
##   tests read back the attributes and inline styles the views set (``display``,
##   ``opacity``, ``pointer-events``, ``data-*``). Nothing else is faked.
## - No CSS and no layout engine run. "Hidden" here means the view set
##   ``display: none`` on the node (or removed it from the tree). The browser
##   checks that the editor really draws that way: e2e_preview_fullscreen_live.mjs.
## - The pointer is not simulated through DOM events. The JS listener in the shell
##   calls ``revealPreviewControlsAt`` with the pointer position inside the centre
##   column, and the tests call that same entry point with positions.
## - ``EditorVM``, its signals, the full-screen procs and the click handlers on
##   the rendered controls are all real. The tests click the rendered buttons and
##   read the view model back.
## - The Escape key and the F key are handled in the browser (browser.nim); they
##   are not reachable from here and are covered by the e2e test. The binding
##   constant and the URL codec are native and are tested below.
import std/[strutils, tables, unittest]
import isonim/core/[signals, computation, owner]
import isonim/testing/mock_dom
import isonim/editor/[viewmodels, types, preview_zoom, preview_fullscreen]
import isonim/editor/views/shell

proc findByAttr(node: MockNode; name, value: string): MockNode =
  if node.kind == mnkElement and node.attributes.hasKey(name) and
      node.attributes[name] == value:
    return node
  for child in node.children:
    let found = findByAttr(child, name, value)
    if found != nil:
      return found

proc countByAttr(node: MockNode; name, value: string): int =
  if node.kind == mnkElement and node.attributes.hasKey(name) and
      node.attributes[name] == value:
    result = 1
  for child in node.children:
    result += countByAttr(child, name, value)

proc hasClass(node: MockNode; cls: string): bool =
  if node.kind == mnkElement and node.attributes.hasKey("class"):
    for part in node.attributes["class"].split(' '):
      if part == cls:
        return true
  for child in node.children:
    if hasClass(child, cls):
      return true

proc findByClass(node: MockNode; cls: string): MockNode =
  if node.kind == mnkElement and node.attributes.hasKey("class"):
    for part in node.attributes["class"].split(' '):
      if part == cls:
        return node
  for child in node.children:
    let found = findByClass(child, cls)
    if found != nil:
      return found

proc pageVm(): EditorVM =
  ## A web page preview at Desktop size with a story selected, the state the
  ## reviewer is in before going full screen.
  result = createEditorVM()
  result.changeViewport(makeBuiltinViewport(pvkDesktop))
  result.setPreviewArea(1000, 700)
  result.activeView.val = evPagePreview
  result.platform.val = pbWeb
  result.selectedStory.val = StoryRef(group: "Components", name: "Sample",
    kind: skPage, index: 0)

suite "Preview full screen (PSZ-M2)":

  test "test_preview_fullscreen_hides_editor_chrome":
    createRoot do (dispose: proc()):
      let vm = pageVm()
      let r = MockRenderer()
      let shell = renderEditorShell[MockRenderer, MockNode](r, vm)
      let sidebar = findByAttr(shell, "data-editor-sidebar", "true")
      let chromeBar = findByAttr(shell, "data-preview-chrome-bar", "true")
      let statusBar = findByClass(shell, "editor-statusbar")
      let host = findByAttr(shell, "data-preview-fullscreen-controls", "true")
      let page = findByAttr(shell, "data-page-preview", "true")
      check sidebar != nil and chromeBar != nil and statusBar != nil
      check host != nil and page != nil

      # Before: the editor chrome is shown and the floating host is not.
      check sidebar.styles["display"] == "flex"
      check chromeBar.styles["display"] == "flex"
      check statusBar.styles["display"] == "flex"
      check host.styles["display"] == "none"
      check findByAttr(shell, "data-test-id", "property-panel") != nil

      vm.setPreviewFullScreen(true)
      check vm.previewFullScreenActive()

      # Full screen: no sidebar, no chrome bar, no status bar, and no right-hand
      # panel in the tree at all (the inspector and the AI panel both carry the
      # property-panel test id, and neither is mounted).
      check sidebar.styles["display"] == "none"
      check chromeBar.styles["display"] == "none"
      check statusBar.styles["display"] == "none"
      check findByAttr(shell, "data-test-id", "property-panel") == nil
      # The preview itself stays, and the floating host shows.
      check page.styles["display"] == "flex"
      check host.styles["display"] == "flex"
      # The zoom cluster is inside the floating host, and only there: its
      # readout is found once, which is what the browser test relies on.
      let cluster = findByAttr(host, "data-preview-zoom-cluster", "true")
      check cluster != nil
      check findByAttr(chromeBar, "data-preview-zoom-cluster", "true") == nil
      check countByAttr(shell, "data-preview-zoom-level", "true") == 1
      # The full-screen toggle is in the chrome bar, which is hidden now.
      check findByAttr(chromeBar, "data-preview-fullscreen-toggle", "true") != nil
      # The floating controls carry the leave control and the browser request.
      check findByAttr(cluster, "aria-label", "Leave full screen") != nil
      check findByAttr(cluster, "aria-label",
        "Request browser full screen") != nil
      # Hidden until the pointer is in the reveal zone: transparent and not
      # clickable, so the preview under the corner stays usable.
      check cluster.styles["opacity"] == "0"
      check cluster.styles["pointer-events"] == "none"

      # Leaving puts the chrome back exactly as it was.
      vm.setPreviewFullScreen(false)
      check not vm.previewFullScreenActive()
      check sidebar.styles["display"] == "flex"
      check chromeBar.styles["display"] == "flex"
      check statusBar.styles["display"] == "flex"
      check host.styles["display"] == "none"
      check findByAttr(chromeBar, "data-preview-zoom-cluster", "true") != nil
      check findByAttr(cluster, "aria-label", "Leave full screen") != nil
      check cluster.styles["box-shadow"] == "none"
      dispose()

  test "test_preview_fullscreen_hides_editor_chrome (reveal corner)":
    createRoot do (dispose: proc()):
      let vm = pageVm()
      let r = MockRenderer()
      let shell = renderEditorShell[MockRenderer, MockNode](r, vm)
      vm.setPreviewFullScreen(true)
      # The cluster moves into the floating host in full screen.
      let host = findByAttr(shell, "data-preview-fullscreen-controls", "true")
      let cluster = findByAttr(host, "data-preview-zoom-cluster", "true")
      check cluster != nil
      # A pointer in the top-right corner zone reveals the cluster.
      vm.revealPreviewControlsAt(990, 10, 1000)
      check vm.previewControlsRevealed.val
      check cluster.styles["opacity"] == "1"
      check cluster.styles["pointer-events"] == "auto"
      # A pointer elsewhere hides it again.
      vm.revealPreviewControlsAt(100, 400, 1000)
      check not vm.previewControlsRevealed.val
      check cluster.styles["opacity"] == "0"
      # Outside full screen the reveal does nothing.
      vm.setPreviewFullScreen(false)
      vm.revealPreviewControlsAt(990, 10, 1000)
      check not vm.previewControlsRevealed.val
      dispose()

  test "test_preview_fullscreen_restores_state":
    createRoot do (dispose: proc()):
      let vm = pageVm()
      vm.setPreviewZoomLevel(0.5)
      let r = MockRenderer()
      let shell = renderEditorShell[MockRenderer, MockNode](r, vm)
      let story = vm.selectedStory.val
      let viewport = vm.viewport.val
      let zoom = vm.previewZoom.val
      let panels = vm.panels.val

      # Enter with the rendered chrome-bar button, as a reviewer does.
      let toggle = findByAttr(shell, "data-preview-fullscreen-toggle", "true")
      check toggle != nil
      check toggle.attributes["aria-label"] == "Full screen preview"
      toggle.fireEvent("click")
      check vm.previewFullScreen.val
      # Entering does not touch the story, the size or the zoom.
      check vm.selectedStory.val.name == story.name
      check vm.viewport.val.kind == viewport.kind
      check vm.previewZoom.val.mode == zoom.mode
      check vm.previewZoom.val.level == zoom.level

      # Leave with the rendered leave control.
      let leave = findByAttr(shell, "aria-label", "Leave full screen")
      check leave != nil
      leave.fireEvent("click")
      check not vm.previewFullScreen.val

      # The same story, viewport, zoom mode and level, and panels.
      check vm.selectedStory.val.group == story.group
      check vm.selectedStory.val.name == story.name
      check vm.selectedStory.val.kind == story.kind
      check vm.selectedStory.val.index == story.index
      check vm.viewport.val.kind == viewport.kind
      check vm.viewport.val.width == viewport.width
      check vm.viewport.val.height == viewport.height
      check vm.previewZoom.val.mode == zoom.mode
      check vm.previewZoom.val.level == zoom.level
      check percentLabel(previewScale(vm.previewZoom.val, 1440, 900,
        vm.previewArea.val)) == "50%"
      check vm.panels.val.sidebar == panels.sidebar
      check vm.panels.val.inspector == panels.inspector
      # And the cluster is back in the chrome bar with its readout at 50%.
      let chromeBar = findByAttr(shell, "data-preview-chrome-bar", "true")
      check findByAttr(chromeBar, "data-preview-zoom-cluster", "true") != nil
      check findByAttr(chromeBar, "data-preview-zoom-level", "true").textContent == "50%"
      dispose()

  test "test_preview_fullscreen_restores_state (zoom fit)":
    createRoot do (dispose: proc()):
      let vm = pageVm()
      vm.setPreviewZoomFit()
      let zoom = vm.previewZoom.val
      vm.setPreviewFullScreen(true)
      # A larger area in full screen refits Fit, and the mode stays Fit.
      vm.setPreviewArea(1600, 1000)
      check vm.previewZoom.val.mode == pzmFit
      vm.setPreviewFullScreen(false)
      check vm.previewZoom.val.mode == zoom.mode
      check vm.previewZoom.val.level == zoom.level
      dispose()

  test "test_preview_fullscreen_ends_with_the_page_view":
    createRoot do (dispose: proc()):
      let vm = pageVm()
      vm.setPreviewFullScreen(true)
      check vm.previewFullScreen.val
      let r = MockRenderer()
      let shell = renderEditorShell[MockRenderer, MockNode](r, vm)
      # Another view stops full screen: the flag is cleared by the shell, so the
      # storyboard's sidebar and chrome come back.
      vm.activeView.val = evStoryboard
      check not vm.previewFullScreen.val
      check not vm.previewFullScreenActive()
      let sidebar = findByAttr(shell, "data-editor-sidebar", "true")
      check sidebar.styles["display"] == "flex"
      # Full screen is refused where it is not offered.
      vm.setPreviewFullScreen(true)
      check not vm.previewFullScreen.val
      # PSZ-M3 (amends M2): the streamed backends offer full screen on the page
      # preview too, so a non-web backend no longer ends it.
      vm.activeView.val = evPagePreview
      vm.setPreviewFullScreen(true)
      check vm.previewFullScreen.val
      vm.platform.val = pbTui
      check vm.previewFullScreen.val
      # Leaving the page preview ends it (a stale flag cannot hide another view).
      vm.activeView.val = evComponentDetail
      check not vm.previewFullScreen.val
      dispose()

  test "test_preview_fullscreen_toggle":
    createRoot do (dispose: proc()):
      let vm = pageVm()
      check not vm.previewFullScreen.val
      vm.togglePreviewFullScreen()
      check vm.previewFullScreen.val
      vm.togglePreviewFullScreen()
      check not vm.previewFullScreen.val
      dispose()

  test "test_preview_fullscreen_url_roundtrip":
    # The key the browser handler reads is the one constant.
    check previewFullScreenKey == "f"
    # Codec: what the story URL carries.
    check previewFullScreenRouteParam(true) == "1"
    check previewFullScreenRouteParam(false) == "0"
    check previewFullScreenFromRouteParam("1", false)
    check previewFullScreenFromRouteParam("true", false)
    check not previewFullScreenFromRouteParam("0", true)
    check not previewFullScreenFromRouteParam(" OFF ", true)
    # A damaged or absent value keeps the screen the reviewer is on.
    check previewFullScreenFromRouteParam("bogus", true)
    check not previewFullScreenFromRouteParam("bogus", false)
    check previewFullScreenFromRouteParam("", true)
    # Every state survives write then read.
    for on in [true, false]:
      check previewFullScreenFromRouteParam(previewFullScreenRouteParam(on),
        not on) == on
    # The VM state the route sync reads and writes, in the page view.
    createRoot do (dispose: proc()):
      let vm = pageVm()
      vm.previewFullScreen.val = previewFullScreenFromRouteParam("1",
        vm.previewFullScreen.val)
      check previewFullScreenRouteParam(vm.previewFullScreen.val) == "1"
      check vm.previewFullScreenActive()
      vm.previewFullScreen.val = previewFullScreenFromRouteParam("0",
        vm.previewFullScreen.val)
      check previewFullScreenRouteParam(vm.previewFullScreen.val) == "0"
      dispose()

  test "test_preview_fullscreen_reveal_zone":
    # The zone is the top-right corner of the area, width x height in CSS px.
    check previewFullScreenRevealWidth == 360
    check previewFullScreenRevealHeight == 120
    check inRevealZone(640, 0, 1000)      # left edge of the zone
    check not inRevealZone(639, 0, 1000)  # one pixel left of it
    check inRevealZone(1000, 0, 1000)     # right edge
    check inRevealZone(700, 119, 1000)    # last row
    check not inRevealZone(700, 120, 1000)
    check not inRevealZone(500, 10, 1000) # the middle of the area
    check not inRevealZone(700, -1, 1000) # above the area
