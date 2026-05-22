// TBAR-M2 — Playwright-driven browser e2e for the ChoiceGroup widget.
//
// Boots Chromium against a static HTML harness that loads the
// JS-compiled widget (``widgets_harness.js`` produced by
// ``nim js --path:src ... widgets_harness.nim``). The harness mounts
// both variants (segmented + chevron) into pre-existing host divs
// and exposes the last-observed ``onChange`` index on
// ``window.__lastSegmentedChange`` / ``window.__lastChevronChange``
// so this script can assert the change callback fired.
//
// This file runs via ``node --test`` — the same pattern as the
// existing ``e2e_design_review_*.mjs`` tests in
// ``isonim/tests/``. The harness JS is built on demand at the start
// of the test suite (mirroring the ``editor-build`` step the other
// e2e files rely on, but scoped to just this widget so the test
// stays fast).
//
// Assertions exercised:
//
//   segmented:
//     * N child elements with aria-pressed, exactly one "true"
//     * clicking a different pill flips aria-pressed and moves
//       the active visual treatment (data-active="true")
//     * window.__lastSegmentedChange updates to the clicked index
//
//   chevron:
//     * single trigger pill renders with active label + chevron glyph
//     * clicking the trigger opens the popup (aria-expanded="true",
//       data-popup-open="true"), popup lists alternatives in
//       declared order
//     * ArrowDown / ArrowUp move focus within the popup
//     * Escape closes the popup
//     * clicking outside the widget closes the popup
//     * selecting an option fires onChange, updates the displayed
//       label, and closes the popup

import { execSync, spawn } from "node:child_process";
import { writeFileSync, existsSync } from "node:fs";
import { dirname, join } from "node:path";
import { fileURLToPath } from "node:url";
import test from "node:test";
import assert from "node:assert/strict";

const __dirname = dirname(fileURLToPath(import.meta.url));
const isonimRoot = join(__dirname, "..", "..");
const fixtureDir = join(__dirname, "widgets_fixture");
const harnessNim = join(fixtureDir, "widgets_harness.nim");
const harnessJs = join(fixtureDir, "widgets_harness.js");
const harnessHtml = join(fixtureDir, "index.html");

const PAGE_PORT = 18510;
let pageServer = null;
let chromium = null;
let browser = null;

function exec(cmd, opts = {}) {
  return execSync(cmd, { stdio: "pipe", ...opts }).toString();
}

function writeHarnessHtml() {
  const html = `<!doctype html>
<html><head><meta charset="utf-8"><title>TBAR-M2 widgets harness</title>
<style>
  body { margin: 0; padding: 24px; background: #0B1220;
          color: #F1F5F9; font-family: system-ui, sans-serif; }
  section { margin-bottom: 32px; }
  h2 { font-size: 14px; margin-bottom: 8px; color: #94A3B8; }
  #click-sink { width: 200px; height: 60px; margin-top: 8px;
                background: #1E293B; border: 1px dashed #475569;
                display: flex; align-items: center;
                justify-content: center; color: #94A3B8; }
</style>
</head>
<body>
  <section>
    <h2>Segmented variant</h2>
    <div id="segmented-host"></div>
  </section>
  <section>
    <h2>Chevron variant</h2>
    <div id="chevron-host"></div>
  </section>
  <section>
    <h2>Outside-click sink</h2>
    <div id="click-sink">click here to close popup</div>
  </section>
  <script>
    window.__lastSegmentedChange = -1;
    window.__lastChevronChange = -1;
  </script>
  <script src="widgets_harness.js" defer></script>
</body></html>`;
  writeFileSync(harnessHtml, html);
}

function buildHarness() {
  // Always rebuild so the test reflects the current widget source.
  // The Nim → JS step is fast (under a second on a warm cache).
  const cmd =
    "nim js --path:src --path:. --path:../nim-everywhere/src --hints:off " +
    `-o:${harnessJs} ${harnessNim}`;
  exec(cmd, { cwd: isonimRoot });
  if (!existsSync(harnessJs)) {
    throw new Error("widgets_harness.js was not produced by nim js");
  }
}

function startPageServer() {
  pageServer = spawn(
    "python3",
    ["-m", "http.server", String(PAGE_PORT), "--bind", "127.0.0.1"],
    { cwd: fixtureDir, stdio: "ignore", detached: true },
  );
  // Wait for the server to bind.
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
  await page.goto(`http://127.0.0.1:${PAGE_PORT}/index.html`);
  // Wait until the harness has mounted both variants.
  await page.waitForSelector('[data-choice-group="segmented"]', {
    timeout: 5000,
  });
  await page.waitForSelector('[data-choice-group="chevron"]', {
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
// Segmented variant
// ---------------------------------------------------------------------------

test("e2e_segmented_renders_n_pills_with_initial_aria_pressed", async () => {
  const { ctx, page } = await openHarness();
  try {
    const pills = await page.$$("[data-choice-group-pill]");
    assert.equal(pills.length, 2, "segmented harness mounts 2 pills");
    let truthy = 0;
    for (const pill of pills) {
      const v = await pill.getAttribute("aria-pressed");
      if (v === "true") truthy++;
    }
    assert.equal(truthy, 1, "exactly one segmented pill has aria-pressed=true");
    const firstPressed = await pills[0].getAttribute("aria-pressed");
    assert.equal(firstPressed, "true", "initial active is index 0 (Preview)");
  } finally {
    await ctx.close();
  }
});

test("e2e_segmented_click_other_pill_updates_aria_pressed", async () => {
  const { ctx, page } = await openHarness();
  try {
    const pillSpec = await page.$('[data-choice-group-pill="1"]');
    assert.ok(pillSpec, "second pill exists");
    await pillSpec.click();
    // Aria + data-active must move.
    const specPressed = await pillSpec.getAttribute("aria-pressed");
    assert.equal(specPressed, "true", "Spec pill becomes aria-pressed");
    const specActive = await pillSpec.getAttribute("data-active");
    assert.equal(specActive, "true", "Spec pill carries data-active=true");
    const pillPreview = await page.$('[data-choice-group-pill="0"]');
    const previewPressed = await pillPreview.getAttribute("aria-pressed");
    assert.equal(previewPressed, "false", "Preview pill releases aria-pressed");
    // VM-level onChange callback fired.
    const observed = await page.evaluate(() => window.__lastSegmentedChange);
    assert.equal(observed, 1, "onChange dispatched the new index (1)");
  } finally {
    await ctx.close();
  }
});

// ---------------------------------------------------------------------------
// Chevron variant
// ---------------------------------------------------------------------------

test("e2e_chevron_renders_trigger_with_active_label_and_chevron", async () => {
  const { ctx, page } = await openHarness();
  try {
    const trigger = await page.$('[data-choice-group-trigger="true"]');
    assert.ok(trigger, "chevron trigger exists");
    const haspopup = await trigger.getAttribute("aria-haspopup");
    assert.equal(haspopup, "listbox", "trigger declares aria-haspopup=listbox");
    const expanded = await trigger.getAttribute("aria-expanded");
    assert.equal(expanded, "false", "popup starts collapsed");
    const labelEl = await page.$('[data-choice-group-trigger-label="true"]');
    const labelText = await labelEl.textContent();
    assert.equal(
      labelText.trim(),
      "768x1024",
      "trigger label reflects initialIndex=1",
    );
    // The chevron glyph (U+25BE) is rendered inside the trigger.
    const chevronEl = await page.$('[data-choice-group-chevron="true"]');
    assert.ok(chevronEl, "chevron glyph element exists");
    const chevronText = await chevronEl.textContent();
    assert.ok(
      chevronText && chevronText.length > 0,
      "chevron glyph has rendered content",
    );
  } finally {
    await ctx.close();
  }
});

test("e2e_chevron_click_opens_popup_with_options_in_declared_order", async () => {
  const { ctx, page } = await openHarness();
  try {
    const trigger = await page.$('[data-choice-group-trigger="true"]');
    await trigger.click();
    const expanded = await trigger.getAttribute("aria-expanded");
    assert.equal(expanded, "true", "popup expanded after click");
    const popup = await page.$('[data-choice-group-popup="true"]');
    const popupOpen = await popup.getAttribute("data-popup-open");
    assert.equal(popupOpen, "true", "popup data-attr flips open");
    const opts = await page.$$("[data-choice-group-option]");
    assert.equal(opts.length, 3, "popup lists all three alternatives");
    const labels = [];
    for (const opt of opts) {
      const lbl = await opt.getAttribute("data-choice-group-option-label");
      labels.push(lbl);
    }
    assert.deepEqual(
      labels,
      ["320x568", "768x1024", "1280x800"],
      "popup options preserve declared order",
    );
  } finally {
    await ctx.close();
  }
});

test("e2e_chevron_arrow_keys_move_focus_within_popup", async () => {
  const { ctx, page } = await openHarness();
  try {
    const trigger = await page.$('[data-choice-group-trigger="true"]');
    await trigger.focus();
    // ArrowDown opens the popup AND focuses the active option (idx 1).
    await page.keyboard.press("ArrowDown");
    const focusedLabel1 = await page.evaluate(
      () =>
        document.activeElement &&
        document.activeElement.getAttribute("data-choice-group-option-label"),
    );
    assert.equal(
      focusedLabel1,
      "768x1024",
      "ArrowDown from trigger focuses active option",
    );
    // ArrowDown advances to next option (320x568 → 768x1024 → 1280x800).
    await page.keyboard.press("ArrowDown");
    const focusedLabel2 = await page.evaluate(
      () =>
        document.activeElement &&
        document.activeElement.getAttribute("data-choice-group-option-label"),
    );
    assert.equal(
      focusedLabel2,
      "1280x800",
      "ArrowDown advances focus within the popup",
    );
    // ArrowUp moves focus back.
    await page.keyboard.press("ArrowUp");
    const focusedLabel3 = await page.evaluate(
      () =>
        document.activeElement &&
        document.activeElement.getAttribute("data-choice-group-option-label"),
    );
    assert.equal(
      focusedLabel3,
      "768x1024",
      "ArrowUp moves focus back one step",
    );
  } finally {
    await ctx.close();
  }
});

test("e2e_chevron_escape_closes_popup", async () => {
  const { ctx, page } = await openHarness();
  try {
    const trigger = await page.$('[data-choice-group-trigger="true"]');
    await trigger.click();
    let expanded = await trigger.getAttribute("aria-expanded");
    assert.equal(expanded, "true");
    await page.keyboard.press("Escape");
    expanded = await trigger.getAttribute("aria-expanded");
    assert.equal(expanded, "false", "Escape closes the popup");
    const popup = await page.$('[data-choice-group-popup="true"]');
    const popupOpen = await popup.getAttribute("data-popup-open");
    assert.equal(popupOpen, "false", "popup data-attr reflects closed state");
  } finally {
    await ctx.close();
  }
});

test("e2e_chevron_outside_click_closes_popup", async () => {
  const { ctx, page } = await openHarness();
  try {
    const trigger = await page.$('[data-choice-group-trigger="true"]');
    await trigger.click();
    let expanded = await trigger.getAttribute("aria-expanded");
    assert.equal(expanded, "true");
    const sink = await page.$("#click-sink");
    assert.ok(sink, "outside-click sink exists");
    await sink.click();
    expanded = await trigger.getAttribute("aria-expanded");
    assert.equal(expanded, "false", "outside click dismisses the popup");
  } finally {
    await ctx.close();
  }
});

test("e2e_chevron_selecting_option_fires_on_change_and_closes_popup", async () => {
  const { ctx, page } = await openHarness();
  try {
    const trigger = await page.$('[data-choice-group-trigger="true"]');
    await trigger.click();
    // Pick the third option ("1280x800").
    const target = await page.$('[data-choice-group-option="2"]');
    await target.click();
    // onChange fired with the new index.
    const observed = await page.evaluate(() => window.__lastChevronChange);
    assert.equal(observed, 2, "onChange dispatched the new index (2)");
    // Trigger label now reflects the picked option.
    const labelEl = await page.$('[data-choice-group-trigger-label="true"]');
    const labelText = await labelEl.textContent();
    assert.equal(
      labelText.trim(),
      "1280x800",
      "trigger label updates after selection",
    );
    // Popup closed.
    const expanded = await trigger.getAttribute("aria-expanded");
    assert.equal(expanded, "false", "popup closes after selecting an option");
  } finally {
    await ctx.close();
  }
});
