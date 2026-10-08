/** Metadata prerequisite only. Actual production preview DOM selection,
 * computedStyles serialization, native ownership hydration and genuine property
 * choice widget in a supplemental probe (not the unfinished layout pills).
 * Real private filesystem/compiler/SSR/authenticated native operations/history.
 * The controlled decision peer permits startup only; zero model calls required.
 * Old detached DOM events are lifecycle probes, not simulated user input.
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
const root=mkdtempSync(path.join(process.env.ISONIM_POPUP_ARTIFACTS||tmpdir(),'flex-metadata-'));
const project=root+'/project',pub=root+'/public';
cpSync(repo+'/tests/fixtures/editor_inspector_project',project,{recursive:true});mkdirSync(pub);
// Disposable actual source declaration and existing manifest capability.
// No native API or selected PropertyInfo is replaced.
let authored=readFileSync(project+'/stories.nim','utf8');
assert(authored.includes('#action { width:120px;'));
writeFileSync(project+'/stories.nim',authored.replace('#action { width:120px;','#action { display:inline-flex; flex-direction:row; width:120px;'));
const manifest=JSON.parse(readFileSync(project+'/.isonim/source-project.json','utf8'));
manifest.editableStyles.find(row=>row.elementId==='action').properties.push('display','flex-direction');
writeFileSync(project+'/.isonim/source-project.json',JSON.stringify(manifest));

for(const [from,to] of [['src/isonim/editor/index.html','index.html'],['build/editor-flex-metadata/editor.js','editor.js'],['node_modules/fabric/dist/index.min.js','fabric.min.js'],['node_modules/paper/dist/paper-core.min.js','paper-core.min.js'],['node_modules/svgo/dist/svgo.browser.js','svgo.browser.js']])copyFileSync(repo+'/'+from,pub+'/'+to);
const build=spawnSync('python3',[repo+'/tools/build_source_catalog.py',project],{env:{...process.env,ISONIM_SOURCE_FRAMEWORK:repo},encoding:'utf8',timeout:70000});
writeFileSync(root+'/catalog-build.log',build.stdout+build.stderr);assert.equal(build.status,0,build.stdout+build.stderr);
const proof={project,head:process.env.ISONIM_TEST_HEAD,sourceState:process.env.ISONIM_TEST_SOURCE_STATE,nativeSha256:createHash('sha256').update(readFileSync(repo+'/build/bin/isonim-review')).digest('hex'),bundleSha256:createHash('sha256').update(readFileSync(pub+'/editor.js')).digest('hex'),cases:[],errors:[],agentRequests:[],sourceRequests:[]};
proof.sourceBeforeSha256=createHash('sha256').update(readFileSync(project+'/stories.nim')).digest('hex');proof.catalogBeforeSha256=createHash('sha256').update(readFileSync(project+'/.isonim/catalog.json')).digest('hex');
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
 await page.addInitScript(()=>{window.__flexSelectionEvents=[];window.addEventListener('isonim-preview-element-selected',event=>window.__flexSelectionEvents.push(event.detail));});
 await page.goto(origin);await page.waitForFunction(()=>!!window.__popupAcceptance);
 await page.locator('[data-toolbar-cluster="mode"] [aria-label="Edit"]').click();
 await page.locator('[data-scene-graph-row="action"]').click();

 const state=()=>page.evaluate(()=>JSON.parse(window.__flexMetadata.state()));
 const snapshot=()=>page.evaluate(()=>JSON.parse(window.__popupAcceptance.snapshot()));
 const source=()=>readFileSync(project+'/stories.nim','utf8');
 const catalog=()=>readFileSync(project+'/.isonim/catalog.json','utf8');
 const computed=()=>page.evaluate(()=>{const frame=[...document.querySelectorAll('iframe')].find(frame=>frame.getClientRects().length&&frame.contentDocument?.querySelector('#action'));if(!frame)return null;const css=frame.contentWindow.getComputedStyle(frame.contentDocument.querySelector('#action'));return {display:css.display,direction:css.flexDirection,width:css.width};});
 const selected=await state();writeFileSync(root+'/selected-initial.json',JSON.stringify(selected,null,2));
 proof.extractedEvents=await page.evaluate(()=>window.__flexSelectionEvents);assert(proof.extractedEvents.some(event=>event.computedStyles?.includes('flex-direction=row')),'Real DOM bridge event contains direction');
 const directions=selected.properties.filter(prop=>prop.name==='flex-direction');
 assert.equal(directions.length,1,'Actual production DOM selection must expose flex-direction before any probe can exist');
 await page.waitForFunction(()=>JSON.parse(window.__flexMetadata.state()).properties.some(prop=>prop.name==='flex-direction'&&prop.authoredValue==='row'));
 const direction=(await state()).properties.find(prop=>prop.name==='flex-direction');
 assert.equal(direction.value,'row');assert.equal(direction.authoredValue,'row');assert.equal(direction.key,'dom.button.flex-direction');assert.equal(direction.nativeShared,false);assert.equal((await state()).reason,'');
 for(const name of ['display','width','padding','background-color'])assert((await state()).properties.some(prop=>prop.name===name));
 proof.initialSelected=await state();assert.deepEqual(await computed(),{display:'inline-flex',direction:'row',width:'120px'});
 record('real DOM selection and native ownership hydration supply direction; other existing properties remain');
 const host=page.locator('[data-flex-metadata-probe]');
 const row=host.locator('[data-property-row-css-property="flex-direction"]');
 async function choose(value,keyboard=false){
   await row.locator('[data-choice-group-trigger]').click();
   const option=row.locator('[data-choice-group-option-label="'+value+'"]');
   assert.equal(await option.count(),1);await option.scrollIntoViewIfNeeded();
   if(keyboard){await option.focus();await option.press('Enter');}else await option.click();
 }
 async function waitApplied(count,value){
  await page.waitForFunction(({count,value})=>{const s=JSON.parse(window.__popupAcceptance.snapshot()),frame=[...document.querySelectorAll('iframe')].find(frame=>frame.getClientRects().length&&frame.contentDocument?.querySelector('#action'));return s.stage==='wesClean'&&s.undoCount===count&&frame?.contentWindow.getComputedStyle(frame.contentDocument.querySelector('#action')).flexDirection===value&&JSON.parse(window.__flexMetadata.state()).properties.some(p=>p.name==='flex-direction'&&p.authoredValue===value);},{count,value},{timeout:70000});
 }
 const original=source(),originalCatalog=catalog();
 for(const [index,label,value] of [[1,'Column','column'],[2,'Row reverse','row-reverse'],[3,'Column reverse','column-reverse'],[4,'Row','row']]){
   const count=proof.sourceRequests.length;await choose(label,index%2===0);await waitApplied(index,value);
   assert(source().includes('display:inline-flex; flex-direction:'+value+';'));
   assert.equal(proof.sourceRequests.length,count+1);assert.equal((await computed()).display,'inline-flex');
   assert(catalog().includes('flex-direction:'+value));
   record('physical '+(index%2===0?'keyboard':'pointer')+' choice '+value+' writes once and compiles unchanged inline display');
 }
 // No-op uses the same real widget and zero new source/history work.
 const noop=await snapshot(),noopSource=source(),noopCatalog=catalog(),noopCount=proof.sourceRequests.length;
 await choose('Row');assert.deepEqual(await snapshot(),noop);assert.equal(proof.sourceRequests.length,noopCount);assert.equal(source(),noopSource);assert.equal(catalog(),noopCatalog);
 record('same direction is a no-op without source/catalog/history changes');
 await page.evaluate(()=>window.__popupAcceptance.history(false));await waitApplied(3,'column-reverse');
 assert(source().includes('flex-direction:column-reverse;'));assert.equal((await computed()).display,'inline-flex');record('native undo restores authored direction and compiled visible preview');
 await page.evaluate(()=>window.__popupAcceptance.history(true));await waitApplied(4,'row');assert.equal(source(),original);record('native redo restores exact original source');
 const before=await snapshot(),beforeSource=source(),beforeCatalog=catalog(),beforeComputed=await computed(),beforeCount=proof.sourceRequests.length;
 await page.evaluate(()=>window.__popupAcceptance.readOnly(true));
 assert((await state()).reason.length>0);
 await row.locator('[data-choice-group-trigger]').click();
 const refused=row.locator('[data-choice-group-option-label="Column"]');await refused.focus();await refused.press('Enter');
 assert.equal(source(),beforeSource);assert.equal(catalog(),beforeCatalog);assert.deepEqual(await computed(),beforeComputed);assert.equal(proof.sourceRequests.length,beforeCount);assert.equal((await snapshot()).undoCount,before.undoCount);
 await page.keyboard.press('Escape');record('live permission refuses choice with source/catalog/preview/history unchanged');
 await page.evaluate(()=>window.__popupAcceptance.readOnly(false));await choose('Column');await waitApplied(5,'column');record('restored permission enables genuine source edit');
 await page.reload();await page.waitForFunction(()=>!!window.__popupAcceptance);await page.locator('[data-toolbar-cluster="mode"] [aria-label="Edit"]').click();await page.locator('[data-scene-graph-row="action"]').click();
 await page.waitForFunction(()=>JSON.parse(window.__flexMetadata.state()).properties.some(p=>p.name==='flex-direction'&&p.authoredValue==='column'));
 assert.equal((await computed()).direction,'column');assert.equal((await computed()).display,'inline-flex');record('fresh editor reload selects current direction and authoring capability from compiled source');
 await row.locator('[data-choice-group-trigger]').click();
 const old=await row.locator('[data-choice-group-option-label="Row reverse"]').elementHandle();assert(old);
 await page.evaluate(()=>window.__popupAcceptance.clear());
 assert.equal(await row.count(),0);const retiredCount=proof.sourceRequests.length,retiredSource=source(),retiredCatalog=catalog(),retired=await snapshot();
 await old.evaluate(node=>{node.dispatchEvent(new MouseEvent('click',{bubbles:true}));node.dispatchEvent(new KeyboardEvent('keydown',{key:'Enter',bubbles:true}));});
 assert.equal(proof.sourceRequests.length,retiredCount);assert.equal(source(),retiredSource);assert.equal(catalog(),retiredCatalog);assert.deepEqual(await snapshot(),retired);record('retired actual choice callbacks cannot edit cleared selection');
 assert.deepEqual(proof.errors,[]);assert.deepEqual(proof.agentRequests,[]);
 writeFileSync(root+'/proof.json',JSON.stringify(proof,null,2));console.log('Flex metadata GUI passed:',root,proof.cases.length);
} finally {
 if(browser)await browser.close();if(browserServer)await browserServer.close();
 server.kill('SIGTERM');await new Promise(resolve=>{if(server.exitCode!==null)return resolve();server.once('exit',resolve);setTimeout(()=>{server.kill('SIGKILL');resolve();},15000).unref();});
 proof.sourceAfterSha256=createHash('sha256').update(readFileSync(project+'/stories.nim')).digest('hex');proof.catalogAfterSha256=createHash('sha256').update(readFileSync(project+'/.isonim/catalog.json')).digest('hex');
 writeFileSync(root+'/proof-final.json',JSON.stringify(proof,null,2));
}
