/** Default native-inspector composition (catalog-only preview mode is exercised
 * separately by popup acceptance). Real mounted production inspector, native authenticated source worker, private
 * files and actual Nim compiler/SSR catalog. No UI, source, compiler, HTTP or
 * dispatcher is mocked. The configured controlled decision peer only permits
 * daemon startup; this suite sends no model prompts and asserts zero agent calls.
 * One response-delivery gate forwards the real native HTTP status/body unchanged
 * after compilation, solely to hold acknowledgement across HMR. It substitutes
 * no source operation, filesystem, compiler, transport result or success outcome.
 * Removing new VM fields before first write is an explicit older-model shape
 * compatibility control; the retained editor/control/agent identity is preserved.
 * The source fixture's compile-time constraint is a real negative compiler control.
 */
import {spawn,spawnSync} from 'node:child_process';
import {mkdtempSync,cpSync,readFileSync,writeFileSync,mkdirSync,openSync,copyFileSync,statSync} from 'node:fs';
import {chromium} from '../node_modules/playwright/index.mjs';
import assert from 'node:assert/strict';
import path from 'node:path';
import {tmpdir} from 'node:os';
import {fileURLToPath} from 'node:url';
import {createHash} from 'node:crypto';
const repo=path.resolve(path.dirname(fileURLToPath(import.meta.url)),'..');
const root=mkdtempSync(path.join(process.env.ISONIM_POPUP_ARTIFACTS||tmpdir(),'inspector-source-'));
const project=root+'/project',pub=root+'/public';
cpSync(repo+'/tests/fixtures/editor_inspector_project',project,{recursive:true});mkdirSync(pub);
// Real declared transform owners in this private Nim/SSR project. The matrix
// owner is deliberately unsupported by numeric Rotation, while remaining valid CSS.
const storyFile=project+'/stories.nim';
writeFileSync(storyFile,readFileSync(storyFile,'utf8').replace('background-color:#112233; color:#FFFFFF; }','background-color:#112233; color:#FFFFFF; transform:translateX(8px) rotate(20deg) scale(1.2); opacity:0.800125; }').replace('background-color:#334455; color:#FFFFFF; }','background-color:#334455; color:#FFFFFF; transform:matrix(1,0,0,1,0,0); }'));
const ownerFile=project+'/.isonim/source-project.json',owners=JSON.parse(readFileSync(ownerFile,'utf8'));
for(const owner of owners.editableStyles)if(['action','secondary-action'].includes(owner.elementId))owner.properties.push('transform');
owners.editableStyles.find(owner=>owner.elementId==='action').properties.push('opacity');
writeFileSync(ownerFile,JSON.stringify(owners,null,2));
for(const [from,to] of [['src/isonim/editor/index.html','index.html'],['build/editor-inspector/editor.js','editor.js'],['node_modules/fabric/dist/index.min.js','fabric.min.js'],['node_modules/paper/dist/paper-core.min.js','paper-core.min.js'],['node_modules/svgo/dist/svgo.browser.js','svgo.browser.js']])copyFileSync(repo+'/'+from,pub+'/'+to);
const build=spawnSync('python3',[repo+'/tools/build_source_catalog.py',project],{env:{...process.env,ISONIM_SOURCE_FRAMEWORK:repo},encoding:'utf8',timeout:70000});
writeFileSync(root+'/catalog-build.log',build.stdout+build.stderr);assert.equal(build.status,0,build.stdout+build.stderr);
const proof={project,head:spawnSync('git',['rev-parse','HEAD'],{cwd:repo,encoding:'utf8'}).stdout.trim(),sourceState:'M3 uncommitted working copy',nativeSha256:createHash('sha256').update(readFileSync(repo+'/build/bin/isonim-review')).digest('hex'),bundleSha256:createHash('sha256').update(readFileSync(pub+'/editor.js')).digest('hex'),cases:[],errors:[],agentRequests:[],sourceRequests:[]};
const record=name=>{proof.cases.push(name);writeFileSync(root+'/proof-partial.json',JSON.stringify(proof,null,2));};
const config=root+'/agent.toml';writeFileSync(config,'[agent]\nbackend="custom"\ncommand="python3"\nargs='+JSON.stringify([repo+'/tests/helpers/editor_control_peer.py'])+'\nprimer_enabled=false\n');
const server=spawn('python3',[repo+'/tools/editor_server.py','--directory',pub,'--project-root',project,'--port','0','--bind','127.0.0.1','--config',config,'--daemon-binary',repo+'/build/bin/isonim-review'],{env:{...process.env,ISONIM_SOURCE_FRAMEWORK:repo},stdio:['ignore','pipe',openSync(root+'/server.log','w')]});
let browser,browserServer;
try {
 const origin=await new Promise((resolve,reject)=>{let text='';server.stdout.on('data',data=>{text+=data;const match=text.match(/Editor listening on (http:\/\/[^\s]+)\//);if(match)resolve(match[1]);});server.once('exit',code=>reject(Error('Server exited '+code)));setTimeout(()=>reject(Error('Server startup timeout')),70000).unref();});
 const chromeEnv={...process.env};delete chromeEnv.LD_LIBRARY_PATH;
 browserServer=await chromium.launchServer({headless:true,env:chromeEnv,executablePath:process.env.PLAYWRIGHT_CHROMIUM_EXECUTABLE});browser=await chromium.connect(browserServer.wsEndpoint());
 const page=await browser.newPage({viewport:{width:1440,height:900}});page.setDefaultTimeout(30000);
 page.on('pageerror',error=>proof.errors.push(error.message));
 page.on('request',request=>{const url=new URL(request.url());if(url.pathname.startsWith('/api/agent/'))proof.agentRequests.push(url.pathname);if(url.pathname==='/api/editor/source/operation')proof.sourceRequests.push(request.postDataJSON());});
 await page.goto(origin);await page.waitForFunction(()=>!!window.__popupAcceptance);
 await page.locator('[data-toolbar-cluster="mode"] [aria-label="Switch to edit mode"]').click();
 await page.locator('[data-scene-graph-row="action"]').click();
 const row=page.locator('[data-property-row-css-property="width"][data-property-row="w"][data-property-row-kind="numeric"]');
 await row.waitFor();assert.equal(await row.count(),1,'Actual visible width row exists');
 const input=row.locator('[data-property-row-input]');
 const snapshot=()=>page.evaluate(()=>JSON.parse(window.__popupAcceptance.snapshot()));
 const waitApplied=async(count)=>{await page.waitForFunction(count=>{const state=JSON.parse(window.__popupAcceptance.snapshot());return state.stage==='wesClean'&&state.undoCount===count;},count,{timeout:70000});};
 const source=()=>readFileSync(project+'/stories.nim','utf8');
 const previewWidth=()=>page.evaluate(()=>{const frame=[...document.querySelectorAll('iframe')].find(frame=>frame.getClientRects().length&&frame.contentDocument?.querySelector('#action'));const target=frame?.contentDocument.querySelector('#action');return target&&frame.contentWindow.getComputedStyle(target).width;});
 const reloadBundle=async(capturedBefore)=>{
  const before=capturedBefore||await snapshot();const response=page.waitForResponse(response=>new URL(response.url()).pathname==='/api/editor/source/catalog'&&response.request().method()==='GET');
  await page.addScriptTag({url:origin+'/editor.js?source-hmr='+Date.now()});assert.equal((await response).status(),200);
  await page.waitForFunction(generation=>JSON.parse(window.__popupAcceptance.snapshot()).sourceGeneration>=generation+2,before.sourceGeneration);
  assert(await page.evaluate(()=>window.__popupAcceptance.sameClient()),'HMR retains the backend client');
 };
 const compatibilityBefore=await snapshot();
 const compatibilityIdentity=await page.evaluate(()=>{
  const vm=[...window.__isonimSceneGraphReaderRuntime.records.keys()][0],identity=JSON.stringify(vm.controlInstanceId);
  const dispose=vm.sourceProjectMappingDispose;if(typeof dispose!=="function")throw Error("Installed source owner disposer required");dispose();
  for(const key of ['sourceProjectMappings','sourceProjectMappingDispose','sourceProjectBuildInFlight','sourceProjectOperationSerial'])delete vm[key];
  return identity;
 });
 await reloadBundle(compatibilityBefore);assert.equal(await page.evaluate(()=>JSON.stringify([...window.__isonimSceneGraphReaderRuntime.records.keys()][0].controlInstanceId)),compatibilityIdentity);
 assert.equal((await snapshot()).sourceOperationSerial,0);assert.equal((await snapshot()).sourceMappingObservers,1);assert.equal(proof.sourceRequests.length,0);
 record('older retained model missing source fields attaches safely without resetting editor/control/client identity');
 assert.equal(await previewWidth(),'120px');
 await input.fill('100+50px');await input.press('Enter');await input.press('Tab');
 await waitApplied(1);assert(source().includes('#action { width:150px;'));
 await page.waitForFunction(()=>{const frame=[...document.querySelectorAll('iframe')].find(frame=>frame.getClientRects().length&&frame.contentDocument?.querySelector('#action'));return frame&&frame.contentWindow.getComputedStyle(frame.contentDocument.querySelector('#action')).width==='150px';});
 assert.equal(proof.sourceRequests.length,1,'Enter/change/blur produce exactly one native transaction');record('typed arithmetic persists through native build and actual preview; Enter/blur commits once');
 await page.reload();await page.waitForFunction(()=>!!window.__popupAcceptance);await page.locator('[data-toolbar-cluster="mode"] [aria-label="Switch to edit mode"]').click();await page.locator('[data-scene-graph-row="action"]').click();
 assert.equal(await input.inputValue(),'150');assert.equal(await previewWidth(),'150px');record('reloaded editor reads the compiled source value');
 const handle=row.locator('[data-property-row-field-label]');
 await handle.evaluate(element=>{
  const input=element.parentElement.querySelector('input');window.__m3PointerTrace=[];
  for(const type of ['pointerdown','pointermove','pointerup','pointercancel','lostpointercapture'])
   element.addEventListener(type,event=>window.__m3PointerTrace.push({type,connected:element.isConnected,value:input.value,captured:element.hasPointerCapture(event.pointerId)}));
  const observer=new MutationObserver(()=>{if(!element.isConnected){window.__m3PointerTrace.push({type:'original-handle-removed',value:input.value});observer.disconnect();}});
  observer.observe(element.ownerDocument.body,{subtree:true,childList:true});
 });
 const box=await handle.boundingBox();assert(box);
 await page.mouse.move(box.x+box.width/2,box.y+box.height/2);await page.mouse.down();await page.mouse.move(box.x+box.width/2+25,box.y+box.height/2);await page.mouse.up();
 proof.pointerTrace=await page.evaluate(()=>window.__m3PointerTrace);
 writeFileSync(root+'/pointer-trace.json',JSON.stringify(proof.pointerTrace,null,2));
 assert(!proof.pointerTrace.some(event=>event.type==='original-handle-removed'),'Original scrub handle must survive its own draft changes');
 await waitApplied(1);assert(source().includes('#action { width:200px;'));assert.equal(proof.sourceRequests.length,2);record('real captured pointer scrub persists with one native operation');
 await page.evaluate(()=>window.__popupAcceptance.history(false));await page.waitForFunction(()=>JSON.parse(window.__popupAcceptance.snapshot()).stage==='wesClean',{},{timeout:70000});
 assert(source().includes('#action { width:150px;'));assert.equal((await snapshot()).undoCount,0);record('native undo restores authored declaration before moving history');
 await page.evaluate(()=>window.__popupAcceptance.history(true));await waitApplied(1);assert(source().includes('#action { width:200px;'));record('native redo compiles and restores authored declaration');
 await input.fill('10em');await input.press('Enter');await waitApplied(2);
 assert(source().includes('#action { width:10em;'));
 assert.equal(await input.inputValue(),'10');assert.equal(await row.locator('[data-property-row-unit]').textContent(),'em');
 const geometry=()=>page.evaluate(()=>{const frame=[...document.querySelectorAll('iframe')].find(frame=>frame.getClientRects().length&&frame.contentDocument?.querySelector('#action'));const css=frame.contentWindow.getComputedStyle(frame.contentDocument.querySelector('#action'));return {width:parseFloat(css.width),font:parseFloat(css.fontSize)};});
 await page.waitForFunction(()=>{const frame=[...document.querySelectorAll('iframe')].find(frame=>frame.getClientRects().length&&frame.contentDocument?.querySelector('#action'));if(!frame)return false;const css=frame.contentWindow.getComputedStyle(frame.contentDocument.querySelector('#action'));return Math.abs(parseFloat(css.width)-parseFloat(css.fontSize)*10)<=1/64;});
 assert.notEqual((await geometry()).width,10,'Rendered pixels must differ from authored em quantity');record('explicit em input persists with authored quantity and real computed geometry distinct');
 await page.reload();await page.waitForFunction(()=>!!window.__popupAcceptance);await page.locator('[data-toolbar-cluster="mode"] [aria-label="Switch to edit mode"]').click();await page.locator('[data-scene-graph-row="action"]').click();
 assert.equal(await input.inputValue(),'10');assert.equal(await row.locator('[data-property-row-unit]').textContent(),'em');record('reloaded unit and magnitude are authored em, not computed pixels');
 const emBox=await handle.boundingBox();assert(emBox);
 await page.mouse.move(emBox.x+emBox.width/2,emBox.y+emBox.height/2);await page.mouse.down();await page.mouse.move(emBox.x+emBox.width/2+5,emBox.y+emBox.height/2);await page.mouse.up();
 await waitApplied(1);assert(source().includes('#action { width:20em;'));
 assert.equal(await input.inputValue(),'20');assert.equal(await row.locator('[data-property-row-unit]').textContent(),'em');
 await page.waitForFunction(()=>{const frame=[...document.querySelectorAll('iframe')].find(frame=>frame.getClientRects().length&&frame.contentDocument?.querySelector('#action'));if(!frame)return false;const css=frame.contentWindow.getComputedStyle(frame.contentDocument.querySelector('#action'));return Math.abs(parseFloat(css.width)-parseFloat(css.fontSize)*20)<=1/64;});
 record('scrub after reload changes declared em magnitude without multiplying computed pixels');
 // Zero motion and canceled actual captured gestures never request source/history.
 const priorSource=source(), priorRequests=proof.sourceRequests.length, priorHistory=(await snapshot()).undoCount;
 const cancelBox=await handle.boundingBox();assert(cancelBox);
 const startX=cancelBox.x+cancelBox.width/2,startY=cancelBox.y+cancelBox.height/2;
 await page.mouse.move(startX,startY);await page.mouse.down();await page.mouse.up();
 assert.equal(proof.sourceRequests.length,priorRequests);assert.equal((await snapshot()).undoCount,priorHistory);
 await page.mouse.move(startX,startY);await page.mouse.down();await page.mouse.move(startX+20,startY);await page.keyboard.press('Escape');await page.mouse.up();
 assert.equal(await input.inputValue(),'20');assert.equal(source(),priorSource);assert.equal(proof.sourceRequests.length,priorRequests);
 await page.mouse.move(startX,startY);await page.mouse.down();await page.mouse.move(startX+10,startY);await page.mouse.move(startX,startY);await page.mouse.up();
 assert.equal(proof.sourceRequests.length,priorRequests);assert.equal((await snapshot()).undoCount,priorHistory);
 record('stationary, return-to-start and Escape-canceled captured gestures create no source write or history');
 // Complete grammar rejection restores authored units/control and leaves source intact.
 for(const invalid of ['12garbage','(10+2','1e999px','NaNpx']) {
  await input.fill(invalid);await input.press('Enter');await input.press('Tab');
  assert.equal(await input.inputValue(),'20');assert.equal(source(),priorSource);assert.equal(proof.sourceRequests.length,priorRequests);
 }
 record('malformed and nonfinite typed values are refused without source/history changes');
 // Actual compiler failure restores source/catalog and the confirmed control.
 const catalogBefore=readFileSync(project+'/.isonim/catalog.json','utf8');
 await input.fill('777px');await input.press('Enter');
 await page.waitForFunction(()=>JSON.parse(window.__popupAcceptance.snapshot()).stage==='wesFailed',null,{timeout:70000});
 assert.equal(source(),priorSource);assert.equal(readFileSync(project+'/.isonim/catalog.json','utf8'),catalogBefore);
 assert.equal(await input.inputValue(),'20');assert.equal((await snapshot()).undoCount,priorHistory);
 assert.equal(await row.locator('[data-property-row-unit]').textContent(),'em');
 record('actual native compiler refusal restores exact source, published catalog, control and history');
 // Color channel typing and real pointer plane/hue/alpha edit the same draft;
 // only confirmed Apply creates one guarded source operation.
 const swatch=page.locator('[data-fill-row-swatch="0"]');assert.equal(await swatch.count(),1);
 await swatch.click();const picker=page.locator('[data-color-popover-open="true"]');await picker.waitFor();
 const beforeColor=proof.sourceRequests.length;
 for(const [channel,value] of [['Red','10'],['Green','20'],['Blue','30'],['Alpha %','25']]) {
  const field=picker.locator('[data-color-channel="'+channel+'"]');await field.fill(value);await field.press('Tab');
 }
 assert.equal(await picker.locator('[data-color-popover-input]').inputValue(),'#0A141E40');
 assert.equal(proof.sourceRequests.length,beforeColor);await picker.locator('[data-color-popover-apply]').click();
 await waitApplied(priorHistory+1);assert(source().includes('background-color:#0a141e40;'));
 assert.equal(proof.sourceRequests.length,beforeColor+1);record('typed RGBA channels apply one compiled native source edit');
 await swatch.click();await picker.waitFor();const plane=picker.locator('[data-color-plane]');const planeBox=await plane.boundingBox();assert(planeBox);
 await page.mouse.move(planeBox.x+planeBox.width*.7,planeBox.y+planeBox.height*.3);await page.mouse.down();await page.mouse.move(planeBox.x+planeBox.width*.8,planeBox.y+planeBox.height*.2);await page.mouse.up();
 const alpha=picker.locator('[data-color-alpha]');const alphaBox=await alpha.boundingBox();assert(alphaBox);
 await page.mouse.click(alphaBox.x+alphaBox.width*.5,alphaBox.y+alphaBox.height/2);
 const pointerDraft=await picker.locator('[data-color-popover-input]').inputValue();assert.notEqual(pointerDraft,'#0A141E40');
 assert.equal(proof.sourceRequests.length,beforeColor+1);await picker.locator('[data-color-popover-apply]').click();
 await waitApplied(priorHistory+2);assert(source().includes('background-color:'+pointerDraft.toLowerCase()+';'));
 assert.equal(proof.sourceRequests.length,beforeColor+2);record('real plane and alpha pointer gestures share draft validation and one native Apply');
 await swatch.click();await picker.waitFor();const cancelPlaneBox=await picker.locator('[data-color-plane]').boundingBox();
 await page.mouse.click(cancelPlaneBox.x+10,cancelPlaneBox.y+10);await page.keyboard.press('Escape');
 assert.equal(proof.sourceRequests.length,beforeColor+2);assert(source().includes('background-color:'+pointerDraft.toLowerCase()+';'));
 record('Escape discards color pointer draft without native write');
 // Delay only delivery of one genuinely compiled native response, so HMR
 // and duplicate admission are deterministic while the original ACK is pending.
 const beforeHmr=await snapshot(),beforeHmrSource=source(),beforeHmrRequests=proof.sourceRequests.length;
 let releaseResponse,compiledResponse,rejectCompiled;const deliveryGate=new Promise(resolve=>releaseResponse=resolve),compiledGate=new Promise((resolve,reject)=>{compiledResponse=resolve;rejectCompiled=reject;});
 await page.route('**/api/editor/source/operation',async route=>{
  try {
  const response=await route.fetch();const body=await response.body();const decoded=JSON.parse(body.toString());
  assert.equal(response.status(),200);assert.equal(decoded.ok,true);compiledResponse({status:response.status(),bodySha256:createHash('sha256').update(body).digest('hex'),decoded});
  await deliveryGate;await route.fulfill({response,body});
  } catch(error) {rejectCompiled(error);throw error;}
 });
 await input.fill('21em');await input.press('Enter');
 const nativeResponse=await compiledGate;proof.pendingNativeResponse={status:nativeResponse.status,bodySha256:nativeResponse.bodySha256,sourceEdit:nativeResponse.decoded.sourceEdit};
 assert.equal(source(),beforeHmrSource.replace('width:20em;','width:21em;'));assert.equal((await snapshot()).undoCount,beforeHmr.undoCount);
 assert((await snapshot()).sourceInFlight);assert.equal(proof.sourceRequests.length,beforeHmrRequests+1);
 const pendingSerial=(await snapshot()).sourceOperationSerial;assert.equal(pendingSerial,beforeHmr.sourceOperationSerial+1);
 await reloadBundle();await reloadBundle();
 const modeBefore=await snapshot();
 assert.equal(await page.evaluate(()=>window.__popupAcceptance.catalogOnlyAttempt()),'Native inspector editing is already installed.');
 assert.deepEqual(await snapshot(),modeBefore);assert.equal(source(),beforeHmrSource.replace('width:20em;','width:21em;'));assert.equal(proof.sourceRequests.length,beforeHmrRequests+1);
 proof.pendingModeDowngradeRefused=true;
 const stillPending=await snapshot();assert(stillPending.sourceInFlight);assert.equal(stillPending.sourceOperationSerial,pendingSerial);assert.equal(stillPending.sourceMappingObservers,1);assert.equal(stillPending.undoCount,beforeHmr.undoCount);
 // This attempted second edit must not produce another native operation.
 await input.fill('22em');await input.press('Enter');assert.equal(proof.sourceRequests.length,beforeHmrRequests+1);assert.equal((await snapshot()).undoCount,beforeHmr.undoCount);
 releaseResponse();await waitApplied(beforeHmr.undoCount+1);await page.unroute('**/api/editor/source/operation');
 assert.equal(source(),beforeHmrSource.replace('width:20em;','width:21em;'));assert.equal((await snapshot()).sourceMappingObservers,1);assert.equal(proof.sourceRequests.length,beforeHmrRequests+1);
 record('repeated HMR preserves one source owner and admitted native response completes exactly once');
 await input.fill('22em');await input.press('Enter');await waitApplied(beforeHmr.undoCount+2);
 assert(source().includes('width:22em;'));assert.equal(proof.sourceRequests.length,beforeHmrRequests+2);
 assert.notEqual(proof.sourceRequests[beforeHmrRequests].operationId,proof.sourceRequests[beforeHmrRequests+1].operationId);
 await page.evaluate(()=>window.__popupAcceptance.history(false));await waitApplied(beforeHmr.undoCount+1);assert(source().includes('width:21em;'));
 const refusalSource=source(),refusalCatalog=readFileSync(project+'/.isonim/catalog.json','utf8');
 await input.fill('777px');await input.press('Enter');await page.waitForFunction(()=>JSON.parse(window.__popupAcceptance.snapshot()).stage==='wesFailed',null,{timeout:70000});
 assert.equal(source(),refusalSource);assert.equal(readFileSync(project+'/.isonim/catalog.json','utf8'),refusalCatalog);assert.equal((await snapshot()).undoCount,beforeHmr.undoCount+1);assert.equal(await input.inputValue(),'21');assert.equal(await row.locator('[data-property-row-unit]').textContent(),'em');
 assert.equal(new Set(proof.sourceRequests.slice(beforeHmrRequests).map(request=>request.operationId)).size,4);assert.equal(proof.sourceRequests.length,beforeHmrRequests+4);
 record('post-HMR unique follow-up operation, native undo and genuine compiler refusal preserve exact source/catalog/history');
 // The default native composition must not fall back to preview success for
 // a real rendered property absent from its declared source capabilities.
 const unsupportedRow=page.locator('[data-property-row-kind="color"][data-property-row-css-property="border-color"][data-property-row-readonly="true"]');
 assert.equal(await unsupportedRow.count(),1);
 if(!await unsupportedRow.isVisible()){
  const section=await unsupportedRow.locator('xpath=ancestor::*[@data-inspector-section-body][1]').getAttribute('data-inspector-section-body');
  await page.locator('[data-inspector-section-header="'+section+'"]').click();
 }
 const unsupportedSwatch=unsupportedRow.locator('[data-property-row-swatch]');await unsupportedSwatch.scrollIntoViewIfNeeded();
 const unsupportedBefore=await snapshot(),unsupportedSource=source(),unsupportedCatalog=readFileSync(project+'/.isonim/catalog.json','utf8'),unsupportedRequests=proof.sourceRequests.length;
 await unsupportedSwatch.focus();await page.keyboard.press('Enter');
 const unsupportedPicker=page.locator('[data-color-popover-open="true"]');await unsupportedPicker.waitFor();
 const unsupportedOpen=await snapshot();
 await unsupportedPicker.locator('[data-color-popover-input]').fill('#AABBCC');
 await unsupportedPicker.locator('[data-color-popover-apply]').click();
 assert((await unsupportedPicker.locator('[data-color-popover-error]').innerText()).includes('no editable source declaration in this project owns border-color'));
 assert.equal(await unsupportedPicker.locator('[data-color-popover-input]').inputValue(),'#AABBCC');
 assert.deepEqual(await snapshot(),unsupportedOpen);assert.equal(proof.sourceRequests.length,unsupportedRequests);
 assert.equal(source(),unsupportedSource);assert.equal(readFileSync(project+'/.isonim/catalog.json','utf8'),unsupportedCatalog);
 await page.keyboard.press('Escape');assert(await unsupportedSwatch.evaluate(el=>el===document.activeElement));assert.deepEqual(await snapshot(),unsupportedBefore);
 record('default native inspector allows unsupported value inspection but refuses Apply with zero source/catalog/history changes');
 // Rotation uses the same authenticated source/compiler/history path, retaining
 // literal sibling functions rather than interpreting computed matrix values.
 await page.locator('[data-scene-graph-row="action"]').click();
 const position=page.locator('[data-inspector-section-header="position"]');
 if(await position.getAttribute('aria-expanded')==='false')await position.click();
 const rotation=page.locator('[data-property-row="rotation"]'),angle=rotation.locator('[data-property-row-input]');
 await angle.waitFor();assert.equal(await angle.inputValue(),'20');
 const rotationPreview=()=>page.evaluate(()=>{const frame=[...document.querySelectorAll('iframe')].find(f=>f.getClientRects().length&&f.contentDocument?.querySelector('#action'));const matrix=new frame.contentWindow.DOMMatrix(frame.contentWindow.getComputedStyle(frame.contentDocument.querySelector('#action')).transform);return {degrees:Math.atan2(matrix.b,matrix.a)*180/Math.PI,scale:Math.hypot(matrix.a,matrix.b),x:matrix.e,y:matrix.f};});
 const expectRotation=async(degrees)=>{await page.waitForFunction(degrees=>{const frame=[...document.querySelectorAll('iframe')].find(f=>f.getClientRects().length&&f.contentDocument?.querySelector('#action'));if(!frame)return false;const m=new frame.contentWindow.DOMMatrix(frame.contentWindow.getComputedStyle(frame.contentDocument.querySelector('#action')).transform);return Math.abs(Math.atan2(m.b,m.a)*180/Math.PI-degrees)<.0001;},degrees);const actual=await rotationPreview();assert(Math.abs(actual.degrees-degrees)<.0001);assert(Math.abs(actual.scale-1.2)<.00001);assert.equal(actual.x,8);assert.equal(actual.y,0);};
 let rotationHistory=(await snapshot()).undoCount;const rotationRequests=proof.sourceRequests.length;
 await angle.fill('3^3deg');await angle.press('Enter');writeFileSync(root+'/rotation-first-commit.json',JSON.stringify({state:await snapshot(),value:await angle.inputValue(),text:await rotation.innerText(),requests:proof.sourceRequests,source:source()},null,2));await waitApplied(++rotationHistory);
 assert(source().includes('transform:translateX(8px) rotate(27deg) scale(1.2);'));await expectRotation(27);
 await angle.press('ArrowUp');await waitApplied(++rotationHistory);assert.equal(await angle.inputValue(),'28');await expectRotation(28);
 assert.equal(proof.sourceRequests.length,rotationRequests+2);
 const rotatedSource=source(),rotatedCatalog=JSON.parse(readFileSync(project+'/.isonim/catalog.json','utf8'));
 await page.locator('[data-preview-chrome-bar="true"]').click({position:{x:1,y:1}});assert(await page.evaluate(()=>!document.activeElement.closest('[data-inspector-section-header]')&&!['INPUT','TEXTAREA'].includes(document.activeElement.tagName)));await page.keyboard.press('ControlOrMeta+z');await waitApplied(--rotationHistory);assert(source().includes('rotate(27deg)'));await expectRotation(27);
 await page.keyboard.press('ControlOrMeta+Shift+z');await waitApplied(++rotationHistory);assert.equal(source(),rotatedSource);assert.deepEqual(JSON.parse(readFileSync(project+'/.isonim/catalog.json','utf8')),rotatedCatalog);await expectRotation(28);
 await page.reload();await page.waitForFunction(()=>!!window.__popupAcceptance);await page.locator('[data-toolbar-cluster="mode"] [aria-label="Switch to edit mode"]').click();await page.locator('[data-scene-graph-row="action"]').click();
 if(await position.getAttribute('aria-expanded')==='false')await position.click();
 assert.equal(await angle.inputValue(),'28');await expectRotation(28);assert.equal(source(),rotatedSource);
 record('Rotation arithmetic and arrows preserve siblings through real source/compiler/preview, physical undo/redo and reload');
 const stableSource=source(),stableCatalog=readFileSync(project+'/.isonim/catalog.json','utf8'),stableHistory=await snapshot(),stableCalls=proof.sourceRequests.length;
 await angle.fill('41deg');await angle.press('Escape');assert.equal(await angle.inputValue(),'28');
 for(const invalid of ['1e999deg','NaNdeg','45px','calc(10deg + 1deg)']){await angle.fill(invalid);await angle.press('Enter');await angle.press('Escape');assert.equal(await angle.inputValue(),'28');}
 assert.equal(source(),stableSource);assert.equal(readFileSync(project+'/.isonim/catalog.json','utf8'),stableCatalog);assert.equal((await snapshot()).undoCount,stableHistory.undoCount);assert.equal(proof.sourceRequests.length,stableCalls);
 // The authoritative real-file hash must refuse a stale rotation source edit.
 writeFileSync(storyFile,stableSource+'\n# external revision\n');await angle.fill('32deg');await angle.press('Enter');
 await page.waitForFunction(()=>JSON.parse(window.__popupAcceptance.snapshot()).stage==='wesFailed');
 assert.equal(source(),stableSource+'\n# external revision\n');assert.equal(readFileSync(project+'/.isonim/catalog.json','utf8'),stableCatalog);assert.equal((await snapshot()).undoCount,stableHistory.undoCount);assert.equal(await angle.inputValue(),'28');await expectRotation(28);writeFileSync(storyFile,stableSource);
 record('Rotation cancel malformed/unit/nonfinite refusal and actual stale source preserve exact files/catalog/preview/history');
 await page.locator('[data-scene-graph-row="secondary-action"]').click();
 assert.equal(await angle.inputValue(),'matrix(1,0,0,1,0,0)');assert(await angle.evaluate(el=>el.readOnly));assert((await rotation.locator('[data-property-row-message]').innerText()).includes('Read-only'));
 const opaqueCalls=proof.sourceRequests.length,opaqueState=await snapshot();await angle.click();await page.keyboard.press('ControlOrMeta+A');await page.keyboard.type('45deg');await angle.press('Enter');
 const opaqueHandle=await rotation.locator('[data-property-row-field-label]').boundingBox();assert(opaqueHandle);await page.mouse.move(opaqueHandle.x+opaqueHandle.width/2,opaqueHandle.y+opaqueHandle.height/2);await page.mouse.down();await page.mouse.move(opaqueHandle.x+opaqueHandle.width/2+20,opaqueHandle.y+opaqueHandle.height/2);await page.mouse.up();
 assert.equal(await angle.inputValue(),'matrix(1,0,0,1,0,0)');assert.equal(proof.sourceRequests.length,opaqueCalls);assert.equal((await snapshot()).undoCount,opaqueState.undoCount);assert.equal(source(),stableSource);assert.equal(readFileSync(project+'/.isonim/catalog.json','utf8'),stableCatalog);
 record('Ambiguous computed matrix exposes a visible readonly reason and refuses physical keyboard and drag without source writes');
 // The real admitted Rotation transaction remains owned by its captured target.
 await page.locator('[data-scene-graph-row="action"]').click();const raceHistory=(await snapshot()).undoCount;
 await angle.fill('45deg');await angle.press('Enter');
 const rotationDeadline=Date.now()+15000;while(!source().includes('rotate(45deg)')&&Date.now()<rotationDeadline)await new Promise(resolve=>setTimeout(resolve,20));
 assert(source().includes('transform:translateX(8px) rotate(45deg) scale(1.2);'));assert.equal((await snapshot()).stage,'wesCompiling');
 await page.locator('[data-scene-graph-row="secondary-action"]').click();await waitApplied(raceHistory+1);
 assert.equal((await snapshot()).selected,'secondary-action');assert.equal(await angle.inputValue(),'matrix(1,0,0,1,0,0)');assert(await angle.evaluate(el=>el.readOnly));
 record('Admitted Rotation compiler result preserves the next selected opaque transform and source target ownership');
 await page.locator('[data-scene-graph-row="action"]').click();await angle.fill('0.25turn');await angle.press('Enter');await waitApplied(raceHistory+2);
 assert(source().includes('transform:translateX(8px) rotate(0.25turn) scale(1.2);'));assert.equal(await angle.inputValue(),'0.25');assert.equal(await rotation.locator('[data-property-row-unit]').textContent(),'turn');await expectRotation(90);
 record('Rotation typed turn units serialize full CSS and preserve sibling geometry through actual compiler/preview');
 // Authored fractional units must never be rounded on explicit re-entry.
 await angle.fill('0.125turn');await angle.press('Enter');await waitApplied(raceHistory+3);await expectRotation(45);
 assert.equal(await angle.inputValue(),'0.125');
 const preciseSource=source(),preciseCatalog=readFileSync(project+'/.isonim/catalog.json','utf8'),preciseHistory=await snapshot();
 assert(Number.isInteger(preciseHistory.undoCount)&&Number.isInteger(preciseHistory.redoCount));
 const preciseTimes=[statSync(storyFile).mtimeMs,statSync(project+'/.isonim/catalog.json').mtimeMs];
 for(const originalAngle of ['0.125turn','45deg']){await angle.fill(originalAngle);await angle.press('Enter');await page.waitForFunction(()=>!JSON.parse(window.__popupAcceptance.snapshot()).sourceInFlight);assert.equal(source(),preciseSource);assert.equal(readFileSync(project+'/.isonim/catalog.json','utf8'),preciseCatalog);assert.deepEqual([statSync(storyFile).mtimeMs,statSync(project+'/.isonim/catalog.json').mtimeMs],preciseTimes);assert.equal((await snapshot()).undoCount,preciseHistory.undoCount);assert.equal((await snapshot()).redoCount,preciseHistory.redoCount);await expectRotation(45);}
 record('Explicit authored fractional and equivalent degree re-entry retain exact source/catalog mtimes and history through authoritative no-op');
 await angle.fill('0.126turn');await angle.press('Enter');await waitApplied(preciseHistory.undoCount+1);await expectRotation(45.36);
 assert(source().includes('transform:translateX(8px) rotate(0.126turn) scale(1.2);'));assert.equal(await angle.inputValue(),'0.126');
 await page.locator('[data-preview-chrome-bar="true"]').click({position:{x:1,y:1}});await page.keyboard.press('ControlOrMeta+z');await waitApplied(preciseHistory.undoCount);assert.equal(source(),preciseSource);assert.deepEqual(JSON.parse(readFileSync(project+'/.isonim/catalog.json','utf8')),JSON.parse(preciseCatalog));await expectRotation(45);
 await page.keyboard.press('ControlOrMeta+Shift+z');await waitApplied(preciseHistory.undoCount+1);await expectRotation(45.36);
 await page.reload();await page.waitForFunction(()=>!!window.__popupAcceptance);await page.locator('[data-toolbar-cluster="mode"] [aria-label="Switch to edit mode"]').click();await page.locator('[data-scene-graph-row="action"]').click();if(await position.getAttribute('aria-expanded')==='false')await position.click();assert.equal(await angle.inputValue(),'0.126');assert(source().includes('rotate(0.126turn)'));await expectRotation(45.36);
 record('Changed fractional Rotation survives genuine source/compiler/preview physical undo/redo and reload without rounding');
 // Shared ordinary rows retain precise authoring values, independently of CSS
 // pixel quantization. Source, catalog, mtimes and native history are the oracles.
 const widthInput=row.locator('[data-property-row-input]');let numericHistory=(await snapshot()).undoCount;
 await widthInput.fill('120.125px');await widthInput.press('Enter');await waitApplied(++numericHistory);assert.equal(await widthInput.inputValue(),'120.125');assert(source().includes('#action { width:120.125px;'));
 const numericBaseline={source:source(),catalog:readFileSync(project+'/.isonim/catalog.json','utf8'),times:[statSync(storyFile).mtimeMs,statSync(project+'/.isonim/catalog.json').mtimeMs],state:await snapshot()};
 for(const entry of [null,'120.125px','120+1/8px']){if(entry!==null)await widthInput.fill(entry);else await widthInput.focus();await widthInput.press(entry===null?'Tab':'Enter');await page.waitForFunction(()=>!JSON.parse(window.__popupAcceptance.snapshot()).sourceInFlight);assert.equal(await widthInput.inputValue(),'120.125');assert.equal(source(),numericBaseline.source);assert.equal(readFileSync(project+'/.isonim/catalog.json','utf8'),numericBaseline.catalog);assert.deepEqual([statSync(storyFile).mtimeMs,statSync(project+'/.isonim/catalog.json').mtimeMs],numericBaseline.times);assert.equal((await snapshot()).undoCount,numericBaseline.state.undoCount);assert.equal((await snapshot()).redoCount,numericBaseline.state.redoCount);}
 record('Ordinary width authored fraction untouched Tab and explicit/equivalent re-entry retain exact source/catalog/mtimes/history');
 await widthInput.fill('120.126px');await widthInput.press('Enter');await waitApplied(++numericHistory);assert(source().includes('#action { width:120.126px;'));assert.equal(await widthInput.inputValue(),'120.126');
 const widthChanged=source();await page.locator('[data-preview-chrome-bar="true"]').click({position:{x:1,y:1}});await page.keyboard.press('ControlOrMeta+z');await waitApplied(--numericHistory);assert.equal(source(),numericBaseline.source);assert.deepEqual(JSON.parse(readFileSync(project+'/.isonim/catalog.json','utf8')),JSON.parse(numericBaseline.catalog));await page.keyboard.press('ControlOrMeta+Shift+z');await waitApplied(++numericHistory);assert.equal(source(),widthChanged);
 await page.reload();await page.waitForFunction(()=>!!window.__popupAcceptance);await page.locator('[data-toolbar-cluster="mode"] [aria-label="Switch to edit mode"]').click();await page.locator('[data-scene-graph-row="action"]').click();assert.equal(await widthInput.inputValue(),'120.126');assert.equal(source(),widthChanged);assert.equal(await previewWidth(),'120.125px');
 record('Changed width fraction persists in source/catalog through compiler physical undo/redo/reload independently of quantized pixel preview');
 const appearance=page.locator('[data-inspector-section-header="appearance"]');if(await appearance.getAttribute('aria-expanded')==='false')await appearance.click();const opacityRow=page.locator('[data-property-row="opacity"][data-property-row-kind="numeric"]'),opacityInput=opacityRow.locator('[data-property-row-input]');assert.equal(await opacityInput.inputValue(),'80.0125');
 const opacityBaseline={source:source(),catalog:readFileSync(project+'/.isonim/catalog.json','utf8'),state:await snapshot()};await opacityInput.focus();await opacityInput.press('Tab');assert.equal(source(),opacityBaseline.source);assert.equal(readFileSync(project+'/.isonim/catalog.json','utf8'),opacityBaseline.catalog);assert.equal((await snapshot()).undoCount,opacityBaseline.state.undoCount);
 await opacityInput.fill('80.0126%');await opacityInput.press('Enter');await waitApplied(opacityBaseline.state.undoCount+1);assert(source().includes('opacity:0.8001260000000001;'));assert.equal(await opacityInput.inputValue(),'80.0126');assert(readFileSync(project+'/.isonim/catalog.json','utf8').includes('opacity:0.8001260000000001;'));await page.waitForFunction(()=>{const f=[...document.querySelectorAll('iframe')].find(f=>f.getClientRects().length&&f.contentDocument?.querySelector('#action'));return f&&Math.abs(Number(f.contentWindow.getComputedStyle(f.contentDocument.querySelector('#action')).opacity)-0.8001260000000001)<=Number.EPSILON;});
 record('Another numeric property retains fractional opacity percent projection and real source/compiler/preview parity');
 await page.reload();await page.waitForFunction(()=>!!window.__popupAcceptance);await page.locator('[data-toolbar-cluster="mode"] [aria-label="Switch to edit mode"]').click();await page.locator('[data-scene-graph-row="action"]').click();if(await appearance.getAttribute('aria-expanded')==='false')await appearance.click();assert.equal(await opacityInput.inputValue(),'80.0126');
 const normalizedOpacity={source:source(),catalog:readFileSync(project+'/.isonim/catalog.json','utf8'),state:await snapshot(),times:[statSync(storyFile).mtimeMs,statSync(project+'/.isonim/catalog.json').mtimeMs]};
 for(const typed of [null,'80.0126%']){if(typed===null)await opacityInput.focus();else await opacityInput.fill(typed);await opacityInput.press(typed===null?'Tab':'Enter');await page.waitForFunction(()=>!JSON.parse(window.__popupAcceptance.snapshot()).sourceInFlight);assert.equal(source(),normalizedOpacity.source);assert.equal(readFileSync(project+'/.isonim/catalog.json','utf8'),normalizedOpacity.catalog);assert.deepEqual([statSync(storyFile).mtimeMs,statSync(project+'/.isonim/catalog.json').mtimeMs],normalizedOpacity.times);assert.equal((await snapshot()).undoCount,normalizedOpacity.state.undoCount);assert.equal((await snapshot()).redoCount,normalizedOpacity.state.redoCount);}
 await opacityInput.fill('12.5125%');await opacityInput.press('Enter');await waitApplied(normalizedOpacity.state.undoCount+1);assert(source().includes('opacity:0.125125;'));assert.equal(await opacityInput.inputValue(),'12.5125');assert(readFileSync(project+'/.isonim/catalog.json','utf8').includes('opacity:0.125125;'));
 await page.reload();await page.waitForFunction(()=>!!window.__popupAcceptance);await page.locator('[data-toolbar-cluster="mode"] [aria-label="Switch to edit mode"]').click();await page.locator('[data-scene-graph-row="action"]').click();if(await appearance.getAttribute('aria-expanded')==='false')await appearance.click();assert.equal(await opacityInput.inputValue(),'12.5125');const reloadOpacity={source:source(),catalog:readFileSync(project+'/.isonim/catalog.json','utf8'),state:await snapshot()};await opacityInput.focus();await opacityInput.press('Tab');assert.equal(source(),reloadOpacity.source);assert.equal(readFileSync(project+'/.isonim/catalog.json','utf8'),reloadOpacity.catalog);assert.equal((await snapshot()).undoCount,reloadOpacity.state.undoCount);await page.waitForFunction(()=>{const f=[...document.querySelectorAll('iframe')].find(f=>f.getClientRects().length&&f.contentDocument?.querySelector('#action'));return f&&Math.abs(Number(f.contentWindow.getComputedStyle(f.contentDocument.querySelector('#action')).opacity)-0.125125)<=Number.EPSILON;});
 record('Normalized fractional opacity noisy-ratio blur/re-entry and exact unitless ratio reload preserve source/catalog/history');
 // A whole percent is shorter only when reverse conversion preserves its ratio.
 await opacityInput.fill('7%');await opacityInput.press('Enter');await waitApplied(reloadOpacity.state.undoCount+1);assert(source().includes('opacity:0.07;'));
 await page.reload();await page.waitForFunction(()=>!!window.__popupAcceptance);await page.locator('[data-toolbar-cluster="mode"] [aria-label="Switch to edit mode"]').click();await page.locator('[data-scene-graph-row="action"]').click();if(await appearance.getAttribute('aria-expanded')==='false')await appearance.click();assert.equal(await opacityInput.inputValue(),'7');
 const wholeOpacity={source:source(),catalog:readFileSync(project+'/.isonim/catalog.json','utf8'),state:await snapshot(),times:[statSync(storyFile).mtimeMs,statSync(project+'/.isonim/catalog.json').mtimeMs]};
 for(const entry of [null,'7%']){if(entry===null)await opacityInput.focus();else await opacityInput.fill(entry);await opacityInput.press(entry===null?'Tab':'Enter');await page.waitForFunction(()=>!JSON.parse(window.__popupAcceptance.snapshot()).sourceInFlight);assert.equal(await opacityInput.inputValue(),'7');assert.equal(source(),wholeOpacity.source);assert.equal(readFileSync(project+'/.isonim/catalog.json','utf8'),wholeOpacity.catalog);assert.deepEqual([statSync(storyFile).mtimeMs,statSync(project+'/.isonim/catalog.json').mtimeMs],wholeOpacity.times);assert.equal((await snapshot()).undoCount,wholeOpacity.state.undoCount);assert.equal((await snapshot()).redoCount,wholeOpacity.state.redoCount);}
 await opacityInput.fill('8%');await opacityInput.press('Enter');await waitApplied(wholeOpacity.state.undoCount+1);assert(source().includes('opacity:0.08;'));assert.equal(await opacityInput.inputValue(),'8');await page.waitForFunction(()=>{const f=[...document.querySelectorAll('iframe')].find(f=>f.getClientRects().length&&f.contentDocument?.querySelector('#action'));return f&&f.contentWindow.getComputedStyle(f.contentDocument.querySelector('#action')).opacity==='0.08';});
 await page.locator('[data-preview-chrome-bar="true"]').click({position:{x:1,y:1}});await page.keyboard.press('ControlOrMeta+z');await waitApplied(wholeOpacity.state.undoCount);assert.equal(source(),wholeOpacity.source);assert.deepEqual(JSON.parse(readFileSync(project+'/.isonim/catalog.json','utf8')),JSON.parse(wholeOpacity.catalog));
 await page.reload();await page.waitForFunction(()=>!!window.__popupAcceptance);await page.locator('[data-toolbar-cluster="mode"] [aria-label="Switch to edit mode"]').click();await page.locator('[data-scene-graph-row="action"]').click();if(await appearance.getAttribute('aria-expanded')==='false')await appearance.click();assert.equal(await opacityInput.inputValue(),'7');assert.equal(source(),wholeOpacity.source);
 record('Exact reverse opacity projection displays7 without float noise and preserves ratio/source/history through no-op edits changed8percent undo and reload');
 assert.deepEqual(proof.errors,[]);assert.deepEqual(proof.agentRequests,[]);
 writeFileSync(root+'/proof.json',JSON.stringify(proof,null,2));console.log('Inspector source GUI passed:',root,proof.cases.length);
} finally {
 if(browser)await browser.close();if(browserServer)await browserServer.close();
 server.kill('SIGTERM');await new Promise(resolve=>{if(server.exitCode!==null)return resolve();server.once('exit',resolve);setTimeout(()=>{server.kill('SIGKILL');resolve();},15000).unref();});
 writeFileSync(root+'/proof-final.json',JSON.stringify(proof,null,2));
}
