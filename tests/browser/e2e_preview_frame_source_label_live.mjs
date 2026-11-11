// PSZ-M3 note 20: the page preview labels a streamed frame that is the
// synthetic raster, and does not label a frame whose launcher declares nothing.
//
// The GPUI launcher on Linux streams the synthetic raster, and its `hello`
// M-packet declares `capabilities.frameSource: "synthetic"`. This test selects
// the GPUI backend on the Trip Planner page story and answers the editor's
// `/bridge/gpui` WebSocket with a `hello` (the M-packet wire shape: 'M', a u32
// little-endian length, then the JSON body). It checks the label:
//
//   * labelled hello  -> `[data-preview-frame-source="synthetic"]` is shown and
//     reads "Synthetic preview: GPUI draws boxes only on Linux";
//   * unlabelled hello -> the label is not shown (a launcher that declares no
//     frame source, such as a macOS build with the headless renderer).
//
// Mock, and why it is here: the WebSocket is answered by Playwright's
// `routeWebSocket`, standing in for the launcher. The launcher is not built in
// this check, and a real GPUI frame is not what it asserts. It asserts the
// label, which is a function of the hello only. The editor side is real: the
// editor build, the editor server and headless Chromium.
//
// Screenshots: when PSZ_N20_CAPTURE_DIR is set, the page's preview area is
// written there as PNG for the visual check (not written otherwise).
//
// Convention: `node --test`, like the other e2e_*_live.mjs files here.
// Run with: repro exec -- bash -lc 'cd tests/browser && node --test e2e_preview_frame_source_label_live.mjs'

import { execSync, spawn } from "node:child_process";
import { existsSync, mkdtempSync, openSync, readFileSync } from "node:fs";
import { tmpdir } from "node:os";
import { dirname, join } from "node:path";
import { fileURLToPath } from "node:url";
import test from "node:test";
import assert from "node:assert/strict";

const __dirname = dirname(fileURLToPath(import.meta.url));
const isonimRoot = join(__dirname, "..", "..");
const editorBuildDir = join(isonimRoot, "build", "editor");
const daemonBinary = join(isonimRoot, "build", "bin", "isonim-review");

const PORT = 18681;
const STORY = "/index.html?view=page&storyGroup=Pages" +
  "&story=" + encodeURIComponent("Trip Planner") +
  "&kind=page&index=0&viewport=desktop&zoom=fit";
const LABEL_SELECTOR = '[data-preview-frame-source="synthetic"]';
const LABEL_TEXT = "Synthetic preview: GPUI draws boxes only on Linux";
const captureDir = process.env.PSZ_N20_CAPTURE_DIR || "";

let server = null;
let serverExitCode = null;
let serverLogPath = "";
let browser = null;

function buildEditor() {
  execSync("just editor-build", { cwd: isonimRoot, stdio: "pipe" });
  execSync("just isonim-review-build", { cwd: isonimRoot, stdio: "pipe" });
  if (!existsSync(join(editorBuildDir, "editor.js"))) {
    throw new Error("editor.js was not produced by `just editor-build`");
  }
  if (!existsSync(daemonBinary)) {
    throw new Error("isonim-review was not produced by `just isonim-review-build`");
  }
}

async function startServer() {
  const logDir = mkdtempSync(join(tmpdir(), "psz-n20-server-"));
  serverLogPath = join(logDir, "editor_server.log");
  const logFd = openSync(serverLogPath, "w");
  server = spawn(
    "python3",
    [
      join(isonimRoot, "tools", "editor_server.py"),
      "--directory", editorBuildDir,
      "--project-root", join(isonimRoot, "examples", "wanderlust"),
      "--daemon-binary", daemonBinary,
      "--port", String(PORT),
      "--bind", "127.0.0.1",
    ],
    { cwd: isonimRoot, stdio: ["ignore", logFd, logFd], detached: true },
  );
  server.on("exit", (code) => {
    serverExitCode = code === null ? "signal" : code;
  });
  for (let i = 0; i < 120; i++) {
    if (serverExitCode !== null) break;
    try {
      const res = await fetch(`http://127.0.0.1:${PORT}/index.html`, {
        signal: AbortSignal.timeout(500),
      });
      if (res.ok) return;
    } catch {
      // Not listening yet.
    }
    await new Promise((resolve) => setTimeout(resolve, 1000));
  }
  const tail = readFileSync(serverLogPath, "utf8").split("\n").slice(-20).join("\n");
  throw new Error(`editor server did not serve on ${PORT} ` +
    `(exit: ${serverExitCode}); log tail:\n${tail}`);
}

async function ensureBrowser() {
  if (!browser) {
    const { chromium } = await import("@playwright/test");
    browser = await chromium.launch({
      headless: true,
      executablePath: process.env.PLAYWRIGHT_CHROMIUM_EXECUTABLE || undefined,
    });
  }
  return browser;
}

// The M-packet wire form the bridge sends: 'M', u32 LE length, JSON body.
function mPacket(json) {
  const body = Buffer.from(JSON.stringify(json), "utf8");
  const head = Buffer.alloc(5);
  head[0] = 0x4d;
  head.writeUInt32LE(body.length, 1);
  return Buffer.concat([head, body]);
}

function hello(capabilities) {
  return {
    type: "hello",
    protocolVersion: 1,
    backend: "gpui",
    capabilities: { diffRegions: true, transports: ["f/rgba"], ...capabilities },
    initialSize: { width: 1440, height: 900 },
  };
}

// Open the Trip Planner page story on the GPUI backend, answering the bridge
// with the given hello. Returns the page; the caller closes its context.
async function openGpuiPreview(b, helloBody) {
  const ctx = await b.newContext({ viewport: { width: 2200, height: 1300 } });
  const page = await ctx.newPage();
  await page.routeWebSocket(/\/bridge\/gpui$/, (ws) => {
    ws.send(mPacket(helloBody));
  });
  await page.goto(`http://127.0.0.1:${PORT}${STORY}`);
  await page.waitForSelector('[data-preview-backend="gpui"]', {
    state: "attached",
    timeout: 15000,
  });
  await page.click('[data-preview-backend="gpui"]');
  await page.waitForSelector('[data-canvas-wrapper="true"]', {
    state: "attached",
    timeout: 15000,
  });
  return { ctx, page };
}

async function labelState(page) {
  // Wait for the hello to be processed: the canvas takes the hello's size.
  await page.waitForTimeout(1500);
  return page.evaluate((selector) => {
    const el = document.querySelector(selector);
    if (!el) return { present: false };
    const style = getComputedStyle(el);
    return {
      present: true,
      shown: style.display !== "none" && el.getClientRects().length > 0,
      text: (el.textContent || "").trim(),
    };
  }, LABEL_SELECTOR);
}

test.before(async () => {
  buildEditor();
  await startServer();
});

test.after(async () => {
  try {
    if (browser) await browser.close();
  } catch {}
  try {
    if (server) process.kill(-server.pid);
  } catch {}
});

test("e2e_preview_frame_source_label_synthetic_gpui_frame_is_labelled", async () => {
  const b = await ensureBrowser();
  const { ctx, page } = await openGpuiPreview(b,
    hello({ frameSource: "synthetic" }));
  try {
    const state = await labelState(page);
    assert.ok(state.present, "the page preview has no frame-source label element");
    assert.ok(state.shown, "the label is hidden for a synthetic GPUI frame");
    assert.equal(state.text, LABEL_TEXT);
    if (captureDir) {
      const area = page.locator('[data-page-preview="true"]');
      await area.screenshot({ path: join(captureDir, "label-synthetic.png") });
    }
  } finally {
    await ctx.close();
  }
});

test("e2e_preview_frame_source_label_undeclared_gpui_frame_is_not_labelled", async () => {
  const b = await ensureBrowser();
  const { ctx, page } = await openGpuiPreview(b, hello({}));
  try {
    const state = await labelState(page);
    assert.ok(!state.present || !state.shown,
      "the label is shown for a GPUI frame whose launcher declares no frame source");
    if (captureDir) {
      const area = page.locator('[data-page-preview="true"]');
      await area.screenshot({ path: join(captureDir, "label-undeclared.png") });
    }
  } finally {
    await ctx.close();
  }
});
