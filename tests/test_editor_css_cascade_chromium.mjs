/** The width-aware writer (`css_patch.editTargetAtWidth` /
 * `patchCssDeclarationAt`) against real Chromium, over generated sheets
 * (`tests/helpers/css_cascade_cases.py`, seeded): hand cases for importance,
 * cascade layers (statements, nesting, dotted and anonymous names, layers
 * named under conditions, `@import … layer(…)`), media query lists, `em` and
 * range widths, colour schemes, `@supports`, `@container`, nested rules and
 * in-rule shorthands, plus 400 random sheets.
 *
 * For each case, at its viewport width and once each in a light and a dark
 * colour scheme, the preview's answers for the case's conditions
 * (`editConditions`) are taken from Chromium itself (`matchMedia`,
 * `CSS.supports`), as the editor's preview supplies them; the writer patches
 * `padding-left` to 777px with those answers; and Chromium renders the
 * original and the patched sheet. A write must render 777px. A refusal must
 * say why, and is accepted only where the writer cannot know (a condition
 * no preview answer covers) or the write would not render (another
 * declaration in the target rule still decides the property, or no single
 * rule can take it).
 *
 * Nothing is mocked: the real writer (compiled from this tree) and real
 * Chromium. argv/env: none; ISONIM_POPUP_ARTIFACTS for the artifact dir.
 */
import {spawnSync} from 'node:child_process';
import {mkdtempSync, readFileSync, writeFileSync} from 'node:fs';
import {chromium} from '../node_modules/playwright/index.mjs';
import assert from 'node:assert/strict';
import path from 'node:path';
import {tmpdir} from 'node:os';
import {fileURLToPath} from 'node:url';
const repo = path.resolve(path.dirname(fileURLToPath(import.meta.url)), '..');
const root = mkdtempSync(path.join(process.env.ISONIM_POPUP_ARTIFACTS || tmpdir(), 'css-cascade-chromium-'));
const probe = process.env.ISONIM_CSS_CASCADE_PROBE || root + '/css_cascade_probe';
const run = (cmd, args) => {
  const r = spawnSync(cmd, args, {cwd: repo, encoding: 'utf8', maxBuffer: 1 << 28});
  assert.equal(r.status, 0, cmd + ' ' + args.join(' ') + '\n' + r.stdout + r.stderr);
};
if (!process.env.ISONIM_CSS_CASCADE_PROBE)
  run('nim', ['c', '--hints:off', '-d:release', '--path:src', '--out:' + probe, 'tests/helpers/css_cascade_probe.nim']);
run('python3', ['tests/helpers/css_cascade_cases.py', root + '/cases.json']);
run(probe, ['conditions', root + '/cases.json', root + '/conditions.json']);
const cases = JSON.parse(readFileSync(root + '/cases.json', 'utf8'));
const conditions = JSON.parse(readFileSync(root + '/conditions.json', 'utf8'));
const chromeEnv = {...process.env}; delete chromeEnv.LD_LIBRARY_PATH;
const browser = await chromium.launch({headless: true, env: chromeEnv, executablePath: process.env.PLAYWRIGHT_CHROMIUM_EXECUTABLE});
const summary = {};
const failures = [];
try {
  for (const scheme of ['light', 'dark']) {
    const page = await (await browser.newContext({colorScheme: scheme})).newPage();
    await page.setContent('<!doctype html><html><head><style id=s></style></head><body><div class="x"></div></body></html>');
    const render = async (css, width) => {
      await page.setViewportSize({width, height: 600});
      await page.evaluate(css => { document.getElementById('s').textContent = css; }, css);
      // `@import`ed data: sheets load asynchronously.
      await page.waitForFunction(() => { try { for (const r of document.styleSheets[0].cssRules) if (r.type === 3 && !r.styleSheet) return false; return true; } catch (e) { return true; } }, null, {timeout: 5000}).catch(() => {});
      return page.evaluate(() => ({pl: getComputedStyle(document.querySelector('.x')).paddingLeft, iw: innerWidth}));
    };
    // The preview's answers: matchMedia / CSS.supports on each prelude's text.
    const answers = [];
    for (let i = 0; i < cases.length; i++) {
      await page.setViewportSize({width: cases[i].width, height: 600});
      answers.push(await page.evaluate(list => {
        const out = {};
        for (const prelude of list) {
          const m = prelude.match(/^\s*@(media|supports)\b([\s\S]*)$/i);
          try {
            if (m && m[1].toLowerCase() === 'media') out[prelude] = matchMedia(m[2].trim()).matches;
            else if (m) out[prelude] = CSS.supports(m[2].trim());
          } catch (e) {}
        }
        return out;
      }, conditions[i]));
    }
    writeFileSync(root + '/answers-' + scheme + '.json', JSON.stringify(answers));
    run(probe, ['patch', root + '/cases.json', root + '/answers-' + scheme + '.json', root + '/writer-' + scheme + '.json']);
    const writer = JSON.parse(readFileSync(root + '/writer-' + scheme + '.json', 'utf8'));
    const counts = {};
    for (let i = 0; i < cases.length; i++) {
      const c = cases[i], w = writer[i];
      const before = await render(c.css, c.width);
      assert.equal(before.iw, c.width);
      let cls;
      if (w.ok) {
        const after = await render(w.content, c.width);
        cls = after.pl === '777px' ? 'written' : 'WRONG';
        if (cls === 'WRONG') failures.push({scheme, id: c.id, name: c.name, width: c.width, css: c.css, condition: w.condition, before: before.pl, after: after.pl});
      } else {
        assert(w.message.length > 0, 'a refusal says why: case ' + c.id);
        if (w.undecided) {
          cls = 'refused: not answerable';
          if (!c.tags.includes('unanswerable')) failures.push({scheme, id: c.id, name: c.name, width: c.width, css: c.css, refused: w.message});
        } else if (w.message.includes('would still decide it after the edit')) {
          cls = 'refused: another declaration in the rule decides it';
        } else if (w.outcome === 'cpoAmbiguous' || w.outcome === 'cpoRuleNotFound') {
          cls = 'refused: no single rule';
        } else {
          cls = 'UNEXPECTED REFUSAL';
          failures.push({scheme, id: c.id, name: c.name, width: c.width, css: c.css, refused: w.message});
        }
      }
      counts[cls] = (counts[cls] || 0) + 1;
    }
    summary[scheme] = counts;
  }
} finally {
  await browser.close();
  writeFileSync(root + '/summary.json', JSON.stringify({summary, failures}, null, 2));
}
console.log(JSON.stringify(summary));
assert.deepEqual(failures, [], 'writer and Chromium disagree; see ' + root + '/summary.json');
assert(summary.light.written > 300 && summary.dark.written > 300, 'most cases are written');
console.log('CSS cascade vs Chromium passed:', root, cases.length, 'cases x 2 schemes');
