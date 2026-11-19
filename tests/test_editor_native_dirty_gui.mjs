/** In a native-inspector composition the canvas size and spacing handles
 * write through the native worker, and an agent proposal is refused at
 * acceptance (Chromium).
 *
 * isonim-pm issue 2026-11-04-a-native-inspector-edit-outside-the-rows-that-
 * cannot-be-written-stays-dirty-silently and the native follow-up; editor
 * spec "Edit Mode" (resize handles on the selection box allow direct
 * width/height manipulation), "Saving" (a refusal the editor can know at the
 * act is made at the act; a refused change never reaches the preview, the
 * history or the journal) and "Native project source capabilities" (the
 * native worker writes through the guarded operation).
 *
 * The native composition writes through its native worker; it has no
 * workspace edit adapter, so anything staged in the journal could never be
 * written. The width, height and spacing handles now commit through the row
 * pipeline of the property they drag, as the margin and padding handles
 * already did, and the value written is the one the preview showed. A
 * release the field would refuse (a read-only workspace) is refused, put
 * back, with the reason on the canvas. An agent proposal's plans could never
 * be written, so accepting one is refused with the reason on the proposal.
 * Control: the inspector row still writes.
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

 const frame=page.frameLocator('iframe[title="Editable component preview"]');
 const message=()=>frame.locator('#isonim-editor-box-drag-message').textContent().catch(()=>'');
 const original=source();
 const startState=await snapshot();
 assert.equal(startState.sourcePlans,0);assert.equal(startState.undoCount,0);
 // Native-followup (b): the width, height and spacing handles commit through
 // the native worker, as the row and the margin/padding handles do.
 const ruleOf=(id)=>(source().match(new RegExp('#'+id+' \\{[^}]*\\}'))||[''])[0];
 async function writtenDrag(name,label,dx,dy,property,id='action'){
  const actionRule=()=>ruleOf(id);
  await page.locator('[data-scene-graph-row="'+id+'"]').click();
  const handle=frame.getByLabel(label,{exact:true});await handle.waitFor();
  const before=await snapshot(),ruleBefore=actionRule();
  const box=await handle.boundingBox();const x=box.x+box.width/2,y=box.y+box.height/2;
  await page.mouse.move(x,y);await page.mouse.down();
  for(let i=1;i<=3;i++)await page.mouse.move(x+dx*i/3,y+dy*i/3);
  const shown=await page.evaluate(p=>{const f=[...document.querySelectorAll('iframe')].find(f=>f.getClientRects().length&&f.contentDocument?.querySelector('#'+p[1]));return f.contentWindow.getComputedStyle(f.contentDocument.querySelector('#'+p[1])).getPropertyValue(p[0]);},[property==='padding'?'padding-left':property,id]);
  await page.mouse.up();
  // Waited on state: the write applied, or a refusal shown on the canvas.
  const deadline=Date.now()+240000;let state=await snapshot();
  while(Date.now()<deadline&&!(state.stage==='wesClean'&&state.undoCount===before.undoCount+1)&&!(await message()).trim()){await page.waitForTimeout(200);state=await snapshot();}
  if(!(state.stage==='wesClean'&&state.undoCount===before.undoCount+1))throw new Error(name+': not written; stage '+state.stage+', history '+state.undoCount+', canvas message '+JSON.stringify((await message()).trim())+', preview showed '+shown);
  const rule=actionRule();
  assert.notEqual(rule,ruleBefore,name+': the native worker wrote the file');
  const written=(rule.match(new RegExp('(?:^|[ {;])'+property+':([^;]+);'))||[])[1];
  assert.ok(written,name+': the rule declares '+property+' ('+rule+')');
  if(property!=='padding')assert.equal(written,shown,name+': the value written is the one the preview showed');
  const after=await snapshot();
  assert.equal(after.sourcePlans,0,name+': nothing is left staged');
  assert.equal(after.stage,'wesClean',name+': the write completed');
  assert.equal((await message()).trim(),'',name+': no refusal');
  record(name+': written through the native worker ('+property+':'+written+')');
 }
 await writtenDrag('canvas resize','Resize selected element',-30,0,'width');
 // The height handle takes the same route as the width handle; in this
 // fixture's preview an !important height declaration holds every button's
 // height, which refuses the height handle at the press ("height does not
 // follow the drag"), so it is not driven here.
 await writtenDrag('canvas spacing','Adjust selected spacing',0,6,'padding');
 // A refusal the native field would make at the act (a read-only
 // workspace): the release is refused, the preview put back, the reason shown.
 {
  await page.evaluate(()=>window.__popupAcceptance.readOnly(true));
  await page.locator('[data-scene-graph-row="action"]').click();
  const handle=frame.getByLabel('Resize selected element',{exact:true});await handle.waitFor();
  const before=await previewWidth(),state0=await snapshot(),file0=source();
  const box=await handle.boundingBox();const x=box.x+box.width/2,y=box.y+box.height/2;
  await page.mouse.move(x,y);await page.mouse.down();for(let i=1;i<=3;i++)await page.mouse.move(x-20*i/3,y);await page.mouse.up();
  const deadline=Date.now()+30000;
  while(Date.now()<deadline&&!(await message()).trim())await page.waitForTimeout(100);
  assert.match((await message()).trim(),/read-only/,'the reason is shown on the canvas');
  assert.equal(await previewWidth(),before,'the preview is put back');
  const state=await snapshot();
  assert.equal(state.undoCount,state0.undoCount,'nothing is put in history');assert.equal(state.sourcePlans,0,'nothing staged');
  assert.equal(source(),file0,'the file is unchanged');
  await page.evaluate(()=>window.__popupAcceptance.readOnly(false));
  record('a native canvas release the field would refuse is refused at release and put back');
 }
 // Native-followup (a): an agent proposal accepted in this composition is
 // refused at acceptance (its plans could never be written), with the reason
 // on the proposal, which stays proposed; nothing staged, the stage not failed.
 {
  await page.locator('[data-scene-graph-row="action"]').click();
  const proposalFile=source();
  const id=await page.evaluate(()=>window.__popupAcceptance.propose('width','140px'));
  await page.locator('[data-toolbar-cluster="mode"] [aria-label="Switch to view mode"]').click();
  const accept=page.getByRole('button',{name:'Accept agent edit '+id,exact:true});
  await accept.waitFor();await accept.click();
  const card=page.locator('[data-agent-proposal="'+id+'"]');
  const note=card.locator('[data-agent-proposal-refusal="true"]');
  await note.waitFor({timeout:20000}).catch(async()=>{throw new Error('no refusal on the proposal; card '+JSON.stringify(await card.innerText())+' status '+await card.getAttribute('data-agent-proposal-status')+' snapshot '+JSON.stringify(await snapshot()).slice(0,300));});
  assert.equal((await note.textContent()).trim(),"This project's native source writer changes source only through the inspector's property fields; this proposal cannot be written.",'the reason is on the proposal');
  assert.match(await card.getAttribute('data-agent-proposal-status'),/proposed/,'the proposal stays proposed');
  const state=await snapshot();
  assert.equal(state.sourcePlans,0,'nothing is staged');assert.notEqual(state.stage,'wesFailed','no failed write');
  assert.equal(source(),proposalFile,'the project file is unchanged');
  record('an accepted agent proposal is refused at acceptance, reason on the proposal, nothing staged');
  await page.locator('[data-toolbar-cluster="mode"] [aria-label="Switch to edit mode"]').click();
  await page.locator('[data-scene-graph-row="action"]').click();
 }
 // The inspector row still writes through the native worker (control).
 const rowBefore=(await snapshot()).undoCount;await input.fill('130px');await input.press('Enter');await waitApplied(rowBefore+1);
 assert(source().includes('width:130px;'),'the native row still writes');
 record('the inspector row still writes through the native worker');
 assert.deepEqual(proof.errors,[]);assert.deepEqual(proof.agentRequests,[]);
 writeFileSync(root+'/proof.json',JSON.stringify(proof,null,2));console.log('Native dirty GUI passed:',root,proof.cases.length);
} finally {if(browser)await browser.close();if(browserServer)await browserServer.close();server.kill('SIGTERM');await new Promise(resolve=>{if(server.exitCode!==null)return resolve();server.once('exit',resolve);setTimeout(()=>{server.kill('SIGKILL');resolve();},15000).unref();});}
