// Playwright-driven e2e for the multi-chat tab strip inside the
// Assistant tab of the right sidebar.
//
// User requirement (verbatim):
//
//   "There should be a plus button in the tab at the top for
//    creating a new chat. If I create too many chat tabs, a
//    dropdown menu should be created (with a chevron down icon)."
//
// This test pins the live behaviour of the chat tab strip:
//
//   1. Initial editor mount surfaces one chat tab in the Assistant
//      tab body labeled "New chat". The "+" button is present and
//      keyboard-reachable. The overflow chevron is hidden when no
//      overflow is needed.
//   2. Clicking the "+" button creates a new "New chat 2" tab and
//      activates it (aria-selected="true"). Clicking the first tab
//      flips active back.
//   3. Creating ~10 chats inside a narrow sidebar (default 220 px)
//      triggers the overflow chevron — and the active tab stays
//      visible regardless of overflow.
//   4. Clicking the chevron opens a listbox popup that surfaces ALL
//      chats (visible + hidden) so the user can switch to any chat
//      regardless of overflow. Picking one activates it.
//
// Runs through ``node --test`` like the other ``e2e_*.mjs`` files
// in this directory.

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

const PAGE_PORT = 18537;
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
  // Activate the Assistant tab so the chat strip is visible.
  await page.evaluate(() => {
    const el = document.querySelector(
      '[data-test-id="property-panel"] [data-sidebar-tab="assistant"]',
    );
    if (el) el.click();
  });
  await page.waitForSelector(
    '[data-test-id="property-panel"] [data-chat-tab-strip="true"]',
    { timeout: 10000 },
  );
  return { ctx, page };
}

async function chatTabs(page) {
  return await page.evaluate(() => {
    const strip = document.querySelector(
      '[data-test-id="property-panel"] [data-chat-tab-strip="true"]',
    );
    if (!strip) return [];
    return Array.from(strip.querySelectorAll("[data-chat-tab]")).map((t) => ({
      id: t.getAttribute("data-chat-tab"),
      label: (t.textContent || "").trim(),
      selected: t.getAttribute("aria-selected"),
      hidden: t.getAttribute("data-chat-tab-hidden") === "true",
      displayed:
        t.getAttribute("data-chat-tab-hidden") !== "true" &&
        getComputedStyle(t).display !== "none",
    }));
  });
}

async function clickNewChat(page) {
  await page.evaluate(() => {
    const btn = document.querySelector(
      '[data-test-id="property-panel"] [data-chat-tab-new="true"]',
    );
    if (!btn) throw new Error('Chat "+" button not found');
    btn.click();
  });
}

async function clickChatTab(page, id) {
  await page.evaluate((wanted) => {
    const el = document.querySelector(
      `[data-test-id="property-panel"] [data-chat-tab="${wanted}"]`,
    );
    if (!el) throw new Error(`Chat tab ${wanted} not found in DOM`);
    el.click();
  }, id);
}

async function overflowButtonVisible(page) {
  return await page.evaluate(() => {
    const btn = document.querySelector(
      '[data-test-id="property-panel"] [data-chat-tab-overflow="true"]',
    );
    if (!btn) return false;
    return getComputedStyle(btn).display !== "none";
  });
}

async function openOverflowDropdown(page) {
  await page.evaluate(() => {
    const btn = document.querySelector(
      '[data-test-id="property-panel"] [data-chat-tab-overflow="true"]',
    );
    if (!btn) throw new Error("Overflow chevron not found");
    btn.click();
  });
}

async function overflowDropdownItems(page) {
  return await page.evaluate(() => {
    const popup = document.querySelector(
      '[data-test-id="property-panel"] ' +
        '[data-chat-tab-overflow-popup="true"]',
    );
    if (!popup) return [];
    if (getComputedStyle(popup).display === "none") return [];
    return Array.from(
      popup.querySelectorAll("[data-chat-tab-overflow-item]"),
    ).map((el) => ({
      id: el.getAttribute("data-chat-tab-overflow-item"),
      label: (el.textContent || "").trim(),
      selected: el.getAttribute("aria-selected"),
    }));
  });
}

async function clickOverflowItem(page, id) {
  await page.evaluate((wanted) => {
    const el = document.querySelector(
      '[data-test-id="property-panel"] ' +
        `[data-chat-tab-overflow-item="${wanted}"]`,
    );
    if (!el) throw new Error(`overflow item ${wanted} not found`);
    el.click();
  }, id);
}

async function activeChatId(page) {
  return await page.evaluate(() => {
    const el = document.querySelector(
      '[data-test-id="property-panel"] ' +
        '[data-chat-tab][aria-selected="true"]',
    );
    return el ? el.getAttribute("data-chat-tab") : null;
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
// Initial mount: one chat, "+" button present, overflow hidden
// ---------------------------------------------------------------------------

test("e2e_chat_tabs_initial_state_has_single_new_chat", async () => {
  const { ctx, page } = await openEditor();
  try {
    const tabs = await chatTabs(page);
    assert.equal(tabs.length, 1, "exactly one chat tab on initial load");
    assert.equal(tabs[0].label, "New chat", "first tab label is 'New chat'");
    assert.equal(
      tabs[0].selected,
      "true",
      "first chat is active on initial load",
    );

    const newBtn = await page.$(
      '[data-test-id="property-panel"] [data-chat-tab-new="true"]',
    );
    assert.ok(newBtn, '"+" new-chat button is mounted in the strip');
    assert.equal(
      await newBtn.getAttribute("aria-label"),
      "Create new chat",
      '"+" button advertises its aria-label',
    );

    assert.equal(
      await overflowButtonVisible(page),
      false,
      "overflow chevron is hidden with only one chat",
    );
  } finally {
    await ctx.close();
  }
});

// ---------------------------------------------------------------------------
// "+" creates the second chat; clicking the first tab activates it back.
// ---------------------------------------------------------------------------

test("e2e_chat_tabs_plus_creates_new_chat_and_switching_works", async () => {
  const { ctx, page } = await openEditor();
  try {
    await clickNewChat(page);
    let tabs = await chatTabs(page);
    assert.equal(tabs.length, 2, "second chat appears after clicking +");
    assert.equal(
      tabs[1].label,
      "New chat 2",
      "second chat is labelled 'New chat 2'",
    );
    assert.equal(
      tabs[1].selected,
      "true",
      "newly created chat is active immediately",
    );
    assert.equal(
      tabs[0].selected,
      "false",
      "previous chat is no longer active",
    );

    // Switch back to chat-1 by clicking its tab.
    await clickChatTab(page, "chat-1");
    tabs = await chatTabs(page);
    assert.equal(tabs[0].selected, "true", "first chat re-activates on click");
    assert.equal(
      tabs[1].selected,
      "false",
      "second chat deactivates when first is selected",
    );
  } finally {
    await ctx.close();
  }
});

// ---------------------------------------------------------------------------
// Many chats produce overflow + the active tab stays visible.
// ---------------------------------------------------------------------------

test("e2e_chat_tabs_overflow_chevron_appears_with_many_chats", async () => {
  const { ctx, page } = await openEditor();
  try {
    // Create 9 more chats — total 10. Default sidebar width is
    // ~220 px which can't fit 10 ``New chat N`` tabs side-by-side.
    for (let i = 0; i < 9; i++) {
      await clickNewChat(page);
    }
    const tabs = await chatTabs(page);
    assert.equal(tabs.length, 10, "ten chat tabs after creating 9 extras");

    // The newest chat (chat-10) is active and must remain visible.
    const active = tabs.find((t) => t.selected === "true");
    assert.ok(active, "an active tab is identifiable in the DOM");
    assert.equal(active.id, "chat-10", "newly created chat-10 is active");
    assert.equal(
      active.hidden,
      false,
      "active chat is never marked as overflowed",
    );
    assert.equal(
      active.displayed,
      true,
      "active chat's DOM node is visible in the strip",
    );

    assert.equal(
      await overflowButtonVisible(page),
      true,
      "overflow chevron is surfaced once tabs don't fit inline",
    );

    // At least one non-active tab is hidden by overflow detection.
    const hiddenCount = tabs.filter((t) => t.hidden).length;
    assert.ok(
      hiddenCount >= 1,
      "at least one chat tab is hidden by overflow handling",
    );
  } finally {
    await ctx.close();
  }
});

// ---------------------------------------------------------------------------
// Overflow popup surfaces every chat and lets the user activate any of them.
// ---------------------------------------------------------------------------

test("e2e_chat_tabs_overflow_popup_lets_user_pick_hidden_chat", async () => {
  const { ctx, page } = await openEditor();
  try {
    for (let i = 0; i < 9; i++) {
      await clickNewChat(page);
    }
    // chat-10 is active. Open the overflow dropdown.
    await openOverflowDropdown(page);
    const items = await overflowDropdownItems(page);
    assert.ok(
      items.length >= 1,
      "overflow popup is populated with chat options",
    );
    // The dropdown surfaces ALL chats so the user can switch to any
    // chat regardless of overflow visibility.
    const ids = items.map((it) => it.id).sort();
    const expectedIds = Array.from(
      { length: 10 },
      (_, i) => `chat-${i + 1}`,
    ).sort();
    assert.deepEqual(
      ids,
      expectedIds,
      "overflow popup lists every chat (visible + hidden)",
    );

    // Pick chat-1 from the popup.
    await clickOverflowItem(page, "chat-1");
    // After picking, the popup closes and chat-1 becomes active.
    const popupItemsAfter = await overflowDropdownItems(page);
    assert.equal(
      popupItemsAfter.length,
      0,
      "overflow popup closes after picking a chat",
    );
    assert.equal(
      await activeChatId(page),
      "chat-1",
      "picking chat-1 from the popup activates it",
    );
  } finally {
    await ctx.close();
  }
});
