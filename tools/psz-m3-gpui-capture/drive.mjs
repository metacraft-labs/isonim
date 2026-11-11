// Drives the editor's GPUI page preview inside GuiAssert's headless sway. The
// editor page opens in a headed chromium (Wayland) window that sway shows, and
// this script drives the page's own controls. The Nim capture driver
// (capture_driver.nim) takes the screen between steps; the two sides hand over
// through files in SYNC_DIR:
//   request-<name>  written here, asks for a screen capture named <name>
//   ack-<name>      written by the Nim side once that capture is on disk
//   ready, finished, failed, <state>.json  progress and the measured page state
// Playwright is the one the browser e2e suite installs, found relative to this file.
const { chromium } = await import(
  new URL("../../tests/browser/node_modules/playwright/index.mjs", import.meta.url));
import { writeFileSync, existsSync } from "node:fs";
import { join } from "node:path";

const dir = process.env.SYNC_DIR;
const url = process.env.PSZ_M3_URL;
const executablePath = process.env.CHROMIUM;
const sleep = (ms) => new Promise((r) => setTimeout(r, ms));
const handOver = async (name) => {
  writeFileSync(join(dir, "request-" + name), "");
  const deadline = Date.now() + 300000;
  while (!existsSync(join(dir, "ack-" + name))) {
    if (Date.now() > deadline) throw new Error("no capture for " + name);
    await sleep(200);
  }
};
// Reads the streamed canvas's pixels and returns a digest of them: the
// painted size, the opaque fraction, the number of distinct sampled colours
// and an FNV-1a hash of every byte. Returns null while there is no canvas.
const frameDigest = (page) => page.evaluate(() => {
  const c = document.querySelector('[data-page-preview="true"] canvas');
  if (!c || c.width <= 0 || c.height <= 0) return null;
  const d = c.getContext("2d", { willReadFrequently: true }).getImageData(0, 0, c.width, c.height).data;
  let opaque = 0, h = 0x811c9dc5;
  const colours = new Set();
  for (let i = 0; i < d.length; i += 4) {
    if (d[i + 3] > 0) opaque++;
    if ((i & 0x3fc) === 0) colours.add((d[i] << 16) | (d[i + 1] << 8) | d[i + 2]);
  }
  for (let i = 0; i < d.length; i++) h = Math.imul(h ^ d[i], 0x01000193) >>> 0;
  return { w: c.width, h: c.height, opaqueFraction: opaque / (d.length / 4),
    distinctSampledColours: colours.size, digest: h.toString(16) };
});
// Waits until the streamed frame is the expected size, non-blank and stable.
const waitForFrame = async (page, w, h, timeoutMs) => {
  const deadline = Date.now() + timeoutMs;
  let last = null;
  while (Date.now() < deadline) {
    const f = await frameDigest(page);
    const ok = f && f.w === w && f.h === h && f.opaqueFraction > 0.5 && f.distinctSampledColours >= 3;
    if (ok && last && last.digest === f.digest) return f;
    last = ok ? f : null;
    await sleep(1000);
  }
  throw new Error("no rendered " + w + "x" + h + " frame from the GPUI launcher within " + timeoutMs + " ms");
};
const measure = (page) => page.evaluate(() => {
  const root = document.querySelector('[data-page-preview="true"]');
  const stage = root && root.querySelector('[data-preview-zoom-stage="true"]');
  const wrapper = root && root.querySelector('[data-canvas-wrapper="true"]');
  const canvas = root && root.querySelector("canvas");
  const host = stage && stage.parentElement;
  const readout = document.querySelector("[data-preview-zoom-level]");
  const r = wrapper ? wrapper.getBoundingClientRect() : null;
  return {
    url: location.href,
    areaWidth: host ? host.clientWidth : 0,
    areaHeight: host ? host.clientHeight : 0,
    scale: wrapper ? wrapper.getAttribute("data-preview-zoom-scale") : null,
    transform: wrapper ? getComputedStyle(wrapper).transform : null,
    wrapperStyleWidth: wrapper ? wrapper.style.width : null,
    wrapperStyleHeight: wrapper ? wrapper.style.height : null,
    wrapperRect: r ? { x: r.x, y: r.y, w: r.width, h: r.height } : null,
    canvasWidthAttr: canvas ? canvas.width : null,
    canvasHeightAttr: canvas ? canvas.height : null,
    canvasCssWidth: canvas ? canvas.getBoundingClientRect().width : null,
    canvasCssHeight: canvas ? canvas.getBoundingClientRect().height : null,
    readout: readout ? readout.textContent : null,
    // PSZ-M3 note 21: the frame source the launcher declared (the zoom stage
    // carries it), and the synthetic note: whether it is present, visible, and
    // its text. A real frame has no note.
    frameSource: stage ? stage.getAttribute("data-preview-frame-declared") || null : null,
    frameSourceLabel: (() => {
      const el = root && root.querySelector('[data-preview-frame-source]');
      if (!el) return { present: false, visible: false, text: null };
      const r = el.getBoundingClientRect();
      return { present: true, visible: getComputedStyle(el).display !== "none" && r.height > 0,
        text: el.textContent.trim() };
    })(),
    frame: null,
  };
});

// Captures to take, in order: "fit", "actual" (100% by the zoom control) and
// "actual-wide" (100% from the URL). Each is a shown and a hidden-canvas capture.
const states = (process.env.PSZ_M3_STATES || "fit,actual").split(",");
// The chromium window, "W,H" (the sway output must be at least this big).
const windowSize = process.env.PSZ_M3_WINDOW || "1920,1200";

const browser = await chromium.launch({
  executablePath, headless: false,
  args: ["--ozone-platform=wayland", "--no-sandbox", "--disable-gpu", "--no-first-run",
    `--window-size=${windowSize}`],
});
try {
  const context = await browser.newContext({ viewport: null });
  const page = await context.newPage();
  page.on("pageerror", (e) => console.error("[pageerror]", e.message.slice(0, 300)));
  await page.goto(url, { timeout: 120000 });
  await page.waitForSelector('[data-preview-zoom-stage="true"]', { timeout: 120000 });
  await page.locator('[data-preview-backend="gpui"]').first().click();
  await page.waitForFunction(() => {
    const w = document.querySelector('[data-page-preview="true"] [data-canvas-wrapper="true"]');
    return !!w && w.getAttribute("data-preview-zoom-scale") !== null;
  }, null, { timeout: 120000 });
  // The canvas starts at its 300x150 default, so its size says nothing about
  // the frame. Wait for a rendered frame: the launcher's frame at the page's
  // model size (1440x900), with opaque, non-uniform pixels, unchanged across
  // two polls one second apart.
  await waitForFrame(page, 1440, 900, 120000);
  writeFileSync(join(dir, "ready"), "");

  for (const state of states) {
    if (state.startsWith("actual")) {
      // "actual" is reached by the zoom control; "actual-wide" opens at 100% by URL.
      if (state === "actual") await page.locator('[data-preview-zoom-actual="true"]').first().click();
      await page.waitForFunction(() => {
        const w = document.querySelector('[data-page-preview="true"] [data-canvas-wrapper="true"]');
        return !!w && w.getAttribute("data-preview-zoom-scale") === "1.0";
      }, null, { timeout: 30000 });
      await sleep(1000);
    }
    const measured = await measure(page);
    measured.frame = await waitForFrame(page, 1440, 900, 60000);
    writeFileSync(join(dir, state + ".json"), JSON.stringify(measured, null, 1));
    await handOver(state + "-shown");
    // Hidden: the canvas is invisible and the frame's own background is a colour
    // no frame pixel uses, so the painted box is the whole frame box, border
    // included (a white background would hide the frame's white edge pixels).
    await page.evaluate(() => {
      const w = document.querySelector('[data-page-preview="true"] [data-canvas-wrapper="true"]');
      window.__pszOldBg = w.style.backgroundColor;
      w.style.backgroundColor = "rgb(255, 0, 255)";
      document.querySelector('[data-page-preview="true"] canvas').style.visibility = "hidden";
    });
    await sleep(300);
    await handOver(state + "-hidden");
    await page.evaluate(() => {
      const w = document.querySelector('[data-page-preview="true"] [data-canvas-wrapper="true"]');
      w.style.backgroundColor = window.__pszOldBg;
      document.querySelector('[data-page-preview="true"] canvas').style.visibility = "visible";
    });
    await sleep(300);
  }
  writeFileSync(join(dir, "finished"), "");
} catch (e) {
  console.error("drive: " + e.message);
  writeFileSync(join(dir, "failed"), e.message);
} finally {
  await browser.close();
}
