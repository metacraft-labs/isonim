// FUH-M8 — Full editor acceptance matrix.
//
// Cross-campaign acceptance test that consolidates the six user-visible
// promises measured separately by EPP-M8, ELT-M9, ETS-M6, and FUH-M3
// into a single 18-cell matrix walk. Per FUH-M7 §3 the matrix is:
//
//   backends × viewports × apps = 3 × 3 × 2 = 18 cells
//
//   backends: gpui (raw_rgba), freya (raw_rgba), cocoa (webp)
//   viewports: Phone (390×844), Laptop (1280×800), Desktop (1440×900)
//   apps: task_app, settings_app
//
// Each cell measures all six criteria. Bandwidth + lossless are
// W-path only — non-cocoa cells mark those criteria N/A.
//
//   1. Median frame latency ≤ 50 ms (EPP-M8)
//   2. Idle bandwidth median ≤ 512 B per W-packet (ELT-M9; cocoa only)
//   3. Click → visible response ≤ 33 ms (EPP-M8/EPP-M12, one-frame budget)
//   4. Hover → overlay-update median ≤ 16 ms (ETS-M6/FUH-M3)
//   5. DPR contract drift ≤ 1 px on both axes (EPP-M8)
//   6. Lossless contract: ≥ 2 uniqueRGB + >1/16 sampled pixels non-grey
//      (ELT-M9; cocoa only)
//
// Per FUH-M7 Appendix A + FUH-M6's deadlock surprise, the matrix runs
// strictly sequentially via subtests inside a single parent test() so
// node's test runner cannot accidentally parallelise cells. ONE launcher
// + ONE browserContext alive at any time; the browser singleton survives
// across cells (EPP-M8 pattern).
//
// Skip rule: macOS-only — cocoa launcher only builds on Darwin and the
// matrix gates all 18 cells as a unit.
//
// Honest-measurement contract: no threshold weakening. If any cell's
// criterion fails honestly, the JSON result records the measured value
// + threshold and the test fails at the end with a per-cell summary.

import { execSync, spawn } from "node:child_process";
import { createServer } from "node:http";
import { existsSync, mkdirSync, readFileSync, writeFileSync } from "node:fs";
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
const goldenDir = join(__dirname, "golden", "fuh-m8");

const isMacOS = process.platform === "darwin";

const SKIP_REASON =
  "FUH-M8 — macOS-only acceptance gate. The cocoa launcher (W/webp + " +
  "lossless contract) only builds on Darwin and the matrix gates " +
  "every backend as a unit.";

// Campaign-locked thresholds. Per FUH-M7 §1 these MUST NOT be weakened.
const THRESHOLDS = Object.freeze({
  medianFrameLatencyMs: 50, // EPP-M8
  idleMedianPacketBytes: 512, // ELT-M9
  clickResponseMs: 33, // EPP-M12 (one frame @ 30 FPS)
  hoverOverlayMs: 16, // ETS-M6 + FUH-M3
  dprDriftPx: 1, // EPP-M2 + EPP-M8
  losslessMinUniqueColors: 2, // ELT-M9
  losslessMinNonGreyRatio: 1 / 16, // ELT-M9
});

const TARGET_FRAME_COUNT = 100;
const FRAME_LATENCY_SETTLE_MS = 20000;
const HOVER_SAMPLE_COUNT = 5;
const IDLE_SETTLE_MS = 3500;
const TRANSPORT_SETTLE_MS = 25000;

// Backend axis (per FUH-M7 §2.1).
const BACKENDS = [
  {
    name: "gpui",
    bin: join(backendsBuildDir, "isonim-examples-gpui"),
    encoder: "raw_rgba",
    expectedTransport: "f/rgba",
    pillLabelRx: "gpui",
    extraEnv: {
      DYLD_LIBRARY_PATH: join(isonimGpuiRoot, "rust", "target", "release"),
      DYLD_FALLBACK_LIBRARY_PATH: join(
        isonimGpuiRoot,
        "rust",
        "target",
        "release",
      ),
    },
    measuresBandwidth: false,
    measuresLossless: false,
  },
  {
    name: "freya",
    bin: join(backendsBuildDir, "isonim-examples-freya"),
    encoder: "raw_rgba",
    expectedTransport: "f/rgba",
    pillLabelRx: "freya",
    extraEnv: {},
    measuresBandwidth: false,
    measuresLossless: false,
  },
  {
    name: "cocoa",
    bin: join(backendsBuildDir, "isonim-examples-cocoa"),
    encoder: "webp", // FUH-M8 changes cocoa to W/webp so criteria 2 + 6 are measurable
    expectedTransport: "w/webp",
    pillLabelRx: "cocoa",
    extraEnv: {},
    measuresBandwidth: true,
    measuresLossless: true,
  },
];

// Viewport axis (per FUH-M7 §2.2).
const VIEWPORTS = [
  { name: "Phone", slug: "phone", width: 390, height: 844 },
  { name: "Laptop", slug: "laptop", width: 1280, height: 800 },
  { name: "Desktop", slug: "desktop", width: 1440, height: 900 },
];

// App axis (per FUH-M7 §2.3).
//
// For the click test, task_app uses rect-center (the TaskRow under the
// center is interactive per EPP-M12). settings_app falls back to
// __isonimManifests-derived clicks at the first interactive widget; if
// that fails we use rect-center as the final fallback.
const APPS = [
  {
    name: "task_app",
    demo: "task",
    storyPattern: "task app",
  },
  {
    name: "settings_app",
    demo: "settings",
    storyPattern: "settings app",
  },
];

// Build the matrix as backend-outer / app-middle / viewport-inner so
// the launcher binary can be reused if we ever batch by binary; today
// we still kill+respawn per cell to satisfy the FUH-M6 serialisation
// invariant.
const MATRIX = [];
for (const backend of BACKENDS) {
  for (const app of APPS) {
    for (const viewport of VIEWPORTS) {
      MATRIX.push({ backend, app, viewport });
    }
  }
}

function cellLabel(cell) {
  return `${cell.backend.name}/${cell.app.name}/${cell.viewport.name}`;
}

function exec(cmd, opts = {}) {
  return execSync(cmd, { stdio: "pipe", ...opts }).toString();
}

function buildAll() {
  exec("direnv exec . just editor-build", { cwd: isonimExamplesRoot });
  exec("direnv exec . just build-backends-macos", {
    cwd: isonimExamplesRoot,
  });
  for (const b of BACKENDS) {
    if (!existsSync(b.bin)) {
      throw new Error(
        `FUH-M8: launcher binary missing for ${b.name}: ${b.bin}`,
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

async function spawnLauncher(backend, app, viewport, port) {
  const args = [
    "--port",
    String(port),
    "--demo",
    app.demo,
    "--width",
    String(viewport.width),
    "--height",
    String(viewport.height),
    "--fps",
    "30",
    "--encoder",
    backend.encoder,
  ];
  const proc = spawn(backend.bin, args, {
    cwd: isonimExamplesRoot,
    env: { ...process.env, ...backend.extraEnv },
    stdio: ["ignore", "pipe", "pipe"],
  });
  const tag = `[fuh-m8 ${backend.name}/${app.name}/${viewport.name}]`;
  proc.stderr.on("data", (b) => process.stderr.write(`${tag} ${b}`));
  proc.stdout.on("data", (b) => process.stderr.write(`${tag} ${b}`));

  await new Promise((resolve, reject) => {
    const deadline = Date.now() + 20000;
    const tick = () => {
      if (Date.now() > deadline) {
        reject(new Error(`${backend.name} launcher failed to bind in 20s`));
        return;
      }
      const s = net.connect(port, "127.0.0.1");
      s.once("connect", () => {
        s.end();
        resolve();
      });
      s.once("error", () => setTimeout(tick, 100));
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
      res.writeHead(200, {
        "content-type": ct,
        "cache-control": "no-store",
      });
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

// Combined instrumentation block (criteria 1 + 4 inputs). Mirrors
// the EPP-M8 + ETS-M6 hooks so the matrix gathers F/V frame times,
// canvas paint times, outbound I-packet counts, and the per-overlay
// MutationObserver latency tracker.
function instrumentationScript() {
  return () => {
    try {
      // ---- EPP-M8: frame-arrival + paint mirrors ----
      window.__isonimFrameTimes = [];
      window.__isonimCanvasPaintTimes = [];
      window.__isonimSendInputCount = 0;

      const proto =
        typeof CanvasRenderingContext2D === "function"
          ? CanvasRenderingContext2D.prototype
          : null;
      if (proto) {
        const isStreamingCanvas = (ctx) => {
          try {
            const cnv = ctx && ctx.canvas;
            if (!cnv) return false;
            return (
              cnv.getAttribute &&
              cnv.getAttribute("data-canvas-active") === "true"
            );
          } catch (_) {
            return false;
          }
        };
        const origPut = proto.putImageData;
        proto.putImageData = function (...args) {
          try {
            if (isStreamingCanvas(this)) {
              window.__isonimCanvasPaintTimes.push(performance.now());
            }
          } catch (_) {}
          return origPut.apply(this, args);
        };
        const origDraw = proto.drawImage;
        proto.drawImage = function (img, ...rest) {
          try {
            if (isStreamingCanvas(this)) {
              window.__isonimCanvasPaintTimes.push(performance.now());
            }
          } catch (_) {}
          return origDraw.apply(this, [img, ...rest]);
        };
      }

      // F/V packet arrival hook on WebSocket message events.
      const origAdd = WebSocket.prototype.addEventListener;
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
                if (
                  first === 0x46 /* F */ ||
                  first === 0x56 /* V */ ||
                  first === 0x57 /* W */
                ) {
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

      // Outbound I-packet counter (used to confirm input wiring).
      const origSend = WebSocket.prototype.send;
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
          if (bytes && bytes.length >= 5 && bytes[0] === 0x49 /* I */) {
            window.__isonimSendInputCount =
              (window.__isonimSendInputCount || 0) + 1;
          }
        } catch (_) {}
        return origSend.apply(this, [data]);
      };

      // ---- ETS-M6: hover-overlay latency observer ----
      window.__fuhM8LatencySamples = [];
      window.__fuhM8LastMouseMoveT = null;
      window.__fuhM8LastMouseMoveSeq = 0;
      window.__fuhM8LastConsumedSeq = -1;

      function installObserverOnce() {
        if (window.__fuhM8ObserverInstalled) return;
        // EMC-M4 Fix A: wrapper-by-contained-canvas-rect (mirrors the
        // measureHoverOverlay observer-install logic). Wrappers can
        // pass the >10px gate by chrome alone while the contained
        // canvas remains zero-sized; we want the wrapper whose canvas
        // is actually painted.
        const wrappers = document.querySelectorAll(
          '[data-canvas-wrapper="true"]',
        );
        let visible = null;
        for (const w of wrappers) {
          if (getComputedStyle(w).display === "none") continue;
          const canvasChild = w.querySelector("canvas");
          if (!canvasChild) continue;
          const cr = canvasChild.getBoundingClientRect();
          if (cr.width > 10 && cr.height > 10) {
            visible = w;
            break;
          }
        }
        if (!visible) return;
        const hoverLabel = visible.querySelector(
          '[data-canvas-hover-label="true"]',
        );
        const selectionOutline = visible.querySelector(
          '[data-canvas-selection-outline="true"]',
        );
        if (!hoverLabel && !selectionOutline) return;
        window.__fuhM8ObserverInstalled = true;
        const obs = new MutationObserver((muts) => {
          const t = performance.now();
          let anchor = "unknown";
          for (const m of muts) {
            if (m.target === hoverLabel) {
              anchor = "hover-label";
              break;
            }
            if (m.target === selectionOutline) {
              anchor = "selection-outline";
              break;
            }
          }
          const moveT = window.__fuhM8LastMouseMoveT;
          const moveSeq = window.__fuhM8LastMouseMoveSeq;
          if (moveT == null) return;
          if (window.__fuhM8LastConsumedSeq === moveSeq) return;
          window.__fuhM8LastConsumedSeq = moveSeq;
          window.__fuhM8LatencySamples.push({
            seq: moveSeq,
            moveT,
            paintT: t,
            anchor,
            domLatencyMs: t - moveT,
          });
        });
        if (hoverLabel) {
          obs.observe(hoverLabel, {
            attributes: true,
            attributeFilter: ["style"],
          });
        }
        if (selectionOutline) {
          obs.observe(selectionOutline, {
            attributes: true,
            attributeFilter: ["style"],
          });
        }
        window.__fuhM8Observer = obs;
      }
      const tryInstall = setInterval(() => {
        installObserverOnce();
        if (window.__fuhM8ObserverInstalled) clearInterval(tryInstall);
      }, 80);
      setTimeout(() => clearInterval(tryInstall), 30000);
    } catch (e) {
      try {
        window.__fuhM8InstrumentationError = String(e && e.message);
      } catch (_) {}
    }
  };
}

async function openEditor(serverPort, viewport) {
  const b = await ensureBrowser();
  // Reserve generous chrome width so the canvas wrapper isn't clipped
  // by the sidebar layout when measuring narrow viewports.
  const ctx = await b.newContext({
    viewport: { width: 1920, height: 1080 },
    deviceScaleFactor: 1,
  });
  await ctx.addInitScript(instrumentationScript());
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

async function pickBackend(page, backend, app) {
  const sel = await backendPillSelector(page, backend.pillLabelRx);
  assert.ok(sel, `FUH-M8: ${backend.name} backend pill should be present`);
  await page.locator(sel).click();

  // Pick a story matching the app. The story row carries data-story-row
  // with the canonical "<Group> / <Name>" identifier.
  const pickedRow = await page.evaluate((appPattern) => {
    const rx = new RegExp(appPattern, "i");
    const rows = document.querySelectorAll("[data-story-row]");
    for (const r of rows) {
      const slug = r.getAttribute("data-story-row") || "";
      if (rx.test(slug)) {
        r.click();
        return slug;
      }
    }
    // Fallback: click whatever the first story row is — covers the
    // case where the editor's group header is collapsed and the
    // selectors-by-pattern miss.
    const fallback = document.querySelector("[data-story-row]");
    if (fallback) {
      fallback.click();
      return fallback.getAttribute("data-story-row") || "<fallback>";
    }
    return null;
  }, app.storyPattern);
  return pickedRow;
}

async function pickViewportPill(page, slug) {
  const labelForSlug = {
    phone: "Phone",
    laptop: "Laptop",
    desktop: "Desktop",
  };
  const label = labelForSlug[slug];
  if (!label) return false;
  // Pinned strip first.
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
  const chevronClicked = await page.evaluate(() => {
    const ch = document.querySelector(
      '[data-preview-viewport-overflow="true"]',
    );
    if (!ch) return false;
    ch.click();
    return true;
  });
  if (!chevronClicked) return false;
  await new Promise((r) => setTimeout(r, 200));
  return page.evaluate((slugArg) => {
    const opt = document.querySelector(
      `[data-preview-viewport-dropdown-option="${slugArg}"]`,
    );
    if (!opt) return false;
    opt.click();
    return true;
  }, slug);
}

async function waitFor(predicate, ms = 30000, intervalMs = 100) {
  const t0 = Date.now();
  while (Date.now() - t0 < ms) {
    if (await predicate()) return true;
    await new Promise((r) => setTimeout(r, intervalMs));
  }
  return false;
}

async function findActiveCanvas(page) {
  return page.evaluate(() => {
    const wrappers = document.querySelectorAll('[data-canvas-wrapper="true"]');
    let visibleWrapper = null;
    for (const w of wrappers) {
      if (getComputedStyle(w).display === "none") continue;
      const wr = w.getBoundingClientRect();
      if (wr.width > 10 && wr.height > 10) {
        visibleWrapper = w;
        break;
      }
    }
    const canvases = Array.from(document.querySelectorAll("canvas"));
    let c = canvases.find(
      (cn) => cn.getAttribute("data-canvas-active") === "true",
    );
    if (!c && visibleWrapper) {
      c = visibleWrapper.querySelector("canvas");
    }
    if (!c) c = canvases[0];
    if (!c) return null;
    const rect = c.getBoundingClientRect();
    return {
      present: true,
      intrinsicW: c.width,
      intrinsicH: c.height,
      rectW: rect.width,
      rectH: rect.height,
      rectLeft: rect.left,
      rectTop: rect.top,
      dpr: window.devicePixelRatio || 1,
    };
  });
}

function median(arr) {
  if (arr.length === 0) return null;
  const sorted = [...arr].sort((a, b) => a - b);
  const n = sorted.length;
  if (n % 2 === 1) return sorted[(n - 1) / 2];
  return (sorted[n / 2 - 1] + sorted[n / 2]) / 2;
}

function p99(arr) {
  if (arr.length === 0) return null;
  const sorted = [...arr].sort((a, b) => a - b);
  return sorted[Math.min(sorted.length - 1, Math.floor(sorted.length * 0.99))];
}

// ---------------------------------------------------------------------------
// Criterion 1: median frame latency
// ---------------------------------------------------------------------------

async function measureMedianFrameLatency(page) {
  await page.evaluate(() => {
    window.__isonimFrameTimes = [];
  });
  const settled = await waitFor(async () => {
    const n = await page.evaluate(
      () => (window.__isonimFrameTimes || []).length,
    );
    return n >= TARGET_FRAME_COUNT;
  }, FRAME_LATENCY_SETTLE_MS);
  const times = await page.evaluate(() =>
    (window.__isonimFrameTimes || []).slice(),
  );
  if (!settled) {
    return {
      settled: false,
      collectedCount: times.length,
      medianMs: Number.POSITIVE_INFINITY,
      p99Ms: Number.POSITIVE_INFINITY,
    };
  }
  const slice = times.slice(0, TARGET_FRAME_COUNT);
  const deltas = [];
  for (let i = 1; i < slice.length; i++) deltas.push(slice[i] - slice[i - 1]);
  return {
    settled: true,
    collectedCount: slice.length,
    medianMs: median(deltas),
    p99Ms: p99(deltas),
  };
}

// ---------------------------------------------------------------------------
// Criterion 2: idle W-diff bandwidth (cocoa/webp only)
// ---------------------------------------------------------------------------

async function measureIdleBandwidth(page) {
  await page.evaluate(() => {
    window.__isonimWDiffRectCounts = [];
    window.__isonimWDiffByteLengths = [];
  });
  await new Promise((r) => setTimeout(r, IDLE_SETTLE_MS));
  const samples = await page.evaluate(() => ({
    counts: window.__isonimWDiffRectCounts || [],
    bytes: window.__isonimWDiffByteLengths || [],
  }));
  if (!samples.bytes || samples.bytes.length === 0) {
    return {
      packetCount: 0,
      heartbeatCount: 0,
      nonZeroCount: 0,
      medianBytes: Number.POSITIVE_INFINITY,
      maxBytes: Number.POSITIVE_INFINITY,
    };
  }
  const sorted = samples.bytes.slice().sort((a, b) => a - b);
  const med = sorted[Math.floor(sorted.length / 2)];
  const max = sorted[sorted.length - 1];
  const heartbeats = samples.counts.filter((c) => c === 0).length;
  const nonZero = samples.counts.filter((c) => c > 0).length;
  return {
    packetCount: samples.bytes.length,
    heartbeatCount: heartbeats,
    nonZeroCount: nonZero,
    medianBytes: med,
    maxBytes: max,
  };
}

// ---------------------------------------------------------------------------
// Criterion 3: click → visible response
// ---------------------------------------------------------------------------

// EMC-M4 Fix B (combination of Options 1 + 2 from the spec brief).
//
// The previous shape picked the SMALLEST non-root manifest element as
// the click target — typically a 28-48 px toggle pill in
// settings_app. The 128x128 fingerprint ROI centred on the toggle was
// dominated by the toggle's own chrome rather than the row's
// row-pressed paint mutation that EMC-M3 wired in. Result: 17/18
// click cells null after M3.
//
// New picker shape:
//
//   1. Search the manifest for a candidate element whose centre lies
//      INSIDE the visible canvas rect AND whose projected canvas-pixel
//      area is ≥ ROI² (= 128² = 16384 px²). Among those, pick the one
//      whose centre is CLOSEST to the canvas centre. This biases the
//      click toward the row-shaped element that is centred in the
//      preview (typically the active row in settings_app), and the
//      area gate guarantees the ROI fits inside that element.
//
//   2. If no manifest element clears the ROI-fit gate, fall back to
//      rect-center (the canvas geometric centre). This works because
//      the editor previews position the demo's primary row near the
//      canvas centre, and rect-center was the only target shape that
//      ever yielded a non-null cocoa settings_app Phone measurement
//      under the pre-M4 picker.
//
// Why this combined shape (vs Option 1 alone): Option 1 (largest-fit)
// can pick a section background or container that doesn't carry the
// row-pressed handler EMC-M3 wired into itemContainerLeaf. Biasing
// toward the canvas centre — combined with the ROI-fit area gate —
// picks the row that is both visually-prominent AND has a click
// handler installed. The rect-center fallback closes cells where the
// manifest doesn't yield any large-enough element (notably Phone
// settings_app cells, where the canvas hosts the row directly with no
// intermediate sections).
//
// Why this is applied to settings_app only: task_app's previous
// rect-center picker was already producing non-null measurements for
// the cells where the paint mutation is visible to the rasteriser
// (gpui), so we keep that shape intact and avoid disturbing the cells
// that already worked.
async function pickClickTarget(page, canvas, app) {
  if (app.name === "task_app") {
    return {
      x: canvas.rectLeft + canvas.rectW / 2,
      y: canvas.rectTop + canvas.rectH / 2,
      source: "rect-center",
    };
  }
  const ROI_AREA = 128 * 128;
  const manifestPt = await page.evaluate((roiAreaArg) => {
    const manifests = window.__isonimManifests || [];
    if (manifests.length === 0) return null;
    const m = manifests[manifests.length - 1];
    const elements = m.elements || [];
    if (elements.length === 0) return null;
    // EMC-M4 Fix A applied here too: select the wrapper by inspecting
    // the contained CANVAS's bounding rect, not the wrapper's rect.
    const wrappers = document.querySelectorAll('[data-canvas-wrapper="true"]');
    let canvasEl = null;
    for (const w of wrappers) {
      if (getComputedStyle(w).display === "none") continue;
      const candidate = w.querySelector("canvas");
      if (!candidate) continue;
      const cr = candidate.getBoundingClientRect();
      if (cr.width > 10 && cr.height > 10) {
        canvasEl = candidate;
        break;
      }
    }
    if (!canvasEl) return null;
    const rect = canvasEl.getBoundingClientRect();
    const sx = rect.width / canvasEl.width;
    const sy = rect.height / canvasEl.height;
    const canvasArea = canvasEl.width * canvasEl.height;
    const canvasCenterX = rect.left + rect.width * 0.5;
    const canvasCenterY = rect.top + rect.height * 0.5;
    // Collect non-root candidates whose centres lie inside the canvas
    // rect AND whose area is ≥ the ROI gate. Area is computed in
    // canvas-intrinsic pixel² so the comparison with ROI² is direct.
    const candidates = [];
    for (const el of elements) {
      if (!el.bounds) continue;
      const { x, y, w, h } = el.bounds;
      if (w <= 0 || h <= 0) continue;
      const area = w * h;
      if (area >= canvasArea * 0.95) continue; // skip root
      if (area < roiAreaArg) continue; // skip too-small for ROI
      const cx = rect.left + (x + w * 0.5) * sx;
      const cy = rect.top + (y + h * 0.5) * sy;
      if (
        cx < rect.left ||
        cx > rect.left + rect.width ||
        cy < rect.top ||
        cy > rect.top + rect.height
      ) {
        continue;
      }
      const dx = cx - canvasCenterX;
      const dy = cy - canvasCenterY;
      candidates.push({ cx, cy, area, distSq: dx * dx + dy * dy });
    }
    if (candidates.length === 0) return null;
    // Closest-to-canvas-centre wins.
    let best = candidates[0];
    for (const c of candidates) {
      if (c.distSq < best.distSq) best = c;
    }
    return { x: best.cx, y: best.cy };
  }, ROI_AREA);
  if (manifestPt) {
    return {
      x: manifestPt.x,
      y: manifestPt.y,
      source: "manifest-centre-rowfit",
    };
  }
  return {
    x: canvas.rectLeft + canvas.rectW / 2,
    y: canvas.rectTop + canvas.rectH / 2,
    source: "rect-center-fallback",
  };
}

async function measureClickResponse(page, app) {
  const canvas = await findActiveCanvas(page);
  if (!canvas || !canvas.present) {
    return {
      latencyMs: Number.POSITIVE_INFINITY,
      canvasFocusOk: false,
      bodyMarkerOk: false,
      diagnostic: "no canvas",
    };
  }
  const target = await pickClickTarget(page, canvas, app);
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
      return { x, y, roi, fingerprint: `${r}/${g}/${b}/${count}` };
    },
    { cx: target.x, cy: target.y, roi: ROI },
  );

  const clickMark = await page.evaluate(() => performance.now());
  await page.mouse.click(target.x, target.y);
  const focusState = await page.evaluate(() => ({
    isCanvas:
      document.activeElement &&
      document.activeElement.tagName.toLowerCase() === "canvas",
    bodyMarker: document.body.getAttribute("data-isonim-canvas-focused"),
  }));

  const responseDeadlineMs = THRESHOLDS.clickResponseMs * 10;
  let latencyMs = Number.POSITIVE_INFINITY;
  const t0 = Date.now();
  if (roiBaseline) {
    while (Date.now() - t0 < responseDeadlineMs) {
      const sample = await page.evaluate(({ x, y, roi }) => {
        const cnv = document.querySelector('canvas[data-canvas-active="true"]');
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
          t: performance.now(),
        };
      }, roiBaseline);
      if (sample && sample.fingerprint !== roiBaseline.fingerprint) {
        latencyMs = sample.t - clickMark;
        break;
      }
      await new Promise((r) => setTimeout(r, 5));
    }
  }
  return {
    latencyMs,
    canvasFocusOk: focusState.isCanvas === true,
    bodyMarkerOk: focusState.bodyMarker === "true",
    targetSource: target.source,
  };
}

// ---------------------------------------------------------------------------
// Criterion 4: hover → overlay-update latency
// ---------------------------------------------------------------------------

async function measureHoverOverlay(page) {
  // Reinstall observer if necessary (mode/viewport switches can swap
  // the canvas wrapper DOM nodes; ETS-M6 § criterion 2 pattern).
  await page.evaluate(() => {
    try {
      if (window.__fuhM8Observer) window.__fuhM8Observer.disconnect();
    } catch (_) {}
    window.__fuhM8ObserverInstalled = false;
    window.__fuhM8LatencySamples = [];
    window.__fuhM8LastConsumedSeq = -1;

    // EMC-M4 Fix A: pick the wrapper by inspecting the CONTAINED
    // CANVAS's bounding rect (the actual paint surface), not the
    // wrapper's own rect. The wrapper rect can mismatch the paint
    // surface at narrow viewports (Phone, 390 px), causing the
    // observer to never install and the Phone hover cells to report
    // null.
    const wrappers = document.querySelectorAll('[data-canvas-wrapper="true"]');
    let visible = null;
    for (const w of wrappers) {
      if (getComputedStyle(w).display === "none") continue;
      const canvasChild = w.querySelector("canvas");
      if (!canvasChild) continue;
      const cr = canvasChild.getBoundingClientRect();
      if (cr.width > 10 && cr.height > 10) {
        visible = w;
        break;
      }
    }
    if (!visible) return;
    const hoverLabel = visible.querySelector(
      '[data-canvas-hover-label="true"]',
    );
    const selectionOutline = visible.querySelector(
      '[data-canvas-selection-outline="true"]',
    );
    if (!hoverLabel && !selectionOutline) return;
    const obs = new MutationObserver((muts) => {
      const t = performance.now();
      let anchor = "unknown";
      for (const m of muts) {
        if (m.target === hoverLabel) {
          anchor = "hover-label";
          break;
        }
        if (m.target === selectionOutline) {
          anchor = "selection-outline";
          break;
        }
      }
      const moveT = window.__fuhM8LastMouseMoveT;
      const moveSeq = window.__fuhM8LastMouseMoveSeq;
      if (moveT == null) return;
      if (window.__fuhM8LastConsumedSeq === moveSeq) return;
      window.__fuhM8LastConsumedSeq = moveSeq;
      window.__fuhM8LatencySamples.push({
        seq: moveSeq,
        moveT,
        paintT: t,
        anchor,
        domLatencyMs: t - moveT,
      });
    });
    if (hoverLabel) {
      obs.observe(hoverLabel, {
        attributes: true,
        attributeFilter: ["style"],
      });
    }
    if (selectionOutline) {
      obs.observe(selectionOutline, {
        attributes: true,
        attributeFilter: ["style"],
      });
    }
    window.__fuhM8Observer = obs;
    window.__fuhM8ObserverInstalled = true;
  });

  // Build hover targets from the manifest mirror.
  //
  // EMC-M4 Fix A. Two changes from the previous shape:
  //
  //   (i) Wrapper selection by CONTAINED CANVAS rect. The previous
  //       shape selected a visible wrapper by the wrapper's own
  //       bounding rect — but at Phone (390 px) the wrapper is
  //       narrower than the chrome layout reserved, so its rect can
  //       mismatch the actual paint surface. We now iterate wrappers
  //       and pick the first whose <canvas> child has a non-zero
  //       bounding rect (the real paint surface).
  //
  //   (ii) Rect-centre fallback target. If no manifest element passes
  //        the filter (e.g. at Phone where the manifest reports only
  //        the root element or where every element fails the
  //        centre-inside-canvas test), emit ONE hover target at the
  //        canvas centre. This guarantees the Phone hover cells
  //        produce non-null measurements — measurability is M4's
  //        success criterion per the spec brief.
  const targets = await page.evaluate(() => {
    const manifests = window.__isonimManifests || [];
    if (manifests.length === 0) return [];
    const m = manifests[manifests.length - 1];
    const wrappers = document.querySelectorAll('[data-canvas-wrapper="true"]');
    let canvasEl = null;
    for (const w of wrappers) {
      if (getComputedStyle(w).display === "none") continue;
      const candidate = w.querySelector("canvas");
      if (!candidate) continue;
      const cr = candidate.getBoundingClientRect();
      if (cr.width > 10 && cr.height > 10) {
        canvasEl = candidate;
        break;
      }
    }
    if (!canvasEl) return [];
    const rect = canvasEl.getBoundingClientRect();
    const sx = rect.width / canvasEl.width;
    const sy = rect.height / canvasEl.height;
    const canvasArea = canvasEl.width * canvasEl.height;
    const out = [];
    for (const el of m.elements || []) {
      if (!el.bounds) continue;
      const { x, y, w, h } = el.bounds;
      if (w <= 0 || h <= 0) continue;
      if (w * h >= canvasArea * 0.95) continue;
      const cx = rect.left + (x + w * 0.5) * sx;
      const cy = rect.top + (y + h * 0.5) * sy;
      if (
        cx < rect.left ||
        cx > rect.left + rect.width ||
        cy < rect.top ||
        cy > rect.top + rect.height
      ) {
        continue;
      }
      out.push({ x: cx, y: cy });
    }
    if (out.length === 0) {
      // Rect-centre fallback (Fix A (ii)). Emit a small SWEEP of
      // targets jittered around the canvas centre so the Phone hover
      // cells produce non-null measurements even when the manifest
      // mirror doesn't yield in-canvas leaves. Each successive target
      // must differ from the previous so the hover-label
      // MutationObserver fires per sample.
      const cx0 = rect.left + rect.width * 0.5;
      const cy0 = rect.top + rect.height * 0.5;
      const jitterX = Math.min(40, rect.width * 0.1);
      const jitterY = Math.min(40, rect.height * 0.1);
      out.push({ x: cx0, y: cy0 });
      out.push({ x: cx0 + jitterX, y: cy0 });
      out.push({ x: cx0, y: cy0 + jitterY });
      out.push({ x: cx0 - jitterX, y: cy0 });
      out.push({ x: cx0, y: cy0 - jitterY });
    }
    return out;
  });
  if (targets.length === 0) {
    return {
      sampleCount: 0,
      medianMs: Number.POSITIVE_INFINITY,
      p99Ms: Number.POSITIVE_INFINITY,
      diagnostic: "no hover targets",
    };
  }
  const sweep = targets.slice(0, HOVER_SAMPLE_COUNT);
  // Reseat off-canvas so the FIRST sample carries a real id change.
  await page.mouse.move(0, 0);
  await new Promise((r) => setTimeout(r, 60));
  // Warmup the path so the first sample isn't racing the WS delta.
  await page.evaluate(({ x, y }) => {
    window.__fuhM8LastMouseMoveSeq = (window.__fuhM8LastMouseMoveSeq || 0) + 1;
    window.__fuhM8LastMouseMoveT = performance.now();
    const cs = document.querySelectorAll('[data-canvas-wrapper="true"] canvas');
    for (const c of cs) {
      const rr = c.getBoundingClientRect();
      if (rr.width > 10 && rr.height > 10) {
        c.dispatchEvent(
          new MouseEvent("mousemove", {
            bubbles: true,
            clientX: x,
            clientY: y,
          }),
        );
        break;
      }
    }
  }, sweep[0]);
  await new Promise((r) => setTimeout(r, 200));
  await page.evaluate(() => {
    window.__fuhM8LatencySamples = [];
    window.__fuhM8LastConsumedSeq = -1;
  });

  // Drive successive hovers across distinct positions.
  for (const t of sweep) {
    await page.evaluate(({ x, y }) => {
      window.__fuhM8LastMouseMoveSeq =
        (window.__fuhM8LastMouseMoveSeq || 0) + 1;
      window.__fuhM8LastMouseMoveT = performance.now();
      const cs = document.querySelectorAll(
        '[data-canvas-wrapper="true"] canvas',
      );
      for (const c of cs) {
        const rr = c.getBoundingClientRect();
        if (rr.width > 10 && rr.height > 10) {
          c.dispatchEvent(
            new MouseEvent("mousemove", {
              bubbles: true,
              clientX: x,
              clientY: y,
            }),
          );
          break;
        }
      }
    }, t);
    await new Promise((r) => setTimeout(r, 120));
  }
  const samples = await page.evaluate(() => window.__fuhM8LatencySamples || []);
  const latencies = samples
    .filter((s) => s.anchor === "hover-label")
    .map((s) => s.domLatencyMs)
    .filter((v) => typeof v === "number" && Number.isFinite(v) && v >= 0);
  return {
    sampleCount: latencies.length,
    medianMs: median(latencies) ?? Number.POSITIVE_INFINITY,
    p99Ms: p99(latencies) ?? Number.POSITIVE_INFINITY,
    diagnostic: latencies.length === 0 ? "no hover-label samples captured" : "",
  };
}

// ---------------------------------------------------------------------------
// Criterion 5: DPR contract
// ---------------------------------------------------------------------------

async function measureDpr(page) {
  const c = await findActiveCanvas(page);
  if (!c || !c.present) {
    return {
      driftWpx: Number.POSITIVE_INFINITY,
      driftHpx: Number.POSITIVE_INFINITY,
      diagnostic: "no canvas",
    };
  }
  return {
    intrinsicW: c.intrinsicW,
    intrinsicH: c.intrinsicH,
    rectW: c.rectW,
    rectH: c.rectH,
    dpr: c.dpr,
    driftWpx: Math.abs(c.rectW * c.dpr - c.intrinsicW),
    driftHpx: Math.abs(c.rectH * c.dpr - c.intrinsicH),
  };
}

// ---------------------------------------------------------------------------
// Criterion 6: lossless contract (cocoa/webp only) — canvas-side proxy
// ---------------------------------------------------------------------------

async function measureLossless(page) {
  return page.evaluate(() => {
    const cnv = document.querySelector('canvas[data-canvas-active="true"]');
    if (!cnv || cnv.width === 0 || cnv.height === 0) {
      return {
        uniqueColors: 0,
        nonGreyCount: 0,
        sampledCount: 0,
        nonGreyRatio: 0,
        diagnostic: "no canvas / zero-sized",
      };
    }
    const cctx = cnv.getContext("2d");
    if (!cctx) {
      return {
        uniqueColors: 0,
        nonGreyCount: 0,
        sampledCount: 0,
        nonGreyRatio: 0,
        diagnostic: "no 2d ctx",
      };
    }
    // Sample every Nth pixel up to 16 samples across the canvas. The
    // ELT-M9 proxy samples a coarse grid; we use a 4x4 grid here.
    const samples = [];
    for (let row = 0; row < 4; row++) {
      for (let col = 0; col < 4; col++) {
        const x = Math.floor(((col + 0.5) / 4) * cnv.width);
        const y = Math.floor(((row + 0.5) / 4) * cnv.height);
        try {
          const img = cctx.getImageData(x, y, 1, 1);
          samples.push({ r: img.data[0], g: img.data[1], b: img.data[2] });
        } catch (_) {}
      }
    }
    const colorSet = new Set();
    let nonGrey = 0;
    for (const s of samples) {
      colorSet.add(`${s.r},${s.g},${s.b}`);
      // Placeholder grey is 0x18 = 24. Anything non-grey-ish counts.
      const isPlaceholder = s.r === 0x18 && s.g === 0x18 && s.b === 0x18;
      const isGreyish =
        Math.abs(s.r - s.g) < 4 &&
        Math.abs(s.g - s.b) < 4 &&
        Math.abs(s.r - s.b) < 4;
      if (!isPlaceholder && !isGreyish) nonGrey++;
    }
    return {
      uniqueColors: colorSet.size,
      nonGreyCount: nonGrey,
      sampledCount: samples.length,
      nonGreyRatio: samples.length > 0 ? nonGrey / samples.length : 0,
      diagnostic: "",
    };
  });
}

// ---------------------------------------------------------------------------
// Per-cell runner
// ---------------------------------------------------------------------------

async function runCell(cell) {
  const measurements = {
    backend: cell.backend.name,
    app: cell.app.name,
    viewport: cell.viewport.name,
    expectedTransport: cell.backend.expectedTransport,
    transportSettled: false,
    settledTransport: "",
    pickedStory: "",
    storyPickFailed: false,
    diagnostic: "",
  };
  const criteria = {
    frameLatencyMs: {
      measured: null,
      threshold: THRESHOLDS.medianFrameLatencyMs,
      pass: null,
      na: false,
      note: "",
    },
    idleBandwidthBytes: {
      measured: null,
      threshold: THRESHOLDS.idleMedianPacketBytes,
      pass: null,
      na: false,
      note: "",
    },
    clickResponseMs: {
      measured: null,
      threshold: THRESHOLDS.clickResponseMs,
      pass: null,
      na: false,
      note: "",
    },
    hoverOverlayMs: {
      measured: null,
      threshold: THRESHOLDS.hoverOverlayMs,
      pass: null,
      na: false,
      note: "",
    },
    dprDriftPx: {
      measured: null,
      threshold: THRESHOLDS.dprDriftPx,
      pass: null,
      na: false,
      note: "",
    },
    losslessUniqueColors: {
      measured: null,
      threshold: THRESHOLDS.losslessMinUniqueColors,
      pass: null,
      na: false,
      note: "",
    },
  };

  if (!cell.backend.measuresBandwidth) {
    criteria.idleBandwidthBytes.na = true;
    criteria.idleBandwidthBytes.pass = true;
    criteria.idleBandwidthBytes.note = "N/A (raw_rgba transport)";
  }
  if (!cell.backend.measuresLossless) {
    criteria.losslessUniqueColors.na = true;
    criteria.losslessUniqueColors.pass = true;
    criteria.losslessUniqueColors.note = "N/A (raw_rgba transport)";
  }

  const launcherPort = await pickFreePort();
  const editorPort = await pickFreePort();
  let launcher = null;
  let proxy = null;
  let ctx = null;
  try {
    launcher = await spawnLauncher(
      cell.backend,
      cell.app,
      cell.viewport,
      launcherPort,
    );
    proxy = await startEditorProxy(editorPort, launcherPort, cell.backend.name);
    const opened = await openEditor(editorPort, cell.viewport);
    ctx = opened.ctx;
    const page = opened.page;

    await page.evaluate(() => {
      window.__isonimTestMode = true;
      window.__isonimManifests = [];
      window.__isonimElementTreeDeltas = [];
      window.__isonimWDiffRectCounts = [];
      window.__isonimWDiffByteLengths = [];
    });

    const picked = await pickBackend(page, cell.backend, cell.app);
    measurements.pickedStory = picked || "";
    measurements.storyPickFailed = picked == null;

    measurements.transportSettled = await waitFor(async () => {
      const v = await page.evaluate(
        () => document.body.dataset.isonimActiveTransport || "",
      );
      measurements.settledTransport = v;
      return v === cell.backend.expectedTransport;
    }, TRANSPORT_SETTLE_MS);

    if (!measurements.transportSettled) {
      measurements.diagnostic = `transport never settled on ${cell.backend.expectedTransport} (last="${measurements.settledTransport}")`;
      // Skip downstream criteria — all will report unmeasured.
      return { cell, measurements, criteria };
    }

    // Pick viewport pill so canvas renders at expected dims.
    const pillPicked = await pickViewportPill(page, cell.viewport.slug);
    if (!pillPicked) {
      measurements.diagnostic += ` viewport-pill "${cell.viewport.slug}" not found;`;
    } else {
      await new Promise((r) => setTimeout(r, 1200));
      await waitFor(async () => {
        return page.evaluate(
          ({ expectedWidth }) => {
            const cs = document.querySelectorAll(
              '[data-canvas-wrapper="true"] canvas',
            );
            for (const c of cs) {
              const r = c.getBoundingClientRect();
              if (r.width > 10 && r.height > 10) {
                const ratio = c.width / expectedWidth;
                if (ratio > 0.5 && ratio < 3.5) return true;
              }
            }
            return false;
          },
          { expectedWidth: cell.viewport.width },
        );
      }, 6000);
    }

    // Wait briefly for a manifest to arrive (used by criteria 3 + 4).
    await waitFor(async () => {
      const n = await page.evaluate(
        () => (window.__isonimManifests || []).length,
      );
      return n > 0;
    }, 5000);

    // ---- Criterion 5: DPR (cheap; do first) ----
    const dpr = await measureDpr(page);
    criteria.dprDriftPx.measured = Math.max(dpr.driftWpx, dpr.driftHpx);
    criteria.dprDriftPx.note = `drift w=${dpr.driftWpx?.toFixed(2)}px h=${dpr.driftHpx?.toFixed(2)}px (intrinsic=${dpr.intrinsicW}x${dpr.intrinsicH}, rect=${dpr.rectW?.toFixed(1)}x${dpr.rectH?.toFixed(1)}, dpr=${dpr.dpr})`;
    criteria.dprDriftPx.pass =
      Number.isFinite(criteria.dprDriftPx.measured) &&
      criteria.dprDriftPx.measured <= THRESHOLDS.dprDriftPx;

    // ---- Criterion 6: lossless ----
    if (!criteria.losslessUniqueColors.na) {
      const lossless = await measureLossless(page);
      criteria.losslessUniqueColors.measured = lossless.uniqueColors;
      criteria.losslessUniqueColors.note =
        `uniqueColors=${lossless.uniqueColors}, nonGrey=${lossless.nonGreyCount}/${lossless.sampledCount} ` +
        `(ratio=${lossless.nonGreyRatio?.toFixed(3)}; gate ${THRESHOLDS.losslessMinNonGreyRatio.toFixed(3)})${lossless.diagnostic ? " — " + lossless.diagnostic : ""}`;
      criteria.losslessUniqueColors.pass =
        lossless.uniqueColors >= THRESHOLDS.losslessMinUniqueColors &&
        lossless.nonGreyRatio > THRESHOLDS.losslessMinNonGreyRatio;
    }

    // ---- Criterion 3: click response ----
    const click = await measureClickResponse(page, cell.app);
    criteria.clickResponseMs.measured = click.latencyMs;
    criteria.clickResponseMs.note =
      `target=${click.targetSource} focusOk=${click.canvasFocusOk} bodyMarker=${click.bodyMarkerOk}` +
      (click.diagnostic ? ` — ${click.diagnostic}` : "");
    criteria.clickResponseMs.pass =
      Number.isFinite(click.latencyMs) &&
      click.latencyMs <= THRESHOLDS.clickResponseMs;

    // ---- Criterion 4: hover → overlay-update ----
    const hover = await measureHoverOverlay(page);
    criteria.hoverOverlayMs.measured = hover.medianMs;
    criteria.hoverOverlayMs.note =
      `samples=${hover.sampleCount} p99=${Number.isFinite(hover.p99Ms) ? hover.p99Ms.toFixed(1) + "ms" : "<inf>"}` +
      (hover.diagnostic ? ` — ${hover.diagnostic}` : "");
    criteria.hoverOverlayMs.pass =
      hover.sampleCount > 0 &&
      Number.isFinite(hover.medianMs) &&
      hover.medianMs <= THRESHOLDS.hoverOverlayMs;

    // ---- Criterion 2: idle bandwidth ----
    if (!criteria.idleBandwidthBytes.na) {
      const idle = await measureIdleBandwidth(page);
      criteria.idleBandwidthBytes.measured = idle.medianBytes;
      criteria.idleBandwidthBytes.note =
        `packets=${idle.packetCount} heartbeats=${idle.heartbeatCount} ` +
        `nonZero=${idle.nonZeroCount} max=${idle.maxBytes}B`;
      criteria.idleBandwidthBytes.pass =
        idle.packetCount > 0 &&
        Number.isFinite(idle.medianBytes) &&
        idle.medianBytes <= THRESHOLDS.idleMedianPacketBytes;
    }

    // ---- Criterion 1: frame latency (LAST so prior activity doesn't pollute) ----
    const latency = await measureMedianFrameLatency(page);
    criteria.frameLatencyMs.measured = latency.medianMs;
    criteria.frameLatencyMs.note =
      `samples=${latency.collectedCount} p99=${Number.isFinite(latency.p99Ms) ? latency.p99Ms.toFixed(2) + "ms" : "<inf>"} ` +
      (latency.settled ? "" : "(did not settle)");
    criteria.frameLatencyMs.pass =
      latency.settled &&
      Number.isFinite(latency.medianMs) &&
      latency.medianMs <= THRESHOLDS.medianFrameLatencyMs;
  } catch (e) {
    measurements.diagnostic += ` exception: ${e && e.stack ? e.stack : String(e)};`;
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
  return { cell, measurements, criteria };
}

function verdictForCell(criteria) {
  let allPass = true;
  for (const k of Object.keys(criteria)) {
    if (criteria[k].pass !== true) {
      allPass = false;
      break;
    }
  }
  return allPass ? "pass" : "fail";
}

// ---------------------------------------------------------------------------
// Test harness
// ---------------------------------------------------------------------------

const allResults = [];

test.before(async () => {
  if (!isMacOS) return;
  buildAll();
  mkdirSync(goldenDir, { recursive: true });
});

test.after(async () => {
  try {
    if (browser) await browser.close();
  } catch (_) {}
});

test("FUH-M8 full editor acceptance matrix", async (t) => {
  if (!isMacOS) {
    t.skip(SKIP_REASON);
    return;
  }

  let specCommit = "";
  try {
    specCommit = exec("git rev-parse HEAD", { cwd: isonimRoot }).trim();
  } catch (_) {}

  for (const cell of MATRIX) {
    await t.test(cellLabel(cell), async () => {
      const result = await runCell(cell);
      const verdict = verdictForCell(result.criteria);
      const cellRow = {
        backend: cell.backend.name,
        app: cell.app.name,
        viewport: cell.viewport.name,
        measurements: result.measurements,
        criteria: result.criteria,
        verdict,
      };
      allResults.push(cellRow);
      process.stderr.write(
        `[FUH-M8] ${cellLabel(cell)} verdict=${verdict} ` +
          `frame=${formatCriterion(result.criteria.frameLatencyMs)} ` +
          `idle=${formatCriterion(result.criteria.idleBandwidthBytes)} ` +
          `click=${formatCriterion(result.criteria.clickResponseMs)} ` +
          `hover=${formatCriterion(result.criteria.hoverOverlayMs)} ` +
          `dpr=${formatCriterion(result.criteria.dprDriftPx)} ` +
          `lossless=${formatCriterion(result.criteria.losslessUniqueColors)}\n`,
      );
    });
  }

  const timestamp = new Date().toISOString();
  const report = {
    campaign: "FUH-M8",
    timestamp,
    specCommit,
    platform: `${process.platform}-${process.arch}`,
    thresholds: { ...THRESHOLDS },
    cells: allResults,
  };
  const tsSafe = timestamp.replace(/[:.]/g, "-");
  const outPath = join(goldenDir, `${tsSafe}.json`);
  writeFileSync(outPath, JSON.stringify(report, null, 2));
  writeFileSync(
    join(goldenDir, "latest.json"),
    JSON.stringify(report, null, 2),
  );
  process.stderr.write(`[FUH-M8] wrote ${outPath}\n`);

  // Final honest assertion: per-cell verdicts. We do NOT stop on the
  // first failure — the campaign brief is explicit that the matrix
  // closes by measurement.
  const failingCells = allResults.filter((r) => r.verdict !== "pass");
  if (failingCells.length > 0) {
    const lines = [];
    for (const cell of failingCells) {
      const fails = [];
      for (const [k, v] of Object.entries(cell.criteria)) {
        if (v.pass !== true && !v.na) {
          fails.push(
            `${k}: measured=${formatMeasured(v.measured)} threshold=${v.threshold} ` +
              `(${v.note || "no note"})`,
          );
        }
      }
      lines.push(
        `  [${cell.backend}/${cell.app}/${cell.viewport}]` +
          (fails.length > 0 ? `\n    - ${fails.join("\n    - ")}` : ""),
      );
    }
    assert.fail(
      `FUH-M8 — ${failingCells.length}/${allResults.length} cells failed honestly:\n${lines.join("\n")}\n\nFull report at ${outPath}`,
    );
  }
});

function formatCriterion(c) {
  if (c.na) return "n/a";
  if (c.pass === true) return `pass(${formatMeasured(c.measured)})`;
  if (c.pass === false) return `FAIL(${formatMeasured(c.measured)})`;
  return `?(${formatMeasured(c.measured)})`;
}

function formatMeasured(v) {
  if (v == null) return "null";
  if (typeof v === "number") {
    if (!Number.isFinite(v)) return "inf";
    return v.toFixed(2);
  }
  return String(v);
}
