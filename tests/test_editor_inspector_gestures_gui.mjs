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
const root=mkdtempSync(path.join(process.env.ISONIM_POPUP_ARTIFACTS||tmpdir(),'inspector-gestures-'));
const project=root+'/project',pub=root+'/public';
cpSync(repo+'/tests/fixtures/editor_inspector_project',project,{recursive:true});mkdirSync(pub);
// Real declared transform owners in this private Nim/SSR project. The matrix
// owner is deliberately unsupported by numeric Rotation, while remaining valid CSS.
const storyFile=project+'/stories.nim';
writeFileSync(storyFile,readFileSync(storyFile,'utf8').replace('background-color:#112233; color:#FFFFFF; }','background-color:#112233; color:#FFFFFF; transform:translateX(8px) rotate(20deg) scale(1.2); }').replace('background-color:#334455; color:#FFFFFF; }','background-color:#334455; color:#FFFFFF; transform:matrix(1,0,0,1,0,0); }'));
const ownerFile=project+'/.isonim/source-project.json',owners=JSON.parse(readFileSync(ownerFile,'utf8'));
for(const owner of owners.editableStyles)if(['action','secondary-action'].includes(owner.elementId))owner.properties.push('transform');
writeFileSync(ownerFile,JSON.stringify(owners,null,2));
for(const [from,to] of [['src/isonim/editor/index.html','index.html'],['build/editor-inspector/editor.js','editor.js'],['node_modules/fabric/dist/index.min.js','fabric.min.js'],['node_modules/paper/dist/paper-core.min.js','paper-core.min.js'],['node_modules/svgo/dist/svgo.browser.js','svgo.browser.js']])copyFileSync(repo+'/'+from,pub+'/'+to);
const build=spawnSync('python3',[repo+'/tools/build_source_catalog.py',project],{env:{...process.env,ISONIM_SOURCE_FRAMEWORK:repo},encoding:'utf8',timeout:70000});
writeFileSync(root+'/catalog-build.log',build.stdout+build.stderr);assert.equal(build.status,0,build.stdout+build.stderr);
const proof={project,head:process.env.ISONIM_TEST_HEAD||spawnSync('git',['rev-parse','HEAD'],{cwd:repo,encoding:'utf8'}).stdout.trim(),sourceState:process.env.ISONIM_TEST_SOURCE_STATE||'C4a authored working copy',nativeSha256:createHash('sha256').update(readFileSync(repo+'/build/bin/isonim-review')).digest('hex'),bundleSha256:createHash('sha256').update(readFileSync(pub+'/editor.js')).digest('hex'),cases:[],errors:[],agentRequests:[],sourceRequests:[]};
const record=name=>{proof.cases.push(name);writeFileSync(root+'/proof-partial.json',JSON.stringify(proof,null,2));};
const config=root+'/agent.toml';writeFileSync(config,'[agent]\nbackend="custom"\ncommand="python3"\nargs='+JSON.stringify([repo+'/tests/helpers/editor_control_peer.py'])+'\nprimer_enabled=false\n');
const server=spawn('python3',[repo+'/tools/editor_server.py','--directory',pub,'--project-root',project,'--port','0','--bind','127.0.0.1','--config',config,'--daemon-binary',repo+'/build/bin/isonim-review'],{env:{...process.env,ISONIM_SOURCE_FRAMEWORK:repo,ISONIM_SOURCE_DIAGNOSTICS:'timing'},stdio:['ignore','pipe',openSync(root+'/server.log','w')]});
let browser,browserServer;
try {
 const origin=await new Promise((resolve,reject)=>{let text='';server.stdout.on('data',data=>{text+=data;const match=text.match(/Editor listening on (http:\/\/[^\s]+)\//);if(match)resolve(match[1]);});server.once('exit',code=>reject(Error('Server exited '+code)));setTimeout(()=>reject(Error('Server startup timeout')),70000).unref();});
 const chromeEnv={...process.env};delete chromeEnv.LD_LIBRARY_PATH;
 browserServer=await chromium.launchServer({headless:true,env:chromeEnv,executablePath:process.env.PLAYWRIGHT_CHROMIUM_EXECUTABLE});browser=await chromium.connect(browserServer.wsEndpoint());
 const page=await browser.newPage({viewport:{width:1440,height:900}});page.setDefaultTimeout(30000);
 // Forward actual DOM registrations unchanged while observing source-refresh
 // ownership and event delivery; no selection/source/frame behavior is mocked.
 await page.addInitScript(()=>{const types=new Set(['isonim-select-preview-ancestor','isonim-select-preview-element-id','isonim-preview-set-declaration','isonim-preview-element-visibility','isonim-hover-preview-element-id']);const listeners=new Map([...types].map(type=>[type,new Set()]));let selections=0;const add=window.addEventListener.bind(window),remove=window.removeEventListener.bind(window),dispatch=window.dispatchEvent.bind(window);window.addEventListener=function(type,listener,options){if(types.has(type))listeners.get(type).add(listener);return add(type,listener,options);};window.removeEventListener=function(type,listener,options){if(types.has(type))listeners.get(type).delete(listener);return remove(type,listener,options);};window.dispatchEvent=function(event){if(event.type==='isonim-preview-element-selected')selections++;return dispatch(event);};window.__gestureBridgeState=()=>({parentListeners:Object.fromEntries([...listeners].map(([type,set])=>[type,set.size])),selections,outerOwners:[...(window.__isonimViewRuntime?.bridges||[])].map(([type,bridge])=>({type,count:bridge.owners.size}))});});
 const requestTimes=new WeakMap();page.on('request',request=>{if(new URL(request.url()).pathname.startsWith('/api/editor/source'))requestTimes.set(request,performance.now());});
 page.on('requestfinished',request=>{const start=requestTimes.get(request);if(start!==undefined)(proof.httpTimings||=[]).push({path:new URL(request.url()).pathname,milliseconds:performance.now()-start});});
 page.on('pageerror',error=>proof.errors.push(error.message));
 page.on('request',request=>{const url=new URL(request.url());if(url.pathname.startsWith('/api/agent/'))proof.agentRequests.push(url.pathname);if(url.pathname==='/api/editor/source/operation')proof.sourceRequests.push(request.postDataJSON());});
 await page.goto(origin);await page.waitForFunction(()=>!!window.__popupAcceptance);
 await page.locator('[data-toolbar-cluster="mode"] [aria-label="Edit"]').click();
 await page.locator('[data-scene-graph-row="action"]').click();
 const row=page.locator('[data-property-row-css-property="width"][data-property-row="w"][data-property-row-kind="numeric"]');
 await row.waitFor();assert.equal(await row.count(),1,'Actual visible width row exists');
 const input=row.locator('[data-property-row-input]');
 const snapshot=()=>page.evaluate(()=>JSON.parse(window.__popupAcceptance.snapshot()));
 const waitApplied=async(count)=>{
  const started=performance.now();
  await page.waitForFunction(count=>{const state=JSON.parse(window.__popupAcceptance.snapshot());return state.stage==='wesClean'&&state.undoCount===count;},count,{timeout:70000});
  const acknowledged=performance.now(),state=await snapshot(),catalog=JSON.parse(readFileSync(project+'/.isonim/catalog.json','utf8'));
  const story=catalog.stories.find(story=>story.group+' / '+story.name===state.story);assert(story);
  const css=[...story.documentHtml.matchAll(/<style[^>]*>([\s\S]*?)<\/style>/g)].map(match=>match[1]);assert(css.length);
  await page.waitForFunction(([css,selected])=>[...document.querySelectorAll('iframe')].some(frame=>{const doc=frame.contentDocument,node=frame.contentWindow?.__isonimSelectedElement;return frame.getClientRects().length&&doc?.readyState==='complete'&&css.every(value=>[...doc.querySelectorAll('style')].some(style=>style.textContent===value))&&(node?.id===selected||node?.dataset?.isonimElementId===selected);}),[css,state.selected]);
  await page.evaluate(()=>new Promise(resolve=>requestAnimationFrame(()=>requestAnimationFrame(resolve))));
  const ownership=await page.evaluate(()=>({bridge:window.__gestureBridgeState(),frames:[...document.querySelectorAll('iframe')].map(frame=>({visible:!!frame.getClientRects().length&&getComputedStyle(frame).visibility!=='hidden',connected:frame.isConnected,selected:frame.contentWindow?.__isonimSelectedElement?.dataset?.isonimElementId||'',ready:frame.contentDocument?.readyState})),control:[...document.querySelectorAll('[data-property-row="w"]')].map(row=>({connected:row.isConnected,value:row.querySelector('input')?.value,unit:row.querySelector('[data-property-row-unit]')?.textContent}))}));
  (proof.operationTimings||=[]).push({count,ackMilliseconds:acknowledged-started,loadedRestoredPreviewMilliseconds:performance.now()-acknowledged,ownership});
  writeFileSync(root+'/timing-partial.json',JSON.stringify({httpTimings:proof.httpTimings,operationTimings:proof.operationTimings},null,2));
 };
 const source=()=>readFileSync(project+'/stories.nim','utf8');
 const previewWidth=()=>page.evaluate(()=>{const frame=[...document.querySelectorAll('iframe')].find(frame=>frame.getClientRects().length&&frame.contentDocument?.querySelector('#action'));const target=frame?.contentDocument.querySelector('#action');return target&&frame.contentWindow.getComputedStyle(target).width;});
 let count=0, expected=120;
 const handle=row.locator('[data-property-row-field-label]');
 for(const [dx,dy,modifier,delta,label] of [[-10,0,null,-20,'near reverse speed2'],[10,24,null,10,'vertical speed1'],[20,64,null,10,'vertical speed.5'],[40,112,null,10,'vertical speed.25'],[1,0,'Shift',20,'Shift10 coarse'],[5,0,'Alt',1,'Alt.1 fine'],[-30,0,null,-60,'captured outside-control release']]) {
  const box=await handle.boundingBox();assert(box);const x=box.x+box.width/2,y=box.y+box.height/2;
  if(modifier)await page.keyboard.down(modifier);
  const before=proof.sourceRequests.length;
  await page.mouse.move(x,y);await page.mouse.down();await page.mouse.move(x+dx,y+dy);await page.mouse.up();
  if(modifier)await page.keyboard.up(modifier);
  expected+=delta;await waitApplied(++count);assert.equal(await input.inputValue(),String(expected));
  assert(source().includes('#action { width:'+expected+'px;'));assert.equal(proof.sourceRequests.length,before+1);
  await page.waitForFunction(expected=>{const frame=[...document.querySelectorAll('iframe')].find(frame=>frame.getClientRects().length&&frame.contentDocument?.querySelector('#action'));return frame&&frame.contentWindow.getComputedStyle(frame.contentDocument.querySelector('#action')).width===expected+'px';},expected);assert.equal(await previewWidth(),expected+'px');record(label+' uses one genuine native source/compiler/preview/history operation');
 }
 for(const [key,delta] of [['ArrowUp',1],['Shift+ArrowDown',-10],['Alt+ArrowUp',.1]]) {
  const before=proof.sourceRequests.length;await input.press(key);expected=Math.round((expected+delta)*10)/10;
  await waitApplied(++count);assert.equal(await input.inputValue(),String(expected));assert(source().includes('#action { width:'+expected+'px;'));assert.equal(proof.sourceRequests.length,before+1);record(key+' shares numeric guarded source path');
 }
 await input.fill('2^3px');await input.press('Enter');await input.press('Tab');await waitApplied(++count);assert.equal(await input.inputValue(),'8');assert(source().includes('#action { width:8px;'));record('exponent arithmetic preserves complete parsing and one Enter/change/blur commit');
 const unit=row.locator('[data-property-row-unit]'),beforeUnit=source(),unitCalls=proof.sourceRequests.length;
 await unit.focus();await unit.press('ArrowLeft');await unit.press('a');assert.equal(source(),beforeUnit);assert.equal(proof.sourceRequests.length,unitCalls);assert.equal(await unit.textContent(),'px');record('unrelated unit-chip keys never cycle units or commit');
 await unit.press('Enter');await waitApplied(++count);assert.equal(await unit.textContent(),'em');assert(source().includes('#action { width:8em;'));assert.equal(proof.sourceRequests.length,unitCalls+1);record('unit-chip Enter uses the actual selected supported unit once');
 // Actual read-only refusal restores the prior numeric+unit draft without write.
 await page.evaluate(()=>window.__popupAcceptance.readOnly(true));const refused=source(),refusedCalls=proof.sourceRequests.length;
 assert(await input.evaluate(el=>el.readOnly));await input.click();await input.press('ControlOrMeta+A');await page.keyboard.type('24px');await input.press('Enter');await input.press('Tab');assert.equal(await input.inputValue(),'8');assert.equal(await unit.textContent(),'em');assert.equal(source(),refused);assert.equal(proof.sourceRequests.length,refusedCalls);assert.equal((await snapshot()).undoCount,count);assert((await row.locator('[data-property-row-message]').innerText()).includes('read-only'));record('real workspace permission blocks ordinary keyboard editing and retains value/unit/source/history');await page.evaluate(()=>window.__popupAcceptance.readOnly(false));
 // Actual pending native write may finish for its captured story. The next
 // story deliberately reuses the same authored element ID with a different
 // source declaration; it must never receive the old prepared properties.
 await page.locator('[data-scene-graph-row="reused"]').click();assert.equal(await input.inputValue(),'110');
 await input.fill('140px');await input.press('Enter');
 const deadline=Date.now()+15000;while(!source().includes('#reused-card { width:140px;')&&Date.now()<deadline)await new Promise(resolve=>setTimeout(resolve,20));
 assert(source().includes('#reused-card { width:140px;'),'Actual native source write must be admitted before selection switch');
 assert.equal((await snapshot()).stage,'wesCompiling','The target switch must occur during the actual build');
 assert(await page.evaluate(()=>window.__popupAcceptance.openStory('Alternate','default ready')));
 await page.waitForFunction(()=>[...document.querySelectorAll('iframe')].some(frame=>frame.getClientRects().length&&frame.contentDocument?.querySelector('#reused-alternate')));
 await page.locator('[data-scene-graph-row="reused"]').click();
 await waitApplied(++count);assert.equal((await snapshot()).story,'Alternate / default ready');assert.equal((await snapshot()).selected,'reused');assert.equal(await input.inputValue(),'210');
 assert(source().includes('#reused-alternate { width:210px;'));assert(source().includes('#reused-card { width:140px;'));record('admitted pending source edit preserves another story with the same authored element ID');
 assert(await page.evaluate(()=>window.__popupAcceptance.openStory('Card','default ready')));await page.locator('[data-scene-graph-row="action"]').click();
 const position=page.locator('[data-inspector-section-header="position"]');if(await position.getAttribute('aria-expanded')==='false')await position.click();
 const rotation=page.locator('[data-property-row="rotation"]'),angle=rotation.locator('[data-property-row-input]'),rotationHandle=rotation.locator('[data-property-row-field-label]');
 assert.equal(await angle.inputValue(),'20');let expectedAngle=20;
 for(const [dx,modifier,delta] of [[-5,null,-10],[1,'Shift',20],[5,'Alt',1]]){
  const box=await rotationHandle.boundingBox();assert(box);const x=box.x+box.width/2,y=box.y+box.height/2,before=proof.sourceRequests.length;
  if(modifier)await page.keyboard.down(modifier);await page.mouse.move(x,y);await page.mouse.down();await page.mouse.move(x+dx,y);await page.mouse.up();if(modifier)await page.keyboard.up(modifier);
  expectedAngle+=delta;await waitApplied(++count);assert.equal(await angle.inputValue(),String(expectedAngle));assert(source().includes('transform:translateX(8px) rotate('+expectedAngle+'deg) scale(1.2);'));assert.equal(proof.sourceRequests.length,before+1);
  const preview=await page.evaluate(()=>{const f=[...document.querySelectorAll('iframe')].find(f=>f.getClientRects().length&&f.contentDocument?.querySelector('#action'));const m=new f.contentWindow.DOMMatrix(f.contentWindow.getComputedStyle(f.contentDocument.querySelector('#action')).transform);return {angle:Math.atan2(m.b,m.a)*180/Math.PI,scale:Math.hypot(m.a,m.b),x:m.e};});assert(Math.abs(preview.angle-expectedAngle)<.0001);assert(Math.abs(preview.scale-1.2)<.00001);assert.equal(preview.x,8);
  record('Rotation captured '+(modifier||'reverse')+' drag preserves literal siblings with one native compiler/preview/history operation');
 }
 const rotationSource=source(),rotationCatalog=readFileSync(project+'/.isonim/catalog.json','utf8'),rotationCalls=proof.sourceRequests.length;
 for(const kind of ['zero','return','cancel']){const box=await rotationHandle.boundingBox();const x=box.x+box.width/2,y=box.y+box.height/2;await page.mouse.move(x,y);await page.mouse.down();if(kind!=='zero')await page.mouse.move(x+10,y);if(kind==='return')await page.mouse.move(x,y);if(kind==='cancel'){assert(await position.evaluate(el=>el===document.activeElement),'Natural section-header focus must survive captured scrubbing');await page.keyboard.press('Escape');}await page.mouse.up();assert.equal(await angle.inputValue(),String(expectedAngle));assert.equal(source(),rotationSource);assert.equal(readFileSync(project+'/.isonim/catalog.json','utf8'),rotationCatalog);assert.equal((await snapshot()).undoCount,count);assert.equal(proof.sourceRequests.length,rotationCalls);}
 record('Rotation zero movement return-to-origin and Escape pointer cancellation retain source/catalog/history without transactions');
 await angle.fill('0.125turn');await angle.press('Enter');await waitApplied(++count);assert.equal(await angle.inputValue(),'0.125');
 const preciseBox=await rotationHandle.boundingBox();assert(preciseBox);const preciseX=preciseBox.x+preciseBox.width/2,preciseY=preciseBox.y+preciseBox.height/2;
 const preciseRequests=proof.sourceRequests.length;await page.keyboard.down('Alt');await page.mouse.move(preciseX,preciseY);await page.mouse.down();await page.mouse.move(preciseX+1,preciseY);await page.mouse.up();await page.keyboard.up('Alt');await waitApplied(++count);
 assert.equal(await angle.inputValue(),'0.325');assert(source().includes('transform:translateX(8px) rotate(0.325turn) scale(1.2);'));assert.equal(proof.sourceRequests.length,preciseRequests+1);
 const fineAngle=await page.evaluate(()=>{const f=[...document.querySelectorAll('iframe')].find(f=>f.getClientRects().length&&f.contentDocument?.querySelector('#action'));const m=new f.contentWindow.DOMMatrix(f.contentWindow.getComputedStyle(f.contentDocument.querySelector('#action')).transform);return Math.atan2(m.b,m.a)*180/Math.PI;});assert(Math.abs(fineAngle-117)<.0001);
 record('Fine Alt Rotation drag preserves fractional turn precision in input/source/compiler/preview/history');
 assert.deepEqual(proof.errors,[]);assert.deepEqual(proof.agentRequests,[]);writeFileSync(root+'/proof.json',JSON.stringify(proof,null,2));console.log('Inspector gesture GUI passed:',root,proof.cases.length);
} finally {
 if(browser)await browser.close();if(browserServer)await browserServer.close();
 server.kill('SIGTERM');await new Promise(resolve=>{if(server.exitCode!==null)return resolve();server.once('exit',resolve);setTimeout(()=>{server.kill('SIGKILL');resolve();},15000).unref();});
 writeFileSync(root+'/proof-final.json',JSON.stringify(proof,null,2));
}
