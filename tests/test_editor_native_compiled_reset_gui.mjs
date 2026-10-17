/** Reset, set, undo, undo for a compiled (derived) native binding, and a
 * selector-list rule refused with its reason (isonim-pm issues
 * 2026-10-16-compiled-bindings-cannot-be-re-set-after-reset-removes-their-
 * last-declaration and 2026-10-16-selector-list-rules-are-admitted-for-edit-
 * and-removal; editor spec "Universal Patterns": Reset is "validated,
 * written and undoable like any edit" and the property can be set again;
 * "Saving": an edit changes exactly the one owning declaration and a refusal
 * known at the act is made there). Real mounted production inspector, the
 * native authenticated source worker, private files and the actual Nim
 * compiler/SSR catalog; physical pointer and keyboard input. No UI, source,
 * compiler, HTTP or dispatcher is mocked. The controlled decision peer only
 * permits daemon startup; zero agent calls are asserted.
 * The project opts cardStyles' width in through `editableStyleSources`, so
 * #reused-card's width is a compiled binding whose only declaration Reset
 * removes: the binding keeps offering width, the worker inserts a typed value
 * into #reused-card, and undo removes it and then restores the removed line,
 * each step at exact source bytes.
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
const root=mkdtempSync(path.join(process.env.ISONIM_POPUP_ARTIFACTS||tmpdir(),'native-compiled-reset-'));
const project=root+'/project',pub=root+'/public';
cpSync(repo+'/tests/fixtures/editor_inspector_project',project,{recursive:true});mkdirSync(pub);
const manifestFile=project+'/.isonim/source-project.json',manifest=JSON.parse(readFileSync(manifestFile,'utf8'));
delete manifest.editableStyles;manifest.editableStyleSources=[{file:'stories.nim',const:'cardStyles',properties:['width']}];
writeFileSync(manifestFile,JSON.stringify(manifest,null,2));
for(const [from,to] of [['src/isonim/editor/index.html','index.html'],['build/editor-inspector/editor.js','editor.js'],['node_modules/fabric/dist/index.min.js','fabric.min.js'],['node_modules/paper/dist/paper-core.min.js','paper-core.min.js'],['node_modules/svgo/dist/svgo.browser.js','svgo.browser.js']])copyFileSync(repo+'/'+from,pub+'/'+to);
const catalogBuild=()=>{const build=spawnSync('python3',[repo+'/tools/build_source_catalog.py',project],{env:{...process.env,ISONIM_SOURCE_FRAMEWORK:repo},encoding:'utf8',timeout:70000});writeFileSync(root+'/catalog-build.log',build.stdout+build.stderr,{flag:'a'});assert.equal(build.status,0,build.stdout+build.stderr);};
catalogBuild();
const proof={project,head:process.env.ISONIM_TEST_HEAD||spawnSync('git',['rev-parse','HEAD'],{cwd:repo,encoding:'utf8'}).stdout.trim(),sourceState:process.env.ISONIM_TEST_SOURCE_STATE||'working copy',nativeSha256:createHash('sha256').update(readFileSync(repo+'/build/bin/isonim-review')).digest('hex'),bundleSha256:createHash('sha256').update(readFileSync(pub+'/editor.js')).digest('hex'),cases:[],errors:[],agentRequests:[],sourceRequests:[],inspectorRequests:[]};
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
 page.on('request',request=>{try{const body=request.postDataJSON();if(body?.method==='editor.inspector-source')proof.inspectorRequests.push(body.params.request);}catch(error){}});
 const open=async target=>{await page.goto(origin);await page.waitForFunction(()=>!!window.__popupAcceptance);
  await page.locator('[data-toolbar-cluster="mode"] [aria-label="Edit"]').click();
  await page.locator('[data-scene-graph-row="'+target+'"]').click();};
 await open('reused');
 const snapshot=()=>page.evaluate(()=>JSON.parse(window.__popupAcceptance.snapshot()));
 const settled=count=>page.waitForFunction(count=>{const s=JSON.parse(window.__popupAcceptance.snapshot());return s.stage==='wesClean'&&!s.sourceInFlight&&s.undoCount===count;},count,{timeout:70000});
 const source=()=>readFileSync(project+'/stories.nim','utf8');
 const previewWidth=id=>page.evaluate(id=>{const frame=[...document.querySelectorAll('iframe')].find(frame=>frame.getClientRects().length&&frame.contentDocument?.getElementById(id));const target=frame?.contentDocument.getElementById(id);return target&&frame.contentWindow.getComputedStyle(target).width;},id);
 const row=page.locator('[data-property-row-css-property="width"][data-property-row-kind="numeric"]').first();
 await row.waitFor();
 const input=row.locator('[data-property-row-input]');
 const label=row.locator('[data-property-row-field-label="true"]');
 const menu=row.locator('[data-property-actions-menu="true"]');
 const reset=menu.getByRole('menuitem',{name:'Reset'});
 const original=source();
 const rule='#reused-card { width:110px; height:40px; background-color:#224466; }';
 assert(original.includes(rule));
 const removed=original.replace(rule,'#reused-card { height:40px; background-color:#224466; }');
 const set=original.replace(rule,'#reused-card { height:40px; background-color:#224466; width:150px; }');
 assert.equal(await previewWidth('reused-card'),'110px');
 const start=(await snapshot()).undoCount;assert.equal(proof.sourceRequests.length,0);

 // Reset: right-click the row, Reset removes the binding's only declaration.
 await label.click({button:'right'});await menu.waitFor({state:'visible'});
 assert.equal(await reset.getAttribute('aria-disabled'),'false');
 await reset.click();await settled(start+1);
 assert.equal(source(),removed,'Reset removes exactly the width declaration');
 await page.waitForFunction(()=>{const frame=[...document.querySelectorAll('iframe')].find(frame=>frame.getClientRects().length&&frame.contentDocument?.getElementById('reused-card'));return frame&&frame.contentWindow.getComputedStyle(frame.contentDocument.getElementById('reused-card')).width!=='110px';},{timeout:70000});
 assert.equal(proof.sourceRequests.length,1);assert.equal(proof.inspectorRequests.at(-1).value,'');
 record('Reset removes the compiled binding\'s only width declaration through the native writer');

 // The binding still offers width: the row is editable, not read-only.
 await page.waitForFunction(()=>{const el=document.querySelector('[data-property-row-css-property="width"][data-property-row-kind="numeric"] [data-property-row-input]');return el&&!el.readOnly&&!el.disabled;},{timeout:10000}).catch(()=>{});
 assert.equal(await row.getAttribute('data-property-row-readonly'),'false','After Reset the compiled width row is editable, not read-only');
 assert.equal(await input.evaluate(el=>el.readOnly||el.disabled),false);
 await input.click();await input.fill('150');await input.press('Enter');
 await settled(start+2);
 assert.equal(source(),set,'Setting the reset property inserts exactly one declaration into its rule');
 await page.waitForFunction(()=>{const frame=[...document.querySelectorAll('iframe')].find(frame=>frame.getClientRects().length&&frame.contentDocument?.getElementById('reused-card'));return frame&&frame.contentWindow.getComputedStyle(frame.contentDocument.getElementById('reused-card')).width==='150px';},{timeout:70000});
 assert.equal(proof.sourceRequests.length,2);
 const setRequest=proof.inspectorRequests.at(-1);assert.equal(setRequest.property,'width');assert.equal(setRequest.value,'150px');assert.equal(setRequest.expectedValue,'');
 record('after Reset the compiled binding offers width again and a typed value is inserted into #reused-card');

 // Undo the set, then undo the Reset: exact bytes at each step.
 await page.evaluate(()=>window.__popupAcceptance.history(false));await settled(start+1);
 assert.equal(source(),removed,'Undo of the set removes exactly the inserted declaration');
 await page.evaluate(()=>window.__popupAcceptance.history(false));await settled(start);
 assert.equal(source(),original,'Undo of the Reset restores the exact original bytes');
 await page.waitForFunction(()=>{const frame=[...document.querySelectorAll('iframe')].find(frame=>frame.getClientRects().length&&frame.contentDocument?.getElementById('reused-card'));return frame&&frame.contentWindow.getComputedStyle(frame.contentDocument.getElementById('reused-card')).width==='110px';},{timeout:70000});
 assert.equal(proof.sourceRequests.length,4);assert.ok(proof.inspectorRequests.at(-1).restoreWrite,'the Reset is undone through its receipt');
 record('undo, undo return to the exact original source through the removal receipt');

 // A rule shared by a selector list (here under the fixture's explicit
 // #secondary-action entry): read-only with the reason, Reset disabled with
 // it, a commit is refused at the act, and nothing is requested.
 const listed=source().replace('#secondary-action { width:160px;','#secondary-action, .ghost { width:160px;');
 assert.notEqual(listed,source());writeFileSync(project+'/stories.nim',listed);
 copyFileSync(repo+'/tests/fixtures/editor_inspector_project/.isonim/source-project.json',manifestFile);catalogBuild();
 const requestsBefore=proof.sourceRequests.length;
 await open('secondary-action');
 const reason='Read-only: `#secondary-action` is styled here by the selector list `#secondary-action, .ghost`; changing `width` there would change every selector in the list. Edit the stylesheet directly.';
 await page.waitForFunction(()=>document.querySelector('[data-property-row-css-property="width"][data-property-row-kind="numeric"]')?.getAttribute('data-property-row-readonly')==='true',{},{timeout:10000}).catch(()=>{});
 assert.equal(await row.getAttribute('data-property-row-readonly'),'true','A selector-list declaration is read-only');
 assert.equal(await row.getAttribute('data-property-row-readonly-reason'),reason);
 await label.click({button:'right'});await menu.waitFor({state:'visible'});
 assert.equal(await reset.getAttribute('aria-disabled'),'true');
 assert.equal(await reset.getAttribute('title'),reason);
 await reset.dispatchEvent('click');
 const attempt=JSON.parse(await page.evaluate(()=>window.__popupAcceptance.attemptSelectedNativeProperty('width','170px')));
 assert.deepEqual(attempt,{completed:true,ok:false,diagnostic:reason.slice('Read-only: '.length)},'a commit is refused at the act with the reason');
 assert.equal(source(),listed);assert.equal(proof.sourceRequests.length,requestsBefore);assert.equal(proof.inspectorRequests.filter(r=>r.target==='secondary-action').length,0);
 assert.equal(await previewWidth('secondary-action'),'160px');
 record('a selector-list declaration is read-only, Reset is disabled and a commit is refused at the act, with the reason; nothing is requested');
 assert.deepEqual(proof.agentRequests,[]);assert.deepEqual(proof.errors,[]);
 writeFileSync(root+'/proof.json',JSON.stringify(proof,null,2));console.log('Native compiled Reset GUI passed:',root,proof.cases.length);
} finally {
 if(browser)await browser.close();if(browserServer)await browserServer.close();
 server.kill('SIGTERM');await new Promise(resolve=>{if(server.exitCode!==null)return resolve();server.once('exit',resolve);setTimeout(()=>{server.kill('SIGKILL');resolve();},15000).unref();});
 writeFileSync(root+'/proof-final.json',JSON.stringify(proof,null,2));
}
