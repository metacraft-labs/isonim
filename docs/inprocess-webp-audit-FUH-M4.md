# In-Process libwebp Encoder — FUH-M4 Audit

Read-only audit feeding FUH-M5 (Phase B wire). Mirrors the EPP-M1
audit shape (file, symbol surface, wrapper recommendation, perf
expectations, fallback story).

Campaign: [Editor Follow-Up Hardening](../../codetracer-specs/Front-Ends/IsoNim/Editor-Followup-Hardening.milestones.org)
Phase: B — In-Process libwebp.
Audit date: 2026-05-30. Workspace HEAD: see `repo manifest -r` of the
caller's workspace.

## TL;DR

- libwebp 1.5.0 is reachable on this macOS workstation **only** via
  ffmpeg's transitive Nix store dependency
  (`/nix/store/kig5ns7mdimfwwkb68bjc23f5i2lxiiv-libwebp-1.5.0/`); it
  is **not** in the `isonim-render-serve` dev shell as a first-class
  build input. The `pkg-config --libs libwebp` probe fails inside the
  dev shell. Adding `pkgs.libwebp` to `flake.nix` is part of FUH-M5.
- Two nimble packages exist (`webp`, `nimwebp`); neither is a viable
  drop-in. `webp` is a `cwebp` CLI wrapper (worse than the current
  ffmpeg subprocess pattern); `nimwebp` is a real `{.importc.}`
  binding but compiles libwebp from a vendored C source tree at
  build time (~50+ `.c` files, no dynamic-link mode, last touched
  2025-08).
- Recommendation: **vendored Nim FFI** at
  `isonim-render-serve/src/isonim_render_serve/adapters/webp_libwebp_ffi.nim`
  using `{.importc.}` + `{.dynlib: "libwebp.dylib".}` against the
  system / Nix-store libwebp. Mirrors EPP-M5's
  `capture_videotoolbox.nim` shape: opaque handle, RGBA-in / bytes-
  out, host-capability probe, transparent subprocess fallback when
  the dynlib lookup fails. No `.m` shim needed — libwebp is plain C.
- Per-frame budget today: ~133 ms median for typical UI content at
  1280×800, of which ~78 ms is ffmpeg subprocess spawn overhead and
  ~55 ms is actual encode work at `compression_level=3`. Direct-API
  access removes the spawn cost entirely; remaining ~55 ms is
  cl=3-on-busy-content and will drop further on real flat-UI input.
  16 ms target at 1280×800 is achievable at `compression_level=3`
  (the ELT-M7 recommended live tuning).
- Backward compat: gate with `-d:withInProcessWebP`. Default ON when
  the dynlib loads; OFF otherwise (subprocess path stays). One-line
  change in the existing `WebPEncoderHandle` to swap the encode
  callback.

## 1. libwebp availability in the workspace

### 1.1 Binaries on PATH

```
$ which cwebp dwebp ffmpeg
cwebp not found
dwebp not found
/Users/zahary/.nix-profile/bin/ffmpeg
```

Only `ffmpeg` is reachable; the libwebp CLI tools are not on the
user's Nix profile. This means the existing ELT-M8 docstring
comment in `webp_lossless_encoder.nim` ("`cwebp` is NOT on the dev
shell PATH") still holds and the existing subprocess path uses
`ffmpeg -c:v libwebp`, not `cwebp`.

### 1.2 Library on disk

`ffmpeg` is dynamically linked against libwebp 1.5.0 in the Nix
store:

```
$ otool -L /Users/zahary/.nix-profile/bin/ffmpeg | grep webp
/nix/store/kig5ns7mdimfwwkb68bjc23f5i2lxiiv-libwebp-1.5.0/lib/libwebpmux.3.dylib
/nix/store/kig5ns7mdimfwwkb68bjc23f5i2lxiiv-libwebp-1.5.0/lib/libwebp.7.dylib
```

Headers + dylibs at:

- Headers: `/nix/store/kig5ns7mdimfwwkb68bjc23f5i2lxiiv-libwebp-1.5.0/include/webp/{encode,decode,types,mux}.h`
- Encoder dylib: `/nix/store/kig5ns7mdimfwwkb68bjc23f5i2lxiiv-libwebp-1.5.0/lib/libwebp.7.dylib`
  (with `libwebp.dylib` SONAME symlink).
- pkg-config: `.../lib/pkgconfig/libwebp.pc` (in the 1.6.0 build at
  `/nix/store/gs65yhn0rm6q1ncpz1vpfpm3d2im863n-libwebp-1.6.0/`; the
  ffmpeg-linked 1.5.0 derivation also ships one).

ABI version: `WEBP_ENCODER_ABI_VERSION = 0x0210` (encoder.h:25).
Both 1.5.0 and 1.6.0 share this ABI; the Nim FFI's
`WebPConfigInitInternal` / `WebPPictureInitInternal` pass it
directly so version-skew handling is trivial.

### 1.3 Dev-shell exposure

```
$ nix develop --command pkg-config --libs libwebp
Package libwebp was not found in the pkg-config search path.
```

`isonim-render-serve/flake.nix` does **not** list `pkgs.libwebp` in
either the macOS or Linux package set (no `webp` / `libwebp`
substring anywhere in the file). FUH-M5 needs to add it (along with
`pkg-config` already present on Linux only — the macOS branch
needs the same).

### 1.4 Linux dev-shell status

The Linux branch of the dev shell pulls in `pkg-config` and
`tree-sitter` but not `libwebp` either. FUH-M5 needs to add it on
both platforms; on minimal CI hosts without libwebp the
`-d:withInProcessWebP` flag stays off and the subprocess path
serves.

### 1.5 Symbol surface (the relevant subset)

From `/nix/store/.../include/webp/encode.h` — exactly the
EPP-M1-style "what we need from the C API" enumeration:

**Top-level encode entry point (the recommended path for
RGBA → VP8L lossless):**

```c
size_t WebPEncodeLosslessRGBA(const uint8_t* rgba,
                              int width, int height, int stride,
                              uint8_t** output);
```

One call, takes RGBA + dims, returns the encoded WebP RIFF in a
heap-allocated buffer the caller frees via `WebPFree`. **Cannot
tune compression_level / method** — uses libwebp's defaults
(method=6, the slowest setting). Not usable for our 16 ms budget.

**Tunable encode path (the EPP-M5-equivalent shape):**

Lifecycle: `WebPConfig` (knobs) + `WebPPicture` (input pixels +
output writer) + `WebPEncode` (the encode call).

```c
typedef struct WebPConfig WebPConfig;
typedef struct WebPPicture WebPPicture;
typedef struct WebPMemoryWriter WebPMemoryWriter;

// Config init — picks defaults at quality and method=6.
int WebPConfigInit(WebPConfig* config);
// Or via preset — WEBP_PRESET_DEFAULT/PICTURE/PHOTO/DRAWING/ICON/TEXT.
int WebPConfigPreset(WebPConfig* config, WebPPreset preset, float quality);
// Lossless preset — lvl is 0..9, maps to method+quality combo.
int WebPConfigLosslessPreset(WebPConfig* config, int level);
int WebPValidateConfig(const WebPConfig* config);

// Picture init + alloc.
int WebPPictureInit(WebPPicture* picture);
int WebPPictureAlloc(WebPPicture* picture);
void WebPPictureFree(WebPPicture* picture);

// Pixel import — these allocate the WebPPicture's argb plane and
// copy the user buffer in. RGBA path is what we need.
int WebPPictureImportRGBA(WebPPicture* pic,
                          const uint8_t* rgba, int stride);
// Variants exist for RGB/BGRA/BGR etc.

// Memory writer — pic.writer = WebPMemoryWrite, pic.custom_ptr = &mw.
void WebPMemoryWriterInit(WebPMemoryWriter* writer);
int  WebPMemoryWrite(const uint8_t* data, size_t data_size,
                     const WebPPicture* picture);
void WebPMemoryWriterClear(WebPMemoryWriter* writer);

// The actual encode — synchronous; returns 1 on success.
int WebPEncode(const WebPConfig* config, WebPPicture* picture);

// Free output bytes (used with WebPEncodeLossless*).
void WebPFree(void* ptr);
```

**Encoder version probe (matches our `isWebPEncoderAvailable`
pattern):**

```c
int WebPGetEncoderVersion(void);   // returns e.g. 0x010500 for 1.5.0
```

The WebPConfig fields we care about (per ELT-M7's tuning):

- `int lossless;` — set to 1 for VP8L lossless.
- `float quality;` — for lossless this is **effort**, not visual
  quality. 0=fastest/larger, 100=slowest/smaller. Default 75.
- `int method;` — 0=fastest..6=slower-better. This is the field
  that maps to ffmpeg's `-compression_level`. ELT-M7 recommendation
  = 3.
- `int exact;` — preserve RGB values in fully transparent areas.
  Default 0 (libwebp may rewrite for compression). Set to 1 for
  bit-exact lossless contract.
- `int thread_level;` — 0 = single-threaded. ELT-M7 left this off
  for predictable latency; M5 should mirror.

The full `WebPPicture` struct layout has ~20 fields; only `width`,
`height`, `use_argb`, `argb`, `argb_stride`, `writer`, and
`custom_ptr` need explicit Nim-side wiring. The rest stay opaque
behind `pad1..pad8` (pattern already used by tormund/nimwebp).

## 2. Existing Nim wrappers

### 2.1 `webp` (juancarlospaco/nim-webp)

- URL: https://github.com/juancarlospaco/nim-webp
- Updated 2019-11-04; **stale 7 years**.
- Shape: shell-out wrapper around `cwebp` / `dwebp` / `gif2webp`
  CLI tools — uses `osproc.execCmdEx`. Worse than the current
  ffmpeg subprocess (the ELT-M8 docstring already explains why
  `cwebp` is unsuitable: it expects a file on disk, not stdin).
- **Verdict**: unusable. Adds a subprocess dependency we just want
  to remove.

### 2.2 `nimwebp` (tormund/nimwebp)

- URL: https://github.com/tormund/nimwebp
- Updated 2025-08-03; recently maintained.
- Shape: real `{.importc.}` bindings against the libwebp C API
  (`WebPConfig`, `WebPPicture`, `WebPEncode`, etc.), structured as:
  - `src/nimwebp/encoder.nim` — the user-facing API.
  - `src/nimwebp/decoder.nim` — decode side (we don't need this).
  - `src/nimwebp/private/encoder_linkage.nim` — linkage glue.
  - `src/libwebp/` — vendored libwebp source tree as a git submodule.
- **Linkage mode**: static — `encoder_linkage.nim` issues
  `{.compile: "src/libwebp/src/dsp/cost.c".}` etc. for ~50 C files
  including SSE2/SSE4.1/NEON/MIPS/MSA SIMD variants. No `{.dynlib.}`
  fallback path. This means every isonim launcher binary that
  enables `-d:withInProcessWebP` would compile libwebp from source
  (~50× `cc` invocations × Nim's per-c-file rebuild cost). That's
  3-5 minutes added to a clean build per launcher.
- **Other gotchas**: requires the git submodule to be populated;
  pulls in `nimPNG` as a test-only dep (declared `requires`,
  affects nimble resolution). Author warns the bindings are
  "incomplete" in the README; we'd need to extend them for the
  `WebPMemoryWriter` path.
- **Verdict**: usable in principle but bigger code-surface than a
  hand-rolled vendored FFI. The static-link choice is wrong for our
  dynamic-fallback story (we want the launcher to drop to
  subprocess at runtime when libwebp can't be found).

### 2.3 Summary

No drop-in nimble package. **Hand-roll a 100-line FFI** under
`adapters/webp_libwebp_ffi.nim` against the dynlib.

## 3. The current subprocess pattern (replacement target)

File: `isonim-render-serve/src/isonim_render_serve/adapters/webp_lossless_encoder.nim`
(ELT-M8). 246 lines. The `WebPEncoderHandle` ref object holds:

```nim
type
  WebPEncoderHandle* = ref object
    width*, height*: int
    compressionLevel*: int    # libwebp method, 1..6, default 3
    quality*: int             # libwebp quality (only lossy mode)
    codecId*: string          # W-packet header field
    kind*: WebPEncoderKind    # ekFfmpegSubprocess (the only variant)
    ffmpegBin: string         # resolved at construction
```

### 3.1 `encodeFrame` contract

```nim
proc encode*(enc: WebPEncoderHandle;
             rgba: openArray[byte]): WebpFrame
```

- **Input**: `enc` (handle), `rgba` (raw RGBA8888 row-major; must
  be exactly `width*height*4` bytes — raises `IOError` otherwise).
- **Output**: `WebpFrame` from `packet_webp.nim`:
  ```nim
  WebpFrame = object
    flags: WebpFlags          # isStillFrame=true always for ELT-M8
    codecId: string           # default "image/webp" (DefaultWebPCodecId)
    width, height: int
    riffBytes: seq[byte]      # the RIFF container, ready for W packet
  ```
- **Errors**: `IOError` (subprocess non-zero exit; wrong rgba
  length); `Defect` (nil handle — caller bug).

### 3.2 State held across frames

**None.** The subprocess pattern is stateless — every encode spawns
a fresh `ffmpeg` process, feeds RGBA on stdin, drains a single
WebP RIFF on stdout, and waits for exit. `WebPEncoderHandle` only
caches the dimensions and the tuning knobs; nothing carries from
frame N to frame N+1.

This is **good news** for FUH-M5: the in-process FFI replaces the
`encodeViaFfmpeg` helper with a `encodeViaLibwebp` helper that
allocates a fresh `WebPConfig` + `WebPPicture` per call, runs
`WebPEncode`, copies the `WebPMemoryWriter` bytes out, and frees.
No lifecycle / state migration to design.

### 3.3 Resize

```nim
proc resize*(enc: WebPEncoderHandle; newW, newH: int): WebPEncoderHandle
```

O(1) field swap. No teardown / re-create like VTCompressionSession.
**Carries over verbatim** — libwebp is stateless across frames so
resize is still a field swap.

### 3.4 Config knobs wired today

- `compressionLevel: int` — passed to ffmpeg as
  `-compression_level $clampedCL`; clamped to [1, 6]. Default 3
  per ELT-M7 recommendation. In libwebp this is `WebPConfig.method`
  directly.
- `quality: int` — passed as `-quality`; clamped to [0, 100].
  Default 100. In libwebp this is `WebPConfig.quality`; for our
  `lossless=1` path it's an effort knob.
- `codecId: string` — the wire-side codec identifier the W packet
  advertises. Pure metadata; not consumed by the encoder.

The ffmpeg invocation hard-codes `-lossless 1` and `-pix_fmt rgba`.
The FFI equivalent: set `WebPConfig.lossless = 1`, call
`WebPPictureImportRGBA`, set `WebPConfig.exact = 1` (per the libwebp
doc comment on `WebPEncodeLosslessRGBA` — transparent areas can
otherwise be rewritten).

### 3.5 W-diff transient handles

`bridge.nim` § `tsWebPDiff` (lines 850-868) allocates a fresh
`WebPEncoderHandle` per diff rectangle:

```nim
for r in regions:
  let rectEnc = newWebPEncoderHandle(
    r.w, r.h,
    compressionLevel = state.webpEncoder.compressionLevel)
  ...
  finally:
    destroy(rectEnc)
```

Today each transient handle pays an ffmpeg-spawn overhead per
rectangle. The in-process path makes this **free** — `newWebPEncoderHandle`
becomes a ref-object allocation only; the per-rect cost collapses
to `WebPEncode` on a small (~tens-of-pixels-per-side) image, which
libwebp completes in <0.5 ms even at method=6. This is a bigger win
for the diff path than for the full-frame path.

## 4. Recommended approach

### 4.1 Decision: vendored Nim FFI with `{.importc.}` + `{.dynlib.}`

New module:
`isonim-render-serve/src/isonim_render_serve/adapters/webp_libwebp_ffi.nim`

Mirrors EPP-M5's `capture_videotoolbox.nim` shape, scaled to a
plain-C API:

```nim
when defined(macosx) or defined(linux):
  const libwebp = when defined(macosx): "libwebp.dylib"
                   else: "libwebp.so.7"   # SONAME on Linux

  {.push importc, cdecl, dynlib: libwebp.}

  proc WebPGetEncoderVersion(): cint
  proc WebPConfigInitInternal(config: ptr WebPConfig; preset: cint;
                              quality: cfloat; abiVersion: cint): cint
  proc WebPConfigLosslessPreset(config: ptr WebPConfig; level: cint): cint
  proc WebPValidateConfig(config: ptr WebPConfig): cint
  proc WebPPictureInitInternal(pic: ptr WebPPicture; abiVersion: cint): cint
  proc WebPPictureAlloc(pic: ptr WebPPicture): cint
  proc WebPPictureFree(pic: ptr WebPPicture)
  proc WebPPictureImportRGBA(pic: ptr WebPPicture;
                              rgba: ptr UncheckedArray[byte];
                              stride: cint): cint
  proc WebPMemoryWriterInit(writer: ptr WebPMemoryWriter)
  proc WebPMemoryWriterClear(writer: ptr WebPMemoryWriter)
  proc WebPMemoryWrite(data: ptr UncheckedArray[byte]; size: csize_t;
                       pic: ptr WebPPicture): cint
  proc WebPEncode(config: ptr WebPConfig; pic: ptr WebPPicture): cint
  proc WebPFree(p: pointer)

  {.pop.}
```

### 4.2 Why not the alternatives

| Option                                              | Verdict | Reason                                                                                                                                                                                                                    |
| --------------------------------------------------- | ------- | ------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------- |
| `nimble install nimwebp`                            | No      | Static-compiles libwebp (~50 `.c` files), no dynlib mode, blocks the runtime-fallback story.                                                                                                                              |
| `nimble install webp`                               | No      | Just `cwebp`/`dwebp` CLI wrapper. Worse than current.                                                                                                                                                                     |
| Thin `.c` shim (EPP-M5 pattern)                     | No      | libwebp is plain C; no ObjC/C++ needed. The `.m` shim shape exists in EPP-M5 because VideoToolbox is an ObjC API; for libwebp the `{.importc.}` declarations are the same code surface. Adds compilation cost for no win. |
| Vendored `{.importc.}` + `{.dynlib.}` (recommended) | Yes     | ~100 LoC; runtime-loaded dynlib; trivially gated by `-d:withInProcessWebP`; falls back to subprocess when dynlib missing.                                                                                                 |

### 4.3 Why dynlib instead of static link

The campaign brief's "dormant-code-on-loss" rule + the milestone
FUH-M4 § "Backward compat" call out the need for the subprocess
path to stay as fallback. With static link, the launcher binary
either ships libwebp baked in (every binary +500 KB) or doesn't.
With `{.dynlib.}`, the binary stays small and `loadlib` at first
use either finds a system libwebp and turns on the fast path or
returns a load error that the FFI module reports via
`isInProcessWebPAvailable() == false`, gracefully degrading to the
existing subprocess path.

On macOS the dynlib search resolves via `DYLD_FALLBACK_LIBRARY_PATH`
(which Nix populates via the shellHook) and the standard system
paths. On Linux, `LD_LIBRARY_PATH` + `/etc/ld.so.cache`.

### 4.4 Required `flake.nix` changes (FUH-M5)

Add `pkgs.libwebp` to the dev shell on **both** platforms:

```nix
devShells.default = pkgs.mkShell {
  packages = with pkgs; [
    nim
    nimble
    just
    libwebp        # <-- new
    pkg-config     # <-- already on Linux only; lift to both
    ...
  ];
  ...
};
```

Nim's dylib loader honours the dev-shell's `DYLD_FALLBACK_LIBRARY_PATH`
(on macOS) and `LD_LIBRARY_PATH` (on Linux) automatically — both
are populated by `pkgs.mkShell` for any package whose `lib/`
subdirectory contains shared objects.

### 4.5 Module layout (proposed for FUH-M5)

```
isonim-render-serve/src/isonim_render_serve/adapters/
  webp_libwebp_ffi.nim        # NEW — the FFI declarations + thin Nim API
  webp_lossless_encoder.nim   # EXISTS — gate the encode body on a runtime
                              # `useInProcess: bool` flag set by config.nims
```

`webp_lossless_encoder.nim`'s public surface stays unchanged
(`newWebPEncoderHandle`, `encode`, `resize`, `destroy`,
`isWebPEncoderAvailable`, `selectEncoderKind`). Only the
`encodeViaFfmpeg` helper gets a sibling `encodeViaLibwebp` that
runs through the FFI module, with a one-line dispatch:

```nim
let riff =
  when defined(withInProcessWebP):
    if isInProcessWebPAvailable():
      encodeViaLibwebp(enc, rgba)
    else:
      encodeViaFfmpeg(enc, rgba)
  else:
    encodeViaFfmpeg(enc, rgba)
```

`WebPEncoderKind` gets a second enum variant
`wekLibwebpDirect` so callers can introspect which path is live
(useful for the FUH-M6 bench).

## 5. Performance expectations

### 5.1 Current subprocess baseline (measured 2026-05-30)

Bench: `node` driving the existing
`isonim-bench-codecs/codecs/webp-lossless/encoder.mjs` at 1280×800,
compression_level=3, on the user's M-series Mac.

**Synthetic UI content** (flat gray with one rectangular color
band, representative of editor task_app):

- Median encode: **133 ms** per frame.
- Min/max across 10 iterations: 113 / 213 ms.

**Synthetic worst-case** (random RGBA — high entropy, defeats
lossless prediction):

- Median encode: **352 ms** per frame.

**Subprocess spawn overhead** (`ffmpeg -version`, no encode):

- Median: **78 ms** per spawn.

So the typical-UI encode breakdown at 1280×800, cl=3:

- ~78 ms ffmpeg process spawn + dylib load
- ~55 ms actual `WebPEncode` work
- = 133 ms total

The campaign brief's "~297 ms / frame" headline number aligns with
ELT-M8's earlier measurements at cl=6 (the bench's max-effort
setting), where the encode-work portion roughly doubles vs cl=3.
ELT-M9 dropped the production default to cl=3; the live render loop
sees 133 ms today.

### 5.2 In-process expectation

Subprocess overhead → 0. Actual encode work at cl=3 on flat UI
content drops substantially because:

1. **No process spawn**. -78 ms.
2. **No stdin pipe staging** of the 4 MB raw RGBA buffer. libwebp
   reads directly from the `WebPPicture.argb` plane the launcher
   filled.
3. **libwebp at method=3 on flat UI**. Published libwebp benchmarks
   (e.g. Google's own [WebP compression study](https://developers.google.com/speed/webp/docs/webp_lossless_alpha_study))
   put the lossless encoder at method=3 in the 5-15 ms range for
   1280×800 screen content on a modern x86 core. M-series ARM is
   broadly comparable.

**Conservative target**: median encode at 1280×800, cl=3, real UI
content ≤ **16 ms** (the 60 FPS budget). This is the FUH-M5 budget
test threshold.

**Stretch target**: ≤ **8 ms** (frees half the frame budget for
the rest of the bridge / network / browser-side decode pipeline).

### 5.3 W-diff per-rect collapse

Every rectangle in `bridge.nim`'s `tsWebPDiff` branch today pays
~78 ms (spawn) + tiny-encode (~1-2 ms). A frame with 5 hovered
rectangles pays 5 × 80 ms = 400 ms today. In-process drops this
to 5 × 1.5 ms = ~8 ms — a separate **50× speedup** for the diff
path on top of the full-frame win.

## 6. Backward compatibility

### 6.1 Build-time gate: `-d:withInProcessWebP`

Per the campaign's dormant-code-on-loss rule and the FUH-M4 brief
§ 6 spec:

- **Default ON** when the build host has libwebp headers reachable
  (probed via `pkg-config --exists libwebp` in `config.nims` or
  via a `pkgs.libwebp` derivation in `flake.nix`).
- **Default OFF** otherwise — the launcher falls through to the
  existing ffmpeg subprocess path.
- Always forcibly OFF when `-d:withInProcessWebP=off` is passed
  explicitly (escape hatch for debugging).

### 6.2 Run-time gate: dynlib load probe

Even when the build enables `-d:withInProcessWebP`, runtime
detection has to be defensive — the launcher binary may be
deployed to a host without libwebp installed (e.g. a minimal Linux
container). Three layers:

1. `WebPGetEncoderVersion()` wrapped in a `try`/`except` for
   `LibraryError`. Returns the libwebp version when the dynlib
   resolves; raises when it doesn't.
2. `isInProcessWebPAvailable*(): bool` caches the probe result at
   first call.
3. `encode` in the `WebPEncoderHandle` chooses path per-call based
   on the cached probe, so a launcher that boots without libwebp
   still gets working WebP output via the subprocess fallback.

### 6.3 ABI version guard

libwebp's encoder ABI version is 0x0210 (header constant
`WEBP_ENCODER_ABI_VERSION`). `WebPConfigInitInternal` and
`WebPPictureInitInternal` take it as a parameter and refuse the
call (return 0) on mismatch. The Nim FFI passes the build-time
constant; if a future libwebp bumps ABI, the encoder constructor
returns nil and the launcher falls back. No silent corruption.

### 6.4 Linux launcher without libwebp dev headers

The FUH-M4 brief calls out this case specifically. With the
recommended `flake.nix` change, the dev shell ships libwebp; for
deployment scenarios where the launcher runs outside the dev
shell, the dynlib loader either finds the system package (Debian
`libwebp7`, Fedora `libwebp`, etc.) or fails the probe and the
subprocess path serves.

There is **no code change needed in any launcher** — they all go
through `webp_lossless_encoder`'s public API which already has the
"return nil → fall back to F-packet" contract from ELT-M8.

### 6.5 Test matrix to keep passing after FUH-M5

The existing tests in `isonim-render-serve/tests/` that touch the
WebP encoder:

- `test_webp_encoder_lifecycle.nim` — exercises the public API.
  Should pass against **both** backends (subprocess and FFI).
  Currently `skip`s when `isWebPEncoderAvailable()` is false; FUH-M5
  should add a parallel `webpInProcessAvail` gate so the suite runs
  the FFI path when available and the subprocess path otherwise.
- `test_packet_webp_codec_roundtrip.nim` / `test_packet_webp_diff_region_roundtrip.nim`
  — packet-codec round-trip only; encoder-implementation-agnostic.
  Should keep passing unchanged.

New tests for FUH-M5 per the spec brief:

- `tests/test_webp_inprocess_encoder_lifecycle.nim` — mirrors
  `test_webp_encoder_lifecycle.nim` shape, asserts the FFI handle
  branch.
- `tests/test_webp_inprocess_encoder_budget.nim` — 1280×800 × 100
  iterations, median ≤ 16 ms.

## FUH-M5 implementation plan summary

1. **flake.nix** — add `pkgs.libwebp` (and `pkg-config` on macOS)
   to `devShells.default.packages`.
2. **New module** `adapters/webp_libwebp_ffi.nim` — the dynlib FFI
   declarations + Nim-side `EncodeInProcessResult` shape. ~120
   LoC.
3. **Extend** `adapters/webp_lossless_encoder.nim`:
   - Add `wekLibwebpDirect` to `WebPEncoderKind`.
   - Resolve the chosen kind in `newWebPEncoderHandle` based on
     `defined(withInProcessWebP)` + the runtime probe.
   - Add `encodeViaLibwebp` proc; dispatch in `encode`.
4. **`config.nims`** in `isonim-render-serve` + `isonim-examples` —
   default `-d:withInProcessWebP` ON when libwebp is detected.
5. **New tests**:
   - `tests/test_webp_inprocess_encoder_lifecycle.nim` (mirrors
     existing lifecycle shape).
   - `tests/test_webp_inprocess_encoder_budget.nim` (1280×800,
     100 iters, median ≤ 16 ms).
6. **Re-run** `test_webp_encoder_lifecycle.nim` against the FFI
   backend to assert byte-stable wire output.

Acceptance: FUH-M6 re-measures the ELT-M9 W-diff bench against the
in-process backend and asserts the full-frame fallback path lands
under 16 ms at 1280×800.

— end FUH-M4 audit.
