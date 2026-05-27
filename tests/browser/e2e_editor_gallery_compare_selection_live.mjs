// CHRM-M6 Phase D.2 — Playwright e2e: gallery compare-mode selection
// contract.
//
// Verifies the cmd-click multi-select + Compare chip + Clear-selection
// interaction matrix:
//
//   1. Cmd-click two tiles. The overlay root's
//      ``data-design-review-gallery-compare-ids`` attribute mirrors the
//      two selected capture ids as a comma-joined string (see
//      gallery_overlay.nim L1216-L1225).
//   2. With 2 tiles selected the Compare chip is enabled
//      (``aria-disabled='false'``); clicking it flips
//      ``data-gallery-mode`` to ``compare`` AND the compare host
//      (``[data-design-review-gallery-compare="true"]``) becomes
//      visible with two ``[data-design-review-gallery-compare-img]``
//      columns rendered.
//   3. The Clear-selection chip
//      (``[data-design-review-gallery-compare-clear="true"]``) inside
//      the compare-mode body clears the multi-selection — the
//      compare-ids attribute returns to empty AND mode flips back to
//      grid (via ``clearCompare`` — gallery_overlay.nim L244-L248).
//
// Cmd-click is dispatched via a synthetic ``MouseEvent`` with
// ``metaKey: true``; the gallery overlay's capture-phase JS shim
// (gallery_overlay.nim L709-L729) re-dispatches it as a ``meta-click``
// CustomEvent which the Nim handler binds to ``multiSelect``.

import test from "node:test";
import assert from "node:assert/strict";
import { bootFullHarness } from "./lib/design_review_harness.mjs";

const PAGE_PORT = 18498;
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
      runArgs: { snapshotHash: "h-cmp-" + i, recordedBy: "tester" },
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

test("cmd-clicking two tiles mirrors selection onto data-design-review-gallery-compare-ids", async () => {
  const b = await ensureBrowser();
  const ctx = await b.newContext({ viewport: { width: 1440, height: 900 } });
  const page = await ctx.newPage();
  try {
    await openGalleryWithCaptures(page);
    // Cmd-click the first two tiles. The dispatched ``click`` event
    // carries ``metaKey: true``; the gallery_overlay.nim capture-phase
    // JS shim sees it, stops propagation, and dispatches a
    // ``meta-click`` CustomEvent which the Nim ``multiSelect`` handler
    // binds to.
    const expectedIds = await page.evaluate(() => {
      const tiles = Array.from(
        document.querySelectorAll("[data-design-review-gallery-tile]"),
      );
      const ids = [];
      for (let i = 0; i < 2 && i < tiles.length; i++) {
        const t = tiles[i];
        const id = t.getAttribute("data-design-review-gallery-tile");
        ids.push(id);
        t.dispatchEvent(
          new MouseEvent("click", { metaKey: true, bubbles: true }),
        );
      }
      return ids;
    });
    assert.equal(
      expectedIds.length,
      2,
      "test setup must select two tile capture ids",
    );
    // Wait for the reactive effect to mirror compareCaptureIds onto
    // the overlay root.
    await page.waitForFunction(
      () => {
        const overlay = document.querySelector(
          '[data-design-review-gallery-overlay="true"]',
        );
        const val = overlay?.getAttribute(
          "data-design-review-gallery-compare-ids",
        );
        return val && val.split(",").filter(Boolean).length === 2;
      },
      null,
      { timeout: 5000 },
    );
    const compareIds = await page.evaluate(() =>
      document
        .querySelector('[data-design-review-gallery-overlay="true"]')
        ?.getAttribute("data-design-review-gallery-compare-ids"),
    );
    assert.ok(
      compareIds && compareIds.length > 0,
      `data-design-review-gallery-compare-ids must be populated; got "${compareIds}"`,
    );
    const idList = compareIds.split(",");
    assert.equal(
      idList.length,
      2,
      `compare-ids must contain 2 entries; got ${idList.length} ("${compareIds}")`,
    );
    for (const want of expectedIds) {
      assert.ok(
        idList.includes(want),
        `compare-ids "${compareIds}" must include selected tile "${want}"`,
      );
    }
  } finally {
    await ctx.close();
  }
});

test("clicking the Compare chip with 2 selected flips mode and renders compare body", async () => {
  const b = await ensureBrowser();
  const ctx = await b.newContext({ viewport: { width: 1440, height: 900 } });
  const page = await ctx.newPage();
  try {
    await openGalleryWithCaptures(page);
    await page.evaluate(() => {
      const tiles = Array.from(
        document.querySelectorAll("[data-design-review-gallery-tile]"),
      );
      for (let i = 0; i < 2 && i < tiles.length; i++) {
        tiles[i].dispatchEvent(
          new MouseEvent("click", { metaKey: true, bubbles: true }),
        );
      }
    });
    await page.waitForFunction(
      () => {
        const chip = document.querySelector(
          '[data-design-review-gallery-mode="compare"]',
        );
        return chip?.getAttribute("aria-disabled") === "false";
      },
      null,
      { timeout: 5000 },
    );
    // Click the Compare chip.
    await page.evaluate(() => {
      const chip = document.querySelector(
        '[data-design-review-gallery-mode="compare"]',
      );
      chip?.dispatchEvent(new MouseEvent("click", { bubbles: true }));
    });
    await page.waitForFunction(
      () =>
        document
          .querySelector('[data-design-review-gallery-overlay="true"]')
          ?.getAttribute("data-gallery-mode") === "compare",
      null,
      { timeout: 5000 },
    );
    const compareHostState = await page.evaluate(() => {
      const host = document.querySelector(
        '[data-design-review-gallery-compare="true"]',
      );
      if (!host) return null;
      return {
        visible: host.getAttribute("data-gallery-visible"),
        display: window.getComputedStyle(host).display,
        imgs: host.querySelectorAll(
          '[data-design-review-gallery-compare-img="true"]',
        ).length,
      };
    });
    assert.ok(compareHostState, "compare host must be in the DOM");
    assert.equal(
      compareHostState.visible,
      "true",
      "compare host must be data-gallery-visible='true' in compare mode",
    );
    assert.notEqual(
      compareHostState.display,
      "none",
      "compare host's computed display must not be 'none' in compare mode",
    );
    assert.equal(
      compareHostState.imgs,
      2,
      `compare body must render exactly 2 images; got ${compareHostState.imgs}`,
    );
  } finally {
    await ctx.close();
  }
});

test("Clear-selection chip clears compare-ids and returns to grid mode", async () => {
  const b = await ensureBrowser();
  const ctx = await b.newContext({ viewport: { width: 1440, height: 900 } });
  const page = await ctx.newPage();
  try {
    await openGalleryWithCaptures(page);
    // Multi-select 2 tiles + enter compare mode.
    await page.evaluate(() => {
      const tiles = Array.from(
        document.querySelectorAll("[data-design-review-gallery-tile]"),
      );
      for (let i = 0; i < 2 && i < tiles.length; i++) {
        tiles[i].dispatchEvent(
          new MouseEvent("click", { metaKey: true, bubbles: true }),
        );
      }
    });
    await page.waitForFunction(
      () => {
        const chip = document.querySelector(
          '[data-design-review-gallery-mode="compare"]',
        );
        return chip?.getAttribute("aria-disabled") === "false";
      },
      null,
      { timeout: 5000 },
    );
    await page.evaluate(() => {
      const chip = document.querySelector(
        '[data-design-review-gallery-mode="compare"]',
      );
      chip?.dispatchEvent(new MouseEvent("click", { bubbles: true }));
    });
    await page.waitForFunction(
      () =>
        document
          .querySelector('[data-design-review-gallery-overlay="true"]')
          ?.getAttribute("data-gallery-mode") === "compare",
      null,
      { timeout: 5000 },
    );
    // Wait for the Clear chip to render inside the compare body.
    await page.waitForSelector(
      '[data-design-review-gallery-compare-clear="true"]',
      { timeout: 5000 },
    );
    // Click Clear-selection.
    await page.evaluate(() => {
      const clear = document.querySelector(
        '[data-design-review-gallery-compare-clear="true"]',
      );
      clear?.dispatchEvent(new MouseEvent("click", { bubbles: true }));
    });
    // ``clearCompare`` (gallery_overlay.nim L244-L248) clears the
    // selection sets AND, if we're in compare mode, flips back to
    // grid.
    await page.waitForFunction(
      () => {
        const overlay = document.querySelector(
          '[data-design-review-gallery-overlay="true"]',
        );
        return (
          overlay?.getAttribute("data-gallery-mode") === "grid" &&
          (overlay?.getAttribute("data-design-review-gallery-compare-ids") ||
            "") === ""
        );
      },
      null,
      { timeout: 5000 },
    );
    const finalState = await page.evaluate(() => {
      const overlay = document.querySelector(
        '[data-design-review-gallery-overlay="true"]',
      );
      return {
        mode: overlay?.getAttribute("data-gallery-mode"),
        ids: overlay?.getAttribute("data-design-review-gallery-compare-ids"),
      };
    });
    assert.equal(
      finalState.mode,
      "grid",
      "mode must return to grid after Clear-selection",
    );
    assert.equal(
      finalState.ids || "",
      "",
      `compare-ids must be empty after Clear-selection; got "${finalState.ids}"`,
    );
  } finally {
    await ctx.close();
  }
});
