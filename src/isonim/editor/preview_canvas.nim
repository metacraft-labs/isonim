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
    hoveredComponentPath: createSignal(none(string)))

proc updateManifest*(vm: PreviewCanvasVM;
                     manifest: ElementTreeManifest) =
  ## Replace the cached manifest. The signal change propagates to
  ## subscribers (e.g. the optional overlay that paints the
  ## manifest's element rectangles for debug).
  vm.surfaceWidth.val = manifest.surfaceWidth
  vm.surfaceHeight.val = manifest.surfaceHeight
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
