## CHRM follow-up — ``gmFullScreen`` must actually render something,
## and ESC must leave it.
##
## What was broken
## ---------------
##
## ``gmFullScreen`` is reachable two ways from the shipped UI: the
## toolbar's "Full screen" mode chip, and shift-clicking any gallery
## tile (``openFullScreen``).  It had no view.  The mode-mirror effect
## hid ``bodyWrap`` / ``gridHost`` (grid only), ``fullTabHost``
## (full-tab only) and ``compareHost`` (compare only), and no
## ``fullScreenHost`` existed — so entering the mode blanked the
## overlay body.  Worse, a separate effect cleared
## ``fullTabCaptureId`` on every mode that was not ``gmFullTab``, so
## the capture the user shift-clicked was discarded on the way in.
##
## ``restoreMode`` is documented as the ESC handler but nothing bound
## it: there was no ``Escape`` binding anywhere in ``src/``, so the
## blank state was also a trap.
##
## The existing coverage could not see any of this.
## ``test_design_review_gallery_vm`` asserts only that
## ``openFullScreen`` writes the mode signal, and
## ``e2e_design_review_gallery_overlay.mjs`` drives a hand-written
## harness page that re-implements full-screen (its own CSS rule, its
## own ``keydown`` listener) rather than the production DSL output.
##
## These tests mount the production overlay under the MockRenderer and
## assert on the nodes it actually emits.

import std/[unittest, options, tables]

import isonim/core/[signals, computation, owner]
import isonim/testing/mock_dom
import isonim/editor/views/gallery_overlay

proc findByAttr(node: MockNode; key, value: string): MockNode =
  if node == nil: return nil
  if node.attributes.getOrDefault(key) == value:
    return node
  for child in node.children:
    let hit = findByAttr(child, key, value)
    if hit != nil: return hit
  nil

proc mkTile(captureId, previewId: string): GalleryTile =
  GalleryTile(
    captureId: captureId,
    runId: "run-" & captureId,
    previewId: previewId,
    status: "complete",
    pngUrl: "/api/design-review/get-capture-png?id=" & captureId,
    width: 320, height: 568)

suite "gallery full-screen mode":

  test "test_full_screen_renders_the_focused_capture":
    ## Shift-clicking a tile enters ``gmFullScreen``.  The overlay must
    ## show that capture — not an empty body.
    createRoot do (dispose: proc()):
      let vm = createGalleryVM("render.task-app")
      vm.tiles.val = @[
        mkTile("cap-a", "p/render.task-app#0@web"),
        mkTile("cap-b", "p/render.task-app#0@web")]
      let r = MockRenderer()
      let parent = createElement(r, "div")
      mountGalleryOverlay[MockRenderer, MockNode](r, parent, vm)
      let root = parent.children[0]

      let tile = findByAttr(root, "data-design-review-gallery-tile", "cap-b")
      check tile != nil
      fireEvent(tile, "shift-click")
      check vm.mode.val == gmFullScreen
      check root.attributes.getOrDefault("data-gallery-mode") == "full-screen"

      # The focused capture must survive the mode switch.
      check vm.fullTabCaptureId.val.isSome
      check vm.fullTabCaptureId.val.get == "cap-b"

      # SOMETHING must be visible.  Every body host being hidden is
      # exactly the blank-overlay bug.
      let visibleBody = findByAttr(root, "data-gallery-visible", "true")
      check visibleBody != nil

      # And it must be the capture the user asked for.
      let img = findByAttr(root, "data-design-review-gallery-fulltab-img",
                           "true")
      check img != nil
      check img.attributes.getOrDefault("src") ==
        "/api/design-review/get-capture-png?id=cap-b"

      # The root advertises the whole-editor promotion so the editor
      # CSS (and any wrapper) can lift the overlay out of the centre
      # column.
      check root.attributes.getOrDefault(
        "data-design-review-gallery-fullscreen") == "true"
      dispose()

  test "test_full_screen_mode_chip_renders_a_body_too":
    ## The toolbar chip is the other door into the same state.
    createRoot do (dispose: proc()):
      let vm = createGalleryVM("render.task-app")
      vm.tiles.val = @[mkTile("cap-a", "p/render.task-app#0@web")]
      let r = MockRenderer()
      let parent = createElement(r, "div")
      mountGalleryOverlay[MockRenderer, MockNode](r, parent, vm)
      let root = parent.children[0]
      # Open a capture first (plain click → full-tab), then promote to
      # full screen via the chip, mirroring a real user's path.
      let tile = findByAttr(root, "data-design-review-gallery-tile", "cap-a")
      check tile != nil
      fireEvent(tile, "click")
      check vm.mode.val == gmFullTab

      vm.mode.val = gmFullScreen
      check findByAttr(root, "data-gallery-visible", "true") != nil
      check findByAttr(root, "data-design-review-gallery-fulltab-img",
                       "true") != nil
      dispose()

  test "test_escape_leaves_full_screen":
    ## ESC is the documented way out of full screen. ``restoreMode``
    ## existed but was called only from a unit test — the overlay bound
    ## no key handler at all, so a user who shift-clicked was stuck
    ## with the toolbar chips as the only exit.
    ##
    ## The binding follows ``shell.nim``'s ``data-shell-escape-key``
    ## idiom: a zero-size node with a no-arg ``keydown`` handler plus a
    ## JS document listener that filters ``event.key === 'Escape'``.
    ## The key filter lives in the JS shim (a generic ``R``/``E`` mount
    ## cannot name the backend's event type), so the native test drives
    ## the node the shim targets.
    createRoot do (dispose: proc()):
      let vm = createGalleryVM("render.task-app")
      vm.tiles.val = @[mkTile("cap-a", "p/render.task-app#0@web")]
      let r = MockRenderer()
      let parent = createElement(r, "div")
      mountGalleryOverlay[MockRenderer, MockNode](r, parent, vm)
      let root = parent.children[0]

      let escNode = findByAttr(
        root, "data-design-review-gallery-escape-key", "true")
      check escNode != nil

      let tile = findByAttr(root, "data-design-review-gallery-tile", "cap-a")
      fireEvent(tile, "shift-click")
      check vm.mode.val == gmFullScreen

      fireEvent(escNode, "keydown")
      check vm.mode.val == gmGrid
      check root.attributes.getOrDefault(
        "data-design-review-gallery-fullscreen") == "false"
      dispose()

  test "test_escape_leaves_full_tab_and_compare_too":
    ## Same handler, same contract for the other non-grid modes.
    createRoot do (dispose: proc()):
      let vm = createGalleryVM("render.task-app")
      vm.tiles.val = @[
        mkTile("cap-a", "p/render.task-app#0@web"),
        mkTile("cap-b", "p/render.task-app#0@web")]
      let r = MockRenderer()
      let parent = createElement(r, "div")
      mountGalleryOverlay[MockRenderer, MockNode](r, parent, vm)
      let root = parent.children[0]
      let escNode = findByAttr(
        root, "data-design-review-gallery-escape-key", "true")
      check escNode != nil

      vm.openFullTab("cap-a")
      check vm.mode.val == gmFullTab
      fireEvent(escNode, "keydown")
      check vm.mode.val == gmGrid

      vm.multiSelect("cap-a")
      vm.multiSelect("cap-b")
      vm.compareSideBySide()
      check vm.mode.val == gmCompare
      fireEvent(escNode, "keydown")
      check vm.mode.val == gmGrid
      dispose()

  test "test_escape_always_reaches_the_grid":
    ## ``restoreMode`` alone can be a no-op: the toolbar's ``setMode``
    ## records ``priorMode``, so full-tab → full-screen leaves
    ## ``priorMode == gmFullTab``.  One ESC restores full-tab; a second
    ## must not sit on full-tab forever.  ESC is never allowed to be a
    ## no-op while a non-grid mode is on screen.
    createRoot do (dispose: proc()):
      let vm = createGalleryVM("render.task-app")
      vm.tiles.val = @[mkTile("cap-a", "p/render.task-app#0@web")]
      let r = MockRenderer()
      let parent = createElement(r, "div")
      mountGalleryOverlay[MockRenderer, MockNode](r, parent, vm)
      let root = parent.children[0]
      let escNode = findByAttr(
        root, "data-design-review-gallery-escape-key", "true")

      vm.openFullTab("cap-a")
      vm.priorMode.val = gmFullTab
      vm.mode.val = gmFullScreen
      fireEvent(escNode, "keydown")
      check vm.mode.val == gmFullTab
      fireEvent(escNode, "keydown")
      check vm.mode.val == gmGrid
      # Idempotent once the grid is showing.
      fireEvent(escNode, "keydown")
      check vm.mode.val == gmGrid
      dispose()
