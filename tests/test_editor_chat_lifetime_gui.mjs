/** Genuine DOMRenderer production assistant/chat tree and physical current input.
 * Recording adapters isolate admission only; no Harbor/process/source/compiler
 * outcome is simulated or claimed. Captured addEventListener functions are saved
 * unchanged and invoked directly after retirement using genuine Event objects.
 * This proves retained-callback safety, not dispatch to removed DOM listeners. */
import {spawn} from 'node:child_process';
import {mkdtempSync,readFileSync,writeFileSync,copyFileSync} from 'node:fs';
import {tmpdir} from 'node:os';import path from 'node:path';import assert from 'node:assert/strict';
import {fileURLToPath} from 'node:url';import {createHash} from 'node:crypto';
import {chromium} from '../node_modules/playwright/index.mjs';
const repo=path.resolve(path.dirname(fileURLToPath(import.meta.url)),'..');
const root=mkdtempSync(path.join(process.env.ISONIM_POPUP_ARTIFACTS||tmpdir(),'chat-lifetime-'));
copyFileSync(repo+'/build/editor-chat-lifetime/editor.js',root+'/editor.js');
writeFileSync(root+'/index.html','<!doctype html><html><body><script src="editor.js"></script></body></html>');
const proof={head:process.env.ISONIM_TEST_HEAD,sourceState:process.env.ISONIM_TEST_SOURCE_STATE,
 bundleSha256:createHash('sha256').update(readFileSync(root+'/editor.js')).digest('hex'),cases:[],errors:[],requests:[]};
const server=spawn('python3',['-u','-m','http.server','0','--bind','127.0.0.1','--directory',root],{stdio:['ignore','pipe','pipe']});let browser;
try{
 const origin=await new Promise((resolve,reject)=>{let text='';server.stdout.on('data',d=>{text+=d;const m=text.match(/port (\d+)/);if(m)resolve('http://127.0.0.1:'+m[1]);});server.once('exit',c=>reject(Error('server exit '+c)));setTimeout(()=>reject(Error('server startup timeout')),10000).unref();});
 const env={...process.env};delete env.LD_LIBRARY_PATH;
 browser=await chromium.launch({headless:true,env,executablePath:process.env.PLAYWRIGHT_CHROMIUM_EXECUTABLE});
 const page=await browser.newPage({viewport:{width:1440,height:900}});page.setDefaultTimeout(30000);
 await page.addInitScript(()=>{const add=EventTarget.prototype.addEventListener;window.__chatListeners=[];
   EventTarget.prototype.addEventListener=function(type,fn,...rest){if(this instanceof Element||this===document)window.__chatListeners.push({node:this,type,fn});return add.call(this,type,fn,...rest);};});
 page.on('pageerror',e=>proof.errors.push(e.message));page.on('request',r=>{if(new URL(r.url()).pathname.startsWith('/api/'))proof.requests.push(r.url());});
 await page.goto(origin,{waitUntil:'domcontentloaded'});await page.waitForFunction(()=>window.__chatLifetime);
 await page.evaluate(()=>{window.__keyPrevention=[];document.addEventListener('keydown',event=>{if(event.target?.getAttribute?.('aria-label')==='Agent prompt'&&event.key==='Enter')queueMicrotask(()=>window.__keyPrevention.push(event.defaultPrevented));});});
 const state=async()=>JSON.parse(await page.evaluate(()=>window.__chatLifetime.state()));
 const input=()=>page.getByRole('textbox',{name:'Agent prompt'});const send=()=>page.getByRole('button',{name:'Send agent prompt',exact:true});
 await input().fill('first prompt');await send().click();assert.deepEqual((await state()).prompts,['Active task:first prompt']);
 await input().fill('retained first draft');
 await page.evaluate(()=>{window.__oldChat=window.__chatListeners.filter(x=>x.node instanceof Element&&(['Agent prompt','Send agent prompt','Cancel agent prompt','Close conversation','Widen right panel'].includes(x.node.getAttribute('aria-label'))||x.node.hasAttribute('data-editor-control-approval')));window.__oldNew=window.__chatListeners.find(x=>x.node instanceof Element&&x.type==='click'&&x.node.hasAttribute('data-ai-assistant-new-chat'));});
 const original=(await state()).original;
 await page.getByRole('button',{name:'Create new chat',exact:true}).click();await input().fill('new untouched draft');
 const invokeOld=async()=>page.evaluate(()=>{for(const x of window.__oldChat){if(x.node.tagName==='TEXTAREA')x.node.value='retired payload';const event=x.type==='keydown'?new KeyboardEvent('keydown',{key:'Enter',cancelable:true}):new Event(x.type);x.fn.call(x.node,event);if(x.type==='keydown'&&x.node.tagName==='TEXTAREA'&&event.defaultPrevented)throw Error('Retired Enter prevented default');}});
 const before=await state();await invokeOld();assert.deepEqual(await state(),before);
 proof.cases.push('physical first admission and New chat; saved old input/send/Enter/cancel/close/settings/width callbacks preserve both conversations exactly');
 await send().click();assert.equal((await state()).prompts.at(-1),'Active task:new untouched draft');
 await page.locator('[data-ai-assistant-tab="'+original+'"]').click();await input().fill('returned current draft');
 const returned=await state();await invokeOld();assert.deepEqual(await state(),returned);
 await page.evaluate(()=>window.__chatLifetime.backendIdentity());await input().press('Enter');assert.equal((await state()).prompts.at(-1),'Active task:returned current draft');assert.deepEqual(await page.evaluate(()=>window.__keyPrevention),[true]);
 proof.cases.push('physical same-chat tab revisit creates fresh live view; old callbacks remain inert and backend identity initialization preserves current keyboard admission');
 await page.getByRole('button',{name:'Cancel agent prompt',exact:true}).click();assert.equal((await state()).cancels,1);
 await page.getByRole('button',{name:'Close conversation',exact:true}).click();assert.equal((await state()).closes,1);
 await input().fill('retained root draft');
 await page.evaluate(()=>window.__oldMouseups=window.__chatListeners.filter(x=>x.node===document&&x.type==='mouseup'));
 await page.evaluate(()=>window.__retiredCurrent=window.__chatListeners.filter(x=>x.node.isConnected));
 const closing=await state();await page.evaluate(()=>window.__chatLifetime.unmount());assert.deepEqual(await state(),closing);
 await page.evaluate(()=>{for(const x of window.__retiredCurrent){if(['click','input','change','keydown'].includes(x.type))x.fn.call(x.node,x.type==='keydown'?new KeyboardEvent('keydown',{key:'Enter'}):new Event(x.type));}window.__oldNew.fn.call(window.__oldNew.node,new Event('click'));});
 assert.deepEqual(await state(),closing);await page.evaluate(()=>window.__chatLifetime.remount());assert.equal(await input().inputValue(),'retained root draft');assert.deepEqual(await state(),closing);
 const handle=page.locator('[data-resize-handle="right-panel"]');assert.equal(await handle.count(),1);
 const box=await handle.boundingBox();assert(box&&box.height>0);const start={x:box.x+box.width/2,y:box.y+box.height/2};
 assert(await handle.evaluate((el,p)=>el.contains(document.elementFromPoint(p.x,p.y)),start));
 const widthBefore=(await state()).width;
 await page.mouse.move(start.x,start.y);await page.mouse.down();await page.mouse.move(start.x-30,start.y);
 const dragging=await page.evaluate(()=>({cursor:document.body.style.cursor,select:document.body.style.userSelect}));assert.deepEqual(dragging,{cursor:'col-resize',select:'none'});
 const dragState=await state();assert.notEqual(dragState.width,widthBefore,'Fresh physical resize changes actual VM width');await page.evaluate(()=>{for(const x of window.__oldMouseups)x.fn.call(document,new MouseEvent('mouseup'));});assert.deepEqual(await state(),dragState);assert.deepEqual(await page.evaluate(()=>({cursor:document.body.style.cursor,select:document.body.style.userSelect})),dragging);
 await page.mouse.up();assert.deepEqual(await page.evaluate(()=>({cursor:document.body.style.cursor,select:document.body.style.userSelect})),{cursor:'',select:''});
 await page.mouse.move(start.x,start.y);await page.mouse.down();await page.evaluate(()=>window.__chatLifetime.unmount());assert.deepEqual(await page.evaluate(()=>({cursor:document.body.style.cursor,select:document.body.style.userSelect})),{cursor:'',select:''});await page.mouse.up();
 proof.cases.push('retired endDrag preserves fresh physical resize; live pointerup and disposal release their own active gesture');
 proof.cases.push('current cancel/close controls work; root disposal and every captured shared/chat control leave admitted close and retained model intact; remount retains draft/session');
 assert.deepEqual(proof.errors,[]);assert.deepEqual(proof.requests,[]);
}finally{if(browser)await browser.close();server.kill('SIGTERM');await new Promise(resolve=>server.once('exit',resolve));writeFileSync(root+'/proof-final.json',JSON.stringify(proof,null,2));console.log(root+'/proof-final.json');}
