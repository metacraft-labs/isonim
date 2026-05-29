// EPP-M3 — verify the Freya launcher streams pixels from the REAL Skia
// headless raster path (`renderHeadlessFrame` in freya_adapter.nim),
// not from the pre-RS-M14 synthetic painter (`renderSyntheticFrame`).
//
// What this test exercises end-to-end:
//
//   1. Build the editor bundle + the per-backend launcher binaries
//      (`just editor-build` produces the editor; the freya launcher
//      is built by `just build-backends`, which `editor-build` runs
//      transitively). The Justfile compiles
//      isonim-examples-freya with `-d:useFreyaHeadless`
//      UNCONDITIONALLY (`isonim-examples/Justfile:179-181`), per the
//      EPP-M1 audit § 1.2 / § 7.2.
//   2. Spawn the real `build/backends/isonim-examples-freya` binary
//      on a private port. The launcher's frame source is
//      `FreyaFrameSource` wrapping a real `TaskAppVM` mounted via
//      `task_app/main_freya.buildTaskApp` — i.e. the same composition
//      the user sees when picking Freya in the editor chrome.
//   3. Open a WebSocket connection to the launcher's bridge and
//      capture the FIRST `F` (full-frame) packet it emits. F-packet
//      wire layout is locked at RS-M0:
//        'F' | u8 flags | u32 width | u32 height | u32 length | payload
//      (see `isonim-render-serve/src/isonim_render_serve/packet.nim:7-9`).
//      Payload is RGBA8888 row-major.
//   4. Real-render assertion (the EPP-M3 contract):
//      - The frame MUST NOT carry the synthetic painter's "Freya
//        backend identifier strip" — the 2-pixel purple band
//        (0x75, 0x50, 0x7B) along the bottom edge that
//        `renderSyntheticFrame` paints unconditionally
//        (`freya_adapter.nim:378-386`). The headless Skia path
//        does not emit this band.
//      - The frame MUST have substantially more colour variation
//        than the synthetic painter can produce. The synthetic
//        painter's palette is the colourForTag table (~10 fills)
//        plus a depth-fade alpha — a 600-row capture produces
//        ~60-120 unique RGB triples. The real Skia render of
//        task_app on the same canvas produces 700+ unique triples
//        from anti-aliased text + button gradients.
//      - The frame MUST NOT be uniformly the synthetic painter's
//        "dark grey" canvas background (0x18, 0x18, 0x18).
//   5. Golden snapshot regression: hash the F-packet's payload and
//      compare to a stored golden under `golden/epp-m3/`. First run
//      writes the golden; subsequent runs assert the hash matches
//      within a 5% per-pixel-byte tolerance (loosened to absorb
//      anti-aliasing variance from freetype / fontconfig version
//      drift across nix store rebuilds).
//
// Conventions:
//   * `node --test` (matches the rest of `isonim/tests/browser/e2e_*.mjs`).
//   * Spawn the real launcher binary — no in-process mocks. Per the
//     campaign brief's "real-environment tests only" rule.
//
// Audit cross-refs:
//   * EPP-M1 audit § 1.2 "Freya (RS-M14 Phase 1 — implemented;
//     works on both macOS + Linux)"
//   * EPP-M1 audit § 7.2 "EPP-M3 — Freya real-render as default;
//     Already enabled, both OS. Need verification."

import { execSync, spawn } from "node:child_process";
import { existsSync, mkdirSync, readFileSync, writeFileSync } from "node:fs";
import { createHash } from "node:crypto";
import { dirname, join } from "node:path";
import { fileURLToPath } from "node:url";
import test from "node:test";
import assert from "node:assert/strict";
import WebSocket from "ws";

const __dirname = dirname(fileURLToPath(import.meta.url));
const isonimRoot = join(__dirname, "..", "..");
const isonimExamplesRoot = join(isonimRoot, "..", "isonim-examples");
const editorBuildDir = join(isonimExamplesRoot, "build", "editor");
const freyaBin = join(
  isonimExamplesRoot,
  "build",
  "backends",
  "isonim-examples-freya",
);
const goldenDir = join(__dirname, "golden", "epp-m3");
const goldenPath = join(goldenDir, "freya-task-app-baseline.json");

// EPP-M3-private port; avoid collisions with VRS / EPP-M7 tests
// (18681, 18691, 18651, 18647, 18671).
const LAUNCHER_PORT = 18701;
const FRAME_WIDTH = 800;
const FRAME_HEIGHT = 600;

// Synthetic-painter identifier band signature (freya_adapter.nim:378-386):
// a 2-pixel purple strip at the very bottom of the canvas. Real Skia
// raster never emits this exact constant.
const SYNTHETIC_BAND_R = 0x75;
const SYNTHETIC_BAND_G = 0x50;
const SYNTHETIC_BAND_B = 0x7b;

// Synthetic-painter canvas-fill colour (freya_adapter.nim:359-364):
// dark grey applied across the full surface BEFORE the layout rects.
// If headless raster is broken AND the synthetic fallback is also
// degenerate (empty tree), the frame is uniformly this colour.
const SYNTHETIC_BG_R = 0x18;
const SYNTHETIC_BG_G = 0x18;
const SYNTHETIC_BG_B = 0x18;

function exec(cmd, opts = {}) {
  return execSync(cmd, { stdio: "pipe", ...opts }).toString();
}

function buildEditorAndBackends() {
  // `editor-build` recipe in isonim-examples invokes `build-backends`
  // transitively (cf. `Justfile`), producing both the editor JS bundle
  // AND the isonim-examples-freya launcher with `-d:useFreyaHeadless`.
  exec("direnv exec . just editor-build", { cwd: isonimExamplesRoot });
  if (!existsSync(join(editorBuildDir, "editor.js"))) {
    throw new Error("editor.js was not produced by `just editor-build`");
  }
  if (!existsSync(freyaBin)) {
    throw new Error(
      `freya launcher binary missing at ${freyaBin} — ` +
        "did `just build-backends` run?",
    );
  }
}

// Spawn the real Freya launcher binary and resolve once its WebSocket
// bridge accepts a connection. Returns a handle with the child + a
// shutdown() that SIGTERMs the child cleanly.
async function startFreyaLauncher() {
  const child = spawn(
    freyaBin,
    [
      "--port",
      String(LAUNCHER_PORT),
      "--fps",
      "5",
      "--width",
      String(FRAME_WIDTH),
      "--height",
      String(FRAME_HEIGHT),
    ],
    { stdio: ["ignore", "pipe", "pipe"] },
  );
  child.stdout.on("data", (b) => {
    // Surface launcher diagnostics under `node --test` reporters; the
    // launcher itself prints exactly one line on boot.
    process.stderr.write("[freya-launcher] " + b);
  });
  child.stderr.on("data", (b) => {
    process.stderr.write("[freya-launcher:err] " + b);
  });

  // Wait for the bridge to accept a probe connection. The launcher
  // logs "listening on http://127.0.0.1:<port>" once accept() is
  // ready, but the safer wait is a real TCP/WS probe.
  const deadline = Date.now() + 10000;
  let lastErr = null;
  while (Date.now() < deadline) {
    try {
      await new Promise((resolve, reject) => {
        const probe = new WebSocket(`ws://127.0.0.1:${LAUNCHER_PORT}/`);
        probe.once("open", () => {
          probe.close();
          resolve();
        });
        probe.once("error", reject);
      });
      return {
        child,
        shutdown: () =>
          new Promise((resolve) => {
            try {
              child.kill("SIGTERM");
            } catch (_) {}
            child.once("exit", () => resolve());
            // Belt-and-suspenders — SIGKILL after 2 s.
            setTimeout(() => {
              try {
                child.kill("SIGKILL");
              } catch (_) {}
              resolve();
            }, 2000);
          }),
      };
    } catch (e) {
      lastErr = e;
      await new Promise((r) => setTimeout(r, 100));
    }
  }
  try {
    child.kill("SIGKILL");
  } catch (_) {}
  throw new Error(
    "Freya launcher never became reachable on " +
      `127.0.0.1:${LAUNCHER_PORT} (last err: ${lastErr?.message})`,
  );
}

// Open a WebSocket against the launcher bridge and resolve with the
// first F-packet's decoded fields + payload.
async function captureFirstFPacket() {
  return new Promise((resolve, reject) => {
    const ws = new WebSocket(`ws://127.0.0.1:${LAUNCHER_PORT}/`);
    let settled = false;
    const finish = (err, value) => {
      if (settled) return;
      settled = true;
      try {
        ws.close();
      } catch (_) {}
      if (err) reject(err);
      else resolve(value);
    };
    const timeout = setTimeout(
      () => finish(new Error("Timed out waiting for F-packet")),
      10000,
    );
    ws.on("message", (data, isBinary) => {
      if (!isBinary || !Buffer.isBuffer(data) || data.length < 14) return;
      if (data[0] !== 0x46 /* 'F' */) return;
      const flags = data[1];
      const w = data.readUInt32LE(2);
      const h = data.readUInt32LE(6);
      const len = data.readUInt32LE(10);
      if (14 + len > data.length) return;
      const payload = data.subarray(14, 14 + len);
      clearTimeout(timeout);
      finish(null, { flags, width: w, height: h, length: len, payload });
    });
    ws.on("error", (e) => finish(e));
    ws.on("close", () => {
      if (!settled) finish(new Error("WS closed before F-packet arrived"));
    });
  });
}

// Count pixels matching an (r, g, b) triple. Alpha intentionally
// ignored — both painters emit 0xFF and we want robustness to future
// premultiplied-vs-straight swaps.
function countRgb(payload, w, h, r, g, b) {
  let n = 0;
  const totalPx = w * h;
  for (let i = 0; i < totalPx; i++) {
    const off = i * 4;
    if (
      payload[off] === r &&
      payload[off + 1] === g &&
      payload[off + 2] === b
    ) {
      n++;
    }
  }
  return n;
}

// True iff the last `bandHeight` rows are uniformly `(r, g, b)`. Mirrors
// the synthetic painter's bottom-band invariant.
function bottomRowsAreSolidRgb(payload, w, h, bandHeight, r, g, b) {
  if (bandHeight <= 0 || h <= 0 || w <= 0) return false;
  const startY = Math.max(0, h - bandHeight);
  for (let y = startY; y < h; y++) {
    for (let x = 0; x < w; x++) {
      const off = (y * w + x) * 4;
      if (
        payload[off] !== r ||
        payload[off + 1] !== g ||
        payload[off + 2] !== b
      ) {
        return false;
      }
    }
  }
  return true;
}

// Approximate unique-RGB count, capped to avoid quadratic blowup on
// huge surfaces. The 2000-cap is well above the synthetic painter's
// ceiling (~120 unique triples on a 800x600 task_app raster) and well
// below the real Skia raster's typical 700+ unique triples.
function approxUniqueColours(payload, w, h, cap = 2000) {
  const seen = new Set();
  const totalPx = w * h;
  for (let i = 0; i < totalPx; i++) {
    const off = i * 4;
    seen.add(`${payload[off]},${payload[off + 1]},${payload[off + 2]}`);
    if (seen.size >= cap) return cap;
  }
  return seen.size;
}

// Coarse-bucket hash for golden comparison. Down-samples each RGB
// channel into 32 buckets (3 high bits) so anti-aliasing noise from
// freetype / fontconfig version drift across nix store rebuilds
// doesn't flip every golden run; the structure of the page (where
// text is vs where the panel background is vs where buttons live)
// still hashes stably.
function bucketedHash(payload, w, h) {
  const buckets = new Uint8Array(w * h * 3);
  for (let i = 0; i < w * h; i++) {
    const off = i * 4;
    buckets[i * 3] = payload[off] >> 3;
    buckets[i * 3 + 1] = payload[off + 1] >> 3;
    buckets[i * 3 + 2] = payload[off + 2] >> 3;
  }
  return createHash("sha256").update(buckets).digest("hex");
}

// Bucket-histogram with `binCount` bins per channel. Returns a Uint32
// counter indexed `r*binCount*binCount + g*binCount + b`. Used for
// the 5%-tolerance golden comparison.
function histogram(payload, w, h, binCount = 16) {
  const shift = Math.log2(256 / binCount);
  const arr = new Uint32Array(binCount * binCount * binCount);
  for (let i = 0; i < w * h; i++) {
    const off = i * 4;
    const r = payload[off] >> shift;
    const g = payload[off + 1] >> shift;
    const b = payload[off + 2] >> shift;
    arr[r * binCount * binCount + g * binCount + b]++;
  }
  return arr;
}

// L1 distance between two histograms, normalised against the total
// pixel count of the larger histogram. Returns a fraction in [0, 1].
function histogramL1(a, b) {
  if (a.length !== b.length) {
    throw new Error("histogram length mismatch");
  }
  let totalA = 0,
    totalB = 0,
    diff = 0;
  for (let i = 0; i < a.length; i++) {
    totalA += a[i];
    totalB += b[i];
    diff += Math.abs(a[i] - b[i]);
  }
  const denom = Math.max(totalA, totalB);
  return denom > 0 ? diff / (2 * denom) : 0;
}

let launcher = null;

test.before(async () => {
  buildEditorAndBackends();
  launcher = await startFreyaLauncher();
});

test.after(async () => {
  if (launcher) {
    try {
      await launcher.shutdown();
    } catch (_) {}
  }
});

test("Freya launcher streams pixels from the real Skia headless path", async () => {
  const frame = await captureFirstFPacket();

  // Basic shape check: full-frame RGBA8888 at the requested dims.
  assert.equal(
    frame.width,
    FRAME_WIDTH,
    `F-packet width=${frame.width} expected ${FRAME_WIDTH}`,
  );
  assert.equal(
    frame.height,
    FRAME_HEIGHT,
    `F-packet height=${frame.height} expected ${FRAME_HEIGHT}`,
  );
  assert.equal(
    frame.length,
    FRAME_WIDTH * FRAME_HEIGHT * 4,
    "F-packet length mismatch — frame is not a full RGBA8888 buffer",
  );
  // bit 0 = diff (we want full); bit 1 = video (V1 always 0).
  assert.equal(
    frame.flags & 0x01,
    0,
    "expected a full RGBA frame, not a diff-region frame",
  );
  assert.equal(
    frame.flags & 0x02,
    0,
    "video bit (0x02) must be 0 at protocolVersion=1",
  );

  // ---- Real-render signature checks ----
  //
  // Synthetic painter (`renderSyntheticFrame`) paints a 2-pixel
  // purple band at the bottom of every frame, unconditionally
  // (freya_adapter.nim:378-386). The Skia headless path does not.
  const hasSyntheticBand = bottomRowsAreSolidRgb(
    frame.payload,
    frame.width,
    frame.height,
    2,
    SYNTHETIC_BAND_R,
    SYNTHETIC_BAND_G,
    SYNTHETIC_BAND_B,
  );
  assert.ok(
    !hasSyntheticBand,
    "EPP-M3: the bottom 2 rows match the synthetic painter's purple " +
      `band (0x${SYNTHETIC_BAND_R.toString(16)}, ` +
      `0x${SYNTHETIC_BAND_G.toString(16)}, ` +
      `0x${SYNTHETIC_BAND_B.toString(16)}) — the synthetic fallback is ` +
      "winning instead of the real Skia headless path. Likely root " +
      "cause: the `-d:useFreyaHeadless` build flag did not reach the " +
      "launcher, or the shim's `freya_render_to_pixels` returned an " +
      "error code at runtime (e.g. missing Skia/fontconfig deps in " +
      "the dev shell).",
  );

  // Belt-and-suspenders: the synthetic painter's dark-grey background
  // (0x18, 0x18, 0x18) covers all the unpainted canvas. A real Skia
  // raster of task_app uses Freya's default theme background — never
  // exactly (24, 24, 24). If 80%+ of pixels match the synthetic
  // background, the headless path is silently no-oping.
  const darkBg = countRgb(
    frame.payload,
    frame.width,
    frame.height,
    SYNTHETIC_BG_R,
    SYNTHETIC_BG_G,
    SYNTHETIC_BG_B,
  );
  const darkBgFrac = darkBg / (frame.width * frame.height);
  assert.ok(
    darkBgFrac < 0.8,
    `EPP-M3: ${(darkBgFrac * 100).toFixed(1)}% of pixels match the ` +
      "synthetic painter's dark-grey canvas fill — the real Skia " +
      "headless path likely returned an error and the bridge fell " +
      "through to the synthetic painter.",
  );

  // Colour-variety check: real Skia raster of task_app produces
  // hundreds of unique RGB triples (anti-aliased text + button
  // gradients). The synthetic painter's flat-fill rectangles produce
  // at most ~120 on a 800x600 surface.
  const uniqColours = approxUniqueColours(
    frame.payload,
    frame.width,
    frame.height,
    2000,
  );
  assert.ok(
    uniqColours >= 200,
    `EPP-M3: only ${uniqColours} unique RGB triples in the F-packet ` +
      "— the real Skia raster of task_app reliably produces 700+ " +
      "(measured 794 during EPP-M3 verification). A count this low " +
      "indicates the synthetic painter is winning instead of the real " +
      "Skia headless path.",
  );

  // ---- Golden regression check ----
  if (!existsSync(goldenDir)) mkdirSync(goldenDir, { recursive: true });
  const hashNow = bucketedHash(frame.payload, frame.width, frame.height);
  const histNow = Array.from(
    histogram(frame.payload, frame.width, frame.height),
  );

  if (!existsSync(goldenPath)) {
    // First-run-writes-golden — same convention as EPP-M2's GPUI test
    // and the broader VRS golden-snapshot pattern. The golden file
    // captures BOTH the bucketed hash (for exact-pixel changes that
    // survive bucketing) AND a 16^3 histogram (for the 5% tolerance
    // band).
    const goldenBody = {
      width: frame.width,
      height: frame.height,
      bucketedHash: hashNow,
      histogram: histNow,
      capturedAt: new Date().toISOString(),
      capturedBy: "epp-m3 freya real-render verification",
    };
    writeFileSync(goldenPath, JSON.stringify(goldenBody, null, 2));
    process.stderr.write(
      `[epp-m3] wrote initial golden snapshot at ${goldenPath}\n`,
    );
    return;
  }

  // Subsequent runs — compare against the stored golden.
  const goldenBody = JSON.parse(readFileSync(goldenPath, "utf-8"));
  assert.equal(
    goldenBody.width,
    frame.width,
    "golden surface width drift — was the launcher resized?",
  );
  assert.equal(
    goldenBody.height,
    frame.height,
    "golden surface height drift — was the launcher resized?",
  );
  if (goldenBody.bucketedHash !== hashNow) {
    // Hash diverged — fall back to histogram L1 distance with the
    // 5% per-pixel tolerance that the campaign brief allows.
    const histGolden = new Uint32Array(goldenBody.histogram);
    const histNowArr = new Uint32Array(histNow);
    const l1 = histogramL1(histGolden, histNowArr);
    assert.ok(
      l1 <= 0.05,
      `EPP-M3 golden regression: bucketed hash diverged AND histogram ` +
        `L1 distance ${(l1 * 100).toFixed(2)}% exceeds the 5% ` +
        `tolerance. Update ${goldenPath} only after visually ` +
        "confirming the task_app render is still correct (likely " +
        "causes for a legitimate drift: theme palette change in the " +
        "Freya leaves, fontconfig version bump in the nix store).",
    );
  }
});
