// Serve the actual Nim-compiled public env facade. Intl and time zones are
// real Chromium operations; wrappers delegate unchanged and count observations.
// Local HTTP only supplies fixture bytes, never environment values.
import assert from 'node:assert/strict';
import {readFile} from 'node:fs/promises';
import {createServer} from 'node:http';
import {chromium} from './browser/node_modules/playwright/index.mjs';

const bundle = await readFile(process.env.ISONIM_ENV_BUNDLE || 'build/nondet_partial_window_boot.js');
const server = createServer((req, res) => {
  if (req.url === '/suite.js') { res.setHeader('Content-Type', 'text/javascript'); res.end(bundle); }
  else res.end('<!doctype html><script src="/suite.js"></script>');
});
await new Promise(resolve => server.listen(0, '127.0.0.1', resolve));
let browser;
try {
  browser = await chromium.launch({executablePath: process.env.PLAYWRIGHT_CHROMIUM_EXECUTABLE});
  const results = [];
  for (const timezoneId of ['America/New_York', 'America/Toronto']) {
    const context = await browser.newContext({timezoneId, locale: 'bg-BG', viewport: {width: 831, height: 619}});
    await context.addInitScript(() => {
      const original = Intl.DateTimeFormat;
      const probe = {constructors: 0, resolutions: 0, observations: []};
      window.xrZoneProbe = probe;
      Intl.DateTimeFormat = function(...args) {
        probe.constructors++;
        const formatter = original(...args);
        const resolve = formatter.resolvedOptions.bind(formatter);
        formatter.resolvedOptions = function() {
          probe.resolutions++;
          const options = resolve();
          probe.observations.push(options.timeZone);
          return options;
        };
        return formatter;
      };
      // Independent oracle bypasses the counting wrapper, still actual Intl.
      window.xrPlatformZone = () => original().resolvedOptions().timeZone;
    });
    const page = await context.newPage();
    const errors = [];
    page.on('pageerror', error => errors.push(String(error)));
    await page.goto(`http://127.0.0.1:${server.address().port}/`);
    const result = await page.evaluate(() => {
      const read = () => JSON.parse(window.isonimReadEnv());
      const boot = JSON.parse(window.isonimBootEnv);
      const before = structuredClone(window.xrZoneProbe);
      const cached = read();
      cached.timeZone = 'caller-mutation';
      window.isonimMutateEnv(); // Mutate the actual returned Nim JsonNode too.
      history.replaceState(null, '', '/changed');
      const after = read();
      const afterCache = structuredClone(window.xrZoneProbe);
      window.isonimResetEnv();
      const fresh = read();
      const freshCounts = structuredClone(window.xrZoneProbe);
      read(); read();
      return {boot, after, fresh, before, afterCache, freshCounts,
        final: structuredClone(window.xrZoneProbe), expected: window.xrPlatformZone(),
        offset: new Date().getTimezoneOffset(), url: location.href,
        ua: navigator.userAgent, language: navigator.language,
        hasCtGlobal: Object.keys(globalThis).some(key => key.startsWith('__ct'))};
    });
    assert.deepEqual(errors, []);
    for (const snapshot of [result.boot, result.after, result.fresh]) {
      assert.equal(snapshot.timezoneOffset, result.offset);
      assert.equal(snapshot.ua, result.ua);
      assert.equal(snapshot.language, result.language);
      assert.deepEqual(snapshot.viewport, {width: 831, height: 619});
      for (const key of ['browserMajor', 'dpr', 'prefersDark', 'prefersReducedMotion', 'buildId', 'assignment', 'traceparent']) {
        assert(Object.hasOwn(snapshot, key), `legacy env key ${key}`);
      }
    }
    console.log('legacy-environment-and-offset: PASS');
    for (const snapshot of [result.boot, result.after, result.fresh]) {
      assert.equal(snapshot.timeZone, result.expected, 'IANA environment must retain actual platform zone');
    }
    assert.equal(result.after.url, result.boot.url);
    assert.equal(result.fresh.url, result.url);
    assert.deepEqual(result.afterCache, result.before, 'cached public reads must not reobserve Intl');
    assert.equal(result.freshCounts.constructors - result.before.constructors, 1, 'one Intl construction per fresh snapshot');
    assert.equal(result.freshCounts.resolutions - result.before.resolutions, 1, 'one Intl resolution per fresh snapshot');
    assert.equal(result.freshCounts.observations.at(-1), result.expected);
    assert.deepEqual(result.final, result.freshCounts);
    assert.equal(result.hasCtGlobal, false);
    results.push({zone: result.expected, offset: result.offset});
    await context.close();
  }
  assert.notEqual(results[0].zone, results[1].zone, 'actual zones must be distinct');
  assert.equal(results[0].offset, results[1].offset, 'same offset must not collapse zone identity');
  console.log(`IANA-environment-cache: PASS ${JSON.stringify(results)}`);
} finally {
  await browser?.close();
  await new Promise(resolve => server.close(resolve));
}
