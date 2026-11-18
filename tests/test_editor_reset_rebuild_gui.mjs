/** A written Reset (or any removal) stays removed when the preview frame is
 * rebuilt without a write: View, then Edit (Chromium).
 *
 * isonim-pm issue 2026-11-18-after-a-reset-the-preview-shows-the-removed-
 * declaration-again-on-view-then-edit; editor spec "Visual box model" ("The
 * preview shows the same values, before the write and after it, and through
 * undo and redo") and "Saving" (Reset "removes the one declaration that sets
 * the property").
 *
 * A removal showed itself, so its write requests no reload, and the frame is
 * rebuilt from the editor's preview document from before the write. The
 * preview keeps a record of every value it shows for that rebuild; a removal
 * used to delete the record instead, so the rebuild showed the removed
 * declaration again. It is now recorded as the removal of that declaration
 * from the rule it was removed from, and replayed only there: re-resolving
 * the rule after the removal would find a lower rule and remove its
 * declaration too. Every case has such a lower rule (`article` padding 4px,
 * appended to the file), so a replay that removed the wrong declaration
 * shows as 0px instead of 4px.
 *
 * GUI cases, each asserting the written rule, then the preview after the
 * write and after View then Edit:
 *   1. Reset of `padding` (the issue);
 *   2. Reset of a side (`padding-top` after the shorthand);
 *   3. undo of an edit that added a declaration (padding-top 30, undo);
 *   2b. a side Reset with no shorthand in the rule (2 and 3 also pass at
 *      fea614a: the shorthand's follower record re-applies `padding`);
 *   3b. the undo of a side added in a write that reloaded (a canvas resize
 *      in the same auto-save), so the preview's document carries it;
 *   7. padding 20px written, then Reset (round 2: the value's side records
 *      must not replay over the shorthand's removal);
 *   8. Reset, undo, redo (the undo's side followers, then the redo's removal);
 *   9. Reset, then a side committed after it (the side replays after the
 *      removal);
 *   4. Reset, then View and Edit BEFORE the write lands (the page's clock is
 *      Playwright's fake clock, paused so the rebuild falls inside the 900 ms
 *      auto-save debounce whatever the host load), then the write.
 * Runtime cases on the same real preview document, calling its declaration
 * runtime directly (supplementary, as in test_editor_shorthand_order_gui.mjs):
 *   5. a removal reports where it was made, and replaying it there on a
 *      document that still declares it removes it, twice without harm, and
 *      leaves the lower rule's declaration;
 *   6. a recorded place that does not name this document's rules is a no-op.
 *
 * The host is the shorthand-order host
 * (`tests/helpers/editor_shorthand_order_workspace.nim`: the editor example
 * with its real writer, preview document and selection bridge). Physical
 * pointer and keyboard input; no mocks; external requests are aborted.
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
const pub=mkdtempSync(path.join(process.env.ISONIM_POPUP_ARTIFACTS||tmpdir(),'reset-rebuild-'));
copyFileSync(bundle,pub+'/editor.js');
for(const [from,to] of [['node_modules/fabric/dist/index.min.js','fabric.min.js'],['node_modules/paper/dist/paper-core.min.js','paper-core.min.js'],['node_modules/svgo/dist/svgo.browser.js','svgo.browser.js']])copyFileSync(repo+'/'+from,pub+'/'+to);
const index=readFileSync(repo+'/src/isonim/editor/index.html','utf8');
// The lower rule every case's removal must leave. The example's writer
// refuses a Reset when the file has two declarations of the property, so a
// case that resets `padding` gets the lower rule's sides as longhands, and a
// case about `padding-top` gets it as the shorthand.
const LOWER_SIDES='\narticle { padding-top: 4px; padding-right: 4px; padding-bottom: 4px; padding-left: 4px; }\n';
const LOWER_SHORTHAND='\narticle { padding: 4px; }\n';
let rule='',lower='';
const page=()=>index.replace('<script src="editor.js"></script>','<script>window.__isonimShorthandCardRule='+JSON.stringify(rule)+';window.__isonimShorthandExtraCss='+JSON.stringify(lower)+';window.__isonimShorthandMapped="width";</script><script src="editor.js"></script>');
const types={'.js':'text/javascript','.html':'text/html'};
const server=createServer((req,res)=>{const url=new URL(req.url,'http://x');const name=url.pathname==='/'?'index.html':url.pathname.slice(1);
  if(name==='index.html'){res.writeHead(200,{'content-type':'text/html'});res.end(page());return;}
  const file=path.join(pub,path.basename(name));if(!existsSync(file)){res.writeHead(404);res.end();return;}
  res.writeHead(200,{'content-type':types[path.extname(file)]||'application/octet-stream'});res.end(readFileSync(file));});
// A fixed port when one is given (ISONIM_RESET_REBUILD_PORT), otherwise any.
await new Promise(resolve=>server.listen(Number(process.env.ISONIM_RESET_REBUILD_PORT||0),'127.0.0.1',resolve));
const origin='http://127.0.0.1:'+server.address().port;
const foundation='examples/wanderlust/design-system/foundations.css';
const proof={head:process.env.ISONIM_TEST_HEAD||'working copy',cases:[],failures:[],errors:[]};
let browser;
try {
  const env={...process.env};delete env.LD_LIBRARY_PATH;
  browser=await chromium.launch({headless:true,env,executablePath:process.env.PLAYWRIGHT_CHROMIUM_EXECUTABLE});
  const p=await browser.newPage({viewport:{width:1440,height:900}});p.setDefaultTimeout(60000);
  // Playwright's fake clock, at real speed except where case 4 pauses it.
  await p.clock.install();
  p.on('pageerror',e=>proof.errors.push(e.message));
  await p.route(url=>!url.href.startsWith(origin),route=>route.abort());
  const frame=()=>p.frameLocator('iframe[title="Editable component preview"]');
  const card=()=>frame().getByTestId('component-edit-preview');
  const source=()=>p.evaluate(f=>window.__isonimDemoSources?.[f]??'',foundation);
  const cardRule=async()=>((await source()).match(/\.destination-card \{[^}]*\}/)||[''])[0];
  const pending=()=>p.evaluate(()=>Number(window.__isonimEditor.pendingSourceEdits()));
  const reloadGeneration=()=>p.evaluate(()=>window.__isonimEditorVm.livePreviewReloadGeneration.value);
  const look=()=>card().evaluate(n=>({paddingTop:getComputedStyle(n).paddingTop,paddingLeft:getComputedStyle(n).paddingLeft}));
  async function poll(read,expected,ms=60000){
    const deadline=Date.now()+ms;let last;
    while(Date.now()<deadline){last=await read();try{assert.deepEqual(last,expected);return {ok:true,last};}catch{}await p.waitForTimeout(100);}
    return {ok:false,last};
  }
  async function assertPoll(read,expected,what){const r=await poll(read,expected);assert.deepEqual(r.last,expected,what);}
  async function looks(want,what){
    const r=await poll(look,want);
    if(!r.ok)throw new Error(what+': the preview shows '+JSON.stringify(r.last)+' while the file renders '+JSON.stringify(want)+' (rule '+JSON.stringify(await cardRule())+')');
  }
  async function select(){
    if(await card().getAttribute('data-isonim-selected')==='true')return;
    await card().click({force:true,position:{x:3,y:3}});
    await frame().locator('[data-isonim-selected="true"]').waitFor();
  }
  async function open(startRule,lowerCss=LOWER_SIDES){
    rule=startRule;lower=lowerCss;
    await p.goto(origin+'/');
    await p.getByRole('button',{name:'Open Components section'}).click();
    await p.getByRole('button',{name:'Toggle DestinationCard stories'}).click();
    await p.getByRole('button',{name:'Select story DestinationCard / Default'}).click();
    await modeButton('edit').click();
    await select();
    assert.equal(await cardRule(),'.destination-card { '+startRule+' }','the case starts from its rule');
  }
  const modeButton=(mode)=>p.locator('[aria-label="Preview mode"]').getByRole('button',{name:'Switch to '+mode+' mode',exact:true});
  // Each switch replaces the frame's document (the mode is part of it):
  // wait for the replacement, marked on the old window, not for a time.
  const mark=()=>p.evaluate(()=>{const w=document.querySelector('iframe[title="Editable component preview"]')?.contentWindow;if(w)w.__resetRebuildMark=true;});
  const replaced=()=>p.waitForFunction(()=>{const w=document.querySelector('iframe[title="Editable component preview"]')?.contentWindow;return !!w&&!w.__resetRebuildMark&&w.document.readyState==='complete'&&!!w.document.querySelector('[data-testid="component-edit-preview"]');});
  async function rebuild(){await mark();await modeButton('view').click();await replaced();await mark();await modeButton('edit').click();await replaced();}
  // The first visible inspector row for `property`, its Component properties
  // section opened.
  async function row(property){
    await select();
    const section=p.locator('[data-inspector-section-header="component-properties"]');
    if(await section.count()&&(await section.getAttribute('aria-expanded'))!=='true')await section.click();
    const rows=p.locator('[data-property-row="'+property+'"][data-property-row-css-property="'+property+'"]');
    const n=await rows.count();
    for(let i=0;i<n;i++)if(await rows.nth(i).isVisible())return rows.nth(i);
    throw new Error('no visible row for '+property);
  }
  async function reset(property){
    const r=await row(property);
    const menu=r.locator('[data-property-actions-menu="true"]');
    await r.locator('[data-property-row-field-label="true"]').click({button:'right'});
    await menu.waitFor({state:'visible'});
    const item=menu.getByRole('menuitem',{name:'Reset'});
    const offered=await poll(()=>item.getAttribute('aria-disabled'),'false');
    if(!offered.ok)throw new Error('Reset is not offered for '+property+': '+JSON.stringify(await r.evaluate(n=>({reason:n.getAttribute('data-property-row-readonly-reason'),items:[...n.querySelectorAll('[role="menuitem"]')].map(m=>[m.innerText,m.getAttribute('aria-disabled'),m.getAttribute('title'),m.getAttribute('data-property-action-reason')||'']),diag:JSON.stringify(window.__isonimEditorVm?.inspector?.editDiagnostics?.value||null).slice(0,300)}))));
    await item.click();
  }
  async function typed(property,value){
    const r=await row(property);const i=r.locator('[data-property-row-input="true"]');
    await i.click();await i.fill(value);await i.press('Enter');
  }
  async function paddingTop(value){
    await select();
    const layout=p.locator('[data-inspector-section-header="layout"]');
    if((await layout.getAttribute('aria-expanded'))!=='true')await layout.click();
    const toggle=p.getByRole('button',{name:'Show box model controls'});
    if((await toggle.getAttribute('aria-expanded'))!=='true')await toggle.click();
    const f=p.getByRole('textbox',{name:'Padding top',exact:true});
    await f.click();await f.press('ControlOrMeta+A');await p.keyboard.type(value);await f.press('Enter');
  }
  const handle=()=>frame().getByLabel('Resize selected element',{exact:true});
  async function resizeBy(css){
    await select();await handle().waitFor();
    const s=await p.evaluate(()=>{const n=document.querySelector('iframe[title="Editable component preview"]');return n.getBoundingClientRect().width/n.contentWindow.innerWidth;});
    const b=await handle().boundingBox();const x=b.x+b.width/2,y=b.y+b.height/2;
    await p.mouse.move(x,y);await p.mouse.down();for(let i=1;i<=3;i++)await p.mouse.move(x+css*s*i/3,y);await p.mouse.up();
  }
  async function undo(){await p.evaluate(()=>document.activeElement?.blur());await p.keyboard.press('ControlOrMeta+z');}
  async function caseRun(name,fn){
    const trail=[];
    try{await fn(trail);proof.cases.push({name,ok:true,trail});}
    catch(error){proof.cases.push({name,ok:false,trail,error:String(error.message)});proof.failures.push(name+': '+error.message);}
  }
  const written=(what,body)=>assertPoll(async()=>[await pending(),await cardRule()],[0,body?'.destination-card { '+body+' }':'.destination-card { }'],what+': written');
  // A write whose removal showed itself requests no reload.
  async function noReload(g0,what){assert.equal(await reloadGeneration(),g0,what+': the write requests no reload (the removal showed itself)');}

  await caseRun('Reset of padding, then View and Edit',async(trail)=>{
    await open('padding: 18px;');
    await looks({paddingTop:'18px',paddingLeft:'18px'},'before');
    const g0=await reloadGeneration();
    await reset('padding');
    await written('the Reset','');
    await noReload(g0,'the Reset');
    await looks({paddingTop:'4px',paddingLeft:'4px'},'after the Reset is written');
    await rebuild();
    await looks({paddingTop:'4px',paddingLeft:'4px'},'after View, then Edit');
    trail.push({file:'no padding (lower rule 4px)',preview:await look()});
  });
  await caseRun('Reset of padding-top after the shorthand, then View and Edit',async(trail)=>{
    await open('padding: 18px; padding-top: 30px;',LOWER_SHORTHAND);
    await looks({paddingTop:'30px',paddingLeft:'18px'},'before');
    const g0=await reloadGeneration();
    await reset('padding-top');
    await written('the side Reset','padding: 18px;');
    await noReload(g0,'the side Reset');
    await looks({paddingTop:'18px',paddingLeft:'18px'},'after the side Reset is written');
    await rebuild();
    await looks({paddingTop:'18px',paddingLeft:'18px'},'after View, then Edit');
    trail.push({file:'padding 18px',preview:await look()});
  });
  await caseRun('padding-top 30 added, undone, then View and Edit',async(trail)=>{
    await open('padding: 18px;',LOWER_SHORTHAND);
    await paddingTop('30');
    await written('the added side','padding: 18px; padding-top: 30px;');
    await looks({paddingTop:'30px',paddingLeft:'18px'},'after the added side is written');
    const g0=await reloadGeneration();
    await undo();
    await written('the undo','padding: 18px;');
    await noReload(g0,'the undo');
    await looks({paddingTop:'18px',paddingLeft:'18px'},'after the undo is written');
    await rebuild();
    await looks({paddingTop:'18px',paddingLeft:'18px'},'after View, then Edit');
    trail.push({file:'padding 18px',preview:await look()});
  });
  // The same two without a shorthand in the rule: nothing else the preview
  // keeps for the rule puts the side back, so only the removal's own record
  // can keep it removed (the cases above pass at fea614a because the
  // shorthand's follower record re-applies `padding` on the rebuild).
  await caseRun('Reset of padding-top with no shorthand in the rule, then View and Edit',async(trail)=>{
    await open('padding-top: 30px;',LOWER_SHORTHAND);
    await looks({paddingTop:'30px',paddingLeft:'4px'},'before');
    const g0=await reloadGeneration();
    await reset('padding-top');
    await written('the side Reset','');
    await noReload(g0,'the side Reset');
    await looks({paddingTop:'4px',paddingLeft:'4px'},'after the side Reset is written');
    await rebuild();
    await looks({paddingTop:'4px',paddingLeft:'4px'},'after View, then Edit');
    trail.push({file:'no padding-top (lower rule 4px)',preview:await look()});
  });
  // An undo that removes a declaration the preview's document already
  // carries: the add was written together with a canvas resize, whose write
  // reloads the preview from the file, so the document has padding-top 30.
  // (An add written alone requests no reload: the document never had it, and
  // its undo cannot show it again.)
  await caseRun('padding-top 30 added in a reloading write, undone, then View and Edit',async(trail)=>{
    await open('box-sizing: content-box; width: 300px;',LOWER_SHORTHAND);
    const now=await p.evaluate(()=>Date.now());
    await p.clock.pauseAt(now+5000);
    try{
      await resizeBy(-30);
      await paddingTop('30');
      await p.evaluate(()=>document.activeElement?.blur());
      await p.clock.runFor(1500);
    }finally{await p.clock.resume();}
    await written('the resize and the added side','box-sizing: content-box; width: 270px; padding-top: 30px;');
    await looks({paddingTop:'30px',paddingLeft:'4px'},'after the reloading write');
    const g0=await reloadGeneration();
    await undo();
    await written('the undo of the side','box-sizing: content-box; width: 270px;');
    await noReload(g0,'the undo');
    await looks({paddingTop:'4px',paddingLeft:'4px'},'after the undo is written');
    await rebuild();
    await looks({paddingTop:'4px',paddingLeft:'4px'},'after View, then Edit');
    trail.push({file:'no padding-top (lower rule 4px)',preview:await look()});
  });
  // Round 2 (review V1): a shorthand's record replaces the records of the
  // sides it covers. A value commit records its sides as followers; a later
  // Reset of the shorthand must not leave them to replay over the removal.
  await caseRun('padding 20px written, then Reset, then View and Edit',async(trail)=>{
    await open('padding: 18px;');
    await typed('padding','20px');
    await written('the value','padding: 20px;');
    await looks({paddingTop:'20px',paddingLeft:'20px'},'after the value is written');
    await reset('padding');
    await written('the Reset','');
    await looks({paddingTop:'4px',paddingLeft:'4px'},'after the Reset is written');
    await rebuild();
    await looks({paddingTop:'4px',paddingLeft:'4px'},'after View, then Edit');
    trail.push({file:'no padding (lower rule 4px)',preview:await look()});
  });
  await caseRun('Reset, undo, redo, then View and Edit',async(trail)=>{
    await open('padding: 18px;');
    await reset('padding');
    await written('the Reset','');
    await undo();
    await written('the undo','padding: 18px;');
    await looks({paddingTop:'18px',paddingLeft:'18px'},'after the undo is written');
    await p.evaluate(()=>document.activeElement?.blur());
    await p.keyboard.press('ControlOrMeta+Shift+z');
    await written('the redo','');
    await looks({paddingTop:'4px',paddingLeft:'4px'},'after the redo is written');
    await rebuild();
    await looks({paddingTop:'4px',paddingLeft:'4px'},'after View, then Edit');
    trail.push({file:'no padding (lower rule 4px)',preview:await look()});
  });
  // And symmetrically: a side committed after its shorthand replays after it.
  await caseRun('Reset of padding, then padding-top 30, then View and Edit',async(trail)=>{
    await open('padding: 18px;');
    await reset('padding');
    await written('the Reset','');
    await paddingTop('30');
    await written('the side','padding-top: 30px;');
    await looks({paddingTop:'30px',paddingLeft:'4px'},'after the side is written');
    await rebuild();
    await looks({paddingTop:'30px',paddingLeft:'4px'},'after View, then Edit');
    trail.push({file:'padding-top 30px (lower rule 4px)',preview:await look()});
  });
  await caseRun('Reset, View and Edit before the write, then the write',async(trail)=>{
    await open('padding: 18px;');
    const original=await source();
    const now=await p.evaluate(()=>Date.now());
    await p.clock.pauseAt(now+5000);
    try{
      await reset('padding');
      await looks({paddingTop:'4px',paddingLeft:'4px'},'the Reset shown');
      await rebuild();
      assert.equal(await source(),original,'nothing was written before the debounce fired');
      await looks({paddingTop:'4px',paddingLeft:'4px'},'after View, then Edit, before the write');
      await p.evaluate(()=>document.activeElement?.blur());
      await p.clock.runFor(1500);
    }finally{await p.clock.resume();}
    await written('the Reset','');
    await looks({paddingTop:'4px',paddingLeft:'4px'},'after the write');
    trail.push({file:'no padding (lower rule 4px)',preview:await look()});
  });

  // Runtime cases: the preview's declaration runtime on the same document.
  await caseRun('runtime: a removal is replayed where it was made, and only there',async(trail)=>{
    await open('padding: 18px;');
    const id=await card().evaluate(n=>n.getAttribute('data-isonim-element-id')||'');
    const sel='article[data-testid="component-edit-preview"]';
    const lowerRule=()=>card().evaluate(()=>{for(const sh of document.styleSheets){try{for(const r of sh.cssRules)if(r.selectorText==='article')return r.style.getPropertyValue('padding-top');}catch(e){}}return null;});
    assert.equal(await lowerRule(),'4px');
    const place=await card().evaluate((n,[id,sel])=>{const shown=window.__isonimSetDeclaration(id,sel,'padding','','sskLocalInstance','','');return {shown,place:window.__isonimLastRemoval(),pad:getComputedStyle(n).paddingTop};},[id,sel]);
    assert.equal(place.shown,true);assert.equal(place.pad,'4px');
    const at=JSON.parse(place.place);
    assert.equal(at.name,'.destination-card','the removal names the rule it was made in');
    trail.push({place:at});
    // A document that still declares it: the pre-write one, rebuilt.
    await rebuild();
    const replay=await card().evaluate((n,[id,sel,place])=>{const a=window.__isonimSetDeclaration(id,sel,'padding','','sskLocalInstance','','',place);const p1=getComputedStyle(n).paddingTop;const b=window.__isonimSetDeclaration(id,sel,'padding','','sskLocalInstance','','',place);return {a,b,p1,p2:getComputedStyle(n).paddingTop};},[id,sel,place.place]);
    assert.deepEqual(replay,{a:true,b:true,p1:'4px',p2:'4px'},'replayed twice: removed from its rule, the lower rule kept');
    assert.equal(await lowerRule(),'4px','the lower rule still declares its padding');
    // The hazard the place avoids: re-resolving after the removal finds the lower rule.
    const naive=await card().evaluate((n,[id,sel])=>{window.__isonimSetDeclaration(id,sel,'padding','','sskLocalInstance','','');return getComputedStyle(n).paddingTop;},[id,sel]);
    trail.push({naiveReplayAfterRemoval:naive});
    assert.equal(naive,'0px','control: a re-resolved removal takes the lower rule\'s declaration');
  });
  await caseRun('runtime: a place that does not name this document\'s rules is a no-op',async(trail)=>{
    await open('padding: 18px;');
    const sel='article[data-testid="component-edit-preview"]';
    const r=await card().evaluate((n,sel)=>{const id=n.getAttribute('data-isonim-element-id')||'';const stale=JSON.stringify({name:'.destination-card',index:0,count:7});const a=window.__isonimSetDeclaration(id,sel,'padding','','sskLocalInstance','','',stale);return {a,pad:getComputedStyle(n).paddingTop};},sel);
    assert.deepEqual(r,{a:false,pad:'18px'});
    trail.push(r);
  });

  writeFileSync(pub+'/proof.json',JSON.stringify(proof,null,2));
  for(const c of proof.cases)console.log((c.ok?'ok   ':'FAIL ')+c.name+(c.ok?'':' -- '+c.error));
  assert.deepEqual(proof.failures,[],'every case keeps the removal');
  assert.deepEqual(proof.errors,[]);
  console.log('Reset rebuild GUI passed:',pub,proof.cases.length);
} finally {
  if(browser)await browser.close();
  await new Promise(resolve=>server.close(resolve));
}
