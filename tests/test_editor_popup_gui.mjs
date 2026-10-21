/** Mounted full production editor, real temporary source copy/native SSR compiler,
 * real inspector/DOM/preview and actual controls. No renderer or source/compiler
 * boundary is mocked. The configured editor_control_peer.py is a controlled
 * decision peer solely to satisfy daemon startup, because these scenarios make
 * no agent requests; that zero count is asserted. This suite does not prove
 * Harbor integration (official real Harbor scenario E2E remains separate).
 * This catalog-only attachment preserves genuine legacy preview edits while
 * native-inspector source writes are proven by the separately registered suites.
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
const proof={bundleSha256:hash(readFileSync(pub+'/editor.js')),sourceRoot:project,cases:[],pageErrors:[],agentRequests:[],sourceRequests:[]};
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
    const registrations=[],pending=new Map(),observers=new Set();
    window.__actualLayerPolls=0;
    const addEvent=EventTarget.prototype.addEventListener,removeEvent=EventTarget.prototype.removeEventListener;
    const production=stack=>stack.includes('/editor.js');
    const capture=options=>typeof options==='boolean'?options:!!options?.capture;
    EventTarget.prototype.addEventListener=function(type,fn,options){
      const stack=new Error().stack||'';
      if((this===window||this===document)&&production(stack)&&!registrations.some(r=>r.target===this&&r.type===type&&r.fn===fn&&r.capture===capture(options)))registrations.push({target:this,type,fn,capture:capture(options),stack});
      return addEvent.call(this,type,fn,options);
    };
    EventTarget.prototype.removeEventListener=function(type,fn,options){
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
  page.on('request',request=>{const pathname=new URL(request.url()).pathname;if(pathname.startsWith('/api/agent/'))proof.agentRequests.push({method:request.method(),url:request.url()});if(pathname==='/api/editor/source/operation')proof.sourceRequests.push(request.postDataJSON());});
  await page.goto(origin);
  await page.waitForFunction(()=>!!window.__popupAcceptance);
  await page.locator('[data-scene-graph-row="action"]').waitFor();
  // Actual compiled preview DOM, production observer and unchanged polling
  // fallback. Align immediately after a real poll so 400ms cannot pass by the
  // original 700ms fallback. Deliberately disconnect only the real observer as
  // the falsifier; restore it before positive assertions.
  const alignLayerPoll=async()=>{
    const before=await page.evaluate(()=>window.__actualLayerPolls);
    await page.waitForFunction(before=>window.__actualLayerPolls>before,before,{timeout:1500});
    return await page.evaluate(()=>window.__actualLayerPolls);
  };
  const realFrame=page.locator('.editor-preview iframe').filter({visible:true}).first().contentFrame();
  await realFrame.locator('[data-isonim-element-id="long-text-12"]').waitFor();
  await alignLayerPoll();
  await page.evaluate(()=>{
    const record=[...window.__isonimSceneGraphReaderRuntime.records.values()].find(r=>!r.closed);
    window.__readerControl=record;record.docObserver.disconnect();
    const target=record.doc.querySelector('[data-isonim-element-id="long-text-12"]');
    target.setAttribute('data-isonim-element-id','observer-falsifier');
  });
  await page.waitForTimeout(400);
  assert.equal(await page.locator('[data-scene-graph-row="observer-falsifier"]').count(),0,
    'Disconnected real observer falsifies prompt interior identity publication');
  await page.evaluate(()=>{
    const record=window.__readerControl;
    record.doc.querySelector('[data-isonim-element-id="observer-falsifier"]').setAttribute('data-isonim-element-id','long-text-12');
    record.docObserver.observe(record.doc.body,{subtree:true,childList:true,characterData:true,attributes:true});
  });
  const positivePoll=await alignLayerPoll();
  await realFrame.locator('[data-isonim-element-id="long-text-12"]').evaluate(el=>{
    el.setAttribute('data-isonim-element-id','observer-positive');el.textContent='Notify label';
  });
  await page.locator('[data-scene-graph-row="observer-positive"]').waitFor({timeout:400});
  assert.equal(await page.evaluate(()=>window.__actualLayerPolls),positivePoll,'Identity publishes before another poll');
  assert((await page.locator('[data-scene-graph-row="observer-positive"]').textContent()).includes('Notify label'));
  const labelPoll=await alignLayerPoll();
  await realFrame.locator('[data-isonim-element-id="observer-positive"]').evaluate(el=>{el.textContent='Second label';});
  await page.waitForFunction(()=>document.querySelector('[data-scene-graph-row="observer-positive"]')?.textContent.includes('Second label'),null,{timeout:400});
  assert.equal(await page.evaluate(()=>window.__actualLayerPolls),labelPoll,'Same-ID label change publishes before polling');
  await page.locator('[data-layer-search]').fill('Second label');
  assert.equal(await page.locator('[data-scene-graph-row="observer-positive"]').count(),1,'Search consumes the latest same-ID label');
  await page.locator('[data-layer-search]').fill('');

  await realFrame.locator('[data-isonim-element-id="observer-positive"]').evaluate(el=>{
    el.setAttribute('data-isonim-element-id','long-text-12');el.textContent='Long layer 12';
  });
  await page.locator('[data-scene-graph-row="long-text-12"]').waitFor({timeout:400});
  const readerCounts=await page.evaluate(()=>({records:window.__isonimSceneGraphReaderRuntime.records.size,
    owners:window.__readerControl.owners.size,roots:window.__readerControl.roots.size}));
  assert.equal(readerCounts.records,1);assert.equal(readerCounts.owners,1);assert.equal(readerCounts.roots,1);
  proof.cases.push({width,name:'real interior DOM identity and label mutation publishes before polling; disconnected production observer falsifies the 400ms gate',positivePoll,readerCounts});
  await page.locator('[data-scene-graph-row="action"]').click();
  const replacementState=JSON.parse(await page.evaluate(()=>window.__popupAcceptance.snapshot()));
  const replacement=await page.evaluate(()=>{
    const record=window.__readerControl;
    const frame=Array.from(document.querySelectorAll('.editor-preview iframe')).find(frame=>frame.contentDocument===record.doc);
    window.__readerReplacement={frame,doc:record.doc,observer:record.docObserver,
      html:record.doc.documentElement.outerHTML,srcdoc:frame.getAttribute('srcdoc')};
    frame.srcdoc='<html><body></body></html>';
    return {rowCount:document.querySelectorAll('[data-scene-graph-row]').length};
  });
  await page.waitForFunction(()=>window.__readerReplacement.frame.contentDocument!==window.__readerReplacement.doc);
  // Several true load/visibility notifications during the empty replacement
  // must not become two temporal polls and erase selection or the last tree.
  await page.evaluate(()=>{for(let i=0;i<5;i++)window.dispatchEvent(new Event('resize'));});
  await page.waitForTimeout(100);
  assert.equal(await page.locator('[data-scene-graph-row]').count(),replacement.rowCount,'Rapid empty-document notifications preserve the two-poll reload guard');
  const loadingState=JSON.parse(await page.evaluate(()=>window.__popupAcceptance.snapshot()));
  assert.equal(loadingState.selected,replacementState.selected,'Real reload retains selected layer');
  assert.deepEqual(loadingState.expandedLayers,replacementState.expandedLayers,'Real reload retains saved expansion');
  await page.evaluate(()=>{const replacement=window.__readerReplacement;replacement.frame.srcdoc=replacement.html;});
  await page.waitForFunction(()=>{
    const record=window.__readerControl,frame=window.__readerReplacement.frame;
    return record.doc===frame.contentDocument&&!!record.doc.querySelector('[data-isonim-element-id="long-text-12"]');
  },null,{timeout:400});
  assert(await page.evaluate(()=>window.__readerControl.docObserver!==window.__readerReplacement.observer),'Document replacement obtains a new actual observer');
  await page.evaluate(()=>{
    window.__readerReplacement.doc.querySelector('[data-isonim-element-id="long-text-12"]').setAttribute('data-isonim-element-id','disposed-document-negative');
  });
  await page.waitForTimeout(100);
  assert.equal(await page.locator('[data-scene-graph-row="disposed-document-negative"]').count(),0,'Detached old document cannot republish its tree');
  await page.evaluate(()=>{
    const replacement=window.__readerReplacement;
    if(replacement.srcdoc===null)replacement.frame.removeAttribute('srcdoc');else replacement.frame.srcdoc=replacement.srcdoc;
  });
  await page.waitForFunction(()=>window.__readerControl.doc!==window.__readerReplacement.doc&&
    !!window.__readerControl.doc?.querySelector('[data-isonim-element-id="long-text-12"]'),null,{timeout:400});
  proof.cases.push({width,name:'real iframe document replacement promptly reconnects, rapid empty loading notifications preserve tree, old document cannot publish',replacement});
  await alignLayerPoll();
  const emptyStart=await page.evaluate(()=>{
    const replacement=window.__readerReplacement;
    replacement.frame.srcdoc='<html><body></body></html>';
    return window.__actualLayerPolls;
  });
  await page.waitForFunction(start=>window.__actualLayerPolls===start+1,emptyStart,{timeout:1500});
  assert.equal(await page.locator('[data-scene-graph-row]').count(),replacement.rowCount,'One real empty poll retains the previous tree');
  await page.waitForFunction(start=>window.__actualLayerPolls>=start+2,emptyStart,{timeout:1500});
  assert.equal(await page.locator('[data-scene-graph-row]').count(),0,'Two real empty polls clear a genuinely empty document');
  await page.evaluate(()=>{
    const replacement=window.__readerReplacement;
    if(replacement.srcdoc===null)replacement.frame.removeAttribute('srcdoc');else replacement.frame.srcdoc=replacement.srcdoc;
  });
  await page.locator('[data-scene-graph-row="action"]').waitFor({timeout:400});
  assert.deepEqual(JSON.parse(await page.evaluate(()=>window.__popupAcceptance.snapshot())).expandedLayers,replacementState.expandedLayers);
  proof.cases.push({width,name:'genuinely empty real document clears only on its second actual poll and reload restores saved expansion',emptyStart});


  await page.locator('[data-toolbar-cluster="mode"] [aria-label="Switch to edit mode"]').click();
  const frame=page.locator('.editor-preview iframe').filter({visible:true}).first().contentFrame();
  await frame.locator('#isonim-editor-selection-style').waitFor({state:'attached'});
  await frame.locator('#action').waitFor();
  assert.equal(await frame.locator('#action').evaluate(el=>getComputedStyle(el).backgroundColor),'rgb(17, 34, 51)');
  await page.locator('[data-scene-graph-row="action"]').click();
  await page.locator('[data-fill-row-bind="0"]').waitFor();
  proof.cases.push({width,name:'real source preview and selection hydration',events:await page.evaluate(()=>window.__actualSelectionEvents),final:JSON.parse(await page.evaluate(()=>window.__popupAcceptance.snapshot()))});
  await page.evaluate(()=>window.__popupAcceptance.tokens());
  const layerSearch=page.locator('[data-layer-search]');
  const ancestorId=await page.locator('[data-scene-graph-row][data-scene-graph-depth="0"]').first().getAttribute('data-scene-graph-row');
  const ancestorTwisty=page.locator('[data-scene-graph-twisty="'+ancestorId+'"]');
  await ancestorTwisty.click();assert.equal(await page.locator('[data-scene-graph-row="'+ancestorId+'"]').getAttribute('aria-expanded'),'false');
  assert.equal(await page.locator('[data-scene-graph-row="action"]').count(),0);
  const savedExpansion=JSON.parse(await page.evaluate(()=>window.__popupAcceptance.snapshot())).expandedLayers;
  await layerSearch.fill('Continue');
  await page.locator('[data-scene-graph-row="action"]').waitFor();
  assert.equal(await page.locator('[data-scene-graph-row="long-layer-0"]').count(),0);
  assert.equal(await page.locator('[data-scene-graph-row][data-scene-graph-depth="0"]').count(),1,'Matching descendants preserve the real ancestor');
  assert.equal(await page.locator('[data-scene-graph-row="'+ancestorId+'"]').getAttribute('aria-expanded'),'true','A revealed ancestor uses an expanded disclosure');
  assert.deepEqual(JSON.parse(await page.evaluate(()=>window.__popupAcceptance.snapshot())).expandedLayers,savedExpansion);
  await layerSearch.fill('');
  assert.equal(await page.locator('[data-scene-graph-row="action"]').count(),0);
  assert.equal(await page.locator('[data-scene-graph-row="'+ancestorId+'"]').getAttribute('aria-expanded'),'false');
  assert.deepEqual(JSON.parse(await page.evaluate(()=>window.__popupAcceptance.snapshot())).expandedLayers,savedExpansion);
  await ancestorTwisty.click();
  await page.locator('[data-scene-graph-row="long-layer-0"]').waitFor();
  assert.equal(JSON.parse(await page.evaluate(()=>window.__popupAcceptance.snapshot())).selected,'action');
  // Expand the actual story group to expose the real long tree.
  await page.getByRole('button',{name:'Toggle Card stories',exact:true}).click();
  const story=page.locator('[data-sidebar-story-tree]'), layers=page.locator('[data-scene-graph-rows]');
  const measurePanels=async()=>await story.evaluate(el=>{
    const panel=document.querySelector('[data-scene-graph]');
    const outer=el.closest('.editor-sidebar');
    const fullyVisible=(host,selector)=>{const b=host.getBoundingClientRect();return Array.from(host.querySelectorAll(selector)).filter(row=>{const r=row.getBoundingClientRect();return r.height>0 && r.top>=b.top && r.bottom<=b.bottom && r.left>=b.left && r.right<=b.right;}).length;};
    return {visibleStoryControls:fullyVisible(el,'[data-story-row],[role="button"][aria-label^="Open " ][aria-label$=" section"],[role="button"][aria-label$=" stories"]'),visibleStories:fullyVisible(el,'[data-story-row]'),visibleLayers:fullyVisible(panel.querySelector('[data-scene-graph-rows]'),'[data-scene-graph-row]'),siblings:panel.parentElement===outer,outerOverflow:getComputedStyle(outer).overflowY,
      outerScroll:outer.scrollHeight,outerClient:outer.clientHeight,
      storyHeight:el.scrollHeight,storyClient:el.clientHeight,
      layerHeight:panel.querySelector('[data-scene-graph-rows]').scrollHeight,
      layerClient:panel.querySelector('[data-scene-graph-rows]').clientHeight,
      scrollbar:getComputedStyle(el).scrollbarWidth,color:getComputedStyle(el).scrollbarColor};
  });
  const layout=await measurePanels();
  assert(layout.visibleStories>=4 && layout.visibleLayers>=4,'Both genuine sibling trees must have at least four fully visible usable rows: '+JSON.stringify(layout));
  assert(layout.siblings,'Storyboard and Layers must be sibling panels under the bounded outer region');
  assert.equal(layout.outerOverflow,'hidden');assert(layout.outerScroll<=layout.outerClient+1);
  assert(layout.storyHeight>layout.storyClient && layout.layerHeight>layout.layerClient,'Both genuine long trees must overflow');
  assert.equal(layout.scrollbar,'thin');assert.notEqual(layout.color,'auto');
  await page.setViewportSize({width,height:600});
  const initialShorter=await measurePanels();
  const fourStoryRowsHeight=await story.evaluate(el=>Array.from(el.querySelectorAll('[data-story-row]')).slice(0,4).reduce((height,row)=>height+row.getBoundingClientRect().height,0));
  assert(initialShorter.visibleStoryControls>=4 && initialShorter.storyClient>=fourStoryRowsHeight && initialShorter.visibleLayers>=4,'Both short-viewport regions must fit useful real content: '+JSON.stringify(initialShorter));
  // Category/group headers are scrollable story content. Prove actual keyboard
  // access to four leaves rather than counting headers against leaf capacity.
  const shortLayerTop=await layers.evaluate(el=>el.scrollTop),shortStoryTop=await story.evaluate(el=>el.scrollTop);
  await story.focus();await page.keyboard.press('PageDown');
  await page.waitForFunction(before=>document.querySelector('[data-sidebar-story-tree]').scrollTop>before,shortStoryTop);
  await story.evaluate(el=>new Promise(resolve=>{let last=el.scrollTop,stable=0;function frame(){const next=el.scrollTop;stable=next===last?stable+1:0;last=next;if(stable===8)resolve();else requestAnimationFrame(frame);}requestAnimationFrame(frame);}));
  assert.equal(await layers.evaluate(el=>el.scrollTop),shortLayerTop,'Short viewport story navigation preserves Layers scroll');
  const shorter=await measurePanels();
  assert(shorter.visibleStories>=4 && shorter.visibleLayers>=4,'Shorter viewport must expose four useful real leaves in both trees: '+JSON.stringify(shorter));
  assert(shorter.siblings);assert.equal(shorter.outerOverflow,'hidden');assert(shorter.outerScroll<=shorter.outerClient+1);
  for(const input of [layerSearch,page.locator('[data-sidebar-search]')]){
    assert(await input.isVisible());assert(await input.evaluate(el=>{const b=el.getBoundingClientRect();return b.top>=0 && b.bottom<=innerHeight;}));
  }
  proof.cases.push({width,name:'usable sibling tree allocation and reachable searches at shorter600 viewport',initialLayout:initialShorter,layout:shorter});
  await page.setViewportSize({width,height:900});await story.evaluate(el=>el.scrollTop=0);
  await layers.hover(); await page.mouse.wheel(0,200);
  await page.waitForFunction(()=>document.querySelector('[data-scene-graph-rows]').scrollTop>0);
  assert.equal(await story.evaluate(el=>el.scrollTop),0);
  await layers.focus(); const beforeKeyboard=await layers.evaluate(el=>el.scrollTop);
  await page.keyboard.press('PageDown');
  await page.waitForFunction(before=>document.querySelector('[data-scene-graph-rows]').scrollTop>before,beforeKeyboard);
  // Wait for actual browser PageDown animation to settle before measuring
  // independence; the other panel must not be blamed for remaining frames.
  await layers.evaluate(el=>new Promise(resolve=>{let last=el.scrollTop,stable=0;function frame(){const next=el.scrollTop;stable=next===last?stable+1:0;last=next;if(stable===8)resolve();else requestAnimationFrame(frame);}requestAnimationFrame(frame);}));
  const layerTop=await layers.evaluate(el=>el.scrollTop);
  await story.hover(); await page.mouse.wheel(0,140);
  await page.waitForFunction(()=>document.querySelector('[data-sidebar-story-tree]').scrollTop>0);
  assert.equal(await layers.evaluate(el=>el.scrollTop),layerTop);
  await story.focus(); const beforeStoryKeyboard=await story.evaluate(el=>el.scrollTop);
  await page.keyboard.press('PageDown');
  await page.waitForFunction(before=>document.querySelector('[data-sidebar-story-tree]').scrollTop>before,beforeStoryKeyboard);
  assert.equal(await layers.evaluate(el=>el.scrollTop),layerTop);
  proof.cases.push({width,name:'real sibling scrolling, ancestor search, clear and preserved selection',layout});
  const bounds=async(selector)=>{
    await page.waitForTimeout(40);
    const value=await page.locator(selector).evaluate(el=>{
      const b=el.getBoundingClientRect(),v=window.visualViewport;
      return {left:b.left,top:b.top,right:b.right,bottom:b.bottom,width:b.width,height:b.height,
        vx:v?.offsetLeft||0,vy:v?.offsetTop||0,vw:v?.width||innerWidth,vh:v?.height||innerHeight,
        topLayer:el.matches(':popover-open'),theme:getComputedStyle(el).backgroundColor,
        scrollbar:getComputedStyle(el).scrollbarWidth};
    });
    assert(value.topLayer);assert(value.width>0 && value.height>0);
    assert(value.left>=value.vx && value.top>=value.vy);
    assert(value.right<=value.vx+value.vw+0.5 && value.bottom<=value.vy+value.vh+0.5,JSON.stringify(value));
    assert.notEqual(value.theme,'rgba(0, 0, 0, 0)');assert.equal(value.scrollbar,'thin');
    return value;
  };
  // These are real current DOM surfaces. Legacy .editor-tabbar and
  // .editor-manual-inspector are CSS-only and are not fabricated here.
  const forcedSnapshot=async selectors=>{
    const rows=[];
    for(const selector of selectors){
      const host=page.locator(selector);assert.equal(await host.count(),1,'Actual forced-colors surface '+selector);
      assert(await host.isVisible(),'Visible current surface '+selector);
      rows.push(await host.evaluate((el,selector)=>({selector,width:getComputedStyle(el).scrollbarWidth,color:getComputedStyle(el).scrollbarColor}),selector));
    }
    for(const row of rows){assert.equal(row.width,'auto',JSON.stringify(row));assert.equal(row.color,'auto',JSON.stringify(row));}
    return rows;
  };
  const forcedPanelGeometry=async()=>await story.evaluate(el=>({storyTop:el.scrollTop,storyHeight:el.scrollHeight,storyClient:el.clientHeight,layerTop:document.querySelector('[data-scene-graph-rows]').scrollTop}));
  const forcedBeforeMedia=await forcedPanelGeometry();
  await page.emulateMedia({forcedColors:'active'});
  const forcedAfterMedia=await forcedPanelGeometry();
  const legacyFallback=await page.evaluate(()=>{
    const styles=Array.from(document.querySelectorAll('style')).filter(el=>el.textContent.includes('Use platform-sized, visible scrollbars'));
    if(styles.length!==1)throw Error('Expected one actual production scrollbar stylesheet');
    return Array.from(styles[0].sheet.cssRules).filter(rule=>rule.conditionText==='(forced-colors: active)').flatMap(rule=>Array.from(rule.cssRules).map(item=>({selector:item.selectorText,width:item.style.width,height:item.style.height,display:item.style.display})));
  });
  assert(legacyFallback.some(rule=>rule.selector==='.editor-tabbar::-webkit-scrollbar'&&rule.display==='revert'),'Parsed legacy CSS fallback restores scrollbar visibility; no exposed legacy tabbar claimed');
  assert(legacyFallback.some(rule=>rule.selector==='::-webkit-scrollbar'&&rule.width==='auto'&&rule.height==='auto'));
  const forcedInspector=await forcedSnapshot(['.editor-sidebar','[data-sidebar-story-tree]','[data-scene-graph-rows]','[data-inspector-section-list]']);
  const forcedBeforeFocus=await forcedPanelGeometry();
  await layers.evaluate(el=>el.scrollTop=0);
  await page.locator('[data-scene-graph-row]').first().focus();
  // The preceding Storyboard PageDown animates across forced-colors setup.
  // Settle that earlier action BEFORE protecting the sibling scroll snapshot.
  await story.evaluate(el=>new Promise(resolve=>{let previous=el.scrollTop,stable=0;const frame=()=>{const current=el.scrollTop;stable=current===previous?stable+1:0;previous=current;if(stable>=3)resolve();else requestAnimationFrame(frame);};requestAnimationFrame(frame);}));
  const forcedAfterFocus=await forcedPanelGeometry(),forcedStoryTop=forcedAfterFocus.storyTop;
  // Owning falsifier: a genuine forbidden sibling move after the baseline must
  // still fail the identical equality below. No outcome/assertion is replaced.
  if(process.env.ISONIM_POPUP_SCROLL_FALSIFIER==='1')await story.evaluate(el=>el.scrollTop+=1);
  await page.keyboard.press('PageDown');
  await page.waitForFunction(()=>document.querySelector('[data-scene-graph-rows]').scrollTop>0);
  assert.equal(await story.evaluate(el=>el.scrollTop),forcedStoryTop,'Forced-colors Layers keyboard scroll leaves Storyboard fixed');
  await page.locator('[data-toolbar-cluster="mode"] [aria-label="Switch to view mode"]').click();
  const forcedChat=await forcedSnapshot(['.editor-chat','[data-chat-scroll]']);
  await page.locator('[data-toolbar-cluster="mode"] [aria-label="Switch to edit mode"]').click();
  await page.emulateMedia({forcedColors:'none'});
  for(const selector of ['.editor-sidebar','[data-sidebar-story-tree]','[data-scene-graph-rows]','[data-inspector-section-list]']){
    const actual=await page.locator(selector).evaluate(el=>({width:getComputedStyle(el).scrollbarWidth,color:getComputedStyle(el).scrollbarColor}));
    assert.equal(actual.width,'thin');assert.notEqual(actual.color,'auto','Ordinary theme remains subtle');
  }
  proof.cases.push({width,name:'forced-colors actual sibling/inspector/chat defaults and independent native Layers keyboard scroll; ordinary theme restored',forcedInspector,forcedChat,legacyFallback,forcedBeforeMedia,forcedAfterMedia,forcedBeforeFocus,forcedAfterFocus,forcedAfterKey:await forcedPanelGeometry()});
  const bind=page.locator('[data-fill-row-bind="0"]');
  await bind.focus();await page.keyboard.press('Enter');
  await page.locator('[data-variable-picker-open="true"]').waitFor();
  await bounds('[data-variable-picker]');
  const body=page.locator('[data-variable-picker-body]');
  assert(await body.evaluate(el=>el.scrollHeight>el.clientHeight));
  await page.emulateMedia({forcedColors:'active'});
  const forcedPopup=await forcedSnapshot(['[data-variable-picker-open="true"]','[data-variable-picker-body]']);
  const forcedScrollOwners=async()=>await story.evaluate(el=>({story:el.scrollTop,layers:document.querySelector('[data-scene-graph-rows]').scrollTop,inspector:document.querySelector('[data-inspector-section-list]').scrollTop}));
  const forcedPopupBeforeFocus=await forcedScrollOwners();
  await body.evaluate(el=>el.scrollTop=0);
  await page.locator('[data-variable-picker-row-edit]').first().focus();
  const forcedUnderlying=await forcedScrollOwners();
  await page.keyboard.press('PageDown');
  await page.waitForFunction(()=>document.querySelector('[data-variable-picker-body]').scrollTop>0);
  assert.deepEqual(await story.evaluate(el=>({story:el.scrollTop,layers:document.querySelector('[data-scene-graph-rows]').scrollTop,inspector:document.querySelector('[data-inspector-section-list]').scrollTop})),forcedUnderlying,'Forced-colors popup keyboard scrolling keeps underlying owners fixed');
  await page.emulateMedia({forcedColors:'none'});
  assert.equal(await body.evaluate(el=>getComputedStyle(el).scrollbarWidth),'thin');
  await body.evaluate(el=>el.scrollTop=0);
  proof.cases.push({width,name:'oversized top-layer forced-colors defaults and native keyboard scroll without underlying movement',forcedPopup,forcedPopupBeforeFocus,forcedAfterFocus:forcedUnderlying,forcedAfterKey:await forcedScrollOwners()});

  await page.locator('[data-variable-picker-row-edit]').first().click();
  await page.locator('[data-variable-inline-editor-open="true"]').waitFor();
  await bounds('[data-variable-inline-editor]');
  const draft=await page.locator('[data-variable-inline-editor-value]').inputValue();
  const colorInvoker=page.locator('[data-variable-inline-editor-picker]');
  await colorInvoker.focus();await page.keyboard.press('Enter');
  await page.locator('[data-color-popover-open="true"]').waitFor();
  await bounds('[data-color-popover-open="true"]');
  for(const color of ['#FFFFFF','#3B82F6','#22C55E']){
    await page.locator('[data-color-popover-open="true"] [data-color-popover-swatch="'+color+'"]').click();
    assert.equal(await page.locator('[data-color-popover-open="true"] [data-color-popover-input]').inputValue(),color);
  }
  assert.equal(await page.locator('[data-variable-inline-editor-value]').inputValue(),draft,'Child draft changes do not silently commit the parent');
  await page.keyboard.press('Tab');
  assert(await page.locator('[data-color-popover-open="true"]').evaluate(el=>el.contains(document.activeElement)));
  await page.keyboard.press('Escape');
  assert.equal(await page.locator('[data-color-popover-open="true"]').count(),0);
  assert.equal(await page.locator('[data-variable-inline-editor-open="true"]').count(),1);
  assert(await colorInvoker.evaluate(el=>el===document.activeElement));
  await page.keyboard.press('Escape');
  assert.equal(await page.locator('[data-variable-inline-editor-open="true"]').count(),0);
  assert(await page.locator('[data-variable-picker-row-edit]').first().evaluate(el=>el===document.activeElement));
  await page.keyboard.press('Escape');
  assert.equal(await page.locator('[data-variable-picker-open="true"]').count(),0);
  assert(await bind.evaluate(el=>el===document.activeElement));
  proof.cases.push({width,name:'actual token/value/child-color keyboard and pointer flow, topmost Escape and focus return'});
  // Every edge uses the original mounted literal-color invoker. Temporary
  // fixed positioning isolates anchor geometry without replacing the renderer.
  const literal=page.locator('[data-property-row-swatch]').first();
  const originalStyle=await literal.getAttribute('style');
  await page.evaluate(()=>window.__popupAcceptance.readOnly(true));
  const readonlyRow=literal.locator('xpath=ancestor::*[@data-property-row][1]');
  assert.equal(await readonlyRow.getAttribute('data-property-row-readonly'),'true');
  const readonlyInput=readonlyRow.locator('[data-property-row-input]').first();
  assert(await readonlyInput.evaluate(el=>el.readOnly));
  const inspectBefore=await page.evaluate(()=>window.__popupAcceptance.snapshot());
  proof.readonlyObserverAudit={before:JSON.parse(await page.evaluate(()=>window.__popupAcceptance.observerDetails()))};
  const inspectValue=await readonlyInput.inputValue();
  const inspectRequests=proof.sourceRequests.length;
  await page.context().grantPermissions(['clipboard-read','clipboard-write'],{origin});
  await readonlyInput.click();
  assert(await readonlyInput.evaluate(el=>el===document.activeElement));
  await page.keyboard.press('ControlOrMeta+A');
  assert.deepEqual(await readonlyInput.evaluate(el=>[el.selectionStart,el.selectionEnd]),[0,inspectValue.length]);
  await page.keyboard.press('ControlOrMeta+C');
  assert.equal(await page.evaluate(()=>navigator.clipboard.readText()),inspectValue);
  for(const key of ['ArrowLeft','ArrowRight','Home','End','ArrowUp','ArrowDown']) await page.keyboard.press(key);
  assert.equal(await readonlyInput.inputValue(),inspectValue);

  const readonlyNumeric=page.locator('[data-property-row-kind="numeric"][data-property-row-readonly="true"]:visible').first();
  await readonlyNumeric.scrollIntoViewIfNeeded();
  const numericInput=readonlyNumeric.locator('[data-property-row-input]');
  const numericValue=await numericInput.inputValue();
  await numericInput.focus();
  for(const key of ['ArrowUp','ArrowDown']) await page.keyboard.press(key);
  assert.equal(await numericInput.inputValue(),numericValue);
  const readonlyUnit=readonlyNumeric.locator('[data-property-row-unit]');
  assert.equal(await readonlyUnit.count(),1);
  const unitText=await readonlyUnit.innerText();
  await readonlyUnit.focus();
  for(const key of ['Enter','Space']) await page.keyboard.press(key);
  assert.equal(await readonlyUnit.innerText(),unitText);
  const readonlyScrubber=readonlyNumeric.locator('[data-property-row-field-label]');
  await readonlyScrubber.scrollIntoViewIfNeeded();
  const scrubBox=await readonlyScrubber.boundingBox();
  assert(scrubBox && scrubBox.width>0 && scrubBox.height>0);
  await page.mouse.move(scrubBox.x+scrubBox.width/2,scrubBox.y+scrubBox.height/2);
  await page.mouse.down();await page.mouse.move(scrubBox.x+scrubBox.width/2+30,scrubBox.y+scrubBox.height/2,{steps:4});await page.mouse.up();
  assert.equal(await numericInput.inputValue(),numericValue);
  assert.equal(await page.evaluate(()=>window.__popupAcceptance.snapshot()),inspectBefore);
  assert.equal(proof.sourceRequests.length,inspectRequests);
  for(const activation of ['pointer','Enter','Space']){
    await literal.scrollIntoViewIfNeeded();
    if(activation==='pointer') await literal.click();
    else {await literal.focus();await page.keyboard.press(activation);}
    await page.locator('[data-color-popover-open="true"]').waitFor();
    const openInspectBefore=await page.evaluate(()=>window.__popupAcceptance.snapshot());
    proof.readonlyObserverAudit.open=JSON.parse(await page.evaluate(()=>window.__popupAcceptance.observerDetails()));
    const inspectDraft=page.locator('[data-color-popover-open="true"] [data-color-popover-input]');
    assert(!(await inspectDraft.evaluate(el=>el.readOnly)));
    await inspectDraft.fill('#AABBCC');
    await page.locator('[data-color-popover-open="true"] [data-color-popover-apply]').click();
    assert.equal(await inspectDraft.inputValue(),'#AABBCC');
    assert((await page.locator('[data-color-popover-open="true"] [data-color-popover-error]').innerText()).includes('refused'));
    assert.equal(await readonlyInput.inputValue(),inspectValue);
    assert.equal(await page.evaluate(()=>window.__popupAcceptance.snapshot()),openInspectBefore);
    assert.equal(proof.sourceRequests.length,inspectRequests,'Readonly inspection must not submit a native source edit');
    await page.keyboard.press('Escape');
    assert.equal(await page.locator('[data-color-popover-open="true"]').count(),0);
    assert(await literal.evaluate(el=>el===document.activeElement));
    proof.readonlyObserverAudit.after=JSON.parse(await page.evaluate(()=>window.__popupAcceptance.observerDetails()));
    assert.equal(await page.evaluate(()=>window.__popupAcceptance.snapshot()),inspectBefore);
  }
  proof.cases.push({width,name:'readonly color pointer and keyboard inspection, real clipboard copy and refused draft Apply preserve value and history'});
  await page.evaluate(()=>window.__popupAcceptance.readOnly(false));

  for(const [edge,x,y] of [['top-left',1,1],['top-right',width-18,1],['bottom-left',1,881],['bottom-right',width-18,881]]){
    await literal.evaluate((el,{x,y})=>{el.style.position='fixed';el.style.left=x+'px';el.style.top=y+'px';el.style.zIndex='1400';},{x,y});
    await literal.click();
    await page.locator('[data-color-popover-open="true"]').waitFor();
    const position=await bounds('[data-color-popover-open="true"]');
    await page.locator('[data-color-popover-open="true"] [data-color-popover-input]').fill('#invalid');
    await page.locator('[data-color-popover-open="true"] [data-color-popover-apply]').click();
    assert((await page.locator('[data-color-popover-open="true"] [data-color-popover-error]').innerText()).includes('valid hex'));
    await page.keyboard.press('Escape');
    assert(await literal.evaluate(el=>el===document.activeElement));
    proof.cases.push({width,name:'actual literal-color edge '+edge,position});
  }
  await literal.evaluate((el,style)=>el.setAttribute('style',style),originalStyle);
  // Changing viewport and page zoom while a real popup is already open.
  await bind.click();
  await page.locator('[data-variable-picker-open="true"]').waitFor();
  await page.setViewportSize({width:width-90,height:240});
  await bounds('[data-variable-picker]');
  assert(await body.evaluate(el=>el.scrollHeight>el.clientHeight));
  const devtools=await page.context().newCDPSession(page);
  await devtools.send('Emulation.setPageScaleFactor',{pageScaleFactor:1.6});
  await bounds('[data-variable-picker]');
  await devtools.send('Emulation.setPageScaleFactor',{pageScaleFactor:1});
  await page.keyboard.press('Escape');
  await page.setViewportSize({width,height:900});
  await bind.click();
  await page.locator('[data-variable-picker-open="true"]').waitFor();
  const beforeScroll=await bounds('[data-variable-picker]');
  await page.locator('[data-inspector-section-list]').evaluate(el=>el.scrollTop=el.scrollTop+80);
  const afterScroll=await bounds('[data-variable-picker]');
  assert(beforeScroll.top!==afterScroll.top || await bind.evaluate(el=>el.getBoundingClientRect().top<0),'A real anchor scroll must be observed');
  await page.keyboard.press('Escape');
  proof.cases.push({width,name:'real oversized token body, resize, page zoom and inspector-scroll repositioning',beforeScroll,afterScroll});
  // A real project permission change makes the common commit path refuse.
  // Absence of a source adapter alone still permits genuine preview edits.
  await page.evaluate(()=>window.__popupAcceptance.readOnly(true));
  await literal.click();
  const row=literal.locator('xpath=ancestor::*[@data-property-row][1]');
  const originalValue=await row.locator('[data-property-row-input]').inputValue();
  await page.locator('[data-color-popover-open="true"] [data-color-popover-input]').fill('#22C55E');
  await page.locator('[data-color-popover-open="true"] [data-color-popover-apply]').click();
  assert.equal(await row.locator('[data-property-row-input]').inputValue(),originalValue);
  assert((await page.locator('[data-color-popover-open="true"] [data-color-popover-error]').innerText()).includes('refused'));
  assert.equal(await frame.locator('#action').evaluate(el=>getComputedStyle(el).backgroundColor),'rgb(17, 34, 51)');
  await page.keyboard.press('Escape');
  await literal.click();
  await page.locator('[data-color-popover-open="true"] [data-color-popover-input]').fill('#ABCDEF');
  const staleApply=await page.locator('[data-color-popover-open="true"] [data-color-popover-apply]').elementHandle();
  assert(await page.evaluate(()=>window.__popupAcceptance.select('secondary-action')));
  assert.equal(await page.locator('[data-color-popover-open="true"]').count(),0,'Changing selection through the real VM must close the existing literal draft');
  const newSelection=await page.evaluate(()=>window.__popupAcceptance.snapshot());
  await staleApply.evaluate(el=>el.click());
  assert.equal(await page.evaluate(()=>window.__popupAcceptance.snapshot()),newSelection,'A retained real Apply handler cannot edit the new selection');
  assert.equal(await frame.locator('#secondary-action').evaluate(el=>getComputedStyle(el).backgroundColor),'rgb(239, 239, 239)');
  await page.locator('[data-scene-graph-row="action"]').click();
  await page.locator('[data-fill-row-bind="0"]').waitFor();
  proof.cases.push({width,name:'real common-path refusal and stale Apply after actual VM selection change'});
  await page.evaluate(()=>window.__popupAcceptance.readOnly(false));
  // The entire menu is mounted before either activation. Both actual token
  // choices must name the clicked row rather than the last loop item.
  for(const [index,key] of ['color/test-3','color/test-7'].entries()){
    const trigger=index===0?bind:page.locator('[data-fill-row-linked-chip] [data-variable-chip-chevron]');
    await trigger.focus();await page.keyboard.press('Enter');
    await page.locator('[data-variable-picker-open="true"]').waitFor();
    await page.locator('[data-variable-picker-row="'+key+'"]').click();
    assert.equal(await page.locator('[data-fill-row-linked-chip][data-variable-chip]').getAttribute('data-variable-chip-key'),key);
  }
  proof.cases.push({width,name:'two distinct actual token activations after full menu mount'});
  // Exercise every mounted chevron choice and every source-scope disclosure,
  // including native summary activation, actual top-layer theme and focus return.
  const ordinarySelection=await page.evaluate(()=>{
    const element=globalThis.__isonimEditorVm.inspector.selectedElement.value;
    const text=value=>typeof value==='string'?value:String.fromCharCode(...value);
    return {id:text(element.id),schema:text(element.schemaKey),
      propertySchemas:element.properties.map(property=>text(property.schemaKey))};
  });
  assert.equal(ordinarySelection.id,'action');assert.equal(ordinarySelection.schema,'dom.button');
  assert(ordinarySelection.propertySchemas.length>0);assert(ordinarySelection.propertySchemas.every(schema=>schema.startsWith('dom.button.')));
  const sections=page.locator('[data-inspector-section-body]');
  const expectedSections=['position','layout','appearance','fill','stroke','effects','typography','selection-colors','source','component-properties','state','export'];
  assert.deepEqual(await sections.evaluateAll(nodes=>nodes.map(node=>node.dataset.inspectorSectionBody)),expectedSections);
  let applicableSections=0;
  for(let index=0;index<await sections.count();index++){
    const body=sections.nth(index),slug=await body.getAttribute('data-inspector-section-body');
    const header=page.locator('[data-inspector-section-header="'+slug+'"]');
    if(slug==='component-properties'){
      assert.equal(await header.isVisible(),false,'Ordinary DOM ownership must not expose component-instance controls');
      assert.equal(await body.isVisible(),false);assert.equal(await body.locator('[data-component-prop-schema]').count(),0);
    }else{
      assert(await header.isVisible(),'Every applicable section header must be exposed: '+slug);
      if(!await body.isVisible())await header.click();
      assert(await body.isVisible(),'Every applicable section body must open: '+slug);applicableSections++;
    }
  }
  assert.equal(applicableSections,11);proof.cases.push({width,name:'ordinary DOM selection exposes all11 applicable sections and excludes component-instance parameters',ordinarySelection});
  const choices=page.locator('[data-choice-group-trigger]');
  const choiceCount=await choices.count(); assert(choiceCount>0);
  for(let index=0;index<choiceCount;index++){
    const trigger=choices.nth(index);
    await trigger.scrollIntoViewIfNeeded();assert(await trigger.isVisible());await trigger.focus();await page.keyboard.press('Enter');
    await bounds('[data-choice-group-popup][data-popup-open="true"]');
    await page.keyboard.press('Shift+Tab');
    assert(await page.locator('[data-choice-group-popup][data-popup-open="true"]').evaluate(el=>el.contains(document.activeElement) && document.activeElement.getAttribute('aria-disabled')!=='true'),'Shift+Tab wraps to an enabled real option');
    await page.keyboard.press('Tab');
    assert(await page.locator('[data-choice-group-popup][data-popup-open="true"]').evaluate(el=>el.contains(document.activeElement)),'Choice focus traversal remains in the real menu');
    await page.keyboard.press('Escape');assert(await trigger.evaluate(el=>el===document.activeElement));
  }
  const firstChoice=choices.first(),group=firstChoice.locator('xpath=..');
  const availability=await group.locator('[data-choice-group-option]').evaluateAll(nodes=>nodes.slice(0,3).map(el=>({style:el.getAttribute('style'),aria:el.getAttribute('aria-disabled'),inert:el.hasAttribute('inert')})));
  await group.locator('[data-choice-group-option]').evaluateAll(nodes=>{nodes[0].style.visibility='hidden';nodes[1].setAttribute('aria-disabled','true');nodes[2].setAttribute('inert','');});
  await firstChoice.focus();await page.keyboard.press('Enter');
  assert.equal(await page.evaluate(()=>document.activeElement.getAttribute('data-choice-group-option-label')),'Auto','Initial focus skips actual hidden, aria-disabled and inert entries');
  await page.keyboard.press('Tab');assert.equal(await page.evaluate(()=>document.activeElement.getAttribute('data-choice-group-option-label')),'Auto');
  await page.keyboard.press('Shift+Tab');assert.equal(await page.evaluate(()=>document.activeElement.getAttribute('data-choice-group-option-label')),'Auto');
  await page.keyboard.press('Escape');
  await group.locator('[data-choice-group-option]').evaluateAll((nodes,values)=>{values.forEach((saved,index)=>{const el=nodes[index];saved.style===null?el.removeAttribute('style'):el.setAttribute('style',saved.style);saved.aria===null?el.removeAttribute('aria-disabled'):el.setAttribute('aria-disabled',saved.aria);saved.inert?el.setAttribute('inert',''):el.removeAttribute('inert');});},availability);
  proof.cases.push({width,name:'real menu initial/forward/reverse focus skips hidden, aria-disabled and inert entries'});
  for(const [label,mode] of [['Hidden','pointer'],['Scroll','keyboard'],['Visible','keyboard']]){
    const before=JSON.parse(await page.evaluate(()=>window.__popupAcceptance.snapshot())).undoCount;
    await firstChoice.focus();await page.keyboard.press('Enter');
    const menu=page.locator('[data-choice-group-popup][data-popup-open="true"]');
    await menu.evaluate(root=>{
      const audit=[];window.__choiceFocusAudit=audit;
      for(const name of ['sync','dispose']){
        const original=root.__isonimPopover[name];
        root.__isonimPopover[name]=function(...args){
          const snapshot=phase=>audit.push({name,phase,open:args[0],connected:root.isConnected,active:document.activeElement?.outerHTML?.slice(0,400)});
          snapshot('before');const result=original.apply(this,args);snapshot('after');return result;
        };
      }
    });
    assert(await menu.evaluate(el=>el.contains(document.activeElement)),'Opening focuses an actual menu option');
    if(mode==='pointer')await menu.locator('[data-choice-group-option-label="'+label+'"]').click();
    else {
      for(let step=0;step<4 && await page.evaluate(()=>document.activeElement.getAttribute('data-choice-group-option-label'))!==label;step++)await page.keyboard.press('ArrowDown');
      assert.equal(await page.evaluate(()=>document.activeElement.getAttribute('data-choice-group-option-label')),label);
      await page.keyboard.press('Enter');
    }
    assert.equal(await firstChoice.locator('[data-choice-group-trigger-label]').innerText(),label,'Distinct choices must capture their own actual value');
    assert.equal(await menu.count(),0,'Each selection closes its actual menu');
    proof.choiceFocusTransitions??=[];proof.choiceFocusTransitions.push({width,label,events:await page.evaluate(()=>window.__choiceFocusAudit)});
    assert(await firstChoice.evaluate(el=>el===document.activeElement),'Selection returns focus to its actual invoker');
    assert.equal(JSON.parse(await page.evaluate(()=>window.__popupAcceptance.snapshot())).undoCount,before+1,'Each actual pointer/keyboard activation dispatches one production edit');
  }
  // An explicit user focus during the real accepted click must win over
  // replacement-invoker restoration in the next microtask.
  await firstChoice.click();
  const focusChoice=page.locator('[data-choice-group-popup][data-popup-open="true"] [data-choice-group-option-label="Hidden"]');
  await focusChoice.evaluate(el=>el.addEventListener('click',()=>document.querySelector('[data-layer-search]').focus(),{once:true}));
  await focusChoice.click();assert(await layerSearch.evaluate(el=>el===document.activeElement));
  await firstChoice.click();await page.locator('[data-choice-group-popup][data-popup-open="true"] [data-choice-group-option-label="Visible"]').click();
  await firstChoice.click();
  const selectionChoice=page.locator('[data-choice-group-popup][data-popup-open="true"] [data-choice-group-option-label="Scroll"]');
  await selectionChoice.evaluate(el=>el.addEventListener('click',()=>{window.__popupAcceptance.select('secondary-action');document.activeElement.blur();},{once:true}));
  await selectionChoice.click();
  assert.equal(JSON.parse(await page.evaluate(()=>window.__popupAcceptance.snapshot())).selected,'secondary-action');
  assert(await page.evaluate(()=>document.activeElement===document.body),'Selection changes invalidate delayed focus restoration');
  assert(await page.evaluate(()=>window.__popupAcceptance.select('action')));
  await page.locator('[data-fill-row-linked-chip]').waitFor();
  // Conditional controls remain real mounted scope menus. Reveal their actual
  // owning configuration before sweeping every summary; no hidden row is skipped.
  const conditionalBefore=JSON.parse(await page.evaluate(()=>window.__popupAcceptance.snapshot())).undoCount;
  await page.locator('[data-layout-mode="vertical"]').click();
  await page.locator('[data-layout-gap-host]').waitFor({state:'visible'});
  const perCornerToggle=page.locator('[data-property-row="per-corner"] input[type="checkbox"]');
  assert.equal(await perCornerToggle.count(),1);await perCornerToggle.check();assert(await perCornerToggle.isChecked());
  await page.locator('[data-appearance-percorner-host]').waitFor({state:'visible'});
  assert.equal(JSON.parse(await page.evaluate(()=>window.__popupAcceptance.snapshot())).undoCount,conditionalBefore,'Disclosure configuration creates no property edit');
  const summaries=page.locator('.editor-inspector summary');const summaryCount=await summaries.count();assert(summaryCount>0);
  for(let index=0;index<summaryCount;index++){
    const trigger=summaries.nth(index);await trigger.scrollIntoViewIfNeeded();await trigger.focus();await page.keyboard.press('Enter');
    await bounds('[data-compact-choice-popup]:popover-open');
    await page.keyboard.press('Escape');assert(await trigger.evaluate(el=>el===document.activeElement));
  }
  proof.cases.push({width,name:'all mounted choice menus and source-scope details, native activation, theme and focus; three distinct actual choices',choiceCount,summaryCount});
  // All popup families use their original production invoker at each edge.
  // Relocation is controlled geometry stimulus; controls, ownership and handlers
  // are unchanged. The actual popup is also constrained after live resize.
  const edgeFamily=async(invoker,selector,family,prepare=null)=>{
    const style=await invoker.getAttribute('style');
    for(const [edge,x,y] of [['top-left',1,1],['top-right',width-19,1],['bottom-left',1,881],['bottom-right',width-19,881]]){
      if(prepare)await prepare(edge,x,y);
      else await invoker.evaluate((el,{x,y})=>{Object.assign(el.style,{position:'fixed',left:x+'px',top:y+'px',width:'18px',minWidth:'0',maxWidth:'18px',height:'18px',zIndex:'1400'});const b=el.getBoundingClientRect();el.style.left=(parseFloat(el.style.left)+x-b.left)+'px';el.style.top=(parseFloat(el.style.top)+y-b.top)+'px';},{x,y});
      assert(await invoker.isVisible());await invoker.click();
      const invokerBounds=await invoker.boundingBox();
      const atEdge=await bounds(selector);
      await page.setViewportSize({width,height:family==='token'?160:80});const small=await bounds(selector);
      assert(await page.locator(selector).evaluate(el=>[el,...el.querySelectorAll('*')].some(node=>node.scrollHeight>node.clientHeight && /auto|scroll/.test(getComputedStyle(node).overflowY))),'A genuinely oversized '+family+' popup must internally scroll');
      const focusedReachable=async()=>await page.locator(selector).evaluate(root=>{
        const el=document.activeElement;if(!root.contains(el))return false;
        const r=el.getBoundingClientRect(),hit=document.elementFromPoint(r.left+r.width/2,r.top+r.height/2);
        return !!hit&&(hit===el||el.contains(hit));
      });
      const underlyingScrolls=()=>page.evaluate(()=>['[data-sidebar-story-tree]','[data-scene-graph-rows]','[data-inspector-section-list]'].map(selector=>{const el=document.querySelector(selector);return {selector,top:el.scrollTop,left:el.scrollLeft};}).concat([{selector:'document',top:document.scrollingElement.scrollTop,left:document.scrollingElement.scrollLeft}]));
      const beforeFocusScrolls=await underlyingScrolls();
      await page.keyboard.press('Shift+Tab');
      assert(await focusedReachable(),'Oversized '+family+' last enabled control must be visible and reachable when focused');
      await page.keyboard.press('Tab');
      assert(await focusedReachable(),'Oversized '+family+' first enabled control must be visible and reachable when focused');
      assert.deepEqual(await underlyingScrolls(),beforeFocusScrolls,'Popup keyboard traversal must preserve underlying editor scroll positions');
      const end=page.locator(selector).locator('input:not([disabled]),button:not([disabled]),[role="button"]:not([aria-disabled="true"]),[role="option"]:not([aria-disabled="true"])').filter({visible:true}).last();
      await end.scrollIntoViewIfNeeded();
      assert(await end.evaluate(el=>{const r=el.getBoundingClientRect(),hit=document.elementFromPoint(r.left+r.width/2,r.top+r.height/2);return !!hit&&(hit===el||el.contains(hit));}),'Actual final '+family+' control remains pointer reachable');
      await page.keyboard.press('Escape');await page.setViewportSize({width,height:900});
      assert(await invoker.evaluate(el=>el===document.activeElement),'Edge dismissal returns focus to the original '+family+' invoker');
      proof.cases.push({width,name:family+' actual edge/oversize/pointer reach '+edge,invokerBounds,atEdge,small,underlyingScrolls:beforeFocusScrolls});
    }
    await invoker.evaluate((el,style)=>style===null?el.removeAttribute('style'):el.setAttribute('style',style),style);
  };
  await edgeFamily(firstChoice,'[data-choice-group-popup][data-popup-open="true"]','choice');
  await edgeFamily(summaries.first(),'[data-compact-choice-popup]:popover-open','scope');
  const tokenInvoker=page.locator('[data-fill-row-linked-chip] [data-variable-chip-chevron]');
  await edgeFamily(tokenInvoker,'[data-variable-picker-open="true"]','token');
  await tokenInvoker.click();await page.locator('[data-variable-picker-open="true"]').waitFor();
  const parentStyle=await page.locator('[data-variable-picker]').getAttribute('style');
  const parentInvokerStyle=await tokenInvoker.getAttribute('style');
  await page.locator('[data-variable-picker]').evaluate(el=>{el.style.transform='scale(.95)';el.style.transformOrigin='center';});
  // A transformed, scrolling parent clips children moved outside its box.
  // Move its actual anchor, then open the visible edge-side original Edit.
  await page.locator('[data-variable-picker-row-edit]').first().evaluate(el=>el.setAttribute('data-edge-value-invoker','true'));
  await edgeFamily(page.locator('[data-edge-value-invoker]'),'[data-variable-inline-editor-open="true"]','value under transformed popup ancestor',async(edge,x,y)=>{
    await tokenInvoker.evaluate((el,{x,y})=>Object.assign(el.style,{position:'fixed',left:x+'px',top:y+'px',width:'18px',height:'18px'}),{x,y});
    await bounds('[data-variable-picker-open="true"]');
    await page.locator('[data-edge-value-invoker]').evaluate(el=>el.removeAttribute('data-edge-value-invoker'));
    const edit=edge.startsWith('bottom')?page.locator('[data-variable-picker-row-edit]').last():page.locator('[data-variable-picker-row-edit]').first();
    await edit.scrollIntoViewIfNeeded();await edit.evaluate(el=>el.setAttribute('data-edge-value-invoker','true'));
  });
  await page.locator('[data-edge-value-invoker]').evaluate(el=>el.removeAttribute('data-edge-value-invoker'));
  await tokenInvoker.evaluate((el,style)=>style===null?el.removeAttribute('style'):el.setAttribute('style',style),parentInvokerStyle);
  await page.locator('[data-variable-picker]').evaluate((el,style)=>el.setAttribute('style',style),parentStyle);
  await page.keyboard.press('Escape');
  // Literal and Fill colours share the production popup, not a marker. The
  // Fill swatch is exposed by actual detachment of its token binding.
  await page.locator('[data-fill-row-linked-chip]').hover();
  assert(await page.locator('[data-fill-row-linked-chip] [data-variable-chip-detach]').isVisible());
  await page.locator('[data-fill-row-linked-chip] [data-variable-chip-detach]').click();
  await edgeFamily(page.locator('[data-fill-row-swatch="0"]'),'[data-color-popover-open="true"]','Fill color');
  await edgeFamily(literal,'[data-color-popover-open="true"]','literal color');
  // Remove the real invoker without a selection change: the live controller
  // must close on the next frame and refuse the retained real Apply handler.
  await literal.click();const retainedApply=await page.locator('[data-color-popover-open="true"] [data-color-popover-apply]').elementHandle();
  const unchanged=await page.evaluate(()=>window.__popupAcceptance.snapshot());
  const disconnected=await literal.elementHandle();
  await disconnected.evaluate(el=>{window.__disconnectedPopupInvoker={el,parent:el.parentNode,next:el.nextSibling};el.remove();});
  await page.waitForFunction(()=>!document.querySelector('[data-color-popover-open="true"]'));
  await retainedApply.evaluate(el=>el.click());assert.equal(await page.evaluate(()=>window.__popupAcceptance.snapshot()),unchanged);
  await page.evaluate(()=>{const {el,parent,next}=window.__disconnectedPopupInvoker;parent.insertBefore(el,next);delete window.__disconnectedPopupInvoker;});
  proof.cases.push({width,name:'actual disconnected invoker closes live popup and retained Apply cannot commit'});
  const listenerBaseline=await page.evaluate(()=>window.__actualPopoverListenerCount());
  for(let round=0;round<12;round++){
    assert(await page.evaluate(()=>window.__popupAcceptance.select('secondary-action')));
    assert(await page.evaluate(()=>window.__popupAcceptance.select('action')));
  }
  await page.waitForTimeout(50);
  assert.equal(await page.evaluate(()=>window.__actualPopoverListenerCount()),listenerBaseline,'Selection-owned controller disposal must remove its real document listeners');
  proof.cases.push({width,name:'twelve actual selection cycles preserve global listener balance',listenerBaseline});
  // Text and box Fill target actual distinct CSS properties. This is real
  // source-backed text with authored colour, selected through its layer row.
  await page.locator('[data-scene-graph-row="long-text-0"]').click();
  await page.locator('[data-fill-row-bind="0"]').waitFor();
  assert.equal(await frame.locator('#long-text-0').evaluate(el=>getComputedStyle(el).color),'rgb(51, 68, 85)');
  await page.locator('[data-fill-row-bind="0"]').click();
  await page.locator('[data-variable-picker-row="color/test-12"]').click();
  const textBinding=JSON.parse(await page.evaluate(()=>window.__popupAcceptance.snapshot()));
  assert.equal(textBinding.bindings.color,'color/test-12');assert.equal(textBinding.bindings['background-color'],'');
  await page.locator('[data-fill-row-linked-chip]').hover();
  assert(await page.locator('[data-fill-row-linked-chip] [data-variable-chip-detach]').isVisible());
  await page.locator('[data-fill-row-linked-chip] [data-variable-chip-detach]').click();
  assert.equal(JSON.parse(await page.evaluate(()=>window.__popupAcceptance.snapshot())).bindings.color,'');
  const background=await frame.locator('#long-text-0').evaluate(el=>getComputedStyle(el).backgroundColor);
  await page.locator('[data-fill-row-swatch="0"]').click();
  await page.locator('[data-color-popover-open="true"] [data-color-popover-input]').fill('#22C55E');
  await page.locator('[data-color-popover-open="true"] [data-color-popover-apply]').click();
  await page.waitForFunction(()=>Array.from(document.querySelectorAll('.editor-preview iframe')).some(frame=>{const el=frame.contentDocument?.querySelector('#long-text-0');return frame.getClientRects().length && el && frame.contentWindow.getComputedStyle(el).color==='rgb(34, 197, 94)';}));
  assert.equal(await frame.locator('#long-text-0').evaluate(el=>getComputedStyle(el).backgroundColor),background);
  proof.cases.push({width,name:'actual text Fill bind/detach targets color; shared Apply commits preview color without changing background',textBinding});
  // Re-evaluate the exact compiled production bundle as HMR does. The audit
  // wraps existing delivery callbacks only to count and forwards their actual
  // arguments/side effects unchanged; no renderer/model boundary is replaced.
  const hmrBefore=await page.evaluate(()=>{
    window.__hmrRuntime=globalThis.__isonimViewRuntime;
    window.__hmrBridge=globalThis.__isonimPreviewBridge;
    return {listeners:window.__actualUiResources().listeners.map(({type,target,name})=>({type,target,name})).sort((a,b)=>JSON.stringify(a).localeCompare(JSON.stringify(b))),bridges:globalThis.__isonimViewRuntime.bridges.size};
  });
  const hmrBody=await page.evaluate(async()=>await(await fetch('/editor.js?m2-hmr-proof=1')).text());
  assert.equal(hash(hmrBody),proof.bundleSha256);
  const hmrProfiler=await page.context().newCDPSession(page);
  await hmrProfiler.send('Profiler.enable');await hmrProfiler.send('Profiler.setSamplingInterval',{interval:10000});await hmrProfiler.send('Profiler.start');
  const hmrSourceBefore=JSON.parse(await page.evaluate(()=>window.__popupAcceptance.snapshot()));
  proof.hmrStateBefore=hmrSourceBefore;writeFileSync(root+'/proof-partial.json',JSON.stringify(proof,null,2));
  const refreshedSource=page.waitForResponse(response=>new URL(response.url()).pathname==='/api/editor/source/catalog'&&response.request().method()==='GET');
  try {
  await bounded(page.addScriptTag({url:origin+'/editor.js?m2-hmr=1'}),'Exact production-bundle HMR');
  await bounded(refreshedSource,'Actual HMR source-catalog response');
  await bounded(page.waitForFunction(generation=>JSON.parse(window.__popupAcceptance.snapshot()).sourceGeneration>=generation+2,hmrSourceBefore.sourceGeneration),'Actual applied HMR catalog');
  assert(await page.evaluate(()=>globalThis.__isonimViewRuntime===window.__hmrRuntime&&globalThis.__isonimPreviewBridge===window.__hmrBridge),'Unchanged-bundle HMR retains the actual UI runtime/registry');
  assert.equal(await page.locator('[data-isonim-editor]').count(),1);
  const hmrAfter=await page.evaluate(()=>({listeners:window.__actualUiResources().listeners.map(({type,target,name})=>({type,target,name})).sort((a,b)=>JSON.stringify(a).localeCompare(JSON.stringify(b))),bridges:globalThis.__isonimViewRuntime.bridges.size}));
  assert.deepEqual(hmrAfter,hmrBefore,'HMR retains one actual listener roster');
  await page.evaluate(()=>{
    const bridge=globalThis.__isonimViewRuntime.bridges.get('isonim-preview-element-selected');
    window.__hmrDeliveries=[];window.__hmrEventStart=window.__nativeSelectionEvents.length;window.__hmrOriginalDeliveries=[];
    for(const [node,callback] of bridge.owners){
      const wrapper=event=>{window.__hmrDeliveries.push({eventId:window.__nativeSelectionIdentities.get(event),id:event.detail.elementId,connected:node.isConnected,visible:!!node.getClientRects().length});return callback(event);};
      window.__hmrOriginalDeliveries.push({node,callback,wrapper});bridge.owners.set(node,wrapper);
    }
  });
  await frame.locator('#action').evaluate(el=>el.click());
  const nativeDelivery=await page.evaluate(()=>({events:window.__nativeSelectionEvents.slice(window.__hmrEventStart),deliveries:window.__hmrDeliveries}));
  verifyNativeDeliveries(nativeDelivery.events,nativeDelivery.deliveries);
  assert.equal(JSON.parse(await page.evaluate(()=>window.__popupAcceptance.snapshot())).selected,'action');
  // A real additional parent listener deliberately forwards the native event
  // through the actual production dispatcher. The same audit must reject it.
  await page.evaluate(()=>{
    const bridge=globalThis.__isonimViewRuntime.bridges.get('isonim-preview-element-selected');
    window.__hmrDeliveries=[];window.__hmrEventStart=window.__nativeSelectionEvents.length;
    window.__duplicatePreviewDelivery=event=>bridge.listener(event);
    window.addEventListener('isonim-preview-element-selected',window.__duplicatePreviewDelivery);
  });
  let duplicateDelivery;
  try {
    await frame.locator('#secondary-action').evaluate(el=>el.click());
    duplicateDelivery=await page.evaluate(()=>({events:window.__nativeSelectionEvents.slice(window.__hmrEventStart),deliveries:window.__hmrDeliveries}));
    assert.throws(()=>verifyNativeDeliveries(duplicateDelivery.events,duplicateDelivery.deliveries),/one actual production delivery|exactly once/,'Audit must reject genuine duplicated production delivery');
  } finally {
    await page.evaluate(()=>{
      window.removeEventListener('isonim-preview-element-selected',window.__duplicatePreviewDelivery);delete window.__duplicatePreviewDelivery;
      const bridge=globalThis.__isonimViewRuntime.bridges.get('isonim-preview-element-selected');
      for(const {node,callback,wrapper} of window.__hmrOriginalDeliveries)if(bridge.owners.get(node)===wrapper)bridge.owners.set(node,callback);
    });
  }
  assert(await page.evaluate(()=>window.__popupAcceptance.select('action')));
  assert.equal(JSON.parse(await page.evaluate(()=>window.__popupAcceptance.snapshot())).selected,'action');
  proof.cases.push({width,name:'exact production bundle HMR retains shared runtime, listener roster and once-only visible preview delivery',bundleSha256:hash(hmrBody),hmrBefore,hmrAfter,nativeDelivery,duplicateDelivery});
  } finally {
    try {const profile=await bounded(hmrProfiler.send('Profiler.stop'),'HMR CPU profile',2000);writeFileSync(root+'/hmr-profile-'+width+'.json',JSON.stringify(profile));}catch(error){writeFileSync(root+'/hmr-profile-error-'+width+'.txt',String(error));}
  }
  // Completed selection-scroll frames release their owner cleanup entries.
  // This repeatedly uses actual production selection rather than directly
  // invoking the scheduler or substituting a timer implementation.
  await page.evaluate(()=>window.__popupAcceptance.select('action'));
  await page.waitForTimeout(80);
  const cleanupSize=await page.locator('[data-scene-graph-rows]').evaluate(el=>el.__isonimViewCleanups?.size||0);
  const readerObserversBefore=await page.evaluate(()=>window.__actualUiResources().observers.length);
  await page.evaluate(()=>{
    window.__actualReaderModel=[...window.__isonimSceneGraphReaderRuntime.records.keys()][0];
    window.__actualModelOwnerAudit=()=>{
      const model=window.__actualReaderModel;
      const signals={selected:model.inspector.selectedElement,preview:model.preview.current.signal,reload:model.livePreviewReloadGeneration};
      const memoPaths=new Map(),seen=new Set();
      const visit=(value,path,depth=0)=>{
        if(!value || typeof value!=='object' || seen.has(value) || depth>8)return;
        seen.add(value);
        if(value.computation && (value.signal || value.observers)){
          memoPaths.set(value.computation,[...(memoPaths.get(value.computation)||[]),path]);return;
        }
        for(const [key,child] of Object.entries(value)){
          if(['m_type','observers','observerSlots','sources','sourceSlots','owned','owner','fn','cleanups','contextTable','computation'].includes(key))continue;
          if(key==='value' && value.observers)continue;
          if(Array.isArray(child) && child.every(item=>!item || typeof item!=='object'))continue;
          visit(child,path+'.'+key,depth+1);
        }
      };
      visit(model,'EditorVM');
      const describe=node=>{
        const fn=node?.fn?.ClP_0||node?.fn;
        const match=fn && String(fn).match(/filename:\s*"([^"]+)"/);
        return {name:fn?.name||null,file:match?.[1]||null};
      };
      return Object.fromEntries(Object.entries(signals).map(([key,signal])=>[key,[...new Set(signal.observers)].map(node=>{
        const owners=[];for(let owner=node.owner;owner;owner=owner.owner)owners.push(describe(owner));
        const callback=node.fn?.ClE_0?.fn0;
        return {computation:describe(node),callback:callback?describe({fn:callback}):null,
          memoPaths:memoPaths.get(node)||[],owners,sourceEdges:node.sources.length};
      }).sort((a,b)=>JSON.stringify(a).localeCompare(JSON.stringify(b)))]));
    };
    window.__actualGraphAudit=()=>{
      const result={};
      for(const key of ['selectedElement','designSystemSchema','propertyBindings','properties']){
        const value=window.__actualReaderModel.inspector[key],signal=value?.observers?value:value?.signal;
        let bad=0;
        for(let i=0;i<signal.observers.length;i++){
          const observer=signal.observers[i],slot=signal.observerSlots[i];
          if(observer.sources[slot]!==signal||observer.sourceSlots[slot]!==i)bad++;
        }
        result[key]={observers:signal.observers.length,slots:signal.observerSlots.length,bad};
      }
      return result;
    };
  });
  const graphFalsifier=await page.evaluate(()=>{
    const signal=window.__actualReaderModel.inspector.selectedElement;
    const original=signal.observerSlots[0];
    try {signal.observerSlots[0]=1000000;return window.__actualGraphAudit();}
    finally {signal.observerSlots[0]=original;}
  });
  assert(graphFalsifier.selectedElement.bad>0,'Real reciprocal-slot corruption falsifies the graph audit');
  const pairedGraphCounts={};
  const schedulingProfiler=await page.context().newCDPSession(page);
  await schedulingProfiler.send('Profiler.enable');await schedulingProfiler.send('Profiler.setSamplingInterval',{interval:10000});await schedulingProfiler.send('Profiler.start');
  try {
    for(let i=0;i<20;i++){
      proof.scheduling={width,iteration:i,id:i%2?'action':'secondary-action'};writeFileSync(root+'/proof-partial.json',JSON.stringify(proof,null,2));
      assert(await page.evaluate(id=>window.__popupAcceptance.select(id),proof.scheduling.id));
      await page.waitForTimeout(30);
      const graph=await page.evaluate(()=>window.__actualGraphAudit());
      for(const [key,value] of Object.entries(graph))assert.equal(value.bad,0,'Actual '+key+' reciprocal observer slots remain valid');
      if(pairedGraphCounts[proof.scheduling.id])assert.deepEqual(graph,pairedGraphCounts[proof.scheduling.id],'Returning to the same real selection must not grow observer subscriptions');
      else pairedGraphCounts[proof.scheduling.id]=graph;
    }
  } finally {
    try{const profile=await bounded(schedulingProfiler.send('Profiler.stop'),'Selection scheduling profile',2000);writeFileSync(root+'/selection-profile-'+width+'.json',JSON.stringify(profile));}catch(error){writeFileSync(root+'/selection-profile-error-'+width+'.txt',String(error));}
  }
  await page.waitForTimeout(80);
  assert.equal(await page.locator('[data-scene-graph-rows]').evaluate(el=>el.__isonimViewCleanups?.size||0),cleanupSize,'Completed repeated actual UI scheduling does not retain cleanup closures');
  assert.equal(await page.evaluate(()=>window.__actualUiResources().observers.length),readerObserversBefore,'Twenty selections do not grow actual DOM observer ownership');
  proof.cases.push({width,name:'twenty production selection-scroll schedules release completed owner resources with bounded real reciprocal signal subscriptions',cleanupSize,pairedGraphCounts,graphFalsifier});
  // Whole production UI ownership: pending shortcut focus, idempotent teardown,
  // retained VM/client, remount, and one undo/redo dispatch after remount.
  await page.locator('[data-fill-row-swatch="0"]').click();
  await bounds('[data-color-popover-open="true"]');
  const dragHandle=page.locator('[data-resize-handle="left-sidebar"]');
  const dragRect=await dragHandle.boundingBox();assert(dragRect);
  await page.mouse.move(dragRect.x+dragRect.width/2,dragRect.y+40);
  await page.mouse.down();
  assert.equal(await page.evaluate(()=>document.body.style.cursor),'col-resize');
  // Keep the original open-popup teardown gate while a genuine drag remains
  // active: opening by keyboard does not send mouseup or outside pointerdown.
  await page.locator('[data-fill-row-swatch="0"]').focus();await page.keyboard.press('Enter');
  await bounds('[data-color-popover-open="true"]');
  const stateBefore=await page.evaluate(()=>window.__popupAcceptance.snapshot());
  const resourcesBefore=await page.evaluate(()=>window.__actualUiResources());
  assert(resourcesBefore.listeners.length>5);assert(resourcesBefore.observers.length>0);assert(resourcesBefore.pending.some(r=>r.schedule==='setInterval'));
  const lifecycle=await page.evaluate(()=>{
    const focus=HTMLElement.prototype.focus,attempts=[];
    HTMLElement.prototype.focus=function(...args){attempts.push({tag:this.tagName,connected:this.isConnected});return focus.apply(this,args);};
    document.body.dispatchEvent(new KeyboardEvent('keydown',{key:'k',code:'KeyK',ctrlKey:true,bubbles:true}));
    const first=window.__popupAcceptance.unmount(),second=window.__popupAcceptance.unmount();
    window.__lifecycleFocusAudit={focus,attempts};
    return {first,second,listeners:window.__actualPopoverListenerCount(),shells:document.querySelectorAll('[data-isonim-editor]').length,attempts:attempts.slice(),sameClient:window.__popupAcceptance.sameClient(),resources:window.__actualUiResources(),cursor:document.body.style.cursor,userSelect:document.body.style.userSelect};
  });
  assert(lifecycle.first);assert(!lifecycle.second);assert.equal(lifecycle.listeners,0);assert.equal(lifecycle.shells,0);assert.deepEqual(lifecycle.attempts,[]);assert(lifecycle.sameClient);
  assert.equal(lifecycle.cursor,'');assert.equal(lifecycle.userSelect,'');
  assert.deepEqual(lifecycle.resources.listeners,[],'Whole UI disposal removes actual parent UI registrations');
  assert.deepEqual(lifecycle.resources.observers,[],'Whole UI disposal disconnects actual UI observers');
  assert.deepEqual(lifecycle.resources.pending,[],'Whole UI disposal cancels actual queued UI work and polling');
  const stateAfterUnmount=await page.evaluate(()=>window.__popupAcceptance.snapshot());
  // The original oracle covers retained VM state. M3's additional diagnostic
  // observer counts describe mounted UI ownership and must decrease on disposal.
  const persistentState=raw=>{const state=JSON.parse(raw);delete state.reactiveObservers;return state;};
  assert.deepEqual(persistentState(stateAfterUnmount),persistentState(stateBefore));
  const mountedGraph=JSON.parse(stateBefore).reactiveObservers,disposedGraph=JSON.parse(stateAfterUnmount).reactiveObservers;
  assert.equal(disposedGraph.preview,0,'Disposed UI retains no preview subscriptions');
  assert(disposedGraph.selected<mountedGraph.selected,'Actual selected-element UI subscriptions are disposed');
  assert(disposedGraph.reload<mountedGraph.reload,'Actual UI reload subscriptions are disposed');
  assert(Object.values(await page.evaluate(()=>window.__actualGraphAudit())).every(value=>value.bad===0),'Retained VM subscriptions still have valid reciprocal slots');
  const modelOwnerBaseline=await page.evaluate(()=>window.__actualModelOwnerAudit());
  proof.modelOwnerAudits??=[];proof.modelOwnerAudits.push({width,phase:'first settled unmount',graph:modelOwnerBaseline});
  assert.equal(modelOwnerBaseline.preview.length,0);
  for(const node of [...modelOwnerBaseline.selected,...modelOwnerBaseline.reload]){
    const lineage=[node.computation,...(node.callback?[node.callback]:[]),...node.owners];
    assert(node.computation.name,'A retained computation must still be live');
    assert(lineage.every(owner=>!owner.file || !/\/editor\/views\/|\/dsl\/|\/dom\//.test(owner.file)),'Disposed UI computations and their owned children cannot remain subscribed');
    assert(node.memoPaths.length>0,'Retained memo identity is held by an actual VM field, excluding observer/owner graphs');
    assert(lineage.some(owner=>owner.file && /\/editor\/(viewmodels|source_browser|streaming_preview)\.nim$/.test(owner.file)),'Every retained subscription has actual model/source callback provenance');
  }


  assert.equal(await page.evaluate(()=>window.__isonimSceneGraphReaderRuntime.records.size),0,'Last real mount releases its parent reader record');
  assert(await page.evaluate(()=>window.__readerControl.closed&&window.__readerControl.doc===null&&window.__readerControl.roots.size===0),'Disposed reader retains no document/observer/root');
  await page.mouse.move(dragRect.x+70,dragRect.y+50);
  await page.evaluate(()=>window.dispatchEvent(new CustomEvent('isonim-preview-element-hovered',{detail:{id:'stale-owner-hover'}})));
  await page.waitForTimeout(800);
  assert.deepEqual(await page.evaluate(()=>window.__lifecycleFocusAudit.attempts),[],'Disposed shortcuts/popovers cannot restore focus later');
  assert.equal(await page.evaluate(()=>window.__popupAcceptance.snapshot()),stateAfterUnmount,'Stale UI events cannot mutate retained VM state or resurrect subscriptions');
  await page.evaluate(()=>{HTMLElement.prototype.focus=window.__lifecycleFocusAudit.focus;delete window.__lifecycleFocusAudit;});
  assert(await page.evaluate(()=>window.__popupAcceptance.remount()));assert(await page.evaluate(()=>window.__popupAcceptance.sameClient()));
  assert.equal(await page.locator('[data-isonim-editor]').count(),1);
  const widthsBefore=JSON.parse(await page.evaluate(()=>window.__popupAcceptance.snapshot()));
  await page.mouse.move(dragRect.x+100,dragRect.y+60);await page.mouse.up();
  const widthsAfter=JSON.parse(await page.evaluate(()=>window.__popupAcceptance.snapshot()));
  assert.equal(widthsAfter.leftWidth,widthsBefore.leftWidth,'Disposed active resize cannot mutate remounted UI');
  assert.equal(widthsAfter.rightWidth,widthsBefore.rightWidth);
  // Repeat complete mount ownership, retaining the VM/client and checking the
  // listener roster rather than relying on one successful disposal.
  const remountedListeners=await page.evaluate(()=>window.__actualUiResources().listeners.map(({type,target,name})=>({type,target,name})).sort((a,b)=>JSON.stringify(a).localeCompare(JSON.stringify(b))));
  assert(await page.evaluate(()=>window.__popupAcceptance.unmount()));
  assert.deepEqual(await page.evaluate(()=>window.__actualUiResources()),{listeners:[],pending:[],observers:[]});
  const repeatedModelOwnerBaseline=await page.evaluate(()=>window.__actualModelOwnerAudit());
  assert.deepEqual(repeatedModelOwnerBaseline,modelOwnerBaseline,'Repeated mount/unmount retains exactly the same model-owned graph');
  proof.modelOwnerAudits.push({width,phase:'repeated settled unmount',graph:repeatedModelOwnerBaseline});

  assert(await page.evaluate(()=>window.__popupAcceptance.remount()));
  const repeatedListeners=await page.evaluate(()=>window.__actualUiResources().listeners.map(({type,target,name})=>({type,target,name})).sort((a,b)=>JSON.stringify(a).localeCompare(JSON.stringify(b))));
  assert.deepEqual(repeatedListeners,remountedListeners,'Remount has exactly one identical UI listener roster');
  // Ctrl+K deliberately retained the palette VM state across teardown.
  // Close its actual remounted dialog before exercising the uncovered handle.
  const retainedPalette=page.locator('[data-editor-command-palette]');
  assert.equal(await retainedPalette.getAttribute('aria-hidden'),'false','Queued-focus stimulus retains model state across remount');
  await page.keyboard.press('Escape');
  await retainedPalette.waitFor({state:'hidden'});
  const freshHandle=page.locator('[data-resize-handle="left-sidebar"]'),freshRect=await freshHandle.boundingBox();assert(freshRect);
  assert(await freshHandle.evaluate(el=>{const b=el.getBoundingClientRect();return el===document.elementFromPoint(b.x+b.width/2,b.y+40);}), 'Actual remounted resize stimulus hits its uncovered invoker');
  await page.evaluate(()=>{const original=window.__isonimEditor.setLeftSidebarWidth;window.__resizeDispatchAudit={original,calls:[]};window.__isonimEditor.setLeftSidebarWidth=function(value){window.__resizeDispatchAudit.calls.push(value);return original(value);};});
  try {
    proof.resizeStimulus={rect:freshRect,before:await page.evaluate(({x,y})=>{const target=document.elementFromPoint(x,y);return {target:target?.getAttribute('data-resize-handle')||target?.tagName,cursor:document.body.style.cursor,listeners:window.__actualUiResources().listeners.filter(r=>r.type==='mousemove')};},{x:freshRect.x+freshRect.width/2,y:freshRect.y+40})};
    await page.mouse.move(freshRect.x+freshRect.width/2,freshRect.y+40);await page.mouse.down();proof.resizeStimulus.during=await page.evaluate(()=>({cursor:document.body.style.cursor,hook:window.__isonimEditor.setLeftSidebarWidth===window.__resizeDispatchAudit.original,calls:window.__resizeDispatchAudit.calls.slice()}));await page.mouse.move(freshRect.x+freshRect.width/2+20,freshRect.y+40);await page.mouse.up();
    assert.equal(await page.evaluate(()=>window.__resizeDispatchAudit.calls.length),1,'Remounted actual resize dispatches exactly once');
  } finally {await page.evaluate(()=>window.__isonimEditor.setLeftSidebarWidth=window.__resizeDispatchAudit.original);}
  await page.keyboard.press('Escape');await page.evaluate(()=>document.activeElement.blur());
  const undoBefore=JSON.parse(await page.evaluate(()=>window.__popupAcceptance.snapshot())).undoCount;assert(undoBefore>1);
  await page.keyboard.press('Control+z');
  assert.equal(JSON.parse(await page.evaluate(()=>window.__popupAcceptance.snapshot())).undoCount,undoBefore-1,'Remounted keyboard shortcut dispatches exactly one undo');
  await page.keyboard.press('Control+Shift+z');
  assert.equal(JSON.parse(await page.evaluate(()=>window.__popupAcceptance.snapshot())).undoCount,undoBefore,'Remounted keyboard shortcut dispatches exactly one redo');
  proof.cases.push({width,name:'production UI idempotent unmount/remount preserves same VM/client, removes popup listeners and queued focus, shortcuts dispatch once; actual UI resources and active gesture are disposed',lifecycle,resourcesBefore,remountedListeners});
  await page.emulateMedia({forcedColors:'active'});
  assert.equal(await story.evaluate(el=>getComputedStyle(el).scrollbarColor),'auto');
  await page.emulateMedia({forcedColors:'none'});
  await page.screenshot({path:root+'/editor-'+width+'.png'});
  await page.close();
 }
 proof.sourceAfterSha256=hash(readFileSync(project+'/stories.nim'));
 proof.sourceBeforeSha256=hash(readFileSync(root+'/source-before.nim'));
 assert.equal(proof.sourceAfterSha256,proof.sourceBeforeSha256);
 assert.deepEqual(proof.pageErrors,[]);
 assert.deepEqual(proof.agentRequests,[],'Popup/source acceptance must make no requests to its controlled agent peer');
 writeFileSync(root+'/proof.json',JSON.stringify(proof,null,2));
 console.log('Mounted popup acceptance passed; artifacts '+root);

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
