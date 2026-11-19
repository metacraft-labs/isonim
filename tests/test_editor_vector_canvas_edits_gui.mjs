/** Vector canvas edits besides drawing with a shape tool and the Select
 * tool's transforms (isonim-pm vector follow-ups of the pointer-move fix;
 * editor spec "Vector Tools": "Pencil | Freehand drawing, auto-smoothed",
 * "Text | Text on canvas"; "Saving": every vector edit is a commit, one
 * timeline for undo and redo).
 *
 * Cases. (1) Pencil, writable: a pointer stroke adds one smoothed path,
 * one source change, written; the editor's undo and redo write the exact
 * bytes back and take the stroke off and put it on again. (2) Pencil,
 * read-only: the stroke is refused at the act, taken off, the reason shown,
 * nothing written, no further change. (3) Text, writable: typing into the
 * title and leaving it is one written change; undo and redo at exact bytes
 * put the text back and again. (4) Text, read-only: refused, the text goes
 * back. (5) Ctrl+Z with the canvas focused is one undo of the one timeline:
 * after a node nudge and a card move, the first undo takes back only the
 * move, the second only the nudge, and Ctrl+Shift+Z redoes the nudge -- no
 * path-node undo runs beside it and no extra entry appears; with a path
 * redo available, Ctrl+Y does nothing. (6) A pointer node drag is one
 * path-history entry, so the toolbar's path undo takes it back. (7) At
 * 1440, 900 and 769px (the narrowest width the vector view is shown at)
 * the toolbars keep every action on screen -- no clipping ancestor or the
 * viewport cuts one, and nothing is drawn over it -- and clicking one does
 * not scroll the canvas away.
 *
 * No mocks: the editor example's real vector view, fabric adapter and
 * writer (`tests/helpers/editor_shorthand_order_workspace.nim`), served by a
 * plain static server started here; Chromium and real pointer and keyboard
 * input.
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
const pub=mkdtempSync(path.join(process.env.ISONIM_POPUP_ARTIFACTS||tmpdir(),'vector-canvas-edits-'));
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
await new Promise(resolve=>server.listen(Number(process.env.ISONIM_VECTOR_CANVAS_EDITS_PORT||0),'127.0.0.1',resolve));
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

  // 1. Pencil, writable.
  {
    await openVector(false);
    const s0=await sources();const before=await count();
    await tool('Pencil');
    await stroke(wave);
    await assertPoll(count,before+1,'the stroke is on the canvas');
    const drawn=await p.evaluate(()=>{const o=document.querySelector('[data-vector-adapter="fabric"][role="application"]').__isonimVectorEditor.canvas.getObjects().find(o=>o.name==='drawn-pencil');return o?{commands:o.path.map(c=>c[0]).join(''),stroke:o.stroke}:null;});
    assert(drawn,'the stroke is a drawn-pencil path');
    assert.match(drawn.commands,/Q/,'the stroke is smoothed (quadratic segments): '+drawn.commands);
    const s1=await written(s0,'the stroke');
    assert.ok((s1.match(/<path/g)||[]).length>(s0.match(/<path/g)||[]).length||s1.includes('stroke: rgb(248,250,252)'),'the written source has the stroke');
    await p.waitForTimeout(800);
    assert.equal(await events(),1,'one source change per stroke');
    await editorKey('Control+z');
    await settledAt(s0,'undo of the stroke');
    assert.equal(await count(),before,'undo takes the stroke off');
    await editorKey('Control+Shift+z');
    await settledAt(s1,'redo of the stroke');
    assert.equal(await count(),before+1,'redo puts it on again');
    cases.push('Pencil, writable: a stroke is one smoothed path and one written change, undone and redone at exact bytes');
  }

  // 2. Pencil, read-only.
  {
    await openVector(true);
    const s0=await sources();const before=await count();
    await tool('Pencil');
    await stroke(wave);
    await settleRefused('a refused stroke',1);
    assert.equal(await count(),before,'the refused stroke is taken off');
    assert.ok(!(await names()).includes('drawn-pencil'),'no pencil path stays');
    assert.equal(await sources(),s0,'nothing written');
    cases.push('Pencil, read-only: a stroke is refused at the act and taken off, with the reason, once');
  }

  // 3. Text, writable.
  {
    await openVector(false);
    const s0=await sources();const t0=await textOf('title');
    await typeIntoTitle(' probe');
    assert.equal(await textOf('title'),t0+' probe','the title holds the typed text');
    const s1=await written(s0,'the text edit');
    assert.ok(s1.includes(t0+' probe')||s1.includes('probe'),'the written source has the text');
    await p.waitForTimeout(800);
    assert.equal(await events(),1,'one source change for the text edit');
    await editorKey('Control+z');
    await settledAt(s0,'undo of the text edit');
    assert.equal(await textOf('title'),t0,'undo puts the text back');
    await editorKey('Control+Shift+z');
    await settledAt(s1,'redo of the text edit');
    assert.equal(await textOf('title'),t0+' probe','redo types it again');
    cases.push('text, writable: an edit of the canvas text is one written change, undone and redone at exact bytes');
  }

  // 4. Text, read-only.
  {
    await openVector(true);
    const s0=await sources();const t0=await textOf('title');
    await typeIntoTitle(' probe');
    await settleRefused('a refused text edit',1);
    assert.equal(await textOf('title'),t0,'the refused text edit is put back');
    assert.equal(await sources(),s0,'nothing written');
    cases.push('text, read-only: a canvas text edit is refused at the act and put back, with the reason, once');
  }

  // 5. Ctrl+Z on the focused canvas: one undo of one timeline.
  {
    await openVector(false);
    const s0=await sources();const n0=await node0();
    await p.locator('[data-vector-action="path-nudge-right"]').first().click();
    const s1=await written(s0,'the nudge');
    await click(...cardAt);
    await drag(cardAt,40,30);
    const s2=await written(s1,'the card move');
    const focused=()=>p.evaluate(()=>document.activeElement===document.querySelector('[data-vector-adapter="fabric"][role="application"]'));
    assert.equal(await focused(),true,'the canvas has keyboard focus');
    const n=await events();
    await p.keyboard.press('Control+z');
    await settledAt(s1,'the first Ctrl+Z');
    const c1=await obj('card');
    assert.deepEqual([c1.x,c1.y],[72,96],'the first Ctrl+Z takes back the move');
    assert.deepEqual(await node0(),[n0[0]+4,n0[1]],'and only the move: the nudge stays');
    await p.keyboard.press('Control+z');
    await settledAt(s0,'the second Ctrl+Z');
    assert.deepEqual(await node0(),n0,'the second Ctrl+Z takes back the nudge');
    await p.keyboard.press('Control+Shift+z');
    await settledAt(s1,'Ctrl+Shift+Z');
    assert.deepEqual(await node0(),[n0[0]+4,n0[1]],'Ctrl+Shift+Z redoes the nudge');
    const c2=await obj('card');
    assert.deepEqual([c2.x,c2.y],[72,96],'and not the move');
    await p.waitForTimeout(800);
    assert.equal(await events(),n,'undo and redo record no canvas edit of their own');
    // Ctrl+Y on the canvas is nothing (it was the canvas's own path redo;
    // the editor's redo is Ctrl+Shift+Z).
    // With a path redo available (the toolbar's path undo), so that a
    // canvas path redo on Ctrl+Y would show.
    const pathDepths=async()=>[await host().getAttribute('data-vector-path-undo-depth'),await host().getAttribute('data-vector-path-redo-depth')];
    await p.locator('[data-vector-action="path-undo"]').first().click();
    const s3=await written(s1,'the toolbar path undo');
    assert.deepEqual(await node0(),n0,'the toolbar path undo takes the nudge back');
    const d0=await pathDepths();
    assert.equal(d0[1],'1','one path redo available');
    await click(650,400);
    assert.equal(await focused(),true,'the canvas has keyboard focus again');
    const nY=await events();
    await p.keyboard.press('Control+y');
    await p.waitForTimeout(1200);
    assert.equal(await sources(),s3,'Ctrl+Y writes nothing');
    assert.deepEqual(await node0(),n0,'Ctrl+Y moves no node');
    assert.deepEqual(await pathDepths(),d0,'Ctrl+Y steps no path history');
    assert.equal(await events(),nY,'Ctrl+Y records no canvas edit');

    cases.push('Ctrl+Z and Ctrl+Shift+Z on the focused canvas are one undo or redo of the one timeline each, with no path-node undo beside them; Ctrl+Y does nothing');
  }

  // 6. A pointer node drag is one path-history entry.
  {
    await openVector(false);
    const s0=await sources();const n0=await node0();
    const depth=()=>host().getAttribute('data-vector-path-undo-depth').then(v=>Number(v||0));
    assert.equal(await depth(),0,'no path history yet');
    const a=host().locator('[data-vector-anchor="node-0"]');const b=await a.boundingBox();
    await p.mouse.move(b.x+b.width/2,b.y+b.height/2);await p.mouse.down();
    for(let i=1;i<=4;i++)await p.mouse.move(b.x+b.width/2+5*i,b.y+b.height/2+3*i);
    await p.mouse.up();
    const s1=await written(s0,'the node drag');
    assert.deepEqual(await node0(),[n0[0]+20,n0[1]+12],'the node moved with the pointer');
    assert.equal(await depth(),1,'one path-history entry for the whole drag');
    await p.locator('[data-vector-action="path-undo"]').first().click();
    await assertPoll(node0,n0,'the toolbar path undo takes the drag back');
    await written(s1,'the path undo');
    cases.push('a pointer node drag is one path-history entry, which the toolbar path undo takes back');
  }

  // 7. The toolbars keep every action on screen, at a desktop width, a
  // narrow laptop width and the narrowest width the vector view is shown
  // at (769px: below it the editor shows no vector view).
  {
    // An action is on screen when no ancestor that clips (overflow other
    // than visible) and not the viewport cuts any of it, and nothing else
    // is drawn over it.
    const layout=()=>p.evaluate(()=>{
      const c=document.querySelector('[data-vector-adapter="fabric"] canvas.upper-canvas');
      const clipOf=(el)=>{let l=0,t=0,r=innerWidth,b=innerHeight;for(let e=el.parentElement;e;e=e.parentElement){const cs=getComputedStyle(e);if(cs.overflowX==='visible'&&cs.overflowY==='visible')continue;const q=e.getBoundingClientRect();const x0=q.left+e.clientLeft,y0=q.top+e.clientTop;l=Math.max(l,x0);t=Math.max(t,y0);r=Math.min(r,x0+e.clientWidth);b=Math.min(b,y0+e.clientHeight);}return {l,t,r,b};};
      // ... and nothing else is drawn over its centre.
      const covered=(btn)=>{const q=btn.getBoundingClientRect();const top=document.elementFromPoint(q.left+q.width/2,q.top+q.height/2);return !top||!(top===btn||btn.contains(top));};
      const off=[...document.querySelectorAll('[data-vector-action]')].filter(btn=>{const q=btn.getBoundingClientRect();const k=clipOf(btn);return q.width===0||q.left<k.l-0.5||q.right>k.r+0.5||q.top<k.t-0.5||q.bottom>k.b+0.5||covered(btn);}).map(b=>b.getAttribute('data-vector-action'));
      let scrolled=0;for(let e=c.parentElement;e;e=e.parentElement)scrolled+=e.scrollLeft;
      return {canvasLeft:Math.round(c.getBoundingClientRect().left),scrolled,off,count:document.querySelectorAll('[data-vector-action]').length};});
    for(const width of [1440,900,769]){
      await p.setViewportSize({width,height:900});
      await openVector(false);
      const l0=await layout();
      assert.equal(l0.count,24,width+'px: the 24 toolbar actions are there');
      assert.deepEqual(l0.off,[],width+'px: every toolbar action is on screen');
      for(const action of ['zoom-in','zoom-out','path-nudge-right','transform-selection','boolean-exclude','export']){
        await p.locator('[data-vector-action="'+action+'"]').first().click();
        const l=await layout();
        assert.equal(l.scrolled,l0.scrolled,width+'px: clicking '+action+' scrolls nothing sideways');
        assert.equal(l.canvasLeft,l0.canvasLeft,width+'px: clicking '+action+' leaves the canvas where it was');
      }
    }
    await p.setViewportSize({width:1440,height:900});
    cases.push('the toolbars keep every action on screen at 1440, 900 and 769px; clicking one leaves the canvas in place');
  }

  assert.deepEqual(errors,[]);
  console.log('Vector canvas edits GUI passed:',pub,cases.length);
} finally {
  if(browser)await browser.close();
  await new Promise(resolve=>server.close(resolve));
}
