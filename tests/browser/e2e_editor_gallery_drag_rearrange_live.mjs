// CHRM-M6 Phase D.3 — Playwright e2e: gallery drag-and-drop pipeline
// is wired without errors on the live editor.
//
// IMPORTANT — architectural scope note:
//
// The gallery overlay (gallery_overlay.nim) attaches ``dragover`` and
// ``drop`` listeners to each tile that call ``registerDragMove`` on
// the VM (L731-L736). That call:
//
//   * Appends to (or updates an entry in) ``vm.pendingLayout`` — a
//     Signal[seq[PendingLayoutEntry]].
//   * Flips ``vm.isDirty.val = true``.
//
// NEITHER ``pendingLayout`` NOR ``isDirty`` are surfaced to the DOM
// in the current gallery_overlay.nim (see gallery_overlay.nim L17-19:
// "REV-M7 only delivers view-only behaviour. Drag handlers update
// ``pendingLayout`` but never persist — REV-M8 wires the save path.").
//
// Additionally, the grid only re-renders when ``rows.val`` changes
// (driven by ``tiles.val``); the drop handler never mutates either,
// so the rendered tiles' ``data-design-review-gallery-row`` /
// ``data-design-review-gallery-col`` attributes are STABLE after a
// drop. The VM-level reorder semantics (record + replace by
// captureId) are covered exhaustively by
// ``tests/test_design_review_gallery_drag_rearrange_vm.nim``.
//
// What we CAN verify at the DOM/e2e level:
//
//   1. Tiles are ``draggable="true"`` per their DSL declaration so
//      native HTML5 drag is available.
//   2. Dispatching ``dragstart`` + ``dragover`` + ``drop`` synthetic
//      events on tiles does not raise a page error and the tile DOM
//      stays consistent (count + capture-id attributes unchanged —
//      the documented contract for REV-M7).
//
// The Plan agent's note about a save affordance
// (``data-design-review-isdirty="true"``) was speculative — no such
// attribute exists in gallery_overlay.nim today. Case 3 (save
// affordance) is dropped per the implementer's instruction:
// "if no such affordance exists, drop case 3 and document why".

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
  const captures = [];
  for (let i = 0; i < 6; i++) {
    captures.push({
      storyId: "p/inbox:page#0@web",
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
      `expected ≥2 tiles to assert draggable; got ${draggableInfo.length}`,
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

test("synthetic dragstart + dragover + drop fires without page errors and DOM stays consistent", async () => {
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
      return tiles.map((t) => ({
        captureId: t.getAttribute("data-design-review-gallery-tile"),
        row: t.getAttribute("data-design-review-gallery-row"),
        col: t.getAttribute("data-design-review-gallery-col"),
      }));
    });
    assert.ok(
      before.length >= 2,
      `expected ≥2 tiles for drag scenario; got ${before.length}`,
    );
    // Dispatch a synthetic drag sequence: dragstart on tile A,
    // dragover on tile B (with a constructed DataTransfer for
    // realism), and drop on tile B. The gallery_overlay.nim handlers
    // bind ``dragover`` + ``drop`` to ``registerDragMove`` — the
    // event payload itself is unused beyond the bound captureId,
    // rowIdx, colIdx baked into the closure at render time.
    await page.evaluate(() => {
      const tiles = Array.from(
        document.querySelectorAll("[data-design-review-gallery-tile]"),
      );
      const src = tiles[0];
      const dst = tiles[1];
      // ``DataTransfer`` may not be constructible in every browser
      // context; the gallery's handler closure never reads
      // ``ev.dataTransfer`` so an empty object on a generic Event
      // works just as well. We use the spec-correct
      // ``new DragEvent`` constructor where available and fall back
      // to a plain Event otherwise.
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
    // Tile count must be stable.
    const after = await page.evaluate(() => {
      const tiles = Array.from(
        document.querySelectorAll("[data-design-review-gallery-tile]"),
      );
      return tiles.map((t) => ({
        captureId: t.getAttribute("data-design-review-gallery-tile"),
        row: t.getAttribute("data-design-review-gallery-row"),
        col: t.getAttribute("data-design-review-gallery-col"),
      }));
    });
    assert.equal(
      after.length,
      before.length,
      "tile count must be stable across a drag sequence " +
        `(before=${before.length}, after=${after.length})`,
    );
    // Each tile's captureId persists (no tile destroyed or replaced).
    for (let i = 0; i < before.length; i++) {
      assert.equal(
        after[i].captureId,
        before[i].captureId,
        `tile at index ${i} captureId changed (${before[i].captureId} → ${after[i].captureId})`,
      );
    }
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

test("drop handler does not alter rendered tile row/col attrs (REV-M7 contract: pendingLayout only)", async () => {
  // This case enforces the architectural contract: a drop records
  // intent into ``vm.pendingLayout`` (off-DOM) but does NOT trigger a
  // re-render of the grid. The rendered tiles' position attributes
  // therefore stay where ``groupByPreview`` placed them. If a future
  // milestone wires REV-M8's persistence + reapplication, this test
  // will surface that change and force the assertion to be rewritten
  // alongside the new behaviour.
  const b = await ensureBrowser();
  const ctx = await b.newContext({ viewport: { width: 1440, height: 900 } });
  const page = await ctx.newPage();
  try {
    await openGalleryWithCaptures(page);
    const before = await page.evaluate(() => {
      return Array.from(
        document.querySelectorAll("[data-design-review-gallery-tile]"),
      ).map((t) => ({
        captureId: t.getAttribute("data-design-review-gallery-tile"),
        row: t.getAttribute("data-design-review-gallery-row"),
        col: t.getAttribute("data-design-review-gallery-col"),
      }));
    });
    await page.evaluate(() => {
      const tiles = Array.from(
        document.querySelectorAll("[data-design-review-gallery-tile]"),
      );
      if (tiles.length < 2) return;
      const dst = tiles[1];
      function ev(type) {
        try {
          return new DragEvent(type, { bubbles: true, cancelable: true });
        } catch {
          return new Event(type, { bubbles: true, cancelable: true });
        }
      }
      tiles[0].dispatchEvent(ev("dragstart"));
      dst.dispatchEvent(ev("dragover"));
      dst.dispatchEvent(ev("drop"));
    });
    await page.waitForTimeout(200);
    const after = await page.evaluate(() => {
      return Array.from(
        document.querySelectorAll("[data-design-review-gallery-tile]"),
      ).map((t) => ({
        captureId: t.getAttribute("data-design-review-gallery-tile"),
        row: t.getAttribute("data-design-review-gallery-row"),
        col: t.getAttribute("data-design-review-gallery-col"),
      }));
    });
    assert.equal(after.length, before.length, "tile count stable");
    for (let i = 0; i < before.length; i++) {
      assert.equal(
        after[i].captureId,
        before[i].captureId,
        `tile[${i}] captureId stable`,
      );
      assert.equal(
        after[i].row,
        before[i].row,
        `tile[${i}] data-design-review-gallery-row must be unchanged ` +
          `(REV-M7 contract: drop records pendingLayout but does not re-render)`,
      );
      assert.equal(
        after[i].col,
        before[i].col,
        `tile[${i}] data-design-review-gallery-col must be unchanged ` +
          `(REV-M7 contract: drop records pendingLayout but does not re-render)`,
      );
    }
  } finally {
    await ctx.close();
  }
});
