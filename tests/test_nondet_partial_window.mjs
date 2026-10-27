/** No mocks of IsoNim code: evaluates the actually compiled boundary module.
 * The `window` objects below are deliberate partial hosts, not stand-ins for a
 * browser: Node fixtures and worker shims define a `window` with only the
 * members they need, and importing core/nondet must not assume the rest exist
 * as bare globals. Each case runs in its own vm context, so no Node global
 * (e.g. Node's own `navigator`) can satisfy a read the module should have made
 * through `window`. */
import assert from 'node:assert/strict';
import {readFileSync} from 'node:fs';
import vm from 'node:vm';

const source = readFileSync(
  process.env.ISONIM_NONDET_PARTIAL_WINDOW_BUILD || 'build/nondet_partial_window_boot.js', 'utf8');

function boot(name, window) {
  // Only the language builtins plus what a Nim JS bundle needs from its host.
  const context = vm.createContext({
    window, console, crypto: globalThis.crypto, performance: globalThis.performance,
    setTimeout, clearTimeout, queueMicrotask,
  });
  vm.runInContext(source, context, {filename: `nondet-partial-window-${name}.js`, timeout: 2000});
  // Parse in this realm so deepEqual compares plain objects of one realm.
  return JSON.parse(context.isonimBootEnv);
}

// The shape metacraft-web's bridge-client fixture provides: window.location,
// storage, history and listeners, but no bare `location`, `navigator`,
// `document`, `matchMedia`, `innerWidth` or `devicePixelRatio` globals.
const fixtureWindow = {
  location: {href: 'http://127.0.0.1:4173/editor?tab=1', pathname: '/editor'},
  localStorage: {getItem: () => null, setItem() {}},
  history: {pushState() {}, replaceState() {}},
  addEventListener() {}, removeEventListener() {},
};
const located = boot('location-only', fixtureWindow);
assert.equal(located.url, 'http://127.0.0.1:4173/editor?tab=1',
  'The boot snapshot must read the URL through the window it guarded on');
assert.equal(located.ua, '');
assert.equal(located.browserMajor, '');
assert.equal(located.language, '');
assert.deepEqual(located.viewport, {width: 0, height: 0});
assert.equal(located.dpr, 1);
assert.equal(located.prefersDark, false);
assert.equal(located.prefersReducedMotion, false);
assert.equal(located.traceparent, '');
console.log('partial window with location: boot snapshot PASS');

// An empty window still imports; every member falls back to its default.
const bare = boot('empty', {});
assert.equal(bare.url, '');
assert.deepEqual(Object.keys(bare).sort(), Object.keys(located).sort(),
  'Absent members must keep every snapshot key present');
console.log('empty window: boot snapshot PASS');

// Members that are present are read through window, not through globals.
const full = boot('window-members', {
  location: {href: 'https://example.test/a'},
  navigator: {userAgent: 'Mozilla/5.0 Chrome/131.0.0.0', language: 'bg'},
  innerWidth: 800, innerHeight: 600, devicePixelRatio: 2,
  matchMedia: query => ({matches: query === '(prefers-color-scheme: dark)'}),
  document: {querySelector: sel => sel === 'meta[name=traceparent]' ? {content: '00-abc-def-01'} : null},
});
assert.equal(full.url, 'https://example.test/a');
assert.equal(full.browserMajor, '131');
assert.equal(full.language, 'bg');
assert.deepEqual(full.viewport, {width: 800, height: 600});
assert.equal(full.dpr, 2);
assert.equal(full.prefersDark, true);
assert.equal(full.prefersReducedMotion, false);
assert.equal(full.traceparent, '00-abc-def-01');
console.log('window members: boot snapshot PASS');

assert.equal(located.timeZone, '', 'partial window must not borrow bare global Intl');
assert.equal(bare.timeZone, '');
for (const [name, Intl] of [
  ['empty-Intl', {}], ['missing-constructor', {DateTimeFormat: null}],
  ['missing-options', {DateTimeFormat: () => ({})}],
  ['missing-zone', {DateTimeFormat: () => ({resolvedOptions: () => ({})})}],
  ['non-string-zone', {DateTimeFormat: () => ({resolvedOptions: () => ({timeZone: 0})})}],
]) {
  assert.equal(boot(name, {Intl}).timeZone, '', `${name} must denote unavailable zone`);
}
console.log('partial-window IANA absence: PASS');
assert.throws(() => boot('throwing-Intl', {Intl: {
  DateTimeFormat() { throw new Error('platform Intl failure'); },
}}), /platform Intl failure/, 'platform failures must propagate, not become a guessed zone');
assert.throws(() => boot('throwing-options', {Intl: {
  DateTimeFormat: () => ({resolvedOptions() { throw new Error('platform options failure'); }}),
}}), /platform options failure/);
console.log('partial-window Intl exception fidelity: PASS');
