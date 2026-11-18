/** The preview shows what the last write put in the file, whichever path made
 * the edits before it (Chromium).
 *
 * Editor spec "Visual box model" ("The preview shows the same values, before
 * the write and after it, and through undo and redo") and "Saving". isonim-pm
 * issue 2026-11-16-the-preview-does-not-follow-a-write-that-repeats-content-
 * written-before-an-undo: commit the card's width 270px with the canvas
 * resize handle (it was 300px), undo, commit 270px again -- the file said
 * 270px and the history grew, but the preview kept 300px.
 *
 * The cause was not the content: an inspector commit, an undo and a redo
 * remember the value they show (so a preview rebuilt before the write gets it
 * back), and nothing forgot those records once the file carried them. A later
 * edit made by a path that records nothing -- the canvas resize handle --
 * reloaded the preview from the written file, and the stale record was put
 * back over it. So the cases cover a different value after the undo and a
 * redo, besides the issue's own sequence; and, as a control, a path that
 * records what it shows (the box model's padding-top field), which always
 * passed. (The host's inspector `width` row is read-only for this shared
 * family, so no inspector width edit can be made here; an agent proposal and
 * a write with no undo are covered by `tests/test_editor_save_pipeline.nim`.)
 *
 * Every case asserts, after the write has settled, the written rule, the
 * history, and the preview: the card's computed width and the width the
 * preview's `.destination-card` rule declares, both equal to the file's --
 * and again after the frame is rebuilt without a write (View, then Edit),
 * which builds it from the editor's preview document rather than from the
 * file. A case that fails names the step and the value the preview kept.
 *
 * Round 2 (review V1, V2): the records may be forgotten only when that
 * preview document is recomputed from the written file. A write that
 * requests no reload (an edit that showed its value: a box-model field, an
 * undo) leaves the document from before it, and the rebuild needs the
 * records; a canvas edit keeps no record, so a write that carries one must
 * reload even when it also carries an edit that showed its value. Cases:
 * a field write, then a rebuild; a canvas write, an undo write, then a
 * rebuild; and a field edit, its undo and a canvas edit in ONE write (the
 * page's clock is Playwright's fake clock, paused so the three fall in one
 * 900 ms auto-save debounce whatever the host load, then advanced).
 *
 * The host is the shorthand-order host
 * (`tests/helpers/editor_shorthand_order_workspace.nim`: the editor example
 * with its real writer, preview document and selection bridge) with the card
 * rule's `width` mapped. Physical pointer and keyboard input. No mocks;
 * external requests are aborted so the run is offline.
 */
import {createServer} from 'node:http';
import {mkdtempSync,readFileSync,copyFileSync,existsSync,writeFileSync} from 'node:fs';
import {chromium} from '../node_modules/playwright/index.mjs';
import assert from 'node:assert/strict';
import path from 'node:path';
import {tmpdir} from 'node:os';
import {fileURLToPath} from 'node:url';
const repo=path.resolve(path.dirname(fileURLToPath(import.meta.url)),'..');
const bundle=repo+'/build/editor-shorthand/editor.js';
assert(existsSync(bundle),'build the host first: nim js -o:build/editor-shorthand/editor.js tests/helpers/editor_shorthand_order_workspace.nim');
const pub=mkdtempSync(path.join(process.env.ISONIM_POPUP_ARTIFACTS||tmpdir(),'preview-follows-write-'));
copyFileSync(bundle,pub+'/editor.js');
for(const [from,to] of [['node_modules/fabric/dist/index.min.js','fabric.min.js'],['node_modules/paper/dist/paper-core.min.js','paper-core.min.js'],['node_modules/svgo/dist/svgo.browser.js','svgo.browser.js']])copyFileSync(repo+'/'+from,pub+'/'+to);
const index=readFileSync(repo+'/src/isonim/editor/index.html','utf8');
const startRule='box-sizing: content-box; padding: 24px; border: 1px solid #CBD5E1; width: 300px;';
const page=()=>index.replace('<script src="editor.js"></script>','<script>window.__isonimShorthandCardRule='+JSON.stringify(startRule)+';window.__isonimShorthandMapped="width,height";</script><script src="editor.js"></script>');
const types={'.js':'text/javascript','.html':'text/html'};
const server=createServer((req,res)=>{const url=new URL(req.url,'http://x');const name=url.pathname==='/'?'index.html':url.pathname.slice(1);
  if(name==='index.html'){res.writeHead(200,{'content-type':'text/html'});res.end(page());return;}
  const file=path.join(pub,path.basename(name));if(!existsSync(file)){res.writeHead(404);res.end();return;}
  res.writeHead(200,{'content-type':types[path.extname(file)]||'application/octet-stream'});res.end(readFileSync(file));});
// A fixed port when one is given (ISONIM_PREVIEW_WRITE_PORT), otherwise any.
await new Promise(resolve=>server.listen(Number(process.env.ISONIM_PREVIEW_WRITE_PORT||0),'127.0.0.1',resolve));
const origin='http://127.0.0.1:'+server.address().port;
const foundation='examples/wanderlust/design-system/foundations.css';
const proof={head:process.env.ISONIM_TEST_HEAD||'working copy',cases:[],failures:[],errors:[]};
let browser;
try {
  const env={...process.env};delete env.LD_LIBRARY_PATH;
  browser=await chromium.launch({headless:true,env,executablePath:process.env.PLAYWRIGHT_CHROMIUM_EXECUTABLE});
  const p=await browser.newPage({viewport:{width:1440,height:900}});p.setDefaultTimeout(60000);
  // Playwright's fake clock, running at real speed except where the
  // one-write case pauses it.
  await p.clock.install();
  p.on('pageerror',e=>proof.errors.push(e.message));
  await p.route(url=>!url.href.startsWith(origin),route=>route.abort());
  const frame=()=>p.frameLocator('iframe[title="Editable component preview"]');
  const card=()=>frame().getByTestId('component-edit-preview');
  const handle=()=>frame().getByLabel('Resize selected element',{exact:true});
  const computedWidth=()=>card().evaluate(n=>getComputedStyle(n).width);
  // The width the preview's own `.destination-card` rule declares ('' for
  // none), and the card's inline width (a drag's hold), together.
  const previewRule=()=>card().evaluate(n=>{let declared=null;for(const sheet of document.styleSheets){const owner=sheet.ownerNode;if(owner&&owner.id&&owner.id.startsWith('isonim-editor'))continue;try{for(const r of sheet.cssRules)if(r.selectorText==='.destination-card')declared=r.style.getPropertyValue('width');}catch(e){}}return {rule:declared,inline:n.style.getPropertyValue('width')};});
  const source=()=>p.evaluate(f=>window.__isonimDemoSources?.[f]??'',foundation);
  const cardRule=async()=>((await source()).match(/\.destination-card \{[^}]*\}/)||[''])[0];
  const pending=()=>p.evaluate(()=>Number(window.__isonimEditor.pendingSourceEdits()));
  const undoCount=()=>p.evaluate(()=>window.__isonimEditorVm.inspector.undoStack.value.length);
  const frameScale=()=>p.evaluate(()=>{const n=document.querySelector('iframe[title="Editable component preview"]');return n.getBoundingClientRect().width/n.contentWindow.innerWidth;});
  // Deadlines wait on state: a write on a loaded host can take well over 20s.
  async function poll(read,expected,ms=60000){
    const deadline=Date.now()+ms;let last;
    while(Date.now()<deadline){last=await read();try{assert.deepEqual(last,expected);return {ok:true,last};}catch{}await p.waitForTimeout(100);}
    return {ok:false,last};
  }
  async function assertPoll(read,expected,what,ms){const r=await poll(read,expected,ms);assert.deepEqual(r.last,expected,what);}
  const ruleWith=(width)=>'.destination-card { '+(width===null?startRule.replace(' width: 300px;',''):startRule.replace('width: 300px;','width: '+width+';'))+' }';
  async function select(){
    if(await card().getAttribute('data-isonim-selected')==='true'&&await handle().count())return;
    await card().click({force:true,position:{x:3,y:3}});
    await frame().locator('[data-isonim-selected="true"]').waitFor();
    await handle().waitFor();
  }
  async function open(){
    await p.goto(origin+'/');
    await p.getByRole('button',{name:'Open Components section'}).click();
    await p.getByRole('button',{name:'Toggle DestinationCard stories'}).click();
    await p.getByRole('button',{name:'Select story DestinationCard / Default'}).click();
    await p.getByRole('button',{name:'Switch to edit mode'}).click();
    await select();
    assert.equal(await cardRule(),ruleWith('300px'),'the case starts from 300px');
    assert.equal(await computedWidth(),'300px');
  }
  // The write a step made has settled: nothing pending, the file holds
  // `width` (null: no width declaration), and the history is `history` long.
  async function settled(width,history,what){
    await assertPoll(async()=>[await pending(),await cardRule(),await undoCount()],[0,ruleWith(width),history],what+': written');
  }
  // The preview shows the file: the card's width and its rule's, with no
  // drag held inline. `computed` is the width the file renders.
  async function shows(width,computed,what){
    const expected={computed,rule:{rule:width===null?'':width,inline:''}};
    const r=await poll(async()=>({computed:await computedWidth(),rule:await previewRule()}),expected);
    if(!r.ok)throw new Error(what+': the preview shows '+JSON.stringify(r.last)+' while the file holds '+JSON.stringify(width));
  }
  // The canvas resize handle, dragged by `css` px of the preview document.
  async function resizeBy(css){
    await select();
    const s=await frameScale();
    const b=await handle().boundingBox();const x=b.x+b.width/2,y=b.y+b.height/2;
    await p.mouse.move(x,y);await p.mouse.down();
    for(let i=1;i<=3;i++)await p.mouse.move(x+css*s*i/3,y);
    await p.mouse.up();
  }
  // The box model's field, through the inspector's row pipeline (it records
  // the value it shows, as an inspector commit does).
  async function paddingTop(value){
    await select();
    const layout=p.locator('[data-inspector-section-header="layout"]');
    if((await layout.getAttribute('aria-expanded'))!=='true')await layout.click();
    const toggle=p.getByRole('button',{name:'Show box model controls'});
    if((await toggle.getAttribute('aria-expanded'))!=='true')await toggle.click();
    const f=p.getByRole('textbox',{name:'Padding top',exact:true});
    await f.click();await f.press('ControlOrMeta+A');await p.keyboard.type(value);await f.press('Enter');
  }
  // A rebuild of the frame that is not a write: View, then Edit. The frame
  // is rebuilt from the editor's preview document and the kept records.
  const modeButton=(mode)=>p.locator('[aria-label="Preview mode"]').getByRole('button',{name:'Switch to '+mode+' mode',exact:true});
  // Each switch replaces the frame's document (the mode is part of it):
  // wait for the replacement, marked on the old window, not for a time.
  const frameWindowMarked=()=>p.evaluate(()=>{const w=document.querySelector('iframe[title="Editable component preview"]')?.contentWindow;if(w)w.__previewWriteMark=true;});
  const frameReplaced=()=>p.waitForFunction(()=>{const w=document.querySelector('iframe[title="Editable component preview"]')?.contentWindow;return !!w&&!w.__previewWriteMark&&w.document.readyState==='complete'&&!!w.document.querySelector('[data-testid="component-edit-preview"]');});
  async function rebuild(){
    await frameWindowMarked();
    await modeButton('view').click();
    await frameReplaced();
    await frameWindowMarked();
    await modeButton('edit').click();
    await frameReplaced();
  }
  const reloadGeneration=()=>p.evaluate(()=>window.__isonimEditorVm.livePreviewReloadGeneration.value);
  const look=()=>card().evaluate(n=>({width:getComputedStyle(n).width,paddingTop:getComputedStyle(n).paddingTop,inlineWidth:n.style.width}));
  // Width and padding-top the file renders, with no drag held inline.
  async function looks(want,what){
    const r=await poll(look,{...want,inlineWidth:''});
    if(!r.ok)throw new Error(what+': the preview shows '+JSON.stringify(r.last)+' while the file holds '+JSON.stringify(want)+' (rule '+JSON.stringify(await cardRule())+')');
  }
  async function undoRedo(redo){await p.evaluate(()=>document.activeElement?.blur());await p.keyboard.press(redo?'ControlOrMeta+Shift+z':'ControlOrMeta+z');}
  // Steps: ['canvas',-30] | ['undo'] | ['redo']; each followed by the
  // file's width after it and the history length.
  async function run(name,steps){
    await open();
    const h0=await undoCount();
    const trail=[];
    try{
      for(const [i,[kind,arg,width,depth]] of steps.entries()){
        const what=name+' / step '+(i+1)+' ('+kind+(arg===undefined?'':' '+arg)+')';
        if(kind==='canvas')await resizeBy(arg);
        else if(kind==='undo')await undoRedo(false);
        else if(kind==='redo')await undoRedo(true);
        await settled(width,h0+depth,what);
        await shows(width,width,what);
        trail.push({step:what,file:width,preview:await computedWidth()});
      }
      // The last write's values survive a rebuild that is not a write.
      const [,,width]=steps[steps.length-1];
      await rebuild();
      await shows(width,width,name+' / after View, then Edit');
      trail.push({step:'View, then Edit',file:width,preview:await computedWidth()});
      proof.cases.push({name,ok:true,trail});
    }catch(error){
      proof.cases.push({name,ok:false,trail,error:String(error.message)});
      proof.failures.push(name+': '+error.message);
    }
  }
  // The issue: the same value written again after the undo.
  await run('canvas 270, undo, canvas 270 again',[
    ['canvas',-30,'270px',1],['undo',undefined,'300px',0],['canvas',-30,'270px',1]]);
  // Not the content: any later value the handle writes.
  await run('canvas 270, undo, canvas 250',[
    ['canvas',-30,'270px',1],['undo',undefined,'300px',0],['canvas',-50,'250px',1]]);
  // A redo records what it shows, as an undo does.
  await run('canvas 270, undo, redo, canvas 250',[
    ['canvas',-30,'270px',1],['undo',undefined,'300px',0],['redo',undefined,'270px',1],['canvas',-20,'250px',2]]);
  // Control: a path that records what it shows, before the write and
  // after it, through an undo and the same value again. It always showed
  // the file; it is here so the cases above cannot pass by the preview
  // never moving.
  {
    const name='box field padding-top 30, undo, padding-top 30 again';
    await open();
    const h0=await undoCount();
    const trail=[];
    const ruleTop=(top)=>'.destination-card { '+startRule+(top?' padding-top: '+top+';':'')+' }';
    const top=()=>card().evaluate(n=>getComputedStyle(n).paddingTop);
    try{
      for(const [i,[kind,value,depth]] of [['field','30px',1],['undo',null,0],['field','30px',1]].entries()){
        const what=name+' / step '+(i+1)+' ('+kind+')';
        if(kind==='field')await paddingTop('30');else await undoRedo(false);
        await assertPoll(async()=>[await pending(),await cardRule(),await undoCount()],[0,ruleTop(value),h0+depth],what+': written');
        const r=await poll(top,value||'24px');
        if(!r.ok)throw new Error(what+': the preview shows padding-top '+r.last+' while the file holds '+JSON.stringify(value));
        trail.push({step:what,file:value,preview:r.last});
      }
      proof.cases.push({name,ok:true,trail});
    }catch(error){
      proof.cases.push({name,ok:false,trail,error:String(error.message)});
      proof.failures.push(name+': '+error.message);
    }
  }

  // Review V1: a write that requests no reload, then a rebuild.
  async function caseRun(name,fn){
    const trail=[];
    try{await fn(trail);proof.cases.push({name,ok:true,trail});}
    catch(error){proof.cases.push({name,ok:false,trail,error:String(error.message)});proof.failures.push(name+': '+error.message);}
  }
  const ruleOf=(width,top)=>'.destination-card { '+startRule.replace('width: 300px;','width: '+width+';')+(top?' padding-top: '+top+';':'')+' }';
  await caseRun('box field padding-top 30 written, then View and Edit',async(trail)=>{
    await open();
    const g0=await reloadGeneration();
    await paddingTop('30');
    await assertPoll(async()=>[await pending(),await cardRule()],[0,ruleOf('300px','30px')],'the field write');
    assert.equal(await reloadGeneration(),g0,'the field write requests no reload (it showed its value)');
    await looks({width:'300px',paddingTop:'30px'},'after the write');
    await rebuild();
    await looks({width:'300px',paddingTop:'30px'},'after View, then Edit');
    trail.push({file:'padding-top 30px',preview:await look()});
  });
  await caseRun('canvas 270 written, undo written, then View and Edit',async(trail)=>{
    await open();
    await resizeBy(-30);
    await assertPoll(async()=>[await pending(),await cardRule()],[0,ruleOf('270px')],'the canvas write');
    await looks({width:'270px',paddingTop:'24px'},'after the canvas write');
    const g1=await reloadGeneration();
    await undoRedo(false);
    await assertPoll(async()=>[await pending(),await cardRule()],[0,ruleOf('300px')],'the undo write');
    assert.equal(await reloadGeneration(),g1,'the undo write requests no reload (it showed its value)');
    await looks({width:'300px',paddingTop:'24px'},'after the undo write');
    await rebuild();
    await looks({width:'300px',paddingTop:'24px'},'after View, then Edit');
    trail.push({file:'width 300px',preview:await look()});
  });
  // Review V2: a field edit, its undo and a canvas edit, written together.
  await caseRun('field 30, undo, canvas 270 in one write, then View and Edit',async(trail)=>{
    await open();
    const original=await source();
    const now=await p.evaluate(()=>Date.now());
    await p.clock.pauseAt(now+5000);
    try{
      await paddingTop('30');
      await undoRedo(false);
      await resizeBy(-30);
      assert.equal(await source(),original,'nothing was written before the debounce fired (one write)');
      await p.evaluate(()=>document.activeElement?.blur());
      await p.clock.runFor(1500);
    }finally{await p.clock.resume();}
    await assertPoll(async()=>[await pending(),await cardRule()],[0,ruleOf('270px')],'the one write');
    await looks({width:'270px',paddingTop:'24px'},'after the one write');
    await rebuild();
    await looks({width:'270px',paddingTop:'24px'},'after View, then Edit');
    trail.push({file:'width 270px',preview:await look()});
  });

  writeFileSync(pub+'/proof.json',JSON.stringify(proof,null,2));
  for(const c of proof.cases)console.log((c.ok?'ok   ':'FAIL ')+c.name+(c.ok?'':' -- '+c.error));
  assert.deepEqual(proof.failures,[],'every case shows the written file');
  assert.deepEqual(proof.errors,[]);
  console.log('Preview follows the write GUI passed:',pub,proof.cases.length);
} finally {
  if(browser)await browser.close();
  await new Promise(resolve=>server.close(resolve));
}
