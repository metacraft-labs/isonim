// PSZ-M3 (Preview-Sizing-And-Zoom) exported story, in a headless browser.
//
// "An exported story" (spec open decision D5, proposed) is a story opened from
// its own story URL in a fresh browser session, with nothing carried over from
// the editor. This test opens the editor's DestinationCard / Default story with
// ``zoom=50&fullscreen=1`` and checks that the page renders that way:
//
//   * the story is in full screen: the sidebar, the chrome bar and the status
//     bar are not shown, and the floating controls are;
//   * the zoom readout reads 50%, the device frame carries scale(0.5), and its
//     rendered box is half the 1440x900 Desktop frame (720x450);
//   * the URL still carries zoom=50 and fullscreen=1 after the page loads, so
//     the link a reviewer copies points at the same view.
//
// Fixture and stack: the same as e2e_preview_fullscreen_live.mjs. The editor
// build, the editor server and headless Chromium are real; nothing is mocked
// (psz_live_harness.mjs). The browser is taken from PLAYWRIGHT_CHROMIUM_EXECUTABLE.
//
// Run with:
//   repro exec -- bash -lc 'export PLAYWRIGHT_CHROMIUM_EXECUTABLE="$(command -v chromium)"; cd tests/browser && node --test e2e_exported_story_zoom_url_live.mjs'

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
// The exported state: half size, full screen. Both are read from the URL.
const EXPORTED_SUFFIX = "&zoom=50&fullscreen=1";

test.before(async () => {
  buildEditor();
  await startPageServer(PORT);
});

test.after(async () => {
  await closeBrowser();
  stopPageServer();
});

test("e2e_exported_story_zoom_url", async () => {
  const { ctx, page } = await openStoryPreview(PORT, STORY,
    { suffix: EXPORTED_SUFFIX });
  try {
    const layout = await page.evaluate(() => {
      const visible = (el) => !!el && getComputedStyle(el).display !== "none" &&
        el.getClientRects().length > 0;
      const frame = document.querySelector('[data-preview-zoom-frame="true"]');
      const iframe = document.querySelector("[data-page-project-frame]");
      const readout = document.querySelector("[data-preview-zoom-level]");
      const host = document.querySelector('[data-preview-fullscreen-controls="true"]');
      const rect = iframe ? iframe.getBoundingClientRect() : null;
      return {
        sidebar: visible(document.querySelector('[data-editor-sidebar="true"]')),
        chromeBar: visible(document.querySelector('[data-preview-chrome-bar="true"]')),
        statusBar: visible(document.querySelector(".editor-statusbar")),
        floatingControls: visible(host),
        readout: readout ? readout.textContent : null,
        readoutCount: document.querySelectorAll("[data-preview-zoom-level]").length,
        transform: frame ? getComputedStyle(frame).transform : null,
        scaleAttr: frame ? frame.getAttribute("data-preview-zoom-scale") : null,
        frameWidth: rect ? Math.round(rect.width) : null,
        frameHeight: rect ? Math.round(rect.height) : null,
      };
    });

    // Full screen: only the preview and the floating controls are laid out.
    assert.equal(layout.sidebar, false, "the sidebar is hidden in full screen");
    assert.equal(layout.chromeBar, false, "the chrome bar is hidden in full screen");
    assert.equal(layout.statusBar, false, "the status bar is hidden in full screen");
    assert.equal(layout.floatingControls, true, "the floating controls are shown");

    // Zoom 50%: one readout, half-scale transform, and a frame box of half the
    // 1440x900 Desktop frame. The measured box is printed for the record.
    assert.equal(layout.readoutCount, 1, "exactly one zoom readout");
    assert.equal(layout.readout, "50%", "the readout shows the URL zoom");
    assert.equal(layout.scaleAttr, "0.5", "the frame is scaled to 0.5");
    assert.match(layout.transform, /^matrix\(0\.5, 0, 0, 0\.5/,
      "the frame carries the 0.5 transform");
    console.log(`[exported story] frame box ${layout.frameWidth}x${layout.frameHeight} at 50%`);
    assert.ok(Math.abs(layout.frameWidth - 720) <= 1, "720 px wide at 50%");
    assert.ok(Math.abs(layout.frameHeight - 450) <= 1, "450 px tall at 50%");

    // The URL the page settled on still carries the exported state.
    const params = await page.evaluate(() =>
      Object.fromEntries(new URLSearchParams(location.search).entries()));
    assert.equal(params.zoom, "50", "the URL keeps zoom=50");
    assert.equal(params.fullscreen, "1", "the URL keeps fullscreen=1");
    assert.equal(params.story, "Default", "the URL keeps the story");
    assert.equal(params.viewport, "desktop", "the URL keeps the viewport");
  } finally {
    await ctx.close();
  }
});
