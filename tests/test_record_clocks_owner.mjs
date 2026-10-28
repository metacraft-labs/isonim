/** Real Nim primitive -> owner Recorder/strict codec -> owned Replay/dom-v1.
 * Controlled Date subclasses delegate to native Date for historical epochs;
 * counted native wrappers witness calls/receivers without invented clock values.
 * Exact native-error sentinels select the exception path only; successful paths
 * always delegate to native functions. A one-shot actual sink append fault
 * exercises Recorder.guard/Refusal, without replacing the writer or codec.
 * No fake writer, cursor, scheduler, checkpoint, provider or platform adapter.
 */
import assert from 'node:assert/strict';
import {readFileSync} from 'node:fs';
import {createRequire} from 'node:module';
import {createServer} from 'node:http';
const root=process.cwd(), artifact=process.env.CT_ARTIFACT;
assert(artifact,'CT_ARTIFACT required: owner integration cannot skip');
const require=createRequire(artifact+'/packages/boundary-shim/package.json');
const {build}=require('esbuild');
const {chromium}=await import(root+'/tests/browser/node_modules/playwright/index.mjs');
const owner=(await build({stdin:{resolveDir:artifact,contents:`
import {Recorder,numberToBits} from '@codetracer/boundary-shim/dist/browser/recorder.js';
import {captureOriginals} from '@codetracer/boundary-shim/dist/browser/originals.js';
import {readEnvironment} from '@codetracer/boundary-shim/dist/browser/install.js';
import {domV1Hash} from '@codetracer/boundary-shim/dist/browser/dom-v1.js';
import {decodeRecord,encodeLog} from '@codetracer/boundary-format';
import {installReplayRuntime} from '@codetracer/boundary-replay/dist/browser/runtime.js';
globalThis.recordClockApi={Recorder,numberToBits,captureOriginals,readEnvironment,domV1Hash,decodeRecord,encodeLog,installReplayRuntime};
`},bundle:true,platform:'browser',format:'iife',write:false})).outputFiles[0].text;
// Bundle once, together: separately bundling the owner would create another class.
const combined=(await build({stdin:{resolveDir:artifact,contents:`
import {Recorder,numberToBits} from '@codetracer/boundary-shim/dist/browser/recorder.js';
import {captureOriginals} from '@codetracer/boundary-shim/dist/browser/originals.js';
import {readEnvironment} from '@codetracer/boundary-shim/dist/browser/install.js';
import {domV1Hash} from '@codetracer/boundary-shim/dist/browser/dom-v1.js';
import {decodeRecord,encodeLog} from '@codetracer/boundary-format';
globalThis.recordClockApi={Recorder,numberToBits,captureOriginals,readEnvironment,domV1Hash,decodeRecord,encodeLog};
${readFileSync(process.env.RECORD_CLOCK_BUNDLE,'utf8')}
Object.assign(globalThis,{rcInit,rcMono,rcWall,rcSwitchTest,rcSelected,rcPublicWall,rcPublicMono});
`},bundle:true,platform:'browser',format:'iife',write:false})).outputFiles[0].text;
const replay=readFileSync(process.env.RECORD_CLOCK_REPLAY,'utf8');
const contextBundle=readFileSync(root+'/build/replay-reads-context.js','utf8');
const inverse=process.env.RECORD_CLOCK_INVERSE||'';
const server=createServer((req,res)=>res.end('<!doctype html><main>Clock primitives</main>'));
await new Promise(resolve=>server.listen(0,'127.0.0.1',resolve));
let browser;
try{
 browser=await chromium.launch({executablePath:process.env.PLAYWRIGHT_CHROMIUM_EXECUTABLE});
 const context=await browser.newContext(),url='http://127.0.0.1:'+server.address().port;
 const prior=await context.newPage();await prior.goto(url);await prior.addScriptTag({content:contextBundle});
 const boot=await prior.evaluate(()=>xrReadBootContext);await prior.close();
 const modes=inverse?['positive']:['positive','throw-mono','throw-date','throw-getTime','stopped','faulted','selection','invalid'];
 for(const mode of modes){
  const page=await context.newPage();await page.goto(url);await page.addScriptTag({content:combined});
  const result=await page.evaluate(({mode})=>{
   const a=recordClockApi,native=a.captureOriginals(window),frames=[],counts={mono:0,date:0,getTime:0,dateNow:0},receivers=[];
   const nativeTime=native.Date.prototype.getTime,monoValues=[],wallValues=[],sentinel={nativeClockFailure:true},trace=[];
   let epoch=1710000000123,throwAt='',failSink=mode==='faulted';
   // The controlled original still constructs actual native Date instances.
   window.Date=class extends native.Date{
    constructor(...args){if(args.length)super(...args);else{counts.date++;trace.push('Date');if(throwAt==='date')throw sentinel;super(epoch);}}
    getTime(){counts.getTime++;trace.push('getTime');if(throwAt==='getTime')throw sentinel;const v=nativeTime.call(this);wallValues.push(v);return v;}
    static now(){counts.dateNow++;throw Error('Date.now must not substitute');}
   };
   performance.now=function(){counts.mono++;trace.push('performance');receivers.push(this===performance);if(throwAt==='mono')throw sentinel;const v=native.performanceNow.call(this);monoValues.push(v);return v;};
   const orig=a.captureOriginals(window);
   const rec=new a.Recorder({checkpointScheme:'dom-v1',checkpointHash:()=>a.domV1Hash(document),sink:{append(f){const r=a.decodeRecord(f.subarray(4));if(r.record==='Clock')trace.push('Clock'+r.src);if(failSink&&r.record==='Clock'){failSink=false;throw Error('actual sink fault');}frames.push(f);},end(unloading,frame){frames.push(frame);},halt(){}}});
   rec.start({vocab:1,protocol_level:0,recorder_id:'private-clock-primitives',framework:'',build_hash:'a'.repeat(64),session_id:'1'.repeat(32),prev_session:'',capabilities:'[]'},a.readEnvironment(window,native));
   globalThis.recordClockOwner={orig,rec};
   const initialFrames=frames.length;
   // Constructor must neither read clocks nor select/patch the platform.
   const before={...counts},beforePerf=performance.now,beforeDate=Date,beforeReplay=globalThis.__ctReplay;
   if(mode==='invalid'){
    const errors=[];
    for(const bad of [{orig,rec:{guard(){},emit(){}}},{orig:{...orig,Date:null},rec},{orig:{...orig,performanceNow:null},rec}]){
     globalThis.recordClockOwner=bad;try{rcInit();errors.push(null);}catch(e){errors.push({name:e.name,message:e.message});}
    }
    return {mode,errors,before,counts,frames:frames.length,initialFrames};
   }
   rcInit();
   const construction={before,after:{...counts},samePerf:beforePerf===performance.now,sameDate:beforeDate===Date,sameReplay:beforeReplay===globalThis.__ctReplay};
   // Perturb the current platform after capture. The object owns originals.
   const lateRaw={performance:0,date:0,dateNow:0},lateError=Error('late raw clock');
   const lateTrap=name=>{lateRaw[name]++;throw lateError;};
   performance.now=()=>lateTrap('performance');
   window.Date=new Proxy(native.Date,{construct(){return lateTrap('date');},get(target,key,receiver){if(key==='now')return()=>lateTrap('dateNow');return Reflect.get(target,key,receiver);}});
   for(const [name,invoke] of [['performance',()=>performance.now()],['date',()=>new Date()],['dateNow',()=>Date.now()]]){const n=lateRaw[name];let caught;try{invoke();}catch(e){caught=e;}if(caught!==lateError||lateRaw[name]!==n+1)throw Error('late trap witness '+name);lateRaw[name]=0;}
   let substituteError;try{orig.Date.now();}catch(e){substituteError=e;}if(substituteError?.message!=='Date.now must not substitute'||counts.dateNow!==1)throw Error('captured Date.now trap witness');counts.dateNow=0;
   const output=[],throws=[];
   const call=kind=>{const n=frames.length;try{const v=kind==='mono'?rcMono():rcWall();output.push({kind,value:v,bits:String(a.numberToBits(v))});}catch(e){throws.push({kind,same:e===sentinel,framesUnchanged:frames.length===n});}};
   if(mode.startsWith('throw-')){throwAt=mode.slice(6);call(throwAt==='mono'?'mono':'wall');throwAt='';call('mono');call('wall');}
   else if(mode==='stopped'){rec.end(2);const n=frames.length;call('mono');call('wall');return {mode,construction,output,counts,receivers,unchanged:frames.length===n,monoValues,wallValues,lateRaw,trace};}
   else if(mode==='faulted'){call('mono');call('wall');call('mono');}
   else{
    if(mode==='selection'){rcSwitchTest();if(rcSelected()!==17.25)throw Error('ordinary selected Test clock changed');}
    call('mono');call('mono');
    for(const value of [1710000000123,0,-0,1,-1,999,-999,1000,-1000,1001,-1001,2147483647999,2147483648000,-2147483648000,-2147483649000,8640000000000000]){epoch=value;call('wall');}
   }
   rec.end(2);
   const records=frames.map(f=>a.decodeRecord(f.subarray(4)));
   let raw='';for(const b of a.encodeLog(records))raw+=String.fromCharCode(b);
   return {mode,construction,output,throws,counts,receivers,monoValues,wallValues,lateRaw,trace,log:btoa(raw),records:JSON.parse(JSON.stringify(records,(_,v)=>typeof v==='bigint'?String(v):v))};
  },{mode});
  if(mode==='invalid'){
   assert.deepEqual(result.counts,result.before);assert.equal(result.frames,result.initialFrames);
   assert(result.errors.every(e=>e?.name==='TypeError'&&/actual Recorder/.test(e.message)));await page.close();continue;
  }
  assert.deepEqual(result.construction.before,result.construction.after,'construction must not observe native clocks');
  for(const key of ['samePerf','sameDate','sameReplay'])assert.equal(result.construction[key],true);
  assert(result.receivers.every(Boolean),'exact performance receiver');assert.equal(result.counts.dateNow,0);
  assert.deepEqual(result.lateRaw,{performance:0,date:0,dateNow:0},'every witnessed late platform trap remains unused');
  if(['stopped','faulted'].includes(mode)){
   // Silence is not enough: successful native observations must still return
   // the exact original number/double, even after stop or an actual sink fault.
   const monos=result.output.filter(r=>r.kind==='mono'),walls=result.output.filter(r=>r.kind==='wall');
   assert.equal(monos.length,result.monoValues.length);assert.equal(walls.length,result.wallValues.length);
   for(let i=0;i<monos.length;i++)assert(Object.is(monos[i].value,result.monoValues[i]));
   for(let i=0;i<walls.length;i++)assert(Object.is(walls[i].value,result.wallValues[i]));
   const expectedBits=await page.evaluate(values=>values.map(v=>String(recordClockApi.numberToBits(v))),result.output.map(r=>r.value));
   assert.deepEqual(result.output.map(r=>r.bits),expectedBits,'stopped/faulted exact returned double bits');
  }
  if(mode==='stopped'){assert.equal(result.unchanged,true);assert.equal(result.counts.mono,1);assert.equal(result.counts.date,1);assert.equal(result.counts.getTime,1);await page.close();continue;}
  if(mode.startsWith('throw-'))assert.deepEqual(result.throws,[{kind:mode==='throw-mono'?'mono':'wall',same:true,framesUnchanged:true}],'native throw identity and no emission');
  if(mode==='faulted'){
   assert.equal(result.output.length,3);assert.equal(result.counts.mono,2);assert.equal(result.counts.date,1);
   assert.deepEqual(result.records.filter(r=>!['Header','Env'].includes(r.record)).map(r=>r.record),['Refusal']);
   assert.equal(result.records.at(-1).feature,'recorder-fault');await page.close();continue;
  }
  const clocks=result.records.filter(r=>r.record==='Clock');
  const expectedMono=result.monoValues.length,expectedWall=result.wallValues.length;
  const wallOutput=result.output.filter(r=>r.kind==='wall'),wallClocks=clocks.filter(r=>r.src===3);
  assert.equal(wallClocks.length,expectedWall,'neutral native wall count retained in each inverse');
  for(let i=0;i<expectedWall;i++){assert(Object.is(wallOutput[i].value,result.wallValues[i]));assert.equal(wallClocks[i].bits,wallOutput[i].bits,'neutral wall double bits retained');}
  if(inverse!=='value')for(let i=0;i<result.output.filter(r=>r.kind==='mono').length;i++)assert(Object.is(result.output.filter(r=>r.kind==='mono')[i].value,result.monoValues[inverse==='extra'?2*i:i]),'unchanged native monotonic value');
  if(inverse==='extra'){
   assert.equal(result.counts.mono,result.output.filter(r=>r.kind==='mono').length*2,'inverse adds exactly a second original read');
   assert.equal(clocks.length,result.output.length);console.log('additional native sampling REJECTED at exact one-read oracle');await page.close();continue;
  }
  assert.equal(result.counts.mono,mode==='throw-mono'?2:expectedMono,'one original monotonic read');
  assert.equal(result.counts.date,['throw-date','throw-getTime'].includes(mode)?expectedWall+1:expectedWall,'one original Date construction');
  assert.equal(result.counts.getTime,mode==='throw-getTime'?expectedWall+1:expectedWall,'one instance getTime');
  if(inverse==='omit'){
   assert.equal(clocks.length,result.output.length-expectedMono);assert(clocks.every(r=>r.src===3));console.log('omitted Clock2 emission REJECTED at exact recorded read count');await page.close();continue;
  }
  assert.equal(clocks.length,result.output.length,'one Clock record per successful original');
  if(inverse==='value'){
   assert(result.output.filter(r=>r.kind==='mono').every((r,i)=>r.value===result.monoValues[i]+1));
   assert(clocks.filter(r=>r.src===2).every((r,i)=>r.bits!==result.output.filter(r=>r.kind==='mono')[i].bits));console.log('altered native return REJECTED at exact recorded/native/returned bit equality');await page.close();continue;
  }
  for(let i=0;i<clocks.length;i++)assert.equal(clocks[i].bits,result.output[i].bits,'full double bits before projection');
  if(!inverse&&['positive','selection'].includes(mode))assert.deepEqual(result.trace,result.output.flatMap(r=>r.kind==='mono'?['performance','Clock2']:['Date','getTime','Clock3']),'exact native read then Clock emission order');
  if(inverse!=='source')for(let i=0;i<clocks.length;i++)assert.equal(clocks[i].src,result.output[i].kind==='mono'?2:3);
  if(mode.startsWith('throw-')){await page.close();continue;}
  await page.close();
  const replayPage=await context.newPage();await replayPage.goto(url);await replayPage.addScriptTag({content:owner});
  const replayed=await replayPage.evaluate(({log,replay,boot,expected,inverse})=>{
   recordClockApi.installReplayRuntime(window,{log});globalThis.xrReadBootContext=boot;
   let raw=0;const sentinel=Error('raw replay clock'),D=Date,original=new D(0);
   const trap=()=>{raw++;throw sentinel;};performance.now=trap;Date.prototype.getTime=trap;
   window.Date=new Proxy(D,{construct(target,args,newTarget){if(args.length===0)return trap();return Reflect.construct(target,args,newTarget);},apply(){return trap();},get(target,key,receiver){if(key==='now')return trap;return Reflect.get(target,key,receiver);}});
   for(const invoke of [()=>performance.now(),()=>Date.now(),()=>original.getTime(),()=>new Date(),()=>Date()]){let caught;const n=raw;try{invoke();}catch(e){caught=e;}if(caught!==sentinel||raw!==n+1)throw Error('independent raw trap witness');}raw=0;
   (0,eval)(replay);const values=[];let error;
   for(let i=0;i<expected.length;i++){
    const row=expected[i],before=__ctReplay.status().cursor;
    try{values.push({kind:row.kind,value:row.kind==='mono'?(i===0?rcReplayMono():rcReplayNeMono()):JSON.parse(rcReplayWall()),before,after:__ctReplay.status().cursor});}
    catch(e){values.push({kind:row.kind,error:String(e),name:e.name,before,after:__ctReplay.status().cursor});if(inverse==='source'){error={name:e.name,kind:e.divergence?.kind,seq:String(e.divergence?.seq)};break;}}
   }
   globalThis.recordClockReplayRaw=()=>raw;
   return {values,error,raw,status:__ctReplay.status()};
  },{log:result.log,replay,boot,expected:result.output,inverse});
  assert.equal(replayed.raw,0);
  if(inverse==='source'){
   assert.equal(replayed.error.kind,'ArgumentMismatch');assert.equal(replayed.error.seq,clocks[0].seq);assert.equal(replayed.status.state,'diverged');console.log('wrong Clock source REJECTED at actual public Replay checked source');await replayPage.close();continue;
  }
  assert.equal(replayed.values[0].value,String(BigInt(Math.trunc(result.output[0].value*1e6))));
  assert.equal(replayed.values[1].value,String(BigInt(Math.trunc(result.output[1].value))),'unchanged NE integer projection');
  // Compare to the existing public wallNow, not a normalized substitute.
  const nativePage=await context.newPage();await nativePage.goto(url);await nativePage.addScriptTag({content:combined});
  const baseline=await nativePage.evaluate(epochs=>{
   const D=Date,gt=D.prototype.getTime,rows=[];
   for(const epoch of epochs){let constructs=0,reads=0;window.Date=class extends D{constructor(...args){if(args.length)super(...args);else{constructs++;super(epoch);}}getTime(){reads++;return gt.call(this);}};
    try{rows.push({value:JSON.parse(rcPublicWall()),constructs,reads});}catch(e){rows.push({error:String(e),name:e.name,constructs,reads});}}
   return rows;
  },result.wallValues);
  await nativePage.close();
  for(let i=0;i<baseline.length;i++){
   const actual=replayed.values[i+2],native=baseline[i];assert.equal(native.constructs,1);assert.equal(native.reads,1);
   if(native.error){assert.match(native.error,/RangeDefect/);assert.equal(actual.name,native.name);assert.equal(actual.error.split('\n')[0],native.error.split('\n')[0],'exact original error heading; native and Replay call stacks differ');}
   else assert.deepEqual(actual.value,native.value);
   assert.equal(BigInt(actual.after),BigInt(actual.before)+1n,'Clock consumed before stock projection failure');
  }
  await replayPage.waitForFunction(()=>['done','diverged'].includes(__ctReplay.status().state));
  const done=await replayPage.evaluate(()=>({status:__ctReplay.status(),raw:recordClockReplayRaw()}));
  assert.equal(done.status.state,'done');assert.equal(done.raw,0);assert.equal(done.status.tasks,0);
  assert.equal(result.records.filter(r=>r.record==='Checkpoint').length,1);assert.equal(result.records.at(-1).record,'End');
  console.log(mode+' actual Nim Record -> strict owner/public Replay DONE, exact double bits and stock Time failures');
  await replayPage.close();
 }
}finally{if(browser)await browser.close();await new Promise(resolve=>server.close(resolve));}
