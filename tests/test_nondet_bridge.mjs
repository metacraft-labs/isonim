// Serve the actual compiled control program. Real Chromium initialization is
// the subject; the local server supplies bytes, not clocks/hooks/time values.
import assert from "node:assert/strict";
import { readFileSync } from "node:fs";
import { createServer } from "node:http";
import { chromium } from "./browser/node_modules/playwright/index.mjs";
const bundle = readFileSync(process.env.ISONIM_BRIDGE_BUNDLE);
const server = createServer((req, res) => {
  if (req.url === "/app.js") {
    res.setHeader("Content-Type", "text/javascript");
    res.end(bundle);
  } else res.end('<!doctype html><script src="/app.js"></script>');
});
await new Promise((resolve) => server.listen(0, "127.0.0.1", resolve));
let browser;
try {
  browser = await chromium.launch({
    executablePath: process.env.PLAYWRIGHT_CHROMIUM_EXECUTABLE,
  });
  const page = await browser.newPage();
  const errors = [],
    output = [];
  page.on("pageerror", (error) => errors.push(String(error)));
  page.on("console", (message) => output.push(message.text()));
  await page.goto(`http://127.0.0.1:${server.address().port}/`);
  assert.deepEqual(errors, []);
  assert(output.includes("nondet-bridge-initialization: PASS"));
  console.log("real Chromium lazy bridge: PASS");
} finally {
  await browser?.close();
  await new Promise((resolve) => server.close(resolve));
}
