/** A vector canvas edit the editor refuses at the act is taken off the
 * canvas, back to the canvas the editor last accepted, once -- with no
 * further source change -- and its reason is shown under the canvas
 * (isonim-pm issue 2026-11-18-a-canvas-drag-in-a-read-only-workspace-is-
 * staged-instead-of-refused-at-the-act, vector editor; review V1/V2 of
 * ro-canvas round 2; editor spec "Saving": a refusal the editor can know at
 * the act is made at the act, so a refused change never reaches the
 * preview, the history or the journal).
 *
 * Cases: (1) a workspace read-only for source changes: one drawing with the
 * Rectangle tool is refused -- the shape count returns to the count before
 * the drawing, no further source-change event follows over a settle period
 * (the restore does not go through the tool, which would draw again), the
 * reason is shown, nothing is staged. (2) A writable workspace: a drawing is
 * accepted and staged; then source writes are withdrawn
 * (`window.__isonimShorthandSetWriteSource(false)`) and the next drawing is
 * refused -- the canvas goes back to the canvas with the accepted drawing,
 * which stays. (3, 4) Read-only, a refused node nudge and a refused node
 * pointer drag: the Paper.js editable path, its handles and its canvas shape
 * go back to the accepted ones. (5) Writable, writes withdrawn, two refused
 * nudges, writes granted, one accepted nudge: one nudge from the accepted
 * path, one editable path.
 *
 * No mocks: the editor example's real vector view, fabric adapter and
 * writer (`tests/helpers/editor_shorthand_order_workspace.nim`), served by a
 * plain static server started here; Chromium.
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
const pub=mkdtempSync(path.join(process.env.ISONIM_POPUP_ARTIFACTS||tmpdir(),'vector-refusal-'));
copyFileSync(bundle,pub+'/editor.js');
for(const [from,to] of [['node_modules/fabric/dist/index.min.js','fabric.min.js'],['node_modules/paper/dist/paper-core.min.js','paper-core.min.js'],['node_modules/svgo/dist/svgo.browser.js','svgo.browser.js']])copyFileSync(repo+'/'+from,pub+'/'+to);
const index=readFileSync(repo+'/src/isonim/editor/index.html','utf8');
let readOnly='';
const page=()=>index.replace('<script src="editor.js"></script>','<script>window.__isonimShorthandReadOnly='+JSON.stringify(readOnly)+';window.__isonimShorthandVectorSymbols="1";</script><script src="editor.js"></script>');
const types={'.js':'text/javascript','.mjs':'text/javascript','.html':'text/html'};
const server=createServer((req,res)=>{const url=new URL(req.url,'http://x');const name=url.pathname==='/'?'index.html':url.pathname.slice(1);
  if(name==='index.html'){res.writeHead(200,{'content-type':'text/html'});res.end(page());return;}
  const file=path.join(pub,path.basename(name));if(!existsSync(file)){res.writeHead(404);res.end();return;}
  res.writeHead(200,{'content-type':types[path.extname(file)]||'application/octet-stream'});res.end(readFileSync(file));});
await new Promise(resolve=>server.listen(Number(process.env.ISONIM_VECTOR_REFUSAL_PORT||0),'127.0.0.1',resolve));
const origin='http://127.0.0.1:'+server.address().port;
const cases=[],errors=[];
const readOnlyWhy=/This workspace is read-only for source changes\./;
let browser;
try {
  const env={...process.env};delete env.LD_LIBRARY_PATH;
  browser=await chromium.launch({headless:true,env,executablePath:process.env.PLAYWRIGHT_CHROMIUM_EXECUTABLE});
  const p=await browser.newPage({viewport:{width:1440,height:900}});p.setDefaultTimeout(30000);
  p.on('pageerror',e=>errors.push(e.message));
  await p.route(url=>!url.href.startsWith(origin),route=>route.abort());
  const host=()=>p.locator('[data-vector-adapter="fabric"][role="application"]');
  const count=async()=>Number(await host().getAttribute('data-vector-object-count'));
  const events=()=>p.evaluate(()=>window.__vectorEvents);
  const pending=()=>p.evaluate(()=>window.__isonimEditor.pendingSourceEdits());
  const note=()=>p.locator('[data-vector-refusal]');
  async function assertPoll(read,expected,what,ms=20000){
    const deadline=Date.now()+ms;let last;
    while(Date.now()<deadline){last=await read();try{assert.deepEqual(last,expected);return;}catch{}await p.waitForTimeout(100);}
    assert.deepEqual(last,expected,what);
  }
  async function openVector(ro){
    readOnly=ro?'1':'';
    await p.goto(origin+'/?view=vector');
    await host().waitFor();
    // The loaded symbol's objects are imported asynchronously; the accepted
    // canvas is taken once they are.
    await assertPoll(async()=>(await host().getAttribute('data-vector-accepted-count'))===(await host().getAttribute('data-vector-object-count'))&&(await count())>0,true,'the symbol is loaded');
    await p.waitForTimeout(500);
    await p.evaluate(()=>{window.__vectorEvents=0;document.addEventListener('isonim-vector-source-change',()=>{window.__vectorEvents++;},true);});
  }
  const draw=(tool)=>p.getByRole('button',{name:'Select '+tool+' vector tool',exact:true}).click();

  // 1. Read-only: one refused drawing, once.
  {
    await openVector(true);
    const before=await count();
    await draw('Rectangle');
    await note().waitFor({state:'visible'});
    assert.match(await note().textContent(),readOnlyWhy,'the reason is shown under the canvas');
    await assertPoll(count,before,'the canvas goes back to its count before the drawing',5000);
    const settled=await events();
    await p.waitForTimeout(3000);
    assert.equal(await count(),before,'no shape is drawn again');
    assert.equal(await events(),settled,'no further source change follows the refusal');
    assert.ok(settled<=1,'one source change: the drawing ('+settled+')');
    assert.equal(await pending(),0,'nothing staged');
    cases.push('read-only: a refused drawing is taken off the canvas once, with the reason shown and nothing staged');
  }

  // 2. Writable, then source writes withdrawn: the accepted drawing stays.
  {
    await openVector(false);
    const before=await count();
    await draw('Rectangle');
    await assertPoll(count,before+1,'the accepted drawing is on the canvas');
    await assertPoll(async()=>(await host().getAttribute('data-vector-accepted-count'))===String(before+1),true,'the drawing is the accepted canvas');
    assert.equal(await note().isVisible(),false,'no refusal shown');
    await p.evaluate(()=>window.__isonimShorthandSetWriteSource(false));
    const eventsBefore=await events();
    await draw('Ellipse');
    await note().waitFor({state:'visible'});
    assert.match(await note().textContent(),readOnlyWhy,'the reason is shown under the canvas');
    await assertPoll(count,before+1,'back to the canvas with the accepted drawing, not the loaded symbol',5000);
    await p.waitForTimeout(3000);
    assert.equal(await count(),before+1,'the accepted drawing stays');
    assert.equal(await events(),eventsBefore+1,'one source change for the refused drawing, none after');
    cases.push('writable then read-only: a refusal after an accepted drawing goes back to the accepted canvas, which keeps the drawing');
  }

  // 3-5. Path-node edits (review P1 of ro-canvas round 3): a node edit
  // changes the Paper.js editable path behind the canvas's editable-path
  // shape, and a refusal must put that back too -- its nodes, its handles on
  // the overlay, and which canvas object draws it -- or the next accepted
  // path edit writes the refused change.
  const pathState=()=>p.evaluate(()=>{const h=document.querySelector('[data-vector-adapter="fabric"][role="application"]');const e=h.__isonimVectorEditor;const c=e.canvas;
    const anchor=h.querySelector('[data-vector-anchor="node-0"]');
    return {nodes:e.pathSegments().map(n=>[Math.round(n.x*100)/100,Math.round(n.y*100)/100]),anchor0:anchor?[anchor.style.left,anchor.style.top]:null,
      editablePaths:c.getObjects().filter(o=>o.name==='editable-path').length,editableOnCanvas:c.getObjects().includes(e.editablePathObject),count:c.getObjects().length};});
  const action=(a)=>p.locator('[data-vector-action="'+a+'"]').first().click();
  async function dragAnchor(){const a=host().locator('[data-vector-anchor="node-0"]');const b=await a.boundingBox();assert(b,'node-0 has an anchor');const x=b.x+b.width/2,y=b.y+b.height/2;await p.mouse.move(x,y);await p.mouse.down();await p.mouse.move(x+10,y+6);await p.mouse.move(x+20,y+12);await p.mouse.up();}
  for(const [label,edit] of [['a node nudge',()=>action('path-nudge-right')],['a node pointer drag',dragAnchor]]){
    await openVector(true);
    const before=await pathState();
    assert.equal(before.editablePaths,1);
    await edit();
    await note().waitFor({state:'visible'});
    assert.match(await note().textContent(),readOnlyWhy,label+': the reason is shown under the canvas');
    await p.waitForTimeout(800);
    assert.deepEqual(await pathState(),before,label+': the editable path, its handles and its canvas shape are back at the accepted positions');
    assert.equal(await pending(),0,label+': nothing staged');
    cases.push('read-only: '+label+' is refused and the editable path goes back to its accepted nodes and handles');
  }
  {
    // Writable: accept a drawing; withdraw writes; two refused nudges;
    // grant writes again; one accepted nudge moves node 0 by one nudge from
    // the accepted position, with one editable path.
    await openVector(false);
    await draw('Rectangle');
    const accepted=await (async()=>{await assertPoll(async()=>(await host().getAttribute('data-vector-accepted-count'))===String((await pathState()).count),true,'the drawing is accepted');return pathState();})();
    await assertPoll(pending,0,'the drawing is written');
    await p.evaluate(()=>window.__isonimShorthandSetWriteSource(false));
    for(let i=0;i<2;i++){await action('path-nudge-right');await note().waitFor({state:'visible'});await p.waitForTimeout(500);}
    assert.deepEqual(await pathState(),accepted,'after two refused nudges the path is the accepted one');
    await p.evaluate(()=>window.__isonimShorthandSetWriteSource(true));
    await action('path-nudge-right');
    await assertPoll(async()=>(await pathState()).nodes[0],[accepted.nodes[0][0]+4,accepted.nodes[0][1]],'the accepted nudge moves node 0 once from the accepted position');
    const after=await pathState();
    assert.equal(after.count,accepted.count,'no duplicate editable path');
    assert.equal(after.editablePaths,1,'one editable path');
    assert.equal(after.editableOnCanvas,true,'the editable-path reference is on the canvas');
    await assertPoll(pending,0,'the nudge is written');
    assert.equal(await note().isVisible(),false,'no refusal shown after the accepted nudge');
    cases.push('writable, writes withdrawn then granted: two refused nudges leave no trace, and the next accepted nudge writes one nudge from the accepted path');
  }

  assert.deepEqual(errors,[]);
  console.log('Vector refusal GUI passed:',pub,cases.length);
} finally {
  if(browser)await browser.close();
  await new Promise(resolve=>server.close(resolve));
}
