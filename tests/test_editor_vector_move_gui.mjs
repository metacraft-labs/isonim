/** A move, resize, rotation or skew of an existing vector object with the
 * Select tool is a vector edit: it stages a source edit and is written like
 * any other, the editor's undo and redo put back the file's exact bytes and
 * the canvas with them, and in a workspace read-only for source changes it
 * is refused at the act and the canvas goes back, with the reason shown
 * (isonim-pm issue 2026-11-18-moving-an-existing-vector-shape-with-the-
 * pointer-is-never-written-to-the-source; editor spec "Vector Tools":
 * Select moves, resizes and rotates objects; "Saving": a vector edit is a
 * commit, undo/redo of it are commits, one timeline).
 *
 * Cases. Writable: (1) a pointer move of the loaded `card` shape is one
 * source change, written with the card at its new place; Cmd+Z writes back
 * the file's bytes from before the move and puts the card back, and
 * Cmd+Shift+Z writes the moved bytes again and moves it again. (2) A resize
 * with a corner handle, a rotation with the rotation handle and a skew with
 * a side handle and Shift (of the `badge`, whose handles are on the
 * canvas): one written change each, undone and redone at exact bytes; the
 * toolbar's Transform stays one change. (3) A multi-selection move: one
 * change, both shapes written at their moved canvas positions (not
 * positions relative to the selection), the two stay selected, undo and
 * redo move both, and a refused move after it (writes withdrawn) goes back
 * to it. (4) A path-node drag and a node nudge stay one change each, and a
 * click on a node is none; a pointer move of the editable path's shape (in
 * a band selection) is one change too, and the next node nudge starts
 * where the shape was moved to. (5) A click that moves nothing stages
 * nothing. Read-only: (6) a refused move, rotation and multi-selection move
 * each put the shapes back, show the reason, stage and write nothing, and
 * cause no further source change.
 *
 * No mocks: the editor example's real vector view, fabric adapter and
 * writer (`tests/helpers/editor_shorthand_order_workspace.nim`), served by a
 * plain static server started here; Chromium and real pointer input.
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
const pub=mkdtempSync(path.join(process.env.ISONIM_POPUP_ARTIFACTS||tmpdir(),'vector-move-'));
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
await new Promise(resolve=>server.listen(Number(process.env.ISONIM_VECTOR_MOVE_PORT||0),'127.0.0.1',resolve));
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

  // 1. Writable: a pointer move, written; undo and redo at exact bytes.
  {
    await openVector(false);
    const s0=await sources();
    const start=await obj('card');
    assert.deepEqual([start.x,start.y],[72,96],'the card starts at 72,96');
    await click(...cardAt);
    assert.deepEqual(await active(),['card'],'the card is selected');
    assert.equal(await events(),0,'selecting stages nothing');
    await drag(cardAt,40,30);
    const moved=await obj('card');
    assert.deepEqual([moved.x,moved.y],[112,126],'the card moved by the drag');
    const s1=await written(s0,'the move');
    assert.equal(cardMatrix(s1),'matrix(1 0 0 1 112 126)','the written card is at its new place');
    await p.waitForTimeout(800);
    assert.equal(await events(),1,'one source change for the move');
    await editorKey('Control+z');
    await settledAt(s0,'undo of the move');
    await assertPoll(async()=>{const c=await obj('card');return [c.x,c.y];},[72,96],'undo puts the card back on the canvas');
    await editorKey('Control+Shift+z');
    await settledAt(s1,'redo of the move');
    await assertPoll(async()=>{const c=await obj('card');return [c.x,c.y];},[112,126],'redo moves the card again');
    assert.equal(await noteShown(),false,'no refusal shown');
    cases.push('writable: a pointer move of an existing shape is one written source change; undo and redo write the exact bytes back and move the shape with them');
  }

  // 2. Writable: resize, rotate, skew with the fabric controls.
  {
    await openVector(false);
    const s0=await sources();
    await click(...badgeAt);
    const br=await control('badge','br');assert(br,'the badge has a corner handle');
    await drag(br,36,22);
    const scaled=await obj('badge');
    assert.ok(scaled.scaleX>1.05&&scaled.scaleY>1.05,'the corner handle scaled the badge ('+scaled.scaleX+','+scaled.scaleY+')');
    const s1=await written(s0,'the resize');
    assert.notEqual(badgeMatrix(s1),badgeMatrix(s0)||null,'the written badge carries the resize');
    assert.equal(await host().getAttribute('data-vector-modified-action'),'scale','fabric reports a scale');
    const mtr=await control('badge','mtr');assert(mtr,'the badge has a rotation handle');
    await drag(mtr,70,30);
    const rotated=await obj('badge');
    assert.ok(Math.abs(rotated.angle)>5,'the rotation handle rotated the badge ('+rotated.angle+')');
    const s2=await written(s1,'the rotation');
    assert.equal(await host().getAttribute('data-vector-modified-action'),'rotate','fabric reports a rotation');
    const mr=await control('badge','mr');assert(mr,'the badge has a side handle');
    await drag(mr,0,40,{shift:true});
    const skewed=await obj('badge');
    const s3=await written(s2,'the skew');
    assert.match(await host().getAttribute('data-vector-modified-action'),/^skew/,'fabric reports a skew');
    assert.notDeepEqual(skewed,rotated,'the side handle with Shift skewed the badge');
    await p.waitForTimeout(800);
    assert.equal(await events(),3,'one source change each');
    await editorKey('Control+z');
    await settledAt(s2,'undo of the skew');
    assert.deepEqual(await obj('badge'),rotated,'undo of the skew puts the rotated badge back');
    await editorKey('Control+z');
    await settledAt(s1,'undo of the rotation');
    assert.deepEqual(await obj('badge'),scaled,'undo of the rotation puts the scaled badge back');
    await editorKey('Control+z');
    await settledAt(s0,'undo of the resize');
    await editorKey('Control+Shift+z');
    await settledAt(s1,'redo of the resize');
    assert.deepEqual(await obj('badge'),scaled,'redo of the resize');
    // The toolbar's Transform records its own change: still one.
    const n=await events();
    await click(...badgeAt);
    await p.locator('[data-vector-action="transform-selection"]').first().click();
    await written(s1,'the toolbar transform');
    await p.waitForTimeout(800);
    assert.equal(await events(),n+1,'the toolbar transform is one source change');
    cases.push('writable: a resize, a rotation and a skew with the fabric handles are one written change each, undone and redone at exact bytes; the toolbar transform stays one change');
  }

  // 3. Writable: a multi-selection move.
  {
    await openVector(false);
    const s0=await sources();
    await click(...cardAt);
    await click(...badgeAt,{shift:true});
    assert.deepEqual(await active(),['badge','card'],'the card and the badge are selected');
    await drag(badgeAt,30,20);
    const s1=await written(s0,'the multi-selection move');
    assert.equal(cardMatrix(s1),'matrix(1 0 0 1 102 116)','the card is written at its canvas position');
    assert.equal(badgeMatrix(s1),'matrix(1 0 0 1 330 144)','the badge is written at its canvas position');
    const card=await obj('card'),badge=await obj('badge');
    assert.deepEqual([card.x,card.y,badge.x,badge.y],[102,116,330,144],'both moved on the canvas');
    assert.deepEqual(await active(),['badge','card'],'the two stay selected');
    await p.waitForTimeout(800);
    assert.equal(await events(),1,'one source change for the multi-selection move');
    await editorKey('Control+z');
    await settledAt(s0,'undo of the multi-selection move');
    const c0=await obj('card'),b0=await obj('badge');
    assert.deepEqual([c0.x,c0.y,b0.x,b0.y],[72,96,300,124],'undo puts both back');
    await editorKey('Control+Shift+z');
    await settledAt(s1,'redo of the multi-selection move');
    const c1=await obj('card'),b1=await obj('badge');
    assert.deepEqual([c1.x,c1.y,b1.x,b1.y],[102,116,330,144],'redo moves both again, to canvas positions');
    // The canvas accepted with the move, put back after a refusal.
    await p.evaluate(()=>window.__isonimShorthandSetWriteSource(false));
    await click(30,80);await click(330,144,{shift:true});
    assert.deepEqual(await active(),['badge','card'],'the two are selected again');
    await drag([330,144],-50,30);
    await note().waitFor({state:'visible'});
    await p.waitForTimeout(800);
    const c2=await obj('card'),b2=await obj('badge');
    assert.deepEqual([c2.x,c2.y,b2.x,b2.y],[102,116,330,144],'a refused move goes back to the accepted multi-selection move');
    assert.equal(await sources(),s1,'nothing written');
    cases.push('writable: a multi-selection move is one change, written at canvas positions, undone and redone for both shapes; a later refusal goes back to it');
  }

  // 4. Path nodes: one change each; the editable path's shape moved whole.
  {
    await openVector(false);
    const node0=()=>p.evaluate(()=>{const e=document.querySelector('[data-vector-adapter="fabric"][role="application"]').__isonimVectorEditor;const n=e.pathSegments()[0];return [Math.round(n.x*100)/100,Math.round(n.y*100)/100];});
    const s0=await sources();
    const a=host().locator('[data-vector-anchor="node-0"]');const b=await a.boundingBox();
    await p.mouse.move(b.x+b.width/2,b.y+b.height/2);await p.mouse.down();await p.mouse.move(b.x+b.width/2+10,b.y+b.height/2+6);await p.mouse.move(b.x+b.width/2+20,b.y+b.height/2+12);await p.mouse.up();
    const s1=await written(s0,'the node drag');
    await p.waitForTimeout(800);
    assert.equal(await events(),1,'a node drag is one source change');
    await p.locator('[data-vector-action="path-nudge-right"]').first().click();
    const s2=await written(s1,'the node nudge');
    await p.waitForTimeout(800);
    assert.equal(await events(),2,'a node nudge is one source change');
    // A click on a node selects it and is no edit.
    await p.evaluate(()=>{const h=document.querySelector('[data-vector-adapter="fabric"][role="application"]');h.__isonimVectorEditor.selectPathNode('node-1');});
    const n0=host().locator('[data-vector-anchor="node-0"]');const nb=await n0.boundingBox();
    await p.mouse.click(nb.x+nb.width/2,nb.y+nb.height/2);
    assert.equal(await host().getAttribute('data-vector-path-selected-nodes'),'node-0','the click selected node 0');
    await p.waitForTimeout(800);
    assert.equal(await events(),2,'a click on a node is no source change');
    const before=await node0();
    const depth=Number(await host().getAttribute('data-vector-path-undo-depth'));
    // The editable path's shape, moved with the pointer: a band selection
    // from an empty spot takes it and the title (the shape alone lies under
    // its node handles), and the selection is dragged by the title.
    await drag([2,2],58,22);
    const members=await active();
    assert.ok(members.includes('editable-path')&&members.includes('title'),'the band selected the editable path\'s shape and the title ('+members.join(',')+')');
    await drag([100,30],24,16);
    const s3=await written(s2,'the move of the editable path\'s shape');
    await p.waitForTimeout(800);
    assert.equal(await events(),3,'moving the editable path\'s shape is one source change');
    assert.deepEqual(await node0(),[before[0]+24,before[1]+16],'the editable path moved with its shape');
    assert.equal(Number(await host().getAttribute('data-vector-path-undo-depth')),depth+1,'one path history entry');
    assert.deepEqual(await active(),members.slice().sort(),'the selection is kept');
    await p.locator('[data-vector-action="path-nudge-right"]').first().click();
    await written(s3,'the next node nudge');
    assert.deepEqual(await node0(),[before[0]+28,before[1]+16],'the next nudge starts where the shape was moved to');
    cases.push('path nodes: a node drag and a node nudge stay one change each; moving the editable path\'s shape is one change and the path moves with it');
  }

  // 5. A click that moves nothing.
  {
    await openVector(false);
    const s0=await sources();
    await click(...cardAt);await click(...badgeAt);await click(...cardAt);
    await p.waitForTimeout(1500);
    assert.equal(await events(),0,'selecting by clicking is no source change');
    assert.equal(await pending(),0,'nothing staged');
    assert.equal(await sources(),s0,'nothing written');
    cases.push('a click that selects without moving stages nothing');
  }

  // 6. Read-only: refused at the act, put back, no loop.
  {
    await openVector(true);
    const s0=await sources();
    // The refused edit's source change is recorded a moment after the
    // release (and the note may still show the previous refusal), so wait
    // for that change itself, then watch for any that follows it.
    const settle=async(what,expect)=>{
      await assertPoll(events,expect,what+': one source change each');
      await note().waitFor({state:'visible'});
      assert.match(await note().textContent(),readOnlyWhy,what+': the reason is shown under the canvas');
      await p.waitForTimeout(2500);
      assert.equal(await events(),expect,what+': no further source change follows the refusal');
      assert.equal(await pending(),0,what+': nothing staged');
      assert.equal(await sources(),s0,what+': nothing written');
    };
    await click(...cardAt);
    await drag(cardAt,40,30);
    await settle('a refused move',1);
    const c=await obj('card');assert.deepEqual([c.x,c.y,c.angle],[72,96,0],'the refused move puts the card back');
    await click(...badgeAt);
    const mtr=await control('badge','mtr');
    await drag(mtr,70,30);
    await settle('a refused rotation',2);
    const r=await obj('badge');assert.deepEqual([r.x,r.y,r.angle,r.scaleX],[300,124,0,1],'the refused rotation puts the badge back');
    await click(...cardAt);await click(...badgeAt,{shift:true});
    await drag(badgeAt,30,20);
    await settle('a refused multi-selection move',3);
    const c2=await obj('card'),b2=await obj('badge');
    assert.deepEqual([c2.x,c2.y,b2.x,b2.y],[72,96,300,124],'the refused multi-selection move puts both back');
    cases.push('read-only: a refused move, rotation and multi-selection move are put back once, with the reason, nothing staged or written');
  }

  assert.deepEqual(errors,[]);
  console.log('Vector move GUI passed:',pub,cases.length);
} finally {
  if(browser)await browser.close();
  await new Promise(resolve=>server.close(resolve));
}
