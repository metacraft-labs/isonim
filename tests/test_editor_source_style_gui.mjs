/** Real opt-in GRIP workspace/catalog, production editor/source bridge and native
 * compiler transactions in a disposable source copy. Nothing in the renderer,
 * source provider, adapter, compiler or source HTTP transport is mocked. The
 * controlled startup peer is used only to start the daemon; no agent prompt runs.
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
const root=mkdtempSync(path.join(process.env.ISONIM_POPUP_ARTIFACTS||tmpdir(),'source-style-gui-'));
// The declared real literal-provider archive is hash checked; current source is protected.
const acquired=spawnSync('python3',[repo+'/tests/helpers/native_literal_fixture.py','prepare',root],{encoding:'utf8'});
assert.equal(acquired.status,0,acquired.stdout+acquired.stderr);
const {prototype,project}=JSON.parse(acquired.stdout),pub=root+'/public';
const original=readFileSync(prototype+'/src/components/styles.nim','utf8');
mkdirSync(pub);
writeFileSync(project+'/config.nims','switch("nimcache", '+JSON.stringify(project+'/native-cache')+')\n');
const manifest=JSON.parse(readFileSync(project+'/.isonim/source-project.json','utf8'));
manifest.editableStyleSources=[{file:'src/components/styles.nim',const:'structureCss',properties:['border-radius','font-size','font-weight','gap','height','color','background']}];
writeFileSync(project+'/.isonim/source-project.json',JSON.stringify(manifest));
const env={...process.env,ISONIM_SOURCE_FRAMEWORK:repo};
function checkedBuild(command,args,label,timeout=90000){const result=spawnSync(command,args,{cwd:repo,env,encoding:'utf8',timeout});writeFileSync(root+'/'+label+'.log',result.stdout+result.stderr);assert.equal(result.status,0,result.stdout+result.stderr);return result.stdout;}
checkedBuild('python3',[repo+'/tools/build_source_catalog.py',project],'catalog-build');
const described=JSON.parse(checkedBuild(repo+'/build/bin/isonim-review',['source-project',project,'--describe'],'describe',5000));
const target=described.editableStyles.find(row=>row.selector==='.panel'&&row.values['border-radius']==='4px');assert(target);assert(target.sharedCount>=2);
checkedBuild('nim',['js','--path:src','--path:.','--path:../nim-everywhere/src','--path:../isonim-render-serve/src','--path:../nim-acp/src','--path:../nim-agent-harbor/src','--path:../nim-agents/src','--path:'+project+'/src','--path:'+project+'/src/editor','-o:'+pub+'/editor.js','tests/helpers/editor_source_style_workspace.nim'],'browser-build');
for(const [from,to] of [['src/isonim/editor/index.html','index.html'],['node_modules/fabric/dist/index.min.js','fabric.min.js'],['node_modules/paper/dist/paper-core.min.js','paper-core.min.js'],['node_modules/svgo/dist/svgo.browser.js','svgo.browser.js']])copyFileSync(repo+'/'+from,pub+'/'+to);
const proof={project,head:process.env.ISONIM_TEST_HEAD||spawnSync('git',['rev-parse','HEAD'],{cwd:repo,encoding:'utf8'}).stdout.trim(),sourceState:process.env.ISONIM_TEST_SOURCE_STATE||'C4a authored working copy',nativeSha256:createHash('sha256').update(readFileSync(repo+'/build/bin/isonim-review')).digest('hex'),target,bundleSha256:createHash('sha256').update(readFileSync(pub+'/editor.js')).digest('hex'),cases:[],errors:[],sourceRequests:[],inspectorRequests:[],agentRequests:[]};
const record=name=>{proof.cases.push(name);writeFileSync(root+'/proof-partial.json',JSON.stringify(proof,null,2));};
const config=root+'/agent.toml';writeFileSync(config,'[agent]\nbackend="custom"\ncommand="python3"\nargs='+JSON.stringify([repo+'/tests/helpers/editor_control_peer.py'])+'\nprimer_enabled=false\n');
const server=spawn('python3',[repo+'/tools/editor_server.py','--directory',pub,'--project-root',project,'--port','0','--bind','127.0.0.1','--config',config,'--daemon-binary',repo+'/build/bin/isonim-review'],{env,stdio:['ignore','pipe',openSync(root+'/server.log','w')]});
let browser,browserServer;
try{
 const origin=await new Promise((resolve,reject)=>{let text='';server.stdout.on('data',data=>{text+=data;const match=text.match(/Editor listening on (http:\/\/[^\s]+)\//);if(match)resolve(match[1]);});server.once('exit',code=>reject(Error('Server exited '+code)));setTimeout(()=>reject(Error('Startup timeout')),70000).unref();});
 const chromeEnv={...process.env};delete chromeEnv.LD_LIBRARY_PATH;
 browserServer=await chromium.launchServer({headless:true,env:chromeEnv,executablePath:process.env.PLAYWRIGHT_CHROMIUM_EXECUTABLE});browser=await chromium.connect(browserServer.wsEndpoint());
 const page=await browser.newPage({viewport:{width:1440,height:900}});page.setDefaultTimeout(30000);
 page.on('pageerror',error=>proof.errors.push(error.message));page.on('request',request=>{const url=new URL(request.url());if(url.pathname.startsWith('/api/agent/'))proof.agentRequests.push(url.pathname);if(url.pathname==='/api/editor/source/operation')proof.sourceRequests.push(request.postDataJSON());if(url.pathname==='/api/editor/rpc'){const body=request.postDataJSON();if(body?.method==='editor.inspector-source')proof.inspectorRequests.push(body);}});
 const snapshot=()=>page.evaluate(()=>JSON.parse(window.__sourceStyleAcceptance.snapshot()));
 async function openTarget(){const divider=target.storyId.indexOf(' / ');assert(await page.evaluate(([group,name])=>window.__sourceStyleAcceptance.openStory(group,name),[target.storyId.slice(0,divider),target.storyId.slice(divider+3)]));await page.locator('[data-toolbar-cluster="mode"] [aria-label="Switch to edit mode"]').click();await page.locator('[data-layer-search="true"]').fill('panel');await page.locator('[data-scene-graph-row="'+target.elementId+'"]').click();}
 await page.goto(origin);await page.waitForFunction(()=>window.__sourceStyleAcceptance&&JSON.parse(window.__sourceStyleAcceptance.snapshot()).ready);await openTarget();
 const row=page.locator('[data-property-row-css-property="border-radius"][data-property-row-kind="numeric"][data-property-row="corner-radius"]');await row.waitFor();assert.equal(await row.count(),1);
 const input=row.locator('[data-property-row-input]');
 await page.waitForFunction(()=>JSON.parse(window.__sourceStyleAcceptance.snapshot()).properties.some(property=>property.name==='border-radius'&&property.authoredValue==='4px'));
 assert.equal(await input.inputValue(),'4');
 const property=(await snapshot()).properties.find(property=>property.name==='border-radius');assert(property.shared);assert.equal(property.count,target.sharedCount);assert.equal(property.authoredValue,'4px');
 await row.locator('summary[aria-label="More Choose source scope for Corner radius"]').click();
 const localScope=row.locator('[aria-label="Apply local instance scope for border-radius"]');await localScope.waitFor();
 assert.equal(await localScope.getAttribute('data-source-scope-editable'),'false');
 assert.equal(await localScope.getAttribute('data-compact-choice-enabled'),'false');
 const localBox=await localScope.boundingBox();assert(localBox);await page.mouse.click(localBox.x+localBox.width/2,localBox.y+localBox.height/2);assert.equal(proof.sourceRequests.length,0);
 const inspectInput=()=>input.evaluate(input=>{const ancestry=[];for(let node=input;node;node=node.parentElement){const style=getComputedStyle(node);ancestry.push({tag:node.tagName,property:node.getAttribute('data-property-row'),display:style.display,visibility:style.visibility,rect:node.getBoundingClientRect().toJSON()});}return ancestry;});
 const beforeEscape=await snapshot();const beforeInput=await inspectInput();await page.keyboard.press('Escape');const afterEscape=await snapshot();writeFileSync(root+'/escape-state.json',JSON.stringify({beforeEscape,afterEscape,beforeInput,afterInput:await inspectInput()},null,2));assert.equal(afterEscape.selected,target.elementId);assert.equal(afterEscape.view,beforeEscape.view);assert.equal(afterEscape.mode,beforeEscape.mode);assert.equal(afterEscape.section,beforeEscape.section);assert(await input.isVisible(),'Closing source scope preserves the visible inspector value control');
 record('mounted compiled selector target exposes exact authored radius and truthful shared scope/count');
 const waitApplied=count=>page.waitForFunction(count=>{const state=JSON.parse(window.__sourceStyleAcceptance.snapshot());return state.stage==='wesClean'&&state.undoCount===count;},count,{timeout:70000});
 const source=()=>readFileSync(project+'/src/components/styles.nim','utf8');
 const radius=()=>page.evaluate(id=>{const frame=[...document.querySelectorAll('iframe')].find(frame=>frame.getClientRects().length&&frame.contentDocument?.querySelector('[data-isonim-element-id="'+id+'"]'));return frame&&frame.contentWindow.getComputedStyle(frame.contentDocument.querySelector('[data-isonim-element-id="'+id+'"]')).borderRadius;},target.elementId);
 const waitRadius=value=>page.waitForFunction(([id,value])=>{const frame=[...document.querySelectorAll('iframe')].find(frame=>frame.getClientRects().length&&frame.contentDocument?.querySelector('[data-isonim-element-id="'+id+'"]'));return frame&&frame.contentWindow.getComputedStyle(frame.contentDocument.querySelector('[data-isonim-element-id="'+id+'"]')).borderRadius===value;},[target.elementId,value]);
 await input.fill('5px');await input.press('Enter');await input.press('Tab');await waitApplied(1);assert.equal(source(),original.replace('.panel { border:1px solid var(--rule); border-radius:4px;','.panel { border:1px solid var(--rule); border-radius:5px;'));assert.equal(proof.sourceRequests.length,1);await waitRadius('5px');assert.equal(await radius(),'5px');record('typed shared radius writes only its actual CSS rule through compiler and visible preview');
 await page.reload();await page.waitForFunction(()=>window.__sourceStyleAcceptance&&JSON.parse(window.__sourceStyleAcceptance.snapshot()).ready);await openTarget();assert.equal(await input.inputValue(),'5');await waitRadius('5px');assert.equal(await radius(),'5px');record('real GRIP workspace reload preserves target identity and compiled authored value');
 const handle=row.locator('[data-property-row-field-label]');
 await handle.waitFor({state:'visible'});await handle.scrollIntoViewIfNeeded();
 proof.scrubGeometry=await handle.evaluate(node=>{const box=node.getBoundingClientRect(),hit=document.elementFromPoint(box.x+box.width/2,box.y+box.height/2);return {box:box.toJSON(),hitMatches:!!hit&&(hit===node||node.contains(hit)),connected:node.isConnected};});
 assert(proof.scrubGeometry.connected);assert(proof.scrubGeometry.hitMatches,'The physical pointer must reach the actual radius handle');
 await handle.evaluate(node=>window.__sourceStyleScrubHandle=node);
 const box=await handle.boundingBox();assert(box);const beforeAdmission=proof.inspectorRequests.length;
 await page.mouse.move(box.x+box.width/2,box.y+box.height/2);await page.mouse.down();await page.mouse.move(box.x+box.width/2+2,box.y+box.height/2);
 assert(await page.evaluate(()=>window.__sourceStyleScrubHandle.isConnected),'Captured radius handle must survive its own draft');
 await page.mouse.up();
 const scrubState=await snapshot();assert(scrubState.stage!=='wesClean'||proof.inspectorRequests.length>beforeAdmission,'A genuine scrub must prepare/admit a source operation: '+JSON.stringify(scrubState));
 await waitApplied(1);assert.equal(source(),original.replace('.panel { border:1px solid var(--rule); border-radius:4px;','.panel { border:1px solid var(--rule); border-radius:9px;'));await waitRadius('9px');assert.equal(await radius(),'9px');assert.equal(proof.sourceRequests.length,2);record('shared rule scrub uses the same native writer and one committed history entry');
 await page.evaluate(()=>window.__sourceStyleAcceptance.history(false));await waitApplied(0);await waitRadius('5px');assert.equal(await radius(),'5px');assert(source().includes('.panel { border:1px solid var(--rule); border-radius:5px;'));record('shared native undo restores rule and compiled preview before history moves');
 assert.equal(readFileSync(prototype+'/src/components/styles.nim','utf8'),original);assert.deepEqual(proof.errors,[]);assert.deepEqual(proof.agentRequests,[]);writeFileSync(root+'/proof.json',JSON.stringify(proof,null,2));console.log('Source style GUI passed:',root,proof.cases.length);
}catch(error){
 if(browser){const pages=browser.contexts().flatMap(context=>context.pages());if(pages[0])writeFileSync(root+'/failure-state.json',JSON.stringify(await pages[0].evaluate(()=>({state:window.__sourceStyleAcceptance&&JSON.parse(window.__sourceStyleAcceptance.snapshot()), frames:[...document.querySelectorAll('iframe')].map(frame=>({title:frame.title,visible:!!frame.getClientRects().length,html:frame.getAttribute('srcdoc')?.match(/\.panel \{[^}]*\}/)?.[0],panels:[...(frame.contentDocument?.querySelectorAll('.panel')||[])].slice(0,2).map(node=>({id:node.getAttribute('data-isonim-element-id'),style:node.getAttribute('style'),radius:frame.contentWindow.getComputedStyle(node).borderRadius}))})),rows:[...document.querySelectorAll('[data-property-row-css-property="border-radius"]')].map(row=>({value:row.querySelector('input')?.value,unit:row.querySelector('[data-property-row-unit]')?.textContent}))})),null,2));}
 throw error;
}finally{
 if(browser)await browser.close();if(browserServer)await browserServer.close();server.kill('SIGTERM');await new Promise(resolve=>{if(server.exitCode!==null)return resolve();server.once('exit',resolve);setTimeout(()=>{server.kill('SIGKILL');resolve();},15000).unref();});writeFileSync(root+'/proof-final.json',JSON.stringify(proof,null,2));
 const protectedCheck=spawnSync('python3',[repo+'/tests/helpers/native_literal_fixture.py','verify',root],{encoding:'utf8'});
 assert.equal(protectedCheck.status,0,protectedCheck.stdout+protectedCheck.stderr);

}
