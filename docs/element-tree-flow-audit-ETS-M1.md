# ETS-M1: Element-tree flow audit

**Milestone:** ETS-M1 — read-only inventory of how the element-tree
manifest is built, shipped, and consumed today.
**Spec:** `codetracer-specs/Front-Ends/IsoNim/Editor-Element-Tree-Streaming.milestones.org`
**Status of this document:** complete; no source code changes; no
commits.

---

## TL;DR

The Brief's introduction states "today the element-tree manifest is
bundled into the existing M-packet as a `type:"element-tree"` JSON
payload, re-emitted on the frame loop whenever the launcher feels like
it" and projects this as a kilobytes-per-second idle cost. The audit
finds **this is not how the code actually behaves**. The bridge
already deduplicates the manifest by hash over `(surfaceWidth,
surfaceHeight, [(id, bounds)])` and emits an M packet only when that
hash changes (`isonim-render-serve/src/isonim_render_serve/bridge.nim:399-416`

- `:359-375`). On a static UI with mouse hover, the manifest ships
  **once** after `hello`, then **never again** until layout actually
  mutates. Measured idle bandwidth of the legacy path is therefore
  **~2 KB amortised over the entire connection lifetime, not per
  second**.

This reframes the campaign goal. ETS is not primarily a bandwidth
campaign — it is a **latency** and **incremental-update** campaign.
The headline gain is not "stop wasting kilobytes per second on idle"
(those are already not being spent); it is:

1. **Latency.** Mouse hover today never triggers a manifest re-emit
   at all — but as soon as the launcher mutates layout (a row added,
   a panel resized, a viewport flip), the **entire** manifest re-
   ships. For 500-element trees that is 58 KB on the wire per layout
   change. ETS-M3's per-element diff cuts this to bytes-per-changed-
   element.
2. **Layout-mutation cadence vs frame cadence.** The current code
   only re-checks the manifest _between F-packet ticks_ (`bridge.nim:603-
604`). A burst of layout mutations between two ticks coalesces
   into a single re-emit at the next tick. Latency for a layout
   change to land in the overlay is therefore bounded by the frame
   interval (33 ms at 30 FPS). A dedicated stream can outrun the
   frame loop.

The recommendation in section 7 lands on **M-subtype**, not E-packet,
contrary to the campaign default — see § 7 for the reasoning.

---

## 1. Launcher-side manifest build (per adapter)

All four launcher adapters share a common pattern: each runs a per-
renderer `buildLayoutRects` pass that is also the source of truth for
the rasteriser, then filters the resulting layout rects to nodes that
carry a non-empty `data-component-path` attribute and emits one
`ElementEntry` per surviving rect. The shared constants live at
`isonim-render-serve/src/isonim_render_serve/element_tree_attrs.nim:19-29`:

```nim
const ComponentPathAttr* = "data-component-path"
const ElementKindAttr*  = "data-component-kind"
```

The emitted schema is the same shape on every adapter (locked at
RS-M11 in `packet.nim:302-337`):

```
ElementTreeManifest
  frameSeq       : int           # not used for dedup; see § 2
  surfaceWidth   : int
  surfaceHeight  : int
  boundsUnit     : string        # "" / "pixels" / "cells"  (RS-M13)
  elements       : seq[ElementEntry]

ElementEntry
  id             : string        # mirrors componentPath today
  componentPath  : string        # canonical leaf identifier
  kind           : string        # free-form UX label
  bounds         : { x, y, w, h }  # integer pixels (or cells on TUI)
```

### 1.1 GPUI

`isonim-render-serve/src/isonim_render_serve/adapters/gpui_adapter.nim:413-436`
provides `buildGpuiElementTreeManifest`. It calls
`buildLayoutRects(root, width, height)` (`:167-174`) — the same DFS
the synthetic rasteriser at `:303-365` uses — then for every layout
rect reads `ComponentPathAttr` and only emits an entry when the
attribute is non-empty. The `id` is set equal to the component path.

### 1.2 Freya

`isonim-render-serve/src/isonim_render_serve/adapters/freya_adapter.nim:443-465`
provides `buildFreyaElementTreeManifest`. Same shape as GPUI: walks
`buildLayoutRects` (`:243-250`, whose layout pass at `:132-241` honours
`data-layout="horizontal"`, `data-layout-padding`, `data-layout-gap`,
and `data-fixed-width/height`), filters by `ComponentPathAttr`.

### 1.3 Cocoa

`isonim-render-serve/src/isonim_render_serve/adapters/cocoa_adapter.nim:938-963`
provides `buildCocoaElementTreeManifest`. Quirk worth flagging: the
Cocoa renderer's tree-inspection helpers take the renderer value as
their first argument (unlike GPUI/Freya where they are bare procs on
the element handle), so the builder constructs a transient `r =
CocoaRenderer()` at `:953`. Same DFS heuristic (`walkLayout` at
`:805-912`), same `ComponentPathAttr` filter. Compiles on Linux
because it only touches the renderer's headless side-tables, never
AppKit.

### 1.4 Android

`isonim-render-serve/src/isonim_render_serve/adapters/android_adapter.nim:494-523`
provides `buildAndroidElementTreeManifest`. Same DFS shape. Gated on
`when defined(android) or defined(mockJni)` because the Android
renderer cannot import on a plain Linux host — the launcher
(`isonim-examples/editor/backends/android.nim`) builds with
`-d:mockJni` for the host-side manifest tree and uses
`AdbScreencapFrameSource` for real-device pixels.

### 1.5 Element-ID stability across frames — load-bearing for ETS-M3

For diff stability, ETS-M3 requires `id` to be stable across re-
emits of the same logical element. **Audit finding: IDs are stable**,
because the `id` field is set to the `data-component-path` attribute,
which on every demo is one of:

- A compile-time constant (`TaskAppPath`, `FilterBarPath`,
  `TaskInputPath`, `TaskListPath`, `SummaryBarPath`, …; see
  `isonim-examples/task_app/core/component_paths.nim:25-47`).
- A function of the **domain identity** of the row, not its render
  order: `taskRowPath(t.id)` (`component_paths.nim:58-62`) yields
  `task_app/views/TaskRow#<id>` keyed by `task.id`, which is
  allocated when the task is created and never reused.

So reordering / filtering / selecting tasks leaves the IDs of the
remaining rows untouched. A new row produces a fresh `#<id>` suffix;
removal drops one. This is the precise shape ETS-M3's diff is built
to consume.

One small caveat for the campaign to know: the surface ID is
launcher-derived, not bridge-derived. If a launcher ever decides to
key rows by index (`#0`, `#1`, …) instead of by domain id, the diff
would degrade to "every reorder is a delete-and-re-add of every row
after the change point". The TUI / GPUI / Freya / Cocoa / Android
demos all currently use `taskRowPath(t.id)` correctly, but ETS-M3
should land a docstring or a check that flags renderers using
index-keyed IDs.

---

## 2. Bridge emission cadence

`isonim-render-serve/src/isonim_render_serve/bridge.nim`:

- On connect, after `hello` lands and **before** the first F packet,
  the bridge force-emits the seed manifest (`:911-912`):
  ```nim
  if cfg.elementTree != nil:
    await sendElementTreeIfChanged(client, cfg, state, force = true)
  ```
- On every subsequent render tick, the same call runs without
  `force` (`:603-604`).
- `sendElementTreeIfChanged` (`:399-416`) hashes the current manifest
  via `manifestKey` (`:359-375`) and **emits an M packet only when
  the hash differs from `state.elementTreeKey`**. Empty hash on a
  fresh connection forces the first emission.

`manifestKey` is:

```nim
proc manifestKey(m: ElementTreeManifest): string =
  result = $m.surfaceWidth & 'x' & $m.surfaceHeight & '|'
  for e in m.elements:
    result.add e.id
    result.add ':'
    result.add $e.bounds.x ; result.add ','
    result.add $e.bounds.y ; result.add ','
    result.add $e.bounds.w ; result.add ','
    result.add $e.bounds.h ; result.add ';'
```

So the hash spans the surface dimensions and the `(id, bbox)` set,
but deliberately excludes `frameSeq`, `boundsUnit`, and `kind`. The
practical consequences:

- `frameSeq` exclusion is correct — every adapter currently emits
  `frameSeq = 0` anyway (`buildXxxElementTreeManifest(..., frameSeq:
int = 0)`). The field exists for future ordering but is dead
  weight in the dedup path.
- `boundsUnit` exclusion is fine because `boundsUnit` is determined
  by transport (always `""` / `"pixels"` on F/M/I, always `"cells"`
  on the TUI D/M/P bridge), not by per-tick state — it could never
  toggle mid-connection on the same bridge.
- **`kind` exclusion is a latent bug for ETS.** If a launcher
  recategorises a node from `kind="row"` to `kind="row-completed"`
  without otherwise mutating bbox or id, the manifest re-emit is
  suppressed and the editor's overlay (which reads `kind` for
  selection-outline styling per affordance) sees a stale value.
  ETS-M2 should fix this by spanning `kind` in the diff input.

Verified empirically by `tests/test_bridge_element_tree_emission.nim`,
specifically the "idle frames do NOT re-emit the manifest" test
(`:157-191`): after the seed manifest lands, six identical-tree F
frames burn through and **zero** further M packets appear.

---

## 3. Browser-side consumption

The editor side has two entry points.

### 3.1 Signal source: `dispatchMetaPacket`

`isonim/src/isonim/editor/streaming_preview.nim:631-657`. When the
browser-side shim receives an M packet, the JSON body flows through
`dispatchMetaPacket`. The dispatcher probes for the element-tree
subtype via `isElementTreeBody(body)` (`packet.nim:457-464` — a cheap
substring scan of `"type":"element-tree"`), then:

- If `"boundsUnit":"cells"` is present, route through the TUI
  decoder.
- Else call `decodeElementTreeJson(body)` and feed the result into
  `vm.canvas.updateManifest(manifest)`.

`updateManifest` writes the decoded manifest into the
`PreviewCanvasVM.manifest` signal — the reactive root the overlay
chain subscribes to.

### 3.2 Overlay chain: `bindCanvasOverlayEffect`

`isonim/src/isonim/editor/views/canvas_mount.nim:271-554`. A
`createRenderEffect` reactively reads, per tick:

- `vm.platform.val` (web vs streaming)
- `canvas.hoveredElementId.val` / `canvas.hoveredComponentPath.val`
- `canvas.selectedElementId.val` / `canvas.selectedComponentPath.val`
- `vm.editMode.val`
- `canvas.manifest.val` (the latched manifest; _current_ and
  _changed_ both fire the effect)

For each of `(hoverLabel, selectionOutline, breadcrumb,
handlesGroup)` the effect inlines `{.emit: ["""..."""].}` JS that
reads `canvas.clientWidth / canvas.width` (per VRS-M2) to derive
`sx, sy` scaling factors then positions each overlay child via
`.style.left = ... + 'px'`. On the TUI cell path (`boundsUnit ==
"cells"`) the scaling reads the xterm.js host's rect instead.

The bbox lookup goes through `canvas.boundsOf(id)` (the primary path)
and `canvas.boundsOfPath(componentPath)` (the secondary fallback when
manifest re-emission shifted IDs). There is also a per-effect latch
(`latchedPath` / `latchedBounds` at `canvas_mount.nim:315-316`) that
bridges the gap between a chrome-bar `emEdit` flip and the new
manifest landing — a precedent ETS-M4 must preserve.

### 3.3 Cadence implication

The overlay's _paint cadence_ today is bounded by **render-tick** —
i.e. the bridge's frame loop. A mouse hover that should re-paint
the hover label re-runs the effect at the next `manifest.val` write,
but `manifest.val` only changes when the bridge sends a new M
packet, which only happens at most once per frame tick. **The
overlay does not paint at "DOM mousemove" cadence today.**

(This is a subtle point. The hover label's _text_ updates per
mousemove because `hoveredElementId` / `hoveredComponentPath` are
written from the canvas's local `mousemove` handler. But the
label's _position_ is derived from the manifest's bbox for the
hovered ID — and the manifest is whatever was last shipped. So
positioning is correct as long as the bbox is stable; it lags only
when layout itself moves between F-packet ticks.)

This is exactly the gap ETS exists to close: post-layout-mutation
overlay latency is bounded by the frame tick, not by the mutation
itself. ETS-M2..M6 buy back the difference.

---

## 4. Hit-chain consumption (EPP-M12 path)

The browser side does NOT consume the manifest's hit-test
information — it only uses bbox lookup for overlay positioning. The
actual click dispatch goes the other direction: the browser ships an
`I`-packet with `(mouseX, mouseY)` and the launcher resolves the
click into a chain of shadow-tree nodes via `hitTestPath`. The
launcher composition then fires `"click"` on every node in the chain.

Per-adapter wiring:

- `isonim-render-serve/src/isonim_render_serve/adapters/gpui_adapter.nim:176-201`
  defines `hitTestPath(root, width, height, x, y)`. **Critical
  parity:** it reuses `buildLayoutRects` (`:194-195`) — the same
  layout pass `buildGpuiElementTreeManifest` uses. So the rect that
  paints a pixel = the rect the user clicks = the manifest entry the
  editor's overlay outlines. ETS streaming does NOT regress this
  because the hit-test is computed launcher-side from the **tree**
  on click, not from the streamed manifest. The wire format change
  in ETS-M2..M6 is invisible to `hitTestPath`.

- `isonim-render-serve/src/isonim_render_serve/adapters/freya_adapter.nim:252-264`
  — same pattern.

- `isonim-render-serve/src/isonim_render_serve/adapters/cocoa_adapter.nim:923-936`
  — same pattern, threading the renderer value through.

- `isonim-render-serve/src/isonim_render_serve/adapters/android_adapter.nim`
  — Android does not currently expose a `hitTestPath` (gated by
  `when defined(android) or defined(mockJni)`); its input adapter
  uses the legacy single-target hit-tester. The EPP-M12 walk-up
  dispatch is GPUI / Freya / Cocoa only, by design. ETS does not
  change this.

The wiring at the input-sink side lives in the launcher composition,
e.g. `isonim-examples/editor/backends/gpui.nim:108-111`:

```nim
let hitChain = proc(x, y: int): seq[GpuiElement] {.gcsafe.} =
  {.cast(gcsafe).}:
    hitTestPath(capturedHitRoot, dynamicW, dynamicH, x, y)
let inputAdapter = newGpuiInputSink(hitTester, hitChain)
```

Then `gpui_input_adapter.submit` (`gpui_input_adapter.nim:114-130`)
on `maClick` walks the chain firing `"click"` on each node in turn.

**Regression risk for ETS:** zero. The hit-chain is computed
launcher-side on each click, not from the streamed manifest. ETS
changes the wire payload's shape (delta vs full snapshot), not the
tree-derived hit-test pipeline. As long as the launcher's manifest
builder and hit-test pass remain synced on `buildLayoutRects`, the
two paths cannot drift.

---

## 5. Metadata in the manifest beyond bboxes

The manifest schema today (per `packet.nim:310-320`) carries exactly:

- `id`
- `componentPath`
- `kind`
- `bounds = { x, y, w, h }`

Nothing else. Specifically:

- **No `parent_id`** — the manifest is a flat list, not a tree. The
  editor reconstructs spatial relationships from bbox containment if
  it needs them; today it doesn't.
- **No role / aria-label / accessibility data.** The renderer-side
  trees carry richer attributes (`aria-pressed`, `data-active`,
  `data-toggle`, `data-value`, `data-fixed-width`, …), but those
  drive _launcher-side rasterisation_ (the GPUI synthetic adapter's
  `aria-pressed` brand-tint at `gpui_adapter.nim:336-339`) and
  _layout_ (Freya / Cocoa `data-fixed-width` at `:172-176` /
  `:482-496`). They are not lifted into the wire payload.
- **No layout-padding / layout-gap.** Same story — the EPP-M4 Cocoa
  WIP reads `data-layout-padding` and `data-layout-gap` on the
  launcher side to drive flex distribution; it never reaches the
  browser.
- **No per-element style hints (z-order, opacity).** Likewise
  launcher-side only.

The implication for ETS-M2: the wire payload can stay narrow. The
editor today consumes only the `(id, componentPath, kind, bounds)`
tuple. Adding role / aria / data-\* would broaden the per-element
delta size unnecessarily for the current consumer.

**Recommendation for ETS-M2's metadata blob:** include `kind` in the
delta (fixes the latent `manifestKey` `kind`-exclusion bug from § 2),
**defer** broader metadata (role / aria / layout hints) to a
follow-up. If a later consumer (comment-mode breadcrumb, edit-mode
type badge) needs richer info, extend the schema then. JSON metadata
blobs forward-compat as the brief's spec proposes (`metadata_len`

- UTF-8 bytes; unknown keys preserved by the browser cache) is the
  right shape for that future extension but should ship empty / minimal
  in ETS-M2.

---

## 6. Cadence vs idle bandwidth — measured

**Methodology.** A standalone Nim program
(`/tmp/measure_ets_idle.nim`) calls the real `encodeElementTreeJson`

- `encodeMeta` codecs (no mocks) against three representative
  manifests at sizes matching the EX-M14 task_app composition root, the
  EX-M15 settings_app composition root, and the ETS-M3 worst-case
  perf-budget bound (500 elements). Wire-byte totals include the
  2-byte WS server-frame framing overhead. The script was compiled +
  run from the `isonim-render-serve` dev shell on macOS arm64; rebuild
  with `nim c -d:release --path:src --path:tests --path:../isonim-cocoa/src
--mm:orc -o:/tmp/measure_ets_idle /tmp/measure_ets_idle.nim`.

Measured wire sizes per element-tree M packet:

| Scenario                    | Elements | Bytes / emission |
| --------------------------- | -------- | ---------------- |
| task_app, 800×600           | 15       | 2 065            |
| settings_app, 1024×768      | 48       | 6 801            |
| dense worst-case, 1920×1080 | 500      | 58 157           |

Projected bytes-per-second under the two cadence models:

| Scenario         | Legacy _projected unconditional_ @ 30 FPS | **Actual code path on idle** |
| ---------------- | ----------------------------------------- | ---------------------------- |
| task_app         | 61 950 B/s                                | **0 B/s** after seed         |
| settings_app     | 204 030 B/s                               | **0 B/s** after seed         |
| dense worst-case | 1 744 710 B/s                             | **0 B/s** after seed         |

**The Brief's "every M-tick re-ships the full manifest, wasteful on
bandwidth" mental model does not match the code.** The bridge's
`manifestKey` dedup ships the manifest once per (id, bounds) change
and then is silent. On hovered-but-static UI the steady-state idle
cost is the _one-time_ seed cost, amortised to 0 B/s.

Where ETS actually saves bytes is on **mutation events** — a task
added / removed (every row's bbox below the insertion point shifts ⇒
full re-emit ⇒ ~2 KB on task_app, 6.8 KB on settings_app); a
viewport-pill resize that re-lays out every visible row; a chrome-bar
edit-mode flip that re-seeds the manifest (RS-M12 `select-story`
trigger). ETS-M3's per-element diff cuts these from "ship 6.8 KB"
to "ship maybe 200 bytes of bbox deltas for the actually-moved rows".

**Recommended reframing for ETS-M5's bandwidth bench.** The measurement
matrix the Brief proposes (idle / hover / scroll / mass-edit) needs
to recognise:

- **Idle = 0 B/s today.** The "win" is 0 → 0; there is no headline
  to capture here.
- **Hover = 0 B/s today** (hover moves the mouse, not the layout).
- **Scroll** — depends. If the launcher's scroll mutates layout
  positions, every scroll tick re-emits the full manifest today;
  ETS-M3 cuts this to a per-element y-delta. If scroll only
  translates the rendered canvas without mutating the headless tree
  (the synthetic raster's case), neither path emits anything. The
  bench must isolate which.
- **Mass edit** = the real win. Insert 100 rows ⇒ today re-ships
  the whole post-edit manifest (~7 KB for settings_app, scaling
  linearly with mutation count); ETS-M3 cuts this to N small deltas.

**Recommended bench cases for ETS-M5:**

1. Insert one row in task_app ⇒ measure delta size.
2. Resize viewport across the EX-M14 pill ⇒ measure delta size.
3. Open settings_app's "Profile" group accordion ⇒ measure delta
   size.
4. Mass-add 100 rows ⇒ measure total bytes ETS vs legacy.
5. **Latency:** mouse-move → overlay re-paint, with the launcher in
   a deliberate layout-mutation loop (e.g. animated bbox). This is
   the headline ETS-M6 number.

---

## 7. ETS-M2..M6 plan summary

### 7.1 The load-bearing decision: E-packet kind vs M-subtype

**Recommendation: M-subtype, not new E-packet kind.**

The campaign's stated default lean is E-packet. After this audit I
recommend flipping that to **M-subtype** for the following reasons:

1. **No new dispatcher seam.** The browser-side `dispatchMetaPacket`
   already routes by `"type"` field
   (`streaming_preview.nim:631-657`); the launcher-side bridge
   already routes M packets back via `decodeMeta`. Adding an
   `element-tree-delta` sub-kind reuses the entire codec, transport,
   and dispatch chain — including the `isElementTreeBody`
   substring-probe optimisation. The browser shim's M-handler is the
   single integration point.
2. **The seed manifest stays an M packet.** The campaign's diff
   stream needs an occasional full-snapshot resync (browser
   reconnect, seq gap). That snapshot is byte-identical to today's
   `element-tree` M packet. Splitting the snapshot into "M for
   snapshot, E for delta" creates an asymmetric dispatcher that
   ETS-M4's reset-on-isSnapshot logic re-couples anyway. M-subtype
   keeps the two emissions in one wire space.
3. **Capability handshake reuses `capabilities.elementTree`.** The
   bridge already advertises this bool in the hello packet
   (`bridge.nim:230`). M-subtype consumers branch on the new
   `"type":"element-tree-delta"` value; legacy consumers that don't
   recognise the subtype fall through to "unknown M body, ignore"
   per RS-M0 § "Error handling". No new capability field needed.
4. **Backward compat is free.** Per the brief, "the existing
   element-tree M-packet payload stays operative until ETS-M5
   measures the streaming alternative as a net win". M-subtype
   makes "send full snapshot OR delta" a per-tick decision the
   bridge can opt in/out of without renegotiating the transport
   set in the hello capability bag.
5. **Wire-tag pressure.** F / M / I / V / W are already burning
   tag bytes; introducing E (then conceivably D for the TUI
   element-tree, then …) racks up coupling between every consumer
   that wants to filter on tag. M-subtype centralises the new
   semantics in the JSON `"type"` field where extension is cheap
   and consumers that don't care can ignore the body.
6. **One bug to fix anyway.** `manifestKey` currently excludes
   `kind` from the dedup hash (`bridge.nim:359-375`). ETS-M2 is the
   natural moment to span `kind` into the diff input; doing that
   inside an M-subtype keeps the change localised to the existing
   element-tree code path.

The only argument that would flip this back to E-packet is "raw-
byte efficiency". JSON-in-M is verbose vs a packed binary E-packet
(roughly 2× factor on the dense bench). But § 6 shows even the
verbose path is 0 B/s on idle and ~7 KB per mutation on the real-
sized demo. The 2× factor is not load-bearing on either bandwidth
or latency, and ETS-M3's diff already cuts the per-mutation total
by ≥10× via the (op + element_id + delta) shape regardless of
which container holds the bytes.

If a future bench surfaces a real perf gap from the JSON encoding
(unlikely given measured idle), the M-subtype can be promoted to a
binary E-packet by swapping the codec without touching the
dispatcher's hello / capability / consumer-fallback semantics.

### 7.2 ETS-M2: wire format + bridge emission

- New M sub-kind: `"type":"element-tree-delta"`.
- Body shape:
  ```json
  {
    "type": "element-tree-delta",
    "seq": <u32>,
    "isSnapshot": <bool>,
    "surfaceWidth": <u32>,
    "surfaceHeight": <u32>,
    "ops": [
      { "op": "add",
        "id": "...", "parentId": "" (optional),
        "componentPath": "...", "kind": "...",
        "bounds": { "x": ..., "y": ..., "w": ..., "h": ... } },
      { "op": "update", "id": "...", "kind": "...",
        "bounds": { ... } },
      { "op": "remove", "id": "..." }
    ]
  }
  ```
- `parentId` is optional / empty by default — § 5 found nothing
  consumes parent links today; reserve the slot.
- Bridge holds a per-connection cache of the previous manifest
  (`prevElementTree`) and a monotonic `elementSeq` counter inside
  `ConnectionState` (already partially staged at `bridge.nim:316`).
- `sendElementTreeIfChanged` computes deltas via the ETS-M3 helper
  and emits when `ops.len > 0`. Heartbeat at a configurable
  interval (default off; the dedup invariant already covers idle).
- `BridgeConfig.streamElementTree: bool` defaults true when
  `-d:withElementStream` is set. Hello capabilities advertise
  `e/element-tree` (audit recommends `m/element-tree-delta` instead;
  see § 7.1).

### 7.3 ETS-M3: launcher-side diff computation

- New helper
  `isonim-render-serve/src/isonim_render_serve/element_tree_diff.nim`.
- Implementation strategy: index both manifests by `id`, iterate the
  union, emit add / update / remove ops. Critical: **also include
  `kind` in the update-trigger condition** to close the latent
  `manifestKey` exclusion bug (§ 2).
- Perf budget per spec: <1 ms / frame for ≤500 elements. The wire
  size measurements in § 6 give the ETS-M5 bench its calibration:
  a per-element delta is ~80 bytes JSON (`{"op":"update","id":"...",
"bounds":{...}}`); 50 mutated rows = ~4 KB delta vs ~6.8 KB full
  re-ship. The headline win is for low-mutation-count layout
  changes (≤10 rows), where the delta drops to ~800 B vs 6.8 KB
  (8.5× win).

### 7.4 ETS-M4: browser-side handler

- In `isonim/src/isonim/editor/streaming_preview.nim`, extend
  `dispatchMetaPacket` to branch on `isElementTreeDeltaBody(body)`.
- Maintain a per-bridge-connection local cache:
  `StreamingPreviewVM.canvas.manifest` already exists — `handleE`-
  equivalent applies ops in place. `isSnapshot=true` (or `seq` gap)
  triggers full cache reset.
- Reactive contract: every applied delta writes
  `canvas.manifest.val = some(updatedManifest)` so the
  `bindCanvasOverlayEffect` chain reruns.
- **Preserve the EPP-M12 hit-chain consumer.** § 4 confirmed the
  hit-chain reads launcher-side from `buildLayoutRects`, not from
  the manifest — so the browser-side change cannot regress this.
  ETS-M4 just needs to avoid removing `canvas.boundsOf(id)` /
  `boundsOfPath(componentPath)`; both are read directly by
  `bindCanvasOverlayEffect` (canvas_mount.nim:350-353,
  :403-411).
- **Preserve the latch mechanism** at `canvas_mount.nim:315-316,
:426-431`. The reset-on-snapshot branch must reset `latchedPath`
  / `latchedBounds` together with the manifest cache — otherwise
  the latch would paint stale rects from before the resync.

### 7.5 ETS-M5: bandwidth + latency measurement

See § 6 for the proposed bench shape. Key recommendation: do **not**
use the Brief's "idle / hover / scroll / mass-edit" matrix
unmodified — half those cells measure 0 B/s vs 0 B/s on the legacy
path because of the `manifestKey` dedup. Replace with the
mutation-event matrix in § 6.

The latency number is the one that actually moves: today the
overlay re-paints at frame-tick cadence (max 33 ms at 30 FPS;
sometimes 16 ms at 60 FPS); ETS-M4 unblocks sub-frame latency by
letting the M-subtype ship between frames.

### 7.6 ETS-M6: acceptance gate

The Brief's gate (hover across N positions, assert overlay matches
visual rect within 1 px, measure mouse-move → overlay-update latency
median <16 ms) is correct as-stated. One addition: include a
synthetic launcher that _deliberately mutates layout between F
ticks_ — that exercises the ETS-M2 sub-frame ship cadence the legacy
M-packet path can never match. Without that, ETS-M6 would pass on
today's static-UI demo without proving the campaign's headline
latency claim.

---

## Appendix: file:line cite map

| Concern                                 | File : line                                                                            |
| --------------------------------------- | -------------------------------------------------------------------------------------- |
| Shared element-tree attribute constants | `isonim-render-serve/src/isonim_render_serve/element_tree_attrs.nim:19-29`             |
| GPUI manifest builder                   | `isonim-render-serve/src/isonim_render_serve/adapters/gpui_adapter.nim:413-436`        |
| GPUI layout pass                        | `isonim-render-serve/src/isonim_render_serve/adapters/gpui_adapter.nim:117-174`        |
| GPUI hitTestPath                        | `isonim-render-serve/src/isonim_render_serve/adapters/gpui_adapter.nim:176-201`        |
| Freya manifest builder                  | `isonim-render-serve/src/isonim_render_serve/adapters/freya_adapter.nim:443-465`       |
| Freya hitTestPath                       | `isonim-render-serve/src/isonim_render_serve/adapters/freya_adapter.nim:252-264`       |
| Cocoa manifest builder                  | `isonim-render-serve/src/isonim_render_serve/adapters/cocoa_adapter.nim:938-963`       |
| Cocoa hitTestPath                       | `isonim-render-serve/src/isonim_render_serve/adapters/cocoa_adapter.nim:923-936`       |
| Android manifest builder                | `isonim-render-serve/src/isonim_render_serve/adapters/android_adapter.nim:494-523`     |
| `ElementTreeProvider` definition        | `isonim-render-serve/src/isonim_render_serve/bridge.nim:68-82`                         |
| `BridgeConfig.elementTree` field        | `isonim-render-serve/src/isonim_render_serve/bridge.nim:106-112`                       |
| `manifestKey` hash                      | `isonim-render-serve/src/isonim_render_serve/bridge.nim:359-375`                       |
| `sendElementTreeIfChanged` dedup gate   | `isonim-render-serve/src/isonim_render_serve/bridge.nim:399-416`                       |
| First-emission force (post-hello)       | `isonim-render-serve/src/isonim_render_serve/bridge.nim:909-912`                       |
| Per-tick re-check                       | `isonim-render-serve/src/isonim_render_serve/bridge.nim:603-604`                       |
| `ElementTreeManifest` / `ElementEntry`  | `isonim-render-serve/src/isonim_render_serve/packet.nim:302-337`                       |
| `encodeElementTreeJson` codec           | `isonim-render-serve/src/isonim_render_serve/packet.nim:339-394`                       |
| `encodeElementTreeMeta` wrapper         | `isonim-render-serve/src/isonim_render_serve/packet.nim:396-401`                       |
| `decodeElementTreeJson`                 | `isonim-render-serve/src/isonim_render_serve/packet.nim:403-455`                       |
| `isElementTreeBody` probe               | `isonim-render-serve/src/isonim_render_serve/packet.nim:457-464`                       |
| Browser M-packet dispatcher             | `isonim/src/isonim/editor/streaming_preview.nim:631-657`                               |
| `bindCanvasOverlayEffect`               | `isonim/src/isonim/editor/views/canvas_mount.nim:271-554`                              |
| Overlay manifest read                   | `isonim/src/isonim/editor/views/canvas_mount.nim:329-335`                              |
| Overlay coordinate transform            | `isonim/src/isonim/editor/views/canvas_mount.nim:388-395`                              |
| Mid-reseed bbox latch                   | `isonim/src/isonim/editor/views/canvas_mount.nim:315-316, :426-431`                    |
| GPUI input adapter `hitChain` dispatch  | `isonim-render-serve/src/isonim_render_serve/adapters/gpui_input_adapter.nim:114-130`  |
| Freya input adapter `hitChain` dispatch | `isonim-render-serve/src/isonim_render_serve/adapters/freya_input_adapter.nim:109-127` |
| Cocoa input adapter `hitChain` dispatch | `isonim-render-serve/src/isonim_render_serve/adapters/cocoa_input_adapter.nim:131-148` |
| Component-path constants (task_app)     | `isonim-examples/task_app/core/component_paths.nim:25-62`                              |
| Cadence regression test                 | `isonim-render-serve/tests/test_bridge_element_tree_emission.nim:157-191`              |
| Element-tree codec round-trip test      | `isonim-render-serve/tests/test_packet_element_tree_roundtrip.nim`                     |
| Launcher wiring (GPUI)                  | `isonim-examples/editor/backends/gpui.nim:68-111`                                      |
| Launcher wiring (Freya)                 | `isonim-examples/editor/backends/freya.nim:64-94`                                      |
| Launcher wiring (Cocoa)                 | `isonim-examples/editor/backends/cocoa.nim:69-99`                                      |
| Launcher wiring (Android)               | `isonim-examples/editor/backends/android.nim:201-215`                                  |
| Bandwidth measurement script            | `/tmp/measure_ets_idle.nim`                                                            |
