// Local HTTP supplies deterministic response bytes; all browser APIs, layout,
// networking and animation frames remain real Chromium operations.
import { chromium } from './browser/node_modules/playwright/index.mjs';
import { createServer } from 'node:http';
import { readFile } from 'node:fs/promises';
import assert from 'node:assert/strict';
const bundle = await readFile(process.env.ISONIM_NONDET_BUNDLE ?? new URL('./test_nondet_seams.js', import.meta.url));
const server = createServer((req, res) => {
  if (req.url === '/suite.js') { res.setHeader('Content-Type', 'text/javascript'); res.end(bundle); }
  else if (req.url === '/boundary-response') { res.statusCode = req.headers['x-xr-seam'] === 'real' ? 200 : 400; res.setHeader('Content-Type', 'text/plain'); res.setHeader('X-XR-Response', 'preserved'); res.end('real-network'); }
  else res.end('<!doctype html><body><script src="/suite.js"></script>');
});
await new Promise(resolve => server.listen(0, '127.0.0.1', resolve));
let browser;
try {
  browser = await chromium.launch({ executablePath: process.env.PLAYWRIGHT_CHROMIUM_EXECUTABLE });
  const page = await browser.newPage();
  const errors = [], messages = [];
  page.on('pageerror', err => { errors.push(String(err)); console.error(String(err)); });
  page.on('console', msg => messages.push(msg.text()));
  await page.goto(`http://127.0.0.1:${server.address().port}/`);
  await Promise.race([
    page.waitForFunction(() => window.xrBrowserComplete === true),
    new Promise((_, reject) => page.on('pageerror', reject)),
  ]);
  assert.deepEqual(errors, []);
  assert(!messages.some(m => /FAILED|Check failed/.test(m)), messages.join('\n'));
  assert(messages.includes('async-browser-seams: PASS'));
  const opaque = await browser.newPage();
  const opaqueErrors = [];
  opaque.on('pageerror', error => opaqueErrors.push(String(error)));
  await opaque.goto('about:blank');
  await opaque.evaluate(() => { window.xrStorageDeniedContext = true; });
  await opaque.addScriptTag({ content: bundle.toString() });
  await opaque.waitForFunction(() => window.xrStorageDeniedComplete === true);
  assert.deepEqual(opaqueErrors, []);
  await opaque.close();
  console.log('real-browser-seams: PASS');
} finally {
  await browser?.close();
  await new Promise(resolve => server.close(resolve));
}
