// PSZ-M3 note 18 (Step 2): the web page preview shows the Trip Planner page.
//
// The story is Pages / Trip Planner, a page story. On the web path the preview
// shows the page as its document in a srcdoc iframe. Before this change the
// hook supplied no document for it, so the preview showed the story's title and
// summary line in its fallback card instead of the page. This test opens the
// story in the real editor build and checks the iframe's own document: it must
// contain the planner's itinerary builder and budget summary, and the fallback
// card must be hidden.
//
// The negative control is the fallback itself: its summary line is outside the
// iframe, so a preview that shows only the card fails the iframe assertions.
//
// Real stack: the editor build (`just editor-build`), the editor server, and
// headless Chromium. Nothing is mocked.
//
// Convention: `node --test`, like the other e2e_*_live.mjs files here.
// Run with: repro exec -- bash -lc 'cd tests/browser && node --test e2e_web_trip_planner_page_live.mjs'

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

const PAGE_PORT = 18662;
const STORY = "/index.html?view=page&storyGroup=Pages" +
  "&story=" + encodeURIComponent("Trip Planner") +
  "&kind=page&index=0&viewport=desktop&zoom=fit";
// The page's own text, from examples/wanderlust/pages/trip_planner_document.nim.
const PAGE_TEXT = ["Itinerary builder", "Budget summary"];
// The fallback card's summary line: on the page it is the story's own copy.
const FALLBACK_SUMMARY = "Morocco trip planner with itinerary builder and budget summary";

let pageServer = null;
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

async function startPageServer() {
  const logDir = mkdtempSync(join(tmpdir(), "psz-n18-server-"));
  serverLogPath = join(logDir, "editor_server.log");
  const logFd = openSync(serverLogPath, "w");
  pageServer = spawn(
    "python3",
    [
      join(isonimRoot, "tools", "editor_server.py"),
      "--directory", editorBuildDir,
      "--project-root", join(isonimRoot, "examples", "wanderlust"),
      "--daemon-binary", daemonBinary,
      "--port", String(PAGE_PORT),
      "--bind", "127.0.0.1",
    ],
    { cwd: isonimRoot, stdio: ["ignore", logFd, logFd], detached: true },
  );
  pageServer.on("exit", (code) => {
    serverExitCode = code === null ? "signal" : code;
  });
  for (let i = 0; i < 120; i++) {
    if (serverExitCode !== null) break;
    try {
      const res = await fetch(`http://127.0.0.1:${PAGE_PORT}/index.html`, {
        signal: AbortSignal.timeout(500),
      });
      if (res.ok) return;
    } catch {
      // Not listening yet.
    }
    await new Promise((resolve) => setTimeout(resolve, 1000));
  }
  const tail = readFileSync(serverLogPath, "utf8").split("\n").slice(-20).join("\n");
  throw new Error(`editor server did not serve on ${PAGE_PORT} ` +
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

test.before(async () => {
  buildEditor();
  await startPageServer();
});

test.after(async () => {
  try {
    if (browser) await browser.close();
  } catch {}
  try {
    if (pageServer) process.kill(-pageServer.pid);
  } catch {}
});

test("e2e_web_trip_planner_iframe_document_shows_the_page", async () => {
  const b = await ensureBrowser();
  const ctx = await b.newContext({ viewport: { width: 2200, height: 1300 } });
  const page = await ctx.newPage();
  try {
    await page.goto(`http://127.0.0.1:${PAGE_PORT}${STORY}`);
    await page.waitForSelector('[data-page-project-frame="true"]', {
      state: "attached",
      timeout: 15000,
    });
    // Poll for the iframe's document text for up to 15 s. A preview without a
    // document leaves the iframe empty, and the assertions below name what it
    // shows instead of timing out.
    const readFrameText = () => page.evaluate(() => {
      const f = document.querySelector('[data-page-project-frame="true"]');
      const body = f && f.contentDocument && f.contentDocument.body;
      return body ? body.innerText : "";
    });
    let frameText = "";
    for (let i = 0; i < 30 && frameText.trim() === ""; i++) {
      frameText = await readFrameText();
      if (frameText.trim() === "") await page.waitForTimeout(500);
    }
    const lower = frameText.toLowerCase();
    for (const text of PAGE_TEXT) {
      assert.ok(lower.includes(text.toLowerCase()),
        `the preview's iframe document does not show "${text}"; it shows: ` +
        JSON.stringify(frameText.slice(0, 200)));
    }
    console.log(`  iframe document contains: ${PAGE_TEXT.join(", ")}`);

    // The fallback card is the empty state. Its summary line is the only
    // element with that exact text; it must have no layout box when the page
    // is shown.
    const fallbackState = await page.evaluate((summary) => {
      const el = [...document.querySelectorAll("p, div, span")].find((d) =>
        d.children.length === 0 && d.textContent.trim() === summary);
      if (!el) return "absent";
      return el.getClientRects().length > 0 ? "visible" : "hidden";
    }, FALLBACK_SUMMARY);
    assert.notEqual(fallbackState, "visible",
      `the fallback summary card is shown instead of the page: "${FALLBACK_SUMMARY}"`);
  } finally {
    await ctx.close();
  }
});
