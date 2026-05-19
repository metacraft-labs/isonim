## REV-M8 — gallery VM drag-rearrange + isDirty tests.
##
## Verifies that ``registerDragMove`` records the user's intent into
## ``pendingLayout`` AND flips ``isDirty`` so REV-M8's save-button
## affordance can light up reactively, AND that ``serializePendingLayout``
## + ``applyLayoutJson`` round-trip the data structure cleanly.

import std/[unittest, options, strutils]

import isonim/core/[signals, owner]
import isonim/editor/views/gallery_overlay

proc mkTile(captureId, previewId: string;
            score: Option[float] = none[float]()): GalleryTile =
  GalleryTile(
    captureId: captureId,
    runId: "run-" & captureId,
    previewId: previewId,
    score: score,
    status: "complete",
    pngUrl: "/api/design-review/get-capture-png?id=" & captureId,
    width: 200, height: 200,
  )

suite "REV-M8 gallery drag-rearrange VM":

  test "test_gallery_vm_drag_rearrange_updates_layout":
    createRoot do (dispose: proc()):
      let vm = createGalleryVM("render.x")
      # 6 tiles across 2 previews → 2 rows of 3.
      var tiles: seq[GalleryTile] = @[]
      for i in 0 ..< 3:
        tiles.add mkTile("a" & $i, "p/a")
      for i in 0 ..< 3:
        tiles.add mkTile("b" & $i, "p/b")
      vm.tiles.val = tiles
      check vm.isDirty.val == false
      check vm.pendingLayout.val.len == 0
      # Drag a0 from (row 0, col 0) → (row 2, col 1).
      vm.registerDragMove("a0", 2, 1)
      check vm.isDirty.val == true
      check vm.pendingLayout.val.len == 1
      check vm.pendingLayout.val[0].captureId == "a0"
      check vm.pendingLayout.val[0].rowIndex == 2
      check vm.pendingLayout.val[0].columnIndex == 1
      # Subsequent drag of the same tile replaces, doesn't duplicate.
      vm.registerDragMove("a0", 1, 2)
      check vm.pendingLayout.val.len == 1
      check vm.pendingLayout.val[0].rowIndex == 1
      # Different tile appends.
      vm.registerDragMove("b2", 0, 0)
      check vm.pendingLayout.val.len == 2
      dispose()

  test "test_gallery_vm_pending_layout_roundtrips_through_json":
    createRoot do (dispose: proc()):
      let vm = createGalleryVM("render.x")
      vm.registerDragMove("cap-1", 0, 2)
      vm.registerDragMove("cap-2", 1, 0)
      vm.registerDragMove("cap-3", 2, 1)
      let serialized = serializePendingLayout(vm)
      check serialized.contains("\"captureId\":\"cap-1\"")
      check serialized.contains("\"row\":1")
      check serialized.contains("\"col\":2")
      # Round-trip into a fresh VM and inspect.
      let vm2 = createGalleryVM("render.x")
      vm2.applyLayoutJson(serialized)
      check vm2.pendingLayout.val.len == 3
      check vm2.pendingLayout.val[0].captureId == "cap-1"
      check vm2.pendingLayout.val[0].rowIndex == 0
      check vm2.pendingLayout.val[0].columnIndex == 2
      check vm2.pendingLayout.val[1].captureId == "cap-2"
      check vm2.pendingLayout.val[1].rowIndex == 1
      check vm2.pendingLayout.val[2].captureId == "cap-3"
      # applyLayoutJson clears isDirty (we just loaded the saved state).
      check vm2.isDirty.val == false
      dispose()

  test "test_gallery_vm_mark_saved_clears_dirty_and_records_version":
    createRoot do (dispose: proc()):
      let vm = createGalleryVM("render.x")
      vm.registerDragMove("cap-1", 1, 1)
      check vm.isDirty.val == true
      vm.markSaved("a1b2c3d4-e5f6-7890-1234-567890abcdef", 2)
      check vm.isDirty.val == false
      check vm.activeLayoutId.val == "a1b2c3d4-e5f6-7890-1234-567890abcdef"
      check vm.activeLayoutVersion.val == 2
      dispose()

  test "test_gallery_vm_conflict_state":
    createRoot do (dispose: proc()):
      let vm = createGalleryVM("render.x")
      check vm.conflict.val.currentRow.len == 0
      vm.markConflict("a1b2c3d4-e5f6-7890-1234-567890abcdef",
                      "{\"version\":3,\"name\":\"foo\"}")
      check vm.conflict.val.layoutId == "a1b2c3d4-e5f6-7890-1234-567890abcdef"
      check vm.conflict.val.currentRow.contains("\"version\":3")
      vm.dismissConflict()
      check vm.conflict.val.currentRow.len == 0
      dispose()
