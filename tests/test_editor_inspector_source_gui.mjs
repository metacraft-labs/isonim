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
import {mkdtempSync,cpSync,readFileSync,writeFileSync,mkdirSync,openSync,copyFileSync} from 'node:fs';
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
 await page.locator('[data-toolbar-cluster="mode"] [aria-label="Edit"]').click();
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
 await page.reload();await page.waitForFunction(()=>!!window.__popupAcceptance);await page.locator('[data-toolbar-cluster="mode"] [aria-label="Edit"]').click();await page.locator('[data-scene-graph-row="action"]').click();
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
 await page.reload();await page.waitForFunction(()=>!!window.__popupAcceptance);await page.locator('[data-toolbar-cluster="mode"] [aria-label="Edit"]').click();await page.locator('[data-scene-graph-row="action"]').click();
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
 assert((await unsupportedPicker.locator('[data-color-popover-error]').innerText()).includes('cannot safely edit'));
 assert.equal(await unsupportedPicker.locator('[data-color-popover-input]').inputValue(),'#AABBCC');
 assert.deepEqual(await snapshot(),unsupportedOpen);assert.equal(proof.sourceRequests.length,unsupportedRequests);
 assert.equal(source(),unsupportedSource);assert.equal(readFileSync(project+'/.isonim/catalog.json','utf8'),unsupportedCatalog);
 await page.keyboard.press('Escape');assert(await unsupportedSwatch.evaluate(el=>el===document.activeElement));assert.deepEqual(await snapshot(),unsupportedBefore);
 record('default native inspector allows unsupported value inspection but refuses Apply with zero source/catalog/history changes');
 assert.deepEqual(proof.errors,[]);assert.deepEqual(proof.agentRequests,[]);
 writeFileSync(root+'/proof.json',JSON.stringify(proof,null,2));console.log('Inspector source GUI passed:',root,proof.cases.length);
} finally {
 if(browser)await browser.close();if(browserServer)await browserServer.close();
 server.kill('SIGTERM');await new Promise(resolve=>{if(server.exitCode!==null)return resolve();server.once('exit',resolve);setTimeout(()=>{server.kill('SIGKILL');resolve();},15000).unref();});
 writeFileSync(root+'/proof-final.json',JSON.stringify(proof,null,2));
}
