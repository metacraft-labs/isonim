# EPP-M2 — GPUI launcher runtime render path (verified)

Date: 2026-05-29
Author: EPP-M2 sub-agent
Spec: `codetracer-specs/Front-Ends/IsoNim/Editor-Preview-Performance.milestones.org`
Audit basis: `isonim/docs/preview-perf-audit-EPP-M1.md` § 1.1 + § 5.1

## Question

EPP-M1's audit reported that `isonim-examples/Justfile:180-188`
already builds the GPUI launcher with `-d:useGpuiHeadless` on Darwin,
yet a perception of "synthetic-painter behaviour" persisted. EPP-M2
was tasked with **pinning down** whether the runtime path is the
real GPUI render path or a silent fallback to the synthetic painter
in `gpui_adapter.nim:walkLayout` / `renderSyntheticFrame`.

## Verification method

1. Built the GPUI launcher via the existing
   `direnv exec ~/metacraft/isonim-examples just build-backends`
   recipe (Darwin, macOS 25.3.0, Apple Silicon).
2. Inspected the produced `build/backends/isonim-examples-gpui`
   binary for the synthetic-vs-headless code path:
   - `strings` returned both `gpui_render_to_pixels` (the FFI
     symbol) AND `renderHeadlessFrame` (the Nim-side wrapper),
     confirming `-d:useGpuiHeadless` was active at compile time.
   - The cdylib `libgpui_nim_shim.dylib` is loaded at runtime via
     Nim's `dynlib` pragma (per
     `isonim-gpui/src/isonim_gpui/bindings.nim:14-15`); no rpath
     baked into the launcher.
3. Spawned the launcher subprocess with
   `DYLD_LIBRARY_PATH=isonim-gpui/rust/target/release` so the
   dynamic loader resolves the shim, then opened a real WebSocket
   to its bridge port and captured the first `F`-packet.
4. Analysed the captured 800 × 600 × 4 RGBA buffer for the
   synthetic painter's three signatures (per `gpui_adapter.nim`):

| Signature                           | Synthetic painter | Captured frame |
| ----------------------------------- | ----------------- | -------------- |
| Teal bottom band (#06989A)          | 100 % of last row | 0 / 800 px     |
| Dark-grey canvas pre-fill (#181818) | ~30–60 % of frame | 0 / 480 000 px |
| Unique RGB triplets (stride sample) | < 50              | 301            |

## Verdict

**The launcher's runtime render path IS the real headless GPUI
pipeline** (`gpui_render_to_pixels` → Zed `HeadlessAppContext::
with_platform` → `Window::render_to_image()`). Sampled centre
pixel `#1d1d28`, corners `#0f0f14` — task_app's brand-dark surface,
not anything the synthetic painter ever emits.

The earlier "synthetic-painter feeling" came from a different gap
the campaign has now closed:

- Before EPP-M7 (commits `1bf09d0` / `3faa9c4` / `721374a`), mouse
  and keyboard events that reached the launcher were dropped by
  the launcher composition's `resizingSink` (audit § 4.2 / § 5.1).
  Render fidelity was already real-headless; **interactivity** was
  what felt synthetic. EPP-M7 wired
  `newDispatchingLauncherSink` + `GpuiInputSink` and clicks now
  reach the shadow-tree `fireEvent` table. So clicks now produce
  visible VM mutations on the next rendered frame.

So no runtime gap remains in EPP-M2's scope. The headless flag is
on, the shim is loaded, the pipeline produces real GPUI pixels.

## Regression net

To prevent silent regressions (e.g. a future Zed revision bump
that breaks `current_headless_renderer()`, or an accidental drop
of `-d:useGpuiHeadless` from the Justfile), this milestone adds
the golden-snapshot test at
`isonim/tests/browser/e2e_editor_gpui_real_render_live.mjs`. The
test:

1. Spawns the real `isonim-examples-gpui` launcher with
   `DYLD_LIBRARY_PATH` pointed at the shim's release dylib.
2. Captures the first `F`-packet over a real WebSocket.
3. Asserts the three no-synthetic-signature checks above.
4. Compares pixels byte-by-byte (mean ΔE) against the golden at
   `tests/browser/golden/epp-m2/gpui-task-app-800x600.bin`,
   tolerating up to 5 % per-channel mean ΔE for GPU driver
   variance and Zed's deferred-draw pump jitter.

On first run the golden is written, subsequent runs assert. To
re-baseline (e.g. after an intentional visual change to
`task_app`), delete the golden file and re-run.

Run locally with:

```sh
direnv exec ~/metacraft/isonim node --test \
    tests/browser/e2e_editor_gpui_real_render_live.mjs
```

## Linux note

Per the EPP-M1 audit § 1.1 and the EPP-M2 milestone § 7.1 Linux
note: the pinned Zed revision's `current_headless_renderer()`
returns `None` on non-macOS, so Linux falls back to the synthetic
painter by design. The test guards on `process.platform !==
"darwin"` and exits cleanly without assertions — Linux real-render
is explicitly deferred to a future EPP-M2b milestone (the gating
hard dependency is Zed shipping a Linux headless platform). No
runtime gap to fix on the Darwin path that the campaign targets.

## Files touched

- New: `isonim/tests/browser/e2e_editor_gpui_real_render_live.mjs`
- New: `isonim/tests/browser/golden/epp-m2/gpui-task-app-800x600.bin`
- New: `isonim/tests/browser/golden/epp-m2/gpui-task-app-800x600.meta.json`
- New: this document (`isonim/docs/epp-m2-gpui-runtime-path.md`)

No edits to shared isonim code or the launcher composition; no
edits to `isonim-render-serve`; no Justfile changes (the
`-d:useGpuiHeadless` recipe at `isonim-examples/Justfile:182-184`
was already correct).
