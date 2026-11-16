/** A native inspector edit, and then its undo, made right after the editor
 * tab's main thread stalled past its 10 s browser lease, are both written
 * (isonim-pm issue 2026-11-16-a-source-edit-or-undo-is-refused-with-
 * disconnected-instance-after-the-editor-tab-stalls-for-ten-seconds).
 *
 * The stall is a real busy loop on the page's main thread. The edit (Enter on
 * the Width row) and the undo are started in the same task as the stall, so
 * no overdue poll can renew the lease first; the test checks that no poll
 * reached the server in the 10 s before each write's admission. The tab's own
 * source requests must renew the lease.
 *
 * Real mounted production inspector, native authenticated source worker,
 * private files and the actual Nim compiler/SSR catalog, as in
 * `test_editor_inspector_source_scheme_gui.mjs`, whose harness this copies;
 * nothing is mocked. The configured decision peer only permits daemon
 * startup; zero agent calls are asserted.
 */
import {spawn, spawnSync} from 'node:child_process';
import {mkdtempSync, cpSync, readFileSync, writeFileSync, mkdirSync, openSync, copyFileSync} from 'node:fs';
import {chromium} from '../node_modules/playwright/index.mjs';
import assert from 'node:assert/strict';
import path from 'node:path';
import {tmpdir} from 'node:os';
import {fileURLToPath} from 'node:url';
import {createHash} from 'node:crypto';
const repo = path.resolve(path.dirname(fileURLToPath(import.meta.url)), '..');
const basePort = Number(process.env.ISONIM_LEASE_GUI_PORT || '9976');
const cases = [];

async function scenario(name, port, scheme, block, act) {
  const root = mkdtempSync(path.join(process.env.ISONIM_POPUP_ARTIFACTS || tmpdir(), 'inspector-lease-' + name + '-'));
  const project = root + '/project', pub = root + '/public';
  cpSync(repo + '/tests/fixtures/editor_inspector_project', project, {recursive: true}); mkdirSync(pub);
  const storyFile = project + '/stories.nim';
  {
    const original = readFileSync(storyFile, 'utf8');
    assert(original.includes('#action { width:120px; height:48px;'), 'fixture shape');
    writeFileSync(storyFile, original.replace('#secondary-action {', block + '\n#secondary-action {'));
  }
  const authored = readFileSync(storyFile, 'utf8');
  for (const [from, to] of [['src/isonim/editor/index.html', 'index.html'], ['build/editor-inspector/editor.js', 'editor.js'], ['node_modules/fabric/dist/index.min.js', 'fabric.min.js'], ['node_modules/paper/dist/paper-core.min.js', 'paper-core.min.js'], ['node_modules/svgo/dist/svgo.browser.js', 'svgo.browser.js']]) copyFileSync(repo + '/' + from, pub + '/' + to);
  const build = spawnSync('python3', [repo + '/tools/build_source_catalog.py', project], {env: {...process.env, ISONIM_SOURCE_FRAMEWORK: repo}, encoding: 'utf8', timeout: 70000});
  writeFileSync(root + '/catalog-build.log', build.stdout + build.stderr); assert.equal(build.status, 0, build.stdout + build.stderr);
  const proof = {name, scheme, project, head: spawnSync('git', ['rev-parse', 'HEAD'], {cwd: repo, encoding: 'utf8'}).stdout.trim(),
    dirty: spawnSync('git', ['status', '--porcelain'], {cwd: repo, encoding: 'utf8'}).stdout.trim().split('\n').filter(Boolean),
    nativeSha256: createHash('sha256').update(readFileSync(repo + '/build/bin/isonim-review')).digest('hex'),
    bundleSha256: createHash('sha256').update(readFileSync(pub + '/editor.js')).digest('hex'), cases: [], errors: [], agentRequests: []};
  const record = text => { proof.cases.push(text); cases.push(name + ': ' + text); writeFileSync(root + '/proof-partial.json', JSON.stringify(proof, null, 2)); };
  const config = root + '/agent.toml'; writeFileSync(config, '[agent]\nbackend="custom"\ncommand="python3"\nargs=' + JSON.stringify([repo + '/tests/helpers/editor_control_peer.py']) + '\nprimer_enabled=false\n');
  const server = spawn('python3', [repo + '/tools/editor_server.py', '--directory', pub, '--project-root', project, '--port', String(port), '--bind', '127.0.0.1', '--config', config, '--daemon-binary', repo + '/build/bin/isonim-review'], {env: {...process.env, ISONIM_SOURCE_FRAMEWORK: repo}, stdio: ['ignore', 'pipe', openSync(root + '/server.log', 'w')]});
  let browser, browserServer;
  try {
    const origin = await new Promise((resolve, reject) => { let text = ''; server.stdout.on('data', data => { text += data; const match = text.match(/Editor listening on (http:\/\/[^\s]+)\//); if (match) resolve(match[1]); }); server.once('exit', code => reject(Error('Server exited ' + code))); setTimeout(() => reject(Error('Server startup timeout')), 70000).unref(); });
    const chromeEnv = {...process.env}; delete chromeEnv.LD_LIBRARY_PATH;
    browserServer = await chromium.launchServer({headless: true, env: chromeEnv, executablePath: process.env.PLAYWRIGHT_CHROMIUM_EXECUTABLE}); browser = await chromium.connect(browserServer.wsEndpoint());
    const page = await (await browser.newContext({viewport: {width: 1440, height: 900}, colorScheme: scheme})).newPage(); page.setDefaultTimeout(30000);
    page.on('pageerror', error => proof.errors.push(error.message));
    page.on('request', request => { const url = new URL(request.url()); if (url.pathname.startsWith('/api/agent/')) proof.agentRequests.push(url.pathname); });
    const rpcLog = []; proof.rpc = rpcLog;
    page.on('request', request => { const url = new URL(request.url()); if (url.pathname === '/api/editor/rpc') { try { rpcLog.push({t: Date.now(), method: request.postDataJSON().method}); } catch (_) {} } else if (url.pathname === '/api/editor/source/operation') rpcLog.push({t: Date.now(), method: 'source-operation'}); });
    const frameWith = 'const frame=[...document.querySelectorAll("iframe")].find(frame=>frame.getClientRects().length&&frame.contentDocument?.querySelector("#action"));';
    const preview = () => page.evaluate(frameWith + 'frame?({width:frame.contentWindow.getComputedStyle(frame.contentDocument.querySelector("#action")).width,dark:frame.contentWindow.matchMedia("(prefers-color-scheme: dark)").matches}):null');
    const waitPreviewWidth = async width => {
      try { await page.waitForFunction(width => { const frame = [...document.querySelectorAll('iframe')].find(frame => frame.getClientRects().length && frame.contentDocument?.querySelector('#action')); return !!frame && frame.contentWindow.getComputedStyle(frame.contentDocument.querySelector('#action')).width === width; }, width, {timeout: 70000}); }
      catch (error) { throw Error('Preview #action width never became ' + width + ': ' + JSON.stringify(await preview())); }
    };
    const ctx = {
      page, authored, record, preview, waitPreviewWidth, rpcLog,
      source: () => readFileSync(storyFile, 'utf8'),
      snapshot: () => page.evaluate(() => JSON.parse(window.__popupAcceptance.snapshot())),
      waitUndo: async count => {
        try { await page.waitForFunction(count => { const state = JSON.parse(window.__popupAcceptance.snapshot()); return state.stage === 'wesClean' && state.undoCount === count; }, count, {timeout: 70000}); }
        catch (error) { throw Error('undo count never became ' + count + ': ' + await page.evaluate(() => JSON.stringify({stage: JSON.parse(window.__popupAcceptance.snapshot()).stage, saveError: [...document.querySelectorAll('[data-save-error], [data-workspace-edit-diagnostic], [role="status"], [role="alert"]')].map(e => e.textContent.trim()).filter(Boolean)}))); }
      },
    };
    await page.goto(origin); await page.waitForFunction(() => !!window.__popupAcceptance);
    await page.locator('[data-toolbar-cluster="mode"] [aria-label="Switch to edit mode"]').click();
    await page.locator('[data-scene-graph-row="action"]').click();
    ctx.row = page.locator('[data-property-row-css-property="width"][data-property-row="w"][data-property-row-kind="numeric"]');
    await ctx.row.waitFor(); assert.equal(await ctx.row.count(), 1, 'Actual visible width row exists');
    ctx.input = ctx.row.locator('[data-property-row-input]');
    await act(ctx);
    assert.deepEqual(proof.errors, []); assert.deepEqual(proof.agentRequests, []);
    writeFileSync(root + '/proof.json', JSON.stringify(proof, null, 2));
  } finally {
    if (browser) await browser.close(); if (browserServer) await browserServer.close();
    server.kill('SIGTERM'); await new Promise(resolve => { if (server.exitCode !== null) return resolve(); server.once('exit', resolve); setTimeout(() => { server.kill('SIGKILL'); resolve(); }, 15000).unref(); });
    writeFileSync(root + '/proof-final.json', JSON.stringify(proof, null, 2));
  }
}


const StallMs = Number(process.env.ISONIM_LEASE_STALL_MS || 11000);
// Positive control: the write's first request reached the server with no poll
// in the lease window before it, so only the write itself could renew it.
function stalledPast(rpcLog, since, method) {
  const write = rpcLog.find(entry => entry.t >= since && entry.method === method);
  assert(write, method + ' was sent');
  const polls = rpcLog.filter(entry => entry.method === 'editor.poll' && entry.t <= write.t).map(entry => entry.t);
  const gap = write.t - Math.max(...polls);
  assert(gap > 10000, 'the stall outlasted the 10 s lease before ' + method + ' (gap ' + gap + ' ms)');
  return gap;
}
const saveError = page => page.evaluate(() => [...document.querySelectorAll('[data-save-error]')].map(e => e.textContent.trim()).filter(Boolean));

try {
  await scenario('stall', basePort, 'light', '', async ctx => {
    const {page, authored, record, source, input, waitPreviewWidth, waitUndo, rpcLog} = ctx;
    await waitPreviewWidth('120px');
    await page.waitForFunction(() => document.querySelector('[data-property-row-css-property="width"][data-property-row="w"] [data-property-row-input]')?.value === '120');
    await input.focus(); await input.fill('150');
    let since = Date.now();
    await page.evaluate(ms => {
      const end = Date.now() + ms; while (Date.now() < end);
      const row = document.querySelector('[data-property-row-css-property="width"][data-property-row="w"] [data-property-row-input]');
      row.dispatchEvent(new KeyboardEvent('keydown', {key: 'Enter', code: 'Enter', bubbles: true, cancelable: true}));
    }, StallMs);
    const editGap = stalledPast(rpcLog, since, 'editor.inspector-source');
    await waitUndo(1);
    assert.equal(source(), authored.replace('#action { width:120px;', '#action { width:150px;'), 'the edit is written');
    assert.deepEqual(await saveError(page), [], 'no save error after the edit');
    await waitPreviewWidth('150px');
    record('an edit committed right after a ' + StallMs + ' ms stall (no poll for ' + editGap + ' ms) is written');
    since = Date.now();
    await page.evaluate(ms => {
      const end = Date.now() + ms; while (Date.now() < end);
      window.__popupAcceptance.history(false);
    }, StallMs);
    const undoGap = stalledPast(rpcLog, since, 'editor.inspector-source');
    await waitUndo(0);
    assert.equal(source(), authored, 'the undo restores the file byte for byte');
    assert.deepEqual(await saveError(page), [], 'no save error after the undo');
    await waitPreviewWidth('120px');
    record('its undo, started right after another ' + StallMs + ' ms stall (no poll for ' + undoGap + ' ms), is written');
  });
} finally {
  console.log(JSON.stringify(cases, null, 1));
}
console.log('Inspector source lease-stall GUI passed:', cases.length);
