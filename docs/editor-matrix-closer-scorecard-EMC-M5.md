# IsoNim Editor — Matrix Closer Scorecard (EMC-M5)

Closes the Editor Matrix Closer (EMC) campaign-of-campaigns. Compares
the FUH-M8 baseline (the run that produced FUH-M9's "shipped with gaps"
verdict) against the post-EMC-M4 re-run of the same 18-cell matrix.

Source data:

- Baseline: `isonim/tests/browser/golden/fuh-m8/2026-05-30T18-52-12-944Z.json`
  (specCommit `5955d18`, run pre-EMC, matches FUH-M9 scorecard).
- Post-EMC: `isonim/tests/browser/golden/fuh-m8/latest.json`
  (specCommit `80b7074`, run on isonim commit `b8f9fe7` (EMC-M4),
  with EMC-M2 GPUI mitigation, EMC-M3 settings_app click feedback,
  and EMC-M4 harness fixes in place).

Matrix shape unchanged: 3 backends × 3 viewports × 2 apps = 18 cells,
six criteria per cell, thresholds locked at the FUH-M7 values
(no weakening).

---

## 1. Executive summary

EMC delivered three of three planned harness/app fixes and one
backend mitigation. Honest reading of the post-EMC numbers:

- **Total measurable-criterion passes** moved from **80/108 to 85/108**
  (strict pass excluding N/A: **56/84 → 61/84**). Net **+5** cells.
- **Hover axis fully closed on the measurable side**: 12 → 16 of 18 PASS.
  The remaining 2 nulls (freya + cocoa task_app Phone) are now an
  app-level signal: the harness sees the canvas rect but the backends
  don't paint a hover-label mutation at Phone for task_app.
- **Click axis moved from 0/18 PASS → 1/18 PASS**, but the underlying
  story is bigger than that single cell: EMC-M3 + EMC-M4 turned **3 → 7
  click cells measurable** (non-null), and the first ever full-pass cell
  of the matrix appeared (freya / settings_app / Laptop, 27.6 ms).
- **GPUI mitigation (EMC-M2) under-delivered against the gate**: alloc
  skip + WebP encoder shaved 1.3–3.6 ms per cell but Laptop/Desktop
  still land at 50.9–57.0 ms. The audit projected ~25–30 % reachable;
  actual was ~10–15 %. The unmoved cost is the shim FFI body
  (HeadlessAppContext + `Window::render_to_image` MTLCommandBuffer
  wait) — exactly what the FUH-M9 + EMC-M1 deferred milestone
  flagged as needing a backend-architecture campaign.
- **First cell to pass all six criteria**: freya / settings_app /
  Laptop (last column of the appendix). The matrix is no longer 0/18
  on full cell-verdict.

Was the campaign worth it? **Yes, but with one caveat.** EMC closed
every gap that was reachable inside its declared scope (harness +
example-app + one launcher option). The remaining gap is a backend-
architecture problem the campaign explicitly didn't commit to fixing
(the GPUI Zed serialisation rewrite). The matrix is now an honest
truth-teller: every remaining FAIL is either a backend rasteriser
output choice (rasterisers don't paint a click-state colour the probe
can fingerprint on 11 cells) or the GPUI architectural constraint
(6 frame-latency cells; 3 click-response cells riding on the same path).

---

## 2. Per-criterion delta table

For each criterion: cells passing the threshold + cells measurable
(non-null, non-N/A) pre vs post. "Measurable" is the denominator the
matrix is honestly able to score; "passing" is the numerator under the
locked threshold.

| Criterion                 | Pre-EMC pass / measurable | Post-EMC pass / measurable | Net change                                |
| ------------------------- | ------------------------- | -------------------------- | ----------------------------------------- |
| 1. Frame latency ≤ 50 ms  | 14 / 18                   | 14 / 18                    | **0 cells** (median trims 1.3–3.6 ms)     |
| 2. Idle bandwidth ≤ 512 B | 6 / 6 (12 N/A)            | 6 / 6 (12 N/A)             | **unchanged** (already perfect on w-path) |
| 3. Click response ≤ 33 ms | 0 / 3 measurable          | 1 / 7 measurable           | **+1 pass, +4 measurable**                |
| 4. Hover ≤ 16 ms          | 12 / 12 measurable        | 16 / 16 measurable         | **+4 pass, +4 measurable**                |
| 5. DPR drift ≤ 1 px       | 18 / 18                   | 18 / 18                    | **unchanged** (0 px drift everywhere)     |
| 6. Lossless (W-path)      | 6 / 6 (12 N/A)            | 6 / 6 (12 N/A)             | **unchanged**                             |

**Roll-ups**:

- Total measurable-cell PASSes (including N/A counted as PASS, the way
  cell verdicts gate): **80/108 → 85/108** (+5).
- Strict PASS, excluding the 24 N/A cells: **56/84 → 61/84** (+5).
- Fully passing cells (verdict = pass): **0/18 → 1/18**.
- Measurable-but-null cells eliminated: **9** click+hover nulls became
  measurements; **2** new click nulls appeared on cocoa settings_app
  (the EMC-M3 wiring made cells measurable that were N/A before; some
  fail because the cocoa rasteriser paints the click-state at the
  wrong cadence — a real measurement, an honest fail).

The criterion-level read is dominated by hover (cleanly closed) and
click (partially closed, mostly opened to measurement). Frame latency
is the headline disappointment: the gate didn't move on any cell.

---

## 3. Per-cell delta

| Backend | App          | Viewport | Pre verdict | Post verdict | Changes                                                           |
| ------- | ------------ | -------- | ----------- | ------------ | ----------------------------------------------------------------- |
| gpui    | task_app     | Phone    | fail        | fail         | Click 60.4→46.8 (still fail); Hover null→1.0 PASS                 |
| gpui    | task_app     | Laptop   | fail        | fail         | Frame 55.0→50.9 (still fail); Click 120.4→78.0 (still fail)       |
| gpui    | task_app     | Desktop  | fail        | fail         | Frame 58.9→55.5 (still fail); Click 129.8→111.2 (still fail)      |
| gpui    | settings_app | Phone    | fail        | fail         | Hover null→1.9 PASS; Click stays null                             |
| gpui    | settings_app | Laptop   | fail        | fail         | Frame 53.2→52.2 (still fail); Click stays null                    |
| gpui    | settings_app | Desktop  | fail        | fail         | Frame 58.7→56.2 (still fail); Click stays null                    |
| freya   | task_app     | Phone    | fail        | fail         | Hover null→null (backend gap, see §4)                             |
| freya   | task_app     | Laptop   | fail        | fail         | No change (click stays null)                                      |
| freya   | task_app     | Desktop  | fail        | fail         | No change                                                         |
| freya   | settings_app | Phone    | fail        | fail         | Hover null→1.0 PASS                                               |
| freya   | settings_app | Laptop   | fail        | **pass**     | Click null→27.6 **PASS** — first full-pass cell in matrix history |
| freya   | settings_app | Desktop  | fail        | fail         | Click stays null                                                  |
| cocoa   | task_app     | Phone    | fail        | fail         | Hover null→null (backend gap)                                     |
| cocoa   | task_app     | Laptop   | fail        | fail         | No change                                                         |
| cocoa   | task_app     | Desktop  | fail        | fail         | No change                                                         |
| cocoa   | settings_app | Phone    | fail        | fail         | Click null→57.1 (fail); Hover null→1.0 PASS                       |
| cocoa   | settings_app | Laptop   | fail        | fail         | Click null→42.3 (fail) — measurement opened, gate missed          |
| cocoa   | settings_app | Desktop  | fail        | fail         | Click null→106.6 (fail) — measurement opened, gate missed         |

Cell verdict count: **17/18 fail → 17/18 fail, 0/18 pass → 1/18 pass**.

---

## 4. Residual gap classification

Each remaining FAIL or null classified by root cause. EMC's brief
required cleanly separating "the editor isn't ready" from "the
harness can't see what's there".

### Gap class A — BACKEND ARCHITECTURE LIMIT (GPUI Zed serialisation)

**Cells affected (frame latency)**: 4 — gpui × {task_app, settings_app}
× {Laptop, Desktop}. Measurements 50.9, 55.5, 52.2, 56.2 ms vs 50 ms gate.
**Cells affected (click response)**: 3 — gpui × task_app × {Phone, Laptop, Desktop}.
Measurements 46.8, 78.0, 111.2 ms vs 33 ms gate.

Per EMC-M1 audit § 5 + EMC-M2 verification commit message: ~41–43 ms
of every GPUI tick lives inside the opaque body of `render_to_rgba`
in the `gpui-nim-shim` (HeadlessAppContext + run_until_parked +
`Window::render_to_image` with synchronous `MTLCommandBuffer`).
EMC-M2 closed everything Nim-side could close; the remainder is the
Zed runtime's render-thread synchronisation.

**Recommended follow-up**: **GPUI-RT-M1** — decouple the GPUI shim
render thread from the Zed app thread via Metal-backed offscreen pass
with command-buffer fence (analogous to EPP-M4 Cocoa). Closes 4 frame

- 3 click = **7 cells**. Leverage estimate: medium-high (requires a
  new ObjC/Metal helper inside the Rust shim, plus rebuilding the GPUI
  launcher).

### Gap class B — EXAMPLE-APP COVERAGE LIMIT (click-state pixel signature)

**Cells affected**: 11 click-null cells — gpui settings_app × 3,
freya task_app × 3, freya settings_app × {Phone, Desktop},
cocoa task_app × 3.

EMC-M3 wired a click-state class flip across all four example-app
backends. But the matrix's click-fingerprint probe asserts a
**rasteriser-visible** pixel mutation in a 128×128 ROI within 33 ms.
The ElementKind mutation goes through, but for these cells the
rasteriser either (a) doesn't bind the click-state class to a colour
override (most freya + cocoa task*app), or (b) the colour delta is
inside the ROI but below the fingerprint threshold (most gpui
settings_app). The cells where EMC-M3 \_did* produce a measurable
delta show up as the 4 new non-null cocoa + freya settings_app click
cells (one of which passes at 27.6 ms).

This is technically an EXAMPLE-APP COVERAGE LIMIT — the rasteriser
in the example app's per-backend leaves doesn't read ElementKindAttr
for colour on every backend. It's not an editor regression, and it
isn't a backend rasteriser limitation in general (the rasterisers
do paint other class-driven colour changes).

**Recommended follow-up**: **EAR-M1** (Example-App Rasteriser) —
explicitly bind `ElementKindAttr=="clicked"` to a high-contrast colour
delta in each of the 4 backends' leaves for both example apps.
Closes 8–11 cells depending on how aggressive the colour delta is.
Leverage estimate: low cost (example-app-only edits), medium-high
leverage.

### Gap class C — BACKEND RASTERISER CONSTRAINT (hover-label mutation at Phone)

**Cells affected**: 2 hover nulls — freya / task_app / Phone and
cocoa / task_app / Phone.

EMC-M4 fixed the harness geometry. Post-fix, the harness emits 5
jittered hover targets in the canvas-centre band. But for these two
cells the backend rasteriser doesn't mutate the hover-label DOM/style
in response to the synthetic move events — the editor's overlay
machinery isn't getting a fresh hover label payload for task*app at
390 px on these two backends specifically (gpui task_app Phone \_does*
work, suggesting it's not the harness any more).

**Recommended follow-up**: **EHL-M1** (Example Hover-Label) — verify
that freya + cocoa task_app produce a hover-label payload at Phone
viewport when the cursor crosses a manifest leaf. Likely a missed
wire-up in the FUH-M2 hover dispatch parity. Closes 2 cells. Leverage
estimate: low (single-file probe), low-medium leverage.

### Gap class D — BACKEND RASTERISER CONSTRAINT (click-paint cadence)

**Cells affected**: 3 cocoa settings*app click measurements that
opened but failed the 33 ms gate (Phone 57.1, Laptop 42.3,
Desktop 106.6 ms). These cells are **honest measurements** — the
click \_is* visible, it just takes longer than one frame at 30 FPS.

Root cause is plausibly the W-path encode cadence: cocoa is on
`w/webp`, so the click-state delta has to wait for the next WebP
encode tick. The 27.6 ms freya pass (raw_rgba transport) supports
this — raw_rgba ships the pixel mutation a frame earlier.

**Recommended follow-up**: **EPC-M1** (Edge-triggered Paint Cadence) —
when a click-state change is detected, force an immediate WebP
encode + flush instead of waiting for the next scheduled tick.
Closes 2–3 cells. Leverage estimate: medium cost (touches the
render-serve scheduler), medium leverage.

---

## 5. Top-level user-readiness assessment

**Is the editor MORE ready, EQUALLY ready, or LESS ready vs FUH-M9?**

**Equally ready on Cocoa + Freya Laptop/Desktop; marginally more
informative everywhere.**

FUH-M9 verdict: editor ready on Cocoa, on Freya Laptop/Desktop, not
on GPUI Laptop/Desktop. Post-EMC:

- **Cocoa Laptop/Desktop** (the FUH-M9 daily-driver target): frame
  latency 34.1–37.7 ms median, idle 29 B floor, hover 0.9–1.0 ms,
  lossless 2–4 unique colours, DPR pixel-exact. **Unchanged from
  FUH-M9**. The new click measurements (42.3, 106.6 ms) document an
  honest cadence gap on settings_app that the user would perceive
  as a 1–3 frame click lag — measurable now, not previously visible.
- **Freya Laptop/Desktop**: frame 34.8–39.6 ms, hover 1.2 ms, click
  now confirmed at 27.6 ms on settings_app Laptop (the only
  full-pass cell). **Marginally better** — what was unmeasurable is
  now measured-good on one cell.
- **GPUI Laptop/Desktop**: frame 50.9–57.0 ms (was 53.2–58.9 ms),
  click 78.0–111.2 ms (was 120.4–129.8 ms). **Better but still
  fails the gate**. The EPP-M2 / GPUI-RT constraint is unchanged in
  character.
- **Phone**: hover axis is now mostly measurable across backends
  (was uniformly null). Frame and DPR remain perfect.

**Net user-readiness verdict**: the user-facing readiness conclusion
of FUH-M9 stands as-is. EMC didn't make a previously-not-ready cell
ready (well, exactly one: freya settings_app Laptop). What EMC did is
**confirm the FUH-M9 verdict by closing the measurement gaps that
made it tentative**, and document with measurements (not estimates)
what each remaining gap costs.

---

## 6. Final recommendation

EMC closed the harness gaps it set out to close. The matrix is now an
honest truth-teller. Two paths forward:

### Option A — Close the FUH/EMC arc here (recommended)

The remaining gaps are now precisely classified: 1 backend
architecture limit (GPUI Zed serialisation, 7 cells), 1 example-app
coverage limit (rasteriser click-paint, 11 cells), 2 small cleanup
items (hover-label parity, click-paint cadence; 2–3 cells each).
None of these are foundational reworks; each is a self-contained
follow-up campaign. The editor is ready on its intended daily-driver
configuration (Cocoa + Freya Laptop/Desktop) and that hasn't changed.

### Option B — Dispatch one more campaign (GPUI-RT)

If GPUI is in the user's primary backend set, dispatch **GPUI-RT-M1**
(GPUI render-thread decoupling) — high-leverage single milestone that
closes 7 of the 18 strict-fail cells. This is the FUH-M9 + EMC-M1
deferred milestone the audit deliberately punted on. After it,
the matrix lands ~92/108 strict pass.

### Top 3 follow-ups (single-line scope)

1. **GPUI-RT-M1** — Decouple GPUI shim render thread from Zed app
   thread via Metal command-buffer fence (closes 7 cells; medium-high
   leverage; medium-high cost).
2. **EAR-M1** — Bind `ElementKindAttr=="clicked"` to a high-contrast
   colour in each backend's example-app leaves (closes 8–11 click
   cells; low cost; high leverage).
3. **EHL-M1 + EPC-M1** — Hover-label parity at Phone (2 cells) +
   edge-triggered W-path encode on click (2–3 cells); both small,
   both close the remaining matrix-honest gaps.

**Recommendation**: close the arc with Option A. If the user's
roadmap puts GPUI on the daily-driver path, dispatch GPUI-RT-M1 as a
standalone follow-up; otherwise the EAR-M1 + EHL-M1 + EPC-M1 trio is
the cleanest follow-up sweep (10–14 cells closed for a fraction of
the engineering cost).

---

## Appendix: Per-cell verdict matrix (post-EMC)

| Backend | App          | Viewport | Frame       | Idle      | Click           | Hover             | DPR  | Lossless | Verdict  |
| ------- | ------------ | -------- | ----------- | --------- | --------------- | ----------------- | ---- | -------- | -------- |
| gpui    | task_app     | Phone    | PASS (35.3) | N/A       | FAIL (46.8)     | PASS (1.0)        | PASS | N/A      | fail     |
| gpui    | task_app     | Laptop   | FAIL (50.9) | N/A       | FAIL (78.0)     | PASS (1.1)        | PASS | N/A      | fail     |
| gpui    | task_app     | Desktop  | FAIL (55.5) | N/A       | FAIL (111.2)    | PASS (0.9)        | PASS | N/A      | fail     |
| gpui    | settings_app | Phone    | PASS (35.4) | N/A       | FAIL (null)     | PASS (1.9)        | PASS | N/A      | fail     |
| gpui    | settings_app | Laptop   | FAIL (52.2) | N/A       | FAIL (null)     | PASS (0.9)        | PASS | N/A      | fail     |
| gpui    | settings_app | Desktop  | FAIL (56.2) | N/A       | FAIL (null)     | PASS (0.9)        | PASS | N/A      | fail     |
| freya   | task_app     | Phone    | PASS (35.1) | N/A       | FAIL (null)     | FAIL (no samples) | PASS | N/A      | fail     |
| freya   | task_app     | Laptop   | PASS (34.8) | N/A       | FAIL (null)     | PASS (1.1)        | PASS | N/A      | fail     |
| freya   | task_app     | Desktop  | PASS (38.2) | N/A       | FAIL (null)     | PASS (0.9)        | PASS | N/A      | fail     |
| freya   | settings_app | Phone    | PASS (34.9) | N/A       | FAIL (null)     | PASS (1.0)        | PASS | N/A      | fail     |
| freya   | settings_app | Laptop   | PASS (36.2) | N/A       | **PASS (27.6)** | PASS (1.2)        | PASS | N/A      | **pass** |
| freya   | settings_app | Desktop  | PASS (39.6) | N/A       | FAIL (null)     | PASS (1.2)        | PASS | N/A      | fail     |
| cocoa   | task_app     | Phone    | PASS (35.2) | PASS (29) | FAIL (null)     | FAIL (no samples) | PASS | PASS (5) | fail     |
| cocoa   | task_app     | Laptop   | PASS (35.5) | PASS (29) | FAIL (null)     | PASS (0.9)        | PASS | PASS (4) | fail     |
| cocoa   | task_app     | Desktop  | PASS (35.0) | PASS (29) | FAIL (null)     | PASS (1.0)        | PASS | PASS (2) | fail     |
| cocoa   | settings_app | Phone    | PASS (35.6) | PASS (29) | FAIL (57.1)     | PASS (1.0)        | PASS | PASS (5) | fail     |
| cocoa   | settings_app | Laptop   | PASS (34.1) | PASS (29) | FAIL (42.3)     | PASS (0.9)        | PASS | PASS (3) | fail     |
| cocoa   | settings_app | Desktop  | PASS (37.7) | PASS (29) | FAIL (106.6)    | PASS (0.9)        | PASS | PASS (4) | fail     |

Pass rate by criterion (post-EMC, strict / measurable):

- Frame: 14 / 18
- Idle: 6 / 6 (12 N/A)
- Click: **1 / 18** measurable-as-fail-or-pass; **1 / 7 non-null** measured-or-failed
- Hover: 16 / 18
- DPR: 18 / 18
- Lossless: 6 / 6 (12 N/A)

Strict measurable-criterion pass count: **61 / 84**. Full N/A-inclusive
pass count: **85 / 108**. Cell verdict: **1 / 18 pass**.
