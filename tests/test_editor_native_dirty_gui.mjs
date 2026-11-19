/** A native-inspector composition refuses at the act the canvas edits it
 * cannot write (Chromium).
 *
 * isonim-pm issue 2026-11-04-a-native-inspector-edit-outside-the-rows-that-
 * cannot-be-written-stays-dirty-silently; editor spec "Saving": a refusal the
 * editor can know at the act is made at the act, so a refused change never
 * reaches the preview, the history or the journal first; an edit staged
 * while no source adapter is ready is reported where it was made.
 *
 * The native composition writes through its native worker, only from the
 * inspector's property fields; it has no workspace edit adapter, so a canvas
 * resize or spacing drag staged into the journal could never be written. It
 * used to be previewed, put in history and left pending, with no report.
 * Each case: the drag previews, the release is refused with the reason shown
 * on the canvas, the preview is put back, nothing is staged or put in
 * history, the stage stays clean, and the project file is unchanged.
 *
 * Setup is the inspector-source GUI's (`tests/test_editor_inspector_source_gui.mjs`):
 * the real mounted production inspector, the native authenticated source
 * worker, private project files and the actual Nim compiler/SSR catalog. No
 * UI, source, compiler, HTTP or dispatcher is mocked; no model prompts.
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
// The inspector-source GUI's transform owners are not added: a rotated element
// refuses every canvas handle at the press, before the case this test is about.
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

 const reason="This project's native source writer changes source only through the inspector's property fields; this edit cannot be written. Nothing was changed.";
 const frame=page.frameLocator('iframe[title="Editable component preview"]');
 const message=()=>frame.locator('#isonim-editor-box-drag-message').textContent().catch(()=>'');
 const original=source();
 const startState=await snapshot();
 assert.equal(startState.sourcePlans,0);assert.equal(startState.undoCount,0);
 async function refusedDrag(name,label,dx,dy){
  const handle=frame.getByLabel(label,{exact:true});
  await handle.waitFor();
  const before=await previewWidth();
  const box=await handle.boundingBox();const x=box.x+box.width/2,y=box.y+box.height/2;
  await page.mouse.move(x,y);await page.mouse.down();
  for(let i=1;i<=3;i++)await page.mouse.move(x+dx*i/3,y+dy*i/3);
  const during=await page.evaluate(()=>{const f=[...document.querySelectorAll('iframe')].find(f=>f.getClientRects().length&&f.contentDocument?.querySelector('#action'));const t=f.contentDocument.querySelector('#action');const cs=f.contentWindow.getComputedStyle(t);return {width:cs.width,padding:cs.paddingTop};});
  await page.mouse.up();
  // Waited on state: the reason on the canvas, or the state that shows the
  // edit was not refused.
  const deadline=Date.now()+60000;
  while(Date.now()<deadline&&!(await message()).includes(reason.slice(0,40)))await page.waitForTimeout(100);
  if(!(await message()).includes(reason.slice(0,40))){const s=await snapshot();throw new Error(name+': no refusal on the canvas; stage '+s.stage+', staged plans '+s.sourcePlans+', history '+s.undoCount+', preview width '+(await previewWidth())+', file '+(source()===original?'unchanged':'changed'));}
  assert.equal((await message()).trim(),reason,name+': the reason is shown on the canvas');
  assert.equal(await previewWidth(),before,name+': the preview is put back');
  const state=await snapshot();
  assert.equal(state.sourcePlans,0,name+': nothing is staged');
  assert.equal(state.undoCount,0,name+': nothing is put in history');
  assert.equal(state.stage,'wesClean',name+': the stage stays clean');
  assert.equal(source(),original,name+': the project file is unchanged');
  record(name+': refused at the act, put back, reason shown, nothing staged');
  return during;
 }
 await page.locator('[data-scene-graph-row="action"]').click();
 const resized=await refusedDrag('canvas resize','Resize selected element',-30,0);
 assert.notEqual(resized.width,'120px','the resize drag previewed before its release');
 await page.locator('[data-scene-graph-row="action"]').click();
 await refusedDrag('canvas spacing','Adjust selected spacing',0,6);
 // The inspector row still writes through the native worker (control).
 await input.fill('130px');await input.press('Enter');await waitApplied(1);
 assert(source().includes('width:130px;'),'the native row still writes');
 record('the inspector row still writes through the native worker');
 assert.deepEqual(proof.errors,[]);assert.deepEqual(proof.agentRequests,[]);
 writeFileSync(root+'/proof.json',JSON.stringify(proof,null,2));console.log('Native dirty GUI passed:',root,proof.cases.length);
} finally {if(browser)await browser.close();if(browserServer)await browserServer.close();server.kill('SIGTERM');await new Promise(resolve=>{if(server.exitCode!==null)return resolve();server.once('exit',resolve);setTimeout(()=>{server.kill('SIGKILL');resolve();},15000).unref();});}
