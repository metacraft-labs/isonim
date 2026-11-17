/** A native source project does not offer a shared rule's declaration for an
 * element another declaration decides it for, and the row says which one
 * decides (isonim-pm issue 2026-11-15-an-accepted-edit-of-a-shared-class-
 * changes-nothing-when-another-rule-decides-the-property; editor spec
 * "Saving": an edit changes the one declaration that owns the property for
 * the selected element; "Native project source capabilities": a possible
 * override prevents the producer from presenting an earlier shared rule as
 * that origin).
 *
 * The fixture's project opts `width` of the `cardStyles` constant in through
 * `editableStyleSources` (the catalog producer's path). The Card page adds a
 * rule of its own that the project does not opt in,
 * `main #reused-card { width:90px; }`, which outranks the opted-in
 * `#reused-card { width:110px; }`. The reused button's Width row is therefore
 * read-only, naming that rule, and an edit is never sent; the action button,
 * which the rule does not match, keeps its row, and its edit is written and
 * rendered (the positive control on the same page).
 *
 * Real mounted production inspector, native authenticated source worker,
 * private files and the actual Nim compiler/SSR catalog, as in
 * `test_editor_inspector_source_gui.mjs`; nothing is mocked. The configured
 * decision peer only permits daemon startup; no model prompt is sent and
 * zero agent calls are asserted.
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
const root=mkdtempSync(path.join(process.env.ISONIM_POPUP_ARTIFACTS||tmpdir(),'inspector-source-overridden-'));
const project=root+'/project',pub=root+'/public';
cpSync(repo+'/tests/fixtures/editor_inspector_project',project,{recursive:true});mkdirSync(pub);
const storyFile=project+'/stories.nim';
const pageRule='main #reused-card { width:90px; }';
{
 const original=readFileSync(storyFile,'utf8');
 const call='"documentHtml":card("Ready card", cardStyles, "action")';
 assert(original.includes(call),'fixture shape');
 writeFileSync(storyFile,original.replace(call,'"documentHtml":card("Ready card", cardStyles & "\\n'+pageRule+'\\n", "action")'));
 const manifestFile=project+'/.isonim/source-project.json',manifest=JSON.parse(readFileSync(manifestFile,'utf8'));
 delete manifest.editableStyles;
 manifest.editableStyleSources=[{file:'stories.nim',const:'cardStyles',properties:['width']}];
 writeFileSync(manifestFile,JSON.stringify(manifest,null,2));
}
const authored=readFileSync(storyFile,'utf8');
for(const [from,to] of [['src/isonim/editor/index.html','index.html'],['build/editor-inspector/editor.js','editor.js'],['node_modules/fabric/dist/index.min.js','fabric.min.js'],['node_modules/paper/dist/paper-core.min.js','paper-core.min.js'],['node_modules/svgo/dist/svgo.browser.js','svgo.browser.js']])copyFileSync(repo+'/'+from,pub+'/'+to);
const build=spawnSync('python3',[repo+'/tools/build_source_catalog.py',project],{env:{...process.env,ISONIM_SOURCE_FRAMEWORK:repo},encoding:'utf8',timeout:70000});
writeFileSync(root+'/catalog-build.log',build.stdout+build.stderr);assert.equal(build.status,0,build.stdout+build.stderr);
const proof={project,head:spawnSync('git',['rev-parse','HEAD'],{cwd:repo,encoding:'utf8'}).stdout.trim(),
 dirty:spawnSync('git',['status','--porcelain'],{cwd:repo,encoding:'utf8'}).stdout.trim().split('\n').filter(Boolean),
 nativeSha256:createHash('sha256').update(readFileSync(repo+'/build/bin/isonim-review')).digest('hex'),
 bundleSha256:createHash('sha256').update(readFileSync(pub+'/editor.js')).digest('hex'),cases:[],errors:[],agentRequests:[],sourceRequests:[]};
const record=name=>{proof.cases.push(name);writeFileSync(root+'/proof-partial.json',JSON.stringify(proof,null,2));};
const config=root+'/agent.toml';writeFileSync(config,'[agent]\nbackend="custom"\ncommand="python3"\nargs='+JSON.stringify([repo+'/tests/helpers/editor_control_peer.py'])+'\nprimer_enabled=false\n');
const port=process.env.ISONIM_OVERRIDDEN_GUI_PORT||'9934';
const server=spawn('python3',[repo+'/tools/editor_server.py','--directory',pub,'--project-root',project,'--port',port,'--bind','127.0.0.1','--config',config,'--daemon-binary',repo+'/build/bin/isonim-review'],{env:{...process.env,ISONIM_SOURCE_FRAMEWORK:repo},stdio:['ignore','pipe',openSync(root+'/server.log','w')]});
let browser,browserServer;
try {
 const origin=await new Promise((resolve,reject)=>{let text='';server.stdout.on('data',data=>{text+=data;const match=text.match(/Editor listening on (http:\/\/[^\s]+)\//);if(match)resolve(match[1]);});server.once('exit',code=>reject(Error('Server exited '+code)));setTimeout(()=>reject(Error('Server startup timeout')),70000).unref();});
 const chromeEnv={...process.env};delete chromeEnv.LD_LIBRARY_PATH;
 browserServer=await chromium.launchServer({headless:true,env:chromeEnv,executablePath:process.env.PLAYWRIGHT_CHROMIUM_EXECUTABLE});browser=await chromium.connect(browserServer.wsEndpoint());
 const page=await browser.newPage({viewport:{width:1440,height:900}});page.setDefaultTimeout(30000);
 page.on('pageerror',error=>proof.errors.push(error.message));
 page.on('request',request=>{const url=new URL(request.url());if(url.pathname.startsWith('/api/agent/'))proof.agentRequests.push(url.pathname);if(url.pathname==='/api/editor/source/operation')proof.sourceRequests.push(request.postDataJSON());});
 const source=()=>readFileSync(storyFile,'utf8');
 const frameWidth=(id)=>page.evaluate((id)=>{const frame=[...document.querySelectorAll('iframe')].find(frame=>frame.getClientRects().length&&frame.contentDocument?.getElementById(id));const target=frame?.contentDocument.getElementById(id);return target?frame.contentWindow.getComputedStyle(target).width:null;},id);
 await page.goto(origin);await page.waitForFunction(()=>!!window.__popupAcceptance);
 await page.locator('[data-toolbar-cluster="mode"] [aria-label="Switch to edit mode"]').click();
 const row=page.locator('[data-property-row-css-property="width"][data-property-row="w"][data-property-row-kind="numeric"]');
 // The reused button: the page's own rule decides its width.
 await page.locator('[data-scene-graph-row="reused"]').click();
 await row.waitFor();
 assert.equal(await frameWidth('reused-card'),'90px','the page\'s own rule decides the width');
 await page.waitForFunction(()=>document.querySelector('[data-property-row-css-property="width"][data-property-row="w"][data-property-row-kind="numeric"]')?.getAttribute('data-property-row-readonly')==='true',{},{timeout:20000}).catch(()=>{});
 assert.equal(await row.getAttribute('data-property-row-readonly'),'true','the opted-in rule is not offered for this element');
 assert.equal(await row.getAttribute('data-property-row-readonly-reason'),'Read-only: no editable source declaration in this project owns width for this element (the preview measures `main #reused-card` as deciding it).');
 const input=row.locator('[data-property-row-input]');
 await input.fill('150',{timeout:3000}).catch(()=>{});await input.press('Enter',{timeout:3000}).catch(()=>{});
 await page.waitForTimeout(1500);
 assert.equal(proof.sourceRequests.length,0,'no edit was sent');
 assert.equal(source(),authored,'nothing was written');
 assert.equal(await frameWidth('reused-card'),'90px');
 record('a shared rule another page rule outranks is not offered: the row is read-only, naming the deciding rule, and nothing is sent or written');
 // The action button, which that rule does not match: offered, written, rendered.
 await page.locator('[data-scene-graph-row="action"]').click();
 await page.waitForFunction(()=>document.querySelector('[data-property-row-css-property="width"][data-property-row="w"][data-property-row-kind="numeric"]')?.getAttribute('data-property-row-readonly')!=='true',{},{timeout:20000});
 assert.equal(await frameWidth('action'),'120px');
 await input.fill('150');await input.press('Enter');await input.press('Tab');
 await page.waitForFunction(()=>{const s=JSON.parse(window.__popupAcceptance.snapshot());return s.stage==='wesClean'&&s.undoCount===1;},{},{timeout:70000});
 assert.equal(proof.sourceRequests.length,1,'one native transaction');
 assert.equal(source(),authored.replace('#action { width:120px;','#action { width:150px;'),'the action rule owns its width');
 await page.waitForFunction(()=>{const frame=[...document.querySelectorAll('iframe')].find(frame=>frame.getClientRects().length&&frame.contentDocument?.getElementById('action'));return !!frame&&frame.contentWindow.getComputedStyle(frame.contentDocument.getElementById('action')).width==='150px';},{},{timeout:70000});
 record('on the same page an element the rule does not match keeps its row, and its edit is written and renders');
 assert.deepEqual(proof.errors,[]);assert.deepEqual(proof.agentRequests,[]);
 writeFileSync(root+'/proof.json',JSON.stringify(proof,null,2));console.log('Inspector source overridden GUI passed:',root,proof.cases.length);
} finally {
 if(browser)await browser.close();if(browserServer)await browserServer.close();
 server.kill('SIGTERM');await new Promise(resolve=>{if(server.exitCode!==null)return resolve();server.once('exit',resolve);setTimeout(()=>{server.kill('SIGKILL');resolve();},15000).unref();});
 writeFileSync(root+'/proof-final.json',JSON.stringify(proof,null,2));
}
