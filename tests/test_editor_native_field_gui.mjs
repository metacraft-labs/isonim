/** A native composition's shorthand and rapid canvas edits (Chromium).
 *
 * Editor spec "Visual box model": "a shorthand edit moves the sides the
 * shorthand decides", "The preview shows the same values, before the write
 * and after it", the reverse case ("A value edit of a side that a later ...
 * shorthand in the same rule still overrides is refused at the act with that
 * reason, and nothing changes"), a drag "back to the value in place, commits
 * nothing", and a refused commit's reason shown "on the canvas beside the
 * selection until the next drag or another selection"; "Edit Mode": a
 * spacing release another declaration decides for the element is refused at
 * the act; "Saving": a refusal the editor can know at the act is made at the
 * act.
 *
 * N1: `#action` declares every padding side after its `padding`, so an edit
 * of the shorthand moves none: the all-sides field and the spacing handle
 * are refused at the act with the reason, and nothing is written or added
 * to history. `#secondary-action` declares only its left side after it: a
 * spacing drag previews the three sides the shorthand moves, and the
 * written file renders the same. A drag that ends on the value in place
 * writes nothing and leaves no preview hold.
 * N2: a second release while the first native write is in flight is refused
 * ("Wait for the current source build to complete."), and its reason stays
 * beside the selection after the first write's rebuild, so two drags and one
 * history entry are explained.
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
// One side declared after the shorthand (N1, partial).
writeFileSync(storyFile,readFileSync(storyFile,'utf8').replace('#secondary-action { width:160px; height:52px; padding:12px;','#secondary-action { width:160px; height:52px; padding:12px; padding-left:4px;'));
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
 const status=()=>page.locator('[data-save-error]').textContent().catch(()=>'');
 const sides=async id=>{for(let k=0;k<120;k++){const r=await page.evaluate(id=>{const f=[...document.querySelectorAll('iframe')].find(f=>f.getClientRects().length&&f.contentDocument?.querySelector('#'+id));if(!f)return null;const n=f.contentDocument.querySelector('#'+id);const s=f.contentWindow.getComputedStyle(n);return {sides:['top','right','bottom','left'].map(k=>s.getPropertyValue('padding-'+k)),width:s.width,inline:n.getAttribute('style')||''};},id).catch(()=>null);if(r)return r;await page.waitForTimeout(250);}throw new Error('no preview frame showing #'+id);};
 const ruleOf=id=>(source().match(new RegExp('#'+id+' \\{[^}]*\\}'))||[''])[0];
 const settled=async(count,what)=>{const deadline=Date.now()+240000;let s=await snapshot();while(Date.now()<deadline&&!(s.stage==='wesClean'&&!s.sourceInFlight&&s.undoCount===count)){await page.waitForTimeout(250);s=await snapshot();}
  if(!(s.stage==='wesClean'&&s.undoCount===count))throw new Error(what+': not settled; stage '+s.stage+', history '+s.undoCount+' (expected '+count+')');};
 const select=async id=>{await page.locator('[data-scene-graph-row="'+id+'"]').click();await frame.locator('#'+id+'[data-isonim-selected="true"]').waitFor();
  const layout=page.locator('[data-inspector-section-header="layout"]');if((await layout.getAttribute('aria-expanded'))!=='true')await layout.click();
  const toggle=page.getByRole('button',{name:'Show box model controls'});await toggle.waitFor();if((await toggle.getAttribute('aria-expanded'))!=='true')await toggle.click();};
 const press=async(label)=>{const h=frame.getByLabel(label,{exact:true});await h.waitFor();const b=await h.boundingBox();const x=b.x+b.width/2,y=b.y+b.height/2;await page.mouse.move(x,y);await page.mouse.down();return {x,y};};
 const OVERRIDDEN=/^(Read-only: )?`padding` for `#action` cannot be edited here: in .*`padding-top`, `padding-right`, `padding-bottom` and `padding-left` are each declared after it or `!important` over it, so it decides no side and the edit would change nothing that renders\. Edit those declarations instead\.$/;

 // N1a: the native writer states that `padding` on #action decides no side
 // (every side is declared after it), so the all-sides field is read-only
 // with that reason, as a field the project's writer makes read-only is
 // ("Visual box model"), and a commit is refused at the act before any
 // request ("Saving").
 {
  await select('action');const s0=await snapshot(),file0=source(),shown0=await sides('action');
  const field=page.getByRole('textbox',{name:'Padding, all sides',exact:true});
  await page.waitForFunction(()=>{const f=[...document.querySelectorAll('input')].find(i=>i.getAttribute('aria-label')==='Padding, all sides');return f&&f.getAttribute('aria-readonly')==='true';},null,{timeout:60000});
  const reason=await field.getAttribute('title');
  assert.match(reason,OVERRIDDEN,'the field says why: '+reason);
  await field.click();await page.keyboard.type('24');await page.keyboard.press('Enter');await page.waitForTimeout(1500);
  const s1=await snapshot();
  assert.equal(s1.undoCount,s0.undoCount,'nothing is added to history');assert.equal(s1.sourcePlans,0);assert.notEqual(s1.stage,'wesFailed');
  assert.deepEqual((await sides('action')).sides,shown0.sides,'the preview is unchanged');
  assert.equal(source(),file0,'nothing is written');
  record('the all-sides field is read-only with the writer\'s reason when every side is declared after the shorthand');
 }
 // N1b: the spacing handle on #action is refused at the press.
 {
  await select('action');const s0=await snapshot(),file0=source(),shown0=await sides('action');
  const at=await press('Adjust selected spacing');for(let i=1;i<=3;i++)await page.mouse.move(at.x,at.y+6*i/3);
  const mid=await sides('action');await page.mouse.up();
  assert.deepEqual(mid.sides,shown0.sides,'nothing moves while the pointer moves');
  assert.match((await message()).trim(),OVERRIDDEN,'the reason is on the canvas');
  await page.waitForTimeout(1500);
  const s1=await snapshot();assert.equal(s1.undoCount,s0.undoCount);assert.equal(s1.stage,'wesClean');assert.equal(source(),file0,'nothing is written');
  assert.deepEqual((await sides('action')).sides,shown0.sides,'the preview is unchanged');
  record('the spacing handle is refused at the press with the reason when every side is declared after the shorthand');
 }
 // N1c: partial -- the drag previews the three sides the shorthand moves,
 // and the written file renders the same.
 {
  await select('secondary-action');const s0=await snapshot();
  const shown0=await sides('secondary-action');assert.deepEqual(shown0.sides,['12px','12px','12px','4px']);
  const at=await press('Adjust selected spacing');for(let i=1;i<=3;i++)await page.mouse.move(at.x,at.y+6*i/3);
  const mid=await sides('secondary-action');await page.mouse.up();
  assert.equal(mid.sides[3],'4px','the left side, declared after the shorthand, does not move');
  assert.ok(mid.sides[0]!=='12px'&&mid.sides[0]===mid.sides[1]&&mid.sides[1]===mid.sides[2],'the shorthand\'s sides move together: '+mid.sides);
  await settled(s0.undoCount+1,'partial spacing drag');
  const rule=ruleOf('secondary-action');
  assert.ok(rule.includes('padding:'+mid.sides[0]+'; padding-left:4px;'),'the shorthand written is the value shown: '+rule);
  const after=await sides('secondary-action');
  assert.deepEqual(after.sides,mid.sides,'the preview after the write shows what it showed before it');
  assert.equal((await message()).trim(),'','no refusal');
  record('a spacing drag previews only the sides the shorthand moves, and the write renders the same ('+mid.sides.join(' ')+')');
 }
 // N1d: a drag back to the value in place writes nothing and leaves no hold.
 {
  await select('secondary-action');const s0=await snapshot(),file0=source(),shown0=await sides('secondary-action');
  const at=await press('Adjust selected spacing');
  for(let i=1;i<=3;i++)await page.mouse.move(at.x,at.y+9*i/3);
  for(let i=1;i<=3;i++)await page.mouse.move(at.x,at.y+9-9*i/3);
  await page.mouse.up();
  const deadline=Date.now()+60000;let now=await sides('secondary-action');
  while(Date.now()<deadline&&now.inline.includes('padding')){await page.waitForTimeout(200);now=await sides('secondary-action');}
  assert.ok(!now.inline.includes('padding'),'no preview hold is left: '+now.inline);
  assert.deepEqual(now.sides,shown0.sides,'the preview shows the file');
  const s1=await snapshot();assert.equal(s1.undoCount,s0.undoCount,'nothing is added to history');assert.equal(source(),file0,'nothing is written');
  assert.equal((await message()).trim(),'','no refusal');
  record('a spacing drag back to the value in place writes nothing and leaves no preview hold');
 }
 // N2: a second release while the first write is in flight.
 {
  await select('secondary-action');const s0=await snapshot();
  const width0=(await sides('secondary-action')).width;
  for(let k=0;k<2;k++){const at=await press('Resize selected element');for(let i=1;i<=3;i++)await page.mouse.move(at.x-10*i/3,at.y);await page.mouse.up();}
  const firstMessage=(await message()).trim();
  await settled(s0.undoCount+1,'first resize');await page.waitForTimeout(2000);
  const s1=await snapshot();assert.equal(s1.undoCount,s0.undoCount+1,'one entry: the second release was refused');
  const written=(ruleOf('secondary-action').match(/width:([^;]+);/)||[])[1];
  assert.notEqual(written,width0,'the first release is written');
  assert.equal((await sides('secondary-action')).width,written,'the preview shows the written width');
  assert.equal(firstMessage,'Wait for the current source build to complete.','the second release is refused with the reason');
  assert.equal((await message()).trim(),firstMessage,'the reason is still beside the selection after the first write\'s rebuild');
  // Until the next drag: a press clears it.
  const at=await press('Resize selected element');await page.mouse.up();
  assert.equal((await message()).trim(),'','the next drag clears the reason');
  record('a release refused while the first write is in flight keeps its reason after the rebuild (written '+written+')');
 }
 // Control: the all-sides field still writes the partial rule.
 {
  await select('secondary-action');const s0=await snapshot();
  const field=page.getByRole('textbox',{name:'Padding, all sides',exact:true});
  await field.click();await field.press('ControlOrMeta+A');await page.keyboard.type('20');await field.press('Enter');
  await settled(s0.undoCount+1,'field control');
  assert.ok(ruleOf('secondary-action').includes('padding:20px; padding-left:4px;'),ruleOf('secondary-action'));
  assert.deepEqual((await sides('secondary-action')).sides,['20px','20px','20px','4px']);
  record('the all-sides field still writes where the shorthand decides sides');
 }
 assert.deepEqual(proof.errors,[]);assert.deepEqual(proof.agentRequests,[]);
 writeFileSync(root+'/proof.json',JSON.stringify(proof,null,2));console.log('Native field GUI passed:',root,proof.cases.length);
} finally {if(browser)await browser.close();if(browserServer)await browserServer.close();server.kill('SIGTERM');await new Promise(resolve=>{if(server.exitCode!==null)return resolve();server.once('exit',resolve);setTimeout(()=>{server.kill('SIGKILL');resolve();},15000).unref();});}
