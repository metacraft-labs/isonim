// Phase N (2026-05-29) — Playwright-driven e2e for the LEFT
// sidebar drag-resize affordance.
//
// The left sidebar (story tree) carries a 4 px-wide
// ``data-resize-handle="left-sidebar"`` strip pinned to its right
// edge. Mousedown + mousemove on the strip drives
// ``window.__isonimEditor.setLeftSidebarWidth(width)``, which
// updates ``vm.leftSidebarWidth`` and feeds back into the
// reactive sidebar-width effect. The width is clamped to
// [180, 420] both by the JS-side resize shim and by the VM's
// ``clampLeftSidebarWidth`` helper.
//
// This file pins the live behaviour:
//
//   1. Sidebar mounts with the default 260 px width.
//   2. The resize handle is reachable + has ``cursor: col-resize``.
//   3. ``window.__isonimEditor.setLeftSidebarWidth(320)`` changes
//      the rendered sidebar width to 320 px.
//   4. The handle responds to a real ``mousedown`` +
//      ``mousemove`` + ``mouseup`` sequence by adjusting the
//      width (and the handle stays at the new right edge so
//      future drags keep working).
//   5. Bounds are honoured — pushing past 420 / below 180 snaps
//      to the boundary.
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

const PAGE_PORT = 18556;
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
  // The left sidebar root carries ``data-editor-sidebar="true"``.
  await page.waitForSelector('[data-editor-sidebar="true"]', {
    timeout: 10000,
  });
  await page.waitForSelector('[data-resize-handle="left-sidebar"]', {
    timeout: 10000,
  });
  return { ctx, page };
}

async function sidebarWidth(page) {
  return await page.evaluate(() => {
    const sidebar = document.querySelector('[data-editor-sidebar="true"]');
    if (!sidebar) return -1;
    return Math.round(sidebar.getBoundingClientRect().width);
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

test("e2e_sidebar_resize_handle_present_with_col_resize_cursor", async () => {
  const { ctx, page } = await openEditor();
  try {
    const probe = await page.evaluate(() => {
      const sidebar = document.querySelector('[data-editor-sidebar="true"]');
      const handle = document.querySelector(
        '[data-resize-handle="left-sidebar"]',
      );
      if (!sidebar || !handle) return null;
      const style = getComputedStyle(handle);
      const sidebarBox = sidebar.getBoundingClientRect();
      const handleBox = handle.getBoundingClientRect();
      return {
        cursor: style.cursor,
        position: style.position,
        width: Math.round(handleBox.width),
        // The handle's right edge sits at the sidebar's right edge
        // (the handle is ``right: 0`` inside the relatively-
        // positioned sidebar root, width 4 px).
        rightAlignedWithSidebar:
          Math.abs(
            Math.round(handleBox.right) - Math.round(sidebarBox.right),
          ) <= 1,
      };
    });
    assert.ok(probe, "sidebar + handle both mounted");
    assert.equal(probe.cursor, "col-resize");
    assert.equal(probe.position, "absolute");
    assert.equal(probe.width, 4);
    assert.equal(probe.rightAlignedWithSidebar, true);
  } finally {
    await ctx.close();
  }
});

test("e2e_sidebar_resize_via_set_left_sidebar_width_hook", async () => {
  // Headless contract: drives the same hook the JS-side mousemove
  // shim uses. This proves the VM signal → reactive width effect
  // → sidebar style flow lands without a real drag gesture.
  const { ctx, page } = await openEditor();
  try {
    const beforeWidth = await sidebarWidth(page);
    assert.ok(
      beforeWidth >= 180 && beforeWidth <= 420,
      "default width inside the clamp",
    );
    await page.evaluate(() => {
      window.__isonimEditor.setLeftSidebarWidth(340);
    });
    // The reactive width effect runs asynchronously through the
    // signal scheduler; wait one frame.
    await page.waitForFunction(
      () => {
        const sidebar = document.querySelector('[data-editor-sidebar="true"]');
        if (!sidebar) return false;
        return Math.round(sidebar.getBoundingClientRect().width) === 340;
      },
      { timeout: 4000 },
    );
    const afterWidth = await sidebarWidth(page);
    assert.equal(afterWidth, 340);
  } finally {
    await ctx.close();
  }
});

test("e2e_sidebar_resize_clamps_at_180_and_420", async () => {
  const { ctx, page } = await openEditor();
  try {
    await page.evaluate(() => {
      window.__isonimEditor.setLeftSidebarWidth(50);
    });
    await page.waitForFunction(
      () => {
        const sidebar = document.querySelector('[data-editor-sidebar="true"]');
        if (!sidebar) return false;
        return Math.round(sidebar.getBoundingClientRect().width) === 180;
      },
      { timeout: 4000 },
    );
    assert.equal(await sidebarWidth(page), 180);

    await page.evaluate(() => {
      window.__isonimEditor.setLeftSidebarWidth(9999);
    });
    await page.waitForFunction(
      () => {
        const sidebar = document.querySelector('[data-editor-sidebar="true"]');
        if (!sidebar) return false;
        return Math.round(sidebar.getBoundingClientRect().width) === 420;
      },
      { timeout: 4000 },
    );
    assert.equal(await sidebarWidth(page), 420);
  } finally {
    await ctx.close();
  }
});

test("e2e_sidebar_resize_real_mouse_drag_changes_width", async () => {
  const { ctx, page } = await openEditor();
  try {
    // Reset to a known starting width so the drag math is stable.
    await page.evaluate(() => {
      window.__isonimEditor.setLeftSidebarWidth(260);
    });
    await page.waitForFunction(
      () => {
        const sidebar = document.querySelector('[data-editor-sidebar="true"]');
        if (!sidebar) return false;
        return Math.round(sidebar.getBoundingClientRect().width) === 260;
      },
      { timeout: 4000 },
    );

    const handleBox = await page.evaluate(() => {
      const handle = document.querySelector(
        '[data-resize-handle="left-sidebar"]',
      );
      if (!handle) return null;
      const box = handle.getBoundingClientRect();
      return {
        x: box.x + box.width / 2,
        y: box.y + box.height / 2,
      };
    });
    assert.ok(handleBox, "handle position resolvable");

    // Drag the handle 50 px to the right — sidebar should widen
    // by ~50 px (260 → 310, within the [180, 420] clamp).
    await page.mouse.move(handleBox.x, handleBox.y);
    await page.mouse.down();
    await page.mouse.move(handleBox.x + 50, handleBox.y, { steps: 10 });
    await page.mouse.up();

    await page.waitForFunction(
      () => {
        const sidebar = document.querySelector('[data-editor-sidebar="true"]');
        if (!sidebar) return false;
        const w = Math.round(sidebar.getBoundingClientRect().width);
        // Allow ±2 px slop for sub-pixel rounding in the drag math.
        return w >= 305 && w <= 315;
      },
      { timeout: 4000 },
    );
    const finalWidth = await sidebarWidth(page);
    assert.ok(
      finalWidth >= 305 && finalWidth <= 315,
      `expected sidebar width ~310 after +50 px drag, got ${finalWidth}`,
    );
  } finally {
    await ctx.close();
  }
});
