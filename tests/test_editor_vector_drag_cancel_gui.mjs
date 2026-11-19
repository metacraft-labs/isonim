/** A drag on the vector canvas ends without an edit when it is cancelled:
 * Escape, pointer cancellation or (for a path node, whose anchor holds the
 * pointer capture) a lost capture put the canvas back to what it showed
 * before the drag -- no source change, nothing staged or written, no
 * path-history entry -- and the rest of the gesture changes nothing (the
 * editor's drag contract, editor spec "Visual box model": "Escape, pointer
 * cancellation or a lost capture put back the value from before the drag";
 * "Planned interaction parity": "Escape or pointer cancellation restores
 * the value from before the gesture").
 *
 * Cases (writable workspace). (1) A path-node drag cancelled by Escape,
 * (2) by pointer cancellation, (3) by a lost pointer capture: node, path
 * history and file as before; the pointer's further moves and release
 * change nothing; a following drag is still one edit. (4) A Select-tool
 * move cancelled by Escape, (5) a rotation cancelled by pointer
 * cancellation, (6) a multi-selection move cancelled by Escape: the shapes
 * are back, nothing is recorded, and a following move is one edit. (7) A
 * Pencil stroke cancelled by Escape draws nothing and records nothing; the
 * next stroke is one edit. (8-10) A corner resize and a skew of the badge
 * and a corner resize of the card and the badge, cancelled by Escape: every
 * shape's full transform is as before the drag (a resize or skew anchors
 * the opposite corner or side), nothing is recorded, and the next accepted
 * edit writes the shapes at their places. (11) A resize of a band selection
 * holding the editable path's shape, cancelled: its shape and nodes stay
 * where they were and the next nudge starts there. After a node-drag
 * cancel (1-3), the editable path's canvas shape is drawn at the nodes from
 * before the drag.
 *
 * Pointer cancellation and a lost capture cannot be produced by a mouse;
 * they are dispatched as the browser would (a `pointercancel` PointerEvent
 * for the pointer in the drag; `releasePointerCapture` on the anchor that
 * holds it), mid-drag between real pointer moves. No other mocks: the
 * editor example's vector view, fabric adapter and writer
 * (`tests/helpers/editor_shorthand_order_workspace.nim`), served by a plain
 * static server started here; Chromium.
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
const pub=mkdtempSync(path.join(process.env.ISONIM_POPUP_ARTIFACTS||tmpdir(),'vector-drag-cancel-'));
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
await new Promise(resolve=>server.listen(Number(process.env.ISONIM_VECTOR_DRAG_CANCEL_PORT||0),'127.0.0.1',resolve));
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
  const noteShown=()=>note().isVisible();
  // The vector symbol file's written content (the demo workspace's write
  // receipt; the test host publishes its starting content at load): an edit
  // is written once this changes, not merely once nothing is pending --
  // which also holds before the edit's deferred commit has staged anything.
  const vectorFile='examples/wanderlust/design-system/vector-symbols.svg';
  const sources=()=>p.evaluate(f=>{const s=window.__isonimDemoSources;return s&&typeof s[f]==='string'?s[f]:null;},vectorFile);
  async function assertPoll(read,expected,what,ms=20000){
    const deadline=Date.now()+ms;let last;
    while(Date.now()<deadline){last=await read();try{assert.deepEqual(last,expected);return;}catch{}await p.waitForTimeout(100);}
    assert.deepEqual(last,expected,what);
  }
  // An accepted edit made after `before` was read: its source is written,
  // then nothing is left pending and the canvas marks the source saved.
  async function written(before,what){
    assert.equal(typeof before,'string',what+': the vector file held content before the edit');
    await assertPoll(async()=>(await sources())!==before,true,what+': the source is written');
    await assertPoll(pending,0,what+': nothing left pending');
    await assertPoll(()=>host().getAttribute('data-vector-source-pending'),'0',what+': the canvas marks the source saved');
    return sources();
  }
  async function openVector(ro){
    readOnly=ro?'1':'';
    await p.goto(origin+'/?view=vector');
    await host().waitFor();
    // The loaded symbol's objects are imported asynchronously; the accepted
    // canvas is taken once they are.
    await assertPoll(async()=>(await host().getAttribute('data-vector-accepted-count'))===(await host().getAttribute('data-vector-object-count'))&&(await count())>0,true,'the symbol is loaded');
    await p.waitForTimeout(500);
    assert.match(await sources()||'',/<svg/,'the vector file\'s starting content is published');
    await p.evaluate(()=>{window.__vectorEvents=0;document.addEventListener('isonim-vector-source-change',()=>{window.__vectorEvents++;},true);});
  }

  // Where a canvas object is, in canvas coordinates: its centre (fabric 7
  // objects have a centre origin), through its full transform, so a member
  // of a multi-selection reads where it is on the canvas.
  const obj=(name)=>p.evaluate(n=>{const h=document.querySelector('[data-vector-adapter="fabric"][role="application"]');const e=h.__isonimVectorEditor;const o=e.canvas.getObjects().find(o=>o.name===n);if(!o)return null;
    const c=fabric.util.transformPoint(new fabric.Point(0,0),o.calcTransformMatrix());const d=fabric.util.qrDecompose(o.calcTransformMatrix());const r=(v)=>Math.round(v*100)/100;
    return {x:r(c.x),y:r(c.y),scaleX:r(d.scaleX),scaleY:r(d.scaleY),angle:r(d.angle),skewX:r(d.skewX)};},name);
  const active=()=>p.evaluate(()=>{const e=document.querySelector('[data-vector-adapter="fabric"][role="application"]').__isonimVectorEditor;const a=e.canvas.getActiveObject();if(!a)return [];return a instanceof fabric.ActiveSelection?a.getObjects().map(o=>o.name).sort():[a.name];});
  const control=(name,corner)=>p.evaluate(([n,k])=>{const e=document.querySelector('[data-vector-adapter="fabric"][role="application"]').__isonimVectorEditor;const o=e.canvas.getActiveObject();const c=o&&o.oCoords&&o.oCoords[k];return c?[c.x,c.y]:null;},[name,corner]);
  // Page coordinates of a canvas point. No scrolling into view first: the
  // toolbar keeps every action on screen, and a click that scrolled the
  // canvas away would put the pointer off it.
  const at=async(x,y)=>{const b=await host().locator('canvas.upper-canvas').boundingBox();return [b.x+x,b.y+y];};
  async function drag(from,dx,dy,{shift=false}={}){
    const [sx,sy]=await at(from[0],from[1]);
    if(shift)await p.keyboard.down('Shift');
    await p.mouse.move(sx,sy);await p.mouse.down();
    for(let i=1;i<=6;i++)await p.mouse.move(sx+dx*i/6,sy+dy*i/6);
    await p.mouse.up();
    if(shift)await p.keyboard.up('Shift');
  }
  async function click(x,y,{shift=false}={}){const [sx,sy]=await at(x,y);if(shift)await p.keyboard.down('Shift');await p.mouse.click(sx,sy);if(shift)await p.keyboard.up('Shift');}
  // The editor's undo and redo (one timeline), from the page rather than
  // the canvas, which has its own path-node undo keys.
  async function editorKey(combo){await p.evaluate(()=>document.activeElement&&document.activeElement.blur&&document.activeElement.blur());await p.keyboard.press(combo);}
  async function settledAt(bytes,what){await assertPoll(sources,bytes,what+': the file holds exactly these bytes');await assertPoll(pending,0,what+': nothing left pending');}
  // The card's group in the written SVG: its transform matrix.
  const cardMatrix=(svg)=>{const m=/<g transform="(matrix\([^)]*\))"\s*>\s*<rect style="stroke: rgb\(59,130,246\)/.exec(svg||'');return m?m[1]:null;};
  const badgeMatrix=(svg)=>{const m=/<g transform="(matrix\([^)]*\))"\s*>\s*<circle style="stroke: rgb\(16,185,129\)/.exec(svg||'');return m?m[1]:null;};
  const cardAt=[90,110],badgeAt=[300,124];


  const tool=(name)=>p.getByRole('button',{name:'Select '+name+' vector tool',exact:true}).click();
  const names=()=>p.evaluate(()=>document.querySelector('[data-vector-adapter="fabric"][role="application"]').__isonimVectorEditor.canvas.getObjects().map(o=>o.name));
  const textOf=(n)=>p.evaluate(n=>{const o=document.querySelector('[data-vector-adapter="fabric"][role="application"]').__isonimVectorEditor.canvas.getObjects().find(o=>o.name===n);return o?o.text:null;},n);
  const node0=()=>p.evaluate(()=>{const n=document.querySelector('[data-vector-adapter="fabric"][role="application"]').__isonimVectorEditor.pathSegments()[0];return [Math.round(n.x*100)/100,Math.round(n.y*100)/100];});
  async function stroke(points){const [sx,sy]=await at(...points[0]);await p.mouse.move(sx,sy);await p.mouse.down();for(const pt of points.slice(1)){const [x,y]=await at(...pt);await p.mouse.move(x,y);}await p.mouse.up();}
  const wave=[];for(let i=0;i<=24;i++)wave.push([420+i*6,300+Math.round(18*Math.sin(i/3))]);
  async function settleRefused(what,expect){
    await assertPoll(events,expect,what+': one source change');
    await note().waitFor({state:'visible'});
    assert.match(await note().textContent(),readOnlyWhy,what+': the reason is shown under the canvas');
    await p.waitForTimeout(2500);
    assert.equal(await events(),expect,what+': no further source change follows the refusal');
    assert.equal(await pending(),0,what+': nothing staged');
  }
  async function typeIntoTitle(suffix){
    // A double-click on the title enters text editing; End, the suffix,
    // and Escape leave it.
    const [x,y]=await at(60,28);
    await p.mouse.dblclick(x,y);
    await assertPoll(()=>p.evaluate(()=>{const o=document.querySelector('[data-vector-adapter="fabric"][role="application"]').__isonimVectorEditor.canvas.getObjects().find(o=>o.name==='title');return !!(o&&o.isEditing);}),true,'the title is being edited');
    await p.keyboard.press('End');
    await p.keyboard.type(suffix);
    await p.keyboard.press('Escape');
    await assertPoll(()=>p.evaluate(()=>{const o=document.querySelector('[data-vector-adapter="fabric"][role="application"]').__isonimVectorEditor.canvas.getObjects().find(o=>o.name==='title');return !!(o&&o.isEditing);}),false,'the title is left');
  }


  const depths=async()=>[Number(await host().getAttribute('data-vector-path-undo-depth')||0),Number(await host().getAttribute('data-vector-path-redo-depth')||0)];
  const cancelledAs=()=>host().getAttribute('data-vector-gesture-cancelled');
  async function openAndTrack(){
    await openVector(false);
    await p.evaluate(()=>{window.__dragPointer=null;document.addEventListener('pointerdown',e=>{window.__dragPointer=e.pointerId;},true);});
  }
  // Nothing more happens: no source change over a settle period, nothing
  // pending, the file as it was.
  async function nothingRecorded(what,eventsBefore,bytes){
    await p.waitForTimeout(1500);
    assert.equal(await events(),eventsBefore,what+': no source change');
    assert.equal(await pending(),0,what+': nothing staged');
    assert.equal(await sources(),bytes,what+': nothing written');
  }
  const pointercancel=()=>p.evaluate(()=>{const id=window.__dragPointer;const el=document.elementFromPoint(10,10)||document.body;
    (document.querySelector('[data-vector-anchor]:focus')||document.body).dispatchEvent(new PointerEvent('pointercancel',{pointerId:id,bubbles:true,pointerType:'mouse'}));});
  // The editable path's shape on the canvas: its path commands and where it
  // is drawn, and whether it is the shape the editor edits.
  const pathShape=()=>p.evaluate(()=>{const e=document.querySelector('[data-vector-adapter="fabric"][role="application"]').__isonimVectorEditor;const o=e.editablePathObject;
    const r=(v)=>Math.round(v*100)/100;return o?{path:JSON.stringify(o.path),left:r(o.left),top:r(o.top),width:r(o.width),height:r(o.height),onCanvas:e.canvas.getObjects().includes(o),shapes:e.canvas.getObjects().filter(x=>x.name==='editable-path').length}:null;});
  async function nodeDrag(cancelWith){
    const a=host().locator('[data-vector-anchor="node-0"]');const b=await a.boundingBox();
    const x=b.x+b.width/2,y=b.y+b.height/2;
    await p.mouse.move(x,y);await p.mouse.down();
    await p.mouse.move(x+10,y+6);await p.mouse.move(x+20,y+12);
    if(cancelWith){
      await cancelWith();
      await p.mouse.move(x+30,y+18);await p.mouse.move(x+40,y+24);
    }
    await p.mouse.up();
  }

  // 1-3. A path-node drag, cancelled three ways.
  for(const [label,cancel,why] of [
    ['Escape',()=>p.keyboard.press('Escape'),'node-escape'],
    ['pointer cancellation',pointercancel,'node-pointercancel'],
    ['a lost pointer capture',()=>p.evaluate(()=>{const id=window.__dragPointer;const a=document.querySelector('[data-vector-anchor="node-0"]');a.releasePointerCapture(id);}),'node-lost-capture']]){
    await openAndTrack();
    const s0=await sources(),n0=await node0(),d0=await depths(),e0=await events(),shape0=await pathShape();
    await nodeDrag(cancel);
    assert.equal(await cancelledAs(),why,label+': the drag was cancelled');
    assert.deepEqual(await node0(),n0,label+': the node is back where it was before the drag');
    assert.deepEqual(await depths(),d0,label+': no path-history entry');
    assert.deepEqual(await pathShape(),shape0,label+': the editable path\'s shape on the canvas is drawn at the nodes from before the drag');
    await nothingRecorded(label,e0,s0);
    assert.deepEqual(await node0(),n0,label+': the moves and release after the cancel move nothing');
    await nodeDrag(null);
    await written(s0,label+', then a whole drag');
    assert.deepEqual(await node0(),[n0[0]+20,n0[1]+12],label+': a following drag moves the node');
    cases.push('a path-node drag cancelled by '+label+' puts the node and its history back and records nothing; the next drag is one edit');
  }

  // 4. A Select-tool move cancelled by Escape.
  {
    await openAndTrack();
    const s0=await sources(),e0=await events();
    await click(...cardAt);
    const [sx,sy]=await at(...cardAt);
    await p.mouse.move(sx,sy);await p.mouse.down();
    for(let i=1;i<=4;i++)await p.mouse.move(sx+10*i,sy+8*i);
    const mid=await obj('card');assert.notDeepEqual([mid.x,mid.y],[72,96],'the card follows the pointer');
    await p.keyboard.press('Escape');
    await p.mouse.move(sx+60,sy+50);
    await p.mouse.up();
    assert.equal(await cancelledAs(),'transform','the move was cancelled');
    const c=await obj('card');assert.deepEqual([c.x,c.y],[72,96],'the card is back where it was before the drag');
    await nothingRecorded('a cancelled move',e0,s0);
    await click(...cardAt);
    await drag(cardAt,40,30);
    await written(s0,'a following move');
    const c2=await obj('card');assert.deepEqual([c2.x,c2.y],[112,126],'a following move moves the card');
    cases.push('a Select-tool move cancelled by Escape puts the shape back and records nothing; the next move is one edit');
  }

  // 5. A rotation cancelled by pointer cancellation.
  {
    await openAndTrack();
    const s0=await sources(),e0=await events();
    await click(...badgeAt);
    const mtr=await control('badge','mtr');
    const [sx,sy]=await at(...mtr);
    await p.mouse.move(sx,sy);await p.mouse.down();
    for(let i=1;i<=4;i++)await p.mouse.move(sx+18*i,sy+8*i);
    const mid=await obj('badge');assert.ok(Math.abs(mid.angle)>5,'the badge follows the rotation handle ('+mid.angle+')');
    await pointercancel();
    await p.mouse.move(sx+90,sy+60);
    await p.mouse.up();
    assert.equal(await cancelledAs(),'transform','the rotation was cancelled');
    const b=await obj('badge');assert.deepEqual([b.x,b.y,b.angle,b.scaleX],[300,124,0,1],'the badge is back as it was before the drag');
    await nothingRecorded('a cancelled rotation',e0,s0);
    cases.push('a Select-tool rotation cancelled by pointer cancellation puts the shape back and records nothing');
  }

  // 6. A multi-selection move cancelled by Escape.
  {
    await openAndTrack();
    const s0=await sources(),e0=await events();
    await click(...cardAt);await click(...badgeAt,{shift:true});
    assert.deepEqual(await active(),['badge','card'],'the card and the badge are selected');
    const [sx,sy]=await at(...badgeAt);
    await p.mouse.move(sx,sy);await p.mouse.down();
    for(let i=1;i<=4;i++)await p.mouse.move(sx+8*i,sy+6*i);
    await p.keyboard.press('Escape');
    await p.mouse.up();
    const c=await obj('card'),b=await obj('badge');
    assert.deepEqual([c.x,c.y,b.x,b.y],[72,96,300,124],'both are back where they were');
    await nothingRecorded('a cancelled multi-selection move',e0,s0);
    cases.push('a multi-selection move cancelled by Escape puts both shapes back and records nothing');
  }

  // 7. A Pencil stroke cancelled by Escape.
  {
    await openAndTrack();
    const s0=await sources(),e0=await events(),n=await count();
    await tool('Pencil');
    const [sx,sy]=await at(420,300);
    await p.mouse.move(sx,sy);await p.mouse.down();
    for(let i=1;i<=10;i++)await p.mouse.move(sx+8*i,sy+Math.round(12*Math.sin(i/2)));
    await p.keyboard.press('Escape');
    for(let i=11;i<=14;i++)await p.mouse.move(sx+8*i,sy);
    await p.mouse.up();
    assert.equal(await cancelledAs(),'stroke','the stroke was cancelled');
    assert.equal(await count(),n,'no stroke is drawn');
    await nothingRecorded('a cancelled stroke',e0,s0);
    await p.mouse.move(sx,sy+40);await p.mouse.down();
    for(let i=1;i<=10;i++)await p.mouse.move(sx+8*i,sy+40+Math.round(12*Math.sin(i/2)));
    await p.mouse.up();
    await assertPoll(count,n+1,'a following stroke is drawn');
    await written(s0,'a following stroke');
    cases.push('a Pencil stroke cancelled by Escape draws and records nothing; the next stroke is one edit');
  }


  // 8-11. A resize, a skew and a multi-selection resize cancelled by Escape,
  // and a multi-selection holding the editable path's shape: everything is
  // where it was before the drag (fabric's resize and skew anchor the
  // opposite corner or side), and the next accepted edit writes it there.
  const all=()=>p.evaluate(()=>{const e=document.querySelector('[data-vector-adapter="fabric"][role="application"]').__isonimVectorEditor;const r=(v)=>Math.round(v*100)/100;
    return Object.fromEntries(e.canvas.getObjects().map(o=>{const m=o.calcTransformMatrix();return [o.name,m.map(r)];}));});
  async function cancelledDrag(from,dx,dy,{shift=false}={}){
    const [sx,sy]=await at(...from);
    if(shift)await p.keyboard.down('Shift');
    await p.mouse.move(sx,sy);await p.mouse.down();
    for(let i=1;i<=4;i++)await p.mouse.move(sx+dx*i/4,sy+dy*i/4);
    await p.keyboard.press('Escape');
    await p.mouse.move(sx+dx*1.5,sy+dy*1.5);
    await p.mouse.up();
    if(shift)await p.keyboard.up('Shift');
  }
  // After a cancel: a whole node nudge is accepted and written; the written
  // file has every shape at its place from before the cancelled drag.
  async function nextEditWritesOriginal(what,s0,before){
    await p.locator('[data-vector-action="path-nudge-right"]').first().click();
    const s1=await written(s0,what+', then a node nudge');
    const after=await all();
    for(const [name,m] of Object.entries(before)){if(name==='editable-path')continue;assert.deepEqual(after[name],m,what+': '+name+' still where it was after the next edit');}
    return s1;
  }
  for(const [label,setup,handle,dx,dy,shift] of [
    ['a corner resize of the badge',async()=>{await click(...badgeAt);},'br',40,40,false],
    ['a skew of the badge',async()=>{await click(...badgeAt);},'mr',0,40,true],
    ['a corner resize of the card and the badge',async()=>{await click(...cardAt);await click(...badgeAt,{shift:true});},'br',40,30,false]]){
    await openAndTrack();
    const s0=await sources(),e0=await events();
    await setup();
    const before=await all();
    const corner=await control(null,handle);assert(corner,label+': the '+handle+' handle is on the canvas');
    await cancelledDrag(corner,dx,dy,{shift});
    assert.equal(await cancelledAs(),'transform',label+': the drag was cancelled');
    assert.deepEqual(await all(),before,label+': every shape is where it was before the drag');
    await nothingRecorded(label,e0,s0);
    const s1=await nextEditWritesOriginal(label,s0,before);
    assert.equal(badgeMatrix(s1),'matrix(1 0 0 1 300 124)',label+': the next edit writes the badge at its place');
    assert.equal(cardMatrix(s1),'matrix(1 0 0 1 72 96)',label+': and the card at its place');
    cases.push(label+' cancelled by Escape puts every shape back as it was, and the next edit writes them there');
  }
  {
    // The editable path's shape and the title, band-selected from an empty
    // spot (the shape alone lies under its node handles), resized by the
    // selection's corner handle and cancelled.
    await openAndTrack();
    const s0=await sources(),e0=await events(),n0=await node0(),shape0=await pathShape();
    await drag([70,3],-68,19);
    const members=await active();
    assert.ok(members.includes('editable-path')&&members.includes('title'),'the band selected the editable path\'s shape and the title ('+members.join(',')+')');
    const before=await all();
    const corner=await control(null,'br');
    await cancelledDrag(corner,50,40);
    assert.equal(await cancelledAs(),'transform','the drag was cancelled');
    assert.deepEqual(await all(),before,'the editable path\'s shape and the title are where they were');
    assert.deepEqual(await node0(),n0,'the path\'s nodes did not move');
    await nothingRecorded('a cancelled resize holding the editable path',e0,s0);
    await p.locator('[data-vector-action="path-nudge-right"]').first().click();
    await written(s0,'then a node nudge');
    assert.deepEqual(await node0(),[n0[0]+4,n0[1]],'the nudge starts from the nodes before the drag');
    const shape=await pathShape();
    assert.equal(shape.shapes,1,'one editable path shape');
    assert.equal(shape.onCanvas,true,'the editable path shape is on the canvas');
    cases.push('a resize of a multi-selection holding the editable path\'s shape, cancelled by Escape, puts its shape back with its nodes, and the next nudge starts there');
  }

  assert.deepEqual(errors,[]);
  console.log('Vector drag cancel GUI passed:',pub,cases.length);
} finally {
  if(browser)await browser.close();
  await new Promise(resolve=>server.close(resolve));
}
