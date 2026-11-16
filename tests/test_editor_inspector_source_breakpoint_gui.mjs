/** At a responsive preview width, a native inspector edit is written into the
 * rule the cascade uses there, and the preview that the written file
 * produces agrees with it (isonim-pm issue 2026-11-15-edit-target-at-width-
 * ignores-important-and-never-targets-a-rule-in-layer).
 *
 * The fixture's `#action` declares `width:120px !important` and a later
 * `@media (max-width: 1080px)` block declares `width:60px`. At the Tablet
 * preview (1024px) both rules apply and the important one decides, so an
 * edit of Width must change the base rule's declaration (keeping its
 * priority) and leave the `@media` rule alone; the preview then shows the
 * new width. Writing into the `@media` rule instead (the document-order
 * choice) changes nothing that renders, which this fails on.
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
const root=mkdtempSync(path.join(process.env.ISONIM_POPUP_ARTIFACTS||tmpdir(),'inspector-source-breakpoint-'));
const project=root+'/project',pub=root+'/public';
cpSync(repo+'/tests/fixtures/editor_inspector_project',project,{recursive:true});mkdirSync(pub);
const storyFile=project+'/stories.nim';
const baseRule='#action { width:120px !important; height:48px;';
const mediaRule='@media (max-width: 1080px) { #action { width:60px; } }';
{
 const original=readFileSync(storyFile,'utf8');
 assert(original.includes('#action { width:120px; height:48px;'),'fixture shape');
 writeFileSync(storyFile,original.replace('#action { width:120px; height:48px;',baseRule)
  .replace('#secondary-action {',mediaRule+'\n#secondary-action {'));
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
const port=process.env.ISONIM_BREAKPOINT_GUI_PORT||'9973';
const server=spawn('python3',[repo+'/tools/editor_server.py','--directory',pub,'--project-root',project,'--port',port,'--bind','127.0.0.1','--config',config,'--daemon-binary',repo+'/build/bin/isonim-review'],{env:{...process.env,ISONIM_SOURCE_FRAMEWORK:repo},stdio:['ignore','pipe',openSync(root+'/server.log','w')]});
let browser,browserServer;
try {
 const origin=await new Promise((resolve,reject)=>{let text='';server.stdout.on('data',data=>{text+=data;const match=text.match(/Editor listening on (http:\/\/[^\s]+)\//);if(match)resolve(match[1]);});server.once('exit',code=>reject(Error('Server exited '+code)));setTimeout(()=>reject(Error('Server startup timeout')),70000).unref();});
 const chromeEnv={...process.env};delete chromeEnv.LD_LIBRARY_PATH;
 browserServer=await chromium.launchServer({headless:true,env:chromeEnv,executablePath:process.env.PLAYWRIGHT_CHROMIUM_EXECUTABLE});browser=await chromium.connect(browserServer.wsEndpoint());
 const page=await browser.newPage({viewport:{width:1440,height:900}});page.setDefaultTimeout(30000);
 page.on('pageerror',error=>proof.errors.push(error.message));
 page.on('request',request=>{const url=new URL(request.url());if(url.pathname.startsWith('/api/agent/'))proof.agentRequests.push(url.pathname);if(url.pathname==='/api/editor/source/operation')proof.sourceRequests.push(request.postDataJSON());});
 const snapshot=()=>page.evaluate(()=>JSON.parse(window.__popupAcceptance.snapshot()));
 const waitApplied=async(count)=>{await page.waitForFunction(count=>{const state=JSON.parse(window.__popupAcceptance.snapshot());return state.stage==='wesClean'&&state.undoCount===count;},count,{timeout:70000});};
 const source=()=>readFileSync(storyFile,'utf8');
 const preview=()=>page.evaluate(()=>{const frame=[...document.querySelectorAll('iframe')].find(frame=>frame.getClientRects().length&&frame.contentDocument?.querySelector('#action'));if(!frame)return null;return {frameWidth:frame.contentWindow.innerWidth,width:frame.contentWindow.getComputedStyle(frame.contentDocument.querySelector('#action')).width};});
 const waitPreviewWidth=async(width)=>{
  try{await page.waitForFunction(width=>{const frame=[...document.querySelectorAll('iframe')].find(frame=>frame.getClientRects().length&&frame.contentDocument?.querySelector('#action'));return !!frame&&frame.contentWindow.getComputedStyle(frame.contentDocument.querySelector('#action')).width===width;},width,{timeout:70000});}
  catch(error){throw Error('Preview #action width never became '+width+': '+JSON.stringify(await preview())+' with source '+JSON.stringify(source().slice(0,400)));}
 };
 await page.goto(origin);await page.waitForFunction(()=>!!window.__popupAcceptance);
 await page.locator('[data-toolbar-cluster="mode"] [aria-label="Switch to edit mode"]').click();
 await page.locator('[aria-label="Preview viewport Tablet"]').click();
 await page.locator('[data-scene-graph-row="action"]').click();
 const row=page.locator('[data-property-row-css-property="width"][data-property-row="w"][data-property-row-kind="numeric"]');
 await row.waitFor();assert.equal(await row.count(),1,'Actual visible width row exists');
 const input=row.locator('[data-property-row-input]');
 // The preview is at the Tablet width, where the `@media` block applies and
 // the important base declaration still decides.
 await page.waitForFunction(()=>{const frame=[...document.querySelectorAll('iframe')].find(frame=>frame.getClientRects().length&&frame.contentDocument?.querySelector('#action'));return !!frame&&frame.contentWindow.innerWidth===1024;});
 await waitPreviewWidth('120px');
 assert(await page.evaluate(()=>{const frame=[...document.querySelectorAll('iframe')].find(frame=>frame.getClientRects().length&&frame.contentDocument?.querySelector('#action'));return frame.contentWindow.matchMedia('(max-width: 1080px)').matches;}),'the @media block applies in the preview');
 const shown=await input.inputValue();
 record('Tablet preview at 1024px: the @media block applies and the important base width renders 120px');
 await input.fill('150');await input.press('Enter');await input.press('Tab');
 await waitApplied(1);
 assert.equal(proof.sourceRequests.length,1,'one native transaction');
 // The command (with the editor's viewport width) goes over the control
 // transport; the preview frame being 1024px wide is what was checked above.
 // The written file and the preview agree: the important base declaration
 // changed, priority kept, the @media rule untouched, and 150px renders.
 assert.equal(source(),authored.replace(baseRule,'#action { width:150px !important; height:48px;'),'the base rule owns width at 1024px');
 assert(source().includes(mediaRule),'the @media rule is untouched');
 await waitPreviewWidth('150px');
 assert.equal((await preview()).frameWidth,1024,'the edit was made, and is shown, at the Tablet width');
 record('an edit at 1024px is written into the important base rule the cascade uses there, and the preview renders it');
 assert.equal(shown,'120','the row shows the deciding important declaration');
 record('the width row shows the important declaration that decides, without its priority');
 await page.evaluate(()=>window.__popupAcceptance.history(false));
 await page.waitForFunction(()=>JSON.parse(window.__popupAcceptance.snapshot()).stage==='wesClean'&&JSON.parse(window.__popupAcceptance.snapshot()).undoCount===0,{},{timeout:70000});
 assert.equal(source(),authored,'undo restores the file byte for byte');
 await waitPreviewWidth('120px');
 record('undo restores the authored file byte for byte and the preview renders 120px');
 await page.evaluate(()=>window.__popupAcceptance.history(true));await waitApplied(1);
 assert.equal(source(),authored.replace(baseRule,'#action { width:150px !important; height:48px;'),'redo writes the same bytes');
 await waitPreviewWidth('150px');
 record('redo writes the same bytes into the same rule and the preview renders 150px');
 assert.deepEqual(proof.errors,[]);assert.deepEqual(proof.agentRequests,[]);
 writeFileSync(root+'/proof.json',JSON.stringify(proof,null,2));console.log('Inspector source breakpoint GUI passed:',root,proof.cases.length);
} finally {
 if(browser)await browser.close();if(browserServer)await browserServer.close();
 server.kill('SIGTERM');await new Promise(resolve=>{if(server.exitCode!==null)return resolve();server.once('exit',resolve);setTimeout(()=>{server.kill('SIGKILL');resolve();},15000).unref();});
 writeFileSync(root+'/proof-final.json',JSON.stringify(proof,null,2));
}
