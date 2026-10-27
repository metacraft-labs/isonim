/** Actual original browser frame delivery -> actual owner Recorder/strict codec
 * -> actual installed scheduling/checkpoint loop -> private Nim frame backend.
 * Native rAF instrumentation observes the genuine delivered argument, not a
 * fabricated timestamp or generic shim. Existing RealClock callback observation
 * supplies mixed timers with the same Recorder. One Nim program per realm.
 * Level0/dom-v1 is bounded library proof, not privacy/full Recording acceptance.
 * The task-kind negative changes only one genuine Task.kind then uses the codec.
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
globalThis.startFrameOwner=()=>{const orig=captureOriginals(window),frames=[];
 const rec=new Recorder({checkpointScheme:'dom-v1',checkpointHash:()=>domV1Hash(document),sink:{append(f){frames.push(f)},end(){},halt(){}}});
 rec.start({vocab:1,protocol_level:0,recorder_id:'native-frame-observation',framework:'',build_hash:'a'.repeat(64),session_id:'1'.repeat(32),prev_session:'',capabilities:'[]'},readEnvironment(window,orig));
 globalThis.timerRecorder=rec;globalThis.timerClock=value=>rec.guard(()=>rec.emit('Clock',{src:2,bits:numberToBits(value)}));
 globalThis.nativeStamps=[];globalThis.frameValues=[];
 globalThis.frameValue=value=>frameValues.push(String(numberToBits(value)));
 globalThis.frameCanary=()=>new Promise(resolve=>orig.requestAnimationFrame.call(window,()=>orig.requestAnimationFrame.call(window,resolve)));
 window.requestAnimationFrame=function(callback){const task=rec.nextTaskId();const handle=orig.requestAnimationFrame.call(window,ts=>{rec.guard(()=>{rec.task(task,3);rec.emit('Clock',{src:4,bits:numberToBits(ts)});nativeStamps.push({task:String(task),bits:String(numberToBits(ts)),timestamp:ts});});callback(ts);});rec.guard(()=>rec.emit('TaskReg',{task_id:task,kind:3,delay_ms:0}));return handle;};
 globalThis.stopFrameOwner=negative=>{rec.end(2);const records=frames.map(f=>decodeRecord(f.subarray(4))),originalTask=negative==='task-kind'?{...records.find(r=>r.record==='Task')}:undefined;
 if(negative==='task-kind'){const task=records.find(r=>r.record==='Task');if(!task||task.kind!==3)throw Error('native frame Task required');task.kind=1;}
 const log=encodeLog(records);let raw='';for(const b of log)raw+=String.fromCharCode(b);const serial=value=>JSON.parse(JSON.stringify(value,(_,v)=>typeof v==='bigint'?String(v):v));return {log:btoa(raw),records:records.map(serial),originalTask:originalTask&&serial(originalTask)};};};
globalThis.installFrameOwner=log=>{globalThis.frameValues=[];globalThis.frameValue=value=>frameValues.push(String(numberToBits(value)));return installReplayRuntime(window,{log});};
`},bundle:true,platform:'browser',format:'iife',write:false})).outputFiles[0].text;
const program=readFileSync(process.env.REPLAY_FRAMES_BUNDLE||root+'/build/replay-frames.js','utf8');
const nativeProgram=readFileSync(process.env.REPLAY_FRAMES_NATIVE_BUNDLE||root+'/build/replay-frames-native.js','utf8');
const inverse=process.env.REPLAY_FRAMES_INVERSE||'';
const early=process.env.REPLAY_FRAMES_EARLY==='1';
const receipts=[];
const server=createServer((req,res)=>res.end('<!doctype html><main>Timer observations</main>'));
await new Promise(r=>server.listen(0,'127.0.0.1',r));
const browser=await chromium.launch({executablePath:process.env.PLAYWRIGHT_CHROMIUM_EXECUTABLE});
const traces={public:['public'],positive:['registered','first','micro','second','nested'],'same-frame-cancel':['cancel-inside'],error:['error','after-error'],premature:['dispose-refused','after-refused'],mixed:null,'timer-first':null,two:null,pending:[],'cancel-mismatch':['required'],'task-kind':['required'],'after-fire':['fired'],'switch-nil':['owned-after-switch'],'switch-test':['owned-after-switch'],'switch-real':['owned-after-switch'],'switch-custom':['owned-after-switch']};
const modeList=inverse==='raw'||inverse==='dispose'||inverse==='registration'?['pending']:inverse==='namespace'?['two']:inverse?['positive']:Object.keys(traces);
const newPage=async content=>{const p=await browser.newPage();await p.goto('http://127.0.0.1:'+server.address().port);await p.addScriptTag({content:owned});if(content)await p.addScriptTag({content});return p;};
try{
 for(const mode of modeList){
  const native=await newPage(nativeProgram),nativeErrors=[];
  native.on('pageerror',e=>nativeErrors.push(e.message));
  const context=await native.evaluate(()=>JSON.parse(timerBoot()));
  const initial=await native.evaluate(mode=>{timerTrace=[];startFrameOwner();timerSelectRecord();const control=JSON.parse(timerNeutral());frameStart(mode);const pending=mode==='pending'?{trace:timerTrace.slice(),dispatch:JSON.parse(timerDispatches()),maps:JSON.parse(frameMaps()),stamps:nativeStamps.slice(),values:frameValues.slice(),...stopFrameOwner(mode)}:undefined;return {control,trace:timerTrace.slice(),pending};},mode);
  if(mode==='positive')assert.deepEqual(initial.trace,['registered']);
  const expectedLength=traces[mode]?.length??(mode==='two'?3:2);
  if(expectedLength)await native.waitForFunction(n=>timerTrace.length===n,expectedLength);
  if(mode==='positive'||mode==='same-frame-cancel')await native.evaluate(()=>frameCanary());
  const observed=initial.pending??await native.evaluate(mode=>({trace:timerTrace.slice(),dispatch:JSON.parse(timerDispatches()),maps:JSON.parse(frameMaps()),stamps:nativeStamps.slice(),values:frameValues.slice(),...stopFrameOwner(mode)}),mode);
  if(traces[mode])assert.deepEqual(observed.trace,traces[mode],mode+' native trace');
  else assert.deepEqual([...observed.trace].sort(),mode==='two'?['first','second','timer']:['first','timer']);
  if(mode==='error'){assert.equal(nativeErrors.length,1);assert.match(nativeErrors[0],/frame callback/);}else assert.deepEqual(nativeErrors,[]);
  const regs=observed.records.filter(r=>r.record==='TaskReg'),tasks=observed.records.filter(r=>r.record==='Task'),clocks=observed.records.filter(r=>r.record==='Clock'&&r.src===4);
  assert.deepEqual(observed.values,mode==='public'?[]:observed.stamps.map(s=>s.bits),'private native observation preserves exact platform delivery bits; public facade erases it');
  assert.deepEqual(clocks.map(c=>String(c.bits)),observed.stamps.map(s=>s.bits),'recorded Clock4 bits equal original/private native delivery');
  if(mode==='positive'){assert.equal(regs.length,5);assert.equal(tasks.length,3);assert.equal(clocks.length,3);assert(regs.every(r=>r.kind===3&&r.delay_ms===0));assert.equal(observed.stamps[0].bits,observed.stamps[1].bits,'same frame original timestamps');assert.notEqual(observed.stamps[1].bits,observed.stamps[2].bits,'nested frame original timestamp');}
  if(['mixed','timer-first','two'].includes(mode)){assert(regs.some(r=>r.kind===1));assert(regs.some(r=>r.kind===3));assert.deepEqual(regs.map(r=>r.task_id),regs.map((_,i)=>String(i+1)));assert.deepEqual(regs.map(r=>r.kind),mode==='timer-first'?[1,3]:mode==='two'?[3,1,3]:[3,1]);}
  await native.close();
  const page=await newPage('');
  const setup=await page.evaluate(({context,observed,mode,program})=>{
   timerTrace=[];timerContext=context;globalThis.xrReadBootContext=context;installFrameOwner(observed.log);(0,eval)(program);timerSelectReplay();
   const nativeOff=__ctReplay.offTask;offCalls=[];__ctReplay.offTask=function(id){offCalls.push(String(id));return nativeOff.call(this,id);};
   rawFrames=0;rawTimers=0;rawClocks=0;for(const name of ['requestAnimationFrame','cancelAnimationFrame'])window[name]=()=>{rawFrames++;throw Error('RAW frame');};
   for(const name of ['setTimeout','setInterval','clearTimeout','clearInterval'])window[name]=()=>{rawTimers++;throw Error('RAW timer');};
   performance.now=()=>{rawClocks++;throw Error('RAW clock');};
   // Install after actual owner capture. Preserve explicit date construction
   // and prototype identity; all THREE fresh-clock entry points fail closed.
   const OriginalDate=window.Date;
   const rejectDate=()=>{rawClocks++;throw Error('RAW clock');};
   window.Date=new Proxy(OriginalDate,{
    apply(){return rejectDate();},
    construct(target,args,newTarget){if(args.length===0)return rejectDate();return Reflect.construct(target,args,newTarget);},
    get(target,key,receiver){return key==='now'?rejectDate:Reflect.get(target,key,receiver);},
   });
   const explicitDate=new Date(0);
   if(!(explicitDate instanceof OriginalDate)||explicitDate.getTime()!==0||Date.prototype!==OriginalDate.prototype)throw Error('explicit date/prototype control failed');
   let clockTrapWitnesses=0;
   for(const [name,invoke] of [['performance.now',()=>performance.now()],['Date.now',()=>Date.now()],['new Date',()=>new Date()],['Date()',()=>Date()]]){
    const before=rawClocks;let error;try{invoke();}catch(e){error=e;}
    if(error?.message!=='RAW clock'||rawClocks!==before+1)throw Error(name+' clock trap witness failed: expected RAW clock and one counted observation');
    clockTrapWitnesses++;
   }
   // The witness calls above are driver controls, not framework observations.
   // From here every fresh framework/runtime clock read remains counted.
   if(clockTrapWitnesses!==4||rawClocks!==4)throw Error('unexpected setup clock observation');rawClocks=0;
   const control=JSON.parse(timerNeutral());let premature=false;try{timerDispose();}catch(e){premature=true;}if(!premature)throw Error('premature disposal accepted');
   const before=__ctReplay.peek();let thrown;
   try{frameStart(mode);}catch(e){let direct;const latched=__ctReplay.peek();if(e.divergence)try{__ctReplay.next('TaskReg');}catch(other){direct=other;}thrown={text:String(e),divergence:e.divergence,preservedClass:e.constructor===direct?.constructor,payload:e.divergence===direct?.divergence&&e.divergence===__ctReplay.failed,cursor:latched.seq===__ctReplay.peek().seq};}
   if(mode==='cancel-mismatch')timerCancelRetained();
   return {control,before,after:__ctReplay.peek(),thrown,rawFrames,rawTimers,rawClocks,clockTrapWitnesses,trace:timerTrace.slice(),handles:globalThis.timerHandles};
  },{context,observed,mode,program});
  assert.equal(setup.clockTrapWitnesses,4,'all four performance/Date clock traps are live with explicit-date/prototype control');
  assert.deepEqual(setup.control,initial.control,'neutral actual Clock2/context');receipts.push({mode,native:observed,setup});
  if(inverse==='raw'){
   assert.equal(setup.rawFrames,1);assert.equal(setup.before.kind,'TaskReg');assert.equal(setup.after.seq,setup.before.seq);assert.match(setup.thrown.text,/RAW frame/);assert.equal(setup.rawTimers,0);assert.equal(setup.rawClocks,0);
   console.log('raw frame restoration REJECTED: actual raw effect AND pending registration; neutral reads/context PASS');await page.close();continue;
  }
  if(inverse==='registration'){
   assert.equal(setup.rawFrames+setup.rawTimers+setup.rawClocks,0);assert.equal(setup.thrown.divergence.kind,'ArgumentMismatch');assert.match(setup.thrown.divergence.detail,/delay_ms/);assert(setup.thrown.preservedClass&&setup.thrown.payload&&setup.thrown.cursor);assert.equal(setup.thrown.divergence.seq,regs[0].seq);assert.equal(setup.after.seq,setup.before.seq);
   console.log('wrong frame registration delay REJECTED at genuine TaskReg; original class/shared latch/cursor PASS');await page.close();continue;
  }
  if(inverse==='namespace'){
   assert.equal(setup.rawFrames+setup.rawTimers+setup.rawClocks,0);assert.equal(setup.thrown.divergence.kind,'ArgumentMismatch');assert.match(setup.thrown.divergence.detail,/task_id/);assert(setup.thrown.preservedClass&&setup.thrown.payload&&setup.thrown.cursor);assert.equal(setup.thrown.divergence.seq,regs[2].seq);
   console.log('split frame namespace REJECTED: exact second backend mixed TaskReg ID; neutral reads/context PASS');await page.close();continue;
  }
  assert.equal(setup.thrown,undefined,mode+' registration');
  if(mode==='two')assert.deepEqual(setup.handles,{first:1,second:1},'colliding public handles do not share task ID');
  await page.waitForFunction(()=>['done','diverged'].includes(__ctReplay.status().state));
  const outcome=await page.evaluate(()=>({trace:timerTrace.slice(),dispatch:JSON.parse(timerDispatches()),values:frameValues.slice(),maps:JSON.parse(frameMaps()),rawFrames,rawTimers,rawClocks,offCalls:offCalls.slice(),status:__ctReplay.status()}));receipts.at(-1).outcome=outcome;
  assert.equal(outcome.rawFrames+outcome.rawTimers+outcome.rawClocks,0);
  if(inverse==='clock'||mode==='cancel-mismatch'||mode==='task-kind'){
   assert.equal(outcome.status.state,'diverged');const expected=inverse==='clock'?'ArgumentMismatch':'TaskOrderMismatch';assert.equal(outcome.status.divergence.kind,expected);
   const latched=await page.evaluate(()=>{const before=__ctReplay.peek();let a,b;try{__ctReplay.next('Clock',{src:2});}catch(e){a=e;}try{__ctReplay.next('Clock',{src:2});}catch(e){b=e;}return {before,after:__ctReplay.peek(),sameClass:a.constructor===b.constructor,shared:a.divergence===b.divergence&&a.divergence===__ctReplay.failed};});
   assert(latched.sameClass&&latched.shared);assert.equal(latched.before.seq,latched.after.seq);
   if(inverse==='clock'){assert.equal(outcome.status.divergence.seq,clocks[0].seq);assert.equal(latched.before.seq,clocks[0].seq);assert.match(outcome.status.divergence.detail,/src/);assert.deepEqual(outcome.trace,['registered']);assert.equal(outcome.status.tasks,1);assert.equal(outcome.dispatch.selected,'0');assert.deepEqual(outcome.offCalls,[regs[0].task_id,tasks[0].task_id]);assert.deepEqual(outcome.maps,{selected:1,other:0});console.log('wrong frame clock source REJECTED at genuine Clock4; original class/shared latch/cursor PASS');}
   else{assert.deepEqual(outcome.trace,[]);assert.equal(latched.before.seq,tasks[0].seq);assert.equal(outcome.status.tasks,0);if(mode==='task-kind'){assert.deepEqual({...tasks[0],kind:observed.originalTask.kind},observed.originalTask);assert.match(outcome.status.divergence.detail,/kind 1.*kind 3/);}}
  }else{
   assert.equal(outcome.status.state,'done',JSON.stringify(outcome));assert.deepEqual(outcome.trace,observed.trace);assert.deepEqual(outcome.dispatch,observed.dispatch);assert.equal(outcome.status.tasks,tasks.length);assert.equal(outcome.status.checkpoints,1);
   if(mode==='error'){assert.equal(outcome.status.pageErrors.length,1);assert.match(outcome.status.pageErrors[0].message??String(outcome.status.pageErrors[0]),/frame callback/);}else assert.deepEqual(outcome.status.pageErrors,[]);
   if(inverse==='bits'){assert.equal(outcome.values.length,observed.values.length);assert(outcome.values.length>0);for(let i=0;i<outcome.values.length;i++)assert.equal(BigInt(outcome.values[i])^BigInt(observed.values[i]),1n);console.log('one-bit frame timestamp corruption REJECTED by exact private observation; public trace/dispatch/checkpoint PASS');}
   else assert.deepEqual(outcome.values,observed.values,'exact PRIVATE returned Clock4 bits, not merely public noarg behavior');
  }
  if(inverse==='dispatch'){
   assert.equal(outcome.offCalls.length,2,'only two explicit cancellations; three fired handlers retained');assert.deepEqual(outcome.maps,{selected:0,other:0});console.log('missing frame dispatch unregister REJECTED: three actual owner handlers retained; private bits/public trace/checkpoint PASS');await page.close();continue;
  }
  if(!inverse||inverse==='bits'){
   assert.equal(outcome.offCalls.length,regs.length-(mode==='pending'||mode==='task-kind'?1:0));
   const expectedOff=mode==='positive'?[regs[0].task_id,tasks[0].task_id,regs[3].task_id,tasks[1].task_id,tasks[2].task_id]:mode==='same-frame-cancel'?[tasks[0].task_id,regs[1].task_id]:mode==='cancel-mismatch'?[regs[0].task_id]:mode==='task-kind'?[]:tasks.map(t=>t.task_id);
   assert.deepEqual(outcome.offCalls,expectedOff,'each exact owning ID unregisters once in native dispatch/cancellation order');
   if(mode!=='pending'&&mode!=='task-kind')assert.deepEqual(outcome.maps,{selected:0,other:0},'delivered/cancelled map entries removed');
  }
  const cleanup=await page.evaluate(mode=>{timerReselect();const before=offCalls.length;timerDispose();if(mode==='two')timerDisposeOther();const after=offCalls.length;const maps=JSON.parse(frameMaps());timerDispose();timerUnknownCancel();timerCancelRetained();let thrown;try{frameDisposed();}catch(e){thrown=String(e);}return {before,after,final:offCalls.length,maps,thrown};},mode);receipts.at(-1).cleanup=cleanup;
  if(inverse==='dispose'){
   assert.equal(outcome.maps.selected,1);assert.equal(cleanup.after-cleanup.before,0);assert.equal(cleanup.maps.selected,1);console.log('missing frame disposal REJECTED: actual pending owner handler AND frame cancellation map retained');await page.close();continue;
  }
  assert.equal(cleanup.after,cleanup.final,'dispose/cancel idempotence');assert.deepEqual(cleanup.maps,{selected:0,other:0});assert.match(cleanup.thrown,/disposed/);
  if(mode==='pending'||mode==='task-kind'||inverse==='clock')assert.equal(cleanup.after-cleanup.before,1,'pending owned handler released after actual done/diverged');
  console.log(mode+': native/owned replay frame bits, dispatch, task identities and cleanup PASS');await page.close();
 }
}finally{writeFileSync(root+'/build/'+basename(process.env.REPLAY_FRAMES_BUNDLE||'replay-frames.js')+'.receipt.json',JSON.stringify({inverse,early,receipts},(_,v)=>typeof v==='bigint'?String(v):v,2));await browser.close();await new Promise(r=>server.close(r));}
