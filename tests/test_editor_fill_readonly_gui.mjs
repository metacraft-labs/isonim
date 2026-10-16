/** Default native-inspector composition (catalog-only preview mode is exercised
 * separately by popup acceptance). Real mounted production inspector, native authenticated source worker, private
 * files and actual Nim compiler/SSR catalog. No UI, source, compiler, HTTP or
 * dispatcher is mocked. The configured controlled decision peer only permits
 * daemon startup; this suite sends no model prompts and asserts zero agent calls.
 * Permission toggles use the production workspace permission signal. No source
 * result, renderer, clipboard, compiler or event outcome is simulated. Saved
 * detached DOM events exercise lifetime guards, not successful source outcomes.
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
const root=mkdtempSync(path.join(process.env.ISONIM_POPUP_ARTIFACTS||tmpdir(),'fill-readonly-'));
const project=root+'/project',pub=root+'/public';
cpSync(repo+'/tests/fixtures/editor_inspector_project',project,{recursive:true});mkdirSync(pub);
for(const [from,to] of [['src/isonim/editor/index.html','index.html'],['build/editor-inspector/editor.js','editor.js'],['node_modules/fabric/dist/index.min.js','fabric.min.js'],['node_modules/paper/dist/paper-core.min.js','paper-core.min.js'],['node_modules/svgo/dist/svgo.browser.js','svgo.browser.js']])copyFileSync(repo+'/'+from,pub+'/'+to);
const build=spawnSync('python3',[repo+'/tools/build_source_catalog.py',project],{env:{...process.env,ISONIM_SOURCE_FRAMEWORK:repo},encoding:'utf8',timeout:70000});
writeFileSync(root+'/catalog-build.log',build.stdout+build.stderr);assert.equal(build.status,0,build.stdout+build.stderr);
const proof={project,head:process.env.ISONIM_TEST_HEAD||spawnSync('git',['rev-parse','HEAD'],{cwd:repo,encoding:'utf8'}).stdout.trim(),sourceState:process.env.ISONIM_TEST_SOURCE_STATE||'M3 uncommitted working copy',nativeSha256:createHash('sha256').update(readFileSync(repo+'/build/bin/isonim-review')).digest('hex'),bundleSha256:createHash('sha256').update(readFileSync(pub+'/editor.js')).digest('hex'),cases:[],errors:[],agentRequests:[],sourceRequests:[]};
const record=name=>{proof.cases.push(name);writeFileSync(root+'/proof-partial.json',JSON.stringify(proof,null,2));};
const config=root+'/agent.toml';writeFileSync(config,'[agent]\nbackend="custom"\ncommand="python3"\nargs='+JSON.stringify([repo+'/tests/helpers/editor_control_peer.py'])+'\nprimer_enabled=false\n');
const server=spawn('python3',[repo+'/tools/editor_server.py','--directory',pub,'--project-root',project,'--port','0','--bind','127.0.0.1','--config',config,'--daemon-binary',repo+'/build/bin/isonim-review'],{env:{...process.env,ISONIM_SOURCE_FRAMEWORK:repo},stdio:['ignore','pipe',openSync(root+'/server.log','w')]});
let browser,browserServer;
try {
 const origin=await new Promise((resolve,reject)=>{let text='';server.stdout.on('data',data=>{text+=data;const match=text.match(/Editor listening on (http:\/\/[^\s]+)\//);if(match)resolve(match[1]);});server.once('exit',code=>reject(Error('Server exited '+code)));setTimeout(()=>reject(Error('Server startup timeout')),70000).unref();});
 const chromeEnv={...process.env};delete chromeEnv.LD_LIBRARY_PATH;
 browserServer=await chromium.launchServer({headless:true,env:chromeEnv,executablePath:process.env.PLAYWRIGHT_CHROMIUM_EXECUTABLE});browser=await chromium.connect(browserServer.wsEndpoint());
 const context=await browser.newContext({viewport:{width:1440,height:900},permissions:['clipboard-read','clipboard-write']});const page=await context.newPage();page.setDefaultTimeout(30000);
 page.on('pageerror',error=>proof.errors.push(error.message));
 page.on('request',request=>{const url=new URL(request.url());if(url.pathname.startsWith('/api/agent/'))proof.agentRequests.push(url.pathname);if(url.pathname==='/api/editor/source/operation')proof.sourceRequests.push(request.postDataJSON());});
 await page.goto(origin);await page.waitForFunction(()=>!!window.__popupAcceptance);
 await page.locator('[data-toolbar-cluster="mode"] [aria-label="Edit"]').click();
 await page.locator('[data-scene-graph-row="action"]').click();

 const snapshot=()=>page.evaluate(()=>JSON.parse(window.__popupAcceptance.snapshot()));
 const source=()=>readFileSync(project+'/stories.nim','utf8');
 const catalog=()=>readFileSync(project+'/.isonim/catalog.json','utf8');
 const preview=()=>page.evaluate(()=>{const frame=[...document.querySelectorAll('iframe')].find(frame=>frame.getClientRects().length&&frame.contentDocument?.querySelector('#action'));assertFrame:if(!frame)throw Error('Visible actual preview required');return {background:frame.contentWindow.getComputedStyle(frame.contentDocument.querySelector('#action')).backgroundColor,styles:[...frame.contentDocument.querySelectorAll('style')].map(style=>style.textContent)};});
 const fill=page.locator('[data-fill-row="0"]');
 const swatch=fill.locator('[data-fill-row-swatch="0"]');
 await swatch.waitFor({state:'visible'});assert.equal(await swatch.count(),1);
 // Public Delete must refuse unsupported removal even with genuine source
 // permission. These are physical browser inputs, not synthetic source results.
 const deleteButton=fill.locator('[data-fill-row-delete="0"]');
 await page.waitForFunction(()=>document.querySelector('[data-fill-row="0"]')?.getAttribute('data-fill-row-readonly')==='false');
 await deleteButton.hover();await page.waitForFunction(()=>JSON.parse(window.__popupAcceptance.snapshot()).hover==='');
 const deleteBefore={source:source(),catalog:catalog(),state:await snapshot(),preview:await preview(),hex:await fill.locator('[data-fill-row-hex]').inputValue()};
 const fillMessage=page.locator('[data-fill-message="true"]');
 assert.equal(await deleteButton.getAttribute('aria-disabled'),'true');
 const deleteNode=await deleteButton.elementHandle();
 for(const activation of ['click','Enter','Space']){
  await deleteButton.scrollIntoViewIfNeeded();assert(await deleteButton.evaluate(el=>{const r=el.getBoundingClientRect();return el.contains(document.elementFromPoint(r.x+r.width/2,r.y+r.height/2));}));
  if(activation==='click'){const box=await deleteButton.boundingBox();assert(box);await page.mouse.click(box.x+box.width/2,box.y+box.height/2);}else{await deleteButton.focus();await deleteButton.press(activation);}
  assert.equal(await fill.count(),1);assert(await deleteNode.evaluate(el=>el.isConnected));
  await fillMessage.waitFor({state:'visible'});assert.equal(await fillMessage.textContent(),'The native source writer cannot remove a declaration.');
  assert.equal(await fill.locator('[data-fill-row-hex]').inputValue(),deleteBefore.hex);
  assert.equal(source(),deleteBefore.source);assert.equal(catalog(),deleteBefore.catalog);assert.deepEqual(await snapshot(),deleteBefore.state);assert.deepEqual(await preview(),deleteBefore.preview);
  assert.equal(proof.sourceRequests.length,0);assert.deepEqual(proof.agentRequests,[]);
 }
 for(const key of ['Tab','Escape']){await deleteButton.focus();await deleteButton.press(key);assert.equal(await fill.count(),1);assert.deepEqual(await snapshot(),deleteBefore.state);assert.equal(await fillMessage.textContent(),'The native source writer cannot remove a declaration.');}
 record('editable public Delete click/Enter/Space explains unsupported removal with exact row/source/catalog/preview/history and zero requests; Tab/Escape are inert');
 await page.evaluate(()=>window.__popupAcceptance.readOnly(true));
 await page.waitForFunction(()=>document.querySelector('[data-fill-row="0"]')?.getAttribute('data-fill-row-readonly')==='true');
 await swatch.hover();await page.waitForFunction(()=>JSON.parse(window.__popupAcceptance.snapshot()).hover==='');
 const before={source:source(),catalog:catalog(),state:await snapshot(),preview:await preview()};
 const popup=page.locator('[data-color-popover-open="true"]'),draft=popup.locator('[data-color-popover-input]');
 async function unchanged(){assert.equal(source(),before.source);assert.equal(catalog(),before.catalog);assert.deepEqual(await snapshot(),before.state);assert.deepEqual(await preview(),before.preview);assert.equal(proof.sourceRequests.length,0);assert.deepEqual(proof.agentRequests,[]);}
 async function inspect(activation){
  await swatch.scrollIntoViewIfNeeded();const box=await swatch.boundingBox();assert(box);assert(await swatch.evaluate(el=>{const r=el.getBoundingClientRect();return el.contains(document.elementFromPoint(r.x+r.width/2,r.y+r.height/2));}));
  if(activation==='click')await swatch.click();else{await swatch.focus();await swatch.press(activation);}
  assert.equal(await popup.count(),1);await draft.waitFor({state:'visible'});
  await draft.fill('#445566');await draft.focus();await draft.press('Control+a');await draft.press('Control+c');
  assert.equal(await page.evaluate(()=>navigator.clipboard.readText()),'#445566','Actual clipboard copies inspectable draft');
  await popup.locator('[data-color-popover-apply]').click();
  assert.equal(await draft.inputValue(),'#445566');assert.equal(await popup.count(),1);assert((await popup.locator('[data-color-popover-error]').textContent()).length>0);
  assert.equal(source(),before.source);assert.equal(catalog(),before.catalog);assert.equal(proof.sourceRequests.length,0);
  await draft.press('Escape');assert.equal(await popup.count(),0);assert(await swatch.evaluate(el=>document.activeElement===el));
  await unchanged();record('readonly Fill '+activation+' inspects/copies draft, refuses Apply and Escape restores invoker without source/preview/history change');
 }
 await inspect('click');await inspect('Enter');await inspect('Space');
 const hex=fill.locator('[data-fill-row-hex]'),alpha=fill.locator('[data-fill-row-alpha]');
 assert(await hex.evaluate(el=>el.readOnly));assert(await alpha.evaluate(el=>el.readOnly));
 for(const field of [hex,alpha]){const value=await field.inputValue();await field.focus();await field.press('Control+a');await field.pressSequentially('50');await field.press('Tab');assert.equal(await field.inputValue(),value);}
 await deleteButton.scrollIntoViewIfNeeded();const readonlyDeleteBox=await deleteButton.boundingBox();assert(readonlyDeleteBox);assert(await deleteButton.evaluate(el=>{const r=el.getBoundingClientRect();return el.contains(document.elementFromPoint(r.x+r.width/2,r.y+r.height/2));}));await page.mouse.click(readonlyDeleteBox.x+readonlyDeleteBox.width/2,readonlyDeleteBox.y+readonlyDeleteBox.height/2);assert.equal(await fill.count(),1);await unchanged();for(const key of ['Enter','Space']){await deleteButton.focus();await deleteButton.press(key);assert.equal(await fill.count(),1);assert((await fillMessage.textContent()).length>0);await unchanged();}record('readonly literal/opacity keyboard entry and Delete click/Enter/Space preserve values with zero writer requests');
 // The open draft responds to permission changes, not a captured readonly flag.
 await page.evaluate(()=>window.__popupAcceptance.readOnly(false));await swatch.click();await draft.fill('#778899');
 await page.evaluate(()=>window.__popupAcceptance.readOnly(true));await popup.locator('[data-color-popover-apply]').click();
 assert.equal(await draft.inputValue(),'#778899');assert((await popup.locator('[data-color-popover-error]').textContent()).length>0);assert.equal(proof.sourceRequests.length,0);
 await draft.press('Escape');await unchanged();record('permission revoked while open refuses the current draft without closing or writing');
 // Restoring permission applies the same real draft through source/compiler,
 // and real undo restores the authored source and visible preview.
 await page.evaluate(()=>window.__popupAcceptance.readOnly(false));await swatch.click();await draft.fill('#445566');await popup.locator('[data-color-popover-apply]').click();
 await page.waitForFunction(()=>JSON.parse(window.__popupAcceptance.snapshot()).stage==='wesClean'&&JSON.parse(window.__popupAcceptance.snapshot()).undoCount===1,{},{timeout:70000});
 assert.equal(source(),before.source.replace('background-color:#112233;','background-color:#445566;'));assert.equal(proof.sourceRequests.length,1);
 await page.waitForFunction(()=>{const frame=[...document.querySelectorAll('iframe')].find(frame=>frame.getClientRects().length&&frame.contentDocument?.querySelector('#action'));return frame&&frame.contentWindow.getComputedStyle(frame.contentDocument.querySelector('#action')).backgroundColor==='rgb(68, 85, 102)';});
 await page.evaluate(()=>window.__popupAcceptance.history(false));await page.waitForFunction(()=>JSON.parse(window.__popupAcceptance.snapshot()).stage==='wesClean'&&JSON.parse(window.__popupAcceptance.snapshot()).undoCount===0,{},{timeout:70000});
 assert.equal(source(),before.source);assert.equal(proof.sourceRequests.length,2);
 await page.waitForFunction(()=>{const frame=[...document.querySelectorAll('iframe')].find(frame=>frame.getClientRects().length&&frame.contentDocument?.querySelector('#action'));return frame&&frame.contentWindow.getComputedStyle(frame.contentDocument.querySelector('#action')).backgroundColor==='rgb(17, 34, 51)';});
 assert.deepEqual(JSON.parse(catalog()),JSON.parse(before.catalog),'Undo restores the compiled document; native producer uses its own final-newline serialization');const restoredCatalog=catalog();
 await page.evaluate(()=>window.__popupAcceptance.readOnly(true));record('restored permission applies one real native Fill transaction/compiler/preview; native undo restores exact source');
 // A detached old row cannot delete or write in the new same-ID story.
 await page.evaluate(()=>{window.__oldFill={swatch:document.querySelector('[data-fill-row-swatch="0"]'),hex:document.querySelector('[data-fill-row-hex="0"]'),alpha:document.querySelector('[data-fill-row-alpha="0"]'),del:document.querySelector('[data-fill-row-delete="0"]')};});
 await page.locator('[data-scene-graph-row="reused"]').click();
 const oldState=await snapshot();const oldMessage=await fillMessage.textContent();
 await page.evaluate(()=>{const row=window.__oldFill;if(row.swatch.isConnected)throw Error('Old row must be disposed');row.swatch.click();row.hex.value='#FFFFFF';row.hex.dispatchEvent(new Event('change'));row.alpha.value='40';row.alpha.dispatchEvent(new Event('change'));row.del.click();row.del.dispatchEvent(new KeyboardEvent('keydown',{key:'Enter',bubbles:true}));row.del.dispatchEvent(new KeyboardEvent('keydown',{key:' ',bubbles:true}));});
 assert.deepEqual(await snapshot(),oldState);assert.equal(await fillMessage.textContent(),oldMessage);assert.equal(proof.sourceRequests.length,2);assert.equal(source(),before.source);assert.equal(catalog(),restoredCatalog);record('detached Fill literal/alpha/delete callbacks cannot mutate another selection');
 // Repeated real view lifetime disposal cannot accumulate inspector subscribers.
 await page.evaluate(()=>window.__popupAcceptance.unmount());const disposed=await snapshot();
 for(let i=0;i<2;i++){assert(await page.evaluate(()=>window.__popupAcceptance.remount()));await page.waitForFunction(()=>!!document.querySelector('[data-toolbar-cluster="mode"]'));assert(await page.evaluate(()=>window.__popupAcceptance.unmount()));assert.deepEqual(await snapshot(),disposed);}
 assert.equal(proof.sourceRequests.length,2);assert.deepEqual(proof.errors,[]);assert.deepEqual(proof.agentRequests,[]);record('repeated real mount/unmount retains only the same model subscriptions and no stale source activity');
 writeFileSync(root+'/proof.json',JSON.stringify(proof,null,2));console.log('Readonly Fill GUI passed:',root,proof.cases.length);
} finally {
 if(browser)await browser.close();if(browserServer)await browserServer.close();
 server.kill('SIGTERM');await new Promise(resolve=>{if(server.exitCode!==null)return resolve();server.once('exit',resolve);setTimeout(()=>{server.kill('SIGKILL');resolve();},15000).unref();});
 writeFileSync(root+'/proof-final.json',JSON.stringify(proof,null,2));
}
