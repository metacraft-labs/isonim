// Playwright-driven browser e2e for the right-sidebar Manual /
// Assistant tabbed contract.
//
// Driving complaint:
//
//   "You've made the AI assistant a separate sidebar, but this was
//    not my intention. I prefer the previous design where the manual
//    edits and the AI assistant are two separate 'tabs' in the
//    sidebar. Logically, the sidebar is related to editing the
//    content. You can do it either manually or by messaging the
//    assistant."
//
// This test pins the contract that replaces the prior AIVS-NSO
// "AI sidebar is its own column" design:
//
//   1. On initial load the right sidebar (``data-test-id="property-
//      panel"``) is mounted with the Manual tab active by default
//      and the 12 inspector sub-section tabs visible.
//   2. Clicking the Assistant tab marks it ``aria-selected="true"``
//      and surfaces the chat composer (the Agent prompt input).
//   3. Clicking the Manual tab brings the 12-section sub-tab bar
//      back. Both tabs remain present (no mode-dependent gating).
//   4. Switching tabs does NOT unmount the sidebar root — the
//      ``[data-test-id="property-panel"]`` selector keeps resolving
//      across tab flips.
//   5. Both tabs are always available even after flipping surface
//      (Preview ↔ Spec) without a story selected.
//
// Runs via ``node --test`` (same pattern as the rest of
// ``tests/browser/e2e_*.mjs``).

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

const PAGE_PORT = 18528;
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
  await page.waitForSelector(
    '[data-test-id="property-panel"] [data-sidebar-tab-bar="true"]',
    { timeout: 10000 },
  );
  return { ctx, page };
}

async function tabSelected(page, tabName) {
  return await page.evaluate((name) => {
    const el = document.querySelector(
      `[data-test-id="property-panel"] [data-sidebar-tab="${name}"]`,
    );
    if (!el) return null;
    return el.getAttribute("aria-selected");
  }, tabName);
}

async function tabPanelVisible(page, tabName) {
  return await page.evaluate((name) => {
    const el = document.querySelector(
      `[data-test-id="property-panel"] [data-sidebar-tab-panel="${name}"]`,
    );
    if (!el) return false;
    return getComputedStyle(el).display !== "none";
  }, tabName);
}

async function clickTab(page, tabName) {
  await page.evaluate((name) => {
    const el = document.querySelector(
      `[data-test-id="property-panel"] [data-sidebar-tab="${name}"]`,
    );
    if (!el) throw new Error(`sidebar tab ${name} not found`);
    el.click();
  }, tabName);
}

async function clickSurfacePill(page, index) {
  await page.evaluate((i) => {
    const pill = document.querySelector(
      `[data-preview-surface-switch="true"] [data-choice-group-pill="${i}"]`,
    );
    if (!pill) throw new Error(`surface pill index ${i} not found`);
    pill.click();
  }, index);
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

// ---------------------------------------------------------------------------
// Default tab is Manual
// ---------------------------------------------------------------------------

test("e2e_sidebar_default_tab_is_manual", async () => {
  const { ctx, page } = await openEditor();
  try {
    assert.equal(
      await tabSelected(page, "manual"),
      "true",
      "Manual tab is aria-selected on initial load",
    );
    assert.equal(
      await tabSelected(page, "assistant"),
      "false",
      "Assistant tab is NOT aria-selected on initial load",
    );
    assert.equal(
      await tabPanelVisible(page, "manual"),
      true,
      "Manual tab body is visible on initial load",
    );
    assert.equal(
      await tabPanelVisible(page, "assistant"),
      false,
      "Assistant tab body is hidden on initial load",
    );
  } finally {
    await ctx.close();
  }
});

// ---------------------------------------------------------------------------
// Clicking Assistant surfaces the chat composer
// ---------------------------------------------------------------------------

test("e2e_sidebar_clicking_assistant_surfaces_chat_input", async () => {
  const { ctx, page } = await openEditor();
  try {
    await clickTab(page, "assistant");
    assert.equal(
      await tabSelected(page, "assistant"),
      "true",
      "Assistant tab is aria-selected after click",
    );
    assert.equal(
      await tabSelected(page, "manual"),
      "false",
      "Manual tab is no longer aria-selected after switching to Assistant",
    );
    assert.equal(
      await tabPanelVisible(page, "assistant"),
      true,
      "Assistant tab body is visible after click",
    );
    assert.equal(
      await tabPanelVisible(page, "manual"),
      false,
      "Manual tab body is hidden after switching to Assistant",
    );
    // Chat composer is reachable inside the Assistant tab body.
    const promptInput = await page.$(
      '[data-test-id="property-panel"] ' +
        '[data-sidebar-tab-panel="assistant"] ' +
        '[aria-label="Agent prompt"]',
    );
    assert.ok(
      promptInput,
      "Agent prompt input is mounted under the Assistant tab body",
    );
    const sendBtn = await page.$(
      '[data-test-id="property-panel"] ' +
        '[data-sidebar-tab-panel="assistant"] ' +
        '[aria-label="Send agent prompt"]',
    );
    assert.ok(
      sendBtn,
      "Send agent prompt button is mounted under the Assistant tab body",
    );
  } finally {
    await ctx.close();
  }
});

// ---------------------------------------------------------------------------
// Clicking Manual brings the 12-section sub-tab bar back
// ---------------------------------------------------------------------------

test("e2e_sidebar_clicking_manual_surfaces_inspector_sections", async () => {
  const { ctx, page } = await openEditor();
  try {
    // Start on Assistant…
    await clickTab(page, "assistant");
    assert.equal(
      await tabSelected(page, "assistant"),
      "true",
      "Assistant tab is active before flipping back",
    );
    // …then flip back to Manual.
    await clickTab(page, "manual");
    assert.equal(
      await tabSelected(page, "manual"),
      "true",
      "Manual tab is aria-selected after clicking Manual",
    );
    assert.equal(
      await tabPanelVisible(page, "manual"),
      true,
      "Manual tab body is visible after clicking Manual",
    );
    // The 12-section sub-tab bar lives inside the Manual body and
    // surfaces named labels for each section (Layout / Size / Space …).
    const sectionLabels = await page.$$eval(
      '[data-test-id="property-panel"] ' +
        '[data-sidebar-tab-panel="manual"] ' +
        '[aria-label^="Show "][aria-label$=" inspector section"]',
      (els) =>
        els.map((el) =>
          (el.getAttribute("aria-label") || "")
            .replace(/^Show /, "")
            .replace(/ inspector section$/, ""),
        ),
    );
    assert.equal(
      sectionLabels.length,
      12,
      "Manual tab exposes all 12 inspector sub-section tabs",
    );
    for (const expected of [
      "Layout",
      "Size",
      "Space",
      "Pos",
      "Fill",
      "Stroke",
      "Type",
      "FX",
      "Trans",
      "Filter",
      "State",
      "Source",
    ]) {
      assert.ok(
        sectionLabels.includes(expected),
        `Manual tab contains section ${expected}`,
      );
    }
  } finally {
    await ctx.close();
  }
});

// ---------------------------------------------------------------------------
// Sidebar root stays mounted across tab flips
// ---------------------------------------------------------------------------

test("e2e_sidebar_root_stays_mounted_across_tab_switches", async () => {
  const { ctx, page } = await openEditor();
  try {
    const initial = await page.$('[data-test-id="property-panel"]');
    assert.ok(initial, "Sidebar root is mounted on initial load");
    await clickTab(page, "assistant");
    const onAssistant = await page.$('[data-test-id="property-panel"]');
    assert.ok(
      onAssistant,
      "Sidebar root remains mounted after switching to Assistant tab",
    );
    await clickTab(page, "manual");
    const backOnManual = await page.$('[data-test-id="property-panel"]');
    assert.ok(
      backOnManual,
      "Sidebar root remains mounted after switching back to Manual tab",
    );
  } finally {
    await ctx.close();
  }
});

// ---------------------------------------------------------------------------
// Both tabs are always available across surface flips
// ---------------------------------------------------------------------------

test("e2e_sidebar_both_tabs_present_across_surface_flips", async () => {
  const { ctx, page } = await openEditor();
  try {
    // Both tabs visible in Preview surface (initial).
    const previewTabs = await page.$$eval(
      '[data-test-id="property-panel"] [data-sidebar-tab]',
      (els) =>
        els.map((el) => el.getAttribute("data-sidebar-tab")).filter(Boolean),
    );
    assert.deepEqual(
      previewTabs.sort(),
      ["assistant", "manual"],
      "Manual + Assistant tabs both present in Preview surface",
    );

    // Flip to Spec surface — sidebar tabs must still both render
    // regardless of whether a story is selected.
    await clickSurfacePill(page, 1);
    await page.waitForFunction(
      () => {
        const el = document.querySelector('[data-test-id="spec-pane"]');
        return el && getComputedStyle(el).display !== "none";
      },
      { timeout: 5000 },
    );
    const specTabs = await page.$$eval(
      '[data-test-id="property-panel"] [data-sidebar-tab]',
      (els) =>
        els.map((el) => el.getAttribute("data-sidebar-tab")).filter(Boolean),
    );
    assert.deepEqual(
      specTabs.sort(),
      ["assistant", "manual"],
      "Manual + Assistant tabs both present in Spec surface (no story selected)",
    );
    // Tab toggling still works on the Spec surface.
    await clickTab(page, "assistant");
    assert.equal(
      await tabSelected(page, "assistant"),
      "true",
      "Assistant tab is selectable on the Spec surface without a story",
    );
  } finally {
    await ctx.close();
  }
});
