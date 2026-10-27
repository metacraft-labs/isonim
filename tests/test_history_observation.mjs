/** Real History performs all URL resolution. Delegating wrappers capture native
 * calls and errors. VM hosts are deliberately partial hosts for availability
 * and ordering controls; they are never evidence of browser URL resolution. */
import {chromium} from './browser/node_modules/playwright/index.mjs';
import {createServer} from 'node:http';
import {readFileSync} from 'node:fs';
import vm from 'node:vm';
import assert from 'node:assert/strict';

const source = readFileSync(process.env.ISONIM_HISTORY_BUNDLE ?? 'build/nondet_history.js', 'utf8');
const server = createServer((req, res) => res.end('<!doctype html><base href="/base/nested/"><body>history'));
await new Promise(resolve => server.listen(0, '127.0.0.1', resolve));
let browser;
try {
  browser = await chromium.launch({executablePath: process.env.PLAYWRIGHT_CHROMIUM_EXECUTABLE});
  const page = await browser.newPage();
  await page.goto(`http://127.0.0.1:${server.address().port}/initial?old=1#old`);
  await page.addScriptTag({content: source});
  const result = await page.evaluate(async () => {
    const api = globalThis.xrHistory, calls = [], reflected = [];
    let events = 0, lastError;
    addEventListener('popstate', () => events++);
    addEventListener('hashchange', () => events++);
    for (const name of ['pushState', 'replaceState']) {
      const original = history[name];
      history[name] = function(...args) {
        calls.push({name, receiver: this === history, args});
        try { const value = original.apply(this, args); reflected.push(location.href); return value; }
        catch (error) { lastError = error; throw error; }
      };
    }
    const actions = [
      ['pushState', '../café path?q=雪#fragment'],
      ['replaceState', '?query=a b#雪'],
      ['pushState', '/absolute/deep/../path?x=%2F#encoded'],
      ['replaceState', '#same-path'],
    ];
    const observations = [], expected = [];
    for (const [name, input] of actions) {
      const before = calls.length;
      const previousLength = history.length;
      const observed = JSON.parse(api.observe(name, input));
      if (calls.length !== before + 1) throw Error('one original history call');
      observations.push(observed); expected.push(reflected.at(-1));
      if (history.state !== null) throw Error('native history state must remain null');
      if (history.length !== previousLength + (name === 'pushState' ? 1 : 0))
        throw Error('native history length must preserve push/replace behavior');
    }
    for (const name of ['pushState', 'replaceState']) {
      const before = calls.length;
      const input = location.href;
      const value = api[name === 'pushState' ? 'push' : 'replace'](input);
      if (value !== undefined || calls.length !== before + 1 || api.pathname() !== location.pathname)
        throw Error('ordinary public history facade');
    }
    let errors = 0;
    for (const invoke of [() => api.observe('pushState', 'https://other.invalid/'),
                          () => api.observe('replaceState', 'https://other.invalid/'),
                          () => api.push('https://other.invalid/'),
                          () => api.replace('https://other.invalid/')]) {
      const before = calls.length;
      try { invoke(); throw Error('cross-origin mutation unexpectedly accepted'); }
      catch (error) { if (error !== lastError || error.name !== 'SecurityError' || calls.length !== before + 1) throw error; errors++; }
    }
    await new Promise(resolve => requestAnimationFrame(() => requestAnimationFrame(resolve)));
    return {observations, expected, calls, actions, events, errors};
  });
  assert.equal(result.errors, 4);
  assert.equal(result.events, 0);
  for (const call of result.calls) {
    assert.equal(call.receiver, true); assert.equal(call.args.length, 3);
    assert.equal(call.args[0], null); assert.equal(call.args[1], '');
  }
  assert.deepEqual(result.calls.slice(0, 4).map(call => [call.name, call.args[2]]), result.actions);
  console.log('ordinary-history-void-pathname-one-call: PASS');
  assert.deepEqual(result.observations, result.expected, 'full-reflected-history-URL must equal same successful native action');
  assert(result.observations[0].includes('caf%C3%A9%20path'));
  assert(result.observations.every(url => url.startsWith('http://127.0.0.1:')));
  console.log('full-reflected-history-URL: PASS');
} finally {
  await browser?.close(); await new Promise(resolve => server.close(resolve));
}

function partial(window) {
  const context = vm.createContext({window, console, crypto: globalThis.crypto,
    performance, setTimeout, clearTimeout, queueMicrotask});
  vm.runInContext(source, context);
  return context.xrHistory;
}
for (const metadata of [undefined, {}, {href: 42}, {href: ''}, {href: 'https://partial.test/reflected'}]) {
  const calls = [], window = {location: metadata, history: {}};
  for (const name of ['pushState', 'replaceState']) window.history[name] = function(...args) { calls.push([this === window.history, args]); };
  const api = partial(window);
  let metadataReads = 0;
  const actualLocation = window.location;
  Object.defineProperty(window, 'location', {get() { metadataReads++; return actualLocation; }});
  for (const name of ['pushState', 'replaceState']) {
    assert.equal(JSON.parse(api.observe(name, '/input')), typeof metadata?.href === 'string' ? metadata.href : null);
    assert.equal(api[name === 'pushState' ? 'push' : 'replace']('/public'), undefined);
  }
  assert.equal(calls.length, 4);
  assert.equal(metadataReads, 4, 'successful history performs exactly one metadata observation');
  assert(calls.every(([receiver, args]) => receiver && args[0] === null && args[1] === '' && args.length === 3));
}
for (const member of ['location', 'href']) {
  const window = {location: {}, history: {pushState() {}, replaceState() {}}};
  const api = partial(window); // Module boot succeeds before installing a throwing accessor.
  Object.defineProperty(member === 'location' ? window : window.location, member,
    {get() { throw new Error('metadata-only-failure'); }});
  for (const name of ['pushState', 'replaceState']) {
    assert.equal(JSON.parse(api.observe(name, '/input')), null);
    assert.equal(api[name === 'pushState' ? 'push' : 'replace']('/public'), undefined);
  }
}
{
  const failure = new Error('original-mutation-failure'), storageFailure = new Error('storage-write-failure');
  let reads = 0, writes = 0;
  const window = {history: {pushState() { writes++; throw failure; }, replaceState() { writes++; throw failure; }}};
  const api = partial(window);
  Object.defineProperty(window, 'location', {get() { reads++; throw new Error('must-not-read'); }});
  for (const invoke of [() => api.observe('pushState', '/x'), () => api.observe('replaceState', '/x'),
                        () => api.push('/x'), () => api.replace('/x')]) assert.throws(invoke, error => error === failure);
  assert.equal(writes, 4); assert.equal(reads, 0);
  // The fixture binds storage through the existing bare global. No location read
  // is allowed even when localStorage itself throws.
  const context = vm.createContext({window: {}, console, crypto: globalThis.crypto, performance,
    setTimeout, clearTimeout, queueMicrotask, localStorage: {setItem() { throw storageFailure; }}});
  vm.runInContext(source, context);
  Object.defineProperty(context.window, 'location', {get() { reads++; throw new Error('storage-must-not-read'); }});
  assert.throws(() => context.xrHistory.storage('key', 'value'), error => error === storageFailure);
  assert.equal(reads, 0);
}
console.log('partial-history-availability-and-error-order: PASS');
