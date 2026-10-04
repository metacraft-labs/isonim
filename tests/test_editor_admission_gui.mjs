/**
 * Actual production mounted editor, BrowserAgentClient/adapter/VM/DOM/fetch/SSE.
 * The HTTP daemon peer is a justified protocol mock: minimal register/poll/session
 * metadata and withheld SSE/close responses force timing unavailable to a real
 * external provider. It performs no editor operations/catalog/apply ACKs. Only this peer is controlled to deterministically withhold end,
 * interrupt an admitted stream and hold close. No browser/VM/client mocks or
 * substituted events/callbacks; a real TCP peer sends documented protocol frames.
 * Official Rust/provider coverage remains the unchanged required GUI15 suite.
 * Barriers are observed requests, actual DOM state and handler observations;
 * no sleep proves consumption or readiness. No model inference.
 */
import assert from 'node:assert/strict';
import http from 'node:http';
import net from 'node:net';
import {spawn} from 'node:child_process';
import {fileURLToPath} from 'node:url';
import {randomUUID} from 'node:crypto';
import {readFileSync,mkdtempSync,writeFileSync} from 'node:fs';
import path from 'node:path';
import {tmpdir} from 'node:os';
import {chromium} from '../node_modules/playwright/index.mjs';
const root=path.resolve(process.env.ISONIM_ADMISSION_ASSETS??'build/editor-chat'),artifacts=mkdtempSync(path.join(tmpdir(),'isonim-admission-gui-'));
console.log('ADMISSION ARTIFACTS '+artifacts);
// A real child and an actually nonexistent executable exercise setup cleanup.
// No browser/process mocks: prove child exit, readable receipt, and refused TCP.
if (!process.argv.includes('--launch-failure-child')) {
 const child=spawn(process.execPath,[fileURLToPath(import.meta.url),'--launch-failure-child'],
  {env:{...process.env,PLAYWRIGHT_CHROMIUM_EXECUTABLE:path.join(artifacts,'nonexistent-browser')},stdio:['ignore','pipe','pipe']});
 let output='';child.stdout.on('data',chunk=>output+=chunk);child.stderr.on('data',chunk=>output+=chunk);
 const timer=setTimeout(()=>child.kill('SIGKILL'),30000);
 const code=await new Promise((resolve,reject)=>{child.on('error',reject);child.on('close',resolve);}).finally(()=>clearTimeout(timer));
 writeFileSync(path.join(artifacts,'launch-control.log'),output,{mode:0o600});
 assert.equal(code,1);assert.throws(()=>process.kill(child.pid,0),{code:'ESRCH'});
 const childArtifacts=output.match(/^ADMISSION ARTIFACTS (.+)$/m)?.[1];assert.ok(childArtifacts);
 const receipt=JSON.parse(readFileSync(path.join(childArtifacts,'cleanup.json'),'utf8'));
 assert.equal(receipt.serverListening,false);assert.equal(receipt.browserCreated,false);assert.ok(receipt.port>0);
 assert.match(readFileSync(path.join(childArtifacts,'failure.txt'),'utf8'),/executable.*exist/i);
 await new Promise((resolve,reject)=>{
  const socket=net.connect({host:'127.0.0.1',port:receipt.port});
  socket.setTimeout(5000,()=>{socket.destroy();reject(Error('Cleanup TCP verification timeout'));});
  socket.once('connect',()=>{socket.destroy();reject(Error('Setup failure left server listening'));});
  socket.once('error',error=>{socket.destroy();error.code==='ECONNREFUSED'?resolve():reject(error);});
 });
 writeFileSync(path.join(artifacts,'launch-control.json'),JSON.stringify({childPid:child.pid,childExited:true,port:receipt.port,connectionRefused:true,childArtifacts},null,2),{mode:0o600});
 console.log('PASS actual nonexistent-browser launch cleanup');
}
const requests=[],streams=[],routes=[];let sessions=0,closeReply,browser,page,port;const errors=[];
const binding={instance:randomUUID(),epoch:randomUUID(),browserToken:randomUUID()};
const server=http.createServer((req,res)=>{
 let raw='';req.on('data',chunk=>raw+=chunk);req.on('end',()=>{
  routes.push(req.url);
  if(req.url==='/api/editor/rpc') {
   const rpc=JSON.parse(raw);let result;
   if(rpc.method==='editor.register') {binding.workspace=rpc.params.workspace;result=binding;}
   else {assert.equal(req.headers['x-isonim-control'],binding.browserToken);assert.equal(rpc.params.instance,binding.instance);assert.equal(rpc.params.epoch,binding.epoch);assert.equal(rpc.params.workspace,binding.workspace);result={commands:[]};}
   res.setHeader('Content-Type','application/json');res.end(JSON.stringify({jsonrpc:'2.0',id:rpc.id,result}));
  } else if(req.url==='/api/agent/sessions') {sessions++;assert.deepEqual(JSON.parse(raw).editor,{workspace:binding.workspace,instance:binding.instance,epoch:binding.epoch});assert.equal(req.headers['x-isonim-control'],binding.browserToken);res.setHeader('Content-Type','application/json');res.end(JSON.stringify({sessionId:'persistent-peer',backend:'harbor',sessionCapabilities:{cancelTurn:false,closeSession:true}}));}
  else if(req.url==='/api/agent/prompts') {
   const body=JSON.parse(raw);assert.equal(body.sessionId,'persistent-peer');requests.push(body);streams.push(res);
   res.writeHead(200,{'Content-Type':'text/event-stream'});
   res.write('event: admitted\ndata: {"accepted":true}\n\n');
   res.write('event: session/update\ndata: '+JSON.stringify({kind:'completed',sessionId:'persistent-peer',state:'completed',stopReason:'end_turn'})+'\n\n');
  } else if(req.url==='/api/agent/close') {assert.equal(JSON.parse(raw).sessionId,'persistent-peer');closeReply=res;}
  else if(req.url.startsWith('/api/')) {res.statusCode=404;res.end('{}');}
  else {
   try {let body=readFileSync(path.join(root,req.url==='/'?'index.html':req.url.split('?')[0]));
    if(req.url==='/')body=Buffer.from(body.toString().replace('<head>','<head><meta name="isonim-review-api" content="http://127.0.0.1:'+server.address().port+'">'));
    res.setHeader('Content-Type',req.url.endsWith('.js')?'application/javascript':'text/html');res.end(body);
   }catch {res.statusCode=404;res.end();}
  }
 });
});
const until=async probe=>{const end=Date.now()+5000;while(!await probe()){if(Date.now()>end)throw Error('Observed admission boundary timeout');await new Promise(resolve=>setTimeout(resolve,2));}};
try{
 await new Promise((resolve,reject)=>{server.once('error',reject);server.listen(0,'127.0.0.1',resolve);});
 port=server.address().port;
 browser=await chromium.launch({headless:true,
  ...(process.env.PLAYWRIGHT_CHROMIUM_EXECUTABLE?{executablePath:process.env.PLAYWRIGHT_CHROMIUM_EXECUTABLE}:{}),
  env:{...process.env,LD_LIBRARY_PATH:''},args:['--no-sandbox']});
 page=await browser.newPage();page.on('pageerror',e=>errors.push(e.message));
 await page.addInitScript(()=>{window.admission=[];window.__isonimObserveAgentAdmission=value=>window.admission.push({...value,time:Date.now()});});
 await page.goto('http://127.0.0.1:'+server.address().port);
 const composer=page.getByRole('textbox',{name:'Agent prompt'}),send=page.getByRole('button',{name:'Send agent prompt',exact:true});
 await composer.fill('first exact prompt');await send.click();await until(()=>requests.length===1);
 await page.waitForFunction(()=>document.querySelector('[data-chat-session-status]')?.textContent==='Finishing reply');
 await composer.fill('exact newer unsent followup');assert.equal(await send.isDisabled(),true);assert.equal(await send.getAttribute('aria-disabled'),'true');
 await composer.press('Enter');const denied=await page.evaluate(()=>window.admission.at(-1));
 assert.equal(denied.accepted,false);assert.equal(denied.inFlight,true);assert.equal(denied.ready,false);assert.equal(denied.sameChat,true);
 const before=await page.evaluate(()=>window.admission.length);await send.evaluate(el=>el.click());
 assert.equal(await page.evaluate(()=>window.admission.length),before);assert.equal(requests.length,1);assert.equal(sessions,1);assert.equal(await composer.inputValue(),'exact newer unsent followup');
 // Real terminal receipt, with activity already completed: flight notification
 // must enable the existing DOM control even without a new status transition.
 streams[0].end('event: end\ndata: {"stopReason":"max_tokens"}\n\n');
 await page.waitForFunction(()=>document.querySelector('[aria-label="Send agent prompt"]')?.disabled===false);
 assert.equal(await page.locator('[data-chat-session-status]').innerText(),'Ready for next message');
 await send.click();await until(()=>requests.length===2);
 assert.equal(sessions,1);assert.equal(requests[1].sessionId,requests[0].sessionId);
 assert.equal(requests[1].messages[0].content[0].text,'exact newer unsent followup');
 await composer.fill('draft retained across actual interrupted EOF');streams[1].end();
 await page.waitForFunction(()=>document.querySelector('.editor-chat')?.textContent.includes('interrupted'));
 assert.equal(await send.isDisabled(),true);await composer.press('Enter');
 const interrupted=await page.evaluate(()=>window.admission.at(-1));assert.equal(interrupted.accepted,false);assert.equal(interrupted.inFlight,true);
 assert.equal(requests.length,2);assert.equal(sessions,1);assert.equal(await composer.inputValue(),'draft retained across actual interrupted EOF');
 await page.getByRole('button',{name:'Close conversation',exact:true}).click();await until(()=>closeReply);
 assert.equal(await send.isDisabled(),true);closeReply.end(JSON.stringify({closed:true}));
 await page.waitForFunction(()=>document.querySelector('[aria-label="Agent prompt"]')?.value==='');
 assert.equal(requests.length,2);assert.equal(sessions,1);assert.deepEqual(errors,[]);
 const observation=await page.evaluate(()=>window.admission);
 writeFileSync(path.join(artifacts,'evidence.json'),JSON.stringify({sessions,prompts:requests.length,sameSession:true,observations:observation,errors},null,2));
 console.log('PASS actual HTTP/SSE mounted admission, premature completion, terminal same-session followup, interrupted draft and explicit close; '+artifacts);
}catch(error){
 writeFileSync(path.join(artifacts,'failure.txt'),String(error.stack),{mode:0o600});
 writeFileSync(path.join(artifacts,'diagnostics.json'),JSON.stringify({routes,sessions,prompts:requests.length,
  observations:page?await page.evaluate(()=>window.admission).catch(()=>[]):[],
  publicText:page?await page.locator('.editor-chat').innerText().catch(()=>''):'',errors},null,2),{mode:0o600});
 throw error;
}finally{
 try {if(browser)await browser.close();}
 finally {
  for(const response of streams)response.destroy();closeReply?.destroy();server.closeAllConnections();
  if(server.listening)await new Promise((resolve,reject)=>server.close(error=>error?reject(error):resolve()));
  writeFileSync(path.join(artifacts,'cleanup.json'),JSON.stringify({port,serverListening:server.listening,browserCreated:Boolean(browser)},null,2),{mode:0o600});
 }
}
