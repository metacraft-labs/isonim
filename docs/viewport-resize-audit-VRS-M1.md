# VRS-M1 Audit — Viewport Resize Streaming Pipeline (read-only)

Date: 2026-05-29
Author: VRS-M1 sub-agent (audit only — no code changes)
Spec: `codetracer-specs/Front-Ends/IsoNim/Viewport-Resize-Streaming.milestones.org`

This audit maps the complete viewport-pill → launcher → frame pipeline
across `isonim/`, `isonim-render-serve/`, `isonim-examples/editor/backends/`,
and the underlying launcher apps (`isonim-gpui`, `isonim-freya`,
`isonim-cocoa`, `isonim-android`). All path references are absolute.

The headline finding is encouraging: the **launcher side of the pipeline
is already wired** for resize. Every per-backend launcher
(`gpui.nim` / `freya.nim` / `cocoa.nim` / `android.nim` under
`-d:mockJni`) installs an `iekResize`-aware sink that mutates the
`AnyFrameSource`'s backing `width`/`height` so the next `renderFrame()`
emits a new-sized F packet. **What's missing is purely the editor →
launcher sender:** the JS shim embedded in
`streaming_preview.nim` reads incoming `resize` M packets (line 1016)
but never sends an `I` packet of `type:"resize"` when the user clicks
a viewport pill. That's the one gap VRS-M2 fills; VRS-M3..M7 then
either no-op (the launcher dispatch already exists) or only need to
patch documentation + re-emit a `resize` upstream meta-frame.

---

## Section 1 — Editor side: viewport pill → reactive chain

### 1.1 Viewport type and helpers (`viewmodels.nim`)

- `previewViewportWidth*` / `previewViewportHeight*`
  `/Users/zahary/metacraft/isonim/src/isonim/editor/viewmodels.nim:928-932`
  Pure accessors returning `viewport.width` / `viewport.height` (int).
- `viewportsEqual*`
  `/Users/zahary/metacraft/isonim/src/isonim/editor/viewmodels.nim:938-943`
  Used by the chrome-bar pill active-state binding.
- `changePlatform*`
  `/Users/zahary/metacraft/isonim/src/isonim/editor/viewmodels.nim:2515-2530`
  Sets `platform.val`, then auto-swaps the viewport to the backend's
  default when the current pill is not in the pinned set. Important:
  this means a backend change can synthetically also change
  `viewport.val` — the resize sender effect MUST treat both as
  triggers.
- `changeViewport*`
  `/Users/zahary/metacraft/isonim/src/isonim/editor/viewmodels.nim:2532-2537`
  The canonical chip-click and dropdown-pick handler. Simply assigns
  `editor.viewport.val = viewport`. No side effect today.
- Existing `viewport.val` readers used as the "current" viewport
  source:
  - `views/page_preview.nim:174-176` — derives `width`, `height` from
    `viewport.val` for the device-frame CSS sizing.
  - `views/shell.nim:1491` — chrome-bar active state for pills.
  - `views/shell.nim:3155` / `:3185` — pill / dropdown click handler
    bodies (call `changeViewport`).
  - `views/shell.nim:3280-3284` — sync-strip-active-index effect.
  - `views/component_edit.nim:1735`, `:3038` — layout mode key.
  - `viewmodels.nim:8026-8028`, `:8103-8105` — review-annotation
    capture pulls viewport width/height into review metadata.

### 1.2 Click handlers

- `viewportSelectHandler*`
  `/Users/zahary/metacraft/isonim/src/isonim/editor/views/shell.nim:314-316`
  Dedicated handler; calls `vm.changeViewport(captured)`.
  **Today no other side effect.**
- Pinned-strip pick handler (closure)
  `/Users/zahary/metacraft/isonim/src/isonim/editor/views/shell.nim:3152-3156`
  Built inline at `mountSegmentedChoice` time. Calls
  `capturedVm.changeViewport(viewportPinned[i])`.
- Dropdown pick handler
  `/Users/zahary/metacraft/isonim/src/isonim/editor/views/shell.nim:3184-3187`
  Calls `cvm.changeViewport(vp)` then closes the popup.
- Backend-pill handler `platformHandler*`
  `/Users/zahary/metacraft/isonim/src/isonim/editor/views/shell.nim:306-312`
  Calls `selectBackend(vm.streamingPreview, captured)` then
  `vm.changePlatform(captured)`. Note: `selectBackend` also resets
  `vm.streamingPreview.bridgePort.val = 0` and bumps `status.val`,
  but does NOT touch the viewport. The viewport may flip as a
  side-effect of `changePlatform` (1.1).

### 1.3 Consumers of `viewport.val` that already participate in render

effects

- `views/page_preview.nim:172-238` — the page-preview render effect
  reads `viewport.val`, derives `width`/`height`, sets device-frame
  CSS styles. This is the **single most natural place** to add a
  parallel resize sender effect — the existing effect already
  subscribes to both `vm.viewport.val` and `vm.platform.val` (it
  branches on `vm.platform.val != pbWeb` at line 194), so it has
  exactly the right tracked-deps shape for the new sender.

  BUT: the canvas bridge attachment lives later in the same effect
  (`pageBridgeBinding.attachIfNeeded(vm, pageCanvasMnt.canvas, useCanvas)`
  at `:240`), and `attachIfNeeded` allocates a fresh
  `BridgeClientHandle` whenever the backend changes. The resize
  sender will have to coordinate: it must fire AFTER the bridge is
  open AND AFTER each `attachIfNeeded` re-attach (so a freshly-
  attached launcher learns the current viewport immediately).

- `views/component_detail.nim:938` — component-detail view's bridge
  attach.
- `views/foundations_page.nim:183` — foundations-page bridge attach.

There are **three** view modules that mount a canvas bridge
(`component_detail.nim`, `page_preview.nim`, `foundations_page.nim`),
each via its own `BridgeBinding`. Whichever module currently owns
the live bridge needs to emit the resize. The simplest VRS-M2 design
is: install the resize-send capability on the
`StreamingPreviewVM` itself (next to the existing
`StoryPublisher` hook at `streaming_preview.nim:162-173`), then have
**each** view's `attachIfNeeded` register a sender closure mirroring
the existing `installStoryPublisher` pattern at
`canvas_mount.nim:597-628`. That way the resize sender always
follows the active bridge, and the editor's reactive code can call
a single `streaming.publishResize(w, h)` from `page_preview.nim`'s
render effect.

### 1.4 Natural insertion point for resize message

**The audit confirms the spec's hypothesis:** the JS shim inside
`streaming_preview.nim` is the right place to add a `sendResize(w, h)`
function. Specifically:

- The shim already has `sendInput(obj)` at
  `/Users/zahary/metacraft/isonim/src/isonim/editor/streaming_preview.nim:1053-1056`
  that wraps `encodeI(JSON.stringify(obj))` and writes to the
  `WebSocket`. Adding a `sendResize(w, h)` is one line: call
  `sendInput({ type:"resize", width:w, height:h })`.

- The Nim side needs a small importjs/emit-style shim to invoke the
  JS function from the editor's reactive code. The cleanest pattern
  mirrors `sendSelectStory*`/`sendApplyMutation*` at
  `streaming_preview.nim:1152-1208` — define `sendResize*(handle:
BridgeClientHandle; width, height: int)` as a Nim proc that emits
  a small `(ws, width, height) => ws.send(encodeI(...))` JS shim,
  guarded by `ws.readyState === OPEN`.

- The reactive trigger lives in `page_preview.nim`'s existing render
  effect (or — better — in `canvas_mount.nim`'s
  `attachIfNeeded` closure, so it is shared across the three callers
  uniformly). Pattern: after each successful attach, fire one
  initial resize message; then a separate effect that reads
  `vm.viewport.val` (tracked) and re-fires.

### 1.5 The `bridgePortForBackend` table (for completeness)

- `streaming_preview.nim:641-657` documents:
  `pbWeb=0, pbTui=8112, pbGpui=8103, pbFreya=8104, pbCocoa=8105,
pbAndroid=8106, pbIos=8107`.
- Web has no bridge — the resize sender effect MUST short-circuit
  when `platform.val == pbWeb` (per the spec VRS-M2 brief).

---

## Section 2 — Transport / wire protocol

### 2.1 RS-M0 framing — recap

The `isonim-render-serve` library implements the F/M/I framing:

- **F packet** (Frame): `'F' | u8 flags | u32 LE width | u32 LE height
| u32 LE length | payload`. RS-M3 broadened with the diff-region
  payload. The browser's JS shim at
  `streaming_preview.nim:959-1006` decodes this and calls
  `ensureSize(width, height)` which mutates `canvas.width` /
  `canvas.height` — so any change in the launcher's frame source
  size automatically reseeds the canvas's intrinsic dims.

- **M packet** (Meta): `'M' | u32 LE length | UTF-8 JSON`. Types
  currently used:
  - `hello` — first packet on every connection. Schema:
    `{ type, protocolVersion, backend, capabilities, initialSize:
{width, height} }`. Built by
    `isonim-render-serve/src/isonim_render_serve/bridge.nim:128-155`
    (`buildHelloJson`). Browser handles at
    `streaming_preview.nim:1014-1015` — calls `ensureSize(width, height)`.
  - `resize` — schema: `{ type:"resize", width, height }`. Browser
    handles at `streaming_preview.nim:1016-1017` — calls
    `ensureSize(width, height)`. **NO launcher currently sends this
    upstream** (no call site exists in `isonim-render-serve` for an
    outbound resize M packet; grep `\"resize\"` over
    `isonim-render-serve/src/` finds only: the `inputKinds`
    capability bag at `bridge.nim:145` (advertises that `resize` I
    packets are accepted), the I-decode case at
    `event_dispatch.nim:163-169`, and the I-encode case at
    `event_dispatch.nim:274-277`).
  - `hot-reload` — clears the canvas (`streaming_preview.nim:1018-1020`).
  - `element-tree` — RS-M11 manifest, decoded via
    `dispatchMetaPacket*` at `streaming_preview.nim:566-592`.

- **I packet** (Input): `'I' | u32 LE length | UTF-8 JSON`. Types:
  `key`, `mouse`, `scroll`, `resize`, `focus`, `select-story`,
  `apply-mutation`. See `event_dispatch.nim:14-16` (`InputEventKind`)
  and `:116-226` (the decoder).

### 2.2 Browser → launcher (`I` frames) — currently sent

The JS shim at `streaming_preview.nim:1075-1131` currently emits:

- `{ type:"mouse", action:"down"|"up"|"move"|"click"|"dblclick",
button, x, y, modifiers }` — at
  `:1075-1112, :1119-1124`.
- `{ type:"scroll", x, y, deltaX, deltaY, modifiers }` — at
  `:1126-1130`.

**No** `resize`, `key`, `focus`, `select-story`, or `apply-mutation`
packets are emitted by `attachBridgeClient`'s embedded JS shim
itself. `select-story` / `apply-mutation` go through
`sendSelectStory*` / `sendApplyMutation*` (separate procs at
`streaming_preview.nim:1152-1208`). The reference HTML/JS at
`isonim-render-serve/static/index.html` DOES include a
`window.addEventListener('resize', …)` that emits an `iekResize`
(`static/index.html:262-264`), but that's the standalone reference
page, not the editor.

### 2.3 Launcher → browser (`F` + `M` frames) — currently sent

- `F` frames every `frameIntervalMs` (~50 ms at fps=20), with the
  payload's `width` / `height` reflecting the current
  `AnyFrameSource.width` / `.height` AT TIME OF RENDER. Because the
  launcher resizingSink mutates `src.width` / `src.height` and the
  next `renderFrame()` reads those, the F packet width/height
  automatically reflects the new size.

  Bridge dispatch:
  `bridge.nim:240-302` (`buildOutgoingFrame` + `frameLoop`). Note
  the deliberate cache invalidation at `:255-259`: when
  `prev.width != curr.width or prev.height != curr.height`, the
  bridge emits a full (non-diff) F packet AND drops the
  `lastSentFrame` cache so subsequent diffs are correct. This means
  the diff pipeline already handles resize gracefully — no further
  work required in `bridge.nim` for VRS-M3+.

- `M` `hello` once at connect: `bridge.nim:211-219`. Reads
  `cfg.frameSource.width` / `cfg.frameSource.height` from the
  `AnyFrameSource` wrapper. **Important asymmetry** (see 2.4
  below): the launcher mutates the _underlying_ frame source's
  width/height in the resizingSink, but the `AnyFrameSource`
  wrapper's `width` / `height` fields stay frozen. The first
  `hello` therefore carries the launch-time defaults, but
  subsequent F packets carry the live (resized) values.

- `M` `element-tree` on connect + on (id, bounds) change:
  `bridge.nim:221-238`, `bridge.nim:281-287`. The manifest's
  `surfaceWidth` / `surfaceHeight` come from the per-launcher
  `ElementTreeProvider` closure, which reads the launcher's
  `dynamicW` / `dynamicH` (the same variables the resizing sink
  updates). So manifests already follow size changes. Good.

- `M` `resize`, `M` `screenshot-response`, `M` `hot-reload` —
  declared in `isonim-render-serve/CLAUDE.md` § "What this library
  does" but the **outbound `resize` M packet has no sender today**
  (see 2.1). VRS-M4..M7 should EITHER add an outbound resize meta
  emission after `dynamicW`/`dynamicH` mutate, OR rely on the
  next F packet's intrinsic width/height (which the browser's
  `ensureSize` already honours at `streaming_preview.nim:954-958`).
  Per the spec (VRS-M4 brief), the explicit `resize` M is preferred
  for clarity and immediate canvas reseeding; deferring to F-frame
  intrinsic sizing works but introduces a one-frame lag.

### 2.4 `AnyFrameSource.width` vs `src.width` — minor latent bug

`isonim-render-serve/src/isonim_render_serve/frame_source.nim:53` —
`AnyFrameSource.width*` / `height*` are public fields cached at
wrapper-construction time
(`frame_source.nim:57-66`, `newAnyFrameSource`).

The bridge reads `cfg.frameSource.width` / `.height` at
`bridge.nim:213-215` for the `hello` packet, but the per-launcher
resizingSink (e.g. `editor/backends/gpui.nim:81-82`) only mutates
`src.width` / `src.height` — the underlying `GpuiFrameSource`'s
width/height — not the `AnyFrameSource` wrapper's fields. The
mismatch is harmless for in-session resize because the next F frame
(via `renderFrame()`) is built against `src.width`/`src.height` and
the JS shim's `ensureSize` picks up the new dims. But if the bridge
ever re-emits `hello` (e.g. on a future reconnect) it will lie. And
the manifest emitted by the `ElementTreeProvider` closure uses
`dynamicW` / `dynamicH` (local launcher state) — which matches
`src.width`/`.height` after the sink fires. So the
`AnyFrameSource.width` is dead state today.

**Recommendation for VRS-M3+:** when the launcher's resizingSink
fires, also update the `AnyFrameSource` wrapper's `width` / `height`
fields and emit a `resize` M packet. (The fields are already `*` —
exported — so this is a one-line patch in each launcher.)

The android adapter already does this implicitly at
`isonim-examples/editor/backends/android.nim:131-132`: when
`captureFrame` reads the device's native framebuffer dims it mutates
`src.width` / `src.height`. The launcher's resize-sink path mirrors
the pattern.

### 2.5 `InputEventKind` enum — receive vs send

`isonim-render-serve/src/isonim_render_serve/event_dispatch.nim:14-15`
defines:

```
InputEventKind = enum
  iekKey, iekMouse, iekScroll, iekResize, iekFocus,
  iekSelectStory, iekApplyMutation
```

- **Decode side** (browser → launcher): `decodeInputEvent*`
  (`event_dispatch.nim:116-226`) handles all 7 kinds.
  `iekResize` decode at `:163-169` requires `width` AND `height`,
  raises `PacketProtocolError` on missing fields.

- **Encode side** (launcher-side or test-side): `encodeInputEvent*`
  (`event_dispatch.nim:248-298`) handles all 7. **Used by tests
  today** (`isonim-render-serve/tests/test_packet_codec_roundtrip.nim:151`
  and `tests/test_bridge_input_roundtrip.nim:79,103` exercise the
  `iekResize` round-trip). There is also a hand-rolled deterministic
  encoder for `select-story` / `apply-mutation` at
  `event_dispatch.nim:333-372` to ensure on-wire bytes match across
  JSON ordering changes; **no hand-rolled deterministic encoder
  exists for `resize`** — VRS-M2 should add `encodeResizeBody*` to
  the editor side at `streaming_preview.nim` (next to
  `encodeSelectStoryBody*` / `encodeApplyMutationBody*` at
  `:753-790`).

- **Dispatch side** (launcher consumers):
  - All 5 per-backend input adapters (`gpui_input_adapter.nim:86-87`,
    `freya_input_adapter.nim:96-97`, `cocoa_input_adapter.nim:130-131`,
    `android_input_adapter.nim:165-166`) currently **only log**
    `iekResize` to the buffered log. They do NOT mutate the frame
    source or call any window API. The real handling lives in
    the launcher-specific resizingSink (see Section 3 per
    launcher).
  - The `StoryDispatchSink` at `story_dispatch.nim:54-83` delegates
    every non-story event (including `iekResize`) to its `inner`
    sink — which in every launcher is the per-launcher
    resizingSink (`editor/backends/gpui.nim:73-82` and analogues).
    This is the correct, working hand-off: `StoryDispatchSink →
resizingSink → AnyFrameSource state mutation`.
  - The reference `BufferedInputSink` at `event_dispatch.nim:386-409`
    only logs.

**Bottom line:** the launcher-side dispatch for `iekResize`
**already works** for GPUI, Freya, Cocoa (under macOS), and Android
(under `-d:mockJni`). The send side (browser → launcher) is the
only missing leg.

---

## Section 3 — Per-launcher state and resize support

### 3.0 Shared launcher plumbing (`common.nim`)

`/Users/zahary/metacraft/isonim-examples/editor/backends/common.nim`

- `LauncherConfig` (lines 23-30): `backend, port, width, height, fps,
staticDir, demo`.
- `parseLauncherArgs*` (lines 32-75): CLI parser. Reads `--width
<N>`, `--height <N>` etc. **Important:** the editor today
  spawns launchers via the editor-server (`isonim-examples/tools/
editor-server.mjs:1-280`), NOT via `launchBridge*`
  (`streaming_preview.nim:342-398` is only called from tests). The
  editor-server's spawning command lines are configured in
  `isonim-examples/tools/editor-server.mjs` (worth confirming what
  `--width` / `--height` they pass — I did not exhaustively read
  the file, but section 1.2 of `editor-server.mjs` is the
  `proxy /bridge/<backend>` config; the launcher spawn command
  itself is likely launched separately via `just` recipes — VRS-M7
  should investigate whether the initial launch passes the
  current viewport pill's dimensions).
- `runDemoBridgeWith*` (lines 89-119): builds `BridgeConfig`,
  starts the WS server. The launcher's only contract with the
  bridge is the F/M/I plumbing.

### 3.1 GPUI launcher

`/Users/zahary/metacraft/isonim-examples/editor/backends/gpui.nim`

- Defaults: `DefaultWidth=800`, `DefaultHeight=600` (lines 35-36).
- Initial size resolution: `let w = if cfg.width > 0: cfg.width
else: DefaultWidth` (line 39).
- Frame source: `newGpuiFrameSource(r, root, dynamicW, dynamicH)`
  at line 64.
- **Element-tree provider** reads `dynamicW`/`dynamicH` at line 71
  (closure capture — re-reads each tick).
- **resizingSink** at lines 73-82: mutates `dynamicW`, `dynamicH`,
  AND `src.width`, `src.height`. This is the canonical pattern
  every launcher mirrors.
- Wrapped via `StoryDispatchSink(... inner=resizingSink)` at line
  101-102 — so the `StoryDispatchSink.submit` at
  `story_dispatch.nim:81-83` forwards every non-story event
  (including `iekResize`) down to the resizing sink.

**Underlying app (`isonim-gpui/`):**

- `isonim-gpui/src/isonim_gpui/window.nim:115-119` — `createWindow*`
  creates a window of fixed initial size.
- `isonim-gpui/src/isonim_gpui/window.nim:152-156` — `onResize*` is
  a callback REGISTRATION proc; there's no `setSize` /
  `setWindowSize` exposed. The Rust shim at
  `isonim-gpui/rust/gpui-nim-shim/src/window.rs:167` only exposes
  `window_size(id)` (getter), not a setter (grep finds no
  `set_window_size` / `setSize` setter).
- HOWEVER the per-launcher integration uses the **headless render
  path** (`isonim-render-serve/src/isonim_render_serve/adapters/
gpui_adapter.nim:234-274`, `renderHeadlessFrame`), which calls
  `gpui_render_to_pixels(width, height, scale, ...)` — i.e. it
  passes the dims as args to the render call. There's no GPUI
  window to "resize"; the headless path simply renders to the
  requested dims each frame. So updating
  `src.width`/`src.height` is sufficient.
- The fallback synthetic path (`renderSyntheticFrame` at
  `gpui_adapter.nim:276+`) also reads `src.width` /
  `src.height` directly.
- **Conclusion:** GPUI is already fully resize-capable as soon as
  the editor sends `iekResize`. No `isonim-gpui` repo changes are
  needed for VRS-M4. The launcher's resizingSink IS the resize
  hook.

### 3.2 Freya launcher

`/Users/zahary/metacraft/isonim-examples/editor/backends/freya.nim`

Structure is identical to GPUI:

- Defaults: `DefaultWidth=800`, `DefaultHeight=600` (lines 31-32).
- Frame source: `newFreyaFrameSource(r, root, dynamicW, dynamicH)`
  at line 60.
- resizingSink at lines 69-78 mutates `dynamicW`/`dynamicH`/
  `src.width`/`src.height`.
- Wrapped via `StoryDispatchSink(... inner=resizingSink)` line 97-99.

**Underlying app (`isonim-freya/`):**

- `isonim-freya/src/isonim_freya/window.nim:14, 153-156` — Freya
  exposes `onResize` callback REGISTRATION (the OS-driven path).
  Like GPUI, there is **no Nim-side `setSize` setter** wired
  through the Rust shim; the shim's
  `isonim-freya/src/isonim_freya/bindings.nim:134-135` exposes
  `freya_notify_resize` which is a notify-the-app-of-an-OS-resize
  call, not "the app asks for a new size".
- The Freya adapter's `renderFrame` at
  `isonim-render-serve/src/isonim_render_serve/adapters/
freya_adapter.nim:280-345` uses the same headless
  `freya_render_to_pixels(w, h, ...)` shape as GPUI. Reads
  `src.width` / `src.height` each tick.
- **Conclusion:** Freya is also fully resize-capable via the
  launcher's resizingSink. No `isonim-freya` repo changes needed
  for VRS-M5.

### 3.3 Cocoa launcher

`/Users/zahary/metacraft/isonim-examples/editor/backends/cocoa.nim`

- Entire file gated `when defined(macosx):` (line 14).
- Defaults: `DefaultWidth=800`, `DefaultHeight=600` (lines 33-34).
- Frame source: `newCocoaFrameSource(r, root, dynamicW, dynamicH)`
  at line 58.
- resizingSink at lines 67-76 mutates `dynamicW`/`dynamicH`/
  `src.width`/`src.height`. Same pattern.
- Wrapped via `StoryDispatchSink` at lines 95-98.

**Underlying app (`isonim-cocoa/`):**

- `isonim-cocoa/src/isonim_cocoa/appkit/window.nim` declares
  `NSWindow.styleMask` etc.; not directly used by the headless
  capture pipeline.
- `isonim-cocoa/src/isonim_cocoa/appkit/autolayout.nim:164-182` —
  `setFrameSize*`, `setFrameOrigin*`, `setFrame*` are Nim-side
  AppKit selector shims (already wrapped — VRS-M6 can call them
  directly if the launcher's path ever needs to resize a real
  NSWindow).
- The Cocoa adapter's `renderFrame` at
  `isonim-render-serve/src/isonim_render_serve/adapters/
cocoa_adapter.nim:177-705` is an offscreen layout-and-rasterise
  pass that reads `src.width` / `src.height` (declared at line 177)
  to size its layout. NO NSWindow is involved on the streaming
  path. So updating `src.width`/`src.height` suffices.
- The `cocoa_input_adapter.nim:130-131` only logs `iekResize`
  (because it routes via the renderer's `fireEvent`); the actual
  resize handling is done by the editor launcher's resizingSink.
- **Conclusion:** Cocoa is fully resize-capable via the launcher's
  resizingSink (on macOS). No `isonim-cocoa` repo changes needed
  for VRS-M6 PROVIDED the milestone restricts itself to the
  offscreen streaming path. If VRS-M6 ever wants to drive a real
  NSWindow's `setFrame`, the AppKit hooks at
  `appkit/autolayout.nim:164-182` are available.

### 3.4 Android launcher

`/Users/zahary/metacraft/isonim-examples/editor/backends/android.nim`

Two modes:

**Mode A — `-d:mockJni` (in-process Android renderer tree)**
(lines 32-41, 177-237):

- Builds a real `AndroidRenderer` tree in-process.
- Frame source: `newAdbScreencapFrameSource(width=w, height=h)`
  at line 196 — but this captures from `adb screencap` (a REAL
  attached device, not the in-process mock tree).
- resizingSink at lines 205-214 mutates `dynamicW`/`dynamicH`/
  `src.width`/`src.height` — SAME pattern.
- StoryDispatchSink wraps at lines 233-235.

**Mode B — no `mockJni`** (lines 238-240):

- Just spawns `newAdbScreencapFrameSource(width=w, height=h)`
  without any input sink. **No resize handling at all** in this
  mode.

**Underlying app:**

- The android.nim launcher reads frames from a real device via
  `adb exec-out screencap`. The capture call at
  `editor/backends/android.nim:81-139` (`captureFrame`)
  **overrides `src.width` / `src.height` to the device's native
  framebuffer dimensions every frame** (lines 131-132).
- This means an `iekResize` event from the editor will get
  applied to `dynamicW`/`dynamicH`/`src.width`/`src.height` — but
  on the NEXT `captureFrame` call, those will be **overridden
  again** to the device's native dims. The screencap is whatever
  the device produces.

**Mobile devices typically have a fixed physical resolution.**
A Pixel 7's framebuffer is 1080×2400 portrait; an iPhone 14's is
1170×2532. The editor CANNOT genuinely resize the device's
display through the streaming protocol.

VRS-M7's spec acknowledges this explicitly:

> Mobile devices typically _do not_ resize — the target device
> has a fixed physical resolution, and the editor letterboxes the
> bitmap.

The audit confirms: **for Android, resize is meaningless on the
device side**. The right VRS-M7 contract is the "honest letterbox"
path from the spec — drop the resize-sink no-op for Android, and
ensure that the launcher is spawned with `--width`/`--height`
matching the current viewport pill at launch time (which the
spec brief flags as a separate concern).

Note: M-EVP-14's "no image stretching" rule
(`feedback_no_image_stretching.md` in memory) already mandates
the bitmap is displayed at intrinsic size with letterboxing in
the device-frame, so the editor side is already honest. The
audit's recommendation is to keep the existing resizingSink wiring
(it's harmless — the next captureFrame overrides) but document
the contract clearly.

### 3.5 iOS launcher (out-of-scope for this campaign per the spec

brief, but documented for completeness)

`/Users/zahary/metacraft/isonim-examples/editor/backends/ios.nim`

- All-macOS-only. Talks to a paired iPhone/iPad over TCP.
- Defaults: `DefaultWidth=390`, `DefaultHeight=844`
  (iPhone 14 portrait, lines 46-47).
- **NO resizingSink** (grep `iekResize`/`resizingSink` in the file
  returns only the `width*, height*` field declaration at line 98).
- iOS frames are read from the device's TCP stream (line 79
  onwards). Same situation as Android: the device dictates frame
  size.

VRS-M7's scope explicitly mentions Android only; iOS is similar
and probably wants the same "honest letterbox" treatment, but is
out of campaign scope for now.

### 3.6 Where does the launcher learn its initial dimensions?

`editor-server.mjs` is the entry that spawns launcher binaries.
The launcher receives `--width <N> --height <N>` via the CLI
parser at `common.nim:53-57`. The audit DID NOT exhaustively trace
how `editor-server.mjs` selects the initial `--width`/`--height`,
but the natural search points are:

- `/Users/zahary/metacraft/isonim-examples/tools/editor-server.mjs`
- The `just` recipes (`isonim-examples/Justfile`) that the user
  invokes to start the editor.

VRS-M7's "honest letterbox" branch (or the spec's parenthetical
"DO honor the initial viewport selection at launch time") requires
that the spawn command include the current viewport pill's
dimensions. The audit flags this as something VRS-M7 must
investigate further during implementation — the editor-server
spawning code is the lookup-table that needs auditing.

---

## Section 4 — Editor display chain (canvas CSS + iframe path)

### 4.1 `applyCanvasFitStyle` — no-stretch CSS rule

`/Users/zahary/metacraft/isonim/src/isonim/editor/views/canvas_mount.nim:192-263`

When `active=true`:

- wrapper: `display:flex`, `align-items:center`, `justify-content:
center`, `overflow:hidden`, `background-color:#0a101e`,
  `border:1px solid #303244`, `border-radius:6px`,
  `box-shadow:...` (lines 224-235).
- canvas: `display:block`, `width:auto`, `height:auto`,
  `object-fit:""`, `flex-shrink:0`,
  `image-rendering:pixelated` (lines 236-249).
  **`width:auto`/`height:auto` means the canvas renders at its
  intrinsic pixel size** — the size set by `canvas.width` /
  `canvas.height` HTML attributes. **There is no CSS scaling.**
  The wrapper letterboxes/crops via flex centering.

When `active=false`:

- wrapper: `display:none`, all the styles cleared (lines 251-262).

This is the **no-stretch rule**: the canvas is locked to the
launcher-emitted bitmap dimensions. The deviceFrame's
`width`/`height` are set separately by
`page_preview.nim:199-202` based on `viewport.val`:

```
r.setStyle(deviceFrame, "width", $width & "px")
r.setStyle(deviceFrame, "height", $height & "px")
r.setStyle(deviceFrame, "min-width", $width & "px")
r.setStyle(deviceFrame, "min-height", $height & "px")
```

But when `useCanvas` is true, the deviceFrame is HIDDEN:

```
r.setStyle(deviceFrame, "display", if useCanvas: "none" else: "flex")
r.setStyle(canvasPaneEl, "display", if useCanvas: "flex" else: "none")
```

(`page_preview.nim:213-214`). So the deviceFrame's CSS sizing
only affects the Web backend's iframe path. The canvas's
rendered size is purely the bitmap's intrinsic size.

### 4.2 Bitmap intrinsic size source-of-truth

The canvas's `width` / `height` HTML attributes are updated by the
JS shim's `ensureSize(width, height)` function at
`streaming_preview.nim:953-958`:

```js
function ensureSize(width, height) {
  if (canvas.width !== width || canvas.height !== height) {
    canvas.width = width;
    canvas.height = height;
  }
}
```

`ensureSize` is invoked from:

- `handleF`: every F packet payload header (`streaming_preview.nim
:966-970`).
- `handleM`'s `hello` branch: `:1014-1015`
  (uses `initialSize.{width,height}`).
- `handleM`'s `resize` branch: `:1016-1017`
  (uses `width`,`height` from the M payload).

This is the **cleanest invariant**: the canvas's intrinsic dims
always equal whatever the launcher last emitted. So when the
launcher's resizingSink mutates `src.width`/`src.height`, the next
F packet brings the new dims, `ensureSize` fires, and the canvas
intrinsic resizes. The overlay scaler (Section 5) then
auto-adjusts because it reads `canvas.width` live.

### 4.3 Letterbox vs stretch — confirmed letterbox

Per the inline comment at `canvas_mount.nim:194-212`:

> No-stretch rule: when the canvas is the active surface, we
> render it at its **intrinsic pixel size** (no CSS scaling). The
> wrapper becomes a flex container that centers the canvas; if
> the canvas is smaller than the pane, the wrapper letterboxes
> the surround with its `#0a101e` background. If the canvas is
> larger than the pane, `overflow: hidden` crops it centered.

This contract is **exactly what the user wants**: pixel-perfect
1:1 rendering with no upscaling. The pre-existing user complaint
("pixelated frames") is caused entirely by the launcher's
`AnyFrameSource.width`/`height` being frozen at 640×480 or
800×600 — whatever the launcher was spawned at — so the F packet
emits a tiny bitmap that letterboxes inside a much larger
viewport-pane and reads as "pixelated" relative to the chosen
viewport pill. Once VRS-M2 wires the resize sender end-to-end and
the launcher's resizingSink fires, `src.width`/`.height` update,
the next F packet carries the new dims, `ensureSize` reseeds the
canvas, and the pixel-perfect path is hit.

### 4.4 deviceFrame CSS (Web backend path only)

For completeness: the deviceFrame's CSS sizing per pill at
`page_preview.nim:199-207` is used ONLY when `useCanvas=false`
(i.e. the Web backend's iframe path). The iframe path sets
`<iframe srcdoc>` to the rendered HTML and lets the iframe lay
itself out inside the deviceFrame's pixel-sized box. No streaming
canvas involved.

This means the **device-frame chrome (rounded corners,
borders for phone-shaped viewports, etc.) is currently visible
ONLY for the Web backend.** Non-Web backends use the canvas pane
which is just a centered flex container with a hairline border —
no phone-shaped chrome. This is a deliberate decision (the
inline note at `page_preview.nim:86-96` explicitly explains that
the device frame is sized to the user's viewport pill which for
TUI is 80×24 cells, making a 640×288 surface look like a thin
strip inside the device frame).

If the campaign ever wants phone-shaped chrome for non-Web
backends, that's a separate UI-polish milestone — outside VRS
scope.

---

## Section 5 — Bounding-box overlay scaler verification

### 5.1 The scaler at line 383

`/Users/zahary/metacraft/isonim/src/isonim/editor/views/canvas_mount.nim`

The spec specifically calls out `canvas_mount.nim:383`. That line
is the `else if` branch that runs when **not** in cell mode
(i.e. for the pixel-coord F/M/I path used by every non-TUI
backend). The fragment:

```
} else if (c && lbl && c.width > 0 && c.height > 0) {
  var sx = c.clientWidth / c.width;
  var sy = c.clientHeight / c.height;
  var leftPx = (""", bx, """ + """, bw, """) * sx;
  var topPx = """, by, """ * sy;
  lbl.style.left = leftPx + 'px';
  lbl.style.top = topPx + 'px';
}
```

- `c.width` / `c.height` are the canvas's **intrinsic pixel
  dimensions** (the HTML attributes — i.e. the size emitted by
  the launcher's F packet).
- `c.clientWidth` / `c.clientHeight` are the canvas's **rendered
  CSS dimensions**.
- `sx` / `sy` is the ratio CSS / intrinsic — i.e. exactly the
  scale factor mapping bitmap-space to CSS-space.

**Verification:** under the no-stretch CSS rule
(`canvas_mount.nim:241-248` sets `width:auto, height:auto` on the
canvas), `clientWidth` should equal `c.width` in CSS pixels,
giving `sx = sy = 1`. Bounds are then placed in 1:1 correspondence
with bitmap pixels — which IS what the comment claims and what
the user expects.

If a downstream CSS rule ever forces the canvas to scale (e.g.
re-introduces `width:100%`), `sx`/`sy` ≠ 1, and the scaler
compensates: the overlay still lands on the right element
_relative to whatever scaling the browser applied_. So the math
is correct in principle — it follows the bitmap, not the
viewport pill.

But the math is correct only **if the launcher's bitmap
dimensions match what the user expects**. Today they don't (the
launcher is frozen at 640×480 / 800×600), so the overlay lands
on the right element _of the rendered bitmap_, which is in turn
showing whatever the launcher rendered at its launch-time size.
The user expects boxes that land on the elements _as visually
rendered at the chosen viewport_. The pixel positions match the
bitmap, but the bitmap content is wrong (smaller/different
layout than the viewport pill suggests).

**Conclusion:** the scaler at `canvas_mount.nim:383` is
**correct in principle**. VRS-M8 is therefore a **verification
milestone**: assert empirically that for every (backend × viewport)
combination, the overlay rect matches the visually-rendered
element to within 1 px AFTER VRS-M4..M7 close the resize loop. No
scaler fix is anticipated; if VRS-M8 finds a drift, the bug lives
in VRS-M4..M7's launcher-side handling, not in the scaler.

### 5.2 Other overlay coord branches (related code paths)

The same `sx = c.clientWidth / c.width` pattern is replicated at:

- `:382-389` — hover-label positioning (pixel-coord path).
- `:462-469` — selection-outline positioning (pixel-coord path).
- `:509-513`, `:514-531` — edit-mode handle positioning (pixel-coord
  path).

And cell-coord equivalents (for the TUI backend) at:

- `:364-381` — hover-label.
- `:446-461` — selection outline.
- `:496-508` — handles.

The cell-coord branches use `hostRect.width / cols` and
`hostRect.height / rows` to compute cell pixel size. These are
not affected by the campaign (the TUI backend's bitmap is
naturally locked to cell dims), and VRS-M8 should keep them
green as a regression-safety check.

---

## Section 6 — VRS-M2..M7 plan summary (consume verbatim)

This section is what VRS-M2 reads as its starting brief. Every
citation here is grounded in the previous sections.

### 6.1 VRS-M2 — Editor sends resize message on viewport change

**Files to edit:**

1. **`/Users/zahary/metacraft/isonim/src/isonim/editor/streaming_preview.nim`**

   Add three things mirroring the existing `select-story` /
   `apply-mutation` patterns (lines 753-790, 1152-1208):
   - A hand-rolled deterministic JSON encoder
     `encodeResizeBody*(width, height: int): string` that emits
     `{"type":"resize","width":<W>,"height":<H>}`. Place next to
     `encodeSelectStoryBody*` at line 753.
   - A JS-side `sendResize*(handle: BridgeClientHandle; width,
height: int)` proc that emits a small JS shim writing an I
     packet over `handle.socket`. Mirror `sendSelectStory*` at
     line 1152-1180.
   - A view-layer `publishResize*(vm: StreamingPreviewVM; width,
height: int)` proc next to `publishSelectStory*` at line
     478-485, that delegates to a registered closure.
   - Extend `StoryPublisher` (line 162-173) with a
     `sendResizeFn*: proc(width, height: int) {.closure.}` field.
     Update `setStoryPublisher*` (line 457-471) to accept and store
     the new closure (and `clearStoryPublisher*` to clear it).

2. **`/Users/zahary/metacraft/isonim/src/isonim/editor/views/canvas_mount.nim`**
   - Update `installStoryPublisher` at lines 597-628 to also install
     a `sendResize` closure that calls `sendResize(b.handle, w, h)`
     (and the TUI variant via `b.tuiHandle` if relevant — but TUI
     normally doesn't honour resize per Section 3, so TUI's path
     can be a no-op).
   - Inside `attachIfNeeded` at line 697-788, after a successful
     attach (after the `onOpen` fires `sendCurrentStory`), trigger
     an initial `publishResize` so the freshly-opened bridge learns
     the current viewport pill's dimensions.

3. **`/Users/zahary/metacraft/isonim/src/isonim/editor/views/page_preview.nim`**

   In the existing render effect at lines 172-241, ADD a
   `publishResize` call. The effect already reads
   `vm.viewport.val`, `vm.platform.val`, derives `width`/`height`,
   so the new call is one line:

   ```
   if vm.platform.val != pbWeb and vm.streamingPreview != nil:
     publishResize(vm.streamingPreview, width, height)
   ```

   Place it next to `pageBridgeBinding.attachIfNeeded(...)` at
   line 240.

   Mirror the same edit in `component_detail.nim` (line 938 area)
   and `foundations_page.nim` (line 183 area) so every view that
   mounts a canvas also publishes resizes.

**Tests:**

- Headless Nim unit test: install a stub `sendResize` closure on a
  `StoryPublisher`, fire `publishResize`, assert the captured
  (w, h) pair.
- Browser test (`tests/browser/e2e_editor_viewport_resize_send_live.mjs`):
  spin up a tiny Node-side mock WS launcher that decodes I packets,
  drive a viewport pill click in the editor, assert the launcher
  received `{type:"resize", width:W, height:H}` with the expected
  dims (e.g. iPhone pill → 375×667).

  Look at existing helper patterns in
  `/Users/zahary/metacraft/isonim/tests/browser/helpers/` for the
  shape of a Node-side mock; the current helper
  `spawn_pg_for_browser_test.nim` is the closest existing test
  scaffold, though it's not a WS mock launcher — VRS-M2 may need
  to extend with a new `helpers/mock_launcher.mjs` that listens
  on a chosen bridge port and records inbound I-packets.

- No new `setStyle` outside `createRenderEffect` (gate
  `test_no_setstyle_outside_render_effects.nim` must stay green).
  The new `publishResize` call IS inside an existing
  `createRenderEffect`, so no new setStyle issue.

### 6.2 VRS-M3 — `isonim-render-serve` resize dispatch

**Verdict: NEARLY NO-OP.** The dispatch already works:

- `decodeInputEvent` at `event_dispatch.nim:163-169` already decodes
  `{type:"resize", width, height}` into `InputEvent(kind:iekResize,
width, height)`.
- The bridge at `bridge.nim:345-361` already routes I packets to
  `cfg.inputSink.submit(ev)`.
- The `StoryDispatchSink` already forwards `iekResize` to its
  `inner` sink at `story_dispatch.nim:81-83`.

VRS-M3's actual deliverable should therefore be **documentation +
a new round-trip unit test** that asserts: "feed an `I` packet
containing `{type:"resize", width:1920, height:1080}` →
`StoryDispatchSink.inner` receives `InputEvent(kind:iekResize,
width:1920, height:1080)`." There may already be such a test —
`/Users/zahary/metacraft/isonim-render-serve/tests/
test_bridge_input_roundtrip.nim:79,103` exercises it, but VRS-M3
should pin a freshly-named test (`test_input_resize_dispatch.nim`
per the spec brief) AND verify the launcher-side resizingSink
mutates the AnyFrameSource correctly.

**Recommendation:** also patch each launcher's resizingSink to
update the **AnyFrameSource wrapper's** width/height fields (not
just the underlying `src.width`/`src.height`) — see Section 2.4
on the latent inconsistency. One-line addition in each of
`gpui.nim`, `freya.nim`, `cocoa.nim`, `android.nim`:

```
src.toAny()  # the AnyFrameSource handle — keep a binding
# inside the resizingSink closure, after src.width = ...:
anyHandle.width = event.width
anyHandle.height = event.height
```

But this is OPTIONAL — only matters if the bridge ever re-emits
hello, which it currently does not. VRS-M3 can skip and document
the gap as a follow-up.

**Optional but recommended:** add a `sendResizeMeta(client, w, h)`
helper that the launcher's resizingSink fires after mutating
`dynamicW`/`dynamicH`, emitting an outbound `M` packet of
`{type:"resize", width, height}`. The browser already decodes this
(`streaming_preview.nim:1016-1017`) and reseeds `canvas.width`
immediately. Without it, the canvas reseeds one frame later (on
the next F packet). One frame ≈ 50 ms is fine but the explicit
echo is cleaner and easier to debug.

### 6.3 VRS-M4 — GPUI launcher honors resize

**Verdict: ALREADY WORKS.** Per Section 3.1 the GPUI launcher's
resizingSink at `editor/backends/gpui.nim:73-82` is the resize
hook; the headless adapter's `gpui_render_to_pixels(w, h)` call
sees the new dims on the next frame.

VRS-M4's deliverable is therefore primarily the **end-to-end test**
that proves the whole chain works:

- `tests/browser/e2e_editor_viewport_resize_gpui_live.mjs` (live):
  spawn the real GPUI launcher (per editor-server.mjs), open the
  editor, click iPhone pill, assert (a) the canvas's intrinsic
  `canvas.width === 375` within 500 ms, (b) the next F packet's
  width matches, (c) the overlay scaler still maps correctly. Use
  the existing frame-readback path (per memory
  `project_ev_m8_status` for iOS — the same pattern applies to
  GPUI's canvas via `canvas.toDataURL` or similar).

If the test fails, the bug is most likely in the
editor-server.mjs spawning recipe (the launcher's initial
dimensions, or some race where the resize lands before the
bridge is open). VRS-M4 can also OPTIONALLY add the
`sendResizeMeta` upstream echo from §6.2.

### 6.4 VRS-M5 — Freya launcher honors resize

**Verdict: ALREADY WORKS.** Per Section 3.2 the Freya launcher
already has the same resizingSink pattern at
`editor/backends/freya.nim:69-78`.

VRS-M5 deliverable: same test shape as VRS-M4 but for Freya
(`e2e_editor_viewport_resize_freya_live.mjs`). No app code
changes anticipated; if the test fails, investigate.

### 6.5 VRS-M6 — Cocoa launcher honors resize

**Verdict: ALREADY WORKS ON macOS.** Section 3.3 confirms the
Cocoa launcher's resizingSink mirrors the others. The
streaming path uses offscreen rasterisation, NOT a real NSWindow,
so no `setFrame` call is needed.

VRS-M6 deliverable: `e2e_editor_viewport_resize_cocoa_live.mjs`.
macOS-only (Linux test should `test.skip` per the spec). If
future work wants to drive a real NSWindow, the helpers at
`isonim-cocoa/src/isonim_cocoa/appkit/autolayout.nim:164-182`
(`setFrameSize`, `setFrame`) are already wrapped.

### 6.6 VRS-M7 — Android launcher: honest letterbox path

**Verdict: HONEST LETTERBOX is the right path.** Per Section 3.4
the Android launcher reads frames from `adb screencap`; the
device's framebuffer dimensions are fixed by the physical
display. Any `iekResize` arriving at the launcher would mutate
`src.width`/`.height` but `captureFrame` at
`editor/backends/android.nim:131-132` immediately overrides them
with the device's native dims.

VRS-M7's deliverable:

- Document the contract: "Android backend does NOT honour
  mid-session resize. The device framebuffer is the canonical
  bitmap size; the editor's canvas-mount letterboxes that
  bitmap inside the pane. Resize-on-pill-click is a no-op on
  Android."
- Verify the initial `--width`/`--height` at launcher spawn time
  IS derived from the current viewport pill (not a hard-coded
  default). Look at the editor-server.mjs spawning command at
  `isonim-examples/tools/editor-server.mjs` (the audit did not
  exhaustively read this — VRS-M7 must investigate).
- E2E test `e2e_editor_viewport_resize_android_live.mjs` asserts:
  (a) clicking a different viewport pill does NOT change the
  device-emitted bitmap dims (legitimate — the device doesn't
  resize), (b) the canvas displays the bitmap at 1:1 with
  letterboxing in the pane, (c) overlay coords map correctly.

iOS is similar (Section 3.5) but out-of-scope for the campaign.

### 6.7 VRS-M8 — overlay coord matrix verification

Per Section 5 the scaler at `canvas_mount.nim:383` is correct in
principle. VRS-M8 is a verification milestone:

- Add `e2e_editor_overlay_coords_matrix_live.mjs` that for each
  (backend × viewport) combination:
  1. switches to backend; 2. clicks viewport pill; 3. waits for
     the launcher to emit a fresh `element-tree`; 4. picks a known
     element by componentPath; 5. hovers; 6. asserts overlay
     outline's `getBoundingClientRect()` matches the element's
     rendered rect to within 1 px.

If any combination fails, the bug is most likely in the relevant
launcher's resize-handling path (re-open VRS-M4..M7).

### 6.8 Out-of-scope / follow-ups

- **Editor-server.mjs initial-dims spawn audit** — VRS-M7
  investigation will surface whether `--width`/`--height` reflect
  the current viewport pill at launcher spawn time. May need a
  separate sub-task.
- **`AnyFrameSource.width`/`.height` wrapper drift** — Section 2.4.
  Cosmetic today; tighten in VRS-M3 if convenient.
- **Outbound `resize` M packet from the launcher** — Section 2.3.
  Currently the canvas reseeds from the next F frame's intrinsic
  dims (the path the spec acknowledges). Adding an explicit
  upstream `resize` M cuts the lag by ≤ 50 ms (one frame). Worth
  doing in VRS-M3 alongside the sendResizeMeta helper.
- **iOS resize/honest-letterbox milestone** — symmetric with VRS-M7
  Android but explicitly out-of-scope for this campaign. Add as a
  future milestone if needed.
- **Device-shaped phone chrome for non-Web backends** — Section 4.4.
  Out of campaign scope. The canvas pane is just a centered flex
  container with a hairline border; phone-shaped chrome only paints
  on the Web iframe path today.

---

## Appendix A — Gaps and uncertainties (honest "I could not find X")

1. **`editor-server.mjs` launcher-spawn command line** — VRS-M1 did
   not exhaustively read `isonim-examples/tools/editor-server.mjs`
   beyond confirming it proxies `/bridge/<backend>` to localhost
   ports (lines 194-267). The actual launcher-spawn command lines
   (the `--width N --height N` initial args) almost certainly live
   in the `just` recipes (`isonim-examples/Justfile`) or in a
   helper script invoked by the user before opening the editor.
   VRS-M7's audit branch should grep `--width\|--height\|gpui\|freya`
   under `isonim-examples/Justfile`, `isonim-examples/scripts/`, and
   neighbouring tools to confirm the initial-dims source.

2. **Whether the editor-server starts launchers itself OR expects
   them already running** — From the file header (lines 1-50)
   `editor-server.mjs` only proxies; it does not appear to spawn
   launchers. That suggests the user (or a `just` recipe) spawns
   them separately. If true, the VRS-M7 "honor initial viewport
   pill at spawn time" branch needs a richer change — the editor
   may need to ASK the user to relaunch the launcher whenever the
   viewport changes (or, more usefully, just send a `resize` I
   packet which the launcher already honours — making the
   initial-dims question moot for software backends, and only
   relevant for Android where it can't honour resize).

3. **Whether the `iekResize` chain currently propagates all the way
   through `StoryDispatchSink → resizingSink → AnyFrameSource →
renderFrame()`** is verified by code-reading but NOT empirically
   tested end-to-end today. The existing `tests/
test_bridge_input_roundtrip.nim:79,103` only checks
   InputEventKind decode + `BufferedInputSink` capture. There's no
   existing test that takes an I-packet resize, runs it through the
   `StoryDispatchSink`-wrapped `resizingSink`, calls `renderFrame`,
   and asserts the F frame's width/height match. VRS-M3 should add
   this.

4. **What viewport pills exist per backend** — `viewmodels.nim:911-914`
   shows `pbTui` has only `pvkCustom` (i.e. 80×24 cells); the other
   backends have desktop/laptop/wide/ultrawide etc., and the
   `phone-` variants for some. VRS-M2 must short-circuit when the
   current backend doesn't surface useful resize semantics (TUI
   already does its own size negotiation via cell counts; the
   resize sender should probably no-op for `pbTui`).

5. **Whether the canvas's intrinsic-size CSS rule
   (`width:auto, height:auto`) actually renders at 1 CSS px per
   bitmap px in all browsers** — visual verification done by prior
   milestones (M-EVP-14 Wave AB note inside
   `editor/backends/android.nim:110-128` references the
   no-stretch contract from `feedback_no_image_stretching.md`), but
   VRS-M9's pixel-perfect matrix test is the empirical gate.

---

## Appendix B — Key file index (jump table)

### Editor side

- `/Users/zahary/metacraft/isonim/src/isonim/editor/viewmodels.nim:928-943`
  viewport width/height/eq helpers.
- `/Users/zahary/metacraft/isonim/src/isonim/editor/viewmodels.nim:2515-2537`
  `changePlatform` / `changeViewport`.
- `/Users/zahary/metacraft/isonim/src/isonim/editor/views/shell.nim:306-316`
  `platformHandler` / `viewportSelectHandler`.
- `/Users/zahary/metacraft/isonim/src/isonim/editor/views/shell.nim:3150-3270`
  viewport pill strip + dropdown construction.
- `/Users/zahary/metacraft/isonim/src/isonim/editor/views/page_preview.nim:172-241`
  page-preview render effect with the deviceFrame + canvas attach.
- `/Users/zahary/metacraft/isonim/src/isonim/editor/views/canvas_mount.nim:192-263`
  `applyCanvasFitStyle` (no-stretch CSS).
- `/Users/zahary/metacraft/isonim/src/isonim/editor/views/canvas_mount.nim:265-548`
  `bindCanvasOverlayEffect` (overlay scaler).
- `/Users/zahary/metacraft/isonim/src/isonim/editor/views/canvas_mount.nim:382-389`
  the spec-cited `sx = c.clientWidth / c.width` hover-label scaler.
- `/Users/zahary/metacraft/isonim/src/isonim/editor/views/canvas_mount.nim:550-789`
  `BridgeBinding` + `attachIfNeeded`.
- `/Users/zahary/metacraft/isonim/src/isonim/editor/streaming_preview.nim:162-173`
  `StoryPublisher` (add `sendResizeFn` here in VRS-M2).
- `/Users/zahary/metacraft/isonim/src/isonim/editor/streaming_preview.nim:457-497`
  `setStoryPublisher` / `clearStoryPublisher` / `publishSelectStory`
  / `publishApplyMutation` (pattern to copy for `publishResize`).
- `/Users/zahary/metacraft/isonim/src/isonim/editor/streaming_preview.nim:641-657`
  `bridgePortForBackend`.
- `/Users/zahary/metacraft/isonim/src/isonim/editor/streaming_preview.nim:753-790`
  `encodeSelectStoryBody*` / `encodeApplyMutationBody*` (pattern to
  copy for `encodeResizeBody*`).
- `/Users/zahary/metacraft/isonim/src/isonim/editor/streaming_preview.nim:953-1023`
  JS shim `handleF` / `handleM` (including the `resize` M handler at
  1016-1017 and `ensureSize` at 953-958).
- `/Users/zahary/metacraft/isonim/src/isonim/editor/streaming_preview.nim:1040-1056`
  JS shim `encodeI` + `sendInput` (the pattern `sendResize` mirrors).
- `/Users/zahary/metacraft/isonim/src/isonim/editor/streaming_preview.nim:1152-1208`
  Nim-side `sendSelectStory*` / `sendApplyMutation*` (the pattern
  `sendResize*` mirrors).

### Transport

- `/Users/zahary/metacraft/isonim-render-serve/src/isonim_render_serve/event_dispatch.nim:14-46`
  `InputEventKind` + `InputEvent` variant (including `iekResize`).
- `/Users/zahary/metacraft/isonim-render-serve/src/isonim_render_serve/event_dispatch.nim:116-226`
  `decodeInputEvent*` (incl. `iekResize` decode at :163-169).
- `/Users/zahary/metacraft/isonim-render-serve/src/isonim_render_serve/event_dispatch.nim:248-298`
  `encodeInputEvent*` (incl. `iekResize` encode at :274-277).
- `/Users/zahary/metacraft/isonim-render-serve/src/isonim_render_serve/frame_source.nim:40-89`
  `AnyFrameSource` definition + constructors.
- `/Users/zahary/metacraft/isonim-render-serve/src/isonim_render_serve/bridge.nim:128-155`
  `buildHelloJson*`.
- `/Users/zahary/metacraft/isonim-render-serve/src/isonim_render_serve/bridge.nim:240-302`
  `buildOutgoingFrame` + `frameLoop` (resize handling: invalidates
  the diff cache on size change at :255-259).
- `/Users/zahary/metacraft/isonim-render-serve/src/isonim_render_serve/bridge.nim:303-374`
  `handleInbound` (the I-packet decode + dispatch to `inputSink`).
- `/Users/zahary/metacraft/isonim-render-serve/src/isonim_render_serve/story_dispatch.nim:54-83`
  `StoryDispatchSink.submit` (delegates non-story events incl.
  `iekResize` to `inner`).
- `/Users/zahary/metacraft/isonim-render-serve/static/index.html:262-264`
  Reference HTML's `window.addEventListener('resize', …)` that emits
  an `iekResize` (already works for the standalone reference page;
  the editor JS shim needs the same).

### Per-backend launchers

- `/Users/zahary/metacraft/isonim-examples/editor/backends/common.nim:23-119`
  `LauncherConfig` + `parseLauncherArgs` + `runDemoBridgeWith`.
- `/Users/zahary/metacraft/isonim-examples/editor/backends/gpui.nim:34-111`
  GPUI launcher. resizingSink at lines 73-82.
- `/Users/zahary/metacraft/isonim-examples/editor/backends/freya.nim:30-107`
  Freya launcher. resizingSink at lines 69-78.
- `/Users/zahary/metacraft/isonim-examples/editor/backends/cocoa.nim:14-107`
  Cocoa launcher (macOS-only). resizingSink at lines 67-76.
- `/Users/zahary/metacraft/isonim-examples/editor/backends/android.nim:24-247`
  Android launcher. resizingSink at lines 205-214 (mockJni only).
  `captureFrame` overrides `src.width`/`.height` at :131-132.
- `/Users/zahary/metacraft/isonim-examples/editor/backends/ios.nim:38-…`
  iOS launcher. NO resizingSink (out of campaign scope but worth
  flagging).

### Underlying apps

- `/Users/zahary/metacraft/isonim-gpui/src/isonim_gpui/window.nim:115-156`
  GPUI window create/resize-callback (no setSize setter; doesn't
  matter for headless render path).
- `/Users/zahary/metacraft/isonim-gpui/rust/gpui-nim-shim/src/window.rs:167`
  Rust shim's `window_size(id)` (getter only).
- `/Users/zahary/metacraft/isonim-render-serve/src/isonim_render_serve/adapters/gpui_adapter.nim:205-274`
  GPUI adapter `renderFrame` + `renderHeadlessFrame`. Reads
  `src.width`/`.height` each tick.
- `/Users/zahary/metacraft/isonim-freya/src/isonim_freya/window.nim:14, 153-156`
  Freya `onResize` callback (no setSize setter; doesn't matter for
  headless render path).
- `/Users/zahary/metacraft/isonim-render-serve/src/isonim_render_serve/adapters/freya_adapter.nim:280-345`
  Freya adapter `renderFrame` + `renderHeadlessFrame`.
- `/Users/zahary/metacraft/isonim-cocoa/src/isonim_cocoa/appkit/autolayout.nim:164-182`
  Cocoa `setFrameSize` / `setFrame` (NOT used by the headless
  streaming path, but available if VRS-M6 ever needs them).
- `/Users/zahary/metacraft/isonim-render-serve/src/isonim_render_serve/adapters/cocoa_adapter.nim:177-705`
  Cocoa adapter `renderFrame` (offscreen layout-and-rasterise).
- `/Users/zahary/metacraft/isonim-render-serve/src/isonim_render_serve/adapters/android_adapter.nim:268-422`
  Android adapter; uses adb screencap, NOT a render-to-dims path.

### Per-backend input adapters (currently no-op for resize)

- `/Users/zahary/metacraft/isonim-render-serve/src/isonim_render_serve/adapters/gpui_input_adapter.nim:86-87`
  `iekResize` only logs.
- `/Users/zahary/metacraft/isonim-render-serve/src/isonim_render_serve/adapters/freya_input_adapter.nim:96-97`
  `iekResize` only logs.
- `/Users/zahary/metacraft/isonim-render-serve/src/isonim_render_serve/adapters/cocoa_input_adapter.nim:130-131`
  `iekResize` only logs.
- `/Users/zahary/metacraft/isonim-render-serve/src/isonim_render_serve/adapters/android_input_adapter.nim:165-166`
  `iekResize` only logs.

The "real" resize handling lives in the launcher's `resizingSink`
(not in these adapters); these adapters route mouse/click into
the renderer's `fireEvent` for in-process event dispatch.

### Existing tests of interest

- `/Users/zahary/metacraft/isonim-render-serve/tests/test_packet_codec_roundtrip.nim:130, 151`
  encode/decode resize round-trip.
- `/Users/zahary/metacraft/isonim-render-serve/tests/test_bridge_input_roundtrip.nim:79, 103`
  `iekResize` round-trip through bridge + sink.
- `/Users/zahary/metacraft/isonim-render-serve/tests/test_story_dispatch_sink.nim:111, 138, 142, 148`
  `StoryDispatchSink` forwards `iekResize` to inner.

---

End of audit.
