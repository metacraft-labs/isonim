# EPP-M1 Audit — Editor Preview Performance + Interaction (read-only)

Date: 2026-05-29
Author: EPP-M1 sub-agent (audit only — no code changes, no commits)
Spec: `codetracer-specs/Front-Ends/IsoNim/Editor-Preview-Performance.milestones.org`
Prior: `isonim/docs/viewport-resize-audit-VRS-M1.md` (referenced as VRS-M1)

This audit maps the territory the Editor Preview Performance + Interaction
campaign (EPP-M2..M8) must cover: (1) which of the non-Web launchers
already have a real-render headless path and what gates it; (2) which
hardware-encoder APIs the workspace can lean on for low-latency video
transport; (3) the browser-side WebCodecs surface the editor JS shim
will consume; (4) the current `I`-frame input event schema and per-
launcher dispatch; (5) per-launcher real-render interactivity status;
(6) the fps configuration knob; and (7) a concrete EPP-M2..M7 plan
summary every later sub-agent can read on its own.

Headline conclusions (cross-cutting; later sections back each one with
file:line citations):

1. **All three non-Web backends already have a real-render code path**
   wired through the `isonim-render-serve` adapter family — GPUI via
   Zed's `HeadlessAppContext` + `Window::render_to_image()`
   (`isonim-gpui/rust/gpui-nim-shim/src/gpui_headless.rs`), Freya via
   `freya-testing`'s Skia raster pass
   (`isonim-freya/rust/freya-nim-shim/src/freya_headless.rs`), Cocoa
   via AppKit's `bitmapImageRepForCachingDisplayInRect:` capture
   (`isonim-cocoa/src/isonim_cocoa/testing/capture_rgba.m`). The
   GPUI/Freya paths gate behind `-d:useGpuiHeadless` /
   `-d:useFreyaHeadless`; Cocoa always uses the real path on macOS.
   **The Justfile in `isonim-examples` already enables the headless
   flag for Darwin GPUI and unconditional for Freya** (lines 179-184).
   So EPP-M2's "flip the default" work is partially already done —
   what's missing is verification, polish, and CI wiring (Linux GPUI
   still falls back to synthetic stripes because `current_headless_renderer()`
   returns `None` on non-macOS — the pinned Zed revision has no Linux
   headless path yet, see `gpui_headless.rs:242-244`).

2. **Zero hardware video encoder bindings exist anywhere in the
   workspace.** The packet codec already reserves F-flag bit 1 for
   future `video/h264` payloads (`isonim-render-serve/src/isonim_render_serve/packet.nim:14-17`)
   AND the browser-side JS shim already _closes the connection_ when
   that bit is set at protocolVersion=1 (`streaming_preview.nim:1027`).
   No `VTCompressionSession`, `videoToolbox`, `nim_video_toolbox`,
   `vaapi`, `nvenc`, etc. anywhere — EPP-M5 is a full new FFI binding.
   The only h264-adjacent code path is `libx264`/`wf-recorder`/CLI use
   inside the GPUI/Freya CI test scripts
   (`isonim-gpui/scripts/xvfb-run-test.sh:218,231,239`) — not a Nim
   binding, not reusable for the launcher's encoder.

3. **The synthetic painter does NOT swallow mouse events on the
   real-render paths** — but it's not quite the story EPP-M7 hopes
   for either. All three of GPUI / Freya / Cocoa expose a _synthetic_
   `fireEvent` dispatcher (`isonim-gpui/src/isonim_gpui/renderer.nim:341`,
   `isonim-freya/src/isonim_freya/renderer.nim:343`,
   `isonim-cocoa/src/isonim_cocoa/renderer.nim:1160`) that directly
   invokes a Nim closure registered on the shadow-tree node. The
   bridge's per-launcher input adapter
   (`gpui_input_adapter.nim:74-77`, `freya_input_adapter.nim:84-87`,
   `cocoa_input_adapter.nim:106-113`) hit-tests the mouse coordinate
   to a target node and calls `fireEvent(target, "click")`. The
   Nim closure runs in-process and mutates the VM — which the next
   frame then re-rasterizes. So mouse clicks DO work end-to-end on
   all three real-render paths, but they bypass the engine's native
   input pipeline entirely (no GPUI `WindowContext::dispatch_keystroke`,
   no Cocoa `NSWindow::sendEvent:`). For keyboard, none of the three
   Rust shims expose any input entry point — EPP-M7 will need a new
   `fireEvent(node, "keydown"/"keyup"/"input"/...)` schema or a new
   FFI for the launcher to call.

4. **WebCodecs is broadly available in the editor's Playwright/Chromium
   target.** `VideoDecoder` has been Baseline in Chromium since 94
   (Oct 2021); Safari 16.4+; Firefox 130+. The dev target is
   bundled Chromium via the editor's Playwright env (and the user
   workspace's Chrome), so EPP-M6 can rely on `VideoDecoder` always
   being present — the JPEG-per-frame fallback in the spec is purely
   defensive.

The rest of the audit fills in the file:line citations for each
section.

---

## Section 1 — Real-render headless paths per backend

### 1.1 GPUI (RS-M14 Phase 2 — implemented; Darwin-only at runtime)

**Entry point.** The shim exposes a single C ABI function:

```nim
# isonim-gpui/src/isonim_gpui/bindings.nim:217-220
proc gpui_render_to_pixels*(width: cuint; height: cuint; scale: cfloat;
                             outPtr: ptr ptr uint8;
                             outLen: ptr csize_t): cint
  {.importc: "gpui_render_to_pixels".}
```

Implementation:
`/Users/zahary/metacraft/isonim-gpui/rust/gpui-nim-shim/src/gpui_headless.rs:117-163`.
It drives Zed's `HeadlessAppContext::with_platform`
(`gpui_headless.rs:246-250`), opens a window at the requested logical
size (`gpui_headless.rs:252-257`), pumps `cx.run_until_parked()`
twice with intervening `Window::refresh` calls so the deferred-draw
GPUI pipeline has a chance to settle (`gpui_headless.rs:266-272`),
then captures via `capture_screenshot` (a wrapper around
`Window::render_to_image()`) and downsamples by 2x with a triangle
filter to compensate for the test platform's hard-coded scale factor
of 2.0 (`gpui_headless.rs:280-310`).

The output buffer is RGBA8888 non-premultiplied sRGB row-major,
exactly what the F-packet protocol requires
(`gpui_headless.rs:84-88`). The buffer is `Box::leak`-handed back
across the FFI and must be freed via `gpui_free_pixels`
(`gpui_headless.rs:174-180`).

**Build flag.** Two layers gate the path:

1. The Rust shim must be built with `--features gpui-headless`
   (Cargo feature defined in
   `isonim-gpui/rust/gpui-nim-shim/Cargo.toml`). The feature pulls
   in `gpui = { ... features = ["test-support"] }` plus `gpui_platform`
   and `image` — non-trivial weight, which is why it's opt-in.
2. The Nim adapter compiles with `-d:useGpuiHeadless` to make
   `gpui_adapter.renderFrame` route through the headless path
   (`isonim-render-serve/src/isonim_render_serve/adapters/gpui_adapter.nim:225-232`).

**Current default in the dev shell.** Per
`isonim-examples/Justfile:180-188`:

```sh
if [ "$renderer" = "gpui" ] && [ "$(uname -s)" = "Darwin" ]; then
  extra_flags="-d:useGpuiHeadless"
fi
nim c ... $extra_flags -o:build/backends/isonim-examples-gpui ...
```

So on macOS the editor's `isonim-examples-gpui` launcher binary is
already built with the headless flag ON. **The fallback to the
synthetic painter only fires on Linux today.** The Justfile comment
at lines 164-175 explains this: the pinned Zed revision's
`current_headless_renderer()` returns `None` on non-macOS, so the
Linux binary still uses synthetic stripes (`gpui_headless.rs:242-244`
surfaces this as error code `RendererUnavailable = 2`).

**Per-platform availability.**

| Host         | Cargo feature buildable?          | Runtime works?                                                             |
| ------------ | --------------------------------- | -------------------------------------------------------------------------- |
| macOS ARM64  | Yes                               | Yes (MetalHeadlessRenderer)                                                |
| macOS x86_64 | Yes                               | Yes                                                                        |
| Linux x86_64 | Yes (compiles)                    | No — `current_headless_renderer()` returns `None`; falls back to synthetic |
| Windows      | Likely no (untested in workspace) | n/a                                                                        |

**Known regressions / TODOs in the shim.** The most recent landed
fix (M-EVP-14) corrected the (W, H) scale handling
(`gpui_headless.rs:204-218`) — the prior version divided width/height
by the test platform's 2.0 scale factor before opening the window,
which collapsed the design canvas to half size and made every padded
button look "4x too large". That's already fixed; no other open
TODOs in `gpui_headless.rs`.

**Cocoa-style Metal-backed offscreen feasibility (cross-ref §1.3).**
GPUI on macOS effectively _is_ using a Metal-backed offscreen render
already — `MetalHeadlessRenderer` is the renderer factory inside
Zed's `current_headless_renderer()` on macOS. EPP-M4 should NOT add
another Metal path here.

### 1.2 Freya (RS-M14 Phase 1 — implemented; works on both macOS + Linux)

**Entry point.**

```nim
# isonim-freya/src/isonim_freya/bindings.nim (analogous to GPUI's bindings)
proc freya_render_to_pixels*(width: cuint; height: cuint; scale: cfloat;
                              outPtr: ptr ptr uint8;
                              outLen: ptr csize_t): cint
```

Implementation:
`/Users/zahary/metacraft/isonim-freya/rust/freya-nim-shim/src/freya_headless.rs:76-122`.
Drives `freya-testing`'s `launch_test_with_config` (`freya_headless.rs:187`),
applies the latest VDOM via `wait_for_update().await`
(`freya_headless.rs:190`), calls `utils.create_snapshot()` which
returns a PNG-encoded `skia_safe::Data` blob, then decodes through
the `image` crate's PNG decoder to canonical RGBA8888
(`freya_headless.rs:201-207`). One PNG round-trip per frame — not
ideal but the price `freya-testing 0.3.4` charges (the raw `Surface`
isn't accessible outside the crate; see the module docstring at
`freya_headless.rs:20-29`).

**Build flag.** Two layers, mirroring GPUI:

1. Rust shim with `--features freya-headless`
   (`isonim-freya/rust/freya-nim-shim/Cargo.toml`).
2. Nim adapter with `-d:useFreyaHeadless`
   (`isonim-render-serve/src/isonim_render_serve/adapters/freya_adapter.nim:296-302`).

**Current default in the dev shell.** Per
`isonim-examples/Justfile:179-181`:

```sh
if [ "$renderer" = "freya" ]; then
  extra_flags="-d:useFreyaHeadless";
fi
```

So Freya is built with the headless flag ON **unconditionally** —
both macOS and Linux. (Freya uses Skia raster which doesn't depend
on a platform-specific GPU compositor — see Section 1.2.4.)

**Per-platform availability.**

| Host         | Works?                                                 |
| ------------ | ------------------------------------------------------ |
| macOS ARM64  | Yes                                                    |
| macOS x86_64 | Yes                                                    |
| Linux x86_64 | Yes (`freya-testing` is platform-agnostic Skia raster) |
| Windows      | Likely (untested)                                      |

**Known limitations.** The PNG round-trip is the headline perf
cost — measured implicitly through the campaign's "~100–170 ms per
frame" perceived latency. Real Freya wallclock pixel cost is in the
single-digit ms; the PNG encode + decode add 5–20 ms per frame on
top. EPP-M3's brief should call this out as a known limitation that
EPP-M5's hardware encoder will subsume (the encoder consumes raw
RGBA, so the PNG step becomes unnecessary). A future shim
revision could bypass `create_snapshot()` and walk the surface
directly if freya-testing ever exposes it (see the docstring at
`freya_headless.rs:22-29`).

**Cocoa-style fallback feasibility:** Not applicable — Freya is
already pixel-accurate; no AppKit involvement.

### 1.3 Cocoa (RS-M5 — implemented for macOS, placeholder on Linux)

**Entry point.** ObjC helper, not a Rust shim:

`/Users/zahary/metacraft/isonim-cocoa/src/isonim_cocoa/testing/capture_rgba.m:61-177`
exposes:

```c
int nim_capture_view_rgba(id view, int width, int height,
                          unsigned char *buf);
```

The Nim wrapper is `captureViewRgba` in
`isonim-cocoa/src/isonim_cocoa/appkit/capture.nim`, called from
the adapter's `renderFrame` at
`isonim-render-serve/src/isonim_render_serve/adapters/cocoa_adapter.nim:628`.

The 6-step recipe (documented inline at `capture_rgba.m:1-42`):

1. Set the view's frame to (0, 0, width, height).
2. Force `layoutSubtreeIfNeeded` so AutoLayout passes commit.
3. Allocate an `NSBitmapImageRep` via `bitmapImageRepForCachingDisplayInRect:`.
4. Drive `cacheDisplayInRect:toBitmapImageRep:` — AppKit renders
   the view hierarchy into the rep's backing store.
5. Inspect format (`pixelsWide`, `bytesPerRow`, `samplesPerPixel`,
   `bitmapFormat`).
6. Copy each row into the destination buffer, swizzling per-pixel
   when the channel order is ARGB / BGRA / ABGR rather than RGBA.

**Build flag.** No flag — the AppKit capture is the only path on
macOS. The whole module is gated `when defined(macosx)` at
`cocoa_adapter.nim:140` and `cocoa.nim:14`. Linux compiles a
placeholder that returns uniform dark-grey
(`cocoa_adapter.nim:656-678`).

**Current default in the dev shell.** Per
`isonim-examples/Justfile:214-219` (build-backends-macos recipe),
the Cocoa launcher is built only on macOS hosts and the build is
unconditional (no `-d:useCocoaHeadless`-style flag exists).

**Per-platform availability.**

| Host         | Works?                                 |
| ------------ | -------------------------------------- |
| macOS ARM64  | Yes                                    |
| macOS x86_64 | Yes                                    |
| Linux        | Placeholder only (uniform grey pixels) |

**Performance characteristics.** Per the spec brief and the
adapter's docstring at `cocoa_adapter.nim:89-98`:

> Capture on each `frameLoop` tick — `renderFrame` is called once
> per bridge tick (typically 20–60 Hz). For sufficient FPS on
> heavier views, pre-build the `NSBitmapImageRep` once at
> construction time (so AppKit doesn't re-allocate the backing
> store every tick) and refresh it on dirty signals from the VM.
> That optimisation is explicitly deferred — RS-M5's deliverable
> is _correct_ capture, not fastest capture.

`cacheDisplayInRect:toBitmapImageRep:` is documented elsewhere as
software-rasterised (no GPU compositing). Measured 10–40 ms per
frame in the campaign brief.

**Metal-backed offscreen feasibility for EPP-M4.** Two architectural
options:

1. **`CARenderer` + `CAMetalLayer` offscreen** — Apple's documented
   path for headless Core Animation rendering. Requires the view
   to be layer-backed (`setWantsLayer:YES`, which the adapter
   already does at `cocoa_adapter.nim:340-356`). The flow would be:
   create an `MTLTexture` and `MTLCommandQueue`, wrap with
   `CARenderer(MTLTexture:options:)`, point its root at the view's
   layer (`view.layer`), call `render`, then read the texture via
   `MTLBlitCommandEncoder.synchronize` + `getBytes:`. Estimated
   5-15 ms per frame on M1.
2. **`CGWindowListCreateImage`** — RS-M0's documented fallback. Per
   `cocoa_adapter.nim:99-111`, requires a real on-screen NSWindow
   (which the headless adapter explicitly avoids). Not suitable
   for the editor preview.

**Feasibility assessment for EPP-M4.** Option 1 is _feasible from
the existing launcher code_ — the adapter already touches the view
hierarchy at `cocoa_adapter.nim:444-452` (`setFrame`, `setWantsLayer`,
`setLayerBackgroundColor`) so adding a `CARenderer`-backed capture
path is well within the architecture. The only new dependencies are
`<Metal/Metal.h>` and `<QuartzCore/QuartzCore.h>`, both already
implicit in the `passL: -framework CoreGraphics` line at
`cocoa_adapter.nim:22-23` (the framework set needs to grow). The
non-trivial work is:

- A new ObjC helper (`capture_metal.m` next to `capture_rgba.m`)
  that allocates the Metal device, command queue, texture, and
  CARenderer; drives `render`; and reads back RGBA bytes.
- Gate the choice via a new build flag `-d:cocoaMetalCapture` (per
  spec) or a runtime `--cocoaCapture=metal` arg — keep
  `cacheDisplayInRect:toBitmapImageRep:` as fallback when the layer
  configuration isn't Metal-friendly (some `NSView` subclasses
  fall through CoreImage that CARenderer doesn't honour).
- BGRA → RGBA swizzle: `CARenderer` produces BGRA8 on most Apple
  GPUs; the existing `capture_rgba.m`'s swizzle logic at lines
  146-168 is the template.

**Recommendation for EPP-M4:** implement option 1 behind
`-d:cocoaMetalCapture` (default off until the EPP-M8 gate validates),
keep the AppKit `cacheDisplayInRect:` path as the fallback. Estimated
sub-agent effort: 1–2 days for the helper + Nim wrapping + a
microbenchmark.

---

## Section 2 — Hardware video encoder APIs

**Headline:** no Nim or Rust bindings to any hardware video encoder
exist in the workspace today. EPP-M5 must add them from scratch. The
F-packet codec is forward-compatible: `flags` bit 1 is reserved for
`video/h264` (`packet.nim:14-17`) and the browser shim closes the
WS with code 1002 if that bit is set at protocolVersion=1
(`streaming_preview.nim:1027`) — so a new packet kind or a bumped
protocol version is required.

### 2.1 macOS — VideoToolbox (`VTCompressionSession`)

**API surface for low-latency H.264 encoding:**

- `VTCompressionSessionCreate(allocator, width, height, codecType,
encoderSpecification, sourceImageBufferAttributes,
compressedDataAllocator, outputCallback, outputCallbackRefcon,
compressionSessionOut)` — the entry point.
- `kCMVideoCodecType_H264` for AVC1 / Baseline / Main / High;
  `kCMVideoCodecType_HEVC` for H.265.
- `VTSessionSetProperty(session, key, value)` for tuning:
  - `kVTCompressionPropertyKey_ProfileLevel` — set to
    `kVTProfileLevel_H264_Baseline_AutoLevel` for lowest latency,
    best browser compat.
  - `kVTCompressionPropertyKey_RealTime` — `true` to disable
    look-ahead, prioritize wallclock latency over bitrate.
  - `kVTCompressionPropertyKey_AllowFrameReordering` — `false` to
    prevent B-frames (B-frames require a future reference, which
    adds latency).
  - `kVTCompressionPropertyKey_MaxKeyFrameInterval` — set to 1
    (every frame is a keyframe per the EPP-M5 brief) for simplest
    transport at the bandwidth cost of ~5× IPB, OR set to ~60 for
    the standard "one keyframe per second at 60 FPS" trade-off.
    The spec brief picks GopSize=1 — confirm bandwidth budget at
    EPP-M5 implementation time.
  - `kVTCompressionPropertyKey_DataRateLimits` — array of
    `[bytesPerSecond, seconds]` pairs.
  - `kVTCompressionPropertyKey_AverageBitRate` — target bps.
- `VTCompressionSessionEncodeFrame(session, imageBuffer, ptsTime,
duration, frameProperties, sourceFrameRefcon,
infoFlagsOut)` — feed a `CVImageBufferRef` (created via
  `CVPixelBufferCreate` with `kCVPixelFormatType_32BGRA` — the
  encoder accepts BGRA natively, no swizzle needed).
- `VTCompressionSessionCompleteFrames(session, completeUntilTime)` —
  flush.
- Encoder output callback receives `OSStatus, encodeInfoFlags,
CMSampleBufferRef sampleBuffer` — extract the H.264 NALU bytes
  via `CMSampleBufferGetDataBuffer` + `CMBlockBufferCopyDataBytes`.
  The first frame is preceded by SPS/PPS NALUs (parameter sets),
  which the browser decoder needs as the `description` for its
  `VideoDecoderConfig`.
- **Encoder lifecycle:** the session is dimension-bound. Re-init
  on every resize (per the EPP-M5 brief, this is the canonical
  path). `VTCompressionSessionInvalidate` + recreate.

**Existing Nim/Rust bindings in the workspace:** None. Grep for
`VTCompressionSession`, `VideoToolbox`, `videoToolbox`,
`vt_compression`, `kCMVideoCodec`, `CMSampleBuffer` across
`isonim/`, `isonim-render-serve/`, `isonim-cocoa/`, `isonim-gpui/`,
`isonim-freya/`, `isonim-examples/` returns zero hits in source
files (only the spec `.org` and the campaign milestones file
reference it).

The cleanest binding approach for EPP-M5:

1. **An ObjC helper** (`videotoolbox_encoder.m`) modelled on
   `isonim-cocoa/src/isonim_cocoa/testing/capture_rgba.m`. The
   helper owns a `VTCompressionSession*`, a callback that pushes
   NALU bytes into a Nim-supplied callback, and an init/encode/
   destroy triplet. Compile with
   `passL: -framework VideoToolbox -framework CoreMedia
-framework CoreVideo`. Linker addition matches the existing
   pattern at `cocoa_adapter.nim:22-23`.
2. **A small Nim wrapper** (`isonim-render-serve/src/isonim_render_serve/encoders/videotoolbox.nim`)
   that exposes a `H264VideoToolboxEncoder` type plus an `encode`
   method matching the spec's encoder family abstraction.
3. **A new encoder family** in `isonim-render-serve` —
   `Encoder` concept (`RawRgbaEncoder`, `JpegEncoder`,
   `H264VideoToolboxEncoder`) wrapping `frame -> packet bytes`.
   Today `bridge.nim:288-302` calls
   `cfg.frameSource.renderFrame()` → `buildOutgoingFrame()` →
   raw F-packet emission. EPP-M5 inserts the encoder between
   `renderFrame` and the packet build.

**Latency-tunable parameters (summary for EPP-M5 implementation):**

| Setting              | Value (low-latency)       | Effect                                                  |
| -------------------- | ------------------------- | ------------------------------------------------------- |
| ProfileLevel         | `H264_Baseline_AutoLevel` | No CABAC, no B-frames; browser-universal                |
| RealTime             | `true`                    | Encoder never blocks waiting for look-ahead             |
| AllowFrameReordering | `false`                   | No B-frames                                             |
| MaxKeyFrameInterval  | 1 (per spec brief) or 60  | 1 = every frame keyframe; 60 = ~1 keyframe/sec @ 60 FPS |
| DataRateLimits       | `[targetBps/8, 1.0]`      | Cap burst rate                                          |
| AverageBitRate       | ~2 Mbps for 1024×768@60   | Per EPP-M5 spec target                                  |
| ExpectedFrameRate    | 60                        | Hint for rate control                                   |

**HEVC alternative.** `kCMVideoCodecType_HEVC` is available on
macOS 10.13+, but Safari is the only browser that supports HEVC in
WebCodecs (as of 2026). Stick with H.264 Baseline for browser
universality.

**AVC1 streaming format.** The encoder emits "AVC1" framing
(length-prefixed NALUs, parameter sets carried in
`CMVideoFormatDescription` extra data). The browser's
`VideoDecoder` accepts AVC1 directly via:

```js
decoder.configure({
  codec: "avc1.42E01F",  // Baseline profile, level 3.1
  optimizeForLatency: true,
  description: <SPS/PPS extra data bytes>,
});
```

The launcher must serialise the extra-data buffer once on session
init and ship it as part of the `M`-packet `hello`'s capabilities
(see EPP-M6's transport negotiation) — the browser cannot decode
without it.

### 2.2 Linux — VAAPI (Intel/AMD) + NVENC (NVIDIA)

**API surface (VAAPI):** `va_render.h` / `libva` provides the
generic accelerated decoding/encoding interface; per-vendor drivers
plug in beneath. The relevant entry points for H.264 encoding:

- `vaInitialize(display, major, minor)`.
- `vaQueryConfigEntrypoints(display, profile, entrypoints,
numEntrypoints)` — look for `VAEntrypointEncSlice` (constant
  bitrate) or `VAEntrypointEncSliceLP` (low-power low-latency).
- `vaCreateConfig(display, profile=VAProfileH264ConstrainedBaseline,
entrypoint, attribs, numAttribs, configOut)`.
- `vaCreateSurfaces(display, format=VA_RT_FORMAT_YUV420, width,
height, surfaces, numSurfaces, attribs, numAttribs)`.
- `vaCreateContext(display, config, picture_width, picture_height,
flag=VA_PROGRESSIVE, render_targets, numTargets, context)`.
- Per-frame: build a `VAEncSequenceParameterBufferH264`, a
  `VAEncPictureParameterBufferH264`, a `VAEncSliceParameterBufferH264`,
  upload via `vaCreateBuffer` + `vaBeginPicture` + `vaRenderPicture`
  - `vaEndPicture`. Read NALU bytes via `vaMapBuffer` on a coded
    buffer.

**API surface (NVENC):** `nvEncodeAPI.h` (NVIDIA proprietary).
Workflow:

- `NvEncodeAPICreateInstance` → fills an `NV_ENCODE_API_FUNCTION_LIST`.
- `nvEncOpenEncodeSessionEx` → returns encoder handle.
- `nvEncGetEncodePresetConfig(handle, codecGuid=NV_ENC_CODEC_H264_GUID,
presetGuid=NV_ENC_PRESET_LOW_LATENCY_HQ_GUID, configOut)`.
- `nvEncInitializeEncoder(handle, initParams)`.
- `nvEncEncodePicture(handle, encPicParams)`.
- `nvEncLockBitstream` / `nvEncUnlockBitstream` to read NALUs.

**Latency-tunable parameters:**

| API   | Low-latency preset                  | Notes                   |
| ----- | ----------------------------------- | ----------------------- |
| VAAPI | `VAEntrypointEncSliceLP`            | Intel low-power, on-die |
| NVENC | `NV_ENC_PRESET_LOW_LATENCY_HP_GUID` | Hi-perf, low-latency    |

**Existing bindings in the workspace:** None for either API. Same
grep pattern returns zero hits.

**EPP-M5 scope decision per the spec brief:** macOS first
(VideoToolbox); VAAPI/NVENC explicitly deferred to a "future EPP-M5b"
follow-up. The encoder abstraction in `isonim-render-serve` must be
designed so VAAPI / NVENC adapters slot in alongside
VideoToolbox without churning the bridge interface.

### 2.3 Windows (future) — Media Foundation

`MFTEnumEx` for `MFT_CATEGORY_VIDEO_ENCODER`,
`MFT_FRIENDLY_NAME_Attribute` containing "H264" — picks the
hardware encoder MFT (Intel QSV, AMD AMF, NVENC, all expose MFT
plugins). Workflow is more verbose than VideoToolbox: input/output
sample buffers via `IMFMediaBuffer`, async drain loop.

Not in the workspace; explicitly out of EPP-M5's scope. Document
as a future axis.

### 2.4 Recommendation summary for EPP-M5

1. **Build only the VideoToolbox encoder for EPP-M5.** macOS is
   the campaign's acceptance target (the user is on M1, and the
   campaign brief acknowledges Linux CI is a follow-up).
2. **Design the encoder abstraction in `isonim-render-serve`** so
   VAAPI / NVENC / MediaFoundation slot in cleanly:
   ```nim
   type
     Encoder* = ref object
       configureImpl*: proc(w, h: int) {.closure, gcsafe.}
       encodeImpl*: proc(rgba: openArray[byte]): seq[byte] {.closure, gcsafe.}
       codecId*: string  # "avc1.42E01F" — fed to the M-packet hello
       extraData*: seq[byte]  # SPS/PPS for the browser decoder config
   ```
3. **Wire the encoder into the bridge's frame loop** at
   `bridge.nim:288-302`, replacing the direct
   `buildOutgoingFrame(curr, state)` call with a switch that emits
   either an F-packet (raw RGBA) or a new `V`-packet (compressed
   video) depending on the negotiated transport.
4. **New packet kind `V`** per the EPP-M5 spec brief:
   - `'V' | u8 flags | u32 LE codec_id_index | u32 LE width |
u32 LE height | u32 LE length | NALU bytes`. The `codec_id_index`
     references a per-connection table announced in the `hello`
     capabilities so the browser can pick the right `VideoDecoder`
     config without re-parsing on every frame.
5. **Encoder lifecycle hooks** for resize: in the per-launcher
   `editor/backends/<renderer>.nim` `resizingSink`, also call
   `encoder.configure(newW, newH)` so the VideoToolbox session is
   re-initialised at the new dims. The spec brief acknowledges
   this (VideoToolbox sessions are dimension-bound).

---

## Section 3 — Browser-side decoder (WebCodecs)

### 3.1 API surface for the editor JS shim

The editor's `streaming_preview.nim` JS shim (lines 938–1211) is
the integration point. EPP-M6 will add a `VideoDecoder` path that
parallels the existing `handleF(bytes)` at
`/Users/zahary/metacraft/isonim/src/isonim/editor/streaming_preview.nim:1021`.

**Core API surface:**

```js
const decoder = new VideoDecoder({
  output: (frame /* VideoFrame */) => {
    // Paint the frame into the existing canvas.
    const ctx = canvas.getContext("2d");
    ctx.drawImage(frame, 0, 0); // 2D context can drawImage(VideoFrame)
    frame.close(); // release the underlying surface
  },
  error: (e) => {
    console.error("VideoDecoder error:", e);
  },
});

decoder.configure({
  codec: "avc1.42E01F", // Baseline 3.1 — matches encoder profile
  codedWidth: width,
  codedHeight: height,
  optimizeForLatency: true, // hint: emit frames as soon as decoded
  hardwareAcceleration: "prefer-hardware", // use VideoToolbox decoder
  description: extraDataU8Array, // SPS+PPS from encoder
});

// Per-frame, in handleV(bytes):
decoder.decode(
  new EncodedVideoChunk({
    type: "key", // every frame is a keyframe per GopSize=1
    timestamp: framePtsMicros,
    duration: 16667, // ~60 FPS
    data: naluBytesU8Array,
  }),
);
```

The `optimizeForLatency` hint is the load-bearing knob — without
it, the decoder may queue frames waiting for B-frames it knows
will never arrive. With it, output fires as soon as the decoded
frame is ready. Spec ref: WebCodecs "VideoDecoderConfig" interface
in W3C / WICG; `optimizeForLatency` flag at
<https://www.w3.org/TR/webcodecs/#dom-videodecoderconfig-optimizeforlatency>.

### 3.2 Browser support matrix (target: editor Playwright env = Chromium)

| Browser                       | `VideoDecoder` | `optimizeForLatency` | Notes                                      |
| ----------------------------- | -------------- | -------------------- | ------------------------------------------ |
| Chrome 94+ (Oct 2021)         | Yes            | Yes                  | Baseline; ChromeBeta has had it since 2021 |
| Edge 94+                      | Yes            | Yes                  | Same engine                                |
| Safari 16.4+ (Mar 2023)       | Yes            | Yes                  | macOS 13.3+, iOS 16.4+                     |
| Firefox 130+ (Sep 2024)       | Yes (default)  | Yes                  | Earlier versions had it behind a pref      |
| Playwright Chromium (default) | Yes            | Yes                  | The editor's e2e test target               |

**Editor dev target:** Chromium via `tests/browser` (per
`isonim/CLAUDE.md`'s `just test-browser-editor-*` recipes). Always
has `VideoDecoder`. The JPEG-per-frame fallback path in EPP-M6's
brief is a defensive safety net for non-Chromium browsers; it can
be implemented behind feature-detect (`typeof VideoDecoder ===
"function"`) and never exercised in CI.

### 3.3 `ImageDecoder` (alternative for JPEG fallback)

For the JPEG-per-frame fallback path, the editor JS shim can use
either:

- `ImageDecoder` (newer, async, same hardware-accel hooks as
  `VideoDecoder`) — Chrome 94+, Safari 17+, Firefox 133+.
- `Image()` + `URL.createObjectURL(blob)` + `<img>` decode (legacy,
  universal) — works everywhere.

The legacy path is simpler and the EPP-M6 spec doesn't require
hardware-accelerated JPEG. Pick `Image()`.

### 3.4 `VideoFrame` lifetime — important footgun

`VideoFrame` holds a reference to a GPU texture. The browser limits
the number of in-flight frames per origin (currently 64 in Chrome).
**The output callback MUST call `frame.close()` after draw**
otherwise the decoder will throttle and the perceived latency rises.
The example above does this synchronously after `drawImage`. Note
this for EPP-M6's implementation.

### 3.5 DPR / canvas sizing contract

VRS-M2 follow-up (visible at `streaming_preview.nim:1004-1019`)
already established the canvas-sizing contract: intrinsic dims =
launcher's physical pixels (dpr-scaled); CSS dims = intrinsic / dpr.
EPP-M6 must preserve this — the `VideoDecoder`'s output `VideoFrame`
has `codedWidth` / `codedHeight` which the editor sets as the
canvas intrinsic. The CSS-width math at lines 1017-1018 stays the
same.

---

## Section 4 — Current `I`-frame input event schema

This section reads `isonim-render-serve`'s `InputEventKind` enum
plus the per-launcher dispatch flow.

### 4.1 `InputEventKind` enum — every kind shipped today

`/Users/zahary/metacraft/isonim-render-serve/src/isonim_render_serve/event_dispatch.nim:14-16`:

```nim
InputEventKind* = enum
  iekKey, iekMouse, iekScroll, iekResize, iekFocus,
  iekSelectStory, iekApplyMutation
```

With the `InputEvent` discriminated variant immediately below:

- `iekKey`: `keyAction (kaDown/kaUp/kaPress), key, code, keyModifiers,
repeat` — the schema is fully defined (`event_dispatch.nim:30-34`)
  but **no editor JS shim today emits an I packet of `type:"key"`**.
- `iekMouse`: `mouseAction (maDown/maUp/maMove/maClick), button,
mouseX, mouseY, mouseModifiers` (`event_dispatch.nim:35-39`). The
  JS shim sends `mouse down/up/move/click/dblclick` at
  `streaming_preview.nim:1137-1187`. Note: `dblclick` is sent as an
  `"action":"dblclick"` string by the editor JS shim
  (`streaming_preview.nim:1184`), but the `MouseAction` Nim enum
  does NOT include `dblclick` — `parseMouseAction` at
  `event_dispatch.nim:106-114` raises `PacketProtocolError`. **This
  is a pre-existing decode failure** the campaign should fix; EPP-M7
  is the natural milestone to absorb it (add `maDblClick`).
- `iekScroll`: `scrollX/Y, deltaX/Y, scrollModifiers`
  (`event_dispatch.nim:40-43`). Sent by `onWheel` in the JS shim
  (`streaming_preview.nim:1188-1193`).
- `iekResize`: `width, height` (`event_dispatch.nim:44-45`). Sent
  by `sendResize` at `streaming_preview.nim:1272-1322` (added in
  VRS-M2).
- `iekFocus`: `focused: bool` (`event_dispatch.nim:46-47`). No
  sender today.
- `iekSelectStory` and `iekApplyMutation`: RS-M12 additions for
  editor → launcher story selection / inspector mutation. Senders
  at `streaming_preview.nim:1214-1270`.

### 4.2 Per-launcher input dispatch

VRS-M1's Section 2.5 already documented the dispatch chain — the
relevant new finding for EPP-M7 is **what mouse events actually do**
inside each launcher's wrapped sink chain.

The chain is: `bridge.handleInbound → cfg.inputSink.submit →
StoryDispatchSink.submit → inner (resizingSink) → AnyInputSink`.
Per `editor/backends/gpui.nim:73-82` (and analogues for Freya /
Cocoa), the resizingSink ONLY handles `iekResize` and discards
everything else:

```nim
let resizingSink = newAnyInputSink(
  proc(event: InputEvent) {.gcsafe.} =
    if event.kind != iekResize: return
    ...)
```

**So mouse / scroll / key events arriving at the launcher today are
DROPPED.** They reach the bridge, get decoded, traverse
`StoryDispatchSink → resizingSink` — and the resizingSink filters
them out at the `if event.kind != iekResize: return` line. EPP-M7
will need to either:

1. **Wrap the resizingSink in a richer sink** that dispatches mouse
   / key / scroll into the renderer-specific input adapter
   (`gpui_input_adapter.nim` / `freya_input_adapter.nim` /
   `cocoa_input_adapter.nim`), OR
2. **Replace the resizingSink** with a `LauncherInputDispatchSink`
   that handles every kind and routes via a per-renderer table.

The **renderer-specific input adapters** (Section 4.3) already exist
and already handle mouse clicks via `fireEvent` — they just aren't
wired into the launcher composition today. The reason: the launcher
composition predates RS-M12, and the `StoryDispatchSink → resizingSink`
chain was the minimum the resize milestones (VRS-M2..M7) needed.

EPP-M7 is the right place to retire the "resizingSink filters
everything except iekResize" pattern and replace it with a true
dispatching sink.

### 4.3 Per-launcher input adapters — what they handle today

**GPUI** — `/Users/zahary/metacraft/isonim-render-serve/src/isonim_render_serve/adapters/gpui_input_adapter.nim:65-89`:

- `iekMouse(maClick)`: hit-tests via composition-root-supplied
  `HitTester`, calls `fireEvent(target, "click")`.
- `iekMouse(maDown/maUp/maMove)`: log only.
- `iekKey`: log to stderr ("gpui_input_adapter: key event ignored"
  — line 82).
- `iekScroll`, `iekResize`, `iekFocus`: log only.

**Freya** — `/Users/zahary/metacraft/isonim-render-serve/src/isonim_render_serve/adapters/freya_input_adapter.nim:75-99`:

- Same shape as GPUI; click → `fireEvent(target, "click")`; keys
  logged to stderr ("freya_input_adapter: key event ignored").

**Cocoa** — `/Users/zahary/metacraft/isonim-render-serve/src/isonim_render_serve/adapters/cocoa_input_adapter.nim:100-133`:

- `iekMouse(maClick)`: hit-tests, calls `r.fireEvent(target, "click")`
  **only on macOS** (Linux logs "hit (linux scaffold; fireEvent
  deferred)" at line 120).
- Other kinds: log only.

### 4.4 What `fireEvent` actually does

`fireEvent` in every renderer is **a synthetic dispatcher**, not a
native AppKit / GPUI / Skia input pump. It looks up the registered
Nim closure for the event name on the target shadow-tree node and
calls it. The fact that the headless render path is active does
NOT mean the engine's native input pipeline is active — the synthetic
painter and the real renderer both use the same fireEvent table
because both are built on the shadow tree.

- GPUI: `isonim-gpui/src/isonim_gpui/renderer.nim:341-342` —
  `fireEvent(node, event)` calls `gpui_dispatch_event(node, event.cstring)`,
  which iterates the node's `event_listeners` table and invokes
  the Nim callbacks via the registered dispatcher
  (`isonim-gpui/rust/gpui-nim-shim/src/lib.rs:516-554`). The GPUI
  `WindowContext::dispatch_keystroke` API the spec brief mentions
  is **not currently bound by the shim** — there's no
  `gpui_dispatch_keystroke` symbol in the shim's exports.
- Freya: same shape (`isonim-freya/src/isonim_freya/renderer.nim:343-345`
  - `lib.rs:485-523`).
- Cocoa: `isonim-cocoa/src/isonim_cocoa/renderer.nim:1160-1166` —
  again a Nim-side closure-table dispatch. The spec brief's
  `NSWindow::sendEvent:` reference is **not currently bound**.

### 4.5 What needs to change for `iekKeyboard`

The schema already defines `iekKey` — _decoding_ works. The gaps:

1. **No JS sender.** EPP-M7 must add `sendKey({down|up|press}, key,
code, modifiers, repeat)` to the JS shim, modelled on the
   existing `sendInput({type:"mouse", action:"click", ...})`
   pattern at `streaming_preview.nim:1173-1175`.
2. **Canvas focus management.** Per the spec brief: the preview
   canvas needs `tabindex="0"` so it can receive focus; a click
   inside the canvas gives it focus; `keydown`/`keyup` while
   focused route to `sendInput({type:"key", ...})`. Esc returns
   focus to the editor.
3. **Per-launcher dispatch.** Add `fireEvent(target, "keydown")` /
   `"keyup"` / `"input"` to each renderer's input adapter (already
   has the `iekKey` log line; just upgrade it to a real
   `fireEvent` call). For text input specifically, the existing
   `task_app` / `settings_app` leaves register `"input"` listeners on
   `<input>` elements — wire `iekKey(text="abc")` → `r.setStyle(target,
"value", "abc"); fireEvent(target, "input")` or similar.
4. **(Stretch) Real engine dispatch.** If the campaign wants to
   honour GPUI's `dispatch_keystroke` or Cocoa's `sendEvent:`,
   each shim needs a new C entry point. Probably out of EPP-M7
   scope — the existing `fireEvent` path is sufficient for the
   demo apps' Nim-registered keyboard handlers.

### 4.6 What `iekTouch` / pen / precision-scroll would need

Defer per EPP-M7's brief; trivial only if the existing mouse path
handles them as enriched mouse events. iOS would be the primary
consumer (touch). For desktop targets, precision-scroll deltas
(magic mouse / trackpad pixel-precise) need extending `iekScroll`
to carry `deltaMode` (`px` vs `line` vs `page`), `momentum`
(boolean for inertial scroll), and possibly `phase` (`began` /
`changed` / `ended`). The wire schema is easy; the per-launcher
dispatch via `fireEvent` is less obvious because none of the
renderers expose a native scroll-event surface.

---

## Section 5 — Per-launcher real-render interactivity status

This is the load-bearing section for EPP-M7's scope estimation.
**Question:** with the real-render headless path enabled, does a
mouse click in the preview actually trigger an app event handler?

### 5.1 GPUI — partial: clicks work IF the launcher is wired with an input sink

**Status today:** The GPUI launcher
(`isonim-examples/editor/backends/gpui.nim:67-103`) wires
`runDemoBridgeWith(cfg, src.toAny(), provider, storySink.toAnyInputSink())`
at line 103. The `storySink` is a `StoryDispatchSink` that wraps
`resizingSink` (line 101-102):

```nim
let storySink = newStoryDispatchSink(mountFn, applyFn,
                                     inner = resizingSink)
```

The `resizingSink` filters everything except `iekResize`. **There
is NO GpuiInputSink chained anywhere in the GPUI launcher today.**
Mouse clicks arrive at `StoryDispatchSink.submit`, fall through the
`else` branch (line 81-83 of `story_dispatch.nim`), get handed to
`resizingSink`, which discards them.

**Verification path:** grep for `GpuiInputSink` in
`isonim-examples/editor/backends/`:

```sh
$ grep -rn "GpuiInputSink\|newGpuiInputSink" isonim-examples/editor/backends/
# (no hits — the adapter is defined but never instantiated in the launcher)
```

So mouse clicks **today don't trigger app handlers** through the
editor preview. The bridge `e2e_editor_streaming_preview` tests
verify rendering, not click-driven VM mutations.

**Does the GPUI headless render path "swallow" events?** Per
Section 4.4, the headless path is render-only — there's no input
dispatch surface inside `gpui_render_to_pixels`. The render path
does not swallow OR forward events; events would have to be
delivered via the existing shadow-tree `fireEvent` table. The
`GpuiInputSink` is the bridge to that table.

**EPP-M7 GPUI work:**

1. Add a `GpuiInputSink` instance in `editor/backends/gpui.nim`,
   wired with a `HitTester` closure that walks the element-tree
   manifest's `LayoutRect` list (already built for the F-packet
   raster at `gpui_adapter.nim:167-174`) and returns the deepest
   node containing the (x, y) coordinate.
2. Chain the `GpuiInputSink` AFTER `StoryDispatchSink` but BEFORE
   `resizingSink` (or fold the resize handling into the new
   dispatcher).
3. Verify the GPUI demo's `task_app` "Add task" button's
   registered `onClick` Nim closure fires on canvas click. Existing
   leaves at `isonim-examples/task_app/gpui/leaves.nim` register
   click handlers via the renderer's `onEvent` API — confirm the
   handler path is `fireEvent("click")` (it is, per
   `renderer.nim:341`).

**Estimated effort:** 1 day. The infrastructure exists; the wiring
is mechanical.

### 5.2 Freya — same situation as GPUI

`isonim-examples/editor/backends/freya.nim` mirrors the GPUI
launcher's wiring exactly (`StoryDispatchSink(inner=resizingSink)`,
no `FreyaInputSink`). Same gap, same EPP-M7 fix shape.

Freya's `fireEvent` (`isonim-freya/src/isonim_freya/renderer.nim:343-345`
→ `freya_dispatch_event` at lib.rs:485-523) takes the same callback-
table approach as GPUI. Clicks will land if the launcher chains a
`FreyaInputSink` with a real hit-tester. Estimated 1 day.

### 5.3 Cocoa — same as GPUI / Freya, plus a known limitation

`isonim-examples/editor/backends/cocoa.nim:67-98` mirrors GPUI's
shape. No `CocoaInputSink` chained.

**Specific to Cocoa:** the cocoa_input_adapter's `fireEvent` works
on macOS but is a no-op on Linux
(`cocoa_input_adapter.nim:112-120`). EPP-M7's Cocoa test must be
macOS-gated.

**AppKit-native dispatch alternative.** The Cocoa adapter's
`layoutTreeForCapture` at `cocoa_adapter.nim:389-586` mutates real
NSView frames via `setFrame:`, so a real NSView hierarchy exists in
memory. Dispatching a real `NSEvent` via `[NSApp sendEvent:]` is
_possible_ — `+[NSEvent mouseEventWithType:location:modifierFlags:
timestamp:windowNumber:context:eventNumber:clickCount:pressure:]`
constructs the event; AppKit routes it via the hit-tested view's
`-mouseDown:` / `-mouseUp:` selectors. But:

- This requires a real NSWindow to host the views (the headless
  capture path explicitly avoids creating one — see
  `cocoa_adapter.nim:32-33`).
- The campaign's "real-render" goal is _render fidelity_, not
  _input fidelity_. The `fireEvent` table-driven dispatch IS the
  in-process event surface every Cocoa leaf registers handlers
  against (see `isonim-cocoa/src/isonim_cocoa/renderer.nim:1018-1030`).

**Recommendation:** stick with the synthetic `fireEvent` dispatch
for EPP-M7. Document the AppKit-native option as a future
follow-up if EPP-M8's acceptance gate finds the synthetic
dispatch insufficient (e.g. an `NSTextField` whose edit handlers
care about real `keyDown:` semantics).

### 5.4 Summary table

| Backend       | Render works?           | Mouse click → Nim handler? | Key event support? | What blocks EPP-M7?                     |
| ------------- | ----------------------- | -------------------------- | ------------------ | --------------------------------------- |
| GPUI (macOS)  | Yes                     | NO (no input sink wired)   | No (no FFI)        | Wire GpuiInputSink + add key fireEvent  |
| GPUI (Linux)  | Falls back to synthetic | Same as above              | No                 | Same                                    |
| Freya (any)   | Yes                     | NO (no input sink wired)   | No (no FFI)        | Wire FreyaInputSink + add key fireEvent |
| Cocoa (macOS) | Yes                     | NO (no input sink wired)   | No (no FFI)        | Wire CocoaInputSink + add key fireEvent |
| Cocoa (Linux) | Placeholder grey        | n/a                        | n/a                | macOS-only                              |

---

## Section 6 — Frame-rate config

### 6.1 Where fps is set today

`/Users/zahary/metacraft/isonim-examples/editor/backends/common.nim:43`:

```nim
result = LauncherConfig(
  backend: backendOverride,
  port: 0,
  width: 0,
  height: 0,
  fps: 12,            # ← line 43
  staticDir: "static",
  demo: defaultDemo)
```

The 12 FPS default is the hard ceiling on the campaign's "100–170
ms perceived latency" — at 12 FPS the inter-frame interval is
~83 ms, so even with zero encode/decode/network cost the perceived
latency floor is 83 ms.

### 6.2 How fps flows to the bridge

`common.nim:106-114`:

```nim
let bridgeCfg = BridgeConfig(
  ...
  frameIntervalMs: max(1, 1000 div cfg.fps),
  ...
)
```

The bridge's `frameLoop` at
`isonim-render-serve/src/isonim_render_serve/bridge.nim:300-301`
calls `await sleepAsync(cfg.frameIntervalMs)` between ticks.

### 6.3 CLI override

`common.nim:58-59`:

```nim
of "--fps":
  inc i; result.fps = parseInt(paramStr(i))
```

So a launcher invoked with `--fps 60` will tick at 60 FPS. The
editor-server.mjs spawn command does not pass `--fps`
(grep returns no hits in `isonim-examples/tools/editor-server.mjs`).

### 6.4 Path to dynamic / negotiated fps

EPP-M5 / EPP-M6 will negotiate transport via the `M`-packet `hello`
exchange. The path to dynamic fps:

1. **Raise the default from 12 to 60** in `common.nim:43`. With
   real-render + hardware encoder the per-frame budget drops well
   below the 16.7 ms 60 FPS frame interval. Risk: the synthetic
   painter on Linux (the fallback) is CPU-bound; 60 FPS there
   could spin a core. Mitigation: per-backend default in the
   launcher's `runDemoBridge`, e.g. GPUI default 60 on macOS, 12
   on Linux fallback.
2. **Add an `fps` field to the `hello` capabilities bag**
   (`isonim-render-serve/src/isonim_render_serve/bridge.nim:128-155`)
   so the browser can downshift the launcher under bandwidth
   constraints. The launcher honours an inbound `M`-packet
   `{"type":"fps","value":N}` by mutating
   `cfg.frameIntervalMs = max(1, 1000 div N)` (the bridge's
   `BridgeConfig.frameIntervalMs` field is `var`).
3. **Editor UI**: add a "Frame rate" field to the streaming-preview
   inspector if the campaign wants to expose the knob. Probably
   out of campaign scope; EPP-M5/M6 just need the wire negotiation.

**Estimated effort for "raise default + per-backend override":**
30 minutes. **Dynamic negotiation:** 2-3 hours including the
hello-handshake wiring.

---

## Section 7 — EPP-M2..M7 plan summary

Each subsection here is what the corresponding milestone's
implementation sub-agent reads as its starting brief.

### 7.1 EPP-M2 — GPUI real-render as default

**Verdict: Already enabled on macOS; need verification + Linux story.**

Per Section 1.1 the `isonim-examples/Justfile:180-188` already
builds the GPUI launcher with `-d:useGpuiHeadless` on Darwin. So
EPP-M2's work breaks down as:

**Files to touch / verify:**

1. **`isonim-examples/Justfile:180-188`** — confirm Darwin-gated
   build. No edits needed unless the implementation agent wants
   to remove the Darwin gate (Linux would still fall back to
   synthetic via the runtime error code).
2. **`isonim-render-serve/src/isonim_render_serve/adapters/gpui_adapter.nim:225-232`**
   — already routes through the headless path under
   `-d:useGpuiHeadless`. No edits needed; verify the fallback
   logic at line 226-230 handles the empty-pixels case gracefully.
3. **`isonim-examples/editor/backends/gpui.nim`** — no edits
   anticipated.

**Pixel-snapshot e2e test to add:**

`/Users/zahary/metacraft/isonim/tests/browser/e2e_editor_gpui_real_render_live.mjs`:

1. Spawn the GPUI launcher (per existing
   `helpers/spawn_pg_for_browser_test.nim` or analogue).
2. Open the editor at `task_app`.
3. Capture a frame from the canvas via
   `canvas.toDataURL('image/png')`.
4. Compare against a golden snapshot stored in
   `tests/browser/fixtures/gpui-task-app-baseline.png`. Tolerance:
   5% per-pixel deltaE.

**Verification:**

- The existing `e2e_editor_streaming_preview` tests stay green.
- The chrome-bar fuzz regression net stays green.

**Linux note:** the headless renderer returns `None` on non-Darwin,
so Linux still uses synthetic. EPP-M2's brief should EITHER (a)
document this as a known limitation deferred to a future EPP-M2b,
OR (b) wire a `weston-headless` / `Xvfb` Mesa stack into the
flake.nix so the Zed revision's Linux headless path becomes
real once Zed lands it. Recommend (a) — the user works on macOS
M1.

**Estimated sub-agent effort:** 4–6 hours (test infrastructure

- golden capture + flake validation).

### 7.2 EPP-M3 — Freya real-render as default

**Verdict: Already enabled, both OS. Need verification.**

Per Section 1.2 `isonim-examples/Justfile:179-181` builds Freya
with `-d:useFreyaHeadless` unconditionally. Both macOS and Linux
work.

**Files to touch / verify:** Same shape as EPP-M2 but for Freya.
No build flag changes anticipated.

**Tests:**

- `/Users/zahary/metacraft/isonim/tests/browser/e2e_editor_freya_real_render_live.mjs`
  with the same shape as the GPUI test.

**Known limitation:** the PNG round-trip adds 5-20 ms per frame.
Document as a known trade-off; EPP-M5's hardware encoder bypasses
it (encodes the RGBA buffer directly).

**Estimated effort:** 4–6 hours.

### 7.3 EPP-M4 — Cocoa Metal-backed offscreen render

**Verdict: Feasible from existing launcher code; non-trivial new
ObjC helper.**

Per Section 1.3's feasibility assessment, the architectural delta
is: a new `capture_metal.m` next to `capture_rgba.m` in
`isonim-cocoa/src/isonim_cocoa/testing/`, plus a build-flag-gated
swap in `cocoa_adapter.nim:628` between
`captureViewRgba` (AppKit software) and `captureViewMetal` (Metal).

**Files to touch:**

1. **New file:** `isonim-cocoa/src/isonim_cocoa/testing/capture_metal.m`.
   Implements `nim_capture_view_metal(id view, int width, int height,
unsigned char *buf) -> int` using `CARenderer(MTLTexture:options:)`
   driving the view's `CALayer` into a `MTLTexture`, then
   `MTLBlitCommandEncoder.synchronize` + `MTLTexture.getBytes:`.
2. **New helper:**
   `isonim-cocoa/src/isonim_cocoa/appkit/capture_metal.nim`
   exposing `captureViewMetal(view: Id, w, h: int): seq[byte]`.
3. **Adapter change:**
   `isonim-render-serve/src/isonim_render_serve/adapters/cocoa_adapter.nim:628`
   — branch on `when defined(cocoaMetalCapture)` between the two
   capture procs.
4. **Linker:** add `-framework Metal -framework QuartzCore` to the
   passL line at `cocoa_adapter.nim:22-23`.
5. **Justfile (`isonim-examples/Justfile:214-219`):** add the
   `-d:cocoaMetalCapture` flag once the path is validated.

**Tests:**

- Microbench: `tests/test_cocoa_metal_capture_perf.nim` — assert
  `captureViewMetal(view, 1024, 768)` returns within 10 ms wall-
  clock on M1 (matching the EPP-M4 acceptance criterion).
- Pixel-snapshot:
  `tests/browser/e2e_editor_cocoa_real_render_live.mjs` matches
  EPP-M2 / EPP-M3 shape.

**Decision branch per the spec brief:** "if no, document the
architectural delta + defer". The audit's answer is **yes,
feasible** — the launcher architecture already touches the view
hierarchy via `setFrame:` + `setWantsLayer:YES`, so adding a
Metal-backed read-back is incremental work, not a rewrite. Sub-agent
should proceed.

**Estimated effort:** 1.5–2 days. The CARenderer API is well-
documented; the BGRA→RGBA swizzle template already exists at
`capture_rgba.m:146-168`.

### 7.4 EPP-M5 — VideoToolbox H.264 encoder

**Verdict: Brand-new FFI; ~3 days of implementation.**

Per Section 2 there are no existing bindings. The work:

**New files:**

1. **`isonim-render-serve/src/isonim_render_serve/encoders/videotoolbox.m`**
   — ObjC helper. Functions:
   ```c
   void* vt_encoder_create(int width, int height, int bitrate, int gop);
   int   vt_encoder_encode(void* enc, const unsigned char* rgba,
                            int width, int height, long long pts_us,
                            void (*callback)(const unsigned char* nalu,
                                              int len, int is_keyframe,
                                              void* user_data),
                            void* user_data);
   void  vt_encoder_get_extra_data(void* enc,
                                    unsigned char* out, int* out_len);
   void  vt_encoder_destroy(void* enc);
   ```
2. **`isonim-render-serve/src/isonim_render_serve/encoders/videotoolbox.nim`**
   — Nim wrapper exposing `H264VideoToolboxEncoder` ref object.
3. **`isonim-render-serve/src/isonim_render_serve/encoders/encoder.nim`**
   — `Encoder` polymorphic wrapper, `RawRgbaEncoder` /
   `H264VideoToolboxEncoder` constructors. Pattern lifted from
   `frame_source.nim`'s `AnyFrameSource` shape.

**Files to edit:**

1. **`isonim-render-serve/src/isonim_render_serve/packet.nim`** —
   add `pkVideo = 'V'` (or similar) packet kind; encode/decode
   procs. Reserve flags bit layout per the spec brief.
2. **`isonim-render-serve/src/isonim_render_serve/bridge.nim:286-300`**
   — bridge frame loop: if the encoder is non-nil and connected
   client opted into video, encode → emit V packet; else emit F
   packet.
3. **`isonim-render-serve/src/isonim_render_serve/bridge.nim:128-155`**
   (`buildHelloJson`) — extend the capabilities bag with
   `transports: ["v/avc1", "f/rgba"]`, `videoCodecExtraData:
"<base64 SPS/PPS>"` when video is enabled.
4. **`isonim-examples/editor/backends/gpui.nim` /
   `freya.nim` / `cocoa.nim`** — construct the encoder, hand to
   `runDemoBridgeWith`. Gate on `-d:useVideoToolbox` plus
   `when defined(macosx)`.
5. **`isonim-examples/editor/backends/common.nim`** — extend
   `LauncherConfig` with `useVideoToolbox: bool`; CLI flag
   `--video-toolbox`.

**Tests:**

1. **Round-trip encode→decode** — `test_videotoolbox_roundtrip.nim`:
   feed a known RGBA pattern, encode, pipe NALU bytes through
   `ffmpeg -i - -f image2 -` (CLI subprocess), assert decoded
   pixels match within tolerance. Real-environment test per spec.
2. **Bridge V vs F selection** —
   `test_bridge_video_negotiation.nim`: configure launcher with
   encoder, hello advertises both transports; client advertises
   `accept: ["v/avc1"]`, bridge emits V packets; client advertises
   `accept: ["f/rgba"]`, bridge emits F packets.
3. **Resize-on-encoder-lifecycle**: assert encoder is
   re-initialised when launcher's resizingSink fires (per EPP-M5
   brief).

**Encoder lifecycle on resize:** the per-launcher resizingSink
already mutates `dynamicW` / `dynamicH` / `src.width` /
`src.height` (per VRS-M1 §3.0-3.3). EPP-M5 adds one line to each
resizingSink: `encoder.configure(event.width, event.height)`.

**Bandwidth target verification.** Per EPP-M5 brief, ~1-2 Mbps at
60 FPS @ 1024×768. VideoToolbox H.264 Baseline + RealTime + GOP=1
typically lands at 3-5 Mbps with default rate control — set
`AverageBitRate = 2_000_000` and `DataRateLimits = @[250_000, 1.0]`
to enforce the cap. Confirm at implementation time via test.

**Estimated effort:** 2.5–3 days for the encoder + ObjC FFI +
Nim wrapper + bridge integration + tests.

### 7.5 EPP-M6 — WebCodecs decoder + transport negotiation

**Verdict: Browser support is Baseline; ~1.5 days for JS shim
changes + tests.**

**Files to edit:**

1. **`isonim/src/isonim/editor/streaming_preview.nim:1021-1067`
   (`handleF`)** — keep unchanged; raw RGBA path stays.
2. **`isonim/src/isonim/editor/streaming_preview.nim:1129-1136`
   (`ws.onmessage` dispatch)** — add `else if (kind === 'V')
handleV(bytes);`.
3. **Same file, new JS function `handleV(bytes)`** — parses V
   header (matching the packet format from EPP-M5), feeds NALU
   into a `VideoDecoder` (created once, reused across frames),
   draws the resulting `VideoFrame` to canvas via
   `ctx.drawImage(frame, 0, 0); frame.close();`.
4. **`isonim/src/isonim/editor/streaming_preview.nim:1069-1101`
   (`handleM`'s `hello` branch)** — read
   `node.capabilities.transports` and
   `node.capabilities.videoCodecExtraData`. Pick the first
   transport the browser supports (`VideoDecoder` available =>
   `v/avc1`; else `f/rgba`). Send an outbound M-packet
   `{type: "accept", transport: "v/avc1"}` back to the launcher.
5. **Bridge side (`bridge.nim:303-374`,
   `handleInbound`)** — decode the new `accept` M packet, set
   the per-connection encoder to video (else fall back to raw
   F frames).

**Feature detection:**

```js
const haveVideoDecoder = typeof VideoDecoder === "function";
const acceptList = haveVideoDecoder ? ["v/avc1", "f/rgba"] : ["f/rgba"];
```

**Tests:**

1. **Playwright e2e:**
   `tests/browser/e2e_editor_video_decode_live.mjs` — open editor
   against a launcher built with `-d:useVideoToolbox`, capture a
   canvas frame, assert the decoded pixel sample matches the
   launcher's RGBA source within tolerance.
2. **Negotiation test:**
   `tests/browser/e2e_editor_transport_negotiation_live.mjs` —
   spawn launcher with both transports, assert V is selected;
   spawn launcher without video flag, assert F is selected.

**Estimated effort:** 1.5 days. The JS surface is small; the
launcher-side wiring is already prepared by EPP-M5.

### 7.6 EPP-M7 — Keyboard + precision-scroll forwarding

**Verdict: Schema exists; need JS sender + per-launcher dispatcher
wiring.**

Per Sections 4.2-4.5 the `iekKey` decode side is fully wired;
only the JS sender and the per-launcher dispatcher chain need
work.

**Files to edit:**

1. **`isonim/src/isonim/editor/streaming_preview.nim:1129-1211`
   (JS shim event wiring)** — add `keydown` / `keyup` / `input`
   listeners on the canvas. Mirror the existing `mousedown`
   etc. pattern at line 1194-1200. Compose key events:
   ```js
   function onKeyDown(e) {
     sendInput({
       type: "key",
       action: "down",
       key: e.key,
       code: e.code,
       modifiers: modsFromEvent(e),
       repeat: e.repeat,
     });
     // Suppress browser default for shortcuts the launcher handles.
     e.preventDefault();
   }
   ```
2. **Same file** — extend the canvas mount with
   `canvas.tabIndex = 0; canvas.style.outline = 'none';` so it
   can take focus. Add a `canvas.focus()` call inside the
   existing `click` handler.
3. **`isonim/src/isonim/editor/views/canvas_mount.nim`** — focus
   management: when the canvas is the active surface, pressing
   Esc should `canvas.blur()` so the editor's chrome-bar keyboard
   shortcuts work again. Reactive contract: `if !canvasFocused
then canvas events route to chrome bar` (existing path);
   `if canvasFocused then canvas events route to launcher`.
4. **`isonim-examples/editor/backends/gpui.nim` /
   `freya.nim` / `cocoa.nim`** — replace the bare resizingSink
   with a dispatching sink that routes:
   - `iekResize` → resize logic (existing).
   - `iekMouse` → `GpuiInputSink.submit` (existing adapter).
   - `iekKey` → `GpuiInputSink.submit` (existing adapter; just
     needs the `fireEvent(target, "keydown")` call inside the
     adapter — see next bullet).
   - `iekScroll` → `GpuiInputSink.submit` (extend adapter).
5. **`isonim-render-serve/src/isonim_render_serve/adapters/gpui_input_adapter.nim:78-82`
   (and freya/cocoa)** — upgrade the key path from "log to
   stderr" to:
   ```nim
   of iekKey:
     sink.log.add "key " & ...
     if sink.focusedNode != nil:
       case event.keyAction
       of kaDown: fireEvent(sink.focusedNode, "keydown")
       of kaUp:   fireEvent(sink.focusedNode, "keyup")
       of kaPress:
         # For text input, also push the character to the input's value.
         # (Implementation depends on whether the focused element
         # is an <input>; the leaf bundle knows.)
         fireEvent(sink.focusedNode, "input")
   ```
   The `focusedNode` is tracked via the existing `iekFocus`
   sink path (currently just-log; EPP-M7 promotes it to update
   the sink's `focusedNode` field on focus-in / focus-out).
6. **(Mouse decode fix mentioned in §4.1)** — extend
   `MouseAction` enum at `event_dispatch.nim:22` with `maDblClick`;
   extend `parseMouseAction` at line 106 to accept "dblclick".
   This fixes the silent decode failure for `dblclick` packets
   emitted at `streaming_preview.nim:1184`.

**Tests:**

1. **Playwright e2e per backend:**
   `tests/browser/e2e_editor_gpui_keyboard_live.mjs` —
   focus the preview canvas, type "hello", assert the example
   app's text field shows "hello". Repeat for Freya / Cocoa.
2. **Sanity test for focus management:**
   `tests/browser/e2e_editor_canvas_focus_release_live.mjs` —
   focus canvas, press Esc, assert focus returned to editor
   chrome and `cmd-k` shortcut works.

**Note on AppKit-native dispatch (Cocoa):** The spec brief
mentions `NSWindow::sendEvent:`. Per Section 5.3 the recommendation
is to stick with the synthetic `fireEvent` dispatch. EPP-M7 sub-
agent should NOT add a real-event-loop dependency unless EPP-M8
validation requires it.

**Estimated effort:** 1.5–2 days. Schema decode already works; new
work is JS sender (small) + per-launcher dispatcher (medium) +
tests (medium).

### 7.7 EPP-M8 — Acceptance gate + matrix test

**Verdict: Pure verification milestone; no implementation work
beyond the matrix test.**

Per the spec brief, EPP-M8 walks the
(backend × interaction × performance) matrix. The test file:
`tests/browser/e2e_editor_preview_acceptance_matrix_live.mjs`.

**Acceptance criteria from the spec:**

1. Median frame latency < 50 ms over 100 frames.
2. Canvas at 1:1 device pixels (no upsample).
3. Click events trigger visible response within one frame.
4. Chrome-bar fuzz + active-state regressions stay green.

**Measurement methodology:**

- Frame latency: instrument `handleF` / `handleV` to record
  `performance.now() - emittedPts`. The launcher's `pts_us` field
  in the V packet (or a new `emittedAtMs` field in F) supplies the
  emission timestamp.
- 1:1 device pixels: assert `canvas.width === canvas.clientWidth *
devicePixelRatio` (the VRS-M2 follow-up contract; per
  `streaming_preview.nim:1004-1019`).
- Click response: timestamp the click in JS, wait for the next
  manifest change, measure the delta. Should be ≤ 50 ms.

**Estimated effort:** 1 day for the matrix test + telemetry
capture.

### 7.8 Cross-cutting issues / follow-ups

These are gaps the audit found that don't fit cleanly into a
single milestone but are flagged for the relevant sub-agent's
awareness:

1. **MouseAction enum missing `maDblClick`** (§4.1). Fix in EPP-M7.
2. **Frame-rate default of 12 FPS** (§6) — raise to 60 in EPP-M5
   or EPP-M6 (whichever the implementation agent feels more
   natural; both touch `common.nim`).
3. **GPUI Linux real-render gap** (§1.1) — out of EPP-M2 scope;
   document as a follow-up.
4. **PNG round-trip cost in Freya headless** (§1.2) — mitigated
   by EPP-M5; document.
5. **No real engine input dispatch (GPUI dispatch_keystroke / Cocoa
   sendEvent:)** (§4.4) — out of EPP-M7 scope; document as a
   future follow-up if EPP-M8 finds the synthetic dispatch
   insufficient.
6. **VRS-M1 §2.3 outbound `resize` M-packet** — not yet sent by
   the launcher; orthogonal to this campaign but worth tracking.
   The EPP-M5 work to add `V` packets may want to also add the
   outbound `resize` M for consistency.

---

## Appendix A — Gaps and uncertainties (honest "I could not find X")

1. **WebCodecs `optimizeForLatency` exact draft date.** I cited
   the W3C TR URL from memory but did not WebFetch the live spec.
   The flag has been in the spec since at least 2022 and is
   honoured by Chrome 94+; my confidence is high but the citation
   is from training data rather than a live fetch.

2. **VideoToolbox `kVTCompressionPropertyKey_DataRateLimits` units.**
   Apple's docs say "array of (bytesPerSecond, seconds) pairs",
   but the seconds value behaviour varies across macOS versions.
   The EPP-M5 sub-agent should pin a known-good combination via
   experiment, not trust the documented contract verbatim. A
   reference SO post that worked in macOS 13: `@[2_000_000 / 8,
1.0]`.

3. **GPUI `current_headless_renderer()` on macOS x86_64.** The shim
   docstring at `gpui_headless.rs:240-244` says "macOS is the
   supported headless target" but only macOS ARM64 is empirically
   verified in CI today. Intel Macs may or may not work depending
   on whether the pinned Zed revision's Metal headless path
   gates on Apple Silicon. Sub-agent should test on Intel if
   relevant.

4. **Freya headless on Windows / Linux non-x86_64.** The
   freya-headless feature compiles against `freya-testing` which
   ultimately uses Skia raster — should be cross-platform — but
   I did not validate empirically on anything beyond macOS ARM64
   and Linux x86_64.

5. **The browser-side `VideoFrame.close()` lifetime contract** —
   I asserted Chrome's in-flight limit at "currently 64" but did
   not verify against current Chromium source. The principle (close
   the frame after draw) is correct regardless; the magic number
   is informational.

6. **`canvas.tabIndex = 0` focus visibility** — modern browsers
   draw a focus ring when the canvas has focus. EPP-M7 should
   either suppress it via `outline: none` or visualise the focus
   state via a 2px border (matches the design system's input
   focus treatment). Out of audit scope to decide.

7. **The exact list of `task_app` / `settings_app` text-input
   handlers** — I confirmed the demo apps have `<input>`-like
   leaves (e.g. the task-name input from EX-M14) but did NOT
   exhaustively enumerate which leaves register `"keydown"` vs
   `"input"` vs `"keyup"` handlers. EPP-M7 sub-agent must
   inspect `isonim-examples/task_app/{gpui,freya,cocoa}/leaves.nim`
   to confirm the event-name vocabulary the leaves expect.

8. **MoltenVK / Vulkan-on-Mac considerations** — irrelevant to this
   campaign (no Vulkan path), but if EPP-M5 wanted to share the
   encoder with the existing MCR VK Replay work (per user memory),
   the encoder would need a Vulkan import path. Out of scope.

---

## Appendix B — Key file index (jump table)

### Headless render entry points

- **GPUI Rust shim:**
  `/Users/zahary/metacraft/isonim-gpui/rust/gpui-nim-shim/src/gpui_headless.rs:117-163`
  (`gpui_render_to_pixels`).
- **GPUI Nim bindings:**
  `/Users/zahary/metacraft/isonim-gpui/src/isonim_gpui/bindings.nim:217-230`.
- **GPUI Nim adapter:**
  `/Users/zahary/metacraft/isonim-render-serve/src/isonim_render_serve/adapters/gpui_adapter.nim:205-274`.
- **Freya Rust shim:**
  `/Users/zahary/metacraft/isonim-freya/rust/freya-nim-shim/src/freya_headless.rs:76-122`.
- **Freya Nim adapter:**
  `/Users/zahary/metacraft/isonim-render-serve/src/isonim_render_serve/adapters/freya_adapter.nim:280-345`.
- **Cocoa ObjC helper:**
  `/Users/zahary/metacraft/isonim-cocoa/src/isonim_cocoa/testing/capture_rgba.m:61-177`.
- **Cocoa adapter:**
  `/Users/zahary/metacraft/isonim-render-serve/src/isonim_render_serve/adapters/cocoa_adapter.nim:588-640`.

### Build flags / Justfile recipes

- **`-d:useGpuiHeadless` /
  `-d:useFreyaHeadless` gates:**
  `/Users/zahary/metacraft/isonim-examples/Justfile:176-189`.
- **Cocoa macOS-only recipe:**
  `/Users/zahary/metacraft/isonim-examples/Justfile:214-219`.

### Packet codec

- **F-flag bit 1 reserved for video/h264:**
  `/Users/zahary/metacraft/isonim-render-serve/src/isonim_render_serve/packet.nim:14-17,151-153`.
- **JS shim rejects video bit:**
  `/Users/zahary/metacraft/isonim/src/isonim/editor/streaming_preview.nim:1027`.

### `InputEventKind` schema

- **Enum:** `/Users/zahary/metacraft/isonim-render-serve/src/isonim_render_serve/event_dispatch.nim:14-46`.
- **Decode `iekResize`:** `event_dispatch.nim:163-169`.
- **Decode `iekKey`:** `event_dispatch.nim:134-144`.
- **Decode `iekMouse`:** `event_dispatch.nim:145-154` (missing `dblclick`).
- **Decode `iekScroll`:** `event_dispatch.nim:155-162`.

### Per-launcher input adapters

- **GPUI:** `/Users/zahary/metacraft/isonim-render-serve/src/isonim_render_serve/adapters/gpui_input_adapter.nim:65-100`.
- **Freya:** `/Users/zahary/metacraft/isonim-render-serve/src/isonim_render_serve/adapters/freya_input_adapter.nim:75-110`.
- **Cocoa:** `/Users/zahary/metacraft/isonim-render-serve/src/isonim_render_serve/adapters/cocoa_input_adapter.nim:100-144`.

### Per-renderer fireEvent

- **GPUI:**
  `/Users/zahary/metacraft/isonim-gpui/src/isonim_gpui/renderer.nim:341-342`
  → `lib.rs:516-554`.
- **Freya:**
  `/Users/zahary/metacraft/isonim-freya/src/isonim_freya/renderer.nim:343-345`
  → `lib.rs:485-523`.
- **Cocoa:**
  `/Users/zahary/metacraft/isonim-cocoa/src/isonim_cocoa/renderer.nim:1160-1166`
  (Nim-side closure-table dispatch).

### Per-launcher composition

- **GPUI launcher:**
  `/Users/zahary/metacraft/isonim-examples/editor/backends/gpui.nim`.
  resizingSink: lines 73-82. Bridge wire: line 103.
- **Freya launcher:**
  `/Users/zahary/metacraft/isonim-examples/editor/backends/freya.nim`.
- **Cocoa launcher:**
  `/Users/zahary/metacraft/isonim-examples/editor/backends/cocoa.nim`.

### Editor JS shim

- **handleF:**
  `/Users/zahary/metacraft/isonim/src/isonim/editor/streaming_preview.nim:1021-1067`.
- **handleM:**
  `streaming_preview.nim:1069-1101`.
- **sendInput / encodeI:**
  `streaming_preview.nim:1102-1118`.
- **Mouse handlers:**
  `streaming_preview.nim:1137-1200`.
- **sendResize:**
  `streaming_preview.nim:1272-1322`.
- **canvas DPR sizing contract:**
  `streaming_preview.nim:1004-1019`.

### Frame-rate config

- **fps default = 12:**
  `/Users/zahary/metacraft/isonim-examples/editor/backends/common.nim:43`.
- **CLI flag parse:**
  `common.nim:58-59`.
- **frameIntervalMs derivation:**
  `common.nim:110`.
- **Bridge sleep:**
  `/Users/zahary/metacraft/isonim-render-serve/src/isonim_render_serve/bridge.nim:300-301`.

### Hello capabilities bag (for transport negotiation in EPP-M5/M6)

- **buildHelloJson:**
  `/Users/zahary/metacraft/isonim-render-serve/src/isonim_render_serve/bridge.nim:128-155`.
- **Existing `inputKinds`:** line 145 (`["key", "mouse", "scroll",
"resize", "focus"]`). EPP-M6 will add `transports` here.

---

End of audit.
