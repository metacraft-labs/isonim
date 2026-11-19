/** An accepted agent proposal asks the act-time questions a commit asks, and a
 * written token removal survives View then Edit (Chromium).
 *
 * isonim-pm issue 2026-11-19-an-accepted-agent-proposal-can-write-a-token-
 * removal-the-preview-does-not-record; editor spec "Saving" ("a commit" means
 * every path that stages a source edit; a refusal the editor can know at the
 * act is made at the act; Reset is enabled only where the write would
 * succeed) and "Visual box model" (the preview shows the same values before
 * the write and after it).
 *
 * Nothing in the tree proposes a token removal or declares a token entry
 * removable, so the shorthand-order host has two test-only knobs, inert when
 * unset (`tests/helpers/editor_shorthand_order_workspace.nim`):
 *   - `__isonimShorthandProposals`: `__isonimShorthandPropose(property,
 *     scope)` adds an agent proposal removing ``property`` at ``scope``, the
 *     plan an identical editor's commit makes on a scratch copy of the source
 *     (whose writer would accept it);
 *   - `__isonimShorthandRemovableTokens`: the token entries state that their
 *     writer can remove them, as a project might.
 * The proposal is accepted with the chat's real Accept button (View mode,
 * where the AI assistant is). Cases:
 *   1. a token removal on the stock writer: refused at acceptance with the
 *      Reset's reason, shown on the proposal; nothing staged or written;
 *   2. a proposal in a read-only workspace: refused with the read-only reason;
 *   3. a token removal with removable tokens: written as the variable's
 *      removal; the preview (reloaded by that write) and a later View then
 *      Edit show the file;
 *   4. Reset at the Component token scope with removable tokens: written, no
 *      reload (it showed the removal), the removal recorded at the variable's
 *      declaration, and View then Edit shows the file;
 *   5. the same Reset, View and Edit BEFORE the write (the page's clock is
 *      Playwright's fake clock, paused so the rebuild falls inside the 900 ms
 *      auto-save debounce), then the write.
 * The token is `--wl-space-card` (16px), used by the card's
 * `padding: var(--wl-space-card)`; with it removed the padding is invalid at
 * computed-value time and renders 0px. The token chip sits in the row's
 * scope-strip overflow; it is chosen with a DOM click on the chip, the
 * handler the overflow's entry runs. No mocks; external requests aborted.
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
const pub=mkdtempSync(path.join(process.env.ISONIM_POPUP_ARTIFACTS||tmpdir(),'proposal-token-'));
copyFileSync(bundle,pub+'/editor.js');
for(const [from,to] of [['node_modules/fabric/dist/index.min.js','fabric.min.js'],['node_modules/paper/dist/paper-core.min.js','paper-core.min.js'],['node_modules/svgo/dist/svgo.browser.js','svgo.browser.js']])copyFileSync(repo+'/'+from,pub+'/'+to);
const index=readFileSync(repo+'/src/isonim/editor/index.html','utf8');
const RULE='padding: var(--wl-space-card);';
let knobs={};
const page=()=>index.replace('<script src="editor.js"></script>','<script>window.__isonimShorthandCardRule='+JSON.stringify(RULE)+';'+Object.entries(knobs).map(([k,v])=>'window.'+k+'='+JSON.stringify(v)+';').join('')+'</script><script src="editor.js"></script>');
const server=createServer((req,res)=>{const url=new URL(req.url,'http://x');const name=url.pathname==='/'?'index.html':url.pathname.slice(1);
  if(name==='index.html'){res.writeHead(200,{'content-type':'text/html'});res.end(page());return;}
  const file=path.join(pub,path.basename(name));if(!existsSync(file)){res.writeHead(404);res.end();return;}
  res.writeHead(200,{'content-type':file.endsWith('.js')?'text/javascript':'application/octet-stream'});res.end(readFileSync(file));});
await new Promise(resolve=>server.listen(Number(process.env.ISONIM_PROPOSAL_TOKEN_PORT||0),'127.0.0.1',resolve));
const origin='http://127.0.0.1:'+server.address().port;
const foundation='examples/wanderlust/design-system/foundations.css';
const NOT_REMOVABLE="This project's source writer cannot remove the --wl-space-card token from "+foundation+'.';
const proof={head:process.env.ISONIM_TEST_HEAD||'working copy',cases:[],failures:[],errors:[]};
let browser;
try {
  const env={...process.env};delete env.LD_LIBRARY_PATH;
  browser=await chromium.launch({headless:true,env,executablePath:process.env.PLAYWRIGHT_CHROMIUM_EXECUTABLE});
  const p=await browser.newPage({viewport:{width:1440,height:900}});p.setDefaultTimeout(60000);
  await p.clock.install();
  p.on('pageerror',e=>proof.errors.push(e.message));
  await p.route(url=>!url.href.startsWith(origin),route=>route.abort());
  const frame=()=>p.frameLocator('iframe[title="Editable component preview"]');
  const card=()=>frame().getByTestId('component-edit-preview');
  const source=()=>p.evaluate(f=>window.__isonimDemoSources?.[f]??'',foundation);
  const tokenDecl=async()=>((await source()).match(/--wl-space-card:[^;]*;/)||[''])[0];
  const pending=()=>p.evaluate(()=>Number(window.__isonimEditor.pendingSourceEdits()));
  const reloadGeneration=()=>p.evaluate(()=>window.__isonimEditorVm.livePreviewReloadGeneration.value);
  const records=()=>p.evaluate(()=>Object.values(window.__isonimPreviewDeclarations||{}).map(r=>({property:r.property,value:r.value,at:r.removedFrom||''})));
  const look=()=>card().evaluate(n=>({padding:getComputedStyle(n).paddingTop,token:getComputedStyle(document.documentElement).getPropertyValue('--wl-space-card').trim()}));
  async function poll(read,expected,ms=60000){const deadline=Date.now()+ms;let last;while(Date.now()<deadline){last=await read();try{assert.deepEqual(last,expected);return {ok:true,last};}catch{}await p.waitForTimeout(100);}return {ok:false,last};}
  async function assertPoll(read,expected,what){const r=await poll(read,expected);assert.deepEqual(r.last,expected,what);}
  async function looks(want,what){const r=await poll(look,want);if(!r.ok)throw new Error(what+': the preview shows '+JSON.stringify(r.last)+' while the file renders '+JSON.stringify(want)+' (token '+JSON.stringify(await tokenDecl())+')');}
  const modeButton=(m)=>p.locator('[aria-label="Preview mode"]').getByRole('button',{name:'Switch to '+m+' mode',exact:true});
  const mark=()=>p.evaluate(()=>{const w=document.querySelector('iframe[title="Editable component preview"]')?.contentWindow;if(w)w.__ptMark=true;});
  const replaced=()=>p.waitForFunction(()=>{const w=document.querySelector('iframe[title="Editable component preview"]')?.contentWindow;return !!w&&!w.__ptMark&&w.document.readyState==='complete'&&!!w.document.querySelector('[data-testid="component-edit-preview"]');});
  async function toMode(m){await mark();await modeButton(m).click();await replaced();}
  async function rebuild(){await toMode('view');await toMode('edit');}
  async function select(){
    if(await card().getAttribute('data-isonim-selected')==='true')return;
    await card().click({force:true,position:{x:3,y:3}});
    await frame().locator('[data-isonim-selected="true"]').waitFor();
  }
  async function open(withKnobs){
    knobs=withKnobs;
    await p.goto(origin+'/');
    await p.getByRole('button',{name:'Open Components section'}).click();
    await p.getByRole('button',{name:'Toggle DestinationCard stories'}).click();
    await p.getByRole('button',{name:'Select story DestinationCard / Default'}).click();
    await modeButton('edit').click();
    await select();
    await looks({padding:'16px',token:'16px'},'before');
    assert.equal(await tokenDecl(),'--wl-space-card: 16px;');
  }
  async function propose(property,scope){
    const id=await p.evaluate(([a,b])=>window.__isonimShorthandPropose(a,b),[property,scope]);
    assert.ok(!String(id).startsWith('refused'),'the proposal is made: '+id);
    return id;
  }
  // Accept in View mode, where the chat's proposals are; back to Edit after.
  async function accept(id){
    await toMode('view');
    const button=p.getByRole('button',{name:'Accept agent edit '+id,exact:true});
    await button.waitFor();
    await button.click();
  }
  const proposalCard=(id)=>p.locator('[data-agent-proposal="'+id+'"]');
  const cardButton=(label,id)=>p.getByRole('button',{name:label+' agent edit '+id,exact:true});
  const cardStatus=(id)=>proposalCard(id).getAttribute('data-agent-proposal-status');
  const cardRule=async()=>((await source()).match(/\.destination-card \{[^}]*\}/)||[''])[0];
  // A box-model field edit that is still pending (inside the auto-save
  // debounce, the page clock paused) when the proposal is accepted.
  async function pendingFieldThenAccept(id){
    await select();
    const layout=p.locator('[data-inspector-section-header="layout"]');
    if((await layout.getAttribute('aria-expanded'))!=='true')await layout.click();
    const toggle=p.getByRole('button',{name:'Show box model controls'});
    if((await toggle.getAttribute('aria-expanded'))!=='true')await toggle.click();
    const f=p.getByRole('textbox',{name:'Padding top',exact:true});
    await f.click();await f.press('ControlOrMeta+A');
    const now=await p.evaluate(()=>Date.now());
    await p.clock.pauseAt(now+60000);
    let pendingBefore=-1;
    try{
      await p.keyboard.type('30');await f.press('Enter');
      pendingBefore=await pending();
      // View mode (the chat); waited on from node, since page-side waits do
      // not run on a paused clock.
      await modeButton('view').click();
      const b=cardButton('Accept',id);const deadline=Date.now()+60000;
      while(!(await b.count())&&Date.now()<deadline)await new Promise(r=>setTimeout(r,200));
      await b.click();
    }finally{await p.clock.resume();}
    assert.equal(pendingBefore,1,'the field edit is pending when the proposal is accepted');
  }
  const paddingRow=async()=>{
    await select();
    const section=p.locator('[data-inspector-section-header="component-properties"]');
    if(await section.count()&&(await section.getAttribute('aria-expanded'))!=='true')await section.click();
    const row=p.locator('[data-property-row="padding"][data-property-row-css-property="padding"]').first();
    await row.waitFor({state:'visible'});return row;
  };
  async function resetAtTokenScope(){
    const row=await paddingRow();
    const chip=row.locator('[data-source-scope-kind="sskComponentToken"]').first();
    if(await chip.isVisible().catch(()=>false))await chip.click();else await chip.evaluate(n=>n.click());
    await assertPoll(()=>chip.getAttribute('aria-pressed'),'true','the Component token scope is chosen');
    const menu=row.locator('[data-property-actions-menu="true"]');
    await row.locator('[data-property-row-field-label="true"]').click({button:'right'});
    await menu.waitFor({state:'visible'});
    const reset=menu.getByRole('menuitem',{name:'Reset'});
    const offered=await poll(()=>reset.getAttribute('aria-disabled'),'false');
    if(!offered.ok)throw new Error('Reset at the token scope is not offered: '+await reset.getAttribute('title'));
    await reset.click();
  }
  async function caseRun(name,fn){const trail=[];try{await fn(trail);proof.cases.push({name,ok:true,trail});}catch(error){proof.cases.push({name,ok:false,trail,error:String(error.message)});proof.failures.push(name+': '+error.message);}}

  await caseRun('a token removal on the stock writer is refused at acceptance',async(trail)=>{
    await open({__isonimShorthandProposals:'1'});
    const before=await source();
    const id=await propose('padding','sskComponentToken');
    await accept(id);
    const note=proposalCard(id).locator('[data-agent-proposal-refusal="true"]');
    await note.waitFor();
    assert.equal((await note.textContent()).trim(),NOT_REMOVABLE,'the refusal is the Reset\'s reason');
    assert.match(await proposalCard(id).getAttribute('data-agent-proposal-status'),/proposed/,'the proposal stays proposed');
    assert.equal(await pending(),0,'nothing is staged');
    assert.equal(await source(),before,'nothing is written');
    await toMode('edit');
    await looks({padding:'16px',token:'16px'},'the preview is as it was');
    trail.push({refusal:await note.textContent().catch(()=>'')});
  });
  await caseRun('a proposal in a read-only workspace is refused at acceptance',async(trail)=>{
    await open({__isonimShorthandProposals:'1',__isonimShorthandReadOnly:'1'});
    const before=await source();
    const id=await propose('padding','sskSharedClass');
    await accept(id);
    const note=proposalCard(id).locator('[data-agent-proposal-refusal="true"]');
    await note.waitFor();
    assert.equal((await note.textContent()).trim(),'This workspace is read-only for source changes.');
    assert.equal(await pending(),0);
    assert.equal(await source(),before);
    trail.push({refusal:await note.textContent()});
  });
  await caseRun('a removable token\'s removal proposed, accepted and written, then View and Edit',async(trail)=>{
    await open({__isonimShorthandProposals:'1',__isonimShorthandRemovableTokens:'1'});
    const id=await propose('padding','sskComponentToken');
    const g0=await reloadGeneration();
    await accept(id);
    await assertPoll(async()=>[await pending(),await tokenDecl()],[0,''],'the variable\'s declaration is written out');
    assert.equal(await proposalCard(id).locator('[data-agent-proposal-refusal="true"]').count(),0,'no refusal');
    assert.ok((await reloadGeneration())>g0,'the write reloads the preview (nothing showed it)');
    await toMode('edit');
    await looks({padding:'0px',token:''},'after the accepted write');
    await rebuild();
    await looks({padding:'0px',token:''},'after View, then Edit');
    trail.push({preview:await look()});
  });
  await caseRun('Reset at the token scope written, then View and Edit',async(trail)=>{
    await open({__isonimShorthandRemovableTokens:'1'});
    const g0=await reloadGeneration();
    await resetAtTokenScope();
    await assertPoll(async()=>[await pending(),await tokenDecl()],[0,''],'the variable\'s declaration is written out');
    assert.equal(await reloadGeneration(),g0,'the write requests no reload (the removal showed itself)');
    await looks({padding:'0px',token:''},'after the Reset is written');
    const kept=(await records()).find(r=>r.property==='padding'&&r.value==='');
    assert.ok(kept&&kept.at,'the removal is kept');
    const at=JSON.parse(kept.at);
    assert.equal(at.variable,'--wl-space-card','recorded as the variable\'s removal');
    assert.equal(at.name,':root','at the rule that declares it');
    await rebuild();
    await looks({padding:'0px',token:''},'after View, then Edit');
    trail.push({place:at,preview:await look()});
  });
  await caseRun('Reset at the token scope, View and Edit before the write, then the write',async(trail)=>{
    await open({__isonimShorthandRemovableTokens:'1'});
    const before=await source();
    const now=await p.evaluate(()=>Date.now());
    await p.clock.pauseAt(now+5000);
    try{
      await resetAtTokenScope();
      await looks({padding:'0px',token:''},'the Reset shown');
      await rebuild();
      assert.equal(await source(),before,'nothing was written before the debounce fired');
      await looks({padding:'0px',token:''},'after View, then Edit, before the write');
      await p.evaluate(()=>document.activeElement?.blur());
      await p.clock.runFor(1500);
    }finally{await p.clock.resume();}
    await assertPoll(async()=>[await pending(),await tokenDecl()],[0,''],'the write');
    await looks({padding:'0px',token:''},'after the write');
    trail.push({preview:await look()});
  });

  // Follow-up (review PE1, PE2, P3).
  await caseRun('a token removal accepted while a field edit is pending is shown, also after View and Edit',async(trail)=>{
    await open({__isonimShorthandProposals:'1',__isonimShorthandRemovableTokens:'1'});
    const id=await propose('padding','sskComponentToken');
    await pendingFieldThenAccept(id);
    await assertPoll(async()=>[await pending(),await tokenDecl(),await cardRule()],[0,'','.destination-card { padding: var(--wl-space-card); padding-top: 30px; }'],'both written in one write');
    await toMode('edit');
    const shown=()=>card().evaluate(n=>({top:getComputedStyle(n).paddingTop,left:getComputedStyle(n).paddingLeft}));
    let r=await poll(shown,{top:'30px',left:'0px'});
    if(!r.ok)throw new Error('after the write the preview shows '+JSON.stringify(r.last)+'; the file renders top 30px, left 0px');
    await rebuild();
    r=await poll(shown,{top:'30px',left:'0px'});
    if(!r.ok)throw new Error('after View, then Edit the preview shows '+JSON.stringify(r.last)+'; the file renders top 30px, left 0px');
    trail.push({preview:r.last});
  });
  await caseRun('a class removal accepted while a field edit is pending is shown, also after View and Edit',async(trail)=>{
    await open({__isonimShorthandProposals:'1'});
    const id=await propose('padding','sskSharedClass');
    await pendingFieldThenAccept(id);
    await assertPoll(async()=>[await pending(),await cardRule()],[0,'.destination-card { padding-top: 30px; }'],'both written in one write');
    await toMode('edit');
    const left=()=>card().evaluate(n=>getComputedStyle(n).paddingLeft);
    let r=await poll(left,'0px');
    if(!r.ok)throw new Error('after the write the preview shows padding-left '+r.last+'; the file renders 0px');
    await rebuild();
    r=await poll(left,'0px');
    if(!r.ok)throw new Error('after View, then Edit the preview shows padding-left '+r.last+'; the file renders 0px');
    trail.push({left:r.last});
  });
  await caseRun('Revert of an accepted token removal puts the variable back',async(trail)=>{
    await open({__isonimShorthandProposals:'1',__isonimShorthandRemovableTokens:'1'});
    const before=await source();
    const id=await propose('padding','sskComponentToken');
    await accept(id);
    await assertPoll(async()=>[await pending(),await tokenDecl()],[0,''],'the acceptance is written');
    assert.equal(await cardButton('Accept',id).count(),0,'an accepted card offers no Accept');
    await cardButton('Revert',id).click();
    await assertPoll(async()=>[await pending(),await source()],[0,before],'the revert puts back exactly what was removed');
    await assertPoll(()=>cardStatus(id),'reverted','the proposal is reverted');
    assert.equal(await proposalCard(id).locator('[data-agent-proposal-refusal="true"]').count(),0,'no refusal');
    await toMode('edit');
    await looks({padding:'16px',token:'16px'},'after the revert');
    await rebuild();
    await looks({padding:'16px',token:'16px'},'after the revert, View then Edit');
    trail.push({preview:await look()});
  });
  await caseRun('Revert of an accepted class removal puts the declaration back',async(trail)=>{
    await open({__isonimShorthandProposals:'1'});
    const before=await source();
    const id=await propose('padding','sskSharedClass');
    await accept(id);
    await assertPoll(async()=>[await pending(),await cardRule()],[0,'.destination-card { }'],'the acceptance is written');
    await cardButton('Revert',id).click();
    await assertPoll(async()=>[await pending(),await source()],[0,before],'the revert puts back exactly what was removed');
    await assertPoll(()=>cardStatus(id),'reverted','the proposal is reverted');
    // A reverted proposal can be accepted again; it offers no Revert.
    assert.equal(await cardButton('Revert',id).count(),0,'a reverted card offers no Revert');
    assert.equal(await cardButton('Accept',id).count(),1,'a reverted card offers Accept again');
    await toMode('edit');
    await looks({padding:'16px',token:'16px'},'after the revert');
    trail.push({preview:await look()});
  });

  writeFileSync(pub+'/proof.json',JSON.stringify(proof,null,2));
  for(const c of proof.cases)console.log((c.ok?'ok   ':'FAIL ')+c.name+(c.ok?'':' -- '+c.error));
  assert.deepEqual(proof.failures,[],'every case');
  assert.deepEqual(proof.errors,[]);
  console.log('Proposal token GUI passed:',pub,proof.cases.length);
} finally {
  if(browser)await browser.close();
  await new Promise(resolve=>server.close(resolve));
}
