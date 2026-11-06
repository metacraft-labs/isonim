// PSZ-M3 (Preview-Sizing-And-Zoom) TUI cell viewport, in a headless browser.
//
// The named test is test_tui_cells_viewport_zoom. Its model-level half is in
// tests/test_editor_preview_streamed_zoom.nim. This file checks the rendered
// half against a real terminal:
//
//   * the 80x24 frame is the cell grid at the browser's measured column width
//     plus the 1 px border on each side (spec "Cell frame (TUI)"). This file
//     measures that column width in the page, the way the page does, and checks
//     the DOM frame against it within 1 px. The model's frame is the same value
//     (EditorVM.previewCellWidth), and the frame's style width is checked against
//     the DOM's own width, so a 5 px disagreement fails;
//   * the terminal draws 80 columns and 24 rows, and no glyph runs past the
//     frame's border (measured per text node, not per row box);
//   * at Fit the frame is scaled to the preview area by min(1, area/frame);
//   * at 100% the frame is drawn at its real size, with no transform, and the
//     terminal's own screen is the measured grid within 1 px.
//
// Story. The served catalog (examples/wanderlust, which the editor build
// compiles in) has no story the TUI launcher renders. The launcher mounts the
// task_app demo and only knows task_app story ids ("Task App / Pages / Inbox",
// ...); for any other id it logs `unknown task_app storyId` and shows its Inbox
// defaults. So the terminal content checked here is the launcher's rendered
// task demo, not the story the page names. That is recorded in the milestone
// (PSZ-M3, e2e_tui_cells_viewport_zoom) rather than asserted away.
//
// Real stack: the editor build, the editor server (psz_live_harness.mjs),
// the isonim-examples TUI launcher (`isonim-examples-tui-term`, built from the
// isonim-examples sources; its path is PSZ_M3_TUI_LAUNCHER) and headless
// Chromium. Nothing is mocked.
//
// The one piece this file adds is a same-origin proxy. The editor reaches the
// TUI launcher at ``ws://<page host>/tui-bridge``; the editor server here does
// not proxy that path, so this file forwards the page to the editor server and
// the WebSocket upgrade of ``/tui-bridge`` to the launcher's port. Nothing in
// the editor is changed to make this work.
//
// Run with:
//   repro exec -- bash -lc 'export PLAYWRIGHT_CHROMIUM_EXECUTABLE="$(command -v chromium)"; export PSZ_M3_TUI_LAUNCHER=<path>; cd tests/browser && PSZ_M3_CAPTURE_DIR=<dir> node --test e2e_tui_cells_viewport_zoom_live.mjs'

import { spawn } from "node:child_process";
import http from "node:http";
import net from "node:net";
import { existsSync, mkdirSync } from "node:fs";
import { join } from "node:path";
import test from "node:test";
import assert from "node:assert/strict";
import {
  buildEditor,
  closeBrowser,
  ensureBrowser,
  startPageServer,
  stopPageServer,
} from "./psz_live_harness.mjs";

const EDITOR_PORT = 18664;
const PROXY_PORT = 18665;
const LAUNCHER_PORT = 18666;
const LAUNCHER = process.env.PSZ_M3_TUI_LAUNCHER || "";
const CAPTURE_DIR = process.env.PSZ_M3_CAPTURE_DIR || "";
// The TUI 80x24 viewport on a page story. The streamed page preview takes its
// canvas path only for a page story (page_preview.nim, ``useCanvas``), so this
// is the example project's "Pages / Trip Planner" page story
// (examples/wanderlust/stories.nim), not the DestinationCard component the web
// tests use. See the header for why the launcher does not render this story.
const STORY = "/index.html?view=page&storyGroup=Pages" +
  "&story=" + encodeURIComponent("Trip Planner") +
  "&kind=page&index=0&viewport=tui-80x24";
const COLS = 80;
const FRAME_H = 396; // 24 rows * 1.18 em * 14 px, rounded (the model's height)
const GRID_H = 384; // the 24 rows xterm draws inside the frame (spec: 675x384)
const CONTENT = "Buy groceries"; // a row of the launcher's Inbox defaults
const BORDER = 1; // the wrapper's border on each side (canvas_mount.nim)

// The column width xterm draws at, measured the way the page measures it
// (``ttyCellWidthPx`` in streaming_preview.nim: 32 "W" glyphs, offsetWidth / 32).
// The test measures it itself so the expected frame is not hard-coded.
function measureColumnWidth(page) {
  return page.evaluate(() => {
    const s = document.createElement("span");
    s.style.position = "absolute";
    s.style.visibility = "hidden";
    s.style.whiteSpace = "pre";
    s.style.fontKerning = "none";
    s.style.fontFamily = "ui-monospace, SFMono-Regular, Menlo, monospace";
    s.style.fontSize = "14px";
    s.textContent = "W".repeat(32);
    document.body.appendChild(s);
    const w = s.offsetWidth / 32;
    document.body.removeChild(s);
    return w;
  });
}

// The right edge of the rightmost glyph run in the terminal, and the frame's
// right edge. Each text node is measured on its own: a row box can be wider
// than its glyphs, so the per-node rectangles are the ones that show overflow.
function glyphEdges(page) {
  return page.evaluate(() => {
    const root = document.querySelector('[data-page-preview="true"]');
    const rows = root && root.querySelector(".xterm-rows");
    const frame = root && root.querySelector('[data-canvas-wrapper="true"]');
    if (!rows || !frame) return null;
    const range = document.createRange();
    const walker = document.createTreeWalker(rows, NodeFilter.SHOW_TEXT);
    let glyphRight = -Infinity;
    for (let n = walker.nextNode(); n; n = walker.nextNode()) {
      if (!n.textContent.trim()) continue;
      range.selectNodeContents(n);
      for (const r of range.getClientRects()) {
        if (r.width > 0) glyphRight = Math.max(glyphRight, r.right);
      }
    }
    return { glyphRight, frameRight: frame.getBoundingClientRect().right };
  });
}

let proxy = null;
let launcher = null;

function startProxy() {
  const server = http.createServer((req, res) => {
    const up = http.request({
      host: "127.0.0.1", port: EDITOR_PORT, path: req.url,
      method: req.method, headers: req.headers,
    }, (ures) => {
      res.writeHead(ures.statusCode, ures.headers);
      ures.pipe(res);
    });
    up.on("error", () => { res.statusCode = 502; res.end(); });
    req.pipe(up);
  });
  server.on("upgrade", (req, socket, head) => {
    if (!req.url.startsWith("/tui-bridge")) { socket.destroy(); return; }
    const up = net.connect(LAUNCHER_PORT, "127.0.0.1", () => {
      let text = "GET / HTTP/1.1\r\n";
      for (let i = 0; i < req.rawHeaders.length; i += 2) {
        text += `${req.rawHeaders[i]}: ${req.rawHeaders[i + 1]}\r\n`;
      }
      up.write(text + "\r\n");
      if (head && head.length) up.write(head);
      socket.pipe(up).pipe(socket);
    });
    up.on("error", () => socket.destroy());
    socket.on("error", () => up.destroy());
  });
  return new Promise((resolve) =>
    server.listen(PROXY_PORT, "127.0.0.1", () => resolve(server)));
}

async function waitForPort(port, timeoutMs) {
  const deadline = Date.now() + timeoutMs;
  while (Date.now() < deadline) {
    const ok = await new Promise((resolve) => {
      const s = net.connect(port, "127.0.0.1", () => { s.destroy(); resolve(true); });
      s.on("error", () => resolve(false));
    });
    if (ok) return;
    await new Promise((r) => setTimeout(r, 300));
  }
  throw new Error(`port ${port} did not open within ${timeoutMs} ms`);
}

async function startLauncher() {
  launcher = spawn(LAUNCHER, [
    "--port", String(LAUNCHER_PORT), "--demo", "task",
    "--cols", "80", "--rows", "24",
  ], { stdio: ["ignore", "pipe", "pipe"] });
  launcher.stdout.on("data", (b) => process.stderr.write(`[tui-term] ${b}`));
  launcher.stderr.on("data", (b) => process.stderr.write(`[tui-term] ${b}`));
  await waitForPort(LAUNCHER_PORT, 20000);
}

// Measures what the reviewer sees in the page preview.
function readPreview(page) {
  return page.evaluate((content) => {
    const root = document.querySelector('[data-page-preview="true"]');
    const stage = root && root.querySelector('[data-preview-zoom-stage="true"]');
    const wrapper = root && root.querySelector('[data-canvas-wrapper="true"]');
    const host = stage && stage.parentElement;
    const screen = root && root.querySelector(".xterm-screen");
    const readout = document.querySelector("[data-preview-zoom-level]");
    const rows = root ? root.querySelectorAll(".xterm-rows > div").length : 0;
    const text = root ? root.textContent : "";
    return {
      frameWidth: wrapper ? wrapper.style.width : null,
      frameHeight: wrapper ? wrapper.style.height : null,
      // The DOM's own size of the frame, untransformed: the layout box.
      frameOffsetWidth: wrapper ? wrapper.offsetWidth : 0,
      frameOffsetHeight: wrapper ? wrapper.offsetHeight : 0,
      hasContent: text.includes(content),
      transform: wrapper ? getComputedStyle(wrapper).transform : null,
      scale: wrapper ? wrapper.getAttribute("data-preview-zoom-scale") : null,
      areaWidth: host ? host.clientWidth : 0,
      areaHeight: host ? host.clientHeight : 0,
      screenWidth: screen ? screen.getBoundingClientRect().width : 0,
      screenHeight: screen ? screen.getBoundingClientRect().height : 0,
      rows,
      readout: readout ? readout.textContent : null,
    };
  }, CONTENT);
}

test.before(async () => {
  if (!LAUNCHER || !existsSync(LAUNCHER)) {
    throw new Error("PSZ_M3_TUI_LAUNCHER must name the built isonim-examples-tui-term binary");
  }
  buildEditor();
  await startPageServer(EDITOR_PORT);
  proxy = await startProxy();
  await startLauncher();
});

test.after(async () => {
  await closeBrowser();
  stopPageServer();
  if (proxy) proxy.close();
  if (launcher) launcher.kill("SIGTERM");
});

// Opens the page story on the TUI backend in a window of the given size, and
// waits until the terminal has painted its grid.
async function openTuiPage(width, height) {
  const b = await ensureBrowser();
  const ctx = await b.newContext({ viewport: { width, height } });
  const page = await ctx.newPage();
  page.on("pageerror", (e) => process.stderr.write(`[pageerror] ${e.message}\n`));
  await page.goto(`http://127.0.0.1:${PROXY_PORT}${STORY}&zoom=fit`);
  await page.waitForSelector('[data-preview-zoom-cluster="true"]', { state: "attached", timeout: 15000 });
  await page.locator('[data-preview-backend="tui"]').click();
  try {
    await page.waitForFunction(() => {
      const root = document.querySelector('[data-page-preview="true"]');
      const screen = root && root.querySelector(".xterm-screen");
      return !!screen && screen.getBoundingClientRect().width > 0 &&
        root.querySelectorAll(".xterm-rows > div").length > 0 &&
        root.textContent.includes("Buy groceries");
    }, null, { timeout: 30000 });
  } catch (err) {
    const state = await page.evaluate(() => {
      const root = document.querySelector('[data-page-preview="true"]');
      const host = root && root.querySelector('[data-tui-terminal="true"]');
      return { host: !!host, xterm: root ? root.querySelectorAll(".xterm").length : -1 };
    });
    console.log("[tui diagnostics]", JSON.stringify(state));
    await ctx.close();
    throw err;
  }
  return { ctx, page };
}

test("e2e_tui_cells_viewport_zoom", async () => {
  // Wide window: the preview area is larger than the 80x24 frame.
  const wide = await openTuiPage(2200, 1300);
  try {
    // Fit (the default): the frame is the grid, scaled to the area.
    const cw = await measureColumnWidth(wide.page);
    const grid = Math.round(COLS * cw);
    const expectedFrameW = grid + 2 * BORDER;
    console.log("[tui column width]", cw, "grid", grid, "frame", expectedFrameW);
    const fit = await readPreview(wide.page);
    console.log("[tui fit wide]", JSON.stringify(fit));
    // The model's frame (the style the page wrote) is the DOM's frame, exactly.
    assert.ok(Math.abs(parseFloat(fit.frameWidth) - fit.frameOffsetWidth) <= 1,
      `the frame's style width ${fit.frameWidth} must be the DOM frame ${fit.frameOffsetWidth} px`);
    // And the frame is the measured grid plus its border, within 1 px.
    assert.ok(Math.abs(fit.frameOffsetWidth - expectedFrameW) <= 1,
      `the cell frame must be ${expectedFrameW} px (${COLS} columns at ${cw.toFixed(4)} px, plus borders), got ${fit.frameOffsetWidth}`);
    assert.equal(fit.frameHeight, `${FRAME_H}px`, "the cell frame is 396 px tall");
    assert.equal(fit.frameOffsetHeight, FRAME_H, "the cell frame's DOM height is 396 px");
    assert.equal(fit.rows, 24, "the terminal draws 24 rows");
    assert.ok(fit.hasContent, `the terminal shows the launcher's rendered rows ("${CONTENT}")`);
    const expected = Math.min(1, fit.areaWidth / parseFloat(fit.frameWidth),
      fit.areaHeight / parseFloat(fit.frameHeight));
    assert.ok(Math.abs(Number(fit.scale) - expected) < 0.005,
      `Fit scale ${fit.scale} should be min(1, area/frame) = ${expected.toFixed(4)}`);
    if (CAPTURE_DIR) {
      mkdirSync(CAPTURE_DIR, { recursive: true });
      await wide.page.screenshot({ path: join(CAPTURE_DIR, "tui-80x24-fit-wide.png") });
    }

    // 100%: no transform, the terminal's own screen at the grid's real size.
    await wide.page.locator('[data-preview-zoom-actual="true"]').click();
    await wide.page.waitForFunction(() => {
      const w = document.querySelector('[data-page-preview="true"] [data-canvas-wrapper="true"]');
      return !!w && w.getAttribute("data-preview-zoom-scale") === "1.0";
    }, null, { timeout: 5000 });
    const real = await readPreview(wide.page);
    console.log("[tui 100%]", JSON.stringify(real));
    assert.equal(real.transform, "none", "100% sets no transform");
    // The frame is the grid plus the wrapper's border on each side: at 100% the
    // terminal's screen is the frame less those borders, and that is the grid.
    assert.ok(Math.abs(real.screenWidth - (real.frameOffsetWidth - 2 * BORDER)) <= 1,
      `terminal screen ${real.screenWidth} px wide should be the frame ${real.frameOffsetWidth} less its borders`);
    assert.ok(Math.abs(real.screenWidth - grid) <= 1,
      `terminal screen ${real.screenWidth} px wide should be the measured grid ${grid} px`);
    assert.ok(Math.abs(real.screenHeight - GRID_H) <= 1,
      `terminal screen ${real.screenHeight} px tall should be the ${GRID_H} px grid`);
    if (CAPTURE_DIR) {
      await wide.page.screenshot({ path: join(CAPTURE_DIR, "tui-80x24-100.png") });
    }
  } finally {
    await wide.ctx.close();
  }

  // Narrow window: the area is smaller than the grid, so Fit must scale it.
  const narrow = await openTuiPage(1100, 800);
  try {
    const fit = await readPreview(narrow.page);
    console.log("[tui fit narrow]", JSON.stringify(fit));
    const expected = Math.min(1, fit.areaWidth / parseFloat(fit.frameWidth),
      fit.areaHeight / parseFloat(fit.frameHeight));
    assert.ok(expected < 1, "the narrow area is smaller than the 80x24 grid");
    assert.ok(Math.abs(Number(fit.scale) - expected) < 0.005,
      `Fit scale ${fit.scale} should be ${expected.toFixed(4)} in a ${fit.areaWidth}x${fit.areaHeight} area`);
    const narrowCw = await measureColumnWidth(narrow.page);
    const narrowFrameW = Math.round(COLS * narrowCw) + 2 * BORDER;
    assert.ok(Math.abs(parseFloat(fit.frameWidth) - fit.frameOffsetWidth) <= 1,
      `the frame's style width ${fit.frameWidth} must be the DOM frame ${fit.frameOffsetWidth} px`);
    assert.ok(Math.abs(fit.frameOffsetWidth - narrowFrameW) <= 1,
      `the grid keeps its ${narrowFrameW} px size under Fit, got ${fit.frameOffsetWidth}`);
    assert.equal(fit.readout, `${Math.round(expected * 100)}%`,
      "the zoom readout shows the Fit scale of the grid, not the cell count");
    const stageWidth = await narrow.page.evaluate(() => {
      const s = document.querySelector('[data-page-preview="true"] [data-preview-zoom-stage="true"]');
      return s ? s.getBoundingClientRect().width : 0;
    });
    assert.ok(stageWidth <= fit.areaWidth + 1, "the scaled frame fits the area");
    // The whole grid is inside the frame box: the terminal's rendered screen
    // (what the cells draw into) must not run past the frame's right or bottom
    // edge. Both rects are measured after the scale transform.
    const edges = await narrow.page.evaluate(() => {
      const root = document.querySelector('[data-page-preview="true"]');
      const frame = root && root.querySelector('[data-canvas-wrapper="true"]');
      const screen = root && root.querySelector(".xterm-screen");
      const f = frame ? frame.getBoundingClientRect() : null;
      const s = screen ? screen.getBoundingClientRect() : null;
      return f && s ? { frameRight: f.right, frameBottom: f.bottom,
        screenRight: s.right, screenBottom: s.bottom } : null;
    });
    assert.ok(edges, "the frame and the terminal screen are measured");
    console.log("[tui fit narrow edges]", JSON.stringify(edges));
    assert.ok(edges.screenRight <= edges.frameRight + 0.5,
      `terminal right edge ${edges.screenRight} must be inside the frame's ${edges.frameRight}`);
    assert.ok(edges.screenBottom <= edges.frameBottom + 0.5,
      `terminal bottom edge ${edges.screenBottom} must be inside the frame's ${edges.frameBottom}`);
    // Glyph level: the rightmost text must sit inside the frame's border, not
    // only the terminal's box. The last column's glyphs end before the border.
    const glyphs = await glyphEdges(narrow.page);
    assert.ok(glyphs, "the glyph runs and the frame are measured");
    console.log("[tui fit narrow glyphs]", JSON.stringify(glyphs));
    assert.ok(glyphs.glyphRight <= glyphs.frameRight - BORDER + 0.5,
      `the rightmost glyph ${glyphs.glyphRight} must be inside the frame's border (frame right ${glyphs.frameRight})`);
    // The readout is fully visible in the chrome bar's visible box: the bar
    // scrolls, so the readout's right edge must sit inside the bar's right edge.
    const readoutBox = await narrow.page.evaluate(() => {
      const ro = document.querySelector("[data-preview-zoom-level]");
      const bar = document.querySelector("[data-preview-chrome-bar]");
      if (!ro || !bar) return null;
      const r = ro.getBoundingClientRect();
      const b = bar.getBoundingClientRect();
      return { left: r.left, right: r.right, barRight: b.right, barLeft: b.left };
    });
    assert.ok(readoutBox, "the readout and the chrome bar are measured");
    console.log("[tui fit narrow readout]", JSON.stringify(readoutBox));
    assert.ok(readoutBox.left >= readoutBox.barLeft && readoutBox.right <= readoutBox.barRight,
      `the zoom readout ${readoutBox.left}..${readoutBox.right} must be visible in the bar ${readoutBox.barLeft}..${readoutBox.barRight}`);
    // The zoom trough is opaque and sticky at the bar's trailing edge. In this
    // narrow chrome the bar overflows, so the viewport cluster must shrink to
    // stay clear of it: the size label truncates (ellipsis, to nothing at this
    // width) and the overflow chevron, the one control that names the size and
    // opens the list, must end before the trough begins.
    const label = await narrow.page.evaluate(() => {
      const l = document.querySelector("[data-preview-viewport-current]");
      const c = document.querySelector("[data-preview-viewport-overflow]");
      const t = document.querySelector('[data-preview-zoom-cluster="true"]');
      if (!l || !c || !t) return null;
      const lr = l.getBoundingClientRect();
      const cr = c.getBoundingClientRect();
      const tr = t.getBoundingClientRect();
      return { shown: getComputedStyle(l).display !== "none", labelRight: lr.right,
        chevronLeft: cr.left, chevronRight: cr.right, troughLeft: tr.left,
        text: l.textContent, scrollWidth: l.scrollWidth, clientWidth: l.clientWidth };
    });
    console.log("[tui fit narrow label]", JSON.stringify(label));
    assert.ok(label && label.shown, "the viewport label is shown in the narrow chrome");
    assert.ok(label.labelRight <= label.troughLeft + 0.5,
      `the viewport label ends at ${label.labelRight}, under the zoom trough at ${label.troughLeft}`);
    assert.ok(label.chevronRight <= label.troughLeft + 0.5,
      `the viewport chevron ends at ${label.chevronRight}, under the zoom trough at ${label.troughLeft}`);
    if (CAPTURE_DIR) {
      await narrow.page.screenshot({ path: join(CAPTURE_DIR, "tui-80x24-fit-narrow.png") });
    }
  } finally {
    await narrow.ctx.close();
  }
});
