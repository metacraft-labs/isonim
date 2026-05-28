// Phase K — Playwright-driven browser e2e for the Notion-style
// inline comment overlay.
//
// The user-direction scenario:
//
//   1. Open editor; select a page story; switch to Comment mode.
//   2. Click on the preview canvas → an anchor marker appears and a
//      thread popover opens with an empty composer.
//   3. Type a comment + click Send → the comment lands on the
//      underlying annotation.  Popover closes.
//   4. Click the anchor → the popover re-opens showing the comment.
//   5. Click Resolve → the anchor's resolved data attribute flips
//      to "true" and the popover closes.
//   6. Switch to Edit mode → the overlay layer is hidden
//      (``display: none``) so the anchor is no longer visible.
//   7. Switch back to Comment mode → the anchor reappears with the
//      resolved visual (muted dot).
//
// Runs via ``node --test`` (same pattern as the rest of
// ``tests/browser/e2e_*.mjs``).
//
// IsoNim chrome-bar mode mapping (see browser.nim
// ``exposeWindowEditorHandle``):
//   0 = Spec, 1 = View, 2 = Comment, 3 = Edit
// We call ``window.__isonimEditor.setEditMode`` directly so we don't
// depend on the mode chip's "select a story first" guard which would
// otherwise reject Comment / Edit without a story.

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

const PAGE_PORT = 18563;
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
  const ctx = await b.newContext({ viewport: { width: 1440, height: 900 } });
  const page = await ctx.newPage();
  await page.goto(`http://127.0.0.1:${PAGE_PORT}/index.html`);
  await page.waitForSelector('[data-preview-chrome-bar="true"]', {
    timeout: 10000,
  });
  await page.waitForFunction(
    () =>
      typeof window !== "undefined" &&
      window.__isonimEditor &&
      typeof window.__isonimEditor.setEditMode === "function" &&
      typeof window.__isonimEditor.selectStoryByName === "function",
    { timeout: 10000 },
  );
  return { ctx, page };
}

async function selectTaskAppStory(page) {
  await page.evaluate(() => {
    window.__isonimEditor.selectStoryByName("Task App / Pages", "Inbox");
  });
}

async function setMode(page, modeIndex) {
  await page.evaluate((idx) => {
    window.__isonimEditor.setEditMode(idx);
  }, modeIndex);
}

const MODE_COMMENT = 2;
const MODE_VIEW = 1;
const MODE_EDIT = 3;

async function overlayVisible(page) {
  return await page.evaluate(() => {
    const el = document.querySelector('[data-comment-overlay="true"]');
    if (!el) return false;
    return getComputedStyle(el).display !== "none";
  });
}

async function popoverVisible(page) {
  return await page.evaluate(() => {
    const el = document.querySelector('[data-comment-thread-popover="true"]');
    if (!el) return false;
    return getComputedStyle(el).display !== "none";
  });
}

async function anchorCount(page) {
  return await page.evaluate(
    () => document.querySelectorAll("[data-comment-anchor]").length,
  );
}

async function anchorResolvedState(page, index = 0) {
  return await page.evaluate((i) => {
    const list = document.querySelectorAll("[data-comment-anchor]");
    if (i >= list.length) return null;
    return list[i].getAttribute("data-comment-resolved");
  }, index);
}

async function clickUnderlay(page) {
  // Click somewhere in the centre of the overlay so the new anchor's
  // popover anchors visibly inside the viewport.
  await page.evaluate(() => {
    const u = document.querySelector('[data-comment-overlay-underlay="true"]');
    if (!u) throw new Error("comment overlay underlay not mounted");
    const rect = u.getBoundingClientRect();
    const ev = new MouseEvent("click", {
      bubbles: true,
      cancelable: true,
      clientX: rect.left + Math.round(rect.width / 2),
      clientY: rect.top + Math.round(rect.height / 2),
    });
    u.dispatchEvent(ev);
  });
}

async function typeIntoComposer(page, text) {
  await page.evaluate((t) => {
    const ta = document.querySelector(
      '[data-comment-thread-popover-input="true"]',
    );
    if (!ta) throw new Error("composer textarea not mounted");
    ta.value = t;
    ta.dispatchEvent(new Event("input", { bubbles: true }));
  }, text);
}

async function clickSend(page) {
  await page.evaluate(() => {
    const btn = document.querySelector(
      '[data-comment-thread-popover-send="true"]',
    );
    if (!btn) throw new Error("send button not mounted");
    btn.click();
  });
}

async function clickResolve(page) {
  await page.evaluate(() => {
    const btn = document.querySelector(
      '[data-comment-thread-popover-resolve="true"]',
    );
    if (!btn) throw new Error("resolve button not mounted");
    btn.click();
  });
}

async function clickFirstAnchor(page) {
  await page.evaluate(() => {
    const a = document.querySelector("[data-comment-anchor]");
    if (!a) throw new Error("no anchor mounted");
    a.click();
  });
}

async function firstCommentText(page) {
  return await page.evaluate(() => {
    const el = document.querySelector(
      '[data-comment-thread-popover-comment="first"]',
    );
    return el ? (el.textContent || "").trim() : null;
  });
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
// Overlay visibility tracks the active edit mode
// ---------------------------------------------------------------------------

test("e2e_comment_overlay_hidden_outside_comment_mode", async () => {
  const { ctx, page } = await openEditor();
  try {
    await selectTaskAppStory(page);
    // Default mode is View.  Overlay is mounted but display:none.
    await page.waitForSelector('[data-comment-overlay="true"]', {
      timeout: 5000,
    });
    assert.equal(
      await overlayVisible(page),
      false,
      "comment overlay must be hidden in View mode",
    );

    // Edit mode also keeps the overlay hidden.
    await setMode(page, MODE_EDIT);
    assert.equal(
      await overlayVisible(page),
      false,
      "comment overlay must be hidden in Edit mode",
    );

    // Switching to Comment mode reveals it.
    await setMode(page, MODE_COMMENT);
    await page.waitForFunction(
      () => {
        const el = document.querySelector('[data-comment-overlay="true"]');
        return el && getComputedStyle(el).display !== "none";
      },
      { timeout: 5000 },
    );
    assert.equal(
      await overlayVisible(page),
      true,
      "comment overlay must surface in Comment mode",
    );
  } finally {
    await ctx.close();
  }
});

// ---------------------------------------------------------------------------
// Click-to-place + send + resolve + mode toggle round-trip
// ---------------------------------------------------------------------------

test("e2e_comment_overlay_full_thread_round_trip", async () => {
  const { ctx, page } = await openEditor();
  try {
    await selectTaskAppStory(page);
    await setMode(page, MODE_COMMENT);
    await page.waitForFunction(
      () => {
        const el = document.querySelector('[data-comment-overlay="true"]');
        return el && getComputedStyle(el).display !== "none";
      },
      { timeout: 5000 },
    );

    // Step A: no anchors yet.
    assert.equal(await anchorCount(page), 0, "starts with no anchors");
    assert.equal(
      await popoverVisible(page),
      false,
      "thread popover starts hidden",
    );

    // Step B: click underlay → anchor appears + popover opens.
    await clickUnderlay(page);
    await page.waitForFunction(
      () => document.querySelectorAll("[data-comment-anchor]").length === 1,
      { timeout: 5000 },
    );
    assert.equal(await anchorCount(page), 1, "underlay click drops one anchor");
    await page.waitForFunction(
      () => {
        const el = document.querySelector(
          '[data-comment-thread-popover="true"]',
        );
        return el && getComputedStyle(el).display !== "none";
      },
      { timeout: 5000 },
    );
    assert.equal(
      await popoverVisible(page),
      true,
      "popover auto-opens for the new anchor",
    );

    // Step C: type a comment + click Send → popover closes, anchor
    // stays.
    await typeIntoComposer(page, "Why is the hero so tall on phone?");
    await clickSend(page);
    await page.waitForFunction(
      () => {
        const el = document.querySelector(
          '[data-comment-thread-popover="true"]',
        );
        return !el || getComputedStyle(el).display === "none";
      },
      { timeout: 5000 },
    );
    assert.equal(
      await popoverVisible(page),
      false,
      "popover closes after Send",
    );
    assert.equal(await anchorCount(page), 1, "anchor persists after Send");

    // Step D: click the anchor → popover re-opens showing the comment
    // text the user just sent.
    await clickFirstAnchor(page);
    await page.waitForFunction(
      () => {
        const el = document.querySelector(
          '[data-comment-thread-popover="true"]',
        );
        return el && getComputedStyle(el).display !== "none";
      },
      { timeout: 5000 },
    );
    assert.equal(
      await firstCommentText(page),
      "Why is the hero so tall on phone?",
      "popover re-displays the sent comment",
    );

    // Step E: click Resolve → anchor flips to resolved, popover
    // closes.
    await clickResolve(page);
    await page.waitForFunction(
      () => {
        const a = document.querySelector("[data-comment-anchor]");
        return a && a.getAttribute("data-comment-resolved") === "true";
      },
      { timeout: 5000 },
    );
    assert.equal(
      await anchorResolvedState(page, 0),
      "true",
      "anchor's data-comment-resolved attribute is 'true' after Resolve",
    );
    assert.equal(
      await popoverVisible(page),
      false,
      "popover closes after Resolve",
    );

    // Step F: switch to View mode → overlay hidden, anchor invisible.
    await setMode(page, MODE_VIEW);
    await page.waitForFunction(
      () => {
        const el = document.querySelector('[data-comment-overlay="true"]');
        return el && getComputedStyle(el).display === "none";
      },
      { timeout: 5000 },
    );
    assert.equal(
      await overlayVisible(page),
      false,
      "comment overlay hides on switch to View",
    );

    // Step G: switch back to Comment mode → anchor re-appears,
    // resolved (muted dot) visual preserved.
    await setMode(page, MODE_COMMENT);
    await page.waitForFunction(
      () => {
        const el = document.querySelector('[data-comment-overlay="true"]');
        return el && getComputedStyle(el).display !== "none";
      },
      { timeout: 5000 },
    );
    assert.equal(
      await anchorCount(page),
      1,
      "anchor data survives the mode toggle",
    );
    assert.equal(
      await anchorResolvedState(page, 0),
      "true",
      "resolved state survives the mode toggle",
    );
  } finally {
    await ctx.close();
  }
});
