// VRS-M2 — editor sends an I-framed JSON `{type:"resize", width, height}`
// message over the WebSocket bridge whenever the user clicks a viewport
// pill (and once when the bridge first attaches, so a freshly-spawned
// launcher learns the user's current viewport pill immediately).
//
// What this test exercises end-to-end:
//
//   1. Build the editor bundle (`just editor-build` in
//      ~/metacraft/isonim-examples).
//   2. Start a tiny Node-side mock launcher that
//      a) serves the editor's static files on a chosen port,
//      b) accepts WebSocket upgrades at `/bridge/gpui`,
//      c) sends the launcher-side `hello` M packet on connect
//         (so the editor's BridgeClientHandle stays open),
//      d) records every inbound I packet's UTF-8 JSON body.
//   3. Drive the editor in headless Chromium:
//      a) wait for the chrome bar,
//      b) click the GPUI backend pill so `vm.platform.val = pbGpui`
//         and the editor attaches the bridge,
//      c) select a Page story from the sidebar so the page-preview
//         canvas mount runs its render effect,
//      d) click a viewport pill (default first non-default pill,
//         e.g. Laptop or Phone).
//   4. Assert the mock launcher recorded:
//      - at least one `{type:"resize"}` I packet whose width/height
//        match a known builtin viewport (the spec lists Desktop=1440x900,
//        Laptop=1280x800, Tablet=1024x768, Phone=390x844),
//      - the EXACT bytes match `encodeResizeBody(W, H)`'s JSON
//        (`{"type":"resize","width":<W>,"height":<H>}`).
//
// Why this is the right shape:
//   * The audit (VRS-M1 § 2.2) confirmed the editor's JS shim NEVER
//     sent a `resize` I packet before VRS-M2. So the existence of any
//     I packet with `type:"resize"` from the editor proves the
//     publisher path is wired.
//   * The launcher side is verified separately (VRS-M3+); this test
//     intentionally does NOT spawn the real launcher binary, because
//     VRS-M2's scope is the editor-side sender only. A real-launcher
//     end-to-end test lives in VRS-M4+ (per-backend) and VRS-M10
//     (acceptance).
//   * The mock launcher is a REAL WebSocket server — we are NOT
//     running an in-process WS shim. The editor opens a real WS
//     connection through Chromium and the launcher decodes the
//     RFC-6455 frames via the `ws` package (which Playwright already
//     ships with). Per the campaign brief's "real-environment tests
//     only" rule.
//
// Convention: `node --test` (not `npx playwright test`) — matches the
// rest of `isonim/tests/browser/e2e_*.mjs`.

import { execSync, spawn } from "node:child_process";
import { existsSync } from "node:fs";
import { createServer } from "node:http";
import { readFileSync } from "node:fs";
import { dirname, extname, join } from "node:path";
import { fileURLToPath } from "node:url";
import test from "node:test";
import assert from "node:assert/strict";
import { WebSocketServer } from "ws";

const __dirname = dirname(fileURLToPath(import.meta.url));
const isonimRoot = join(__dirname, "..", "..");
const isonimExamplesRoot = join(isonimRoot, "..", "isonim-examples");
const editorBuildDir = join(isonimExamplesRoot, "build", "editor");

const SERVER_PORT = 18681;
const RESIZE_BACKEND = "gpui";

function exec(cmd, opts = {}) {
  return execSync(cmd, { stdio: "pipe", ...opts }).toString();
}

function buildEditor() {
  exec("direnv exec . just editor-build", { cwd: isonimExamplesRoot });
  if (!existsSync(join(editorBuildDir, "editor.js"))) {
    throw new Error("editor.js was not produced by `just editor-build`");
  }
  if (!existsSync(join(editorBuildDir, "index.html"))) {
    throw new Error("index.html was not produced by `just editor-build`");
  }
}

// Build the launcher → browser `hello` M packet so the editor's
// BridgeClientHandle stays alive. Mirrors the wire schema documented
// in the VRS-M1 audit § 2.1 (transport framing) — initialSize is the
// launcher's default surface dims; the test asserts the editor later
// REPLACES these via a resize I packet.
function buildHelloMPacket(backend) {
  const json = JSON.stringify({
    type: "hello",
    protocolVersion: 1,
    backend,
    capabilities: {},
    initialSize: { width: 800, height: 600 },
  });
  const bodyBytes = Buffer.from(json, "utf-8");
  const length = bodyBytes.length;
  const header = Buffer.alloc(5);
  header[0] = 0x4d; // 'M'
  header.writeUInt32LE(length, 1);
  return Buffer.concat([header, bodyBytes]);
}

// MIME-type heuristic. We do NOT use a dependency — the editor build
// only emits `.html`, `.js`, `.css`, and the vendored xterm + tiptap
// bundles, so a tiny table is enough.
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

// Start the unified HTTP + WebSocket mock launcher. Returns a handle
// with: server (http.Server), wss (WebSocketServer), recorded (the
// list of decoded inbound JSON bodies), and shutdown().
async function startMockLauncher() {
  const recorded = [];
  const server = createServer((req, res) => {
    if (req.method !== "GET") {
      res.writeHead(405);
      res.end();
      return;
    }
    let p = req.url.split("?")[0];
    if (p === "/") p = "/index.html";
    // Path-traversal guard.
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
      res.writeHead(200, { "content-type": ct });
      res.end(body);
    } catch (e) {
      res.writeHead(500);
      res.end(String(e));
    }
  });

  const wss = new WebSocketServer({ noServer: true });
  wss.on("connection", (ws, req) => {
    // Send the launcher-side `hello` M packet immediately so the
    // editor's JS shim's `ensureSize(800, 600)` runs and the
    // BridgeClientHandle stays in OPEN. The editor sends nothing
    // back until the publishResize closure fires.
    try {
      ws.send(buildHelloMPacket(RESIZE_BACKEND));
    } catch (e) {
      console.error("[mock] hello send failed:", e.message);
    }
    ws.on("message", (data, isBinary) => {
      if (!isBinary || !Buffer.isBuffer(data)) return;
      if (data.length < 5) return;
      const kind = String.fromCharCode(data[0]);
      if (kind !== "I") return;
      const len = data.readUInt32LE(1);
      if (5 + len > data.length) return;
      const body = data.subarray(5, 5 + len).toString("utf-8");
      let node;
      try {
        node = JSON.parse(body);
      } catch (_) {
        return;
      }
      recorded.push({ raw: body, json: node });
    });
    ws.on("error", (e) => {
      // The test occasionally closes the page before clean-shutting
      // the WS — swallow.
      void e;
    });
  });

  server.on("upgrade", (req, socket, head) => {
    const p = req.url.split("?")[0];
    if (p === `/bridge/${RESIZE_BACKEND}`) {
      wss.handleUpgrade(req, socket, head, (ws) => {
        wss.emit("connection", ws, req);
      });
    } else {
      // Any other upgrade target is a no-op (e.g. `/bridge/cocoa`
      // when the editor mounts the cocoa pill first — we don't
      // record those because the test pins gpui).
      socket.destroy();
    }
  });

  await new Promise((resolve, reject) => {
    server.once("error", reject);
    server.listen(SERVER_PORT, "127.0.0.1", () => {
      server.off("error", reject);
      resolve();
    });
  });

  return {
    server,
    wss,
    recorded,
    shutdown: () =>
      new Promise((resolve) => {
        try {
          wss.close();
        } catch (_) {}
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

async function openEditor() {
  const b = await ensureBrowser();
  const ctx = await b.newContext({
    viewport: { width: 1440, height: 900 },
  });
  const page = await ctx.newPage();
  // Forward page logs to the test stderr for debugging.
  page.on("pageerror", (e) => console.error("[page] error:", e.message));
  await page.goto(`http://127.0.0.1:${SERVER_PORT}/index.html`);
  await page.waitForSelector('[data-preview-chrome-bar="true"]', {
    timeout: 15000,
  });
  await page.waitForSelector(
    '[data-toolbar-cluster="backend"] [data-choice-group-pill]',
    { timeout: 15000 },
  );
  await page.waitForSelector(
    '[data-toolbar-cluster="viewport"] [data-choice-group-pill]',
    { timeout: 15000 },
  );
  // Kill CSS transitions to remove timing flake.
  await page.addStyleTag({
    content:
      "*, *::before, *::after { transition: none !important;" +
      " animation: none !important; }",
  });
  return { ctx, page };
}

test.before(async () => {
  buildEditor();
});

test.after(async () => {
  try {
    if (browser) await browser.close();
  } catch (_) {}
});

// Locate a backend pill by its label (case-insensitive). Returns the
// fully-qualified selector or null when the pill isn't surfaced.
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

// Locate a viewport pill by its label. Returns selector + the (w,h)
// the spec table associates with that label so the assertion can
// match exactly.
async function viewportPillByLabel(page, labelRx) {
  return page.evaluate((rxSrc) => {
    const rx = new RegExp(rxSrc, "i");
    const pills = document.querySelectorAll(
      '[data-toolbar-cluster="viewport"] ' +
        '[data-preview-viewport-strip-host="true"] ' +
        "[data-choice-group-pill]",
    );
    for (const p of pills) {
      const lbl =
        p.getAttribute("data-choice-group-label") ||
        p.getAttribute("aria-label") ||
        p.textContent ||
        "";
      if (rx.test(lbl)) {
        return {
          selector: `[data-toolbar-cluster="viewport"] [data-preview-viewport-strip-host="true"] [data-choice-group-pill="${p.getAttribute(
            "data-choice-group-pill",
          )}"]`,
          label: lbl.trim(),
        };
      }
    }
    return null;
  }, labelRx);
}

// Build the byte-exact `encodeResizeBody(W, H)` reference. Mirrors
// the Nim implementation in `streaming_preview.nim:encodeResizeBody`
// (field order `type, width, height`, integer literals, no spaces).
function expectedResizeBody(w, h) {
  return `{"type":"resize","width":${w},"height":${h}}`;
}

test("editor sends a resize I packet matching the viewport pill", async () => {
  const mock = await startMockLauncher();
  const { ctx, page } = await openEditor();
  try {
    // Switch to GPUI. The chrome bar's backend cluster always
    // surfaces GPUI (it's universally available, see
    // detectAvailableBackends).
    const gpuiSel = await backendPillSelector(page, "gpui");
    assert.ok(gpuiSel, "GPUI backend pill should be present");
    await page.locator(gpuiSel).click();

    // Select the first sidebar story so the page-preview / canvas
    // mount has something to attach against. Without a selection,
    // the canvas pane stays display:none and the publisher closure
    // is never wired into a live bridge. Best-effort — if no story
    // row exists in this build the publisher still fires through
    // foundations_page/component_detail effects whenever their
    // useCanvas flips true, but the page-preview path is the
    // canonical exercise.
    await page.evaluate(() => {
      const row = document.querySelector("[data-story-row]");
      if (row) row.click();
    });

    // Wait for the bridge to attach + at least the initial
    // resize from the freshly-opened bridge to land. The default
    // viewport for GPUI is Desktop (1440x900) — see
    // `defaultViewport(pbGpui)` in viewmodels.nim.
    const desktopBody = expectedResizeBody(1440, 900);

    const waitFor = async (predicate, ms = 8000) => {
      const t0 = Date.now();
      while (Date.now() - t0 < ms) {
        if (predicate()) return true;
        await new Promise((r) => setTimeout(r, 50));
      }
      return false;
    };

    const sawInitial = await waitFor(() =>
      mock.recorded.some(
        (r) => r.json && r.json.type === "resize" && r.raw === desktopBody,
      ),
    );
    assert.ok(
      sawInitial,
      `expected an initial resize I packet matching ${desktopBody}; ` +
        `recorded so far: ${JSON.stringify(mock.recorded.map((r) => r.raw))}`,
    );

    // Now click a different viewport pill (Phone — 390x844 per
    // makeBuiltinViewport(pvkPhone)) and assert the publisher
    // fires the matching message.
    const phone = await viewportPillByLabel(page, "phone$|^phone\\b");
    // The strip pinned set is Desktop / Laptop / Tablet / Phone
    // for GPUI; "Phone" matches by exact label.
    assert.ok(phone, "Phone viewport pill should be in the GPUI strip");
    const recordedBefore = mock.recorded.length;
    await page.locator(phone.selector).click();

    const phoneBody = expectedResizeBody(390, 844);
    const sawPhone = await waitFor(() =>
      mock.recorded.some(
        (r) =>
          r.json &&
          r.json.type === "resize" &&
          r.raw === phoneBody &&
          mock.recorded.indexOf(r) >= recordedBefore,
      ),
    );
    assert.ok(
      sawPhone,
      `expected a resize I packet matching ${phoneBody} after Phone ` +
        `pill click; recorded since click: ${JSON.stringify(
          mock.recorded.slice(recordedBefore).map((r) => r.raw),
        )}`,
    );

    // Also click Laptop (1280x800) to confirm the publisher fires
    // for distinct pills — guards against a stuck cached (w,h).
    const laptop = await viewportPillByLabel(page, "laptop");
    if (laptop) {
      const before2 = mock.recorded.length;
      await page.locator(laptop.selector).click();
      const laptopBody = expectedResizeBody(1280, 800);
      const sawLaptop = await waitFor(() =>
        mock.recorded.some(
          (r) =>
            r.json &&
            r.json.type === "resize" &&
            r.raw === laptopBody &&
            mock.recorded.indexOf(r) >= before2,
        ),
      );
      assert.ok(
        sawLaptop,
        `expected a resize I packet matching ${laptopBody} after ` +
          `Laptop pill click; recorded since click: ${JSON.stringify(
            mock.recorded.slice(before2).map((r) => r.raw),
          )}`,
      );
    }
  } finally {
    try {
      await ctx.close();
    } catch (_) {}
    await mock.shutdown();
  }
});
