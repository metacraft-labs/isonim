/** Actual stock Time projection and actual installed owner integration.
 * Native Date subclasses select controlled historical/future inputs without
 * changing platform configuration; every getTime delegates to the native Date.
 * A perturbed real Date distinguishes raw fallback. No fake cursor/provider.
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
const owned = (await build({stdin:{resolveDir:artifact,contents:`
import {Recorder,numberToBits} from '@codetracer/boundary-shim/dist/browser/recorder.js';
import {captureOriginals} from '@codetracer/boundary-shim/dist/browser/originals.js';
import {readEnvironment} from '@codetracer/boundary-shim/dist/browser/install.js';
import {domV1Hash} from '@codetracer/boundary-shim/dist/browser/dom-v1.js';
import {encodeLog,decodeRecord} from '@codetracer/boundary-format';
import {installReplayRuntime} from '@codetracer/boundary-replay/dist/browser/runtime.js';
globalThis.xrWallBegin=(inputs,wrongSource)=>{
 const orig=captureOriginals(window),frames=[],samples=[];
 localStorage.removeItem('missing');localStorage.setItem('empty','');localStorage.setItem('value','recorded-string');
 document.cookie='xr=original;path=/';const cookie=document.cookie;
 const rec=new Recorder({checkpointScheme:'dom-v1',checkpointHash:()=>domV1Hash(document),sink:{append(f){frames.push(f);},end(){},halt(){}}});
 rec.start({vocab:1,protocol_level:0,recorder_id:'internal-wall-clock',framework:'',build_hash:'a'.repeat(64),session_id:'1'.repeat(32),prev_session:'',capabilities:'[]'},readEnvironment(window,orig));
 for(let i=0;i<2;i++){const value=orig.performanceNow.call(performance);samples.push(value);rec.emit('Clock',{src:2,bits:numberToBits(value)});}
 for(const key of ['missing','empty','value']){const value=orig.storageGetItem.call(localStorage,key);rec.emit('StorageRead',{area:1,key,present:value===null?0:1,value:value??''});}
 rec.emit('StorageRead',{area:3,key:'',present:1,value:cookie});
 const epochs=inputs.map(input=>new orig.Date(input).getTime());
 for(const epoch of epochs)rec.emit('Clock',{src:wrongSource?1:3,bits:numberToBits(epoch)});
 rec.end(2);const records=frames.map(f=>decodeRecord(f.subarray(4))),log=encodeLog(records);let raw='';for(const b of log)raw+=String.fromCharCode(b);
 installReplayRuntime(window,{log:btoa(raw)});
 const counts={date:0,getTime:0,dateNow:0,performance:0,storage:0,cookie:0};
 const trap=name=>{counts[name]++;throw Error('RAW '+name);};
 const NativeDate=Date,nativeGetTime=NativeDate.prototype.getTime;
 window.Date=class extends NativeDate{
   constructor(...args){super(...(args.length?args:[1234567890000]));if(!args.length)counts.date++;}
   getTime(){counts.getTime++;return nativeGetTime.call(this);}
   static now(){return trap('dateNow');}
 };
 performance.now=()=>trap('performance');Storage.prototype.getItem=()=>trap('storage');
 Object.defineProperty(document,'cookie',{get:()=>trap('cookie'),configurable:true});
 globalThis.xrWallCounts=counts;
 return {samples,cookie,epochs,wallRecords:records.filter(r=>r.record==='Clock'&&r.src!==2).map(r=>({seq:r.seq.toString(),src:r.src,bits:r.bits.toString()}))};
};`},bundle:true,platform:"browser",format:"iife",write:false})).outputFiles[0].text;
const bundle = readFileSync(process.env.REPLAY_WALL_BUNDLE, "utf8");
const realBundle = readFileSync(process.env.REPLAY_WALL_REAL_BUNDLE, "utf8");
const capture = readFileSync(root + "/build/replay-reads-context.js", "utf8");
const inverse=process.env.REPLAY_WALL_INVERSE || "";
const late=process.env.REPLAY_WALL_LATE === "1";
const server=createServer((req,res)=>res.end('<!doctype html><main id="root">Wall clock</main>'));
await new Promise(r=>server.listen(0,"127.0.0.1",r));
let browser;
try {
 browser=await chromium.launch({executablePath:process.env.PLAYWRIGHT_CHROMIUM_EXECUTABLE});
 const context=await browser.newContext();
 const url=`http://127.0.0.1:${server.address().port}/`;
 const prior=await context.newPage();await prior.goto(url);
 await prior.evaluate(()=>{globalThis._$HY={seed:731,buildId:'genuine-context',assignment:{read:'A'}};});
 await prior.addScriptTag({content:capture});const boot=await prior.evaluate(()=>xrReadBootContext);await prior.close();
 const real=await context.newPage();await real.goto(url);
 await real.evaluate(()=>{globalThis._$HY={seed:731,buildId:'genuine-context',assignment:{read:'A'}};});
 await real.addScriptTag({content:realBundle});
 const inputs=[Date.now(),0,-1,1,999,-999,1000,-1000,1001,-1001,1710000000123,-2208988800123,2147483647999,2147483648000,-2147483648000,-2147483649000,8639999999999999,-8639999999999999,8640000000000000,-8640000000000000];
 const baseline=await real.evaluate(inputs=>{
  const NativeDate=Date,nativeGetTime=Date.prototype.getTime;let counts;
  window.Date=class extends NativeDate{
   constructor(...args){super(...(args.length?args:[globalThis.xrWallEpoch]));if(!args.length)counts.date++;}
   getTime(){counts.getTime++;return nativeGetTime.call(this);}
   static now(){counts.dateNow++;return NativeDate.now();}
  };
  return inputs.map(input=>{
   globalThis.xrWallEpoch=input;counts={date:0,getTime:0,dateNow:0};
   try{return {input,value:JSON.parse(xrWallObserve()),counts};}
   catch(error){return {input,error:String(error),name:error.name,counts};}
  });
 },inputs);
 assert.equal(baseline.length,20);
 for(const row of baseline)assert.deepEqual(row.counts,{date:1,getTime:1,dateNow:0});
 const errors=[-1,-999,-1001,-2208988800123,2147483648000,-2147483649000,8639999999999999,-8639999999999999,8640000000000000,-8640000000000000];
 assert.deepEqual(baseline.filter(r=>r.error).map(r=>r.input),errors);
 for(const row of baseline.filter(r=>r.error))assert.match(row.error,/\[RangeDefect\]/);
 await real.close();
 for(const mode of inverse?["positive"]:["positive","source-mismatch","switch-real","switch-test","switch-custom","switch-nil","switch-direct-nil"]){
  const page=await context.newPage();await page.goto(url);await page.addScriptTag({content:owned});
  const result=await page.evaluate(({inputs,bundle,boot,mode,late})=>{
   globalThis.xrReadBootContext=boot;
   if(late){
    globalThis._$HY={seed:731,buildId:'genuine-context',assignment:{read:'A'}};
    (0,eval)(bundle);globalThis.xrReadBootContext=JSON.parse(xrWallSnapshot());
   }
   const recorded=xrWallBegin(inputs,mode==='source-mismatch');
   if(late)xrWallSelectLate();else (0,eval)(bundle);
   const controls=JSON.parse(xrWallControls());
   if(mode==='switch-real')xrWallSwitchReal();
   if(mode==='switch-custom')xrWallSwitchCustom();
   if(mode==='switch-test')xrWallSwitchTest();
   if(mode==='switch-nil')xrWallSwitchNil();
   if(mode==='switch-direct-nil')xrWallSwitchDirectNil();
   const rows=[];let first,second,direct;
   for(const input of mode==='positive'?inputs:[inputs[0]]){
    const before=__ctReplay.status().cursor;let value,error;
    try{value=JSON.parse(xrWallObserve());}catch(e){error=String(e);first=e;}
    rows.push({input,value,error,name:first?.name,before,after:__ctReplay.status().cursor});
    if(mode==='source-mismatch'||globalThis.xrWallSourceInverse){
      try{xrWallObserve();}catch(e){second=e;}
      try{__ctReplay.next('Clock',{src:3});}catch(e){direct=e;}
      break;
    }
   }
   return {recorded,controls,boot:globalThis.xrReadBootContext,rows,counts:xrWallCounts,next:__ctReplay.peek().kind,
    state:__ctReplay.status().state,error:first?{name:first.name,kind:first.divergence?.kind,seq:first.divergence?.seq,
     originalClass:first.constructor===direct?.constructor&&second?.constructor===direct?.constructor,
     perCall:first!==second&&second!==direct,payload:first.divergence===second?.divergence&&second?.divergence===direct?.divergence&&direct?.divergence===__ctReplay.failed}:null};
  },{inputs,bundle:inverse==='source'?"globalThis.xrWallSourceInverse=true;"+bundle:bundle,boot,mode,late});
  assert.deepEqual(result.controls.env,result.boot);
  assert.equal(result.controls.tick,BigInt(Math.trunc(result.recorded.samples[0]*1000000)).toString());
  assert.equal(result.controls.neMillis,BigInt(Math.trunc(result.recorded.samples[1])).toString());
  assert.equal(result.controls.missing,"");assert.equal(result.controls.empty,"");assert.equal(result.controls.value,"recorded-string");assert.equal(result.controls.cookie,result.recorded.cookie);
  assert.deepEqual(result.recorded.epochs,inputs);
  assert.equal(result.recorded.wallRecords.length,20);
  for(let i=0;i<inputs.length;i++){
   const bits=new DataView(new ArrayBuffer(8));bits.setFloat64(0,inputs[i],true);
   assert.equal(result.recorded.wallRecords[i].bits,bits.getBigUint64(0,true).toString());
   assert.equal(result.recorded.wallRecords[i].src,mode==='source-mismatch'?1:3);
  }
  assert.equal(result.counts.performance,0);assert.equal(result.counts.storage,0);assert.equal(result.counts.cookie,0);assert.equal(result.counts.dateNow,0);
  const mismatch=mode==='source-mismatch'||inverse==='source';
  if(mismatch){
   const row=result.rows[0];assert.equal(row.before,result.recorded.wallRecords[0].seq);assert.equal(row.after,row.before);
   assert.equal(result.error.name,'ReplayDivergence');assert.equal(result.error.kind,'ArgumentMismatch');assert.equal(result.error.seq,row.before);
   assert.equal(result.error.originalClass,true);assert.equal(result.error.perCall,true);assert.equal(result.error.payload,true);
   assert.equal(result.state,'diverged');assert.equal(result.next,'Clock');assert.equal(result.counts.date,0);
  }else if(inverse==='raw'){
   assert.equal(result.rows.length,20);assert.equal(result.counts.date,20);assert.equal(result.counts.getTime,20);
   for(const row of result.rows){assert.equal(row.before,row.after);assert.deepEqual(row.value,{seconds:'1234567890',nanoseconds:0});}
   assert.equal(result.next,'Clock');assert.equal(result.rows[0].before,result.recorded.wallRecords[0].seq);
  }else if(mode.startsWith('switch-')){
   const row=result.rows[0];assert.equal(row.before,row.after);assert.equal(result.next,'Clock');
   assert.equal(row.error,undefined);
   if(mode==='switch-test'){assert.deepEqual(row.value,{seconds:'0',nanoseconds:500000000});assert.equal(result.counts.date,0);}
   else {assert.deepEqual(row.value,{seconds:'1234567890',nanoseconds:0});assert.equal(result.counts.date,1);assert.equal(result.counts.getTime,1);}
  }else{
   assert.equal(result.counts.date,0);assert.equal(result.counts.getTime,0);assert.equal(result.rows.length,20);
   assert.equal(result.next,'Checkpoint');
   let changed=0;
   for(let i=0;i<20;i++){
    const row=result.rows[i],expected=baseline[i];
    assert.equal(row.before,result.recorded.wallRecords[i].seq);assert.equal(BigInt(row.after),BigInt(row.before)+1n);
    if(inverse==='normalized'){
     if([0,-1000,1000].includes(row.input)){assert.deepEqual(row.value,expected.value);assert.equal(row.error,undefined);}
     if([-1,2147483648000].includes(row.input)){assert.ok(expected.error);assert.equal(row.error,undefined);assert.ok(row.value);changed++;}
    }else if(expected.error){
     assert.ok(row.error);assert.equal(row.name,expected.name);assert.equal(row.error.split('\nTraceback')[0],expected.error.split('\nTraceback')[0]);
    }else {assert.equal(row.error,undefined);assert.deepEqual(row.value,expected.value);}
   }
   if(inverse==='normalized')assert.equal(changed,2,'both specifically named historical error cases changed');
  }
  // Keep every full baseline/projection error trace, not just the comparison key.
  console.log(JSON.stringify({mode,inverse,late,baseline,result}));
  console.log(`wall ${mode}${inverse?' inverse-'+inverse:''}: PASS; Clock2/storage/context controls PASS`);
  await page.close();
 }
 if(inverse==='raw')console.log('wall raw inverse REJECTED:20 raw Date/getTime effects AND pending Clock3');
 if(inverse==='source')console.log('wall source inverse REJECTED: exact Clock3 sequence, original latched mismatch, pending cursor');
 if(inverse==='normalized')console.log('wall normalization inverse REJECTED:-1 and2147483648000 changed from RangeDefect to Time; whole-second controls PASS');
 if(!inverse)console.log('wall parity:10 exact Time values AND10 preserved genuine RangeDefects; zero replay Date');
 await context.close();
}finally{await browser?.close();await new Promise(r=>server.close(r));}
