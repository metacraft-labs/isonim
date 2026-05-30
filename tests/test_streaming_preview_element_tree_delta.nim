## test_streaming_preview_element_tree_delta — ETS-M4 unit test.
##
## Drives the editor-side ``dispatchMetaPacket`` through a synthetic
## ``element-tree`` seed followed by a sequence of
## ``element-tree-delta`` M-bodies. Asserts that:
##
##   1. The seed full-manifest body lands in
##      ``StreamingPreviewVM.canvas.manifest`` exactly as it does
##      on the legacy path.
##   2. A subsequent ``element-tree-delta`` body applies its op-list
##      to the local cache and republishes a manifest through the
##      SAME ``vm.canvas.manifest`` signal — the recomposed manifest
##      matches what a single legacy full-body would have produced
##      after the same mutation.
##   3. Multiple successive deltas compose correctly (adds + updates
##      + removes accumulate on the local cache).
##   4. A delta arriving BEFORE the seed is dropped defensively and
##      the cache stays empty.
##   5. A seq-gap in the delta stream marks the cache invalid; the
##      next seed re-establishes it.
##
## This is a Nim-target unit test (no JS, no real launcher). The
## end-to-end exercise with a real launcher lives in
## ``tests/browser/e2e_editor_element_tree_delta_live.mjs``.

import std/[options, unittest]

import isonim/core/[signals, owner]
import isonim/editor/streaming_preview
import isonim/editor/preview_canvas
import isonim_render_serve

# ---------------------------------------------------------------------------
# Helpers
# ---------------------------------------------------------------------------

proc baselineManifest(): ElementTreeManifest =
  ## Two-row task-app baseline. Matches the shape ETS-M2's bridge
  ## emission test ships so the wire bytes the editor sees in
  ## production are exercised here too.
  ElementTreeManifest(
    frameSeq: 0,
    surfaceWidth: 640, surfaceHeight: 288,
    boundsUnit: "",
    elements: @[
      ElementEntry(id: "task_app/views/TaskRow#0",
                   componentPath: "task_app/views/TaskRow#0",
                   kind: "row",
                   bounds: ElementBounds(x: 0, y: 12, w: 640, h: 12)),
      ElementEntry(id: "task_app/views/TaskRow#1",
                   componentPath: "task_app/views/TaskRow#1",
                   kind: "row",
                   bounds: ElementBounds(x: 0, y: 24, w: 640, h: 12))])

proc updateRow1BoundsManifest(): ElementTreeManifest =
  ## Single bbox shift on row #1. The legacy full-body re-ship.
  ElementTreeManifest(
    frameSeq: 1,
    surfaceWidth: 640, surfaceHeight: 288,
    boundsUnit: "",
    elements: @[
      ElementEntry(id: "task_app/views/TaskRow#0",
                   componentPath: "task_app/views/TaskRow#0",
                   kind: "row",
                   bounds: ElementBounds(x: 0, y: 12, w: 640, h: 12)),
      ElementEntry(id: "task_app/views/TaskRow#1",
                   componentPath: "task_app/views/TaskRow#1",
                   kind: "row",
                   bounds: ElementBounds(x: 0, y: 240, w: 640, h: 12))])

proc addRow2Manifest(): ElementTreeManifest =
  ## Append a third row; row #1 is back in its baseline position.
  ElementTreeManifest(
    frameSeq: 2,
    surfaceWidth: 640, surfaceHeight: 288,
    boundsUnit: "",
    elements: @[
      ElementEntry(id: "task_app/views/TaskRow#0",
                   componentPath: "task_app/views/TaskRow#0",
                   kind: "row",
                   bounds: ElementBounds(x: 0, y: 12, w: 640, h: 12)),
      ElementEntry(id: "task_app/views/TaskRow#1",
                   componentPath: "task_app/views/TaskRow#1",
                   kind: "row",
                   bounds: ElementBounds(x: 0, y: 240, w: 640, h: 12)),
      ElementEntry(id: "task_app/views/TaskRow#2",
                   componentPath: "task_app/views/TaskRow#2",
                   kind: "row",
                   bounds: ElementBounds(x: 0, y: 252, w: 640, h: 12))])

proc removeRow0Manifest(): ElementTreeManifest =
  ## Drop row #0; rows #1 + #2 stay put.
  ElementTreeManifest(
    frameSeq: 3,
    surfaceWidth: 640, surfaceHeight: 288,
    boundsUnit: "",
    elements: @[
      ElementEntry(id: "task_app/views/TaskRow#1",
                   componentPath: "task_app/views/TaskRow#1",
                   kind: "row",
                   bounds: ElementBounds(x: 0, y: 240, w: 640, h: 12)),
      ElementEntry(id: "task_app/views/TaskRow#2",
                   componentPath: "task_app/views/TaskRow#2",
                   kind: "row",
                   bounds: ElementBounds(x: 0, y: 252, w: 640, h: 12))])

proc kindChangeManifest(): ElementTreeManifest =
  ## Same elements, but row #1 changes kind. Exercises the audit-
  ## flagged ``kind``-update path (see ETS-M1 audit § 2 — the legacy
  ## ``manifestKey`` dedup excludes ``kind`` so a bare kind-change
  ## wouldn't re-emit on the legacy path; the delta path closes that
  ## hole).
  ElementTreeManifest(
    frameSeq: 4,
    surfaceWidth: 640, surfaceHeight: 288,
    boundsUnit: "",
    elements: @[
      ElementEntry(id: "task_app/views/TaskRow#1",
                   componentPath: "task_app/views/TaskRow#1",
                   kind: "row-completed",  # << changed
                   bounds: ElementBounds(x: 0, y: 240, w: 640, h: 12)),
      ElementEntry(id: "task_app/views/TaskRow#2",
                   componentPath: "task_app/views/TaskRow#2",
                   kind: "row",
                   bounds: ElementBounds(x: 0, y: 252, w: 640, h: 12))])

proc idsSet(m: ElementTreeManifest): seq[string] =
  for e in m.elements: result.add e.id

proc kindOf(m: ElementTreeManifest; id: string): string =
  for e in m.elements:
    if e.id == id: return e.kind

proc boundsOfId(m: ElementTreeManifest; id: string): ElementBounds =
  for e in m.elements:
    if e.id == id: return e.bounds

proc deltaBody(prev, curr: ElementTreeManifest; seq: uint32): string =
  encodeElementTreeDelta(computeElementTreeDelta(prev, curr), seq)

# ---------------------------------------------------------------------------
# Suite
# ---------------------------------------------------------------------------

suite "ETS-M4: editor consumes element-tree-delta + transparent overlay feed":

  test "seed full-manifest body lands in canvas.manifest as legacy did":
    createRoot do (dispose: proc()):
      let vm = newStreamingPreviewVM(initial = pbCocoa,
                                     available = @[pbWeb, pbCocoa])
      let seed = baselineManifest()
      vm.dispatchMetaPacket(encodeElementTreeJson(seed))
      let m = vm.canvas.manifest.val
      check m.isSome
      check m.get.surfaceWidth == seed.surfaceWidth
      check m.get.surfaceHeight == seed.surfaceHeight
      check idsSet(m.get) == idsSet(seed)
      dispose()

  test "seed + 1 delta produces the same manifest a single legacy " &
       "full-body re-ship would":
    createRoot do (dispose: proc()):
      let vm = newStreamingPreviewVM(initial = pbCocoa,
                                     available = @[pbWeb, pbCocoa])
      let seed = baselineManifest()
      vm.dispatchMetaPacket(encodeElementTreeJson(seed))
      # Delta: row#1 bounds shift.
      let mutated = updateRow1BoundsManifest()
      vm.dispatchMetaPacket(deltaBody(seed, mutated, seq = 1'u32))
      let m = vm.canvas.manifest.val
      check m.isSome
      let post = m.get
      check idsSet(post) == idsSet(mutated)
      check boundsOfId(post, "task_app/views/TaskRow#1") ==
        boundsOfId(mutated, "task_app/views/TaskRow#1")
      # Row #0 unchanged.
      check boundsOfId(post, "task_app/views/TaskRow#0") ==
        boundsOfId(seed, "task_app/views/TaskRow#0")
      dispose()

  test "seed + add + update + remove deltas compose correctly across ticks":
    createRoot do (dispose: proc()):
      let vm = newStreamingPreviewVM(initial = pbCocoa,
                                     available = @[pbWeb, pbCocoa])
      let seed = baselineManifest()
      let afterUpdate = updateRow1BoundsManifest()
      let afterAdd = addRow2Manifest()
      let afterRemove = removeRow0Manifest()

      vm.dispatchMetaPacket(encodeElementTreeJson(seed))
      vm.dispatchMetaPacket(deltaBody(seed, afterUpdate, seq = 1'u32))
      vm.dispatchMetaPacket(deltaBody(afterUpdate, afterAdd, seq = 2'u32))
      vm.dispatchMetaPacket(deltaBody(afterAdd, afterRemove, seq = 3'u32))

      let m = vm.canvas.manifest.val
      check m.isSome
      let post = m.get
      # Composed result == single legacy full-body re-ship of the
      # final state (idsSet may differ in order; compare set).
      let postIds = idsSet(post)
      let expectIds = idsSet(afterRemove)
      check postIds.len == expectIds.len
      for id in expectIds:
        check id in postIds
      check boundsOfId(post, "task_app/views/TaskRow#1") ==
        boundsOfId(afterRemove, "task_app/views/TaskRow#1")
      check boundsOfId(post, "task_app/views/TaskRow#2") ==
        boundsOfId(afterRemove, "task_app/views/TaskRow#2")
      dispose()

  test "kind-only mutation propagates via delta (closes the legacy " &
       "manifestKey kind-exclusion bug)":
    createRoot do (dispose: proc()):
      let vm = newStreamingPreviewVM(initial = pbCocoa,
                                     available = @[pbWeb, pbCocoa])
      # Reach the post-remove state via legacy seed, then issue a
      # kind-only delta. The legacy ``manifestKey`` excludes ``kind``
      # from the dedup hash (ETS-M1 audit § 2) — the delta path closes
      # that hole because ``computeElementTreeDelta`` includes
      # ``kindChanged`` in the update gate.
      let baseline = removeRow0Manifest()
      let kinded = kindChangeManifest()
      vm.dispatchMetaPacket(encodeElementTreeJson(baseline))
      check kindOf(vm.canvas.manifest.val.get,
                   "task_app/views/TaskRow#1") == "row"
      vm.dispatchMetaPacket(deltaBody(baseline, kinded, seq = 1'u32))
      check kindOf(vm.canvas.manifest.val.get,
                   "task_app/views/TaskRow#1") == "row-completed"
      dispose()

  test "delta-before-seed is dropped; manifest stays empty":
    createRoot do (dispose: proc()):
      let vm = newStreamingPreviewVM(initial = pbCocoa,
                                     available = @[pbWeb, pbCocoa])
      let bogus = updateRow1BoundsManifest()
      # No prior — delta arriving first. Defensive drop.
      vm.dispatchMetaPacket(deltaBody(baselineManifest(), bogus,
                                      seq = 1'u32))
      check vm.canvas.manifest.val.isNone
      check not vm.canvas.elementCacheSeeded
      dispose()

  test "seq gap invalidates the cache; next seed re-establishes it":
    createRoot do (dispose: proc()):
      let vm = newStreamingPreviewVM(initial = pbCocoa,
                                     available = @[pbWeb, pbCocoa])
      let seed = baselineManifest()
      let mutated = updateRow1BoundsManifest()
      let afterAdd = addRow2Manifest()

      vm.dispatchMetaPacket(encodeElementTreeJson(seed))
      vm.dispatchMetaPacket(deltaBody(seed, mutated, seq = 1'u32))
      # Skip seq=2 and ship seq=3. The cache must mark itself invalid.
      vm.dispatchMetaPacket(deltaBody(mutated, afterAdd, seq = 3'u32))
      check not vm.canvas.elementCacheSeeded
      # Cache is invalid — the previous manifest signal value remains
      # so the overlay keeps painting until the next seed.
      check vm.canvas.manifest.val.isSome
      # Reseeding rehydrates the cache and resets seq tracking.
      vm.dispatchMetaPacket(encodeElementTreeJson(afterAdd))
      check vm.canvas.elementCacheSeeded
      let m = vm.canvas.manifest.val
      check m.isSome
      check idsSet(m.get) == idsSet(afterAdd)
      dispose()

  test "legacy-only stream (no delta arrives) keeps working unchanged":
    # Backward-compat: a launcher that doesn't advertise
    # ``e/element-tree`` keeps emitting the legacy full-body. The
    # editor must handle that path with no change in behaviour.
    createRoot do (dispose: proc()):
      let vm = newStreamingPreviewVM(initial = pbCocoa,
                                     available = @[pbWeb, pbCocoa])
      vm.dispatchMetaPacket(encodeElementTreeJson(baselineManifest()))
      vm.dispatchMetaPacket(encodeElementTreeJson(updateRow1BoundsManifest()))
      vm.dispatchMetaPacket(encodeElementTreeJson(addRow2Manifest()))
      let m = vm.canvas.manifest.val
      check m.isSome
      check idsSet(m.get) == idsSet(addRow2Manifest())
      check boundsOfId(m.get, "task_app/views/TaskRow#1") ==
        boundsOfId(addRow2Manifest(), "task_app/views/TaskRow#1")
      dispose()
