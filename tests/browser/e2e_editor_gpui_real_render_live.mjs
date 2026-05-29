// EPP-M2 — verify the GPUI launcher's first F-packet was produced by
// the *real* headless GPUI render path (gpui_render_to_pixels via
// Zed's HeadlessAppContext + Window::render_to_image), not the
// synthetic vertical-stack painter at
// `gpui_adapter.nim:walkLayout` / `renderSyntheticFrame`.
//
// What this test exercises end-to-end:
//
//   1. Build the editor bundle + per-backend launchers (`just
//      editor-build` + `just build-backends` in
//      ~/metacraft/isonim-examples). Builds are skipped if the binaries
//      already exist (re-build with `just build-backends` to refresh).
//   2. Spawn the real GPUI launcher binary
//      (`build/backends/isonim-examples-gpui`) on an ephemeral port,
//      pointed at task_app.
//   3. Open a real WebSocket to the launcher's bridge port and capture
//      the first F-packet of full-frame RGBA pixels.
//   4. Assert the pixels carry **no synthetic-painter signature**:
//      - no teal bottom identifier band (`#06989A` at the last row,
//        applied by `renderSyntheticFrame` at
//        `gpui_adapter.nim:321-335`),
//      - the dark-grey canvas fill (`#181818`) does NOT dominate
//        (synthetic-painter background; see `gpui_adapter.nim:289-294`),
//      - a meaningful unique-RGB-triplet count proving the real GPUI
//        compositor produced anti-aliased, gradient-rich pixels.
//   5. Compare the captured RGBA buffer against a golden snapshot at
//      `tests/browser/golden/epp-m2/gpui-task-app-800x600.bin`. First
//      run writes the golden; later runs assert per-pixel ΔE ≤ 5 %
//      averaged over the frame (per the milestone spec's tolerance
//      knob — GPU driver variance and Zed's deferred-draw pump are
//      both within that envelope).
//
// Why this is the right shape:
//   * EPP-M1 audit § 1.1 confirmed the Justfile already builds GPUI
//     with `-d:useGpuiHeadless` on Darwin (lines 180-188). Yet a feeling
//     of "synthetic-painter behaviour" persisted. This test PINS the
//     runtime path: a passing assertion on the no-synthetic-signature
//     check is on-disk proof that the runtime path is the real GPUI
//     pipeline.
//   * The golden snapshot is a regression net so future changes that
//     accidentally fall back to the synthetic painter (e.g. dropping
//     the `-d:useGpuiHeadless` define, a Zed revision bump that breaks
//     headless rendering) will trigger a CI failure.
//   * Real-environment-only — per the campaign brief no in-process
//     mocks: we spawn the actual launcher subprocess. The launcher
//     binary on disk IS the producer.
//
// Convention: `node --test` (matches the rest of
// `isonim/tests/browser/e2e_*.mjs`).

import { execSync, spawn } from "node:child_process";
import { existsSync, mkdirSync, readFileSync, writeFileSync } from "node:fs";
import { dirname, join } from "node:path";
import { fileURLToPath } from "node:url";
import test from "node:test";
import assert from "node:assert/strict";
import WebSocket from "ws";

const __dirname = dirname(fileURLToPath(import.meta.url));
const isonimRoot = join(__dirname, "..", "..");
const isonimExamplesRoot = join(isonimRoot, "..", "isonim-examples");
const isonimGpuiRoot = join(isonimRoot, "..", "isonim-gpui");
const launcherBin = join(
  isonimExamplesRoot,
  "build",
  "backends",
  "isonim-examples-gpui",
);
const goldenDir = join(__dirname, "golden", "epp-m2");
const goldenPath = join(goldenDir, "gpui-task-app-800x600.bin");
const goldenMetaPath = join(goldenDir, "gpui-task-app-800x600.meta.json");

const FRAME_WIDTH = 800;
const FRAME_HEIGHT = 600;
// EPP-M2-private port; avoid collision with EPP-M3 (18701), EPP-M7
// (18691), VRS-M2 (18681), and the other live e2e suites.
const BRIDGE_PORT = 18703;

// Per-pixel ΔE tolerance in [0, 1]: absolute mean diff per channel,
// scaled by 255. 0.05 ≈ 5 % per-channel-mean — wide enough to absorb
// GPU driver variance + Zed's two-tick render_until_parked pump
// jitter, tight enough to flag a synthetic-painter regression which
// would diverge by 30 %+ on average.
const DELTA_E_TOLERANCE_FRAC = 0.05;

function exec(cmd, opts = {}) {
  return execSync(cmd, { stdio: "pipe", ...opts }).toString();
}

function ensureLauncherBuilt() {
  if (existsSync(launcherBin)) return;
  // Build via the dev shell so the right Nim + nimble paths resolve.
  // Same convention as the VRS-M2 / EPP-M7 tests' `buildEditor()`.
  exec("direnv exec . just build-backends", {
    cwd: isonimExamplesRoot,
  });
  if (!existsSync(launcherBin)) {
    throw new Error(
      `expected ${launcherBin} after \`just build-backends\` but it was not produced`,
    );
  }
}

async function waitForPort(port, timeoutMs = 6000) {
  const t0 = Date.now();
  while (Date.now() - t0 < timeoutMs) {
    try {
      await new Promise((resolve, reject) => {
        const probe = new WebSocket(`ws://127.0.0.1:${port}/`);
        probe.on("open", () => {
          probe.close();
          resolve();
        });
        probe.on("error", reject);
      });
      return true;
    } catch (_) {
      await new Promise((r) => setTimeout(r, 50));
    }
  }
  return false;
}

function spawnLauncher(port) {
  // The GPUI shim is a Rust cdylib loaded via Nim's `dynlib`. The
  // dylib lives under `isonim-gpui/rust/target/release/`. Point
  // DYLD_LIBRARY_PATH at it so the launcher resolves the symbol at
  // run time even without a copy beside the binary.
  const dylibDir = join(isonimGpuiRoot, "rust", "target", "release");
  const env = {
    ...process.env,
    DYLD_LIBRARY_PATH: dylibDir,
    DYLD_FALLBACK_LIBRARY_PATH: dylibDir,
  };
  const proc = spawn(
    launcherBin,
    [
      "--port",
      String(port),
      "--demo",
      "task",
      "--width",
      String(FRAME_WIDTH),
      "--height",
      String(FRAME_HEIGHT),
      "--fps",
      "12",
    ],
    { stdio: ["ignore", "pipe", "pipe"], env, cwd: isonimExamplesRoot },
  );
  // Surface launcher output on the test's stderr so a failure trace
  // includes whatever the launcher printed (dylib lookup failures,
  // bridge errors, ...).
  proc.stdout.on("data", (b) =>
    process.stderr.write(`[gpui launcher] ${b.toString()}`),
  );
  proc.stderr.on("data", (b) =>
    process.stderr.write(`[gpui launcher] ${b.toString()}`),
  );
  return proc;
}

async function captureFirstFrame(port, timeoutMs = 10000) {
  return new Promise((resolve, reject) => {
    const ws = new WebSocket(`ws://127.0.0.1:${port}/`);
    let captured = null;
    const timer = setTimeout(() => {
      try {
        ws.close();
      } catch (_) {}
      reject(new Error(`no F-packet captured within ${timeoutMs} ms`));
    }, timeoutMs);

    ws.on("message", (data) => {
      if (!Buffer.isBuffer(data)) return;
      if (data.length < 14) return;
      const kind = String.fromCharCode(data[0]);
      if (kind !== "F") return;
      const flags = data.readUInt8(1);
      const width = data.readUInt32LE(2);
      const height = data.readUInt32LE(6);
      const length = data.readUInt32LE(10);
      if (5 + 9 + length > data.length) return;
      const pixels = data.subarray(14, 14 + length);
      captured = { flags, width, height, length, pixels };
      clearTimeout(timer);
      try {
        ws.close();
      } catch (_) {}
      resolve(captured);
    });

    ws.on("error", (e) => {
      clearTimeout(timer);
      reject(e);
    });
  });
}

// --- Synthetic-painter detection -----------------------------------------
//
// The synthetic painter at `gpui_adapter.nim:renderSyntheticFrame` has
// three signatures:
//   1. A teal (#06989A) identifier band along the BOTTOM 1-2 rows.
//   2. An opaque dark-grey (#181818) canvas fill where the tree did
//      not paint over it.
//   3. Pixel quantization to a handful of tag-derived colours —
//      typically < 50 unique RGB triplets across an 800×600 frame.
//
// The real headless render path produces anti-aliased text, gradients,
// and a brand background with hundreds-to-thousands of unique RGBs.

function tealBottomBandRatio(pixels, w, h) {
  const stride = w * 4;
  const lastRow = pixels.subarray((h - 1) * stride, h * stride);
  let teal = 0;
  for (let i = 0; i < w; i++) {
    const r = lastRow[i * 4];
    const g = lastRow[i * 4 + 1];
    const b = lastRow[i * 4 + 2];
    if (r === 0x06 && g === 0x98 && b === 0x9a) teal++;
  }
  return teal / w;
}

function darkGreyFillRatio(pixels) {
  let n = 0;
  const total = pixels.length / 4;
  for (let i = 0; i < pixels.length; i += 4) {
    if (
      pixels[i] === 0x18 &&
      pixels[i + 1] === 0x18 &&
      pixels[i + 2] === 0x18
    ) {
      n++;
    }
  }
  return n / total;
}

function sampleUniqueRgbCount(pixels, sampleStride = 64) {
  const set = new Set();
  for (let i = 0; i < pixels.length; i += sampleStride) {
    set.add(`${pixels[i]},${pixels[i + 1]},${pixels[i + 2]}`);
    if (set.size > 5000) break;
  }
  return set.size;
}

function meanDeltaE(a, b) {
  if (a.length !== b.length) {
    throw new Error(`pixel length mismatch: ${a.length} vs ${b.length}`);
  }
  let sum = 0;
  for (let i = 0; i < a.length; i += 4) {
    sum +=
      Math.abs(a[i] - b[i]) +
      Math.abs(a[i + 1] - b[i + 1]) +
      Math.abs(a[i + 2] - b[i + 2]);
  }
  // Per-channel mean, scaled to [0, 1].
  return sum / (a.length / 4) / 3 / 255;
}

// -------------------------------------------------------------------------

test("EPP-M2: GPUI launcher's first frame comes from the real headless render path", async () => {
  // macOS-only — the EPP-M1 audit (§ 1.1) documents the pinned Zed
  // revision's `current_headless_renderer()` returns `None` on Linux,
  // so Linux falls back to the synthetic painter by design. The
  // EPP-M2 milestone explicitly defers the Linux story to a follow-up
  // (per the milestones spec § 7.1, "Linux note").
  if (process.platform !== "darwin") {
    console.log(
      "[EPP-M2] skipping non-Darwin host (headless GPUI is Darwin-only)",
    );
    return;
  }

  ensureLauncherBuilt();
  const proc = spawnLauncher(BRIDGE_PORT);
  try {
    const up = await waitForPort(BRIDGE_PORT, 8000);
    assert.ok(up, `launcher did not listen on :${BRIDGE_PORT} in 8s`);
    const frame = await captureFirstFrame(BRIDGE_PORT, 10000);

    // -- Sanity on the frame envelope itself.
    assert.equal(frame.width, FRAME_WIDTH, "F-packet width must match request");
    assert.equal(
      frame.height,
      FRAME_HEIGHT,
      "F-packet height must match request",
    );
    assert.equal(
      frame.length,
      FRAME_WIDTH * FRAME_HEIGHT * 4,
      "F-packet length must equal w*h*4 for a full-frame F packet",
    );

    // -- Synthetic-painter signature rejection.
    const tealRatio = tealBottomBandRatio(
      frame.pixels,
      frame.width,
      frame.height,
    );
    const greyRatio = darkGreyFillRatio(frame.pixels);
    const uniqColours = sampleUniqueRgbCount(frame.pixels);

    // The synthetic painter writes its teal band on EVERY bottom-edge
    // pixel; the real render path produces sub-pixel colour variation
    // there. Tolerate <20 % teal coverage as noise (e.g. a brand
    // accent in the demo that happens to land in that band).
    assert.ok(
      tealRatio < 0.2,
      `EPP-M2: synthetic-painter teal band detected on bottom row ` +
        `(${(tealRatio * 100).toFixed(1)}% of pixels matched #06989A); ` +
        `the launcher fell back to the synthetic painter at ` +
        `gpui_adapter.nim:renderSyntheticFrame. Check that ` +
        `-d:useGpuiHeadless was active at compile time AND that ` +
        `libgpui_nim_shim.dylib was resolved at runtime via ` +
        `DYLD_LIBRARY_PATH.`,
    );
    assert.ok(
      greyRatio < 0.3,
      `EPP-M2: opaque dark-grey (#181818) fill covers ${(
        greyRatio * 100
      ).toFixed(1)}% of the frame; this is the synthetic ` +
        `painter's canvas pre-fill (gpui_adapter.nim:289-294). The ` +
        `real headless render path produces task_app's brand surface ` +
        `with no dark-grey saturation.`,
    );
    assert.ok(
      uniqColours >= 80,
      `EPP-M2: only ${uniqColours} unique RGB triplets sampled across ` +
        `the frame; the synthetic painter typically lands < 50 because ` +
        `it draws solid-fill rectangles. The real GPUI compositor ` +
        `produces hundreds (anti-aliased text + gradients).`,
    );

    // -- Golden snapshot regression.
    mkdirSync(goldenDir, { recursive: true });
    if (!existsSync(goldenPath)) {
      writeFileSync(goldenPath, frame.pixels);
      writeFileSync(
        goldenMetaPath,
        JSON.stringify(
          {
            note:
              "EPP-M2 golden snapshot. RGBA8888 row-major, top row first. " +
              "Captured from build/backends/isonim-examples-gpui --demo task " +
              "--width 800 --height 600. Regenerate by deleting this file + " +
              "re-running the test.",
            width: frame.width,
            height: frame.height,
            captured: new Date().toISOString(),
            telemetry: {
              tealBottomBandRatio: tealRatio,
              darkGreyFillRatio: greyRatio,
              sampledUniqueRgb: uniqColours,
            },
          },
          null,
          2,
        ),
      );
      console.log(
        `[EPP-M2] wrote golden snapshot ${goldenPath} ` +
          `(${frame.pixels.length} bytes, ${uniqColours} unique RGB)`,
      );
      return;
    }

    const golden = readFileSync(goldenPath);
    const deltaE = meanDeltaE(frame.pixels, golden);
    assert.ok(
      deltaE <= DELTA_E_TOLERANCE_FRAC,
      `EPP-M2: captured frame diverged from golden snapshot by ` +
        `${(deltaE * 100).toFixed(2)}% mean per-channel ΔE ` +
        `(tolerance ${(DELTA_E_TOLERANCE_FRAC * 100).toFixed(1)}%). ` +
        `Either the GPUI headless render path regressed, or task_app's ` +
        `visual changed intentionally — in which case delete ` +
        `${goldenPath} to re-baseline.`,
    );
    console.log(
      `[EPP-M2] golden match: mean ΔE = ${(deltaE * 100).toFixed(2)}% ` +
        `(<= ${(DELTA_E_TOLERANCE_FRAC * 100).toFixed(1)}% tolerance); ` +
        `synthetic signatures absent (teal=${(tealRatio * 100).toFixed(
          1,
        )}%, grey=${(greyRatio * 100).toFixed(1)}%, uniq=${uniqColours})`,
    );
  } finally {
    try {
      proc.kill("SIGTERM");
    } catch (_) {}
    // Give the launcher a grace period to flush before SIGKILLing.
    await new Promise((r) => setTimeout(r, 200));
    try {
      proc.kill("SIGKILL");
    } catch (_) {}
  }
});
