/** verify_ux_inspector_persistence (editor UX-M3, Verification V2).
 *
 * A real temporary source project, the native source worker, the actual Nim
 * compiler and SSR catalog, and the mounted production inspector: a value
 * reached through either modality -- typed, and a pointer scrub -- is
 * written to the source, compiled into the preview and read back after a
 * reload; a refusal (a non-finite value; a value the project's compile-time
 * constraint rejects) restores source, catalog, control and preview; a
 * typed draft still in its field when the selection changes is written to
 * neither the old selection nor the new one.
 * (Editor spec "Planned interaction parity": "A refused source edit
 * restores the control and preview"; "Saving": a draft belongs to the
 * selection it was started on.)
 *
 * No UI, source, compiler, HTTP or dispatcher is mocked; the setup is the
 * one `test_editor_inspector_source_gui.mjs` uses (its fixture's
 * compile-time constraint, `width:777px`, is a real negative compiler
 * control). The controlled decision peer only permits daemon startup; no
 * model prompt is sent.
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
const root=mkdtempSync(path.join(process.env.ISONIM_POPUP_ARTIFACTS||tmpdir(),'verify-persistence-'));
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
const server=spawn('python3',[repo+'/tools/editor_server.py','--directory',pub,'--project-root',project,'--port',String(process.env.ISONIM_VERIFY_PERSISTENCE_PORT||0),'--bind','127.0.0.1','--config',config,'--daemon-binary',repo+'/build/bin/isonim-review'],{env:{...process.env,ISONIM_SOURCE_FRAMEWORK:repo},stdio:['ignore','pipe',openSync(root+'/server.log','w')]});
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
 const cases=[];
 const previewWidthOf=(id)=>page.evaluate((id)=>{const frame=[...document.querySelectorAll('iframe')].find(frame=>frame.getClientRects().length&&frame.contentDocument?.querySelector('#'+id));const target=frame?.contentDocument.querySelector('#'+id);return target?frame.contentWindow.getComputedStyle(target).width:null;},id);
 const declared=(id)=>{const m=source().match(new RegExp('#'+id+' \\{ width:([^;]+);'));return m?m[1]:null;};
 const open=async()=>{await page.reload();await page.waitForFunction(()=>!!window.__popupAcceptance);await page.locator('[data-toolbar-cluster="mode"] [aria-label="Switch to edit mode"]').click();await page.locator('[data-scene-graph-row="action"]').click();await row.waitFor();};
 const previewSettles=(id,value)=>page.waitForFunction(([id,value])=>{const frame=[...document.querySelectorAll('iframe')].find(frame=>frame.getClientRects().length&&frame.contentDocument?.querySelector('#'+id));return frame&&frame.contentWindow.getComputedStyle(frame.contentDocument.querySelector('#'+id)).width===value;},[id,value],{timeout:70000});
 assert.equal(declared('action'),'120px');assert.equal(await input.inputValue(),'120');

 // Typed: written, compiled into the preview, read back after a reload.
 await input.fill('100+50');await input.press('Enter');await input.press('Tab');
 await waitApplied(1);assert.equal(declared('action'),'150px','typed value written');
 await previewSettles('action','150px');
 assert.equal(proof.sourceRequests.length,1,'one native transaction for the typed value');
 await open();
 assert.equal(await input.inputValue(),'150','reload reads the typed value from the compiled source');
 assert.equal(await previewWidthOf('action'),'150px','and the preview shows it');
 cases.push('a typed value is written, compiled into the preview and read back after a reload');

 // Pointer scrub: written, compiled, read back.
 const handle=row.locator('[data-property-row-field-label]');
 await handle.scrollIntoViewIfNeeded();
 const box=await handle.boundingBox();assert(box);
 await page.mouse.move(box.x+box.width/2,box.y+box.height/2);await page.mouse.down();await page.mouse.move(box.x+box.width/2+25,box.y+box.height/2);await page.mouse.up();
 await waitApplied(1);assert.equal(declared('action'),'200px','scrubbed value written');
 await previewSettles('action','200px');
 assert.equal(proof.sourceRequests.length,2,'one native transaction for the scrub');
 await open();
 assert.equal(await input.inputValue(),'200','reload reads the scrubbed value');
 assert.equal(await previewWidthOf('action'),'200px','and the preview shows it');
 cases.push('a pointer scrub is written, compiled into the preview and read back after a reload');

 // Refusals restore source, catalog, control and preview.
 const before=source(),catalogBefore=readFileSync(project+'/.isonim/catalog.json','utf8'),requests=proof.sourceRequests.length;
 for(const bad of ['1e999px','NaNpx']){
  await input.fill(bad);await input.press('Enter');await input.press('Tab');
  assert.equal(await input.inputValue(),'200',bad+': the control is put back');
  assert.equal(source(),before,bad+': source unchanged');assert.equal(proof.sourceRequests.length,requests,bad+': nothing sent');
 }
 await input.fill('777px');await input.press('Enter');
 await page.waitForFunction(()=>JSON.parse(window.__popupAcceptance.snapshot()).stage==='wesFailed',null,{timeout:70000});
 assert.equal(source(),before,'a compiler refusal restores the exact source');
 assert.equal(readFileSync(project+'/.isonim/catalog.json','utf8'),catalogBefore,'and the published catalog');
 assert.equal(await input.inputValue(),'200','and the control');
 assert.equal(await previewWidthOf('action'),'200px','and the preview');
 cases.push('a non-finite value and a compiler refusal restore source, catalog, control and preview');

 // A draft still in its field when the selection changes -- the field never
 // losing focus, so nothing commits it on the way -- is written to neither
 // element: Enter in that field afterwards (on the field itself, held across
 // the change) commits nothing.
 await open();
 const secondBefore=declared('secondary-action'),firstBefore=declared('action'),requestsBefore=proof.sourceRequests.length;
 await input.click();await input.fill('333');
 const draftField=await input.elementHandle();
 assert.equal(await draftField.evaluate(n=>document.activeElement===n),true,'the draft field has focus');
 assert.equal(await page.evaluate(()=>window.__popupAcceptance.select('secondary-action')),true,'the selection changes in the page');
 await page.waitForTimeout(1500);
 await draftField.evaluate(n=>{n.dispatchEvent(new KeyboardEvent('keydown',{key:'Enter',bubbles:true}));n.dispatchEvent(new Event('change',{bubbles:true}));});
 await page.waitForTimeout(1500);
 await page.waitForFunction(()=>JSON.parse(window.__popupAcceptance.snapshot()).stage!=='wesWriting',null,{timeout:70000});
 assert.equal(declared('secondary-action'),secondBefore,'the new selection does not receive the draft');
 assert.equal(declared('action'),firstBefore,'the first selection keeps its value: the draft was never committed');
 assert.equal(proof.sourceRequests.length,requestsBefore,'nothing is sent to the writer');
 assert.equal(await input.inputValue(),'160','the field shows the new selection\'s value');
 cases.push('a draft left in its field across a selection change is written to neither selection');

 assert.deepEqual(proof.errors,[],'no page errors');
 assert.equal(proof.agentRequests.length,0,'no agent calls');
 console.log('verify_ux_inspector_persistence passed:',root,cases.length);
} finally {
 if(browser)await browser.close();if(browserServer)await browserServer.close();
 server.kill('SIGTERM');await new Promise(resolve=>{if(server.exitCode!==null)return resolve();server.once('exit',resolve);setTimeout(()=>{server.kill('SIGKILL');resolve();},15000).unref();});
 writeFileSync(root+'/proof-final.json',JSON.stringify(proof,null,2));
}
