// Actual compiled production task app in Chromium. No fake DOM, model or
// renderer; the test only exposes existing store/dispose handles for assertions.
import {chromium} from '../node_modules/playwright/index.mjs';
import {readFile, writeFile} from 'node:fs/promises';
import assert from 'node:assert/strict';
import {readFileSync, statfsSync, existsSync} from 'node:fs';
import {createServer} from 'node:http';
const bundle = await readFile(process.env.BRANDED_TASK_BUNDLE, 'utf8');
const css = await readFile(new URL('../build/tailwind.css', import.meta.url), 'utf8');
const checks = [], observations = {};
function check(name, actual, expected) {
  const row = {name, actual, expected};
  checks.push(row);
  assert.deepEqual(actual, expected, 'semantic: ' + name);
}
// A loopback origin hosts actual bundle/CSS only; application work is real.
const server = createServer((request, response) => {
  response.setHeader('Content-Type', 'text/html');
  response.end('<!doctype html><html><head></head><body></body></html>');
});
await new Promise(resolve => server.listen(0, '127.0.0.1', resolve));
let browser;
try {
  const stat = statfsSync(process.cwd());
  const memory = existsSync('/proc/meminfo') ? Number(/^MemAvailable:\s+(\d+)/m.exec(readFileSync('/proc/meminfo', 'utf8'))?.[1]) * 1024 : null;
  observations.browserAdmission = {disk:stat.bavail * stat.bsize, MemAvailable:memory};
  const minimum = Number(process.env.ISONIM_TEST_MIN_AVAILABLE_BYTES || 0);
  assert.ok(observations.browserAdmission.disk >= minimum && (minimum === 0 || memory !== null && memory >= minimum), 'BLOCKED: browser resource admission');
  browser = await chromium.launch({executablePath: process.env.PLAYWRIGHT_CHROMIUM_EXECUTABLE});
  const page = await browser.newPage(), errors = [];
  observations.pageErrors = errors;
  page.on('pageerror', error => errors.push(String(error)));
  await page.goto('http://127.0.0.1:' + server.address().port + '/');
  await page.addStyleTag({content: css});
  await page.addScriptTag({content: bundle});
  await page.evaluate(() => { globalThis.app = brandedTaskApp.open('task-app'); });
  const root = page.locator('#task-app'), input = root.locator('input');
  const add = input.locator('..').locator(':scope > div');
  const filter = name => root.locator('div.rounded-2xl').filter({hasText: new RegExp('^' + name + '$')});
  const row = text => root.locator('span').filter({hasText: new RegExp('^' + text + '$')}).locator('..');
  const tasks = () => page.evaluate(() => JSON.parse(app.snapshot()));
  const texts = async () => (await tasks()).map(task => task.text);
  observations.emptyStyle = await root.getByText('No tasks yet.', {exact:false}).evaluate(element => ({
    inlineWidth:element.style.width, computedWidth:getComputedStyle(element).width,
  }));
  check('initial-store', await tasks(), []);
  check('initial-empty-state', await root.getByText('No tasks yet.', {exact:false}).count(), 1);
  check('title', await root.locator(':scope > span').textContent(), 'Tasks');
  for (const name of ['All', 'Active', 'Completed']) check('filter-' + name, await filter(name).count(), 1);
  await root.getByText('Clear Completed', {exact:true}).click();
  check('clear-empty-is-noop', await tasks(), []);
  await input.evaluate(element => element.setAttribute('value', 'old default'));
  await input.fill('alpha');
  await add.click();
  observations.firstAdd = await page.evaluate(() => ({
    tasks: JSON.parse(app.snapshot()), text: app.root.textContent,
    value: app.root.querySelector('input').value,
    defaultValue: app.root.querySelector('input').defaultValue,
  }));
  // A mutant must have reached the actual callback and rendered an actual row.
  check('add-reached-model-and-render', observations.firstAdd.tasks.length === 1 && observations.firstAdd.text.includes(observations.firstAdd.tasks[0].text), true);
  check('submitted-current-value', await texts(), ['alpha']);
  check('rendered-current-value', await row('alpha').count(), 1);
  check('cleared-current-value', await input.inputValue(), '');
  await add.click();
  check('empty-second-click-no-duplicate', await texts(), ['alpha']);
  await input.fill('beta'); await add.click();
  check('second-task', await texts(), ['alpha', 'beta']);
  await row('alpha').locator(':scope > div').first().click();
  check('toggle-exact-task', (await tasks()).map(t => [t.text, t.completed]), [['alpha', true], ['beta', false]]);
  await filter('Active').click();
  check('active-filter', [await row('alpha').count(), await row('beta').count()], [0, 1]);
  await filter('Completed').click();
  check('completed-filter', [await row('alpha').count(), await row('beta').count()], [1, 0]);
  await filter('All').click();
  check('all-filter', [await row('alpha').count(), await row('beta').count()], [1, 1]);
  await row('beta').locator(':scope > div').last().click();
  check('delete-exact-task', await texts(), ['alpha']);
  await root.getByText('Clear Completed', {exact:true}).click();
  check('clear-completed-model', await tasks(), []);
  check('clear-completed-empty-state', await root.getByText('No tasks yet.', {exact:false}).count(), 1);
  for (const text of ['gamma', 'delta']) {
    await input.fill(text); await add.click();
    check('repeated-add-' + text, await row(text).count(), 1);
  }
  observations.styles = await page.evaluate(() => {
    const root = app.root;
    return [...root.querySelectorAll('span')].map(element => ({
      text: element.textContent, nodeType:element.nodeType,
      color:getComputedStyle(element).color, fontSize:getComputedStyle(element).fontSize,
      inlineFontSize:element.style.fontSize, inlineWidth:element.style.width, inlineHeight:element.style.height, width:getComputedStyle(element).width,
    }));
  });
  observations.boxStyles = await page.evaluate(() => {
    const root = app.root, input = root.querySelector('input');
    const plus = [...root.querySelectorAll('span')].find(element => element.textContent === '+');
    const checkbox = [...root.querySelectorAll('span')].find(element => element.textContent === '✓').parentElement;
    const props = ['font-size', 'width', 'height', 'padding', 'border-radius', 'border-width'];
    return Object.fromEntries([['input', input], ['plus', plus], ['addButton', plus.parentElement], ['checkbox', checkbox]].map(([name, element]) => [name, {
      inline:Object.fromEntries(props.map(property => [property, element.style.getPropertyValue(property)])),
      computed:Object.fromEntries(props.map(property => [property, getComputedStyle(element).getPropertyValue(property)])),
    }]));
  });
  check('styled-glyph-count', observations.styles.filter(s => ['+', '✓', '✕', 'All', 'Active', 'Completed'].includes(s.text)).length, 8);
  check('styled-glyphs-are-elements', observations.styles.filter(s => ['+', '✓', '✕', 'All', 'Active', 'Completed'].includes(s.text)).every(s => s.nodeType === 1), true);
  check('styled-plus-color', observations.styles.find(s => s.text === '+').color, 'rgb(255, 255, 255)');
  await page.evaluate(() => {
    globalThis.retainedAdd = app.root.querySelector('input').parentElement.children[1];
    globalThis.foreignCalls = 0;
    retainedAdd.addEventListener('click', () => foreignCalls++);
    app.dispose();
    globalThis.disposedMarkup = app.root.innerHTML;
    globalThis.disposedRenders = app.renders();
  });
  await input.fill('after-disposal'); await add.click();
  check('disposed-first-owner-listener-removed', await texts(), ['gamma', 'delta']);
  check('foreign-native-listener-survives', await page.evaluate(() => foreignCalls), 1);
  await page.evaluate(() => app.add('retained-model-action'));
  check('retained-store-still-mutable', await texts(), ['gamma', 'delta', 'retained-model-action']);
  check('disposed-effects-stopped', await page.evaluate(() => [app.renders() === disposedRenders, app.root.innerHTML === disposedMarkup]), [true, true]);
  await page.evaluate(() => { globalThis.fresh = brandedTaskApp.open('fresh-app'); });
  const fresh = page.locator('#fresh-app');
  await fresh.locator('input').fill('fresh task');
  await fresh.locator('input').locator('..').locator(':scope > div').click();
  check('fresh-root-usable', await page.evaluate(() => JSON.parse(fresh.snapshot()).map(t => t.text)), ['fresh task']);
  // Native EventTarget reports callback exceptions to window.error. Observe the
  // exact controlled object, without treating it as an unexpected app error.
  await page.evaluate(() => {
    globalThis.brandedLeafError = new Error('controlled onAdd failure');
    globalThis.controlledErrors = [];
    addEventListener('error', event => {
      if (event.error === brandedLeafError) { controlledErrors.push(event.error); event.preventDefault(); }
    });
    globalThis.failedLeaf = brandedTaskApp.leaf(true);
    failedLeaf.root.id = 'failed-leaf';
    globalThis.successLeaf = brandedTaskApp.leaf(false);
    successLeaf.root.id = 'success-leaf';
  });
  const failed = page.locator('#failed-leaf'), success = page.locator('#success-leaf');
  await failed.locator('input').fill('preserve on error');
  await page.evaluate(() => {
    const native = Object.getOwnPropertyDescriptor(HTMLInputElement.prototype, 'value');
    globalThis.failedAccess = {reads:0, writes:0};
    Object.defineProperty(failedLeaf.root.querySelector('input'), 'value', {
      get() { failedAccess.reads++; return native.get.call(this); },
      set(value) { failedAccess.writes++; native.set.call(this, value); },
    });
  });
  await failed.locator(':scope > div').click();
  check('throwing-leaf-reads-once-no-clear', await page.evaluate(() => failedAccess), {reads:1, writes:0});
  check('throwing-callback-original-error', await page.evaluate(() => controlledErrors.length === 1 && controlledErrors[0] === brandedLeafError), true);
  check('throwing-callback-once', await page.evaluate(() => failedLeaf.calls()), 1);
  check('throwing-callback-preserves-input', await failed.locator('input').inputValue(), 'preserve on error');
  await success.locator('input').fill('success companion');
  await page.evaluate(() => {
    const native = Object.getOwnPropertyDescriptor(HTMLInputElement.prototype, 'value');
    globalThis.successAccess = {reads:0, writes:0};
    Object.defineProperty(successLeaf.root.querySelector('input'), 'value', {
      get() { successAccess.reads++; return native.get.call(this); },
      set(value) { successAccess.writes++; native.set.call(this, value); },
    });
  });
  await success.locator(':scope > div').click();
  check('successful-leaf-reads-once-clears-once', await page.evaluate(() => successAccess), {reads:1, writes:1});
  check('successful-leaf-once', await page.evaluate(() => [successLeaf.calls(), successLeaf.last()]), [1, 'success companion']);
  check('successful-leaf-clears', await success.locator('input').inputValue(), '');
  check('unexpected-page-errors', errors, []);
  observations.browser = browser.version();
  if (process.env.BRANDED_TASK_STYLE === '1') {
    const intended = {'+':'24px', All:'14px', Active:'14px', Completed:'14px', '✓':'14px', '✕':'20px'};
    for (const [text, font] of Object.entries(intended)) {
      const labels = observations.styles.filter(style => style.text === text);
      check('intended-font-' + text, labels.map(style => style.fontSize), labels.map(() => font));
    }
    const inputStyle = observations.boxStyles.input.inline;
    check('intended-input-font-assigned', inputStyle['font-size'], '16px');
    check('intended-input-font-computed', observations.boxStyles.input.computed['font-size'], '16px');
    check('intended-input-padding', inputStyle.padding, '12px');
    check('intended-input-radius', inputStyle['border-radius'], '8px');
    check('intended-input-height-assigned', inputStyle.height, '48px');
    check('intended-checkbox-border-width', observations.boxStyles.checkbox.inline['border-width'], '2px');
    for (const [text, width, height] of [['+', '28px', '28px'], ['✓', '18px', '18px'], ['✕', '24px', '24px'], ['All', '30px', '18px'], ['Active', '54px', '18px'], ['Completed', '81px', '18px'], ['Clear Completed', '130px', '']]) {
      const labels = observations.styles.filter(style => style.text === text);
      check('intended-width-' + text, labels.map(style => style.inlineWidth), labels.map(() => width));
      if (height) check('intended-height-' + text, labels.map(style => style.inlineHeight), labels.map(() => height));
    }
    check('intended-empty-width', observations.emptyStyle.inlineWidth, '300px');
  }
} finally {
  if (browser) await browser.close();
  await new Promise(resolve => server.close(resolve));
  await writeFile(process.env.BRANDED_TASK_RESULTS, JSON.stringify({checks, observations}, null, 2) + '\n');
}
console.log('PASS ' + checks.length + ' actual branded-app assertions');
