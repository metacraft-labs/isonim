// PSZ-M2 full-screen reveal driven by the pointer over the device frame, in
// headless Chromium (PSZ-M3 review gap: the frame-document path had no test).
//
// The device frame is an iframe. Pointer events over it never reach the
// editor's document, so the shell listens to the frame's own document
// (onFrameMove in shell.nim) and maps the pointer into the centre column. This
// file checks that path with a real pointer:
//
//   * with the pointer over the frame, inside the top-right reveal zone, the
//     floating controls become visible (opacity 1);
//   * with the pointer still over the frame but out of the zone, they hide.
//
// Mocks: none. The editor build, the editor server, the isonim-review daemon
// and headless Chromium are the real ones (psz_live_harness.mjs). The pointer
// is Playwright's real mouse input, which Chromium dispatches to the frame's
// document. The 1100-px window is the width at which the frame sits under the
// reveal zone; the test computes the points from the frame's own box and checks
// them against the zone before it relies on them.
//
// Run with:
//   repro exec -- bash -lc 'export PLAYWRIGHT_CHROMIUM_EXECUTABLE="$(command -v chromium)"; cd tests/browser && node --test e2e_preview_fullscreen_frame_pointer_live.mjs'

import test from "node:test";
import assert from "node:assert/strict";
import {
  buildEditor,
  closeBrowser,
  openStoryPreview,
  startPageServer,
  stopPageServer,
} from "./psz_live_harness.mjs";

const PORT = 18663;
const STORY = "/index.html?view=page&storyGroup=DestinationCard" +
  "&story=" + encodeURIComponent("Default") +
  "&kind=component&index=0&viewport=desktop";
const WINDOW = { width: 1100, height: 900 };
// The reveal corner, as preview_fullscreen.nim defines it (CSS pixels, measured
// from the top-right of the centre column).
const REVEAL = { width: 360, height: 120 };

test.before(async () => {
  buildEditor();
  await startPageServer(PORT);
});

test.after(async () => {
  await closeBrowser();
  stopPageServer();
});

// The floating cluster's opacity, read in the page. The cluster is the reveal
// target: the frame listener shows it, and the pointer leaving the zone hides it.
function clusterOpacity(page) {
  return page.evaluate(() => {
    const c = document.querySelector(
      '[data-preview-fullscreen-controls] [data-preview-zoom-cluster="true"]');
    return c ? getComputedStyle(c).opacity : null;
  });
}

// The frame's box, and the centre column's box, both in window coordinates.
function frameAndCentre(page) {
  return page.evaluate(() => {
    const frame = document.querySelector('[data-page-project-frame="true"]');
    const controls = document.querySelector('[data-preview-fullscreen-controls="true"]');
    const centre = controls && controls.parentElement;
    const f = frame.getBoundingClientRect();
    const c = centre.getBoundingClientRect();
    return {
      frame: { x: f.x, y: f.y, width: f.width, height: f.height },
      centre: { x: c.x, y: c.y, width: c.width, height: c.height },
    };
  });
}

test("e2e_preview_fullscreen_frame_pointer_reveals_and_hides", async () => {
  const { ctx, page } = await openStoryPreview(PORT, STORY,
    { suffix: "&zoom=fit&fullscreen=1", viewport: WINDOW });
  try {
    // The page opens in full screen, so the floating controls are displayed.
    // Their opacity is the reveal state the rest of the test reads.
    await page.waitForFunction(() => {
      const h = document.querySelector('[data-preview-fullscreen-controls="true"]');
      return !!h && getComputedStyle(h).display !== "none";
    }, null, { timeout: 5000 });
    // Park the pointer away from the frame and wait for the controls to hide.
    await page.mouse.move(5, 5);
    await page.waitForFunction(() => {
      const c = document.querySelector(
        '[data-preview-fullscreen-controls] [data-preview-zoom-cluster="true"]');
      return c && getComputedStyle(c).opacity === "0";
    }, null, { timeout: 5000 });

    const { frame, centre } = await frameAndCentre(page);
    // A point over the frame, near its top-right, converted into centre-column
    // coordinates the way the reveal test takes them.
    const inside = { x: frame.x + frame.width - 60, y: frame.y + 12 };
    const relX = inside.x - centre.x;
    const relY = inside.y - centre.y;
    const inZone = relX >= centre.width - REVEAL.width && relX <= centre.width &&
      relY >= 0 && relY < REVEAL.height;
    assert.ok(inZone,
      `precondition: the point (${relX}, ${relY}) must lie in the reveal zone of ` +
      `a ${centre.width}-px centre column`);
    const hit = await page.evaluate(([x, y]) => {
      const el = document.elementFromPoint(x, y);
      return !!el && el.tagName === "IFRAME" &&
        el.getAttribute("data-page-project-frame") === "true";
    }, [inside.x, inside.y]);
    assert.ok(hit, "precondition: the point must be over the device frame's iframe");

    // The pointer moves over the frame, inside the zone: the controls show.
    await page.mouse.move(inside.x, inside.y);
    await page.waitForFunction(() => {
      const c = document.querySelector(
        '[data-preview-fullscreen-controls] [data-preview-zoom-cluster="true"]');
      return c && getComputedStyle(c).opacity === "1";
    }, null, { timeout: 5000 });
    assert.equal(await clusterOpacity(page), "1",
      "the pointer over the frame in the reveal zone shows the floating controls");

    // The pointer stays over the frame but leaves the zone: the controls hide.
    const away = { x: frame.x + 40, y: frame.y + frame.height - 40 };
    const awayRelX = away.x - centre.x;
    const awayRelY = away.y - centre.y;
    assert.ok(!(awayRelX >= centre.width - REVEAL.width && awayRelY < REVEAL.height),
      "precondition: the second point must lie outside the reveal zone");
    await page.mouse.move(away.x, away.y);
    await page.waitForFunction(() => {
      const c = document.querySelector(
        '[data-preview-fullscreen-controls] [data-preview-zoom-cluster="true"]');
      return c && getComputedStyle(c).opacity === "0";
    }, null, { timeout: 5000 });
    assert.equal(await clusterOpacity(page), "0",
      "the pointer over the frame outside the reveal zone hides the floating controls");
  } finally {
    await ctx.close();
  }
});
