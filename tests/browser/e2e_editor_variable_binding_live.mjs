// Phase E.2 + E.3 + E.4 — live e2e for the variable binding flow.
//
// VBIND-M7 NOTE: this drives the STANDALONE widget fixture
// (`variable_binding_fixture/harness.nim`) — a single chip + picker on a bare
// page, NOT the section-based inspector shell. It is retained as a FAST widget
// SMOKE TEST. The M7 ACCEPTANCE GATE for the full loop through the REAL
// inspector shell + real workspace (select → chip → unlink → local override →
// compatible-only picker with previously-linked at the top → re-link → save +
// load round-trip through the sidecar, DTCG source untouched) is the headless
// real-shell e2e `tests/test_editor_variable_binding_e2e.nim` (isonim's
// headless-first philosophy). See that file for the shell-level acceptance.
//
// Boots Chromium against a Nim-compiled harness that mounts:
//
//   * A ``variable_chip`` bound to ``color/surface``.
//   * The ``variable_picker`` popover (single instance, reused).
//   * The ``variable_inline_editor`` popover (single instance).
//   * A live-preview swatch whose background colour mirrors the
//     resolved value of the chip's binding — used to verify that
//     editing a variable's value propagates instantly through
//     ``vm.foundations.tokens`` + ``resolveVariableValue``.
//
// The harness is a tiny page produced by ``nim js`` from
// ``tests/browser/variable_binding_fixture/harness.nim``. The
// pattern (build → static-serve → Chromium) mirrors
// ``e2e_editor_choice_group_widget.mjs``.
//
// Pinned scenarios:
//
//   1. Initial chip mount: shows ``color/surface``, the live preview
//      swatch resolves to ``#0F172A``.
//   2. Clicking the chevron opens the picker
//      (``data-variable-picker-open="true"``); the picker lists the
//      seeded variables grouped by category.
//   3. Typing in the picker's search input filters the visible rows
//      to those whose key matches the substring.
//   4. Clicking a different variable row swaps the chip's binding;
//      the picker closes; the live preview swatch flips to the new
//      resolved value.
//   5. Clicking the chip's name opens the inline editor anchored to
//      the chip; the editor's value input is pre-populated with the
//      current resolved value.
//   6. Saving a new value in the inline editor flips the live
//      preview swatch to the new value (propagation contract).
//   7. The chip's detach affordance hides by default and surfaces on
//      hover.

import { execSync, spawn } from "node:child_process";
import { writeFileSync, existsSync } from "node:fs";
import { dirname, join } from "node:path";
import { fileURLToPath } from "node:url";
import test from "node:test";
import assert from "node:assert/strict";

const __dirname = dirname(fileURLToPath(import.meta.url));
const isonimRoot = join(__dirname, "..", "..");
const fixtureDir = join(__dirname, "variable_binding_fixture");
const harnessNim = join(fixtureDir, "harness.nim");
const harnessJs = join(fixtureDir, "harness.js");
const harnessHtml = join(fixtureDir, "index.html");

const PAGE_PORT = 18548;
let pageServer = null;
let chromium = null;
let browser = null;

function exec(cmd, opts = {}) {
  return execSync(cmd, { stdio: "pipe", ...opts }).toString();
}

function writeHarnessHtml() {
  const html = `<!doctype html>
<html><head><meta charset="utf-8"><title>Phase E variable binding harness</title>
<style>
  body { margin: 0; padding: 24px; background: #0B1220;
          color: #F1F5F9; font-family: system-ui, sans-serif; }
  section { margin-bottom: 24px; }
  h2 { font-size: 12px; margin-bottom: 8px; color: #94A3B8;
    text-transform: uppercase; letter-spacing: 0.04em; }
  #chip-host { display: inline-flex; min-width: 240px; }
  #preview-swatch { display: inline-block; width: 56px; height: 56px;
                    border-radius: 6px;
                    border: 1px solid rgba(255,255,255,0.12); }
  #popover-host { position: relative; }
</style>
</head>
<body>
  <section>
    <h2>Chip</h2>
    <div id="chip-host"></div>
  </section>
  <section>
    <h2>Live preview</h2>
    <div id="preview-swatch" data-test-id="live-preview-swatch"></div>
  </section>
  <div id="popover-host"></div>
  <script src="harness.js" defer></script>
</body></html>`;
  writeFileSync(harnessHtml, html);
}

function buildHarness() {
  const cmd =
    "nim js --path:src --path:. " +
    "--path:../nim-everywhere/src " +
    "--path:../isonim-render-serve/src " +
    "--hints:off " +
    `-o:${harnessJs} ${harnessNim}`;
  exec(cmd, { cwd: isonimRoot });
  if (!existsSync(harnessJs)) {
    throw new Error("harness.js was not produced by nim js");
  }
}

function startPageServer() {
  pageServer = spawn(
    "python3",
    ["-m", "http.server", String(PAGE_PORT), "--bind", "127.0.0.1"],
    { cwd: fixtureDir, stdio: "ignore", detached: true },
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

async function openHarness() {
  const b = await ensureBrowser();
  const ctx = await b.newContext();
  const page = await ctx.newPage();
  page.on("pageerror", (err) => console.log("PAGE ERROR:", err.message));
  page.on("console", (msg) => {
    if (msg.type() === "error" || msg.type() === "warning") {
      console.log("PAGE", msg.type().toUpperCase(), msg.text());
    }
  });
  await page.goto(`http://127.0.0.1:${PAGE_PORT}/index.html`);
  // Wait for the chip to settle to the initial binding. The harness
  // mounts twice (once explicitly, once via a render-effect) so the
  // first chip element is detached before this returns.
  await page.waitForSelector('[data-variable-chip-key="color/surface"]', {
    state: "attached",
    timeout: 5000,
  });
  await page.waitForSelector('[data-variable-picker="true"]', {
    state: "attached",
    timeout: 5000,
  });
  await page.waitForSelector('[data-variable-inline-editor="true"]', {
    state: "attached",
    timeout: 5000,
  });
  return { ctx, page };
}

test.before(async () => {
  writeHarnessHtml();
  buildHarness();
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
// Initial state
// ---------------------------------------------------------------------------

test("e2e_variable_chip_initial_mount_shows_color_surface", async () => {
  const { ctx, page } = await openHarness();
  try {
    const chip = await page.$('[data-variable-chip="true"]');
    assert.ok(chip, "variable chip mounted");
    const key = await chip.getAttribute("data-variable-chip-key");
    assert.equal(key, "color/surface", "chip initial key is color/surface");
    const state = await chip.getAttribute("data-variable-chip-state");
    assert.equal(state, "bound", "chip initial state is bound");

    const nameNode = await page.$('[data-variable-chip-name="true"]');
    const nameText = await nameNode.textContent();
    assert.equal(
      nameText.trim(),
      "color/surface",
      "chip displays the variable name",
    );

    const swatch = await page.$('[data-test-id="live-preview-swatch"]');
    const resolved = await swatch.getAttribute("data-preview-resolved");
    assert.equal(
      resolved,
      "#0F172A",
      "live preview swatch resolves to the initial value",
    );
  } finally {
    await ctx.close();
  }
});

test("e2e_variable_chip_chevron_opens_picker", async () => {
  const { ctx, page } = await openHarness();
  try {
    const chevron = await page.$('[data-variable-chip-chevron="true"]');
    assert.ok(chevron, "chip chevron exists");
    await chevron.click();
    const picker = await page.$('[data-variable-picker="true"]');
    const open = await picker.getAttribute("data-variable-picker-open");
    assert.equal(open, "true", "picker open flag flips after chevron click");

    const rows = await page.$$("[data-variable-picker-row]");
    assert.ok(rows.length >= 3, "picker lists the seeded variables");
  } finally {
    await ctx.close();
  }
});

test("e2e_variable_picker_search_filters_rows", async () => {
  const { ctx, page } = await openHarness();
  try {
    await page.click('[data-variable-chip-chevron="true"]');
    await page.waitForSelector('[data-variable-picker-open="true"]', {
      state: "attached",
      timeout: 5000,
    });
    const search = await page.$('[data-variable-picker-search="true"]');
    await search.fill("spacing");

    // Wait for the reactive effect to re-render the body.
    await page.waitForFunction(
      () =>
        document.querySelectorAll("[data-variable-picker-row]").length === 1,
      null,
      { timeout: 2000 },
    );
    const rows = await page.$$("[data-variable-picker-row]");
    assert.equal(rows.length, 1, "search filters to a single row");
    const key = await rows[0].getAttribute("data-variable-picker-row");
    assert.equal(key, "spacing/4", "remaining row is the spacing token");
  } finally {
    await ctx.close();
  }
});

test("e2e_variable_picker_pick_swaps_chip_binding", async () => {
  const { ctx, page } = await openHarness();
  try {
    await page.click('[data-variable-chip-chevron="true"]');
    await page.waitForSelector('[data-variable-picker-open="true"]', {
      state: "attached",
      timeout: 5000,
    });
    const accentRow = await page.$('[data-variable-picker-row="color/accent"]');
    assert.ok(accentRow, "color/accent row exists in the picker");
    await accentRow.click();

    // The picker closes and the chip re-mounts with the new binding.
    await page.waitForSelector('[data-variable-picker-open="false"]', {
      state: "attached",
      timeout: 5000,
    });
    await page.waitForFunction(
      () => {
        const chip = document.querySelector('[data-variable-chip="true"]');
        if (!chip) return false;
        return chip.getAttribute("data-variable-chip-key") === "color/accent";
      },
      null,
      { timeout: 5000 },
    );

    const swatch = await page.$('[data-test-id="live-preview-swatch"]');
    await page.waitForFunction(
      () => {
        const el = document.querySelector(
          '[data-test-id="live-preview-swatch"]',
        );
        return el && el.getAttribute("data-preview-resolved") === "#7C7AED";
      },
      null,
      { timeout: 5000 },
    );
    const resolved = await swatch.getAttribute("data-preview-resolved");
    assert.equal(
      resolved,
      "#7C7AED",
      "live preview swatch follows the new binding",
    );
  } finally {
    await ctx.close();
  }
});

test("e2e_variable_chip_name_click_opens_inline_editor", async () => {
  const { ctx, page } = await openHarness();
  try {
    const nameNode = await page.$('[data-variable-chip-name="true"]');
    await nameNode.click();
    await page.waitForSelector('[data-variable-inline-editor-open="true"]', {
      state: "attached",
      timeout: 5000,
    });
    const editor = await page.$('[data-variable-inline-editor="true"]');
    const open = await editor.getAttribute("data-variable-inline-editor-open");
    assert.equal(open, "true", "inline editor opens on name click");

    const valueInput = await page.$(
      '[data-variable-inline-editor-value="true"]',
    );
    const value = await valueInput.inputValue();
    assert.equal(
      value,
      "#0F172A",
      "inline editor pre-populates the current value",
    );
  } finally {
    await ctx.close();
  }
});

test("e2e_variable_inline_editor_save_propagates_to_preview", async () => {
  const { ctx, page } = await openHarness();
  try {
    await page.click('[data-variable-chip-name="true"]');
    await page.waitForSelector('[data-variable-inline-editor-open="true"]', {
      state: "attached",
      timeout: 5000,
    });
    const valueInput = await page.$(
      '[data-variable-inline-editor-value="true"]',
    );
    await valueInput.fill("#10182B");
    const save = await page.$('[data-variable-inline-editor-save="true"]');
    await save.click();
    await page.waitForSelector('[data-variable-inline-editor-open="false"]', {
      state: "attached",
      timeout: 5000,
    });
    await page.waitForFunction(
      () => {
        const el = document.querySelector(
          '[data-test-id="live-preview-swatch"]',
        );
        return el && el.getAttribute("data-preview-resolved") === "#10182B";
      },
      null,
      { timeout: 5000 },
    );
    const swatch = await page.$('[data-test-id="live-preview-swatch"]');
    const resolved = await swatch.getAttribute("data-preview-resolved");
    assert.equal(
      resolved,
      "#10182B",
      "saving a new value propagates to the live preview swatch",
    );
  } finally {
    await ctx.close();
  }
});

test("e2e_variable_chip_detach_hidden_by_default_visible_on_hover", async () => {
  const { ctx, page } = await openHarness();
  try {
    const chip = await page.$('[data-variable-chip="true"]');
    const initialHover = await chip.getAttribute("data-variable-chip-hover");
    assert.equal(initialHover, "false", "chip starts in the un-hovered state");

    const detach = await page.$('[data-variable-chip-detach="true"]');
    const initialDisplay = await detach.evaluate(
      (el) => window.getComputedStyle(el).display,
    );
    assert.equal(
      initialDisplay,
      "none",
      "detach affordance is hidden by default",
    );

    await chip.dispatchEvent("mouseenter");
    await page.waitForFunction(
      () => {
        const el = document.querySelector('[data-variable-chip="true"]');
        return el && el.getAttribute("data-variable-chip-hover") === "true";
      },
      null,
      { timeout: 2000 },
    );
    const hoveredDisplay = await detach.evaluate(
      (el) => window.getComputedStyle(el).display,
    );
    assert.notEqual(
      hoveredDisplay,
      "none",
      "detach affordance surfaces while the chip is hovered",
    );
  } finally {
    await ctx.close();
  }
});
