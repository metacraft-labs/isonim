/** Actual RealClock callback instrumentation -> owner Recorder/strict codec ->
 * actual installed owner scheduler -> production private timer clock. Level0
 * dom-v1 proves library behavior only; no fake timer/task/cursor or privacy/
 * complete native Recording acceptance. Platform traps discriminate fallback.
 * The task-kind negative changes only the kind of a genuine captured Task,
 * preserving its identity/order and re-encoding through the actual strict codec.
 */
import assert from 'node:assert/strict';
import {readFileSync,writeFileSync} from 'node:fs';
import {basename} from 'node:path';
import {createRequire} from 'node:module';
import {createServer} from 'node:http';
const root=process.cwd(),artifact=process.env.CT_ARTIFACT;
assert(artifact,'actual owner artifact required');
const {chromium}=await import(root+'/tests/browser/node_modules/playwright/index.mjs');
const require=createRequire(artifact+'/packages/boundary-shim/package.json');
const esbuild=require('esbuild');
const owned=(await esbuild.build({stdin:{resolveDir:artifact,contents:`
import {Recorder,numberToBits} from '@codetracer/boundary-shim/dist/browser/recorder.js';
import {captureOriginals} from '@codetracer/boundary-shim/dist/browser/originals.js';
import {readEnvironment} from '@codetracer/boundary-shim/dist/browser/install.js';
import {domV1Hash} from '@codetracer/boundary-shim/dist/browser/dom-v1.js';
import {encodeLog,decodeRecord} from '@codetracer/boundary-format';
import {installReplayRuntime} from '@codetracer/boundary-replay/dist/browser/runtime.js';
globalThis.startTimerOwner=()=>{const orig=captureOriginals(window),frames=[];
 const rec=new Recorder({checkpointScheme:'dom-v1',checkpointHash:()=>domV1Hash(document),sink:{append(f){frames.push(f)},end(){},halt(){}}});
 rec.start({vocab:1,protocol_level:0,recorder_id:'native-callback-observation',framework:'',build_hash:'a'.repeat(64),session_id:'1'.repeat(32),prev_session:'',capabilities:'[]'},readEnvironment(window,orig));
 globalThis.timerRecorder=rec;globalThis.timerClock=value=>rec.guard(()=>rec.emit('Clock',{src:2,bits:numberToBits(value)}));
 globalThis.stopTimerOwner=(negative)=>{rec.end(2);const records=frames.map(f=>decodeRecord(f.subarray(4))),originalTask=negative==='task-kind'?{...records.find(r=>r.record==='Task')}:undefined;
 if(negative==='task-kind'){const task=records.find(r=>r.record==='Task');if(!task||task.kind!==1)throw Error('native timeout Task required');task.kind=2;}
 const log=encodeLog(records);let raw='';for(const b of log)raw+=String.fromCharCode(b);const serial=value=>JSON.parse(JSON.stringify(value,(_,v)=>typeof v==='bigint'?String(v):v));return {log:btoa(raw),records:records.map(serial),originalTask:originalTask&&serial(originalTask)};};};
globalThis.installTimerOwner=log=>installReplayRuntime(window,{log});
`},bundle:true,platform:'browser',format:'iife',write:false})).outputFiles[0].text;
const program=readFileSync(process.env.REPLAY_TIMERS_BUNDLE||root+'/build/replay-timers.js','utf8');
const nativeProgram=readFileSync(process.env.REPLAY_TIMERS_NATIVE_BUNDLE||root+'/build/replay-timers.js','utf8');
const inverse=process.env.REPLAY_TIMERS_INVERSE||'';
const receipts=[];
const server=createServer((req,res)=>res.end('<!doctype html><main>Timer observations</main>'));
await new Promise(r=>server.listen(0,'127.0.0.1',r));
const browser=await chromium.launch({executablePath:process.env.PLAYWRIGHT_CHROMIUM_EXECUTABLE});
const traces={positive:['start','registered','zero','micro','fractional','tick1','tick2'],nested:['outer','micro','nested'],error:['error','after-error'],premature:['dispose-refused'],two:['first','second'],pending:[],'cancel-mismatch':['required'],'task-kind':['required'],'after-fire':['fired'],'ne-cancel':['remaining'],'ne-every':['ne1','ne2'],'switch-nil':['owned-after-nil'],'switch-test':['owned-after-test'],'switch-real':['owned-after-real'],'switch-custom':['owned-after-custom'],priority:['fake','explicit']};
const modes=inverse==='counter'?['two']:inverse==='interval'?['positive']:inverse==='dispatch'?['positive']:inverse==='raw'?['pending']:Object.keys(traces);
const early=process.env.REPLAY_TIMERS_EARLY==='1';
const newPage=async(content)=>{const p=await browser.newPage();await p.goto('http://127.0.0.1:'+server.address().port);await p.addScriptTag({content:owned});if(content)await p.addScriptTag({content});return p;};
try{
 for(const mode of modes){
  const native=await newPage(nativeProgram);
  // Native errors are intentionally observed and asserted below, not hidden.
  const nativeErrors=[];native.on('pageerror',e=>nativeErrors.push(e.message));
  const context=await native.evaluate(()=>JSON.parse(timerBoot()));
  const initial=await native.evaluate(mode=>{timerTrace=[];startTimerOwner();timerSelectRecord();const control=JSON.parse(timerNeutral());timerStart(mode);return {control,trace:timerTrace.slice()};},mode);
  if(mode==='positive')assert.deepEqual(initial.trace,['start','registered']);
  if(traces[mode].length)await native.waitForFunction(n=>timerTrace.length===n,traces[mode].length);
  if(mode==='positive'||mode==='ne-cancel'){
   // A real platform canary after the cancelled100ms deadline makes absence
   // observable. Merely finishing the shorter callbacks would be vacuous.
   await native.evaluate(()=>new Promise(resolve=>setTimeout(resolve,120)));
  }
  const observed=await native.evaluate(mode=>({trace:timerTrace.slice(),dispatch:JSON.parse(timerDispatches()),...stopTimerOwner(mode)}),mode);
  assert.deepEqual(observed.trace,traces[mode],mode+' native trace');
  if(mode==='error')assert.equal(nativeErrors.length,1,'actual native callback error');
  else assert.deepEqual(nativeErrors,[]);
  const regs=observed.records.filter(r=>r.record==='TaskReg'),tasks=observed.records.filter(r=>r.record==='Task');
  if(mode==='positive'){assert.deepEqual(regs.map(r=>r.delay_ms),[100,0,3,4,4]);assert.equal(tasks.length,4);assert(regs.every(r=>r.kind===1));assert.equal(new Set(regs.map(r=>r.task_id)).size,5);}
  await native.close();
  const page=await newPage('');
  const setup=await page.evaluate(({context,observed,mode,inverse,program})=>{
   timerTrace=[];timerContext=context;globalThis.xrReadBootContext=context;installTimerOwner(observed.log);(0,eval)(program);timerSelectReplay();
   const nativeOff=__ctReplay.offTask;offCalls=[];__ctReplay.offTask=function(id){offCalls.push(String(id));return nativeOff.call(this,id);};
   rawTimers=0;for(const name of ['setTimeout','setInterval','clearTimeout','clearInterval'])window[name]=()=>{rawTimers++;throw Error('RAW timer');};
   performance.now=()=>{throw Error('RAW clock');};
   const control=JSON.parse(timerNeutral());
   let premature=false;try{timerDispose();}catch(e){premature=true;}if(!premature)throw Error('premature disposal accepted');
   const before=__ctReplay.peek();let thrown;
   try{timerStart(mode);}catch(e){const before=__ctReplay.peek();let direct;try{__ctReplay.next('TaskReg');}catch(other){direct=other;}thrown={text:String(e),divergence:e.divergence,preservedClass:e.constructor===direct?.constructor,payload:e.divergence===direct?.divergence&&e.divergence===__ctReplay.failed,cursor:before.seq===__ctReplay.peek().seq};}
   if(mode==='cancel-mismatch')timerCancelRetained();
   return {control,before,after:__ctReplay.peek(),thrown,rawTimers,trace:timerTrace.slice(),handles:globalThis.timerHandles};
  },{context,observed,mode,inverse,program});
  assert.deepEqual(setup.control,initial.control,'neutral actual clock/context');
  receipts.push({mode,context,native:observed,setup});
  if(inverse==='raw'){
   assert.equal(setup.rawTimers,1);assert.equal(setup.before.kind,'TaskReg');assert.equal(setup.after.seq,setup.before.seq);
   // RealClock's raw sleep uses a Promise executor: the trap rejects that
   // Promise, rather than synchronously throwing from the registration call.
   assert.equal(setup.thrown,undefined);
   console.log('raw timer restoration REJECTED: raw effect AND pending TaskReg; neutral clock/context PASS');await page.close();continue;
  }
  if(inverse==='counter'){
   assert.equal(setup.rawTimers,0);assert.equal(setup.thrown.divergence.kind,'ArgumentMismatch');assert.match(setup.thrown.divergence.detail,/task_id/);assert(setup.thrown.preservedClass&&setup.thrown.payload&&setup.thrown.cursor);assert.equal(setup.thrown.divergence.seq,regs[1].seq);
   console.log('counter reset REJECTED at actual second backend TaskReg; neutral clock/context PASS');await page.close();continue;
  }
  if(inverse==='interval'){
   assert.equal(setup.rawTimers,0);assert.equal(setup.thrown.divergence.kind,'ArgumentMismatch');assert.match(setup.thrown.divergence.detail,/kind/);assert(setup.thrown.preservedClass&&setup.thrown.payload&&setup.thrown.cursor);assert.equal(setup.thrown.divergence.seq,regs.find(r=>r.delay_ms===4).seq);
   console.log('interval-kind restoration REJECTED at actual TaskReg; neutral clock/context PASS');await page.close();continue;
  }
  assert.equal(setup.thrown,undefined,mode+' registration');
  if(mode==='two'){assert.deepEqual(setup.handles,{first:1,second:1});assert.deepEqual(regs.map(r=>r.task_id),['1','2'],'public/clock handles differ from shared owner identity');}
  if(mode==='positive')assert.deepEqual(setup.trace,['start','registered']);
  await page.waitForFunction(()=>['done','diverged'].includes(__ctReplay.status().state));
  const outcome=await page.evaluate(()=>({trace:timerTrace.slice(),dispatch:JSON.parse(timerDispatches()),rawTimers,offCalls:offCalls.slice(),status:__ctReplay.status()}));
  receipts.at(-1).outcome=outcome;
  assert.equal(outcome.rawTimers,0);
  if(inverse==='dispatch'){
   assert.deepEqual(outcome.trace,observed.trace);assert.equal(outcome.status.state,'done');assert.equal(outcome.status.checkpoints,1);assert.equal(outcome.offCalls.length,1,'only explicit cancellation survived; four fired callbacks leaked owner handlers');
   console.log('missing dispatch unregister REJECTED: four actual owner callbacks retained; native trace/checkpoint and neutral clock/context PASS');await page.close();continue;
  }
  if(mode==='cancel-mismatch'||mode==='task-kind'){
   assert.equal(outcome.status.state,'diverged');assert.equal(outcome.status.divergence.kind,'TaskOrderMismatch');assert.deepEqual(outcome.trace,[]);
   const latched=await page.evaluate(()=>{const before=__ctReplay.peek();let a,b;try{__ctReplay.next('Clock',{src:2});}catch(e){a=e;}try{__ctReplay.next('Clock',{src:2});}catch(e){b=e;}return {preservedClass:a.constructor===b.constructor,payload:a.divergence===b.divergence,kind:a.divergence.kind,before,after:__ctReplay.peek()};});
   assert(latched.preservedClass&&latched.payload);assert.equal(latched.kind,'TaskOrderMismatch');assert.equal(latched.before.seq,latched.after.seq);
   if(mode==='task-kind'){assert.deepEqual({...tasks[0],kind:observed.originalTask.kind},observed.originalTask);assert.equal(outcome.status.tasks,0);assert.equal(latched.before.seq,tasks[0].seq);assert.match(outcome.status.divergence.detail,/kind 2.*kind 1/);}
  }else{
   assert.equal(outcome.status.state,'done',JSON.stringify(outcome));assert.deepEqual(outcome.trace,observed.trace);assert.deepEqual(outcome.dispatch,observed.dispatch);assert.equal(outcome.status.tasks,tasks.length);assert.equal(outcome.status.checkpoints,1);
   if(mode==='error')assert.equal(outcome.status.pageErrors.length,1);else assert.deepEqual(outcome.status.pageErrors,[]);
  }
  assert.equal(outcome.offCalls.length,regs.length-(mode==='pending'||mode==='task-kind'?1:0),'every fired/cancelled callback unregisters exactly once');
  const expectedOff=mode==='cancel-mismatch'?[regs[0].task_id]:mode==='task-kind'?[]:[
   ...(mode==='positive'||mode==='ne-cancel'?[regs[0].task_id]:[]),
   ...tasks.map(task=>task.task_id),
  ];
  assert.deepEqual(outcome.offCalls,expectedOff,'unregisters the exact owning task IDs in actual native order');
  const cleanup=await page.evaluate(mode=>{const before=offCalls.length;timerDispose();if(mode==='two')timerDisposeOther();const after=offCalls.length;timerDispose();timerUnknownCancel();timerCancelRetained();let thrown;try{timerScheduleDisposed();}catch(e){thrown=String(e);}return {before,after,final:offCalls.length,thrown};},mode);
  receipts.at(-1).cleanup=cleanup;
  assert.equal(cleanup.after,cleanup.final,'idempotent disposal/cancel');assert.match(cleanup.thrown,/disposed/);
  if(mode==='pending'||mode==='task-kind'){assert.equal(cleanup.after-cleanup.before,1,'pending handler explicitly released after actual owner done/diverged');assert.equal(outcome.offCalls.length,0);}
  console.log(mode+': actual native/owner replay trace, dispatch, lifecycle PASS');await page.close();
 }
 if(!inverse){
  for(const value of [-2,0,0.25,2.25,2147483647,2147483648,NaN,Infinity,-Infinity]){
   const native=await newPage(nativeProgram);
   const observed=await native.evaluate(value=>{timerTrace=[];const context=JSON.parse(timerBoot());startTimerOwner();timerSelectRecord();const control=JSON.parse(timerNeutral()),answer=timerDelay(value);return {context,control,answer,...stopTimerOwner()};},value);
   await native.close();
   const page=await newPage('');
   const outcome=await page.evaluate(({value,observed,program})=>{timerTrace=[];timerContext=observed.context;globalThis.xrReadBootContext=observed.context;installTimerOwner(observed.log);(0,eval)(program);timerSelectReplay();const control=JSON.parse(timerNeutral());let raw=0;window.setTimeout=()=>{raw++;throw Error('RAW timer');};let answer;try{answer=timerDelay(value);}catch(e){answer={owner:e.divergence};}return {answer,control,raw,peek:__ctReplay.peek()};},{value,observed,program});
   assert.deepEqual(outcome.control,observed.control);assert.equal(outcome.raw,0);
   receipts.push({delay:String(value),native:observed,outcome});
   assert.equal(outcome.answer,observed.answer,'delay conversion parity '+String(value));
   assert.equal(outcome.peek.kind,'Checkpoint','conversion outcome consumes exactly actual registration, or no registration on errors');
   await page.waitForFunction(()=>__ctReplay.status().state==='done');
   await page.evaluate(()=>timerDispose());await page.close();
   console.log('delay '+String(value)+': exact native conversion/error parity PASS');
  }
  if(!early)for(const method of ['registerTask','onTask','offTask','status','bad-context']){
   const native=await newPage(nativeProgram);const captured=await native.evaluate(()=>{timerTrace=[];const context=JSON.parse(timerBoot());startTimerOwner();timerSelectRecord();timerNeutral();timerStart('pending');return {context,...stopTimerOwner()};});await native.close();
   const page=await newPage('');
   const failure=await page.evaluate(({captured,method,program})=>{timerContext=method==='bad-context'?[]:captured.context;installTimerOwner(captured.log);(0,eval)(program);if(method!=='bad-context')__ctReplay[method]=undefined;const before=__ctReplay.peek();let error;try{timerSelectReplay();}catch(e){error=String(e);}return {error,before,after:__ctReplay.peek(),guard:Object.hasOwn(globalThis,'__isonimInternalReadReplaySelected')};},{captured,method,program});
   assert.match(failure.error,method==='bad-context'?/genuine boot context/:new RegExp('owner '+method));assert.equal(failure.before.seq,failure.after.seq);assert.equal(failure.guard,false);await page.close();
   console.log('constructor '+method+': fails before state/cursor mutation PASS');
  }
 }
}finally{writeFileSync(root+'/build/'+basename(process.env.REPLAY_TIMERS_BUNDLE||'replay-timers.js')+'.receipt.json',JSON.stringify({inverse,early,receipts},(_,v)=>typeof v==='bigint'?String(v):v,2));await browser.close();await new Promise(r=>server.close(r));}
