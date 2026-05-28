// Phase G (2026-05-28) — Playwright-driven browser e2e for the section
// body content the Phase G section_<name>.nim widgets paint into the
// Phase B section frames. Backstops the per-section catalogue rows from
// `~/metacraft/codetracer-specs/Front-Ends/IsoNim/isonim-editor.md`
// §"Section catalogue":
//
//   1. Position section exposes X / Y / Rotation property rows.
//   2. Layout section exposes W / H + Overflow rows + the mode strip.
//   3. Appearance section exposes Opacity / Corner radius / Blend mode
//      / Per-corner rows.
//   4. Fill section exposes the fill list scaffold + the "+ Add fill"
//      button (the list is empty until a fill is added or the
//      selection's background-color seeds one).
//   5. Source section exposes the file:line label, the scope label,
//      the staged-commit counter, and the ownership warning host.
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

const PAGE_PORT = 18547;
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
  await page.waitForSelector('[data-test-id="property-panel"]', {
    timeout: 10000,
  });
  await page.waitForSelector('[data-inspector-section-body="position"]', {
    timeout: 10000,
  });
  return page;
}

async function rowExists(page, sectionSlug, propertySlug) {
  return await page.evaluate(
    ({ sectionSlug, propertySlug }) => {
      const body = document.querySelector(
        `[data-inspector-section-body="${sectionSlug}"]`,
      );
      if (!body) return false;
      return Boolean(
        body.querySelector(`[data-property-row="${propertySlug}"]`),
      );
    },
    { sectionSlug, propertySlug },
  );
}

async function selectorExistsInSection(page, sectionSlug, selector) {
  return await page.evaluate(
    ({ sectionSlug, selector }) => {
      const body = document.querySelector(
        `[data-inspector-section-body="${sectionSlug}"]`,
      );
      if (!body) return false;
      return Boolean(body.querySelector(selector));
    },
    { sectionSlug, selector },
  );
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

test("e2e_inspector_sections_position_shows_x_y_rotation", async () => {
  const b = await ensureBrowser();
  const ctx = await b.newContext();
  try {
    const page = await openEditor(ctx);
    assert.ok(
      await rowExists(page, "position", "x"),
      "Position section should render the X property row",
    );
    assert.ok(
      await rowExists(page, "position", "y"),
      "Position section should render the Y property row",
    );
    assert.ok(
      await rowExists(page, "position", "rotation"),
      "Position section should render the Rotation property row",
    );
    assert.ok(
      await selectorExistsInSection(
        page,
        "position",
        '[data-position-alignment-row="true"]',
      ),
      "Position section should render the alignment strip",
    );
    assert.ok(
      await selectorExistsInSection(
        page,
        "position",
        '[data-position-flip-row="true"]',
      ),
      "Position section should render the flip strip",
    );
  } finally {
    await ctx.close();
  }
});

test("e2e_inspector_sections_layout_shows_w_h_overflow_mode", async () => {
  const b = await ensureBrowser();
  const ctx = await b.newContext();
  try {
    const page = await openEditor(ctx);
    assert.ok(
      await rowExists(page, "layout", "w"),
      "Layout section should render the W property row",
    );
    assert.ok(
      await rowExists(page, "layout", "h"),
      "Layout section should render the H property row",
    );
    assert.ok(
      await rowExists(page, "layout", "overflow"),
      "Layout section should render the Overflow property row",
    );
    assert.ok(
      await selectorExistsInSection(
        page,
        "layout",
        '[data-layout-mode-row="true"]',
      ),
      "Layout section should render the mode strip",
    );
  } finally {
    await ctx.close();
  }
});

test("e2e_inspector_sections_appearance_shows_opacity", async () => {
  const b = await ensureBrowser();
  const ctx = await b.newContext();
  try {
    const page = await openEditor(ctx);
    assert.ok(
      await rowExists(page, "appearance", "opacity"),
      "Appearance section should render the Opacity row",
    );
    assert.ok(
      await rowExists(page, "appearance", "corner-radius"),
      "Appearance section should render the Corner radius row",
    );
    assert.ok(
      await rowExists(page, "appearance", "blend-mode"),
      "Appearance section should render the Blend mode row",
    );
  } finally {
    await ctx.close();
  }
});

test("e2e_inspector_sections_fill_shows_list_and_add_button", async () => {
  const b = await ensureBrowser();
  const ctx = await b.newContext();
  try {
    const page = await openEditor(ctx);
    assert.ok(
      await selectorExistsInSection(page, "fill", '[data-fill-list="true"]'),
      "Fill section should render the fill list host",
    );
    assert.ok(
      await selectorExistsInSection(page, "fill", '[data-fill-add="true"]'),
      "Fill section should render the + Add fill button",
    );
  } finally {
    await ctx.close();
  }
});

test("e2e_inspector_sections_source_shows_file_scope_staged", async () => {
  const b = await ensureBrowser();
  const ctx = await b.newContext();
  try {
    const page = await openEditor(ctx);
    // Expand the Source section (collapsed by default).
    await page.evaluate(() => {
      const header = document.querySelector(
        '[data-inspector-section-header="source"]',
      );
      if (header) header.click();
    });
    await page.waitForFunction(
      () => {
        const body = document.querySelector(
          '[data-inspector-section-body="source"]',
        );
        return body && getComputedStyle(body).display !== "none";
      },
      { timeout: 2000 },
    );
    assert.ok(
      await selectorExistsInSection(
        page,
        "source",
        '[data-source-file-line="true"]',
      ),
      "Source section should render the file:line label",
    );
    assert.ok(
      await selectorExistsInSection(
        page,
        "source",
        '[data-source-scope="true"]',
      ),
      "Source section should render the scope label",
    );
    assert.ok(
      await selectorExistsInSection(
        page,
        "source",
        '[data-source-staged-count="true"]',
      ),
      "Source section should render the staged-commit counter",
    );
    assert.ok(
      await selectorExistsInSection(
        page,
        "source",
        '[data-source-ownership="true"]',
      ),
      "Source section should render the ownership-warning host",
    );
  } finally {
    await ctx.close();
  }
});
