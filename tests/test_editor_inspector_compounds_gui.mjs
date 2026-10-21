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
writeFileSync(project+'/stories.nim',setupSource.replace('#action { width:120px;','#action { box-shadow:1px 2px 3px #123456; border-style:dashed; display:inline-flex; flex-direction:row; opacity:80%; width:120px;').replace('#secondary-action { width:160px;', '#secondary-action { box-shadow:1px 2px 3px #123456; border-color:#FFFFFF; width:160px;').replace('background-color:#334455;', 'background-color:rgba(18,52,86,0.5);'));
const setupManifest=JSON.parse(readFileSync(project+'/.isonim/source-project.json','utf8'));
setupManifest.editableStyles.find(row=>row.elementId==='action').properties.push('display','flex-direction','opacity','box-shadow');
assert(!setupManifest.editableStyles.find(row=>row.elementId==='secondary-action').properties.includes('box-shadow'),'Computed fallback fixture must have no editable box-shadow owner');
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
 await page.locator('[data-toolbar-cluster="mode"] [aria-label="Switch to edit mode"]').click();
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
 // Read actual bridge events from the real compiled document. The expected CSS
 // is a literal independent of bridge implementation and source-owner lookup.
 const selectionBefore={source:readFileSync(project+'/stories.nim','utf8'),catalog:readFileSync(project+'/.isonim/catalog.json','utf8'),state:await snapshot(),requests:proof.sourceRequests.length};
 assert(Number.isInteger(selectionBefore.state.undoCount));assert(Number.isInteger(selectionBefore.state.redoCount));
 await page.evaluate(()=>{window.__documentStyleSelections=[];window.__documentStyleListener=event=>window.__documentStyleSelections.push(event.detail);window.addEventListener('isonim-preview-element-selected',window.__documentStyleListener);});

 // A real responsive document exposes layout corruption if overlay positioning
 // is suppressed with selection paint. Temporary literal author CSS uses the
 // same browser/compiler preview; restore its exact declarations afterwards.
 await page.evaluate(()=>{const frame=[...document.querySelectorAll('iframe')].find(frame=>frame.getClientRects().length&&frame.contentWindow?.__isonimSelectedElement),doc=frame.contentDocument,target=doc.querySelector('#secondary-action');let owner=target;while(owner.parentElement!==doc.body)owner=owner.parentElement;const style=doc.createElement('style');style.textContent='body { display:flex!important; flex-direction:row!important; width:800px!important; margin:0!important; }';window.__responsiveAuthorStyles={owner,target,ownerStyle:owner.getAttribute('style'),targetStyle:target.getAttribute('style'),style};doc.head.appendChild(style);owner.style.cssText+=';flex:1 1 0%!important;min-width:0!important';target.style.cssText+=';width:100%!important;box-sizing:border-box!important';});
 await page.locator('[data-scene-graph-row="secondary-action"]').click();await page.mouse.move(0,0);await page.evaluate(()=>new Promise(resolve=>requestAnimationFrame(()=>requestAnimationFrame(resolve))));
 const responsive=await page.evaluate(()=>{const saved=window.__responsiveAuthorStyles,doc=saved.target.ownerDocument,win=doc.defaultView,target=saved.target,rect=target.getBoundingClientRect(),style=win.getComputedStyle(target),handles=doc.querySelector('#isonim-editor-selection-handles');return{detail:window.__documentStyleSelections.at(-1),rendered:{width:style.width,rectWidth:String(Math.round(rect.width))},layoutDisabled:doc.querySelector('#isonim-editor-selection-style').sheet.disabled,paintDisabled:doc.querySelector('#isonim-editor-selection-paint-style')?.sheet.disabled,handlesPosition:win.getComputedStyle(handles).position,handlesVisible:!handles.hidden&&!!handles.getClientRects().length,handleCount:handles.querySelectorAll('[data-handle]').length,state:JSON.parse(window.__popupAcceptance.snapshot())};});
 proof.responsiveLayout=responsive;writeFileSync(root+'/responsive-layout.json',JSON.stringify(responsive,null,2));
 assert.equal(responsive.rendered.width,'800px');assert.equal(responsive.rendered.rectWidth,'800');
 assert.equal(responsive.detail.width,'800px','Sampling must preserve actual responsive authored width');assert.equal(responsive.detail.rectWidth,'800','Sampling must preserve actual responsive authored rectangle');assert(responsive.detail.computedStyles.split(';').includes('width=800px'));
 assert.equal(responsive.layoutDisabled,false);assert.equal(responsive.paintDisabled,false);assert.equal(responsive.handlesPosition,'fixed');assert(responsive.handlesVisible);assert.equal(responsive.handleCount,5);
 for(const key of ['undoCount','redoCount','stage'])assert.equal(responsive.state[key],selectionBefore.state[key]);assert.equal(readFileSync(project+'/stories.nim','utf8'),selectionBefore.source);assert.equal(readFileSync(project+'/.isonim/catalog.json','utf8'),selectionBefore.catalog);assert.equal(proof.sourceRequests.length,selectionBefore.requests);
 const responsiveFocus=await page.evaluate(()=>{const saved=window.__responsiveAuthorStyles,doc=saved.target.ownerDocument,target=saved.target;target.focus();const focused=doc.activeElement;window.dispatchEvent(new CustomEvent('isonim-select-preview-element-id',{detail:{id:target.dataset.isonimElementId}}));return{focusedBefore:focused===target,focusUnchanged:doc.activeElement===focused,detail:window.__documentStyleSelections.at(-1),chromeShadow:doc.defaultView.getComputedStyle(target).boxShadow,layoutDisabled:doc.querySelector('#isonim-editor-selection-style').sheet.disabled,paintDisabled:doc.querySelector('#isonim-editor-selection-paint-style').sheet.disabled,state:JSON.parse(window.__popupAcceptance.snapshot())};});
 proof.responsiveFocus=responsiveFocus;assert(responsiveFocus.focusedBefore);assert(responsiveFocus.focusUnchanged);assert.equal(responsiveFocus.detail.width,'800px');assert.equal(responsiveFocus.detail.rectWidth,'800');assert(responsiveFocus.detail.computedStyles.split(';').includes('width=800px'));assert.equal(responsiveFocus.chromeShadow,'rgba(59, 130, 246, 0.22) 0px 0px 0px 4px');assert.equal(responsiveFocus.layoutDisabled,false);assert.equal(responsiveFocus.paintDisabled,false);for(const key of ['undoCount','redoCount','stage'])assert.equal(responsiveFocus.state[key],selectionBefore.state[key]);assert.equal(readFileSync(project+'/stories.nim','utf8'),selectionBefore.source);assert.equal(readFileSync(project+'/.isonim/catalog.json','utf8'),selectionBefore.catalog);assert.equal(proof.sourceRequests.length,selectionBefore.requests);
 await page.evaluate(()=>{const saved=window.__responsiveAuthorStyles;for(const [node,value] of [[saved.owner,saved.ownerStyle],[saved.target,saved.targetStyle]]){if(value===null)node.removeAttribute('style');else node.setAttribute('style',value);}saved.style.remove();delete window.__responsiveAuthorStyles;});
 record('real responsive document metadata preserves authored width/rectangle/overlay positioning/focus/source/catalog/undo/redo');
 const documentStyles=[];
 for(let cycle=0;cycle<2;cycle++)for(const [id,expectedShadow] of [['secondary-action','rgb(18, 52, 86) 1px 2px 3px 0px'],['reused','none']]){
  await page.locator('[data-scene-graph-row="'+id+'"]').click();
  await page.mouse.move(0,0);await page.evaluate(()=>new Promise(resolve=>requestAnimationFrame(()=>requestAnimationFrame(resolve))));
  const inspected=await page.evaluate(()=>{const detail=window.__documentStyleSelections.at(-1),frame=[...document.querySelectorAll('iframe')].find(frame=>frame.getClientRects().length&&frame.contentWindow?.__isonimSelectedElement),doc=frame.contentDocument,node=frame.contentWindow.__isonimSelectedElement,style=frame.contentWindow.getComputedStyle(node),handles=doc.querySelector('#isonim-editor-selection-handles');return{detail,selected:node.dataset.isonimElementId,chromeShadow:style.boxShadow,outline:style.outline,selectedAttribute:node.getAttribute('data-isonim-selected'),sheetDisabled:doc.querySelector('#isonim-editor-selection-style').sheet.disabled,paintDisabled:doc.querySelector('#isonim-editor-selection-paint-style').sheet.disabled,handlesVisible:!!handles&&!handles.hidden&&!!handles.getClientRects().length,handleCount:handles?.querySelectorAll('[data-handle]').length,state:JSON.parse(window.__popupAcceptance.snapshot())};});
  documentStyles.push(inspected);proof.documentStyleSelections=documentStyles;writeFileSync(root+'/document-style-selections.json',JSON.stringify(documentStyles,null,2));
  assert.equal(inspected.selected,id);assert.equal(inspected.detail.boxShadow,expectedShadow,'Inspector must sample document shadow without selection chrome');
  assert(inspected.detail.computedStyles.split(';').includes('box-shadow='+expectedShadow),'Universal computed metadata must match document CSS');
  assert.equal(inspected.selectedAttribute,'true');assert.equal(inspected.sheetDisabled,false);assert.equal(inspected.paintDisabled,false);assert.equal(inspected.chromeShadow,'rgba(59, 130, 246, 0.22) 0px 0px 0px 4px');assert.equal(inspected.outline,'rgb(59, 130, 246) solid 2px');assert(inspected.handlesVisible);assert.equal(inspected.handleCount,5);
  const header=page.locator('[data-inspector-section-header="effects"]');if(await header.getAttribute('aria-expanded')==='false')await header.click();
  const effects=page.locator('[data-inspector-section-body="effects"]');if(expectedShadow==='none'){assert.equal(await effects.locator('[data-effects-row]').count(),0);assert(await effects.locator('[data-effects-empty]').isVisible());}else{assert((await effects.locator('[data-effects-list]').innerText()).includes(expectedShadow),'Unowned document shadow must reach actual inspector Effects');assert.equal(await effects.locator('[data-effects-empty]').isVisible(),false);}
  await header.click();
  for(const key of ['undoCount','redoCount','stage'])assert.equal(inspected.state[key],selectionBefore.state[key]);
  assert.equal(readFileSync(project+'/stories.nim','utf8'),selectionBefore.source);assert.equal(readFileSync(project+'/.isonim/catalog.json','utf8'),selectionBefore.catalog);assert.equal(proof.sourceRequests.length,selectionBefore.requests);
 }
 await page.locator('[data-scene-graph-row="action"]').click();
 await page.evaluate(()=>{window.removeEventListener('isonim-preview-element-selected',window.__documentStyleListener);delete window.__documentStyleListener;});
 record('real repeated unowned-shadow and no-shadow selections inspect document CSS while retaining blue chrome/handles/source/catalog/history');

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
 // Unsupported specialized controls must inspect the real current selection,
 // never simulate an edit with section-local state. Physical pointer and keys
 // retain the exact source, compiled catalog, preview declarations and history.
 const unsupportedPreview=()=>page.evaluate(()=>{const frame=[...document.querySelectorAll('iframe')].find(frame=>frame.getClientRects().length&&frame.contentDocument?.querySelector('#action'));if(!frame)throw Error('Actual source preview is required');const node=frame.contentDocument.querySelector('#action');return{shadow:frame.contentWindow.getComputedStyle(node).boxShadow,rules:[...frame.contentDocument.styleSheets].map(sheet=>[...sheet.cssRules].map(rule=>rule.cssText))};});
 await page.mouse.move(0,0);await page.evaluate(()=>new Promise(resolve=>requestAnimationFrame(()=>requestAnimationFrame(resolve))));
 // First focus restoration can register existing visibility-effect source
 // dependencies. Record that first-use behavior, then hold the complete stable
 // snapshot (including observer counts) across every repeated rejected edit.
 const warmHeader=page.locator('[data-inspector-section-header="stroke"]');if(await warmHeader.getAttribute('aria-expanded')==='false')await warmHeader.click();
 const warmPosition=page.locator('[data-inspector-section-body="stroke"] [data-property-row="position"]'),warmTrigger=warmPosition.locator('[data-choice-group-trigger]');
 const warmBefore={state:await snapshot(),source:source(),catalog:readFileSync(project+'/.isonim/catalog.json','utf8'),preview:await unsupportedPreview(),requests:proof.sourceRequests.length};
 await warmTrigger.click();await warmPosition.locator('[data-choice-group-option="0"]').focus();await page.keyboard.press('Escape');await page.evaluate(()=>new Promise(resolve=>requestAnimationFrame(()=>requestAnimationFrame(resolve))));
 assert.equal(await warmTrigger.getAttribute('aria-expanded'),'false');assert.equal(await warmPosition.locator('[data-choice-group-popup]').getAttribute('data-popup-open'),'false');assert(await warmTrigger.evaluate(node=>document.activeElement===node));
 const warmAfter=await snapshot();const {reactiveObservers:warmBeforeObservers,...warmBeforeState}=warmBefore.state,{reactiveObservers:warmAfterObservers,...warmAfterState}=warmAfter;assert.deepEqual(warmAfterState,warmBeforeState);assert.equal(source(),warmBefore.source);assert.equal(readFileSync(project+'/.isonim/catalog.json','utf8'),warmBefore.catalog);assert.deepEqual(await unsupportedPreview(),warmBefore.preview);assert.equal(proof.sourceRequests.length,warmBefore.requests);proof.firstPositionDisclosure={beforeObservers:warmBeforeObservers,afterObservers:warmAfterObservers};
 const unsupportedBefore={source:source(),catalog:readFileSync(project+'/.isonim/catalog.json','utf8'),state:await snapshot(),preview:await unsupportedPreview(),requests:proof.sourceRequests.length};
 const unsupportedUnchanged=async()=>{assert.equal(source(),unsupportedBefore.source);assert.equal(readFileSync(project+'/.isonim/catalog.json','utf8'),unsupportedBefore.catalog);assert.deepEqual(await snapshot(),unsupportedBefore.state);assert.deepEqual(await unsupportedPreview(),unsupportedBefore.preview);assert.equal(proof.sourceRequests.length,unsupportedBefore.requests);};
 const effectsHeader=page.locator('[data-inspector-section-header="effects"]'),headerAdd=effectsHeader.locator('[data-inspector-section-action="add"]');
 const expandedBefore=await effectsHeader.getAttribute('aria-expanded');await headerAdd.scrollIntoViewIfNeeded();const headerAddBox=await headerAdd.boundingBox();assert(headerAddBox);await page.mouse.click(headerAddBox.x+headerAddBox.width/2,headerAddBox.y+headerAddBox.height/2);assert.equal(await headerAdd.getAttribute('aria-disabled'),'true');assert((await headerAdd.getAttribute('title')).length>0);
 for(const key of ['Enter','Space','a','ArrowDown','Tab','Shift+Tab','Escape']){await headerAdd.focus();await page.keyboard.press(key);assert.equal(await effectsHeader.getAttribute('aria-expanded'),expandedBefore);await unsupportedUnchanged();if(key==='Tab'||key==='Shift+Tab')assert.equal(await headerAdd.evaluate(node=>document.activeElement===node),false,'Disabled header action retains natural focus traversal');}
 record('unsupported Effects header Add physical click and keyboard preserve expansion/source/catalog/preview/history and natural Tab traversal');
 await page.locator('[data-inspector-section-header="effects"]').click();
 const effects=page.locator('[data-inspector-section-body="effects"]'),addEffect=effects.locator('[data-effects-add]');
 await addEffect.scrollIntoViewIfNeeded();const addBox=await addEffect.boundingBox();assert(addBox);await page.mouse.click(addBox.x+addBox.width/2,addBox.y+addBox.height/2);
 assert.equal(await effects.locator('[data-effects-row-delete]').count(),0,'Unsupported Add must not fabricate editable effect rows');
 assert.equal(await addEffect.getAttribute('aria-disabled'),'true');
 for(const key of ['Enter','Space','a','ArrowDown','Tab','Escape']){await addEffect.focus();await page.keyboard.press(key);await unsupportedUnchanged();}
 assert((await effects.locator('[data-effects-readonly-message]').innerText()).length>0);
 assert((await effects.locator('[data-effects-list]').innerText()).includes('1px 2px 3px'),'Actual selected box shadow must remain inspectable');
 assert.equal(await effects.locator('[data-effects-empty]').isVisible(),false,'Existing computed effects cannot be labelled empty');
 await unsupportedUnchanged();record('unsupported Effects physical click and all keys preserve actual effect/source/catalog/preview/selection/history');
 await page.locator('[data-inspector-section-header="effects"]').click();
 const strokeHeader=page.locator('[data-inspector-section-header="stroke"]');
 if(await strokeHeader.getAttribute('aria-expanded')==='false')await strokeHeader.click();
 const stroke=page.locator('[data-inspector-section-body="stroke"]'),position=stroke.locator('[data-property-row="position"]');
 const beforePositionDisclosure=await snapshot();
 proof.positionObserversBefore=await page.evaluate(()=>JSON.parse(window.__popupAcceptance.observerDetails()));
 await position.locator('[data-choice-group-trigger]').click();
 unsupportedBefore.state=await snapshot();
 const positionBefore=await position.innerText(),inside=position.locator('[data-choice-group-option="0"]');await inside.scrollIntoViewIfNeeded();const insideBox=await inside.boundingBox();assert(insideBox);await page.mouse.click(insideBox.x+insideBox.width/2,insideBox.y+insideBox.height/2);
 assert.equal(await position.getAttribute('data-property-row-readonly'),'true');assert.equal(await position.innerText(),positionBefore);
 for(const key of ['Enter','Space']){await inside.focus();await inside.press(key);assert.equal(await position.innerText(),positionBefore);await unsupportedUnchanged();}
 await inside.press('Escape');
 await page.evaluate(()=>new Promise(resolve=>requestAnimationFrame(()=>requestAnimationFrame(resolve))));
 proof.positionDisclosureAfterClose={expanded:await position.locator('[data-choice-group-trigger]').getAttribute('aria-expanded'),open:await position.locator('[data-choice-group-popup]').getAttribute('data-popup-open'),focused:await position.locator('[data-choice-group-trigger]').evaluate(node=>document.activeElement===node),state:await snapshot(),observers:await page.evaluate(()=>JSON.parse(window.__popupAcceptance.observerDetails()))};writeFileSync(root+'/position-disclosure-diagnostic.json',JSON.stringify({before:proof.positionObserversBefore,after:proof.positionDisclosureAfterClose},null,2));assert.equal(proof.positionDisclosureAfterClose.expanded,'false');assert.equal(proof.positionDisclosureAfterClose.open,'false');assert.equal(proof.positionDisclosureAfterClose.focused,true);
 assert.deepEqual(await snapshot(),beforePositionDisclosure,'Repeated inspection popup closure preserves stable observer ownership and the complete prior state');unsupportedBefore.state=beforePositionDisclosure;
 for(let cycle=0;cycle<2;cycle++){await position.locator('[data-choice-group-trigger]').click();await inside.focus();await inside.press('Escape');await page.evaluate(()=>new Promise(resolve=>requestAnimationFrame(()=>requestAnimationFrame(resolve))));assert.equal(await position.locator('[data-choice-group-trigger]').getAttribute('aria-expanded'),'false');assert(await position.locator('[data-choice-group-trigger]').evaluate(node=>document.activeElement===node));await unsupportedUnchanged();}
 const dash=stroke.locator('[data-property-row="dash-pattern"]'),dashInput=dash.locator('[data-property-row-input]');assert(await dashInput.evaluate(node=>node.readOnly));await dashInput.click();await dashInput.press('ControlOrMeta+A');await page.keyboard.type('4 8');await dashInput.press('Enter');await dashInput.press('Tab');assert.equal(await dashInput.inputValue(),'');assert((await dash.locator('[data-property-row-message]').innerText()).length>0);
 await unsupportedUnchanged();record('unsupported Stroke position and dash pointer/keyboard refuse without local value/source/catalog/preview/history success');
 await page.locator('[data-inspector-section-header="stroke"]').click();
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

 // Header slots have no Add capability. Physical pointer and activation keys
 // must refuse independently of the working body editors/configuration.
 const headerPreview=()=>page.evaluate(()=>{const frame=[...document.querySelectorAll('iframe')].find(frame=>frame.getClientRects().length&&frame.contentWindow?.__isonimSelectedElement);if(!frame)throw Error('Actual current preview is required');const doc=frame.contentDocument,node=frame.contentWindow.__isonimSelectedElement;return{selected:node.dataset.isonimElementId,html:doc.documentElement.outerHTML,rules:[...doc.styleSheets].map(sheet=>[...sheet.cssRules].map(rule=>rule.cssText))};});
 await page.mouse.move(0,0);await page.evaluate(()=>new Promise(resolve=>requestAnimationFrame(()=>requestAnimationFrame(resolve))));
 const headerBefore={source:source(),catalog:readFileSync(project+'/.isonim/catalog.json','utf8'),state:await snapshot(),preview:await headerPreview(),requests:proof.sourceRequests.length};assert(Number.isInteger(headerBefore.state.undoCount));assert(Number.isInteger(headerBefore.state.redoCount));
 const headerUnchanged=async()=>{assert.equal(source(),headerBefore.source);assert.equal(readFileSync(project+'/.isonim/catalog.json','utf8'),headerBefore.catalog);assert.deepEqual(await snapshot(),headerBefore.state);assert.deepEqual(await headerPreview(),headerBefore.preview);assert.equal(proof.sourceRequests.length,headerBefore.requests);};
 proof.headerAddRefusals=[];
 for(const slug of ['fill','stroke','effects','export']){
  const header=page.locator('[data-inspector-section-header="'+slug+'"]'),add=header.locator('[data-inspector-section-action="add"]'),expanded=await header.getAttribute('aria-expanded');
  await add.scrollIntoViewIfNeeded();await page.mouse.move(0,0);await page.evaluate(()=>new Promise(resolve=>requestAnimationFrame(()=>requestAnimationFrame(resolve))));const idleColors=await add.evaluate(node=>({background:getComputedStyle(node).backgroundColor,color:getComputedStyle(node).color}));const box=await add.boundingBox();assert(box);await page.mouse.click(box.x+box.width/2,box.y+box.height/2);
  const observed={slug,expanded,disabled:await add.getAttribute('aria-disabled'),reason:await add.getAttribute('title'),cursor:await add.evaluate(node=>getComputedStyle(node).cursor),hoverColors:await add.evaluate(node=>({background:getComputedStyle(node).backgroundColor,color:getComputedStyle(node).color})),idleColors,pointerExpanded:await header.getAttribute('aria-expanded'),keys:[]};proof.headerAddRefusals.push(observed);assert.equal(observed.pointerExpanded,expanded);await headerUnchanged();
  for(const key of ['Enter','Space','a','ArrowDown','Tab','Shift+Tab','Escape']){await add.focus();await page.keyboard.press(key);observed.keys.push({key,expanded:await header.getAttribute('aria-expanded')});writeFileSync(root+'/header-add-refusals.json',JSON.stringify(proof.headerAddRefusals,null,2));assert.equal(observed.keys.at(-1).expanded,expanded,'Unsupported '+slug+' header Add must not toggle its section on '+key);await headerUnchanged();if(key==='Tab'||key==='Shift+Tab')assert.equal(await add.evaluate(node=>document.activeElement===node),false,'Unavailable Add retains natural Tab traversal');}
  assert.equal(observed.disabled,'true');assert(observed.reason?.startsWith('Adding another '));assert.equal(observed.cursor,'default');assert.deepEqual(observed.hoverColors,observed.idleColors,'Unavailable header Add must not receive enabled hover styling');
 }
 record('all four unsupported header Add pointer and keys retain expansion/full source/catalog/preview/selection/undo/redo and natural Tab');

 // Export settings are local configuration, not a generated-file or source
 // transaction. Exercise actual native key defaults and physical input while
 // retaining the complete real source/catalog/preview/inspector history state.
 const exportHeader=page.locator('[data-inspector-section-header="export"]');if(await exportHeader.getAttribute('aria-expanded')==='false')await exportHeader.click();
 const exportBody=page.locator('[data-inspector-section-body="export"]'),exportAdd=exportBody.locator('[data-export-add]');
 await page.mouse.move(0,0);await page.evaluate(()=>new Promise(resolve=>requestAnimationFrame(()=>requestAnimationFrame(resolve))));
 const exportBefore={source:source(),catalog:readFileSync(project+'/.isonim/catalog.json','utf8'),state:await snapshot(),preview:await headerPreview(),requests:proof.sourceRequests.length};assert(Number.isInteger(exportBefore.state.undoCount));assert(Number.isInteger(exportBefore.state.redoCount));
 const exportUnchanged=async()=>{assert.equal(source(),exportBefore.source);assert.equal(readFileSync(project+'/.isonim/catalog.json','utf8'),exportBefore.catalog);assert.deepEqual(await snapshot(),exportBefore.state);assert.deepEqual(await headerPreview(),exportBefore.preview);assert.equal(proof.sourceRequests.length,exportBefore.requests);assert.equal(await exportHeader.getAttribute('aria-expanded'),'true');};
 const exportConfig=()=>exportBody.evaluate(body=>[...body.querySelectorAll('[data-export-row]')].map(row=>({size:row.querySelector('[data-export-row-size]').textContent,format:row.querySelector('[data-export-row-format]').textContent,suffix:row.querySelector('[data-export-row-suffix]').value})));
 proof.exportKeys=[];
 for(const key of ['Tab','Shift+Tab','Escape','a','ArrowDown']){await exportAdd.focus();const before=await exportConfig();await page.keyboard.press(key);const after=await exportConfig();proof.exportKeys.push({control:'add',key,before,after});writeFileSync(root+'/export-keyboard.json',JSON.stringify(proof.exportKeys,null,2));assert.deepEqual(after,before,'Export Add must ignore nonactivation '+key);await exportUnchanged();if(key==='Tab'||key==='Shift+Tab')assert.equal(await exportAdd.evaluate(node=>document.activeElement===node),false);}
 assert.equal(await exportAdd.evaluate(node=>node.tagName),'BUTTON');assert.equal(await exportAdd.getAttribute('type'),'button');
 await exportAdd.focus();await page.keyboard.press('Enter');assert.deepEqual(await exportConfig(),[{size:'1x',format:'PNG',suffix:''}]);assert(await exportAdd.evaluate(node=>document.activeElement===node));await exportUnchanged();
 const size=exportBody.locator('[data-export-row-size="0"]'),format=exportBody.locator('[data-export-row-format="0"]'),suffix=exportBody.locator('[data-export-row-suffix="0"]');
 const sizeIdentity=await size.elementHandle();await size.focus();
 for(const [key,value] of [['Enter','2x'],['Space','3x'],['Enter','1x']]){await page.keyboard.press(key);assert.equal(await size.textContent(),value);assert(await sizeIdentity.evaluate(node=>node.isConnected&&document.activeElement===node),'Size cycles retain the exact focused native button');await exportUnchanged();}
 const formatIdentity=await format.elementHandle();await format.focus();
 for(const [key,value] of [['Space','SVG'],['Enter','PDF'],['Space','PNG']]){await page.keyboard.press(key);assert.equal(await format.textContent(),value);assert(await formatIdentity.evaluate(node=>node.isConnected&&document.activeElement===node),'Format cycles retain the exact focused native button');await exportUnchanged();}
 for(const control of [size,format])for(const key of ['Escape','a','ArrowDown','Tab','Shift+Tab']){await control.focus();const before=await exportConfig();await page.keyboard.press(key);assert.deepEqual(await exportConfig(),before);await exportUnchanged();if(key==='Tab'||key==='Shift+Tab')assert.equal(await control.evaluate(node=>document.activeElement===node),false);}
 const suffixIdentity=await suffix.elementHandle();await suffix.fill('-wide');await suffix.press('Tab');assert.deepEqual(await exportConfig(),[{size:'1x',format:'PNG',suffix:'-wide'}]);assert(await suffixIdentity.evaluate(node=>node.isConnected));await exportUnchanged();
 await size.click();await format.click();assert.deepEqual(await exportConfig(),[{size:'2x',format:'SVG',suffix:'-wide'}]);await exportUnchanged();
 await exportAdd.focus();await page.keyboard.press('Space');assert.deepEqual(await exportConfig(),[{size:'2x',format:'SVG',suffix:'-wide'},{size:'1x',format:'PNG',suffix:''}]);assert(await exportAdd.evaluate(node=>document.activeElement===node));await exportUnchanged();
 const secondDelete=exportBody.locator('[data-export-row-delete="1"]');
 for(const key of ['Escape','a','ArrowDown','Tab','Shift+Tab']){await secondDelete.focus();const before=await exportConfig();await page.keyboard.press(key);assert.deepEqual(await exportConfig(),before);await exportUnchanged();if(key==='Tab'||key==='Shift+Tab')assert.equal(await secondDelete.evaluate(node=>document.activeElement===node),false);}
 await secondDelete.focus();await page.keyboard.press('Space');assert.deepEqual(await exportConfig(),[{size:'2x',format:'SVG',suffix:'-wide'}]);assert(await exportBody.locator('[data-export-row-delete="0"]').evaluate(node=>document.activeElement===node));await exportUnchanged();
 await page.keyboard.press('Enter');assert.deepEqual(await exportConfig(),[]);assert(await exportAdd.evaluate(node=>document.activeElement===node));await exportUnchanged();
 await exportAdd.click();assert.deepEqual(await exportConfig(),[{size:'1x',format:'PNG',suffix:''}]);await exportBody.locator('[data-export-row-delete="0"]').click();assert.deepEqual(await exportConfig(),[]);assert(await exportAdd.evaluate(node=>document.activeElement===node));await exportUnchanged();
 await exportAdd.click();await exportHeader.focus();const programmaticDelete=await exportBody.locator('[data-export-row-delete="0"]').evaluate(node=>{const before=document.activeElement;node.click();return document.activeElement===before;});assert(programmaticDelete,'Programmatic deletion must not steal unrelated header focus');assert.deepEqual(await exportConfig(),[]);await exportUnchanged();
 record('real Export local configuration native keys/pointer/presets/suffix/delete retain focus/natural Tab and full source/catalog/preview/undo/redo');
 // Literal alpha and a unique editable owner come from the actual compiled
 // source. The default source host persists metadata separately and confirms
 // unlink through the actual native source/compiler transaction.
 await page.evaluate(()=>window.__popupAcceptance.openStory('Card','default ready'));
 await page.waitForFunction(()=>[...document.querySelectorAll('iframe')].some(frame=>frame.getClientRects().length&&frame.contentDocument?.querySelector('#secondary-action')));
 await page.locator('[data-scene-graph-row="secondary-action"]').click();
 const selectionColorsHeader=page.locator('[data-inspector-section-header="selection-colors"]');
 if(await selectionColorsHeader.getAttribute('aria-expanded')==='false')await selectionColorsHeader.click();
 const colorsBody=page.locator('[data-inspector-section-body="selection-colors"]');
 const alphaIndex=await colorsBody.evaluate(body=>[...body.querySelectorAll('[data-selection-color-row]')].find(row=>getComputedStyle(row.querySelector('[data-selection-color-swatch]')).backgroundColor==='rgba(18, 52, 86, 0.5)')?.getAttribute('data-selection-color-row'));
 assert.notEqual(alphaIndex,undefined,'Actual authored translucent document color must be inspected');
 const alphaRow=colorsBody.locator('[data-selection-color-property="background-color"]'),colorBind=alphaRow.locator('[data-selection-color-bind]');
 await page.evaluate(()=>window.__popupAcceptance.tokens());
 const observedAlpha=await alphaRow.locator('[data-selection-color-opacity]').textContent();
 await colorBind.focus();await page.keyboard.press('Enter');
 const observedPicker=await page.locator('[data-variable-picker-open="true"]').count();
 proof.selectionColorOracles={observedAlpha,observedPicker};writeFileSync(root+'/selection-color-oracles.json',JSON.stringify(proof.selectionColorOracles,null,2));
 assert.equal(observedAlpha,'50%');assert.equal(observedPicker,1);assert.equal(await alphaRow.locator('[data-selection-color-hex]').textContent(),'#123456');assert.equal(await alphaRow.getAttribute('data-selection-color-property'),'background-color');
 await page.keyboard.press('Escape');assert(await colorBind.evaluate(node=>document.activeElement===node));
 await page.mouse.move(0,0);await page.evaluate(()=>new Promise(resolve=>requestAnimationFrame(()=>requestAnimationFrame(resolve))));
 const colorsBefore={source:source(),catalog:readFileSync(project+'/.isonim/catalog.json','utf8'),state:await snapshot(),preview:await headerPreview(),requests:proof.sourceRequests.length};assert(Number.isInteger(colorsBefore.state.undoCount));assert(Number.isInteger(colorsBefore.state.redoCount));
 const colorFilesUnchanged=async()=>{assert.equal(source(),colorsBefore.source);assert.equal(readFileSync(project+'/.isonim/catalog.json','utf8'),colorsBefore.catalog);assert.equal(proof.sourceRequests.length,colorsBefore.requests);};
 const colorsUnchanged=async()=>{await colorFilesUnchanged();assert.deepEqual(await snapshot(),colorsBefore.state);assert.deepEqual(await headerPreview(),colorsBefore.preview);};
 for(const key of ['Tab','Shift+Tab','Escape','a','ArrowDown']){await colorBind.focus();await page.keyboard.press(key);assert.equal(await page.locator('[data-variable-picker-open="true"]').count(),0);await colorsUnchanged();if(key==='Tab'||key==='Shift+Tab')assert(!await colorBind.evaluate(node=>document.activeElement===node));}
 for(const activation of ['Space','pointer']){if(activation==='pointer')await colorBind.click();else{await colorBind.focus();await page.keyboard.press(activation);}const popup=page.locator('[data-variable-picker-open="true"]');assert.equal(await popup.count(),1);assert.equal(await popup.locator('[data-variable-picker-row]').count(),90);await popup.locator('[data-variable-picker-row="color/test-0"]').focus();await page.keyboard.press('Tab');assert(await popup.evaluate(node=>node.contains(document.activeElement)));await page.keyboard.press('Escape');assert(await colorBind.evaluate(node=>document.activeElement===node));await colorsUnchanged();}
 await colorBind.focus();await page.keyboard.press('Enter');
 const compatiblePicker=page.locator('[data-variable-picker-open="true"]');await compatiblePicker.locator('[data-variable-picker-row="color/test-0"]').focus();await page.keyboard.press('Space');
 await page.waitForFunction(()=>!globalThis.__isonimEditorVm.sourceBindingMetadataDirty.value&&!globalThis.__isonimEditorVm.sourceBindingMetadataSaving);
 assert.equal((await snapshot()).bindings['background-color'],'color/test-0');
 assert.equal(proof.sourceRequests.length,colorsBefore.requests+1);colorsBefore.requests=proof.sourceRequests.length;
 assert(JSON.parse(readFileSync(project+'/.isonim/bindings.json','utf8')).variableBindings.some(binding=>binding.elementId==='secondary-action'&&binding.propertyName==='background-color'&&binding.variableKey==='color/test-0'));
 const alphaChip=alphaRow.locator('[data-selection-color-linked-chip]'),alphaChevron=alphaChip.locator('[data-variable-chip-chevron]'),alphaDetach=alphaChip.locator('[data-variable-chip-detach]');
 assert.equal(await alphaChip.locator('[data-variable-chip-name]').getAttribute('aria-disabled'),'true');assert.equal(await alphaChip.locator('[data-variable-chip-name]').getAttribute('tabindex'),'-1');
 await page.mouse.move(0,0);await alphaChevron.focus();
 assert(await alphaDetach.isVisible(),'Keyboard focus reveals the real unlink action');
 await page.keyboard.press('Shift+Tab');assert(await alphaDetach.evaluate(node=>document.activeElement===node),'Reverse natural Tab reaches preceding detach');
 await page.keyboard.press('Tab');assert(await alphaChevron.evaluate(node=>document.activeElement===node),'Forward natural Tab returns to chevron without hiding focused actions');
 const linkedBefore=await snapshot();assert.equal(linkedBefore.undoCount,colorsBefore.state.undoCount);assert.equal(linkedBefore.redoCount,colorsBefore.state.redoCount);assert.equal(linkedBefore.sourcePlans,colorsBefore.state.sourcePlans);
 for(const key of ['Tab','Shift+Tab','Escape','a','ArrowDown']){await alphaDetach.focus();await page.keyboard.press(key);assert.deepEqual(await snapshot(),linkedBefore,'Nonactivation key must preserve the complete binding/history/source state');await colorFilesUnchanged();assert.deepEqual(await headerPreview(),colorsBefore.preview);if(key==='Tab'||key==='Shift+Tab')assert(!await alphaDetach.evaluate(node=>document.activeElement===node));}
 // A real persisted link remains readable when permission changes, while every
 // child action is visibly and semantically unavailable and cannot mutate it.
 await page.evaluate(()=>window.__popupAcceptance.readOnly(true));await alphaChip.hover();
 const readonlyBefore=await snapshot();
 for(const attr of ['name','chevron','detach']){const action=alphaChip.locator('[data-variable-chip-'+attr+']');assert.equal(await action.getAttribute('aria-disabled'),'true');assert.equal(await action.getAttribute('tabindex'),'-1');assert((await action.getAttribute('title')).length>0);assert.equal(await action.evaluate(node=>getComputedStyle(node).cursor),'default');await alphaChip.hover();const box=await action.boundingBox();assert(box);await page.mouse.click(box.x+box.width/2,box.y+box.height/2);for(const key of ['Enter','Space','Tab','Escape','a']){await action.focus();await page.keyboard.press(key);assert.deepEqual(await snapshot(),readonlyBefore);assert.equal(await page.locator('[data-variable-picker-open="true"]').count(),0);await colorFilesUnchanged();}}
 assert((await alphaRow.locator('[data-selection-color-reason]').innerText()).length>0);
 await page.evaluate(()=>window.__popupAcceptance.readOnly(false));await page.mouse.move(0,0);
 // Repeated selection replaces owned row roots; a stale detached DOM control
 // cannot open a picker or detach a binding belonging to a later selection.
 const staleChevron=await alphaChevron.elementHandle(),staleDetach=await alphaDetach.elementHandle();
 const selectedObservers=(await snapshot()).reactiveObservers;
 for(let cycle=0;cycle<3;cycle++){await page.locator('[data-scene-graph-row="action"]').click();const state=await snapshot();await staleChevron.evaluate(node=>node.click());await staleDetach.evaluate(node=>node.click());assert.deepEqual(await snapshot(),state);assert.equal(await page.locator('[data-variable-picker-open="true"]').count(),0);await page.locator('[data-scene-graph-row="secondary-action"]').click();assert.equal((await snapshot()).bindings['background-color'],'color/test-0');assert.deepEqual((await snapshot()).reactiveObservers,selectedObservers);await colorFilesUnchanged();}
 // First unlink persists the actual resolved source literal and compiler
 // preview. A later equal authored literal is a source no-op; metadata/history
 // still persist without inventing a source undo or pending owner plan.
 for(const [key,token] of [['Enter','color/test-0'],['Space','color/test-1']]){
  await alphaChevron.focus();await page.keyboard.press('Enter');const popup=page.locator('[data-variable-picker-open="true"]');await popup.locator('[data-variable-picker-row="'+token+'"]').click();
  await page.waitForFunction(()=>!globalThis.__isonimEditorVm.sourceBindingMetadataDirty.value&&!globalThis.__isonimEditorVm.sourceBindingMetadataSaving);
  const before=await snapshot(),beforeSource=source(),beforeCatalog=readFileSync(project+'/.isonim/catalog.json','utf8'),beforeRequests=proof.sourceRequests.length;
  await alphaChevron.focus();await page.keyboard.press('Shift+Tab');await page.keyboard.press(key);
  await page.waitForFunction(()=>{const state=JSON.parse(window.__popupAcceptance.snapshot());return state.bindings['background-color']===''&&!globalThis.__isonimEditorVm.sourceBindingMetadataDirty.value&&!globalThis.__isonimEditorVm.sourceBindingMetadataSaving&&!globalThis.__isonimEditorVm.sourceProjectBuildInFlight;},null,{timeout:70000});
  const detached=await snapshot();proof.selectionColorUnlinks??=[];proof.selectionColorUnlinks.push({key,token,before,detached});writeFileSync(root+'/selection-color-unlinks.json',JSON.stringify(proof.selectionColorUnlinks,null,2));
  assert.equal(detached.bindings['background-color'],'');assert.equal(detached.undoCount,before.undoCount+(key==='Enter'?1:0));assert.equal(detached.redoCount,0);assert.equal(detached.sourcePlans,before.sourcePlans);
  assert.equal(detached.properties.find(property=>property.name==='background-color').value,'rgb(17, 34, 51)');
  assert.equal(proof.sourceRequests.length,beforeRequests+2);
  if(key==='Enter'){assert.equal(source(),beforeSource.replace('background-color:rgba(18,52,86,0.5);','background-color:#112233;'));assert.notEqual(readFileSync(project+'/.isonim/catalog.json','utf8'),beforeCatalog);}
  else {assert.equal(source(),beforeSource);assert.equal(readFileSync(project+'/.isonim/catalog.json','utf8'),beforeCatalog);}
  await page.waitForFunction(()=>[...document.querySelectorAll('iframe')].some(frame=>frame.getClientRects().length&&frame.contentDocument?.querySelector('#secondary-action')&&frame.contentWindow.getComputedStyle(frame.contentDocument.querySelector('#secondary-action')).backgroundColor==='rgb(17, 34, 51)'));
  const metadata=JSON.parse(readFileSync(project+'/.isonim/bindings.json','utf8'));assert(!metadata.variableBindings.some(binding=>binding.elementId==='secondary-action'&&binding.propertyName==='background-color'));assert.equal(metadata.variableBindingHistory.find(binding=>binding.elementId==='secondary-action'&&binding.propertyName==='background-color').variableKeys[0],token);
  assert.equal(await colorsBody.locator('[data-selection-color-property="background-color"] [data-selection-color-linked-chip]').count(),0);
  proof.relinkOwnerBefore={row:await alphaRow.evaluate(node=>node.outerHTML),state:await snapshot(),tokenCount:await page.evaluate(()=>globalThis.__isonimEditorVm.foundations.tokens.value.length)};writeFileSync(root+'/relink-owner.json',JSON.stringify(proof.relinkOwnerBefore,null,2));assert.equal(proof.relinkOwnerBefore.tokenCount,90,'Declared fixture tokens must survive real source catalog reload');
  await colorBind.click();proof.relinkOwnerBefore.afterClick={row:await alphaRow.evaluate(node=>node.outerHTML),pickerCount:await page.locator('[data-variable-picker-open="true"]').count(),state:await snapshot()};writeFileSync(root+'/relink-owner.json',JSON.stringify(proof.relinkOwnerBefore,null,2));await page.locator('[data-variable-picker-open="true"] [data-variable-picker-row="'+token+'"]').click();await page.waitForFunction(()=>!globalThis.__isonimEditorVm.sourceBindingMetadataDirty.value&&!globalThis.__isonimEditorVm.sourceBindingMetadataSaving);
  colorsBefore.source=source();colorsBefore.catalog=readFileSync(project+'/.isonim/catalog.json','utf8');colorsBefore.requests=proof.sourceRequests.length;
 }
 const ambiguity=colorsBody.locator('[data-selection-color-row]').filter({hasText:'multiple properties'});assert(await ambiguity.count()>0);const ambiguous=ambiguity.first(),ambiguousBind=ambiguous.locator('[data-selection-color-bind]');assert.equal(await ambiguousBind.getAttribute('aria-disabled'),'true');const ambiguousBefore=await snapshot();await ambiguousBind.scrollIntoViewIfNeeded();const ambiguousBox=await ambiguousBind.boundingBox();assert(ambiguousBox);await page.mouse.click(ambiguousBox.x+ambiguousBox.width/2,ambiguousBox.y+ambiguousBox.height/2);for(const key of ['Enter','Space','Tab','Escape']){await ambiguousBind.focus();await page.keyboard.press(key);assert.deepEqual(await snapshot(),ambiguousBefore);assert.equal(await page.locator('[data-variable-picker-open="true"]').count(),0);await colorFilesUnchanged();}
 proof.selectionColorsFinal=await snapshot();
 record('Selection Colors actual alpha/unique compatible binding/natural keys/read-only ambiguity/stale selection persist metadata and native unlink source/catalog');

 assert.deepEqual(proof.errors,[]);assert.deepEqual(proof.agentRequests,[]);writeFileSync(root+'/proof.json',JSON.stringify(proof,null,2));console.log('Inspector compound GUI passed:',root,proof.cases.length);
} finally {
 if(browser)await browser.close();if(browserServer)await browserServer.close();
 server.kill('SIGTERM');await new Promise(resolve=>{if(server.exitCode!==null)return resolve();server.once('exit',resolve);setTimeout(()=>{server.kill('SIGKILL');resolve();},15000).unref();});
 writeFileSync(root+'/proof-final.json',JSON.stringify(proof,null,2));
}
