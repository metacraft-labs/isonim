/** Default native-inspector composition (catalog-only preview mode is exercised
 * separately by popup acceptance). Real mounted production inspector, native authenticated source worker, private
 * files and actual Nim compiler/SSR catalog. No UI, source, compiler, HTTP or
 * dispatcher is mocked. The configured controlled decision peer only permits
 * daemon startup; this suite sends no model prompts and asserts zero agent calls.
 * This remaining ordinary/actual-schema matrix checks genuine DSL provenance,
 * exact declared text/choices/numerics, authoring
 * units, actual source/compiler publication, browser CSS, history and reload.
 * Nonfinite and read-only negatives share the mounted writer; genuine compiler
 * failure/stale-selection controls remain in the original compounds suite.
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
const root=mkdtempSync(path.join(process.env.ISONIM_POPUP_ARTIFACTS||tmpdir(),'inspector-remaining-'));
const project=root+'/project',pub=root+'/public';
cpSync(repo+'/tests/fixtures/editor_inspector_project',project,{recursive:true});mkdirSync(pub);
// Admit only exact literal owners in a private actual project. The manifest is
// this fixture's ownership boundary, not the product-wide property inventory.
const declarations='font-size:16px; position:relative; left:10px; top:12px; display:flex; gap:6px; mix-blend-mode:normal;';
const setupSource=readFileSync(project+'/stories.nim','utf8');
writeFileSync(project+'/stories.nim',setupSource.replace('#action { width:120px;', 'html, body, main { font-size:16px; font-family:monospace; }\n#schema-panel { width:24px; text-align:left; }\n#state-panel { width:24px; }\n#action { '+declarations+' width:120px;').replace('            button(id = "secondary-action",', '            p(id = "schema-panel", `data-isonim-element-id` = "schema-panel", `data-isonim-schema-key` = "component.card"): text "Actual schema node"\n            p(id = "state-panel", `data-isonim-element-id` = "state-panel", style = "width:44px"): text "Actual inline state node"\n            button(id = "secondary-action",'));
const setupManifest=JSON.parse(readFileSync(project+'/.isonim/source-project.json','utf8'));
setupManifest.editableStyles.find(row=>row.elementId==='action').properties.push('left','top','display','gap','mix-blend-mode');
for(const id of ['schema-panel','state-panel'])setupManifest.editableStyles.push({key:'style.'+id,elementId:id,storyId:'Card / default ready',file:'stories.nim',const:'cardStyles',selector:'#'+id,properties:id==='schema-panel'?['width','text-align']:['width']});
writeFileSync(project+'/.isonim/source-project.json',JSON.stringify(setupManifest));
// Compile genuine DSL editor provenance; never inject manufactured browser metadata.
const producer=readFileSync(project+'/build_catalog.py','utf8');assert(producer.includes('"nim", "c",'));
writeFileSync(project+'/build_catalog.py',producer.replace('"nim", "c",','"nim", "c", "-d:isonimEditor",').replace('"--path:" + str(framework / "src"),','"--path:" + str(framework / "src"), "--path:" + str(framework.parent / "nim-everywhere" / "src"),'));

for(const [from,to] of [['src/isonim/editor/index.html','index.html'],['build/editor-inspector/editor.js','editor.js'],['node_modules/fabric/dist/index.min.js','fabric.min.js'],['node_modules/paper/dist/paper-core.min.js','paper-core.min.js'],['node_modules/svgo/dist/svgo.browser.js','svgo.browser.js']])copyFileSync(repo+'/'+from,pub+'/'+to);
const build=spawnSync('python3',[repo+'/tools/build_source_catalog.py',project],{env:{...process.env,ISONIM_SOURCE_FRAMEWORK:repo},encoding:'utf8',timeout:70000});
writeFileSync(root+'/catalog-build.log',build.stdout+build.stderr);assert.equal(build.status,0,build.stdout+build.stderr);
const proof={project,head:process.env.ISONIM_TEST_HEAD||spawnSync('git',['rev-parse','HEAD'],{cwd:repo,encoding:'utf8'}).stdout.trim(),sourceState:process.env.ISONIM_TEST_SOURCE_STATE||'C4a authored working copy',nativeSha256:createHash('sha256').update(readFileSync(repo+'/build/bin/isonim-review')).digest('hex'),bundleSha256:createHash('sha256').update(readFileSync(pub+'/editor.js')).digest('hex'),cases:[],errors:[],agentRequests:[],sourceRequests:[],httpTimings:[],previewTimings:[]};
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
 await page.locator('[data-toolbar-cluster="mode"] [aria-label="Edit"]').click();
 const snapshot=()=>page.evaluate(()=>JSON.parse(window.__popupAcceptance.snapshot()));
 const source=()=>readFileSync(project+'/stories.nim','utf8'),catalog=()=>readFileSync(project+'/.isonim/catalog.json','utf8');
 let selected='action',expectedSource=source(),count=0;
 const body=section=>page.locator('[data-inspector-section-body="'+section+'"]');
 const row=(property,section)=>body(section).locator('[data-property-row-css-property="'+property+'"]');
 async function select(id){selected=id;await page.locator('[data-scene-graph-row="'+id+'"]').click();await page.waitForFunction(id=>JSON.parse(window.__popupAcceptance.snapshot()).selected===id,id);}
 async function open(section){const h=page.locator('[data-inspector-section-header="'+section+'"]');if(await h.getAttribute('aria-expanded')==='false')await h.click();}
 async function published(n){await page.waitForFunction(n=>{const v=JSON.parse(window.__popupAcceptance.snapshot());return v.stage==='wesFailed'||v.stage==='wesClean'&&v.undoCount===n;},n,{timeout:70000});const v=await snapshot();proof.lastState=v;assert.equal(v.stage,'wesClean');assert.equal(v.selected,selected);const story=JSON.parse(catalog()).stories.find(story=>story.group+' / '+story.name===v.story);const css=[...story.documentHtml.matchAll(/<style[^>]*>([\s\S]*?)<\/style>/g)].map(m=>m[1]);assert(css.length);await page.waitForFunction(([css,id])=>[...document.querySelectorAll('iframe')].some(f=>f.getClientRects().length&&f.contentDocument?.querySelector('#'+id)&&css.every(value=>[...f.contentDocument.querySelectorAll('style')].some(s=>s.textContent===value))),[css,selected]);}
 const reference={left:'10px',top:'12px',height:'48px',gap:'6px','mix-blend-mode':'normal','padding-bottom':'3px','padding-left':'4px','border-bottom-right-radius':'3px','border-bottom-left-radius':'4px','padding-top':'16px','padding-right':'2px','border-top-left-radius':'16px','border-top-right-radius':'2px'};
 async function computed(values=reference){for(const [property,value] of Object.entries(values)){await page.waitForFunction(([id,property,value])=>{const f=[...document.querySelectorAll('iframe')].find(f=>f.getClientRects().length&&f.contentDocument?.querySelector('#'+id));return f&&f.contentWindow.getComputedStyle(f.contentDocument.querySelector('#'+id)).getPropertyValue(property)===value;},[selected,property,value]);}}
 const typed=value=>async target=>{const i=target.locator('[data-property-row-input]');await i.click();await i.press('ControlOrMeta+A');await page.keyboard.type(value);await i.press('Enter');await i.press('Tab');};
 const scrub=dx=>async target=>{const h=target.locator('[data-property-row-field-label]');await h.scrollIntoViewIfNeeded();const b=await h.boundingBox();assert(b);await page.mouse.move(b.x+b.width/2,b.y+b.height/2);await page.mouse.down();await page.mouse.move(b.x+b.width/2+dx,b.y+b.height/2);await page.mouse.up();};
 const choose=(index,keyboard)=>async target=>{await target.locator('[data-choice-group-trigger]').click();if(keyboard){await target.locator('[data-choice-group-option="0"]').focus();for(let i=0;i<index;i++)await page.keyboard.press('ArrowDown');await page.keyboard.press('Enter');}else await target.locator('[data-choice-group-option="'+index+'"]').click();};
 async function edit(property,section,oldValue,value,action,values=reference){const requests=proof.sourceRequests.length,oldCatalog=catalog();await action(row(property,section));const start=expectedSource.indexOf('#'+selected+' {'),end=expectedSource.indexOf('}',start)+1;assert(expectedSource.slice(start,end).includes(property+':'+oldValue+';'));expectedSource=expectedSource.slice(0,start)+expectedSource.slice(start,end).replace(property+':'+oldValue+';',property+':'+value+';')+expectedSource.slice(end);await published(++count);assert.equal(source(),expectedSource);assert.notEqual(catalog(),oldCatalog);assert.equal(proof.sourceRequests.length,requests+1);values[property]=value;await computed(values);record(selected+' '+property+' exact native source/compiler/preview one request/history command');}
 await select('action');for(const s of ['position','layout','appearance'])await open(s);
 await computed();await body('appearance').getByRole('checkbox',{name:'Toggle Per-corner'}).check();
 for(const [property,section,oldValue,midValue,newValue] of [['left','position','10px','12px','14px'],['top','position','12px','14px','16px'],['height','layout','48px','50px','52px'],['gap','layout','6px','8px','10px'],['padding-bottom','layout','3px','5px','7px'],['padding-left','layout','4px','6px','8px'],['border-bottom-right-radius','appearance','3px','5px','7px'],['border-bottom-left-radius','appearance','4px','6px','8px']]){
  await edit(property,section,oldValue,midValue,scrub(1));await edit(property,section,midValue,newValue,typed(newValue));
 }
 await edit('mix-blend-mode','appearance','normal','multiply',choose(1,false));await edit('mix-blend-mode','appearance','multiply','screen',choose(2,true));
 const ordinarySource=source(),ordinaryCatalog=catalog(),requests=proof.sourceRequests.length;
 await page.evaluate(()=>window.__popupAcceptance.history(false));await published(--count);assert.equal(source(),ordinarySource.replace('mix-blend-mode:screen;','mix-blend-mode:multiply;'));reference['mix-blend-mode']='multiply';await computed();
 await page.evaluate(()=>window.__popupAcceptance.history(true));await published(++count);assert.equal(source(),ordinarySource);reference['mix-blend-mode']='screen';await computed();assert.equal(proof.sourceRequests.length,requests+2);record('remaining ordinary undo/redo compiles exact bytes and preserves all siblings');
 // Actual declared schema arrives through the real SSR DOM reader, not seeded VMs.
 await select('schema-panel');await open('component-properties');
 const schemaList=body('component-properties').locator('[data-component-props-list]');
 const schemaRow=property=>schemaList.locator('[data-property-row-css-property="'+property+'"]');
 proof.schemaRows=await schemaList.locator('[data-component-prop-schema]').evaluateAll(nodes=>nodes.map(n=>({property:n.dataset.propertyRowCssProperty,schema:n.dataset.componentPropSchema,readonly:n.dataset.propertyRowReadonly})));assert(proof.schemaRows.some(r=>r.property==='width'&&r.schema==='component.card.width'));
 const schemaValues={width:'24px','text-align':'left'};await computed(schemaValues);
 // Scope ordinary helper to this real component list; no duplicate CSS-row ambiguity.
 async function schemaEdit(property,oldValue,value,action){const n=proof.sourceRequests.length,oldCatalog=catalog();await action(schemaRow(property));const start=expectedSource.indexOf('#schema-panel {'),end=expectedSource.indexOf('}',start)+1;expectedSource=expectedSource.slice(0,start)+expectedSource.slice(start,end).replace(property+':'+oldValue+';',property+':'+value+';')+expectedSource.slice(end);await published(++count);assert.equal(source(),expectedSource);assert.notEqual(catalog(),oldCatalog);assert.equal(proof.sourceRequests.length,n+1);schemaValues[property]=value;await computed(schemaValues);assert.equal(await schemaRow(property).locator('input').inputValue(),property==='width'?value.slice(0,-2):value);record('actual component schema '+property+' guarded source/compiler/preview');}
 await schemaEdit('width','24px','26px',scrub(1));await schemaEdit('width','26px','28px',typed('28px'));
 await schemaEdit('text-align','left','right',typed('right'));
 // Actual computed/text-content schema rows with no mapped source stay readonly.
 const content=schemaRow('text');assert.equal(await content.count(),1);assert.equal(await content.getAttribute('data-property-row-readonly'),'true');
 const unsupportedSchema={source:source(),catalog:catalog(),requests:proof.sourceRequests.length,state:await snapshot()};await typed('Changed content')(content);assert.equal(await content.locator('input').inputValue(),'Actual schema node');assert.equal(source(),unsupportedSchema.source);assert.equal(catalog(),unsupportedSchema.catalog);assert.equal(proof.sourceRequests.length,unsupportedSchema.requests);assert.equal((await snapshot()).undoCount,count);record('actual unmapped component text content refuses without fabricated source capability');
 // Actual inline DSL provenance must have a legitimate source owner; a lower
 // priority CSS const declaration cannot masquerade as ownership of that inline value.
 await select('state-panel');await open('state');
 const stateRow=body('state').locator('[data-state-list] [data-property-row-css-property="width"]');
 assert.equal(await stateRow.count(),1,'Real DSL provenance must expose width State row');
 proof.stateBefore={state:await snapshot(),row:await stateRow.evaluate(n=>n.outerHTML),metadata:await page.evaluate(()=>{const f=[...document.querySelectorAll('iframe')].find(f=>f.getClientRects().length&&f.contentDocument?.querySelector('#state-panel'));return f.contentDocument.querySelector('#state-panel').outerHTML;}),source:source(),catalog:catalog(),requests:proof.sourceRequests.length};writeFileSync(root+'/actual-state-admission.json',JSON.stringify(proof.stateBefore,null,2));
 await computed({width:'44px'});
 if(await stateRow.getAttribute('data-property-row-readonly')!=='true'){
  const beforeStateRequests=proof.sourceRequests.length;await typed('48px')(stateRow);
  // The State view may replace its own draft row before submission. Preserve
  // that physical result; the ordinary Width row proves the same bad admission
  // reaches the actual native writer rather than inferring a source patch.
  proof.statePhysicalDraft={state:await snapshot(),source:source(),requests:proof.sourceRequests.length,row:await stateRow.evaluate(n=>n.outerHTML)};
  if(proof.sourceRequests.length===beforeStateRequests){await open('layout');await typed('48px')(row('width','layout'));}
  await published(++count);await computed({width:'44px'});
  proof.stateWrongOwner={state:await snapshot(),source:source(),catalog:catalog(),row:await stateRow.evaluate(n=>n.outerHTML),requests:proof.sourceRequests.length};writeFileSync(root+'/actual-state-wrong-owner.json',JSON.stringify(proof.stateWrongOwner,null,2));
  assert.fail('Real State edit wrote lower-priority const while actual winning inline width remains44px');
 }
 assert.equal(await stateRow.getAttribute('data-property-row-readonly'),'true','Unsupported inline declaration must not borrow lower CSS const ownership');
 await open('layout');assert.equal(await row('width','layout').getAttribute('data-property-row-readonly'),'true');assert.equal(await row('width','layout').locator('input').inputValue(),'44');await typed('48px')(row('width','layout'));await typed('48px')(stateRow);assert.equal(source(),proof.stateBefore.source);assert.equal(catalog(),proof.stateBefore.catalog);assert.equal(proof.sourceRequests.length,proof.stateBefore.requests);await computed({width:'44px'});assert.equal(await stateRow.locator('input').inputValue(),'44px');assert.equal((await snapshot()).undoCount,count);record('actual inline State source admission refuses lower-priority const and preserves winning preview');
 // Both actual mounted Width hosts must disclose unsupported native scopes.
 const scopes=stateRow.locator('[data-source-scope-kind][aria-label="Apply local instance scope for width"]').or(row('width','layout').locator('[data-source-scope-kind][aria-label="Apply local instance scope for width"]'));
 // Each host has a visible pill plus its closed-menu option.
 assert.equal(await scopes.count(),4);
 proof.inlineScopeChoices=await scopes.evaluateAll(nodes=>nodes.map(n=>({editable:n.getAttribute('data-source-scope-editable'),disabled:n.getAttribute('aria-disabled'),target:n.getAttribute('data-source-scope-target')})));
 for(const scope of proof.inlineScopeChoices){assert.equal(scope.editable,'false');assert.equal(scope.disabled,'true');assert.equal(scope.target,'state-panel');}
 const visibleScopes=scopes.filter({visible:true});assert.equal(await visibleScopes.count(),2);
 for(let i=0;i<await visibleScopes.count();i++){await visibleScopes.nth(i).click({force:true});}
 assert.equal(source(),proof.stateBefore.source);assert.equal(catalog(),proof.stateBefore.catalog);assert.equal(proof.sourceRequests.length,proof.stateBefore.requests);assert.equal((await snapshot()).undoCount,count);await computed({width:'44px'});
 const directRefusal=JSON.parse(await page.evaluate(()=>window.__popupAcceptance.attemptSelectedNativeProperty('width','48px')));assert(directRefusal.completed);assert.equal(directRefusal.ok,false);assert(directRefusal.diagnostic.includes('inline'));assert.equal(source(),proof.stateBefore.source);assert.equal(catalog(),proof.stateBefore.catalog);assert.equal(proof.sourceRequests.length,proof.stateBefore.requests);await computed({width:'44px'});record('supplementary actual selected-element native writer refuses inline ownership before transport');
 const finalSource=source(),finalCatalog=catalog();await page.reload();await page.waitForFunction(()=>!!window.__popupAcceptance);await page.locator('[data-toolbar-cluster="mode"] [aria-label="Edit"]').click();await select('action');await computed();assert.equal(source(),finalSource);assert.equal(catalog(),finalCatalog);record('remaining native source declarations and sibling values survive real reload');
 await open('layout');const before=await snapshot(),nr=proof.sourceRequests.length;await typed('NaN')(row('height','layout'));assert.equal(source(),finalSource);assert.equal(catalog(),finalCatalog);assert.equal(proof.sourceRequests.length,nr);await computed();assert.equal((await snapshot()).undoCount,before.undoCount);record('remaining numeric nonfinite refusal retains native source/compiler/preview/history');
 assert.deepEqual(proof.errors,[]);assert.deepEqual(proof.agentRequests,[]);writeFileSync(root+'/proof.json',JSON.stringify(proof,null,2));console.log('Inspector remaining GUI passed:',root,proof.cases.length);
} finally {if(browser)await browser.close();if(browserServer)await browserServer.close();server.kill('SIGTERM');await new Promise(resolve=>{if(server.exitCode!==null)return resolve();server.once('exit',resolve);setTimeout(()=>{server.kill('SIGKILL');resolve();},15000).unref();});writeFileSync(root+'/proof-final.json',JSON.stringify(proof,null,2));}
