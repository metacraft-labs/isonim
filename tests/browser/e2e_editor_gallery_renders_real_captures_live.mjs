// CHRM-M6 Wave A acceptance gate — verifies the JS-side gallery
// data-binding cascade end-to-end.
//
// Before Wave A, the production editor mounted the gallery overlay
// but never rendered tile children: ``list-history`` returned the
// seeded runs, but the follow-on ``fetch-run`` chain silently bailed
// because ``HttpCallbackResult.body`` was a native JS ``String`` (not
// a Nim string-as-int-array), every ``strutils.find`` call raised a
// ``SyntaxError: Cannot convert i to a BigInt`` from the
// out-of-bounds skip-table lookup, the fetch ``.catch`` re-invoked
// the callback with ``kind=hcError``, and ``tiles.val`` stayed
// empty. The same root cause kept ``brief-has-history`` from ever
// surfacing as ``data-history-visible="true"`` on the chrome-bar
// button.
//
// This test seals BOTH cascades:
//   1. Seeds 2 captures via the harness, opens the editor, navigates
//      to a story bound to ``render.task-app``, clicks the history
//      button, and asserts at least 2
//      ``[data-design-review-gallery-tile]`` elements render with
//      non-empty thumbnails.
//   2. Asserts the history-button itself reflects the populated
//      state via ``[data-design-review-history-button]
//      [data-history-visible="true"]`` BEFORE the click.

import test from "node:test";
import assert from "node:assert/strict";
import { bootFullHarness } from "./lib/design_review_harness.mjs";

const PAGE_PORT = 18496;
const EDITOR_BUILD = "/Users/zahary/metacraft/isonim-examples/build/editor";

let harness = null;
let chromium = null,
  browser = null;

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
  // Seed 2 captures for the canonical ``render.task-app`` brief BEFORE
  // the browser loads. The captures share a preview_id so they end up
  // in the same row in the grid; the gallery still renders 2 tiles.
  await harness.seedCaptures("render.task-app", [
    {
      storyId: "p/inbox:page#0@web",
      platform: "web",
      deviceClass: "desktop",
      width: 320,
      height: 240,
    },
    {
      storyId: "p/inbox:page#0@web",
      platform: "web",
      deviceClass: "mobile",
      width: 200,
      height: 320,
    },
  ]);
});

test.after(async () => {
  try {
    if (browser) await browser.close();
  } catch {}
  if (harness) harness.teardownAll();
});

// Helper — drive the sidebar to select the story bound to
// ``render.task-app`` (the "Task App / Pages / Inbox" story in the
// isonim-examples bundled workspace). We dispatch the click events
// programmatically because Playwright's hit-testing refuses to click
// elements that are clipped or below the fold on small viewports.
async function selectInboxStory(page) {
  await page.evaluate(() => {
    // Expand the "Pages" section.
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

test("e2e_gallery_renders_real_captures_after_history_button_click", async () => {
  const b = await ensureBrowser();
  const ctx = await b.newContext({
    viewport: { width: 1440, height: 900 },
  });
  const page = await ctx.newPage();
  // Surface JS errors as test failures.
  const errors = [];
  page.on("pageerror", (err) => errors.push(String(err)));
  await page.goto(harness.editorUrl, { waitUntil: "domcontentloaded" });
  await page.waitForTimeout(500);
  await selectInboxStory(page);
  // 2-second poll for the briefHasHistory cascade to settle: the
  // selected story drives the briefId signal, the poll fires, the
  // response sets briefHasHistory=true, the history-button mirror
  // flips ``data-history-visible``.
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
  // Click the history button (programmatic dispatch — the chrome
  // bar may layout-clip the button at this viewport).
  await page.evaluate(() => {
    const btn = document.querySelector(
      '[data-design-review-history-button="true"]',
    );
    btn?.dispatchEvent(new MouseEvent("click", { bubbles: true }));
  });
  // Wait for the gallery to fetch + render at least 2 tiles.
  await page.waitForFunction(
    () =>
      document.querySelectorAll("[data-design-review-gallery-tile]").length >=
      2,
    null,
    { timeout: 15_000 },
  );
  const tileCount = await page.evaluate(
    () => document.querySelectorAll("[data-design-review-gallery-tile]").length,
  );
  assert.ok(
    tileCount >= 2,
    `expected ≥2 gallery tiles after history button click; got ${tileCount}`,
  );
  // Each tile must carry a non-empty thumbnail image src.
  const thumbSrcs = await page.evaluate(() => {
    const tiles = Array.from(
      document.querySelectorAll("[data-design-review-gallery-tile]"),
    );
    return tiles.map((t) => {
      const img = t.querySelector(
        'img[data-design-review-gallery-thumb="true"]',
      );
      return img?.getAttribute("src") || "";
    });
  });
  for (const src of thumbSrcs) {
    // Wave A — the pngUrl is now absolute (daemon baseUrl prefix)
    // so the browser actually loads the PNG bytes when the editor
    // and the daemon are on different origins (the e2e harness
    // setup). Accept any URL that ends with the canonical route.
    assert.ok(
      src.includes("/api/design-review/get-capture-png?id="),
      `gallery tile thumbnail src must include the capture-png route; got "${src}"`,
    );
  }
  // No page errors during the full mount + fetch dance.
  assert.equal(
    errors.length,
    0,
    "no page errors expected during cascade: " + JSON.stringify(errors),
  );
  await ctx.close();
});

test("e2e_history_button_data_history_visible_true_before_click", async () => {
  const b = await ensureBrowser();
  const ctx = await b.newContext({
    viewport: { width: 1440, height: 900 },
  });
  const page = await ctx.newPage();
  await page.goto(harness.editorUrl, { waitUntil: "domcontentloaded" });
  await page.waitForTimeout(500);
  await selectInboxStory(page);
  // The button MUST flip data-history-visible="true" once the
  // briefHasHistory poll succeeds — the Wave A cascade fix is the
  // contract being tested here.
  await page.waitForSelector(
    '[data-design-review-history-button][data-history-visible="true"]',
    { timeout: 15_000 },
  );
  const visibleCount = await page.evaluate(
    () =>
      document.querySelectorAll(
        '[data-design-review-history-button][data-history-visible="true"]',
      ).length,
  );
  assert.ok(
    visibleCount >= 1,
    `expected ≥1 history button with data-history-visible="true"; got ${visibleCount}`,
  );
  await ctx.close();
});
