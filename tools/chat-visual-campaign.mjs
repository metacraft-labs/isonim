/** Production mounted editor campaign. Synthetic DTO corpus substitutes external
 * transport timing only; actual normalization/reducer/VM/view/DOM are unchanged.
 * Real Rust mock REST scenarios are separately required, never claimed here.
 * Local control-host fixture substitutes connected transport timing only; real
 * admission/approval and production DOM adapters remain installed. Initial control
 * admission requires complete visible preview/documents, loaded fonts, actual DOM
 * targets in the production published scene graph (300ms/700ms scanner), then two
 * advancing actual animation callback timestamps within one 5000ms deadline.
 * Every capture shares this readiness boundary. Negative controls
 * temporarily replace the read-only fixture snapshot with missing published rows
 * (a stalled-publication timing substitute) and change the real preview heading
 * (a wrong-document substitute); they use the same predicate and restore both.
 * No VM/renderer/scanner is mocked or invoked by these controls.
 * No revision polling/rebasing, forced result or mutation retry.
 * Read-only stored-operation diagnostics persist before assertions.
 * Run inside the pinned capture container via chat-visual-campaign.py.
 */
import assert from 'node:assert/strict';
import {horizontalChatGuard,oldClippedChatControl} from './chat-horizontal-guard.mjs';
import {sidebarSearchFocusEvidence,requireSidebarSearchFocus} from './chat-focus-guard.mjs';
import {waitForAdvancingFrames} from './chat-capture-frames.mjs';
import {execFileSync} from 'node:child_process';
import {createServer} from 'node:http';
import {readFileSync,writeFileSync,mkdirSync,readdirSync,rmSync,existsSync} from 'node:fs';
import {createHash} from 'node:crypto';
import path from 'node:path';
import {chromium} from '../node_modules/playwright/index.mjs';
const args=process.argv.slice(2);const option=(name,fallback)=>args.includes(name)?args[args.indexOf(name)+1]:fallback;
const output=option('--output','/captures'); const filter=option('--view','');const sizeFilter=option('--size','');
const hash=buffer=>createHash('sha256').update(buffer).digest('hex');
const corpus=JSON.parse(readFileSync(new URL('../tests/scenarios/chat-activity/public-session-events.json',import.meta.url)));
const thresholds=JSON.parse(readFileSync(new URL('./chat-visual-thresholds.json',import.meta.url)));
const sizes={wide:{width:1440,height:900,panel:420},narrow:{width:1024,height:768,panel:240}};
// Explicit representatives follow the independent expected-elements briefs.
// Repeated event types must never depend on fixture object/insertion order.
const isolatedReferences={
 user_input:['conversation',0],log:['long-content',0],thought:['completed',1],
 tool_use:['long-content',1],tool_result:['tools',5],plan:['plan',0],
 turn_complete:['completed',2],file_edit:['files',0],file_read:['files',1],diff:['files',2],
 llm_request:['model-context',0],context_files:['model-context',1],context_injection:['model-context',2],
 workspace:['workspace',0],fleet_fence:['workspace',1],fleet_host:['workspace',2],
 sub_agent:['delegation',0],delegation:['delegation',1],orchestration:['delegation',2],
 session_started:['lifecycle',0],session_awaiting_input:['login',1],session_resumed:['lifecycle',2],session_ended:['lifecycle',3],
 proxy_credential_rotated:['recovery',0],proxy_rate_limit_absorbed:['recovery',1],dispatcher_restarted:['recovery',2],
 anti_halting_resume_confirmed:['recovery',3],session_leadership_migrated:['recovery',4],
 agent_question:['question',0],login_required:['login',0],participant:['participants',0],link_spans:['participants',1],
 status:['error',0],error:['error',1]
};
assert.deepEqual(Object.keys(isolatedReferences).sort(),[...new Set(Object.values(corpus.scenes).flat().map(event=>event.type))].sort(),'exact isolated REST type inventory');
const singleEvents=Object.fromEntries(Object.entries(isolatedReferences).map(([type,[scene,index]])=>{
 const event=corpus.scenes[scene][index];assert.equal(event.type,type,'named isolated representative type');
 return ['event-'+type,[event]];
}));
// Literal visible facts audited against chat-visual-expected.json, not derived
// from the selected DTO, production normalization, or captured manifest.
const isolatedContent={
 user_input:['You','Improve the hero spacing.'],
 log:['Assistant','Long source identifiers remain readable:'],
 thought:['Thinking','Verified the mounted preview.','streaming'],
 tool_use:['isonim inspect','started'],
 tool_result:['isonim build','failed','stories/hero.nim:42: undeclared identifier spacingLarge','Exit code','1'],
 plan:['Plan','Inspect the current hero','Create the spacious variant','Check tablet layout','completed','in progress','pending'],
 turn_complete:['Turn complete','Stop reason','end_turn','Input tokens','1260','Output tokens','180'],
 file_edit:['File change · stories/hero.nim','+4 / −2 lines','Use shared spacing and preserve the title.'],
 file_read:['File read','theme/spacing.nim','From line','8','To line','20'],
 diff:['Diff · stories/hero.nim','Before','After','padding = "16px"','gap = "8px"','padding = "32px"','gap = "16px"'],
 llm_request:['Model request','Sonnet','1260','180','provider_reported','Messages','6','Tool calls','true'],
 context_files:['Context files','added','Files in context','2','stories/hero.nim','theme/spacing.nim'],
 context_injection:['Session context','attribution','Website author requested a spacious hero.'],
 workspace:['Workspace ready','/workspace/website','local'],
 fleet_fence:['Workspace synchronization','fence_complete','preview-sync','240'],
 fleet_host:['Host execution','host_complete','preview-host','linux','isonim build','Exit code','0','stdout','Compiled the website preview.'],
 sub_agent:['Sub-agent','layout-review','website-session','thought','Checking the tablet hero layout.'],
 delegation:['Delegation','completed','Active agents','0','Total agents','1','Layout review completed.'],
 orchestration:['Orchestration','review_requested','layout-review','Review the selected hero story.'],
 session_started:['Session started'],
 session_awaiting_input:['Waiting for input','Request','login-provider','Waiting for input. This editor cannot respond to this request.'],
 session_resumed:['Session resumed','Deliverer','human'],session_ended:['Session ended','Outcome','completed'],
 proxy_credential_rotated:['Provider access recovered','anthropic','Provider status','401'],
 proxy_rate_limit_absorbed:['Provider throttling recovered','Retry attempts','2','Wait (ms)','1200'],
 dispatcher_restarted:['Agent restarted','Restart','2'],anti_halting_resume_confirmed:['Agent progress resumed','Recovered stall','idle'],
 session_leadership_migrated:['Session moved to another executor','authoring-host','preview-host','linux','Flushed sequence','40'],
 agent_question:['Agent question','Which hero spacing should I use?','question-hero','Comfortable','Compact','This editor cannot answer this request.'],
 login_required:['Provider login required','anthropic','login-provider',"Open the matching LOGIN REQUIRED card in Agent Harbor WebUI task details or Inbox, if available. This editor cannot open sign-in. If you cannot access Harbor, ask this editor's operator to open the request."],
 participant:['Participant activity','Website author','owner','joined'],link_spans:['Source references','stories/hero.nim'],
 status:['Session','running'],error:['Error','Build failed. The last successful preview is still available.']
};
assert.deepEqual(Object.keys(isolatedContent).sort(),Object.keys(isolatedReferences).sort(),'exact independent semantic oracle inventory');
const wrongIsolated={thought:corpus.scenes.conversation[3],tool_use:corpus.scenes.tools[4],
 session_awaiting_input:corpus.scenes.question[1],turn_complete:corpus.scenes.plan[1]};
const sceneEvents={...corpus.scenes,...singleEvents,...corpus.normalizedScenes,"event-log-bottom":singleEvents["event-log"],"recovery-top":corpus.scenes.recovery,"long-content-top":corpus.scenes["long-content"]};
const allViews=['empty',...Object.keys(sceneEvents),...Object.keys(corpus.behaviorScenes)];
const lineage={bundleSha256:hash(readFileSync(new URL('../build/editor-chat/editor.js',import.meta.url))),sceneSha256:hash(readFileSync(new URL('../tests/scenarios/chat-activity/public-session-events.json',import.meta.url))),captureSha256:hash(readFileSync(new URL(import.meta.url))),browserExecutableSha256:hash(readFileSync('/ms-playwright/chromium-1217/chrome-linux64/chrome')),fonts:[...new Set(execFileSync('fc-list',['--format','%{file}\n'],{encoding:'utf8'}).trim().split('\n'))].sort().map(file=>({file,sha256:hash(readFileSync(file))}))};
const flags=['--no-sandbox','--disable-gpu','--force-color-profile=srgb','--font-render-hinting=none','--disable-lcd-text'];
const environment={deviceScaleFactor:1,locale:'en-US',timezoneId:'UTC',colorScheme:'dark',reducedMotion:'reduce'};
lineage.horizontalGuardSha256=hash(readFileSync(new URL('./chat-horizontal-guard.mjs',import.meta.url)));
lineage.focusGuardSha256=hash(readFileSync(new URL('./chat-focus-guard.mjs',import.meta.url)));
lineage.captureFramesSha256=hash(readFileSync(new URL('./chat-capture-frames.mjs',import.meta.url)));
lineage.expectedSha256=hash(readFileSync(new URL('./chat-visual-expected.json',import.meta.url)));
lineage.thresholdsSha256=hash(readFileSync(new URL('./chat-visual-thresholds.json',import.meta.url)));
const expected=JSON.parse(readFileSync(new URL('./chat-visual-expected.json',import.meta.url)));
assert.deepEqual(Object.keys(expected).sort(),allViews.slice().sort(),'exact expected view inventory');
assert.deepEqual(Object.keys(thresholds).sort(),allViews.slice().sort(),'exact threshold view inventory');
lineage.mountedAssets=['editor.js','index.html','fabric.min.js','paper-core.min.js','svgo.browser.js'].map(file=>({file,sha256:hash(readFileSync(new URL('../build/editor-chat/'+file,import.meta.url)))}));
const canary=args.includes('--canary');const recoveryOnly=args.includes('--recovery-controls-only');
assert(!recoveryOnly||(!filter&&!sizeFilter&&!canary),'recovery controls require their own complete paired scope');
const longContentOnly=args.includes('--long-content-controls-only');
assert(!longContentOnly||(!filter&&!sizeFilter&&!canary&&!recoveryOnly),'long-content controls require their own complete paired scope');
const views=longContentOnly?['long-content','long-content-top']:recoveryOnly?['recovery','recovery-top']:filter?[filter]:canary?['conversation','plan']:allViews;
for(const name of views)assert(allViews.includes(name),`unknown view ${name}`);
for(const name of sizeFilter?[sizeFilter]:Object.keys(sizes))assert(sizes[name],`unknown viewport ${name}`);
mkdirSync(output,{recursive:true});
const targeted=Boolean(filter||sizeFilter);
let previous=null;
if(targeted){
 assert(existsSync(path.join(output,'manifest.json')),'targeted capture requires full current corpus');
 previous=JSON.parse(readFileSync(path.join(output,'manifest.json')));
 assert.equal(previous.schema,2,'full regeneration required for old manifest');
 assert.deepEqual(previous.lineage,lineage,'changed capture closure requires full regeneration');
 assert.equal(previous.container,'mcr.microsoft.com/playwright@sha256:eac9b0a5312cdab40ee8c2429df5bf19bffdccf8f3bf3c42268e173f97541645');
 assert.equal(previous.browser,'147.0.7727.15');assert.equal(previous.node,process.version);
 assert.deepEqual(previous.flags,flags);assert.deepEqual(previous.environment,environment);assert.deepEqual(previous.sizes,sizes);
 const keys=new Set();for(const row of previous.views){
  const key=row.view+'/'+row.size;assert(allViews.includes(row.view)&&sizes[row.size]&&!keys.has(key),'unknown/duplicate prior key');keys.add(key);
  assert.equal(row.file,`${row.view}-${row.size}.png`);const png=readFileSync(path.join(output,row.file));assert.equal(hash(png),row.sha256,'prior PNG altered');
  assert.equal(png.subarray(0,8).toString('hex'),'89504e470d0a1a0a');
  assert.deepEqual(row.dimensions,[sizes[row.size].width,sizes[row.size].height]);assert.deepEqual(row.dimensions,[png.readUInt32BE(16),png.readUInt32BE(20)]);
  assert.equal(row.scope,'full editor viewport');assert.equal(row.browser,previous.browser);assert.deepEqual(row.perceptualThreshold,{maximumChangedPixelRatio:thresholds[row.view]});
 }
 assert.equal(keys.size,allViews.length*2,'missing prior views');
}else for(const name of readdirSync(output))if(name.endsWith('.png')||['manifest.json','review.html','findings-ledger.json','perceptual-gates.json','missing-element-control.json'].includes(name))rmSync(path.join(output,name));
async function composerGuard(page,viewport){
 const input=page.getByRole('textbox',{name:'Agent prompt'});
 assert.equal(await input.count(),1,'required composer missing');assert(await input.isVisible(),'composer visible');
 const box=await input.boundingBox();assert(box&&box.y>=0&&box.y+box.height<=viewport.height,'anchored composer');
 await horizontalChatGuard(page);
 return input;
}
async function loginGuidanceGuard(page,wholeNotice=false,expected=[]){
 const rows=page.locator('[data-chat-entry][data-chat-source="login_required"]');
 assert.equal(await rows.count(),expected.length,'required login card count');
 for(let index=0;index<await rows.count();index++){
  const row=rows.nth(index),notice=row.locator('[data-chat-availability]');
  assert((await row.locator('[data-chat-fact="Request"]').innerText()).includes(expected[index].request),'actual login request identity');
  assert((await row.locator('[data-chat-fact="Provider"]').innerText()).includes(expected[index].provider),'actual login provider identity');
  assert.equal(await notice.count(),1,'required supported login guidance missing');
  assert((await notice.innerText()).includes("Open the matching LOGIN REQUIRED card in Agent Harbor WebUI task details or Inbox, if available. This editor cannot open sign-in. If you cannot access Harbor, ask this editor's operator to open the request."),'required supported login guidance missing');
  assert(await notice.isVisible(),'supported login guidance visible before Details');
  assert.equal(await notice.locator('xpath=ancestor::details').count(),0,'login guidance outside Details');
  if(wholeNotice){
   assert.equal(await row.locator('details').getAttribute('open'),null,'login guidance precedes expansion');
   const inside=await notice.evaluate(el=>{const box=el.getBoundingClientRect(),scroll=el.closest('[data-chat-scroll]').getBoundingClientRect();return box.width>0&&box.height>0&&box.left>=scroll.left&&box.right<=scroll.right&&box.top>=scroll.top&&box.bottom<=scroll.bottom;});
   assert(inside,'whole supported login notice inside conversation bounds');
  }
 }
}
async function isolatedContentGuard(page,type){
 const selector=type==='user_input'?'[data-chat-role="arUser"]':type==='log'?'[data-chat-role="arAssistant"]':`[data-chat-source="${type}"]`;
 const card=page.locator('.editor-chat '+selector);
 assert.equal(await card.count(),1,`isolated ${type} card count`);
 assert(await card.isVisible(),`isolated ${type} visible card`);
 const title=await card.locator(':scope > div').first().locator(':scope > div').first().innerText();
 const text=await card.innerText();
 assert.equal(title,isolatedContent[type][0],`isolated ${type} semantic heading`);
 for(const literal of isolatedContent[type].slice(1))assert(text.includes(literal),`isolated ${type} semantic content missing: ${literal}`);
 assert.equal(await card.locator('details[open]').count(),0,'isolated semantics visible before Details');
 return {type,title,text};
}
async function admitScene(page,events){
 await page.evaluate(()=>window.__chatTest.backend(true));
 await page.getByRole('textbox',{name:'Agent prompt'}).fill('Improve the hero spacing.');
 await page.getByRole('button',{name:'Send agent prompt',exact:true}).click();
 for(const event of events)await page.evaluate(payload=>payload.type?window.__chatTest.harborEvent(JSON.stringify(payload)):window.__chatTest.event(JSON.stringify(payload)),event);
}
async function wrongIsolatedControl(context,url,type,size){
 const wrong=wrongIsolated[type];assert.equal(wrong.type,type,'negative has the SAME public DTO type');
 const page=await context.newPage();
 try{
  await page.goto(url);await page.waitForFunction(()=>window.__chatTest);
  await page.evaluate(panel=>window.__chatTest.width(panel),sizes[size].panel);
  await admitScene(page,[wrong]);
  await page.evaluate(async()=>{await document.fonts.ready;await new Promise(resolve=>requestAnimationFrame(()=>requestAnimationFrame(resolve)));});
  const rendered=await page.locator(`[data-chat-source="${type}"]`).innerText();
  await assert.rejects(()=>isolatedContentGuard(page,type),/semantic (heading|content missing)/,'same rendered semantic guard rejects wrong same-type DTO');
  return {type,size,wrongPayload:wrong,rendered,rejected:true,guard:'isolatedContentGuard before every isolated capture'};
 }finally{await page.close();}
}
// Read only the selected mounted fixture and the sole production reader's output.
// Loaded fonts/two frames alone can precede its first 300ms scan.
function mountedPreviewReady(){
 if(!window.__chatTest || document.readyState!=='complete' || document.fonts.status!=='loaded')return false;
 const frames=Array.from(document.querySelectorAll('iframe[data-page-project-frame="true"]'))
   .filter(frame=>frame.getClientRects().length && frame.offsetParent!==null);
 if(frames.length!==1)return false;
 const doc=frames[0].contentDocument;
 if(!doc || doc.readyState!=='complete' || doc.fonts.status!=='loaded' || doc.title!=='Chat preview' || doc.querySelector('h1')?.textContent!=='Website preview')return false;
 const state=JSON.parse(window.__chatTest.controlState());
 if(state.workspace!=='chat-acceptance' || !['Pages / Home','Pages / Details'].includes(state.storyId))return false;
 return [['primary','Primary action'],['secondary','Secondary action']].every(([id,text])=>{
   const element=doc.querySelector(`[data-isonim-element-id="${id}"]`);
   const row=state.elements.find(row=>row.id===id);
   const published=document.querySelector(`[data-scene-graph-row="${id}"]`);
   return element?.textContent===text && element.getClientRects().length>0 &&
     row?.tag==='button' && row.label.includes(text) && published?.getClientRects().length>0;
 }) && !document.querySelector('[data-scene-graph-empty]');
}
async function captureReady(page){
 const deadline=performance.now()+5000;
 const remaining=()=>{const budget=deadline-performance.now();assert(budget>0,'capture readiness deadline exceeded');return budget;};
 await page.waitForFunction(mountedPreviewReady,null,{timeout:remaining()});
 const frameTimes=await page.evaluate(waitForAdvancingFrames,remaining());
 remaining();
 const readiness=await page.evaluate(frameTimes=>{
   const frame=Array.from(document.querySelectorAll('iframe[data-page-project-frame="true"]')).find(frame=>frame.getClientRects().length && frame.offsetParent!==null);
   return {frameTimes,documentReadyState:document.readyState,fontStatus:document.fonts.status,
     previewReadyState:frame.contentDocument.readyState,previewFontStatus:frame.contentDocument.fonts.status,
     previewTitle:frame.contentDocument.title,previewHeading:frame.contentDocument.querySelector('h1').textContent,
     sceneGraphRows:Array.from(document.querySelectorAll('[data-scene-graph-row]')).map(row=>row.dataset.sceneGraphRow),
     state:JSON.parse(window.__chatTest.controlState())};
 },frameTimes);
 assert(await page.evaluate(mountedPreviewReady),'mounted preview and published scene remain ready after normal frames');
 remaining();
 return readiness;
}
async function controlReady(page,view,size){
 const readiness=await captureReady(page);
 writeFileSync(path.join(output,`control-${view}-${size}-readiness.json`),JSON.stringify(readiness,null,2));
 return readiness;
}
async function previewReadinessControls(page,size){
 const before=await captureReady(page);
 await page.evaluate(()=>{window.__originalControlSnapshot=window.__chatTest.controlState;
   window.__chatTest.controlState=()=>{const state=JSON.parse(window.__originalControlSnapshot());state.elements=[];return JSON.stringify(state);};});
 try{assert.equal(await page.evaluate(mountedPreviewReady),false,'same capture predicate rejects absent published scene rows');}
 finally{await page.evaluate(()=>{window.__chatTest.controlState=window.__originalControlSnapshot;delete window.__originalControlSnapshot;});}
 await captureReady(page);
 const heading=await page.evaluate(()=>{const h=document.querySelector('iframe[data-page-project-frame="true"]').contentDocument.querySelector('h1');const text=h.textContent;h.textContent='Wrong selected preview';return text;});
 try{assert.equal(await page.evaluate(mountedPreviewReady),false,'same capture predicate rejects wrong real preview despite published rows');}
 finally{await page.evaluate(text=>{document.querySelector('iframe[data-page-project-frame="true"]').contentDocument.querySelector('h1').textContent=text;},heading);}
 const restored=await captureReady(page);
 writeFileSync(path.join(output,`preview-readiness-control-${size}.json`),JSON.stringify({size,before,
   absentPublishedRowsRejected:true,wrongActualPreviewRejected:true,restored,
   guard:'mountedPreviewReady used by every capture and controlReady'},null,2));
}
async function controlDiagnostic(page,id,size,phase){
 const actual=JSON.parse(await page.evaluate(id=>window.__chatTest.controlDiagnostics(id),id));
 actual.phase=phase;
 writeFileSync(path.join(output,`control-${id}-${size}-${phase}.json`),JSON.stringify(actual,null,2));
 return actual;
}
async function behavioralScene(page,view,size){
 const input=page.getByRole('textbox',{name:'Agent prompt'});
 const panel=page.locator('.editor-chat');
 const inject=payload=>page.evaluate(value=>window.__chatTest.event(JSON.stringify(value)),payload);
 const state=async()=>JSON.parse(await page.evaluate(()=>window.__chatTest.controlState()));
 const command=payload=>page.evaluate(value=>JSON.parse(window.__chatTest.control(JSON.stringify(value))),payload);
 const settle=async()=>page.evaluate(()=>new Promise(resolve=>requestAnimationFrame(()=>requestAnimationFrame(resolve))));
 await page.evaluate(()=>window.__chatTest.localApprovals(true));
 if(view.startsWith('navigation-')||['focus-auto','selection-highlight-auto','highlight-auto'].includes(view)){
   await input.focus();await settle();
   const approval=page.getByRole('checkbox',{name:'Require approval for agent navigation'});
   if(view!=='navigation-auto'&&view.startsWith('navigation-'))await approval.check();else await approval.uncheck();
   const readiness=await controlReady(page,view,size);
   const initial=await state();
   let request={commandId:view,command:'open-story',storyId:initial.stories.find(row=>row.name==='Details').id};
   if(view==='focus-auto')request={commandId:view,command:'focus',target:'sidebar-search'};
   if(['selection-highlight-auto','highlight-auto'].includes(view)){
     await page.waitForFunction(()=>JSON.parse(window.__chatTest.controlState()).elements.some(row=>row.id==='primary'));
     request={commandId:view,command:view==='highlight-auto'?'highlight':'select',target:view==='highlight-auto'?'secondary':'primary',focus:view!=='highlight-auto',highlight:true};
   }
   const admitted=await command(request);
   const admittedDiagnostic=await controlDiagnostic(page,view,size,'admitted');
   assert.deepEqual(admittedDiagnostic.operation,admitted,'stored actual admission');
   assert.equal(admitted.status,view.startsWith('navigation-')&&view!=='navigation-auto'?'pending':'applied','actual command admission '+JSON.stringify(admittedDiagnostic));
   const beforeClick=await controlDiagnostic(page,view,size,'before-click');
   if(view==='navigation-approved')await page.locator(`[data-editor-control-approve="${view}"]`).click();
   if(view==='navigation-rejected')await page.locator(`[data-editor-control-reject="${view}"]`).click();
   if(view==='navigation-stale'){
      assert.equal((await command({commandId:'human-viewport-change',command:'viewport',viewport:'tablet',expectedRevision:(await state()).revision})).status,'pending');
      await page.locator('[data-editor-control-approve="human-viewport-change"]').click();
      await page.locator(`[data-editor-control-approve="${view}"]`).click();
   }
   const afterClick=await controlDiagnostic(page,view,size,'after-click');
   const expectedStatus=view==='navigation-pending'?'pending':view==='navigation-rejected'?'rejected':view==='navigation-stale'?'failed':'applied';
   const row=panel.locator(`[data-editor-control-operation="${view}"]`);await row.waitFor();
   assert.equal(await row.getAttribute('data-operation-status'),expectedStatus,'rendered shared command result '+JSON.stringify({readiness,admitted,beforeClick,afterClick}));
   assert.equal(await row.locator('button').count(),expectedStatus==='pending'?2:0,'only live approval controls');
   const final=await state();
   if(view.startsWith('navigation-'))assert.equal(final.storyId,initial.stories.find(row=>row.name===(['navigation-approved','navigation-auto'].includes(view)?'Details':'Home')).id,'actual selected story');
   // Real rendered destinations/actions/errors, in addition to retained VM facts.
   const navigationEvidence={};
   if(['navigation-approved','navigation-auto'].includes(view)) {
     const selected=page.locator('[data-story-row="Pages/Details"]');
     const destinationEvidence=async()=>selected.evaluate(el=>{
       const box=el.getBoundingClientRect(),clip=el.closest('[data-editor-sidebar]').getBoundingClientRect();
       return {selected:el.getAttribute('aria-current')==='true',inside:box.width>0&&box.height>0&&box.left>=clip.left&&box.right<=clip.right&&box.top>=clip.top&&box.bottom<=clip.bottom};
     });
     const requireDestination=evidence=>assert(evidence.selected&&evidence.inside,'selected destination visible within actual sidebar clip');
     const before=await destinationEvidence();requireDestination(before);
     const node=await selected.elementHandle(),original=await node.getAttribute('style');let hidden;
     try {
       await node.evaluate(el=>el.style.setProperty('display','none','important'));
       hidden=await destinationEvidence();assert.throws(()=>requireDestination(hidden),/selected destination visible/);
     } finally {
       await node.evaluate((el,style)=>{if(style===null)el.removeAttribute('style');else el.setAttribute('style',style);},original);await node.dispose();
     }
     const restored=await destinationEvidence();requireDestination(restored);
     navigationEvidence.destination={before,hidden,restored,missingSelectedRowRejected:true};
   }
   if(view==='navigation-pending') {
     const actions=row.locator(`[data-editor-control-actions="${view}"]`);
     const boxes=await actions.evaluate(el=>{
       const bounds=el.getBoundingClientRect();return [...el.querySelectorAll('button')].map(button=>{
         const box=button.getBoundingClientRect(),css=getComputedStyle(button);return {width:box.width,height:box.height,top:box.top,inside:box.left>=bounds.left&&box.right<=bounds.right,fontSize:css.fontSize,background:css.backgroundColor};
       });
     });
     assert.equal(boxes.length,2);assert.equal(boxes[0].top,boxes[1].top);
     for(const box of boxes){assert(box.width>=60&&box.height>=32&&box.inside,JSON.stringify(boxes));assert.equal(box.fontSize,'12px');assert.notEqual(box.background,'rgb(239, 239, 239)');}
     navigationEvidence.actions=boxes;
   }
   if(view==='navigation-stale') {
     assert.equal(afterClick.operation.error,'revision_conflict');
     const reason=row.locator('[data-editor-control-failure="revision_conflict"]');
     assert.equal(await reason.innerText(),'The editor changed after this request. Ask the agent to make a fresh request.');
     assert(await reason.isVisible());navigationEvidence.failure={error:afterClick.operation.error,text:await reason.innerText()};
   }
   if(view.startsWith('navigation-'))writeFileSync(path.join(output,`navigation-outcomes-${view}-${size}.json`),JSON.stringify(navigationEvidence,null,2));

   if(view==='focus-auto'){
     const before=requireSidebarSearchFocus(await page.evaluate(sidebarSearchFocusEvidence));
     const field=await page.locator('[data-sidebar-search-field="true"]').elementHandle();
     const original=await field.getAttribute('style');let rejected;
     try{
       await field.evaluate(el=>el.style.setProperty('outline','none','important'));
       rejected=await page.evaluate(sidebarSearchFocusEvidence);
       assert.throws(()=>requireSidebarSearchFocus(rejected),/visible sidebar search focus ring/,'same focus guard rejects missing real ring despite activeElement');
     }finally{
       await field.evaluate((el,value)=>{if(value===null)el.removeAttribute('style');else el.setAttribute('style',value);},original);
       await field.dispose();
     }
     const restored=requireSidebarSearchFocus(await page.evaluate(sidebarSearchFocusEvidence));
     writeFileSync(path.join(output,`sidebar-focus-control-${size}.json`),JSON.stringify({before,rejected,restored,missingRingRejected:true},null,2));
   }
   if(['selection-highlight-auto','highlight-auto'].includes(view)){
      // The shell retains hidden preview documents. Identify the visible production
      // page iframe first, then use its associated frame, never frame URL order.
      const preview=page.locator('iframe[data-page-project-frame="true"]:visible');
      assert.equal(await preview.count(),1,'one visible mounted page preview');
      const previewElement=await preview.elementHandle();
      const frame=await previewElement.contentFrame();assert(frame,'actual visible preview document');
      const target=frame.locator(`[data-isonim-element-id="${request.target}"]`);
      assert.equal(await target.getAttribute('data-editor-agent-highlight'),'true','actual preview highlight');
      if(view==='selection-highlight-auto'){
        assert(await target.evaluate(el=>el.ownerDocument.activeElement===el),'actual preview element focus');
        assert.equal(final.selection,'primary','actual selection');
      }else assert.equal(final.selection,initial.selection,'highlight preserves selection');
   }
   return {admission:admitted.status,status:expectedStatus,selectedStory:final.storyId,focus:final.focus,selectedElement:final.selection,highlight:final.highlight};
 }
 await page.evaluate(value=>window.__chatTest.backend(value),view!=='chat-send-failed');
 const send=async(text)=>{await input.fill(text);await page.getByRole('button',{name:'Send agent prompt',exact:true}).click();};
 if(view==='chat-send-failed'){
   await send('Retry this website request.');assert.equal(await input.inputValue(),'Retry this website request.');
   assert.equal(await panel.getByRole('button',{name:'Insert suggested prompt'}).count(),0);return {draftPreserved:true,suggestionsDismissed:true};
 }
 await send('Improve the hero spacing.');
 assert.equal(await panel.locator('[data-chat-role="arUser"]').count(),1);
 assert.equal(await panel.getByRole('button',{name:'Insert suggested prompt'}).count(),0);
 if(view==='chat-first-send')return {actualUserCount:1,suggestionsDismissed:true};
 if(view.startsWith('chat-independent-')){
   await inject({kind:'message_chunk',text:'First conversation website update.'});
   await input.fill('First conversation draft.');
   const second=await page.evaluate(()=>window.__chatTest.newChat());await input.fill('Second conversation draft.');
   if(view==='chat-independent-first'){
     await page.evaluate(()=>window.__chatTest.switchChat('chat-1'));
     assert.equal(await input.inputValue(),'First conversation draft.');assert.equal(await panel.locator('[data-chat-role="arUser"]').count(),1);
     assert.equal(await panel.getByRole('button',{name:'Insert suggested prompt'}).count(),0);
   }else{
     assert.equal(await input.inputValue(),'Second conversation draft.');assert.equal(await panel.locator('[data-chat-entry]').count(),0);
     assert(await panel.getByRole('button',{name:'Insert suggested prompt'}).first().isVisible());
   }
   return {active:(JSON.parse(await page.evaluate(()=>window.__chatTest.state()))).active,second,draftsRetained:true};
 }
 await page.evaluate(()=>window.__chatTest.busy(true));await input.fill('Next website change.');
 if(view.startsWith('chat-scroll-')){
   for(let index=0;index<26;index++){
      await inject({kind:'message_chunk',text:`# History ${index}\nWebsite activity ${index}.`});await inject({kind:'completed',stopReason:'end_turn'});
   }
   const scroll=panel.locator('[data-chat-scroll]');await scroll.evaluate(el=>{el.scrollTop=0;el.dispatchEvent(new Event('scroll'));});await settle();
   const before=await scroll.evaluate(el=>el.scrollTop);
   await inject({kind:'message_chunk',text:'# Newest website activity\nPreview compilation finished.'});await settle();
   assert.equal(await scroll.evaluate(el=>el.scrollTop),before,'scrollback retained');
   await panel.locator('[data-chat-latest]').waitFor({state:'visible'});
   if(view==='chat-scroll-latest'){
      await panel.locator('[data-chat-latest]').click();await settle();
      assert.equal(await panel.locator('[data-chat-latest]').isVisible(),false);
      assert(await panel.getByText('Newest website activity',{exact:true}).isVisible());
      assert(await scroll.evaluate(el=>el.scrollTop+el.clientHeight>=el.scrollHeight-2),'latest scroll position');
   }
   assert.equal(await input.inputValue(),'Next website change.');return {scrollbackRetained:true,latest:view==='chat-scroll-latest',draftRetained:true};
 }
 await inject({kind:'message_chunk',text:'# Website update\nThe hero remains spacious.'});
 if(view==='chat-selection-streaming'){
   const heading=panel.locator('[data-chat-markdown="heading"]');
   await heading.evaluate(el=>{const range=document.createRange();range.selectNodeContents(el);const selection=window.getSelection();selection.removeAllRanges();selection.addRange(range);});
   const selected=await page.evaluate(()=>getSelection().toString());assert.equal(selected,'Website update');
   await inject({kind:'message_chunk',text:'\nStreaming continuation preserves the selected text.'});assert.equal(await page.evaluate(()=>getSelection().toString()),selected);
   return {selectedText:selected,selectionRetained:true};
 }
 assert.equal(await page.getByRole('button',{name:'Send agent prompt',exact:true}).isDisabled(),true);
 assert.equal(await input.inputValue(),'Next website change.');return {draftRetained:true,busySendDisabled:true};
}
const root=path.resolve(path.dirname(new URL(import.meta.url).pathname),'../build/editor-chat');
const server=createServer((req,res)=>{
 const target=path.resolve(root,'.'+decodeURIComponent(req.url.split('?')[0]==='/'?'/index.html':req.url.split('?')[0]));
 if(!target.startsWith(root+path.sep)||!existsSync(target)){res.writeHead(404);res.end();return;}
 res.setHeader('Content-Type',target.endsWith('.js')?'application/javascript':target.endsWith('.css')?'text/css':'text/html');res.end(readFileSync(target));
});await new Promise(resolve=>server.listen(0,'127.0.0.1',resolve));
// Both views use the same five original DTOs and production cards. The original
// follows the latest activity; its top companion exposes the first recovery card.
const recoveryTypes=['proxy_credential_rotated','proxy_rate_limit_absorbed','dispatcher_restarted','anti_halting_resume_confirmed','session_leadership_migrated'];
const recoveryVisible={
 'recovery-top':[['proxy_credential_rotated','Provider access recovered'],['proxy_credential_rotated','anthropic'],['proxy_credential_rotated','401'],['proxy_rate_limit_absorbed','Provider throttling recovered'],['proxy_rate_limit_absorbed','2'],['proxy_rate_limit_absorbed','1200']],
 recovery:[['dispatcher_restarted','Agent restarted'],['dispatcher_restarted','2'],['anti_halting_resume_confirmed','Agent progress resumed'],['anti_halting_resume_confirmed','idle'],['session_leadership_migrated','Session moved to another executor'],['session_leadership_migrated','authoring-host'],['session_leadership_migrated','preview-host'],['session_leadership_migrated','linux'],['session_leadership_migrated','40']]
};
async function companionViewport(scroll){
 return scroll.evaluate(el=>{const b=el.getBoundingClientRect();return {top:b.top,bottom:b.bottom,left:b.left,right:b.right};});
}
async function companionVisible(node,viewport,label){
 assert.equal(await node.count(),1,`required companion text missing ${label}`);
 const box=await node.evaluate(el=>{const b=el.getBoundingClientRect();return {top:b.top,bottom:b.bottom,left:b.left,right:b.right,width:b.width,height:b.height};});
 assert(box.width>0&&box.height>0&&box.top>=viewport.top-1&&box.bottom<=viewport.bottom+1&&box.left>=viewport.left-1&&box.right<=viewport.right+1,`required companion text outside visible frame ${label}`);
 return box;
}
async function companionPosition(scroll,top){
 const position=await scroll.evaluate(el=>({scrollTop:el.scrollTop,scrollHeight:el.scrollHeight,clientHeight:el.clientHeight}));
 if(top)assert.equal(position.scrollTop,0,'top companion real scroll position');
 else assert(position.scrollTop+position.clientHeight>=position.scrollHeight-2,'original latest companion scroll position');
 return position;
}
async function recoveryContentGuard(page,view){
 const scroll=page.locator('[data-chat-scroll]');
 const cards=scroll.locator('[data-chat-entry][data-chat-role="arActivity"][data-chat-source]');
 const sources=await cards.evaluateAll(nodes=>nodes.map(node=>node.getAttribute('data-chat-source')));
 assert.deepEqual(sources,recoveryTypes,'same original five recovery cards');
 const texts=[];
 for(const source of recoveryTypes){
  const card=scroll.locator(`[data-chat-source="${source}"]`);
  const text=await card.innerText();
  for(const literal of isolatedContent[source])assert(text.includes(literal),`required recovery semantics missing ${source}: ${literal}`);
  texts.push({source,text});
 }
 const viewport=await companionViewport(scroll);
 const visible=[];
 for(const [source,text] of recoveryVisible[view]){
  const node=scroll.locator(`[data-chat-source="${source}"]`).getByText(text,{exact:true});
  const box=await companionVisible(node,viewport,`${source}: ${text}`);
  visible.push({source,text,box});
 }
 const position=await companionPosition(scroll,view==='recovery-top');
 return {parent:'recovery',companion:'recovery-top',position:view==='recovery-top'?'top':'bottom',...position,viewport,cards:texts,visible};
}
// Independent literals establish the same original log/tool cards at either
// normal scroll position. The full long identifier must fit visibly and wrap.
const longIdentifier='responsiveHeroWithSharedSpacingAndAccessiblePrimaryAction'.repeat(6);
const longProse='Long source identifiers remain readable: '+longIdentifier;
const longFinalLine='setStyle(hero, "padding", "32px") # line 11';
async function longContentGuard(page,view){
 const scroll=page.locator('[data-chat-scroll]');
 const assistant=scroll.locator('[data-chat-entry][data-chat-role="arAssistant"]');
 const tool=scroll.locator('[data-chat-entry][data-chat-role="arActivity"][data-chat-source="tool_use"]');
 assert.equal(await assistant.count(),1,'same original long-content assistant card');
 assert.equal(await tool.count(),1,'same original long-content tool card');
 const cards=[{source:'log',text:await assistant.innerText()},{source:'tool_use',text:await tool.innerText()}];
 for(const literal of ['Assistant',longProse,longFinalLine])assert(cards[0].text.includes(literal),`required long-content semantics missing: ${literal}`);
 for(const literal of ['isonim inspect','started'])assert(cards[1].text.includes(literal),`required long-content semantics missing: ${literal}`);
 const viewport=await companionViewport(scroll),visible=[];
 const top=view==='long-content-top';
 const nodes=top?[[assistant.getByText('Assistant',{exact:true}),'log','Assistant'],[assistant.getByText(longProse,{exact:true}),'log',longProse]]:[[tool.getByText('isonim inspect',{exact:true}),'tool_use','isonim inspect'],[tool.getByText('started',{exact:true}),'tool_use','started']];
 for(const [node,source,text] of nodes)visible.push({source,text,box:await companionVisible(node,viewport,text)});
 let identifierLines=null;
 if(top){
  identifierLines=await assistant.getByText(longProse,{exact:true}).evaluate((el,identifier)=>{
   const walker=document.createTreeWalker(el,NodeFilter.SHOW_TEXT);let node;while(node=walker.nextNode()){
    const offset=node.textContent.indexOf(identifier);if(offset<0)continue;
    const range=document.createRange();range.setStart(node,offset);range.setEnd(node,offset+identifier.length);
    return [...range.getClientRects()].map(b=>({top:b.top,bottom:b.bottom,left:b.left,right:b.right,width:b.width,height:b.height}));
   }return [];
  },longIdentifier);
  assert(identifierLines.length>1,'actual long identifier wraps across multiple lines');
  assert(identifierLines.every(b=>b.width>0&&b.height>0&&b.top>=viewport.top-1&&b.bottom<=viewport.bottom+1&&b.left>=viewport.left-1&&b.right<=viewport.right+1),'entire wrapped identifier visibly inside conversation');
 }else{
  const code=assistant.locator('[data-chat-markdown="code"]');
  const box=await code.evaluate((el,line)=>{const node=el.firstChild;const offset=node.textContent.indexOf(line);if(offset<0)return null;const range=document.createRange();range.setStart(node,offset);range.setEnd(node,offset+line.length);const b=range.getBoundingClientRect();return {top:b.top,bottom:b.bottom,left:b.left,right:b.right,width:b.width,height:b.height};},longFinalLine);
  assert(box&&box.width>0&&box.height>0&&box.top>=viewport.top-1&&box.bottom<=viewport.bottom+1&&box.left>=viewport.left-1&&box.right<=viewport.right+1,'original final code line inside visible conversation');
  visible.push({source:'log',text:longFinalLine,box});
 }
 return {parent:'long-content',companion:'long-content-top',position:top?'top':'bottom',...await companionPosition(scroll,top),viewport,cards,visible,identifierLines};
}
async function longContentNegativeControl(page,view,size){
 const scroll=page.locator('[data-chat-scroll]');
 const targets=view==='long-content-top'?['Assistant',longProse]:['isonim inspect'];
 const controls=[];
 for(const text of targets){
  const node=scroll.getByText(text,{exact:true}),handle=await node.elementHandle();assert(handle,'actual required long-content node');const original=await handle.textContent();
  try{await handle.evaluate(el=>{el.textContent='Missing required long-content';});await assert.rejects(()=>longContentGuard(page,view),/required long-content semantics missing/,'same guard rejects actual missing content');}
  finally{try{await handle.evaluate((el,text)=>{el.textContent=text;},original);}finally{await handle.dispose();}}
  controls.push({text,rejected:true});
 }
 const restored=await longContentGuard(page,view);
 writeFileSync(path.join(output,`long-content-control-${view}-${size}.json`),JSON.stringify({view,size,controls,restored,guard:'longContentGuard before both long-content captures'},null,2));
}
async function recoveryNegativeControl(page,view,size){
 const [source,text]=recoveryVisible[view][0];
 const node=page.locator(`[data-chat-source="${source}"]`).getByText(text,{exact:true});
 const handle=await node.elementHandle();assert(handle,'actual required heading node');
 const original=await handle.textContent();
 try{
  await handle.evaluate(el=>{el.textContent='Wrong recovery heading';});
  await assert.rejects(()=>recoveryContentGuard(page,view),/required recovery semantics missing/,'same recovery guard rejects genuinely missing required heading');
 }finally{try{await handle.evaluate((el,text)=>{el.textContent=text;},original);}finally{await handle.dispose();}}
 const restored=await recoveryContentGuard(page,view);
 writeFileSync(path.join(output,`recovery-heading-control-${view}-${size}.json`),JSON.stringify({view,size,source,heading:text,missingHeadingRejected:true,restored,guard:'recoveryContentGuard before both recovery captures'},null,2));
}

let browser;const manifest=[];
try{
 browser=await chromium.launch({headless:true,executablePath:'/ms-playwright/chromium-1217/chrome-linux64/chrome',args:flags});
 for(const view of views)for(const size of sizeFilter?[sizeFilter]:Object.keys(sizes)){
  const viewport=sizes[size];const context=await browser.newContext({viewport:{width:viewport.width,height:viewport.height},...environment});
  const page=await context.newPage();const errors=[];page.on('pageerror',error=>errors.push(error.message));
  await page.goto(`http://127.0.0.1:${server.address().port}/`);await page.waitForFunction(()=>window.__chatTest);
  // Capture discrete focus states, not the wall-clock phase of focus transitions.
  // No content, state, selection, outlines or controls are hidden.
  await page.addStyleTag({content:'*,*::before,*::after { transition-duration: 0s !important; animation-duration: 0s !important; }'});
  await page.evaluate(panel=>window.__chatTest.width(panel),viewport.panel);
  let behaviorEvidence=null;
  if(corpus.behaviorScenes[view])behaviorEvidence=await behavioralScene(page,view,size);
  else if(view!=='empty'){
   await admitScene(page,sceneEvents[view]);
  }
  await captureReady(page);
  if(view==='empty'&&!canary)await previewReadinessControls(page,size);
  const panel=page.locator('.editor-chat');await panel.waitFor({state:'visible'});
  const input=await composerGuard(page,viewport);
  const expectedLogins=(sceneEvents[view]??[]).filter(event=>event.type==='login_required');
  await loginGuidanceGuard(page,['login','event-login_required'].includes(view),expectedLogins);
  if(view==='login'){
   const notice=page.locator('[data-chat-entry][data-chat-source="login_required"] [data-chat-availability]');
   const original=await notice.textContent();await notice.evaluate(el=>{el.textContent='This editor cannot answer this request.';});
   await assert.rejects(()=>loginGuidanceGuard(page,true,expectedLogins),/required supported login guidance missing/,'same semantic guard rejects absent supported recovery');
   await notice.evaluate((el,text)=>{el.textContent=text;},original);await loginGuidanceGuard(page,true,expectedLogins);
   await page.evaluate(()=>{const node=document.querySelector('[data-chat-entry][data-chat-source="login_required"]');window.__loginCardControl={node,parent:node.parentNode,next:node.nextSibling};node.remove();});
   await assert.rejects(()=>loginGuidanceGuard(page,true,expectedLogins),/required login card count/,'same semantic guard rejects missing login card');
   await page.evaluate(()=>{const {node,parent,next}=window.__loginCardControl;parent.insertBefore(node,next);delete window.__loginCardControl;});
   await loginGuidanceGuard(page,true,expectedLogins);
   writeFileSync(path.join(output,`login-guidance-control-${size}.json`),JSON.stringify({missingGuidanceRejected:true,missingLoginCardRejected:true,restored:true,guard:'loginGuidanceGuard used before every capture'},null,2));
  }

  if(view==='empty'&&size==='narrow'){
   const restored=await oldClippedChatControl(page);
   writeFileSync(path.join(output,'horizontal-clipping-control.json'),JSON.stringify({oldClippedStateRejected:true,guard:'horizontalChatGuard used by every composerGuard',restored},null,2));
  }
  const layout=await panel.evaluate(el=>{
   const box=el.getBoundingClientRect();const composer=el.querySelector('textarea').getBoundingClientRect();
   const overflow=[...el.querySelectorAll('[data-chat-entry], [data-chat-facts], [data-chat-markdown]')].filter(node=>node.scrollWidth>node.clientWidth+1).map(node=>node.getAttribute('data-chat-entry')||node.getAttribute('data-chat-markdown'));
   return {width:box.width,composer:{top:composer.top,bottom:composer.bottom,left:composer.left,right:composer.right},overflow,visibleEntries:[...el.querySelectorAll('[data-chat-entry]')].length};
  });
  assert.equal(layout.overflow.length,0,`horizontal overflow ${view}/${size}: ${layout.overflow}`);
  assert(layout.composer.bottom<=viewport.height&&layout.composer.top>=0,'anchored composer');
  assert.equal(errors.length,0,`browser exceptions ${errors}`);
  const geometry=await page.evaluate(()=>{
    const iframe=[...document.querySelectorAll('iframe')].find(el=>el.getBoundingClientRect().width>0);
    return {pageOverflow:document.documentElement.scrollWidth>innerWidth,previewWidth:iframe?.getBoundingClientRect().width||0};
  });
  assert.equal(geometry.pageOverflow,false,'no horizontal page overflow');
  assert(geometry.previewWidth>300,'website preview retains usable working space');
  const contrast=await panel.evaluate(el=>{
    const rgb=value=>{const match=value.match(/rgba?\(([^)]+)\)/);return match?match[1].split(',').map(Number):null;};
    const luminance=color=>{const values=color.slice(0,3).map(value=>{const x=value/255;return x<=0.04045?x/12.92:((x+0.055)/1.055)**2.4;});return values[0]*.2126+values[1]*.7152+values[2]*.0722;};
    const rows=[];
    for(const node of el.querySelectorAll('[data-chat-entry] *')){
      if(![...node.childNodes].some(child=>child.nodeType===3&&child.textContent.trim())||!node.getClientRects().length)continue;
      let bg=node,background=null;
      while(bg){const value=rgb(getComputedStyle(bg).backgroundColor);if(value&&(value.length<4||value[3]===1)){background=value;break;}bg=bg.parentElement;}
      const foreground=rgb(getComputedStyle(node).color);if(!foreground||!background)continue;
      const a=luminance(foreground),b=luminance(background);rows.push({text:node.textContent.slice(0,60),ratio:(Math.max(a,b)+.05)/(Math.min(a,b)+.05)});
    }
    return rows;
  });
  assert(contrast.every(row=>row.ratio>=4.5),`chat text contrast ${JSON.stringify(contrast.filter(row=>row.ratio<4.5))}`);
  assert(!await panel.innerText().then(text=>text.includes('PRIVATE_CAMPAIGN_SECRET')),'credentials excluded');
  if(view==='plan')assert.equal(await panel.locator('[data-chat-surface="plan"] [data-chat-fact]').count(),3);
  if(view==='model-context')assert(await panel.getByText('1260',{exact:true}).isVisible(),'actual token usage');
  if(view==='question')assert(await panel.getByText('Which hero spacing should I use?',{exact:true}).isVisible(),'question shown');
  if(view==='files')assert(await panel.getByText('Before',{exact:true}).isVisible(),'visible before/after diff');
  // Keyboard reachability uses the actual composer and native focus styling.
  await page.mouse.move(0,0);
  const preserveFocus=['focus-auto','selection-highlight-auto','chat-selection-streaming'].includes(view);
  if(!preserveFocus){await input.focus();assert(await input.evaluate(el=>document.activeElement===el),'composer keyboard focus');}
  await page.evaluate(()=>new Promise(resolve=>requestAnimationFrame(()=>requestAnimationFrame(resolve))));
  if(view.startsWith('event-')){
    const bottom=view==='event-log-bottom';
    const type=bottom?'log':view.slice(6);
    // The long log has a separately verified bottom companion; its heading and
    // initial prose are intentionally checked only in the top frame.
    if(!bottom){
      const accepted=await isolatedContentGuard(page,type);
      if(wrongIsolated[type]){
        const rejected=await wrongIsolatedControl(context,`http://127.0.0.1:${server.address().port}/`,type,size);
        writeFileSync(path.join(output,`isolated-semantic-control-${type}-${size}.json`),JSON.stringify({...rejected,accepted},null,2));
      }
    }
    await panel.locator('[data-chat-scroll]').evaluate((el,bottom)=>{el.scrollTop=bottom?el.scrollHeight:0;},bottom);
    await page.evaluate(()=>new Promise(resolve=>requestAnimationFrame(()=>requestAnimationFrame(resolve))));
    const source=bottom?'log':view.slice(6);
    if(source==='user_input')assert.equal(await panel.locator('[data-chat-role="arUser"]').count(),1,'typed acknowledgement coalesces into local human message');
    else if(source==='log')assert(await panel.locator('[data-chat-role="arAssistant"]').isVisible(),'assistant content shown');
    else await panel.locator(`[data-chat-source="${source}"]`).waitFor({state:'visible'});
    const visibleContent=await panel.locator('[data-chat-scroll]').evaluate((el,bottom)=>{
      const viewport=el.getBoundingClientRect();
      const cards=[...el.querySelectorAll('[data-chat-entry]')];
      const card=cards.at(-1);const box=card.getBoundingClientRect();
      return {viewport:{top:viewport.top,bottom:viewport.bottom},card:{top:box.top,bottom:box.bottom},bottom};
    },bottom);
    if(bottom){
      assert(visibleContent.card.bottom<=visibleContent.viewport.bottom+1,'bottom companion shows final content');
      const code=panel.locator('[data-chat-role="arAssistant"] [data-chat-markdown="code"]');
      assert((await code.innerText()).endsWith('setStyle(hero, "padding", "32px") # line 11'),'independent bottom companion final Nim line');
      const finalLineVisible=await code.evaluate(el=>{
        const text=el.firstChild,range=document.createRange();range.setStart(text,text.textContent.lastIndexOf('setStyle'));range.setEnd(text,text.textContent.length);
        const box=range.getBoundingClientRect(),scroll=el.closest('[data-chat-scroll]').getBoundingClientRect();
        return box.width>0&&box.height>0&&box.top>=scroll.top&&box.bottom<=scroll.bottom;
      });
      assert(finalLineVisible,'bottom companion final Nim line inside visible conversation');
    }
    else assert(visibleContent.card.top>=visibleContent.viewport.top-1&&visibleContent.card.top<visibleContent.viewport.bottom-20,'event card heading inside actual visible frame');
  }
  let recoveryEvidence=null;
  if(view==='recovery'||view==='recovery-top'){
    await panel.locator('[data-chat-scroll]').evaluate((el,top)=>{el.scrollTop=top?0:el.scrollHeight;el.dispatchEvent(new Event('scroll'));},view==='recovery-top');
    await captureReady(page);
    recoveryEvidence=await recoveryContentGuard(page,view);
    await recoveryNegativeControl(page,view,size);
  }
  let longContentEvidence=null;
  if(view==='long-content'||view==='long-content-top'){
    await panel.locator('[data-chat-scroll]').evaluate((el,top)=>{el.scrollTop=top?0:el.scrollHeight;el.dispatchEvent(new Event('scroll'));},view==='long-content-top');
    await captureReady(page);
    longContentEvidence=await longContentGuard(page,view);
    await longContentNegativeControl(page,view,size);
  }
  if(view==='files'){
    const before=panel.locator('[data-chat-fact="Before"]');assert.equal(await before.locator('span').last().innerText(),sceneEvents[view].find(event=>event.type==='diff').oldText,'diff line boundaries preserved');
    assert.equal(await before.locator('span').last().evaluate(el=>getComputedStyle(el).whiteSpace),'pre-wrap');
  }
  if(view==='question'||view.startsWith('question-')){
    const question=panel.locator('[data-chat-source="agent_question"]');
    assert.equal(await question.locator('[data-chat-availability]').innerText(),'This editor cannot answer this request.');
    assert(await question.locator('[data-chat-availability]').isVisible());
    assert.equal(await question.locator('details').getAttribute('open'),null,'availability precedes expansion');
    assert.equal(await question.locator('button,input,textarea,select').count(),0,'unavailable answers have no fake controls');
  }
  const sidebarFocusPaint=view==='focus-auto'?requireSidebarSearchFocus(await page.evaluate(sidebarSearchFocusEvidence)):null;
  const focusPaint=await input.evaluate(el=>{const s=getComputedStyle(el);return {border:s.borderColor,outline:s.outline,animation:s.animation,transition:s.transition,active:document.activeElement===el,animations:document.getAnimations().map(a=>({state:a.playState,time:a.currentTime}))};});
  const target=canary?page.locator('[data-chat-scroll]'):page;
  if(canary){
    if(view==='conversation'){
      await panel.getByText('Hero refreshed',{exact:true}).waitFor({state:'visible'});
      await panel.locator('[data-chat-markdown="code"]').waitFor({state:'visible'});
    } else {
      for(const label of ['completed','in progress','pending'])await panel.getByText(label,{exact:true}).waitFor({state:'visible'});
    }
  }
  const sceneReadiness=await captureReady(page);
  const file=`${view}-${size}.png`;const png=await target.screenshot({path:path.join(output,file),animations:'disabled',caret:'hide'});
  let positiveControl=null;
  if(canary){
    const payload=view==='conversation'?{type:'log',level:'info',message:'CANARY POSITIVE CONTROL: changed actual assistant content.',timestamp:1700000000,eventId:'canary-negative'}:{type:'plan',entries:[{content:'CANARY POSITIVE CONTROL: changed actual plan layout.',priority:'high',status:'failed'}],is_update:true,timestamp:1700000000,eventId:'canary-negative'};
    await page.evaluate(payload=>window.__chatTest.harborEvent(JSON.stringify(payload)),payload);
    await page.evaluate(()=>new Promise(resolve=>requestAnimationFrame(()=>requestAnimationFrame(resolve))));
    const changed=await target.screenshot({path:path.join(output,`${view}-${size}-positive-control.png`),animations:'disabled',caret:'hide'});
    assert(!changed.equals(png),'exact image gate must reject changed actual prose/plan');
    positiveControl={changedSha256:hash(changed),mutation:'actual production event alters conversation/plan'};
  }
  manifest.push({view,size,file,sceneReadiness,recoveryEvidence,longContentEvidence,behaviorEvidence,positiveControl,contentVerified:canary,dimensions:[png.readUInt32BE(16),png.readUInt32BE(20)],scope:canary?'actual production conversation scroll surface; excludes editor chrome, preview and composer':'full editor viewport',sha256:createHash('sha256').update(png).digest('hex'),layout,geometry,contrast,focusPaint,sidebarFocusPaint,boundary:corpus.boundary,events:(sceneEvents[view]||[]).map(e=>e.type||e.kind),baseline:'candidate; human acceptance pending',perceptualThreshold:{maximumChangedPixelRatio:thresholds[view]},browser:browser.version()});
  if(args.includes('--missing-element-control')&&view==='empty'&&size==='wide'){
    await input.evaluate(el=>el.remove());
    await assert.rejects(()=>composerGuard(page,viewport),/required composer missing/,'same positive composer guard rejects removed composer');
    await page.screenshot({path:path.join(output,'positive-control-missing-composer.png'),animations:'disabled',caret:'hide'});
    writeFileSync(path.join(output,'missing-element-control.json'),JSON.stringify({view:'empty',size:'wide',requiredElement:'Agent prompt composer',domGateRejected:true,guard:'composerGuard used by every normal capture',independentVisualReviewerDetection:'pending'},null,2)+'\n');
  }
  await context.close();process.stdout.write(`PASS ${view}/${size}\n`);
 }
 const replaced=new Set(manifest.map(row=>row.view+'/'+row.size));
 const merged=[...(previous?.views||[]).filter(row=>!replaced.has(row.view+'/'+row.size)),...manifest].sort((a,b)=>(a.view+'/'+a.size).localeCompare(b.view+'/'+b.size));
 writeFileSync(path.join(output,'manifest.json'),JSON.stringify({schema:2,lineage,container:'mcr.microsoft.com/playwright@sha256:eac9b0a5312cdab40ee8c2429df5bf19bffdccf8f3bf3c42268e173f97541645',flags,environment,sizes,browser:browser.version(),node:process.version,views:merged},null,2)+'\n');
}finally{if(browser)await browser.close();await new Promise(resolve=>server.close(resolve));}
