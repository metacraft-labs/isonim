// EPP-M8 — campaign-closing acceptance gate. For each non-Web backend
// (GPUI, Freya, Cocoa), the test walks the editor end-to-end as the
// user would:
//
//   1. Spawn the launcher with the encoder appropriate for that
//      backend (Cocoa: --encoder h264, GPUI/Freya: --encoder raw_rgba —
//      they don't have VideoToolbox available the same way).
//   2. Start an HTTP+WS proxy that serves the editor's static bundle
//      and pipes ``/bridge/<backend>`` WebSocket upgrades through to
//      the real launcher binary.
//   3. Open the editor in headless Chromium, pick the backend pill,
//      select a story (mounts the canvas), and wait for the bridge to
//      land its first frame.
//   4. Cycle through 2-3 viewport pills, capturing a frame after each
//      settles. Each switch must produce a fresh canvas paint.
//   5. Click into the rendered canvas; confirm the click registers
//      (body marker ``data-isonim-canvas-focused="true"``) AND
//      a fresh frame paints within one frame budget (33 ms at 30 FPS,
//      16 ms at 60 FPS — the launcher cap is read from the hello bag).
//   6. Type into the focused canvas; confirm a keyboard packet lands
//      at the launcher (the launcher cannot directly echo, so we
//      hook the JS shim's outbound ``WebSocket.send`` and confirm at
//      least one ``down`` packet's ``text`` field matches the typed
//      letter).
//   7. Measure median frame latency over ~100 frames using the
//      wall-clock approach the EPP-M1 audit recommends. Two distinct
//      buffers are populated via ``addInitScript``:
//      * ``window.__isonimFrameTimes`` — every F or V packet arrival
//        on the WebSocket (the inter-arrival cadence, including
//        RS-M3 heartbeat diffs that don't paint).
//      * ``window.__isonimCanvasPaintTimes`` — every ``putImageData``
//        / ``drawImage`` call against the streaming canvas (only
//        non-heartbeat F packets and decoded V VideoFrames produce
//        these).
//      Cadence assertion compares the inter-arrival times; the
//      click-response assertion uses an ROI pixel-fingerprint poll
//      (campaign brief: "the next emitted F or V packet within one
//      frame budget shows a pixel change in the clicked region").
//
// Acceptance assertions per backend:
//   * Median frame latency under 50 ms (campaign goal).
//   * Canvas displays at 1:1 device pixels:
//     ``canvas.getBoundingClientRect().{width,height} * dpr`` equals
//     ``canvas.{width, height}`` within 1 px. (EPP-M2 / VRS-M2
//     follow-up contract.)
//   * Click event produces visible response within one frame budget
//     (33 ms at 30 FPS or 16 ms at 60 FPS — picked from the launcher's
//     advertised cadence).
//   * Existing chrome-bar fuzz + active-state repros stay green —
//     covered by the sibling tests this matrix walk re-runs alongside
//     (this file doesn't re-implement them).
//
// Honest-measurement contract: the milestone brief is explicit — if any
// of these fails for any backend, surface the failing assertion plus
// the measured value. DO NOT silently widen the tolerance.
//
// Conventions:
//   * `node --test` (matches the rest of `isonim/tests/browser/e2e_*.mjs`).
//   * Spawn the real launcher binary — no in-process mocks. Per the
//     campaign brief's "real-environment tests only" rule.
//
// Skip rule: macOS-only. The cocoa launcher only builds on Darwin,
// and the GPUI real-render headless path is pinned to Darwin too
// (EPP-M2). Freya works on Linux, but the matrix is acceptance-
// gating ALL three backends as a unit, so the file gates on macOS.

import { execSync, spawn } from "node:child_process";
import { createServer } from "node:http";
import { existsSync, readFileSync } from "node:fs";
import { dirname, extname, join } from "node:path";
import { fileURLToPath } from "node:url";
import net from "node:net";
import test from "node:test";
import assert from "node:assert/strict";

const __dirname = dirname(fileURLToPath(import.meta.url));
const isonimRoot = join(__dirname, "..", "..");
const isonimExamplesRoot = join(isonimRoot, "..", "isonim-examples");
const isonimGpuiRoot = join(isonimRoot, "..", "isonim-gpui");
const editorBuildDir = join(isonimExamplesRoot, "build", "editor");
const backendsBuildDir = join(isonimExamplesRoot, "build", "backends");

const isMacOS = process.platform === "darwin";

const SKIP_REASON =
  "EPP-M8 — macOS-only acceptance gate. The cocoa launcher (with " +
  "VideoToolbox H.264) only builds on Darwin and the GPUI headless " +
  "render path's pinned Zed revision is Darwin-only too (per EPP-M1 " +
  "§ 1.1). Linux CI tracks the per-axis tests directly.";

// Acceptance criteria — locked at the values the campaign promised.
// Tightening these is a behaviour change; loosening them is forbidden.
const MAX_MEDIAN_FRAME_LATENCY_MS = 50;
const MAX_DPR_DRIFT_PX = 1;
// Click response: one frame budget. We spawn the launchers with
// ``--fps 30`` so 33 ms is the canonical budget. A 60 FPS launcher
// (no backend ships one today) would land at 16 ms; the test would
// then read the cadence cap from the hello capability bag.
const ONE_FRAME_AT_30FPS_MS = 33;
const TARGET_FRAME_COUNT = 100;

// Matrix definition. Each row pins the launcher binary, the encoder
// flag, and the canonical bridge backend path the editor's JS shim
// expects when the matching backend pill is clicked.
//
// Why encoders differ:
// * Cocoa: --encoder h264 — exercises the V-packet (VideoToolbox)
//   path that EPP-M5/M6 shipped. VideoToolbox is Darwin-only.
// * GPUI/Freya: --encoder raw_rgba — neither has a hardware encoder
//   wired into its launcher today; the F-packet path is canonical.
const MATRIX = [
  {
    name: "gpui",
    bin: join(backendsBuildDir, "isonim-examples-gpui"),
    encoder: "raw_rgba",
    expectedTransport: "f/rgba",
    pillLabelRx: "gpui",
    extraEnv: {
      // The GPUI Rust shim is a cdylib loaded via Nim's `dynlib`.
      DYLD_LIBRARY_PATH: join(isonimGpuiRoot, "rust", "target", "release"),
      DYLD_FALLBACK_LIBRARY_PATH: join(
        isonimGpuiRoot,
        "rust",
        "target",
        "release",
      ),
    },
  },
  {
    name: "freya",
    bin: join(backendsBuildDir, "isonim-examples-freya"),
    encoder: "raw_rgba",
    expectedTransport: "f/rgba",
    pillLabelRx: "freya",
    extraEnv: {},
  },
  {
    name: "cocoa",
    bin: join(backendsBuildDir, "isonim-examples-cocoa"),
    encoder: "h264",
    expectedTransport: "v/avc1",
    pillLabelRx: "cocoa",
    extraEnv: {},
  },
];

function exec(cmd, opts = {}) {
  return execSync(cmd, { stdio: "pipe", ...opts }).toString();
}

function buildAll() {
  // editor-build transitively builds Linux backends (gpui+freya).
  exec("direnv exec . just editor-build", { cwd: isonimExamplesRoot });
  // build-backends-macos additionally builds the cocoa launcher with
  // the VideoToolbox helper compiled in.
  exec("direnv exec . just build-backends-macos", {
    cwd: isonimExamplesRoot,
  });
  for (const row of MATRIX) {
    if (!existsSync(row.bin)) {
      throw new Error(
        `EPP-M8: launcher binary missing for ${row.name}: ${row.bin}`,
      );
    }
  }
  if (!existsSync(join(editorBuildDir, "editor.js"))) {
    throw new Error("editor.js not produced by `just editor-build`");
  }
}

async function pickFreePort() {
  return new Promise((resolve, reject) => {
    const srv = net.createServer();
    srv.unref();
    srv.on("error", reject);
    srv.listen(0, "127.0.0.1", () => {
      const port = srv.address().port;
      srv.close(() => resolve(port));
    });
  });
}

async function spawnLauncher(row, port, dims) {
  // CLI mirrors editor/backends/common.nim parseLauncherArgs. We pin
  // --fps 30 so the launcher cadence is predictable; the matrix
  // assertion picks the click-response budget from the same cap.
  const proc = spawn(
    row.bin,
    [
      "--port",
      String(port),
      "--demo",
      "task",
      "--width",
      String(dims.width),
      "--height",
      String(dims.height),
      "--fps",
      "30",
      "--encoder",
      row.encoder,
    ],
    {
      cwd: isonimExamplesRoot,
      env: { ...process.env, ...row.extraEnv },
      stdio: ["ignore", "pipe", "pipe"],
    },
  );
  const tag = `[${row.name}-launcher]`;
  proc.stderr.on("data", (b) => process.stderr.write(`${tag} ${b}`));
  proc.stdout.on("data", (b) => process.stderr.write(`${tag} ${b}`));

  // Wait until the launcher binds the port.
  await new Promise((resolve, reject) => {
    const deadline = Date.now() + 20000;
    const tick = () => {
      if (Date.now() > deadline) {
        reject(new Error(`${row.name} launcher failed to bind in 20s`));
        return;
      }
      const s = net.connect(port, "127.0.0.1");
      s.once("connect", () => {
        s.end();
        resolve();
      });
      s.once("error", () => {
        setTimeout(tick, 100);
      });
    };
    tick();
  });
  return proc;
}

const MIME_BY_EXT = {
  ".html": "text/html; charset=utf-8",
  ".js": "application/javascript; charset=utf-8",
  ".mjs": "application/javascript; charset=utf-8",
  ".css": "text/css; charset=utf-8",
  ".json": "application/json; charset=utf-8",
  ".txt": "text/plain; charset=utf-8",
  ".png": "image/png",
  ".svg": "image/svg+xml",
  ".ico": "image/x-icon",
};

// HTTP+WS proxy: serves the editor's static bundle and pipes
// ``/bridge/<backend>`` WebSocket upgrades through to the real
// launcher. RFC-6455 frames are opaque post-upgrade — we pipe bytes
// through verbatim. Outbound I packets (keyboard / mouse / resize)
// are observed via the page-side instrumentation (a wrapper around
// ``WebSocket.prototype.send`` set up by ``paintInstrumentationScript``);
// the proxy itself does not decode them.
async function startEditorProxy(serverPort, launcherPort, backendName) {
  const server = createServer((req, res) => {
    if (req.method !== "GET") {
      res.writeHead(405);
      res.end();
      return;
    }
    let p = (req.url || "/").split("?")[0];
    if (p === "/") p = "/index.html";
    if (p.includes("..")) {
      res.writeHead(403);
      res.end();
      return;
    }
    const filePath = join(editorBuildDir, p);
    if (!existsSync(filePath)) {
      res.writeHead(404);
      res.end(`not found: ${p}`);
      return;
    }
    try {
      const body = readFileSync(filePath);
      const ct = MIME_BY_EXT[extname(p)] || "application/octet-stream";
      res.writeHead(200, { "content-type": ct, "cache-control": "no-store" });
      res.end(body);
    } catch (e) {
      res.writeHead(500);
      res.end(String(e));
    }
  });

  server.on("upgrade", (req, clientSocket, head) => {
    const url = req.url || "";
    if (!url.startsWith(`/bridge/${backendName}`)) {
      clientSocket.write("HTTP/1.1 404 Not Found\r\n\r\n");
      clientSocket.destroy();
      return;
    }
    const upstream = net.connect(
      { host: "127.0.0.1", port: launcherPort },
      () => {
        const lines = [];
        lines.push(`GET / HTTP/1.1`);
        for (const [k, v] of Object.entries(req.headers || {})) {
          if (k.toLowerCase() === "host") {
            lines.push(`Host: 127.0.0.1:${launcherPort}`);
          } else {
            const values = Array.isArray(v) ? v : [v];
            for (const vv of values) lines.push(`${k}: ${vv}`);
          }
        }
        lines.push("\r\n");
        upstream.write(lines.join("\r\n"));
        if (head && head.length) upstream.write(head);
        upstream.pipe(clientSocket);
        clientSocket.pipe(upstream);
      },
    );
    upstream.on("error", (e) => {
      try {
        clientSocket.write(
          `HTTP/1.1 502 Bad Gateway\r\nContent-Type: text/plain\r\n\r\n` +
            `launcher unreachable: ${e.message}`,
        );
      } catch {}
      clientSocket.destroy();
    });
    clientSocket.on("error", () => upstream.destroy());
    clientSocket.on("close", () => upstream.destroy());
  });

  await new Promise((resolve, reject) => {
    server.once("error", reject);
    server.listen(serverPort, "127.0.0.1", () => {
      server.off("error", reject);
      resolve();
    });
  });

  return {
    server,
    shutdown: () =>
      new Promise((resolve) => {
        try {
          server.close(() => resolve());
        } catch (_) {
          resolve();
        }
      }),
  };
}

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

// addInitScript hook: wrap CanvasRenderingContext2D.prototype.putImageData
// (F-packet path) and drawImage (V-packet decoded VideoFrame path) so
// every paint pushes a timestamp into window.__isonimFrameTimes.
// The matrix test reads this back via page.evaluate.
function paintInstrumentationScript() {
  return () => {
    try {
      // Frame-receive timing — recorded each time an F or V packet
      // arrives on a WebSocket. The launcher emits at its --fps cap
      // even for identical content (RS-M3 "heartbeat" rule), so this
      // is the honest measure of the wall-clock cadence the editor
      // observes — paint-skipping for empty diffs cannot suppress it.
      // eslint-disable-next-line no-undef
      window.__isonimFrameTimes = [];
      // Canvas-paint timing — recorded each time the JS shim actually
      // paints into the streaming canvas. Useful for "click → visible
      // response" because we want a paint that REPLACES pixels, not
      // just a heartbeat F packet that no-ops.
      // eslint-disable-next-line no-undef
      window.__isonimCanvasPaintTimes = [];
      // eslint-disable-next-line no-undef
      window.__isonimSendInputCount = 0;
      // eslint-disable-next-line no-undef
      window.__isonimKeyboardDownChars = [];
      const proto =
        // eslint-disable-next-line no-undef
        typeof CanvasRenderingContext2D === "function"
          ? // eslint-disable-next-line no-undef
            CanvasRenderingContext2D.prototype
          : null;
      if (proto) {
        const isStreamingCanvas = (ctx) => {
          try {
            const cnv = ctx && ctx.canvas;
            if (!cnv) return false;
            // The streaming preview canvas carries the data-canvas-active
            // attribute (set by canvas_mount.nim). Any other canvas
            // (chrome bar icons, gallery thumbnails, etc.) is ignored.
            return (
              cnv.getAttribute &&
              cnv.getAttribute("data-canvas-active") === "true"
            );
          } catch (_) {
            return false;
          }
        };
        const origPut = proto.putImageData;
        // eslint-disable-next-line func-names
        proto.putImageData = function (...args) {
          try {
            if (isStreamingCanvas(this)) {
              // eslint-disable-next-line no-undef
              window.__isonimCanvasPaintTimes.push(performance.now());
            }
          } catch (_) {}
          return origPut.apply(this, args);
        };
        const origDraw = proto.drawImage;
        // eslint-disable-next-line func-names
        proto.drawImage = function (img, ...rest) {
          try {
            // Streaming-canvas paints only. We don't filter by image
            // type because the JS shim calls drawImage(frame) for V
            // packets and also reuses ctx.drawImage paths in the
            // future-extensions slot.
            if (isStreamingCanvas(this)) {
              // eslint-disable-next-line no-undef
              window.__isonimCanvasPaintTimes.push(performance.now());
            }
          } catch (_) {}
          return origDraw.apply(this, [img, ...rest]);
        };
      }
      // Hook into WebSocket.prototype.addEventListener so we can
      // intercept 'message' events and record F/V packet arrival
      // timestamps. This is the campaign-honest measure of the
      // wall-clock cadence — independent of whether the paint
      // actually happens (the JS shim skips paints for empty
      // diff F packets, per RS-M3 heartbeat rule).
      // eslint-disable-next-line no-undef
      const origAdd = WebSocket.prototype.addEventListener;
      // eslint-disable-next-line no-undef
      WebSocket.prototype.addEventListener = function (
        kind,
        listener,
        ...rest
      ) {
        if (kind === "message" && typeof listener === "function") {
          const wrapped = function (ev) {
            try {
              if (
                ev &&
                ev.data instanceof ArrayBuffer &&
                ev.data.byteLength > 0
              ) {
                const first = new Uint8Array(ev.data, 0, 1)[0];
                if (first === 0x46 /* F */ || first === 0x56 /* V */) {
                  // eslint-disable-next-line no-undef
                  window.__isonimFrameTimes.push(performance.now());
                }
              }
            } catch (_) {}
            return listener.call(this, ev);
          };
          return origAdd.call(this, kind, wrapped, ...rest);
        }
        return origAdd.call(this, kind, listener, ...rest);
      };
      // Hook into WebSocket.send so we can count outbound I packets
      // and parse keyboard text fields. The JS shim emits I packets
      // as binary frames matching: 'I' | u32 LE length | UTF-8 JSON.
      // eslint-disable-next-line no-undef
      const origSend = WebSocket.prototype.send;
      // eslint-disable-next-line func-names, no-undef
      WebSocket.prototype.send = function (data) {
        try {
          let bytes = null;
          if (data instanceof ArrayBuffer) bytes = new Uint8Array(data);
          else if (data && data.buffer instanceof ArrayBuffer) {
            bytes = new Uint8Array(
              data.buffer,
              data.byteOffset || 0,
              data.byteLength,
            );
          }
          if (bytes && bytes.length >= 5 && bytes[0] === 0x49 /* 'I' */) {
            // eslint-disable-next-line no-undef
            window.__isonimSendInputCount =
              // eslint-disable-next-line no-undef
              (window.__isonimSendInputCount || 0) + 1;
            const view = new DataView(
              bytes.buffer,
              bytes.byteOffset,
              bytes.byteLength,
            );
            const len = view.getUint32(1, true);
            if (5 + len <= bytes.length) {
              const dec = new TextDecoder();
              const json = dec.decode(bytes.subarray(5, 5 + len));
              try {
                const node = JSON.parse(json);
                if (
                  node &&
                  node.type === "keyboard" &&
                  node.action === "down" &&
                  typeof node.text === "string"
                ) {
                  // eslint-disable-next-line no-undef
                  window.__isonimKeyboardDownChars.push(node.text);
                }
              } catch (_) {}
            }
          }
        } catch (_) {}
        return origSend.apply(this, [data]);
      };
    } catch (e) {
      // Surface any setup error via a global the test can read.
      try {
        // eslint-disable-next-line no-undef
        window.__isonimInstrumentationError = String(e && e.message);
      } catch (_) {}
    }
  };
}

async function openEditor(serverPort, dpr = 1) {
  const b = await ensureBrowser();
  const ctx = await b.newContext({
    viewport: { width: 1440, height: 900 },
    deviceScaleFactor: dpr,
  });
  await ctx.addInitScript(paintInstrumentationScript());
  const page = await ctx.newPage();
  page.on("pageerror", (e) =>
    console.error("[page] error:", e && e.message ? e.message : String(e)),
  );
  await page.goto(`http://127.0.0.1:${serverPort}/index.html`);
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
  await page.addStyleTag({
    content:
      "*, *::before, *::after { transition: none !important;" +
      " animation: none !important; }",
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

async function viewportPillSelectors(page) {
  return page.evaluate(() => {
    const pills = document.querySelectorAll(
      '[data-toolbar-cluster="viewport"] ' +
        '[data-preview-viewport-strip-host="true"] [data-choice-group-pill]',
    );
    const out = [];
    for (const p of pills) {
      const disabled = p.getAttribute("aria-disabled") === "true";
      if (disabled) continue;
      const idx = p.getAttribute("data-choice-group-pill");
      const lbl =
        p.getAttribute("data-choice-group-label") ||
        p.getAttribute("aria-label") ||
        p.textContent ||
        "";
      const active = p.getAttribute("aria-pressed") === "true";
      out.push({
        index: idx,
        label: lbl.trim(),
        active,
        selector:
          `[data-toolbar-cluster="viewport"] ` +
          `[data-preview-viewport-strip-host="true"] ` +
          `[data-choice-group-pill="${idx}"]`,
      });
    }
    return out;
  });
}

async function waitFor(predicate, ms = 30000, intervalMs = 80) {
  const t0 = Date.now();
  while (Date.now() - t0 < ms) {
    if (await predicate()) return true;
    await new Promise((r) => setTimeout(r, intervalMs));
  }
  return false;
}

// Read the JS shim's frame-time buffer and compute the median delta
// (gap between consecutive paints) in milliseconds.
async function measureMedianFrameLatency(page, sampleCount) {
  // Reset the buffer so we measure ONLY the next ``sampleCount`` paints.
  await page.evaluate(() => {
    // eslint-disable-next-line no-undef
    window.__isonimFrameTimes = [];
  });
  // Wait until we have enough samples (at 30 FPS = ~33 ms apart,
  // 100 samples ≈ 3.3 s of paint activity).
  const settled = await waitFor(async () => {
    const n = await page.evaluate(
      // eslint-disable-next-line no-undef
      () => (window.__isonimFrameTimes || []).length,
    );
    return n >= sampleCount;
  }, 30000);
  const times = await page.evaluate(
    // eslint-disable-next-line no-undef
    () => (window.__isonimFrameTimes || []).slice(),
  );
  if (!settled) {
    return {
      settled: false,
      collectedCount: times.length,
      medianMs: Number.POSITIVE_INFINITY,
      p99Ms: Number.POSITIVE_INFINITY,
    };
  }
  const slice = times.slice(0, sampleCount);
  const deltas = [];
  for (let i = 1; i < slice.length; i++) deltas.push(slice[i] - slice[i - 1]);
  deltas.sort((a, b) => a - b);
  const median = deltas[Math.floor(deltas.length / 2)];
  const p99 =
    deltas[Math.floor(deltas.length * 0.99)] || deltas[deltas.length - 1];
  return {
    settled: true,
    collectedCount: slice.length,
    medianMs: median,
    p99Ms: p99,
  };
}

async function findActiveCanvas(page) {
  return page.evaluate(() => {
    const canvases = Array.from(document.querySelectorAll("canvas"));
    let c = canvases.find(
      (cn) => cn.getAttribute("data-canvas-active") === "true",
    );
    if (!c) {
      c = canvases.find((cn) => {
        try {
          const wrapper = cn.closest("[data-canvas-wrapper]");
          return wrapper && wrapper.style.display !== "none";
        } catch (_) {
          return false;
        }
      });
    }
    if (!c) c = canvases[0];
    if (!c) return null;
    const rect = c.getBoundingClientRect();
    return {
      present: true,
      intrinsicW: c.width,
      intrinsicH: c.height,
      styleW: c.style.width,
      styleH: c.style.height,
      rectW: rect.width,
      rectH: rect.height,
      rectLeft: rect.left,
      rectTop: rect.top,
      dpr: window.devicePixelRatio || 1,
      tabIndex: c.tabIndex,
    };
  });
}

async function pickBackend(page, row) {
  const sel = await backendPillSelector(page, row.pillLabelRx);
  assert.ok(sel, `EPP-M8: ${row.name} backend pill should be present`);
  await page.locator(sel).click();
  await page.evaluate(() => {
    const candidate = document.querySelector("[data-story-row]");
    if (candidate) candidate.click();
  });
}

// Run the matrix walk for a single backend. Collects ALL measurements
// before doing assertions so a single failing axis doesn't mask the
// other backends' (or the same backend's) measurements. The report
// surfaces every measured value, honestly, per the campaign brief.
async function runBackendMatrix(row) {
  const launcherPort = await pickFreePort();
  const editorPort = await pickFreePort();
  // EPP-M8 dimensions: pick a generous frame so the rendered task_app
  // has room for meaningful UI surface (the click-response assertion
  // needs a non-trivial click region).
  const dims = { width: 800, height: 600 };
  let launcher = null;
  let proxy = null;
  let ctx = null;
  // Measurements bag — populated as the walk progresses. Every key
  // starts as a "not-measured" sentinel so the JSON summary surfaces
  // partial walks (e.g. if the transport never settled).
  const measurements = {
    backend: row.name,
    expectedTransport: row.expectedTransport,
    transportSettled: false,
    settledTransport: "",
    dpr: null,
    intrinsicW: null,
    intrinsicH: null,
    dprDriftWpx: null,
    dprDriftHpx: null,
    viewportsCycled: 0,
    viewportPaintFailures: [],
    canvasFocusOk: null,
    bodyMarkerOk: null,
    clickResponseLatencyMs: Number.POSITIVE_INFINITY,
    keyboardForwarded: null,
    framesObserved: 0,
    canvasPaintsObserved: 0,
    medianFrameLatencyMs: Number.POSITIVE_INFINITY,
    p99FrameLatencyMs: Number.POSITIVE_INFINITY,
    decoderConfigureError: "",
    decoderDecodeError: "",
    diagnosticNote: "",
  };
  try {
    launcher = await spawnLauncher(row, launcherPort, dims);
    proxy = await startEditorProxy(editorPort, launcherPort, row.name);
    const opened = await openEditor(editorPort, 1);
    ctx = opened.ctx;
    const page = opened.page;
    await page.evaluate(() => {
      // eslint-disable-next-line no-undef
      window.__isonimTestMode = true;
    });
    await pickBackend(page, row);

    // 1. Wait for the bridge to settle on its expected transport.
    measurements.transportSettled = await waitFor(async () => {
      const v = await page.evaluate(
        () => document.body.dataset.isonimActiveTransport || "",
      );
      measurements.settledTransport = v;
      return v === row.expectedTransport;
    }, 25000);
    if (!measurements.transportSettled) {
      const diag = await page.evaluate(() => ({
        // eslint-disable-next-line no-undef
        configureError: window.__isonimLastVideoConfigureError || "",
        // eslint-disable-next-line no-undef
        decodeError: window.__isonimLastVideoDecodeError || "",
      }));
      measurements.decoderConfigureError = diag.configureError;
      measurements.decoderDecodeError = diag.decodeError;
      measurements.diagnosticNote = `editor never settled on transport ${row.expectedTransport}`;
      return measurements;
    }

    // 2. DPR contract measurement.
    const canvasInfo = await findActiveCanvas(page);
    if (canvasInfo && canvasInfo.present) {
      measurements.dpr = canvasInfo.dpr;
      measurements.intrinsicW = canvasInfo.intrinsicW;
      measurements.intrinsicH = canvasInfo.intrinsicH;
      measurements.dprDriftWpx = Math.abs(
        canvasInfo.rectW * canvasInfo.dpr - canvasInfo.intrinsicW,
      );
      measurements.dprDriftHpx = Math.abs(
        canvasInfo.rectH * canvasInfo.dpr - canvasInfo.intrinsicH,
      );
    }

    // 3. Cycle through viewport pills (2-3 non-active pills).
    const viewports = await viewportPillSelectors(page);
    const switchable = viewports.filter((v) => !v.active);
    const cycleCount = Math.min(3, switchable.length);
    for (let i = 0; i < cycleCount; i++) {
      const target = switchable[i];
      const baseline = await page.evaluate(
        // eslint-disable-next-line no-undef
        () => (window.__isonimCanvasPaintTimes || []).length,
      );
      await page.locator(target.selector).click();
      const sawPaint = await waitFor(async () => {
        const n = await page.evaluate(
          // eslint-disable-next-line no-undef
          () => (window.__isonimCanvasPaintTimes || []).length,
        );
        return n > baseline;
      }, 10000);
      if (sawPaint) {
        measurements.viewportsCycled++;
      } else {
        measurements.viewportPaintFailures.push(target.label);
      }
    }

    // 4. Click into the rendered canvas; record focus + click-response.
    const fresh = await findActiveCanvas(page);
    const clickX = fresh.rectLeft + fresh.rectW / 2;
    const clickY = fresh.rectTop + fresh.rectH / 2;
    const ROI = 128;
    const roiBaseline = await page.evaluate(
      ({ cx, cy, roi }) => {
        const cnv = document.querySelector('canvas[data-canvas-active="true"]');
        if (!cnv) return null;
        const rect = cnv.getBoundingClientRect();
        const scaleX = cnv.width / rect.width;
        const scaleY = cnv.height / rect.height;
        const half = Math.floor(roi / 2);
        const px = Math.round((cx - rect.left) * scaleX) - half;
        const py = Math.round((cy - rect.top) * scaleY) - half;
        const x = Math.max(0, Math.min(cnv.width - roi, px));
        const y = Math.max(0, Math.min(cnv.height - roi, py));
        const cctx = cnv.getContext("2d");
        if (!cctx) return null;
        const img = cctx.getImageData(x, y, roi, roi);
        let r = 0,
          g = 0,
          b = 0,
          count = 0;
        for (let i = 0; i < img.data.length; i += 4 * 16) {
          r += img.data[i];
          g += img.data[i + 1];
          b += img.data[i + 2];
          count++;
        }
        return {
          x,
          y,
          roi,
          fingerprint: `${r}/${g}/${b}/${count}`,
        };
      },
      { cx: clickX, cy: clickY, roi: ROI },
    );

    const clickMark = await page.evaluate(
      // eslint-disable-next-line no-undef
      () => performance.now(),
    );
    await page.mouse.click(clickX, clickY);
    const focusState = await page.evaluate(() => ({
      isCanvas:
        document.activeElement &&
        document.activeElement.tagName.toLowerCase() === "canvas",
      bodyMarker: document.body.getAttribute("data-isonim-canvas-focused"),
    }));
    measurements.canvasFocusOk = focusState.isCanvas === true;
    measurements.bodyMarkerOk = focusState.bodyMarker === "true";

    const oneFrameBudgetMs = ONE_FRAME_AT_30FPS_MS;
    const responseDeadlineMs = oneFrameBudgetMs * 10;
    const t0 = Date.now();
    if (roiBaseline) {
      while (Date.now() - t0 < responseDeadlineMs) {
        const sample = await page.evaluate(({ x, y, roi }) => {
          const cnv = document.querySelector(
            'canvas[data-canvas-active="true"]',
          );
          if (!cnv) return null;
          const cctx = cnv.getContext("2d");
          if (!cctx) return null;
          const img = cctx.getImageData(x, y, roi, roi);
          let r = 0,
            g = 0,
            b = 0,
            count = 0;
          for (let i = 0; i < img.data.length; i += 4 * 16) {
            r += img.data[i];
            g += img.data[i + 1];
            b += img.data[i + 2];
            count++;
          }
          return {
            fingerprint: `${r}/${g}/${b}/${count}`,
            // eslint-disable-next-line no-undef
            t: performance.now(),
          };
        }, roiBaseline);
        if (sample && sample.fingerprint !== roiBaseline.fingerprint) {
          measurements.clickResponseLatencyMs = sample.t - clickMark;
          break;
        }
        await new Promise((r) => setTimeout(r, 5));
      }
    }

    // 5. Type into the focused canvas, confirm the keyboard packet
    //    reached the JS shim's sendInput wrapper.
    await page.evaluate(() => {
      // eslint-disable-next-line no-undef
      window.__isonimKeyboardDownChars = [];
    });
    await page.keyboard.type("hi");
    measurements.keyboardForwarded = await waitFor(async () => {
      const chars = await page.evaluate(
        // eslint-disable-next-line no-undef
        () => (window.__isonimKeyboardDownChars || []).slice(),
      );
      return chars.includes("h") && chars.includes("i");
    }, 5000);

    // 6. Median frame latency over the target sample count.
    const latency = await measureMedianFrameLatency(page, TARGET_FRAME_COUNT);
    measurements.framesObserved = latency.collectedCount;
    measurements.medianFrameLatencyMs = latency.medianMs;
    measurements.p99FrameLatencyMs = latency.p99Ms;

    const tail = await page.evaluate(() => ({
      // eslint-disable-next-line no-undef
      paintsTotal: (window.__isonimCanvasPaintTimes || []).length,
      // eslint-disable-next-line no-undef
      configureError: window.__isonimLastVideoConfigureError || "",
      // eslint-disable-next-line no-undef
      decodeError: window.__isonimLastVideoDecodeError || "",
    }));
    measurements.canvasPaintsObserved = tail.paintsTotal;
    measurements.decoderConfigureError = tail.configureError;
    measurements.decoderDecodeError = tail.decodeError;

    return measurements;
  } finally {
    try {
      if (ctx) await ctx.close();
    } catch (_) {}
    try {
      if (launcher) launcher.kill("SIGTERM");
      await new Promise((r) => setTimeout(r, 200));
      if (launcher) launcher.kill("SIGKILL");
    } catch (_) {}
    try {
      if (proxy) await proxy.shutdown();
    } catch (_) {}
  }
}

// Apply the campaign-locked acceptance criteria to one backend's
// measurements. Returns a list of human-readable assertion failures
// (empty when the backend passes).
function assertAcceptance(m) {
  const failures = [];
  if (!m.transportSettled) {
    failures.push(
      `transport never settled on ${m.expectedTransport} ` +
        `(last observed=${m.settledTransport || "<empty>"}); ` +
        `decoder errors: configure="${m.decoderConfigureError}", ` +
        `decode="${m.decoderDecodeError}"`,
    );
    // If the transport never settled, the remaining axes cannot
    // produce meaningful measurements; report them downstream as N/A.
  }
  if (m.dpr != null) {
    if (m.dprDriftWpx > MAX_DPR_DRIFT_PX) {
      failures.push(
        `DPR contract (width) drift=${m.dprDriftWpx.toFixed(3)}px > ` +
          `${MAX_DPR_DRIFT_PX}px; intrinsic=${m.intrinsicW}px`,
      );
    }
    if (m.dprDriftHpx > MAX_DPR_DRIFT_PX) {
      failures.push(
        `DPR contract (height) drift=${m.dprDriftHpx.toFixed(3)}px > ` +
          `${MAX_DPR_DRIFT_PX}px; intrinsic=${m.intrinsicH}px`,
      );
    }
  } else if (m.transportSettled) {
    failures.push("DPR measurement missing (no canvas info captured)");
  }
  if (m.viewportPaintFailures.length > 0) {
    failures.push(
      `viewport pills failed to repaint within 10s: ` +
        m.viewportPaintFailures.join(","),
    );
  }
  if (m.canvasFocusOk === false) {
    failures.push("canvas did not own focus after click");
  }
  if (m.bodyMarkerOk === false) {
    failures.push("data-isonim-canvas-focused did not mark the body");
  }
  if (m.clickResponseLatencyMs > ONE_FRAME_AT_30FPS_MS) {
    const v = Number.isFinite(m.clickResponseLatencyMs)
      ? `${m.clickResponseLatencyMs.toFixed(1)} ms`
      : ">330 ms (no visible response observed)";
    failures.push(
      `click response ${v} > ${ONE_FRAME_AT_30FPS_MS} ms ` +
        "(one frame at 30 FPS)",
    );
  }
  if (m.keyboardForwarded === false) {
    failures.push('typed "hi" but keyboard packets never reached the JS shim');
  }
  if (m.medianFrameLatencyMs > MAX_MEDIAN_FRAME_LATENCY_MS) {
    const v = Number.isFinite(m.medianFrameLatencyMs)
      ? `${m.medianFrameLatencyMs.toFixed(2)} ms`
      : "<unmeasured>";
    failures.push(
      `median frame latency ${v} > ${MAX_MEDIAN_FRAME_LATENCY_MS} ms ` +
        `(p99=${
          Number.isFinite(m.p99FrameLatencyMs)
            ? m.p99FrameLatencyMs.toFixed(2) + " ms"
            : "<unmeasured>"
        }, samples=${m.framesObserved})`,
    );
  }
  return failures;
}

// Singleton measurements bag — written by each per-backend test so the
// final summary test can print them. node --test runs files in
// declaration order; we use a module-level object that the summary
// test reads in test.after.
const matrixResults = {};

test.before(async () => {
  if (!isMacOS) return;
  buildAll();
});

test.after(async () => {
  try {
    if (browser) await browser.close();
  } catch (_) {}
  // Always print the matrix summary so a failing case still surfaces
  // the other backends' measurements honestly.
  process.stderr.write(
    "\n[EPP-M8 matrix summary] " +
      JSON.stringify(matrixResults, null, 2) +
      "\n",
  );
});

for (const row of MATRIX) {
  test(`EPP-M8 [${row.name}]: acceptance matrix walk`, async (t) => {
    if (!isMacOS) {
      t.skip(SKIP_REASON);
      return;
    }
    const measurements = await runBackendMatrix(row);
    matrixResults[row.name] = measurements;
    const failures = assertAcceptance(measurements);
    if (failures.length > 0) {
      assert.fail(
        `EPP-M8 [${row.name}] acceptance failed:\n  - ` +
          failures.join("\n  - ") +
          `\nMeasurements: ${JSON.stringify(measurements, null, 2)}`,
      );
    }
  });
}
