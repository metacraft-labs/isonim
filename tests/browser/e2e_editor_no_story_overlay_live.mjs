// AIVS-NSO — Playwright-driven browser e2e for the "select an item
// to edit its properties" overlay + the always-mounted AI sidebar
// contract.
//
// The user complaint that drove this milestone:
//
//   "While I'm editing the spec, I should still be able to talk to
//    the AI assistant (the sidebar should not get hidden, but it may
//    somehow gray out the various editors that are usable when I
//    select an item — there could be some kind of overlay message
//    stating 'select an item to edit its properties' or 'switch to
//    preview mode and select an item to edit its properties'
//    depending on the current mode)."
//
// This test pins the new contract that replaces the prior TBAR-M3
// "Spec surface has no property/AI panel by default" invariant:
//
//   1. Open the editor without selecting any story.  The default
//      surface is ``sPreview`` with ``vm.selectedStory`` empty.
//   2. Switch to Spec mode.  Assert the no-story overlay is visible
//      and the AI sidebar (data-test-id="property-panel") remains
//      mounted.
//   3. Flip the mode triplet to Edit.  Assert the overlay is still
//      visible (the spec pane has nothing to edit without a brief)
//      and the AI sidebar is still mounted.
//   4. Flip the mode triplet to Comment.  Same overlay + sidebar
//      assertions.
//   5. Flip the surface back to Preview.  The active view is
//      ``evStoryboard`` by default — the storyboard has its own
//      "No user flows defined" empty state and does not need the
//      overlay, so the overlay must NOT be visible.  The AI sidebar
//      is still mounted.
//   6. Select Task App / Pages / Inbox.  Active view flips to
//      ``evPagePreview`` and the story is no longer empty — the
//      overlay must disappear.  The AI sidebar remains mounted.
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

const PAGE_PORT = 18527;
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
  await page.waitForSelector('[data-preview-surface-switch="true"]', {
    timeout: 10000,
  });
  await page.waitForSelector('[data-preview-chrome-bar="true"]', {
    timeout: 10000,
  });
  return { ctx, page };
}

async function clickSurfacePill(page, index) {
  // 0 = Preview, 1 = Spec.
  await page.evaluate((i) => {
    const pill = document.querySelector(
      `[data-preview-surface-switch="true"] [data-choice-group-pill="${i}"]`,
    );
    if (!pill) throw new Error(`surface pill index ${i} not found`);
    pill.click();
  }, index);
}

async function clickModePill(page, index) {
  // 0 = View, 1 = Comment, 2 = Edit.
  await page.evaluate((i) => {
    const chip = document.querySelector(
      `[data-toolbar-cluster="mode"] [data-choice-group-pill="${i}"]`,
    );
    if (!chip) throw new Error(`mode chip index ${i} not found`);
    chip.click();
  }, index);
}

async function selectTaskAppStory(page) {
  await page.waitForFunction(
    () =>
      typeof window !== "undefined" &&
      window.__isonimEditor &&
      typeof window.__isonimEditor.selectStoryByName === "function",
    { timeout: 10000 },
  );
  await page.evaluate(() => {
    window.__isonimEditor.selectStoryByName("Task App / Pages", "Inbox");
  });
}

async function overlayVisible(page) {
  return await page.evaluate(() => {
    const el = document.querySelector('[data-test-id="no-story-overlay"]');
    if (!el) return false;
    return getComputedStyle(el).display !== "none";
  });
}

async function overlayHeading(page) {
  return await page.evaluate(() => {
    const el = document.querySelector('[data-no-story-overlay-heading="true"]');
    return el ? (el.textContent || "").trim() : null;
  });
}

async function aiSidebarMounted(page) {
  const panel = await page.$('[data-test-id="property-panel"]');
  return panel !== null;
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
// AI sidebar visibility across surfaces / modes
// ---------------------------------------------------------------------------

test("e2e_ai_sidebar_remains_mounted_in_every_mode_no_story", async () => {
  const { ctx, page } = await openEditor();
  try {
    // Initial: Preview surface, View mode, no story selected.  AI
    // sidebar must be mounted (the user always has somewhere to ask
    // questions).
    assert.equal(
      await aiSidebarMounted(page),
      true,
      "AI sidebar mounted on initial load (Preview + View, no story)",
    );

    // Switch to Spec surface.  Per the AIVS-NSO contract the sidebar
    // remains mounted even though there is no story selected.
    await clickSurfacePill(page, 1);
    // Wait for the spec pane to display so the surface flip has
    // actually landed.
    await page.waitForFunction(
      () => {
        const el = document.querySelector('[data-test-id="spec-pane"]');
        if (!el) return false;
        return getComputedStyle(el).display !== "none";
      },
      { timeout: 5000 },
    );
    assert.equal(
      await aiSidebarMounted(page),
      true,
      "AI sidebar mounted in Spec + View mode without a story",
    );

    // Flip to Edit mode.  Still no story.
    await clickModePill(page, 2);
    assert.equal(
      await aiSidebarMounted(page),
      true,
      "AI sidebar mounted in Spec + Edit mode without a story",
    );

    // Flip to Comment mode.  Still no story.
    await clickModePill(page, 1);
    assert.equal(
      await aiSidebarMounted(page),
      true,
      "AI sidebar mounted in Spec + Comment mode without a story",
    );
  } finally {
    await ctx.close();
  }
});

// ---------------------------------------------------------------------------
// No-story overlay shows in Spec mode (View/Comment/Edit)
// ---------------------------------------------------------------------------

test("e2e_no_story_overlay_visible_in_spec_view_mode", async () => {
  const { ctx, page } = await openEditor();
  try {
    await clickSurfacePill(page, 1); // Spec
    await page.waitForFunction(
      () => {
        const el = document.querySelector('[data-test-id="spec-pane"]');
        return el && getComputedStyle(el).display !== "none";
      },
      { timeout: 5000 },
    );
    // Spec default mode is View (the shell mirror effect syncs spec
    // mode from ``vm.editMode`` which defaults to ``emView``).
    await clickModePill(page, 0);
    await page.waitForFunction(
      () => {
        const el = document.querySelector('[data-test-id="no-story-overlay"]');
        return el && getComputedStyle(el).display !== "none";
      },
      { timeout: 5000 },
    );
    assert.equal(
      await overlayVisible(page),
      true,
      "no-story overlay visible in Spec + View",
    );
    const heading = await overlayHeading(page);
    assert.ok(
      heading && heading.toLowerCase().includes("select an item"),
      `overlay heading carries "select an item"; got: ${heading}`,
    );
    assert.equal(
      await aiSidebarMounted(page),
      true,
      "AI sidebar still mounted alongside overlay (Spec + View)",
    );
  } finally {
    await ctx.close();
  }
});

test("e2e_no_story_overlay_visible_in_spec_edit_mode", async () => {
  // The mode chips' click dispatcher (``runEditorCommand``) refuses
  // to flip ``editMode`` when ``vm.selectedStory.val.isEmptyStory ==
  // true``: per ``commandRequirementFailure`` the View / Comment /
  // Edit commands all surface "Select a story before using …".  So
  // clicking the Edit chip without a story leaves ``editMode == emView``
  // and the overlay heading correctly reads "view its specification".
  // To exercise the Edit-mode copy path we drive ``vm.setEditMode``
  // directly via the editor's test hook — same path the chip would
  // take after a story is selected.
  const { ctx, page } = await openEditor();
  try {
    await clickSurfacePill(page, 1); // Spec
    await page.waitForFunction(
      () => {
        const el = document.querySelector('[data-test-id="spec-pane"]');
        return el && getComputedStyle(el).display !== "none";
      },
      { timeout: 5000 },
    );
    // Drive setEditMode directly because the chip-dispatch guard
    // refuses to fire without a selected story.
    await page.evaluate(() => {
      window.__isonimEditor.setEditMode(2); // emEdit (View=0, Comment=1, Edit=2)
    });
    await page.waitForFunction(
      () => {
        const el = document.querySelector(
          '[data-no-story-overlay-heading="true"]',
        );
        return el && (el.textContent || "").toLowerCase().includes("edit");
      },
      { timeout: 5000 },
    );
    assert.equal(
      await overlayVisible(page),
      true,
      "no-story overlay visible in Spec + Edit mode",
    );
    const heading = await overlayHeading(page);
    assert.ok(
      heading && heading.toLowerCase().includes("edit"),
      `overlay heading mentions "edit"; got: ${heading}`,
    );
    assert.equal(
      await aiSidebarMounted(page),
      true,
      "AI sidebar still mounted alongside overlay (Spec + Edit)",
    );
  } finally {
    await ctx.close();
  }
});

test("e2e_no_story_overlay_visible_in_spec_comment_mode", async () => {
  // See e2e_no_story_overlay_visible_in_spec_edit_mode for why we
  // drive setEditMode directly.
  const { ctx, page } = await openEditor();
  try {
    await clickSurfacePill(page, 1); // Spec
    await page.waitForFunction(
      () => {
        const el = document.querySelector('[data-test-id="spec-pane"]');
        return el && getComputedStyle(el).display !== "none";
      },
      { timeout: 5000 },
    );
    await page.evaluate(() => {
      window.__isonimEditor.setEditMode(1); // emComment
    });
    await page.waitForFunction(
      () => {
        const el = document.querySelector(
          '[data-no-story-overlay-heading="true"]',
        );
        return el && (el.textContent || "").toLowerCase().includes("comment");
      },
      { timeout: 5000 },
    );
    assert.equal(
      await overlayVisible(page),
      true,
      "no-story overlay visible in Spec + Comment mode",
    );
    const heading = await overlayHeading(page);
    assert.ok(
      heading && heading.toLowerCase().includes("comment"),
      `overlay heading mentions "comment"; got: ${heading}`,
    );
    assert.equal(
      await aiSidebarMounted(page),
      true,
      "AI sidebar still mounted alongside overlay (Spec + Comment)",
    );
  } finally {
    await ctx.close();
  }
});

// ---------------------------------------------------------------------------
// Preview mode storyboard does NOT show the overlay
// ---------------------------------------------------------------------------

test("e2e_no_story_overlay_hidden_in_preview_storyboard", async () => {
  // The storyboard is the default landing view and renders the full
  // flow graph regardless of selection.  It has its own
  // "No user flows defined" empty state; the no-story overlay must
  // NOT show on top of it.
  const { ctx, page } = await openEditor();
  try {
    // Confirm we are on Preview surface + storyboard view.
    const previewActive = await page.evaluate(() => {
      const pill = document.querySelector(
        '[data-preview-surface-switch="true"] [data-choice-group-pill="0"]',
      );
      return pill && pill.getAttribute("aria-pressed") === "true";
    });
    assert.equal(previewActive, true, "Preview surface is active on load");
    // Overlay must be hidden.
    const visible = await overlayVisible(page);
    assert.equal(
      visible,
      false,
      "no-story overlay hidden over the storyboard view (Preview default)",
    );
    assert.equal(
      await aiSidebarMounted(page),
      true,
      "AI sidebar mounted on Preview storyboard view",
    );
  } finally {
    await ctx.close();
  }
});

// ---------------------------------------------------------------------------
// Selecting a story dismisses the overlay
// ---------------------------------------------------------------------------

test("e2e_no_story_overlay_disappears_after_selecting_a_story", async () => {
  const { ctx, page } = await openEditor();
  try {
    // Switch to Spec + Edit to surface the overlay.
    await clickSurfacePill(page, 1);
    await page.waitForFunction(
      () => {
        const el = document.querySelector('[data-test-id="spec-pane"]');
        return el && getComputedStyle(el).display !== "none";
      },
      { timeout: 5000 },
    );
    await clickModePill(page, 2);
    await page.waitForFunction(
      () => {
        const el = document.querySelector('[data-test-id="no-story-overlay"]');
        return el && getComputedStyle(el).display !== "none";
      },
      { timeout: 5000 },
    );

    // Select the canonical Task App / Inbox story.  The shell's
    // reactive effect should hide the overlay now that
    // ``vm.selectedStory`` is populated.
    await selectTaskAppStory(page);
    await page.waitForFunction(
      () => {
        const el = document.querySelector('[data-test-id="no-story-overlay"]');
        if (!el) return true;
        return getComputedStyle(el).display === "none";
      },
      { timeout: 5000 },
    );
    assert.equal(
      await overlayVisible(page),
      false,
      "no-story overlay disappears after selecting a story",
    );
    assert.equal(
      await aiSidebarMounted(page),
      true,
      "AI sidebar still mounted after selecting a story",
    );

    // Flip back to Preview — page preview view loads — overlay still
    // hidden (story is selected).
    await clickSurfacePill(page, 0);
    const visibleInPreview = await overlayVisible(page);
    assert.equal(
      visibleInPreview,
      false,
      "no-story overlay stays hidden in Preview after a story is selected",
    );
  } finally {
    await ctx.close();
  }
});
