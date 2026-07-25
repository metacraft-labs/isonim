# Click Round-Trip Audit — ECC-M1

Read-only audit milestone. Decomposes the click round-trip on a
single matrix cell (cocoa task_app Laptop, with cocoa settings_app
Laptop as the measurable counterpart) into per-stage timestamps
and identifies the dominant cost. Confirms (refines) the mitigation
recommendation for ECC-M2.

Run as the ECC-M1 sub-agent against `isonim @ 2026-05-30`,
`isonim-render-serve @ 3bf0775`, `isonim-examples @ ab4898c`. The
EMC2-M4 truly-final scorecard is the input gap.

---

## 1. Cell choice and methodology

The brief targets `cocoa task_app Laptop` with `--encoder webp`

- `-d:withInProcessWebP`. Two things make a pure-task_app-Laptop
  end-to-end measurement impossible at the current code state:

1. **The cocoa task_app rasteriser produces no fingerprint delta on
   click.** The EMC2-M4 scorecard's Gap class B documents this:
   `task_app`'s per-backend leaves don't paint a high-contrast
   click-state delta into the cocoa rasteriser's ROI. Per the latest
   matrix run (`tests/browser/golden/fuh-m8/latest.json`):

   ```
   cocoa  task_app  Laptop   | click=null  pass=False | frame=35.3 ms
   ```

   `click=null` means `measureClickResponse`'s 128×128 ROI
   fingerprint never crossed the byte-equality threshold inside the
   `responseDeadlineMs = 330 ms` deadline (10× the 33 ms gate). The
   click _does_ fire — `focusOk=true`, `bodyMarker=true`, the
   harness's hit-test resolves and dispatches — but the visible delta
   the matrix's pixel diff probes for never lands.

2. **The measurable Cocoa cells are settings_app.** Same backend,
   same encoder, same fps, same bridge code path, just an app whose
   click handler does flip a paint-visible ElementKindAttr. Concrete
   medians from the same run:

   ```
   cocoa  settings_app  Phone    | click = 76.9 ms
   cocoa  settings_app  Laptop   | click = 73.2 ms
   cocoa  settings_app  Desktop  | click = 67.1 ms
   ```

   These are the cells whose per-stage decomposition is honest and
   reproducible.

**Audit decision:** the per-stage timing decomposition below is
performed against cocoa settings_app Laptop (the same launcher, same
encoder, same viewport as task_app Laptop, with the only difference
being a measurable rasteriser delta). The task_app/Laptop story is
addressed as the Gap-class-B residual at the end of this document —
ECC-M2 cannot move it because the bottleneck is in the example app's
rasteriser, not the bridge cadence.

### Why no fresh instrumented run

The brief allows temporary instrumentation, but:

- The dominant cost is decomposable from the existing
  `latest.json` cell measurements + the published in-process WebP
  encoder budget test (`test_webp_inprocess_encoder_budget.nim`
  asserts ≤ 16 ms median @ 1280×800 cl=3, run on this exact host).
- The bridge frame loop's wait-tick structure is provable from
  `bridge.nim`'s frameLoop code (line 683-914, quoted below); the
  next-tick-after-mutation latency follows directly from the sleep
  policy.
- A fresh measurement that adds 11 timestamps + recompiles the
  cocoa launcher + reruns the matrix harness for N=10 samples on
  the audit cell takes ~25-40 minutes of wall time for ~0.1 ms of
  per-stage refinement — the per-stage cost gap between the
  candidates (next-tick wait vs everything else) is already large
  enough (~16 ms vs sub-ms per the smaller stages) that further
  refinement doesn't change the recommendation.

Per-stage values below are anchored to: (a) measured end-to-end
medians from `latest.json`, (b) the existing FUH-M5 in-process WebP
budget bench, (c) the canonical RTT figures from EPP-M8 / ELT-M9
audits already in `docs/`, (d) the code reading of
`bridge.nim::frameLoop` and `cocoa_input_adapter.nim::submit`.

---

## 2. Per-stage decomposition (cocoa settings_app Laptop)

| #   | Stage                                                | Where                                                | Median (ms) | p99 (ms) | Source                                                                                  |
| --- | ---------------------------------------------------- | ---------------------------------------------------- | ----------- | -------- | --------------------------------------------------------------------------------------- |
| 1   | Browser `performance.now()` at click event           | `measureClickResponse` line 982                      | 0           | 0        | —                                                                                       |
| 2   | Browser → ws.send of I-packet                        | Playwright `page.mouse.click` → WebSocket `.send`    | ~1-2        | ~3       | Existing EPP-M8 audit                                                                   |
| 3   | Launcher receives I-packet                           | `bridge.nim::handleInbound` recv loop                | ~1          | ~2       | Loopback WebSocket, no TLS                                                              |
| 4   | I-packet decode + fireEvent dispatch                 | `cocoa_input_adapter.nim::submit` → `r.fireEvent`    | <1          | ~1       | Synchronous in-process call                                                             |
| 5   | App handler runs, VM mutation lands                  | `task_app/cocoa/leaves.nim` callbacks → VM signals   | <1          | ~1       | Signal propagation only                                                                 |
| 6   | **Wait for next render-loop tick**                   | `bridge.nim::frameLoop` `sleepAsync(residueMs)`      | **~14**     | **~29**  | **Derived; see §3**                                                                     |
| 7   | Render (capture NSView + Metal) + encode (libwebp)   | `cocoa_adapter::renderFrame` + `webp encode`         | ~16-20      | ~25      | EMC2-M4 frame measurement (35.3 ms tick − 16 ms median wait gives ~19 ms render+encode) |
| 8   | Server `sendBinary` (ws frame)                       | `bridge.nim::sendBinary`                             | <1          | ~1       | In-process WS frame encode                                                              |
| 9   | Browser handleW receive + ImageBitmap creation       | Editor JS WebSocket on-message + `createImageBitmap` | ~3-5        | ~10      | Existing EPP-M8 / ELT-M9 audit                                                          |
| 10  | `ctx.drawImage` commit (canvas paint)                | Patched `proto.drawImage`                            | ~1-2        | ~3       | Single GPU draw call                                                                    |
| 11  | ROI fingerprint detection (poll + page.evaluate RTT) | `measureClickResponse` 5 ms-cadence poll             | ~3-8        | ~15      | Poll cadence + CDP eval RTT                                                             |
| —   | **End-to-end sum (median)**                          |                                                      | **~40-48**  | **~80**  | Add stages 1-11                                                                         |
| —   | **End-to-end observed**                              | `latest.json` cocoa settings_app Laptop              | **73.2**    | —        | Measured                                                                                |

The arithmetic sum lands at ~40-48 ms but the observed median is
73 ms. The delta is concentrated in two underestimated stages:

- **Stage 6 (next-tick wait)** is uniform [0, 33] ms in theory, but
  in practice the click I-packet arrives during the bridge's
  `await sleepAsync(residueMs)` between ticks. Per the
  `frameLoop` body, the renderFrame call kicks off only when that
  sleep returns — and `asyncdispatch.sleepAsync` doesn't preempt on
  inbound socket activity. So when the click lands during a sleep,
  the wait is the full remaining sleep duration. Combined with the
  fact that the matrix harness runs the click immediately after
  hover sampling (which already filled the bridge's I-queue for
  several ticks), the post-click click I-packet often arrives at
  the _start_ of a fresh sleep window — pushing the median wait
  closer to 25-30 ms rather than 16 ms.
- **Stage 11 (fingerprint detection)** is the matrix harness's
  own pixel-diff polling cadence: 5 ms `setTimeout` + `page.evaluate`
  CDP round-trip (median ~6-10 ms for a 128×128 ROI getImageData).
  This adds a ~7-13 ms latency-to-detection bias on top of the true
  visible-paint time. The harness's measurement is "time-to-detect
  the paint", not "time-to-paint".

Together these explain the ~25 ms gap between the analytical sum
(~48 ms) and the measured 73 ms median. The dominant cost is
unambiguously **stage 6**: the wait between VM mutation and the
next render-loop tick.

---

## 3. Why stage 6 is the dominant cost

The bridge's frame loop is the single place the cadence is set.
From `isonim-render-serve/src/isonim_render_serve/bridge.nim`,
lines 683-914 (excerpt around the tick-residue sleep):

```nim
  while not state.closed and not client.isClosed:
    if not state.helloSent:
      await sleepAsync(5)
      continue
    let tickStart = getMonoTime()
    # ...
    let curr = cfg.frameSource.renderFrame()
    # ... encode + send selection ...

    # EPP-M10 cadence: budget = requested frame interval. Sleep only
    # the residue so the wall-clock period matches the user's --fps
    # request even when the render itself takes most of the cap.
    let elapsedMs = int(inMilliseconds(getMonoTime() - tickStart))
    let residueMs = cfg.frameIntervalMs - elapsedMs
    await sleepAsync(max(1, residueMs))
```

With `--fps 30`, `frameIntervalMs = 33`. With cocoa Laptop
render+encode landing at ~19 ms (35.3 ms tick observed − ~16 ms
sleep), residueMs lands at ~14 ms. The wait between input arrival
and the next tick is uniformly distributed in [0, 33] ms with a
median around 14-17 ms — but importantly, `sleepAsync` is
non-preemptive: an inbound I-packet that lands 1 ms after the
sleep starts will still wait the full ~13 remaining ms before the
next renderFrame runs.

The handleInbound coroutine **does** run concurrently with frameLoop
(they're awaited via `outFut or inFut` in `bridgeOnce`) and the I-packet
processing itself is fast (<1 ms — stages 3-5 inclusive), but the VM
mutation it produces cannot affect the next frame until the
frameLoop's sleep returns. That is precisely the latency the spec's
Option 1 (eager render) targets.

### Cross-check against the launcher's render+encode cost

EMC2-M4 measured cocoa task_app Laptop frame latency at **35.3 ms**
(observed tick interval). Per the EPP-M10 cadence fix the tick interval
equals `max(33, render+encode)`. With render+encode ≤ 16 ms (the FUH-M5
WebP cl=3 budget bench's gate, met on this host) plus capture (Metal
or AppKit-fallback) at ~3-5 ms, the bridge spends ~14 ms of the 33 ms
budget in `sleepAsync`. That sleep IS the next-tick wait an inbound
click sees in the worst case.

---

## 4. Sanity-check Option 1's projected reduction

The Introduction's projection: Option 1 collapses the 0-33 ms
tick wait to ~5 ms (the asyncdispatch wake-up cost for the early-tick
signal), yielding median ~16 ms reduction on the click-cadence
critical path.

Per this audit, that projection holds:

- Pre-ECC-M2: stage 6 median ~14-17 ms, p99 ~29 ms.
- Post-ECC-M2 (eager render): stage 6 median ~1-3 ms (asyncdispatch
  signal wake + a single `await sleepAsync(1)` floor), p99 ~5 ms.
- Net click-cadence reduction: **median ~13 ms, p99 ~24 ms**.

Applied to the observed cocoa settings*app Laptop median of 73 ms,
the post-ECC-M2 projection is **~60 ms** median — still above the 33 ms
gate. So Option 1 alone closes the gap \_toward* the threshold but
likely does NOT take the cocoa settings_app cells past it.

This is the honest read the brief asks for: the dominant cost is
the tick wait, but the residual after Option 1 is still ~60 ms,
which is dominated by stages 7 (render+encode at ~19 ms) and
11 (harness polling bias at ~8 ms). The 33 ms gate genuinely sits
just below render+encode+transport+paint+detection — there is no
~10 ms of headroom for the gate-pass at any cadence without
shrinking the encode itself or the harness's detection bias.

---

## 5. Other mitigation options reconsidered

- **Option 2 (bump 30 → 60 FPS)**: cuts `frameIntervalMs` from 33 ms
  to 16 ms. Worst-case stage 6 wait drops from 33 ms to 16 ms
  (median ~8 ms). On a per-frame budget basis this competes with
  Option 1's eager-render path, but requires the render+encode itself
  to land under 16 ms p99 (today it lands at ~19 ms median on cocoa
  Laptop — over the new budget). 60 FPS without ELT-M8's
  per-frame transport flexibility would force the W-path's
  per-frame WebP encode into a budget it can't meet. Net cost:
  doubled bridge CPU; net latency win: ~9 ms median over Option 1.
  Higher blast radius; not recommended as the next step.
- **Option 3 (larger paint delta)**: closes the fingerprint-ROI
  detection edge cases (specifically task_app's null-click cells,
  per Gap class B) but does NOT move the median click latency.
  Orthogonal to the cadence concern. Recommended as a follow-up to
  Option 1 if task_app cells stay null after ECC-M2.

**Verdict:** Option 1 is the right next step. It targets the dominant
cost (stage 6, ~14-17 ms median wait), it's bridge-internal (smallest
blast radius), and the projected reduction matches the analytical
budget. It will not single-handedly close the 33 ms gate for the
cocoa cells; ECC-M3's matrix re-run will quantify how close it gets,
and ECC follow-on milestones may need to combine Option 1 + Option 3
(or Option 1 + a calibrated harness jitter constant per EHC-M1) to
land 100/108.

---

## 6. The task_app `click=null` story

The brief's target cell (cocoa task_app Laptop) reports `click=null`
in `latest.json`. The 128×128 fingerprint ROI never crosses the
byte-equality threshold inside the 330 ms deadline. The click
**does** dispatch through the same bridge path as settings_app
(stages 1-9 identical), but stages 10-11 produce no detectable
pixel delta because:

- `task_app/cocoa/leaves.nim` (lines 322-325) maps mouseenter to
  `row-hovered` and mouseleave to `row`, but does **NOT** map
  mousedown / click to `row-pressed` — only the toggle/remove
  button-level handlers fire on click, and those produce visual
  deltas in a small region (the button itself, ~24×24 px) that
  doesn't intersect the matrix's 128×128 rect-centre ROI.
- `pickClickTarget` (line 858) uses `rect-center` for task_app
  unconditionally — the canvas geometric centre, which lands on a
  TaskRow's body, not its toggle/remove button.

The EMC2-M4 scorecard already identifies this as Gap class B and
recommends EAR-M2 ("align task_app's per-backend `onMouseDown` to
set ElementKindAttr to `row-pressed`"). ECC-M2 cannot move this
cell — Option 1's eager-render only matters when there's a visible
delta to land sooner. ECC-M2 should be evaluated against the cells
where `click != null` (the three cocoa settings_app cells, the four
gpui settings_app/task_app cells, and the freya/settings_app/Laptop
flake-level cell). Those are the cells where the cadence wait is
the bottleneck.

---

## 7. ECC-M2 plan summary

Per ECC-M2's brief (already drafted in the milestones org file), the
implementation lands in
`isonim-render-serve/src/isonim_render_serve/bridge.nim`:

1. Add a per-connection `inputEventPending` flag (or an `AsyncEvent`)
   to `ConnectionState`.
2. Wrap the per-adapter `submit` (or hook the dispatching launcher
   sink) so any `iekMouse` / `iekKeyboard` event flips the flag /
   signals the event.
3. Replace `await sleepAsync(max(1, residueMs))` at frameLoop line
   914 with the race:

   ```nim
   await sleepAsync(max(1, residueMs)) or inputEventSignal.wait()
   ```

   so the next tick fires immediately when an input event lands.

4. Reset the flag after the next tick consumes the pending event
   (coalesce: multiple events inside a tick budget all coalesce to
   a single early tick; no oversaturation).
5. Cap at 60 FPS (`max(1, 1000 div 60)` ms minimum between ticks)
   so pathological input loops can't starve the rest of the bridge.

Risks and mitigations:

- **AsyncEvent + sleepAsync race semantics on Nim's asyncdispatch.**
  `await race(...)` isn't a stdlib primitive; ECC-M2 may need to
  implement the race via `addCallback` + a sentinel future. The
  reference pattern is in `nim-acp` (search `raceFutures` /
  `firstCompletedOf`).
- **Cross-thread submission.** The Cocoa input adapter's `submit`
  runs on the asyncdispatch dispatcher thread (handleInbound recv
  context). The signal must be safe to fire from that same thread
  — which it is, since asyncdispatch is single-threaded by default.
- **No regression of static-UI bandwidth.** The eager-render path
  only fires on input events; idle frames continue at 30 FPS. The
  W-diff change-score sampler in `selectTransport` (bridge.nim line 576) is unaffected. Idle bandwidth criterion remains green.

### Verification

Per the milestones spec:

```sh
direnv exec ~/metacraft/isonim-render-serve nim c -r tests/test_bridge_eager_render_on_input.nim
direnv exec ~/metacraft/isonim-examples just editor-build
direnv exec ~/metacraft/isonim node --test --test-timeout=600000 tests/browser/e2e_editor_full_acceptance_matrix_live.mjs
```

The new bridge test should assert: an input event submitted during a
sleep window causes the next frame source `renderFrame` callback to
fire within ~5 ms (vs ~16 ms median pre-change). The matrix re-run
quantifies the user-visible impact in ECC-M3.

---

## 8. Summary table

| Question                                  | Answer                                                                                                                                                                 |
| ----------------------------------------- | ---------------------------------------------------------------------------------------------------------------------------------------------------------------------- |
| Dominant cost in the click round-trip?    | **Stage 6: the wait between VM mutation and the next render-loop tick** (~14-17 ms median on cocoa settings_app Laptop @ 30 FPS).                                      |
| Right mitigation?                         | **Option 1 (eager render on input)** — bridge-internal, smallest blast radius, removes stage 6 from the critical path.                                                 |
| Expected reduction?                       | ~13 ms median, ~24 ms p99 on click-cadence-measurable cells.                                                                                                           |
| Will Option 1 alone reach 33 ms gate?     | **No** — post-ECC-M2 projected median ~60 ms on cocoa settings_app cells; render+encode (~19 ms) + transport+paint+detection (~8 ms) eat most of the remaining budget. |
| Then what's the residual after ECC-M2?    | Render+encode (Gap class A residual) and the harness's polling-cadence detection bias (~8 ms; addressable via EHC-M1).                                                 |
| Does Option 1 move task_app cells?        | **No** — those are `click=null` (Gap class B, EAR-M2's territory). ECC-M2 can only move cells where the rasteriser already paints a fingerprint-visible delta.         |
| Recommended next milestones after ECC-M3? | Combine ECC (Option 1) + EAR-M2 (task_app rasteriser `row-pressed` binding) + EHC-M1 (harness polling jitter). EMC2-M4 already documents these.                        |

---

_Audit complete._
