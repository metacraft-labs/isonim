// Phase H — Right-sidebar visual capture utility.
//
// Usage:
//   node capture_sidebar.mjs <output.png> [--no-select]
//
// Captures a clip of the right-hand inspector sidebar at 1920x1080.
// By default tries to perform a selection so the property rows render;
// pass --no-select to capture the empty state.

import { dirname, join } from "node:path";
import { fileURLToPath } from "node:url";

const __dirname = dirname(fileURLToPath(import.meta.url));

const args = process.argv.slice(2);
const outPath = args[0] || "/tmp/sidebar_capture.png";
const doSelect = !args.includes("--no-select");
const TARGET_URL = process.env.SIDEBAR_URL || "http://127.0.0.1:8091/";

const m = await import("playwright");
const browser = await m.chromium.launch({ headless: true });

try {
  const ctx = await browser.newContext({
    viewport: { width: 1920, height: 1080 },
    deviceScaleFactor: 2,
  });
  const page = await ctx.newPage();
  await page.goto(TARGET_URL, { waitUntil: "networkidle", timeout: 30000 });

  // Wait for the inspector panel to mount.
  await page.waitForSelector('[data-test-id="property-panel"]', {
    timeout: 15000,
  });
  await page.waitForSelector('[data-inspector-section-body="position"]', {
    timeout: 15000,
  });

  // Best-effort selection: click into the preview iframe so the
  // selection-driven property rows have something to render. The
  // editor-build app boots into a story by default.
  if (doSelect) {
    try {
      const iframe =
        page.frame({ url: /.*preview.*/i }) ||
        page.frames().find((f) => f !== page.mainFrame());
      if (iframe) {
        const target = await iframe.$("body *");
        if (target) await target.click({ force: true });
      } else {
        // Fallback: click anywhere in the preview area.
        const previewEl = await page.$(
          '[data-test-id="preview-frame"], iframe',
        );
        if (previewEl) {
          const box = await previewEl.boundingBox();
          if (box) {
            await page.mouse.click(
              box.x + box.width / 2,
              box.y + box.height / 2,
            );
          }
        }
      }
    } catch (e) {
      console.warn("selection attempt failed:", e.message);
    }
    await page.waitForTimeout(500);
  }

  // Locate the inspector panel bounding box.
  const panel = await page.$('[data-test-id="property-panel"]');
  if (!panel) {
    throw new Error("property-panel not found");
  }
  const box = await panel.boundingBox();
  if (!box) {
    throw new Error("property-panel has no bounding box");
  }
  console.log("inspector bbox:", JSON.stringify(box));

  await page.screenshot({
    path: outPath,
    clip: {
      x: Math.max(0, Math.floor(box.x) - 2),
      y: Math.max(0, Math.floor(box.y) - 2),
      width: Math.ceil(box.width) + 4,
      height: Math.min(1054, Math.ceil(box.height) + 4),
    },
  });
  console.log("wrote", outPath);
} finally {
  await browser.close();
}
