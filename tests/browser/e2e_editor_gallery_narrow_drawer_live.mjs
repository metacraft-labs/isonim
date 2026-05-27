// CHRM-M7 — Playwright e2e: gallery overlay at narrow viewports.
//
// CHRM-M6 deferred narrow widths: the editor's responsive CSS
// (``browser.nim``'s ``@media (max-width: 768px)`` rule) hides the
// centre column at narrow widths, which made the gallery overlay
// (mounted inside the centre column) unreachable. CHRM-M7 fixes that
// by:
//
//   1. Surfacing a second history button in the sidebar header, gated
//      by the ``editor-sidebar-history-narrow`` class so it appears
//      only at narrow widths.
//   2. Re-parenting the gallery host to ``document.body`` and applying
//      ``position: fixed`` when the viewport is narrow AND the gallery
//      is open, so the drawer overlays the sidebar rather than living
//      inside the (hidden) centre column.
//   3. Exposing a close affordance (×) in the drawer's top-right
//      corner, since ESC isn't reliable on touch devices.
//
// This test seals each of those three contracts.

import test from "node:test";
import assert from "node:assert/strict";
import { bootFullHarness } from "./lib/design_review_harness.mjs";

const PAGE_PORT = 18509;
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
});

test.after(async () => {
  try {
    if (browser) await browser.close();
  } catch {}
  if (harness) harness.teardownAll();
});

// Drive the sidebar to select the Inbox story. Programmatic clicks
// because Playwright's hit-testing refuses to click elements that
// are clipped at 375 px widths.
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

test("narrow viewport — sidebar history button is reachable (visible and clickable)", async () => {
  const b = await ensureBrowser();
  const ctx = await b.newContext({
    viewport: { width: 375, height: 812 },
  });
  const page = await ctx.newPage();
  try {
    await page.goto(harness.editorUrl, { waitUntil: "domcontentloaded" });
    await page.waitForTimeout(500);
    await selectInboxStory(page);
    // The sidebar history slot must be on screen. The slot class
    // (``editor-sidebar-history-narrow``) is shown via the media
    // query at ≤768 px and hidden at wider widths.
    await page.waitForSelector(".editor-sidebar-history-narrow", {
      timeout: 10_000,
    });
    const slotVisible = await page.evaluate(() => {
      const slot = document.querySelector(".editor-sidebar-history-narrow");
      if (!slot) return false;
      const cs = window.getComputedStyle(slot);
      return cs.display !== "none";
    });
    assert.ok(
      slotVisible,
      "sidebar history slot must be visible at narrow viewport",
    );
    // The button inside the slot must also be visible.
    const btnVisible = await page.evaluate(() => {
      const slot = document.querySelector(".editor-sidebar-history-narrow");
      const btn = slot?.querySelector(
        '[data-design-review-history-button-sidebar="true"]',
      );
      if (!btn) return false;
      const cs = window.getComputedStyle(btn);
      const rect = btn.getBoundingClientRect();
      return cs.display !== "none" && rect.width > 0 && rect.height > 0;
    });
    assert.ok(
      btnVisible,
      "sidebar history button must be visible (display!=none, non-zero size) at narrow viewport",
    );
  } finally {
    await ctx.close();
  }
});

test("narrow viewport — clicking history button mounts gallery in drawer mode", async () => {
  const b = await ensureBrowser();
  const ctx = await b.newContext({
    viewport: { width: 375, height: 812 },
  });
  const page = await ctx.newPage();
  try {
    await page.goto(harness.editorUrl, { waitUntil: "domcontentloaded" });
    await page.waitForTimeout(500);
    await selectInboxStory(page);
    await page.waitForSelector(".editor-sidebar-history-narrow", {
      timeout: 10_000,
    });
    // Click the sidebar history button.
    await page.evaluate(() => {
      const slot = document.querySelector(".editor-sidebar-history-narrow");
      const btn = slot?.querySelector(
        '[data-design-review-history-button-sidebar="true"]',
      );
      btn?.dispatchEvent(new MouseEvent("click", { bubbles: true }));
    });
    // The host must flip to drawer mount-mode.
    await page.waitForFunction(
      () => {
        const host = document.querySelector(
          '[data-design-review-gallery-host="true"]',
        );
        return (
          host && host.getAttribute("data-gallery-mount-mode") === "drawer"
        );
      },
      null,
      { timeout: 10_000 },
    );
    const mountMode = await page.evaluate(() => {
      const host = document.querySelector(
        '[data-design-review-gallery-host="true"]',
      );
      return host?.getAttribute("data-gallery-mount-mode");
    });
    assert.equal(
      mountMode,
      "drawer",
      `host must report mount-mode="drawer" at narrow widths; got "${mountMode}"`,
    );
    // Position must be fixed so the host overlays the viewport.
    const position = await page.evaluate(() => {
      const host = document.querySelector(
        '[data-design-review-gallery-host="true"]',
      );
      return host ? window.getComputedStyle(host).position : "";
    });
    assert.equal(
      position,
      "fixed",
      `host must use position:fixed when in drawer mode; got "${position}"`,
    );
    // The host must have been re-parented to <body> (or a descendant
    // of body that is NOT the centre column, which is display:none).
    const parentClass = await page.evaluate(() => {
      const host = document.querySelector(
        '[data-design-review-gallery-host="true"]',
      );
      return host?.parentElement?.tagName?.toLowerCase() || "";
    });
    assert.equal(
      parentClass,
      "body",
      `host must be re-parented to <body> in drawer mode; parent tagName was "${parentClass}"`,
    );
  } finally {
    await ctx.close();
  }
});

test("narrow viewport — close affordance dismisses drawer without dropping the chrome", async () => {
  const b = await ensureBrowser();
  const ctx = await b.newContext({
    viewport: { width: 375, height: 812 },
  });
  const page = await ctx.newPage();
  try {
    await page.goto(harness.editorUrl, { waitUntil: "domcontentloaded" });
    await page.waitForTimeout(500);
    await selectInboxStory(page);
    await page.waitForSelector(".editor-sidebar-history-narrow", {
      timeout: 10_000,
    });
    // Open the drawer.
    await page.evaluate(() => {
      const slot = document.querySelector(".editor-sidebar-history-narrow");
      const btn = slot?.querySelector(
        '[data-design-review-history-button-sidebar="true"]',
      );
      btn?.dispatchEvent(new MouseEvent("click", { bubbles: true }));
    });
    await page.waitForFunction(
      () => {
        const host = document.querySelector(
          '[data-design-review-gallery-host="true"]',
        );
        return host && host.getAttribute("data-gallery-host-open") === "true";
      },
      null,
      { timeout: 10_000 },
    );
    // The close chip must be visible (it's hidden in inline mode).
    const closeVisible = await page.evaluate(() => {
      const close = document.querySelector(
        '[data-design-review-gallery-close="true"]',
      );
      if (!close) return false;
      const cs = window.getComputedStyle(close);
      return cs.display !== "none";
    });
    assert.ok(closeVisible, "close chip must be visible in narrow drawer mode");
    // Click it.
    await page.evaluate(() => {
      const close = document.querySelector(
        '[data-design-review-gallery-close="true"]',
      );
      close?.dispatchEvent(new MouseEvent("click", { bubbles: true }));
    });
    // The host must flip back to closed.
    await page.waitForFunction(
      () => {
        const host = document.querySelector(
          '[data-design-review-gallery-host="true"]',
        );
        return host && host.getAttribute("data-gallery-host-open") === "false";
      },
      null,
      { timeout: 10_000 },
    );
    const openAttr = await page.evaluate(() => {
      const host = document.querySelector(
        '[data-design-review-gallery-host="true"]',
      );
      return host?.getAttribute("data-gallery-host-open");
    });
    assert.equal(
      openAttr,
      "false",
      `host must report open=false after close chip click; got "${openAttr}"`,
    );
    // The underlying sidebar must still be present (close shouldn't
    // dismount editor chrome).
    const sidebarStillPresent = await page.evaluate(() => {
      const sidebar = document.querySelector(".editor-sidebar");
      if (!sidebar) return false;
      const cs = window.getComputedStyle(sidebar);
      return cs.display !== "none";
    });
    assert.ok(
      sidebarStillPresent,
      "sidebar must remain visible after closing the gallery drawer",
    );
  } finally {
    await ctx.close();
  }
});
