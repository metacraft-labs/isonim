// Shared live-browser harness for the PSZ (Preview-Sizing-And-Zoom) e2e files.
//
// It builds the packaged editor and the isonim-review daemon, starts the editor
// server on a port the caller picks, and opens a headless Chromium page on a
// story. Nothing here is mocked: the server, the daemon and the browser are the
// real ones. The M1 file e2e_preview_zoom_live.mjs keeps its own copy of these
// helpers; this module is what new PSZ files import.
//
// Chromium: PLAYWRIGHT_CHROMIUM_EXECUTABLE, when set, is the browser used. Run
// under `repro exec` with that variable taken from `command -v chromium`.

import { execSync, spawn } from "node:child_process";
import { existsSync, mkdtempSync, openSync, readFileSync } from "node:fs";
import { tmpdir } from "node:os";
import { dirname, join } from "node:path";
import { fileURLToPath } from "node:url";

const __dirname = dirname(fileURLToPath(import.meta.url));
export const isonimRoot = join(__dirname, "..", "..");
const editorBuildDir = join(isonimRoot, "build", "editor");
const daemonBinary = join(isonimRoot, "build", "bin", "isonim-review");

const state = { server: null, exitCode: null, logPath: "", browser: null };

export function buildEditor() {
  // The daemon is built here, in the test's own shell, and handed to the editor
  // server by path (see e2e_preview_zoom_live.mjs for why).
  execSync("just editor-build", { cwd: isonimRoot, stdio: "pipe" });
  execSync("just isonim-review-build", { cwd: isonimRoot, stdio: "pipe" });
  if (!existsSync(join(editorBuildDir, "editor.js"))) {
    throw new Error("editor.js was not produced by `just editor-build`");
  }
  if (!existsSync(daemonBinary)) {
    throw new Error("isonim-review was not produced by `just isonim-review-build`");
  }
}

export async function startPageServer(port) {
  const logDir = mkdtempSync(join(tmpdir(), "psz-live-server-"));
  state.logPath = join(logDir, "editor_server.log");
  state.exitCode = null;
  const logFd = openSync(state.logPath, "w");
  state.server = spawn(
    "python3",
    [
      join(isonimRoot, "tools", "editor_server.py"),
      "--directory", editorBuildDir,
      "--project-root", join(isonimRoot, "examples", "wanderlust"),
      "--daemon-binary", daemonBinary,
      "--port", String(port),
      "--bind", "127.0.0.1",
    ],
    { cwd: isonimRoot, stdio: ["ignore", logFd, logFd], detached: true },
  );
  state.server.on("exit", (code) => {
    state.exitCode = code === null ? "signal" : code;
  });
  // Poll asynchronously so the child's exit event can be seen while waiting.
  for (let i = 0; i < 120; i++) {
    if (state.exitCode !== null) break;
    try {
      const res = await fetch(`http://127.0.0.1:${port}/index.html`, {
        signal: AbortSignal.timeout(500),
      });
      if (res.ok) return;
    } catch {
      // Not listening yet.
    }
    await new Promise((resolve) => setTimeout(resolve, 1000));
  }
  const tail = readFileSync(state.logPath, "utf8").split("\n").slice(-20).join("\n");
  throw new Error(`editor server did not serve on ${port} ` +
    `(exit: ${state.exitCode}); log tail:\n${tail}`);
}

export function stopPageServer() {
  try {
    if (state.server) process.kill(-state.server.pid);
  } catch {}
  state.server = null;
}

export async function ensureBrowser() {
  if (!state.browser) {
    const { chromium } = await import("@playwright/test");
    state.browser = await chromium.launch({
      headless: true,
      executablePath: process.env.PLAYWRIGHT_CHROMIUM_EXECUTABLE || undefined,
    });
  }
  return state.browser;
}

export async function closeBrowser() {
  try {
    if (state.browser) await state.browser.close();
  } catch {}
  state.browser = null;
}

// Opens a story in a fresh context whose window leaves room for the whole
// 1440x900 Desktop frame at 100%, and waits until the story's document is in the
// srcdoc iframe (the empty-state fallback is not accepted).
export async function openStoryPreview(port, story, { suffix = "" } = {}) {
  const b = await ensureBrowser();
  const ctx = await b.newContext({ viewport: { width: 2200, height: 1300 } });
  const page = await ctx.newPage();
  await page.goto(`http://127.0.0.1:${port}${story}${suffix}`);
  await page.waitForSelector('[data-preview-zoom-cluster="true"]', {
    state: "attached",
    timeout: 15000,
  });
  await page.waitForFunction(() => {
    const f = document.querySelector("[data-page-project-frame]");
    return !!(f && f.contentDocument && f.contentDocument.body &&
      f.contentDocument.body.children.length > 0 &&
      getComputedStyle(f).display !== "none");
  }, null, { timeout: 15000 });
  return { ctx, page };
}
