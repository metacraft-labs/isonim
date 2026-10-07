/** Mounted full production editor, real temporary source copy/native SSR compiler,
 * real inspector/DOM/preview and actual controls. No renderer or source/compiler
 * boundary is mocked. The configured editor_control_peer.py is a controlled
 * decision peer solely to satisfy daemon startup, because these scenarios make
 * no agent requests; that zero count is asserted. This suite does not prove
 * Harbor integration (official real Harbor scenario E2E remains separate).
 * Focus availability conditions use actual DOM disabled/hidden/inert state;
 * focus/network/listener audits forward native operations without substitutions. Foundation metadata is ordinary fixture data only; the
 * project's genuine read-only permission is explicitly tested as refusal.
 * Accepted file writes are covered by the separately registered real consumer
 * adapter test. Test-only anchor relocation uses the original mounted invoker,
 * never a synthetic popup/HTML renderer. Every run uses an isolated port/project.
 */
import {spawn,spawnSync} from 'node:child_process';
import {mkdtempSync,cpSync,readFileSync,writeFileSync,mkdirSync,openSync,copyFileSync,existsSync} from 'node:fs';
import {chromium} from '../node_modules/playwright/index.mjs';
import assert from 'node:assert/strict';
import path from 'node:path';
import {tmpdir} from 'node:os';
import {fileURLToPath} from 'node:url';
import {createHash} from 'node:crypto';
const repo=path.resolve(path.dirname(fileURLToPath(import.meta.url)), '..');
const base=process.env.ISONIM_POPUP_ARTIFACTS || tmpdir();
const bundle=path.resolve(process.env.ISONIM_POPUP_BUILD || path.join(repo,'build/editor-popup/editor.js'));
assert(existsSync(bundle),'Run just editor-popup-build before mounted popup acceptance');
const root=mkdtempSync(base+'/actual-gui-'),project=root+'/project',pub=root+'/public';
cpSync(repo+'/examples/source_project',project,{recursive:true,filter:p=>!p.includes('catalog-producer')});mkdirSync(pub);
for(const [from,to] of [['src/isonim/editor/index.html','index.html'],['node_modules/fabric/dist/index.min.js','fabric.min.js'],['node_modules/paper/dist/paper-core.min.js','paper-core.min.js'],['node_modules/svgo/dist/svgo.browser.js','svgo.browser.js']])copyFileSync(repo+'/'+from,pub+'/'+to);
copyFileSync(bundle,pub+'/editor.js');
const hash=text=>createHash('sha256').update(text).digest('hex');
const verifyNativeDeliveries=(events,deliveries)=>{
 assert(events.length>0,'Actual iframe stimulus must emit native selection events');
 assert.equal(deliveries.length,events.length,'Each native event must produce one actual production delivery');
 for(const event of events){
  const matching=deliveries.filter(delivery=>delivery.eventId===event.eventId);
  assert.equal(matching.length,1,'Native event '+event.eventId+' must be delivered exactly once');
  assert.equal(matching[0].id,event.id);assert(matching[0].connected&&matching[0].visible);
 }
};
const beforeSourceHash=hash(readFileSync(project+'/stories.nim'));
const proof={bundleSha256:hash(readFileSync(pub+'/editor.js')),sourceRoot:project,cases:[],pageErrors:[],agentRequests:[]};
let src=readFileSync(project+'/stories.nim','utf8').replace('button(id = "action",','button(style = "background-color:#112233", id = "action",');
src=src.replace('var stories = newJArray()',`var stories = newJArray()\nfor i in 0 ..< 100:\n  stories.add(%* {"group": "Card", "name": "long story " & $i, "kind": "component", "documentHtml": card("Ready card")})`);
src=src.replace('          button(style',`          for i in 0 ..< 100:\n            tdiv(\`data-isonim-element-id\` = "long-layer-" & $i):\n              span(id = "long-text-" & $i, \`data-isonim-element-id\` = "long-text-" & $i, style = "color:#334455"): text "Long layer " & $i\n          button(style`);
writeFileSync(project+'/stories.nim',src);writeFileSync(root+'/source-before.nim',src);
const build=spawnSync('python3',[repo+'/tools/build_source_catalog.py',project],{env:{...process.env,ISONIM_SOURCE_FRAMEWORK:repo},encoding:'utf8',timeout:70000});
writeFileSync(root+'/catalog-build.log',(build.stdout||'')+(build.stderr||''));
if(build.status!==0)throw Error('Actual catalog build failed: '+build.status+' '+build.stderr);
const config=root+'/agent.toml';writeFileSync(config,'[agent]\nbackend="custom"\ncommand="python3"\nargs=["'+repo+'/tests/helpers/editor_control_peer.py"]\nprimer_enabled=false\n');
const server=spawn('python3',[repo+'/tools/editor_server.py','--directory',pub,'--project-root',project,'--port','0','--bind','127.0.0.1','--config',config,'--daemon-binary',repo+'/build/bin/isonim-review'],{env:{...process.env,ISONIM_SOURCE_FRAMEWORK:repo},stdio:['ignore','pipe',openSync(root+'/server.log','w')]});
let browser,browserServer;
const bounded=(promise,label,ms=30000)=>new Promise((resolve,reject)=>{
 const timer=setTimeout(()=>reject(Error(label+' exceeded '+ms+'ms')),ms);
 promise.then(value=>{clearTimeout(timer);resolve(value);},error=>{clearTimeout(timer);reject(error);});
});
// Retain every completed case even if Chromium stops servicing protocol calls.
const appendCase=proof.cases.push.bind(proof.cases);
proof.cases.push=(...items)=>{const length=appendCase(...items);writeFileSync(root+'/proof-partial.json',JSON.stringify(proof,null,2));return length;};
try{
 const origin=await new Promise((resolve,reject)=>{let out='';server.stdout.on('data',c=>{out+=c;const m=out.match(/Editor listening on (http:\/\/[^\s]+)\//);if(m)resolve(m[1]);});server.once('exit',code=>reject(Error('server exit '+code)));setTimeout(()=>reject(Error('startup timeout')),70000).unref();});
 const env={...process.env};delete env.LD_LIBRARY_PATH;browserServer=await chromium.launchServer({headless:true,env,executablePath:process.env.PLAYWRIGHT_CHROMIUM_EXECUTABLE});browser=await chromium.connect(browserServer.wsEndpoint());
 for (const width of [1440, 900]) {
  const page=await browser.newPage({viewport:{width,height:900}});
  page.setDefaultTimeout(30000);
  const evaluate=page.evaluate.bind(page);
  page.evaluate=(...args)=>bounded(evaluate(...args),'Actual editor runtime evaluation');
  page.on('pageerror',e=>proof.pageErrors.push(e.message));
  await page.addInitScript(()=>{
    // Audit actual production registrations/resources. Native event callbacks
    // and geometry are unchanged; timer/observer audits forward native work.
    const registrations=[],pending=new Map(),observers=new Set(),restoreLoads=new Set();
    window.__actualRestorationLoads=()=>[...restoreLoads].map(entry=>({connected:entry.target.isConnected,disposed:!!entry.target.__isonimViewDisposed}));
    window.__actualRestorationLoadsFor=frame=>[...restoreLoads].filter(entry=>entry.target===frame).length;
    window.__actualRestorationTimerIds=()=>[...pending.entries()].filter(([key,entry])=>entry.stack.includes('restorePreviewSelection')).map(([key])=>key);
    window.__actualLayerPolls=0;
    const addEvent=EventTarget.prototype.addEventListener,removeEvent=EventTarget.prototype.removeEventListener;
    const production=stack=>stack.includes('/editor.js');
    const capture=options=>typeof options==='boolean'?options:!!options?.capture;
    EventTarget.prototype.addEventListener=function(type,fn,options){
      const stack=new Error().stack||'';
      if(this instanceof HTMLIFrameElement&&type==='load'&&fn?.name==='loaded')restoreLoads.add({target:this,fn});
      if((this===window||this===document)&&production(stack)&&!registrations.some(r=>r.target===this&&r.type===type&&r.fn===fn&&r.capture===capture(options)))registrations.push({target:this,type,fn,capture:capture(options),stack});
      return addEvent.call(this,type,fn,options);
    };
    EventTarget.prototype.removeEventListener=function(type,fn,options){
      for(const entry of restoreLoads)if(entry.target===this&&entry.fn===fn)restoreLoads.delete(entry);
      const index=registrations.findIndex(r=>r.target===this&&r.type===type&&r.fn===fn&&r.capture===capture(options));
      if(index>=0)registrations.splice(index,1);
      return removeEvent.call(this,type,fn,options);
    };
    for(const [schedule,cancel,repeat] of [['setTimeout','clearTimeout',false],['setInterval','clearInterval',true],['requestAnimationFrame','cancelAnimationFrame',false]]){
      const native=window[schedule],clear=window[cancel];
      window[schedule]=function(callback,...args){
        const stack=new Error().stack||'';let id;
        const forwarded=typeof callback==='function'?function(...values){if(!repeat)pending.delete(schedule+':'+id);if(repeat&&args[0]===700&&callback.toString().includes('previewDoc()'))window.__actualLayerPolls++;return callback.apply(this,values);}:callback;
        id=native.call(this,forwarded,...args);
        if(production(stack))pending.set(schedule+':'+id,{schedule,stack});
        return id;
      };
      window[cancel]=function(id){pending.delete(schedule+':'+id);return clear.call(this,id);};
    }
    for(const name of ['MutationObserver','ResizeObserver']){
      const Native=window[name];
      window[name]=class extends Native{
        constructor(callback){super(callback);this.auditStack=new Error().stack||'';}
        observe(...args){if(production(this.auditStack))observers.add(this);return super.observe(...args);}
        disconnect(){observers.delete(this);return super.disconnect();}
      };
    }
    window.__actualUiResources=()=>({listeners:registrations.map(r=>({type:r.type,target:r.target===window?'window':'document',name:r.fn?.name||'',stack:r.stack})),pending:[...pending.values()],observers:[...observers].map(o=>({type:o.constructor.name,stack:o.auditStack}))});
    const listeners=new Set(),add=Document.prototype.addEventListener,remove=Document.prototype.removeEventListener;
    Document.prototype.addEventListener=function(type,fn,...rest){if((type==='keydown'&&fn?.name==='key')||(type==='pointerdown'&&fn?.name==='pointer'))listeners.add(fn);return add.call(this,type,fn,...rest);};
    Document.prototype.removeEventListener=function(type,fn,...rest){listeners.delete(fn);return remove.call(this,type,fn,...rest);};
    window.__actualPopoverListenerCount=()=>listeners.size;
    window.__nativeSelectionIdentities=new WeakMap();window.__nativeSelectionEvents=[];let selectionSerial=0;
    window.__actualSelectionEvents=[];window.addEventListener('isonim-preview-element-selected',event=>{
      if(!window.__nativeSelectionIdentities.has(event))window.__nativeSelectionIdentities.set(event,++selectionSerial);
      window.__nativeSelectionEvents.push({eventId:window.__nativeSelectionIdentities.get(event),id:event.detail.elementId});
      window.__actualSelectionEvents.push({id:event.detail.elementId,backgroundColor:event.detail.backgroundColor,before:JSON.parse(window.__popupAcceptance.snapshot())});},true);});
  page.on('request',request=>{if(new URL(request.url()).pathname.startsWith('/api/agent/'))proof.agentRequests.push({method:request.method(),url:request.url()});});
  await page.goto(origin);
  await page.waitForFunction(()=>!!window.__popupAcceptance);
  await page.locator('[data-scene-graph-row="action"]').waitFor();

  await page.locator('[data-toolbar-cluster="mode"] [aria-label="Edit"]').click();
  const ready=async()=>page.waitForFunction(()=>Array.from(document.querySelectorAll('.editor-preview iframe')).some(frame=>frame.getClientRects().length&&typeof frame.contentWindow?.__isonimRestoreSelection==='function'));
  await ready();
  await page.evaluate(()=>{
    window.__restoreTrace=[];window.__restoreDocuments=new WeakMap();window.__restoreDocumentSerial=0;
    window.__auditRestoration=()=>{
      for(const frame of document.querySelectorAll('.editor-preview iframe')){
        const doc=frame.contentDocument,win=frame.contentWindow,native=win?.__isonimRestoreSelection;
        if(!native||win.__restorationAudited)continue;
        win.__restorationAudited=true;
        if(!window.__restoreDocuments.has(doc))window.__restoreDocuments.set(doc,++window.__restoreDocumentSerial);
        win.__isonimRestoreSelection=function(id){
          window.__restoreTrace.push({id,selected:JSON.parse(window.__popupAcceptance.snapshot()).selected,document:window.__restoreDocuments.get(doc),liveDocument:frame.contentDocument===doc,view:JSON.parse(window.__popupAcceptance.snapshot()).activeView,connected:frame.isConnected,visible:!!frame.getClientRects().length});
          return native.apply(this,arguments); // Exactly one original call.
        };
      }
    };
    window.__auditRestoration();
    window.__restoreGraph=()=>{
      const vm=[...window.__isonimSceneGraphReaderRuntime.records.keys()][0], result={};
      for(const key of ['selectedElement','designSystemSchema','propertyBindings','properties']){
        const value=vm.inspector[key],signal=value?.observers?value:value?.signal;let bad=0;
        for(let i=0;i<signal.observers.length;i++){const observer=signal.observers[i],slot=signal.observerSlots[i];if(observer.sources[slot]!==signal||observer.sourceSlots[slot]!==i)bad++;}
        result[key]={observers:signal.observers.length,slots:signal.observerSlots.length,bad};
      }
      return result;
    };
  });
  const paired=new Map();
  const assertLatest=async(name)=>{
    await ready();
    await page.evaluate(()=>{
      window.__auditRestoration();window.__restoreTrace=[];
      window.__queuedFirst=window.__popupAcceptance.select('secondary-action');
      window.__queuedSecond=window.__popupAcceptance.select('action');
      document.querySelector('[data-layer-search]').focus();
    });
    await page.waitForTimeout(80);
    const actual=await page.evaluate(()=>{
      const state=JSON.parse(window.__popupAcceptance.snapshot());
      const frame=[...document.querySelectorAll('.editor-preview iframe')].find(f=>f.getClientRects().length);
      return {first:window.__queuedFirst,second:window.__queuedSecond,state,trace:window.__restoreTrace,
        pending:frame.__isonimSelectionRestore?.id||'',selectedDOM:frame.contentDocument.querySelector('[data-isonim-selected="true"]')?.getAttribute('data-isonim-element-id'),
        outline: (()=>{const selected=frame.contentDocument.querySelector('[data-isonim-selected="true"]');const css=selected&&frame.contentWindow.getComputedStyle(selected);return {id:selected?.getAttribute('data-isonim-element-id'),style:css?.outlineStyle,width:css?.outlineWidth};})(),
        searchFocused:document.activeElement===document.querySelector('[data-layer-search]'),graph:window.__restoreGraph()};
    });
    proof.cases.push({width,name,actual});
    assert(actual.first&&actual.second);assert.equal(actual.state.selected,'action');
    assert(actual.trace.length>0,'Must exercise actual production restore callback');
    for(const item of actual.trace){assert.equal(item.id,item.selected,'No obsolete ID may replay');assert(item.liveDocument&&item.connected&&item.visible);}
    assert.equal(actual.pending,'action');assert.equal(actual.selectedDOM,'action');assert.equal(actual.outline.id,'action');assert.notEqual(actual.outline.style,'none');assert(parseFloat(actual.outline.width)>0);
    assert(actual.searchFocused,'Preview restoration preserves newer explicit user focus');
    for(const value of Object.values(actual.graph))assert.equal(value.bad,0,'Actual reciprocal slots remain valid');
    const key=actual.state.activeView;
    if(paired.has(key))assert.deepEqual(actual.graph,paired.get(key),'Repeated same-view queued selection must not grow observers');else paired.set(key,actual.graph);
  };
  await assertLatest('same-task two production selections preserve latest edit selection, outline/inspector, focus and reciprocal graph');
  const cleanupBefore=await page.evaluate(()=>{
    const frame=[...document.querySelectorAll('.editor-preview iframe')].find(frame=>frame.getClientRects().length);
    window.__restoreLifetime=frame.__isonimSelectionRestoreLifetime;
    const lifetime=window.__restoreLifetime;
    return {registrations:lifetime.owner.cleanups.filter(fn=>fn===lifetime.dispose).length,ownerCleanups:lifetime.owner.cleanups.length};
  });
  assert.equal(cleanupBefore.registrations,1,'One real construction-owner cleanup binding');
  await page.evaluate(()=>{for(let i=0;i<12;i++)window.__popupAcceptance.select(i%2?'action':'secondary-action');});
  await page.waitForTimeout(80);
  const cleanupAfter=await page.evaluate(()=>{
    const frame=[...document.querySelectorAll('.editor-preview iframe')].find(frame=>frame.getClientRects().length);
    const lifetime=frame.__isonimSelectionRestoreLifetime;
    return {same:lifetime===window.__restoreLifetime,registrations:lifetime.owner.cleanups.filter(fn=>fn===lifetime.dispose).length,ownerCleanups:lifetime.owner.cleanups.length,selected:JSON.parse(window.__popupAcceptance.snapshot()).selected};
  });
  assert(cleanupAfter.same);assert.equal(cleanupAfter.registrations,1);assert.equal(cleanupAfter.ownerCleanups,cleanupBefore.ownerCleanups);assert.equal(cleanupAfter.selected,'action');
  proof.cases.push({width,name:'twelve same-task selections retain one actual frame-construction owner cleanup',cleanupBefore,cleanupAfter});

  await page.evaluate(()=>{window.__popupAcceptance.select('secondary-action');window.__popupAcceptance.clear();document.querySelector('[data-layer-search]').focus();});
  await page.waitForTimeout(80);
  const cleared=await page.evaluate(()=>({state:JSON.parse(window.__popupAcceptance.snapshot()),pending:window.__isonimPendingPreviewSelectionId,requests:[...document.querySelectorAll('.editor-preview iframe')].filter(frame=>frame.__isonimSelectionRestore).length}));
  assert.equal(cleared.state.selected,'');assert.equal(cleared.pending,'');assert.equal(cleared.requests,0);
  proof.cases.push({width,name:'genuine clear invalidates queued/load/bootstrap request and cannot resurrect selection',cleared});
  await assertLatest('latest selection after genuine clear restores normally');
  // Real srcdoc replacement has a new Document with unchanged source. The
  // latest request's actual load listener must restore the latest ID there.
  const replacement=await page.evaluate(()=>{
    const frame=[...document.querySelectorAll('.editor-preview iframe')].find(f=>f.getClientRects().length);
    window.__replacementDocument=frame.contentDocument;window.__replacementFrame=frame;
    window.__popupAcceptance.select('secondary-action');window.__popupAcceptance.select('action');
    frame.srcdoc=frame.srcdoc;return {beforeDocument:window.__restoreDocuments.get(window.__replacementDocument)};
  });
  await page.waitForFunction(()=>window.__replacementFrame.contentDocument!==window.__replacementDocument&&window.__replacementFrame.contentDocument.querySelector('[data-isonim-element-id="action"][data-isonim-selected="true"]'));
  await assertLatest('real same-source iframe Document replacement retains only valid latest load restoration');
  proof.cases.push({width,name:'actual document identity changed',replacement});
  // Each inverse transition starts in the positively checked OLD view. The
  // actual old request/timer/load listener are captured in the same task before
  // switching and cannot drain between this capture and the cancellation check.
  await page.evaluate(()=>window.__popupAcceptance.activeView(false));
  await ready();await assertLatest('genuine Detail pretransition owner selection/outline and focus');
  const transition=async(from,to,edit)=>{
    const immediate=await page.evaluate(({from,to,edit})=>{
      window.__auditRestoration();window.__restoreTrace=[];
      const oldFrame=[...document.querySelectorAll('.editor-preview iframe')].find(frame=>frame.getClientRects().length);
      const selectedOld=window.__popupAcceptance.select('secondary-action');
      const beforeState=JSON.parse(window.__popupAcceptance.snapshot());
      const oldRequest=oldFrame.__isonimSelectionRestore;
      const oldTimers=window.__actualRestorationTimerIds();
      window.__transitionOldFrame=oldFrame;window.__transitionOldRequest=oldRequest;
      const before={state:beforeState,selectedOld,requestId:oldRequest?.id,valid:!!oldRequest?.valid(),visible:!!oldFrame.getClientRects().length,
        loadListeners:window.__actualRestorationLoadsFor(oldFrame),timerIds:oldTimers,document:window.__restoreDocuments.get(oldFrame.contentDocument)};
      window.__popupAcceptance.activeView(edit);
      const selectedNew=window.__popupAcceptance.select('action');
      document.querySelector('[data-layer-search]').focus();
      const newFrame=[...document.querySelectorAll('.editor-preview iframe')].find(frame=>frame.getClientRects().length);
      const after={state:JSON.parse(window.__popupAcceptance.snapshot()),selectedNew,differentFrame:newFrame!==oldFrame,
        oldVisible:!!oldFrame.getClientRects().length,oldRequestValid:!!oldRequest?.valid(),oldSlotPresent:!!oldFrame.__isonimSelectionRestore,
        oldLoadListeners:window.__actualRestorationLoadsFor(oldFrame),timerIds:window.__actualRestorationTimerIds(),
        newId:newFrame.__isonimSelectionRestore?.id,newValid:!!newFrame.__isonimSelectionRestore?.valid(),newLoadListeners:window.__actualRestorationLoadsFor(newFrame)};
      return {from,to,before,after};
    },{from,to,edit});
    proof.cases.push({width,name:from+' to '+to+' actual pending owner cancellation before timer drain',immediate});
    assert.equal(immediate.before.state.activeView,from);assert.equal(immediate.before.state.selected,'secondary-action');assert(immediate.before.selectedOld&&immediate.before.visible&&immediate.before.valid);
    assert.equal(immediate.before.requestId,'secondary-action');assert.equal(immediate.before.loadListeners,1);assert(immediate.before.timerIds.length>0);
    assert.equal(immediate.after.state.activeView,to);assert.equal(immediate.after.state.selected,'action');assert(immediate.after.selectedNew&&immediate.after.differentFrame);
    assert(!immediate.after.oldVisible&&!immediate.after.oldRequestValid&&!immediate.after.oldSlotPresent);assert.equal(immediate.after.oldLoadListeners,0);
    for(const id of immediate.before.timerIds)assert(!immediate.after.timerIds.includes(id),'Each genuine old timer canceled synchronously');
    assert(immediate.after.timerIds.length>0&&immediate.after.newValid);assert.equal(immediate.after.newId,'action');assert.equal(immediate.after.newLoadListeners,1);
    await page.waitForTimeout(80);
    const delivered=await page.evaluate(()=>({state:JSON.parse(window.__popupAcceptance.snapshot()),trace:window.__restoreTrace,
      oldRequestValid:!!window.__transitionOldRequest?.valid(),oldSlotPresent:!!window.__transitionOldFrame.__isonimSelectionRestore,
      oldLoads:window.__actualRestorationLoadsFor(window.__transitionOldFrame),graph:window.__restoreGraph()}));
    proof.cases.push({width,name:from+' to '+to+' settled actual latest-only delivery with inactive owner refused',delivered});
    assert.equal(delivered.state.activeView,to);assert.equal(delivered.state.selected,'action');assert(delivered.trace.length>0);
    for(const item of delivered.trace){assert.equal(item.id,'action');assert.equal(item.selected,'action');assert.equal(item.view,to);assert(item.visible&&item.liveDocument);assert.notEqual(item.document,immediate.before.document,'Inactive old iframe cannot deliver');}
    assert(!delivered.oldRequestValid&&!delivered.oldSlotPresent);assert.equal(delivered.oldLoads,0);
    for(const value of Object.values(delivered.graph))assert.equal(value.bad,0);
    // No trace reset happens until the forbidden old-delivery oracle above.
    await assertLatest(from+' to '+to+' actual latest outline/DOM/inspector/focus and reciprocal cardinality');
  };
  await transition('evComponentDetail','evComponentEdit',true);
  await transition('evComponentEdit','evComponentDetail',false);
  const before=JSON.parse(await page.evaluate(()=>window.__popupAcceptance.snapshot()));
  await page.evaluate(()=>{window.__beforeHmrFrames=[...document.querySelectorAll('.editor-preview iframe')].filter(frame=>frame.__isonimSelectionRestoreLifetime).map(frame=>({frame,lifetime:frame.__isonimSelectionRestoreLifetime,request:frame.__isonimSelectionRestore,document:frame.contentDocument}));});
  const bundleBody=await page.evaluate(async()=>await(await fetch('/editor.js?selection-hmr=1')).text());assert.equal(hash(bundleBody),proof.bundleSha256);
  const refreshed=page.waitForResponse(response=>new URL(response.url()).pathname==='/api/editor/source/catalog'&&response.request().method()==='GET');
  await page.addScriptTag({url:origin+'/editor.js?selection-hmr=1'});await refreshed;
  await page.waitForFunction(generation=>JSON.parse(window.__popupAcceptance.snapshot()).sourceGeneration>=generation+2,before.sourceGeneration);
  await ready();await assertLatest('identical production bundle HMR plus same-task distinct selections remain responsive/latest');
  const hmrOwners=await page.evaluate(()=>window.__beforeHmrFrames.map(({frame,lifetime,request,document})=>({connected:frame.isConnected,sameLifetime:frame.__isonimSelectionRestoreLifetime===lifetime,disposed:lifetime.disposed,visible:!!frame.getClientRects().length,documentChanged:frame.contentDocument!==document,sameRequest:frame.__isonimSelectionRestore===request,oldRequestValid:!!request?.valid(),currentRequestValid:!!frame.__isonimSelectionRestore?.valid(),currentId:frame.__isonimSelectionRestore?.id,selected:JSON.parse(window.__popupAcceptance.snapshot()).selected,registrations:lifetime.owner.cleanups.filter(fn=>fn===lifetime.dispose).length})));
  proof.cases.push({width,name:'identical bundle HMR distinguishes retained live owners from disposed replaced owners',hmrOwners});
  assert(hmrOwners.length>0&&hmrOwners.some(owner=>owner.connected&&owner.visible),'Actual retained/mounted owner positive control');
  assert(hmrOwners.some(owner=>owner.connected&&owner.sameLifetime&&!owner.visible),'Actual hidden owner negative control is non-vacuous');
  for(const owner of hmrOwners){
    if(!owner.connected||!owner.sameLifetime){assert(owner.disposed);assert(!owner.oldRequestValid);}
    else {assert(!owner.disposed);assert.equal(owner.registrations,1);if(owner.visible){assert(owner.currentRequestValid);assert.equal(owner.currentId,owner.selected);}else{assert(!owner.currentRequestValid);assert.equal(owner.currentId,undefined,'Hidden HMR owner retains no request');}if(!owner.sameRequest)assert(!owner.oldRequestValid);}
  }
  await page.evaluate(()=>{window.__popupAcceptance.select('secondary-action');window.__popupAcceptance.select('action');window.__pendingRestoreBefore={timers:window.__actualUiResources().pending.filter(entry=>entry.stack.includes('restorePreviewSelection')).length,loads:window.__actualRestorationLoads()};window.__disposedRestoreFrames=[...document.querySelectorAll('.editor-preview iframe')].map(frame=>({frame,owned:frame.__isonimViewCleanups!==undefined,hadRequest:!!frame.__isonimSelectionRestore,lifetime:frame.__isonimSelectionRestoreLifetime}));window.__popupAcceptance.unmount();});
  const disposed=await page.evaluate(()=>window.__disposedRestoreFrames.map(({frame,owned,hadRequest,lifetime})=>({owned,hadRequest,lifetimeDisposed:lifetime?.disposed,lifetimeCleanups:lifetime?.owner.cleanups.length,connected:frame.isConnected,disposed:frame.__isonimViewDisposed,request:!!frame.__isonimSelectionRestore,cleanups:frame.__isonimViewCleanups?.size||0})));
  proof.cases.push({width,name:'actual disposed frame ownership audit',disposed});
  const pendingBefore=await page.evaluate(()=>window.__pendingRestoreBefore);
  proof.cases.push({width,name:'genuine pending restoration timer/load ownership before teardown',pendingBefore});
  assert(disposed.some(frame=>frame.owned&&frame.hadRequest),'Teardown must dispose a genuine owned pending request');
  assert(pendingBefore.timers>0&&pendingBefore.loads.length>0,'Actual timer and load registration must be installed before same-task teardown');
  assert.deepEqual(await page.evaluate(()=>window.__actualRestorationLoads()),[],'All actual restoration load listeners removed');
  assert.equal(await page.evaluate(()=>window.__actualUiResources().pending.filter(entry=>entry.stack.includes('restorePreviewSelection')).length),0,'All actual restoration timers cancelled');
  for(const frame of disposed){assert(!frame.connected);if(frame.owned)assert(frame.disposed);if(frame.hadRequest){assert(frame.lifetimeDisposed);assert.equal(frame.lifetimeCleanups,0);}assert(!frame.request);assert.equal(frame.cleanups,0);}
  await page.waitForTimeout(80);
  assert(await page.evaluate(()=>window.__popupAcceptance.remount()));await ready();
  await assertLatest('actual teardown cancels pending restoration; same-VM remount has valid latest owner');
  assert(await page.evaluate(()=>[...document.querySelectorAll('.editor-preview iframe')].some(frame=>frame.getClientRects().length&&frame.__isonimSelectionRestoreLifetime&&!frame.__isonimSelectionRestoreLifetime.disposed&&window.__disposedRestoreFrames.every(old=>old.lifetime!==frame.__isonimSelectionRestoreLifetime))),'Genuine remount constructs new live owner identity after disposed pending owner');
  proof.cases.push({width,name:'disposed original frames have no restoration request/owned resource',disposed});
  await page.close();
 }
 proof.sourceAfterSha256=hash(readFileSync(project+'/stories.nim'));
 proof.sourceBeforeSha256=hash(readFileSync(root+'/source-before.nim'));
 assert.equal(proof.sourceAfterSha256,proof.sourceBeforeSha256);
 assert.deepEqual(proof.pageErrors,[]);
 assert.deepEqual(proof.agentRequests,[],'Popup/source acceptance must make no requests to its controlled agent peer');
 writeFileSync(root+'/proof.json',JSON.stringify(proof,null,2));
 console.log('Mounted queued-selection acceptance passed; artifacts '+root);

}catch(e){
 proof.error=String(e.stack||e);writeFileSync(root+'/proof.json',JSON.stringify(proof,null,2));console.error(e);process.exitCode=1;
 if(browser){for(const [index,page] of browser.contexts().flatMap(context=>context.pages()).entries()){
  try{writeFileSync(root+'/failed-page-'+index+'.html',await bounded(page.content(),'Failure DOM capture',2000));}catch(error){writeFileSync(root+'/failed-page-'+index+'.txt',String(error));}
  try{writeFileSync(root+'/failed-state-'+index+'.json',JSON.stringify(await bounded(page.evaluate(()=>({events:window.__actualSelectionEvents,state:window.__popupAcceptance?.snapshot()})),'Failure state capture',2000),null,2));}catch(error){writeFileSync(root+'/failed-state-'+index+'.txt',String(error));}
 }}
}finally{
 if(browserServer){try{await bounded(browserServer.close(),'Owned browser cleanup',5000);}catch(error){
  proof.cleanupFailure=String(error);process.exitCode=1;browserServer.process().kill('SIGTERM');
 }}
 server.kill('SIGTERM');
 try{await bounded(new Promise(resolve=>server.exitCode!==null?resolve():server.once('exit',resolve)),'Owned server cleanup',5000);}catch(error){proof.serverCleanupFailure=String(error);process.exitCode=1;server.kill('SIGKILL');}
 writeFileSync(root+'/proof.json',JSON.stringify(proof,null,2));
}
