/** Actual synchronous scheduler queue and original browser frame delivery -> actual owner Recorder/strict codec
 * -> actual installed scheduling/checkpoint loop -> private Nim frame backend.
 * Native rAF instrumentation observes the genuine delivered argument, not a
 * fabricated timestamp or generic shim. Existing RealClock callback observation
 * supplies mixed timers with the same Recorder. One Nim program per realm.
 * Level0/dom-v1 is bounded library proof, not privacy/full Recording acceptance.
 * The wrong-source control changes one genuine scheduler Clock.src, then uses
 * the owner codec; source inverses compile the actual queue implementation.
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
 if(negative==='clock-source'){const c=records.find((r,i)=>r.record==='Clock'&&r.src===2&&i>2);if(!c)throw Error('actual scheduler Clock required');c.src=1;}
 const log=encodeLog(records);let raw='';for(const b of log)raw+=String.fromCharCode(b);const serial=value=>JSON.parse(JSON.stringify(value,(_,v)=>typeof v==='bigint'?String(v):v));return {log:btoa(raw),records:records.map(serial),originalTask:originalTask&&serial(originalTask)};};};
globalThis.installFrameOwner=log=>{globalThis.frameValues=[];globalThis.frameValue=value=>frameValues.push(String(numberToBits(value)));return installReplayRuntime(window,{log});};
`},bundle:true,platform:'browser',format:'iife',write:false})).outputFiles[0].text;
const program=readFileSync(process.env.REPLAY_SCHEDULER_BUNDLE||root+'/build/replay-scheduler.js','utf8');
const nativeProgram=readFileSync(process.env.REPLAY_SCHEDULER_NATIVE||root+'/build/replay-scheduler-native.js','utf8');
const inverse=process.env.REPLAY_SCHEDULER_INVERSE||'';
const receipts=[];
const server=createServer((req,res)=>res.end('<!doctype html><main>Timer observations</main>'));
await new Promise(r=>server.listen(0,'127.0.0.1',r));
const browser=await chromium.launch({executablePath:process.env.PLAYWRIGHT_CHROMIUM_EXECUTABLE});
const allModes=['basic','nested','nested-reorder','error','error-owned','timer','frame','two','switch','priority','hooks','clock-source'];
const modes=inverse==='sort'?['priority']:inverse?['basic']:allModes;
const asyncModes=new Set(['timer','frame','error-owned']);
const clocks={basic:4,nested:4,'nested-reorder':4,error:4,'error-owned':4,timer:3,frame:3,two:3,switch:4,priority:1,hooks:3,'clock-source':4};
const expected={'nested-reorder':['outer:false','outer:false','later:false'],nested:['outer:false','after-reentry','nested:false'],error:['prior:false','throw:false','prior:false','throw:false','after:false'],'error-owned':['prior:false','throw:false','prior:false','throw:false','after:false'],timer:['before-flush','inside:false','micro'],frame:['before-flush','inside:false','micro'],switch:['retained:false','nil:false','test-early:false','test-late:false','custom:false','resumed:false'],priority:['early:false','late:false'],hooks:['fake-selection:false','hook-selection:false']};
function expectedOrder(entries){return entries.filter(e=>!e.cancelled).sort((a,b)=>Number(a.expiration)-Number(b.expiration)).map(e=>e.name+':false');}
const pageFor=async content=>{const p=await browser.newPage();await p.goto('http://127.0.0.1:'+server.address().port);await p.addScriptTag({content:owned});if(content)await p.addScriptTag({content});return p;};
try{
 for(const requested of modes){
  const mode=requested==='clock-source'?'basic':requested;
  const native=await pageFor(nativeProgram),nativeErrors=[];
  native.on('pageerror',e=>nativeErrors.push(e.message));
  const context=await native.evaluate(()=>JSON.parse(timerBoot()));
  const initial=await native.evaluate(mode=>{
   timerTrace=[];localStorage.setItem('scheduler-control','native-control');startFrameOwner();timerSelectRecord();const control=JSON.parse(timerNeutral());control.storage=schedulerStorage();schedulerPrepare(mode);const before=timerTrace.slice(),entries=JSON.parse(schedulerSnapshot());
   let first,second;
   if(!['timer','frame','error-owned','switch','hooks'].includes(mode)){first=schedulerFlush();second=schedulerFlush();}
   return {control,before,entries,first,second,after:timerTrace.slice()};
  },mode);
  if(asyncModes.has(mode))await native.waitForFunction(n=>timerTrace.length===n,expected[mode].length);
  const observed=await native.evaluate(negative=>({trace:timerTrace.slice(),entries:JSON.parse(schedulerSnapshot()),dispatch:JSON.parse(timerDispatches()),...stopFrameOwner(negative)}),requested);
  const regs=observed.records.filter(r=>r.record==='TaskReg'),tasks=observed.records.filter(r=>r.record==='Task'),clockRecords=observed.records.filter(r=>r.record==='Clock'&&r.src===2);
  assert.equal(clockRecords.length,clocks[requested]-(requested==='clock-source'?1:0),requested+' actual Clock2 count');
  if(['basic','nested','nested-reorder','error','two','priority','clock-source'].includes(requested))assert.deepEqual(initial.before,[],'exact synchronous deferral');
  assert.deepEqual(observed.trace,expected[mode]||expectedOrder(initial.entries),mode+' actual native queue output');
  if(mode==='error'){assert.deepEqual(JSON.parse(initial.first),{same:true,message:'original scheduler callback'});assert.equal(initial.second,'ok');}
  else if(!asyncModes.has(mode)&&!['switch','hooks'].includes(mode)){assert.equal(initial.first,'ok');assert.equal(initial.second,'ok');}
  assert.equal(tasks.length,mode==='error-owned'?2:asyncModes.has(mode)?1:0);
  assert.equal(regs.length,tasks.length,'no synchronous scheduler wire registration');
  assert.equal(observed.dispatch.selected,String(tasks.length));
  if(mode==='error-owned'){assert.equal(nativeErrors.length,1);assert.match(nativeErrors[0],/original scheduler callback/);}else assert.deepEqual(nativeErrors,[]);
  assert.equal(observed.records.filter(r=>r.record==='Checkpoint').length,1);
  // wrong-source intentionally changes exactly one actual scheduler read.
  if(requested==='clock-source')assert.equal(observed.records.filter(r=>r.record==='Clock'&&r.src===1).length,1);
  const nativeNil=await native.evaluate(()=>{try{return {answer:schedulerNilCancel()};}catch(e){return {name:e.constructor.name,message:e.message};}});
  await native.close();
  const page=await pageFor('');
  const setup=await page.evaluate(({context,observed,mode,program,inverse})=>{
   timerTrace=[];timerContext=context;globalThis.xrReadBootContext=context;installFrameOwner(observed.log);(0,eval)(program);timerSelectReplay();
   localStorage.setItem('scheduler-control','different-replay-live');const sentinel=Error('scheduler raw boundary');let rawClocks=0,rawScheduling=0,rawStorage=0,witnesses=[];
   const clockTrap=()=>{rawClocks++;throw sentinel;},scheduleTrap=function(){rawScheduling++;throw sentinel;};
   const originalDate=new Date(0);
   Date.now=clockTrap;Date.prototype.getTime=clockTrap;performance.now=clockTrap;Object.defineProperty(performance,'timeOrigin',{configurable:true,get:clockTrap});
   for(const [name,fn] of [['Date.now',()=>Date.now()],['Date.getTime',()=>originalDate.getTime()],['performance.now',()=>performance.now()],['performance.timeOrigin',()=>performance.timeOrigin]]){const before=rawClocks;let error;try{fn();}catch(e){error=e;}if(error!==sentinel||rawClocks!==before+1)throw Error('dead clock trap '+name);witnesses.push(name);}
   for(const name of ['setTimeout','setInterval','clearTimeout','clearInterval','requestAnimationFrame','cancelAnimationFrame','requestIdleCallback','cancelIdleCallback','MessageChannel']){window[name]=scheduleTrap;const before=rawScheduling;let error;try{if(name==='MessageChannel')new window[name]();else window[name](()=>{},0);}catch(e){error=e;}if(error!==sentinel||rawScheduling!==before+1)throw Error('dead scheduling trap '+name);witnesses.push(name);}
   const storageTrap=function(){rawStorage++;throw sentinel;};Storage.prototype.getItem=storageTrap;let storageError;try{localStorage.getItem('witness');}catch(e){storageError=e;}if(storageError!==sentinel||rawStorage!==1)throw Error('dead storage trap');witnesses.push('Storage.getItem');
   rawClocks=0;rawScheduling=0;rawStorage=0;
   globalThis.schedulerRaw=()=>({rawClocks,rawScheduling,rawStorage,witnesses});
   const control=JSON.parse(timerNeutral());control.storage=schedulerStorage();const before=__ctReplay.peek();let thrown,first,second,entries,typedRefusal;
   try{if(inverse==='refusal')typedRefusal=JSON.parse(schedulerPrepareChecked(mode));else schedulerPrepare(mode);}catch(e){let direct;try{__ctReplay.next('Clock',{src:2});}catch(other){direct=other;}thrown={text:String(e),nimType:e.m_type?.name,owner:e.divergence,originalClass:e.constructor===direct?.constructor,payload:e.divergence===direct?.divergence&&e.divergence===__ctReplay.failed,cursor:__ctReplay.peek()};}
   const preflush=timerTrace.slice();entries=JSON.parse(schedulerSnapshot());
   if(!thrown&&!['timer','frame','error-owned','switch','hooks'].includes(mode)){first=schedulerFlush();second=schedulerFlush();}
   return {control,before,after:__ctReplay.peek(),thrown,typedRefusal,preflush,entries,first,second,trace:timerTrace.slice(),raw:schedulerRaw()};
  },{context,observed,mode,program,inverse});
  receipts.push({requested,context,initial,observed,setup});
  assert.deepEqual(setup.control,initial.control,'neutral actual owner Clock2/context');
  assert.equal(setup.raw.witnesses.length,14);assert.equal(setup.raw.rawClocks+setup.raw.rawScheduling+setup.raw.rawStorage,0);
  if(inverse==='refusal'){
   assert.deepEqual(setup.typedRefusal,{type:'ValueError',message:'internal read Replay does not support requestCallback'});assert.equal(setup.thrown,undefined);assert.equal(setup.before.seq,setup.after.seq);assert.equal(setup.after.kind,'Clock');assert.deepEqual(setup.preflush,[]);
   console.log('restored private refusal REJECTED: exact ValueError/pending Clock2, neutral owner reads PASS');await page.close();continue;
  }
  if(requested==='clock-source'){
   assert.equal(setup.thrown.owner.kind,'ArgumentMismatch');assert.match(setup.thrown.owner.detail,/src/);assert.equal(setup.thrown.owner.seq,setup.before.seq);assert(setup.thrown.originalClass&&setup.thrown.payload);assert.equal(setup.thrown.cursor.seq,setup.before.seq);assert.equal(setup.after.seq,setup.before.seq);assert.deepEqual(setup.preflush,[]);
   console.log('wrong scheduler Clock2 source: actual owner class/shared latch/exact seq/cursor PASS');await page.close();continue;
  }
  assert.equal(setup.thrown,undefined);
  if(inverse==='inline'){
   assert.deepEqual(setup.preflush,['late:false','early:false','cancelled:false']);assert.equal(setup.after.kind,'Checkpoint');
   console.log('premature execution REJECTED by exact preflush count/order; neutral owner read PASS');await page.close();continue;
  }
  if(inverse==='cancel'){
   assert(setup.trace.includes('cancelled:false'));assert.equal(setup.trace.length,3);assert.equal(setup.after.kind,'Checkpoint');assert.deepEqual(setup.preflush,[]);
   console.log('disabled cancellation REJECTED by actual cancelled callback/count; neutral owner read PASS');await page.close();continue;
  }
  if(inverse==='sort'){
   assert.deepEqual(setup.trace,['late:false','early:false']);assert.deepEqual(initial.after,['early:false','late:false']);assert.equal(setup.after.kind,'Checkpoint');
   console.log('omitted sort REJECTED by deterministic actual TestClock reversed priority; neutral owner read PASS');await page.close();continue;
  }
  if(inverse==='read'){
   assert.equal(setup.before.seq,setup.after.seq);assert.equal(setup.after.kind,'Clock');assert(setup.entries.every(e=>e.start==='0.0'));
   assert.deepEqual(setup.after,setup.before,'exact unconsumed genuine Clock2 payload');assert.equal(String(setup.after.record.bits),clockRecords[1].bits);assert.equal(setup.after.seq,clockRecords[1].seq);assert(initial.entries.some(e=>e.start!=='0.0'),'native sampled clock differs from substituted zero');assert.equal(setup.control.storage,'native-control');
   console.log('omitted selected Clock2 REJECTED: exact pending read/seq/bits and zero substitution; neutral owner Clock2/storage PASS');await page.close();continue;
  }
  assert.deepEqual(setup.preflush,initial.before);
  assert.deepEqual(setup.entries,initial.entries,'exact native Task values/local IDs and cancellation');
  assert.equal(setup.first,initial.first);assert.equal(setup.second,initial.second);
  await page.waitForFunction(()=>['done','diverged'].includes(__ctReplay.status().state));
  const final=await page.evaluate(()=>({trace:timerTrace.slice(),entries:JSON.parse(schedulerSnapshot()),dispatch:JSON.parse(timerDispatches()),status:__ctReplay.status(),raw:schedulerRaw()}));receipts.at(-1).final=final;
  assert.equal(final.status.state,'done',JSON.stringify(final.status));assert.deepEqual(final.trace,observed.trace);assert.deepEqual(final.entries,observed.entries);assert.deepEqual(final.dispatch,observed.dispatch);assert.equal(final.status.tasks,tasks.length);assert.equal(final.status.checkpoints,1);assert.equal(final.raw.rawClocks+final.raw.rawScheduling+final.raw.rawStorage,0);
  if(mode==='error-owned'){assert.equal(final.status.pageErrors.length,1);assert.match(final.status.pageErrors[0],/original scheduler callback/);}else assert.deepEqual(final.status.pageErrors,[]);
  const nil=await page.evaluate(()=>{try{return {answer:schedulerNilCancel()};}catch(e){return {name:e.constructor.name,message:e.message};}});assert.deepEqual(nil,nativeNil,'original native nil cancellation error');
  console.log(requested+': actual native/private queue, checked Clock2, dispatch/checkpoint and errors PASS');await page.close();
 }
}finally{writeFileSync(root+'/build/'+basename(process.env.REPLAY_SCHEDULER_BUNDLE||'replay-scheduler.js')+'.receipt.json',JSON.stringify({inverse,receipts},(_,v)=>typeof v==='bigint'?String(v):v,2));await browser.close();await new Promise(r=>server.close(r));}
