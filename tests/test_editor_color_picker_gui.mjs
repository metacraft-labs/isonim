/** Default native-inspector composition (catalog-only preview mode is exercised
 * separately by popup acceptance). Real mounted production inspector, native authenticated source worker, private
 * files and actual Nim compiler/SSR catalog. No UI, source, compiler, HTTP or
 * dispatcher is mocked. Added ColorPicker cases audit actual native range UA
 * shadow/thumb computed CSS through Chromium CDP, physical keys/drags and marker
 * coordinates. Expected percentages use native CSSOM serialization (which rounds
 * percentage text), with exact equality to independent physical-coordinate
 * expectations. This is not a popup/source/renderer substitute. Cancellation stimuli control input delivery only; no source or
 * compiler result is simulated. The original Fill permission/lifetime cases remain. The configured controlled decision peer only permits
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
 // C3 production picker: all drafts below leave real source/compiler state alone.
 const pickerPopup=page.locator('[data-color-popover-open="true"]');
 const pickerHex=pickerPopup.locator('[data-color-popover-input]');
 const plane=pickerPopup.locator('[data-color-plane]'),marker=plane.locator('[data-color-plane-marker]');
 const hue=pickerPopup.locator('[data-color-hue]'),opacity=pickerPopup.locator('[data-color-alpha]');
 await swatch.click();
 const c3Before={source:source(),catalog:catalog(),state:await snapshot(),preview:await preview()};
 const pickerState=async()=>({hex:await pickerHex.inputValue(),left:await marker.evaluate(el=>el.style.left),top:await marker.evaluate(el=>el.style.top),hue:await hue.inputValue(),opacity:await opacity.inputValue()});
 async function draftOnly(){assert.equal(source(),c3Before.source);assert.equal(catalog(),c3Before.catalog);assert.deepEqual(await snapshot(),c3Before.state);assert.deepEqual(await preview(),c3Before.preview);assert.equal(proof.sourceRequests.length,0);assert.deepEqual(proof.agentRequests,[]);}
 async function point(s,v,release=true){await plane.scrollIntoViewIfNeeded();const b=await plane.boundingBox();assert(b);assert.equal(b.width,b.height,'Actual SV field is square');assert(b.width>100);const x=Math.round(b.x+b.width*s),y=Math.round(b.y+b.height*(1-v));const start={x:Math.max(b.x+1,Math.min(x,b.x+b.width-1)),y:Math.max(b.y+1,Math.min(y,b.y+b.height-1))};assert(await plane.evaluate((el,{x,y})=>el.contains(document.elementFromPoint(x,y)),start));const node=await plane.elementHandle();await page.mouse.move(start.x,start.y);await page.mouse.down();await page.mouse.move(x,y);assert(await node.evaluate(el=>el.isConnected),'Captured original plane stays connected');if(release)await page.mouse.up();return{s:(x-b.x)/b.width,v:1-(y-b.y)/b.height};}
 const opening=await pickerState();assert.equal(await marker.count(),1);assert(await marker.isVisible());assert.equal(await marker.evaluate(el=>getComputedStyle(el).pointerEvents),'none');assert.equal(await marker.evaluate(el=>getComputedStyle(el).borderTopColor),'rgb(255, 255, 255)');
 const percent=async value=>page.evaluate(value=>{const reference=document.createElement('div');reference.style.left=value+'%';return reference.style.left;},value);
 const chosen=await point(.6,.75);let st=await pickerState();writeFileSync(root+'/marker-coordinate-diagnostic.json',JSON.stringify({chosen,st},null,2));assert.equal(st.left,await percent(chosen.s*100));assert.equal(st.top,await percent((1-chosen.v)*100));
 await plane.focus();const axes=await pickerState();await plane.press('ArrowRight');await plane.press('ArrowUp');st=await pickerState();assert.equal(st.left,await percent(parseFloat(axes.left)+1));assert.equal(st.top,await percent(parseFloat(axes.top)-1));assert(await plane.evaluate(el=>document.activeElement===el));await draftOnly();record('square visible contrasting marker tracks real pointer coordinates and both keyboard axes without source/history/global-selection effects');
 // Inspect the real native range thumb/track computed styles, not stylesheet text.
 const cdp=await context.newCDPSession(page);await cdp.send('DOM.enable');await cdp.send('CSS.enable');
 const doc=(await cdp.send('DOM.getDocument',{depth:-1,pierce:true})).root;
 const descendants=n=>[n,...(n.children||[]).flatMap(descendants),...(n.shadowRoots||[]).flatMap(descendants)];
 const nodes=descendants(doc),attr=(n,k)=>{const a=n.attributes||[];for(let i=0;i<a.length;i+=2)if(a[i]===k)return a[i+1];};
 const liveDialog=nodes.filter(n=>attr(n,'data-color-popover-open')==='true');assert.equal(liveDialog.length,1);const liveNodes=descendants(liveDialog[0]);const nativeThumbs=[];
 for(const [selector,control] of [['data-color-hue',hue],['data-color-alpha',opacity]]){
  const input=liveNodes.find(n=>attr(n,selector)==='true'&&descendants(n).some(c=>attr(c,'id')==='thumb'||attr(c,'id')==='slider-thumb'));
  assert(input,'Real native UA shadow range required');const thumb=descendants(input).find(n=>['thumb','slider-thumb'].includes(attr(n,'id')));assert(thumb?.nodeId);
  const computed=Object.fromEntries((await cdp.send('CSS.getComputedStyleForNode',{nodeId:thumb.nodeId})).computedStyle.map(v=>[v.name,v.value]));
  assert.equal(computed.width,'14px');assert.equal(computed.height,'14px');assert.equal(computed['border-top-width'],'2px');assert.equal(computed['border-top-color'],'rgb(255, 255, 255)');nativeThumbs.push({selector,nodeId:thumb.nodeId,computed});
  assert((await control.evaluate(el=>getComputedStyle(el).backgroundImage)).includes('linear-gradient'));
 }
 assert((await opacity.evaluate(el=>getComputedStyle(el).backgroundImage)).includes('conic-gradient'));proof.nativeThumbs=nativeThumbs;record('actual native hue and opacity thumbs use contrasting custom computed styles with rainbow/checkerboard tracks');
 // Physical keyboard navigation establishes focus-visible, not just activeElement.
 await plane.scrollIntoViewIfNeeded();await plane.focus();await plane.press('Tab');
 const focusStyles=[];
 for(const control of [hue,opacity]){
  assert(await control.evaluate(el=>document.activeElement===el));
  const css=await control.evaluate(el=>({visible:el.matches(':focus-visible'),outline:getComputedStyle(el).outlineStyle,width:getComputedStyle(el).outlineWidth,color:getComputedStyle(el).outlineColor}));
  assert.equal(css.visible,true);assert.equal(css.outline,'solid');assert.equal(css.width,'2px');assert.equal(css.color,'rgb(165, 180, 252)');focusStyles.push(css);await control.press('Tab');
 }
 await opacity.focus();await opacity.press('Shift+Tab');await hue.press('Shift+Tab');assert(await plane.evaluate(el=>document.activeElement===el));
 const planeFocus=await plane.evaluate(el=>({visible:el.matches(':focus-visible'),outline:getComputedStyle(el).outlineStyle,width:getComputedStyle(el).outlineWidth,color:getComputedStyle(el).outlineColor}));
 assert.equal(planeFocus.visible,true);assert.equal(planeFocus.outline,'solid');assert.equal(planeFocus.width,'2px');assert.equal(planeFocus.color,'rgb(165, 180, 252)');proof.focusStyles=[...focusStyles,planeFocus];await draftOnly();

 await pickerHex.fill('#000000');await hue.focus();await hue.press('Home');for(let i=0;i<120;i++)await hue.press('ArrowRight');assert.equal(await hue.inputValue(),'120');assert.equal(await pickerHex.inputValue(),'#000000');
 const black=await point(.7,0);const blackBefore=await pickerState();assert.equal(blackBefore.hex,'#000000');
 await hue.focus();await hue.press('End');assert.equal(await hue.inputValue(),'359');assert.equal((await pickerState()).left,blackBefore.left);assert.equal(await pickerHex.inputValue(),'#000000');
 await plane.focus();await plane.press('ArrowUp');st=await pickerState();assert.equal(st.hue,'359');assert.equal(st.left,blackBefore.left);assert.notEqual(st.hex,'#000000');await draftOnly();record('native hue keyboard at black preserves latent saturation; raising brightness retains chosen hue and marker intent');
 // Actual capture loss, window blur and Escape cancel a black same-hex gesture.
 for(const cancel of ['lostcapture','blur','Escape']){
  await pickerHex.fill('#000000');await point(.7,0);const original=await pickerState();await point(.2,0,false);
  if(cancel==='lostcapture')await plane.evaluate(el=>{for(let id=1;id<5;id++)if(el.hasPointerCapture(id))el.releasePointerCapture(id);});
  else if(cancel==='blur')await page.evaluate(()=>window.dispatchEvent(new Event('blur')));
  else await plane.press('Escape');
  await page.mouse.up();assert.equal(await pickerPopup.count(),1);assert.deepEqual(await pickerState(),original);await draftOnly();
 }
 await opacity.scrollIntoViewIfNeeded();const alphaBefore=await pickerState();await opacity.focus();await opacity.press('Home');await opacity.press('ArrowRight');assert.equal(await opacity.inputValue(),'1');assert.equal((await pickerState()).left,alphaBefore.left);await draftOnly();
 await hue.focus();await hue.press('ArrowLeft');await draftOnly();record('same-hex latent SV cancellation restores full coordinates after capture loss/blur/Escape; native range keys retain selection and draft-only semantics');
 // Preserve genuine native range behavior while capturing transaction lifetime.
 async function rangeDrag(control,fraction,release=true){await control.scrollIntoViewIfNeeded();await control.focus();await control.press('Home');const b=await control.boundingBox();assert(b);const start={x:b.x+7,y:b.y+b.height/2};assert(await control.evaluate((el,p)=>el.contains(document.elementFromPoint(p.x,p.y)),start));const node=await control.elementHandle();await page.mouse.move(start.x,start.y);await page.mouse.down();await page.mouse.move(b.x+7+(b.width-14)*fraction,start.y);assert(await node.evaluate(el=>el.isConnected));if(release)await page.mouse.up();}
 await pickerHex.fill('#336699');const rangeBefore=await pickerState();await rangeDrag(hue,.4);st=await pickerState();assert(Number(st.hue)>0&&Number(st.hue)<359);assert.notEqual(st.hex,rangeBefore.hex);assert.equal(st.left,rangeBefore.left);assert.equal(st.top,rangeBefore.top);
 await rangeDrag(opacity,.5);st=await pickerState();assert(Number(st.opacity)>0&&Number(st.opacity)<100);assert.equal(parseInt(st.hex.slice(7,9),16),Math.round(Number(st.opacity)*255/100));await draftOnly();
 await pickerPopup.locator('[data-color-channel="Red"]').fill('255');await pickerPopup.locator('[data-color-channel="Red"]').press('Tab');st=await pickerState();assert.equal(st.hex.slice(1,3),'FF');
 const rgb=[1,3,5].map(i=>parseInt(st.hex.slice(i,i+2),16)/255),greatest=Math.max(...rgb),least=Math.min(...rgb);assert.equal(st.left,await percent((greatest?1-least/greatest:0)*100));assert.equal(st.top,await percent((1-greatest)*100));
 await pickerPopup.locator('[data-color-channel="Alpha %"]').fill('70');await pickerPopup.locator('[data-color-channel="Alpha %"]').press('Tab');assert.equal((await pickerHex.inputValue()).slice(7,9),'B3');await draftOnly();record('physical native hue/opacity drags and typed RGB/alpha share color/marker draft validation without source writes');
 for(const control of [hue,opacity]){
  await pickerHex.fill('#000000');await point(.7,0);await control.focus();await control.press('Home');const original=await pickerState();await control.evaluate(el=>{window.__rangeCaptureAudit=[];for(const type of ['pointerdown','gotpointercapture','lostpointercapture','pointermove','pointerup','input'])el.addEventListener(type,e=>window.__rangeCaptureAudit.push({type,id:e.pointerId,captured:e.pointerId?el.hasPointerCapture(e.pointerId):false,value:el.value}));});await rangeDrag(control,.5,false);
  const nativeThumb=nativeThumbs.find(t=>t.selector===(control===hue?'data-color-hue':'data-color-alpha'));const remote=(await cdp.send('DOM.resolveNode',{nodeId:nativeThumb.nodeId})).object;const released=await cdp.send('Runtime.callFunctionOn',{objectId:remote.objectId,functionDeclaration:'function(){if(!this.hasPointerCapture(1))return false;this.releasePointerCapture(1);return !this.hasPointerCapture(1);}',returnByValue:true});assert.equal(released.result.value,true,'Release the ACTUAL UA thumb pointer capture, not the retargeted input host');const continued=await control.boundingBox();await page.mouse.move(continued.x+continued.width*.8,continued.y+continued.height/2);await page.mouse.up();writeFileSync(root+'/range-capture-diagnostic.json',JSON.stringify({events:await page.evaluate(()=>window.__rangeCaptureAudit),original,after:await pickerState()},null,2));assert.deepEqual(await pickerState(),original);await draftOnly();
 }
 record('real native UA thumb capture loss restores complete hue/SV/alpha draft coordinates through continued movement, including same-hex black');await cdp.detach();
 for(const control of [hue,opacity])for(const cancellation of ['Escape','blur']){
  await pickerHex.fill('#000000');await point(.7,0);await control.focus();await control.press('Home');const original=await pickerState();await rangeDrag(control,.4,false);
  if(cancellation==='Escape')await control.press('Escape');else await page.evaluate(()=>window.dispatchEvent(new Event('blur')));
  assert.equal(await pickerPopup.count(),1);assert.deepEqual(await pickerState(),original);
  const b=await control.boundingBox();await page.mouse.move(b.x+b.width*.8,b.y+b.height/2);writeFileSync(root+'/range-cancel-continuation.json',JSON.stringify({cancellation,original,after:await pickerState()},null,2));assert.deepEqual(await pickerState(),original);await page.mouse.up();assert.deepEqual(await pickerState(),original);await draftOnly();
  await rangeDrag(control,.3);assert.notDeepEqual(await pickerState(),original,'Fresh subsequent native gesture remains usable');await draftOnly();
 }
 record('Escape/blur range cancellation keeps full restored coordinates through continued physical motion; fresh native gestures still work');
 await pickerPopup.locator('[data-color-popover-cancel]').click();await swatch.click();assert.deepEqual(await pickerState(),opening);await pickerHex.press('Escape');assert.equal(await pickerPopup.count(),0);await draftOnly();record('Cancel and reopening resynchronize authored color and both marker coordinates without a source operation');
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
 await page.evaluate(()=>window.__popupAcceptance.readOnly(false));await swatch.click();await hue.focus();await hue.press('Home');await hue.press('ArrowRight');await point(.6,.75);await plane.focus();await plane.press('ArrowRight');const appliedPickerHex=(await draft.inputValue()).toLowerCase();const appliedRgb=[1,3,5].map(i=>parseInt(appliedPickerHex.slice(i,i+2),16));await popup.locator('[data-color-popover-apply]').click();
 await page.waitForFunction(()=>JSON.parse(window.__popupAcceptance.snapshot()).stage==='wesClean'&&JSON.parse(window.__popupAcceptance.snapshot()).undoCount===1,{},{timeout:70000});
 assert.equal(source(),before.source.replace('background-color:#112233;','background-color:'+appliedPickerHex+';'));assert.equal(proof.sourceRequests.length,1);
 await page.waitForFunction(expected=>{const frame=[...document.querySelectorAll('iframe')].find(frame=>frame.getClientRects().length&&frame.contentDocument?.querySelector('#action'));return frame&&frame.contentWindow.getComputedStyle(frame.contentDocument.querySelector('#action')).backgroundColor===expected;},'rgb('+appliedRgb.join(', ')+')');
 await page.evaluate(()=>window.__popupAcceptance.history(false));await page.waitForFunction(()=>JSON.parse(window.__popupAcceptance.snapshot()).stage==='wesClean'&&JSON.parse(window.__popupAcceptance.snapshot()).undoCount===0,{},{timeout:70000});
 assert.equal(source(),before.source);assert.equal(proof.sourceRequests.length,2);
 await page.waitForFunction(()=>{const frame=[...document.querySelectorAll('iframe')].find(frame=>frame.getClientRects().length&&frame.contentDocument?.querySelector('#action'));return frame&&frame.contentWindow.getComputedStyle(frame.contentDocument.querySelector('#action')).backgroundColor==='rgb(17, 34, 51)';});
 assert.deepEqual(JSON.parse(catalog()),JSON.parse(before.catalog),'Undo restores the compiled document; native producer uses its own final-newline serialization');const restoredCatalog=catalog();
 await page.evaluate(()=>window.__popupAcceptance.readOnly(true));record('restored permission applies the actual pointer/keyboard SV draft in ONE native transaction/compiler/preview; native undo restores exact source');
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
 writeFileSync(root+'/proof.json',JSON.stringify(proof,null,2));console.log('ColorPicker GUI passed:',root,proof.cases.length);
} finally {
 if(browser)await browser.close();if(browserServer)await browserServer.close();
 server.kill('SIGTERM');await new Promise(resolve=>{if(server.exitCode!==null)return resolve();server.once('exit',resolve);setTimeout(()=>{server.kill('SIGKILL');resolve();},15000).unref();});
 writeFileSync(root+'/proof-final.json',JSON.stringify(proof,null,2));
}
