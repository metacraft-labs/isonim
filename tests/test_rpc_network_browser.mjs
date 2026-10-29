// Genuine loopback HTTP, real Chromium fetch/Promise/Response and abort signal.
// The local server controls head/body delivery and failures; no transport stub.
import {chromium} from './browser/node_modules/playwright/index.mjs';
import {readFile} from 'node:fs/promises';
import {createServer} from 'node:http';
import {execFileSync} from 'node:child_process';
import assert from 'node:assert/strict';
const fixture=await readFile('build/rpc_projection_fixture.js','utf8');
const requests=[],slots=new Map(),failedHeads=new Set();
const server=createServer(async(req,res)=>{
 const u=new URL(req.url,'http://localhost');
 if(u.pathname==='/'){res.end('<!doctype html>RPC native I/O');return;}
 if(u.pathname==='/fixture.js'){res.setHeader('Content-Type','text/javascript');res.end(fixture);return;}
 let body='';for await(const chunk of req)body+=chunk;
 const id=u.searchParams.get('id');
 requests.push({id,method:req.method,body,csrf:req.headers['x-csrf-token'],context:req.headers['isonim-context'],oldContext:req.headers['x-isonim-context'],type:req.headers['content-type']});
 // The browser may natively retry a reused connection closed before headers.
 // A released head failure remains a failed endpoint, including that retry;
 // no application retry or transport replacement is installed by this test.
 if(failedHeads.has(id)){req.socket.destroy();return;}
 if(u.pathname==='/head'||u.pathname==='/body'){
  slots.set(id,res);
  if(u.pathname==='/body'){res.writeHead(207,{'Content-Type':'text/plain'});res.flushHeaders();res.write('first-');}
 }else{res.writeHead(207,{'Content-Type':'text/plain','Retry-After':'3','Isonim-Commit':'0/16B3750'});res.end('actual:'+body);}
});
await new Promise(r=>server.listen(0,'127.0.0.1',r));
const base='http://127.0.0.1:'+server.address().port;
const browser=await chromium.launch({executablePath:execFileSync('which',['chromium'],{encoding:'utf8'}).trim()});
const errors=[];
async function slot(id){for(let n=0;n<200;n++){if(slots.has(id))return slots.get(id);await new Promise(r=>setTimeout(r,5));}throw Error('missing actual request '+id);}
try{
 for(const path of ['facade','composition']){
  const page=await browser.newPage();page.on('pageerror',e=>errors.push(String(e)));
  await page.goto(base);await page.addScriptTag({url:base+'/fixture.js'});
  for(const body of [null,'','payload']){
   const id=path+'-body-'+String(body);
   const done=await page.evaluate(async({path,body,id})=>{
    rpcProbe.reset();const result=await rpcProbe[path]('POST','/ready?id='+id,body,'csrf','context','text/x-rpc',null);
    return {status:result.status,text:result.text,retryAfter:result.retryAfter,commit:result.commit,dispatches:rpcProbe.count()};
   },{path,body,id});
   assert.deepEqual(done,{status:207,text:'actual:'+(body??''),retryAfter:'3',commit:'0/16B3750',dispatches:path==='facade'?1:0},'RPC real response and Retry-After/Isonim-Commit projection');
   assert.deepEqual(requests.filter(r=>r.id===id),[{id,method:'POST',body:body??'',csrf:'csrf',context:'context',oldContext:undefined,type:'text/x-rpc'}],'RPC real request body/headers/count');
  }
  for(const phase of ['head','body'])for(const finish of ['complete','abort','fail']){
   const id=path+'-'+phase+'-'+finish;
   console.log('RPC native case '+id);
   const response=phase==='body'?page.waitForResponse(r=>r.url().endsWith('?id='+id)):null;
   await page.evaluate(({path,id,phase})=>{
    rpcProbe.reset();globalThis.outcome={state:'pending'};globalThis.controller=new AbortController();
    rpcProbe[path]('POST','/'+phase+'?id='+id,'payload','csrf','context','text/x-rpc',controller.signal).then(
     value=>outcome={state:'fulfilled',status:value.status,text:value.text,dispatches:rpcProbe.count()},
     error=>outcome={state:'rejected',error:String(error),dispatches:rpcProbe.count()});
   },{path,id,phase});
   const res=await slot(id);if(response)await response;
   const pending=await page.evaluate(()=>({state:outcome.state,dispatches:rpcProbe.count()}));
   assert.deepEqual(pending,{state:'pending',dispatches:0},'RPC delayed native completion remains pending');
   if(finish==='complete'){if(phase==='head')res.writeHead(207,{'Content-Type':'text/plain'});res.end(phase==='body'?'last':'complete');}
   else if(finish==='abort'){await page.evaluate(()=>controller.abort());}
   else {if(phase==='head')failedHeads.add(id);res.destroy();}
   try {await page.waitForFunction(()=>outcome.state!=='pending');}
   catch(error){console.error('RPC native pending diagnostic',id,await page.evaluate(()=>({outcome,dispatches:rpcProbe.count()})),requests);throw error;}
   const done=await page.evaluate(()=>outcome);
   assert.equal(done.state,'fulfilled','RPC native failure fulfilled');
   assert.equal(done.status,finish==='complete'?207:finish==='abort'?-1:0,'RPC real head/body status');
   assert.equal(done.dispatches,path==='facade'?1:0,'RPC real exactly one facade dispatch');
   if(finish==='complete')assert.equal(done.text,phase==='body'?'first-last':'complete');
   else assert.equal(typeof done.text,'string');
   const received=requests.filter(r=>r.id===id);
   if(phase==='head'&&finish==='fail'){
    assert(received.length>0,'RPC native head failure reached server');
    for(const request of received)assert.deepEqual(request,{id,method:'POST',body:'payload',csrf:'csrf',context:'context',oldContext:undefined,type:'text/x-rpc'},'native connection retries preserve request');
   }else assert.equal(received.length,1,'RPC actual native request count');
   if(finish==='abort')res.destroy();
  }
  await page.close();
 }
 assert.deepEqual(errors,[],'no uncaught browser error');
 console.log('PASS actual delayed RPC facade/composition native HTTP '+requests.length+' requests');
}finally{for(const res of slots.values())res.destroy();await browser.close();server.closeAllConnections();await new Promise(r=>server.close(r));}
