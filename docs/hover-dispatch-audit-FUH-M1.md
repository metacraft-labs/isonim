# FUH-M1: Hover-dispatch feasibility audit (Phase A)

**Milestone:** FUH-M1 — read-only audit for the IsoNim Editor
Follow-Up Hardening campaign, Phase A (hover dispatch).
**Spec:** `codetracer-specs/Front-Ends/IsoNim/Editor-Followup-Hardening.milestones.org`
**Trigger:** ETS-M6 acceptance closed `Editor-Element-Tree-Streaming`
honestly, but flagged that all four backends' input adapters
log-only `maMove`. The ETS campaign's projected 15x per-mutation
payload win cannot materialise on hover until apps actually mutate
state on hover. This milestone audits what's needed to wire
`maMove` -> `fireEvent` through the per-launcher adapters.
**Source pin:** `isonim-render-serve` HEAD = `463bc16` (ETS-M3
diff perf budget). The brief mentions `@2f770ee`; that SHA is not
on this repo's current branch, but the files cited
(`adapters/{gpui,freya,cocoa,android}_input_adapter.nim` carrying
the EPP-M12 `hitChain` walk-up) all read at the post-EPP-M12 state
exactly as the brief assumes. No code changes; no commits.

---

## TL;DR

The four input adapters already carry every piece of plumbing
hover dispatch needs _except the dispatch itself_:

- `iekMouse` events flow into `submit()` and are switched on
  `mouseAction`. The `maMove` arm currently appends one log line
  and falls through.
- The `hitChain` callback (deepest-first chain walk) is wired into
  GPUI / Freya / Cocoa — and identical chain code can run for
  every mouse coordinate, not just clicks.
- Each renderer's `fireEvent` primitive (GPUI / Freya through the
  Rust shim's `event_listeners: HashMap<String, ...>`; Cocoa
  through `eventCallbacks: Table[string, int32]`; Android via
  `jniSetEventListener(handle, event, callbackId)`) is a
  **free-form string-keyed dispatcher** — any event name the
  launcher's leaves register (e.g. `"mouseenter"`, `"mouseleave"`,
  `"mouseover"`) is fireable. No per-event whitelist gates them.
- Manifest `kind` mutates idiomatically by calling
  `r.setAttribute(row, ElementKindAttr, "row-hovered")`. The
  next bridge poll picks the new kind up via `getAttribute(lr.node,
ElementKindAttr)` in `buildLayoutRects` (gpui_adapter.nim:430,
  cocoa_adapter.nim:958, freya_adapter.nim:460) and the
  ETS-M2 delta encoder ships a sparse `{op:"update", id, kind}`
  op (~70 bytes) instead of re-emitting the whole row.

The four diverging items FUH-M2 must address:

1. **Android adapter lacks the `hitChain` field entirely** —
   `android_input_adapter.nim:102-117` is still the EPP-M7 shape
   with only `hitTest`. The other three adapters carry `hitChain`
   per EPP-M12.
2. **Cocoa `addEventListener` real-AppKit wiring** only honours
   `"click" / "input" / "change"` (renderer.nim:1030-1053); other
   event names land in `eventCallbacks` as a stored callback but
   are unreachable through real AppKit input. Synthetic
   `fireEvent("mouseenter")` from our adapter works (it walks
   `eventCallbacks` directly), so for the bridge-driven path this
   is fine; documenting the gap so a future native-Cocoa consumer
   doesn't expect AppKit tracking-area integration.
3. **No throttling exists anywhere** — `maMove` fires once per
   browser-side `mousemove` (60 Hz on a typical canvas).
   Per-leaf-change throttling lives in `submit()`: cache the prior
   hovered leaf id and only emit `mouseleave`/`mouseenter` on
   change.
4. **No app surfaces a hover handler.** Zero matches for
   `addEventListener.*"mouse(enter|leave|over|move)"` across the
   `task_app/*` leaves and the editor backends — confirming
   ETS-M6's audit. FUH-M2's demo must add at least one (proposed:
   `task_app`'s `renderTaskRow` mutates `ElementKindAttr` between
   `"row"` and `"row-hovered"`).

---

## 1. Per-adapter `maMove` handling today

All four adapters share the same shape: switch on `event.kind`,
when `iekMouse` log the action+coords, and dispatch through
`fireEvent` **only** when `mouseAction == maClick`. `maMove` falls
through to the log-only branch.

| Adapter | File                                                                             | `maMove` site                                                                                                                          | `hitChain` field present?         |
| ------- | -------------------------------------------------------------------------------- | -------------------------------------------------------------------------------------------------------------------------------------- | --------------------------------- |
| GPUI    | `isonim-render-serve/src/isonim_render_serve/adapters/gpui_input_adapter.nim`    | `:111-114` (log line built from `actionToStr(event.mouseAction)`); the `maClick` arm at `:114-138` fires through `hitChain`/`hitTest`. | yes (`:73`)                       |
| Freya   | `isonim-render-serve/src/isonim_render_serve/adapters/freya_input_adapter.nim`   | `:106-109`; `maClick` arm at `:109-127`.                                                                                               | yes (`:69`)                       |
| Cocoa   | `isonim-render-serve/src/isonim_render_serve/adapters/cocoa_input_adapter.nim`   | `:131-134`; `maClick` arm at `:134-164`. Gated `when defined(macosx)`.                                                                 | yes (`:92`)                       |
| Android | `isonim-render-serve/src/isonim_render_serve/adapters/android_input_adapter.nim` | `:151-154`; `maClick` arm at `:154-168`.                                                                                               | **no** — only `hitTest` (`:115`). |

### 1.1 The actual `maMove` branch (representative)

GPUI (`:111-138`, EPP-M12 hit-chain dispatch on `maClick`):

```nim
of iekMouse:
  sink.log.add "mouse " & actionToStr(event.mouseAction) & " " &
    $event.mouseX & "," & $event.mouseY
  if event.mouseAction == maClick:
    if sink.hitChain != nil:
      let chain = sink.hitChain(event.mouseX, event.mouseY)
      if chain.len > 0:
        sink.focusedNode = chain[0]
        sink.log.add "hit-chain " & $chain.len
        for node in chain:
          if node != nil:
            fireEvent(node, "click")
    elif sink.hitTest != nil:
      ...
```

When the `mouseAction` is `maMove`, control falls past the `if
event.mouseAction == maClick:` guard — no chain resolution, no
`fireEvent`, no `focusedNode` update. The only side effect is the
log line at the top of the arm.

### 1.2 Where the maMove wire event comes from

The browser-side `mousemove` listener installed at
`isonim/src/isonim/editor/streaming_preview.nim:1860` forwards every
mousemove to the bridge as an I packet. `event_dispatch.nim:202-211`
decodes the `mouse` body into an `InputEvent` with
`mouseAction = maMove`. The bridge then hands it to the adapter's
`submit()`. Rate confirmed at ~60 Hz on every viewport during the
ETS-M6 acceptance run (the harness records the wire latency for
hover-label updates at 0.8-1.0 ms median, which is the dispatch
floor, not the wire frequency).

---

## 2. `fireEvent` API surface — what's dispatched today

### 2.1 Per-renderer dispatch primitive

| Renderer | Signature                                                                                                                                                                                                                                                                                 | Backing store                                              | Free-form name?                                                                                                    |
| -------- | ----------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------- | ---------------------------------------------------------- | ------------------------------------------------------------------------------------------------------------------ |
| GPUI     | `proc fireEvent*(node: GpuiElement; event: string)` (`isonim-gpui/src/isonim_gpui/renderer.nim:341`) -> Rust shim `gpui_dispatch_event(node, event)` (`isonim-gpui/rust/gpui-nim-shim/src/lib.rs:516`). Shim's `event_listeners: HashMap<String, Vec<EventListener>>` (`lib.rs:528-530`). | HashMap<String, listeners>                                 | **yes**                                                                                                            |
| Freya    | `proc fireEvent*(node: FreyaElement; event: string)` (`isonim-freya/src/isonim_freya/renderer.nim:343`) -> Rust shim `freya_dispatch_event(node, event)` (`isonim-freya/rust/freya-nim-shim/src/lib.rs:485`). Same `event_listeners` HashMap shape (`:497-498`).                          | HashMap<String, listeners>                                 | **yes**                                                                                                            |
| Cocoa    | `proc fireEvent*(r: CocoaRenderer; node: CocoaElement; event: string)` (`isonim-cocoa/src/isonim_cocoa/renderer.nim:1160`). Walks `info(node).eventCallbacks[event]` directly (`:1163-1166`).                                                                                             | `Table[string, int32]`                                     | **yes** (storage); register-side only `"click"/"input"/"change"` get real AppKit wiring (`:1030-1053`) — see §3.3. |
| Android  | `proc fireEvent*(r: AndroidRenderer; node: AndroidElement; event: string)` (`isonim-android/nim-lib/src/isonim_android/renderer.nim:266`). MockJni lane walks `callLog` for the matching `(handle, event)` pair (`:268-271`); commandBuffer lane is currently a `discard`.                | `callLog` (jckSetEventListener, handle, event, callbackId) | **yes** in mockJni; **no** in commandBuffer (gap documented in `android_input_adapter.nim:67-82`).                 |

### 2.2 Event names dispatched by the adapters today

A grep over `fireEvent(.*", ".*")` across the four input adapters:

- `"click"` (all four; the EPP-M12 chain walk)
- `"keydown"`, `"keyup"`, `"input"` (EPP-M7 keyboard path on the
  focused node)

That's the entire dispatched-event vocabulary. The wire schema
(`event_dispatch.nim:13-21`) supports `iekKey` / `iekMouse` /
`iekScroll` / `iekResize` / `iekFocus` / `iekKeyboard` / two
RS-M12 story sub-kinds, but the adapter -> `fireEvent` projection
covers exactly the four event names above.

### 2.3 `fireEvent` argument shape

Two args: a node handle and a string. There is no event-object
parameter today (no equivalent of DOM `MouseEvent`); the Nim
closure registered through `addEventListener(node, event,
handler: proc())` takes no arguments. Hover dispatch therefore does
not need to pass `clientX/clientY` or relatedTarget — the closure
already knows which node it's attached to.

This matches what FUH-M2 needs: `fireEvent(rowNode, "mouseenter")`
calls a zero-arg `proc() = vm.hoveredId = some(id)` closure.

---

## 3. Per-renderer shadow-tree hook — hover event names

### 3.1 GPUI

`addEventListener` (`isonim-gpui/src/isonim_gpui/renderer.nim:300-302`)
just registers a callback id keyed by the event name string;
`gpui_add_event_listener_id` (`lib.rs:356-377`) stores
`event_listeners.entry(event_str.to_string()).or_default().push(...)`.
**No event-name filtering.** Registering `"mouseenter"`,
`"mouseleave"`, `"mouseover"`, `"mousemove"` all work. The Rust
shim test at `lib.rs:1503-1506` already exercises a `"hover"`
event name registered via `gpui_add_event_listener` and dispatched
via `gpui_dispatch_event`, so the round-trip is proven.

### 3.2 Freya

Same as GPUI: `freya_add_event_listener_id` (`lib.rs:323-340`)
stores in a `HashMap<String, Vec<EventListener>>` keyed by the
event name; `freya_dispatch_event` (`:485-498`) reads back by the
same key. No filtering.

### 3.3 Cocoa

`addEventListener` (`renderer.nim:1022-1053`) **stores any event
name** in `inf.eventCallbacks[event] = callbackId` (`:1028`) but
the `case event` block (`:1030-1053`) only wires `"click"` to
NSButton target-action / NSClickGestureRecognizer, and
`"input"/"change"` to selection-control target-action. Other event
names (mouseenter, mouseleave, mouseover, mousemove) fall through
the `else: discard` branch (`:1052-1053`).

**This is fine for the FUH-M2 path.** The Cocoa input adapter's
`fireEvent` call (`renderer.nim:1160-1166`) walks
`inf.eventCallbacks[event]` directly and dispatches the stored
callback, bypassing the AppKit-target wiring. So when the launcher
registers a `"mouseenter"` handler on a row and the bridge calls
`r.fireEvent(row, "mouseenter")`, the callback fires. The gap
matters only if a future consumer expected real AppKit
NSTrackingArea integration to fire the same callback on a real
mouse hover inside a windowed app — out of scope for the bridge's
synthetic-input model.

**Cocoa partial-Linux scaffold caveat.** The Cocoa input adapter's
mouse-click `fireEvent` call is gated `when defined(macosx)`
(`cocoa_input_adapter.nim:144-149`, `:156-164`). FUH-M2's
`maMove` branch must mirror that gating so the Linux scaffold
continues to compile.

### 3.4 Android

`jniSetEventListener(handle, event, callbackId)` (`mock_jni.nim:97-99`,
`command_buffer.nim:75`) is string-keyed; the mock lane stores
`(jckSetEventListener, handle, event, callbackId)` in the
`callLog`. `fireEvent` (`renderer.nim:266-271`) walks the log for
a matching `(handle, event)` pair. **No event-name filtering.**

Hover events would work end-to-end on the mockJni lane. On the
commandBuffer lane (real emulator), `fireEvent` is currently
`discard` (`renderer.nim:266` falls through past the `when
defined(mockJni)` block) — same gap the adapter docs flag at
`android_input_adapter.nim:67-79`. FUH-M2 hover-handler test
asserts the mockJni path; the real-emulator path is a follow-up.

### 3.5 Summary — does the vocabulary diverge?

| Event name   | GPUI | Freya | Cocoa           | Android (mockJni) | Android (cmd-buf)      |
| ------------ | ---- | ----- | --------------- | ----------------- | ---------------------- |
| `mouseenter` | yes  | yes   | yes (synthetic) | yes               | no (fireEvent=discard) |
| `mouseleave` | yes  | yes   | yes (synthetic) | yes               | no                     |
| `mouseover`  | yes  | yes   | yes (synthetic) | yes               | no                     |
| `mousemove`  | yes  | yes   | yes (synthetic) | yes               | no                     |

**The FFI surfaces don't diverge** for synthetic dispatch from the
bridge — the storage layer is `HashMap<String, ...>` (GPUI/Freya
Rust), `Table[string, int32]` (Cocoa Nim), or string-keyed JNI
call-log entries (Android). The only divergence is the
_native-input-source_ wiring on Cocoa and the _real-emulator_
dispatch on Android — both irrelevant to a bridge-driven hover
dispatch where the adapter calls `fireEvent` directly.

**Recommendation for FUH-M2:** Standardise on `"mouseenter"` /
`"mouseleave"` as the two registered event names (the DOM-style
pair). Skip `"mouseover"`/`"mousemove"` — they only matter for
deep hover-bubbling semantics the bridge does not need.

---

## 4. Hover state class semantics — mutating manifest `kind`

### 4.1 How `kind` reaches the wire

Manifest builders read the `kind` attribute at every frame poll:

- `gpui_adapter.nim:430` -> `getAttribute(lr.node, ElementKindAttr)`
- `freya_adapter.nim:460` -> same
- `cocoa_adapter.nim:958` -> `r.getAttribute(lr.node, ElementKindAttr)`
- `tui_adapter.nim:427-428` -> `node.attributes[ElementKindAttr]`
- `android_adapter.nim:518` -> `r.getAttribute(lr.node, ElementKindAttr)`

`ElementKindAttr` is the literal string `"data-component-kind"`
(`element_tree_attrs.nim:25`). The launcher's leaves set it once
at row construction (`gpui/leaves.nim:270`:
`r.setAttribute(row, ElementKindAttr, "row")` — same pattern at
`freya/leaves.nim`, `cocoa/leaves.nim`, `android/leaves.nim`,
`tui/leaves.nim`).

### 4.2 Idiomatic kind flip for a hover handler

```nim
let onEnter = proc() =
  r.setAttribute(row, ElementKindAttr, "row-hovered")
let onLeave = proc() =
  r.setAttribute(row, ElementKindAttr, "row")
r.addEventListener(row, "mouseenter", onEnter)
r.addEventListener(row, "mouseleave", onLeave)
```

This is symmetric with the existing click handlers
(`r.addEventListener(toggleBtn, "click", makeToggleHandler(vm, t.id))`
at `gpui/leaves.nim:314`). No VM signal involvement is required
for the _visual_ hover state — the renderer's headless tree
attribute is the canonical source of truth and the bridge poll
picks it up.

### 4.3 Resulting wire shape via ETS-M2 delta

When the next bridge poll runs `buildGpuiElementTreeManifest`, the
row's `kind` field changes from `"row"` to `"row-hovered"`. The
`computeElementTreeDelta` helper (`element_tree_delta.nim`) emits
a sparse update op:

```json
{ "op": "update", "id": "task_app/views/TaskRow#7", "kind": "row-hovered" }
```

vs the full-row `add` shape carrying bounds + componentPath +
kind + label + metadata (~250 bytes). The ETS campaign's 15x
projected win on per-mutation payload is exactly this case.

### 4.4 Alternative: dual signal in the VM

If FUH-M3's acceptance gate wants the **app code** (not just the
renderer attribute) to track the hovered row, the views.nim layer
could carry an `hoveredId: Signal[Option[int]]` field on
`TaskAppVM` and the handler mutates `vm.hoveredId.val = some(t.id)`
in `onEnter`. The `createRenderEffect` chain at
`gpui/leaves.nim:365-371` already proves the pattern (the
empty-state placeholder reactively updates on filter changes).

**FUH-M2 recommendation:** start with the renderer-attribute path
(simpler, fewer moving parts, hits the delta wire cleanly). The
VM-signal path is the natural extension if any non-visual
behaviour (analytics, accessibility) needs to react to hover.

---

## 5. Apps to add the demo handler in

### 5.1 Candidate audit

Apps in the editor catalog:

- `task_app` — three sample TaskRow entries by default
  ("Two Active" story; the static cases used in ETS-M6 § 3.1-3.3).
- `settings_app` — vertical card layout of grouped controls.
- No other app has a multi-instance leaf where hover is a natural
  affordance (filter pills are single-tap; the Add button is a
  one-shot CTA).

### 5.2 Recommendation: `task_app` `renderTaskRow`

Specifically the GPUI/Freya/Cocoa/Web leaves' `renderTaskRow`
proc. Mutation point per backend:

| Backend | File                                          | Insertion point                                                                                                                                              |
| ------- | --------------------------------------------- | ------------------------------------------------------------------------------------------------------------------------------------------------------------ |
| GPUI    | `isonim-examples/task_app/gpui/leaves.nim`    | after `:270` (`r.setAttribute(row, ElementKindAttr, "row")`)                                                                                                 |
| Freya   | `isonim-examples/task_app/freya/leaves.nim`   | analogous (renderTaskRow declares `r.setAttribute(row, ElementKindAttr, "row")` and then assembles children + `r.addEventListener(toggleBtn, "click", ...)`) |
| Cocoa   | `isonim-examples/task_app/cocoa/leaves.nim`   | analogous, at the matching row construction site                                                                                                             |
| Web     | `isonim-examples/task_app/web/leaves.nim`     | (`addEventListener` available via the renderer concept; the editor's web iframe path does not need bridge dispatch)                                          |
| Android | `isonim-examples/task_app/android/leaves.nim` | analogous; gated behind mockJni for the unit test                                                                                                            |
| iOS     | `isonim-examples/task_app/ios/leaves.nim`     | optional — not part of the editor catalog                                                                                                                    |
| TUI     | `isonim-examples/task_app/tui/leaves.nim`     | TUI has no `mousemove` wire event in practice (cursor-anchored)                                                                                              |

The "exact mutation point" for GPUI (canonical pattern):

```nim
proc renderTaskRow(r: GpuiRenderer; vm: TaskAppVM; t: Task): GpuiElement =
  let row = r.createElement("li")
  r.setAttribute(row, "data-task-id", $t.id)
  r.setAttribute(row, ComponentPathAttr, taskRowPath(t.id))
  r.setAttribute(row, ElementKindAttr, "row")
  # ... existing styles ...
  # NEW (FUH-M2):
  let rowRef = row
  r.addEventListener(row, "mouseenter", proc() =
    r.setAttribute(rowRef, ElementKindAttr, "row-hovered"))
  r.addEventListener(row, "mouseleave", proc() =
    r.setAttribute(rowRef, ElementKindAttr, "row"))
  # ... toggleBtn / label / removeBtn ...
```

### 5.3 Which backend to land first

`cocoa` (per the FUH-M0 brief and the ETS-M6 evidence) — Metal
capture is the fastest and the EPP-M12 hit-chain is wired with
real AppKit gestures. The FUH-M2 test
(`test_per_backend_hover_dispatch.nim`) can iterate every backend's
`InputSink` with a synthetic `maMove` sequence, asserting
`fireEvent("mouseenter")` fires for each new hover target and
`fireEvent("mouseleave")` for the prior.

---

## 6. Throttling / debouncing

### 6.1 The risk

`maMove` decodes from browser-side `mousemove` (`streaming_preview.nim:1860`),
which fires at the canvas's refresh rate (~60 Hz on a typical
laptop). If FUH-M2's `submit()` resolves the hit chain and fires
`mouseenter` on **every** `maMove`, the renderer's
`event_listeners` HashMap walk runs 60 times per second on every
nested leaf the cursor crosses, plus the deepest-first walk-up
contract from EPP-M12 means each fire visits the whole ancestor
chain.

At 60 Hz with a typical 5-deep chain that's 300 `fireEvent` calls
per second. Each `fireEvent` is cheap (a `Table` lookup + a
Nim closure invocation) but the **handler side effects** are not:
`r.setAttribute(row, ElementKindAttr, "row-hovered")` triggers a
renderer attribute write, and on the next bridge poll the manifest
diff re-emits an `update` op even if `kind` did not actually
change.

### 6.2 Recommended throttle: hit-test-based change-detection

Cache the prior `hoveredChain[0]` (deepest leaf) in the
`InputSink` and only fire `mouseenter` / `mouseleave` when the
deepest leaf id changes:

```nim
type
  GpuiInputSink* = ref object
    # ... existing fields ...
    lastHoveredNode*: GpuiElement   # NEW
    lastHoveredChain*: seq[GpuiElement]  # NEW (for symmetric leave)

proc submit*(sink: GpuiInputSink; event: InputEvent) =
  # ... existing log + maClick ...
  if event.mouseAction == maMove and sink.hitChain != nil:
    let chain = sink.hitChain(event.mouseX, event.mouseY)
    let newLeaf = if chain.len > 0: chain[0] else: nil
    if newLeaf != sink.lastHoveredNode:
      # Fire mouseleave on the prior chain (deepest-first).
      for node in sink.lastHoveredChain:
        if node != nil: fireEvent(node, "mouseleave")
      # Fire mouseenter on the new chain (deepest-first).
      for node in chain:
        if node != nil: fireEvent(node, "mouseenter")
      sink.lastHoveredNode = newLeaf
      sink.lastHoveredChain = chain
```

**Behavioural cost:** the chain walk runs every `maMove` (60 Hz)
but `fireEvent` only fires on a leaf change. For a static cursor
parked over a single row, the dispatch quiesces immediately. For
a fast drag across N rows, exactly 2N `fireEvent` calls land (one
leave per departed leaf, one enter per arriving leaf) — bounded by
the layout, not by the wire frequency.

**No timer-based debounce is needed** — leaf-change tracking is
already the natural throttle. A timer would add complexity (the
sink would need a clock dependency) for zero gain.

### 6.3 Chain-walk symmetry

The EPP-M12 walk-up dispatch on `maClick` fires `"click"` on every
ancestor in the chain (deepest first). Hover should mirror this:
`mouseenter` and `mouseleave` fire on every ancestor in the
respective chains, deepest-first. This matches DOM `mouseenter`
bubbling semantics (it doesn't bubble in real DOM, but our
synthetic chain dispatch model already chose to fire on every
ancestor for `click`, so consistency wins).

If FUH-M3's acceptance test wants to assert exactly one
`mouseenter` per row-change (not the whole ancestor chain), use
`mouseover` / `mouseout` instead — those bubble in real DOM and a
single fire on `chain[0]` is sufficient. **FUH-M2 recommendation:**
use `mouseenter` / `mouseleave` (chain dispatch), document the
"fire on every ancestor" contract, and let handlers be idempotent
(`r.setAttribute` is idempotent against the same value).

### 6.4 Per-backend perf note

The throttle lives in the input adapter, which is per-backend.
The Android adapter (which currently lacks `hitChain` per § 1)
must grow the `hitChainTester` field and consume an
`AndroidElement` chain. The mock-jni lane's chain implementation
can reuse `buildLayoutRects` from `android_adapter.nim` exactly
as gpui/freya/cocoa do.

---

## FUH-M2 implementation plan (summary)

Touch points (read-only audit, no code changes here):

1. **All four input adapters** — extend `submit()`'s `iekMouse`
   arm to handle `maMove`:
   - Resolve `hitChain(x, y)` if non-nil.
   - Compare `chain[0]` against `sink.lastHoveredNode`.
   - On change: walk the prior chain firing `"mouseleave"`,
     then walk the new chain firing `"mouseenter"`.
   - Update `lastHoveredNode` + `lastHoveredChain`.
2. **Android adapter** must additionally grow `hitChain`:
   - Add `HitChainTester* = proc(x, y: int): seq[AndroidElement]`.
   - Add `hitChain*: HitChainTester` to `AndroidInputSink`.
   - Extend `newAndroidInputSink` to accept an optional
     `hitChain` parameter.
   - Add `hitTestPath*` to `android_adapter.nim` mirroring the
     existing `buildLayoutRects` walk.
   - Wire the chain in `editor/backends/android.nim:218-221`.
3. **Cocoa adapter** must gate the new `fireEvent` calls
   `when defined(macosx)` per the existing partial-Linux scaffold.
4. **No per-renderer FFI changes are required** — every shim
   already accepts arbitrary event names and dispatches through
   the existing `Table`/`HashMap` lookup.
5. **`task_app` `renderTaskRow`** (GPUI / Freya / Cocoa / Android
   leaves) adds the two-line hover handler pair flipping
   `ElementKindAttr` between `"row"` and `"row-hovered"`. Web /
   TUI / iOS optional.
6. **New unit test**
   `isonim-render-serve/tests/test_per_backend_hover_dispatch.nim`
   drives a synthetic `maMove` sequence across a known element
   tree per backend; asserts `fireEvent("mouseenter")` fires for
   each new hover target and `fireEvent("mouseleave")` for the
   prior. The structured `log` field already records every
   `fireEvent` site indirectly (`hit-chain N` lines for clicks);
   FUH-M2 can extend the log to include `enter <chain.len>` /
   `leave <chain.len>` lines for the new branch.

The campaign's 15x payload-win projection then materialises on
FUH-M3 by re-running the ETS-M6 acceptance harness against the
now-mutating `task_app` — hover over N rows, count the
`element-tree-delta` op sizes, compare against the legacy
full-manifest body byte count for the same N rows.
