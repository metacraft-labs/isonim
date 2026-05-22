// TBAR-M3 — Playwright-driven browser e2e for the editor's top-bar
// Preview / Spec surface switch + the chevron-popup screen-size
// selector.
//
// Boots Chromium against the real editor bundle produced by
// ``just editor-build`` in ``isonim-examples``. The harness:
//
//   1. Rebuilds the editor bundle so the test reflects the current
//      ``shell.nim`` / ``viewmodels.nim`` source.
//   2. Starts a static file server pointing at ``build/editor/``.
//   3. Opens the editor and asserts:
//        * Initial surface is Preview, the property panel (right rail)
//          is mounted, the View/Comment/Edit mode triplet is mounted.
//        * Clicking the Spec pill in the top-bar segmented control
//          flips the surface; the property panel UNMOUNTS (DOM is gone,
//          not just hidden), the View/Comment/Edit triplet remains.
//        * Clicking Preview flips back; the property panel re-mounts.
//        * Clicking the chevron screen-size trigger opens a listbox
//          popup with the per-backend viewport labels.
//        * Selecting a different viewport updates the chevron's active
//          label AND changes the editor's viewport state (the chevron
//          label is the load-bearing surface — the editor's downstream
//          ``data-preview-viewport`` attribute on the iframe wrapper
//          may or may not exist depending on backend; we only assert
//          the cheveron's active label updates, which is the
//          milestone-scoped behaviour).
//
// This file runs via ``node --test`` — the same pattern the rest of
// ``tests/browser/e2e_*.mjs`` files use. ``npx playwright test`` is
// reserved for ``tests/browser/specs/*.spec.ts``.

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

const PAGE_PORT = 18520;
let pageServer = null;
let chromium = null;
let browser = null;

function exec(cmd, opts = {}) {
  return execSync(cmd, { stdio: "pipe", ...opts }).toString();
}

function buildEditor() {
  // Rebuild the editor bundle so the test reflects the current
  // ``shell.nim`` source. The build is run inside the
  // ``isonim-examples`` direnv shell so ``nim`` and the path-based
  // ``isonim`` dependency are resolved the same way ``just
  // editor-build`` runs them.
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
  // Wait until the shell paints. The Preview/Spec segmented control
  // is the canonical TBAR-M3 sentinel.
  await page.waitForSelector('[data-preview-surface-switch="true"]', {
    timeout: 10000,
  });
  await page.waitForSelector('[data-preview-chrome-bar="true"]', {
    timeout: 10000,
  });
  return { ctx, page };
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
// Preview / Spec segmented control
// ---------------------------------------------------------------------------

test("e2e_topbar_segmented_renders_with_preview_active", async () => {
  const { ctx, page } = await openEditor();
  try {
    const surfaceCluster = await page.$('[data-preview-surface-switch="true"]');
    assert.ok(surfaceCluster, "Preview/Spec segmented cluster is mounted");
    const previewPill = await page.$(
      '[data-preview-surface-switch="true"] ' + '[data-choice-group-pill="0"]',
    );
    const specPill = await page.$(
      '[data-preview-surface-switch="true"] ' + '[data-choice-group-pill="1"]',
    );
    assert.ok(previewPill, "Preview pill exists");
    assert.ok(specPill, "Spec pill exists");
    const previewPressed = await previewPill.getAttribute("aria-pressed");
    const specPressed = await specPill.getAttribute("aria-pressed");
    assert.equal(
      previewPressed,
      "true",
      "Preview pill is active on initial load",
    );
    assert.equal(
      specPressed,
      "false",
      "Spec pill is not active on initial load",
    );
  } finally {
    await ctx.close();
  }
});

test("e2e_topbar_property_panel_mounted_initially", async () => {
  const { ctx, page } = await openEditor();
  try {
    const panel = await page.$('[data-test-id="property-panel"]');
    assert.ok(panel, "property panel is mounted in Preview surface");
  } finally {
    await ctx.close();
  }
});

test("e2e_topbar_clicking_spec_unmounts_property_panel", async () => {
  const { ctx, page } = await openEditor();
  try {
    const specPill = await page.$(
      '[data-preview-surface-switch="true"] ' + '[data-choice-group-pill="1"]',
    );
    await specPill.click();
    // The shell-level reactive effect removes the chat panel from the
    // DOM when surface flips to sSpec.
    await page.waitForSelector('[data-test-id="property-panel"]', {
      state: "detached",
      timeout: 5000,
    });
    const panel = await page.$('[data-test-id="property-panel"]');
    assert.equal(
      panel,
      null,
      "property panel unmounts from the DOM when surface == sSpec",
    );
    // The Spec-pane placeholder slot becomes visible.
    const specPane = await page.$('[data-test-id="spec-pane"]');
    assert.ok(specPane, "spec-pane element exists");
    const display = await specPane.evaluate(
      (el) => getComputedStyle(el).display,
    );
    assert.notEqual(display, "none", "spec-pane is displayed");
  } finally {
    await ctx.close();
  }
});

test("e2e_topbar_clicking_preview_remounts_property_panel", async () => {
  const { ctx, page } = await openEditor();
  try {
    // Flip to Spec first, then back to Preview.
    const specPill = await page.$(
      '[data-preview-surface-switch="true"] ' + '[data-choice-group-pill="1"]',
    );
    await specPill.click();
    await page.waitForSelector('[data-test-id="property-panel"]', {
      state: "detached",
      timeout: 5000,
    });
    const previewPill = await page.$(
      '[data-preview-surface-switch="true"] ' + '[data-choice-group-pill="0"]',
    );
    await previewPill.click();
    await page.waitForSelector('[data-test-id="property-panel"]', {
      state: "attached",
      timeout: 5000,
    });
    const panel = await page.$('[data-test-id="property-panel"]');
    assert.ok(panel, "property panel re-mounts when surface flips back");
  } finally {
    await ctx.close();
  }
});

test("e2e_topbar_view_comment_edit_triplet_present_in_both_surfaces", async () => {
  const { ctx, page } = await openEditor();
  try {
    // The View/Comment/Edit chip group lives in the chrome bar as the
    // ``mode`` toolbar cluster and is unaffected by the surface
    // switch.
    const modeClusterPreview = await page.$('[data-toolbar-cluster="mode"]');
    assert.ok(
      modeClusterPreview,
      "mode chip cluster is present in Preview surface",
    );
    // Flip to Spec.
    const specPill = await page.$(
      '[data-preview-surface-switch="true"] ' + '[data-choice-group-pill="1"]',
    );
    await specPill.click();
    await page.waitForSelector('[data-test-id="property-panel"]', {
      state: "detached",
      timeout: 5000,
    });
    const modeClusterSpec = await page.$('[data-toolbar-cluster="mode"]');
    assert.ok(
      modeClusterSpec,
      "mode chip cluster is also present in Spec surface",
    );
  } finally {
    await ctx.close();
  }
});

// ---------------------------------------------------------------------------
// Chevron screen-size selector
// ---------------------------------------------------------------------------

test("e2e_topbar_chevron_screen_size_selector_mounts", async () => {
  const { ctx, page } = await openEditor();
  try {
    const chevronTrigger = await page.$(
      '[data-preview-viewport-chevron="true"] ' +
        '[data-choice-group-trigger="true"]',
    );
    assert.ok(chevronTrigger, "chevron screen-size trigger is mounted");
    const labelEl = await page.$(
      '[data-preview-viewport-chevron="true"] ' +
        '[data-choice-group-trigger-label="true"]',
    );
    const initialLabel = (await labelEl.textContent()).trim();
    assert.ok(
      initialLabel.length > 0,
      "chevron displays an initial viewport label",
    );
  } finally {
    await ctx.close();
  }
});

test("e2e_topbar_chevron_opens_popup_with_viewport_options", async () => {
  const { ctx, page } = await openEditor();
  try {
    const chevronTrigger = await page.$(
      '[data-preview-viewport-chevron="true"] ' +
        '[data-choice-group-trigger="true"]',
    );
    await chevronTrigger.click();
    const expanded = await chevronTrigger.getAttribute("aria-expanded");
    assert.equal(
      expanded,
      "true",
      "chevron popup opens after clicking the trigger",
    );
    const popup = await page.$(
      '[data-preview-viewport-chevron="true"] ' +
        '[data-choice-group-popup="true"]',
    );
    const popupOpen = await popup.getAttribute("data-popup-open");
    assert.equal(popupOpen, "true", "popup data-attr flips open");
    const options = await page.$$(
      '[data-preview-viewport-chevron="true"] ' + "[data-choice-group-option]",
    );
    assert.ok(options.length >= 2, "popup lists at least two viewport options");
  } finally {
    await ctx.close();
  }
});

test("e2e_topbar_chevron_selecting_option_updates_active_label", async () => {
  const { ctx, page } = await openEditor();
  try {
    const chevronTrigger = await page.$(
      '[data-preview-viewport-chevron="true"] ' +
        '[data-choice-group-trigger="true"]',
    );
    const labelEl = await page.$(
      '[data-preview-viewport-chevron="true"] ' +
        '[data-choice-group-trigger-label="true"]',
    );
    const initialLabel = (await labelEl.textContent()).trim();
    await chevronTrigger.click();
    // Pick the second option (something different from the active one
    // when initialIndex == 0 — and when initialIndex != 0 it's still
    // a valid alternative).
    const optionLabels = await page.$$eval(
      '[data-preview-viewport-chevron="true"] ' + "[data-choice-group-option]",
      (els) =>
        els.map(
          (el) => el.getAttribute("data-choice-group-option-label") || "",
        ),
    );
    assert.ok(
      optionLabels.length >= 2,
      "at least two viewport options are available",
    );
    // Find an option different from the initial active label.
    let pickIndex = -1;
    for (let i = 0; i < optionLabels.length; i++) {
      if (optionLabels[i] !== initialLabel) {
        pickIndex = i;
        break;
      }
    }
    assert.ok(pickIndex >= 0, "found a viewport option != initial");
    const target = await page.$(
      `[data-preview-viewport-chevron="true"] ` +
        `[data-choice-group-option="${pickIndex}"]`,
    );
    await target.click();
    // Active label should now reflect the picked option.
    const newLabel = (await labelEl.textContent()).trim();
    assert.equal(
      newLabel,
      optionLabels[pickIndex],
      "trigger label updates after selection",
    );
    // Popup closes.
    const expanded = await chevronTrigger.getAttribute("aria-expanded");
    assert.equal(expanded, "false", "popup closes after selecting a viewport");
  } finally {
    await ctx.close();
  }
});
