// Brand-icon iteration tool. Mirrors iterate.mjs's pattern but for
// the backend brand silhouettes (GPUI/Zed, Freya, Android Bugdroid)
// alongside the generic Web/TUI/Cocoa/iOS icons we already have in
// the in-house IconSet. Run:
//
//   node iterate_brands.mjs
//
// then read /tmp/icon_brands_preview.png to see how they look.

import { readFileSync, writeFileSync } from "node:fs";
import { fileURLToPath } from "node:url";
import { dirname, join } from "node:path";
import { chromium } from "/Users/zahary/metacraft/isonim/tests/browser/node_modules/playwright/index.mjs";

const __dirname = dirname(fileURLToPath(import.meta.url));

// Brand silhouettes — our own creation.
const zed = readFileSync(join(__dirname, "zed.svg"), "utf8");
const freya = readFileSync(join(__dirname, "freya.svg"), "utf8");
const bugdroid = readFileSync(join(__dirname, "bugdroid.svg"), "utf8");

// Generic Lucide icons for the non-branded backends (web=globe,
// tui=terminal, cocoa/ios=apple/smartphone). Reused verbatim from
// what the in-house IconSet expansion now ships.
const web = `<svg xmlns="http://www.w3.org/2000/svg" viewBox="0 0 24 24" width="100%" height="100%" fill="none" stroke="currentColor" stroke-width="1.75" stroke-linecap="round" stroke-linejoin="round"><circle cx="12" cy="12" r="9"/><path d="M3 12h18"/><path d="M12 3a14 14 0 0 1 0 18 14 14 0 0 1 0-18"/></svg>`;
const tui = `<svg xmlns="http://www.w3.org/2000/svg" viewBox="0 0 24 24" width="100%" height="100%" fill="none" stroke="currentColor" stroke-width="1.75" stroke-linecap="round" stroke-linejoin="round"><path d="M4 17l5-5-5-5"/><path d="M12 19h8"/></svg>`;
const apple = `<svg xmlns="http://www.w3.org/2000/svg" viewBox="0 0 24 24" width="100%" height="100%" fill="currentColor"><path d="M16.5 12.5c0-2.4 2-3.5 2-3.5-1.1-1.6-2.8-1.8-3.4-1.9-1.5-.1-2.8.9-3.5.9-.7 0-1.8-.9-3-.9-1.5 0-2.9.9-3.7 2.3-1.6 2.7-.4 6.8 1.1 9 .7 1.1 1.6 2.3 2.7 2.2 1.1 0 1.5-.7 2.8-.7s1.7.7 2.8.7c1.2 0 1.9-1.1 2.6-2.2.8-1.2 1.2-2.5 1.2-2.5s-2.6-1-2.6-3.4zM14.4 5.1c.6-.7 1-1.7.9-2.6-.9 0-1.9.5-2.5 1.3-.6.6-1.1 1.6-.9 2.5 1 .1 2-.5 2.5-1.2z"/></svg>`;
const smartphone = `<svg xmlns="http://www.w3.org/2000/svg" viewBox="0 0 24 24" width="100%" height="100%" fill="none" stroke="currentColor" stroke-width="1.75" stroke-linecap="round" stroke-linejoin="round"><rect x="7" y="3" width="10" height="18" rx="2"/><path d="M11 18h2"/></svg>`;

let html = readFileSync(join(__dirname, "preview_brands.html"), "utf8");
html = html.replaceAll("__WEB__", web);
html = html.replaceAll("__TUI__", tui);
html = html.replaceAll("__ZED__", zed);
html = html.replaceAll("__FREYA__", freya);
html = html.replaceAll("__APPLE__", apple);
html = html.replaceAll("__BUGDROID__", bugdroid);
html = html.replaceAll("__SMARTPHONE__", smartphone);

const tmpHtml = "/tmp/icon_brands_filled.html";
writeFileSync(tmpHtml, html);

const browser = await chromium.launch({ headless: true });
const page = await browser.newPage({ viewport: { width: 980, height: 900 } });
await page.goto("file://" + tmpHtml, { waitUntil: "load" });
await page.waitForTimeout(150);
await page.screenshot({ path: "/tmp/icon_brands_preview.png", fullPage: true });
console.log("wrote /tmp/icon_brands_preview.png");
await browser.close();
