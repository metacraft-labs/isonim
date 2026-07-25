# FUH-M7 — Full Acceptance Matrix Specification (Phase C audit)

**Milestone:** FUH-M7 — define the cross-campaign acceptance matrix
that consolidates EPP / ELT / ETS / FUH user-visible promises into a
single Playwright matrix run. Read-only audit; no source changes; no
commits. The matrix itself ships in FUH-M8.

**Spec:**
`codetracer-specs/Front-Ends/IsoNim/Editor-Followup-Hardening.milestones.org`
**Audit consumers:** FUH-M8 (matrix implementation),
FUH-M9 (final scorecard).

**Prior campaign tests this audit mines:**

- EPP-M8 — `isonim/tests/browser/e2e_editor_preview_acceptance_matrix_live.mjs`
  (median frame latency, DPR contract, click→visible response, keyboard).
- ELT-M9 — `isonim/tests/browser/e2e_editor_w_no_change_idle_live.mjs`
  (idle bandwidth; W-diff heartbeat byte budget).
- ELT-M9 — `isonim/tests/browser/e2e_editor_w_diff_region_live.mjs`
  (lossless contract; W-diff rectangle path).
- ETS-M6 — `isonim/tests/browser/e2e_editor_overlay_streaming_acceptance_live.mjs`
  (overlay bbox alignment ≤ 1 px; mouse-move → overlay-update latency).
- FUH-M3 — `isonim/tests/browser/e2e_editor_hover_payload_acceptance_live.mjs`
  (per-hover delta wire bytes; hover → overlay-update latency on
  mutating task_app).
- FUH-M6 — `isonim/tests/browser/e2e_editor_w_full_frame_budget_live.mjs`
  - extended `e2e_editor_w_diff_region_live.mjs` (per-viewport encode
    budget; per-W-packet inter-arrival cadence after in-process libwebp
    landed).

---

## Section 1 — Per-criterion enumeration

Six user-visible criteria, drawn directly from the campaign milestones.
Every threshold below is locked at the value its source campaign
shipped against — FUH-M8 is FORBIDDEN from loosening any of them.

### 1.1 Criterion table (headline)

| #   | Criterion                               | Source campaign(s)             | Threshold                                                                       | Sense           |
| --- | --------------------------------------- | ------------------------------ | ------------------------------------------------------------------------------- | --------------- |
| 1   | Median frame latency                    | EPP-M8 / EPP-M10 / FUH-M6      | ≤ 50 ms                                                                         | lower-is-better |
| 2   | Idle bandwidth (steady-state)           | ELT-M9                         | ≤ 512 bytes median per packet (≈ 5 KB/s at 30 FPS)                              | lower-is-better |
| 3   | Click → visible response                | EPP-M8 / EPP-M12               | ≤ 33 ms (1 frame @ 30 FPS)                                                      | lower-is-better |
| 4   | Hover → overlay-update                  | ETS-M6 / FUH-M3                | ≤ 16 ms median (1 frame @ 60 FPS)                                               | lower-is-better |
| 5   | DPR contract (1:1 device-pixel display) | VRS / EPP-M2 / EPP-M4 / EPP-M8 | drift ≤ 1 px on both axes                                                       | bounded         |
| 6   | Lossless contract (per-region payload)  | ELT-M9 / FUH-M5                | uniqueRGB ≥ 2 AND non-grey > 1/16 sampled pixels (canvas-side proxy for L1 = 0) | bounded         |

### 1.2 Per-criterion specification

#### Criterion 1 — Median frame latency ≤ 50 ms

- **Source.** EPP-M8 `e2e_editor_preview_acceptance_matrix_live.mjs:93`
  defines `MAX_MEDIAN_FRAME_LATENCY_MS = 50`. Same value re-affirmed
  by FUH-M6 (the in-process libwebp encoder must not regress this
  baseline).
- **Measurement pattern (EPP-M8).**
  1. `addInitScript` installs a `WebSocket.prototype.addEventListener`
     wrapper that pushes `performance.now()` into
     `window.__isonimFrameTimes` whenever an `F` (0x46) or `V`
     (0x56) packet lands.
  2. Drain the buffer; wait until
     `__isonimFrameTimes.length >= TARGET_FRAME_COUNT (100)`.
  3. Compute pairwise inter-arrival deltas, sort, take the median.
- **Pass.**
  `medianFrameLatencyMs <= 50` AND `framesObserved >= 100` AND the
  buffer settled within 30 s.
- **FUH-M8 reuse.** The full instrumentation script in
  `paintInstrumentationScript()` (EPP-M8 lines 362-522) is
  reusable verbatim — exports `__isonimFrameTimes`,
  `__isonimCanvasPaintTimes`, `__isonimSendInputCount`,
  `__isonimKeyboardDownChars`. New matrix MUST install the same
  `addInitScript` before the editor IIFE attaches.

#### Criterion 2 — Idle bandwidth ≤ 5 KB/s

- **Source.** ELT-M9 `e2e_editor_w_no_change_idle_live.mjs:388-391`:
  `median < 512` bytes per W-diff packet on the static cocoa task_app
  after a 3.5 s settle. At `--fps 30` that is **30 packets/s × 512 B
  = 15 KB/s upper bound**; the median observed for the cocoa
  task_app stays in the few-hundred-byte range (header floor is 29 B:
  15 B W header + 10 B codec_id "image/webp" + 4 B rect_count). The
  campaign brief's "≤ 5 KB/s" headline is the heartbeat-only
  steady-state — heartbeat (zero-rect) packets carry only the
  29-byte W header floor; at 30 packets/s that's 870 B/s, well
  under 5 KB/s.
- **Measurement pattern (ELT-M9).**
  1. Spawn launcher with `--encoder webp`; wait for
     `document.body.dataset.isonimActiveTransport === "w/webp"`.
  2. Reset `window.__isonimWDiffRectCounts` and
     `window.__isonimWDiffByteLengths` (test-mode mirrors in
     `streaming_preview.nim` — populated per W-packet decode).
  3. Settle 3.5 s on quiescent UI (no mouse / keyboard input).
  4. Assert (a) ≥ 10 W-diff packets observed, (b) heartbeat
     count > non-zero rect-count count, (c)
     `median(__isonimWDiffByteLengths) < 512`.
- **Pass.** Heartbeats dominate; median packet size < 512 B; on
  a 30 FPS stream that bounds bandwidth at ≤ 15 KB/s and lands
  the steady-state under the 5 KB/s campaign target.
- **FUH-M8 note.** Only relevant for `--encoder webp` launchers
  (W-path). For `raw_rgba` (gpui/freya defaults) and `h264`
  (cocoa --encoder h264 path), the steady-state cadence is
  governed by the F/V transport, not W; criterion 2 is N/A for
  those launcher/encoder combinations. Matrix MUST mark these
  cells "—" rather than fail.

#### Criterion 3 — Click → visible response ≤ 33 ms

- **Source.** EPP-M12 (close of EPP campaign) — one-frame budget at
  the launcher's advertised cadence. EPP-M8 line 99 pins
  `ONE_FRAME_AT_30FPS_MS = 33`. Locking `--fps 30` makes 33 ms the
  canonical budget.
- **Measurement pattern (EPP-M8).**
  1. `findActiveCanvas` → bounding rect → click target (rect
     center).
  2. Sample a 128×128 ROI fingerprint
     (sum-of-R/G/B/count across every 16th pixel) BEFORE the
     click → `roiBaseline.fingerprint`.
  3. `clickMark = performance.now()` (page-side); `page.mouse.click`.
  4. Poll the same ROI every 5 ms for `responseDeadlineMs = 330 ms`
     (10× one-frame budget headroom); record
     `clickResponseLatencyMs = sample.t - clickMark` at the first
     fingerprint divergence.
- **Pass.** `clickResponseLatencyMs <= 33` AND canvas owns focus
  (`document.activeElement.tagName === "canvas"`) AND
  `body[data-isonim-canvas-focused="true"]`.
- **Caveat.** Click-region pixel divergence requires the click
  to LANDED in a region where the app paints a visible mutation.
  For `task_app` the rect-center hits the task list, which the
  EPP-M12 hit-chain wires to either a row-select highlight
  (cocoa) or an active-state visual feedback (gpui/freya).
  For `settings_app` the rect-center MAY land on dead space;
  FUH-M8 should target the click at a known interactive widget
  (see Section 2.3 below).

#### Criterion 4 — Hover → overlay-update ≤ 16 ms

- **Sources.**
  - ETS-M6 `e2e_editor_overlay_streaming_acceptance_live.mjs:76`:
    `LATENCY_GATE_MS = 16.0`. Measured on the editor-side overlay
    (hover label + selection outline), which re-positions in a
    `createRenderEffect` triggered by manifest mutation.
  - FUH-M3 `e2e_editor_hover_payload_acceptance_live.mjs:76`:
    same 16 ms gate, additionally validated on the mutating-app
    path FUH-M2 wired (`maMove` → `fireEvent("mouseenter"/
"mouseleave")` flips `ElementKindAttr` row → row-hovered).
- **Measurement pattern.**
  1. Install a `MutationObserver` on the hover-label
     (`[data-canvas-hover-label="true"]`) inline `style` attr
     OR the selection-outline (`[data-canvas-selection-outline]`)
     — the overlay effect writes `style.left/.top/.width/.height`
     per (hovered, manifest) change (`canvas_mount.nim:391-394`).
  2. For each hover sample: `t0 = performance.now()`;
     `page.mouse.move(x, y)`; observer records the first style
     mutation `t1`; sample = `t1 - t0`.
  3. Drive N=10 distinct hover targets sampled from the
     `__isonimManifests` test-mode mirror (FUH-M3 pattern).
- **Pass.** `medianLatencyMs <= 16` across the 10-sample sweep.
- **FUH-M8 note.** FUH-M2 wired hover dispatch in ALL FOUR
  backend input adapters (gpui/freya/cocoa/android), but the
  hover-state class (`row` → `row-hovered`) is only mounted in
  `task_app`'s `renderTaskRow`. For `settings_app` the overlay
  STILL updates (it's positioned by the editor's element-tree
  delta, not by app mutation), so the criterion is measurable
  on both apps. settings_app falls back to legacy overlay
  positioning (the M-V12 hover-label tracks the hit-leaf
  regardless of app mutation).

#### Criterion 5 — DPR contract (1:1 device-pixel display) ≤ 1 px

- **Sources.** VRS-M1 audit (viewport-resize-audit-VRS-M1.md);
  EPP-M2 (DPR pinning); EPP-M4 (Metal capture DPR plumbing);
  EPP-M8 line 94 (`MAX_DPR_DRIFT_PX = 1`).
- **Measurement pattern.**
  1. `findActiveCanvas` returns `intrinsicW = canvas.width`,
     `intrinsicH = canvas.height`, `rect = getBoundingClientRect()`,
     `dpr = window.devicePixelRatio`.
  2. `dprDriftWpx = abs(rect.width * dpr - intrinsicW)`;
     `dprDriftHpx = abs(rect.height * dpr - intrinsicH)`.
- **Pass.** Both `dprDriftWpx` AND `dprDriftHpx` are `<= 1`.
- **FUH-M8 note.** Each context spawns at `deviceScaleFactor: 1`
  for parity with EPP-M8; the gate stays the same when DPR=2
  contexts are added later. The matrix should hold deviceScaleFactor=1
  for FUH-M8 — DPR=2 is its own follow-up.

#### Criterion 6 — Lossless contract ≤ L1 = 0 (canvas-side proxy)

- **Sources.** ELT-M9 `e2e_editor_w_diff_region_live.mjs:412-425`;
  FUH-M5 unit budget test verifies libwebp `exact = 1` + lossless
  config keeps L1 = 0 on the encoder side.
- **Measurement pattern (canvas-side proxy).**
  Direct L1-vs-source comparison is impossible from the
  browser (no access to the launcher's raw RGBA), so ELT-M9
  defined a two-part canvas-side proxy:
  1. Read the active canvas via `getImageData(0, 0, w, h)`;
     count `uniqueColors` (RGB triples) up to a cap of 4096;
     count `nonGrey` pixels (anything that isn't 0x18/0x18/0x18,
     the placeholder grey).
  2. Assert `uniqueColors >= 2` (the per-rect VP8L encode
     preserves source bytes — a flat single-colour canvas
     means decode failed or the placeholder leaked through).
  3. Assert `nonGrey > sampled / 16` (substantial non-
     placeholder pixels — i.e. the W-diff stream actually
     reconstructed app content).
- **Pass.** Both assertions hold after the W-diff stream
  has painted at least one rect-bearing packet (or after
  the full-frame W path engages via resize).
- **FUH-M8 note.** N/A for `--encoder raw_rgba` (no codec — F
  packets are byte-identical to source by construction) and
  `--encoder h264` (lossy by design; H.264 baseline does NOT
  satisfy L1 = 0 — this is the entire reason ELT existed).
  Lossless criterion is measurable ONLY on the `--encoder
webp` path. Matrix MUST mark non-webp cells "—" for this
  criterion.

### 1.3 Criterion-to-test-mirror cross-reference

| #   | Criterion       | Test-mode mirrors used                                                                                                                | Mirror source file                                                                                       |
| --- | --------------- | ------------------------------------------------------------------------------------------------------------------------------------- | -------------------------------------------------------------------------------------------------------- |
| 1   | Frame latency   | `window.__isonimFrameTimes`, `window.__isonimCanvasPaintTimes`                                                                        | EPP-M8 `paintInstrumentationScript()` (lines 362-522 in `e2e_editor_preview_acceptance_matrix_live.mjs`) |
| 2   | Idle bandwidth  | `window.__isonimWDiffRectCounts`, `window.__isonimWDiffByteLengths`                                                                   | `streaming_preview.nim` (test-mode mirror added in ELT-M9)                                               |
| 3   | Click response  | ROI fingerprint via `getImageData`, `body[data-isonim-canvas-focused]`                                                                | inline in EPP-M8 test                                                                                    |
| 4   | Hover → overlay | MutationObserver on `[data-canvas-hover-label]` / `[data-canvas-selection-outline]` `style` attr; `__isonimManifests` for hit targets | ETS-M6 / FUH-M3 pattern; manifests mirror from ETS-M4 (`streaming_preview.nim:1683-1688`)                |
| 5   | DPR contract    | `canvas.width`, `canvas.getBoundingClientRect()`, `window.devicePixelRatio`                                                           | inline (no test-mode mirror needed)                                                                      |
| 6   | Lossless        | `getImageData(0, 0, w, h)` over the active canvas; `uniqueColors`, `nonGrey` counts                                                   | inline in ELT-M9 test                                                                                    |

**All six criteria are measurable from existing test-mode mirrors and
the existing `addInitScript` instrumentation. No new test-mode mirrors
need to be added to `streaming_preview.nim` or `canvas_mount.nim` for
FUH-M8.** The shared instrumentation block can be lifted verbatim from
EPP-M8 + ELT-M9 + ETS-M6 into a single helper module under
`isonim/tests/browser/lib/fuh_m8_instrumentation.mjs` (recommended —
keeps the matrix file readable).

---

## Section 2 — Matrix shape

3 backends × 3 viewports × 2 apps = **18 cells**. Each cell asserts
ALL 6 criteria (with N/A markers where the criterion is structurally
inapplicable — see § 1 caveats above).

### 2.1 Backend axis (3)

| Backend | Launcher binary                                        | Encoder flag            | Transport ID |
| ------- | ------------------------------------------------------ | ----------------------- | ------------ |
| gpui    | `isonim-examples/build/backends/isonim-examples-gpui`  | `raw_rgba`              | `f/rgba`     |
| freya   | `isonim-examples/build/backends/isonim-examples-freya` | `raw_rgba`              | `f/rgba`     |
| cocoa   | `isonim-examples/build/backends/isonim-examples-cocoa` | `webp` (NEW for FUH-M8) | `w/webp`     |

**Encoder choice for cocoa.** EPP-M8 used `--encoder h264` to exercise
the V-packet VideoToolbox path. FUH-M8 changes cocoa to `--encoder
webp` because:

- Criterion 6 (lossless) is ONLY measurable on the W path.
- Criterion 2 (idle bandwidth) is ONLY meaningful on W.
- Criterion 1 (median frame latency) is encoder-agnostic — the
  cadence assertion measures inter-arrival times, which the
  launcher pins at `--fps 30` regardless of encoder.
- The V-path acceptance is already covered by the standing EPP-M8
  test; FUH-M8 does NOT replace it.

**Skip Android.** The Android adapter exists (FUH-M2 wired
`maMove` → `fireEvent` there too) but `editor/backends/android.nim`
re-launches a fresh activity for each demo change via
`adb shell am start`. The editor's bridge connects to an emulator-
hosted launcher rather than a desktop process — desktop-spawn is
not the editor's default for Android. Per the FUH-M7 brief explicitly:
"skip Android — mockJni works but desktop-spawn is not the editor's
default".

### 2.2 Viewport axis (3)

| Pill label | Width × Height (CSS px) | Notes                                                                                                |
| ---------- | ----------------------- | ---------------------------------------------------------------------------------------------------- |
| Phone      | 390 × 844               | Matches FUH-M6 `ViewportBudgets.Phone`; matches the EPP iPhone profile (ELT-M9 cocoa launcher dims). |
| Laptop     | 1280 × 800              | Matches FUH-M6 `ViewportBudgets.Laptop`; bench reference dim for ELT-M9 and FUH-M5 budget.           |
| Desktop    | 1440 × 900              | Matches FUH-M6 `ViewportBudgets.Desktop`; matches the EPP-M8 default context viewport.               |

Switching is driven by the editor's viewport-pill strip
(`[data-toolbar-cluster="viewport"] [data-preview-viewport-strip-host="true"]
[data-choice-group-pill]`). FUH-M6 already established the resize-
pill pattern; reuse `viewportPillSelector(page, name)`.

**Launcher spawn dims.** Spawn launcher with `--width 1280 --height 800`
(Laptop default) so the first transport-settled state is Laptop;
then click through Phone → Laptop → Desktop in each cell so all three
viewports get exercised inside the cell. The launcher's frame
source swaps dims via the resize I packet (FUH-M6 pattern).

### 2.3 App axis (2)

| App          | `--demo` value | Hover-state class                   | Notes for criterion 3 (click)                                                                                                                                                       |
| ------------ | -------------- | ----------------------------------- | ----------------------------------------------------------------------------------------------------------------------------------------------------------------------------------- |
| task_app     | `task`         | YES (FUH-M2 row → row-hovered)      | Rect-center click lands on TaskRow; EPP-M12 hit-chain produces row-select feedback.                                                                                                 |
| settings_app | `settings`     | NO (no FUH-M2 mutation in this app) | Rect-center MAY land on a section divider. FUH-M8 should target the click at a known interactive control: the first toggle in the settings list, resolved from `__isonimManifests`. |

settings_app is included because:

- It exercises the criterion-4 overlay-update path even WITHOUT
  app-side mutation (the editor's hover-label tracks hit-leaf
  position from manifest deltas, independent of `kind`-attr flips).
- It surfaces backend correctness for non-FUH-M2 apps — verifies
  the matrix isn't accidentally pinned to the one mutating app.
- It gives FUH-M9 a per-app verdict line.

### 2.4 Cell budget

Per FUH-M7 brief: **≤ 30 s per cell**, **≤ 10 min total** for the
sequential matrix. Honest breakdown for the per-cell timeline:

| Step                                                         | Budget     | Note                                          |
| ------------------------------------------------------------ | ---------- | --------------------------------------------- |
| Launcher spawn + port-bind wait                              | ≤ 3 s      | FUH-M6: 15 s timeout, observed <2 s on macOS. |
| Editor proxy + browser context open                          | ≤ 2 s      | EPP-M8 pattern.                               |
| Pick backend pill + story row                                | ≤ 1 s      |                                               |
| Transport settle (W/F/V)                                     | ≤ 5 s      | EPP-M8 uses 25 s deadline; observed <3 s.     |
| Cycle through 3 viewport pills                               | ≤ 6 s      | FUH-M6 first-arrival budget 350-500 ms × 3.   |
| Click test (ROI poll, 330 ms deadline)                       | ≤ 1 s      | EPP-M8.                                       |
| Hover sweep N=10 (250 ms / move)                             | ≤ 4 s      | FUH-M3 pattern.                               |
| Idle bandwidth settle (3.5 s window)                         | ≤ 4 s      | ELT-M9.                                       |
| Median frame latency settle (≥ 100 samples @ ~33 ms)         | ≤ 4 s      | EPP-M8.                                       |
| Teardown (context close + launcher SIGKILL + proxy shutdown) | ≤ 1 s      |                                               |
| **Per-cell total**                                           | **≤ 30 s** |                                               |

18 cells × 30 s = **9 min total** sequential. Inside the ≤ 10 min
brief budget with headroom.

---

## Section 3 — Test layout recommendation

### 3.1 File location

`isonim/tests/browser/e2e_editor_full_acceptance_matrix_live.mjs`.
Sibling to the existing per-campaign acceptance tests; same
`node --test` harness; same launch pattern.

### 3.2 Critical constraint — sequential execution

**FUH-M6 documented that concurrent execution of multiple cocoa
launchers + Chromium contexts deadlocks.** The matrix MUST iterate
strictly sequentially:

- Single top-level `test()` block iterates all 18 cells in a `for`
  loop.
- OR: Use `test.describe.serial` with one `test()` per cell — node's
  `--test` runs sibling tests in declaration order BUT each test
  can be `async` and the runner does not parallelise within a file
  unless `--test-concurrency` is set. EPP-M8 uses the top-level
  for-loop + one `test()` per backend pattern (lines 1054-1071);
  FUH-M8 should follow that exact shape for matrix iteration but
  with the outer iteration as a single `test()` block to guarantee
  ordered, in-process serialisation:

  ```js
  test("FUH-M8 full acceptance matrix walk", async (t) => {
    if (!isMacOS) {
      t.skip(SKIP_REASON);
      return;
    }
    for (const backend of BACKENDS)
      for (const app of APPS)
        for (const viewport of VIEWPORTS) {
          await t.test(
            `[${backend.name}/${app.name}/${viewport.name}]`,
            async () => {
              const cell = await runCell(backend, app, viewport);
              cellResults.push(cell);
              const failures = assertAcceptance(cell);
              if (failures.length > 0) {
                assert.fail(
                  `cell failed:\n  - ${failures.join("\n  - ")}` +
                    `\nMeasurements: ${JSON.stringify(cell, null, 2)}`,
                );
              }
            },
          );
        }
  });
  ```

  Subtests inside a single parent `test()` run sequentially by
  default (node's test runner). This is the safest serialisation
  primitive — no risk of accidental parallelism via test discovery
  reorder.

- Reuse `chromium.launch({ headless: true })` ONCE; reuse the
  browser across all cells. Create a fresh `browserContext` per
  cell (EPP-M8 pattern lines 525-553).

### 3.3 Per-cell shape

```
runCell(backend, app, viewport):
  1. spawnLauncher(backend, port, { demo: app.demo,
                                    width: viewport.width,
                                    height: viewport.height,
                                    encoder: backend.encoder,
                                    fps: 30 })
  2. proxy = startEditorProxy(serverPort, launcherPort, backend.name)
  3. ctx, page = openEditor(serverPort, dpr=1)
       — install paintInstrumentationScript() before navigate
       — install installWireMirror() (from ETS-M6, for byte-counting)
  4. await pickBackend(page, backend); pickStoryRow(page, app)
  5. await waitForTransport(page, backend.expectedTransport, 25s)

  ─── 6 criterion checks (all six in this order) ───

  6a. DPR contract (cheapest first — pure DOM reads)
       → measurements.dprDriftWpx, dprDriftHpx
  6b. Lossless (canvas-side proxy)
       → measurements.uniqueColors, nonGrey  [N/A if not w/webp]
  6c. Cycle viewport pills (Phone → Laptop → Desktop, settle on
       cell.viewport at the end)
       → measurements.viewportsCycled
       → measurements.firstArrivalMs per viewport (FUH-M6 pattern)
  6d. Click response (ROI fingerprint poll)
       → measurements.clickResponseLatencyMs
       → measurements.canvasFocusOk, bodyMarkerOk
       — for settings_app, target the click at the first
         interactive widget via __isonimManifests, not rect-center
  6e. Hover sweep N=10 + MutationObserver
       → measurements.hoverMedianLatencyMs, hoverPayloadMedianBytes
  6f. Idle bandwidth (W-diff path only) — drain mirrors, sleep
       3.5 s, read __isonimWDiffByteLengths
       → measurements.idleMedianPacketBytes, heartbeatRatio
  6g. Median frame latency (>=100 samples — runs LAST so the
       cell's other activity doesn't pollute the cadence)
       → measurements.medianFrameLatencyMs, p99

  7. cell.failures = assertAcceptance(measurements)
  8. teardown: ctx.close(), launcher.kill("SIGKILL"),
       proxy.shutdown()
  9. return cell
```

### 3.4 Result accumulator + diffability

Per FUH-M7 brief, write per-cell pass/fail to a golden directory:

- Path: `isonim/tests/browser/golden/fuh-m8/<timestamp>.json`
- Schema (one JSON document per run):
  ```json
  {
    "campaign": "FUH-M8",
    "specCommit": "<from git rev-parse HEAD>",
    "platform": "darwin-arm64",
    "thresholds": {
      "medianFrameLatencyMs": 50,
      "idleMedianPacketBytes": 512,
      "clickResponseMs": 33,
      "hoverOverlayMs": 16,
      "dprDriftPx": 1,
      "losslessMinUniqueColors": 2
    },
    "cells": [
      {
        "backend": "cocoa",
        "app": "task_app",
        "viewport": "Laptop",
        "measurements": {
          /* all six values + diagnostics */
        },
        "failures": [],
        "verdict": "pass"
      }
      // ... 17 more
    ]
  }
  ```
- A second file written each run: `latest.json` (symlink-style
  copy) for the test runner to diff against on subsequent runs.

### 3.5 Helper module

Recommended: extract shared instrumentation +
launcher-spawn + proxy code into
`isonim/tests/browser/lib/fuh_m8_helpers.mjs`. The existing
per-campaign tests duplicate the same proxy/launcher/instrumentation
code; FUH-M8 should NOT duplicate it a fifth time. Module exports:

```
buildAll()                    — same as EPP-M8 buildAll()
pickFreePort()
spawnLauncher(backend, port, opts)
startEditorProxy(serverPort, launcherPort, backendName)
ensureBrowser()
openEditor(serverPort, opts)  — installs paint + wire mirrors
pickBackendPill(page, backend)
viewportPillSelector(page, name)
findActiveCanvas(page)
measureMedianFrameLatency(page, sampleCount)
measureClickResponse(page)
measureHoverSweep(page, manifestSample)
measureIdleBandwidth(page, settleMs)
measureLossless(page)
measureDpr(page)
assertAcceptance(cell)
```

This is a refactor opportunity rather than a strict requirement; if
the FUH-M8 implementer prefers to keep the matrix file self-contained
(EPP-M8 style), it should still pass — the shared file is roughly
1100 lines either way.

---

## Section 4 — Reporting format

### 4.1 Per-cell pass/fail breakdown (markdown table)

The FUH-M9 final scorecard renders the 18 cells as an
18-row × 6-column matrix. Sample shape (FUH-M9 will populate the
actual marks; this is the template):

```
| Cell                          | Frame≤50ms | Idle≤512B | Click≤33ms | Hover≤16ms | DPR≤1px | Lossless |
|-------------------------------|------------|-----------|------------|------------|---------|----------|
| gpui/task_app/Phone           |   ✓        |    —      |    ✓       |    ✓       |    ✓    |    —     |
| gpui/task_app/Laptop          |   ✓        |    —      |    ✓       |    ✓       |    ✓    |    —     |
| gpui/task_app/Desktop         |   ✓        |    —      |    ✓       |    ✓       |    ✓    |    —     |
| gpui/settings_app/Phone       |   ✓        |    —      |    ✓       |    ✓       |    ✓    |    —     |
| gpui/settings_app/Laptop      |   ✓        |    —      |    ✓       |    ✓       |    ✓    |    —     |
| gpui/settings_app/Desktop     |   ✓        |    —      |    ✓       |    ✓       |    ✓    |    —     |
| freya/task_app/Phone          |   ✓        |    —      |    ✓       |    ✓       |    ✓    |    —     |
| freya/task_app/Laptop         |   ✓        |    —      |    ✓       |    ✓       |    ✓    |    —     |
| freya/task_app/Desktop        |   ✓        |    —      |    ✓       |    ✓       |    ✓    |    —     |
| freya/settings_app/Phone      |   ✓        |    —      |    ✓       |    ✓       |    ✓    |    —     |
| freya/settings_app/Laptop     |   ✓        |    —      |    ✓       |    ✓       |    ✓    |    —     |
| freya/settings_app/Desktop    |   ✓        |    —      |    ✓       |    ✓       |    ✓    |    —     |
| cocoa/task_app/Phone          |   ✓        |    ✓      |    ✓       |    ✓       |    ✓    |    ✓     |
| cocoa/task_app/Laptop         |   ✓        |    ✓      |    ✓       |    ✓       |    ✓    |    ✓     |
| cocoa/task_app/Desktop        |   ✓        |    ✓      |    ✓       |    ✓       |    ✓    |    ✓     |
| cocoa/settings_app/Phone      |   ✓        |    ✓      |    ✓       |    ✓       |    ✓    |    ✓     |
| cocoa/settings_app/Laptop     |   ✓        |    ✓      |    ✓       |    ✓       |    ✓    |    ✓     |
| cocoa/settings_app/Desktop    |   ✓        |    ✓      |    ✓       |    ✓       |    ✓    |    ✓     |
```

Legend:

- ✓ = criterion passed (measured value at or below threshold).
- ✗ = criterion failed (measured value above threshold).
- — = criterion N/A for this cell (e.g. lossless on raw_rgba).

### 4.2 Per-cell footnotes for ✗ marks

Each `✗` MUST carry a footnote of the shape:

> **\[cell-id, criterion-name\]**: measured `<value> <unit>` > threshold
> `<threshold> <unit>` — likely cause: `<root-cause from
existing campaign milestones>`.

Example (hypothetical):

> **\[gpui/task_app/Desktop, Frame≤50ms\]**: measured 78.4 ms > 50 ms
> — likely cause: GPUI's render-thread blocking during full-frame
> raw_rgba capture (per EPP-M2 § 4.3, the Zed GPUI runtime serialises
> capture on the render thread; Desktop at 1440×900 produces a
> ~5.2 MB raw RGBA frame that exceeds the EPP-M5 baseline).

### 4.3 Campaign-by-campaign verdict

End of the FUH-M9 report MUST carry a per-campaign verdict line.
The template:

| Campaign | Headline promise                                                                    | Cells contributing                                                                                                             | Verdict                                   |
| -------- | ----------------------------------------------------------------------------------- | ------------------------------------------------------------------------------------------------------------------------------ | ----------------------------------------- |
| EPP      | Median frame latency ≤ 50 ms across all backends + DPR contract + click → visible   | 18 (frame latency, DPR, click)                                                                                                 | <pass/fail/partial — populated by FUH-M9> |
| ELT      | Idle bandwidth → near-zero W-diff heartbeats + lossless L1=0 reconstruction         | 6 (cocoa cells only — bandwidth + lossless are W-path only)                                                                    | <populated>                               |
| ETS      | Mouse-move → overlay-update ≤ 16 ms                                                 | 18 (hover criterion applies in every cell)                                                                                     | <populated>                               |
| FUH      | Hover dispatch (Phase A) + in-process libwebp (Phase B) + acceptance gate (Phase C) | Phase A: 12 task_app cells (mutating hover); Phase B: 6 cocoa cells (encode budget under cadence); Phase C: this matrix exists | <populated>                               |

A campaign verdict is:

- **pass** — every contributing cell green on every contributing
  criterion.
- **partial** — at least one contributing cell green, at least one
  red; surface which.
- **fail** — every contributing cell red on the headline criterion.

### 4.4 FUH-M8 implementation plan summary

FUH-M8's work is bounded:

1. **Create** `isonim/tests/browser/e2e_editor_full_acceptance_matrix_live.mjs`
   per §3 layout. Single top-level `test()` block; 18 sub-tests via
   `t.test()`. Reuse `chromium.launch` once.
2. **Optionally extract** shared helpers to
   `isonim/tests/browser/lib/fuh_m8_helpers.mjs`. Skip if it
   blows the FUH-M8 budget; the matrix file standalone is fine.
3. **Create** `isonim/tests/browser/golden/fuh-m8/` directory; ensure
   `.gitignore` covers `<timestamp>.json` files but tracks the
   directory.
4. **Implement** the 6 measurement helpers + `assertAcceptance(cell)`
   per §3.3 — every threshold mapped to a campaign-locked constant
   at the top of the matrix file:
   ```js
   const THRESHOLDS = Object.freeze({
     medianFrameLatencyMs: 50, // EPP-M8
     idleMedianPacketBytes: 512, // ELT-M9
     clickResponseMs: 33, // EPP-M12 (one frame @ 30 FPS)
     hoverOverlayMs: 16, // ETS-M6 + FUH-M3
     dprDriftPx: 1, // EPP-M2 + EPP-M8
     losslessMinUniqueColors: 2, // ELT-M9
   });
   ```
5. **Run** the matrix; capture the per-cell JSON; commit goldens
   only AFTER the run lands honestly.
6. **Do not weaken thresholds.** If any cell fails, surface the
   failing measurement + assertion in the matrix output; the
   FUH-M9 scorecard reports it honestly per the campaign brief.
   Loosening a threshold is forbidden per the FUH-M1-onwards
   "no test weakening" rule.

The matrix's runtime is bounded to ≤ 10 minutes sequential — the
orchestrator should NOT time-out below 15 minutes when running this
test, but the test itself targets 9 minutes wall-clock.

---

## Appendix A — Sequential execution rationale (FUH-M6 finding)

FUH-M6 documented this finding while implementing the in-process
libwebp test: spawning a second cocoa launcher while a first is
still running deadlocked on the macOS VideoToolbox session lock,
and a Chromium context attached to the second launcher's proxy
hung waiting for WS frames that never arrived because the launcher
itself was blocked.

The matrix sidesteps this by:

1. Spawning ONE launcher at a time.
2. Killing it (SIGTERM → 200 ms → SIGKILL) before spawning the
   next.
3. Reusing the SAME `browser` across cells (avoid repeat
   `chromium.launch` cost — the EPP-M8 singleton pattern).
4. Creating a FRESH `browserContext` per cell (clean WS state,
   clean instrumentation buffers).

This is also why a single top-level `test()` block is preferred
over 18 sibling `test()` blocks — node's test runner can be
configured to parallelise siblings (`--test-concurrency=N`),
and a stray harness reconfiguration could break the
serialisation invariant. Subtests inside a parent `test()` ALWAYS
run sequentially.

## Appendix B — Status-file update for this milestone

```
* FUH-M7: Phase C audit — define the full acceptance matrix
  :PROPERTIES:
  :status: complete
  :scope: ...
  :END:

* Document
  :PROPERTIES:
  :current_milestone: "FUH-M7 complete"
  :next_steps: Dispatch FUH-M8 to implement
    isonim/tests/browser/e2e_editor_full_acceptance_matrix_live.mjs
    per the layout in
    isonim/docs/full-acceptance-matrix-FUH-M7.md (§3).
    Sequential execution is mandatory (FUH-M6 deadlock note).
    18 cells × ≤ 30 s = ≤ 9 minutes wall-clock target.
  :END:
```
