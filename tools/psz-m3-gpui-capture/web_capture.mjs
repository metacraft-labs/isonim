// PSZ-M3 note 18: the web equivalent of capture.sh. It captures the editor's
// web page preview of Pages / Trip Planner in the three states the GPUI capture
// uses (Fit, 100% by the zoom control, and 100% opened by the URL in a wide
// window), with headless Chromium, no sway.
//
// For each state it writes three files into PSZ_M3_WEB_FRAMES:
//   web-<state>-page.png   the whole window
//   web-<state>-frame.png  the frame as the reader sees it: the device stage
//                          clipped to the preview's scroll port
//   web-<state>.json       the measured page: the stage, the scroll port, the
//                          visible frame (their intersection) and the readout
//
// The frame crop is the visible part of the stage, not the stage's box. At 100%
// the stage is 1440 px wide and the preview area is narrower: the area clips the
// stage, and the part past the area is the editor's AI panel. A crop of the
// stage's full box shows that panel as if it were the frame, so the crop uses
// the scroll port's box (its padding box, without the scrollbars).
//
// The GPUI capture (capture.sh, drive.mjs) hands over through sway and a
// capture driver; this script needs only the editor server and chromium. Start
// the server as README.md says, then:
//   PSZ_M3_WEB_FRAMES=<empty dir> CHROMIUM=$(command -v chromium) \
//     node tools/psz-m3-gpui-capture/web_capture.mjs
// Playwright is the one the browser e2e suite installs, found relative to this file.
const { chromium } = await import(
  new URL("../../tests/browser/node_modules/playwright/index.mjs", import.meta.url));
import { existsSync, mkdirSync, readdirSync, writeFileSync } from "node:fs";
import { join } from "node:path";

const outDir = process.env.PSZ_M3_WEB_FRAMES;
const base = process.env.PSZ_M3_WEB_BASE ||
  "http://127.0.0.1:18691/index.html?view=page&storyGroup=Pages&story=Trip%20Planner&kind=page&index=0&viewport=desktop";
const executablePath = process.env.CHROMIUM;
if (!outDir) throw new Error("set PSZ_M3_WEB_FRAMES to an output directory");
if (!executablePath) throw new Error("set CHROMIUM to a chromium binary");
if (existsSync(outDir) && readdirSync(outDir).length > 0) {
  throw new Error(`${outDir} is not empty`);
}
mkdirSync(outDir, { recursive: true });

const states = [
  { name: "fit", url: base + "&zoom=fit", size: [1920, 1200] },
  { name: "actual", url: base + "&zoom=fit", size: [1920, 1200], clickActual: true },
  { name: "actual-wide", url: base + "&zoom=100", size: [2550, 900] },
];

// Measures the stage, its scroll port and the visible frame, in CSS px of the
// viewport. The scroll port is the stage's nearest `.editor-preview-scroll`
// ancestor: its padding box, without the scrollbars.
const measure = () => {
  const stage = document.querySelector('[data-preview-zoom-stage="true"]');
  const host = stage && stage.closest(".editor-preview-scroll");
  const readout = document.querySelector("[data-preview-zoom-level]");
  const rect = (r) => ({ x: r.x, y: r.y, w: r.width, h: r.height });
  const sr = stage.getBoundingClientRect();
  const hr = host.getBoundingClientRect();
  const port = {
    x: hr.x + host.clientLeft,
    y: hr.y + host.clientTop,
    w: host.clientWidth,
    h: host.clientHeight,
  };
  const x0 = Math.max(sr.x, port.x);
  const y0 = Math.max(sr.y, port.y);
  const x1 = Math.min(sr.x + sr.width, port.x + port.w);
  const y1 = Math.min(sr.y + sr.height, port.y + port.h);
  const visible = { x: x0, y: y0, w: Math.max(0, x1 - x0), h: Math.max(0, y1 - y0) };
  return {
    url: location.href,
    readout: readout ? readout.textContent : null,
    stage: rect(sr),
    scrollPort: port,
    scrollOverflow: getComputedStyle(host).overflow,
    visible,
    stageClipped: visible.w < sr.width || visible.h < sr.height,
    layers: (document.body.innerText.match(/Nothing to show[^\n]*/) || [null])[0],
    // The source the page declares for streamed frames. The web preview has none,
    // so this is "" there (sidecar.py records "none"); it is read, not assumed.
    frameSource: stage.getAttribute("data-preview-frame-declared"),
  };
};

const browser = await chromium.launch({
  executablePath,
  headless: true,
  args: ["--no-sandbox", "--disable-gpu"],
});
try {
  for (const s of states) {
    const page = await browser.newPage({
      viewport: { width: s.size[0], height: s.size[1] },
    });
    await page.goto(s.url, { timeout: 120000 });
    await page.waitForSelector('[data-preview-zoom-stage="true"]', { timeout: 120000 });
    await page.waitForFunction(() => {
      const f = document.querySelector('[data-page-project-frame="true"]');
      return !!(f && f.contentDocument && f.contentDocument.body &&
        f.contentDocument.body.children.length > 0);
    }, null, { timeout: 120000 });
    await page.waitForTimeout(1500);
    if (s.clickActual) {
      await page.locator('[data-preview-zoom-actual="true"]').first().click();
      await page.waitForTimeout(1200);
    }
    const info = await page.evaluate(measure);
    await page.screenshot({ path: join(outDir, `web-${s.name}-page.png`) });
    const v = info.visible;
    if (v.w > 0 && v.h > 0) {
      await page.screenshot({
        path: join(outDir, `web-${s.name}-frame.png`),
        clip: { x: v.x, y: v.y, width: v.w, height: v.h },
      });
    }
    info.state = s.name;
    info.viewport = s.size;
    writeFileSync(join(outDir, `web-${s.name}.json`), JSON.stringify(info, null, 1));
    console.log(`${s.name}: stage ${info.stage.w}x${info.stage.h}, visible ${v.w}x${v.h}, readout ${info.readout}`);
    await page.close();
  }
} finally {
  await browser.close();
}
