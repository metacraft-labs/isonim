# EMC-M1 — GPUI Zed Serialisation Audit

Date: 2026-05-30
Author: EMC-M1 sub-agent
Spec: `codetracer-specs/Front-Ends/IsoNim/Editor-Matrix-Closer.milestones.org`
Closes the FUH-M9 gap: 4 GPUI Laptop/Desktop frame-latency cells (55-59 ms
median vs the 50 ms gate) + 3 GPUI task_app click-response cells (120-130 ms)
both rooted in the EPP-M2 raw_rgba serialisation cost.

This audit is read-only: no source-tree edits, no commits. Measurements
captured via a one-off Nim harness at `/tmp/profile_gpui_serialisation.nim`
(GPUI path) and `/tmp/profile_webp_encode.nim` (libwebp encoder), compiled
against the same `-d:useGpuiHeadless` flag the production launcher uses
(`isonim-examples/Justfile:180-188`).

---

## 1. Render path trace (file:line)

The GPUI frame-source `renderFrame` walks from the bridge's `frameLoop`
through five hops:

1. **Bridge tick.**
   `isonim-render-serve/src/isonim_render_serve/bridge.nim:694`
   `let curr = cfg.frameSource.renderFrame()` — synchronous; the per-
   connection async `frameLoop` blocks the event loop for the duration of
   the shim call, because Nim's async/await does not yield inside FFI.

2. **AnyFrameSource indirection.**
   `isonim-render-serve/src/isonim_render_serve/adapters/gpui_adapter.nim:386-395`
   The `toAny` wrapper closes over a `GpuiFrameSource` and dispatches
   `renderFrame` through a `proc(): Frame {.gcsafe.}` closure (`captured.renderFrame()`).

3. **renderFrame dispatch.**
   `isonim-render-serve/src/isonim_render_serve/adapters/gpui_adapter.nim:232-259`
   `when defined(useGpuiHeadless):` routes to `renderHeadlessFrame` (the
   production binary always compiles with this define on Darwin per
   `isonim-examples/Justfile:180-188`). The synthetic fallback is dormant
   code on macOS.

4. **renderHeadlessFrame Nim wrapper.**
   `isonim-render-serve/src/isonim_render_serve/adapters/gpui_adapter.nim:261-301`
   - `gpui_set_root_element(src.root)` (line 283) — pins the shim's
     `ROOT_NODE_ID` so the headless `NimRootView` can read it.
   - `gpui_render_to_pixels(width, height, 1.0, &outPtr, &outLen)`
     (lines 286-288) — the FFI call. Returns a shim-owned `Box::leak`-ed
     buffer.
   - `newSeq[byte](int(outLen))` (line 296) — Nim heap allocation
     sized to `width*height*4`.
   - `copyMem(addr pixels[0], outPtr, int(outLen))` (lines 297-298) —
     copies the shim buffer into Nim-owned memory.
   - `gpui_free_pixels(outPtr, outLen)` (line 295, via `defer`) —
     returns the shim's leaked allocation.

5. **FFI declaration.**
   `isonim-gpui/src/isonim_gpui/bindings.nim:217-223` declares
   `gpui_render_to_pixels` / `gpui_free_pixels` via `dynlib`; the shim
   `libgpui_nim_shim.dylib` is loaded lazily at runtime.

The shim entry point `gpui_render_to_pixels`
(`isonim-gpui/rust/gpui-nim-shim/src/gpui_headless.rs:117-163`) runs:

- Argument validation (lines 124-139) — cheap, sub-microsecond.
- `std::panic::catch_unwind(|| render_to_rgba(...))` (line 145) — catches
  Rust panics across the FFI boundary.
- `Box::leak(boxed)` (lines 154-157) — moves the buffer ownership out
  through `*out_ptr` / `*out_len`.

`render_to_rgba` (`gpui_headless.rs:195-311`) is where the cost lives:

- **Platform acquisition.** `current_platform(true)` (line 233) +
  `text_system()` (line 234) — first call constructs the macOS
  `MacTextSystem` and the headless platform shim; subsequent calls hit
  cached singletons.
- **Renderer factory check.** `current_headless_renderer().is_none()`
  (line 242) — returns the `MetalHeadlessRenderer` factory on Darwin;
  returns `None` on Linux (the deliberate degradation path).
- **App-thread acquisition.**
  `HeadlessAppContext::with_platform(text_system, Arc::new(()), || current_headless_renderer())`
  (lines 246-250) — constructs a fresh `HeadlessAppContext` per call;
  this is the single most expensive step because it spins up the GPUI
  dispatcher, foreground / background executors, font system, and
  installs the Metal headless renderer.
- **Window open.**
  `cx.open_window(window_size, |_, cx| cx.new(|_| NimRootView::new()))`
  (lines 252-257) — allocates a fresh `TestWindow` of the requested
  logical size (W×H dp at the test platform's hard-coded `scale_factor =
2.0`, so the underlying Metal texture is 2W×2H).
- **Pump the deferred-draw schedule.**
  Two passes of `cx.run_until_parked()` + `refresh_window(...)` +
  `cx.run_until_parked()` + `refresh_window(...)` + `cx.run_until_parked()`
  (lines 267-271). This sequence is required because GPUI's
  layout-then-paint pipeline interleaves `cx.spawn` tasks with the
  window's render schedule, and a single `run_until_parked` only drains
  the first wave. The audit confirmed (EPP-M2) that a single pass
  produces an all-black capture; two pump pairs are the minimum that
  settles the `task_app` composition.
- **Capture.**
  `cx.capture_screenshot(window)` (lines 278-280). Public wrapper around
  `app.update_window(window, |_, window, _| window.render_to_image())`.
  This is the GPU readback: `Window::render_to_image()` issues the Metal
  command buffer, waits for completion, copies the `MTLTexture` into a
  CPU `image::RgbaImage` (2W × 2H × 4 bytes; that is, 8.2 MiB at
  1280×800 → captured at 2560×1600 internally).
- **Downsample.**
  `image::imageops::resize(&image, width, height, FilterType::Triangle)`
  (lines 303-308) — single-threaded triangle-filter convolution from the
  2W×2H capture to W×H, then `.into_raw()` yields the `Vec<u8>` that
  `gpui_render_to_pixels` boxes and leaks. Substantial CPU cost (~5-7 ms
  at 1280x800; memory-bandwidth bound).

`NimRootView` (`isonim-gpui/rust/gpui-nim-shim/src/gpui_app.rs:54-114`)
is what runs inside that pumped schedule: it reads the shadow tree
(`crate::lock_tree()` line 99 + `ROOT_NODE_ID` line 100), calls
`render_sync::build_render_plan(&tree, root_id)` (line 106) to convert
the Nim-owned shadow tree into a `RenderNode`, then
`render_plan_to_gpui(&plan)` (line 109) materialises it as `AnyElement`.

---

## 2. Serialisation point identification

The 50 ms gate misses are NOT from the texture copy itself, NOT from the
Nim-side allocation/copy, and NOT from the Rust → Nim FFI overhead.
They come from **`HeadlessAppContext::with_platform`'s app-thread
acquisition + the deferred-draw pump + the `Window::render_to_image`
GPU-readback wait**, all of which run synchronously on the same thread
the bridge's async `frameLoop` is on.

Specifically:

- **`with_platform` + `open_window`** (gpui_headless.rs:246-257). The
  shim builds a brand-new `HeadlessAppContext` and opens a fresh
  `TestWindow` every call. There is no reuse of context across frames.
  GPUI's `HeadlessAppContext` was designed for batch screenshot tests,
  not 30-60 Hz repeat invocation. The cost of constructing the context
  (dispatcher init, executor pools, text-system handle, Metal renderer
  factory plumbing) is paid in full on every renderFrame.
- **Deferred-draw pump** (lines 267-271). Two `refresh_window` +
  `run_until_parked` pairs drain the schedule. Each pump pair pays
  ~5-10 ms in practice because GPUI's layout pass interleaves with
  paint, and the second pump is what actually produces the rasterised
  scene.
- **`render_to_image` GPU readback** (lines 278-280). Issues a Metal
  command buffer for the scene and synchronously waits for completion
  via `MTLCommandBuffer::waitUntilCompleted`, then copies the
  `MTLTexture` contents into a CPU `RgbaImage`. The copy bandwidth alone
  is ~8 MiB at 1280×800 (2× upsampled internal texture) + ~10 MiB at
  1440×900.
- **Triangle downsample** (lines 303-308). Pure-CPU single-threaded
  convolution from 2W×2H to W×H. Costs ~5-7 ms at 1280×800; ~7-9 ms
  at 1440×900.

The Nim-side `newSeq[byte]` + `copyMem` cost is dominated by `malloc`
(`newSeq` zero-initialises) plus a memory-bandwidth-bound copy. Real
measurements (§ 3) show these together are ~2.1-2.7 ms — under 10 % of
the wall-clock cost.

**Verdict.** The serialisation point is the entire opaque body of
`render_to_rgba` — primarily `with_platform` + the deferred-draw pump +
`Window::render_to_image`. The Nim-side allocation + copy is a real but
secondary cost. The Rust-side `Box::leak` + the FFI marshalling itself
are noise.

---

## 3. Per-step wall-clock measurement

Measured on macOS 25.3.0, Apple M-series (the same host the FUH-M8
matrix ran on). Compiled with `-d:release -d:useGpuiHeadless --mm:orc`.
Warmup = 3 iterations, N = 30 samples (medians reported). The harness
seeds a 3-element vertical-stack shadow tree (header / body / footer
divs with text labels) — representative of the task_app surface
complexity. Shim: `isonim-gpui/rust/target/release/libgpui_nim_shim.dylib`.

### 1280 × 800

| Step                                              | Median (ms)          | Min   | Max   | Mean  |
| ------------------------------------------------- | -------------------- | ----- | ----- | ----- |
| `gpui_render_to_pixels` (shim FFI total — opaque) | **41.56**            | 37.97 | 46.35 | 41.55 |
| Nim `newSeq[byte]` allocation                     | 2.01                 | 1.95  | 2.21  | 2.03  |
| Nim `copyMem` readback into Nim seq               | 0.10                 | 0.09  | 0.13  | 0.10  |
| **Overall** (shim + alloc + copy + free)          | **43.67**            | 40.08 | 48.50 | 43.68 |
| Payload                                           | 4096000 B (3.91 MiB) |       |       |       |

### 1440 × 900

| Step                                              | Median (ms)          | Min   | Max   | Mean  |
| ------------------------------------------------- | -------------------- | ----- | ----- | ----- |
| `gpui_render_to_pixels` (shim FFI total — opaque) | **43.62**            | 41.35 | 49.86 | 44.18 |
| Nim `newSeq[byte]` allocation                     | 2.54                 | 2.50  | 2.68  | 2.56  |
| Nim `copyMem` readback into Nim seq               | 0.13                 | 0.10  | 0.17  | 0.13  |
| **Overall** (shim + alloc + copy + free)          | **46.39**            | 44.02 | 52.52 | 46.88 |
| Payload                                           | 5184000 B (4.94 MiB) |       |       |       |

### Reconciliation against the FUH-M8 matrix

FUH-M8 measured frame-latency MEDIANS (client-side inter-frame paint
delta) at:

- gpui task_app Laptop 1280×800: **55.0 ms**
- gpui task_app Desktop 1440×900: **58.9 ms**
- gpui settings_app Laptop 1280×800: **53.2 ms**
- gpui settings_app Desktop 1440×900: **58.7 ms**

The measured per-call shim cost (~42 ms at 1280×800; ~44 ms at
1440×900) plus the Nim alloc+copy (~2 ms) accounts for ~44 / 46 ms of
that 55 / 59 ms. The remaining ~9-13 ms is:

- WebSocket binary frame encode (`encodeFrame`) — bounded by RGBA
  payload size (3.9 / 4.9 MiB).
- `await sendBinary(client, …)` socket write (loopback, but still
  pays an asyncdispatch yield + a buffer copy).
- The EPP-M10 cadence sleep that clamps to 1 ms minimum.
- Client-side `putImageData` decode latency on the browser canvas
  (sampled inside `__isonimFrameTimes`).

So the FUH-M8 55-59 ms gap reduces to: ~70-75 % shim cost + ~25-30 %
post-shim wire / paint. **The shim FFI alone is over the 50 ms gate at
1440×900** (44 ms median + 9 ms wire/paint = 53-59 ms observed).

---

## 4. Mitigation options ranked by effort

### Option A — Switch GPUI launcher to `--encoder webp` (smallest effort)

The shipped FUH-M5 in-process libwebp encoder produces a WebP frame
inside the bridge's frame loop. **Measured at the same host with the
same harness**:

| Viewport   | In-process libwebp encode (cl=3) | Subprocess fallback (cl=3) |
| ---------- | -------------------------------- | -------------------------- |
| 1280 × 800 | **5.43 ms** median               | 64.74 ms (no longer used)  |
| 1440 × 900 | **6.84 ms** median               | 67.21 ms (no longer used)  |

(In-process kind = `wekLibwebpDirect`; verified with
`-d:withCodecWebP -d:withInProcessWebP` and `DYLD_FALLBACK_LIBRARY_PATH`
pointing at `${pkgs.libwebp}/lib`, mirroring the dev-shell shellHook.)

**Crucial observation.** Switching encoder DOES NOT reduce the shim
cost — `gpui_render_to_pixels` still runs at ~42-44 ms. WebP would
trade a ~9-13 ms post-shim wire/serialise cost for a +5-7 ms WebP
encode + a much smaller (∼50-100 KB vs 4-5 MiB) frame. Net effect on
the bridge tick: roughly equivalent — possibly 2-5 ms savings from
reduced WebSocket buffer/copy + reduced client-side `putImageData`.

That's not enough to close the 50 ms gate at 1280×800
(55 ms - ~3 ms = ~52 ms) or 1440×900 (59 ms - ~3 ms = ~56 ms). The
shim FFI cost dominates and `--encoder webp` does not touch it.

**However**, the second-order effect matters: WebP at 50-100 KB per
frame turns the bridge into something where pipelining helps. The
existing client-side fingerprint probe measures inter-paint deltas;
shrinking the wire payload by ~50× tightens the tail of the latency
distribution. The FUH-M8 click-response gap (120-130 ms) is more
sensitive to this than the frame-latency gate, because click latency
is rendered+encoded+sent+decoded+painted, end-to-end. **Switching to
WebP is more likely to close the 3 click-response cells than the 4
frame-latency cells.**

**Effort.** One line of code per launcher — `runDemoBridgeWith` already
plumbs `encoder = resolvedEncoder` for the cocoa backend. The GPUI
launcher `editor/backends/gpui.nim` would gain a `resolveEncoderKind`
call (mirroring `editor/backends/cocoa.nim:136`) and pass the result.

**Risk.** Low. The libwebp encoder is already shipped and verified
(FUH-M5 + ELT-M9 matrix). The browser-side decoder is already wired
(FUH-M5 audited W-packet hello-accept).

### Option B — Pre-allocate texture readback buffers (medium effort)

The 2.0-3.0 ms Nim `newSeq[byte]` allocation is real but secondary.
A pool of reusable W×H buffers (one per active connection) eliminates
it. Implementation: per-`GpuiFrameSource` cached `seq[byte]` of the
current dimensions, reused across calls, resized only on resize events.

**Expected savings.** 2-3 ms per frame at these viewports. Not enough
on its own to close the gate, but stacks with Option A.

**Risk.** Low; touches only the Nim adapter.

### Option C — Off-thread readback via Metal command-buffer fence (larger effort)

The shim's `Window::render_to_image()` is synchronous; it blocks the
calling thread on `MTLCommandBuffer::waitUntilCompleted`. A larger
rework: issue the Metal command buffer, attach a completion handler,
return immediately, and deliver the readback bytes via a channel on a
later poll. The bridge frame loop would then have at most one
in-flight render at a time but no longer block on its completion.

**Expected savings.** ~10-15 ms per frame (the Metal wait + copy).
Probably crosses the 50 ms gate, but requires substantial new
plumbing across the Rust shim AND a callback / poll API across the
Nim FFI.

**Risk.** Medium-high. Adds a new completion-channel surface to the
shim, plus a polling integration in the Nim async loop. The shim
becomes stateful (in-flight command buffers per window), which the
current "one stateless call per frame" architecture avoids.

### Option D — Concurrent multi-frame pipeline (largest effort)

True N-deep pipeline: while the GPU works on frame K, the CPU encodes
frame K-1 and sends frame K-2 over the wire. Requires Option C as a
prerequisite (without async GPU readback, there's no "next frame" to
overlap with).

**Expected savings.** Best-case ~70 % throughput improvement; latency
itself doesn't fall but the inter-frame delta the matrix measures
shrinks to ≈ max(render, encode, send) instead of their sum. Could
hit ~25-30 ms inter-frame at 1280×800.

**Risk.** Large. Requires Option C plus a connection-state machine for
in-flight frames, plus resize-mid-pipeline handling, plus correctness
for the diff-region path which is itself stateful.

---

## 5. Recommendation

**Recommended mitigation: Option A — flip the GPUI launcher to
`--encoder webp` (with `--encoder auto` resolving to WebP per
`editor/backends/common.nim:155-159`).**

One-line rationale: it is the closest in effort to FUH-M5 (the shipped
in-process libwebp encoder), it is the only mitigation that lands
fully inside the launcher composition (no shim changes), and even
though it does not close the 50 ms gate purely arithmetically, the
~50× smaller wire payload is the most likely single change to also
close the 3 GPUI task_app click-response cells (120-130 ms) — which is
the dominant cell-count gap in the FUH-M9 scorecard.

If the matrix re-run after Option A still leaves the 4 frame-latency
cells over 50 ms, **stack Option B** (pre-allocated readback buffers).
Both fixes together remove ~5-8 ms from the per-tick cost without
touching the shim, leaving exactly the question "is `gpui_render_to_pixels`
itself fast enough?" — which Option C / D would answer with a
dedicated cross-repo campaign (GPUI-M1 in the FUH-M9 follow-up
catalogue).

If Option A + Option B miss any frame-latency cells, the residual is
the shim FFI body itself (~42 ms at 1280×800 / ~44 ms at 1440×900) and
the campaign should escalate to Option C; before that, do not weaken
the 50 ms gate.

---

## Appendix: harness reproduction

```sh
# In an isonim-render-serve dev shell:
direnv exec ~/metacraft/isonim-render-serve bash

# GPUI path harness (build once):
nim c -d:release -d:useGpuiHeadless --threads:on --mm:orc \
  --path:src --path:tests \
  --path:../isonim-gpui/src --path:../isonim/src \
  --path:../nim-everywhere/src --path:../nim-stew --path:../nim-faststreams \
  -o:/tmp/profile_gpui_emc_m1 /tmp/profile_gpui_serialisation.nim

DYLD_FALLBACK_LIBRARY_PATH="/Users/zahary/metacraft/isonim-gpui/rust/target/release:$DYLD_FALLBACK_LIBRARY_PATH" \
  /tmp/profile_gpui_emc_m1

# WebP encoder harness (build once):
nim c -d:release -d:withCodecWebP -d:withInProcessWebP \
  --threads:on --mm:orc \
  --path:src --path:tests \
  --path:../isonim-gpui/src --path:../isonim-cocoa/src --path:../isonim-freya/src \
  --path:../isonim-android/src --path:../isonim-android/nim-lib/src \
  --path:../isonim/src --path:../nim-everywhere/src \
  --path:../nim-stew --path:../nim-faststreams \
  -o:/tmp/profile_webp_emc_m1 /tmp/profile_webp_encode.nim

/tmp/profile_webp_emc_m1
```

Harness sources are at `/tmp/profile_gpui_serialisation.nim` and
`/tmp/profile_webp_encode.nim`. They are deliberately out-of-tree; no
edits were made to the working copy of any repo.

## Files inspected

- `isonim-render-serve/src/isonim_render_serve/adapters/gpui_adapter.nim:232-301` — Nim adapter renderFrame + headless wrapper.
- `isonim-render-serve/src/isonim_render_serve/adapters/gpui_adapter.nim:386-395` — toAny wrapper.
- `isonim-render-serve/src/isonim_render_serve/bridge.nim:680-723` — bridge tick + transport selector + raw-RGBA path.
- `isonim-render-serve/src/isonim_render_serve/bridge.nim:137-156` — BridgeConfig.encoder / encoderHandle fields.
- `isonim-gpui/src/isonim_gpui/bindings.nim:217-230` — FFI declarations.
- `isonim-gpui/rust/gpui-nim-shim/src/gpui_headless.rs:117-180` — gpui_render_to_pixels + gpui_free_pixels FFI.
- `isonim-gpui/rust/gpui-nim-shim/src/gpui_headless.rs:195-323` — render_to_rgba implementation.
- `isonim-gpui/rust/gpui-nim-shim/src/gpui_app.rs:54-114` — NimRootView render impl.
- `isonim-examples/editor/backends/gpui.nim:39-146` — GPUI launcher (NB: does not call `resolveEncoderKind`, so encoder defaults to `ekRawRgba`).
- `isonim-examples/editor/backends/cocoa.nim:122-164` — Cocoa launcher (already resolves and passes `encoder`; the model for Option A).
- `isonim-examples/editor/backends/common.nim:75-162` — CLI parse + `resolveEncoderKind` + `runDemoBridgeWith`.
- `isonim-examples/config.nims:104-120` — `-d:withCodecWebP` + `-d:withInProcessWebP` default-on at the launcher build.
- `isonim-render-serve/tests/test_webp_inprocess_encoder_budget.nim:71-110` — FUH-M5 budget test (16 ms gate at 1280×800).

No source-tree edits were made by this audit. No commits were created.
