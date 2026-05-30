// ELT-M9 — W-diff packet end-to-end. The cocoa launcher booted with
// ``--encoder webp`` produces W-diff packets after the first frame
// (the bridge's per-frame selector prefers the diff variant once
// there is a prev-frame snapshot to diff against). The browser-side
// ``handleW`` branches on flag bit 1 (``isDiffRegion``), walks the
// rectangle list, and paints each rectangle at its (x, y) anchor.
//
// What this test asserts:
//
//   1. The W-diff path engages at all (the test-mode mirror
//      ``window.__isonimWDiffRectCounts`` accumulates one entry per
//      W-diff packet decoded).
//   2. The rectangle count distribution matches the diff-region
//      contract: the heartbeat (zero rects) case appears often on a
//      static cocoa task_app stream; non-heartbeat ticks land at 1-3
//      rectangles for the cocoa task_app's small cursor / status
//      mutations.
//   3. The pixel reconstruction is lossless — the decoded canvas
//      still carries multi-colour content (the lossless contract
//      survives the per-rect VP8L encode).
//
// Spawn the real cocoa launcher binary — no in-process mocks. Per
// the campaign brief's "real-environment tests only" rule. Skip on
// non-Darwin hosts (cocoa launcher only builds on macOS).

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
const editorBuildDir = join(isonimExamplesRoot, "build", "editor");
const cocoaLauncherBin = join(
  isonimExamplesRoot,
  "build",
  "backends",
  "isonim-examples-cocoa",
);

const LAUNCHER_BACKEND = "cocoa";
const isMacOS = process.platform === "darwin";

function exec(cmd, opts = {}) {
  return execSync(cmd, { stdio: "pipe", ...opts }).toString();
}

function buildEditorAndCocoa() {
  exec("direnv exec . just editor-build", { cwd: isonimExamplesRoot });
  exec("direnv exec . just build-backends-macos", { cwd: isonimExamplesRoot });
  if (!existsSync(join(editorBuildDir, "editor.js"))) {
    throw new Error("editor.js was not produced by `just editor-build`");
  }
  if (!existsSync(cocoaLauncherBin)) {
    throw new Error(`cocoa launcher binary missing: ${cocoaLauncherBin}`);
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

async function spawnCocoaLauncher(port, encoder, opts = {}) {
  const { width = 390, height = 844 } = opts;
  const proc = spawn(
    cocoaLauncherBin,
    [
      "--port",
      String(port),
      "--demo",
      "task",
      "--width",
      String(width),
      "--height",
      String(height),
      "--fps",
      "30",
      "--encoder",
      encoder,
    ],
    {
      cwd: isonimExamplesRoot,
      env: { ...process.env },
      stdio: ["ignore", "pipe", "pipe"],
    },
  );
  const tag = `[cocoa-${encoder}]`;
  proc.stderr.on("data", (b) => process.stderr.write(`${tag} ${b}`));
  proc.stdout.on("data", (b) => process.stderr.write(`${tag} ${b}`));
  await new Promise((resolve, reject) => {
    const deadline = Date.now() + 15000;
    const tick = () => {
      if (Date.now() > deadline) {
        reject(new Error(`cocoa launcher (${encoder}) failed to bind in 15s`));
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

async function openEditorAgainst(serverPort, opts = {}) {
  const b = await ensureBrowser();
  const ctx = await b.newContext({
    viewport: { width: 1440, height: 900 },
    deviceScaleFactor: opts.deviceScaleFactor || 1,
  });
  const page = await ctx.newPage();
  page.on("pageerror", (e) => console.error("[page] error:", e.message));
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

async function waitFor(predicate, ms = 30000, intervalMs = 100) {
  const t0 = Date.now();
  while (Date.now() - t0 < ms) {
    if (await predicate()) return true;
    await new Promise((r) => setTimeout(r, intervalMs));
  }
  return false;
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

const SKIP_REASON =
  "ELT-M9 — macOS-only milestone. The cocoa launcher is the test " +
  "vehicle (only builds on Darwin); Linux CI compiles cocoa.nim as " +
  "an empty shell.";

let launcher = null;
let proxy = null;

test.before(async () => {
  if (!isMacOS) return;
  buildEditorAndCocoa();
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

test("editor receives W-diff packets and reconstructs the canvas", async (t) => {
  if (!isMacOS) {
    t.skip(SKIP_REASON);
    return;
  }
  const launcherPort = await pickFreePort();
  const serverPort = await pickFreePort();
  launcher = await spawnCocoaLauncher(launcherPort, "webp");
  proxy = await startEditorProxy(serverPort, launcherPort);

  const { ctx, page } = await openEditorAgainst(serverPort);
  try {
    await page.evaluate(() => {
      window.__isonimTestMode = true;
    });
    await pickCocoa(page);

    // Settle on w/webp first — the bridge's per-frame selector flips
    // to W within a few seconds of the connection going live.
    const settled = await waitFor(async () => {
      const v = await page.evaluate(
        () => document.body.dataset.isonimActiveTransport || "",
      );
      return v === "w/webp";
    }, 30000);
    assert.ok(
      settled,
      "static cocoa task_app should settle on w/webp before the diff " +
        "variant engages",
    );

    // Let several diff packets land. The bridge emits a full-frame W
    // for the first WebP-eligible frame on the connection; from the
    // second WebP frame onward the selector picks the diff variant.
    // At ~30 FPS we observe ~60 W-diff packets across 2s.
    await new Promise((r) => setTimeout(r, 3000));

    const diff = await page.evaluate(() => ({
      counts: window.__isonimWDiffRectCounts || [],
      last: window.__isonimLastWDiffRectCount,
      lastBytes: window.__isonimLastWDiffByteLength,
    }));

    assert.ok(
      diff.counts.length >= 5,
      `expected the W-diff path to engage and accumulate >=5 rect-count ` +
        `samples; got ${diff.counts.length}`,
    );
    // Static UI should yield mostly zero-rect heartbeats; allow up to
    // 3 rectangles for the cursor / status-line / scrollbar mutations
    // a real cocoa task_app produces.
    const small = diff.counts.filter((c) => c <= 3).length;
    assert.ok(
      small >= Math.floor(diff.counts.length * 0.8),
      `>=80% of W-diff packets should ship <=3 rectangles on the static ` +
        `task_app; got ${small}/${diff.counts.length} (counts=` +
        `${JSON.stringify(diff.counts.slice(0, 20))})`,
    );

    // Lossless contract: the canvas continues to carry multi-colour
    // content (the per-rect VP8L encode preserves source bytes). We
    // can't directly compare against the launcher's raw RGBA, but the
    // task_app draws several distinct colours; the canvas should
    // show >=2 unique RGB triples after the diff packets paint.
    const pixels = await page.evaluate(() => {
      const cnv = document.querySelector('canvas[data-canvas-active="true"]');
      if (!cnv) return null;
      const intrinsicW = cnv.width;
      const intrinsicH = cnv.height;
      const ctx = cnv.getContext("2d");
      if (!ctx) return { intrinsicW, intrinsicH };
      const img = ctx.getImageData(0, 0, intrinsicW, intrinsicH);
      const data = img.data;
      const unique = new Set();
      let nonGrey = 0;
      for (let i = 0; i < data.length; i += 4) {
        const r = data[i + 0],
          g = data[i + 1],
          b = data[i + 2];
        if (!(r === 0x18 && g === 0x18 && b === 0x18)) nonGrey++;
        if (unique.size < 4096) unique.add((r << 16) | (g << 8) | b);
      }
      return {
        intrinsicW,
        intrinsicH,
        nonGrey,
        sampled: data.length / 4,
        uniqueColors: unique.size,
      };
    });
    assert.ok(pixels, "canvas should be present and 2D-context capable");
    assert.ok(
      pixels.uniqueColors >= 2,
      `W-diff reconstructed canvas should preserve multiple RGB colours ` +
        `(lossless contract); got ${pixels.uniqueColors}`,
    );
    assert.ok(
      pixels.nonGrey > pixels.sampled / 16,
      `expected substantial non-placeholder pixels after W-diff paints; ` +
        `got ${pixels.nonGrey}/${pixels.sampled}`,
    );
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
});
