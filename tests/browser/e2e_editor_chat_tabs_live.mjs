// Playwright-driven e2e for the per-chat robot buttons in the chrome
// bar's right-edge slot (Phase F).
//
// Phase F moves the per-chat robot row from the demolished sidebar
// tab bar to the chrome bar — see ``Front-Ends/IsoNim/isonim-editor.md``
// §"AI assistant placement". Each chat session = one robot icon in
// ``[data-chrome-chat-strip]``; clicking a robot toggles the AI
// slide-out drawer (``[data-ai-drawer]``).  This file pins the live
// behaviour of the chrome-bar robot row:
//
//   1. Initial editor mount surfaces ONE robot icon in the chrome-bar
//      strip (the seeded chat session) plus a trailing "+" button.
//      The AI drawer is MOUNTED but ``display: none`` so the editor
//      surface stays focused on the inspector.
//   2. Clicking the "+" creates a new robot, activates it AND opens
//      the drawer.  Clicking the first robot flips the drawer to that
//      chat without closing.
//   3. Creating many chats in the (now chrome-bar) strip engages
//      horizontal scroll (``scrollWidth > clientWidth``) instead of
//      hiding tabs in a popup.  Every robot stays mounted in the DOM.
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
  // The robot icons live in the chrome bar's right-edge slot now;
  // the AI drawer is the surface that opens when a robot is clicked.
  await page.waitForSelector(
    '[data-preview-chrome-bar="true"] [data-chrome-chat-strip="true"] ' +
      "[data-chat-tab]",
    { timeout: 10000 },
  );
  return { ctx, page };
}

async function chatTabs(page) {
  return await page.evaluate(() => {
    const strip = document.querySelector(
      '[data-preview-chrome-bar="true"] [data-chrome-chat-strip="true"]',
    );
    if (!strip) return [];
    return Array.from(strip.querySelectorAll("[data-chat-tab]")).map((t) => ({
      id: t.getAttribute("data-chat-tab"),
      // Robot buttons are icon-only — the human label is on the
      // ``title`` and ``aria-label`` attributes, not in
      // ``textContent``.
      label:
        t.getAttribute("aria-label") ||
        t.getAttribute("title") ||
        (t.textContent || "").trim(),
      selected: t.getAttribute("aria-selected"),
      // Native scroll replaces the prior chevron overflow popup, so
      // ``displayed`` is always true while the node is in the DOM.
      displayed: getComputedStyle(t).display !== "none",
      status: (
        t.querySelector("[data-chat-status-dot]") || {
          getAttribute: () => null,
        }
      ).getAttribute("data-chat-status"),
    }));
  });
}

async function clickNewChat(page) {
  await page.evaluate(() => {
    const btn = document.querySelector(
      '[data-preview-chrome-bar="true"] [data-chrome-chat-new="true"]',
    );
    if (!btn) throw new Error('Chrome-bar chat "+" button not found');
    btn.click();
  });
}

async function clickChatTab(page, id) {
  await page.evaluate((wanted) => {
    const el = document.querySelector(
      `[data-preview-chrome-bar="true"] [data-chat-tab="${wanted}"]`,
    );
    if (!el) throw new Error(`Chrome-bar chat tab ${wanted} not found in DOM`);
    el.click();
  }, id);
}

async function tabBarScrollState(page) {
  return await page.evaluate(() => {
    const strip = document.querySelector(
      '[data-preview-chrome-bar="true"] [data-chrome-chat-strip="true"]',
    );
    if (!strip) return null;
    return {
      scrollWidth: strip.scrollWidth,
      clientWidth: strip.clientWidth,
      scrollLeft: strip.scrollLeft,
      overflowX: getComputedStyle(strip).overflowX,
    };
  });
}

async function activeChatId(page) {
  return await page.evaluate(() => {
    const el = document.querySelector(
      '[data-preview-chrome-bar="true"] ' +
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

// Phase F (2026-05-28) — Adapted from the Phase A skip stub. The
// chat strip lives in the chrome bar now; the wrench tab is gone
// (its role was demolished alongside the Manual/Assistant tab pair).
test("e2e_chat_tabs_initial_state_has_single_new_chat", async () => {
  const { ctx, page } = await openEditor();
  try {
    const tabs = await chatTabs(page);
    assert.equal(tabs.length, 1, "exactly one chat tab on initial load");
    assert.equal(
      tabs[0].label,
      "New chat",
      "first robot's tooltip is 'New chat'",
    );
    assert.equal(
      tabs[0].id,
      "chat-1",
      "seeded chat carries the stable 'chat-1' id",
    );

    const newBtn = await page.$(
      '[data-preview-chrome-bar="true"] [data-chrome-chat-new="true"]',
    );
    assert.ok(newBtn, '"+" new-chat button is mounted in the chrome-bar strip');
    assert.equal(
      await newBtn.getAttribute("aria-label"),
      "Create new chat",
      '"+" button advertises its aria-label',
    );
    assert.equal(
      await newBtn.getAttribute("title"),
      "Create new chat",
      '"+" button advertises its title for hover tooltips',
    );

    // Phase F: the wrench (Manual) button is gone. The sidebar is a
    // single-column scroll surface now and the AI assistant drawer
    // handles chat affordance via the chrome bar.
    const wrench = await page.$(
      '[data-test-id="property-panel"] [data-sidebar-tab="manual"]',
    );
    assert.equal(wrench, null, "Phase A demolished the wrench (Manual) button");

    // Each robot exposes a status dot overlay with a reactive
    // data-chat-status attribute. Initial state is idle.
    assert.equal(
      tabs[0].status,
      "idle",
      "robot status dot starts in the idle state",
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
    assert.equal(tabs.length, 2, "second robot appears after clicking +");
    assert.equal(
      tabs[1].label,
      "New chat 2",
      "second robot's tooltip is 'New chat 2'",
    );
    // Phase F: the "+" click opens the drawer, so the new chat
    // shows aria-selected="true" while the drawer is open. The
    // previous chat is no longer active.
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

    // Switch to chat-1 by clicking its robot — the drawer stays
    // open and surfaces chat-1.
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
// Many chats overflow the top tab bar horizontally and the active robot
// stays reachable via native scroll.
// ---------------------------------------------------------------------------
//
// Per the 2026-05-28 icon redesign, the prior chevron-overflow popup
// (``data-chat-tab-overflow="true"`` chevron-down button + a listbox
// popup that surfaced hidden chats) is gone. The top tab bar now uses
// ``overflow-x: auto`` so robots that don't fit fall behind a native
// horizontal scrollbar instead of being hidden + reachable through a
// popup. This test asserts that contract: ``scrollWidth`` exceeds
// ``clientWidth`` (proof that scrolling is needed and possible) and
// every robot is still present in the DOM.

test("e2e_chat_tabs_many_chats_scroll_horizontally", async () => {
  const { ctx, page } = await openEditor();
  try {
    for (let i = 0; i < 9; i++) {
      await clickNewChat(page);
    }
    const tabs = await chatTabs(page);
    assert.equal(tabs.length, 10, "ten robot icons after creating 9 extras");

    // The newest chat (chat-10) is active. Every robot — visible or
    // scrolled out of view — is still mounted in the chrome-bar
    // strip (no hide-via-display:none any more).
    const active = tabs.find((t) => t.selected === "true");
    assert.ok(active, "an active robot is identifiable in the DOM");
    assert.equal(active.id, "chat-10", "newly created chat-10 is active");
    for (const t of tabs) {
      assert.equal(
        t.displayed,
        true,
        `robot ${t.id} stays mounted (native scroll, not hidden)`,
      );
    }

    const scroll = await tabBarScrollState(page);
    assert.ok(scroll, "chrome-bar chat strip is resolvable on the page");
    assert.equal(
      scroll.overflowX,
      "auto",
      "chrome-bar chat strip uses overflow-x:auto for horizontal scroll",
    );
    assert.ok(
      scroll.scrollWidth > scroll.clientWidth,
      "chrome-bar chat strip's content (10 robots) exceeds its " +
        "client width — horizontal scroll is engaged",
    );
  } finally {
    await ctx.close();
  }
});

// Suppress unused-helper warning when no test uses ``activeChatId``.
void activeChatId;
