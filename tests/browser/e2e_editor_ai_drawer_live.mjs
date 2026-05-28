// Phase F — Playwright-driven e2e for the AI assistant slide-out
// drawer.  See ``Front-Ends/IsoNim/isonim-editor.md`` §"AI assistant
// placement" for the user-decided contract:
//
//   "Each chat session is its own robot in the chrome bar.  Chrome
//    bar gets crowded with N robots + plus.  Clicking any robot
//    opens the drawer showing that chat.  No in-drawer tab strip."
//
// What this file pins:
//
//   1. Initial state: ``[data-ai-drawer]`` is mounted but
//      ``display: none``; the chrome bar shows one robot + a "+"
//      button.
//   2. Clicking the robot opens the drawer
//      (``data-ai-drawer-open="true"``).  The chat composer is
//      reachable inside the drawer body.
//   3. Clicking the active robot a second time closes the drawer.
//   4. Clicking "+" creates a second chat AND opens the drawer to
//      it; the chrome-bar strip shows two robots.
//   5. Clicking the first robot switches the drawer to chat-1; the
//      second robot becomes inactive (drawer stays open).
//   6. ESC while drawer open closes the drawer.
//   7. Click outside the drawer closes the drawer.
//
// Runs through ``node --test`` like the other ``e2e_*.mjs`` files in
// this directory.

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

const PAGE_PORT = 18541;
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
    '[data-preview-chrome-bar="true"] [data-chrome-chat-strip="true"] ' +
      "[data-chat-tab]",
    { timeout: 10000 },
  );
  // The drawer is intentionally ``display: none`` on initial load,
  // so we wait for it to be ATTACHED (not visible) — Playwright's
  // default ``visible`` state would time out on a hidden node.
  await page.waitForSelector('[data-ai-drawer="true"]', {
    state: "attached",
    timeout: 10000,
  });
  return { ctx, page };
}

async function drawerState(page) {
  return await page.evaluate(() => {
    const drawer = document.querySelector('[data-ai-drawer="true"]');
    if (!drawer) return null;
    return {
      open: drawer.getAttribute("data-ai-drawer-open"),
      display: getComputedStyle(drawer).display,
    };
  });
}

async function activeRobotId(page) {
  return await page.evaluate(() => {
    const el = document.querySelector(
      '[data-preview-chrome-bar="true"] ' +
        '[data-chat-tab][aria-selected="true"]',
    );
    return el ? el.getAttribute("data-chat-tab") : null;
  });
}

async function clickRobot(page, id) {
  await page.evaluate((wanted) => {
    const el = document.querySelector(
      `[data-preview-chrome-bar="true"] [data-chat-tab="${wanted}"]`,
    );
    if (!el) throw new Error(`robot ${wanted} not found in chrome bar`);
    el.click();
  }, id);
}

async function clickNewChat(page) {
  await page.evaluate(() => {
    const btn = document.querySelector(
      '[data-preview-chrome-bar="true"] [data-chrome-chat-new="true"]',
    );
    if (!btn) throw new Error('Chrome-bar "+" button not found');
    btn.click();
  });
}

async function robotCount(page) {
  return await page.evaluate(() => {
    const strip = document.querySelector(
      '[data-preview-chrome-bar="true"] [data-chrome-chat-strip="true"]',
    );
    if (!strip) return 0;
    return strip.querySelectorAll("[data-chat-tab]").length;
  });
}

async function pressEscape(page) {
  await page.keyboard.press("Escape");
}

async function clickOutsideDrawer(page) {
  // The status bar at the bottom of the shell is well-clear of the
  // drawer (which is fixed to the right edge); clicking it triggers
  // the document mousedown handler the drawer registers for
  // click-outside-to-close.
  await page.evaluate(() => {
    const target =
      document.querySelector('[data-test-id="status-bar"]') ||
      document.querySelector('[data-preview-chrome-bar="true"]') ||
      document.body;
    const rect = target.getBoundingClientRect();
    const cx = Math.max(1, Math.floor(rect.left + 8));
    const cy = Math.max(1, Math.floor(rect.top + rect.height / 2));
    const ev = new MouseEvent("mousedown", {
      bubbles: true,
      cancelable: true,
      clientX: cx,
      clientY: cy,
    });
    document.elementFromPoint(cx, cy).dispatchEvent(ev);
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
// Initial state — drawer mounted but hidden; one robot + "+"
// ---------------------------------------------------------------------------

test("e2e_ai_drawer_initial_state_mounted_hidden", async () => {
  const { ctx, page } = await openEditor();
  try {
    const state = await drawerState(page);
    assert.ok(state, "drawer is mounted in the DOM");
    assert.equal(
      state.open,
      "false",
      'drawer carries data-ai-drawer-open="false" on initial load',
    );
    assert.equal(
      state.display,
      "none",
      "drawer is display: none on initial load",
    );

    assert.equal(await robotCount(page), 1, "exactly one robot at boot");
    const newBtn = await page.$(
      '[data-preview-chrome-bar="true"] [data-chrome-chat-new="true"]',
    );
    assert.ok(newBtn, "trailing + button is mounted in the chrome bar");
  } finally {
    await ctx.close();
  }
});

// ---------------------------------------------------------------------------
// Click robot → drawer opens; chat composer reachable
// ---------------------------------------------------------------------------

test("e2e_ai_drawer_robot_click_opens_drawer", async () => {
  const { ctx, page } = await openEditor();
  try {
    await clickRobot(page, "chat-1");
    const state = await drawerState(page);
    assert.equal(state.open, "true", "drawer flips open after robot click");
    assert.notEqual(
      state.display,
      "none",
      "drawer is visible (display != none) after robot click",
    );
    assert.equal(
      await activeRobotId(page),
      "chat-1",
      "robot for chat-1 is aria-selected after click",
    );

    // The chat composer (Agent prompt input + Send button) is
    // reachable inside the drawer body.
    const promptInput = await page.$(
      '[data-ai-drawer="true"] [aria-label="Agent prompt"]',
    );
    assert.ok(
      promptInput,
      "Agent prompt input is mounted inside the drawer body",
    );
    const sendBtn = await page.$(
      '[data-ai-drawer="true"] [aria-label="Send agent prompt"]',
    );
    assert.ok(sendBtn, "Send button is mounted inside the drawer body");
  } finally {
    await ctx.close();
  }
});

// ---------------------------------------------------------------------------
// Click active robot again → drawer closes
// ---------------------------------------------------------------------------

test("e2e_ai_drawer_active_robot_toggle_closes", async () => {
  const { ctx, page } = await openEditor();
  try {
    await clickRobot(page, "chat-1");
    assert.equal((await drawerState(page)).open, "true");
    // Second click on the same (active) robot toggles closed.
    await clickRobot(page, "chat-1");
    const state = await drawerState(page);
    assert.equal(
      state.open,
      "false",
      "drawer closes when the active robot is clicked again",
    );
    assert.equal(state.display, "none", "drawer is display: none after close");
  } finally {
    await ctx.close();
  }
});

// ---------------------------------------------------------------------------
// "+" creates a new chat + opens the drawer to it
// ---------------------------------------------------------------------------

test("e2e_ai_drawer_plus_button_spawns_chat_and_opens", async () => {
  const { ctx, page } = await openEditor();
  try {
    assert.equal((await drawerState(page)).open, "false");
    await clickNewChat(page);
    assert.equal(
      await robotCount(page),
      2,
      "robot row shows two chats after clicking +",
    );
    assert.equal(
      (await drawerState(page)).open,
      "true",
      "+ click opens the drawer to the new chat",
    );
    assert.equal(
      await activeRobotId(page),
      "chat-2",
      "newly created chat is active",
    );
  } finally {
    await ctx.close();
  }
});

// ---------------------------------------------------------------------------
// Click first robot → drawer switches to chat-1 (drawer stays open)
// ---------------------------------------------------------------------------

test("e2e_ai_drawer_switching_between_robots_keeps_drawer_open", async () => {
  const { ctx, page } = await openEditor();
  try {
    await clickNewChat(page); // chat-2 active + drawer open
    assert.equal(await activeRobotId(page), "chat-2");
    // Click the FIRST robot. Drawer must stay open, but switch chats.
    await clickRobot(page, "chat-1");
    assert.equal(
      (await drawerState(page)).open,
      "true",
      "drawer stays open when switching to a non-active robot",
    );
    assert.equal(
      await activeRobotId(page),
      "chat-1",
      "active robot is chat-1 after click",
    );
  } finally {
    await ctx.close();
  }
});

// ---------------------------------------------------------------------------
// ESC closes an open drawer
// ---------------------------------------------------------------------------

test("e2e_ai_drawer_escape_closes_open_drawer", async () => {
  const { ctx, page } = await openEditor();
  try {
    await clickRobot(page, "chat-1");
    assert.equal((await drawerState(page)).open, "true");
    await pressEscape(page);
    // Allow the synthetic Escape keydown to flush the close handler.
    await page.waitForFunction(
      () => {
        const drawer = document.querySelector('[data-ai-drawer="true"]');
        return drawer && drawer.getAttribute("data-ai-drawer-open") === "false";
      },
      { timeout: 3000 },
    );
    const state = await drawerState(page);
    assert.equal(state.open, "false", "ESC flips data-ai-drawer-open to false");
    assert.equal(state.display, "none", "ESC hides the drawer (display: none)");
  } finally {
    await ctx.close();
  }
});

// ---------------------------------------------------------------------------
// Click outside the drawer closes it (robots / + are exceptions)
// ---------------------------------------------------------------------------

test("e2e_ai_drawer_click_outside_closes_drawer", async () => {
  const { ctx, page } = await openEditor();
  try {
    await clickRobot(page, "chat-1");
    assert.equal((await drawerState(page)).open, "true");
    await clickOutsideDrawer(page);
    await page.waitForFunction(
      () => {
        const drawer = document.querySelector('[data-ai-drawer="true"]');
        return drawer && drawer.getAttribute("data-ai-drawer-open") === "false";
      },
      { timeout: 3000 },
    );
    const state = await drawerState(page);
    assert.equal(state.open, "false", "click outside the drawer closes it");
    assert.equal(state.display, "none", "drawer is hidden after click outside");
  } finally {
    await ctx.close();
  }
});

// ---------------------------------------------------------------------------
// localStorage persistence (deferred — Playwright storage replay is
// awkward in node --test mode without spec harness).  Tracked via the
// VM-level tests in ``test_editor_chat_tabs_vm.nim`` which pin the
// open/close/toggle contract that the localStorage shim mirrors.
// ---------------------------------------------------------------------------

test(
  "e2e_ai_drawer_state_persists_across_reload",
  {
    skip:
      "deferred — node --test runner replays a fresh context per test; " +
      "VM-level localStorage shim is exercised by " +
      "tests/test_editor_chat_tabs_vm.nim",
  },
  () => {
    // intentionally empty
  },
);
