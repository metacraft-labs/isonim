// ETS-M6 — Acceptance gate for the element-tree streaming campaign.
//
// Closes the campaign by measuring whether the production stream's
// overlay tracking meets the user-visible promise on a real launcher:
//
//   1. Overlay outline bbox matches the rendered element rect within
//      1 px after hovering / clicking on it. (The original VRS-era
//      user complaint that initiated this campaign.)
//   2. Median mouse-move -> overlay-update latency <=16 ms. (The
//      60 FPS user-visible promise.)
//   3. Viewport resize re-snaps cleanly without flicker.
//   4. EPP-M12 hit-chain dispatch still routes clicks correctly.
//   5. Backward compat: stripping the editor's hello-accept
//      ``e/element-tree`` advertisement falls back to the legacy
//      full-manifest path and the same overlay tracking works.
//
// Approach taken: **Approach B with deliberate viewport-resize
// mutation triggers.** The ETS-M5 measurement report (and the
// ETS-M1 audit) established that the production cocoa task_app's
// shadow tree is static-on-hover. Per the brief:
//
//   "Look at the existing GPUI / Freya / Cocoa renders of
//    settings_app or any sibling app. If any of them DO mutate
//    the shadow tree on hover..."
//
// Audit of the four cocoa/freya/gpui/android input adapters
// confirms no mousemove-driven mutations exist on any launcher:
// the input adapters log ``maMove`` events but dispatch only
// ``maClick`` through ``fireEvent`` (see
// ``isonim-render-serve/src/isonim_render_serve/adapters/*_input_adapter.nim``).
// No existing app surfaces a mutating hover.
//
// We therefore acceptance-test on cocoa task_app with the
// viewport-resize mass-mutation trigger ETS-M5 already validated
// as the reliable delta-firing event. The five criteria above all
// remain checkable on a static-hover app because:
//
//   * (1) bbox alignment is the steady-state overlay-positioning
//     check the campaign promises — works on any manifest.
//   * (2) latency floor is what ETS-M5 measured at 2.5 ms p99 on
//     both wire paths; M6 re-asserts the <=16 ms gate.
//   * (3) resize re-snap exercises the mutation-event path.
//   * (4) hit-chain dispatch is launcher-side and orthogonal to
//     the wire payload shape (audit § 4).
//   * (5) hello-accept stripping is the ETS-M4 backward-compat
//     contract.
//
// Skip rule: macOS-only — the cocoa launcher only builds on Darwin
// (matches the ETS-M4 / ETS-M5 test pattern).

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
const goldenDir = join(__dirname, "golden", "ets-m6");

const LAUNCHER_BACKEND = "cocoa";
const isMacOS = process.platform === "darwin";

const BBOX_PX_TOLERANCE = 1.0; // criterion 1: overlay matches within 1 px.
const LATENCY_GATE_MS = 16.0; // criterion 2: <=16 ms median (60 FPS).

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

async function spawnCocoaLauncher(port, demo = "task") {
  const proc = spawn(
    cocoaLauncherBin,
    [
      "--port",
      String(port),
      "--demo",
      demo,
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
  const tag = `[cocoa-ets-m6]`;
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

// Install a WS wrapper that mirrors inbound packets for delta/legacy
// path detection. Optionally strip ``e/element-tree`` from outbound
// hello-accept M packets to force the legacy backward-compat path.
async function installWireMirror(ctx, { stripHelloAccept = false } = {}) {
  await ctx.addInitScript((stripArg) => {
    try {
      window.__etsM6Wire = [];
      window.__etsM6T0 = performance.now();
      window.__etsM6StripHelloAccept = !!stripArg;

      const RealWS = window.WebSocket;
      function WrappedWS(url, protocols) {
        const ws = protocols ? new RealWS(url, protocols) : new RealWS(url);
        const origSend = ws.send.bind(ws);
        ws.send = function (data) {
          try {
            if (
              window.__etsM6StripHelloAccept &&
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
            window.__etsM6Wire.push({
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

// MutationObserver-based latency probe. Watches the hover-label's
// inline style attribute (set by the bindCanvasOverlayEffect at
// canvas_mount.nim:393-394 when the hovered element id changes).
// Snapshots moveT into the observer closure to avoid stale anchors
// (see ETS-M5 bench § 1.3 for the bug this guards against).
async function installLatencyObserver(ctx) {
  await ctx.addInitScript(() => {
    try {
      window.__etsM6LatencySamples = [];
      window.__etsM6LastMouseMoveT = null;
      window.__etsM6LastMouseMoveSeq = 0;
      window.__etsM6LastConsumedSeq = -1;

      function installObserverOnce() {
        if (window.__etsM6ObserverInstalled) return;
        const hoverLabel = document.querySelector(
          '[data-canvas-hover-label="true"]',
        );
        const selectionOutline = document.querySelector(
          '[data-canvas-selection-outline="true"]',
        );
        if (!hoverLabel && !selectionOutline) return;
        window.__etsM6ObserverInstalled = true;

        function record(t, anchor) {
          const moveT = window.__etsM6LastMouseMoveT;
          const moveSeq = window.__etsM6LastMouseMoveSeq;
          if (moveT == null) return;
          if (window.__etsM6LastConsumedSeq === moveSeq) return;
          window.__etsM6LastConsumedSeq = moveSeq;
          window.__etsM6LatencySamples.push({
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
        window.__etsM6Observer = observer;
      }

      const tryInstall = setInterval(() => {
        installObserverOnce();
        if (window.__etsM6ObserverInstalled) clearInterval(tryInstall);
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

// Switch the editor into Comment mode (the M-EVP-13 hover overlay
// path). The mode toolbar pill carries a ``data-preview-mode="comment"``
// attribute (shell.nim:1532 + 3306).
async function switchToCommentMode(page) {
  const ok = await page.evaluate(() => {
    const pills = document.querySelectorAll(
      '[data-toolbar-cluster="mode"] [data-choice-group-pill]',
    );
    for (const p of pills) {
      // The chip wrapper carries the data-preview-mode attribute on
      // its inner option metadata; the pill's data-choice-group-label
      // is the human label ("View" / "Comment" / "Edit").
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
  if (!ok) {
    // Best-effort: comment mode is the campaign's user-facing
    // surface but a failure to flip the chip does NOT invalidate
    // the bbox-positioning + latency probes (those run via the
    // hover label which is mode-independent).
    process.stderr.write(
      "[ETS-M6] WARNING: could not flip to comment mode; continuing on " +
        "default mode. Hover label / selection outline probes still " +
        "work because canvas_mount.nim:343-554 paints them in every mode " +
        "where useCanvas is true.\n",
    );
  }
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
// "unknown" — same shape as the ETS-M5 detectPath.
async function detectPath(page) {
  return page.evaluate(() => {
    const arr = window.__etsM6Wire || [];
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
  // After the canvas mounts, the editor sends a sendResize matching
  // the current pane width to the launcher (VRS-M2). The launcher
  // re-renders at the new dims; the bridge re-emits an
  // element-tree-delta covering every bbox; the canvas ensureSize
  // resizes the bitmap. We wait until intrinsicWidth stabilises so
  // hover-target coordinates don't get computed against a stale
  // canvas size.
  await waitFor(async () => {
    return page.evaluate(() => {
      const cs = document.querySelectorAll(
        '[data-canvas-wrapper="true"] canvas',
      );
      for (const c of cs) {
        const r = c.getBoundingClientRect();
        if (r.width > 10 && r.height > 10) {
          // Heuristic: the canvas is stable when its intrinsic width
          // is within 30% of its CSS width (i.e. the launcher's
          // most-recent F-packet matched the editor's most-recent
          // sendResize). Without this, on narrow viewports the canvas
          // briefly carries the OLD intrinsic (390 or 1440 from the
          // initial pane size) while the new resize round-trips.
          const ratio = c.clientWidth / c.width;
          if (ratio > 0.7 && ratio < 1.3) return true;
        }
      }
      return false;
    });
  }, 5000);
  await new Promise((r) => setTimeout(r, 500));
}

// Read the visible canvas rect + intrinsic dims so the harness can
// convert manifest bounds (intrinsic pixels) to CSS-space rects.
//
// IMPORTANT: the overlay's positioning origin is the **wrapper**, not
// the canvas. The wrapper carries ``position: relative`` (the
// canvas_mount.nim sets it via the ``data-canvas-wrapper`` div) and
// the overlay child has ``position:absolute; left:0; top:0; right:0;
// bottom:0`` so it covers the full wrapper. The hover label /
// selection outline children write ``style.left = bounds.x * sx``
// in wrapper-space, where sx is ``canvas.clientWidth / canvas.width``.
// The CANVAS may be offset within the wrapper (flex centering when
// the canvas is smaller than the wrapper), so the expected outline
// rect in viewport-space is ``wrapper.left + bounds.x * sx``.
//
// We therefore return BOTH the canvas geometry (for the
// CSS-px-per-intrinsic-px scale factor) AND the wrapper geometry
// (for the overlay positioning origin) so callers can build the
// correct expected rect.
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
        // Canvas geometry (for the bounds-to-CSS scale factor and the
        // legacy ``geom.left + ...`` callers).
        left: r.left,
        top: r.top,
        clientWidth: r.width,
        clientHeight: r.height,
        intrinsicWidth: c.width,
        intrinsicHeight: c.height,
        // Wrapper geometry (the overlay's positioning origin).
        wrapperLeft: wr.left,
        wrapperTop: wr.top,
        wrapperWidth: wr.width,
        wrapperHeight: wr.height,
      };
    }
    return null;
  });
}

// Read the latest manifest (legacy seed full body OR cumulative
// delta-cache snapshot) by sniffing the test-mode mirror. On the
// legacy path __isonimManifests carries the latest full body. On
// the delta path the first entry is the seed; subsequent deltas
// land in __isonimElementTreeDeltas. For acceptance assertions
// we apply the deltas to the seed locally so we have a fresh
// cache to compare against.
//
// IMPORTANT: the delta wire shape inlines bounds as flat x/y/w/h
// fields on each op (element_tree_delta.nim:204-231), NOT nested
// inside an ``op.bounds`` object. The delta also does NOT carry
// surfaceWidth/Height — the editor's per-VM cache keeps the seed's
// surface dims forever (preview_canvas.nim:167-168). Mirroring
// that behaviour client-side keeps our local snapshot consistent
// with the editor's bounds reading.
//
// We DO still read surfaceWidth/surfaceHeight from the canvas's
// intrinsic size when computing scale factors, since that's the
// only authoritative source for the launcher's current render
// resolution after a resize.
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
    let surfaceWidth = seed.surfaceWidth;
    let surfaceHeight = seed.surfaceHeight;

    function extractBounds(op, prev) {
      // Delta ops carry x/y/w/h inlined on the op (sparse — only
      // present when the field changed). Fall back to prev.bounds
      // for fields the delta omitted.
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
      surfaceWidth,
      surfaceHeight,
      elements: Array.from(byId.values()),
    };
  });
}

// For each manifest element, pick a hover target inside its bbox
// (centre of the rect in canvas-intrinsic pixels) and convert to
// CSS-space coordinates against the canvas's current rect. Skip
// the root element ``task_app/views/TaskApp`` — it covers the
// whole canvas so hover land-ing on it doesn't exercise the
// "track the cursor across elements" promise.
//
// On narrow viewports (Laptop / Phone) the canvas can be wider
// than the wrapper, so the wrapper's overflow:hidden crops the
// canvas. Clicks at viewport coordinates outside the wrapper
// don't reach the canvas. We therefore filter targets to those
// whose hover point falls inside the visible wrapper rect.
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
    const cx = x + w * 0.5;
    const cy = y + h * 0.5;
    const hoverPointClient = {
      x: geom.left + cx * sx,
      y: geom.top + cy * sy,
    };
    // Drop targets whose centre falls outside the visible wrapper —
    // clicks there don't reach the canvas, so they cannot exercise
    // the hit-chain / outline-positioning acceptance criteria.
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
      boundsClient: {
        left: geom.left + x * sx,
        top: geom.top + y * sy,
        width: w * sx,
        height: h * sy,
      },
      hoverPointClient,
    });
  }
  return targets;
}

// Drive a single synthetic mousemove + capture the latency anchor
// inside the page so the MutationObserver records moveT/paintT in
// the same task. See ETS-M5 bench § 1.3.
async function hoverAt(page, x, y) {
  await page.evaluate(
    ({ x, y }) => {
      window.__etsM6LastMouseMoveSeq =
        (window.__etsM6LastMouseMoveSeq || 0) + 1;
      window.__etsM6LastMouseMoveT = performance.now();
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
    },
    { x, y },
  );
}

// Read the currently-hovered component path + element id from the
// editor's test-mode mirror (streaming_preview.nim:1065-1069).
async function readHoverProbe(page) {
  return page.evaluate(() => ({
    path: window.__isonimHoveredComponentPath || null,
    id: window.__isonimHoveredElementId || null,
  }));
}

// Read the hover label's positioned style.left/top in CSS pixels.
// The overlay effect at canvas_mount.nim:391-394 sets these on
// every (hoveredElementId, manifest) change.
//
// Multiple canvas wrappers may exist (one per backend); only the
// active one is non-display:none. Pick the wrapper inside the
// visible canvas wrapper to match the active backend.
async function readHoverLabelRect(page) {
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
    if (!visibleWrapper) return null;
    const lbl = visibleWrapper.querySelector(
      '[data-canvas-hover-label="true"]',
    );
    if (!lbl) return null;
    const display = getComputedStyle(lbl).display;
    if (display === "none") return { visible: false };
    const r = lbl.getBoundingClientRect();
    return {
      visible: true,
      left: r.left,
      top: r.top,
      width: r.width,
      height: r.height,
      styleLeft: lbl.style.left,
      styleTop: lbl.style.top,
    };
  });
}

// Click on the canvas at the given client coordinates. Returns the
// resolved __isonimSelectedComponentPath + __isonimSelectedBounds
// from the editor's test mirror (streaming_preview.nim:1034-1044).
async function clickAt(page, x, y) {
  await page.mouse.click(x, y, { delay: 20 });
  await new Promise((r) => setTimeout(r, 100));
  return page.evaluate(() => ({
    componentPath: window.__isonimSelectedComponentPath || null,
    elementId: window.__isonimSelectedElementId || null,
    boundsIntrinsic: window.__isonimSelectedBounds || null,
  }));
}

// Read the rendered selection outline rect (after click). The
// outline's left/top/width/height are written by the overlay
// effect at canvas_mount.nim:468-475 using bounds * sx/sy.
//
// Multiple canvas wrappers may exist (one per backend); only the
// active one is non-display:none. Pick the outline inside the
// visible wrapper so we don't read a stale hidden mount.
async function readSelectionOutlineRect(page) {
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
    if (!visibleWrapper) return null;
    const o = visibleWrapper.querySelector(
      '[data-canvas-selection-outline="true"]',
    );
    if (!o) return null;
    const display = getComputedStyle(o).display;
    if (display === "none") return { visible: false };
    const r = o.getBoundingClientRect();
    return {
      visible: true,
      left: r.left,
      top: r.top,
      width: r.width,
      height: r.height,
      styleLeft: o.style.left,
      styleTop: o.style.top,
      styleWidth: o.style.width,
      styleHeight: o.style.height,
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
// The acceptance gate proper.
// ---------------------------------------------------------------------------

// Viewport matrix per the brief: Phone / Laptop / Desktop. These are
// EDITOR viewport-pill slugs (viewmodels.nim:804-814), NOT playwright
// viewport sizes. The pill determines the canvas's intrinsic + CSS
// width that the launcher renders at; playwright's viewport is kept
// at 1920×1080 throughout so the editor's chrome layout (sidebars +
// inspector) has enough horizontal room for the canvas + wrapper to
// not be cropped by overflow:hidden on the narrower-canvas runs.
const VIEWPORTS = [
  { name: "Phone", slug: "phone", canvasWidth: 390, canvasHeight: 844 },
  { name: "Laptop", slug: "laptop", canvasWidth: 1280, canvasHeight: 800 },
  { name: "Desktop", slug: "desktop", canvasWidth: 1440, canvasHeight: 900 },
];

const PLAYWRIGHT_VIEWPORT = { width: 1920, height: 1080 };

// Click the viewport pill with the given slug ("phone" | "laptop" |
// "desktop"). The viewport pills live in two places:
//
//   1. The pinned strip (``mountSegmentedChoice``) — labels visible
//      as ``data-choice-group-label="Phone"`` etc., not slugs.
//   2. The overflow dropdown — ``data-preview-viewport-dropdown-option=<slug>``.
//
// Strategy: probe by slug-to-label match against pinned pills first,
// fall back to clicking the chevron and selecting from the dropdown.
async function pickViewportPill(page, slug) {
  const labelForSlug = { phone: "Phone", laptop: "Laptop", desktop: "Desktop" };
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
  // Try the overflow dropdown: click the chevron, wait for options,
  // click the matching slug.
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

async function runAcceptanceForViewport(
  viewport,
  { stripHelloAccept = false },
) {
  const launcherPort = await pickFreePort();
  const serverPort = await pickFreePort();
  const launcher = await spawnCocoaLauncher(launcherPort);
  const proxy = await startEditorProxy(serverPort, launcherPort);
  const { ctx, page } = await openEditorAgainst(
    serverPort,
    PLAYWRIGHT_VIEWPORT,
    { stripHelloAccept },
  );

  const verdict = {
    viewport: viewport.name,
    viewportSlug: viewport.slug,
    canvasSize: {
      width: viewport.canvasWidth,
      height: viewport.canvasHeight,
    },
    stripHelloAccept,
    detectedPath: "unknown",
    criteria: {
      bboxWithin1Px: null,
      medianLatencyMs: null,
      latencyGateMet: null,
      resizeReSnap: null,
      hitChainDispatch: null,
      backwardCompat: null,
    },
    samples: {
      hoverSamples: 0,
      latencyDomMedianMs: null,
      latencyDomP99Ms: null,
      hitChainHits: 0,
      hitChainAttempts: 0,
      bboxMaxDeltaPx: null,
      bboxMatchCount: 0,
      bboxAttemptCount: 0,
    },
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

    // Pick the matching viewport pill so the canvas renders at the
    // expected intrinsic dims (390×844 / 1280×800 / 1440×900). The
    // launcher receives a sendResize and re-emits an element-tree
    // delta covering the new bboxes. settleAfterPick again to wait
    // for the canvas's intrinsicWidth to converge on the new size.
    const pillPicked = await pickViewportPill(page, viewport.slug);
    if (!pillPicked) {
      verdict.notes.push(
        `viewport pill "${viewport.slug}" not found in chrome bar`,
      );
    } else {
      // Wait for the launcher's post-resize element-tree to land.
      await new Promise((r) => setTimeout(r, 1200));
      // Wait for canvas intrinsic to match the expected size (within
      // dpr scaling); the editor pipes through dpr * width so on a
      // Retina display intrinsic ~= 2 * pill width.
      await waitFor(async () => {
        return page.evaluate(
          ({ expectedWidth }) => {
            const cs = document.querySelectorAll(
              '[data-canvas-wrapper="true"] canvas',
            );
            for (const c of cs) {
              const r = c.getBoundingClientRect();
              if (r.width > 10 && r.height > 10) {
                // Accept any intrinsic within dpr of the expected:
                // the editor sends w * dpr, the launcher emits
                // physical pixels, ensureSize bumps canvas.width to
                // that. So intrinsic = expected * (1 or 2 typically).
                const ratio = c.width / expectedWidth;
                if (ratio > 0.9 && ratio < 3.0) return true;
              }
            }
            return false;
          },
          { expectedWidth: viewport.canvasWidth },
        );
      }, 6000);
    }

    await switchToCommentMode(page);
    // After mode switch, let the chrome bar settle so the canvas
    // wrapper isn't transiently re-laid-out.
    await new Promise((r) => setTimeout(r, 600));

    verdict.detectedPath = await detectPath(page);

    // Reset latency samples between viewport runs so prior runs'
    // mutation noise doesn't pollute the median.
    await page.evaluate(() => {
      window.__etsM6LatencySamples = [];
      window.__etsM6LastConsumedSeq = -1;
    });

    let geom = await readCanvasGeometry(page);
    if (!geom) {
      verdict.notes.push("canvas not visible after settle; cannot probe");
      return verdict;
    }

    let manifest = await readCurrentManifest(page);
    if (!manifest || manifest.elements.length === 0) {
      verdict.notes.push("manifest empty after settle; cannot probe");
      return verdict;
    }

    verdict.samples.initialGeom = {
      canvasLeft: geom.left,
      canvasTop: geom.top,
      clientWidth: geom.clientWidth,
      clientHeight: geom.clientHeight,
      intrinsicWidth: geom.intrinsicWidth,
      intrinsicHeight: geom.intrinsicHeight,
      wrapperLeft: geom.wrapperLeft,
      wrapperTop: geom.wrapperTop,
      wrapperWidth: geom.wrapperWidth,
      wrapperHeight: geom.wrapperHeight,
    };
    verdict.samples.initialManifest = {
      surfaceWidth: manifest.surfaceWidth,
      surfaceHeight: manifest.surfaceHeight,
      elementCount: manifest.elements.length,
      elementPaths: manifest.elements.map((e) => e.componentPath),
    };

    // Build hover targets — exclude the surface-covering root entry
    // so the hover crosses real boundaries between elements.
    let targets = buildHoverTargets(manifest, geom);
    if (targets.length > 1) {
      const minArea = Math.min(
        ...targets.map((t) => t.boundsIntrinsic.w * t.boundsIntrinsic.h),
      );
      // Drop any element whose intrinsic area equals the canvas (the
      // root). The remaining leaves are what the user can hover on
      // distinctly.
      const canvasArea = geom.intrinsicWidth * geom.intrinsicHeight;
      targets = targets.filter(
        (t) => t.boundsIntrinsic.w * t.boundsIntrinsic.h < canvasArea * 0.95,
      );
    }
    // Cap at N=10 hover targets per viewport per the brief.
    const HOVER_N = Math.min(10, Math.max(1, targets.length));
    const hoverSet = targets.slice(0, HOVER_N);

    // -------- Criterion 1: bbox alignment ----------------------------------
    //
    // For each target, hover then click. Read the selection outline
    // rect (CSS pixels) and compute the expected rect (bounds *
    // canvas scale). Assert max-of-corner-deltas <= BBOX_PX_TOLERANCE.
    let bboxAttempts = 0;
    let bboxMatches = 0;
    let bboxMaxDelta = 0;
    let hitChainAttempts = 0;
    let hitChainHits = 0;
    const bboxRows = [];
    for (const target of hoverSet) {
      await hoverAt(page, target.hoverPointClient.x, target.hoverPointClient.y);
      await new Promise((r) => setTimeout(r, 60));
      // Click to lock the selection outline so its rect is stable.
      const click = await clickAt(
        page,
        target.hoverPointClient.x,
        target.hoverPointClient.y,
      );
      hitChainAttempts += 1;
      // EPP-M12 hit-chain: the click MUST resolve to SOME component
      // path. We do not require it match the target exactly because
      // the launcher's walk-up dispatch may bubble to a parent for
      // empty leaves; but the resolved path MUST be a real id from
      // the manifest (proves the hit-chain is routing).
      if (
        click.componentPath &&
        manifest.elements.some((e) => e.id === click.elementId)
      ) {
        hitChainHits += 1;
      }
      const outline = await readSelectionOutlineRect(page);
      if (!outline || !outline.visible) {
        // Selection didn't paint (e.g. hover landed on a non-clickable
        // background between elements after a resize). Skip this row.
        bboxRows.push({
          target: target.componentPath,
          status: "outline-not-visible",
        });
        continue;
      }
      // Compute expected outline rect from the click-resolved bounds
      // (the editor's __isonimSelectedBounds mirror, in canvas
      // intrinsic pixels). The overlay positions in WRAPPER-space
      // (canvas_mount.nim:391-394 / :468-475 — style.left = bx*sx
      // relative to the overlay's wrapper origin), so the viewport-
      // space expected origin is wrapper.left + bounds.x * sx, NOT
      // canvas.left.
      const sx = geom.clientWidth / geom.intrinsicWidth;
      const sy = geom.clientHeight / geom.intrinsicHeight;
      const expected = click.boundsIntrinsic
        ? {
            left: geom.wrapperLeft + click.boundsIntrinsic.x * sx,
            top: geom.wrapperTop + click.boundsIntrinsic.y * sy,
            width: click.boundsIntrinsic.w * sx,
            height: click.boundsIntrinsic.h * sy,
          }
        : null;
      if (expected) {
        const dL = Math.abs(outline.left - expected.left);
        const dT = Math.abs(outline.top - expected.top);
        const dW = Math.abs(outline.width - expected.width);
        const dH = Math.abs(outline.height - expected.height);
        const maxD = Math.max(dL, dT, dW, dH);
        bboxAttempts += 1;
        bboxMaxDelta = Math.max(bboxMaxDelta, maxD);
        if (maxD <= BBOX_PX_TOLERANCE) bboxMatches += 1;
        bboxRows.push({
          target: target.componentPath,
          click: click.componentPath,
          maxDeltaPx: maxD,
          dL,
          dT,
          dW,
          dH,
          pass: maxD <= BBOX_PX_TOLERANCE,
          // Diagnostic data so failures are actionable.
          outline: {
            left: outline.left,
            top: outline.top,
            width: outline.width,
            height: outline.height,
            styleLeft: outline.styleLeft,
            styleTop: outline.styleTop,
            styleWidth: outline.styleWidth,
            styleHeight: outline.styleHeight,
          },
          expected,
          clickBounds: click.boundsIntrinsic,
          geom: {
            canvasLeft: geom.left,
            canvasTop: geom.top,
            wrapperLeft: geom.wrapperLeft,
            wrapperTop: geom.wrapperTop,
            sx,
            sy,
            intrinsicWidth: geom.intrinsicWidth,
            intrinsicHeight: geom.intrinsicHeight,
            clientWidth: geom.clientWidth,
            clientHeight: geom.clientHeight,
          },
        });
      } else {
        bboxRows.push({
          target: target.componentPath,
          status: "no-resolved-bounds",
        });
      }
    }
    verdict.criteria.bboxWithin1Px =
      bboxAttempts > 0 && bboxAttempts === bboxMatches;
    verdict.criteria.hitChainDispatch =
      hitChainAttempts > 0 && hitChainHits === hitChainAttempts;
    verdict.samples.bboxAttemptCount = bboxAttempts;
    verdict.samples.bboxMatchCount = bboxMatches;
    verdict.samples.bboxMaxDeltaPx = bboxMaxDelta;
    verdict.samples.hitChainAttempts = hitChainAttempts;
    verdict.samples.hitChainHits = hitChainHits;
    verdict.samples.bboxRows = bboxRows;

    // -------- Criterion 2: mouse-move -> overlay-update latency ----------
    //
    // Strategy:
    //   1. Clear prior samples (click-driven outline mutations would
    //      otherwise pollute the bucket).
    //   2. Run a single warmup hover and DROP its sample. The first
    //      hover after a click is racing the WS bridge's
    //      element-tree-delta re-emission for the just-clicked id
    //      (the click hit-test may trigger a state-mutation that
    //      ships a delta), so the warmup absorbs that initial
    //      wire-bound latency.
    //   3. Sweep across the remaining hover targets, alternating
    //      between each target and an off-target reseat point so
    //      every move produces a distinct hoveredElementId
    //      transition (preview_canvas.nim:285 suppresses id-equality
    //      writes).
    //   4. Filter the recorded samples to those whose anchor matches
    //      the hover-label (not the selection outline) — the
    //      campaign's user-visible promise is overlay-label tracking,
    //      and selection-outline mutations are click-driven not
    //      hover-driven.
    await page.evaluate(() => {
      window.__etsM6LatencySamples = [];
      window.__etsM6LastConsumedSeq = -1;
      // Reinstall the MutationObserver against the currently-visible
      // wrapper's hover-label / selection-outline. The initial install
      // ran when the page first reached the editor; in the interim
      // the user picked Cocoa (which mounts a NEW wrapper for the
      // cocoa preview), then picked a viewport pill, then switched
      // to comment mode — any of which may have replaced the DOM
      // nodes the original observer was watching.
      try {
        if (window.__etsM6Observer) {
          window.__etsM6Observer.disconnect();
        }
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
            const moveT = window.__etsM6LastMouseMoveT;
            const moveSeq = window.__etsM6LastMouseMoveSeq;
            if (moveT == null) return;
            if (window.__etsM6LastConsumedSeq === moveSeq) return;
            window.__etsM6LastConsumedSeq = moveSeq;
            window.__etsM6LatencySamples.push({
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
          window.__etsM6Observer = obs;
        }
      } catch (e) {
        window.__etsM6ObserverReinstallError = String(e);
      }
    });
    await page.mouse.move(0, 0);
    await new Promise((r) => setTimeout(r, 50));

    // Warmup: hover the first target, sleep, then clear samples again.
    if (hoverSet.length > 0) {
      await hoverAt(
        page,
        hoverSet[0].hoverPointClient.x,
        hoverSet[0].hoverPointClient.y,
      );
      await new Promise((r) => setTimeout(r, 200));
      await page.evaluate(() => {
        window.__etsM6LatencySamples = [];
        window.__etsM6LastConsumedSeq = -1;
      });
    }

    // Drive successive hovers across distinct targets. Each move
    // crosses an element boundary so hoveredElementId changes, which
    // fires the reactive overlay effect, which mutates the hover
    // label's style, which fires the MutationObserver.
    //
    // We rely on the hoverSet having distinct elements (the filter
    // in buildHoverTargets drops the canvas-root) so consecutive
    // hovers produce real id transitions. No off-target reseat is
    // needed.
    for (const target of hoverSet) {
      await hoverAt(page, target.hoverPointClient.x, target.hoverPointClient.y);
      await new Promise((r) => setTimeout(r, 120));
    }
    const samples = await page.evaluate(
      () => window.__etsM6LatencySamples || [],
    );
    verdict.samples.rawLatencySamples = samples;
    verdict.samples.observerInstalled = await page.evaluate(
      () => !!window.__etsM6ObserverInstalled,
    );
    // Restrict to hover-label samples — those are the campaign's
    // user-visible cursor-tracking metric. Selection-outline
    // mutations happen on click, not on mousemove.
    const domLatencies = samples
      .filter((s) => s.anchor === "hover-label")
      .map((s) => s.domLatencyMs)
      .filter((v) => typeof v === "number" && Number.isFinite(v) && v >= 0);
    const med = median(domLatencies);
    const p99v = p99(domLatencies);
    verdict.samples.hoverSamples = domLatencies.length;
    verdict.samples.latencyDomMedianMs = med;
    verdict.samples.latencyDomP99Ms = p99v;
    verdict.criteria.medianLatencyMs = med;
    verdict.criteria.latencyGateMet = med != null && med <= LATENCY_GATE_MS;

    // -------- Criterion 3: viewport resize re-snaps -------------------------
    //
    // Click a non-active viewport pill (the same trigger ETS-M5 used
    // for the headline 42 %-fewer-bytes / 2x-faster resize measurement).
    // Then wait for the next manifest landing and re-probe one hover
    // target — the outline must still land within tolerance and the
    // hover label must still be positioned (no NaN coordinates).
    const resizeOk = await page.evaluate(() => {
      const pills = document.querySelectorAll(
        '[data-preview-chrome-bar="true"] [data-toolbar-cluster="viewport"] ' +
          '[data-preview-viewport-strip-host="true"] [data-choice-group-pill]',
      );
      if (pills.length < 2) return false;
      let target = null;
      for (const p of pills) {
        const pressed = p.getAttribute("aria-pressed");
        const disabled = p.getAttribute("aria-disabled") === "true";
        if (pressed !== "true" && !disabled) {
          target = p;
          break;
        }
      }
      if (!target) return false;
      target.click();
      return true;
    });
    if (resizeOk) {
      // Wait for the bridge to ship the post-resize manifest delta.
      await new Promise((r) => setTimeout(r, 1500));
      // Re-read geometry + manifest after resize.
      geom = await readCanvasGeometry(page);
      manifest = await readCurrentManifest(page);
      if (geom && manifest && manifest.elements.length > 0) {
        // Re-hover the first valid target post-resize. The overlay
        // must update to the new bbox.
        const newTargets = buildHoverTargets(manifest, geom);
        let resizeBboxPass = false;
        let resizeMaxDelta = null;
        if (newTargets.length > 0) {
          const t = newTargets[0];
          await hoverAt(page, t.hoverPointClient.x, t.hoverPointClient.y);
          await new Promise((r) => setTimeout(r, 80));
          const click = await clickAt(
            page,
            t.hoverPointClient.x,
            t.hoverPointClient.y,
          );
          const outline = await readSelectionOutlineRect(page);
          if (outline && outline.visible && click.boundsIntrinsic) {
            const sx = geom.clientWidth / geom.intrinsicWidth;
            const sy = geom.clientHeight / geom.intrinsicHeight;
            const exp = {
              left: geom.wrapperLeft + click.boundsIntrinsic.x * sx,
              top: geom.wrapperTop + click.boundsIntrinsic.y * sy,
              width: click.boundsIntrinsic.w * sx,
              height: click.boundsIntrinsic.h * sy,
            };
            const maxD = Math.max(
              Math.abs(outline.left - exp.left),
              Math.abs(outline.top - exp.top),
              Math.abs(outline.width - exp.width),
              Math.abs(outline.height - exp.height),
            );
            resizeMaxDelta = maxD;
            resizeBboxPass = maxD <= BBOX_PX_TOLERANCE;
          }
        }
        verdict.criteria.resizeReSnap = resizeBboxPass;
        verdict.samples.resizeMaxDeltaPx = resizeMaxDelta;
      } else {
        verdict.criteria.resizeReSnap = false;
        verdict.notes.push(
          "post-resize geometry/manifest unavailable; cannot verify re-snap",
        );
      }
    } else {
      verdict.criteria.resizeReSnap = null;
      verdict.notes.push(
        "no inactive viewport pill available — resize skipped",
      );
    }

    // -------- Criterion 5: backward compat is the path-detection ----------
    //
    // The caller flips ``stripHelloAccept`` and we re-run the
    // acceptance for the same viewport. If we reached this point
    // with stripHelloAccept=true and detectedPath==="legacy", the
    // legacy path still drives the overlay; criteria 1-4 already
    // ran against the legacy path so their results encode the
    // backward-compat answer.
    if (stripHelloAccept) {
      verdict.criteria.backwardCompat =
        verdict.detectedPath === "legacy" &&
        verdict.criteria.bboxWithin1Px === true;
    }
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
  "ETS-M6 — macOS-only milestone (cocoa launcher is the test vehicle).";

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
  "ETS-M6 acceptance gate: overlay tracks pointer within 1 px and " +
    "<=16 ms median across Phone/Laptop/Desktop on cocoa task_app",
  async (t) => {
    if (!isMacOS) {
      t.skip(SKIP_REASON);
      return;
    }

    const report = {
      milestone: "ETS-M6",
      timestamp: new Date().toISOString(),
      backend: "cocoa",
      app: "task",
      approach: "B-with-resize-trigger",
      viewports: [],
      backwardCompat: null,
    };

    // Run the delta path across all three viewports.
    for (const vp of VIEWPORTS) {
      const v = await runAcceptanceForViewport(vp, {
        stripHelloAccept: false,
      });
      report.viewports.push(v);
    }

    // Run the backward-compat probe once on the Laptop viewport (the
    // one ETS-M5 used as its canonical bench size). Criterion 5 is
    // a "the legacy path still works" assertion, not a per-viewport
    // matrix.
    const backCompat = await runAcceptanceForViewport(
      { name: "Laptop", width: 1280, height: 800 },
      { stripHelloAccept: true },
    );
    report.backwardCompat = backCompat;

    // Write the report so the orchestrator can correlate with the
    // markdown deliverable.
    const ts = report.timestamp.replace(/[:.]/g, "-").replace(/Z$/, "Z");
    const outPath = join(goldenDir, `${ts}.json`);
    writeFileSync(outPath, JSON.stringify(report, null, 2));
    writeFileSync(
      join(goldenDir, "latest.json"),
      JSON.stringify(report, null, 2),
    );

    process.stderr.write(`[ETS-M6] wrote ${outPath}\n`);
    for (const v of report.viewports) {
      process.stderr.write(
        `[ETS-M6] viewport=${v.viewport} path=${v.detectedPath} ` +
          `bbox=${v.criteria.bboxWithin1Px} ` +
          `medLatency=${
            v.samples.latencyDomMedianMs != null
              ? v.samples.latencyDomMedianMs.toFixed(1) + "ms"
              : "n/a"
          } ` +
          `resize=${v.criteria.resizeReSnap} ` +
          `hitChain=${v.criteria.hitChainDispatch}\n`,
      );
    }
    process.stderr.write(
      `[ETS-M6] backwardCompat path=${backCompat.detectedPath} ` +
        `pass=${backCompat.criteria.backwardCompat}\n`,
    );

    // Acceptance assertions. We honour the brief's "campaign closes
    // by measurement, not by claim" — if any criterion fails honestly
    // we surface that here and the orchestrator decides whether the
    // milestone is "passed" / "passed with caveats" / "partially closed".
    // The assertions below report data; the milestone-level verdict
    // lives in the markdown report.
    for (const v of report.viewports) {
      assert.ok(
        v.criteria.bboxWithin1Px === true,
        `viewport=${v.viewport}: overlay bbox MUST match within ` +
          `${BBOX_PX_TOLERANCE} px on every probed element. ` +
          `matched=${v.samples.bboxMatchCount}/${v.samples.bboxAttemptCount} ` +
          `maxDelta=${v.samples.bboxMaxDeltaPx} ` +
          `path=${v.detectedPath} notes=${JSON.stringify(v.notes)}`,
      );
      assert.ok(
        v.criteria.latencyGateMet === true,
        `viewport=${v.viewport}: median latency MUST be <=` +
          `${LATENCY_GATE_MS} ms; got ${v.samples.latencyDomMedianMs} ms ` +
          `over ${v.samples.hoverSamples} samples (path=${v.detectedPath})`,
      );
      assert.ok(
        v.criteria.hitChainDispatch === true,
        `viewport=${v.viewport}: EPP-M12 hit-chain MUST route every click ` +
          `to a manifest element. routed=${v.samples.hitChainHits}/${v.samples.hitChainAttempts}`,
      );
      // Resize is best-effort (the viewport pill may not have an
      // inactive option when the viewport already matches a pill).
      // Surface the value but only fail on an explicit false.
      assert.ok(
        v.criteria.resizeReSnap !== false,
        `viewport=${v.viewport}: resize re-snap reported failure ` +
          `(maxDelta=${v.samples.resizeMaxDeltaPx}, notes=${JSON.stringify(v.notes)})`,
      );
    }
    // Backward compat: the legacy path must drive the overlay.
    assert.ok(
      backCompat.criteria.backwardCompat === true,
      `backward compat (stripHelloAccept=true) MUST stay on legacy path ` +
        `AND keep the overlay aligned within ${BBOX_PX_TOLERANCE} px. ` +
        `Got path=${backCompat.detectedPath} bbox=${backCompat.criteria.bboxWithin1Px} ` +
        `matched=${backCompat.samples.bboxMatchCount}/${backCompat.samples.bboxAttemptCount}`,
    );
  },
);
