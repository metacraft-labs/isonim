/** Default native-inspector composition (catalog-only preview mode is exercised
 * separately by popup acceptance). Real mounted production inspector, native authenticated source worker, private
 * files and actual Nim compiler/SSR catalog. No UI, source, compiler, HTTP or
 * dispatcher is mocked. The configured controlled decision peer only permits
 * daemon startup; this suite sends no model prompts and asserts zero agent calls.
 * The source fixture's compile-time constraint is a real negative compiler control.
 */
import {spawn,spawnSync} from 'node:child_process';
import {mkdtempSync,cpSync,readFileSync,writeFileSync,mkdirSync,openSync,copyFileSync} from 'node:fs';
import {chromium} from '../node_modules/playwright/index.mjs';
import assert from 'node:assert/strict';
import path from 'node:path';
import {tmpdir} from 'node:os';
import {fileURLToPath} from 'node:url';
import {createHash} from 'node:crypto';
const repo=path.resolve(path.dirname(fileURLToPath(import.meta.url)),'..');
const root=mkdtempSync(path.join(process.env.ISONIM_POPUP_ARTIFACTS||tmpdir(),'inspector-compounds-'));
const project=root+'/project',pub=root+'/public';
cpSync(repo+'/tests/fixtures/editor_inspector_project',project,{recursive:true});mkdirSync(pub);
// Opt in the real disposable fixture's already-supported literal display,
// direction and opacity owners. This changes no production/native capability.
const setupSource=readFileSync(project+'/stories.nim','utf8');assert(setupSource.includes('#action { width:120px;'));
writeFileSync(project+'/stories.nim',setupSource.replace('#action { width:120px;','#action { display:inline-flex; flex-direction:row; opacity:80%; width:120px;'));
const setupManifest=JSON.parse(readFileSync(project+'/.isonim/source-project.json','utf8'));
setupManifest.editableStyles.find(row=>row.elementId==='action').properties.push('display','flex-direction','opacity');
writeFileSync(project+'/.isonim/source-project.json',JSON.stringify(setupManifest));

for(const [from,to] of [['src/isonim/editor/index.html','index.html'],['build/editor-inspector/editor.js','editor.js'],['node_modules/fabric/dist/index.min.js','fabric.min.js'],['node_modules/paper/dist/paper-core.min.js','paper-core.min.js'],['node_modules/svgo/dist/svgo.browser.js','svgo.browser.js']])copyFileSync(repo+'/'+from,pub+'/'+to);
const build=spawnSync('python3',[repo+'/tools/build_source_catalog.py',project],{env:{...process.env,ISONIM_SOURCE_FRAMEWORK:repo},encoding:'utf8',timeout:70000});
writeFileSync(root+'/catalog-build.log',build.stdout+build.stderr);assert.equal(build.status,0,build.stdout+build.stderr);
const proof={project,head:process.env.ISONIM_TEST_HEAD||spawnSync('git',['rev-parse','HEAD'],{cwd:repo,encoding:'utf8'}).stdout.trim(),sourceState:process.env.ISONIM_TEST_SOURCE_STATE||'C4a authored working copy',nativeSha256:createHash('sha256').update(readFileSync(repo+'/build/bin/isonim-review')).digest('hex'),bundleSha256:createHash('sha256').update(readFileSync(pub+'/editor.js')).digest('hex'),cases:[],errors:[],agentRequests:[],sourceRequests:[],httpTimings:[],previewTimings:[]};
const record=name=>{proof.cases.push(name);writeFileSync(root+'/proof-partial.json',JSON.stringify(proof,null,2));};
const config=root+'/agent.toml';writeFileSync(config,'[agent]\nbackend="custom"\ncommand="python3"\nargs='+JSON.stringify([repo+'/tests/helpers/editor_control_peer.py'])+'\nprimer_enabled=false\n');
const server=spawn('python3',[repo+'/tools/editor_server.py','--directory',pub,'--project-root',project,'--port','0','--bind','127.0.0.1','--config',config,'--daemon-binary',repo+'/build/bin/isonim-review'],{env:{...process.env,ISONIM_SOURCE_FRAMEWORK:repo},stdio:['ignore','pipe',openSync(root+'/server.log','w')]});
let browser,browserServer;
try {
 const origin=await new Promise((resolve,reject)=>{let text='';server.stdout.on('data',data=>{text+=data;const match=text.match(/Editor listening on (http:\/\/[^\s]+)\//);if(match)resolve(match[1]);});server.once('exit',code=>reject(Error('Server exited '+code)));setTimeout(()=>reject(Error('Server startup timeout')),70000).unref();});
 const chromeEnv={...process.env};delete chromeEnv.LD_LIBRARY_PATH;
 browserServer=await chromium.launchServer({headless:true,env:chromeEnv,executablePath:process.env.PLAYWRIGHT_CHROMIUM_EXECUTABLE});browser=await chromium.connect(browserServer.wsEndpoint());
 const page=await browser.newPage({viewport:{width:1440,height:900}});page.setDefaultTimeout(30000);
 // Observe actual top-window listener ownership while forwarding every browser
 // registration/removal unchanged. No selection event or DOM behavior is mocked.
 await page.addInitScript(()=>{const types=new Set(['isonim-select-preview-ancestor','isonim-select-preview-element-id','isonim-preview-set-declaration','isonim-preview-element-visibility','isonim-hover-preview-element-id']);const listeners=new Map([...types].map(type=>[type,new Set()]));window.__embeddedSavedCallbacks=[];const add=window.addEventListener.bind(window),remove=window.removeEventListener.bind(window);window.addEventListener=function(type,listener,options){if(types.has(type)){listeners.get(type).add(listener);window.__embeddedSavedCallbacks.push([type,listener]);}return add(type,listener,options);};window.removeEventListener=function(type,listener,options){if(types.has(type))listeners.get(type).delete(listener);return remove(type,listener,options);};window.__embeddedListenerCounts=()=>Object.fromEntries([...listeners].map(([type,set])=>[type,set.size]));});
 page.on('pageerror',error=>proof.errors.push(error.message));
 page.on('request',request=>{const url=new URL(request.url());if(url.pathname.startsWith('/api/agent/'))proof.agentRequests.push(url.pathname);if(url.pathname==='/api/editor/source/operation')proof.sourceRequests.push(request.postDataJSON());});
 const requestTimes=new WeakMap();page.on('request',request=>{if(new URL(request.url()).pathname.startsWith('/api/editor/source'))requestTimes.set(request,performance.now());});
 page.on('requestfinished',request=>{const started=requestTimes.get(request);if(started!==undefined)proof.httpTimings.push({path:new URL(request.url()).pathname,commandId:request.method()==='POST'?request.postDataJSON()?.commandId:null,milliseconds:performance.now()-started});});
 await page.goto(origin);await page.waitForFunction(()=>!!window.__popupAcceptance);
 await page.locator('[data-toolbar-cluster="mode"] [aria-label="Edit"]').click();
 await page.locator('[data-scene-graph-row="action"]').click();
 // Exercise all five current embedded channels on the real visible document.
 // The same forwarded events must leave hidden preview documents untouched.
 const currentChannels=await page.evaluate(()=>{
   const frames=[...document.querySelectorAll('iframe')].filter(frame=>frame.contentDocument?.querySelector('#action'));
   const visible=frames.find(frame=>frame.getClientRects().length&&getComputedStyle(frame).visibility!=='hidden');
   if(!visible)throw Error('Current visible source preview is required');
   const hidden=frames.filter(frame=>frame!==visible&&(!frame.getClientRects().length||getComputedStyle(frame).visibility==='hidden'));
   const documentState=frame=>({html:frame.contentDocument.documentElement.outerHTML,
     css:[...frame.contentDocument.styleSheets].map(sheet=>[...sheet.cssRules].map(rule=>rule.cssText))});
   const before=hidden.map(documentState);
   const doc=visible.contentDocument,target=doc.querySelector('#action'),id=target.dataset.isonimElementId;
   const initialSpacing=visible.contentWindow.getComputedStyle(target).letterSpacing;
   const initialHistory=JSON.parse(window.__popupAcceptance.snapshot()).undoCount;
   if(!Number.isInteger(initialHistory))throw Error("Real undo count required");
   const emit=(type,detail)=>window.dispatchEvent(new CustomEvent(type,{detail}));
   emit('isonim-select-preview-element-id',{id});
   const select=visible.contentWindow.__isonimSelectedElement===target;
   emit('isonim-select-preview-ancestor',{index:0});
   const ancestor=visible.contentWindow.__isonimSelectedElement!==target;
   emit('isonim-select-preview-element-id',{id});
   emit('isonim-hover-preview-element-id',{id});
   const hover=target.getAttribute('data-isonim-hovered')==='true';
   emit('isonim-preview-element-visibility',{id,visible:false});
   const hiddenValue=target.style.visibility==='hidden';
   emit('isonim-preview-element-visibility',{id,visible:true});
   const restoredVisibility=target.style.visibility==='';
   // Selection chrome owns outline with !important. Letter spacing observes
   // the author's actual declaration without competing with that overlay.
   emit('isonim-preview-set-declaration',{id,property:'letter-spacing',value:'3px'});
   const declaration=visible.contentWindow.getComputedStyle(target).letterSpacing==='3px';
   emit('isonim-preview-set-declaration',{id,property:'letter-spacing',value:''});
   const declarationRestored=visible.contentWindow.getComputedStyle(target).letterSpacing===initialSpacing;
   emit('isonim-hover-preview-element-id',{id:''});
   return {select,ancestor,hover,hiddenValue,restoredVisibility,declaration,declarationRestored,
     initialSpacing,historyUnchanged:JSON.parse(window.__popupAcceptance.snapshot()).undoCount===initialHistory,
     hiddenFrames:hidden.length,hiddenUnchanged:hidden.every((frame,index)=>JSON.stringify(documentState(frame))===JSON.stringify(before[index]))};
 });
 assert(currentChannels.select);assert(currentChannels.ancestor);assert(currentChannels.hover);
 assert(currentChannels.hiddenValue);assert(currentChannels.restoredVisibility);assert(currentChannels.declaration);
 assert(currentChannels.declarationRestored);assert(currentChannels.historyUnchanged);assert.equal(proof.sourceRequests.length,0);
 assert(currentChannels.hiddenFrames>=1);assert(currentChannels.hiddenUnchanged);proof.currentChannels=currentChannels;
 record('all five current preview channels work while hidden documents remain unchanged');
 await page.evaluate(()=>{window.__preSourceCallbacks=window.__embeddedSavedCallbacks.slice();window.__preSourceDocument=[...document.querySelectorAll('iframe')].find(frame=>frame.getClientRects().length&&frame.contentDocument?.querySelector('#action')).contentDocument;});
 const initialListeners=await page.evaluate(()=>window.__embeddedListenerCounts());proof.initialListeners=initialListeners;assert(Object.values(initialListeners).every(count=>count>=1));

 // This fixture declares editable CSS, not a component parameter schema.
 // Keep the ordinary CSS identity and native capability; expose these values
 // through their universal section rather than fabricating component rows.
 assert.equal(await page.locator('[data-component-prop-schema]').count(),0);
 assert.equal(await page.locator('[data-inspector-section-header="component-properties"]').isVisible(),false);
 assert.equal(await page.locator('[data-inspector-section-body="component-properties"] [data-property-row]').count(),0);
 record('actual plain DOM CSS selection has no component parameter rows or public section');

 const snapshot=()=>page.evaluate(()=>JSON.parse(window.__popupAcceptance.snapshot()));
 let staleVerified=false;
 async function waitApplied(count){
  const started=performance.now();
  await page.waitForFunction(count=>{const state=JSON.parse(window.__popupAcceptance.snapshot());return state.stage==='wesClean'&&state.undoCount===count;},count,{timeout:70000});
  const acknowledged=performance.now();
  const state=await snapshot(),catalog=JSON.parse(readFileSync(project+'/.isonim/catalog.json','utf8'));
  const story=catalog.stories.find(story=>story.group+' / '+story.name===state.story);assert(story);
  const css=[...story.documentHtml.matchAll(/<style[^>]*>([\s\S]*?)<\/style>/g)].map(match=>match[1]);assert(css.length);
  await page.waitForFunction(([css,selected])=>[...document.querySelectorAll('iframe')].some(frame=>{const doc=frame.contentDocument,win=frame.contentWindow,node=win?.__isonimSelectedElement;return frame.getClientRects().length&&doc?.readyState==='complete'&&css.every(value=>[...doc.querySelectorAll('style')].some(style=>style.textContent===value))&&(node?.id===selected||node?.dataset?.isonimElementId===selected);}),[css,state.selected]);
  await page.evaluate(()=>new Promise(resolve=>requestAnimationFrame(()=>requestAnimationFrame(resolve))));
  proof.previewTimings.push({count,acknowledgementMilliseconds:acknowledged-started,loadedRestoredPreviewMilliseconds:performance.now()-acknowledged});
  proof.currentListeners=await page.evaluate(()=>window.__embeddedListenerCounts());writeFileSync(root+'/listener-ownership.json',JSON.stringify({initial:initialListeners,current:proof.currentListeners},null,2));assert.deepEqual(proof.currentListeners,initialListeners,'source reload must replace embedded parent callbacks without retaining older documents');
  if(!staleVerified){const stale=await page.evaluate(()=>{const old=window.__preSourceDocument,saved=window.__preSourceCallbacks;const state=()=>JSON.parse(window.__popupAcceptance.snapshot()).selected;const oldState=()=>JSON.stringify({html:old.documentElement.outerHTML,rules:[...old.styleSheets].map(sheet=>[...sheet.cssRules].map(rule=>rule.cssText))});const selected=state(),before=oldState();for(const [type,callback] of saved)callback(new CustomEvent(type,{detail:{id:'reused',index:0,property:'width',value:'999px',visible:false}}));return {count:saved.length,selectedUnchanged:state()===selected,oldDocumentUnchanged:oldState()===before};});assert(stale.count>=5);assert(stale.selectedUnchanged);assert(stale.oldDocumentUnchanged);proof.staleCallbacks=stale;staleVerified=true;record('disposed embedded document callbacks cannot emit selection or mutate either document');}
 }
 const source=()=>readFileSync(project+'/stories.nim','utf8');
 let expectedSource=source(),count=0;
 const propertyRow=(property,name)=>page.locator('[data-property-row-css-property="'+property+'"][data-property-row="'+name+'"]');
 async function expectStyle(property,value){await page.waitForFunction(([property,value])=>{const frame=[...document.querySelectorAll('iframe')].find(frame=>frame.getClientRects().length&&frame.contentDocument?.querySelector('#action'));return frame&&frame.contentWindow.getComputedStyle(frame.contentDocument.querySelector('#action')).getPropertyValue(property)===value;},[property,value]);}
 async function applyTyped(row,property,oldValue,newValue,label,sourceValue=newValue){const before=proof.sourceRequests.length;const input=row.locator('[data-property-row-input]');assert.equal(await input.count(),1);await input.waitFor({state:'visible'});await input.scrollIntoViewIfNeeded();assert(await input.isVisible());await input.fill(newValue);await input.press('Enter');await input.press('Tab');await waitApplied(++count);expectedSource=expectedSource.replace(property+':'+oldValue+';',property+':'+sourceValue+';');assert.equal(source(),expectedSource);assert.equal(proof.sourceRequests.length,before+1);record(label);}
 async function applyScrub(row,property,oldValue,newValue,dx,label,sourceValue=newValue){const handle=row.locator('[data-property-row-field-label]');await handle.waitFor({state:'visible'});await handle.scrollIntoViewIfNeeded();const box=await handle.boundingBox();assert(box);assert(await handle.evaluate(el=>{const b=el.getBoundingClientRect();return el.contains(document.elementFromPoint(b.x+b.width/2,b.y+b.height/2));}));const before=proof.sourceRequests.length;await handle.evaluate(node=>{window.__compoundHandle=node;window.__compoundHandleLost=false;new MutationObserver(()=>{if(!node.isConnected)window.__compoundHandleLost=true;}).observe(document.body,{childList:true,subtree:true});});await page.mouse.move(box.x+box.width/2,box.y+box.height/2);await page.mouse.down();await page.mouse.move(box.x+box.width/2+dx,box.y+box.height/2);assert(await page.evaluate(()=>window.__compoundHandle.isConnected&&!window.__compoundHandleLost));await page.mouse.up();await waitApplied(++count);expectedSource=expectedSource.replace(property+':'+oldValue+';',property+':'+sourceValue+';');assert.equal(source(),expectedSource);assert.equal(proof.sourceRequests.length,before+1);record(label);}
 const appearanceHeader=page.locator('[data-inspector-section-header="appearance"]');
 if(await appearanceHeader.getAttribute('aria-expanded')==='false')await appearanceHeader.click();
 proof.checkboxGeometry=await page.locator('input[aria-label="Toggle Per-corner"]').evaluate(node=>{const rows=[];for(let el=node;el;el=el.parentElement){const rect=el.getBoundingClientRect(),style=getComputedStyle(el);rows.push({tag:el.tagName,attributes:[...el.attributes].map(a=>[a.name,a.value]),rect:{x:rect.x,y:rect.y,width:rect.width,height:rect.height},display:style.display,visibility:style.visibility});}return rows;});
 writeFileSync(root+'/checkbox-geometry.json',JSON.stringify(proof.checkboxGeometry,null,2));
 const cornerToggle=page.getByRole('checkbox',{name:'Toggle Per-corner'});
 assert.equal(await cornerToggle.isChecked(),false);
 await cornerToggle.click();assert.equal(await cornerToggle.isChecked(),true);
 assert(await page.locator('[data-appearance-percorner-host]').isVisible());
 await cornerToggle.press('Space');assert.equal(await cornerToggle.isChecked(),false);
 assert.equal(await page.locator('[data-appearance-percorner-host]').isVisible(),false);
 await cornerToggle.press('Space');assert.equal(await cornerToggle.isChecked(),true);
 assert(await page.locator('[data-appearance-percorner-host]').isVisible());
 assert.equal(proof.sourceRequests.length,0);record('pointer and Space toggle real checkbox/compound visibility once without source history');
 const tl=propertyRow('border-top-left-radius','tl'),tr=propertyRow('border-top-right-radius','tr');
 await applyTyped(tl,'border-top-left-radius','1em','2em','typed corner longhand writes only its declared source target');
 proof.afterCornerWrite=await page.evaluate(()=>({header:document.querySelector('[data-inspector-section-header="appearance"]')?.getAttribute('aria-expanded'),checked:document.querySelector('input[aria-label="Toggle Per-corner"]')?.checked,hostDisplay:getComputedStyle(document.querySelector('[data-appearance-percorner-host]')).display,sectionDisplay:getComputedStyle(document.querySelector('[data-inspector-section-body="appearance"]')).display}));writeFileSync(root+'/after-corner-write.json',JSON.stringify(proof.afterCornerWrite,null,2));
 proof.cornerRow=await tr.evaluate(node=>({html:node.outerHTML,geometry:[...node.querySelectorAll('[data-property-row-field-label],input')].map(el=>({text:el.textContent,rect:el.getBoundingClientRect().toJSON(),display:getComputedStyle(el).display}))}));writeFileSync(root+'/corner-row.json',JSON.stringify(proof.cornerRow,null,2));
 await applyScrub(tr,'border-top-right-radius','2px','8px',3,'captured corner scrub writes only the other declared corner');
 await expectStyle('border-top-right-radius','8px');assert.equal(await tl.locator('[data-property-row-unit]').textContent(),'em');assert.equal(await tl.locator('input').inputValue(),'2');record('independent corner units survive edits to a different side');
 const top=propertyRow('padding-top','pad-top'),right=propertyRow('padding-right','pad-right');
 await applyTyped(top,'padding-top','1em','2em','typed padding side uses authored em and genuine native writer');
 await applyScrub(right,'padding-right','2px','6px',2,'captured padding side scrub preserves other source values and units');
 await expectStyle('padding-right','6px');assert.equal(await top.locator('[data-property-row-unit]').textContent(),'em');assert.equal(await top.locator('input').inputValue(),'2');
 await applyTyped(top,'padding-top','2em','3em','ordinary Layout numeric field repeats typed native source operation');
 await applyScrub(top,'padding-top','3em','4em',.5,'ordinary Layout captured numeric field retains draft and native source operation');
 await page.evaluate(()=>window.__popupAcceptance.history(false));await waitApplied(--count);expectedSource=expectedSource.replace('padding-top:4em;','padding-top:3em;');assert.equal(source(),expectedSource);assert.equal(await top.locator('input').inputValue(),'3');
 await page.evaluate(()=>window.__popupAcceptance.history(true));await waitApplied(++count);expectedSource=expectedSource.replace('padding-top:3em;','padding-top:4em;');assert.equal(source(),expectedSource);record('compound native undo and redo move history after exact source recompilation');
 const swatch=page.locator('[data-fill-row-swatch="0"]');await swatch.click();const picker=page.locator('[data-color-popover-open="true"]');const hue=picker.locator('[data-color-hue]');const hueBox=await hue.boundingBox();assert(hueBox);const beforeHue=proof.sourceRequests.length;await page.mouse.move(hueBox.x+hueBox.width*.2,hueBox.y+hueBox.height/2);await page.mouse.down();await page.mouse.move(hueBox.x+hueBox.width*.65,hueBox.y+hueBox.height/2);await page.mouse.up();const draft=await picker.locator('[data-color-popover-input]').inputValue();assert.notEqual(draft,'#112233');assert.equal(proof.sourceRequests.length,beforeHue);await picker.locator('[data-color-popover-apply]').click();await waitApplied(++count);expectedSource=expectedSource.replace('background-color:#112233;','background-color:'+draft.toLowerCase()+';');assert.equal(source(),expectedSource);assert.equal(proof.sourceRequests.length,beforeHue+1);record('actual hue pointer gesture shares cancelable draft and one native Apply');

 // Source-first opacity percentage: typing and captured scrubbing share exactly
 // the same real native operation, compiled stylesheet and retained disclosure.
 const opacityRow=page.locator('[data-inspector-section-body="appearance"] [data-property-row-css-property="opacity"][data-property-row="opacity"]');assert.equal(await opacityRow.count(),1);await appearanceHeader.scrollIntoViewIfNeeded();if(await appearanceHeader.getAttribute('aria-expanded')==='false')await appearanceHeader.click();
 assert.equal(await opacityRow.locator('input').inputValue(),'80');assert.equal(await opacityRow.locator('[data-property-row-unit]').textContent(),'%');
 await applyTyped(opacityRow,'opacity','80%','25%','authored opacity percent types through one normalized native ratio Apply','0.25');
 await expectStyle('opacity','0.25');assert.equal(await opacityRow.locator('input').inputValue(),'25');
 await applyScrub(opacityRow,'opacity','0.25','27%',1,'captured opacity scrub shares percent-to-ratio native compiler boundary','0.27');await expectStyle('opacity','0.27');assert.equal(await opacityRow.locator('input').inputValue(),'27');
 const layoutHeader=page.locator('[data-inspector-section-header="layout"]');if(await layoutHeader.getAttribute('aria-expanded')==='false')await layoutHeader.click();
 const gridMode=page.locator('[data-layout-mode="grid"]'),horizontalMode=page.locator('[data-layout-mode="horizontal"]'),verticalMode=page.locator('[data-layout-mode="vertical"]');
 const modeMessage=page.locator('[data-layout-mode-message]');assert.equal(await horizontalMode.getAttribute('data-layout-mode-active'),'true');
 const beforeMode=proof.sourceRequests.length;await gridMode.scrollIntoViewIfNeeded();await gridMode.click();await waitApplied(++count);expectedSource=expectedSource.replace('display:inline-flex;','display:inline-grid;');assert.equal(source(),expectedSource);assert.equal(proof.sourceRequests.length,beforeMode+1);await expectStyle('display','inline-grid');assert.equal(await gridMode.getAttribute('data-layout-mode-active'),'true');
 const actualModePreview=()=>page.evaluate(()=>{const frame=[...document.querySelectorAll('iframe')].find(frame=>frame.getClientRects().length&&frame.contentDocument?.querySelector('#action'));if(!frame)throw Error("Actual visible native preview is required");const node=frame.contentDocument.querySelector('#action');return{display:frame.contentWindow.getComputedStyle(node).display,direction:frame.contentWindow.getComputedStyle(node).flexDirection,opacity:frame.contentWindow.getComputedStyle(node).opacity,css:[...frame.contentDocument.styleSheets].map(sheet=>[...sheet.cssRules].map(rule=>rule.cssText))};});
 const beforeRefusal={source:source(),catalog:readFileSync(project+'/.isonim/catalog.json','utf8'),state:await snapshot(),preview:await actualModePreview(),requests:proof.sourceRequests.length};
 await verticalMode.scrollIntoViewIfNeeded();const modeBox=await verticalMode.boundingBox();assert(modeBox);assert(await verticalMode.evaluate(el=>{const b=el.getBoundingClientRect();return el.contains(document.elementFromPoint(b.x+b.width/2,b.y+b.height/2));}));await page.mouse.click(modeBox.x+modeBox.width/2,modeBox.y+modeBox.height/2);assert.equal(await modeMessage.textContent(),'The editor cannot safely change both layout declarations together yet.');assert.equal(proof.sourceRequests.length,beforeRefusal.requests);assert.deepEqual(await actualModePreview(),beforeRefusal.preview);

 for(const key of ['Enter','Space']){await verticalMode.focus();await verticalMode.press(key);assert.equal(await modeMessage.textContent(),'The editor cannot safely change both layout declarations together yet.');assert.equal(source(),beforeRefusal.source);assert.equal(readFileSync(project+'/.isonim/catalog.json','utf8'),beforeRefusal.catalog);assert.deepEqual(await snapshot(),beforeRefusal.state);assert.deepEqual(await actualModePreview(),beforeRefusal.preview);assert.equal(proof.sourceRequests.length,beforeRefusal.requests);assert.equal(await gridMode.getAttribute('data-layout-mode-active'),'true');}
 for(const key of ['Tab','Escape']){await verticalMode.focus();await verticalMode.press(key);assert.equal(source(),beforeRefusal.source);assert.equal(proof.sourceRequests.length,beforeRefusal.requests);}
 record('physical layout click writes supported display once; compound Enter/Space refuses without mode/source/history change and Tab/Escape are inert');
 await horizontalMode.focus();await horizontalMode.press('Enter');await page.evaluate(()=>new Promise(resolve=>requestAnimationFrame(resolve)));
 proof.layoutAdmission={snapshot:await snapshot(),message:await modeMessage.textContent(),requests:proof.sourceRequests.length,button:await horizontalMode.evaluate(el=>({html:el.outerHTML,tag:el.tagName,focused:document.activeElement===el,disabled:el.disabled})),before:beforeMode};writeFileSync(root+'/layout-admission.json',JSON.stringify(proof.layoutAdmission,null,2));
 assert(proof.sourceRequests.length>beforeMode+1||(await snapshot()).stage!=='wesClean','Supported native layout keyboard activation must admit a real operation: '+JSON.stringify(proof.layoutAdmission));await waitApplied(++count);expectedSource=expectedSource.replace('display:inline-grid;','display:inline-flex;');assert.equal(source(),expectedSource);await expectStyle('display','inline-flex');
 const beforeDirectionPosts=proof.sourceRequests.length;await verticalMode.focus();await verticalMode.press('Space');await page.evaluate(()=>new Promise(resolve=>requestAnimationFrame(resolve)));
 proof.layoutDirectionAdmission={snapshot:await snapshot(),message:await modeMessage.textContent(),requests:proof.sourceRequests.length,beforeRequests:beforeDirectionPosts,button:await verticalMode.evaluate(el=>({html:el.outerHTML,tag:el.tagName,focused:document.activeElement===el,disabled:el.disabled})),preview:await actualModePreview()};writeFileSync(root+'/layout-direction-admission.json',JSON.stringify(proof.layoutDirectionAdmission,null,2));
 assert(proof.sourceRequests.length>beforeDirectionPosts||(await snapshot()).stage!=='wesClean','Existing native direction capability must be available to the production selection bridge: '+JSON.stringify(proof.layoutDirectionAdmission));await waitApplied(++count);expectedSource=expectedSource.replace('flex-direction:row;','flex-direction:column;');assert.equal(source(),expectedSource);assert.equal(proof.sourceRequests.length,beforeMode+3);await expectStyle('display','inline-flex');await expectStyle('flex-direction','column');assert.equal(await verticalMode.getAttribute('data-layout-mode-active'),'true');record('native Enter/Space single-property layout changes preserve inline display and current compiled direction');
 // Reused authored IDs across stories: failed old writes never restore old drafts
 // or focus into the newly selected story, and the actual compiler restores bytes.
 await page.locator('[data-scene-graph-row="reused"]').click();const width=propertyRow('width','w');await page.waitForFunction(()=>document.querySelector('[data-property-row="w"] input')?.value==='110');const beforeFailure=source(),catalogBefore=readFileSync(project+'/.isonim/catalog.json','utf8');await width.locator('input').fill('777px');await width.locator('input').press('Enter');await page.waitForFunction(()=>JSON.parse(window.__popupAcceptance.snapshot()).stage==='wesCompiling');assert(await page.evaluate(()=>window.__popupAcceptance.openStory('Alternate','default ready')));await page.waitForFunction(()=>[...document.querySelectorAll('iframe')].some(frame=>frame.getClientRects().length&&frame.contentDocument?.querySelector('#reused-alternate')));await page.locator('[data-scene-graph-row="reused"]').click();await page.waitForFunction(()=>document.querySelector('[data-property-row="w"] input')?.value==='210');await width.locator('input').focus();await page.waitForFunction(()=>JSON.parse(window.__popupAcceptance.snapshot()).stage==='wesFailed',null,{timeout:70000});assert.equal(source(),beforeFailure);assert.equal(readFileSync(project+'/.isonim/catalog.json','utf8'),catalogBefore);assert.equal(await width.locator('input').inputValue(),'210');assert.equal(await width.locator('[data-property-row-unit]').textContent(),'px');assert.equal(await width.locator('input').evaluate(node=>document.activeElement===node),true);assert.equal((await snapshot()).undoCount,count);record('real compiler refusal after same-ID story switch preserves new controls/focus/source/catalog/history');
 assert.deepEqual(proof.errors,[]);assert.deepEqual(proof.agentRequests,[]);writeFileSync(root+'/proof.json',JSON.stringify(proof,null,2));console.log('Inspector compound GUI passed:',root,proof.cases.length);
} finally {
 if(browser)await browser.close();if(browserServer)await browserServer.close();
 server.kill('SIGTERM');await new Promise(resolve=>{if(server.exitCode!==null)return resolve();server.once('exit',resolve);setTimeout(()=>{server.kill('SIGKILL');resolve();},15000).unref();});
 writeFileSync(root+'/proof-final.json',JSON.stringify(proof,null,2));
}
