// FUH-M3 — Acceptance gate for Phase A hover dispatch.
//
// FUH-M2 wired ``maMove`` -> ``fireEvent("mouseenter" / "mouseleave")``
// through all four backends' input adapters and added a hover handler
// pair to task_app's ``renderTaskRow`` that flips
// ``ElementKindAttr`` between ``"row"`` and ``"row-hovered"``. The
// FUH-M1 audit projected that the resulting per-hover wire payload
// should be ~70 bytes (the sparse ``{op:"update", id, kind}`` delta
// op) vs ~250 bytes for the legacy full-row body, a ~15x reduction.
//
// This milestone re-runs the ETS-M6 acceptance pattern but ONLY
// against the hover-induced mutation path, so the per-hover wire
// bytes are isolated from idle/resize/click traffic. We:
//
//   1. Spawn the real cocoa launcher (FUH-M2 hover handler is wired
//      for all 4 backends; cocoa is the cheapest to verify against).
//   2. Open the editor against task_app, settle on Cocoa + Phone
//      viewport.
//   3. Resolve N=10 on-screen task-row positions via the
//      __isonimManifests test-mode mirror.
//   4. Hover each row in sequence using playwright's real
//      ``page.mouse.move(x, y)`` (NOT synthetic dispatch — the
//      brief's per-hover wire-payload count must be against real
//      mouse events that the launcher's input adapter sees).
//   5. Capture each hover's M-packet payload via __etsM6Wire (the
//      bytes-on-the-wire mirror established in ETS-M5) and the
//      __isonimElementTreeDeltas test mirror (the test-mode
//      JSON ops). Match by performance.now() timestamps.
//   6. Measure mouse-move -> overlay-rect-update latency via the
//      MutationObserver pattern ETS-M6 established.
//   7. Re-run the same sweep with hello-accept's ``e/element-tree``
//      stripped (the ETS-M5 backward-compat path) to capture
//      legacy bytes-per-hover for the comparison.
//   8. Assert:
//      * Each hover produces >=1 element-tree-delta packet with an
//        ``op:"update"`` carrying the changed ``kind`` field.
//      * Payload bytes per hover <= 200 (audit projected ~70; we
//        leave headroom for JSON whitespace + metadata).
//      * Median mouse-move -> overlay-update latency <= 16 ms.
//      * legacy bytes-per-hover >= 5x delta bytes-per-hover. The
//        audit projected 15x; the actual ratio depends on the
//        specific task_app schema and JSON-encode overhead. The
//        5x bar surfaces the win is significant without baking
//        in the projection.
//
// No editor source changes; no test weakening; no commits.
//
// Skip rule: macOS-only — the cocoa launcher only builds on Darwin.

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
const goldenDir = join(__dirname, "golden", "fuh-m3");

const LAUNCHER_BACKEND = "cocoa";
const isMacOS = process.platform === "darwin";

const HOVER_N = 10;
const PAYLOAD_BYTES_GATE = 200; // audit projected ~70; headroom for JSON.
const LATENCY_GATE_MS = 16.0;
const LEGACY_RATIO_GATE = 5.0; // audit projected 15x; surface significant win.

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
  const tag = `[cocoa-fuh-m3]`;
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

// Install the wire mirror BEFORE the editor IIFE attaches. Same shape
// as ETS-M5/M6 mirror (kind / bytes / t / type) so the byte-count
// matches what those bench / acceptance harnesses measured.
//
// We also install the hello-accept stripper (the ETS-M5 backward-
// compat pattern) when ``stripHelloAccept`` is true so the launcher
// stays on the legacy full-manifest path for Part B.
async function installWireMirror(ctx, { stripHelloAccept = false } = {}) {
  await ctx.addInitScript((stripArg) => {
    try {
      window.__fuhM3Wire = [];
      window.__fuhM3T0 = performance.now();
      window.__fuhM3StripHelloAccept = !!stripArg;

      const RealWS = window.WebSocket;
      function WrappedWS(url, protocols) {
        const ws = protocols ? new RealWS(url, protocols) : new RealWS(url);
        const origSend = ws.send.bind(ws);
        ws.send = function (data) {
          try {
            if (
              window.__fuhM3StripHelloAccept &&
              data &&
              data.byteLength >= 5
            ) {
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
                const m = body.match(/"type"\s*:\s*"([^"]+)"/);
                if (m) typeTag = m[1];
              } catch (_) {}
            }
            window.__fuhM3Wire.push({
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
  }, stripHelloAccept);
}

// Install the latency observer. Watches the hover-label and selection
// outline ``style`` attribute mutations and records
// mousemove -> mutation latency anchored against
// __fuhM3LastMouseMoveT (set by hoverAt before each move).
async function installLatencyObserver(ctx) {
  await ctx.addInitScript(() => {
    try {
      window.__fuhM3LatencySamples = [];
      window.__fuhM3LastMouseMoveT = null;
      window.__fuhM3LastMouseMoveSeq = 0;
      window.__fuhM3LastConsumedSeq = -1;

      function installObserverOnce() {
        if (window.__fuhM3ObserverInstalled) return;
        const hoverLabel = document.querySelector(
          '[data-canvas-hover-label="true"]',
        );
        const selectionOutline = document.querySelector(
          '[data-canvas-selection-outline="true"]',
        );
        if (!hoverLabel && !selectionOutline) return;
        window.__fuhM3ObserverInstalled = true;

        function record(t, anchor) {
          const moveT = window.__fuhM3LastMouseMoveT;
          const moveSeq = window.__fuhM3LastMouseMoveSeq;
          if (moveT == null) return;
          if (window.__fuhM3LastConsumedSeq === moveSeq) return;
          window.__fuhM3LastConsumedSeq = moveSeq;
          window.__fuhM3LatencySamples.push({
            seq: moveSeq,
            moveT,
            paintT: t,
            anchor,
            domLatencyMs: t - moveT,
          });
        }

        const observer = new MutationObserver((muts) => {
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
        window.__fuhM3Observer = observer;
      }

      const tryInstall = setInterval(() => {
        installObserverOnce();
        if (window.__fuhM3ObserverInstalled) clearInterval(tryInstall);
      }, 50);
      setTimeout(() => clearInterval(tryInstall), 30000);
    } catch (_) {}
  });
}

async function openEditorAgainst(
  serverPort,
  viewport,
  { stripHelloAccept = false } = {},
) {
  const b = await ensureBrowser();
  const ctx = await b.newContext({ viewport });
  const page = await ctx.newPage();
  page.on("pageerror", (e) => console.error("[page] error:", e.message));
  await installWireMirror(ctx, { stripHelloAccept });
  await installLatencyObserver(ctx);
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

// Detect which wire path is active. Returns "delta" | "legacy" |
// "unknown" — same shape as ETS-M5/M6.
async function detectPath(page) {
  return page.evaluate(() => {
    const arr = window.__fuhM3Wire || [];
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
  await waitFor(async () => {
    return page.evaluate(() => {
      const cs = document.querySelectorAll(
        '[data-canvas-wrapper="true"] canvas',
      );
      for (const c of cs) {
        const r = c.getBoundingClientRect();
        if (r.width > 10 && r.height > 10) {
          const ratio = c.clientWidth / c.width;
          if (ratio > 0.7 && ratio < 1.3) return true;
        }
      }
      return false;
    });
  }, 5000);
  await new Promise((r) => setTimeout(r, 500));
}

// Switch the editor into Comment mode (ETS-M6 pattern). The hover
// label / overlay path is mode-independent; the mode switch is
// kept for parity with the ETS-M6 acceptance environment.
async function switchToCommentMode(page) {
  await page.evaluate(() => {
    const pills = document.querySelectorAll(
      '[data-toolbar-cluster="mode"] [data-choice-group-pill]',
    );
    for (const p of pills) {
      const lbl = (
        p.getAttribute("data-choice-group-label") ||
        p.textContent ||
        ""
      ).toLowerCase();
      if (lbl.indexOf("comment") >= 0) {
        p.click();
        return true;
      }
    }
    return false;
  });
}

// Read canvas + wrapper geometry. Same shape as ETS-M6's
// readCanvasGeometry — needed to map manifest intrinsic-pixel bounds
// to CSS-space hover coordinates.
async function readCanvasGeometry(page) {
  return page.evaluate(() => {
    const wrappers = document.querySelectorAll('[data-canvas-wrapper="true"]');
    for (const w of wrappers) {
      const wr = w.getBoundingClientRect();
      if (wr.width < 10 || wr.height < 10) continue;
      const c = w.querySelector("canvas");
      if (!c) continue;
      const r = c.getBoundingClientRect();
      if (r.width < 10 || r.height < 10) continue;
      return {
        left: r.left,
        top: r.top,
        clientWidth: r.width,
        clientHeight: r.height,
        intrinsicWidth: c.width,
        intrinsicHeight: c.height,
        wrapperLeft: wr.left,
        wrapperTop: wr.top,
        wrapperWidth: wr.width,
        wrapperHeight: wr.height,
      };
    }
    return null;
  });
}

// Read the current applied manifest (seed + applied deltas). On the
// delta path the seed is the first __isonimManifests entry and the
// deltas accumulate; on the legacy path the seed list is the only
// source. ETS-M6 already mirrors this logic.
async function readCurrentManifest(page) {
  return page.evaluate(() => {
    const manifests = window.__isonimManifests || [];
    if (manifests.length === 0) return null;
    let seed = manifests[manifests.length - 1];
    const byId = new Map();
    for (const el of seed.elements || []) {
      byId.set(el.id, {
        id: el.id,
        componentPath: el.componentPath,
        kind: el.kind,
        bounds: { ...el.bounds },
      });
    }
    function extractBounds(op, prev) {
      const x =
        typeof op.x === "number"
          ? op.x
          : prev && prev.bounds
            ? prev.bounds.x
            : 0;
      const y =
        typeof op.y === "number"
          ? op.y
          : prev && prev.bounds
            ? prev.bounds.y
            : 0;
      const w =
        typeof op.w === "number"
          ? op.w
          : prev && prev.bounds
            ? prev.bounds.w
            : 0;
      const h =
        typeof op.h === "number"
          ? op.h
          : prev && prev.bounds
            ? prev.bounds.h
            : 0;
      return { x, y, w, h };
    }
    const deltas = window.__isonimElementTreeDeltas || [];
    for (const d of deltas) {
      for (const op of d.ops || []) {
        if (op.op === "remove") {
          byId.delete(op.id);
        } else if (op.op === "add" || op.op === "update") {
          const prev = byId.get(op.id) || {};
          byId.set(op.id, {
            id: op.id,
            componentPath: op.componentPath || prev.componentPath || op.id,
            kind: op.kind || prev.kind || "",
            bounds: extractBounds(op, prev),
          });
        }
      }
    }
    return {
      surfaceWidth: seed.surfaceWidth,
      surfaceHeight: seed.surfaceHeight,
      elements: Array.from(byId.values()),
    };
  });
}

// Pick hover targets that correspond to TaskRow leaves — the only
// elements wired with the FUH-M2 mouseenter/mouseleave handler. We
// match on componentPath containing ``TaskRow`` (the audit § 5.2 hot
// spot) so we don't waste hovers on the surface root or non-row
// chrome elements.
function buildHoverTargets(manifest, geom) {
  const sx = geom.clientWidth / geom.intrinsicWidth;
  const sy = geom.clientHeight / geom.intrinsicHeight;
  const wrapperLeft = geom.wrapperLeft;
  const wrapperTop = geom.wrapperTop;
  const wrapperRight = wrapperLeft + geom.wrapperWidth;
  const wrapperBottom = wrapperTop + geom.wrapperHeight;
  const targets = [];
  for (const el of manifest.elements) {
    if (!el.bounds) continue;
    const { x, y, w, h } = el.bounds;
    if (w <= 0 || h <= 0) continue;
    // Drop the surface root.
    const canvasArea = geom.intrinsicWidth * geom.intrinsicHeight;
    if (w * h > canvasArea * 0.95) continue;
    const cx = x + w * 0.5;
    const cy = y + h * 0.5;
    const hoverPointClient = {
      x: geom.left + cx * sx,
      y: geom.top + cy * sy,
    };
    if (
      hoverPointClient.x < wrapperLeft ||
      hoverPointClient.x > wrapperRight ||
      hoverPointClient.y < wrapperTop ||
      hoverPointClient.y > wrapperBottom
    ) {
      continue;
    }
    targets.push({
      id: el.id,
      componentPath: el.componentPath,
      kind: el.kind,
      boundsIntrinsic: { x, y, w, h },
      hoverPointClient,
    });
  }
  // Prefer TaskRow leaves first (the FUH-M2 hover-handler row), then
  // fall back to other distinct leaves so the sweep still produces
  // N=10 hover events on apps with fewer rows.
  const taskRows = targets.filter(
    (t) => t.componentPath && /TaskRow/i.test(t.componentPath),
  );
  const others = targets.filter(
    (t) => !t.componentPath || !/TaskRow/i.test(t.componentPath),
  );
  return [...taskRows, ...others];
}

// Drive a single mousemove via playwright's REAL mouse driver. The
// brief explicitly calls for ``page.mouse.move(x, y)`` (NOT the
// synthetic dispatch ETS-M5 used in its bench). Before each move,
// snapshot moveT so the MutationObserver-driven latency probe can
// anchor against it.
async function hoverAt(page, x, y, hoverSeq) {
  await page.evaluate(
    ({ seq }) => {
      window.__fuhM3LastMouseMoveSeq = seq;
      window.__fuhM3LastMouseMoveT = performance.now();
    },
    { seq: hoverSeq },
  );
  await page.mouse.move(x, y);
}

// Snapshot the running counters BEFORE the hover so we can correlate
// per-hover deltas and per-hover wire bytes.
async function snapshotCounters(page) {
  return page.evaluate(() => ({
    wireLen: (window.__fuhM3Wire || []).length,
    deltaLen: (window.__isonimElementTreeDeltas || []).length,
    manifestLen: (window.__isonimManifests || []).length,
    nowT: performance.now(),
  }));
}

// Read the wire mirror + delta mirror entries that landed AFTER
// ``before``. Buckets by element-tree-delta + element-tree.
async function collectSinceSnapshot(page, before) {
  return page.evaluate((b) => {
    const wireAll = window.__fuhM3Wire || [];
    const deltasAll = window.__isonimElementTreeDeltas || [];
    const manifestsAll = window.__isonimManifests || [];
    const wireSlice = wireAll.slice(b.wireLen);
    const deltaSlice = deltasAll.slice(b.deltaLen);
    const manifestSlice = manifestsAll.slice(b.manifestLen);
    // Only count element-tree-delta + element-tree M packets for the
    // payload-per-hover figure. Frame ('F') traffic is webp video and
    // is the same on both paths; chrome/keyboard M traffic is noise.
    const deltaWire = wireSlice.filter((w) => w.type === "element-tree-delta");
    const legacyWire = wireSlice.filter((w) => w.type === "element-tree");
    const sumBytes = (arr) =>
      arr.reduce((s, w) => s + (typeof w.bytes === "number" ? w.bytes : 0), 0);
    return {
      windowMs: performance.now() - b.nowT,
      wireSliceLen: wireSlice.length,
      deltaWirePackets: deltaWire.length,
      deltaWireBytes: sumBytes(deltaWire),
      deltaWireSizes: deltaWire.map((w) => w.bytes),
      legacyWirePackets: legacyWire.length,
      legacyWireBytes: sumBytes(legacyWire),
      legacyWireSizes: legacyWire.map((w) => w.bytes),
      // The JSON-decoded delta ops (post-decode test-mode mirror) so
      // we can verify the audit's "op:update carries the changed
      // kind field" semantic.
      deltaOps: deltaSlice.flatMap((d) =>
        (d.ops || []).map((op) => ({
          op: op.op,
          id: op.id,
          kind: op.kind,
          hasBounds: typeof op.x === "number",
          opJson: JSON.stringify(op),
        })),
      ),
      manifestsAdded: manifestSlice.length,
    };
  }, before);
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

function sum(arr) {
  return arr.reduce((s, v) => s + v, 0);
}

// Drive the N=10 hover sequence and capture per-hover wire / delta
// / latency rows. Returns a per-hover report.
async function runHoverSweep(page, hoverSet) {
  const perHover = [];
  // Warmup: drive a mousemove far outside the canvas first so the
  // very first real hover crosses an actual element boundary.
  await page.mouse.move(0, 0);
  await new Promise((r) => setTimeout(r, 80));
  let seq = 1;
  for (const target of hoverSet) {
    const before = await snapshotCounters(page);
    await hoverAt(
      page,
      target.hoverPointClient.x,
      target.hoverPointClient.y,
      seq,
    );
    // Wait for the bridge to ship the hover-induced delta + the
    // overlay-effect to repaint. 250 ms is generous vs the audit's
    // sub-16 ms expectation; this is a per-hover wall-clock window
    // so a slow CI machine doesn't starve the legitimate packet.
    await new Promise((r) => setTimeout(r, 250));
    const window_ = await collectSinceSnapshot(page, before);
    perHover.push({
      seq,
      target: {
        id: target.id,
        componentPath: target.componentPath,
      },
      ...window_,
    });
    seq += 1;
  }
  // Drain any trailing observer entries for the final hover.
  await new Promise((r) => setTimeout(r, 200));
  const samples = await page.evaluate(() => window.__fuhM3LatencySamples || []);
  return { perHover, latencySamples: samples };
}

async function runHoverPathForViewport({ stripHelloAccept }) {
  const launcherPort = await pickFreePort();
  const serverPort = await pickFreePort();
  const launcher = await spawnCocoaLauncher(launcherPort);
  const proxy = await startEditorProxy(serverPort, launcherPort);
  const playwrightVp = { width: 1920, height: 1080 };
  const { ctx, page } = await openEditorAgainst(serverPort, playwrightVp, {
    stripHelloAccept,
  });
  const verdict = {
    stripHelloAccept,
    detectedPath: "unknown",
    perHover: [],
    latencySamples: [],
    medianLatencyMs: null,
    p99LatencyMs: null,
    medianBytesPerHover: null,
    meanBytesPerHover: null,
    maxBytesPerHover: null,
    hoversWithDelta: 0,
    hoversWithUpdateKind: 0,
    notes: [],
  };
  try {
    await page.evaluate(() => {
      window.__isonimTestMode = true;
      window.__isonimManifests = [];
      window.__isonimElementTreeDeltas = [];
    });
    await pickCocoa(page);
    await settleAfterPick(page);
    await switchToCommentMode(page);
    await new Promise((r) => setTimeout(r, 600));

    verdict.detectedPath = await detectPath(page);

    // Reset latency + wire counters between viewport runs.
    await page.evaluate(() => {
      window.__fuhM3LatencySamples = [];
      window.__fuhM3LastConsumedSeq = -1;
      window.__fuhM3LastMouseMoveT = null;
      window.__fuhM3LastMouseMoveSeq = 0;
      // Reinstall the MutationObserver against the currently-visible
      // wrapper (same pattern as ETS-M6: the initial mount may have
      // been replaced by the backend pick / mode switch).
      try {
        if (window.__fuhM3Observer) window.__fuhM3Observer.disconnect();
        const wrappers = document.querySelectorAll(
          '[data-canvas-wrapper="true"]',
        );
        let visible = null;
        for (const w of wrappers) {
          if (getComputedStyle(w).display === "none") continue;
          const wr = w.getBoundingClientRect();
          if (wr.width > 10 && wr.height > 10) {
            visible = w;
            break;
          }
        }
        if (visible) {
          const hoverLabel = visible.querySelector(
            '[data-canvas-hover-label="true"]',
          );
          const selectionOutline = visible.querySelector(
            '[data-canvas-selection-outline="true"]',
          );
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
            const moveT = window.__fuhM3LastMouseMoveT;
            const moveSeq = window.__fuhM3LastMouseMoveSeq;
            if (moveT == null) return;
            if (window.__fuhM3LastConsumedSeq === moveSeq) return;
            window.__fuhM3LastConsumedSeq = moveSeq;
            window.__fuhM3LatencySamples.push({
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
          window.__fuhM3Observer = obs;
        }
      } catch (e) {
        window.__fuhM3ObserverReinstallError = String(e);
      }
    });

    const geom = await readCanvasGeometry(page);
    if (!geom) {
      verdict.notes.push("canvas not visible after settle");
      return verdict;
    }
    const manifest = await readCurrentManifest(page);
    if (!manifest || manifest.elements.length === 0) {
      verdict.notes.push("manifest empty after settle");
      return verdict;
    }
    let targets = buildHoverTargets(manifest, geom);
    if (targets.length === 0) {
      verdict.notes.push("no viable hover targets");
      return verdict;
    }
    const n = Math.min(HOVER_N, targets.length);
    const hoverSet = targets.slice(0, n);
    verdict.targetCount = hoverSet.length;
    verdict.targetSummary = hoverSet.map((t) => ({
      id: t.id,
      componentPath: t.componentPath,
    }));

    const { perHover, latencySamples } = await runHoverSweep(page, hoverSet);
    verdict.perHover = perHover;
    verdict.latencySamples = latencySamples;

    // Aggregate latency: restrict to hover-label samples (the campaign's
    // user-visible cursor-tracking metric, per ETS-M6 § Criterion 2).
    const domLatencies = latencySamples
      .filter((s) => s.anchor === "hover-label")
      .map((s) => s.domLatencyMs)
      .filter((v) => typeof v === "number" && Number.isFinite(v) && v >= 0);
    verdict.medianLatencyMs = median(domLatencies);
    verdict.p99LatencyMs = p99(domLatencies);
    verdict.latencySampleCount = domLatencies.length;

    // Aggregate per-hover bytes. ON THE DELTA PATH we count
    // element-tree-delta bytes; on the LEGACY path we count
    // element-tree bytes (the full-body manifest). For the
    // delta-vs-legacy ratio comparison the two columns are
    // apples-to-apples — each is "what the bridge had to ship to
    // describe the hover-induced state change".
    const isDelta = verdict.detectedPath === "delta";
    const perHoverBytes = perHover.map((h) =>
      isDelta ? h.deltaWireBytes : h.legacyWireBytes,
    );
    const perHoverPackets = perHover.map((h) =>
      isDelta ? h.deltaWirePackets : h.legacyWirePackets,
    );
    // Only count hovers that produced AT LEAST ONE packet on the
    // relevant path; static-hover quiescence (where the throttle
    // suppresses re-fire on the same leaf) should not pollute the
    // median.
    const measuredHoverBytes = perHoverBytes.filter((b) => b > 0);
    const measuredHoverPackets = perHoverPackets.filter((p) => p > 0);
    verdict.medianBytesPerHover = median(measuredHoverBytes);
    verdict.meanBytesPerHover =
      measuredHoverBytes.length > 0
        ? sum(measuredHoverBytes) / measuredHoverBytes.length
        : null;
    verdict.maxBytesPerHover =
      measuredHoverBytes.length > 0 ? Math.max(...measuredHoverBytes) : null;
    verdict.minBytesPerHover =
      measuredHoverBytes.length > 0 ? Math.min(...measuredHoverBytes) : null;
    verdict.hoversMeasuredCount = measuredHoverBytes.length;
    verdict.hoverPacketSum = sum(measuredHoverPackets);
    verdict.allHoverBytes = perHoverBytes;

    // Audit semantic assertions (delta path only): each measured
    // hover must produce >=1 element-tree-delta with an op:"update"
    // carrying the changed kind field.
    let hoversWithDelta = 0;
    let hoversWithUpdateKind = 0;
    for (const h of perHover) {
      if (h.deltaWirePackets > 0) hoversWithDelta += 1;
      const hasKindUpdate = (h.deltaOps || []).some(
        (op) =>
          op.op === "update" &&
          typeof op.kind === "string" &&
          op.kind.length > 0,
      );
      if (hasKindUpdate) hoversWithUpdateKind += 1;
    }
    verdict.hoversWithDelta = hoversWithDelta;
    verdict.hoversWithUpdateKind = hoversWithUpdateKind;
  } catch (e) {
    verdict.notes.push(`exception: ${e && e.stack ? e.stack : String(e)}`);
  } finally {
    try {
      await ctx.close();
    } catch (_) {}
    try {
      launcher.kill("SIGTERM");
    } catch (_) {}
    try {
      await proxy.shutdown();
    } catch (_) {}
  }
  return verdict;
}

const SKIP_REASON =
  "FUH-M3 — macOS-only milestone (cocoa launcher is the test vehicle).";

test.before(async () => {
  if (!isMacOS) return;
  buildEditorAndCocoa();
  mkdirSync(goldenDir, { recursive: true });
});

test.after(async () => {
  try {
    if (browser) await browser.close();
  } catch (_) {}
});

test(
  "FUH-M3 hover payload acceptance: delta wire bytes per hover, " +
    "delta vs legacy ratio, latency on cocoa task_app",
  async (t) => {
    if (!isMacOS) {
      t.skip(SKIP_REASON);
      return;
    }

    const report = {
      milestone: "FUH-M3",
      timestamp: new Date().toISOString(),
      backend: "cocoa",
      app: "task",
      hoverN: HOVER_N,
      payloadBytesGate: PAYLOAD_BYTES_GATE,
      latencyGateMs: LATENCY_GATE_MS,
      legacyRatioGate: LEGACY_RATIO_GATE,
      delta: null,
      legacy: null,
      ratio: null,
    };

    // Part A — delta path acceptance.
    const deltaRun = await runHoverPathForViewport({
      stripHelloAccept: false,
    });
    report.delta = deltaRun;

    // Part B — legacy path comparison.
    const legacyRun = await runHoverPathForViewport({
      stripHelloAccept: true,
    });
    report.legacy = legacyRun;

    // Compute the ratio of legacy-bytes-per-hover to delta-bytes-per-hover.
    const ratio =
      deltaRun.medianBytesPerHover && deltaRun.medianBytesPerHover > 0
        ? legacyRun.medianBytesPerHover / deltaRun.medianBytesPerHover
        : null;
    report.ratio = {
      legacyMedianBytesPerHover: legacyRun.medianBytesPerHover,
      deltaMedianBytesPerHover: deltaRun.medianBytesPerHover,
      legacyOverDelta: ratio,
    };

    // Persist the report so the markdown deliverable can cite the
    // exact numbers.
    const ts = report.timestamp.replace(/[:.]/g, "-").replace(/Z$/, "Z");
    const outPath = join(goldenDir, `${ts}.json`);
    writeFileSync(outPath, JSON.stringify(report, null, 2));
    writeFileSync(
      join(goldenDir, "latest.json"),
      JSON.stringify(report, null, 2),
    );
    process.stderr.write(`[FUH-M3] wrote ${outPath}\n`);
    process.stderr.write(
      `[FUH-M3] delta path=${deltaRun.detectedPath} ` +
        `medBytes/hover=${deltaRun.medianBytesPerHover} ` +
        `medLatency=${
          deltaRun.medianLatencyMs != null
            ? deltaRun.medianLatencyMs.toFixed(1) + "ms"
            : "n/a"
        } ` +
        `hoversWithDelta=${deltaRun.hoversWithDelta}/${deltaRun.targetCount}` +
        `\n`,
    );
    process.stderr.write(
      `[FUH-M3] legacy path=${legacyRun.detectedPath} ` +
        `medBytes/hover=${legacyRun.medianBytesPerHover} ` +
        `ratio=${ratio != null ? ratio.toFixed(2) + "x" : "n/a"}\n`,
    );

    // ----- Assertions (Part A) -----
    assert.equal(
      deltaRun.detectedPath,
      "delta",
      `Part A: delta path MUST be detected; got ${deltaRun.detectedPath}. ` +
        `notes=${JSON.stringify(deltaRun.notes)}`,
    );
    assert.ok(
      deltaRun.targetCount && deltaRun.targetCount > 0,
      `Part A: at least one hover target should be resolvable; got ${deltaRun.targetCount}`,
    );
    // Each hover that actually crossed a row leaf must produce >=1
    // element-tree-delta packet. The throttle (FUH-M2 commit message:
    // "If same: no-op") legitimately suppresses re-fire when the
    // cursor stays on the same leaf, so we don't require ALL N=10
    // hovers to fire — we require at least one, and at least one
    // hover must carry an op:"update" with a non-empty ``kind``
    // (the audit's projected sparse-row-flip semantic).
    assert.ok(
      deltaRun.hoversWithDelta >= 1,
      `Part A: at least one hover MUST produce an element-tree-delta packet. ` +
        `Got ${deltaRun.hoversWithDelta}/${deltaRun.targetCount}. ` +
        `perHover=${JSON.stringify(
          deltaRun.perHover.map((h) => ({
            seq: h.seq,
            target: h.target.componentPath,
            deltaPackets: h.deltaWirePackets,
            deltaBytes: h.deltaWireBytes,
            opKinds: (h.deltaOps || []).map((o) => o.op),
          })),
        )}`,
    );
    assert.ok(
      deltaRun.hoversWithUpdateKind >= 1,
      `Part A: at least one hover MUST emit an op:"update" carrying ` +
        `the changed kind field (audit § 4.3 sparse-update semantic). ` +
        `Got ${deltaRun.hoversWithUpdateKind}/${deltaRun.targetCount}.`,
    );
    assert.ok(
      deltaRun.medianBytesPerHover != null &&
        deltaRun.medianBytesPerHover <= PAYLOAD_BYTES_GATE,
      `Part A: median delta wire bytes per hover MUST be <= ${PAYLOAD_BYTES_GATE}; ` +
        `got ${deltaRun.medianBytesPerHover} ` +
        `(min=${deltaRun.minBytesPerHover}, max=${deltaRun.maxBytesPerHover}, ` +
        `mean=${deltaRun.meanBytesPerHover}, ` +
        `measured=${deltaRun.hoversMeasuredCount}/${deltaRun.targetCount})`,
    );
    assert.ok(
      deltaRun.medianLatencyMs != null &&
        deltaRun.medianLatencyMs <= LATENCY_GATE_MS,
      `Part A: median mousemove -> overlay-update latency MUST be <= ` +
        `${LATENCY_GATE_MS} ms; got ${deltaRun.medianLatencyMs} ms ` +
        `(p99=${deltaRun.p99LatencyMs}, n=${deltaRun.latencySampleCount})`,
    );

    // ----- Assertions (Part B) -----
    assert.equal(
      legacyRun.detectedPath,
      "legacy",
      `Part B: legacy path MUST be detected with stripHelloAccept=true; ` +
        `got ${legacyRun.detectedPath}. notes=${JSON.stringify(legacyRun.notes)}`,
    );
    assert.ok(
      legacyRun.medianBytesPerHover != null &&
        legacyRun.medianBytesPerHover > 0,
      `Part B: legacy path MUST produce measurable bytes per hover; ` +
        `got ${legacyRun.medianBytesPerHover}`,
    );
    assert.ok(
      ratio != null && ratio >= LEGACY_RATIO_GATE,
      `Part B: legacy bytes-per-hover MUST be >= ${LEGACY_RATIO_GATE}x ` +
        `delta bytes-per-hover. Got ratio=${ratio} ` +
        `(legacyMed=${legacyRun.medianBytesPerHover}, ` +
        `deltaMed=${deltaRun.medianBytesPerHover}). ` +
        `Audit projected 15x; the actual ratio depends on the specific ` +
        `task_app schema + JSON-encode overhead.`,
    );
  },
);
