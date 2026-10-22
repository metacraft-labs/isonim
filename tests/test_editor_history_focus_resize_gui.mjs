/** Sidebar resize across the preview iframe, and inspector focus across
 * browser-history traversal, in the mounted full production editor.
 *
 * The editor is `tests/helpers/editor_popup_workspace.nim` (the production
 * `mountEditor`, routing and shell) over a disposable copy of
 * `examples/source_project`, served by `tools/editor_server.py` with the real
 * isonim-review daemon. Previews are the real compiled source-project iframes.
 * Pointer and keyboard input is physical (Playwright mouse/keyboard); history
 * traversal is the browser's own Back/Forward.
 *
 * Not mocked. `tests/helpers/editor_control_peer.py` is configured as the
 * agent only because the daemon will not start without one; these cases make
 * no agent requests and the count is asserted to be zero. The popup workspace's
 * `openStory`/`select`/`snapshot` hooks open the story, select an element by
 * id and read the VM widths; they replace sidebar clicks whose own behaviour
 * is not under test here.
 *
 * Editor spec, "Resizable sidebars": both sidebars are drag-resizable from a
 * 4 px handle on their inner edge, through the same mousedown -> mousemove ->
 * mouseup pattern. The preview iframe sits ~30 px from both handles, so a
 * drag whose pointer moves faster than the edge follows it lands on the
 * iframe; the drag must still resize and still end on release.
 *
 * Inspector focus: the inspector control that had focus when the editor
 * navigated away is focused again when Back returns to that history entry.
 * An entry left with no inspector control focused restores nothing.
 */
import {spawn, spawnSync} from 'node:child_process';
import {mkdtempSync, cpSync, writeFileSync, mkdirSync, openSync, copyFileSync, existsSync, readFileSync} from 'node:fs';
import {chromium} from '../node_modules/playwright/index.mjs';
import assert from 'node:assert/strict';
import path from 'node:path';
import {tmpdir} from 'node:os';
import {fileURLToPath} from 'node:url';
import {createHash} from 'node:crypto';

const repo = path.resolve(path.dirname(fileURLToPath(import.meta.url)), '..');
const base = process.env.ISONIM_POPUP_ARTIFACTS || tmpdir();
const bundle = path.resolve(process.env.ISONIM_POPUP_BUILD || path.join(repo, 'build/editor-popup/editor.js'));
assert(existsSync(bundle), 'Run just editor-popup-build before this suite');
const daemon = path.join(repo, 'build/bin/isonim-review');
assert(existsSync(daemon), 'Run just isonim-review-build before this suite');

const root = mkdtempSync(base + '/history-focus-resize-');
const project = root + '/project', pub = root + '/public';
cpSync(repo + '/examples/source_project', project, {recursive: true, filter: p => !p.includes('catalog-producer')});
mkdirSync(pub);
for (const [from, to] of [
  ['src/isonim/editor/index.html', 'index.html'],
  ['node_modules/fabric/dist/index.min.js', 'fabric.min.js'],
  ['node_modules/paper/dist/paper-core.min.js', 'paper-core.min.js'],
  ['node_modules/svgo/dist/svgo.browser.js', 'svgo.browser.js'],
]) copyFileSync(repo + '/' + from, pub + '/' + to);
copyFileSync(bundle, pub + '/editor.js');

const proof = {
  bundleSha256: createHash('sha256').update(readFileSync(pub + '/editor.js')).digest('hex'),
  cases: [], pageErrors: [], agentRequests: [],
};
const record = name => { proof.cases.push(name); writeFileSync(root + '/proof.json', JSON.stringify(proof, null, 2)); };

const build = spawnSync('python3', [repo + '/tools/build_source_catalog.py', project],
  {env: {...process.env, ISONIM_SOURCE_FRAMEWORK: repo}, encoding: 'utf8', timeout: 70000});
writeFileSync(root + '/catalog-build.log', (build.stdout || '') + (build.stderr || ''));
if (build.status !== 0) throw Error('Actual catalog build failed: ' + build.status + ' ' + build.stderr);
const config = root + '/agent.toml';
writeFileSync(config, '[agent]\nbackend="custom"\ncommand="python3"\nargs=["' + repo +
  '/tests/helpers/editor_control_peer.py"]\nprimer_enabled=false\n');
const server = spawn('python3', [repo + '/tools/editor_server.py', '--directory', pub, '--project-root', project,
  '--port', '0', '--bind', '127.0.0.1', '--config', config, '--daemon-binary', daemon],
  {env: {...process.env, ISONIM_SOURCE_FRAMEWORK: repo}, stdio: ['ignore', 'pipe', openSync(root + '/server.log', 'w')]});

let browser;
try {
  const origin = await new Promise((resolve, reject) => {
    let out = '';
    server.stdout.on('data', chunk => {
      out += chunk;
      const m = out.match(/Editor listening on (http:\/\/[^\s]+)\//);
      if (m) resolve(m[1]);
    });
    server.once('exit', code => reject(Error('server exit ' + code)));
    setTimeout(() => reject(Error('startup timeout')), 70000).unref();
  });
  const env = {...process.env};
  delete env.LD_LIBRARY_PATH;
  browser = await chromium.launch({headless: true, env, executablePath: process.env.PLAYWRIGHT_CHROMIUM_EXECUTABLE});
  const page = await browser.newPage({viewport: {width: 1440, height: 900}});
  page.setDefaultTimeout(30000);
  page.on('pageerror', e => proof.pageErrors.push(e.message));
  page.on('request', r => { if (new URL(r.url()).pathname.startsWith('/api/agent/prompt')) proof.agentRequests.push(r.url()); });

  await page.goto(origin);
  await page.waitForFunction(() => window.__popupAcceptance && window.__isonimEditor);
  assert.equal(await page.evaluate(() => window.__popupAcceptance.openStory('Card', 'default ready')), true);
  const snapshot = async () => JSON.parse(await page.evaluate(() => window.__popupAcceptance.snapshot()));
  const modeChip = mode => page.locator(`[data-toolbar-cluster="mode"] [data-choice-group-label="${mode}"]`);
  const switchMode = async mode => {
    await modeChip(mode).click();
    await page.waitForFunction(m => document.querySelector(
      `[data-toolbar-cluster="mode"] [data-choice-group-label="${m}"]`)?.getAttribute('aria-pressed') === 'true', mode);
  };
  const activeLabel = () => page.evaluate(() => {
    const a = document.activeElement;
    return a ? a.tagName + ':' + (a.getAttribute('aria-label') || '') : '';
  });
  // Focus restoration is asynchronous (next frame, or after a row rebuild);
  // wait for it, then report the focused control when it never arrives.
  const expectFocused = async (label, message) => {
    try {
      await page.waitForFunction(l => document.activeElement?.getAttribute('aria-label') === l, label, {timeout: 5000});
    } catch {
      assert.equal(await activeLabel(), 'INPUT:' + label, message);
    }
  };

  // ---- Resize: a fast drag whose pointer lands on the preview iframe ----
  // View mode puts the AI assistant in the right sidebar, Edit mode the
  // Inspector; each carries its own right-panel handle.
  for (const [mode, surface] of [['View', 'ai-assistant'], ['Edit', 'inspector']]) {
    await switchMode(mode);
    await page.locator(`[data-sidebar-content="${surface}"]`).waitFor();
    const frame = page.locator(mode === 'Edit'
      ? 'iframe[title="Editable component preview"]'
      : 'iframe[title="Component preview default ready"]');
    await frame.waitFor();
    for (const [handleName, dx, widthKey, start] of [
      ['right-panel', -100, 'rightWidth', 320],
      ['left-sidebar', 100, 'leftWidth', 260],
    ]) {
      await page.evaluate(([r, l]) => {
        window.__isonimEditor.setRightPanelWidth(r);
        window.__isonimEditor.setLeftSidebarWidth(l);
      }, [320, 260]);
      await page.waitForFunction(([r, l]) => {
        const s = JSON.parse(window.__popupAcceptance.snapshot());
        return s.rightWidth === r && s.leftWidth === l;
      }, [320, 260]);
      const handle = page.locator(`[data-resize-handle="${handleName}"]:visible`);
      const hb = await handle.boundingBox();
      const fb = await frame.boundingBox();
      assert(hb && fb, 'handle and preview iframe are laid out');
      const x = hb.x + hb.width / 2, y = fb.y + fb.height / 2;
      // Precondition: the drag target is the preview iframe, which is the
      // condition the resize has to survive.
      assert.equal(await page.evaluate(([px, py]) => document.elementFromPoint(px, py)?.tagName, [x + dx, y]), 'IFRAME',
        `${mode} ${handleName}: the drag target must lie on the preview iframe`);
      assert.equal((await snapshot())[widthKey], start);
      await page.mouse.move(x, y);
      await page.mouse.down();
      await page.mouse.move(x + dx, y, {steps: 1});
      await page.mouse.up();
      assert.equal((await snapshot())[widthKey], start + Math.abs(dx),
        `${mode} ${handleName}: a drag onto the preview iframe resizes the sidebar`);
      assert.deepEqual(await page.evaluate(() => [document.body.style.cursor, document.body.style.userSelect]), ['', ''],
        `${mode} ${handleName}: releasing over the preview iframe ends the drag`);
      // Once released, moving the pointer no longer resizes.
      await page.mouse.move(x + dx * 2, y, {steps: 2});
      assert.equal((await snapshot())[widthKey], start + Math.abs(dx));
      record(`${mode} ${handleName} drag onto the preview iframe resizes and ends on release`);
    }
  }

  // ---- Inspector focus across browser-history traversal ----
  await switchMode('Edit');
  assert.equal(await page.evaluate(() => window.__popupAcceptance.select('action')), true);
  const padTop = page.locator('[data-sidebar-content="inspector"] [data-property-row="pad-top"] input[data-property-row-input]');
  await padTop.click();
  assert.equal(await activeLabel(), 'INPUT:Edit Pad top');
  const pages = page.getByRole('button', {name: 'Open Pages section'});
  await pages.click();
  await page.waitForURL(/view=page/);
  assert.equal(await activeLabel(), 'DIV:Open Pages section', 'the navigating control takes focus');

  await page.goBack();
  await page.waitForURL(/view=edit/);
  await expectFocused('Edit Pad top', 'Back focuses the inspector control focused when the editor navigated away');
  assert.equal((await snapshot()).selected, 'action');
  record('Back focuses the inspector control that was focused when the editor navigated away');

  await page.goForward();
  await page.waitForURL(/view=page/);
  await page.goBack();
  await page.waitForURL(/view=edit/);
  await expectFocused('Edit Pad top', 'Forward then Back focuses the same inspector control again');
  record('Forward then Back focuses the same inspector control again');

  // An entry left with nothing focused in the inspector restores nothing:
  // a control focused under an OLDER entry is not carried forward.
  await page.getByRole('button', {name: 'Open Components section'}).click();
  await page.waitForURL(/view=detail/);
  await pages.click();
  await page.waitForURL(/view=page/);
  await page.goBack();
  await page.waitForURL(/view=detail/);
  // Give a wrongly armed restore the frames it would need to act.
  await page.evaluate(() => new Promise(r => requestAnimationFrame(() => requestAnimationFrame(r))));
  assert.equal(await activeLabel(), 'DIV:Open Pages section',
    'Back to an entry left without inspector focus keeps focus where it is');
  record('Back to an entry left without inspector focus moves no focus');

  assert.deepEqual(proof.pageErrors, []);
  assert.deepEqual(proof.agentRequests, []);
  writeFileSync(root + '/proof.json', JSON.stringify(proof, null, 2));
  console.log(JSON.stringify({ok: true, cases: proof.cases.length, artifacts: root}));
} finally {
  if (browser) await browser.close();
  server.kill('SIGTERM');
}
