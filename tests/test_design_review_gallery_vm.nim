## REV-M7 — ViewModel-level tests for the gallery overlay.
##
## All state-machine assertions go through ``GalleryVM`` directly with
## hand-built ``GalleryTile`` lists so we don't have to spin up Postgres
## just to verify the mode transitions.  The view itself is also
## mounted under a ``MockRenderer`` to exercise the DOM construction
## path and confirm the ui DSL output is well-formed.

import std/[unittest, options, tables, sets]
import isonim/core/[signals, computation, owner]
import isonim/testing/mock_dom
import isonim/editor/views/gallery_overlay

proc mkTile(captureId, runId, previewId, status: string;
            score: Option[float] = none[float](); width = 200;
            height = 200): GalleryTile =
  GalleryTile(
    captureId: captureId,
    runId: runId,
    previewId: previewId,
    score: score,
    status: status,
    pngUrl: "/api/design-review/get-capture-png?id=" & captureId,
    width: width,
    height: height,
  )

suite "REV-M7 gallery VM":

  test "test_gallery_vm_default_layout_groups_by_preview":
    createRoot do (dispose: proc()):
      let vm = createGalleryVM("render.x")
      # 12 tiles spread across 3 previews, most-recent-first within
      # each preview (caller-controlled order via input list).
      var tiles: seq[GalleryTile] = @[]
      let previews = @["p/a:page#0@web", "p/b:page#0@web", "p/c:page#0@web"]
      var captureIdx = 0
      for p in previews:
        for j in 0 ..< 4:
          inc captureIdx
          tiles.add mkTile("cap" & $captureIdx, "run" & $captureIdx,
                           p, "complete")
      vm.tiles.val = tiles
      let rows = vm.rows.val
      check rows.len == 3
      check rows[0].previewId == "p/a:page#0@web"
      check rows[1].previewId == "p/b:page#0@web"
      check rows[2].previewId == "p/c:page#0@web"
      check rows[0].tiles.len == 4
      check rows[1].tiles.len == 4
      check rows[2].tiles.len == 4
      # The first tile in each bucket is the first item in the
      # caller-supplied list — "most recent" is whatever the caller
      # streamed in first (the API endpoint already sorts DESC).
      check rows[0].tiles[0].captureId == "cap1"
      check rows[1].tiles[0].captureId == "cap5"
      check rows[2].tiles[0].captureId == "cap9"
      dispose()

  test "test_gallery_vm_full_tab_mode_replaces_preview_pane":
    createRoot do (dispose: proc()):
      let vm = createGalleryVM("render.x")
      vm.tiles.val = @[
        mkTile("capA", "runA", "p/a:page#0@web", "complete"),
        mkTile("capB", "runB", "p/a:page#0@web", "complete"),
      ]
      check vm.mode.val == gmGrid
      check vm.fullTabCaptureId.val.isNone
      vm.openFullTab("capA")
      check vm.mode.val == gmFullTab
      check vm.fullTabCaptureId.val.isSome
      check vm.fullTabCaptureId.val.get == "capA"
      # Switching the mode back to gmGrid clears the captureId.
      vm.mode.val = gmGrid
      check vm.fullTabCaptureId.val.isNone
      dispose()

  test "test_gallery_vm_full_screen_mode_overlays_editor":
    createRoot do (dispose: proc()):
      let vm = createGalleryVM("render.x")
      vm.tiles.val = @[
        mkTile("capA", "runA", "p/a:page#0@web", "complete"),
      ]
      check vm.mode.val == gmGrid
      vm.openFullScreen("capA")
      check vm.mode.val == gmFullScreen
      check vm.priorMode.val == gmGrid
      # Restore goes back to the priorMode signal we recorded at the
      # mode-transition site.
      vm.restoreMode()
      check vm.mode.val == gmGrid
      dispose()

  test "test_gallery_vm_select_toggle":
    createRoot do (dispose: proc()):
      let vm = createGalleryVM("render.x")
      vm.tiles.val = @[
        mkTile("capA", "runA", "p", "complete"),
        mkTile("capB", "runB", "p", "complete"),
      ]
      vm.toggleSelect("capA")
      check "capA" in vm.selectedTileIds.val
      check "capB" notin vm.selectedTileIds.val
      vm.toggleSelect("capB")
      check vm.selectedTileIds.val.len == 2
      vm.toggleSelect("capA")
      check "capA" notin vm.selectedTileIds.val
      dispose()

  test "test_gallery_vm_drag_records_pending_layout_but_does_not_save":
    createRoot do (dispose: proc()):
      let vm = createGalleryVM("render.x")
      vm.tiles.val = @[
        mkTile("capA", "runA", "p", "complete"),
      ]
      check vm.pendingLayout.val.len == 0
      check vm.isDirty.val == false
      vm.registerDragMove("capA", 2, 1)
      check vm.pendingLayout.val.len == 1
      check vm.pendingLayout.val[0].captureId == "capA"
      check vm.pendingLayout.val[0].rowIndex == 2
      check vm.pendingLayout.val[0].columnIndex == 1
      check vm.isDirty.val == true
      # Re-dragging the same tile updates in place.
      vm.registerDragMove("capA", 3, 0)
      check vm.pendingLayout.val.len == 1
      check vm.pendingLayout.val[0].rowIndex == 3
      check vm.pendingLayout.val[0].columnIndex == 0
      dispose()

  test "test_gallery_view_mounts_under_mock_renderer":
    createRoot do (dispose: proc()):
      let vm = createGalleryVM("render.x")
      vm.tiles.val = @[
        mkTile("capA", "runA", "p/a:page#0@web", "complete",
               score = some(0.85), width = 1080, height = 2340),
        mkTile("capB", "runB", "p/a:page#0@web", "failed",
               width = 1080, height = 2340),
      ]
      let r = MockRenderer()
      let parent = createElement(r, "div")
      mountGalleryOverlay[MockRenderer, MockNode](r, parent, vm)
      check parent.children.len == 1
      let root = parent.children[0]
      check root.attributes.getOrDefault(
        "data-design-review-gallery-overlay") == "true"
      check root.attributes.getOrDefault("data-gallery-mode") == "grid"
      dispose()
