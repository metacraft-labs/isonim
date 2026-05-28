// Phase C (2026-05-28) — Playwright-driven browser e2e for the
// collapsible-section behaviour introduced by the editor sidebar
// redesign. Backstops the contracts pinned in
// `~/metacraft/codetracer-specs/Front-Ends/IsoNim/isonim-editor.md`
// §"Section header pattern" + the "Section catalogue" table:
//
//   1. On initial render the spec-mandated default open set
//      (Position / Layout / Appearance / Fill) reads as expanded
//      (body display != "none"); the remaining eight sections —
//      including Stroke / Effects / Export — render collapsed
//      (body display == "none").
//   2. Clicking a collapsed section header (Stroke) expands it.
//      The body's display flips to non-"none", data-expanded
//      becomes "true", and the chevron glyph swaps from ▸ to ▾.
//   3. Reloading the page restores the user's expanded set from
//      localStorage — Stroke stays expanded across the reload.
//   4. Clicking Stroke again collapses it; the storage write-back
//      drops it from the persisted slug list.
//   5. After a second reload Stroke reads as collapsed again,
//      confirming the localStorage round-trip is symmetric.
//
// Runs via `node --test` (same pattern as the rest of
// `tests/browser/e2e_*.mjs`).

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

const PAGE_PORT = 18539;
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

async function openEditor(ctx) {
  const page = await ctx.newPage();
  await page.goto(`http://127.0.0.1:${PAGE_PORT}/index.html`);
  // Wait for the inspector sidebar to appear so the section frames
  // are mounted.
  await page.waitForSelector('[data-test-id="property-panel"]', {
    timeout: 10000,
  });
  await page.waitForSelector('[data-inspector-section-header="position"]', {
    timeout: 10000,
  });
  return page;
}

async function bodyDisplay(page, slug) {
  return await page.evaluate((slug) => {
    const el = document.querySelector(
      `[data-inspector-section-body="${slug}"]`,
    );
    if (!el) return null;
    return getComputedStyle(el).display;
  }, slug);
}

async function headerExpanded(page, slug) {
  return await page.evaluate((slug) => {
    const el = document.querySelector(
      `[data-inspector-section-header="${slug}"]`,
    );
    return el ? el.getAttribute("data-expanded") : null;
  }, slug);
}

async function chevronGlyph(page, slug) {
  return await page.evaluate((slug) => {
    const el = document.querySelector(
      `[data-inspector-section-chevron="${slug}"]`,
    );
    return el ? (el.textContent || "").trim() : null;
  }, slug);
}

async function clickHeader(page, slug) {
  await page.evaluate((slug) => {
    const el = document.querySelector(
      `[data-inspector-section-header="${slug}"]`,
    );
    if (!el) throw new Error(`section header ${slug} not found`);
    el.click();
  }, slug);
}

async function storagePayload(page) {
  return await page.evaluate(
    () =>
      (window.localStorage &&
        window.localStorage.getItem("isonim:inspector:expanded")) ||
      "",
  );
}

async function clearStorage(page) {
  await page.evaluate(() => {
    try {
      if (window.localStorage) {
        window.localStorage.removeItem("isonim:inspector:expanded");
      }
    } catch (e) {}
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
// Initial render: spec defaults
// ---------------------------------------------------------------------------

test("e2e_section_collapse_default_open_position_layout_appearance_fill", async () => {
  const b = await ensureBrowser();
  const ctx = await b.newContext();
  try {
    const page = await openEditor(ctx);
    // Defaults: Position / Layout / Appearance / Fill visible.
    for (const slug of ["position", "layout", "appearance", "fill"]) {
      const display = await bodyDisplay(page, slug);
      assert.notStrictEqual(
        display,
        "none",
        `default-open section ${slug} should NOT have display: none ` +
          `(got ${display})`,
      );
      const expanded = await headerExpanded(page, slug);
      assert.equal(
        expanded,
        "true",
        `default-open section ${slug} header data-expanded should be ` +
          `"true" (got ${expanded})`,
      );
    }
    // Defaults: Stroke / Effects / Export collapsed.
    for (const slug of ["stroke", "effects", "export"]) {
      const display = await bodyDisplay(page, slug);
      assert.equal(
        display,
        "none",
        `collapsed section ${slug} should have display: none ` +
          `(got ${display})`,
      );
      const expanded = await headerExpanded(page, slug);
      assert.equal(
        expanded,
        "false",
        `collapsed section ${slug} header data-expanded should be ` +
          `"false" (got ${expanded})`,
      );
    }
  } finally {
    await ctx.close();
  }
});

// ---------------------------------------------------------------------------
// Click Stroke header — body becomes visible + chevron flips
// ---------------------------------------------------------------------------

test("e2e_section_collapse_click_stroke_expands_body", async () => {
  const b = await ensureBrowser();
  const ctx = await b.newContext();
  try {
    const page = await openEditor(ctx);
    await clearStorage(page);
    // Pre-flight: Stroke collapsed.
    assert.equal(await bodyDisplay(page, "stroke"), "none");
    assert.equal(await chevronGlyph(page, "stroke"), "▸"); // ▸
    // Click — Stroke expands.
    await clickHeader(page, "stroke");
    await page.waitForFunction(
      () => {
        const el = document.querySelector(
          '[data-inspector-section-body="stroke"]',
        );
        return el && getComputedStyle(el).display !== "none";
      },
      { timeout: 2000 },
    );
    assert.notStrictEqual(await bodyDisplay(page, "stroke"), "none");
    assert.equal(await headerExpanded(page, "stroke"), "true");
    assert.equal(await chevronGlyph(page, "stroke"), "▾"); // ▾
  } finally {
    await ctx.close();
  }
});

// ---------------------------------------------------------------------------
// Reload after expanding Stroke — Stroke stays expanded
// ---------------------------------------------------------------------------

test("e2e_section_collapse_reload_restores_expanded_stroke", async () => {
  const b = await ensureBrowser();
  const ctx = await b.newContext();
  try {
    let page = await openEditor(ctx);
    await clearStorage(page);
    // Expand Stroke + wait for the storage write to land.
    await clickHeader(page, "stroke");
    await page.waitForFunction(
      () =>
        (window.localStorage &&
          (window.localStorage.getItem("isonim:inspector:expanded") || "")
            .split(",")
            .includes("stroke")) === true,
      { timeout: 2000 },
    );
    const payloadBefore = await storagePayload(page);
    assert.ok(
      payloadBefore.split(",").includes("stroke"),
      `localStorage payload should include "stroke" after expand; ` +
        `got "${payloadBefore}"`,
    );
    // Reload and re-open the editor.
    await page.reload();
    await page.waitForSelector('[data-inspector-section-header="stroke"]', {
      timeout: 10000,
    });
    // Stroke remains expanded post-reload (hydration succeeded).
    assert.notStrictEqual(
      await bodyDisplay(page, "stroke"),
      "none",
      "Stroke body should remain visible after reload (localStorage " +
        "round-trip)",
    );
    assert.equal(await headerExpanded(page, "stroke"), "true");
  } finally {
    await ctx.close();
  }
});

// ---------------------------------------------------------------------------
// Click Stroke again + reload — Stroke is collapsed
// ---------------------------------------------------------------------------

test("e2e_section_collapse_reload_restores_collapsed_stroke", async () => {
  const b = await ensureBrowser();
  const ctx = await b.newContext();
  try {
    let page = await openEditor(ctx);
    await clearStorage(page);
    // Expand → collapse → reload.
    await clickHeader(page, "stroke");
    await page.waitForFunction(
      () => {
        const el = document.querySelector(
          '[data-inspector-section-body="stroke"]',
        );
        return el && getComputedStyle(el).display !== "none";
      },
      { timeout: 2000 },
    );
    await clickHeader(page, "stroke");
    await page.waitForFunction(
      () => {
        const el = document.querySelector(
          '[data-inspector-section-body="stroke"]',
        );
        return el && getComputedStyle(el).display === "none";
      },
      { timeout: 2000 },
    );
    const payload = await storagePayload(page);
    assert.ok(
      !payload.split(",").includes("stroke"),
      `localStorage payload should NOT include "stroke" after collapse; ` +
        `got "${payload}"`,
    );
    // Reload + verify Stroke stays collapsed.
    await page.reload();
    await page.waitForSelector('[data-inspector-section-header="stroke"]', {
      timeout: 10000,
    });
    assert.equal(
      await bodyDisplay(page, "stroke"),
      "none",
      "Stroke body should be hidden after reload (collapsed state " +
        "persisted)",
    );
    assert.equal(await headerExpanded(page, "stroke"), "false");
  } finally {
    await ctx.close();
  }
});
