// Phase J (2026-05-28) — Playwright-driven e2e for the mode-driven
// right sidebar swap.
//
// The right sidebar's content is driven by the active editing mode:
//   * ``emEdit`` → Inspector (``data-sidebar-content="inspector"``)
//   * ``emView`` / ``emComment`` / ``emSpec`` → AI assistant
//     (``data-sidebar-content="ai-assistant"``)
//
// Both surfaces carry ``data-test-id="property-panel"`` so the
// existing e2e selectors keep working; ``data-sidebar-content``
// distinguishes which one is currently up.
//
// This file pins the live behaviour:
//
//   1. Initial editor mount (default View mode) → AI assistant in
//      the right sidebar.
//   2. Click Edit → Inspector replaces the AI assistant.
//   3. Click View → AI assistant comes back.
//   4. Click Comment → AI assistant stays (Inspector is gone).
//   5. Click Spec → AI assistant + centre-column flips to the spec
//      pane (``data-preview-spec-pane`` becomes display:flex).
//   6. Click Edit again → Inspector returns and the spec pane hides.
//
// Runs through ``node --test`` like the other ``e2e_*.mjs`` files.

import { execSync, spawn } from "node:child_process";
import { existsSync } from "node:fs";
import { dirname, join } from "node:path";
import { fileURLToPath } from "node:url";
import test from "node:test";
import assert from "node:assert/strict";

const __dirname = dirname(fileURLToPath(import.meta.url));
const isonimRoot = join(__dirname, "..", "..");
const isonimExamplesRoot = join(isonimRoot, "..", "isonim-examples");
const editorBuildDir = join(isonimExamplesRoot, "build", "editor");

const PAGE_PORT = 18553;
let pageServer = null;
let chromium = null;
let browser = null;

function exec(cmd, opts = {}) {
  return execSync(cmd, { stdio: "pipe", ...opts }).toString();
}

function buildEditor() {
  const cmd = "direnv exec . just editor-build";
  exec(cmd, { cwd: isonimExamplesRoot });
  if (!existsSync(join(editorBuildDir, "editor.js"))) {
    throw new Error("editor.js was not produced by `just editor-build`");
  }
  if (!existsSync(join(editorBuildDir, "index.html"))) {
    throw new Error("index.html was not produced by `just editor-build`");
  }
}

function startPageServer() {
  pageServer = spawn(
    "python3",
    ["-m", "http.server", String(PAGE_PORT), "--bind", "127.0.0.1"],
    { cwd: editorBuildDir, stdio: "ignore", detached: true },
  );
  for (let i = 0; i < 60; i++) {
    try {
      execSync(
        `curl -s -o /dev/null --max-time 0.5 ` +
          `http://127.0.0.1:${PAGE_PORT}/index.html`,
        { stdio: "pipe" },
      );
      return;
    } catch {
      execSync("sleep 0.2");
    }
  }
  throw new Error("static server failed to bind on " + PAGE_PORT);
}

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
  const ctx = await b.newContext();
  const page = await ctx.newPage();
  await page.goto(`http://127.0.0.1:${PAGE_PORT}/index.html`);
  await page.waitForSelector('[data-test-id="property-panel"]', {
    timeout: 10000,
  });
  // Phase J requires a selected story so the mode pills are enabled
  // (the "needs a story selection" requirement is shared by Spec /
  // View / Comment / Edit).
  await page.evaluate(() => {
    if (window.__isonimEditor && window.__isonimEditor.selectStoryByName) {
      window.__isonimEditor.selectStoryByName("Components", "Sample");
    }
  });
  return { ctx, page };
}

async function sidebarContent(page) {
  return await page.evaluate(() => {
    const panel = document.querySelector('[data-test-id="property-panel"]');
    return panel ? panel.getAttribute("data-sidebar-content") : null;
  });
}

async function specPaneVisible(page) {
  return await page.evaluate(() => {
    const pane = document.querySelector('[data-test-id="spec-pane"]');
    if (!pane) return false;
    return getComputedStyle(pane).display !== "none";
  });
}

async function clickModePill(page, indexLabel) {
  // ``modeOrder = [emSpec, emView, emComment, emEdit]`` ⇒
  // indexLabel ∈ ``{"spec","view","comment","edit"}``. The chrome bar's
  // Mode cluster exposes ``data-choice-group-pill="0..3"``.
  const indexMap = { spec: "0", view: "1", comment: "2", edit: "3" };
  const i = indexMap[indexLabel];
  if (i === undefined) throw new Error("unknown mode " + indexLabel);
  await page.evaluate((pillIdx) => {
    const pill = document.querySelector(
      `[data-toolbar-cluster="mode"] [data-choice-group-pill="${pillIdx}"]`,
    );
    if (!pill) throw new Error("mode pill " + pillIdx + " not found");
    pill.click();
  }, i);
}

test.before(async () => {
  buildEditor();
  startPageServer();
});

test.after(async () => {
  try {
    if (browser) await browser.close();
  } catch {}
  try {
    if (pageServer) process.kill(-pageServer.pid);
  } catch {}
});

test("e2e_mode_sidebar_swap: View mode shows AI assistant in the right sidebar", async () => {
  const { ctx, page } = await openEditor();
  try {
    // Default editor mode is View → AI assistant.
    assert.equal(await sidebarContent(page), "ai-assistant");
  } finally {
    await ctx.close();
  }
});

test("e2e_mode_sidebar_swap: Edit mode shows Inspector", async () => {
  const { ctx, page } = await openEditor();
  try {
    await clickModePill(page, "edit");
    assert.equal(await sidebarContent(page), "inspector");
  } finally {
    await ctx.close();
  }
});

test("e2e_mode_sidebar_swap: Comment mode shows AI assistant", async () => {
  const { ctx, page } = await openEditor();
  try {
    await clickModePill(page, "comment");
    assert.equal(await sidebarContent(page), "ai-assistant");
  } finally {
    await ctx.close();
  }
});

test("e2e_mode_sidebar_swap: Spec mode shows AI assistant + spec pane", async () => {
  const { ctx, page } = await openEditor();
  try {
    await clickModePill(page, "spec");
    assert.equal(await sidebarContent(page), "ai-assistant");
    assert.equal(await specPaneVisible(page), true);
  } finally {
    await ctx.close();
  }
});

test("e2e_mode_sidebar_swap: Edit again restores Inspector + hides spec pane", async () => {
  const { ctx, page } = await openEditor();
  try {
    // Spec → Edit round-trip.
    await clickModePill(page, "spec");
    await clickModePill(page, "edit");
    assert.equal(await sidebarContent(page), "inspector");
    assert.equal(await specPaneVisible(page), false);
  } finally {
    await ctx.close();
  }
});
