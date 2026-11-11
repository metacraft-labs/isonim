// PSZ-M3 note 22: a GPUI renderer that falls back mid-connection shows
// "GPUI preview unavailable: renderer fell back" in the page preview, and the
// last frame of the healthy renderer is not left on screen.
//
// The render-serve bridge closes the WebSocket with code 4001 when the
// launcher's frame source changes after its hello. This test stands in for the
// launcher with Playwright's `routeWebSocket`:
//
//   1. it answers the editor's `/bridge/gpui` WebSocket with a `hello` that
//      declares `frameSource: "real"`, then a full frame painted solid magenta;
//   2. it closes the socket with code 4001 and the bridge's reason, which is
//      the fallback the bridge sends;
//   3. it checks that the note `[data-renderer-fell-back="true"]` is visible
//      with its text, that the frame's label is hidden, that the canvas holds no
//      painted pixels, and that the note covers the canvas at its centre (so no
//      stale frame shows through).
//
// Mock, and why it is here: the WebSocket is answered by Playwright's
// `routeWebSocket`, standing in for the bridge and the launcher. The launcher is
// not built and no GPUI renders: the test asserts the editor's reaction to a
// close code and a frame, both of which the bridge sends by the wire format the
// render-serve tests pin. The editor side is real: the editor build, the editor
// server and headless Chromium.
//
// Negative control: with the 4001 handling removed in a scratch copy of the
// editor, the note never shows and this test fails at step 3.
//
// Convention: `node --test`, like the other e2e_*_live.mjs files here.
// Run with: repro exec -- bash -lc 'cd tests/browser && node --test e2e_preview_renderer_fell_back_live.mjs'

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

const PORT = 18682;
const STORY = "/index.html?view=page&storyGroup=Pages" +
  "&story=" + encodeURIComponent("Trip Planner") +
  "&kind=page&index=0&viewport=desktop&zoom=fit";
const NOTE_SELECTOR = '[data-renderer-fell-back="true"]';
const NOTE_TEXT = "GPUI preview unavailable: renderer fell back";
const LABEL_SELECTOR = '[data-preview-frame-source="synthetic"]';
// The bridge's close code and reason (isonim-render-serve bridge.nim).
const FELL_BACK_CODE = 4001;
const FELL_BACK_REASON = "renderer fell back: frame source changed after hello";
const FRAME_W = 1440;
const FRAME_H = 900;

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
  const logDir = mkdtempSync(join(tmpdir(), "psz-n22-server-"));
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

// The F-packet wire form of a full RGBA frame: 'F', flags (0 = full frame),
// u32 LE width, u32 LE height, u32 LE payload length, then the RGBA bytes.
function fPacketSolid(width, height, r, g, b) {
  const payload = Buffer.alloc(width * height * 4);
  for (let i = 0; i < payload.length; i += 4) {
    payload[i] = r;
    payload[i + 1] = g;
    payload[i + 2] = b;
    payload[i + 3] = 255;
  }
  const head = Buffer.alloc(14);
  head[0] = 0x46;
  head[1] = 0;
  head.writeUInt32LE(width, 2);
  head.writeUInt32LE(height, 6);
  head.writeUInt32LE(payload.length, 10);
  return Buffer.concat([head, payload]);
}

function hello(capabilities) {
  return {
    type: "hello",
    protocolVersion: 1,
    backend: "gpui",
    capabilities: { diffRegions: true, transports: ["f/rgba"], ...capabilities },
    initialSize: { width: FRAME_W, height: FRAME_H },
  };
}

// Open the Trip Planner page story on the GPUI backend. The bridge socket is
// answered with a `real` hello; the returned `socket` is the mock bridge side.
async function openGpuiPreview(b) {
  const ctx = await b.newContext({ viewport: { width: 2200, height: 1300 } });
  const page = await ctx.newPage();
  const state = { socket: null };
  await page.routeWebSocket(/\/bridge\/gpui$/, (ws) => {
    state.socket = ws;
    ws.send(mPacket(hello({ frameSource: "real" })));
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
  return { ctx, page, state };
}

// The colour at the canvas centre, or null when the canvas holds no paint.
async function canvasCentre(page) {
  return page.evaluate(() => {
    const canvas = document.querySelector("[data-page-project-canvas]");
    if (!canvas || !canvas.width || !canvas.height) return null;
    const ctx = canvas.getContext("2d");
    if (!ctx) return null;
    const x = Math.floor(canvas.width / 2);
    const y = Math.floor(canvas.height / 2);
    const d = ctx.getImageData(x, y, 1, 1).data;
    return { r: d[0], g: d[1], b: d[2], a: d[3] };
  });
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

test("e2e_preview_renderer_fell_back_shows_the_note_and_no_stale_frame", async () => {
  const b = await ensureBrowser();
  const { ctx, page, state } = await openGpuiPreview(b);
  try {
    // A healthy frame first: a solid magenta frame, so a stale frame is visible
    // to the test if the fallback leaves it on screen.
    await page.waitForFunction(() => !!document.querySelector("[data-page-project-canvas]"),
      null, { timeout: 15000 });
    state.socket.send(fPacketSolid(FRAME_W, FRAME_H, 255, 0, 255));
    await page.waitForFunction(() => {
      const canvas = document.querySelector("[data-page-project-canvas]");
      if (!canvas || !canvas.width) return false;
      const d = canvas.getContext("2d").getImageData(
        Math.floor(canvas.width / 2), Math.floor(canvas.height / 2), 1, 1).data;
      return d[0] === 255 && d[1] === 0 && d[2] === 255;
    }, null, { timeout: 15000 });
    const painted = await canvasCentre(page);
    assert.deepEqual(painted, { r: 255, g: 0, b: 255, a: 255 },
      "the healthy frame was not painted before the fallback");

    // The renderer falls back: the bridge closes with the fallback code.
    assert.ok(state.socket, "the bridge socket was not opened");
    state.socket.close({ code: FELL_BACK_CODE, reason: FELL_BACK_REASON });

    await page.waitForSelector(NOTE_SELECTOR, { state: "visible", timeout: 15000 });
    const note = await page.evaluate((selector) => {
      const el = document.querySelector(selector);
      const rect = el.getBoundingClientRect();
      const canvas = document.querySelector("[data-page-project-canvas]");
      const c = canvas.getBoundingClientRect();
      // The element at the canvas centre: the note must be on top, so no frame
      // shows through it.
      const at = document.elementFromPoint(c.left + c.width / 2, c.top + c.height / 2);
      return {
        text: (el.textContent || "").trim(),
        visible: rect.width > 0 && rect.height > 0,
        coversCanvas: !!at && (at === el || el.contains(at)),
        label: (() => {
          const l = document.querySelector('[data-preview-frame-source="synthetic"]');
          if (!l) return "absent";
          return getComputedStyle(l).display;
        })(),
      };
    }, NOTE_SELECTOR);
    assert.equal(note.text, NOTE_TEXT);
    assert.ok(note.visible, "the fallback note has no area");
    assert.ok(note.coversCanvas,
      "the fallback note does not cover the canvas: a frame would show through");
    assert.ok(note.label === "absent" || note.label === "none",
      `the frame label is shown (${note.label}) for a fallen-back frame`);

    // No stale frame: the canvas holds no paint after the fallback.
    const after = await canvasCentre(page);
    assert.ok(after === null || after.a === 0,
      `the canvas still holds the healthy frame after the fallback: ${JSON.stringify(after)}`);
  } finally {
    await ctx.close();
  }
});
