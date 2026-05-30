## IsoNim Editor — preview-canvas module (RS-M11 TUI slice).
##
## Owns the per-canvas state for the non-Web preview path. The
## editor's `views/component_detail.nim` mounts one of these next to
## the `StreamingPreviewVM` for every backend that isn't `pbWeb`.
##
## State surface:
##
##   * `latestFrame`: the most recent F-packet pixels (held so the
##     same canvas can repaint on resize / DPI change without
##     requesting a new frame).
##   * `manifest`: the most recent `element-tree` manifest decoded
##     from an M packet. `elementAt(x, y)` performs the hit test the
##     editor's pointer handlers call into.
##   * `selectedElementId` / `selectedComponentPath`: derived signals
##     the editor's sidebar binds to.
##
## The hit-test rule is "smallest-area match wins on overlap" — the
## spec's tie-breaker. We compute it via a single linear scan over
## `manifest.elements`; the cache is bounded by the visible element
## count (a few dozen at TUI scale).
##
## This module is JS-target-clean (no `std/os`, no native sockets);
## the canvas paint happens via the `{.emit.}` blocks in
## `component_detail.nim` so this module stays renderer-agnostic.
##
## Pattern-A JS consumer (RS-M11 follow-up).
## ----------------------------------------
## When compiled with `nim js`, this module also exposes
## ``attachBridgeClient`` / ``detachBridgeClient`` which open a real
## WebSocket from the editor's bundle to a render-serve launcher and
## drive the canvas + manifest signals end-to-end. The wire layout is
## the same RS-M0 protocol the bridge's own `static/index.html`
## implements (`'F' | u8 flags | u32 width | u32 height | u32 length |
## payload` for frames, `'M' | u32 length | UTF-8 JSON` for meta,
## `'I' | u32 length | UTF-8 JSON` for input). This file emits the JS
## directly via `{.emit.}` so the implementation tracks the static
## reference page byte-for-byte.

import std/options
import isonim/core/signals
import isonim_render_serve

type
  PreviewCanvasVM* = ref object
    ## Per-canvas state for one mounted non-Web preview.
    surfaceWidth*: Signal[int]
    surfaceHeight*: Signal[int]
    manifest*: Signal[Option[ElementTreeManifest]]
    selectedElementId*: Signal[string]
    selectedComponentPath*: Signal[string]
    hoveredElementId*: Signal[Option[string]]
      ## M-EVP-10: id of the manifest entry currently under the
      ## pointer (or `none` when the pointer is off any entry).
      ## Updates synchronously on `hoverAt`.
    hoveredComponentPath*: Signal[Option[string]]
      ## M-EVP-10: `componentPath` of the hovered entry. Mirrors
      ## `hoveredElementId` so the overlay can bind directly to a
      ## human-readable signal.
    elementCache*: seq[ElementEntry]
      ## ETS-M4: per-canvas element-tree delta cache. Mirrors the
      ## launcher-side ``prevElementTree`` cache that the bridge
      ## maintains under ETS-M2. Seeded by the legacy full-manifest M
      ## body (``type:"element-tree"``); subsequently mutated by
      ## ``element-tree-delta`` ops. The cache + ``surfaceWidth`` /
      ## ``surfaceHeight`` are recomposed into an
      ## ``ElementTreeManifest`` after every delta-apply and pushed
      ## into the ``manifest`` signal so ``bindCanvasOverlayEffect``
      ## sees the same signal-shape regardless of which wire path
      ## delivered the update.
    elementCacheSeeded*: bool
      ## ETS-M4: false until the first legacy ``element-tree`` body
      ## (or the first ``element-tree-delta`` ETS-M5 snapshot) seeds
      ## the cache. Deltas that arrive before the seed are dropped
      ## defensively — the bridge's monotonic seq + the editor's
      ## hello-accept handshake make this race extremely narrow.
    elementCacheSurfaceWidth*: int
      ## ETS-M4: surface dimensions tracked alongside the cache so the
      ## post-delta manifest carries the right (width, height). Set on
      ## seed; left untouched by delta ops (the bridge re-seeds when
      ## the surface dims change).
    elementCacheSurfaceHeight*: int
    elementCacheBoundsUnit*: string
      ## ETS-M4: ``""`` / ``"pixels"`` / ``"cells"`` — mirrors the
      ## seed manifest's ``boundsUnit`` so the recomposed manifest
      ## projects through the right overlay path.
    elementDeltaSeqSeen*: bool
    elementDeltaLastSeq*: uint32
      ## ETS-M4: monotonic seq counter of the last applied delta. A
      ## non-monotonic increment marks the cache invalid so the next
      ## seed re-establishes it; in ETS-M5 this will trigger a
      ## resnapshot request.

proc newPreviewCanvasVM*(): PreviewCanvasVM =
  ## Construct a fresh canvas VM. Must be called inside a `createRoot`
  ## so the signals' subscriptions are owned by the editor's lifetime.
  PreviewCanvasVM(
    surfaceWidth: createSignal(0),
    surfaceHeight: createSignal(0),
    manifest: createSignal(none(ElementTreeManifest)),
    selectedElementId: createSignal(""),
    selectedComponentPath: createSignal(""),
    hoveredElementId: createSignal(none(string)),
    hoveredComponentPath: createSignal(none(string)),
    elementCache: @[],
    elementCacheSeeded: false,
    elementCacheSurfaceWidth: 0,
    elementCacheSurfaceHeight: 0,
    elementCacheBoundsUnit: "",
    elementDeltaSeqSeen: false,
    elementDeltaLastSeq: 0'u32)

proc updateManifest*(vm: PreviewCanvasVM;
                     manifest: ElementTreeManifest) =
  ## Replace the cached manifest. The signal change propagates to
  ## subscribers (e.g. the optional overlay that paints the
  ## manifest's element rectangles for debug).
  ##
  ## ETS-M4: this proc is the legacy full-manifest path AND the seed
  ## for the delta cache. The ``element-tree-delta`` path
  ## (``applyElementTreeDeltaOps``) mutates the cache and recomposes
  ## a manifest through the same signal so the overlay reactive chain
  ## sees one signal-shape regardless of which wire path delivered
  ## the update.
  vm.surfaceWidth.val = manifest.surfaceWidth
  vm.surfaceHeight.val = manifest.surfaceHeight
  vm.elementCache = manifest.elements
  vm.elementCacheSeeded = true
  vm.elementCacheSurfaceWidth = manifest.surfaceWidth
  vm.elementCacheSurfaceHeight = manifest.surfaceHeight
  vm.elementCacheBoundsUnit = manifest.boundsUnit
  # Re-seed resets the delta-seq tracking — the next delta on the
  # post-seed connection will be seq=1 (the bridge's first delta after
  # the seed full-body) and we want to accept it without complaining
  # about a missing prior.
  vm.elementDeltaSeqSeen = false
  vm.elementDeltaLastSeq = 0'u32
  vm.manifest.val = some(manifest)

proc clearManifest*(vm: PreviewCanvasVM) =
  ## Forget the manifest — e.g. on disconnect, or when the backend
  ## switches to a launcher that doesn't advertise the
  ## `elementTree` capability. The canvas remains mounted and
  ## continues painting F frames; hit-testing simply returns `none`.
  vm.manifest.val = none(ElementTreeManifest)
  vm.selectedElementId.val = ""
  vm.selectedComponentPath.val = ""
  vm.hoveredElementId.val = none(string)
  vm.hoveredComponentPath.val = none(string)
  vm.elementCache = @[]
  vm.elementCacheSeeded = false
  vm.elementCacheSurfaceWidth = 0
  vm.elementCacheSurfaceHeight = 0
  vm.elementCacheBoundsUnit = ""
  vm.elementDeltaSeqSeen = false
  vm.elementDeltaLastSeq = 0'u32

proc composeManifestFromCache(vm: PreviewCanvasVM): ElementTreeManifest =
  ## ETS-M4: project the local cache + tracked surface dims into the
  ## same ``ElementTreeManifest`` shape ``updateManifest`` writes when
  ## the legacy full-body arrives. The overlay reactive chain
  ## (`bindCanvasOverlayEffect`) consumes the manifest signal; pushing
  ## the recomposed manifest through the same signal makes the two
  ## wire paths indistinguishable to that effect.
  result = ElementTreeManifest(
    frameSeq: 0,
    surfaceWidth: vm.elementCacheSurfaceWidth,
    surfaceHeight: vm.elementCacheSurfaceHeight,
    boundsUnit: vm.elementCacheBoundsUnit,
    elements: vm.elementCache)

proc applyElementTreeDeltaOps*(vm: PreviewCanvasVM;
                                ops: seq[ElementOp];
                                seqNo: uint32): bool =
  ## ETS-M4: apply a decoded ``element-tree-delta`` op-list to the
  ## local cache and republish the manifest signal. Returns true when
  ## the delta landed cleanly; false on a seq-gap (cache marked
  ## invalid; the next legacy seed re-establishes it).
  ##
  ## Op order on the wire is removes → adds → updates (the launcher-
  ## side ``computeElementTreeDelta`` emits them that way; see
  ## ``isonim-render-serve/src/isonim_render_serve/element_tree_delta.nim``).
  ## We honour that order so adds of a moved id land in the right
  ## slot after the corresponding remove.
  if not vm.elementCacheSeeded:
    # Defensive: ignore deltas that arrive before the seed. In normal
    # operation the bridge emits the seed full-body FIRST (post-hello)
    # and only then flips to the delta sub-kind. Deltas without a
    # seed would corrupt the empty cache silently; dropping them is
    # safer and the next seed (or reconnect) re-establishes the cache.
    return false
  if vm.elementDeltaSeqSeen and seqNo != vm.elementDeltaLastSeq + 1'u32:
    # Seq gap detected. Mark the cache invalid so the next legacy
    # seed (or — in ETS-M5 — a resnapshot request) re-establishes it.
    # The overlay continues painting the previous cache contents
    # until the next seed lands (better than a flicker-to-empty).
    vm.elementCacheSeeded = false
    vm.elementDeltaSeqSeen = false
    vm.elementDeltaLastSeq = 0'u32
    return false
  for op in ops:
    case op.kind
    of eopRemove:
      var keep: seq[ElementEntry] = @[]
      for e in vm.elementCache:
        if e.id != op.remId:
          keep.add e
      vm.elementCache = keep
    of eopAdd:
      var entry: ElementEntry
      entry.id = op.addId
      entry.componentPath = op.addComponentPath
      entry.kind = op.addElemKind
      entry.bounds = op.addBounds
      vm.elementCache.add entry
    of eopUpdate:
      for i in 0 ..< vm.elementCache.len:
        if vm.elementCache[i].id == op.updId:
          if op.updBoundsSet:
            vm.elementCache[i].bounds = op.updBounds
          if op.updElemKindSet:
            vm.elementCache[i].kind = op.updElemKind
          if op.updComponentPathSet:
            vm.elementCache[i].componentPath = op.updComponentPath
          break
  vm.elementDeltaSeqSeen = true
  vm.elementDeltaLastSeq = seqNo
  let manifest = composeManifestFromCache(vm)
  vm.surfaceWidth.val = manifest.surfaceWidth
  vm.surfaceHeight.val = manifest.surfaceHeight
  vm.manifest.val = some(manifest)
  true

proc elementAt*(vm: PreviewCanvasVM; x, y: int): Option[ElementEntry] =
  ## Resolve a pointer coordinate to the smallest-area manifest
  ## entry that contains it. Returns `none` if no entry matches OR
  ## the manifest is absent (no `elementTree` capability).
  ##
  ## Smallest-area wins on overlap. Ties (equal areas) keep the
  ## first match — that's a deterministic but undocumented
  ## tie-breaker; production manifests at TUI scale don't overlap.
  let m = vm.manifest.val
  if m.isNone: return none(ElementEntry)
  let manifest = m.get
  var best: Option[ElementEntry] = none(ElementEntry)
  var bestArea = high(int)
  for e in manifest.elements:
    let b = e.bounds
    if x < b.x or x >= b.x + b.w: continue
    if y < b.y or y >= b.y + b.h: continue
    let area = b.w * b.h
    if area < bestArea:
      bestArea = area
      best = some(e)
  best

proc selectAt*(vm: PreviewCanvasVM; x, y: int): bool =
  ## Run the hit-test and (when it succeeds) update the selection
  ## signals. Returns true if the click landed on a manifest entry.
  let hit = elementAt(vm, x, y)
  if hit.isNone:
    return false
  vm.selectedElementId.val = hit.get.id
  vm.selectedComponentPath.val = hit.get.componentPath
  true

proc hoverAt*(vm: PreviewCanvasVM; x, y: int): bool =
  ## M-EVP-10: hit-test the pointer position and update the hover
  ## signals. Returns true when the pointer is over a manifest entry
  ## (and the signals now report that entry); false when the pointer
  ## is off any entry (and the signals are cleared).
  ##
  ## Cheap to call on every mousemove: the underlying `elementAt`
  ## scans the manifest in one linear pass and the signals only fire
  ## change events when the resolved id actually changes (handled by
  ## the `Signal` set-equal short-circuit).
  let hit = elementAt(vm, x, y)
  if hit.isNone:
    if vm.hoveredElementId.val.isSome:
      vm.hoveredElementId.val = none(string)
      vm.hoveredComponentPath.val = none(string)
    return false
  let entry = hit.get
  let currentId = vm.hoveredElementId.val
  if currentId.isNone or currentId.get != entry.id:
    vm.hoveredElementId.val = some(entry.id)
    vm.hoveredComponentPath.val = some(entry.componentPath)
  true

proc boundsOf*(vm: PreviewCanvasVM; elementId: string): Option[ElementBounds] =
  ## M-EVP-10: look up an element's bounds by id. The overlay layer
  ## uses this to position the selection outline and edit-mode
  ## handles. Returns `none` if the manifest is absent or no entry
  ## matches the id (e.g. the manifest was just refreshed and the
  ## previously-selected entry has gone away).
  let m = vm.manifest.val
  if m.isNone: return none(ElementBounds)
  for e in m.get.elements:
    if e.id == elementId:
      return some(e.bounds)
  none(ElementBounds)

proc boundsOfPath*(vm: PreviewCanvasVM;
                   componentPath: string): Option[ElementBounds] =
  ## Look up an element's bounds by componentPath. Acts as a fallback
  ## for ``boundsOf`` when a manifest re-emission replaces a stable
  ## componentPath with a fresh id (e.g. the launcher reseeded the VM
  ## via ``select-story`` and the demo's per-instance ids were re-
  ## allocated). The componentPath stays stable across re-emissions
  ## for the same logical element (``task_app/views/TaskList``,
  ## ``task_app/views/TaskRow#5`` etc.), so the overlay can still
  ## paint the right rectangle even when the editor's
  ## ``selectedElementId`` references a now-gone id.
  let m = vm.manifest.val
  if m.isNone: return none(ElementBounds)
  for e in m.get.elements:
    if e.componentPath == componentPath:
      return some(e.bounds)
  none(ElementBounds)
