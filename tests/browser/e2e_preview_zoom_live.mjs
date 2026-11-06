// PSZ-M1 (Preview-Sizing-And-Zoom) browser checks for the web page preview.
// The fixture is the editor's existing "DestinationCard / Default" component
// story, whose document the demo preview hook already supplies. The editor
// renders it into the device frame through the normal srcdoc path, so the test
// needs no product story, no demo-app change and no test-only build.
//
//   * e2e_preview_zoom_capture_equals_scaled_100: a capture of the device
//     frame at 50% equals the 100% capture scaled to half size, within a
//     per-channel mean absolute difference of CHANNEL_TOLERANCE = 8 (0-255)
//     over the whole frame. CHANNEL_TOLERANCE is this test's own bound, chosen
//     here; it is not an editor-wide constant. Checked against the other
//     capture tests: e2e_editor_real_pixel_round_trip_live.mjs compares a
//     16x16 grid with FINGERPRINT_DELTA_MAX = 16, and its
//     NEUTRAL_GREY_TOLERANCE = 8 is a grey-classification threshold, not a
//     frame comparison. The 100% capture must also show real content (a share
//     of pixels that differ from the frame background), so a blank frame
//     cannot pass. The measured per-channel values are printed.
//   * e2e_preview_zoom_url_roundtrip_live: the zoom the reviewer picks is
//     written to the story URL, and a URL carrying it restores it.
//   * e2e_preview_zoom_scrollbars_at_100 (PSZ-AREQ2): at 100% the Desktop frame
//     overflows the preview area in a 1600x960 window, and the area's scroll
//     host shows a vertical and a horizontal scrollbar (gutter > 0 on both
//     axes). In a 1600x1000 window only the horizontal bar shows (the area is
//     920 px tall, so the 900 px frame fits vertically), and the test asserts
//     only that bar there. At Fit the frame fits and both gutters are 0.
//
// Scrollbar browser: Playwright launches headless Chromium with
// `--hide-scrollbars` by default, which makes every scrollbar zero-width (a
// probe on the same overflow:auto box measured a 0 px gutter with the default
// and 15 px / 15 px with it removed). The scrollbar test therefore launches its
// own browser with that default removed (`ignoreDefaultArgs`). The other tests
// keep the default browser, so their pixels are unchanged. The scrollbar test's
// screenshots are taken from that browser, so the bars are in them.
//
// Real stack: the editor build (`just editor-build`), a static server, and
// headless Chromium driving the chrome-bar controls. Nothing is mocked.
//
// Convention: `node --test`, like the other e2e_*_live.mjs files here.
// Run with: repro exec -- bash -lc 'cd tests/browser && node --test e2e_preview_zoom_live.mjs'

import { execSync, spawn } from "node:child_process";
import { existsSync, mkdtempSync, openSync, readFileSync } from "node:fs";
import { tmpdir } from "node:os";
import { dirname, join } from "node:path";
import { fileURLToPath } from "node:url";
import test from "node:test";
import assert from "node:assert/strict";

const __dirname = dirname(fileURLToPath(import.meta.url));
const isonimRoot = join(__dirname, "..", "..");
const editorBuildDir = join(isonimRoot, "build", "editor");
const daemonBinary = join(isonimRoot, "build", "bin", "isonim-review");

const PAGE_PORT = 18661;
// The openPreview wait requires the story's document in the srcdoc iframe; the
// empty-state fallback panel is not accepted. viewport=desktop selects the
// Desktop preset (1440x900) explicitly.
const STORY = "/index.html?view=page&storyGroup=DestinationCard" +
  "&story=" + encodeURIComponent("Default") +
  "&kind=component&index=0&viewport=desktop";
const CHANNEL_TOLERANCE = 8; // mean absolute difference per channel, 0-255
const MIN_CONTENT_FRACTION = 0.01; // share of frame pixels that differ from the background

let pageServer = null;
let serverExitCode = null;
let serverLogPath = "";
let browser = null;
let scrollbarBrowser = null;

function buildEditor() {
  // Run under `repro exec` (see the header): `just` is already on PATH there.
  // The daemon is built here, in the test's own shell, and handed to the
  // editor server by path. Left to the server, it would run a second
  // `repro exec` from inside this one, which re-captures the dev environment
  // and has aborted on this host (glibc malloc assertion in the foreign-env
  // capture), leaving the server with no daemon.
  execSync("just editor-build", { cwd: isonimRoot, stdio: "pipe" });
  execSync("just isonim-review-build", { cwd: isonimRoot, stdio: "pipe" });
  if (!existsSync(join(editorBuildDir, "editor.js"))) {
    throw new Error("editor.js was not produced by `just editor-build`");
  }
  if (!existsSync(daemonBinary)) {
    throw new Error("isonim-review was not produced by `just isonim-review-build`");
  }
}

async function startPageServer() {
  // The server's output goes to a log file, so a failed start can be read.
  const logDir = mkdtempSync(join(tmpdir(), "psz-m1-server-"));
  serverLogPath = join(logDir, "editor_server.log");
  const logFd = openSync(serverLogPath, "w");
  pageServer = spawn(
    "python3",
    [
      join(isonimRoot, "tools", "editor_server.py"),
      "--directory", editorBuildDir,
      "--project-root", join(isonimRoot, "examples", "wanderlust"),
      "--daemon-binary", daemonBinary,
      "--port", String(PAGE_PORT),
      "--bind", "127.0.0.1",
    ],
    { cwd: isonimRoot, stdio: ["ignore", logFd, logFd], detached: true },
  );
  pageServer.on("exit", (code) => {
    serverExitCode = code === null ? "signal" : code;
  });
  // Poll asynchronously. A synchronous poll loop never yields to the event
  // loop, so the child's "exit" event cannot be seen while it runs: the
  // previous loop kept polling a dead server for its whole budget (the
  // 876 s hang). Stop as soon as the process has exited.
  for (let i = 0; i < 120; i++) {
    if (serverExitCode !== null) break;
    try {
      const res = await fetch(`http://127.0.0.1:${PAGE_PORT}/index.html`, {
        signal: AbortSignal.timeout(500),
      });
      if (res.ok) return;
    } catch {
      // Not listening yet.
    }
    await new Promise((resolve) => setTimeout(resolve, 1000));
  }
  const tail = readFileSync(serverLogPath, "utf8").split("\n").slice(-20).join("\n");
  throw new Error(`editor server did not serve on ${PAGE_PORT} ` +
    `(exit: ${serverExitCode}); log tail:\n${tail}`);
}

async function ensureBrowser() {
  if (!browser) {
    const { chromium } = await import("@playwright/test");
    browser = await chromium.launch({
      headless: true,
      executablePath: process.env.PLAYWRIGHT_CHROMIUM_EXECUTABLE || undefined,
    });
  }
  return browser;
}

// PSZ-AREQ2: a headless browser that keeps its scrollbars. See the header.
async function ensureScrollbarBrowser() {
  if (!scrollbarBrowser) {
    const { chromium } = await import("@playwright/test");
    scrollbarBrowser = await chromium.launch({
      headless: true,
      ignoreDefaultArgs: ["--hide-scrollbars"],
      executablePath: process.env.PLAYWRIGHT_CHROMIUM_EXECUTABLE || undefined,
    });
  }
  return scrollbarBrowser;
}

async function openPreview(suffix = "", { viewport = { width: 2200, height: 1300 },
    scrollbars = false } = {}) {
  const b = scrollbars ? await ensureScrollbarBrowser() : await ensureBrowser();
  // The window must leave room for the whole 1440x900 frame inside the preview
  // area at 100%. The capture test asserts that, because an element screenshot
  // of a frame wider than its scroll area shows only the part inside the area's
  // clip: at 1600 px the area is 1020 px wide, and that mismatch measured 51
  // points per channel.
  const ctx = await b.newContext({ viewport });
  const page = await ctx.newPage();
  await page.goto(`http://127.0.0.1:${PAGE_PORT}${STORY}${suffix}`);
  await page.waitForSelector('[data-preview-zoom-cluster="true"]', {
    state: "attached",
    timeout: 15000,
  });
  // Wait for the story's document to render inside the srcdoc iframe. The
  // fallback panel is not an acceptable outcome: it is the empty state, and a
  // capture of it would prove nothing about the frame.
  await page.waitForFunction(() => {
    const f = document.querySelector("[data-page-project-frame]");
    return !!(f && f.contentDocument && f.contentDocument.body &&
      f.contentDocument.body.children.length > 0 &&
      getComputedStyle(f).display !== "none");
  }, null, { timeout: 15000 });
  return { ctx, page };
}

async function readout(page) {
  return page.locator("[data-preview-zoom-level]").textContent();
}

async function clickControl(page, label) {
  await page.locator(`[aria-label="${label}"]`).click();
}

test.before(async () => {
  buildEditor();
  await startPageServer();
});

test.after(async () => {
  try {
    if (browser) await browser.close();
  } catch {}
  try {
    if (scrollbarBrowser) await scrollbarBrowser.close();
  } catch {}
  try {
    if (pageServer) process.kill(-pageServer.pid);
  } catch {}
});

test("e2e_preview_zoom_capture_equals_scaled_100", async () => {
  const { ctx, page } = await openPreview("&zoom=100");
  try {
    assert.equal(await readout(page), "100%");
    const frame = page.locator('[data-preview-zoom-frame="true"]');
    // 100% full-frame size check: the Desktop preset's fixed size (1440x900,
    // the viewport preset in viewmodels.nim) is the frame's real size, and the
    // preview area is large enough to hold it, so the capture is the whole frame.
    const area = await page.locator('[data-page-preview="true"]').evaluate(
      (el) => ({ width: el.clientWidth, height: el.clientHeight }));
    assert.ok(area.width >= 1440 && area.height >= 900,
      `preview area ${area.width}x${area.height} is smaller than the 1440x900 frame`);
    const boxA = await frame.boundingBox();
    assert.equal(boxA.width, 1440, "100% frame width is not the Desktop width");
    assert.equal(boxA.height, 900, "100% frame height is not the Desktop height");
    const pngA = await frame.screenshot();
    // Content check: the 100% capture must show the rendered document, not a
    // blank frame. Count the pixels that differ from the frame's corner colour.
    const contentFraction = await page.evaluate(async (b64) => {
      const img = new Image();
      await new Promise((resolve, reject) => {
        img.onload = resolve;
        img.onerror = reject;
        img.src = "data:image/png;base64," + b64;
      });
      const c = document.createElement("canvas");
      c.width = img.naturalWidth;
      c.height = img.naturalHeight;
      const x = c.getContext("2d", { willReadFrequently: true });
      x.drawImage(img, 0, 0);
      const d = x.getImageData(0, 0, c.width, c.height).data;
      const bg = [d[0], d[1], d[2]];
      let differing = 0;
      for (let i = 0; i < d.length; i += 4) {
        if (d[i] !== bg[0] || d[i + 1] !== bg[1] || d[i + 2] !== bg[2]) differing++;
      }
      return differing / (c.width * c.height);
    }, pngA.toString("base64"));
    assert.ok(contentFraction >= MIN_CONTENT_FRACTION,
      `100% capture has ${(contentFraction * 100).toFixed(2)}% non-background pixels ` +
      `(minimum ${MIN_CONTENT_FRACTION * 100}%): the frame shows no rendered content`);

    await clickControl(page, "Zoom preview out");
    await clickControl(page, "Zoom preview out");
    assert.equal(await readout(page), "50%");
    const boxB = await frame.boundingBox();
    const pngB = await frame.screenshot();

    // Geometry first: the scaled frame is half the size of the 100% frame.
    assert.ok(Math.abs(boxB.width * 2 - boxA.width) <= 2,
      `50% width ${boxB.width} is not half of 100% width ${boxA.width}`);
    assert.ok(Math.abs(boxB.height * 2 - boxA.height) <= 2,
      `50% height ${boxB.height} is not half of 100% height ${boxA.height}`);

    // Pixels: downscale the 100% capture to the 50% capture's size, then
    // compare per channel. The comparison runs in the page so it uses the
    // same canvas stack as the browser that drew both captures.
    const measured = await page.evaluate(async ({ a, b, w, h }) => {
      const load = (b64) => new Promise((resolve, reject) => {
        const img = new Image();
        img.onload = () => resolve(img);
        img.onerror = reject;
        img.src = "data:image/png;base64," + b64;
      });
      const [imgA, imgB] = await Promise.all([load(a), load(b)]);
      const canvasB = document.createElement("canvas");
      canvasB.width = imgB.naturalWidth;
      canvasB.height = imgB.naturalHeight;
      const ctxB = canvasB.getContext("2d", { willReadFrequently: true });
      ctxB.drawImage(imgB, 0, 0);
      const canvasA = document.createElement("canvas");
      canvasA.width = canvasB.width;
      canvasA.height = canvasB.height;
      const ctxA = canvasA.getContext("2d", { willReadFrequently: true });
      ctxA.imageSmoothingEnabled = true;
      ctxA.imageSmoothingQuality = "high";
      ctxA.drawImage(imgA, 0, 0, canvasA.width, canvasA.height);
      const dataA = ctxA.getImageData(0, 0, canvasA.width, canvasA.height).data;
      const dataB = ctxB.getImageData(0, 0, canvasB.width, canvasB.height).data;
      let sum = [0, 0, 0];
      const pixels = canvasA.width * canvasA.height;
      for (let i = 0; i < dataA.length; i += 4) {
        sum[0] += Math.abs(dataA[i] - dataB[i]);
        sum[1] += Math.abs(dataA[i + 1] - dataB[i + 1]);
        sum[2] += Math.abs(dataA[i + 2] - dataB[i + 2]);
      }
      return {
        sizeA: [imgA.naturalWidth, imgA.naturalHeight],
        width: canvasB.width,
        height: canvasB.height,
        meanPerChannel: sum.map((s) => s / pixels),
      };
    }, { a: pngA.toString("base64"), b: pngB.toString("base64") });

    const worst = Math.max(...measured.meanPerChannel);
    // The 100% capture must be the full frame: its pixels are the frame box.
    assert.ok(Math.abs(measured.sizeA[0] - boxA.width) <= 2 &&
      Math.abs(measured.sizeA[1] - boxA.height) <= 2,
      `100% capture is ${measured.sizeA} but the frame box is ${boxA.width}x${boxA.height}`);
    console.log(`PSZ-M1 capture comparison: ${measured.width}x${measured.height}, ` +
      `mean abs diff per channel ${measured.meanPerChannel.map((v) => v.toFixed(2)).join(" / ")}`);
    assert.ok(worst <= CHANNEL_TOLERANCE,
      `50% capture differs from the scaled 100% capture by ${worst.toFixed(2)} ` +
      `per channel (tolerance ${CHANNEL_TOLERANCE})`);
  } finally {
    await ctx.close();
  }
});

test("e2e_preview_zoom_url_roundtrip_live", async () => {
  const { ctx, page } = await openPreview("&zoom=fit");
  try {
    // Fit is the default: the readout is the fitted percentage, never above 100.
    const fitText = await readout(page);
    assert.match(fitText, /^\d+%$/);
    assert.ok(parseInt(fitText, 10) <= 100, `fit readout ${fitText} is above 100%`);

    // Zooming writes the level to the URL.
    await clickControl(page, "Show preview at 100%");
    await page.waitForFunction(() => location.search.includes("zoom=100"),
      null, { timeout: 5000 });
    await clickControl(page, "Zoom preview out");
    await page.waitForFunction(() => location.search.includes("zoom=75"),
      null, { timeout: 5000 });
    assert.equal(await readout(page), "75%");

    // Fit writes "fit" back.
    await clickControl(page, "Fit preview to the area");
    await page.waitForFunction(() => location.search.includes("zoom=fit"),
      null, { timeout: 5000 });

    // A URL carrying a level restores it on load.
    await page.goto(`http://127.0.0.1:${PAGE_PORT}${STORY}&zoom=50`);
    await page.waitForSelector('[data-preview-zoom-cluster="true"]', {
      state: "attached",
      timeout: 15000,
    });
    await page.waitForFunction(() => {
      const el = document.querySelector("[data-preview-zoom-level]");
      return el && el.textContent === "50%";
    }, null, { timeout: 10000 });
  } finally {
    await ctx.close();
  }
});

// PSZ-AREQ2: the preview area's scroll host is the parent of the zoom stage.
// Gutters are the scrollbar widths: offset box minus client box.
async function scrollHostMetrics(page) {
  return page.locator('[data-preview-zoom-stage="true"]').evaluate((stage) => {
    const host = stage.parentElement;
    const style = getComputedStyle(host);
    return {
      hostClass: host.className,
      overflowX: style.overflowX,
      overflowY: style.overflowY,
      vGutter: host.offsetWidth - host.clientWidth,
      hGutter: host.offsetHeight - host.clientHeight,
      hostW: host.clientWidth,
      hostH: host.clientHeight,
      stageW: stage.offsetWidth,
      stageH: stage.offsetHeight,
    };
  });
}

// The preview area is the window minus about 80 px of chrome. At 1600x1000 it is
// 1020x920: the 1440x900 frame overflows horizontally only (measured: the
// horizontal gutter is 10 px, the vertical one 0 px). A vertical bar needs an
// area shorter than 900 px, so both-axes overflow is measured at 1600x960
// (area 1020x880). The 1600x1000 capture is kept for the horizontal bar.
test("e2e_preview_zoom_scrollbars_at_100", async () => {
  const shotsDir = process.env.PSZ_SCROLLBAR_SHOTS_DIR || "";
  const { ctx, page } = await openPreview("&zoom=100", {
    viewport: { width: 1600, height: 960 },
    scrollbars: true,
  });
  try {
    assert.equal(await readout(page), "100%");
    const at100 = await scrollHostMetrics(page);
    console.log(`PSZ-AREQ2 at 100% (1600x960): host ${at100.hostW}x${at100.hostH}, ` +
      `stage ${at100.stageW}x${at100.stageH}, overflow ${at100.overflowX}/${at100.overflowY}, ` +
      `gutters vertical ${at100.vGutter}px horizontal ${at100.hGutter}px`);
    assert.ok(at100.stageW > at100.hostW && at100.stageH > at100.hostH,
      `100% stage ${at100.stageW}x${at100.stageH} does not overflow the ` +
      `${at100.hostW}x${at100.hostH} preview area`);
    assert.equal(at100.overflowX, "auto");
    assert.equal(at100.overflowY, "auto");
    assert.ok(at100.vGutter > 0,
      `vertical scrollbar gutter is ${at100.vGutter}px at 100% (expected > 0)`);
    assert.ok(at100.hGutter > 0,
      `horizontal scrollbar gutter is ${at100.hGutter}px at 100% (expected > 0)`);
    if (shotsDir) {
      await page.locator('[data-preview-zoom-stage="true"]').locator("xpath=..")
        .screenshot({ path: join(shotsDir, "scrollbars-100-desktop-1600x960.png") });
    }
  } finally {
    await ctx.close();
  }

  // The operator's 1600x1000 window: the frame overflows horizontally only.
  const wide = await openPreview("&zoom=100", {
    viewport: { width: 1600, height: 1000 },
    scrollbars: true,
  });
  try {
    assert.equal(await readout(wide.page), "100%");
    const m = await scrollHostMetrics(wide.page);
    console.log(`PSZ-AREQ2 at 100% (1600x1000): host ${m.hostW}x${m.hostH}, ` +
      `gutters vertical ${m.vGutter}px horizontal ${m.hGutter}px`);
    assert.ok(m.hGutter > 0,
      `horizontal scrollbar gutter is ${m.hGutter}px at 100% in 1600x1000 (expected > 0)`);
    if (shotsDir) {
      await wide.page.locator('[data-preview-zoom-stage="true"]').locator("xpath=..")
        .screenshot({ path: join(shotsDir, "scrollbars-100-desktop-1600x1000.png") });
    }
  } finally {
    await wide.ctx.close();
  }

  const fit = await openPreview("&zoom=fit", {
    viewport: { width: 1600, height: 960 },
    scrollbars: true,
  });
  const page2 = fit.page;
  try {
    await clickControl(page2, "Fit preview to the area");
    assert.match(await readout(page2), /^\d+%$/);
    const atFit = await scrollHostMetrics(page2);
    console.log(`PSZ-AREQ2 at Fit (1600x960): host ${atFit.hostW}x${atFit.hostH}, ` +
      `stage ${atFit.stageW}x${atFit.stageH}, ` +
      `gutters vertical ${atFit.vGutter}px horizontal ${atFit.hGutter}px`);
    assert.ok(atFit.stageW <= atFit.hostW && atFit.stageH <= atFit.hostH,
      `Fit stage ${atFit.stageW}x${atFit.stageH} overflows the ` +
      `${atFit.hostW}x${atFit.hostH} preview area`);
    assert.equal(atFit.vGutter, 0, "vertical scrollbar shown while the frame fits");
    assert.equal(atFit.hGutter, 0, "horizontal scrollbar shown while the frame fits");
    if (shotsDir) {
      await page2.locator('[data-preview-zoom-stage="true"]').locator("xpath=..")
        .screenshot({ path: join(shotsDir, "scrollbars-fit-desktop-1600x960.png") });
    }
  } finally {
    await fit.ctx.close();
  }
});
