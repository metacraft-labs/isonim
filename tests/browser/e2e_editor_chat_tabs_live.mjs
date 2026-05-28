// Playwright-driven e2e for the per-chat robot buttons in the top
// tab bar of the right sidebar.
//
// User requirement (verbatim, 2026-05-28):
//
//   "I don't like that the assistant chats are appearing below the
//    assistant button. My idea was that they would appear next to
//    the assistant button (or rather that the assistant button
//    represents the initially created chat session, but I can add
//    additional ones). I think the design may start to look better
//    if we switch to icons in this area. The manual edit button can
//    be represented by a wrench and each assistant can be a robot-
//    like icon with the status indicator overlayed on top. The plus
//    sign will sit next to the last robot icon in the row and it
//    would create new chats (new robot icons)."
//
// This test pins the live behaviour of the new icon-driven top tab
// bar:
//
//   1. Initial editor mount surfaces ONE robot icon in the top tab
//      bar (the seeded chat session). The "+" button is present and
//      keyboard-reachable. With one chat there's no overflow.
//   2. Clicking the "+" button creates a new robot icon and
//      activates it (aria-selected="true"). Clicking the first
//      robot flips active back.
//   3. Creating ~10 chats inside a narrow sidebar (default 320 px)
//      makes the bar wider than its container — it now scrolls
//      horizontally (``scrollWidth > clientWidth``) instead of
//      hiding tabs behind a chevron popup. The active robot stays
//      reachable via native scroll.
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
  // The robot icons live directly in the top tab bar now — no
  // Assistant tab to click first.
  await page.waitForSelector(
    '[data-test-id="property-panel"] [data-sidebar-tab-bar="true"] ' +
      "[data-chat-tab]",
    { timeout: 10000 },
  );
  return { ctx, page };
}

async function chatTabs(page) {
  return await page.evaluate(() => {
    const tabBar = document.querySelector(
      '[data-test-id="property-panel"] [data-sidebar-tab-bar="true"]',
    );
    if (!tabBar) return [];
    return Array.from(tabBar.querySelectorAll("[data-chat-tab]")).map((t) => ({
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
        t.querySelector("[data-chat-status]") || { getAttribute: () => null }
      ).getAttribute("data-chat-status"),
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

async function tabBarScrollState(page) {
  return await page.evaluate(() => {
    const tabBar = document.querySelector(
      '[data-test-id="property-panel"] [data-sidebar-tab-bar="true"]',
    );
    if (!tabBar) return null;
    return {
      scrollWidth: tabBar.scrollWidth,
      clientWidth: tabBar.clientWidth,
      scrollLeft: tabBar.scrollLeft,
      overflowX: getComputedStyle(tabBar).overflowX,
    };
  });
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

// DEFERRED Phase F — see Front-Ends/IsoNim/isonim-editor.md §"AI assistant placement". The sidebar chat-tab strip is gone; per-chat robot icons relocate to the chrome bar and drive a slide-out drawer.
test(
  "e2e_chat_tabs_initial_state_has_single_new_chat",
  {
    skip: "Phase A demolition; replaced by Phase F drawer e2e (see isonim-editor.md §AI assistant placement)",
  },
  async () => {
    const { ctx, page } = await openEditor();
    try {
      const tabs = await chatTabs(page);
      assert.equal(tabs.length, 1, "exactly one chat tab on initial load");
      assert.equal(
        tabs[0].label,
        "New chat",
        "first robot's tooltip is 'New chat'",
      );
      // The seeded chat isn't active by default (the sidebar opens
      // on Manual). The aria-selected reflects the active chat
      // regardless of which sidebar surface is showing, so on a
      // single-chat workspace it stays "true" once the sidebar
      // surfaces Assistant. For the initial-mount probe we only
      // check the robot exists and is keyboard-reachable.
      assert.equal(
        tabs[0].id,
        "chat-1",
        "seeded chat carries the stable 'chat-1' id",
      );

      const newBtn = await page.$(
        '[data-test-id="property-panel"] [data-chat-tab-new="true"]',
      );
      assert.ok(newBtn, '"+" new-chat button is mounted in the top tab bar');
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

      // Wrench (Manual) button is present and carries a tooltip.
      const wrench = await page.$(
        '[data-test-id="property-panel"] [data-sidebar-tab="manual"]',
      );
      assert.ok(wrench, "wrench (Manual) button is present in the top tab bar");
      assert.equal(
        await wrench.getAttribute("title"),
        "Manual edits",
        "wrench advertises its title for hover tooltips",
      );

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
  },
);

// ---------------------------------------------------------------------------
// "+" creates the second chat; clicking the first tab activates it back.
// ---------------------------------------------------------------------------

test(
  "e2e_chat_tabs_plus_creates_new_chat_and_switching_works",
  {
    skip: "Phase A demolition; replaced by Phase F drawer e2e (see isonim-editor.md §AI assistant placement)",
  },
  async () => {
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

      // Switch back to chat-1 by clicking its robot.
      await clickChatTab(page, "chat-1");
      tabs = await chatTabs(page);
      assert.equal(
        tabs[0].selected,
        "true",
        "first chat re-activates on click",
      );
      assert.equal(
        tabs[1].selected,
        "false",
        "second chat deactivates when first is selected",
      );
    } finally {
      await ctx.close();
    }
  },
);

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

test(
  "e2e_chat_tabs_many_chats_scroll_horizontally",
  {
    skip: "Phase A demolition; replaced by Phase F drawer e2e (see isonim-editor.md §AI assistant placement)",
  },
  async () => {
    const { ctx, page } = await openEditor();
    try {
      for (let i = 0; i < 9; i++) {
        await clickNewChat(page);
      }
      const tabs = await chatTabs(page);
      assert.equal(tabs.length, 10, "ten robot icons after creating 9 extras");

      // The newest chat (chat-10) is active. Every robot — visible or
      // scrolled out of view — is still mounted in the top bar (no
      // hide-via-display:none any more).
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
      assert.ok(scroll, "tab bar is resolvable on the page");
      assert.equal(
        scroll.overflowX,
        "auto",
        "top tab bar uses overflow-x:auto for horizontal scroll",
      );
      assert.ok(
        scroll.scrollWidth > scroll.clientWidth,
        "tab bar's content (wrench + 10 robots + plus) exceeds its " +
          "client width — horizontal scroll is engaged",
      );
    } finally {
      await ctx.close();
    }
  },
);
