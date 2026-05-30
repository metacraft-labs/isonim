// ELT-M8 — editor JS shim decodes W-packets via
// ``createImageBitmap(Blob)`` and paints them into the preview canvas,
// and the M-packet transport negotiation flips
// ``document.body.dataset.isonimActiveTransport`` to ``"w/webp"``.
//
// What this test exercises end-to-end:
//
//   1. Build the editor bundle + the real cocoa launcher binary
//      (`just editor-build` + `just build-backends-macos`).
//   2. Spawn the cocoa launcher with ``--encoder webp`` so the
//      bridge runs the per-frame transport selector and emits
//      W-packets for static UI frames per the ELT-M7 synthesis
//      report's policy.
//   3. Start a tiny Node HTTP+WS proxy that
//      a) serves the editor's static files,
//      b) proxies WebSocket upgrades at `/bridge/cocoa` to the
//         live launcher (RFC 6455 framing is opaque — we just pipe
//         bytes).
//   4. Drive the editor in headless Chromium:
//      a) wait for the chrome bar,
//      b) click the Cocoa backend pill so the editor's JS shim
//         attaches the bridge (which sends the editor's hello
//         accept M packet immediately on ws.open, advertising
//         ``["w/webp", "v/avc1", "f/rgba"]``),
//      c) wait for ``document.body.dataset.isonimActiveTransport``
//         to settle on ``w/webp`` (the W-packet decode path),
//      d) capture canvas pixels via ``ctx.getImageData`` inside
//         page.evaluate. Assert non-trivial RGBA — the decoded
//         frame must paint at least some non-uniform pixels.
//   5. Lossless contract: WebP-lossless preserves the source RGBA
//      bit-exact. We can't assert against the launcher's raw RGBA
//      directly (it's not exposed) but we can golden a compact
//      summary and verify the canvas paints non-trivially.
//
// Conventions:
//   * `node --test` (matches the rest of `isonim/tests/browser/e2e_*.mjs`).
//   * Spawn the real launcher binary — no in-process mocks. Per the
//     campaign brief's "real-environment tests only" rule.
//
// Skip rule: macOS-only. The cocoa launcher is the test vehicle (only
// builds on Darwin).

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
const goldenDir = join(__dirname, "golden", "elt-m8");

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

async function spawnCocoaLauncher(
  port,
  encoder,
  { width = 390, height = 844 } = {},
) {
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

async function waitFor(predicate, ms = 15000, intervalMs = 80) {
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
  "ELT-M8 — macOS-only milestone. The cocoa launcher is the test " +
  "vehicle (only builds on Darwin); Linux CI compiles cocoa.nim as " +
  "an empty shell.";

let launcherWebP = null;
let proxyWebP = null;

test.before(async () => {
  if (!isMacOS) return;
  buildEditorAndCocoa();
  if (!existsSync(goldenDir)) mkdirSync(goldenDir, { recursive: true });
});

test.after(async () => {
  try {
    if (browser) await browser.close();
  } catch (_) {}
  try {
    if (launcherWebP) launcherWebP.kill("SIGTERM");
  } catch (_) {}
  try {
    if (proxyWebP) await proxyWebP.shutdown();
  } catch (_) {}
});

test("editor decodes W-packets from the webp cocoa launcher", async (t) => {
  if (!isMacOS) {
    t.skip(SKIP_REASON);
    return;
  }
  const launcherPort = await pickFreePort();
  const serverPort = await pickFreePort();
  const launcher = await spawnCocoaLauncher(launcherPort, "webp");
  const proxy = await startEditorProxy(serverPort, launcherPort);
  launcherWebP = launcher;
  proxyWebP = proxy;

  const { ctx, page } = await openEditorAgainst(serverPort);
  try {
    await page.evaluate(() => {
      window.__isonimTestMode = true;
    });
    await pickCocoa(page);

    // Wait for the W-decode path to settle. The cocoa launcher with
    // ``--encoder webp`` emits at ~30 FPS through the per-frame
    // transport selector; the task_app's static UI lands on the W
    // path within the first few seconds.
    const sawW = await waitFor(async () => {
      const v = await page.evaluate(
        () => document.body.dataset.isonimActiveTransport || "",
      );
      return v === "w/webp";
    }, 30000);

    if (!sawW) {
      const diag = await page.evaluate(() => ({
        active: document.body.dataset.isonimActiveTransport || "",
        decodeError: window.__isonimLastWebPDecodeError || "",
        videoConfigureError: window.__isonimLastVideoConfigureError || "",
        videoDecodeError: window.__isonimLastVideoDecodeError || "",
      }));
      assert.fail(
        "editor never marked w/webp as the active transport: " +
          JSON.stringify(diag),
      );
    }

    // Let a couple more W packets land so the renderer paints multiple
    // frames.
    await new Promise((r) => setTimeout(r, 2000));

    // Capture canvas pixels. The W decoder paints via
    // ``ctx.drawImage(bitmap, 0, 0)`` after a synchronous size check;
    // the canvas's intrinsic dims should match the launcher's physical
    // frame dims.
    const pixels = await page.evaluate(() => {
      const cnv = document.querySelector('canvas[data-canvas-active="true"]');
      if (!cnv) return null;
      const intrinsicW = cnv.width;
      const intrinsicH = cnv.height;
      const styleW = cnv.style.width;
      const styleH = cnv.style.height;
      const ctx = cnv.getContext("2d");
      if (!ctx) return { intrinsicW, intrinsicH, styleW, styleH };
      const w = intrinsicW;
      const h = intrinsicH;
      const img = ctx.getImageData(0, 0, w, h);
      const data = img.data;
      let nonGrey = 0;
      const unique = new Set();
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
        styleW,
        styleH,
        nonGrey,
        sampled: data.length / 4,
        uniqueColors: unique.size,
      };
    });

    assert.ok(pixels, "canvas should be present and 2D-context capable");
    assert.ok(
      pixels.intrinsicW >= 1 && pixels.intrinsicH >= 1,
      `canvas intrinsic dims should be non-zero; got ${pixels.intrinsicW}x` +
        `${pixels.intrinsicH}`,
    );
    assert.ok(
      pixels.nonGrey > pixels.sampled / 8,
      `expected substantial non-placeholder pixels in the decoded W ` +
        `frame; got ${pixels.nonGrey}/${pixels.sampled} non-grey ` +
        `(uniqueColors=${pixels.uniqueColors})`,
    );
    // Lossless contract: WebP-lossless preserves the source RGBA
    // bit-exact, so the canvas's distinct color count should be at
    // least 2 (the cocoa task_app has multiple background + foreground
    // colors at every viewport).
    assert.ok(
      pixels.uniqueColors >= 2,
      `decoded W frame should preserve multiple RGB colors (WebP ` +
        `lossless contract); got ${pixels.uniqueColors}`,
    );

    // Golden compact summary.
    const goldenPath = join(goldenDir, "w-decode-summary.json");
    const summary = {
      transport: "w/webp",
      intrinsicW: pixels.intrinsicW,
      intrinsicH: pixels.intrinsicH,
    };
    if (!existsSync(goldenPath)) {
      writeFileSync(goldenPath, JSON.stringify(summary, null, 2));
    } else {
      const golden = JSON.parse(readFileSync(goldenPath, "utf-8"));
      assert.equal(golden.transport, summary.transport);
      assert.ok(
        Math.abs(golden.intrinsicW - summary.intrinsicW) <= 16,
        `intrinsicW drift > 16 (golden=${golden.intrinsicW}, ` +
          `now=${summary.intrinsicW})`,
      );
      assert.ok(
        Math.abs(golden.intrinsicH - summary.intrinsicH) <= 16,
        `intrinsicH drift > 16 (golden=${golden.intrinsicH}, ` +
          `now=${summary.intrinsicH})`,
      );
    }
  } finally {
    try {
      await ctx.close();
    } catch (_) {}
    try {
      launcher.kill("SIGTERM");
      launcherWebP = null;
    } catch (_) {}
    try {
      await proxy.shutdown();
      proxyWebP = null;
    } catch (_) {}
  }
});
