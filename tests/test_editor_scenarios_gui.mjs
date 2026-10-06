/**
 * Real browser production EditorVM -> daemon -> nim-agents -> Harbor REST/SSE,
 * official Rust Scenario-Format playback -> actual scoped CLI/RPC/source worker,
 * real filesystem/Nim compiler/SSR catalog -> actual mounted iframe document.
 * Only model decisions/responses are scripted, in shared editor-workflows.yaml.
 * File barriers coordinate observable tool/render state, never tool results.
 * Browser offline simulates actual network loss; no fake HTTP responses/events.
 * Playwright drives real keyboard/pointer controls. IME checks deliver composition
 * events to the actual DOM because the driver does not operate a workstation IME;
 * they verify production composition guards, without claiming OS IME coverage.
 * Credentials are observed from actual registration and kept in memory/private
 * files only. HTML captures and actual screenshots are separate artifacts.
 */
import assert from 'node:assert/strict';
import {createHash} from 'node:crypto';
import {readFileSync,writeFileSync,existsSync} from 'node:fs';
import {execFile} from 'node:child_process';
import {promisify} from 'node:util';
import path from 'node:path';
import {createPreparationClock} from './helpers/editor_preparation_clock.mjs';
import {chromium} from '../node_modules/playwright/index.mjs';
const context=JSON.parse(readFileSync(process.argv[2],'utf8'));
const {origin,project,repo,artifacts}=context;
const preparationClock=await createPreparationClock(context.preparationClock);
const exec=promisify(execFile);
const outcomes=[];
const evidence=(scenario,outcome)=>{
 outcomes.push({scenario,host:'gui',outcome});
 writeFileSync(path.join(artifacts,'outcomes.json'),JSON.stringify(outcomes,null,2));
 console.log('PASS GUI workflow '+scenario+': '+outcome);
};
const touch=name=>writeFileSync(path.join(artifacts,name),'observed');
const phase=value=>writeFileSync(path.join(artifacts,'phase'),String(value));
async function until(probe,label,ms=70000){
 const started=preparationClock.now();
 while(preparationClock.elapsed(started)<ms){const value=await probe();if(value)return value;await new Promise(resolve=>setTimeout(resolve,30));}
 throw Error('Observable barrier timeout: '+label);
}
async function controlUnchanged(before){
 const current=await cli(['state']);
 for(const field of ['selection','focus','highlight']) assert.equal(current[field],before[field],field+' remains unchanged');
}
async function renderedHighlight(target,previous){
 assert.equal(await preview().locator('#'+target).getAttribute('data-editor-agent-highlight'),'true');
 assert.notEqual(await preview().locator('#'+previous).getAttribute('data-editor-agent-highlight'),'true');
}
async function appliedSelection(target,previous){
 const current=await cli(['state']);
 assert.equal(current.selection,target);assert.equal(current.highlight,target);
 await renderedHighlight(target,previous);
 assert.equal(await preview().locator('#'+target).evaluate(node=>node===node.ownerDocument.activeElement),true);
}
let scope;
async function cli(args,expected=0,useScope=scope){
 const token=args[0]==='wait'&&useScope===scope?
  JSON.parse(readFileSync(path.join(artifacts,'private/provider-scope.json'),'utf8')).ISONIM_EDITOR_TOKEN:useScope.controlToken;
 const env={...process.env,ISONIM_EDITOR_ENDPOINT:origin,ISONIM_EDITOR_WORKSPACE:useScope.workspace,
  ISONIM_EDITOR_INSTANCE:useScope.instance,ISONIM_EDITOR_EPOCH:useScope.epoch,ISONIM_EDITOR_TOKEN:token};
 let result;
 try{result=await exec(path.join(repo,'build/bin/isonim'),['editor',...args],{env,timeout:70000});assert.equal(expected,0);}
 catch(error){assert.equal(error.code,expected,error.stdout+' '+error.stderr);result=error;}
 return JSON.parse(result.stdout);
}
async function rpc(method,params,token=scope.browserToken,useScope=scope){
 return (await fetch(origin+'/api/editor/rpc',{method:'POST',headers:{'Content-Type':'application/json','X-IsoNim-Control':token},
  body:JSON.stringify({jsonrpc:'2.0',id:1,method,params:{workspace:useScope.workspace,instance:useScope.instance,epoch:useScope.epoch,...params}})})).json();
}
const env={...process.env};delete env.LD_LIBRARY_PATH;
const browser=await chromium.launch({headless:true,env,executablePath:process.env.PLAYWRIGHT_CHROMIUM_EXECUTABLE??'/nix/store/1id5xlj91r8d5cj5ks4a5byrxdvr4b50-chromium-143.0.7499.192/bin/chromium'});
const browserContext=await browser.newContext({viewport:{width:1440,height:1000}});
const page=await browserContext.newPage();
const errors=[];page.on('pageerror',error=>errors.push(error.message));
// Opt-in read-only actual handler observations: no draft, credentials or waits.
await page.addInitScript(()=>{window.admissionObservations=[];window.__isonimObserveAgentAdmission=value=>window.admissionObservations.push({...value,time:Date.now()});});
const promptRequests=[];page.on('request',request=>{if(request.url().endsWith('/api/agent/prompts'))promptRequests.push(request.postDataJSON());});
let registrations=0;page.on('request',request=>{if(request.url().endsWith('/api/editor/rpc')&&request.postDataJSON()?.method==='editor.register')registrations++;});
// Read-only observation of actual successful browser publication. Record public
// target state only; authentication headers and registration credentials stay
// out of these artifacts. No fake response or request interception is used.
let acknowledgedControlState;
const controlPublications=[];
const controlFields=['revision','storyId','previewGeneration','elements','buildStage','focus','selection','highlight','viewport','view','mode','panels','surface','rightSidebarTab','buildDiagnostics'];
let acknowledgedBinding;
page.on('response',async response=>{
 const request=response.request();
 if(!response.url().endsWith('/api/editor/rpc')||request.postDataJSON()?.method!=='editor.poll'||!response.ok())return;
 let reply;
 try{reply=await response.json();}catch{
  // A closing/offline page may dispose a response body. It cannot establish
  // readiness; subsequent real acknowledged publication is still required.
  return;
 }
 if(!reply.result)return;
 const params=request.postDataJSON().params,state=params.state;if(!state)return;
 const binding=params.instance+':'+params.epoch;
 const published=Object.fromEntries(controlFields.map(field=>[field,state[field]]));
 if(binding===acknowledgedBinding&&acknowledgedControlState&&published.revision<acknowledgedControlState.revision)return;
 const changed=controlFields.filter(field=>binding!==acknowledgedBinding||JSON.stringify(acknowledgedControlState?.[field])!==JSON.stringify(published[field]));
 acknowledgedBinding=binding;acknowledgedControlState=published;
 if(changed.length){
  controlPublications.push({time:Date.now(),state:published,changed});
  writeFileSync(path.join(artifacts,'control-publications.json'),JSON.stringify(controlPublications,null,2));
 }
});
const composer=page.locator('[data-editor-control-focus="composer"]');
const send=page.getByRole('button',{name:'Send agent prompt',exact:true});
const preview=()=>page.frameLocator('iframe[data-component-project-frame="true"]');
let session;
async function sendPhase(number,text){
 const count=promptRequests.length;
 phase(number);await composer.fill(text);await send.click();
 await until(()=>promptRequests.length===count+1,'real prompt admitted');
 writeFileSync(path.join(artifacts,'admission-observations.json'),JSON.stringify(await page.evaluate(()=>window.admissionObservations),null,2));
}
async function turnEnded(){await until(()=>send.getAttribute('aria-disabled').then(value=>value==='false'),'actual terminal restores composer admission');}
const mountedReadiness=[];
async function mounted(text,buildStage='wesClean'){
 // Visible text can precede iframe load/inspector publication. Release the real
 // tool barrier only after this completed document's exact story, generation
 // and element tree have reached the daemon through a successful browser poll.
 const observed=[];
 await until(async()=>{
  const documentState=await page.evaluate(()=>{
   const frame=document.querySelector('iframe[data-component-project-frame="true"]');
   const doc=frame?.contentDocument,h1=doc?.querySelector('h1');
   return {readyState:doc?.readyState,heading:h1?.textContent,visible:!!h1?.getClientRects().length,
    storyId:doc?.querySelector('meta[name=isonim-rendered-story]')?.content,
    previewGeneration:Number(doc?.querySelector('meta[name=isonim-rendered-generation]')?.content),
    elements:doc?[...doc.querySelectorAll('[data-isonim-element-id]')].map(node=>node.getAttribute('data-isonim-element-id')).sort():[]};
  });
  const published=acknowledgedControlState;
  const observation={document:documentState,published};
  if(JSON.stringify(observed.at(-1))!==JSON.stringify(observation))observed.push(observation);
  if(documentState.readyState!=='complete'||!documentState.visible||!documentState.heading?.includes(text)||
     !published||acknowledgedBinding!==scope.instance+':'+scope.epoch||published.buildStage!==buildStage||published.storyId!==documentState.storyId||
     published.previewGeneration!==documentState.previewGeneration||!documentState.elements.length||
     JSON.stringify(published.elements.map(row=>row.id).sort())!==JSON.stringify(documentState.elements))return false;
  // Preserve Playwright's original heading visibility contract, including
  // hidden outer iframe ancestors, within this same readiness deadline.
  if(!await preview().locator('h1').filter({hasText:text}).isVisible())return false;
  const current=await cli(['state']);
  if(current.revision!==published.revision||current.storyId!==published.storyId||
     current.previewGeneration!==published.previewGeneration||
     JSON.stringify(current.elements.map(row=>row.id).sort())!==JSON.stringify(documentState.elements))return false;
  mountedReadiness.push({heading:text,observed,completed:{document:documentState,published,cliRevision:current.revision}});
  writeFileSync(path.join(artifacts,'mounted-readiness.json'),JSON.stringify(mountedReadiness,null,2));
  return true;
 },'completed mounted preview and acknowledged current element/story/generation state',30000);
}
async function shot(name){await page.screenshot({path:path.join(artifacts,name+'.png')});}
async function selectChat(id){
 const tab=page.locator(`[data-ai-assistant-tab="${id}"]`);
 const geometry=await tab.evaluate(node=>{
  const rect=node.getBoundingClientRect(),hit=document.elementFromPoint(rect.x+rect.width/2,rect.y+rect.height/2);
  const x=rect.x+rect.width/2,y=rect.y+rect.height/2;
  const ancestors=[node.parentElement,node.closest('[data-ai-assistant-tab-strip]'),node.closest('.editor-ai-assistant')]
   .filter(Boolean).map(parent=>{const box=parent.getBoundingClientRect(),style=getComputedStyle(parent);return {rect:box.toJSON(),scrollLeft:parent.scrollLeft,
    clientWidth:parent.clientWidth,scrollWidth:parent.scrollWidth,overflowX:style.overflowX,overflowY:style.overflowY,
    clips:((style.overflowX!=='visible')&&(x<box.left+parent.clientLeft||x>=box.left+parent.clientLeft+parent.clientWidth))||
     ((style.overflowY!=='visible')&&(y<box.top+parent.clientTop||y>=box.top+parent.clientTop+parent.clientHeight))};});
  return {tab:rect.toJSON(),hitTag:hit?.tagName,hitInTab:!!hit&&node.contains(hit),ancestors,
   clipped:ancestors.some(parent=>parent.clips)||x<0||x>=innerWidth||y<0||y>=innerHeight};
 });
 writeFileSync(path.join(artifacts,'chat-navigation-'+id+'.json'),JSON.stringify(geometry,null,2));
 if(geometry.hitInTab)await tab.click();
 else{
  assert(geometry.clipped,'Unoccluded tab must be reachable directly; overflow fallback requires actual clipping');
  const menu=page.getByRole('button',{name:'Show all chat sessions',exact:true});assert(await menu.isVisible());await menu.click();
  await page.locator(`[data-ai-assistant-overflow-entry="${id}"]`).click();
 }
 await until(async()=> (await cli(['state'])).conversations.find(row=>row.active).id===id,'actual selected chat '+id);
}
try{
 const registered=page.waitForResponse(response=>response.url().endsWith('/api/editor/rpc')&&response.request().postDataJSON()?.method==='editor.register');
 await page.goto(origin);scope=(await(await registered).json()).result;
 writeFileSync(path.join(artifacts,'private/browser-registration.json'),JSON.stringify(scope),{mode:0o600});
 assert(scope);await composer.waitFor();await until(async()=> (await cli(['state'])).capabilities.includes('create-story'),'real source adapter ready');
 await page.getByText('Suggested prompts',{exact:true}).waitFor();
 // Keyboard contracts on real unsubmitted draft, including composition guard.
 await composer.fill('first line');await composer.press('Shift+Enter');await composer.press('x');
 assert.equal(await composer.inputValue(),'first line\nx');
 const beforeIME=promptRequests.length;
 await composer.dispatchEvent('compositionstart');
 await composer.dispatchEvent('keydown',{key:'Enter',code:'Enter',isComposing:true});
 assert.equal(promptRequests.length,beforeIME);assert.equal(await composer.inputValue(),'first line\nx');
 await composer.dispatchEvent('compositionend');
 evidence(10,'Shift+Enter multiline and composing Enter cannot submit');
 phase(1);await composer.fill('Create the busy Card story, compile it, open it and capture its HTML.');await composer.press('Enter');
 await until(()=>existsSync(path.join(artifacts,'entered-1')),'official runCmd executing barrier');
 const originalHandoff=JSON.parse(readFileSync(path.join(artifacts,'private/original-handoff.json'),'utf8'));
 const terminalHandoff=JSON.parse(readFileSync(path.join(artifacts,'terminal-network.json'),'utf8')).original_handoff;
 assert.equal(terminalHandoff.path,originalHandoff.environment);
 assert.equal(terminalHandoff.session,originalHandoff.session);
 assert.deepEqual(terminalHandoff.allowed_keys,['ISONIM_EDITOR_CLI_DIR','ISONIM_EDITOR_ENDPOINT','ISONIM_EDITOR_EPOCH',
  'ISONIM_EDITOR_INSTANCE','ISONIM_EDITOR_TOKEN','ISONIM_EDITOR_WORKSPACE']);
 assert.equal(terminalHandoff.provider_scope_matches,true);
 assert.equal(terminalHandoff.file_mode,'0600');assert.equal(terminalHandoff.directory_mode,'0700');
 await page.getByText('ISONIM_M5_STREAM_BEGIN.',{exact:false}).first().waitFor();
 assert.equal(await send.getAttribute('aria-disabled'),'true');
 await composer.fill('Next browser draft during live output and tools');
 await page.getByText('Suggested prompts',{exact:true}).waitFor({state:'hidden'});
 const state=await cli(['state']);session=state.conversations.find(row=>row.active).backendSessionId;
 assert(session);const launch=readFileSync(path.join(artifacts,'provider-launch.jsonl'),'utf8');
 const cancel=page.getByRole('button',{name:'Cancel agent prompt',exact:true});
 assert.equal(await cancel.isVisible(),false,'Unsupported cancellation has no actionable button');
 const cancellation=await fetch(origin+'/api/agent/cancel',{method:'POST',headers:{'Content-Type':'application/json'},body:JSON.stringify({sessionId:session})});
 assert.equal(cancellation.status,409);assert.equal((await cancellation.json()).error,'unsupported_capability');
 touch('release-1');await mounted('Busy card');touch('capture-ready-1');await turnEnded();
 assert.equal(await composer.inputValue(),'Next browser draft during live output and tools');
 const capture=JSON.parse(readFileSync(path.join(artifacts,'capture-busy.json'),'utf8'));
 assert.equal(capture.status,'applied');assert.equal(capture.result.format,'text/html');assert(capture.result.documentHtml.includes('Busy card'));
 assert(capture.result.documentHtml.includes('isonim-rendered-story'));assert(!('captureBoundary' in capture.result));
 await preview().locator('body').screenshot({path:path.join(artifacts,'busy-mounted-preview.png')});
 await shot('created-streamed-guidance-dismissed');
 evidence(1,'actual create/compile/navigation/mounted HTML capture and separate PNG');
 evidence(3,'real streamed text/tool activity preserve next draft');evidence(11,'first Enter attempt hides guidance');
 await sendPhase(2,'Change Busy card to Followup card in this same conversation and compile.');
 await mounted('Followup card');touch('capture-ready-2');await turnEnded();
 assert.equal((await cli(['state'])).conversations.find(row=>row.active).backendSessionId,session);
 assert.equal(readFileSync(path.join(artifacts,'provider-launch.jsonl'),'utf8'),launch,'Same real provider process');
 const firstContext=promptRequests[0].context,followupContext=promptRequests[1].context;
 for(const context of [firstContext,followupContext]) {
  assert.equal(context.backend,'absAgentHarbor');assert.equal(context.platform,'pbWeb');
  for(const field of ['selectedStory','selectedElement','accumulatedEdits','pendingSourceEdits','sourceMap','designSystemSchema','selectedSchemaNodes','tokenContext','componentVariantContext','reviewAnnotations','screenshotRefs','domSnapshots','designSystemConstraints','diagnostics','currentFileDiffs','renderedComponentTree','availableTailwindClasses','tailwindClassTotal','themeTokens','activeThemeContext','contextAvailability'])assert(field in context);
  assert(context.availableTailwindClasses.includes('p-4'));
  assert(context.tailwindClassTotal>=context.availableTailwindClasses.length);
 }
 assert.equal(followupContext.selectedStory.group,'Card');assert.equal(followupContext.selectedStory.name,'default busy');
 assert(followupContext.renderedComponentTree.length>0,'Actual mounted document tree is delivered on follow-up');
 assert(followupContext.renderedComponentTree.some(row=>row.id==='action'&&row.depth>0&&row.parentId));
 const providerTurns=readFileSync(path.join(artifacts,'provider-prompts.jsonl'),'utf8').trim().split('\n').map(line=>JSON.parse(line));
 function deliveredContext(turn){const after=turn.split('EDITOR CONTEXT:\n')[1];assert(after);return JSON.parse(after.split('\n\nPROJECT CONTEXT:')[0]);}
 assert.deepEqual(deliveredContext(providerTurns[0]),firstContext,'Exact first context crosses real REST/provider boundary');
 const followupWire=deliveredContext(providerTurns[1]);
 const firstDelivered=deliveredContext(providerTurns[0]);
 assert.equal(followupWire.fromContext,createHash('sha1').update(JSON.stringify(firstDelivered)).digest('hex').toUpperCase(),'Envelope identifies exact actual admitted context');
 assert(followupWire.current&&typeof followupWire.current==='object'&&!Array.isArray(followupWire.current));
 assert(Object.keys(followupWire).every(key=>['fromContext','current','boundedInherited','protectedV1','protectedV2'].includes(key)),'Unknown context envelope versions/fields fail');
 assert(!('protectedV1' in followupWire&&'protectedV2' in followupWire),'Protected values have one exact version');
 assert.deepEqual(followupWire.boundedInherited??[],[],'Full first/followup equality cannot claim a bounded subset');
 const resolved={...firstDelivered};
 const protectedFields=['accumulatedEdits','pendingSourceEdits','designSystemConstraints','currentFileDiffs','selectedStory','selectedElement'];
 if('protectedV1' in followupWire||'protectedV2' in followupWire){
  const version2='protectedV2' in followupWire;
  const values=followupWire[version2?'protectedV2':'protectedV1'];assert(Array.isArray(values));assert.equal(values.length,6);values.forEach(value=>assert(Array.isArray(value)));
  assert.equal(values[4].length,4);values[4].forEach((value,i)=>assert(i<2?typeof value==='string':Number.isInteger(value)));
  const elementFields=['id','sourceKey','domPath','schemaKey','tag','sourceFile','sourceLine','sourceColumn','properties','children','ancestors','ancestorIds','depth'];
  if(version2)elementFields.push('styleBindings');
  assert.equal(values[5].length,elementFields.length);values[5].forEach((value,i)=>assert(i<6||i===13?typeof value==='string':[6,7,12].includes(i)?Number.isInteger(value):Array.isArray(value)));
  protectedFields.slice(0,4).forEach((field,i)=>resolved[field]=values[i]);
  resolved.selectedStory={group:values[4][0],name:values[4][1],kind:values[4][2],index:values[4][3]};resolved.selectedElement=Object.fromEntries(elementFields.map((field,i)=>[field,values[5][i]]));
  protectedFields.forEach(field=>assert(!(field in followupWire.current),'Protected values have one exact representation'));
 }else protectedFields.forEach(field=>assert(field in followupWire.current,'Protected current fields stay explicit'));
 for(const [field,value] of Object.entries(followupWire.current)){
  if(value&&typeof value==='object'&&!Array.isArray(value)&&'fromPreviousItems' in value){
   assert(!protectedFields.includes(field),'Protected current fields cannot inherit records');
   assert.deepEqual(Object.keys(value),['fromPreviousItems']);assert(Array.isArray(value.fromPreviousItems));
   assert(Array.isArray(firstDelivered[field]));
   resolved[field]=value.fromPreviousItems.map(item=>{
    if('reuse' in item){assert.deepEqual(Object.keys(item),['reuse']);assert(Number.isInteger(item.reuse)&&item.reuse>=0&&item.reuse<firstDelivered[field].length);return firstDelivered[field][item.reuse];}
    assert.deepEqual(Object.keys(item),['value']);return item.value;
   });
  }else resolved[field]=value;
 }
 assert.deepEqual(resolved,followupContext,'Exact full current follow-up context crosses same provider boundary via verified representations');
 evidence(2,'same provider/session followup compiles second source change; complete first/follow-up context arrives at official provider');evidence(4,'truthful unsupported cancel then later prompt same session');
 await sendPhase(4,'Select and highlight action automatically, then focus the composer.');await turnEnded();
 await until(async()=> (await cli(['state'])).selection==='action','automatic real selection');
 assert.equal(await preview().locator('#action').getAttribute('data-editor-agent-highlight'),'true');
 assert.equal(await composer.evaluate(node=>node===document.activeElement),true);
 await shot('automatic-selection-highlight');
 await page.locator('[data-editor-control-approval]').check();
 await until(async()=> (await cli(['state'])).approvalRequired===true,'actual registered approval preference');
 await sendPhase(5,'Select and highlight secondary-action with approval required.');await turnEnded();
 const pending=page.locator('[data-editor-control-approve="approved-select"]');await pending.waitFor();
 const beforeApproval=JSON.parse(readFileSync(path.join(artifacts,'approval-before.json'),'utf8'));
 assert.equal(beforeApproval.selection,'action');assert.equal(beforeApproval.highlight,'action');assert.notEqual(beforeApproval.selection,'secondary-action');
 await controlUnchanged(beforeApproval);await renderedHighlight('action','secondary-action');
 assert.equal((await cli(['wait','approved-select','--timeout-ms','100'],5)).operation.status,'pending');
 await shot('selection-pending');await pending.click();
 assert.equal((await cli(['wait','approved-select'])).status,'applied');
 await appliedSelection('secondary-action','action');
 await shot('selection-approved');
 assert.equal((await cli(['state'])).approvalRequired,true);
 await sendPhase(6,'Request selecting and highlighting action, subject to rejection.');await turnEnded();
 await page.locator('[data-editor-control-reject="rejected-focus"]').waitFor();
 const beforeReject=JSON.parse(readFileSync(path.join(artifacts,'rejection-before.json'),'utf8'));
 assert.equal(beforeReject.selection,'secondary-action');assert.equal(beforeReject.highlight,'secondary-action');assert.notEqual(beforeReject.selection,'action');
 await controlUnchanged(beforeReject);await renderedHighlight('secondary-action','action');
 await page.locator('[data-editor-control-reject="rejected-focus"]').click();
 assert.equal((await cli(['wait','rejected-focus'],4)).status,'rejected');await controlUnchanged(beforeReject);await renderedHighlight('secondary-action','action');
 await shot('focus-rejected');evidence(12,'automatic and pending/approved/rejected real CLI/RPC + visible chat controls and DOM focus/highlight');
 await page.setViewportSize({width:900,height:720});
 await sendPhase(15,'At narrow width select and highlight action with approval.');await turnEnded();
 const narrowPending=page.locator('[data-editor-control-approve="narrow-approved-select"]');await narrowPending.waitFor();
 const narrowBefore=JSON.parse(readFileSync(path.join(artifacts,'narrow-approval-before.json'),'utf8'));
 assert.equal(narrowBefore.selection,'secondary-action');assert.equal(narrowBefore.highlight,'secondary-action');assert.notEqual(narrowBefore.selection,'action');
 await controlUnchanged(narrowBefore);await renderedHighlight('secondary-action','action');
 await shot('narrow-selection-pending');await narrowPending.click();
 assert.equal((await cli(['wait','narrow-approved-select'])).status,'applied');
 await appliedSelection('action','secondary-action');
 await sendPhase(16,'At narrow width reject selecting and highlighting secondary-action.');await turnEnded();
 const narrowReject=page.locator('[data-editor-control-reject="narrow-rejected-focus"]');await narrowReject.waitFor();
 const narrowRejection=JSON.parse(readFileSync(path.join(artifacts,'narrow-rejection-before.json'),'utf8'));
 assert.equal(narrowRejection.selection,'action');assert.equal(narrowRejection.highlight,'action');assert.notEqual(narrowRejection.selection,'secondary-action');
 await controlUnchanged(narrowRejection);await renderedHighlight('action','secondary-action');
 await narrowReject.click();assert.equal((await cli(['wait','narrow-rejected-focus'],4)).status,'rejected');
 await controlUnchanged(narrowRejection);await renderedHighlight('action','secondary-action');await shot('narrow-focus-rejected');
 evidence(12,'normal pending approve/reject pointer controls work at narrow width; actual DOM selection/highlight/focus and rejection preservation');
 await page.setViewportSize({width:1440,height:1000});
 await page.locator('[data-editor-control-approval]').uncheck();
 const source=readFileSync(path.join(project,'stories.nim'),'utf8'),catalog=readFileSync(path.join(project,'.isonim/catalog.json'),'utf8');
 await sendPhase(3,'Attempt invalid error fixture and expose real compiler failure.');await turnEnded();
 const failed=await cli(['wait','fail-compile'],4);assert(failed.diagnostic.includes('type mismatch'));
 assert.equal(readFileSync(path.join(project,'stories.nim'),'utf8'),source);assert.equal(readFileSync(path.join(project,'.isonim/catalog.json'),'utf8'),catalog);
 await mounted('Followup card','wesFailed');
 const failedCard=page.locator('[data-chat-entry]').filter({has:page.locator('[data-chat-activity-status]').filter({hasText:/^failed$/})}).last();
 await failedCard.locator('[data-chat-activity-status]').waitFor();
 await failedCard.locator('summary').click();
 const diagnosticDetails=failedCard.locator('[data-chat-detail]');await diagnosticDetails.waitFor({state:'visible'});
 const visibleDetailText=await diagnosticDetails.textContent();
 assert(visibleDetailText.includes('type mismatch'));
 assert(visibleDetailText.includes(JSON.stringify(failed.diagnostic).slice(1,-1)),
  'Visible expanded raw CLI JSON retains the exact encoded real compiler diagnostic');
 await shot('visible-compile-failure');
 evidence(5,'actual failed tool visible; normal Details click exposes exact compiler diagnostic; mounted prior preview unchanged');
 for(const width of [1440,900]){
  await page.setViewportSize({width,height:width===900?720:1000});
  const toolbar=page.locator('[data-preview-chrome-bar]');
  assert.equal((await toolbar.boundingBox()).height,44,'Single-row chrome preserves header alignment');
  const strip=toolbar.locator('[data-preview-viewport-strip-host]');
  const trigger=page.locator('[data-preview-viewport-overflow]');
  const current=toolbar.locator('[data-preview-viewport-current]');
  const dropdown=page.locator('[data-preview-viewport-dropdown]');
  const compact=width===900;
  assert.equal(await strip.isVisible(),!compact,'Wide pinned strip and narrow current-size selector');
  assert.equal(await current.isVisible(),compact);
  if(compact){
   await trigger.click();await dropdown.waitFor({state:'visible'});
   const desktop=dropdown.locator('[data-preview-viewport-dropdown-option="desktop"]');
   assert(await desktop.isVisible(),'Common sizes remain reachable through the compact selector');
   await desktop.click();await dropdown.waitFor({state:'hidden'});
  }else{
   await strip.getByRole('button',{name:'Desktop',exact:true}).click();
  }
  await until(async()=> (await cli(['state'])).viewport==='desktop','normal common viewport selection '+width);
  if(compact)assert.equal(await current.innerText(),'Desktop');
  await trigger.click();await dropdown.waitFor({state:'visible'});
  for(const slug of ['desktop','laptop','tablet','phone']){
   assert.equal(await dropdown.locator(`[data-preview-viewport-dropdown-option="${slug}"]`).isVisible(),compact,
    'Pinned choices belong in the wide strip or compact menu: '+slug);
  }
  const columnBox=await page.locator('[data-preview-center-column]').boundingBox();
  const popupBox=await dropdown.boundingBox();
  assert(popupBox.x>=columnBox.x&&popupBox.x+popupBox.width<=columnBox.x+columnBox.width,
   'Anchored viewport menu stays within the center column');
  writeFileSync(path.join(artifacts,`toolbar-${width}.json`),JSON.stringify({compact,columnBox,popupBox,
   geometry:await toolbar.evaluate(bar=>({width:bar.clientWidth,scrollWidth:bar.scrollWidth,scrollLeft:bar.scrollLeft}))},null,2));
  await page.keyboard.press('Escape');await dropdown.waitFor({state:'hidden'});
  assert(await trigger.evaluate(node=>node===document.activeElement));
  await page.keyboard.press('Enter');await dropdown.waitFor({state:'visible'});
  const firstSlug=compact?'desktop':'wide';
  const nextSlug=compact?'laptop':'ultrawide';
  const firstVisible=dropdown.locator(`[data-preview-viewport-dropdown-option="${firstSlug}"]`);
  assert(await firstVisible.isVisible());
  assert(await firstVisible.evaluate(node=>node===document.activeElement),'Keyboard focuses the independently expected first VISIBLE option');
  assert(await dropdown.locator('[role=option]').evaluateAll(nodes=>nodes.every(node=>node.getClientRects().length||node!==document.activeElement)),
   'Hidden pinned options never receive keyboard focus');
  await page.keyboard.press('ArrowDown');
  assert(await dropdown.locator(`[data-preview-viewport-dropdown-option="${nextSlug}"]`).evaluate(node=>node===document.activeElement));
  await page.keyboard.press('ArrowUp');
  assert(await firstVisible.evaluate(node=>node===document.activeElement));
  await page.keyboard.press('Enter');await dropdown.waitFor({state:'hidden'});
  await until(async()=> (await cli(['state'])).viewport===firstSlug,'normal keyboard viewport selection '+width);
  assert(await trigger.evaluate(node=>node===document.activeElement));
  await page.keyboard.press('Enter');await dropdown.waitFor({state:'visible'});
  await page.keyboard.press('Escape');await dropdown.waitFor({state:'hidden'});
  await trigger.click();await composer.click();await dropdown.waitFor({state:'hidden'});
  await trigger.click();await page.setViewportSize({width:width-1,height:width===900?720:1000});
  await dropdown.waitFor({state:'hidden'});
  await page.setViewportSize({width,height:width===900?720:1000});
  await trigger.click();
  const option=dropdown.locator('[data-preview-viewport-dropdown-option="wide"]');
  assert(await option.isVisible(),'Explicit long-tail size remains visible at both widths');
  await option.click();await dropdown.waitFor({state:'hidden'});
  await until(async()=> (await cli(['state'])).viewport==='wide','normal viewport dropdown selection '+width);
  if(compact)assert.equal(await current.innerText(),'Wide');
  await toolbar.locator('[data-toolbar-cluster=mode]').getByRole('button',{name:'View',exact:true}).click();
  await until(async()=> (await cli(['state'])).mode==='emView','normal View mode selection '+width);
 }
 evidence(10,'wide/narrow 44px scrolling toolbar, anchored viewport dropdown, keyboard/ESC/outside-click/resize and View controls remain reachable');
 const firstTab=(await cli(['state'])).conversations.find(row=>row.active).id;
 const firstHistory=await page.locator('[data-chat-entry]').allTextContents();assert(firstHistory.length>0);
 await page.setViewportSize({width:1440,height:1000});
 await composer.fill('first chat independent draft');await page.locator('[data-ai-assistant-new-chat]').click();
 assert.equal(await page.locator('[data-chat-entry]').count(),0);
 const secondTab=await until(async()=>{
  const visible=await page.locator('[data-chat-local-id]').getAttribute('data-chat-local-id');
  const published=(await cli(['state'])).conversations.find(row=>row.active).id;
  return visible!==firstTab&&published===visible?visible:false;
 },'new second chat identity published from actual mounted chat');
 assert.notEqual(secondTab,firstTab);
 await composer.fill('second chat independent draft');
 await selectChat(firstTab);assert.equal(await composer.inputValue(),'first chat independent draft');
 assert.equal((await cli(['state'])).conversations.find(row=>row.active).backendSessionId,session);
 assert.deepEqual(await page.locator('[data-chat-entry]').allTextContents(),firstHistory);
 assert.equal(await page.getByText('Suggested prompts',{exact:true}).isVisible(),false);
 await selectChat(secondTab);assert.equal(await composer.inputValue(),'second chat independent draft');
 await page.setViewportSize({width:900,height:720});
 await page.locator('[data-ai-assistant-new-chat]').click();
 const thirdTab=await until(async()=>{
  const visible=await page.locator('[data-chat-local-id]').getAttribute('data-chat-local-id');
  const published=(await cli(['state'])).conversations.find(row=>row.active).id;
  return visible!==secondTab&&visible!==firstTab&&published===visible?visible:false;
 },'new third chat identity published from actual mounted chat');
 assert.notEqual(thirdTab,firstTab);assert.notEqual(thirdTab,secondTab);
 await composer.fill('third narrow chat independent draft');
 assert.equal(await page.locator('[data-chat-entry]').count(),0);
 await selectChat(secondTab);assert.equal(await composer.inputValue(),'second chat independent draft');
 await selectChat(thirdTab);assert.equal(await composer.inputValue(),'third narrow chat independent draft');
 await selectChat(firstTab);evidence(6,'real chat tab/overflow navigation and drafts/history isolation');evidence(11,'return does not restore suggestions');
 assert.equal((await cli(['state'])).conversations.find(row=>row.active).backendSessionId,session);
 await page.setViewportSize({width:1440,height:1000});
 // Genuine same-tab network disconnect lasts until the production lease expires.
 // Waiting is based on actual denied lease state, not a fixed wall-clock sleep.
 await browserContext.setOffline(true);
 await until(async()=>{const result=await cli(['state'],3).catch(()=>null);return result?.error==='disconnected_instance';},'actual native registry lease expiration',20000);
 const oldRegistrationCount=registrations;
 await browserContext.setOffline(false);
 await until(async()=>{try{return (await cli(['state'])).instance===scope.instance;}catch{return false;}},'same instance authenticated lease resume');
 assert.equal(registrations,oldRegistrationCount,'Same mounted tab must keep provider targeting identity');
 await sendPhase(10,'After reconnect focus the composer with this same provider scope.');await turnEnded();
 assert.equal((await cli(['state'])).conversations.find(row=>row.active).backendSessionId,session);assert.equal(readFileSync(path.join(artifacts,'provider-launch.jsonl'),'utf8'),launch);
 assert.equal((await cli(['wait','reconnect-focus'])).status,'applied');assert.equal(await composer.evaluate(node=>node===document.activeElement),true);
 // A separately disconnected instance remains revoked even with its exact old
 // browser/control credentials, and cannot renew or target our current editor.
 const other=await browserContext.newPage();const otherRegistration=other.waitForResponse(r=>r.url().endsWith('/api/editor/rpc')&&r.request().postDataJSON()?.method==='editor.register');await other.goto(origin);
 const stale=(await(await otherRegistration).json()).result;
 const beforeStaleTarget=await cli(['state']);
 await rpc('editor.disconnect',{},stale.browserToken,stale);
 assert.equal((await rpc('editor.poll',{},stale.browserToken,stale)).error.message,'disconnected_instance');
 assert.equal((await cli(['focus','composer','--command-id','stale-instance','--wait'],3,stale)).error,'disconnected_instance');await other.close();
 const afterStaleTarget=await cli(['state']);
 for(const key of ['storyId','selection','highlight','focus','viewport'])assert.deepEqual(afterStaleTarget[key],beforeStaleTarget[key]);
 evidence(7,'genuine offline/lease expiry/same-tab/same provider scope resumes; revoked other instance denied');
 // Real narrow viewport and manual transcript scroll keep draft and focus usable.
 await page.setViewportSize({width:900,height:720});await composer.fill('narrow draft retained');await composer.focus();
 assert.equal(await composer.evaluate(node=>node===document.activeElement),true);
 const bounds=await composer.boundingBox();assert(bounds.width>80&&bounds.x+bounds.width<=900);
 const scroll=page.locator('[data-chat-scroll]');
 assert(await scroll.evaluate(node=>node.scrollHeight>node.clientHeight),'Real transcript must overflow for manual-scroll coverage');
 await sendPhase(14,'Stream while I scroll away and compose another draft.');
 await until(()=>existsSync(path.join(artifacts,'entered-14')),'actual late streaming barrier');
 await scroll.evaluate(node=>node.scrollTop=0);await composer.fill('narrow draft retained while new output streams');
 const position=await scroll.evaluate(node=>node.scrollTop);
 touch('release-14');await turnEnded();
 assert.equal(await scroll.evaluate(node=>node.scrollTop),position,'New actual output preserves user scroll position');
 assert.equal(await composer.inputValue(),'narrow draft retained while new output streams');
 const latest=page.locator('[data-chat-latest]');await latest.waitFor({state:'visible'});await latest.click();
 assert(await scroll.evaluate(node=>node.scrollTop>0),'Return to latest follows real transcript content');
 await shot('narrow-user-scroll-draft');evidence(10,'real narrow layout/focus and actual streamed output preserve manual scroll/draft; Return to latest resumes');
 assert.deepEqual(errors,[]);
 const closed=await fetch(origin+'/api/agent/close',{method:'POST',headers:{'Content-Type':'application/json'},body:JSON.stringify({sessionId:session})});
 assert.equal(closed.status,200);
 const reloadRegistration=page.waitForResponse(r=>r.url().endsWith('/api/editor/rpc')&&r.request().postDataJSON()?.method==='editor.register');
 await page.reload();const previous=scope;scope=(await(await reloadRegistration).json()).result;
 assert.notEqual(scope.instance,previous.instance);
 await until(async()=> (await cli(['state'])).stories.some(story=>story.id==='Card / default busy'),'persisted story after real browser reload');
 await cli(['open-story','Card / default busy','--command-id','open-reloaded','--wait']);await mounted('Followup card');
 const reloadedCapture=await cli(['capture-preview','--command-id','capture-reloaded','--wait']);
 assert(reloadedCapture.result.documentHtml.includes('Followup card'));
 await shot('persisted-reloaded-story');evidence(1,'real browser reload opens/captures persisted compiled Followup story');
 writeFileSync(path.join(artifacts,'outcomes.json'),JSON.stringify(outcomes,null,2));
 console.log('PASS M5 GUI workflows '+outcomes.length+' outcomes; '+artifacts);
}catch(error){writeFileSync(path.join(artifacts,'admission-observations.json'),JSON.stringify(await page.evaluate(()=>window.admissionObservations).catch(()=>[]),null,2));await shot('failure').catch(()=>{});writeFileSync(path.join(artifacts,'failure.txt'),String(error.stack));throw error;}
finally{await browser.close();}
