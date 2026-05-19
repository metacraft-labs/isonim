## REV-M8 — multi-select + side-by-side comparison VM tests.

import std/[unittest, options, sets]

import isonim/core/[signals, owner]
import isonim/editor/views/gallery_overlay

proc mkTile(captureId, previewId: string;
            width = 200; height = 200): GalleryTile =
  GalleryTile(
    captureId: captureId,
    runId: "run-" & captureId,
    previewId: previewId,
    score: none[float](),
    status: "complete",
    pngUrl: "/api/design-review/get-capture-png?id=" & captureId,
    width: width, height: height,
  )

suite "REV-M8 gallery side-by-side VM":

  test "test_gallery_vm_side_by_side_two_selected_tiles":
    createRoot do (dispose: proc()):
      let vm = createGalleryVM("render.x")
      vm.tiles.val = @[
        mkTile("cap-a", "p/x", 1080, 2340),
        mkTile("cap-b", "p/y", 1080, 720),
        mkTile("cap-c", "p/z", 800, 600),
      ]
      # Multi-select two captures.
      vm.multiSelect("cap-a")
      vm.multiSelect("cap-b")
      check vm.selectedTileIds.val.len == 2
      check "cap-a" in vm.selectedTileIds.val
      check "cap-b" in vm.selectedTileIds.val
      check vm.compareCaptureIds.val.len == 2
      # Order preserved by selection order.
      check vm.compareCaptureIds.val[0] == "cap-a"
      check vm.compareCaptureIds.val[1] == "cap-b"
      vm.compareSideBySide()
      check vm.mode.val == gmCompare
      check vm.compareCaptureIds.val.len == 2
      # Both tiles' native dimensions are still exposed via the tile
      # records (the view layer reads them off ``vm.tiles`` keyed by
      # captureId).
      var widths: seq[int] = @[]
      var heights: seq[int] = @[]
      for t in vm.tiles.val:
        if t.captureId in vm.selectedTileIds.val:
          widths.add t.width
          heights.add t.height
      check widths == @[1080, 1080]
      check heights == @[2340, 720]
      dispose()

  test "test_gallery_vm_compare_requires_two_selections":
    createRoot do (dispose: proc()):
      let vm = createGalleryVM("render.x")
      vm.tiles.val = @[mkTile("only-one", "p/x")]
      vm.multiSelect("only-one")
      check vm.mode.val == gmGrid
      vm.compareSideBySide()
      # Defensive: stays in gmGrid when fewer than 2 captures selected.
      check vm.mode.val == gmGrid
      dispose()

  test "test_gallery_vm_multi_select_toggle":
    createRoot do (dispose: proc()):
      let vm = createGalleryVM("render.x")
      vm.tiles.val = @[
        mkTile("a", "p"),
        mkTile("b", "p"),
        mkTile("c", "p"),
      ]
      vm.multiSelect("a")
      vm.multiSelect("b")
      vm.multiSelect("c")
      check vm.compareCaptureIds.val == @["a", "b", "c"]
      # Toggle off middle element.
      vm.multiSelect("b")
      check "b" notin vm.selectedTileIds.val
      check vm.compareCaptureIds.val == @["a", "c"]
      dispose()

  test "test_gallery_vm_clear_compare_resets_state":
    createRoot do (dispose: proc()):
      let vm = createGalleryVM("render.x")
      vm.tiles.val = @[mkTile("a", "p"), mkTile("b", "p")]
      vm.multiSelect("a")
      vm.multiSelect("b")
      vm.compareSideBySide()
      check vm.mode.val == gmCompare
      vm.clearCompare()
      check vm.selectedTileIds.val.len == 0
      check vm.compareCaptureIds.val.len == 0
      check vm.mode.val == gmGrid
      dispose()
