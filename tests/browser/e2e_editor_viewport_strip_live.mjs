// Phase Q (2026-05-29) — Playwright-driven e2e for the chrome bar's
// viewport selector. The legacy single chevron+popup widget was
// replaced by a segmented strip of the most-common viewports plus a
// trailing chevron button that opens a dropdown listing the
// less-common viewports.
//
// Behaviour pinned here:
//
//   1. The viewport cluster mounts a segmented strip
//      (``data-choice-group="segmented"``) inside
//      ``data-toolbar-cluster="viewport"``, with one pill per
//      ``pinnedViewports(backend)`` entry (Web defaults to 4 pills:
//      Desktop / Laptop / Tablet / Phone).
//   2. The strip ends with a chevron overflow button
//      (``data-preview-viewport-overflow``). Clicking it flips
//      ``aria-expanded`` to ``"true"`` and unhides the dropdown
//      listbox.
//   3. The dropdown lists at least one option (the popup-only
//      viewports include Wide / Ultrawide / Phone Sm / Phone Xl /
//      Custom on Web).
//   4. Clicking an option in the dropdown closes the dropdown and
//      activates the selection on the segmented strip's container
//      (since the active viewport is no longer one of the pinned
//      pills, the active state moves to no pill — but the dropdown
//      shuts and aria-expanded flips back to ``"false"``).
//
// Convention: ``node --test`` (not ``npx playwright test``) — matches
// the rest of ``isonim/tests/browser/e2e_*.mjs``.

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

const PAGE_PORT = 18651;
let pageServer = null;
let chromium = null;
let browser = null;

function exec(cmd, opts = {}) {
  return execSync(cmd, { stdio: "pipe", ...opts }).toString();
}

function buildEditor() {
  exec("direnv exec . just editor-build", { cwd: isonimExamplesRoot });
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
  const ctx = await b.newContext({
    viewport: { width: 1440, height: 900 },
  });
  const page = await ctx.newPage();
  await page.goto(`http://127.0.0.1:${PAGE_PORT}/index.html`);
  await page.waitForSelector(
    '[data-toolbar-cluster="viewport"] [data-choice-group="segmented"]',
    { timeout: 10000 },
  );
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

test("viewport cluster mounts a segmented strip with pinned pills", async () => {
  const { ctx, page } = await openEditor();
  try {
    const pillCount = await page.evaluate(() => {
      const cluster = document.querySelector(
        '[data-toolbar-cluster="viewport"]',
      );
      if (!cluster) return -1;
      return cluster.querySelectorAll("[data-choice-group-pill]").length;
    });
    // Web backend pins desktop / laptop / tablet / phone — 4 pills
    // is the canonical count. The test allows >=3 so a future spec
    // tweak that drops one pin doesn't break the contract — the
    // user direction calls for "3-4 common options" in the strip.
    assert.ok(
      pillCount >= 3,
      `viewport strip exposes >=3 segmented pills (got ${pillCount})`,
    );
  } finally {
    await ctx.close();
  }
});

test("viewport strip ends with a chevron overflow button", async () => {
  const { ctx, page } = await openEditor();
  try {
    const chevron = await page.$(
      '[data-toolbar-cluster="viewport"] ' +
        '[data-preview-viewport-overflow="true"]',
    );
    assert.ok(chevron, "viewport cluster carries the chevron overflow button");
    const haspopup = await chevron.getAttribute("aria-haspopup");
    assert.equal(haspopup, "listbox");
    const expandedBefore = await chevron.getAttribute("aria-expanded");
    assert.equal(
      expandedBefore,
      "false",
      "chevron starts with aria-expanded=false",
    );
  } finally {
    await ctx.close();
  }
});

test("clicking the chevron opens a dropdown listing more viewports", async () => {
  const { ctx, page } = await openEditor();
  try {
    const chevron = await page.$(
      '[data-toolbar-cluster="viewport"] ' +
        '[data-preview-viewport-overflow="true"]',
    );
    await chevron.click();
    await page.waitForFunction(
      () => {
        const c = document.querySelector(
          '[data-toolbar-cluster="viewport"] ' +
            '[data-preview-viewport-overflow="true"]',
        );
        return c && c.getAttribute("aria-expanded") === "true";
      },
      { timeout: 3000 },
    );
    const dropdownVisible = await page.evaluate(() => {
      const d = document.querySelector(
        '[data-toolbar-cluster="viewport"] ' +
          '[data-preview-viewport-dropdown="true"]',
      );
      if (!d) return false;
      return window.getComputedStyle(d).display !== "none";
    });
    assert.ok(
      dropdownVisible,
      "dropdown becomes visible after clicking chevron",
    );
    const optionCount = await page.evaluate(() => {
      const d = document.querySelector(
        '[data-toolbar-cluster="viewport"] ' +
          '[data-preview-viewport-dropdown="true"]',
      );
      if (!d) return 0;
      return d.querySelectorAll("[data-preview-viewport-dropdown-option]")
        .length;
    });
    assert.ok(
      optionCount >= 1,
      `dropdown lists at least one option (got ${optionCount})`,
    );
  } finally {
    await ctx.close();
  }
});

test("clicking a dropdown option closes the dropdown", async () => {
  const { ctx, page } = await openEditor();
  try {
    const chevron = await page.$(
      '[data-toolbar-cluster="viewport"] ' +
        '[data-preview-viewport-overflow="true"]',
    );
    await chevron.click();
    await page.waitForFunction(
      () => {
        const c = document.querySelector(
          '[data-toolbar-cluster="viewport"] ' +
            '[data-preview-viewport-overflow="true"]',
        );
        return c && c.getAttribute("aria-expanded") === "true";
      },
      { timeout: 3000 },
    );
    // Click the FIRST option in the dropdown.
    const optionSlug = await page.evaluate(() => {
      const opt = document.querySelector(
        '[data-toolbar-cluster="viewport"] ' +
          '[data-preview-viewport-dropdown="true"] ' +
          "[data-preview-viewport-dropdown-option]",
      );
      if (!opt) return null;
      const slug = opt.getAttribute("data-preview-viewport-dropdown-option");
      opt.click();
      return slug;
    });
    assert.ok(optionSlug, "found a clickable option in the dropdown");
    // Dropdown must close — aria-expanded flips back to "false" AND
    // the dropdown's computed display returns to "none".
    await page.waitForFunction(
      () => {
        const c = document.querySelector(
          '[data-toolbar-cluster="viewport"] ' +
            '[data-preview-viewport-overflow="true"]',
        );
        const d = document.querySelector(
          '[data-toolbar-cluster="viewport"] ' +
            '[data-preview-viewport-dropdown="true"]',
        );
        if (!c || !d) return false;
        return (
          c.getAttribute("aria-expanded") === "false" &&
          window.getComputedStyle(d).display === "none"
        );
      },
      { timeout: 3000 },
    );
  } finally {
    await ctx.close();
  }
});

test("clicking a pinned pill in the strip activates it", async () => {
  const { ctx, page } = await openEditor();
  try {
    // Click the SECOND pill (index 1) — on the Web backend the
    // initial active pill is Desktop (index 0); pill index 1 is
    // Laptop, which is not currently active.
    const before = await page.evaluate(() => {
      const cluster = document.querySelector(
        '[data-toolbar-cluster="viewport"]',
      );
      const pill = cluster.querySelector('[data-choice-group-pill="1"]');
      if (!pill) return null;
      return {
        pressed: pill.getAttribute("aria-pressed"),
        label: pill.getAttribute("data-choice-group-label"),
      };
    });
    assert.ok(before, "pill at index 1 exists");
    assert.equal(
      before.pressed,
      "false",
      "pill at index 1 starts inactive (Desktop is the initial pin)",
    );

    await page.evaluate(() => {
      const cluster = document.querySelector(
        '[data-toolbar-cluster="viewport"]',
      );
      const pill = cluster.querySelector('[data-choice-group-pill="1"]');
      pill.click();
    });

    await page.waitForFunction(
      () => {
        const cluster = document.querySelector(
          '[data-toolbar-cluster="viewport"]',
        );
        const pill = cluster.querySelector('[data-choice-group-pill="1"]');
        return pill && pill.getAttribute("aria-pressed") === "true";
      },
      { timeout: 3000 },
    );
  } finally {
    await ctx.close();
  }
});
