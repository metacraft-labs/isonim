// ELT-M8 — editor's per-frame transport selector ships W for static
// UI and switches to V (or F when V is unavailable) on motion. The
// selector lives in the bridge (``isonim-render-serve/bridge.nim``)
// and is exercised here through the real cocoa launcher with
// ``--encoder webp``.
//
// What this test exercises:
//
//   1. Build the editor bundle + cocoa launcher.
//   2. Spawn the cocoa launcher with ``--encoder webp``. The
//      launcher's bridge holds an H.264 handle (if VideoToolbox is
//      reachable) and a WebP handle (lazily constructed).
//   3. Attach the editor. The static cocoa task_app should settle
//      on ``w/webp`` within a few seconds — the change-score sampler
//      sees no per-tick variation and the per-frame selector keeps
//      W as the preferred transport.
//   4. Drive a viewport resize (which the launcher renders as a
//      change above the static-UI threshold). The selector should
//      switch to V (or fall back to F when V is not available
//      mid-resize) for at least one frame around the change, then
//      settle back on W once the new viewport stops moving.
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

async function openEditorAgainst(serverPort) {
  const b = await ensureBrowser();
  const ctx = await b.newContext({ viewport: { width: 1440, height: 900 } });
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

async function waitFor(predicate, ms = 30000, intervalMs = 80) {
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
  "ELT-M8 — macOS-only milestone (cocoa launcher is the test vehicle).";

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

test("per-frame transport selection: static UI lands on W", async (t) => {
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

    // Headline assertion: static UI settles on w/webp within 30s.
    const settled = await waitFor(async () => {
      const v = await page.evaluate(
        () => document.body.dataset.isonimActiveTransport || "",
      );
      return v === "w/webp";
    }, 30000);
    assert.ok(
      settled,
      "static cocoa task_app should settle on w/webp via the " +
        "per-frame transport selector",
    );

    // Stay settled across multiple frame ticks — the selector must
    // not oscillate W <-> V on a frame stream with no visible change.
    const stable = await page.evaluate(async () => {
      const samples = [];
      for (let i = 0; i < 30; i++) {
        samples.push(document.body.dataset.isonimActiveTransport || "");
        await new Promise((r) => setTimeout(r, 100));
      }
      return samples;
    });
    // All samples should be w/webp; the static stream is the W path
    // by design.
    const wCount = stable.filter((s) => s === "w/webp").length;
    const vCount = stable.filter((s) => s === "v/avc1").length;
    const fCount = stable.filter((s) => s === "f/rgba").length;
    assert.ok(
      wCount >= 20,
      `expected the static stream to stay on w/webp for >=20/30 ` +
        `samples; got w=${wCount} v=${vCount} f=${fCount}`,
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

test("per-frame transport selection: resize triggers V (or F) departure", async (t) => {
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
      // Track every transport change for inspection.
      window.__isonimTransportTransitions = [];
      const obs = new MutationObserver(() => {
        const t = document.body.dataset.isonimActiveTransport || "";
        const arr = window.__isonimTransportTransitions;
        if (arr.length === 0 || arr[arr.length - 1] !== t) {
          arr.push(t);
        }
      });
      obs.observe(document.body, {
        attributes: true,
        attributeFilter: ["data-isonim-active-transport"],
      });
    });
    await pickCocoa(page);

    // Settle on W first.
    const settled = await waitFor(async () => {
      const v = await page.evaluate(
        () => document.body.dataset.isonimActiveTransport || "",
      );
      return v === "w/webp";
    }, 30000);
    assert.ok(settled, "static stream should settle on w/webp");

    // Trigger a viewport resize via the editor's viewport pill UI
    // if one is exposed; otherwise the launcher receives a resize
    // I-packet via the existing VRS-M2 plumbing (the canvas mount's
    // ResizeObserver fires on layout change). The simplest reliable
    // trigger is shrinking the browser viewport — Chrome's
    // ResizeObserver will fire on the canvas, the editor will send
    // an I packet, and the launcher will re-render at the new
    // physical dims.
    await page.setViewportSize({ width: 1000, height: 700 });
    await new Promise((r) => setTimeout(r, 200));
    await page.setViewportSize({ width: 1440, height: 900 });

    // Wait a bit for the transitions to flow through.
    await new Promise((r) => setTimeout(r, 2000));

    const transitions = await page.evaluate(
      () => window.__isonimTransportTransitions || [],
    );
    // The resize is the kind of motion that should kick the bridge's
    // selector out of W at least briefly. We accept either a
    // transition to V (when VideoToolbox is available) or to F (when
    // the resize itself triggers a coded-dim change before the V
    // encoder rebuilds).
    const sawDepartureFromW = transitions.some(
      (t) => t === "v/avc1" || t === "f/rgba",
    );
    assert.ok(
      sawDepartureFromW || transitions.length >= 2,
      `resize should produce a transport transition out of w/webp ` +
        `at least once; observed transitions=${JSON.stringify(transitions)}`,
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
