// ELT-M9 — idle no-change W-diff packets are near-zero-byte
// heartbeats. With the bridge's per-frame transport selector parked
// on the W-diff variant and the cocoa task_app's UI settled, every
// W-diff packet should carry zero (or near-zero) rectangles. The
// over-the-wire byte cost approaches the W header floor — that is
// the architectural payoff this milestone unlocks: near-zero
// bandwidth for static UI between frames.
//
// What this test asserts:
//
//   1. The W-diff path engages.
//   2. After a settle period, the majority of subsequent W-diff
//      packets carry zero rectangles (the heartbeat case).
//   3. The total byte count for the heartbeat samples is within a
//      few-hundred-byte budget per packet (the W header is 15 bytes
//      + 10 codec_id bytes + 4 byte rect_count = 29 bytes per
//      packet; we budget <=512 bytes to absorb any small cursor-
//      blink rectangles the cocoa task_app may legitimately ship).
//
// Skip rule: macOS-only (cocoa launcher).

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

async function spawnCocoaLauncher(port, encoder) {
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
  "vehicle (only builds on Darwin).";

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

test("idle UI ships near-zero-byte W-diff heartbeats", async (t) => {
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

    const settled = await waitFor(async () => {
      const v = await page.evaluate(
        () => document.body.dataset.isonimActiveTransport || "",
      );
      return v === "w/webp";
    }, 30000);
    assert.ok(settled, "stream should settle on w/webp first");

    // Drain any accumulated rect counts so we measure the post-
    // settle steady state only.
    await page.evaluate(() => {
      window.__isonimWDiffRectCounts = [];
      window.__isonimWDiffByteLengths = [];
    });

    // Settle period — let the UI fully quiesce.
    await new Promise((r) => setTimeout(r, 3500));

    const samples = await page.evaluate(() => ({
      counts: window.__isonimWDiffRectCounts || [],
      bytes: window.__isonimWDiffByteLengths || [],
    }));

    assert.ok(
      samples.counts.length >= 10,
      `expected at least 10 W-diff packets during idle settle; got ` +
        `${samples.counts.length}`,
    );

    // Heartbeat majority: the static cocoa task_app must yield more
    // zero-rect heartbeats than rectangle-bearing diffs once the UI
    // has fully settled.
    const heartbeats = samples.counts.filter((c) => c === 0).length;
    const nonZero = samples.counts.filter((c) => c > 0).length;
    assert.ok(
      heartbeats > nonZero,
      `idle W-diff stream should be majority zero-rect heartbeats; got ` +
        `heartbeats=${heartbeats}, nonZero=${nonZero}, ` +
        `counts=${JSON.stringify(samples.counts.slice(0, 30))}`,
    );

    // Bandwidth contract: heartbeat packets should be in the
    // few-hundred-byte range. The W header is 29 bytes (15 +
    // codec_id "image/webp" = 10 bytes + 4-byte rect_count u32);
    // accept up to 512 bytes per packet to absorb any small cursor-
    // blink ticks that drift into the steady-state window.
    if (samples.bytes.length > 0) {
      const max = Math.max(...samples.bytes);
      const median = samples.bytes.slice().sort((a, b) => a - b)[
        Math.floor(samples.bytes.length / 2)
      ];
      assert.ok(
        median < 512,
        `idle W-diff median packet size should be < 512 bytes; got ` +
          `median=${median}, max=${max}`,
      );
    }
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
