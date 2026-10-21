// Fault injection is needed to reproduce browser SecurityError/QuotaExceededError
// without changing machine policy. VM, reactive effects, seams and Chromium are
// real; no storage value or successful operation is fabricated by this harness.
const { chromium } = require('../tests/browser/node_modules/@playwright/test');
const http = require('node:http');
const fs = require('node:fs');
const assert = require('node:assert/strict');
(async () => {
  const script = fs.readFileSync('build/editor_storage_browser_fixture.js');
  const server = http.createServer((req, res) => {
    res.setHeader('Content-Type', req.url === '/test.js' ? 'application/javascript' : 'text/html');
    res.end(req.url === '/test.js' ? script : '<body><script src="/test.js"></script></body>');
  });
  await new Promise(resolve => server.listen(0, '127.0.0.1', resolve));
  let browser;
  try {
    const executablePath = process.env.PLAYWRIGHT_CHROMIUM_EXECUTABLE ||
      (fs.existsSync('/run/current-system/sw/bin/chromium') ? '/run/current-system/sw/bin/chromium' : undefined);
    browser = await chromium.launch({ executablePath, headless: true });
    for (const mode of ['normal', 'getter', 'getItem', 'setItem']) {
      const context = await browser.newContext();
      try {
        await context.addInitScript(mode => {
          globalThis.__storageDeniedCalls = 0;
          function denied() {
            globalThis.__storageDeniedCalls++;
            throw new DOMException('injected browser storage denial', mode === 'setItem' ? 'QuotaExceededError' : 'SecurityError');
          }
          if (mode === 'getter') Object.defineProperty(window, 'localStorage', {get: denied});
          if (mode === 'getItem' || mode === 'setItem') Storage.prototype[mode] = denied;
        }, mode);
        const page = await context.newPage();
        const errors = [];
        page.on('pageerror', error => errors.push(String(error)));
        await page.goto(`http://127.0.0.1:${server.address().port}/`);
        assert.equal(await page.evaluate(() => globalThis.__isonimStorageTestOK), true, `${mode}: fixture did not finish: ${errors}`);
        assert.deepEqual(errors, [], `${mode}: editor failed on optional storage`);
        if (mode === 'normal') {
          assert.deepEqual(await page.evaluate(() => JSON.parse(localStorage.getItem('isonim-editor-ai-drawer'))),
            {open: false, activeChatId: 'chat-1'});
          assert.equal(await page.evaluate(() => localStorage.getItem('isonim:inspector:expanded')), 'layout,fill');
        } else assert.ok(await page.evaluate(() => globalThis.__storageDeniedCalls) > 0, `${mode}: denial was not reached`);
        console.log(`editor storage ${mode}: PASS`);
      } finally { await context.close(); }
    }
  } finally {
    if (browser) await browser.close();
    await new Promise(resolve => server.close(resolve));
  }
})().catch(error => { console.error(error); process.exitCode = 1; });
