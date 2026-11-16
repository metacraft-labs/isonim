/** A native inspector edit is written into the rule the preview's own
 * cascade uses, for conditions only the preview can answer (isonim-pm issue
 * 2026-11-15-edit-target-at-width-ignores-important-and-never-targets-a-rule-
 * in-layer, round 2).
 *
 * The fixture's `#action` declares `width:120px` and a later
 * `@media (prefers-color-scheme: dark)` block declares `width:60px`.
 *   - In a light preview the row shows 120 and an edit of Width changes the
 *     base rule; the dark rule is untouched; the preview renders 150px; undo
 *     and redo are byte-exact.
 *   - In a dark preview the row shows 60 and the same edit changes the dark
 *     rule; the base rule is untouched; the preview renders 150px.
 *   - With a later `@container` block instead (a condition no preview answer
 *     covers), the row is read-only and its reason names that block, not a
 *     missing owner.
 *   - With seven `px` max-width blocks (decided by the preview's width, so
 *     not counted towards the 6-condition cap), the row at Desktop shows the
 *     120px the preview renders and the edit writes the base rule.
 * The preview's answers (its `matchMedia`) ride with the request
 * (`conditions`); the worker writes with them.
 *
 * Real mounted production inspector, native authenticated source worker,
 * private files and the actual Nim compiler/SSR catalog, as in
 * `test_editor_inspector_source_gui.mjs`; nothing is mocked. The configured
 * decision peer only permits daemon startup; zero agent calls are asserted.
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
const basePort = Number(process.env.ISONIM_SCHEME_GUI_PORT || '9976');
const cases = [];

async function scenario(name, port, scheme, block, act) {
  const root = mkdtempSync(path.join(process.env.ISONIM_POPUP_ARTIFACTS || tmpdir(), 'inspector-source-' + name + '-'));
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
    const frameWith = 'const frame=[...document.querySelectorAll("iframe")].find(frame=>frame.getClientRects().length&&frame.contentDocument?.querySelector("#action"));';
    const preview = () => page.evaluate(frameWith + 'frame?({width:frame.contentWindow.getComputedStyle(frame.contentDocument.querySelector("#action")).width,dark:frame.contentWindow.matchMedia("(prefers-color-scheme: dark)").matches}):null');
    const waitPreviewWidth = async width => {
      try { await page.waitForFunction(width => { const frame = [...document.querySelectorAll('iframe')].find(frame => frame.getClientRects().length && frame.contentDocument?.querySelector('#action')); return !!frame && frame.contentWindow.getComputedStyle(frame.contentDocument.querySelector('#action')).width === width; }, width, {timeout: 70000}); }
      catch (error) { throw Error('Preview #action width never became ' + width + ': ' + JSON.stringify(await preview())); }
    };
    const ctx = {
      page, authored, record, preview, waitPreviewWidth,
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

const dark = '@media (prefers-color-scheme: dark) { #action { width:60px; } }';
async function editsTheDecidingRule(ctx, shown, before, after, rendered) {
  const {page, authored, record, source, input, waitPreviewWidth, waitUndo} = ctx;
  await waitPreviewWidth(rendered);
  await page.waitForFunction(shown => { const row = document.querySelector('[data-property-row-css-property="width"][data-property-row="w"] [data-property-row-input]'); return row && row.value === shown; }, shown);
  assert.notEqual(await ctx.row.getAttribute('data-property-row-readonly'), 'true', 'the row is editable: ' + await ctx.row.getAttribute('data-property-row-readonly-reason'));
  record('the row shows ' + shown + ', the value of the rule the preview uses, and is editable');
  await input.fill('150'); await input.press('Enter'); await input.press('Tab');
  await waitUndo(1);
  assert.equal(source(), authored.replace(before, after), 'the deciding rule is written, and only it');
  await waitPreviewWidth('150px');
  record('the edit is written into the rule the preview uses and the preview renders 150px');
  await page.evaluate(() => window.__popupAcceptance.history(false)); await waitUndo(0);
  assert.equal(source(), authored, 'undo restores the file byte for byte');
  await waitPreviewWidth(rendered);
  await page.evaluate(() => window.__popupAcceptance.history(true)); await waitUndo(1);
  assert.equal(source(), authored.replace(before, after), 'redo writes the same bytes');
  await waitPreviewWidth('150px');
  record('undo and redo are byte-exact and the preview follows');
}

try {
  await scenario('light', basePort, 'light', dark, async ctx => {
    assert.equal((await ctx.preview()).dark, false);
    await editsTheDecidingRule(ctx, '120', '#action { width:120px;', '#action { width:150px;', '120px');
    assert(ctx.source().includes(dark), 'the dark rule is untouched');
  });
  await scenario('dark', basePort + 1, 'dark', dark, async ctx => {
    assert.equal((await ctx.preview()).dark, true);
    await editsTheDecidingRule(ctx, '60', dark, dark.replace('width:60px', 'width:150px'), '60px');
    assert(ctx.source().includes('#action { width:120px;'), 'the base rule is untouched');
  });
  await scenario('container', basePort + 2, 'light', '@container (min-width: 1px) { #action { width:60px; } }', async ctx => {
    await ctx.page.waitForFunction(() => document.querySelector('[data-property-row-css-property="width"][data-property-row="w"]')?.getAttribute('data-property-row-readonly') === 'true');
    const reason = await ctx.row.getAttribute('data-property-row-readonly-reason');
    assert(reason.includes('@container (min-width: 1px)'), 'the reason names the block: ' + reason);
    assert(!reason.includes('No editable source declaration'), 'not a false reason: ' + reason);
    ctx.record('a rule under a condition no preview answer covers makes the row read-only, naming it: ' + reason);
  });
  // Round 3 (N2): seven px breakpoints are decided by the preview's width,
  // not counted towards the 6-condition cap: at Desktop the row shows the
  // 120px the preview renders, is editable, and the edit writes the base rule.
  const breakpoints = Array.from({length: 7}, (_, i) => '@media (max-width: ' + (1300 - 100 * i) + 'px) { #action { width:' + (61 + i) + 'px; } }').join('\n');
  await scenario('breakpoints', basePort + 3, 'light', breakpoints, async ctx => {
    await editsTheDecidingRule(ctx, '120', '#action { width:120px;', '#action { width:150px;', '120px');
    assert(ctx.source().includes(breakpoints), 'the breakpoint rules are untouched');
  });
} finally {
  console.log(JSON.stringify(cases, null, 1));
}
console.log('Inspector source scheme GUI passed:', cases.length);
