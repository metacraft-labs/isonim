// End-to-end SUSTAINED-render smoke test against the live editor stack.
//
// This is the sibling to ``e2e_editor_real_pixel_round_trip_live.mjs``.
// Where that test proves a single F/W/V frame round-trips from one
// isolated launcher to the browser canvas, THIS test drives the
// REAL ``just editor-serve-all`` stack on port 8091 (per-backend
// launchers behind the editor-server.mjs /bridge/<backend> WS proxy)
// via Playwright Chromium and asserts the three classes of regression
// that ERV-M1/M2/M3 just fixed:
//
//   1. Sustained rendering — for each backend the canvas keeps
//      painting non-zero pixels for 10s after switching to it. Catches:
//      worker-thread crashes that surface 5-10s in, encoder backpressure
//      stalls, WebSocket close races, the bridge silently detaching.
//
//   2. Resize-storm stability — rapidly switching viewport pills does
//      not leave the canvas blank for more than a transient frame or
//      two. Catches: regression of the ERV-M2 ``pendingResizeNeedsFull
//      Frame`` guard / snapshot-stretch fallback.
//
//   3. Backend-switch isolation — switching the active backend pill
//      drops the prior backend's pixels within ~1s. Catches: the
//      shared canvas leaking a stale frame, ERV-M3's stale-frame
//      guard regressing, the prior backend's bridge still piping
//      frames after detach.
//
// Real-environment constraint (per ``feedback_real_environment_tests.md``):
// the test does NOT spawn the editor stack itself. It probes port 8091
// at startup and SKIPs with a clear message if the harness isn't up.
// The orchestrator's responsibility is to run
// ``direnv exec ~/metacraft/isonim-examples just editor-serve-all`` in
// another shell before invoking these tests.
//
// Convention: ``node --test`` (matches the rest of
// ``isonim/tests/browser/e2e_*.mjs``).

import { execSync } from "node:child_process";
import net from "node:net";
import { dirname } from "node:path";
import { fileURLToPath } from "node:url";
import test from "node:test";
import assert from "node:assert/strict";

const __dirname = dirname(fileURLToPath(import.meta.url));

// The canonical port used by ``isonim-examples just editor-serve-all``.
const EDITOR_PORT = 8091;
const EDITOR_URL = `http://127.0.0.1:${EDITOR_PORT}/`;

// Backends the live stack exposes. The matrix is intentionally narrower
// than the per-backend round-trip test because this test exercises
// behaviour ABOVE the per-launcher boundary (UI switching, resize
// pills) and the three streaming desktop backends share that surface.
// Cocoa is macOS-only; the editor-serve-all recipe skips it on Linux.
const isMacOS = process.platform === "darwin";
const BACKENDS = (() => {
  const all = [
    { name: "gpui", labelRx: "gpui" },
    { name: "freya", labelRx: "freya" },
  ];
  if (isMacOS) all.push({ name: "cocoa", labelRx: "cocoa" });
  return all;
})();

// Sustained-render parameters. 10s @ 100ms = 100 samples per backend.
// Real launchers produce frames at 10-60 fps under load; over 10s we
// expect to see continuous paint, with at most a handful of black
// frames during transport hiccups.
const SUSTAIN_DURATION_MS = 10000;
const SUSTAIN_SAMPLE_INTERVAL_MS = 100;
const SUSTAIN_EXPECTED_SAMPLES = Math.floor(
  SUSTAIN_DURATION_MS / SUSTAIN_SAMPLE_INTERVAL_MS,
);
// Allow up to 10% of samples to be black/near-black — one or two black
// frames per backend swap are an expected artefact of the ERV-M2
// resize-bridge, encoder warmup, or a slow first frame after the
// pill click. >10 is a regression of the sustained-paint path.
const SUSTAIN_MIN_GOOD_SAMPLES = Math.floor(SUSTAIN_EXPECTED_SAMPLES * 0.9);
// Per-sample "is the canvas actually painted" threshold. The launchers
// fill the demo content over well above 30% of the canvas surface.
// Anything below this is "black canvas" — the ERV-M2 regression
// signature.
const NON_ZERO_RATIO_MIN = 0.3;

// Resize-storm parameters. Viewport pills get clicked in sequence; the
// canvas is sampled every 50ms so we can see the in-flight transition.
// After the storm settles we sample 20 more frames and assert they
// are ALL good — the post-storm canvas must be a real frame, not a
// stale snapshot.
const RESIZE_STORM_SAMPLE_INTERVAL_MS = 50;
const RESIZE_STORM_INTER_CLICK_MS = 200;
const RESIZE_STORM_SETTLE_MS = 1000;
const RESIZE_STORM_POST_SAMPLES = 20;
const RESIZE_STORM_MAX_CONSEC_BLACK = 3;

// Backend-switch parameters. After clicking the next backend pill we
// expect the canvas fingerprint to diverge from the prior backend's
// baseline within ~1s. The grid is the same 16x16 perceptual grid
// used by the round-trip test; we count cells whose mean colour
// drifted by > FINGERPRINT_CELL_DELTA_MIN per channel.
const SWITCH_BASELINE_GRID = 16;
const SWITCH_CELL_DELTA_MIN = 16; // per-channel mean delta to call a cell "changed"
const SWITCH_CHANGED_CELL_FRACTION_MIN = 0.5; // at least 50% of cells must change
const SWITCH_DEADLINE_MS = 1500;
const SWITCH_SAMPLE_INTERVAL_MS = 100;

// ----------------------------------------------------------------------
// Stack probe — skip cleanly when ``editor-serve-all`` isn't running.
// ----------------------------------------------------------------------

async function probeEditorStack() {
  return new Promise((resolve) => {
    const s = net.connect(EDITOR_PORT, "127.0.0.1");
    let done = false;
    const finish = (ok) => {
      if (done) return;
      done = true;
      try {
        s.destroy();
      } catch (_) {}
      resolve(ok);
    };
    s.once("connect", () => finish(true));
    s.once("error", () => finish(false));
    setTimeout(() => finish(false), 1500);
  });
}

function listenerPidsOnPort(port) {
  // Best-effort PID lookup — used for the "launcher still alive at end"
  // sustained-render assertion. We can't directly observe the per-backend
  // launcher PIDs from outside ``editor-serve-all``, so we lean on the
  // editor-server.mjs proxy: a single listener on 8091 means the host
  // process is alive, which in the editor-serve-all recipe is the
  // parent of all the launcher subprocesses. If the parent dies, the
  // ``trap '... kill 0'`` clause in the Justfile cleans up the
  // children — so "8091 still listening" implies "all launchers were
  // still alive at the end".
  try {
    const out = execSync(`lsof -nP -iTCP:${port} -sTCP:LISTEN -t || true`, {
      stdio: ["ignore", "pipe", "pipe"],
    })
      .toString()
      .trim();
    if (!out) return [];
    return out
      .split(/\s+/)
      .map((p) => Number(p))
      .filter((p) => Number.isFinite(p));
  } catch (_) {
    return [];
  }
}

// ----------------------------------------------------------------------
// Browser harness.
// ----------------------------------------------------------------------

let chromium = null;
let browser = null;

async function ensureBrowser() {
  if (!chromium) {
    const m = await import("playwright");
    chromium = m.chromium;
  }
  if (!browser) browser = await chromium.launch({ headless: true });
  return browser;
}

async function openEditor() {
  const b = await ensureBrowser();
  const ctx = await b.newContext({
    viewport: { width: 1920, height: 1080 },
    deviceScaleFactor: 1,
  });
  const page = await ctx.newPage();
  page.on("pageerror", (e) =>
    console.error("[page] error:", e && e.message ? e.message : String(e)),
  );
  await page.goto(EDITOR_URL);
  await page.waitForSelector('[data-preview-chrome-bar="true"]', {
    timeout: 20000,
  });
  await page.waitForSelector(
    '[data-toolbar-cluster="backend"] [data-choice-group-pill]',
    { timeout: 20000 },
  );
  await page.waitForSelector(
    '[data-toolbar-cluster="viewport"] [data-choice-group-pill]',
    { timeout: 20000 },
  );
  // Same animation-mute trick as the round-trip test: kill all CSS
  // transitions + animations so canvas samples can't catch a chrome-bar
  // pill mid-fade (irrelevant for canvas sampling, but the round-trip
  // test sets it for the same reason and consistency keeps the harness
  // shape uniform).
  await page.addStyleTag({
    content:
      "*, *::before, *::after { transition: none !important;" +
      " animation: none !important; }",
  });
  // Select a story so the preview pane actually mounts a streaming
  // canvas. Without a story the canvas wrapper stays display:none and
  // every sample reads back zero pixels.
  await page.evaluate(() => {
    const rx = /task app/i;
    const rows = document.querySelectorAll("[data-story-row]");
    for (const r of rows) {
      const slug = r.getAttribute("data-story-row") || "";
      if (rx.test(slug)) {
        r.click();
        return;
      }
    }
    const fallback = document.querySelector("[data-story-row]");
    if (fallback) fallback.click();
  });
  return { ctx, page };
}

async function backendPillSelector(page, labelRx) {
  return page.evaluate((rxSrc) => {
    const rx = new RegExp(rxSrc, "i");
    const pills = document.querySelectorAll(
      '[data-toolbar-cluster="backend"] [data-choice-group-pill]',
    );
    for (const p of pills) {
      const lbl =
        p.getAttribute("data-choice-group-label") ||
        p.getAttribute("aria-label") ||
        p.textContent ||
        "";
      if (rx.test(lbl)) {
        return `[data-toolbar-cluster="backend"] [data-choice-group-pill="${p.getAttribute(
          "data-choice-group-pill",
        )}"]`;
      }
    }
    return null;
  }, labelRx);
}

async function selectBackend(page, backend) {
  const sel = await backendPillSelector(page, backend.labelRx);
  assert.ok(
    sel,
    `${backend.name}: backend pill not found in chrome bar — ` +
      "check that the live editor stack exposes this backend (cocoa " +
      "is macOS-only, the Justfile recipe only spawns it on Darwin).",
  );
  await page.locator(sel).click();
  // Tiny settle window for the reactive graph to repaint the cluster
  // and the canvas-mount to swap bridges.
  await page.waitForTimeout(50);
}

async function pickViewportPill(page, label) {
  // Mirrors round-trip test's logic. ``label`` is the human label
  // ("Laptop", "Phone", "Desktop", ...). Returns true if a pill was
  // clicked.
  const pinnedClicked = await page.evaluate((labelArg) => {
    const pills = document.querySelectorAll(
      '[data-toolbar-cluster="viewport"] [data-choice-group-pill]',
    );
    for (const p of pills) {
      const lbl =
        p.getAttribute("data-choice-group-label") || p.textContent || "";
      if (lbl.trim().toLowerCase() === labelArg.toLowerCase()) {
        const rect = p.getBoundingClientRect();
        if (rect.width > 0 && rect.height > 0) {
          p.click();
          return true;
        }
      }
    }
    return false;
  }, label);
  if (pinnedClicked) return true;
  // Try the overflow chevron dropdown for off-pinned viewports.
  const chevronClicked = await page.evaluate(() => {
    const ch = document.querySelector(
      '[data-preview-viewport-overflow="true"]',
    );
    if (!ch) return false;
    ch.click();
    return true;
  });
  if (!chevronClicked) return false;
  await page.waitForTimeout(150);
  return page.evaluate((labelArg) => {
    const opts = document.querySelectorAll(
      "[data-preview-viewport-dropdown-option]",
    );
    for (const o of opts) {
      const lbl = (o.textContent || "").trim().toLowerCase();
      if (lbl === labelArg.toLowerCase()) {
        o.click();
        return true;
      }
    }
    return false;
  }, label);
}

// Sample the active canvas. Returns {w,h,nz,total,gridB64} or null
// when no canvas is mounted. ``gridB64`` is an OPTIONAL packed
// 16x16x3 (u8) perceptual fingerprint used by the backend-switch
// test; sustained-render + resize-storm tests only need {nz,total}
// so callers can pass want_grid=false to skip the encode cost.
async function sampleCanvas(page, wantGrid) {
  return page.evaluate((wantGridArg) => {
    let canvas = null;
    const wrappers = document.querySelectorAll('[data-canvas-wrapper="true"]');
    for (const w of wrappers) {
      if (getComputedStyle(w).display === "none") continue;
      const candidate = w.querySelector("canvas");
      if (!candidate) continue;
      const cr = candidate.getBoundingClientRect();
      if (cr.width > 10 && cr.height > 10) {
        canvas = candidate;
        break;
      }
    }
    if (!canvas) {
      const c = document.querySelector('canvas[data-canvas-active="true"]');
      if (c) canvas = c;
    }
    if (!canvas) return null;
    const ctx = canvas.getContext("2d");
    if (!ctx) return null;
    const w = canvas.width;
    const h = canvas.height;
    if (w <= 0 || h <= 0) return { w, h, nz: 0, total: 0, gridB64: null };
    let img;
    try {
      img = ctx.getImageData(0, 0, w, h);
    } catch (_) {
      return { w, h, nz: 0, total: 0, gridB64: null };
    }
    const data = img.data;
    const total = (data.length / 4) | 0;
    let nz = 0;
    // Non-zero means: any of R/G/B is meaningfully different from
    // the painter's near-black baseline (#000 / #181818). We use a
    // simple "any channel > 24" threshold to match the round-trip
    // test's "non-zero ratio > 50%" spirit at sample-grain cost.
    for (let i = 0; i < data.length; i += 4) {
      const r = data[i];
      const g = data[i + 1];
      const b = data[i + 2];
      if (r > 24 || g > 24 || b > 24) nz++;
    }
    let gridB64 = null;
    if (wantGridArg) {
      // Pack the 16x16x3 (u8) perceptual grid.
      const G = 16;
      const cellW = Math.max(1, Math.floor(w / G));
      const cellH = Math.max(1, Math.floor(h / G));
      const grid = new Uint8ClampedArray(G * G * 3);
      for (let gy = 0; gy < G; gy++) {
        for (let gx = 0; gx < G; gx++) {
          const x0 = gx * cellW;
          const y0 = gy * cellH;
          const x1 = Math.min(w, x0 + cellW);
          const y1 = Math.min(h, y0 + cellH);
          let cR = 0,
            cG = 0,
            cB = 0,
            cN = 0;
          for (let yy = y0; yy < y1; yy++) {
            const rowOff = yy * w * 4;
            for (let xx = x0; xx < x1; xx++) {
              const off = rowOff + xx * 4;
              cR += data[off];
              cG += data[off + 1];
              cB += data[off + 2];
              cN++;
            }
          }
          const base = (gy * G + gx) * 3;
          if (cN > 0) {
            grid[base] = Math.round(cR / cN);
            grid[base + 1] = Math.round(cG / cN);
            grid[base + 2] = Math.round(cB / cN);
          }
        }
      }
      let s = "";
      const CHUNK = 0x8000;
      for (let i = 0; i < grid.length; i += CHUNK) {
        s += String.fromCharCode.apply(
          null,
          grid.subarray(i, Math.min(i + CHUNK, grid.length)),
        );
      }
      gridB64 = btoa(s);
    }
    return { w, h, nz, total, gridB64 };
  }, wantGrid);
}

async function waitForNonZeroCanvas(page, timeoutMs = 15000) {
  const t0 = Date.now();
  while (Date.now() - t0 < timeoutMs) {
    const s = await sampleCanvas(page, false);
    if (s && s.total > 0 && s.nz / s.total > NON_ZERO_RATIO_MIN) return true;
    await page.waitForTimeout(100);
  }
  return false;
}

function compareGrids(aB64, bB64) {
  // Returns { changedCells, totalCells } — count of grid cells where
  // the per-channel max absolute delta exceeds SWITCH_CELL_DELTA_MIN.
  const a = Buffer.from(aB64, "base64");
  const b = Buffer.from(bB64, "base64");
  if (a.length !== b.length) {
    throw new Error(`grid length mismatch: ${a.length} vs ${b.length}`);
  }
  const cells = (a.length / 3) | 0;
  let changed = 0;
  for (let i = 0; i < cells; i++) {
    const off = i * 3;
    const dr = Math.abs(a[off] - b[off]);
    const dg = Math.abs(a[off + 1] - b[off + 1]);
    const db = Math.abs(a[off + 2] - b[off + 2]);
    if (Math.max(dr, dg, db) > SWITCH_CELL_DELTA_MIN) changed++;
  }
  return { changedCells: changed, totalCells: cells };
}

// ----------------------------------------------------------------------
// Test harness lifecycle.
// ----------------------------------------------------------------------

let stackUp = false;

test.before(async () => {
  // ffmpeg isn't needed here (no W/V decode) but we still want to fail
  // fast if Playwright can't import. The ensureBrowser() lazy import
  // covers that — it'll throw with a clear message on first test.
  stackUp = await probeEditorStack();
  if (!stackUp) {
    console.warn(
      `[sustained-render] port ${EDITOR_PORT} is not listening — ` +
        "the live editor stack isn't running. Start it with " +
        "`direnv exec ~/metacraft/isonim-examples just editor-serve-all` " +
        "in another shell, then re-run this test.",
    );
  }
});

test.after(async () => {
  try {
    if (browser) await browser.close();
  } catch (_) {}
});

// ----------------------------------------------------------------------
// Test 1: sustained rendering per backend.
// ----------------------------------------------------------------------

test("sustained rendering — 100 samples over 10s per backend", async (t) => {
  if (!stackUp) {
    t.skip(
      `editor-serve-all stack on port ${EDITOR_PORT} not running — ` +
        "see test.before warning",
    );
    return;
  }
  const { ctx, page } = await openEditor();
  try {
    for (const backend of BACKENDS) {
      await t.test(backend.name, async () => {
        await selectBackend(page, backend);
        const ready = await waitForNonZeroCanvas(page, 20000);
        assert.ok(
          ready,
          `${backend.name}: canvas never produced a non-zero frame ` +
            "after selecting the backend pill. Either the launcher " +
            "isn't running (check /tmp/isonim-launcher-*.log) or the " +
            "browser-side decode pipeline is wedged.",
        );

        const samples = [];
        const t0 = Date.now();
        let deadline = t0 + SUSTAIN_DURATION_MS;
        while (Date.now() < deadline) {
          const s = await sampleCanvas(page, false);
          samples.push(s);
          await page.waitForTimeout(SUSTAIN_SAMPLE_INTERVAL_MS);
        }

        const goodCount = samples.filter(
          (s) => s && s.total > 0 && s.nz / s.total > NON_ZERO_RATIO_MIN,
        ).length;
        const blackCount = samples.filter(
          (s) => !s || s.total === 0 || s.nz / s.total <= NON_ZERO_RATIO_MIN,
        ).length;

        process.stderr.write(
          `[sustained-render ${backend.name}] ` +
            `samples=${samples.length} good=${goodCount} black=${blackCount} ` +
            `min-good-required=${SUSTAIN_MIN_GOOD_SAMPLES}\n`,
        );

        assert.ok(
          goodCount >= SUSTAIN_MIN_GOOD_SAMPLES,
          `${backend.name}: only ${goodCount}/${samples.length} samples ` +
            `passed the non-zero-ratio gate (need >= ${SUSTAIN_MIN_GOOD_SAMPLES}). ` +
            "The launcher is either dropping frames, the bridge is " +
            "detaching mid-stream, or the canvas is going blank " +
            "(regression of the ERV-M2 snapshot-stretch fallback).",
        );

        // Verify the editor-server.mjs host is still listening at the
        // end — proxy death implies launcher subtree death.
        const pids = listenerPidsOnPort(EDITOR_PORT);
        assert.ok(
          pids.length > 0,
          `${backend.name}: editor-server.mjs is no longer listening ` +
            `on port ${EDITOR_PORT} at end of sustained run — the ` +
            "host process or its launcher subtree died.",
        );
      });
    }
  } finally {
    await ctx.close();
  }
});

// ----------------------------------------------------------------------
// Test 2: resize storm — no sustained black after viewport pill spam.
// ----------------------------------------------------------------------

test("resize storm — no sustained black canvas after rapid viewport changes", async (t) => {
  if (!stackUp) {
    t.skip(
      `editor-serve-all stack on port ${EDITOR_PORT} not running — ` +
        "see test.before warning",
    );
    return;
  }
  const { ctx, page } = await openEditor();
  try {
    // Drive the storm on GPUI — it exercises the deepest snapshot-
    // stretch path because gpui_render_try_take is the encoder most
    // sensitive to viewport changes mid-frame.
    const gpui = BACKENDS.find((b) => b.name === "gpui");
    assert.ok(gpui, "GPUI backend must be present in the live stack");
    await selectBackend(page, gpui);
    const ready = await waitForNonZeroCanvas(page, 20000);
    assert.ok(ready, "GPUI: canvas never became renderable before storm");

    const storm = ["Laptop", "Phone", "Desktop", "Phone", "Laptop", "Wide"];
    const stormSamples = [];

    // Drive the pill clicks while sampling concurrently. We do this
    // sequentially-ish: between clicks we drain a few samples so the
    // sample stream includes the in-flight resize transition (the
    // ERV-M2 fix's main beneficiary).
    for (const label of storm) {
      const clicked = await pickViewportPill(page, label);
      if (!clicked) {
        process.stderr.write(
          `[resize-storm] viewport "${label}" not available in chrome ` +
            "bar — skipping that click (the storm is intentionally " +
            "tolerant of pinned-set differences).\n",
        );
      }
      const clickT0 = Date.now();
      while (Date.now() - clickT0 < RESIZE_STORM_INTER_CLICK_MS) {
        const s = await sampleCanvas(page, false);
        stormSamples.push(s);
        await page.waitForTimeout(RESIZE_STORM_SAMPLE_INTERVAL_MS);
      }
    }

    // Settle window.
    await page.waitForTimeout(RESIZE_STORM_SETTLE_MS);

    // Post-storm samples — must ALL be good.
    const postSamples = [];
    for (let i = 0; i < RESIZE_STORM_POST_SAMPLES; i++) {
      const s = await sampleCanvas(page, false);
      postSamples.push(s);
      await page.waitForTimeout(RESIZE_STORM_SAMPLE_INTERVAL_MS);
    }

    const isBlack = (s) =>
      !s || s.total === 0 || s.nz / s.total <= NON_ZERO_RATIO_MIN;

    // Find the longest run of consecutive black samples in the storm
    // window. Up to 3 in a row is acceptable (one or two frames during
    // the resize transition is the ERV-M2 snapshot-stretch ceiling);
    // more is a regression.
    let maxRun = 0;
    let curRun = 0;
    for (const s of stormSamples) {
      if (isBlack(s)) {
        curRun++;
        if (curRun > maxRun) maxRun = curRun;
      } else {
        curRun = 0;
      }
    }

    const postGood = postSamples.filter((s) => !isBlack(s)).length;

    process.stderr.write(
      `[resize-storm] storm-samples=${stormSamples.length} ` +
        `max-consec-black=${maxRun} ` +
        `post-good=${postGood}/${postSamples.length}\n`,
    );

    assert.ok(
      maxRun <= RESIZE_STORM_MAX_CONSEC_BLACK,
      `resize storm produced ${maxRun} consecutive black samples ` +
        `(>${RESIZE_STORM_MAX_CONSEC_BLACK} = regression). The ERV-M2 ` +
        "snapshot-stretch fallback is supposed to keep the canvas " +
        "non-zero through resize transitions; this run shows the " +
        "bridge dropped paint for more than 3 consecutive sample " +
        "ticks (>150ms).",
    );

    assert.equal(
      postGood,
      postSamples.length,
      `post-storm settle: ${postGood}/${postSamples.length} samples ` +
        "good; expected all good. The canvas got stuck on a black " +
        "frame after the storm — regression of the ERV-M2 " +
        "``pendingResizeNeedsFullFrame`` guard.",
    );
  } finally {
    await ctx.close();
  }
});

// ----------------------------------------------------------------------
// Test 3: backend switch — prior backend's pixels go away within ~1s.
// ----------------------------------------------------------------------

test("backend switch — no sustained stale frame from prior backend", async (t) => {
  if (!stackUp) {
    t.skip(
      `editor-serve-all stack on port ${EDITOR_PORT} not running — ` +
        "see test.before warning",
    );
    return;
  }
  if (BACKENDS.length < 2) {
    t.skip("need at least 2 backends in the live stack for this test");
    return;
  }
  const { ctx, page } = await openEditor();
  try {
    // Walk adjacent pairs in the live backend matrix: (gpui→freya),
    // (freya→cocoa) on macOS, or (gpui→freya) only on Linux.
    for (let i = 0; i + 1 < BACKENDS.length; i++) {
      const fromB = BACKENDS[i];
      const toB = BACKENDS[i + 1];
      await t.test(`${fromB.name} → ${toB.name}`, async () => {
        // Anchor on the "from" backend and wait for a stable baseline.
        await selectBackend(page, fromB);
        const ready = await waitForNonZeroCanvas(page, 20000);
        assert.ok(
          ready,
          `${fromB.name}: never produced a baseline frame for the ` +
            "switch test.",
        );
        // Give the canvas a few hundred ms to settle so the baseline
        // grid reflects a steady-state real frame, not a still-
        // animating one.
        await page.waitForTimeout(400);

        const baseline = await sampleCanvas(page, true);
        assert.ok(
          baseline && baseline.gridB64,
          `${fromB.name}: could not capture baseline grid`,
        );

        // Switch.
        await selectBackend(page, toB);

        // Sample until the grid diverges enough OR we hit the deadline.
        const switchT0 = Date.now();
        let bestChanged = 0;
        let bestTotal = SWITCH_BASELINE_GRID * SWITCH_BASELINE_GRID;
        let satisfiedAtMs = null;
        while (Date.now() - switchT0 < SWITCH_DEADLINE_MS) {
          await page.waitForTimeout(SWITCH_SAMPLE_INTERVAL_MS);
          const cur = await sampleCanvas(page, true);
          if (!cur || !cur.gridB64) continue;
          let cmp;
          try {
            cmp = compareGrids(baseline.gridB64, cur.gridB64);
          } catch (_) {
            // Canvas dims changed between baseline + now — that itself
            // is evidence the switch happened, count as 100% changed.
            cmp = {
              changedCells: SWITCH_BASELINE_GRID * SWITCH_BASELINE_GRID,
              totalCells: SWITCH_BASELINE_GRID * SWITCH_BASELINE_GRID,
            };
          }
          if (cmp.changedCells > bestChanged) {
            bestChanged = cmp.changedCells;
            bestTotal = cmp.totalCells;
          }
          if (
            cmp.changedCells / cmp.totalCells >=
            SWITCH_CHANGED_CELL_FRACTION_MIN
          ) {
            satisfiedAtMs = Date.now() - switchT0;
            break;
          }
        }

        process.stderr.write(
          `[backend-switch] ${fromB.name}→${toB.name} ` +
            `bestChanged=${bestChanged}/${bestTotal} ` +
            `satisfiedAt=${satisfiedAtMs}ms ` +
            `deadline=${SWITCH_DEADLINE_MS}ms\n`,
        );

        assert.ok(
          satisfiedAtMs !== null,
          `${fromB.name}→${toB.name}: within ${SWITCH_DEADLINE_MS}ms ` +
            `of the switch, only ${bestChanged}/${bestTotal} grid ` +
            `cells changed (need >= ${Math.ceil(
              bestTotal * SWITCH_CHANGED_CELL_FRACTION_MIN,
            )}). The canvas is still showing the prior backend's ` +
            "pixels — regression of the ERV-M3 stale-frame guard or " +
            "canvas_mount.nim's bridge-detach on backend switch.",
        );
      });
    }
  } finally {
    await ctx.close();
  }
});
