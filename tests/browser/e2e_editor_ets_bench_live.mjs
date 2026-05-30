// ETS-M5 — bandwidth + latency bench comparing the legacy element-tree
// full-body M-subtype against the new element-tree-delta M-subtype.
//
// Methodology:
//
//   * Spawn the REAL cocoa launcher (same boot path as the ETS-M4 +
//     EPP-M6 + ELT-M9 e2e tests). No synthetic generators in the bench
//     loop. The launcher's bridge naturally negotiates which wire path
//     to use based on the editor's hello-accept M packet (see ETS-M2
//     `helloAcceptAcceptsElementTreeDelta` in bridge.nim).
//   * Wrap the page's WebSocket BEFORE the editor's IIFE attaches so we
//     can:
//       a) Mirror every inbound 'M' packet's wire length + arrival
//          timestamp into `window.__etsM5Wire[]`. This is the
//          authoritative bytes-on-the-wire mirror — it's the JSON body
//          length plus the 5-byte M packet header that the browser
//          receives, NOT the post-decode object size.
//       b) Inject a path selector by rewriting the outbound hello-accept
//          M body to either include or strip the ``e/element-tree``
//          token. The launcher then flips its per-tick re-emit to the
//          delta sub-kind or stays on the legacy full-body accordingly.
//   * Run a fixed measurement matrix per path:
//       1. Idle UI         — 5 s settle, count wire bytes/sec + packets/sec.
//       2. Hover sweep     — move the mouse across N=10 known element
//                            positions over ~2 s. Per move, capture
//                            mousemove→overlay-style-mutation latency +
//                            mousemove→next requestAnimationFrame latency.
//       3. Mass edit       — toggle the filter pill (which re-styles
//                            every row's active state). Capture the
//                            resulting M packet's wire size + op count.
//       4. Resize          — click a viewport pill (changes the entire
//                            tree's bbox space). Capture first-paint
//                            latency after the resize.
//       5. Scroll-equiv    — drive a sustained mousemove burst (the
//                            example apps don't expose a long scrollable
//                            list; sustained hover is the closest
//                            proxy that triggers layout-touching style
//                            updates per tick).
//   * Write results to `tests/browser/golden/ets-m5/<timestamp>.json`.
//   * The bench is intentionally READ-ONLY against the production
//     stream — no editor source changes, no launcher patches.
//
// Skip rule: macOS-only — the cocoa launcher only builds on Darwin
// (the helper ``capture_videotoolbox.m`` compiles only on macOS).

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
const editorBuildDir = join(isonimExamplesRoot, "build", "editor");
const cocoaLauncherBin = join(
  isonimExamplesRoot,
  "build",
  "backends",
  "isonim-examples-cocoa",
);
const goldenDir = join(__dirname, "golden", "ets-m5");

const LAUNCHER_BACKEND = "cocoa";
const isMacOS = process.platform === "darwin";

function exec(cmd, opts = {}) {
  return execSync(cmd, { stdio: "pipe", ...opts }).toString();
}

function buildEditorAndCocoa() {
  exec("direnv exec . just editor-build", { cwd: isonimExamplesRoot });
  exec("direnv exec . just build-backends-macos", {
    cwd: isonimExamplesRoot,
  });
  if (!existsSync(join(editorBuildDir, "editor.js"))) {
    throw new Error("editor.js was not produced by `just editor-build`");
  }
  if (!existsSync(cocoaLauncherBin)) {
    throw new Error(
      `cocoa launcher binary missing: ${cocoaLauncherBin} — ` +
        "did `just build-backends-macos` succeed?",
    );
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

async function spawnCocoaLauncher(port) {
  const proc = spawn(
    cocoaLauncherBin,
    [
      "--port",
      String(port),
      "--demo",
      "task",
      "--width",
      "390",
      "--height",
      "844",
      "--fps",
      "30",
      "--encoder",
      "webp",
    ],
    {
      cwd: isonimExamplesRoot,
      env: { ...process.env },
      stdio: ["ignore", "pipe", "pipe"],
    },
  );
  const tag = `[cocoa-ets-bench]`;
  proc.stderr.on("data", (b) => process.stderr.write(`${tag} ${b}`));
  proc.stdout.on("data", (b) => process.stderr.write(`${tag} ${b}`));
  await new Promise((resolve, reject) => {
    const deadline = Date.now() + 15000;
    const tick = () => {
      if (Date.now() > deadline) {
        reject(new Error(`cocoa launcher failed to bind in 15s`));
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

async function startEditorProxy(serverPort, launcherPort) {
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
    if (!url.startsWith(`/bridge/${LAUNCHER_BACKEND}`)) {
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
    upstream.on("error", () => clientSocket.destroy());
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

// `path` selector. Two values:
//   "delta"  — default editor advertises ``e/element-tree``; launcher
//              flips to ``element-tree-delta`` M-subtype.
//   "legacy" — outbound hello-accept rewritten to strip
//              ``e/element-tree`` so the launcher stays on the legacy
//              full-body ``element-tree`` M-subtype.
//
// Both paths use the SAME wire-byte mirror so the bytes/sec column is
// apples-to-apples.
async function openEditorAgainst(serverPort, { path }) {
  const b = await ensureBrowser();
  const ctx = await b.newContext({ viewport: { width: 1440, height: 900 } });
  const page = await ctx.newPage();
  page.on("pageerror", (e) => console.error("[page] error:", e.message));

  // Install the WS wrapper BEFORE the editor's IIFE attaches. We mirror
  // every inbound 'M' packet (kind byte, wire byte length, timestamp,
  // JSON-decoded type tag for bucketing) into window.__etsM5Wire. We
  // also gate the outbound hello-accept on `path === "legacy"` by
  // stripping ``e/element-tree`` from the accept list.
  const forceLegacy = path === "legacy";
  await ctx.addInitScript((forceLegacyArg) => {
    try {
      window.__etsM5Wire = [];
      window.__etsM5T0 = performance.now();
      window.__etsM5ForceLegacy = !!forceLegacyArg;

      const RealWS = window.WebSocket;
      function WrappedWS(url, protocols) {
        const ws = protocols ? new RealWS(url, protocols) : new RealWS(url);
        const origSend = ws.send.bind(ws);
        ws.send = function (data) {
          try {
            // Outbound hello-accept gate: rewrite the M body to strip
            // ``e/element-tree`` when the test is forcing the legacy
            // path. The editor's hello-accept is the FIRST 'M' packet
            // shipped after WS-OPEN (streaming_preview.nim:1136). We
            // identify by 'M' kind + ``"type":"hello"`` body.
            if (window.__etsM5ForceLegacy && data && data.byteLength >= 5) {
              const view = new Uint8Array(
                data.buffer || data,
                data.byteOffset || 0,
                data.byteLength,
              );
              if (view[0] === 0x4d /* 'M' */) {
                const bodyLen =
                  view[1] | (view[2] << 8) | (view[3] << 16) | (view[4] << 24);
                const bodyBytes = view.subarray(5, 5 + bodyLen);
                let body = "";
                try {
                  body = new TextDecoder("utf-8").decode(bodyBytes);
                } catch (_) {}
                if (
                  body.indexOf('"type":"hello"') >= 0 &&
                  body.indexOf("e/element-tree") >= 0
                ) {
                  try {
                    const obj = JSON.parse(body);
                    if (Array.isArray(obj.accept)) {
                      obj.accept = obj.accept.filter(
                        (t) => t !== "e/element-tree",
                      );
                    }
                    const newBody = JSON.stringify(obj);
                    const enc = new TextEncoder().encode(newBody);
                    const buf = new Uint8Array(5 + enc.length);
                    buf[0] = 0x4d;
                    buf[1] = enc.length & 0xff;
                    buf[2] = (enc.length >>> 8) & 0xff;
                    buf[3] = (enc.length >>> 16) & 0xff;
                    buf[4] = (enc.length >>> 24) & 0xff;
                    buf.set(enc, 5);
                    return origSend(buf);
                  } catch (_) {}
                }
              }
            }
          } catch (_) {}
          return origSend(data);
        };

        ws.addEventListener("message", function (e) {
          try {
            if (!(e.data instanceof ArrayBuffer)) return;
            const bytes = new Uint8Array(e.data);
            if (bytes.length === 0) return;
            const kind = String.fromCharCode(bytes[0]);
            let typeTag = null;
            if (kind === "M" && bytes.length >= 5) {
              const bodyLen =
                bytes[1] |
                (bytes[2] << 8) |
                (bytes[3] << 16) |
                (bytes[4] << 24);
              try {
                const body = new TextDecoder("utf-8").decode(
                  bytes.subarray(5, 5 + bodyLen),
                );
                // Cheap probe; we only need the ``"type":"..."`` tag.
                const m = body.match(/"type"\s*:\s*"([^"]+)"/);
                if (m) typeTag = m[1];
              } catch (_) {}
            }
            window.__etsM5Wire.push({
              kind,
              bytes: bytes.length,
              t: performance.now(),
              type: typeTag,
            });
          } catch (_) {}
        });
        return ws;
      }
      WrappedWS.prototype = RealWS.prototype;
      WrappedWS.CONNECTING = RealWS.CONNECTING;
      WrappedWS.OPEN = RealWS.OPEN;
      WrappedWS.CLOSING = RealWS.CLOSING;
      WrappedWS.CLOSED = RealWS.CLOSED;
      window.WebSocket = WrappedWS;
    } catch (_) {}
  }, forceLegacy);

  // Install hover-label / selection-outline mutation observer + a
  // mousemove timestamp probe for latency. We watch the inline style
  // attribute on the hover label (which the overlay effect writes
  // every time the manifest signal fires for the hovered id) and
  // the selection outline (for click latency, not used in this bench
  // but kept for diagnostic parity).
  await ctx.addInitScript(() => {
    try {
      window.__etsM5LatencySamples = [];
      window.__etsM5LastMouseMoveT = null;
      window.__etsM5LastMouseMoveSeq = 0;

      function installObserverOnce() {
        if (window.__etsM5ObserverInstalled) return;
        // Watch BOTH the hover-label (positioning on hover) and the
        // selection-outline (positioning on select / re-position on
        // manifest re-emit). The hover label is the campaign's
        // user-visible promise — the outline is a secondary anchor
        // when the hover sequence didn't land on a recognised
        // element.
        const hoverLabel = document.querySelector(
          '[data-canvas-hover-label="true"]',
        );
        const selectionOutline = document.querySelector(
          '[data-canvas-selection-outline="true"]',
        );
        if (!hoverLabel && !selectionOutline) return;
        window.__etsM5ObserverInstalled = true;

        function record(t, anchor) {
          // Snapshot the move anchor LOCALLY so a subsequent
          // mousemove doesn't poison the rAF latency calc.
          const moveT = window.__etsM5LastMouseMoveT;
          const moveSeq = window.__etsM5LastMouseMoveSeq;
          if (moveT == null) return;
          if (window.__etsM5LastConsumedSeq === moveSeq) return;
          window.__etsM5LastConsumedSeq = moveSeq;
          const sample = {
            seq: moveSeq,
            moveT: moveT,
            paintT: t,
            anchor: anchor,
            domLatencyMs: t - moveT,
          };
          window.__etsM5LatencySamples.push(sample);
          // Capture moveT into the closure so the rAF callback
          // measures from THIS sample's moveT, not the global.
          const localMoveT = moveT;
          const localSeq = moveSeq;
          requestAnimationFrame((rafT) => {
            const idx = window.__etsM5LatencySamples.findIndex(
              (s) => s.seq === localSeq,
            );
            if (idx >= 0) {
              window.__etsM5LatencySamples[idx].rafT = rafT;
              window.__etsM5LatencySamples[idx].rafLatencyMs =
                rafT - localMoveT;
            }
          });
        }

        const observer = new MutationObserver((muts) => {
          const t = performance.now();
          // Determine which anchor mutated — both write to ``style``.
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
          record(t, anchor);
        });
        if (hoverLabel) {
          observer.observe(hoverLabel, {
            attributes: true,
            attributeFilter: ["style"],
          });
        }
        if (selectionOutline) {
          observer.observe(selectionOutline, {
            attributes: true,
            attributeFilter: ["style"],
          });
        }
        window.__etsM5HoverObserver = observer;
      }

      const tryInstall = setInterval(() => {
        installObserverOnce();
        if (window.__etsM5ObserverInstalled) clearInterval(tryInstall);
      }, 50);
      setTimeout(() => clearInterval(tryInstall), 30000);
    } catch (_) {}
  });

  await page.goto(`http://127.0.0.1:${serverPort}/index.html`);
  await page.waitForSelector('[data-preview-chrome-bar="true"]', {
    timeout: 15000,
  });
  await page.waitForSelector(
    '[data-toolbar-cluster="backend"] [data-choice-group-pill]',
    { timeout: 15000 },
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

async function pickCocoa(page) {
  const sel = await backendPillSelector(page, "cocoa");
  assert.ok(sel, "Cocoa backend pill should be present");
  await page.locator(sel).click();
  await page.evaluate(() => {
    const row = document.querySelector("[data-story-row]");
    if (row) row.click();
  });
}

async function waitFor(predicate, ms = 30000, intervalMs = 100) {
  const t0 = Date.now();
  while (Date.now() - t0 < ms) {
    if (await predicate()) return true;
    await new Promise((r) => setTimeout(r, intervalMs));
  }
  return false;
}

function aggregate(samples, key) {
  if (samples.length === 0) return null;
  const sorted = samples
    .map((s) => s[key])
    .filter((v) => typeof v === "number" && Number.isFinite(v))
    .sort((a, b) => a - b);
  if (sorted.length === 0) return null;
  const sum = sorted.reduce((a, b) => a + b, 0);
  const mean = sum / sorted.length;
  const p50 = sorted[Math.floor(sorted.length * 0.5)];
  const p99 =
    sorted[Math.min(sorted.length - 1, Math.floor(sorted.length * 0.99))];
  const max = sorted[sorted.length - 1];
  const min = sorted[0];
  return { n: sorted.length, mean, p50, p99, max, min };
}

// Collect the wire mirror, bucketing by type tag and computing
// per-second totals over the elapsed window. We compute elapsedMs
// from wall-clock t0/t1 captured around the call site so that page
// navigation / context recreation can't corrupt the window.
async function collectWireWindow(page, sinceT, wallClockNowMs) {
  return page.evaluate(
    ({ sinceTArg, wallElapsedMs }) => {
      const all = (window.__etsM5Wire || []).filter((w) => w.t >= sinceTArg);
      const buckets = {};
      let totalBytes = 0;
      let totalPackets = 0;
      for (const w of all) {
        const k = w.type || w.kind;
        if (!buckets[k]) {
          buckets[k] = { bytes: 0, count: 0, sizes: [] };
        }
        buckets[k].bytes += w.bytes;
        buckets[k].count += 1;
        buckets[k].sizes.push(w.bytes);
        totalBytes += w.bytes;
        totalPackets += 1;
      }
      const elapsedMs = wallElapsedMs;
      return {
        elapsedMs,
        totalBytes,
        totalPackets,
        buckets,
        // Subset relevant to ETS — element-tree (legacy) + element-tree-delta.
        etsBytes:
          ((buckets["element-tree"] || {}).bytes || 0) +
          ((buckets["element-tree-delta"] || {}).bytes || 0),
        etsPackets:
          ((buckets["element-tree"] || {}).count || 0) +
          ((buckets["element-tree-delta"] || {}).count || 0),
        legacyBytes: (buckets["element-tree"] || {}).bytes || 0,
        legacyPackets: (buckets["element-tree"] || {}).count || 0,
        deltaBytes: (buckets["element-tree-delta"] || {}).bytes || 0,
        deltaPackets: (buckets["element-tree-delta"] || {}).count || 0,
        legacySizes: (buckets["element-tree"] || {}).sizes || [],
        deltaSizes: (buckets["element-tree-delta"] || {}).sizes || [],
      };
    },
    { sinceTArg: sinceT, wallElapsedMs: wallClockNowMs },
  );
}

function summariseSizes(sizes) {
  if (!sizes || sizes.length === 0) return null;
  const sorted = [...sizes].sort((a, b) => a - b);
  const sum = sorted.reduce((a, b) => a + b, 0);
  return {
    n: sorted.length,
    mean: sum / sorted.length,
    p50: sorted[Math.floor(sorted.length * 0.5)],
    p99: sorted[Math.min(sorted.length - 1, Math.floor(sorted.length * 0.99))],
    min: sorted[0],
    max: sorted[sorted.length - 1],
    totalBytes: sum,
  };
}

// Drive a hover sweep across N=10 positions across the canvas. We
// timestamp each mousemove from inside the page (consistent with the
// MutationObserver clock); the observer records the first overlay
// style mutation that follows each mousemove.
async function runHoverSweep(page, n = 10, durationMs = 2000) {
  const canvasRect = await page.evaluate(() => {
    // Pick the FIRST visible canvas — there may be multiple
    // [data-canvas-wrapper] roots when the preview surface has been
    // mounted for several backends; only the active one is non-hidden.
    const canvases = document.querySelectorAll(
      '[data-canvas-wrapper="true"] canvas',
    );
    let el = null;
    for (const c of canvases) {
      const rr = c.getBoundingClientRect();
      if (rr.width > 10 && rr.height > 10) {
        el = c;
        break;
      }
    }
    if (!el) return null;
    const r = el.getBoundingClientRect();
    return { left: r.left, top: r.top, w: r.width, h: r.height };
  });
  if (!canvasRect || canvasRect.w === 0) return null;
  const positions = [];
  // Sweep down the canvas's vertical axis to land on different task
  // rows. The task_app's manifest reports 9 element entries on a
  // 390x844 native window; rows are stacked vertically. Sweeping in Y
  // (with X centred) hits a different row's bbox per step, so each
  // mousemove produces a real hover-id transition (the audit § 1.5
  // stable-id invariant means each row has a distinct path).
  for (let i = 0; i < n; i++) {
    const fy = 0.1 + (0.85 * (i + 0.5)) / n;
    positions.push({
      x: canvasRect.left + canvasRect.w * 0.5,
      y: canvasRect.top + canvasRect.h * fy,
    });
  }
  // Drive moves. Strategy:
  //   1. In evaluate, bump moveSeq + capture moveT and synchronously
  //      dispatch a real ``mousemove`` MouseEvent on the canvas. The
  //      canvas's production handler (streaming_preview.nim:1714) runs
  //      synchronously and calls ``onHover`` which writes
  //      ``hoveredElementId.val`` — that signal write fires the
  //      reactive ``bindCanvasOverlayEffect`` which mutates the
  //      hover-label inline style. The MutationObserver then captures
  //      the style change in the same microtask.
  //   2. We use the SYNTHETIC dispatch (not playwright's
  //      ``page.mouse.move``) for the timing anchor because the
  //      synthetic event runs in the same task as the moveT capture —
  //      no CDP round-trip race with the next iteration's moveT.
  const stepMs = Math.floor(durationMs / n);
  for (const p of positions) {
    await page.evaluate(({ x, y }) => {
      window.__etsM5LastMouseMoveSeq =
        (window.__etsM5LastMouseMoveSeq || 0) + 1;
      window.__etsM5LastMouseMoveT = performance.now();
      // Target the visible canvas (matches detectVisibleCanvas).
      let canvas = null;
      const cs = document.querySelectorAll(
        '[data-canvas-wrapper="true"] canvas',
      );
      for (const c of cs) {
        const rr = c.getBoundingClientRect();
        if (rr.width > 10 && rr.height > 10) {
          canvas = c;
          break;
        }
      }
      if (canvas) {
        const ev = new MouseEvent("mousemove", {
          bubbles: true,
          clientX: x,
          clientY: y,
        });
        canvas.dispatchEvent(ev);
      }
    }, p);
    await new Promise((r) => setTimeout(r, stepMs));
  }
}

// Drive a state mutation that touches many elements at once. The
// editor mode pill is purely client-side (no launcher mutation), so
// we drive a real launcher-side mutation by dispatching a canvas
// click at a button-bearing region — the task_app's "add task" /
// "toggle filter" / "select row" affordances all live inside the
// rendered canvas. The launcher's input adapter resolves the click
// through `hitTestPath` and dispatches it to the task_app's onClick
// handlers, which mutate state.
//
// We don't know the exact button positions on the cocoa task_app
// surface; we drive 3 successive clicks at distinct canvas regions
// to maximise the chance of landing on an interactive element.
async function runMassEdit(page) {
  const canvasRect = await page.evaluate(() => {
    const cs = document.querySelectorAll('[data-canvas-wrapper="true"] canvas');
    for (const c of cs) {
      const r = c.getBoundingClientRect();
      if (r.width > 10 && r.height > 10) {
        return { left: r.left, top: r.top, w: r.width, h: r.height };
      }
    }
    return null;
  });
  if (!canvasRect) return null;
  const positions = [
    // Centred horizontally, three vertical bands targeting top-bar
    // (where add/filter buttons typically live), middle row, and
    // bottom-bar (footer / summary).
    {
      x: canvasRect.left + canvasRect.w * 0.5,
      y: canvasRect.top + canvasRect.h * 0.12,
    },
    {
      x: canvasRect.left + canvasRect.w * 0.5,
      y: canvasRect.top + canvasRect.h * 0.45,
    },
    {
      x: canvasRect.left + canvasRect.w * 0.5,
      y: canvasRect.top + canvasRect.h * 0.85,
    },
  ];
  for (const p of positions) {
    await page.mouse.click(p.x, p.y, { delay: 30 });
    await new Promise((r) => setTimeout(r, 200));
  }
  return { t0: 0 };
}

// Drive a viewport-pill click that changes the entire tree's bbox
// space. The launcher re-lays out at the new viewport and re-emits
// the whole manifest (legacy) or a many-op delta (delta path).
async function runResize(page) {
  const t0 = await page.evaluate(() => performance.now());
  const ok = await page.evaluate(() => {
    const pills = document.querySelectorAll(
      '[data-preview-chrome-bar="true"] [data-toolbar-cluster="viewport"] ' +
        '[data-preview-viewport-strip-host="true"] [data-choice-group-pill]',
    );
    if (pills.length < 2) return false;
    let target = null;
    for (const p of pills) {
      const ariaPressed = p.getAttribute("aria-pressed");
      const disabled = p.getAttribute("aria-disabled") === "true";
      if (ariaPressed !== "true" && !disabled) {
        target = p;
        break;
      }
    }
    if (!target) return false;
    target.click();
    return true;
  });
  if (!ok) return null;
  return { t0 };
}

// Drive a sustained mousemove burst across the canvas as a stand-in
// for scroll (the example apps don't expose a long scrollable list).
// Captures the per-tick wire activity during the burst.
async function runScrollProxy(page, durationMs = 2000) {
  const canvasRect = await page.evaluate(() => {
    const canvases = document.querySelectorAll(
      '[data-canvas-wrapper="true"] canvas',
    );
    let el = null;
    for (const c of canvases) {
      const rr = c.getBoundingClientRect();
      if (rr.width > 10 && rr.height > 10) {
        el = c;
        break;
      }
    }
    if (!el) return null;
    const r = el.getBoundingClientRect();
    return { left: r.left, top: r.top, w: r.width, h: r.height };
  });
  if (!canvasRect || canvasRect.w === 0) {
    // Canvas not visible (e.g. transient state after a resize-pill
    // click). Fall back to a passive 2s window — still useful as an
    // upper bound on idle bandwidth right after a mutation event.
    process.stderr.write(
      `[ETS-M5] runScrollProxy: canvas not visible, falling back ` +
        `to passive ${durationMs}ms window\n`,
    );
    await new Promise((r) => setTimeout(r, durationMs));
    return null;
  }
  const ticks = 30;
  const stepMs = Math.floor(durationMs / ticks);
  for (let i = 0; i < ticks; i++) {
    const fx = ((i % 10) + 0.5) / 10;
    const fy = 0.2 + 0.6 * ((i % 5) / 5);
    const x = canvasRect.left + canvasRect.w * fx;
    const y = canvasRect.top + canvasRect.h * fy;
    await page.mouse.move(x, y);
    await new Promise((r) => setTimeout(r, stepMs));
  }
}

// Verify which path we're on. Returns "delta" | "legacy" | "unknown".
async function detectPath(page) {
  return page.evaluate(() => {
    const arr = window.__etsM5Wire || [];
    let sawDelta = false;
    let sawLegacy = false;
    for (const w of arr) {
      if (w.type === "element-tree-delta") sawDelta = true;
      if (w.type === "element-tree") sawLegacy = true;
    }
    if (sawDelta) return "delta";
    if (sawLegacy) return "legacy";
    return "unknown";
  });
}

async function settleAfterPick(page) {
  await waitFor(async () => {
    const detected = await detectPath(page);
    return detected !== "unknown";
  }, 30000);
  // Wait for the canvas to be visible (display:block + non-zero rect).
  await waitFor(async () => {
    return page.evaluate(() => {
      const canvases = document.querySelectorAll(
        '[data-canvas-wrapper="true"] canvas',
      );
      for (const c of canvases) {
        const r = c.getBoundingClientRect();
        if (r.width > 10 && r.height > 10) return true;
      }
      return false;
    });
  }, 10000);
  // Give the bridge a beat to settle into its steady state.
  await new Promise((r) => setTimeout(r, 500));
}

async function runScenarios(page, pathLabel) {
  const results = { path: pathLabel, scenarios: {} };

  // -------- 1. Idle (5s settle) --------
  const idleT0 = await page.evaluate(() => performance.now());
  const idleWall0 = Date.now();
  await new Promise((r) => setTimeout(r, 5000));
  const idleWindow = await collectWireWindow(
    page,
    idleT0,
    Date.now() - idleWall0,
  );
  results.scenarios.idle = {
    elapsedMs: idleWindow.elapsedMs,
    etsBytes: idleWindow.etsBytes,
    etsPackets: idleWindow.etsPackets,
    etsBytesPerSec: (idleWindow.etsBytes / idleWindow.elapsedMs) * 1000,
    etsPacketsPerSec: (idleWindow.etsPackets / idleWindow.elapsedMs) * 1000,
    totalBytes: idleWindow.totalBytes,
    totalPackets: idleWindow.totalPackets,
    totalBytesPerSec: (idleWindow.totalBytes / idleWindow.elapsedMs) * 1000,
    legacy: summariseSizes(idleWindow.legacySizes),
    delta: summariseSizes(idleWindow.deltaSizes),
  };

  // -------- 2. Hover sweep --------
  await page.evaluate(() => {
    window.__etsM5LatencySamples = [];
    window.__etsM5LastConsumedSeq = -1;
  });
  const hoverT0 = await page.evaluate(() => performance.now());
  const hoverWall0 = Date.now();
  await runHoverSweep(page, 10, 2000);
  // Let any trailing rAFs land.
  await new Promise((r) => setTimeout(r, 300));
  const hoverWindow = await collectWireWindow(
    page,
    hoverT0,
    Date.now() - hoverWall0,
  );
  const latencySamples = await page.evaluate(
    () => window.__etsM5LatencySamples || [],
  );
  // Capture diagnostic info: how many hovered elements did the
  // playwright sweep land on, and what's the current manifest size.
  const hoverDiag = await page.evaluate(() => {
    const manifests = window.__isonimManifests || [];
    const deltas = window.__isonimElementTreeDeltas || [];
    const m = manifests.length > 0 ? manifests[manifests.length - 1] : null;
    const lastDelta = deltas.length > 0 ? deltas[deltas.length - 1] : null;
    return {
      manifestEntries: m && Array.isArray(m.elements) ? m.elements.length : 0,
      manifestsCount: manifests.length,
      deltasCount: deltas.length,
      lastHoveredPath: window.__isonimHoveredComponentPath || null,
      lastHoveredId: window.__isonimHoveredElementId || null,
      observerInstalled: !!window.__etsM5ObserverInstalled,
    };
  });
  results.scenarios.hover = {
    elapsedMs: hoverWindow.elapsedMs,
    etsBytes: hoverWindow.etsBytes,
    etsPackets: hoverWindow.etsPackets,
    etsBytesPerSec: (hoverWindow.etsBytes / hoverWindow.elapsedMs) * 1000,
    legacy: summariseSizes(hoverWindow.legacySizes),
    delta: summariseSizes(hoverWindow.deltaSizes),
    diag: hoverDiag,
    latency: {
      samples: latencySamples.length,
      domLatencyMs: aggregate(latencySamples, "domLatencyMs"),
      rafLatencyMs: aggregate(latencySamples, "rafLatencyMs"),
    },
  };

  // -------- 3. Scroll proxy (driven BEFORE the resize scenario so the
  // canvas is guaranteed visible). --------
  const scrollT0 = await page.evaluate(() => performance.now());
  const scrollWall0 = Date.now();
  await runScrollProxy(page, 2000);
  await new Promise((r) => setTimeout(r, 300));
  const scrollWindow = await collectWireWindow(
    page,
    scrollT0,
    Date.now() - scrollWall0,
  );
  results.scenarios.scroll = {
    elapsedMs: scrollWindow.elapsedMs,
    etsBytes: scrollWindow.etsBytes,
    etsPackets: scrollWindow.etsPackets,
    etsBytesPerSec: (scrollWindow.etsBytes / scrollWindow.elapsedMs) * 1000,
    legacy: summariseSizes(scrollWindow.legacySizes),
    delta: summariseSizes(scrollWindow.deltaSizes),
  };

  // -------- 4. Mass edit --------
  // Snapshot the delta mirror length BEFORE the mutation so we can
  // isolate the deltas that arrive DURING the mass-edit window from
  // the cumulative history.
  const preMassDeltaLen = await page.evaluate(
    () => (window.__isonimElementTreeDeltas || []).length,
  );
  const massT0 = await page.evaluate(() => performance.now());
  const massWall0 = Date.now();
  await runMassEdit(page);
  await new Promise((r) => setTimeout(r, 1500));
  const massWindow = await collectWireWindow(
    page,
    massT0,
    Date.now() - massWall0,
  );
  // Probe op-count for ONLY the deltas that arrived during the window.
  const deltaOpsHistory = await page.evaluate((preLen) => {
    const arr = (window.__isonimElementTreeDeltas || []).slice(preLen);
    return arr.map((d) => ({
      seq: d.seq || 0,
      isSnapshot: !!d.isSnapshot,
      opCount: Array.isArray(d.ops) ? d.ops.length : 0,
    }));
  }, preMassDeltaLen);
  results.scenarios.massEdit = {
    elapsedMs: massWindow.elapsedMs,
    legacy: summariseSizes(massWindow.legacySizes),
    delta: summariseSizes(massWindow.deltaSizes),
    deltaOpsHistory,
  };

  // -------- 5. Resize (LAST so its viewport-pill side effects don't
  // poison the earlier scenarios; the canvas may be temporarily
  // hidden right after the click which would break scroll's
  // canvas-rect probe). --------
  const resizeT0 = await page.evaluate(() => performance.now());
  const resizeWall0 = Date.now();
  const r = await runResize(page);
  if (r) {
    // First-paint latency proxy: time from t0 to first ETS packet
    // landing after t0.
    await waitFor(async () => {
      const arr = await page.evaluate(() => window.__etsM5Wire || []);
      const found = arr.find(
        (w) =>
          (w.type === "element-tree" || w.type === "element-tree-delta") &&
          w.t > resizeT0,
      );
      return !!found;
    }, 5000);
    const firstPaint = await page.evaluate((t0) => {
      const arr = window.__etsM5Wire || [];
      for (const w of arr) {
        if (
          (w.type === "element-tree" || w.type === "element-tree-delta") &&
          w.t > t0
        ) {
          return { t: w.t, type: w.type, bytes: w.bytes };
        }
      }
      return null;
    }, resizeT0);
    await new Promise((r) => setTimeout(r, 1000));
    const resizeWindow = await collectWireWindow(
      page,
      resizeT0,
      Date.now() - resizeWall0,
    );
    results.scenarios.resize = {
      firstPaintLatencyMs: firstPaint ? firstPaint.t - resizeT0 : null,
      firstPaintBytes: firstPaint ? firstPaint.bytes : null,
      firstPaintType: firstPaint ? firstPaint.type : null,
      legacy: summariseSizes(resizeWindow.legacySizes),
      delta: summariseSizes(resizeWindow.deltaSizes),
    };
  } else {
    results.scenarios.resize = { skipped: "no viewport pill available" };
  }

  return results;
}

const SKIP_REASON =
  "ETS-M5 — macOS-only milestone (cocoa launcher is the test vehicle).";

let launcher = null;
let proxy = null;

test.before(async () => {
  if (!isMacOS) return;
  buildEditorAndCocoa();
  mkdirSync(goldenDir, { recursive: true });
});

test.after(async () => {
  try {
    if (browser) await browser.close();
  } catch (_) {}
  try {
    if (launcher) launcher.kill("SIGTERM");
  } catch (_) {}
  try {
    if (proxy) await proxy.shutdown();
  } catch (_) {}
});

async function runPath(pathLabel) {
  const launcherPort = await pickFreePort();
  const serverPort = await pickFreePort();
  launcher = await spawnCocoaLauncher(launcherPort);
  proxy = await startEditorProxy(serverPort, launcherPort);
  const { ctx, page } = await openEditorAgainst(serverPort, {
    path: pathLabel,
  });
  try {
    await page.evaluate(() => {
      window.__isonimTestMode = true;
      window.__isonimManifests = [];
      window.__isonimElementTreeDeltas = [];
    });
    await pickCocoa(page);
    await settleAfterPick(page);
    const detected = await detectPath(page);
    const results = await runScenarios(page, pathLabel);
    results.detectedPath = detected;
    return results;
  } finally {
    try {
      await ctx.close();
    } catch (_) {}
    try {
      launcher.kill("SIGTERM");
      launcher = null;
    } catch (_) {}
    try {
      await proxy.shutdown();
      proxy = null;
    } catch (_) {}
  }
}

test(
  "ETS-M5 bench: legacy vs delta wire bytes + latency across " +
    "idle/hover/mass-edit/resize/scroll",
  async (t) => {
    if (!isMacOS) {
      t.skip(SKIP_REASON);
      return;
    }
    const deltaResults = await runPath("delta");
    const legacyResults = await runPath("legacy");

    const ts = new Date()
      .toISOString()
      .replace(/[:.]/g, "-")
      .replace(/Z$/, "Z");
    const out = {
      milestone: "ETS-M5",
      timestamp: ts,
      backend: "cocoa",
      viewport: { width: 1440, height: 900 },
      demo: "task",
      delta: deltaResults,
      legacy: legacyResults,
    };
    const outPath = join(goldenDir, `${ts}.json`);
    writeFileSync(outPath, JSON.stringify(out, null, 2));
    // Also write a stable "latest.json" so the report renderer can pick
    // up the most recent run without globbing.
    writeFileSync(join(goldenDir, "latest.json"), JSON.stringify(out, null, 2));

    // Path-detection sanity: when we asked for delta we must actually
    // be on delta; when we asked for legacy we must be on legacy.
    assert.equal(
      deltaResults.detectedPath,
      "delta",
      `expected delta path; detected ${deltaResults.detectedPath}; ` +
        `wrote ${outPath}`,
    );
    assert.equal(
      legacyResults.detectedPath,
      "legacy",
      `expected legacy path; detected ${legacyResults.detectedPath}; ` +
        `wrote ${outPath}`,
    );

    // Smoke assertions on the data. We DO NOT assert "delta is always
    // smaller" — the report is the place to surface the verdict. We
    // only assert the bench produced data on both sides.
    assert.ok(
      typeof deltaResults.scenarios.idle.totalBytesPerSec === "number",
      "delta idle totalBytesPerSec should be a number",
    );
    assert.ok(
      typeof legacyResults.scenarios.idle.totalBytesPerSec === "number",
      "legacy idle totalBytesPerSec should be a number",
    );

    process.stderr.write(
      `[ETS-M5] wrote ${outPath}\n` +
        `[ETS-M5] delta path detected=${deltaResults.detectedPath} ` +
        `idle B/s=${deltaResults.scenarios.idle.etsBytesPerSec.toFixed(1)}\n` +
        `[ETS-M5] legacy path detected=${legacyResults.detectedPath} ` +
        `idle B/s=${legacyResults.scenarios.idle.etsBytesPerSec.toFixed(1)}\n`,
    );
  },
);
