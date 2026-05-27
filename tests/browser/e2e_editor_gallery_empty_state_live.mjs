// CHRM-M6 Phase D.4 — Playwright e2e: gallery empty-state contract.
//
// Verifies the panel that surfaces when the active brief has zero
// captures (gallery_overlay.nim L794-L822, the
// ``[data-design-review-gallery-empty="true"]`` panel inside
// ``renderGrid``):
//
//   1. The empty-state panel is rendered.
//   2. The heading reads "No captures yet"
//      (``data-design-review-gallery-empty-heading="true"``).
//   3. The subtitle contains the brief's "Run a capture sweep" copy
//      (``data-design-review-gallery-empty-subtitle="true"``).
//   4. The bottom status footer
//      (``data-design-review-gallery-status-footer="true"``) matches
//      the ``<briefId> · <n> captures`` shape with n=0 in uppercase
//      (CSS ``text-transform: uppercase`` — the raw text content
//      itself is the cased original string and the visual uppercase
//      is purely a CSS effect, so we assert the regex against the raw
//      text).
//
// This focuses the empty-state contract that was previously bundled
// inside the no-history branch of the open-gallery test; lifting it
// into its own file lets a future regression in the Wave B copy /
// status-footer wiring fail fast.
//
// Setup notes:
//
//   * We boot the full harness but DO NOT seed any captures. The
//     daemon is up and reachable, so the editor's fetch succeeds and
//     returns an empty captures list. ``vm.rows.val.len == 0`` then
//     drives ``renderGrid`` into the empty-state branch.
//   * ``briefHasHistory`` resolves to false for an empty brief, so
//     the history button's ``data-history-visible`` stays "false".
//     The button is still in the DOM and clickable per CHRM-M5 Fix
//     D (the button no longer gates ``aria-hidden`` on history
//     existence).

import test from "node:test";
import assert from "node:assert/strict";
import { bootFullHarness } from "./lib/design_review_harness.mjs";

const PAGE_PORT = 18500;
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
  // INTENTIONALLY no ``seedCaptures`` call — we want the daemon up
  // but the active brief to have zero captures so the gallery
  // renders its empty-state panel.
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

async function openEmptyGallery(page) {
  await page.goto(harness.editorUrl, { waitUntil: "domcontentloaded" });
  await page.waitForTimeout(500);
  await selectInboxStory(page);
  // The history button is in the DOM regardless of brief history per
  // CHRM-M5 Fix D — wait for it to mount.
  await page.waitForSelector('[data-design-review-history-button="true"]', {
    timeout: 10_000,
  });
  // Click the history button to open the gallery.
  await page.evaluate(() => {
    const btn = document.querySelector(
      '[data-design-review-history-button="true"]',
    );
    btn?.dispatchEvent(new MouseEvent("click", { bubbles: true }));
  });
  // Wait for the empty-state panel to render. We assert on the
  // ``data-design-review-gallery-empty`` attribute (not the host's
  // ``data-gallery-host-open``) so the test is robust against the
  // host's open/close gating: what we care about is that the
  // empty-state panel is in the DOM and visible.
  await page.waitForSelector('[data-design-review-gallery-empty="true"]', {
    timeout: 10_000,
  });
}

test("empty-state panel renders when the active brief has no captures", async () => {
  const b = await ensureBrowser();
  const ctx = await b.newContext({ viewport: { width: 1440, height: 900 } });
  const page = await ctx.newPage();
  try {
    await openEmptyGallery(page);
    const present = await page.evaluate(
      () =>
        document.querySelectorAll('[data-design-review-gallery-empty="true"]')
          .length,
    );
    assert.ok(
      present >= 1,
      `empty-state panel must be present in the gallery; got ${present}`,
    );
  } finally {
    await ctx.close();
  }
});

test("empty-state heading reads 'No captures yet'", async () => {
  const b = await ensureBrowser();
  const ctx = await b.newContext({ viewport: { width: 1440, height: 900 } });
  const page = await ctx.newPage();
  try {
    await openEmptyGallery(page);
    const heading = await page.evaluate(() => {
      const h = document.querySelector(
        '[data-design-review-gallery-empty-heading="true"]',
      );
      return h?.textContent?.trim();
    });
    assert.equal(
      heading,
      "No captures yet",
      `empty-state heading copy mismatch — expected "No captures yet", got "${heading}"`,
    );
  } finally {
    await ctx.close();
  }
});

test("empty-state subtitle contains 'Run a capture sweep'", async () => {
  const b = await ensureBrowser();
  const ctx = await b.newContext({ viewport: { width: 1440, height: 900 } });
  const page = await ctx.newPage();
  try {
    await openEmptyGallery(page);
    const subtitle = await page.evaluate(() => {
      const s = document.querySelector(
        '[data-design-review-gallery-empty-subtitle="true"]',
      );
      return s?.textContent?.trim();
    });
    assert.ok(
      subtitle && subtitle.includes("Run a capture sweep"),
      `empty-state subtitle must include "Run a capture sweep"; got "${subtitle}"`,
    );
  } finally {
    await ctx.close();
  }
});

test("status footer text matches '<briefId> · 0 captures'", async () => {
  const b = await ensureBrowser();
  const ctx = await b.newContext({ viewport: { width: 1440, height: 900 } });
  const page = await ctx.newPage();
  try {
    await openEmptyGallery(page);
    const footer = await page.evaluate(() => {
      const f = document.querySelector(
        '[data-design-review-gallery-status-footer="true"]',
      );
      return f?.textContent?.trim();
    });
    assert.ok(
      footer && footer.length > 0,
      `status footer must have content; got "${footer}"`,
    );
    // The footer's visual uppercase is driven by ``text-transform:
    // uppercase`` CSS; the raw textContent is the original cased
    // brief id followed by the middle-dot separator and the pluralized
    // captures count. Regex matches any briefId · 0 captures shape
    // with whitespace tolerance.
    const re = /^.+\s*·\s*0 captures$/;
    assert.ok(
      re.test(footer),
      `status footer must match /<briefId> · 0 captures/; got "${footer}"`,
    );
  } finally {
    await ctx.close();
  }
});
