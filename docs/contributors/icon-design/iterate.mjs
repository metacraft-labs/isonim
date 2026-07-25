// Icon iteration tool.
//
//   node iterate.mjs            # render all icons; full screenshot
//   node iterate.mjs wrench     # zoomed crop of just one icon
//   node iterate.mjs robot
//   node iterate.mjs plus
//
// Reads wrench.svg / robot.svg / plus.svg from this directory and
// substitutes them into preview.html's __WRENCH__ / __ROBOT__ /
// __PLUS__ placeholders. Renders the page in a headless Chromium
// and writes /tmp/icon_preview.png (full) plus /tmp/icon_<name>.png
// (zoom) so the orchestrator can iterate by editing the SVG files
// and re-running.

import { readFileSync, writeFileSync } from "node:fs";
import { fileURLToPath } from "node:url";
import { dirname, join } from "node:path";
import { chromium } from "/Users/zahary/metacraft/isonim/tests/browser/node_modules/playwright/index.mjs";

const __dirname = dirname(fileURLToPath(import.meta.url));
const focus = process.argv[2];

const wrench = readFileSync(join(__dirname, "wrench.svg"), "utf8");
const robot = readFileSync(join(__dirname, "robot.svg"), "utf8");
const plus = readFileSync(join(__dirname, "plus.svg"), "utf8");

let html = readFileSync(join(__dirname, "preview.html"), "utf8");
html = html.replaceAll("__WRENCH__", wrench);
html = html.replaceAll("__ROBOT__", robot);
html = html.replaceAll("__PLUS__", plus);

const tmpHtml = "/tmp/icon_preview_filled.html";
writeFileSync(tmpHtml, html);

const browser = await chromium.launch({ headless: true });
const page = await browser.newPage({ viewport: { width: 980, height: 1100 } });
await page.goto("file://" + tmpHtml, { waitUntil: "load" });
await page.waitForTimeout(150);

await page.screenshot({ path: "/tmp/icon_preview.png", fullPage: true });
console.log("wrote /tmp/icon_preview.png");

if (focus) {
  // Zoom to a single icon's 48px row.
  const idx = { wrench: 0, robot: 1, plus: 2 }[focus];
  if (idx === undefined) {
    console.error(`unknown focus: ${focus}; use one of wrench, robot, plus`);
  } else {
    const cells = await page.$$("h2:nth-of-type(4) ~ .row .cell");
    if (cells[idx]) {
      const box = await cells[idx].boundingBox();
      if (box) {
        const out = `/tmp/icon_${focus}.png`;
        await page.screenshot({
          path: out,
          clip: {
            x: box.x - 8,
            y: box.y - 8,
            width: box.width + 16,
            height: box.height + 16,
          },
        });
        console.log(`wrote ${out}`);
      }
    }
  }
}

await browser.close();
