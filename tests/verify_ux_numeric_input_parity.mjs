/** verify_ux_numeric_input_parity (editor UX-M3, Verification V1).
 *
 * Actual keyboard and pointer events on a mounted inspector numeric row
 * (the selected card's padding-top, Component properties section) reach
 * one commit path, and its written source is the evidence: left/right
 * scrub deltas, Shift/Alt, arrow steps, typed arithmetic and units,
 * non-finite rejection, one commit per drag, and no commit on a click, a
 * drag back to the start, or a drag cancelled by Escape, pointer
 * cancellation or a lost pointer capture (editor spec "Planned interaction
 * parity": "label scrubbing uses actual horizontal displacement: right
 * increases, left reduces; a click without movement makes no edit.
 * Dragging previews changes and releasing commits one undoable operation.
 * Escape or pointer cancellation restores the value from before the
 * gesture. Typed arithmetic, units and arrow adjustments obey the same
 * property constraints. Invalid or non-finite values are rejected without
 * changing source.").
 *
 * The host is the shorthand-order host
 * (`tests/helpers/editor_shorthand_order_workspace.nim`: the editor example
 * with its real synchronous writer, preview document and selection
 * bridge), the card's padding sides mapped to its rule. Physical pointer
 * and keyboard input through Chromium, except the pointer cancellation and
 * the lost capture, which a mouse cannot produce and which are dispatched
 * as the browser would; no mocks; external requests are aborted.
 */
import {createServer} from 'node:http';
import {mkdtempSync,readFileSync,copyFileSync,existsSync} from 'node:fs';
import {chromium} from '../node_modules/playwright/index.mjs';
import assert from 'node:assert/strict';
import path from 'node:path';
import {tmpdir} from 'node:os';
import {fileURLToPath} from 'node:url';
const repo=path.resolve(path.dirname(fileURLToPath(import.meta.url)),'..');
const bundle=repo+'/build/editor-shorthand/editor.js';
assert(existsSync(bundle),'build the host first: nim js -o:build/editor-shorthand/editor.js tests/helpers/editor_shorthand_order_workspace.nim');
const pub=mkdtempSync(path.join(process.env.ISONIM_POPUP_ARTIFACTS||tmpdir(),'verify-numeric-'));
copyFileSync(bundle,pub+'/editor.js');
for(const [from,to] of [['node_modules/fabric/dist/index.min.js','fabric.min.js'],['node_modules/paper/dist/paper-core.min.js','paper-core.min.js'],['node_modules/svgo/dist/svgo.browser.js','svgo.browser.js']])copyFileSync(repo+'/'+from,pub+'/'+to);
const index=readFileSync(repo+'/src/isonim/editor/index.html','utf8');
let rule='',prefixCss='',sourceReplace='',readOnly='';
const page=()=>index.replace('<script src="editor.js"></script>','<script>window.__isonimShorthandCardRule='+JSON.stringify(rule)+';window.__isonimShorthandPrefixCss='+JSON.stringify(prefixCss)+';window.__isonimShorthandSourceReplace='+JSON.stringify(sourceReplace)+';window.__isonimShorthandReadOnly='+JSON.stringify(readOnly)+';window.__isonimShorthandMapped="width,height";</script><script src="editor.js"></script>');
const types={'.js':'text/javascript','.html':'text/html'};
const server=createServer((req,res)=>{const url=new URL(req.url,'http://x');const name=url.pathname==='/'?'index.html':url.pathname.slice(1);
  if(name==='index.html'){res.writeHead(200,{'content-type':'text/html'});res.end(page());return;}
  const file=path.join(pub,path.basename(name));if(!existsSync(file)){res.writeHead(404);res.end();return;}
  res.writeHead(200,{'content-type':types[path.extname(file)]||'application/octet-stream'});res.end(readFileSync(file));});
// A fixed port when one is given (ISONIM_VERIFY_NUMERIC_PORT), otherwise any.
await new Promise(resolve=>server.listen(Number(process.env.ISONIM_VERIFY_NUMERIC_PORT||0),'127.0.0.1',resolve));
const origin='http://127.0.0.1:'+server.address().port;
const foundation='examples/wanderlust/design-system/foundations.css';
const cases=[],errors=[];
let browser;
try {
  const env={...process.env};delete env.LD_LIBRARY_PATH;
  browser=await chromium.launch({headless:true,env,executablePath:process.env.PLAYWRIGHT_CHROMIUM_EXECUTABLE});
  const p=await browser.newPage({viewport:{width:1440,height:900}});p.setDefaultTimeout(30000);
  p.on('pageerror',e=>errors.push(e.message));
  // The delayed-answer stand-in (see the header): off unless a case sets it.
  await p.addInitScript(()=>{if(window.top!==window)return;window.__held=[];window.__holdCommits=false;window.addEventListener('isonim-preview-box-drag',e=>{if(e.detail&&e.detail.phase==='commit'&&window.__holdCommits){e.stopImmediatePropagation();e.detail.reply='pending';window.__held.push(e.detail.settle);}},true);});
  await p.route(url=>!url.href.startsWith(origin),route=>route.abort());

  const frame=()=>p.frameLocator('iframe[title="Editable component preview"]');
  const card=()=>frame().getByTestId('component-edit-preview');
  const source=()=>p.evaluate(f=>window.__isonimDemoSources?.[f]??'',foundation);
  const cardRule=async()=>(await source()).match(/\.destination-card \{[^}]*\}/)[0];
  const written=async()=>{const m=(await cardRule()).match(/padding-top:\s*([^;]+);/);return m?m[1].trim():null;};
  const pending=()=>p.evaluate(()=>window.__isonimEditor.pendingSourceEdits());
  const undoCount=()=>p.evaluate(()=>window.__isonimEditorVm.inspector.undoStack.value.length);
  async function assertPoll(read,expected,what){
    const deadline=Date.now()+60000;let last;
    while(Date.now()<deadline){last=await read();try{assert.deepEqual(last,expected);return;}catch{}await p.waitForTimeout(100);}
    assert.deepEqual(last,expected,what);
  }
  async function select(){
    const at=await card().evaluate(n=>{const r=n.getBoundingClientRect();for(let y=r.top+3;y<r.bottom;y+=4)for(let x=r.left+3;x<r.right;x+=4)if(document.elementFromPoint(x,y)===n)return {x,y};return null;});
    assert.ok(at,'a point of the card can be clicked');
    const f=await p.evaluate(()=>{const n=document.querySelector('iframe[title="Editable component preview"]');const r=n.getBoundingClientRect();return {x:r.x,y:r.y,s:r.width/n.contentWindow.innerWidth};});
    await p.mouse.click(f.x+at.x*f.s,f.y+at.y*f.s);
    await frame().locator('[data-isonim-selected="true"]').waitFor();
  }
  rule='padding-top: 20px;';
  await p.goto(origin+'/');
  await p.getByRole('button',{name:'Open Components section'}).click();
  await p.getByRole('button',{name:'Toggle DestinationCard stories'}).click();
  await p.getByRole('button',{name:'Select story DestinationCard / Default'}).click();
  await p.getByRole('button',{name:'Switch to edit mode'}).click();
  await select();
  // The card's padding-top as a component property: the project schema maps
  // it to the card's class rule (`classes.destination-card.padding-top`).
  const section=p.locator('[data-inspector-section-header="component-properties"]');
  if((await section.getAttribute('aria-expanded'))!=='true')await section.click();
  const row=p.locator('[data-inspector-section-body="component-properties"] [data-property-row="padding-top"][data-property-row-css-property="padding-top"][data-property-row-kind="numeric"]').first();
  await row.waitFor();
  const input=row.locator('[data-property-row-input]');
  const label=row.locator('[data-property-row-field-label]');
  assert.equal(await written(),'20px','the case starts from padding-top 20px');
  assert.equal(await input.inputValue(),'20','the row shows the written value');
  // Settled: written, nothing pending, the row showing it.
  async function settledAt(value,what){
    await assertPoll(written,value,what+': written');
    await assertPoll(pending,0,what+': nothing pending');
  }
  // A scrub on the row's label: press, `moves` moves of `dx` screen pixels
  // each (vertical distance 0: the fastest speed, 2 steps per pixel),
  // modifiers held throughout, release.
  async function scrub(dx,moves,{shift=false,alt=false,back=false,escape=false}={}){
    await label.scrollIntoViewIfNeeded();
    const b=await label.boundingBox();const x=b.x+b.width/2,y=b.y+b.height/2;
    if(shift)await p.keyboard.down('Shift');if(alt)await p.keyboard.down('Alt');
    await p.mouse.move(x,y);await p.mouse.down();
    for(let i=1;i<=moves;i++)await p.mouse.move(x+dx*i,y);
    if(back)await p.mouse.move(x,y);
    if(escape)await p.keyboard.press('Escape');
    await p.mouse.up();
    if(alt)await p.keyboard.up('Alt');if(shift)await p.keyboard.up('Shift');
  }
  let h=await undoCount();

  // Left/right deltas: right increases, left reduces, by the pointer's travel.
  await scrub(5,4);
  await settledAt('60px','a scrub 20px to the right');
  assert.equal(await undoCount(),h+1,'one commit for the whole drag');h++;
  await scrub(-5,2);
  await settledAt('40px','a scrub 10px to the left');
  assert.equal(await undoCount(),h+1,'one commit for the leftward drag');h++;
  cases.push('a scrub right increases and left reduces by the pointer\'s travel, one commit per drag');

  // Shift is ten times the step, Alt a tenth.
  await scrub(5,2,{shift:true});
  await settledAt('240px','Shift: 10px of travel');
  await scrub(5,2,{alt:true});
  await settledAt('242px','Alt: 10px of travel');
  assert.equal(await undoCount(),h+2,'one commit per modified drag');h+=2;
  cases.push('Shift scrubs ten times the step and Alt a tenth');

  // Arrow keys: one step, Shift ten, Alt a tenth; one commit each.
  await input.click();
  await input.press('ArrowUp');
  await settledAt('243px','ArrowUp');
  await input.press('Shift+ArrowDown');
  await settledAt('233px','Shift+ArrowDown');
  await input.press('Alt+ArrowUp');
  await settledAt('233.1px','Alt+ArrowUp');
  assert.equal(await undoCount(),h+3,'one commit per arrow step');h+=3;
  cases.push('arrow keys step by one, ten with Shift and a tenth with Alt, one commit each');

  // Typed arithmetic and units: one commit on Enter (and none more on blur).
  await input.fill('100+50');await input.press('Enter');await input.press('Tab');
  await settledAt('150px','typed 100+50');
  await input.fill('(2+3)*4em');await input.press('Enter');await input.press('Tab');
  await settledAt('20em','typed (2+3)*4em');
  assert.equal(await undoCount(),h+2,'one commit per typed value');h+=2;
  assert.equal(await row.locator('[data-property-row-unit]').textContent(),'em','the row shows the typed unit');
  cases.push('typed arithmetic and units are written as computed, one commit each');

  // Invalid and non-finite input is rejected: source, history and the field
  // as before.
  const before=await source();
  for(const bad of ['1e999','NaN','12garbage','(10+2','Infinity']){
    await input.fill(bad);await input.press('Enter');await input.press('Tab');
    await p.waitForTimeout(400);
    assert.equal(await source(),before,bad+': source unchanged');
    assert.equal(await undoCount(),h,bad+': nothing committed');
    assert.equal(await input.inputValue(),'20',bad+': the field is put back');
  }
  cases.push('invalid and non-finite typed values are rejected without changing source, history or the field');

  // No commit: a click on the label, a drag back to its start, a drag
  // cancelled with Escape.
  await scrub(0,1);
  await scrub(5,3,{back:true});
  await scrub(5,3,{escape:true});
  await p.waitForTimeout(800);
  assert.equal(await source(),before,'no write from a click, a return to start or a cancelled drag');
  assert.equal(await undoCount(),h,'no commit from a click, a return to start or a cancelled drag');
  assert.equal(await input.inputValue(),'20','the field shows the value from before the gestures');
  assert.equal(await pending(),0,'nothing pending');
  cases.push('a click, a drag back to the start and an Escape-cancelled drag commit nothing and put the value back');

  // Pointer cancellation and a lost pointer capture end a scrub the same
  // way: no commit, the value from before the gesture back in the field.
  // Neither can be produced by a mouse; each is dispatched as the browser
  // would (a pointercancel for the drag's pointer; the label releasing the
  // capture it holds), between real pointer moves.
  await p.evaluate(()=>{window.__scrubPointer=null;document.addEventListener('pointerdown',e=>{window.__scrubPointer=e.pointerId;},true);});
  for(const [how,end] of [
    ['pointer cancellation',()=>label.evaluate(n=>n.dispatchEvent(new PointerEvent('pointercancel',{pointerId:window.__scrubPointer,bubbles:true,pointerType:'mouse'})))],
    ['a lost pointer capture',()=>label.evaluate(n=>n.releasePointerCapture(window.__scrubPointer))]]){
    await label.scrollIntoViewIfNeeded();
    const b=await label.boundingBox();const x=b.x+b.width/2,y=b.y+b.height/2;
    await p.mouse.move(x,y);await p.mouse.down();
    for(let i=1;i<=3;i++)await p.mouse.move(x+5*i,y);
    assert.notEqual(await input.inputValue(),'20',how+': the scrub moves the value first');
    await end();
    await p.mouse.move(x+40,y);await p.mouse.up();
    await p.waitForTimeout(800);
    assert.equal(await input.inputValue(),'20',how+': the value from before the gesture is put back');
    assert.equal(await source(),before,how+': nothing written');
    assert.equal(await undoCount(),h,how+': nothing committed');
    assert.equal(await pending(),0,how+': nothing pending');
  }
  cases.push('a scrub ended by pointer cancellation or a lost pointer capture commits nothing and puts the value back');

  assert.deepEqual(errors,[]);
  console.log('verify_ux_numeric_input_parity passed:',pub,cases.length);
} finally {
  if(browser)await browser.close();
  await new Promise(resolve=>server.close(resolve));
}
