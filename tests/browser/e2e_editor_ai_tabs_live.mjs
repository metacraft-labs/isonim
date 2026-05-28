// Phase J (2026-05-28) — Playwright-driven e2e for the AI assistant
// sidebar tab strip.
//
// The AI assistant lives in the right sidebar (NOT a drawer) when
// the active editing mode is NOT ``emEdit``. Its tab strip exposes
// one tab per ``ChatSession`` in ``vm.chats``, a trailing ``+``
// button, and an overflow chevron (``▾``) that appears when the
// tabs do not fit. Tabs carry ``data-ai-assistant-tab="<chatId>"``;
// the chevron's data attribute is ``data-ai-assistant-overflow``;
// the plus button is ``data-ai-assistant-new-chat``; the dropdown
// listbox is ``data-ai-assistant-overflow-dropdown`` with
// per-session entries tagged
// ``data-ai-assistant-overflow-entry="<chatId>"``.
//
// Behaviour pinned here:
//
//   1. Initial editor mount (View mode → AI assistant) → one tab
//      "New chat" and a "+" button. No chevron yet.
//   2. Click "+" → two tabs visible; both reachable, the newer one
//      is the active tab.
//   3. Click the first tab → it becomes the active tab.
//   4. Click "+" ten more times → twelve tabs; the chevron appears
//      (overflow detected); the active tab is the freshly created
//      chat-12.
//   5. Click the chevron → dropdown listbox lists all twelve
//      sessions.
//   6. Click a hidden entry → it activates.
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

const PAGE_PORT = 18554;
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
  // Default mode is View → AI assistant is the visible right-sidebar
  // surface; wait for its tab strip to render.
  await page.waitForSelector('[data-ai-assistant-tab-strip="true"]', {
    timeout: 10000,
  });
  return { ctx, page };
}

async function tabList(page) {
  return await page.evaluate(() => {
    const strip = document.querySelector('[data-ai-assistant-tab-list="true"]');
    if (!strip) return [];
    return Array.from(strip.querySelectorAll("[data-ai-assistant-tab]")).map(
      (t) => ({
        id: t.getAttribute("data-ai-assistant-tab"),
        selected: t.getAttribute("aria-selected"),
        label: (
          t.querySelector("[data-ai-assistant-tab-label]") || t
        ).textContent.trim(),
      }),
    );
  });
}

async function clickNewChat(page) {
  await page.evaluate(() => {
    const btn = document.querySelector('[data-ai-assistant-new-chat="true"]');
    if (!btn) throw new Error("AI assistant '+' button not found");
    btn.click();
  });
}

async function clickTab(page, id) {
  await page.evaluate((wanted) => {
    const el = document.querySelector(`[data-ai-assistant-tab="${wanted}"]`);
    if (!el) throw new Error(`AI assistant tab ${wanted} not found`);
    el.click();
  }, id);
}

async function chevronVisible(page) {
  return await page.evaluate(() => {
    const btn = document.querySelector('[data-ai-assistant-overflow="true"]');
    if (!btn) return false;
    return getComputedStyle(btn).display !== "none";
  });
}

async function clickChevron(page) {
  await page.evaluate(() => {
    const btn = document.querySelector('[data-ai-assistant-overflow="true"]');
    if (!btn) throw new Error("AI assistant overflow chevron not found");
    btn.click();
  });
}

async function dropdownEntries(page) {
  return await page.evaluate(() => {
    const dropdown = document.querySelector(
      '[data-ai-assistant-overflow-dropdown="true"]',
    );
    if (!dropdown) return [];
    return Array.from(
      dropdown.querySelectorAll("[data-ai-assistant-overflow-entry]"),
    ).map((e) => e.getAttribute("data-ai-assistant-overflow-entry"));
  });
}

async function clickDropdownEntry(page, id) {
  await page.evaluate((wanted) => {
    const el = document.querySelector(
      `[data-ai-assistant-overflow-entry="${wanted}"]`,
    );
    if (!el) throw new Error(`Dropdown entry ${wanted} not found`);
    el.click();
  }, id);
}

async function activeTabId(page) {
  return await page.evaluate(() => {
    const el = document.querySelector(
      '[data-ai-assistant-tab][aria-selected="true"]',
    );
    return el ? el.getAttribute("data-ai-assistant-tab") : null;
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

test("e2e_ai_tabs_initial_state_has_one_tab_and_plus_button", async () => {
  const { ctx, page } = await openEditor();
  try {
    const tabs = await tabList(page);
    assert.equal(tabs.length, 1, "exactly one tab on initial mount");
    assert.equal(tabs[0].id, "chat-1");
    assert.equal(tabs[0].label, "New chat");
    assert.equal(tabs[0].selected, "true", "the lone chat is active");
    const plus = await page.$('[data-ai-assistant-new-chat="true"]');
    assert.ok(plus, "the trailing '+' button is mounted");
    // Chevron is hidden until tabs overflow.
    assert.equal(await chevronVisible(page), false);
  } finally {
    await ctx.close();
  }
});

test("e2e_ai_tabs_plus_creates_second_tab_and_switching_works", async () => {
  const { ctx, page } = await openEditor();
  try {
    await clickNewChat(page);
    let tabs = await tabList(page);
    assert.equal(tabs.length, 2, "second tab appears after clicking +");
    assert.equal(tabs[1].id, "chat-2");
    assert.equal(tabs[1].selected, "true", "new tab is active");
    assert.equal(tabs[0].selected, "false");

    await clickTab(page, "chat-1");
    tabs = await tabList(page);
    assert.equal(tabs[0].selected, "true", "first tab re-activates on click");
    assert.equal(tabs[1].selected, "false");
  } finally {
    await ctx.close();
  }
});

test("e2e_ai_tabs_many_tabs_engage_overflow_chevron_and_dropdown", async () => {
  const { ctx, page } = await openEditor();
  try {
    // Open a total of twelve sessions (one seeded + eleven created).
    for (let i = 0; i < 11; i++) {
      await clickNewChat(page);
    }
    const tabs = await tabList(page);
    assert.equal(tabs.length, 12, "twelve tabs exist after creating eleven");
    // The newest chat is active.
    assert.equal(await activeTabId(page), "chat-12");

    // Wait a tick so the deferred overflow measurement runs.
    await page.waitForTimeout(50);
    assert.equal(
      await chevronVisible(page),
      true,
      "chevron is visible once the strip cannot fit every tab",
    );

    await clickChevron(page);
    const entries = await dropdownEntries(page);
    assert.equal(
      entries.length,
      12,
      "dropdown lists every session (visible + overflowed)",
    );

    // Pick chat-1 (the seeded session) from the dropdown — guaranteed
    // to be one of the entries that scrolled out of the visible strip
    // after the 11 inserts above.
    await clickDropdownEntry(page, "chat-1");
    assert.equal(await activeTabId(page), "chat-1");
  } finally {
    await ctx.close();
  }
});
