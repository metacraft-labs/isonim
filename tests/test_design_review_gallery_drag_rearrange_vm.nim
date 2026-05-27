## REV-M8 — gallery VM drag-rearrange + isDirty tests.
##
## Verifies that ``registerDragMove`` records the user's intent into
## ``pendingLayout`` AND flips ``isDirty`` so REV-M8's save-button
## affordance can light up reactively, AND that ``serializePendingLayout``
## + ``applyLayoutJson`` round-trip the data structure cleanly.

import std/[unittest, options, strutils]

import isonim/core/[signals, computation, owner]
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

  test "test_gallery_vm_effective_tiles_overlays_pending_layout_on_rows":
    ## REV-M8 follow-up — the gallery's ``rows`` memo derives from
    ## ``effectiveTiles`` (which overlays ``pendingLayout`` on
    ## ``tiles``).  This verifies that a drag-reorder visibly moves
    ## the tile in the grid's row buckets BEFORE any server round-trip:
    ## a drop on (rowIdx=0, colIdx=2) repositions the tile to column 2
    ## of row 0, displacing peers.
    createRoot do (dispose: proc()):
      let vm = createGalleryVM("render.x")
      # 4 tiles all in the same preview row.
      vm.tiles.val = @[
        mkTile("a", "p/a"),
        mkTile("b", "p/a"),
        mkTile("c", "p/a"),
        mkTile("d", "p/a"),
      ]
      # Sanity — before any drag, rows reflect the canonical order.
      check vm.rows.val.len == 1
      check vm.rows.val[0].tiles.len == 4
      check vm.rows.val[0].tiles[0].captureId == "a"
      check vm.rows.val[0].tiles[3].captureId == "d"
      # Drag ``a`` to (row 0, col 2) — between c and d.
      vm.registerDragMove("a", 0, 2)
      let after = vm.rows.val
      check after.len == 1
      check after[0].tiles.len == 4
      # New order: b, c, a, d (a removed from col 0, inserted at col 2
      # of the same row, which after removal of ``a`` is between ``c``
      # and ``d``).
      check after[0].tiles[0].captureId == "b"
      check after[0].tiles[1].captureId == "c"
      check after[0].tiles[2].captureId == "a"
      check after[0].tiles[3].captureId == "d"
      dispose()

  test "test_gallery_vm_effective_tiles_no_pending_equals_tiles":
    ## ``effectiveTiles`` is a no-op when ``pendingLayout`` is empty:
    ## the grid's ``rows`` memo stays byte-stable with the canonical
    ## tiles list so no spurious re-renders fire on tile-cache updates.
    createRoot do (dispose: proc()):
      let vm = createGalleryVM("render.x")
      vm.tiles.val = @[
        mkTile("a", "p/a"),
        mkTile("b", "p/a"),
        mkTile("c", "p/b"),
      ]
      let effective = vm.effectiveTiles.val
      check effective.len == 3
      check effective[0].captureId == "a"
      check effective[1].captureId == "b"
      check effective[2].captureId == "c"
      dispose()

  test "test_gallery_vm_effective_tiles_cross_row_drag_moves_to_target_row":
    ## A cross-row drag (drop on row B from row A) places the tile in
    ## the target row's bucket at the requested column.  ``applyPendingLayout``
    ## projects the tile's ``previewId`` onto the target row so the
    ## downstream ``groupByPreview`` step re-buckets it visually into
    ## row B.  Important: this is a projection over ``effectiveTiles``
    ## only — the canonical ``tiles.val`` keeps the tile's true
    ## previewId so any subsequent server round-trip works against the
    ## real data, not the visual reorder.
    createRoot do (dispose: proc()):
      let vm = createGalleryVM("render.x")
      vm.tiles.val = @[
        mkTile("a0", "p/a"),
        mkTile("a1", "p/a"),
        mkTile("b0", "p/b"),
        mkTile("b1", "p/b"),
      ]
      # Drag a0 to (row 1, col 0) — front of p/b's row.
      vm.registerDragMove("a0", 1, 0)
      let rows = vm.rows.val
      check rows.len == 2
      # p/a row now only has a1.
      check rows[0].previewId == "p/a"
      check rows[0].tiles.len == 1
      check rows[0].tiles[0].captureId == "a1"
      # p/b row now leads with a0 followed by b0, b1.
      check rows[1].previewId == "p/b"
      check rows[1].tiles.len == 3
      check rows[1].tiles[0].captureId == "a0"
      check rows[1].tiles[1].captureId == "b0"
      check rows[1].tiles[2].captureId == "b1"
      # The canonical ``tiles.val`` is unchanged — projection lives on
      # ``effectiveTiles`` only.
      let canonical = vm.tiles.val
      check canonical.len == 4
      check canonical[0].captureId == "a0"
      check canonical[0].previewId == "p/a"
      dispose()
