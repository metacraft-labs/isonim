/** Internal viewport preparation. Real Chromium observations, actual installed
 * Recorder/strict codec/runtime; no cursor/provider mock or historical source.
 * Replay getters are deliberately perturbed to discriminate platform fallback.
 */
import assert from "node:assert/strict";
import { readFileSync } from "node:fs";
import { createRequire } from "node:module";
import { createServer } from "node:http";
const root = process.cwd();
const { chromium } = await import(root + "/tests/browser/node_modules/playwright/index.mjs");
const artifact = process.env.CT_ARTIFACT;
assert(artifact, "actual owner artifact required");
const require = createRequire(artifact + "/packages/boundary-shim/package.json");
const { build } = require("esbuild");
const owned = (await build({
  stdin: { resolveDir: artifact, contents: `
import {Recorder,numberToBits} from '@codetracer/boundary-shim/dist/browser/recorder.js';
import {captureOriginals} from '@codetracer/boundary-shim/dist/browser/originals.js';
import {readEnvironment} from '@codetracer/boundary-shim/dist/browser/install.js';
import {domV1Hash} from '@codetracer/boundary-shim/dist/browser/dom-v1.js';
import {encodeLog,decodeRecord} from '@codetracer/boundary-format';
import {installReplayRuntime} from '@codetracer/boundary-replay/dist/browser/runtime.js';
globalThis.xrViewportBegin=()=>{
 const orig=captureOriginals(window),frames=[],samples=[],recordReads=[];
 localStorage.removeItem('missing');localStorage.setItem('empty','');localStorage.setItem('value','recorded-string');
 document.cookie='xr=original;path=/';const cookie=document.cookie;
 const rec=new Recorder({checkpointScheme:'dom-v1',checkpointHash:()=>domV1Hash(document),sink:{append(f){frames.push(f);},end(){},halt(){}}});
 const bootEnvironment=readEnvironment(window,orig);
 rec.start({vocab:1,protocol_level:0,recorder_id:'internal-viewport',framework:'',build_hash:'a'.repeat(64),session_id:'1'.repeat(32),prev_session:'',capabilities:'[]'},bootEnvironment);
 for(let i=0;i<2;i++){const value=orig.performanceNow.call(performance);samples.push(value);rec.emit('Clock',{src:2,bits:numberToBits(value)});}
 for(const key of ['missing','empty','value']){const value=orig.storageGetItem.call(localStorage,key);rec.emit('StorageRead',{area:1,key,present:value===null?0:1,value:value??''});}
 rec.emit('StorageRead',{area:3,key:'',present:1,value:cookie});
 globalThis.xrViewportPrepare=(mode)=>{
 const recorded={};
 for(const prop of ['innerWidth','innerHeight']){
   // The original genuine Chromium getter, called once in original seam order.
   const descriptor=Object.getOwnPropertyDescriptor(window,prop);
   if(typeof descriptor?.get!=='function')throw Error('native viewport getter missing');
   const value=descriptor.get.call(window);recordReads.push(prop);recorded[prop]=value;
   const second=prop==='innerHeight';
   rec.emit('LayoutRead',{target:mode===(second?'height-target':'width-target')?'doc':'win',prop:mode===(second?'height-prop':'width-prop')?'devicePixelRatio':prop,value:JSON.stringify(value)});
 }
 rec.end(2);const records=frames.map(f=>decodeRecord(f.subarray(4))),log=encodeLog(records);
 let raw='';for(const b of log)raw+=String.fromCharCode(b);installReplayRuntime(window,{log:btoa(raw)});
 const rawReads=[];globalThis.xrViewportRaw=rawReads;
 for(const prop of ['innerWidth','innerHeight'])Object.defineProperty(window,prop,{configurable:true,get(){rawReads.push(prop);return prop==='innerWidth'?901:902;}});
 const forbidden=[];globalThis.xrViewportForbidden=forbidden;
 const refuse=(name)=>{forbidden.push(name);throw Error('RAW '+name);};
 const NativeDate=Date;window.Date=class extends NativeDate{constructor(...args){if(!args.length)refuse('Date');super(...args);}};
 performance.now=()=>refuse('performance');crypto.getRandomValues=()=>refuse('crypto');
 Storage.prototype.getItem=()=>refuse('storage');Object.defineProperty(document,'cookie',{get:()=>refuse('cookie'),configurable:true});
 window.matchMedia=()=>refuse('media');Element.prototype.getBoundingClientRect=()=>refuse('measure');
 return {samples,recorded,recordReads,cookie,bootViewport:{width:bootEnvironment.viewport_w,height:bootEnvironment.viewport_h},records:records.filter(r=>r.record==='LayoutRead').map(r=>({seq:r.seq.toString(),target:r.target,prop:r.prop,value:r.value}))};
 };return {width:bootEnvironment.viewport_w,height:bootEnvironment.viewport_h};
};` }, bundle:true, platform:"browser", format:"iife", write:false,
})).outputFiles[0].text;
const capture = readFileSync(root + "/build/replay-reads-context.js", "utf8");
const bundle = readFileSync(process.env.REPLAY_VIEWPORT_BUNDLE || root + "/build/replay-viewport.js", "utf8");
const mutant = process.env.REPLAY_VIEWPORT_MUTANT === "1";
const server = createServer((req,res)=>res.end('<!doctype html><main id="root">Viewport</main>'));
await new Promise(r=>server.listen(0,"127.0.0.1",r));
let browser;
try {
 browser=await chromium.launch({executablePath:process.env.PLAYWRIGHT_CHROMIUM_EXECUTABLE});
 for(const mode of mutant?["positive"]:["positive","width-target","width-prop","height-target","height-prop"]){
  const context=await browser.newContext({viewport:{width:733,height:457}});
  const prior=await context.newPage();await prior.goto(`http://127.0.0.1:${server.address().port}/`);
  await prior.evaluate(()=>{globalThis._$HY={seed:731,buildId:"genuine-context",assignment:{read:"A"}};});
  await prior.addScriptTag({content:capture});const bootContext=await prior.evaluate(()=>xrReadBootContext);await prior.close();
  const page=await context.newPage();await page.goto(`http://127.0.0.1:${server.address().port}/`);
  await page.addScriptTag({content:owned});
  // Record the genuine Env BEFORE the viewport change, at the same boot size
  // as the separate prior context. Only subsequent LayoutReads see the resize.
  assert.deepEqual(await page.evaluate(()=>xrViewportBegin()),{width:733,height:457});
  await page.setViewportSize({width:811,height:509});
  const result=await page.evaluate(({mode,bundle,bootContext})=>{
   globalThis.xrReadBootContext=bootContext;const recorded=xrViewportPrepare(mode);
   (0,eval)(bundle);const controls=JSON.parse(xrViewportControls());const before=__ctReplay.status().cursor;
   let observed,first,second,direct;
   try{observed=JSON.parse(xrViewport());}catch(error){first=error;}
   const afterFirst=__ctReplay.status().cursor;
   if(first){
    try{xrViewport();}catch(error){second=error;}
    try{__ctReplay.next('LayoutRead',{target:'win',prop:'innerWidth'});}catch(error){direct=error;}
   }
   return {recorded,bootContext,controls,before,afterFirst,after:__ctReplay.status().cursor,state:__ctReplay.status().state,
    observed,raw:xrViewportRaw,forbidden:xrViewportForbidden,next:__ctReplay.peek()?.kind,
    error:first?{name:first.name,kind:first.divergence?.kind,seq:first.divergence?.seq,
      recorded:first.divergence?.recorded,perCall:first!==second&&second!==direct,
      originalClass:first.constructor===direct?.constructor&&second?.constructor===direct?.constructor,
      payload:first.divergence===second?.divergence&&second?.divergence===direct?.divergence&&direct?.divergence===__ctReplay.failed}:null};
  },{mode,bundle,bootContext});
  assert.deepEqual(result.controls.env,result.bootContext);
  assert.equal(result.controls.tick,BigInt(Math.trunc(result.recorded.samples[0]*1000000)).toString());
  assert.equal(result.controls.neMillis,BigInt(Math.trunc(result.recorded.samples[1])).toString());
  assert.equal(result.controls.missing,"");assert.equal(result.controls.empty,"");
  assert.equal(result.controls.value,"recorded-string");assert.equal(result.controls.cookie,result.recorded.cookie);
  assert.deepEqual(result.forbidden,[]);assert.deepEqual(result.recorded.recordReads,["innerWidth","innerHeight"]);
  assert.deepEqual(result.recorded.recorded,{innerWidth:811,innerHeight:509});
  assert.deepEqual(result.bootContext.viewport,{width:733,height:457});
  assert.deepEqual(result.recorded.bootViewport,result.bootContext.viewport);
  const cursor=BigInt(result.before);
  if(mode==="positive"){
   assert.equal(result.error,null);
   if(mutant){
    assert.deepEqual(result.observed,{x:0,y:0,width:901,height:902});
    assert.deepEqual(result.raw,["innerWidth","innerHeight"]);
    assert.equal(result.after,result.before);assert.equal(result.next,"LayoutRead");
    console.log("viewport restoration: REJECTED raw getters AND pending LayoutRead; Clock2/storage/context controls PASS");
   }else{
    assert.deepEqual(result.observed,{x:0,y:0,width:811,height:509});assert.deepEqual(result.raw,[]);
    assert.equal(BigInt(result.after),cursor+2n);assert.equal(result.next,"Checkpoint");
   }
  }else{
   const consumed=mode.startsWith("height")?1n:0n;
   assert.equal(BigInt(result.afterFirst),cursor+consumed);assert.equal(result.after,result.afterFirst);
   assert.equal(result.error.seq,result.recorded.records[Number(consumed)].seq);
   assert.equal(result.error.kind,"ArgumentMismatch");assert.equal(result.error.payload,true);
   assert.equal(result.error.originalClass,true);assert.equal(result.error.perCall,true);
   assert.ok(result.error.recorded);assert.equal(result.state,"diverged");assert.deepEqual(result.raw,[]);
  }
  console.log("viewport "+mode+": PASS");await context.close();
 }
}finally{await browser?.close();await new Promise(r=>server.close(r));}
