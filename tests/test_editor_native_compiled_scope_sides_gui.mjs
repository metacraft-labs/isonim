/** Compiled (derived) native bindings in the mounted inspector: a rule is
 * offered only on elements of stories whose page loads its stylesheet, and a
 * shorthand re-offered after Reset presents its per-side rows, each set and
 * undone at exact bytes (isonim-pm issues 2026-10-17-compiled-bindings-match-
 * elements-in-stories-that-do-not-load-their-stylesheet and 2026-10-17-re-
 * offered-shorthand-after-reset-has-no-per-side-rows; editor spec "Saving":
 * an edit changes the one declaration that owns the selected element's
 * property; "Universal Patterns": a re-settable shorthand presents the same
 * rows as an authored one and each side can be set again after Reset).
 * Real mounted production inspector, the native authenticated source worker,
 * private files and the actual Nim compiler/SSR catalog; physical pointer and
 * keyboard input. No UI, source, compiler, HTTP or dispatcher is mocked. The
 * controlled decision peer only permits daemon startup; zero agent calls are
 * asserted.
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
const root=mkdtempSync(path.join(process.env.ISONIM_POPUP_ARTIFACTS||tmpdir(),'native-compiled-scope-sides-'));
const project=root+'/project',pub=root+'/public';
cpSync(repo+'/tests/fixtures/editor_inspector_project',project,{recursive:true});mkdirSync(pub);
const manifestFile=project+'/.isonim/source-project.json',sourceFile=project+'/stories.nim';
const optIn=properties=>{const manifest=JSON.parse(readFileSync(repo+'/tests/fixtures/editor_inspector_project/.isonim/source-project.json','utf8'));delete manifest.editableStyles;manifest.editableStyleSources=[{file:'stories.nim',const:'cardStyles',properties}];writeFileSync(manifestFile,JSON.stringify(manifest,null,2));};
for(const [from,to] of [['src/isonim/editor/index.html','index.html'],['build/editor-inspector/editor.js','editor.js'],['node_modules/fabric/dist/index.min.js','fabric.min.js'],['node_modules/paper/dist/paper-core.min.js','paper-core.min.js'],['node_modules/svgo/dist/svgo.browser.js','svgo.browser.js']])copyFileSync(repo+'/'+from,pub+'/'+to);
const catalogBuild=()=>{const build=spawnSync('python3',[repo+'/tools/build_source_catalog.py',project],{env:{...process.env,ISONIM_SOURCE_FRAMEWORK:repo},encoding:'utf8',timeout:70000});writeFileSync(root+'/catalog-build.log',build.stdout+build.stderr,{flag:'a'});assert.equal(build.status,0,build.stdout+build.stderr);};
// Part 1 project: cardStyles gains `.chip { opacity:0.5; }` and each story's
// first button carries the class; only the Card page loads cardStyles.
const fixture=readFileSync(sourceFile,'utf8');
const chipped=fixture.replace('const cardStyles* = """\n','const cardStyles* = """\n.chip { opacity:0.5; }\n').replace('button(id = target, `data-isonim-element-id` = target): text "Continue"','button(id = target, `data-isonim-element-id` = target, class = "chip"): text "Continue"');
assert.notEqual(chipped,fixture);writeFileSync(sourceFile,chipped);optIn(['opacity']);catalogBuild();
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
 const snapshot=()=>page.evaluate(()=>JSON.parse(window.__popupAcceptance.snapshot()));
 const settled=count=>page.waitForFunction(count=>{const s=JSON.parse(window.__popupAcceptance.snapshot());return s.stage==='wesClean'&&!s.sourceInFlight&&s.undoCount===count;},count,{timeout:70000});
 const source=()=>readFileSync(sourceFile,'utf8');
 const row=property=>page.locator('[data-property-row-css-property="'+property+'"][data-property-row-kind="numeric"]').first();
 const readonlyIs=(property,value)=>page.waitForFunction(([property,value])=>document.querySelector('[data-property-row-css-property="'+property+'"][data-property-row-kind="numeric"]')?.getAttribute('data-property-row-readonly')===value,[property,value],{timeout:10000}).catch(()=>{});

 // Part 1: the Card page loads cardStyles, so .chip offers opacity on its
 // button; the Alternate page does not, so its .chip button is not offered.
 await open('action');
 await readonlyIs('opacity','false');
 assert.equal(await row('opacity').getAttribute('data-property-row-readonly'),'false','the Card page loads cardStyles: .chip opacity is editable on its button');
 assert.equal(await row('opacity').locator('[data-property-row-input]').inputValue(),'50');
 record('the Card story\'s .chip button is offered cardStyles\' opacity');
 assert(await page.evaluate(()=>window.__popupAcceptance.openStory('Alternate','default ready')));
 await page.waitForFunction(()=>[...document.querySelectorAll('iframe')].some(frame=>frame.getClientRects().length&&frame.contentDocument?.querySelector('#alternate-action.chip')),{timeout:70000});
 await page.locator('[data-scene-graph-row="alternate-action"]').click();
 await page.waitForFunction(()=>JSON.parse(window.__popupAcceptance.snapshot()).selected==='alternate-action');
 await readonlyIs('opacity','true');
 assert.equal(await row('opacity').getAttribute('data-property-row-readonly'),'true','the Alternate page does not load cardStyles: its .chip button is not offered opacity');
 const before=source(),requestsBefore=proof.sourceRequests.length;
 const attempt=JSON.parse(await page.evaluate(()=>window.__popupAcceptance.attemptSelectedNativeProperty('opacity','0.7')));
 assert.equal(attempt.completed,true);assert.equal(attempt.ok,false,'a commit there is refused at the act');assert.ok(attempt.diagnostic.length>0,'with its reason');
 assert.equal(source(),before);assert.equal(proof.sourceRequests.length,requestsBefore);
 assert.equal(proof.inspectorRequests.filter(request=>request.target==='alternate-action').length,0);
 record('the Alternate story\'s .chip button, whose page does not load cardStyles, is read-only and a commit is refused with nothing requested or written');

 // Part 2: Reset of #secondary-action's border-radius shorthand. The
 // re-offered shorthand presents TL/TR/BR/BL as the authored one did; TL is
 // set (its own declaration inserted into the rule) and undone, then the
 // Reset is undone, each at exact bytes.
 writeFileSync(sourceFile,fixture);optIn(['border-radius','padding']);catalogBuild();
 await open('secondary-action');
 const original=source();
 const rule='#secondary-action { width:160px; height:52px; padding:12px; border-radius:6px; background-color:#334455; color:#FFFFFF; }';
 assert(original.includes(rule));
 const removed=original.replace(rule,'#secondary-action { width:160px; height:52px; padding:12px; background-color:#334455; color:#FFFFFF; }');
 const set=original.replace(rule,'#secondary-action { width:160px; height:52px; padding:12px; background-color:#334455; color:#FFFFFF; border-top-left-radius:3px; }');
 const corners=['border-top-left-radius','border-top-right-radius','border-bottom-right-radius','border-bottom-left-radius'];
 const appearance=page.locator('[data-inspector-section-header="appearance"]');if(await appearance.getAttribute('aria-expanded')==='false')await appearance.click();
 await page.getByRole('checkbox',{name:'Toggle Per-corner'}).click();
 for(const corner of corners){await readonlyIs(corner,'false');assert.equal(await row(corner).getAttribute('data-property-row-readonly'),'false','authored: '+corner+' is editable');}
 const start=(await snapshot()).undoCount;const requests=proof.sourceRequests.length;
 const radius=row('border-radius'),menu=radius.locator('[data-property-actions-menu="true"]'),reset=menu.getByRole('menuitem',{name:'Reset'});
 await radius.locator('[data-property-row-field-label="true"]').click({button:'right'});await menu.waitFor({state:'visible'});
 assert.equal(await reset.getAttribute('aria-disabled'),'false');
 await reset.click();await settled(start+1);
 assert.equal(source(),removed,'Reset removes exactly the border-radius declaration');
 assert.equal(proof.sourceRequests.length,requests+1);assert.equal(proof.inspectorRequests.at(-1).property,'border-radius');assert.equal(proof.inspectorRequests.at(-1).value,'');
 record('Reset removes the compiled binding\'s border-radius shorthand through the native writer');
 for(const corner of ['border-radius',...corners]){await readonlyIs(corner,'false');assert.equal(await row(corner).getAttribute('data-property-row-readonly'),'false','after Reset the re-offered '+corner+' row is editable');}
 record('after Reset the re-offered shorthand presents its TL/TR/BR/BL rows, each editable');
 const tl=row('border-top-left-radius').locator('[data-property-row-input]');
 await tl.click();await tl.fill('3');await tl.press('Enter');
 // Either the write completes or the row states why it was refused.
 await page.waitForFunction(count=>{const s=JSON.parse(window.__popupAcceptance.snapshot());const message=document.querySelector('[data-property-row-css-property="border-top-left-radius"] [data-property-row-message-visible="true"]')?.textContent||'';return message.length>0||(s.stage==='wesClean'&&!s.sourceInFlight&&s.undoCount===count);},start+2,{timeout:70000});
 assert.equal(await row('border-top-left-radius').locator('[data-property-row-message-visible="true"]').count()?await row('border-top-left-radius').locator('[data-property-row-message-visible="true"]').textContent():'','','the TL commit is not refused');
 await settled(start+2);
 assert.equal(source(),set,'Setting TL inserts exactly its own declaration into the rule');
 const setRequest=proof.inspectorRequests.at(-1);assert.equal(setRequest.property,'border-top-left-radius');assert.equal(setRequest.value,'3px');assert.equal(setRequest.expectedValue,'');
 await page.waitForFunction(()=>{const frame=[...document.querySelectorAll('iframe')].find(frame=>frame.getClientRects().length&&frame.contentDocument?.getElementById('secondary-action'));return frame&&frame.contentWindow.getComputedStyle(frame.contentDocument.getElementById('secondary-action')).borderTopLeftRadius==='3px';},{timeout:70000});
 record('a TL value typed after Reset is inserted into #secondary-action as its own declaration and previewed');
 await page.evaluate(()=>window.__popupAcceptance.history(false));await settled(start+1);
 assert.equal(source(),removed,'Undo of the TL set removes exactly the inserted declaration');
 await page.evaluate(()=>window.__popupAcceptance.history(false));await settled(start);
 assert.equal(source(),original,'Undo of the Reset restores the exact original bytes');
 assert.ok(proof.inspectorRequests.at(-1).restoreWrite,'the Reset is undone through its receipt');
 record('undo, undo return to the exact original source');
 assert.deepEqual(proof.agentRequests,[]);assert.deepEqual(proof.errors,[]);
 writeFileSync(root+'/proof.json',JSON.stringify(proof,null,2));console.log('Native compiled scope and sides GUI passed:',root,proof.cases.length);
} finally {
 if(browser)await browser.close();if(browserServer)await browserServer.close();
 server.kill('SIGTERM');await new Promise(resolve=>{if(server.exitCode!==null)return resolve();server.once('exit',resolve);setTimeout(()=>{server.kill('SIGKILL');resolve();},15000).unref();});
 writeFileSync(root+'/proof-final.json',JSON.stringify(proof,null,2));
}
