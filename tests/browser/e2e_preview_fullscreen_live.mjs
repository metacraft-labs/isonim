// PSZ-M2 (Preview-Sizing-And-Zoom) full-screen preview, in a headless browser.
// The fixture is the editor's existing "DestinationCard / Default" component
// story, as in e2e_preview_zoom_live.mjs. Nothing is mocked: the editor build,
// the editor server and headless Chromium are the real ones
// (psz_live_harness.mjs).
//
//   * e2e_preview_fullscreen_escape: the chrome-bar button enters full screen,
//     F toggles it while the preview has focus, Escape leaves it, the corner
//     reveals the floating controls, the second control requests the browser's
//     full screen (D2), and the story URL carries fullscreen=1 / fullscreen=0
//     with the same story, viewport and zoom on both sides of the round trip.
//
// Captures: when PSZ_M2_CAPTURE_DIR is set, the test writes three PNGs there:
// the normal editor, the full-screen view with the floating controls hidden,
// and the same view with the pointer in the reveal corner.
//
// Run with:
//   repro exec -- bash -lc 'export PLAYWRIGHT_CHROMIUM_EXECUTABLE="$(command -v chromium)"; cd tests/browser && PSZ_M2_CAPTURE_DIR=<dir> node --test e2e_preview_fullscreen_live.mjs'

import { mkdirSync } from "node:fs";
import { join } from "node:path";
import test from "node:test";
import assert from "node:assert/strict";
import {
  buildEditor,
  closeBrowser,
  openStoryPreview,
  startPageServer,
  stopPageServer,
} from "./psz_live_harness.mjs";

const PORT = 18662;
const STORY = "/index.html?view=page&storyGroup=DestinationCard" +
  "&story=" + encodeURIComponent("Default") +
  "&kind=component&index=0&viewport=desktop";
const CAPTURE_DIR = process.env.PSZ_M2_CAPTURE_DIR || "";
// The reveal corner: x near the right edge of the 2200-px window, y near the top.
const CORNER = { x: 2100, y: 60 };
const AWAY = { x: 600, y: 700 };

// One read of the layout the reviewer sees. "Visible" means display is not none
// and the element has a box, so a node hidden by an ancestor counts as hidden.
function readLayout(page) {
  return page.evaluate(() => {
    const visible = (el) => !!el && getComputedStyle(el).display !== "none" &&
      el.getClientRects().length > 0;
    const sidebar = document.querySelector('[data-editor-sidebar="true"]');
    const chromeBar = document.querySelector('[data-preview-chrome-bar="true"]');
    const statusBar = document.querySelector(".editor-statusbar");
    const host = document.querySelector('[data-preview-fullscreen-controls="true"]');
    const cluster = document.querySelector(
      '[data-preview-fullscreen-controls] [data-preview-zoom-cluster="true"]');
    const active = document.activeElement;
    return {
      sidebar: visible(sidebar),
      chromeBar: visible(chromeBar),
      statusBar: visible(statusBar),
      host: visible(host),
      clusterOpacity: cluster ? getComputedStyle(cluster).opacity : null,
      clusterPointerEvents: cluster ? getComputedStyle(cluster).pointerEvents : null,
      readouts: document.querySelectorAll("[data-preview-zoom-level]").length,
      readout: (document.querySelector("[data-preview-zoom-level]") || {}).textContent,
      focusInPreview: !!(active && active.closest &&
        active.closest('[data-page-preview="true"], [data-preview-fullscreen-controls="true"]')),
    };
  });
}

function urlParams(page) {
  return page.evaluate(() => Object.fromEntries(
    new URLSearchParams(location.search).entries()));
}

async function waitParam(page, key, value) {
  await page.waitForFunction(([k, v]) =>
    new URLSearchParams(location.search).get(k) === v,
    [key, value], { timeout: 5000 });
}

async function waitFor(page, predicate, arg) {
  await page.waitForFunction(predicate, arg, { timeout: 5000 });
}

async function snap(page, name) {
  if (!CAPTURE_DIR) return;
  mkdirSync(CAPTURE_DIR, { recursive: true });
  await page.screenshot({ path: join(CAPTURE_DIR, name) });
}

test.before(async () => {
  buildEditor();
  await startPageServer(PORT);
});

test.after(async () => {
  await closeBrowser();
  stopPageServer();
});

test("e2e_preview_fullscreen_escape", async () => {
  const { ctx, page } = await openStoryPreview(PORT, STORY,
    { suffix: "&zoom=fit&fullscreen=0" });
  try {
    // Normal editor: the chrome is shown, the floating controls are not.
    const normal = await readLayout(page);
    assert.equal(normal.sidebar, true, "sidebar should be shown before full screen");
    assert.equal(normal.chromeBar, true, "chrome bar should be shown before full screen");
    assert.equal(normal.host, false, "floating controls should be hidden before full screen");
    assert.equal(normal.readouts, 1, "exactly one zoom readout in the tree");
    const readoutBefore = normal.readout;
    const before = await urlParams(page);
    assert.equal(before.fullscreen, "0", "the URL should carry fullscreen=0");
    const toggle = page.locator('[data-preview-fullscreen-toggle="true"]');
    assert.equal(await toggle.getAttribute("aria-label"), "Full screen preview");
    await snap(page, "normal.png");

    // The chrome-bar button enters full screen.
    await toggle.click();
    await waitParam(page, "fullscreen", "1");
    await page.mouse.move(AWAY.x, AWAY.y);
    const entered = await readLayout(page);
    assert.equal(entered.sidebar, false, "full screen hides the sidebar");
    assert.equal(entered.chromeBar, false, "full screen hides the chrome bar");
    assert.equal(entered.statusBar, false, "full screen hides the status bar");
    assert.equal(entered.host, true, "full screen shows the floating controls");
    assert.equal(entered.readouts, 1, "the cluster moved, it is not duplicated");
    assert.equal(entered.readout, readoutBefore, "the zoom readout is unchanged");
    // The preview takes focus, so F and Escape work at once.
    await waitFor(page, () => {
      const a = document.activeElement;
      return !!(a && a.closest && a.closest('[data-page-preview="true"], [data-preview-fullscreen-controls="true"]'));
    });
    // The floating controls are hidden while the pointer is away from the corner.
    await waitFor(page, () => {
      const c = document.querySelector('[data-preview-fullscreen-controls] [data-preview-zoom-cluster="true"]');
      return c && getComputedStyle(c).opacity === "0";
    });
    await snap(page, "fullscreen-controls-hidden.png");

    // Pointer in the reveal corner: the floating controls show.
    await page.mouse.move(CORNER.x, CORNER.y);
    await waitFor(page, () => {
      const c = document.querySelector('[data-preview-fullscreen-controls] [data-preview-zoom-cluster="true"]');
      return c && getComputedStyle(c).opacity === "1";
    });
    await snap(page, "fullscreen-controls-shown.png");
    await page.mouse.move(AWAY.x, AWAY.y);
    await waitFor(page, () => {
      const c = document.querySelector('[data-preview-fullscreen-controls] [data-preview-zoom-cluster="true"]');
      return c && getComputedStyle(c).opacity === "0";
    });

    // F, while the preview has focus, leaves full screen; F again enters it.
    await page.keyboard.press("f");
    await waitParam(page, "fullscreen", "0");
    let afterF = await readLayout(page);
    assert.equal(afterF.sidebar, true, "F leaves full screen: sidebar back");
    assert.equal(afterF.chromeBar, true, "F leaves full screen: chrome bar back");
    assert.equal(afterF.host, false, "F leaves full screen: floating controls hidden");
    assert.equal(afterF.focusInPreview, true,
      "leaving full screen keeps focus in the preview, so F still works");
    await page.keyboard.press("f");
    await waitParam(page, "fullscreen", "1");
    await waitFor(page, () => {
      const el = document.querySelector('[data-preview-fullscreen-controls="true"]');
      return !!el && getComputedStyle(el).display !== "none";
    });

    // Escape leaves full screen, and the URL reflects it.
    await page.keyboard.press("Escape");
    await waitParam(page, "fullscreen", "0");
    const left = await readLayout(page);
    assert.equal(left.sidebar, true, "Escape leaves full screen: sidebar back");
    assert.equal(left.host, false, "Escape leaves full screen: floating controls hidden");
    assert.equal(left.readout, readoutBefore, "leaving keeps the zoom");

    // The URL, both sides of the round trip: the same story, viewport and zoom.
    const after = await urlParams(page);
    for (const key of ["view", "storyGroup", "story", "kind", "index", "viewport", "zoom"]) {
      assert.equal(after[key], before[key], `URL ${key} changed across full screen`);
    }

    // Second press (D2): the floating browser control asks the browser for its
    // own full screen. The request is recorded by wrapping the method, because
    // headless Chromium may refuse the request itself.
    await toggle.click();
    await waitParam(page, "fullscreen", "1");
    await page.evaluate(() => {
      window.__fsRequests = 0;
      const original = Element.prototype.requestFullscreen;
      Element.prototype.requestFullscreen = function (...args) {
        window.__fsRequests++;
        return original ? original.apply(this, args) : Promise.reject(new Error("unsupported"));
      };
    });
    await page.mouse.move(CORNER.x, CORNER.y);
    const browserButton = page.locator('[aria-label="Request browser full screen"]');
    await browserButton.click();
    await waitFor(page, () => window.__fsRequests === 1);
    assert.equal((await urlParams(page)).fullscreen, "1",
      "requesting the browser's full screen does not change the in-editor state");

    // Leave again with Escape, and the URL is back where it started.
    await page.mouse.move(AWAY.x, AWAY.y);
    await page.keyboard.press("Escape");
    await waitParam(page, "fullscreen", "0");
    const final = await urlParams(page);
    assert.equal(final.fullscreen, "0");
    assert.equal(final.zoom, before.zoom);
  } finally {
    await ctx.close();
  }
});
