/** Shorthand sides follow the card rule's real declaration order, in the
 * inspector and in the rendered preview (Chromium), before and after the
 * automatic write, and through undo and redo.
 *
 * Editor spec "Native project source capabilities" (sides "respect
 * declaration order"), "Visual box model" (an all-sides field is `Mixed`
 * when the sides differ) and the UX-M3 control/preview/history parity
 * requirement; CSS cascade within one rule
 * (https://www.w3.org/TR/css-cascade-4/#cascade-sort). isonim-pm issue
 * 2026-10-23-a-shorthand-edit-is-shown-on-sides-a-later-longhand-still-overrides.
 *
 * No mocks. The host (`tests/helpers/editor_shorthand_order_workspace.nim`)
 * is the editor example with its real writer, preview document and browser
 * selection bridge, plus schema entries for the card's sides. The page is
 * served by a plain static file server started here. External requests (the
 * example page's Tailwind CDN script) are aborted so the run is offline.
 */
import {createServer} from 'node:http';
import {mkdtempSync,readFileSync,writeFileSync,copyFileSync,existsSync} from 'node:fs';
import {chromium} from '../node_modules/playwright/index.mjs';
import assert from 'node:assert/strict';
import path from 'node:path';
import {tmpdir} from 'node:os';
import {fileURLToPath} from 'node:url';
const repo=path.resolve(path.dirname(fileURLToPath(import.meta.url)),'..');
const bundle=repo+'/build/editor-shorthand/editor.js';
assert(existsSync(bundle),'build the host first: nim js -o:build/editor-shorthand/editor.js tests/helpers/editor_shorthand_order_workspace.nim');
const pub=mkdtempSync(path.join(process.env.ISONIM_POPUP_ARTIFACTS||tmpdir(),'shorthand-order-'));
copyFileSync(bundle,pub+'/editor.js');
for(const [from,to] of [['node_modules/fabric/dist/index.min.js','fabric.min.js'],['node_modules/paper/dist/paper-core.min.js','paper-core.min.js'],['node_modules/svgo/dist/svgo.browser.js','svgo.browser.js']])copyFileSync(repo+'/'+from,pub+'/'+to);
const index=readFileSync(repo+'/src/isonim/editor/index.html','utf8');
const page=(rule)=>index.replace('<script src="editor.js"></script>','<script>window.__isonimShorthandCardRule='+JSON.stringify(rule)+';</script><script src="editor.js"></script>');
const types={'.js':'text/javascript','.html':'text/html'};
let rule='';
const server=createServer((req,res)=>{const url=new URL(req.url,'http://x');const name=url.pathname==='/'?'index.html':url.pathname.slice(1);
  if(name==='index.html'){res.writeHead(200,{'content-type':'text/html'});res.end(page(rule));return;}
  const file=path.join(pub,path.basename(name));if(!existsSync(file)){res.writeHead(404);res.end();return;}
  res.writeHead(200,{'content-type':types[path.extname(file)]||'application/octet-stream'});res.end(readFileSync(file));});
await new Promise(resolve=>server.listen(0,'127.0.0.1',resolve));
const origin='http://127.0.0.1:'+server.address().port;
const foundation='examples/wanderlust/design-system/foundations.css';
const cases=[],errors=[];
let browser;
try {
  const env={...process.env};delete env.LD_LIBRARY_PATH;
  browser=await chromium.launch({headless:true,env,executablePath:process.env.PLAYWRIGHT_CHROMIUM_EXECUTABLE});
  const p=await browser.newPage({viewport:{width:1440,height:900}});p.setDefaultTimeout(30000);
  p.on('pageerror',e=>errors.push(e.message));
  await p.route(url=>!url.href.startsWith(origin),route=>route.abort());
  const card=()=>p.frameLocator('iframe[title="Editable component preview"]').getByTestId('component-edit-preview');
  const computed=(prop)=>card().evaluate((n,prop)=>getComputedStyle(n).getPropertyValue(prop),prop);
  const rendered=async(prefix)=>{const out=[];for(const side of ['top','right','bottom','left'])out.push(await computed(prefix+side));return out;};
  const source=()=>p.evaluate(f=>window.__isonimDemoSources?.[f]??'',foundation);
  const cardRule=async()=>(await source()).match(/\.destination-card \{[^}]*\}/)[0];
  const pending=()=>p.evaluate(()=>window.__isonimEditor.pendingSourceEdits());
  const field=(name)=>p.getByRole('textbox',{name,exact:true});
  async function open(startRule){
    rule=startRule;await p.goto(origin+'/');
    await p.getByRole('button',{name:'Open Components section'}).click();
    await p.getByRole('button',{name:'Toggle DestinationCard stories'}).click();
    await p.getByRole('button',{name:'Select story DestinationCard / Default'}).click();
    await p.getByRole('button',{name:'Switch to edit mode'}).click();
    await card().click({force:true});
    await p.frameLocator('iframe[title="Editable component preview"]').locator('[data-isonim-selected="true"]').waitFor();
    const layout=p.locator('[data-inspector-section-header="layout"]');
    if((await layout.getAttribute('aria-expanded'))!=='true')await layout.click();
    const toggle=p.getByRole('button',{name:'Show box model controls'});
    if((await toggle.getAttribute('aria-expanded'))!=='true')await toggle.click();
  }
  async function commit(name,value){const f=field(name);await f.click();await f.press('ControlOrMeta+A');await p.keyboard.type(value);await f.press('Enter');}
  async function settle(expectedRule){
    await assertPoll(async()=>[await pending(),await cardRule()],[0,expectedRule],'written rule');
  }
  async function assertPoll(read,expected,what){
    const deadline=Date.now()+20000;let last;
    while(Date.now()<deadline){last=await read();try{assert.deepEqual(last,expected);return;}catch{}await p.waitForTimeout(100);}
    assert.deepEqual(last,expected,what);
  }
  async function undoRedo(redo){await p.evaluate(()=>document.activeElement?.blur());await p.keyboard.press(redo?'ControlOrMeta+Shift+z':'ControlOrMeta+z');}

  // 1. The case in the issue: a later side keeps its value.
  await open('padding: 18px;');
  await commit('Padding top','24');
  await settle('.destination-card { padding: 18px; padding-top: 24px; }');
  await commit('Padding, all sides','20');
  // At once, from the CSSOM edit: the later side is still shown.
  await assertPoll(()=>rendered('padding-'),['24px','20px','20px','20px'],'preview right after the shorthand edit');
  assert.equal(await field('Padding top').inputValue(),'24');
  assert.equal(await field('Padding, all sides').inputValue(),'');
  assert.equal(await field('Padding, all sides').getAttribute('placeholder'),'Mixed');
  await settle('.destination-card { padding: 20px; padding-top: 24px; }');
  await assertPoll(()=>rendered('padding-'),['24px','20px','20px','20px'],'preview after the write');
  cases.push('later side keeps its value in inspector and preview, before and after the write');
  await undoRedo(false);
  await assertPoll(()=>rendered('padding-'),['24px','18px','18px','18px'],'preview after undo');
  assert.equal(await field('Padding top').inputValue(),'24');
  await undoRedo(true);
  await assertPoll(()=>rendered('padding-'),['24px','20px','20px','20px'],'preview after redo');
  assert.equal(await field('Padding top').inputValue(),'24');
  cases.push('undo and redo of the shorthand keep the later side in the preview');
  // Recapture: select the card again, then set all sides.
  await settle('.destination-card { padding: 20px; padding-top: 24px; }');
  await card().click({force:true});
  await commit('Padding, all sides','22');
  await assertPoll(()=>rendered('padding-'),['24px','22px','22px','22px'],'preview after recapture and shorthand edit');
  assert.equal(await field('Padding top').inputValue(),'24');
  cases.push('a recaptured selection is settled from the file again');

  // 2. A shorthand inserted after its side reaches it.
  await open('padding: 18px;');
  await commit('Margin top','10');
  await commit('Margin, all sides','6');
  await assertPoll(()=>rendered('margin-'),['6px','6px','6px','6px'],'preview after inserting margin');
  assert.equal(await field('Margin top').inputValue(),'6');
  await settle('.destination-card { padding: 18px; margin-top: 10px; margin: 6px; }');
  await assertPoll(()=>rendered('margin-'),['6px','6px','6px','6px'],'preview after the margin write');
  await undoRedo(false);
  await assertPoll(()=>rendered('margin-'),['10px','0px','0px','0px'],'preview after undoing the inserted shorthand');
  assert.equal(await field('Margin top').inputValue(),'10');
  cases.push('a margin shorthand inserted after its side reaches it; undo restores the side');

  // 3. A side declared before the shorthand, edited in place.
  await open('padding-top: 24px; padding: 18px;');
  await commit('Padding top','30');
  await assertPoll(()=>rendered('padding-'),['18px','18px','18px','18px'],'preview after an overridden side edit');
  assert.equal(await field('Padding top').inputValue(),'18');
  await settle('.destination-card { padding-top: 30px; padding: 18px; }');
  await assertPoll(()=>rendered('padding-'),['18px','18px','18px','18px'],'preview after writing the overridden side');
  cases.push('a side edited in place before its shorthand shows what renders');

  // 4. !important: the earlier important shorthand decides a later side.
  await open('padding: 18px !important; padding-top: 24px;');
  await commit('Padding top','30');
  await assertPoll(()=>rendered('padding-'),['18px','18px','18px','18px'],'preview with an important shorthand');
  assert.equal(await field('Padding top').inputValue(),'18');
  await settle('.destination-card { padding: 18px !important; padding-top: 30px; }');
  await assertPoll(()=>rendered('padding-'),['18px','18px','18px','18px'],'preview after writing under an important shorthand');
  cases.push('an important earlier shorthand decides over a later side');

  assert.deepEqual(errors,[]);
  console.log('Shorthand order GUI passed:',pub,cases.length);
} finally {
  if(browser)await browser.close();
  await new Promise(resolve=>server.close(resolve));
}
