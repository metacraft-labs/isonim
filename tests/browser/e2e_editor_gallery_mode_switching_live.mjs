// CHRM-M6 Phase D.1 — Playwright e2e: gallery mode-switching contract.
//
// Locks in the toolbar mode-chip interaction matrix:
//   * Default mode after open is ``grid``
//     (``data-gallery-mode="grid"`` on the overlay root).
//   * Clicking the Full-tab chip flips ``data-gallery-mode="full-tab"``
//     and surfaces the full-tab host
//     (``[data-design-review-gallery-fulltab="true"]`` becomes visible
//     via ``data-gallery-visible="true"``).
//   * Clicking the Grid chip flips mode back to grid and the grid host
//     becomes visible again.
//   * Clicking the Compare chip with fewer than 2 multi-selected tiles
//     does NOT flip mode (the VM's compareSideBySide guards on
//     ``compareCaptureIds.val.len >= 2`` — see gallery_overlay.nim
//     L237). The chip's ``aria-disabled`` mirrors the same gate.
//
// Convention: ``node --test`` (matches other ``tests/browser/e2e_*.mjs``
// files). Uses the shared ``design_review_harness.mjs`` to boot a real
// daemon + Postgres + editor server.

import test from "node:test";
import assert from "node:assert/strict";
import { bootFullHarness } from "./lib/design_review_harness.mjs";

const PAGE_PORT = 18497;
const EDITOR_BUILD = "/Users/zahary/metacraft/isonim-examples/build/editor";

let harness = null;
let chromium = null;
let browser = null;

async function ensureBrowser() {
  if (!chromium) {
    const m = await import("playwright");
    chromium = m.chromium;
  }
  if (!browser) browser = await chromium.launch({ headless: true });
  return browser;
}

test.before(async () => {
  harness = await bootFullHarness({
    editorPort: PAGE_PORT,
    editorBuild: EDITOR_BUILD,
  });
  // Seed 6 captures sharing a single preview so the grid renders a
  // single row with 6 tiles (compact and predictable for the test).
  // ``storyId`` matches the canonical preview-id the editor will use
  // when the Task App / Pages / Inbox @ web story is selected so the
  // gallery's filter-by-current-preview keeps these captures visible.
  const previewId = "Task App %2F Pages/Inbox:page#0@web";
  const captures = [];
  for (let i = 0; i < 6; i++) {
    captures.push({
      storyId: previewId,
      platform: "web",
      deviceClass: i % 2 === 0 ? "desktop" : "mobile",
      width: 320,
      height: 240,
      runArgs: { snapshotHash: "h-mode-" + i, recordedBy: "tester" },
    });
  }
  await harness.seedCaptures("render.task-app", captures);
});

test.after(async () => {
  try {
    if (browser) await browser.close();
  } catch {}
  if (harness) harness.teardownAll();
});

// Mirrors the helper from
// ``e2e_editor_gallery_renders_real_captures_live.mjs`` — select the
// "Task App / Pages / Inbox" story so the brief id resolves to
// ``render.task-app``.
async function selectInboxStory(page) {
  await page.evaluate(() => {
    const sectionBtns = Array.from(
      document.querySelectorAll("button, [role='button']"),
    );
    for (const b of sectionBtns) {
      if (b.textContent?.trim() === "Pages") {
        b.click();
        break;
      }
    }
  });
  await page.waitForTimeout(150);
  await page.evaluate(() => {
    const groupBtns = Array.from(
      document.querySelectorAll("button, [role='button']"),
    );
    for (const b of groupBtns) {
      if (b.textContent?.trim() === "Task App / Pages") {
        b.click();
        break;
      }
    }
  });
  await page.waitForTimeout(150);
  await page.evaluate(() => {
    const all = Array.from(document.querySelectorAll("*"));
    for (const el of all) {
      if (el.textContent?.trim() === "Inbox" && el.children.length === 0) {
        el.click();
        return;
      }
    }
  });
  await page.waitForTimeout(1000);
}

async function openGalleryWithCaptures(page) {
  await page.goto(harness.editorUrl, { waitUntil: "domcontentloaded" });
  await page.waitForTimeout(500);
  await selectInboxStory(page);
  // Wait for the briefHasHistory cascade to populate the button.
  await page.waitForFunction(
    () => {
      const btn = document.querySelector(
        '[data-design-review-history-button="true"]',
      );
      return btn && btn.getAttribute("data-history-visible") === "true";
    },
    null,
    { timeout: 15_000 },
  );
  // Open the gallery.
  await page.evaluate(() => {
    const btn = document.querySelector(
      '[data-design-review-history-button="true"]',
    );
    btn?.dispatchEvent(new MouseEvent("click", { bubbles: true }));
  });
  await page.waitForFunction(
    () =>
      document.querySelectorAll("[data-design-review-gallery-tile]").length >=
      2,
    null,
    { timeout: 15_000 },
  );
}

test("gallery default mode is grid after open", async () => {
  const b = await ensureBrowser();
  const ctx = await b.newContext({ viewport: { width: 1440, height: 900 } });
  const page = await ctx.newPage();
  try {
    await openGalleryWithCaptures(page);
    const mode = await page.evaluate(() => {
      const overlay = document.querySelector(
        '[data-design-review-gallery-overlay="true"]',
      );
      return overlay?.getAttribute("data-gallery-mode");
    });
    assert.equal(
      mode,
      "grid",
      "gallery should open in grid mode by default (data-gallery-mode='grid')",
    );
    // Grid host should be data-visible.
    const gridVisible = await page.evaluate(() => {
      const grid = document.querySelector(
        '[data-design-review-gallery-grid="true"]',
      );
      return grid?.getAttribute("data-gallery-visible");
    });
    assert.equal(
      gridVisible,
      "true",
      "grid host should be data-gallery-visible='true' on default open",
    );
  } finally {
    await ctx.close();
  }
});

test("clicking the Full-tab chip flips mode to full-tab and surfaces the host", async () => {
  const b = await ensureBrowser();
  const ctx = await b.newContext({ viewport: { width: 1440, height: 900 } });
  const page = await ctx.newPage();
  try {
    await openGalleryWithCaptures(page);
    // Click the Full-tab chip.
    await page.evaluate(() => {
      const chip = document.querySelector(
        '[data-design-review-gallery-mode="full-tab"]',
      );
      chip?.dispatchEvent(new MouseEvent("click", { bubbles: true }));
    });
    await page.waitForFunction(
      () => {
        const overlay = document.querySelector(
          '[data-design-review-gallery-overlay="true"]',
        );
        return overlay?.getAttribute("data-gallery-mode") === "full-tab";
      },
      null,
      { timeout: 5000 },
    );
    const mode = await page.evaluate(() =>
      document
        .querySelector('[data-design-review-gallery-overlay="true"]')
        ?.getAttribute("data-gallery-mode"),
    );
    assert.equal(mode, "full-tab");
    // The full-tab host should be data-visible AND its computed
    // display should not be 'none' (the inline ``style.display`` is
    // driven by the same mode-mirror effect).
    const fullTabState = await page.evaluate(() => {
      const host = document.querySelector(
        '[data-design-review-gallery-fulltab="true"]',
      );
      if (!host) return null;
      return {
        visible: host.getAttribute("data-gallery-visible"),
        display: window.getComputedStyle(host).display,
      };
    });
    assert.ok(fullTabState, "full-tab host must be in the DOM");
    assert.equal(
      fullTabState.visible,
      "true",
      "full-tab host should be data-gallery-visible='true' after switch",
    );
    assert.notEqual(
      fullTabState.display,
      "none",
      "full-tab host's computed display must not be 'none' after switch",
    );
  } finally {
    await ctx.close();
  }
});

test("clicking the Grid chip flips mode back to grid", async () => {
  const b = await ensureBrowser();
  const ctx = await b.newContext({ viewport: { width: 1440, height: 900 } });
  const page = await ctx.newPage();
  try {
    await openGalleryWithCaptures(page);
    // Switch to Full-tab first.
    await page.evaluate(() => {
      const chip = document.querySelector(
        '[data-design-review-gallery-mode="full-tab"]',
      );
      chip?.dispatchEvent(new MouseEvent("click", { bubbles: true }));
    });
    await page.waitForFunction(
      () =>
        document
          .querySelector('[data-design-review-gallery-overlay="true"]')
          ?.getAttribute("data-gallery-mode") === "full-tab",
      null,
      { timeout: 5000 },
    );
    // Then click Grid to flip back.
    await page.evaluate(() => {
      const chip = document.querySelector(
        '[data-design-review-gallery-mode="grid"]',
      );
      chip?.dispatchEvent(new MouseEvent("click", { bubbles: true }));
    });
    await page.waitForFunction(
      () =>
        document
          .querySelector('[data-design-review-gallery-overlay="true"]')
          ?.getAttribute("data-gallery-mode") === "grid",
      null,
      { timeout: 5000 },
    );
    const gridVisible = await page.evaluate(() =>
      document
        .querySelector('[data-design-review-gallery-grid="true"]')
        ?.getAttribute("data-gallery-visible"),
    );
    assert.equal(
      gridVisible,
      "true",
      "grid host should be data-gallery-visible='true' after flipping back",
    );
  } finally {
    await ctx.close();
  }
});

test("Compare chip with <2 tiles selected does not flip mode (aria-disabled='true')", async () => {
  const b = await ensureBrowser();
  const ctx = await b.newContext({ viewport: { width: 1440, height: 900 } });
  const page = await ctx.newPage();
  try {
    await openGalleryWithCaptures(page);
    // No tiles cmd-clicked: the VM's compareCaptureIds.val.len is 0.
    // Wave A wires the chip's ``aria-disabled`` reactively: with
    // count < 2 it sets ``aria-disabled='true'`` and
    // ``data-design-review-gallery-compare-enabled='false'`` (see
    // gallery_overlay.nim L1187-L1215). The click handler is still
    // wired but the underlying VM helper ``compareSideBySide`` early-
    // returns when ``len < 2`` (gallery_overlay.nim L237-L242). The
    // result: the mode does NOT flip.
    const compareAttrs = await page.evaluate(() => {
      const chip = document.querySelector(
        '[data-design-review-gallery-mode="compare"]',
      );
      return {
        ariaDisabled: chip?.getAttribute("aria-disabled"),
        enabled: chip?.getAttribute(
          "data-design-review-gallery-compare-enabled",
        ),
      };
    });
    assert.equal(
      compareAttrs.ariaDisabled,
      "true",
      "Compare chip must be aria-disabled='true' when <2 tiles selected",
    );
    assert.equal(
      compareAttrs.enabled,
      "false",
      "data-design-review-gallery-compare-enabled must mirror disabled",
    );
    // Click the chip anyway and verify the mode stays grid (VM guard
    // fires defensively per gallery_overlay.nim L237 comment).
    await page.evaluate(() => {
      const chip = document.querySelector(
        '[data-design-review-gallery-mode="compare"]',
      );
      chip?.dispatchEvent(new MouseEvent("click", { bubbles: true }));
    });
    await page.waitForTimeout(300);
    const modeAfter = await page.evaluate(() =>
      document
        .querySelector('[data-design-review-gallery-overlay="true"]')
        ?.getAttribute("data-gallery-mode"),
    );
    assert.equal(
      modeAfter,
      "grid",
      "mode must NOT flip to compare when <2 tiles are selected",
    );
  } finally {
    await ctx.close();
  }
});
