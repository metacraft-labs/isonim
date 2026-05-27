// REV-M8 follow-up — Playwright e2e: gallery drag-and-drop now
// visibly reorders tiles in the DOM, surfaces a dirty mirror on the
// overlay, and renders a Save layout chip that fires the save action.
//
// Architectural context (post-follow-up):
//
// The gallery's row-rendering memo derives from ``effectiveTiles``
// (NOT ``tiles``). ``effectiveTiles`` is a memo that overlays
// ``pendingLayout`` on the canonical tile cache — so a drop, which
// pushes a ``PendingLayoutEntry`` into ``pendingLayout``, also
// invalidates ``effectiveTiles`` → ``rows`` → the grid repaints with
// the dragged tile at its target position. The original ``tiles.val``
// is untouched (any server round-trip works against the real data).
//
// In addition, the overlay surfaces:
//
//   * ``data-design-review-gallery-dirty`` on the root, mirroring
//     ``vm.isDirty.val``.
//   * A reactive save chip
//     (``[data-design-review-gallery-save-button="true"]``) whose
//     ``data-design-review-gallery-save-visible`` flag mirrors
//     ``isDirty``. Clicking it calls the caller-supplied ``onSave``
//     callback (or falls back to ``vm.markSaved`` when no callback
//     was wired). On success the chip carries ``data-saved="true"``
//     briefly so the e2e can observe the transition.
//
// This file used to assert the inverse "REV-M7 contract: drop records
// pendingLayout but does not re-render". That assertion is now
// inverted: a drop MUST visibly reorder, MUST flip dirty, MUST surface
// the save chip.

import test from "node:test";
import assert from "node:assert/strict";
import { bootFullHarness } from "./lib/design_review_harness.mjs";

const PAGE_PORT = 18499;
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
  // Seed 4 captures across two device classes so the gallery groups
  // them into a single previewId row (the dragging happens within the
  // row — same previewId per the harness story binding).
  //
  // ``storyId`` is the canonical preview-id the editor's
  // ``canonicalPreviewId(story, backend)`` will project the active
  // (Task App / Pages / Inbox, web) story onto — so the gallery's
  // filter-by-current-preview keeps these captures visible after the
  // history button opens the overlay. (Pre-filter the test used
  // ``p/inbox:page#0@web``; the filter would have dropped every tile.)
  const previewId = "Task App %2F Pages/Inbox:page#0@web";
  const captures = [];
  for (let i = 0; i < 4; i++) {
    captures.push({
      storyId: previewId,
      platform: "web",
      deviceClass: i % 2 === 0 ? "desktop" : "mobile",
      width: 320,
      height: 240,
      runArgs: { snapshotHash: "h-drag-" + i, recordedBy: "tester" },
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

test("gallery tiles are draggable per the DSL declaration", async () => {
  const b = await ensureBrowser();
  const ctx = await b.newContext({ viewport: { width: 1440, height: 900 } });
  const page = await ctx.newPage();
  try {
    await openGalleryWithCaptures(page);
    const draggableInfo = await page.evaluate(() => {
      const tiles = Array.from(
        document.querySelectorAll("[data-design-review-gallery-tile]"),
      );
      return tiles.map((t) => ({
        captureId: t.getAttribute("data-design-review-gallery-tile"),
        draggable: t.getAttribute("draggable"),
      }));
    });
    assert.ok(
      draggableInfo.length >= 2,
      `expected >=2 tiles to assert draggable; got ${draggableInfo.length}`,
    );
    for (const info of draggableInfo) {
      assert.equal(
        info.draggable,
        "true",
        `tile ${info.captureId} must carry draggable="true" (got "${info.draggable}")`,
      );
    }
  } finally {
    await ctx.close();
  }
});

test("synthetic dragstart + dragover + drop fires without page errors and tile count stays stable", async () => {
  const b = await ensureBrowser();
  const ctx = await b.newContext({ viewport: { width: 1440, height: 900 } });
  const page = await ctx.newPage();
  const errors = [];
  page.on("pageerror", (err) => errors.push(String(err)));
  try {
    await openGalleryWithCaptures(page);
    const before = await page.evaluate(() => {
      const tiles = Array.from(
        document.querySelectorAll("[data-design-review-gallery-tile]"),
      );
      return tiles.map((t) =>
        t.getAttribute("data-design-review-gallery-tile"),
      );
    });
    assert.ok(
      before.length >= 2,
      `expected >=2 tiles for drag scenario; got ${before.length}`,
    );
    await page.evaluate(() => {
      const tiles = Array.from(
        document.querySelectorAll("[data-design-review-gallery-tile]"),
      );
      const src = tiles[0];
      const dst = tiles[1];
      function dispatchDragEvent(target, type) {
        let ev;
        try {
          ev = new DragEvent(type, { bubbles: true, cancelable: true });
        } catch {
          ev = new Event(type, { bubbles: true, cancelable: true });
        }
        target.dispatchEvent(ev);
      }
      dispatchDragEvent(src, "dragstart");
      dispatchDragEvent(dst, "dragover");
      dispatchDragEvent(dst, "drop");
    });
    await page.waitForTimeout(200);
    // Tile count must be stable — the reorder shifts positions but
    // never adds/removes tiles.
    const afterIds = await page.evaluate(() => {
      const tiles = Array.from(
        document.querySelectorAll("[data-design-review-gallery-tile]"),
      );
      return tiles.map((t) =>
        t.getAttribute("data-design-review-gallery-tile"),
      );
    });
    assert.equal(
      afterIds.length,
      before.length,
      "tile count must be stable across a drag sequence " +
        `(before=${before.length}, after=${afterIds.length})`,
    );
    // No JS errors during the drag pipeline.
    assert.equal(
      errors.length,
      0,
      "no page errors expected during synthetic drag sequence: " +
        JSON.stringify(errors),
    );
  } finally {
    await ctx.close();
  }
});

test("drop visibly reorders the dragged tile and flips data-design-review-gallery-dirty=true", async () => {
  // REV-M8 follow-up — replaces the prior "REV-M7 contract: drop
  // records pendingLayout but does NOT re-render" assertion. The grid
  // now derives from ``effectiveTiles`` (a memo that overlays
  // pendingLayout on tiles), so a drop visibly repositions the tile
  // AND surfaces a dirty mirror + save chip.
  const b = await ensureBrowser();
  const ctx = await b.newContext({ viewport: { width: 1440, height: 900 } });
  const page = await ctx.newPage();
  try {
    await openGalleryWithCaptures(page);
    // Capture the pre-drag layout: ordered list of (captureId, row, col)
    // for each tile.
    const before = await page.evaluate(() => {
      return Array.from(
        document.querySelectorAll("[data-design-review-gallery-tile]"),
      ).map((t) => ({
        captureId: t.getAttribute("data-design-review-gallery-tile"),
        row: t.getAttribute("data-design-review-gallery-row"),
        col: t.getAttribute("data-design-review-gallery-col"),
      }));
    });
    assert.ok(
      before.length >= 2,
      `need >=2 tiles for drag; got ${before.length}`,
    );
    // Confirm the overlay starts NOT dirty.
    const initialDirty = await page.evaluate(() =>
      document
        .querySelector('[data-design-review-gallery-overlay="true"]')
        ?.getAttribute("data-design-review-gallery-dirty"),
    );
    assert.equal(
      initialDirty,
      "false",
      "overlay must start with data-design-review-gallery-dirty=false",
    );
    // Drag tile[0] onto tile[1]'s position. The gallery's handlers
    // bind ``dragover`` + ``drop`` to ``registerDragMove(captureId,
    // rowIdx, colIdx)`` — the rowIdx + colIdx are baked at render
    // time, so the drop on tile[1] records tile[0]->target=(row1,
    // col1). After the memo recomputes, tile[0] sits where tile[1]
    // was; tile[1] shifts left.
    const srcCaptureId = before[0].captureId;
    const dstCaptureId = before[1].captureId;
    const dstRowBefore = before[1].row;
    const dstColBefore = before[1].col;
    await page.evaluate(() => {
      const tiles = Array.from(
        document.querySelectorAll("[data-design-review-gallery-tile]"),
      );
      function ev(type) {
        try {
          return new DragEvent(type, { bubbles: true, cancelable: true });
        } catch {
          return new Event(type, { bubbles: true, cancelable: true });
        }
      }
      tiles[0].dispatchEvent(ev("dragstart"));
      tiles[1].dispatchEvent(ev("dragover"));
      tiles[1].dispatchEvent(ev("drop"));
    });
    await page.waitForTimeout(200);
    // After the drop, the source tile must carry the destination's
    // pre-drag row/col (we dropped it ONTO the destination's slot).
    const after = await page.evaluate(() => {
      return Array.from(
        document.querySelectorAll("[data-design-review-gallery-tile]"),
      ).map((t) => ({
        captureId: t.getAttribute("data-design-review-gallery-tile"),
        row: t.getAttribute("data-design-review-gallery-row"),
        col: t.getAttribute("data-design-review-gallery-col"),
      }));
    });
    const srcAfter = after.find((t) => t.captureId === srcCaptureId);
    assert.ok(srcAfter, `dragged tile ${srcCaptureId} missing post-drop`);
    assert.equal(
      srcAfter.row,
      dstRowBefore,
      `dragged tile ${srcCaptureId} must adopt destination's row ` +
        `(${dstRowBefore}); got ${srcAfter.row}`,
    );
    assert.equal(
      srcAfter.col,
      dstColBefore,
      `dragged tile ${srcCaptureId} must adopt destination's col ` +
        `(${dstColBefore}); got ${srcAfter.col}`,
    );
    // The destination tile MUST still exist (drop is a reorder, not
    // a replace) and its row/col must have shifted off the original.
    const dstAfter = after.find((t) => t.captureId === dstCaptureId);
    assert.ok(dstAfter, `destination tile ${dstCaptureId} missing post-drop`);
    // dst's new col must differ from its before-col (it was displaced
    // when src landed on it).  Row may also differ — both checked.
    const dstMoved =
      dstAfter.col !== dstColBefore || dstAfter.row !== dstRowBefore;
    assert.ok(
      dstMoved,
      `destination tile ${dstCaptureId} must have moved after the ` +
        `drop landed on its slot (before row=${dstRowBefore}, col=${dstColBefore}; ` +
        `after row=${dstAfter.row}, col=${dstAfter.col})`,
    );
    // Dirty mirror is now "true".
    const dirtyAfter = await page.evaluate(() =>
      document
        .querySelector('[data-design-review-gallery-overlay="true"]')
        ?.getAttribute("data-design-review-gallery-dirty"),
    );
    assert.equal(
      dirtyAfter,
      "true",
      "overlay must carry data-design-review-gallery-dirty=true after drop",
    );
  } finally {
    await ctx.close();
  }
});

test("save chip surfaces when dirty, clicking it clears dirty and flashes data-saved=true", async () => {
  // REV-M8 follow-up — the third leg of the visible-reorder pipeline:
  // a Save layout chip becomes visible reactively when isDirty=true,
  // and clicking it (1) fires the save action and (2) flips the chip
  // to a brief "saved" state that the e2e can latch onto.
  const b = await ensureBrowser();
  const ctx = await b.newContext({ viewport: { width: 1440, height: 900 } });
  const page = await ctx.newPage();
  try {
    await openGalleryWithCaptures(page);
    // Save chip MUST exist in the DOM (rendered up front; visibility
    // is controlled by data-design-review-gallery-save-visible).
    const initialChip = await page.evaluate(() => {
      const chip = document.querySelector(
        '[data-design-review-gallery-save-button="true"]',
      );
      if (!chip) return null;
      return {
        visible: chip.getAttribute("data-design-review-gallery-save-visible"),
        saved: chip.getAttribute("data-saved"),
        display: window.getComputedStyle(chip).display,
      };
    });
    assert.ok(
      initialChip,
      "save chip [data-design-review-gallery-save-button='true'] must be in the DOM",
    );
    assert.equal(
      initialChip.visible,
      "false",
      "save chip must start hidden (data-design-review-gallery-save-visible=false)",
    );
    assert.equal(
      initialChip.display,
      "none",
      "save chip must start with computed display:none",
    );
    // Trigger a drag-drop to flip dirty.
    await page.evaluate(() => {
      const tiles = Array.from(
        document.querySelectorAll("[data-design-review-gallery-tile]"),
      );
      function ev(type) {
        try {
          return new DragEvent(type, { bubbles: true, cancelable: true });
        } catch {
          return new Event(type, { bubbles: true, cancelable: true });
        }
      }
      tiles[0].dispatchEvent(ev("dragstart"));
      tiles[1].dispatchEvent(ev("dragover"));
      tiles[1].dispatchEvent(ev("drop"));
    });
    await page.waitForTimeout(200);
    const dirtyChip = await page.evaluate(() => {
      const chip = document.querySelector(
        '[data-design-review-gallery-save-button="true"]',
      );
      return {
        visible: chip.getAttribute("data-design-review-gallery-save-visible"),
        saved: chip.getAttribute("data-saved"),
        display: window.getComputedStyle(chip).display,
      };
    });
    assert.equal(
      dirtyChip.visible,
      "true",
      "save chip must surface (data-design-review-gallery-save-visible=true) after drop",
    );
    assert.notEqual(
      dirtyChip.display,
      "none",
      "save chip must be visible (display != none) after drop",
    );
    assert.equal(
      dirtyChip.saved,
      "false",
      "data-saved must be false while the user is still dirty",
    );
    // Click the chip — fires the save action.
    await page.evaluate(() => {
      const chip = document.querySelector(
        '[data-design-review-gallery-save-button="true"]',
      );
      chip.dispatchEvent(new MouseEvent("click", { bubbles: true }));
    });
    await page.waitForTimeout(200);
    // Post-click: overlay's dirty mirror flips back to false AND the
    // chip records the saved-edge with data-saved=true.
    const post = await page.evaluate(() => {
      const overlay = document.querySelector(
        '[data-design-review-gallery-overlay="true"]',
      );
      const chip = document.querySelector(
        '[data-design-review-gallery-save-button="true"]',
      );
      return {
        dirty: overlay?.getAttribute("data-design-review-gallery-dirty"),
        chipVisible: chip?.getAttribute(
          "data-design-review-gallery-save-visible",
        ),
        chipSaved: chip?.getAttribute("data-saved"),
      };
    });
    assert.equal(
      post.dirty,
      "false",
      "data-design-review-gallery-dirty must flip back to false after save",
    );
    assert.equal(
      post.chipVisible,
      "false",
      "save chip must hide (data-design-review-gallery-save-visible=false) after save",
    );
    assert.equal(
      post.chipSaved,
      "true",
      "save chip must show data-saved=true briefly after a successful save",
    );
  } finally {
    await ctx.close();
  }
});
