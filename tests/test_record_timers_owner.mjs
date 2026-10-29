/** Real Chromium scheduling -> compiled fixed Nim -> actual Recorder -> strict
 * codec -> public Replay/owned loop/DOM-v1 DONE. Native forwarding witnesses
 * retain actual platform behavior. Only native-throw/sink/encoder/preexisting-owner-fault injections are
 * deliberate faults; no fake timer, provider, cursor, tape or DONE is used.
 */
import assert from 'node:assert/strict';
import {readFileSync,appendFileSync} from 'node:fs';
import {createRequire} from 'node:module';
import {createServer} from 'node:http';
const root=process.cwd(),artifact=process.env.CT_ARTIFACT;
assert(artifact,'CT_ARTIFACT required');
for(const k of ['TIMER_BUNDLE','TIMER_REPLAY','TIMER_CONTEXT','TIMER_COMPANION'])assert(process.env[k],k+' required: current input');
const {build}=createRequire(artifact+'/packages/boundary-shim/package.json')('esbuild');
const {chromium}=await import(root+'/tests/browser/node_modules/playwright/index.mjs');
const imports=`import {Recorder,numberToBits} from '@codetracer/boundary-shim/dist/browser/recorder.js';
import {captureOriginals} from '@codetracer/boundary-shim/dist/browser/originals.js';
import {readEnvironment} from '@codetracer/boundary-shim/dist/browser/install.js';
import {domV1Hash} from '@codetracer/boundary-shim/dist/browser/dom-v1.js';
import {encodeLog,decodeLog,decodeRecord} from '@codetracer/boundary-format';
import {installReplayRuntime} from '@codetracer/boundary-replay/dist/browser/runtime.js';
globalThis.timerApi={Recorder,numberToBits,captureOriginals,readEnvironment,domV1Hash,encodeLog,decodeLog,decodeRecord,installReplayRuntime};`;
async function bundle(text){return(await build({stdin:{resolveDir:artifact,contents:text},bundle:true,platform:'browser',format:'iife',write:false})).outputFiles[0].text;}
const suffix='\nObject.assign(globalThis,{rtInit,rtSchedule,rtCancel,rtMono,rtOrdinary,rtUnselected,rtSelect,rtPreserves,rtEvery,rtPublicCancel,rtAdvance,rtOrdinaryDispatch});';
const candidate=await bundle(imports+readFileSync(process.env.TIMER_BUNDLE,'utf8')+suffix),companion=await bundle(imports+readFileSync(process.env.TIMER_COMPANION,'utf8')+suffix),owner=await bundle(imports),replay=readFileSync(process.env.TIMER_REPLAY,'utf8'),capture=readFileSync(process.env.TIMER_CONTEXT,'utf8');
const server=createServer((q,s)=>s.end('<!doctype html><main>Private timers</main>'));await new Promise(r=>server.listen(0,'127.0.0.1',r));
const url='http://127.0.0.1:'+server.address().port;let browser;
const receipt=v=>{if(process.env.TIMER_RESULTS)appendFileSync(process.env.TIMER_RESULTS,JSON.stringify(v)+'\n');};
async function record(context,code,mode){
 const page=await context.newPage();await page.goto(url);await page.addScriptTag({content:capture});const boot=await page.evaluate(()=>xrReadBootContext);await page.addScriptTag({content:code});
 const result=await page.evaluate(async mode=>{
  const a=timerApi,native=a.captureOriginals(window),counts={set:0,clear:0,lateSet:0,lateClear:0},receivers=[],trace=[],errors=[],nativeErrors=[],nativeDelays=[],ordinaryDelays=[],clearHandles=[],lifecycleHandles=[],sentinel={timerError:true};let nativeThrow=false,lastHandle,failSink=false;
  window.setTimeout=function(cb,d){counts.set++;receivers.push(this===window);trace.push('native-set');nativeDelays.push(d);if(nativeThrow)throw sentinel;const h=native.setTimeout.call(this,function(){trace.push('native-entry');receivers.push(this===window);try{return cb.call(this);}catch(e){nativeErrors.push(e);throw e;}},d);lastHandle=h;return h;};
  window.clearTimeout=function(h){counts.clear++;clearHandles.push(h);receivers.push(this===window);trace.push('native-clear');return native.clearTimeout.call(this,h);};
  const captured=a.captureOriginals(window),owners=[];
  function make(n){const frames=[];const rec=new a.Recorder({checkpointScheme:'dom-v1',checkpointHash:()=>a.domV1Hash(document),sink:{append(f){const x=a.decodeRecord(f.subarray(4));if(x.record==='TaskReg'||x.record==='Task')trace.push(x.record);if(failSink&&x.record==='TaskReg'){failSink=false;throw sentinel;}frames.push(f);},end(u,f){frames.push(f);},halt(){}}});rec.start({vocab:1,protocol_level:0,recorder_id:'private-timers',framework:'',build_hash:'a'.repeat(64),session_id:String(n).repeat(32),prev_session:'',capabilities:'[]'},a.readEnvironment(window,native));const o={rec,frames};owners.push(o);return o;}
  const o=make(1),before=o.frames.length;let id;
  if(mode==='invalid'){
   const invalid=[];for(const x of [[{},o.rec,captured],[window,{},captured],[window,o.rec,{}],[window,o.rec,{setTimeout:captured.setTimeout}],[window,o.rec,{clearTimeout:captured.clearTimeout}]]){try{rtInit(...x);invalid.push(null);}catch(e){invalid.push(e.name);}}
   return {invalid,counts,before,after:o.frames.length};
  }
  id=rtInit(window,o.rec,captured);const second=rtInit(window,o.rec,captured);const constructor={counts:{...counts},before,after:o.frames.length,unselected:rtUnselected()};
  for(const kind of [0,1,2,3]){rtSelect(kind);if(!rtPreserves(window,o.rec,captured))throw Error('explicit clock selection changed');}const clocks=[rtMono(id),rtMono(id)],observed=[],delivered=[],callbackErrors=[],lateNative=[];
  const expectedError=mode==='callback-error'||mode==='guard-inverse',nativeNil=['nil','nil-stopped','nil-prefault'].includes(mode);
  let resolveNil,resolveOrdinaryError;const nilDelivery=new Promise(resolve=>resolveNil=resolve),ordinaryErrorDelivery=new Promise(resolve=>resolveOrdinaryError=resolve);
  native.addEventListener.call(window,'error',function(e){
   if(expectedError&&e.error===sentinel&&nativeErrors.includes(e.error)){errors.push({identity:true});e.preventDefault();}
   else if(nativeNil&&nativeErrors.length===1&&e.error===nativeErrors[0]&&e.error instanceof TypeError){callbackErrors.push({identity:true,name:e.error.name,async:trace.includes('returned'),channel:'error'});resolveNil();e.preventDefault();}
   else errors.push({unexpected:String(e.error||e.message)});
  });
  // Ordinary RealClock's actual dispatch counter witnesses entry before the
  // nil call in its Promise continuation. No arbitrary rejection is masked.
  native.addEventListener.call(window,'unhandledrejection',function(e){
   if(mode==='ordinary-nil'&&rtOrdinaryDispatch()===1&&e.reason instanceof TypeError&&callbackErrors.length===0&&trace.includes('returned')){callbackErrors.push({name:e.reason.name,dispatch:rtOrdinaryDispatch(),async:true,channel:'unhandledrejection'});resolveNil();e.preventDefault();}
   else if(mode==='ordinary-every'&&e.reason===sentinel){errors.push({identity:true,channel:'unhandledrejection'});resolveOrdinaryError();e.preventDefault();}
   else errors.push({unexpectedRejection:String(e.reason)});
  });
  let witnessingSet=true;window.setTimeout=function(cb,d){counts.lateSet++;if(witnessingSet)throw sentinel;return native.setTimeout.call(window,cb,d);};window.clearTimeout=function(){counts.lateClear++;throw sentinel;};
  let caught;try{window.setTimeout(()=>{},0);}catch(e){caught=e;}if(caught!==sentinel||counts.lateSet!==1)throw Error('late set witness');counts.lateSet=0;witnessingSet=false;
  caught=undefined;try{window.clearTimeout(0);}catch(e){caught=e;}if(caught!==sentinel||counts.lateClear!==1)throw Error('late clear witness');counts.lateClear=0;
  const fence=()=>new Promise(resolve=>native.setTimeout.call(window,resolve,0));
  let resolveDelivery,nativeCallbackCount=0;const applicationTrace=[],completeDelivery=new Promise(resolve=>resolveDelivery=resolve);const app=n=>{applicationTrace.push(n);document.querySelector('main').textContent='timer:'+applicationTrace.join(',');};const emit=n=>{trace.push('callback:'+n);delivered.push(n);app(n);nativeCallbackCount++;if(nativeCallbackCount===4)resolveDelivery();};
  const bounded=async(p,label)=>{let h;try{return await Promise.race([p,new Promise((_,reject)=>h=native.setTimeout.call(window,()=>reject(Error('positive completion timeout: '+label)),5000))]);}finally{native.clearTimeout.call(window,h);}};
  if(mode==='ordinary-every'){
   window.setTimeout=native.setTimeout;window.clearTimeout=native.clearTimeout;rtSelect(0);
   let n=0,h,complete;const repeated=new Promise(resolve=>complete=resolve);
   h=rtEvery(2,()=>{n++;if(n===2){rtPublicCancel(h);complete();}});
   await bounded(repeated,'ordinary repeated callbacks');await fence();if(n!==2)throw Error('ordinary Real scheduleEvery cancellation');
   rtSelect(1);n=0;h=rtEvery(2,()=>{n++;if(n===2)rtPublicCancel(h);});rtAdvance(10);if(n!==2)throw Error('ordinary Test scheduleEvery cancellation');
   rtSelect(0);let failures=0,completeError;const errorFence=new Promise(resolve=>completeError=resolve);
   rtEvery(2,()=>{try{failures++;throw sentinel;}finally{queueMicrotask(()=>native.setTimeout.call(window,completeError,2));}});
   await bounded(Promise.all([errorFence,ordinaryErrorDelivery]),'ordinary error callback/fence');if(failures!==1||errors.length!==1)throw Error('ordinary scheduleEvery must not rearm after error');errors.length=0;
  }
  if(mode==='stopped'||mode==='nil-stopped')o.rec.end(2);if(mode==='nil-prefault')o.rec.fault(sentinel);
  if(mode==='sink')failSink=true;
  if(mode==='encoder')o.rec.injectEncoderFault();
  if(mode==='native-throw'){
   nativeThrow=true;let identity=false;try{rtSchedule(id,0,()=>{});}catch(e){identity=e===sentinel;}nativeThrow=false;
   return{constructor,identity,records:o.frames.map(f=>a.decodeRecord(f.subarray(4))).map(x=>x.record),next:String(o.rec.nextTaskId()),counts};
  }
  if(mode==='ordinary-every'){await fence();}else if(mode==='namespace'){
   rtSchedule(id,0,()=>emit('one'));rtSchedule(second,0,()=>emit('two'));
   const other=make(2),third=rtInit(window,other.rec,captured);rtSchedule(third,0,()=>{});await fence();
  }else if(mode==='cancel'||mode==='pending'){
   const h=rtSchedule(id,mode==='cancel'?0:1000,()=>emit('cancelled'));observed.push({handle:h,native:lastHandle});
   if(mode==='cancel')rtCancel(id,h);else{o.rec.end(2);rtCancel(id,h);}
   await fence();
  }else if(mode==='cancel-lifecycle'){
   let complete;const lifecycleFence=new Promise(resolve=>complete=resolve);
   let h=rtSchedule(id,0,()=>{emit('one');rtCancel(second,h);rtCancel(id,0);const pending=rtSchedule(second,0,()=>emit('nested'));lifecycleHandles.push(h,pending);rtCancel(id,pending);queueMicrotask(()=>trace.push('micro'));native.setTimeout.call(window,complete,0);});
   await bounded(lifecycleFence,'native nested cancellation fence');rtCancel(id,h);rtCancel(id,h);
  }else if(expectedError){
   rtSchedule(id,0,()=>{try{emit('error');throw sentinel;}finally{trace.push('finally');}});rtSchedule(second,0,()=>emit('after'));trace.push('returned');await fence();
  }else if(nativeNil||mode==='ordinary-nil'){
   if(nativeNil)rtSchedule(id,0,null);else{
    // RealClock calls the ambient platform; restore only this independent
    // compatibility session, without weakening captured-original target tests.
    window.setTimeout=native.setTimeout;window.clearTimeout=native.clearTimeout;
    rtOrdinary(0,null);
   }
   trace.push('returned');await bounded(nilDelivery,'actual nil failure channel');await fence();
  }else if(mode==='after-end'){
   rtSchedule(id,0,()=>emit('outside'));o.rec.end(2);const terminal=o.frames.length;await fence();lateNative.push(terminal,o.frames.length);
  }else if(mode==='delays'){
   for(const d of [-2,0,0.25,2.25,2147483647,2147483648,NaN,Infinity,-Infinity,1e100,-1e100]){
    const h=rtSchedule(id,d,()=>{});rtCancel(id,h);observed.push({input:String(d),handle:h,native:lastHandle});
    window.setTimeout=function(cb,delay){ordinaryDelays.push(delay);const h=native.setTimeout.call(window,cb,delay);native.clearTimeout.call(window,h);return h;};rtOrdinary(d,()=>{});
   }await fence();
  }else{
   rtSchedule(id,0,()=>{emit('zero');queueMicrotask(()=>{trace.push('micro');app('micro');});rtSchedule(second,2.25,()=>emit('nested'));});trace.push('returned');
   // Deliberately programmed real one-shot chain; this is not public Record
   // scheduleEvery. Its registrations pair with existing Replay scheduleEvery.
   let n=0;const tick=()=>{emit('tick'+(++n));if(n<2)rtSchedule(id,4,tick);};rtSchedule(id,4,tick);await bounded(completeDelivery,'four native callbacks');await fence();
  }
  const terminalBefore=o.frames.length;for(const x of owners)x.rec.end(2);
  const sessions=owners.map(x=>{const records=x.frames.map(f=>a.decodeRecord(f.subarray(4))),bytes=a.encodeLog(records),decoded=a.decodeLog(bytes);let raw='';for(const b of bytes)raw+=String.fromCharCode(b);return{records:JSON.parse(JSON.stringify(decoded.records,(_,v)=>typeof v==='bigint'?String(v):v)),log:btoa(raw),termination:decoded.termination};});
  return{constructor,clocks,bits:clocks.map(v=>a.numberToBits(v).toString()),counts,receivers,trace,errors,callbackErrors,observed,delivered,sessions,lateNative,terminalBefore,nativeDelays,ordinaryDelays,clearHandles,lifecycleHandles,applicationTrace,nativeCallbackCount};
 },mode);receipt({mode,stage:'record',result});await page.close();return{result,boot};
}
async function replaySession(context,session,boot,mode,clocks,expectedTrace,expectedCallbacks){
 const page=await context.newPage();await page.goto(url);await page.addScriptTag({content:owner});
 const initial=await page.evaluate(({log,boot,replay,mode})=>{
  timerApi.installReplayRuntime(window,{log});
  const cursor=__ctReplay,observation={on:[],off:[],active:new Set(),callbacks:0},on=cursor.onTask,off=cursor.offTask;
  cursor.onTask=function(task,callback){observation.on.push(String(task));observation.active.add(String(task));return on.call(this,task,function(...args){observation.callbacks++;try{return callback.apply(this,args);}finally{observation.callbacks--;}});};
  cursor.offTask=function(task){const value=off.call(this,task);observation.off.push(String(task));observation.active.delete(String(task));return value;};
  globalThis.timerCursorObservation=observation;
  globalThis.xrReadBootContext=boot;(0,eval)(replay);
  const counts={clock:0,set:0,clear:0},sentinel={unexpectedRawTimer:true};
  performance.now=function(){counts.clock++;throw sentinel;};window.setTimeout=function(){counts.set++;throw sentinel;};window.clearTimeout=function(){counts.clear++;throw sentinel;};
  for(const [key,call] of [['clock',()=>performance.now()],['set',()=>window.setTimeout(()=>{},0)],['clear',()=>window.clearTimeout(0)]]){let error;try{call();}catch(e){error=e;}if(error!==sentinel||counts[key]!==1)throw Error('Replay raw trap witness '+key);counts[key]=0;}
  globalThis.replayTimerCounts=counts;
  const clocks=[rtReplayMono(),rtReplayNeMono()],out=[],applicationTrace=[];const app=n=>{applicationTrace.push(n);document.querySelector('main').textContent='timer:'+applicationTrace.join(',');};const emit=n=>{out.push(n);app(n);};
  if(mode==='cancel'||mode==='pending'){const h=rtReplaySchedule(mode==='cancel'?0:1000,()=>emit('cancelled'));globalThis.oldPublicTimer=h;if(mode==='cancel')rtReplayCancel(h);}
  else{rtReplaySchedule(0,()=>{emit('zero');queueMicrotask(()=>app('micro'));rtReplaySchedule(2.25,()=>emit('nested'));});let n=0,h;h=rtReplayEvery(4,()=>{emit('tick'+(++n));if(n===2)rtReplayCancel(h);});}
  const before={off:observation.off.slice(),active:[...observation.active],callbacks:observation.callbacks};let refusal;
  try{rtReplayDispose();}catch(e){refusal=String(e);}
  const after={off:observation.off.slice(),active:[...observation.active],callbacks:observation.callbacks};
  globalThis.replayTimerOut=out;globalThis.replayApplicationTrace=applicationTrace;return{clocks,refusal,counts,before,after};
 },{log:session.log,boot,replay,mode});
 assert.equal(initial.clocks[0],clocks[0]);assert.equal(initial.clocks[1],String(BigInt(Math.trunc(clocks[1]))));assert.match(initial.refusal,/internal read Replay disposal requires completed owner outside callbacks/);assert.deepEqual(initial.after,initial.before,'premature disposal cannot release actual handlers');if(mode==='pending')assert.equal(initial.before.active.length,1,'actual pending handler witnesses premature refusal');assert.deepEqual(initial.counts,{clock:0,set:0,clear:0});
 await page.waitForFunction(()=>['done','diverged'].includes(__ctReplay.status().state));const end=await page.evaluate(()=>{const status=__ctReplay.status(),out=replayTimerOut.slice(),applicationTrace=replayApplicationTrace.slice(),o=timerCursorObservation;
  const before={off:o.off.slice(),active:[...o.active],callbacks:o.callbacks};rtReplayDispose();const after={off:o.off.slice(),active:[...o.active],callbacks:o.callbacks};rtReplayDispose();const twice=o.off.slice();
  const onBefore=o.on.slice(),offBefore=o.off.slice();let disposed;
  try{rtReplaySchedule(0,()=>{});}catch(e){disposed=String(e);}
  if(globalThis.oldPublicTimer!==undefined)rtReplayCancel(oldPublicTimer);
  return{status,afterStatus:__ctReplay.status(),out,applicationTrace,counts:replayTimerCounts,before,after,twice,disposed,onBefore,onAfter:o.on.slice(),offBefore,offAfter:o.off.slice()};});
 receipt({mode,stage:'replay',end});assert.deepEqual(end.applicationTrace,expectedTrace,'actual full callback plus microtask application/DOM order');assert.deepEqual(end.out,expectedCallbacks,'actual public Replay callback sequence');assert.equal(end.status.state,'done','timer semantic: actual public owner completion');assert.deepEqual(end.counts,{clock:0,set:0,clear:0},'Replay native effects remain zero through completion/disposal');assert.equal(end.before.callbacks,0);assert.deepEqual(end.after.active,[],'completion disposal leaves no actual owned handler');assert.equal(end.after.callbacks,0);assert.deepEqual(end.twice,end.after.off,'second disposal adds no offTask');assert.equal(end.afterStatus.state,'done');assert.match(end.disposed,/internal read Replay timer clock is disposed/);assert.deepEqual(end.onAfter,end.onBefore,'disposed schedule has no cursor registration');assert.deepEqual(end.offAfter,end.offBefore,'old cancellation is idempotent');
 if(mode==='pending'){assert.deepEqual(end.before.active,['1']);assert.deepEqual(end.before.off,[]);assert.deepEqual(end.after.off,['1'],'pending handler released exactly once after actual done');}else{assert.deepEqual(end.before.active,[]);assert.deepEqual(end.after.off,end.before.off,'completed or cancelled handlers were already released');}await page.close();
}
try{
 browser=await chromium.launch({executablePath:process.env.PLAYWRIGHT_CHROMIUM_EXECUTABLE});
 for(const [arm,code,modes] of [['companion',companion,['positive']],['candidate',candidate,process.env.TIMER_INVERSE?[process.env.TIMER_INVERSE==='cancel'?'cancel':process.env.TIMER_INVERSE==='cancel-lifecycle'?'cancel-lifecycle':process.env.TIMER_INVERSE==='guard'?'guard-inverse':'positive']:['positive','cancel','pending','cancel-lifecycle','namespace','delays','callback-error','nil','nil-stopped','nil-prefault','ordinary-nil','ordinary-every','stopped','sink','encoder','after-end','native-throw','invalid']]]){
  for(const mode of modes){
   const context=await browser.newContext();const {result:r,boot}=await record(context,code,mode);
   if(mode==='invalid'){assert(r.invalid.every(x=>x==='TypeError'));assert.equal(r.before,r.after);assert.equal(r.counts.set,0);await context.close();continue;}
   assert.deepEqual(r.constructor.counts,{set:0,clear:0,lateSet:0,lateClear:0});assert.equal(r.constructor.before,r.constructor.after);assert(r.constructor.unselected);
   if(mode==='native-throw'){assert(r.identity);assert.equal(r.next,'2');assert.equal(r.records.filter(x=>x==='TaskReg').length,0);await context.close();continue;}
   assert(r.receivers.every(Boolean),'original Window receiver');assert.equal(r.counts.lateSet,0,'timer semantic: captured scheduling');assert.equal(r.counts.lateClear,0,'captured cancellation');assert(r.observed.every(x=>x.handle===x.native),'exact native handles');
   if(['ordinary-nil','nil','nil-stopped','nil-prefault'].includes(mode)){assert.equal(r.callbackErrors.length,1,'asynchronous nil error delivered');assert(r.callbackErrors[0].async);assert.equal(r.callbackErrors[0].name,'TypeError');assert.equal(r.callbackErrors[0].channel,mode==='ordinary-nil'?'unhandledrejection':'error');}
   if(mode==='callback-error'||mode==='guard-inverse'){assert.equal(r.errors.length,1,'timer semantic: callback error delivered outside guard');assert(r.errors[0].identity);assert(r.trace.includes('finally'));assert.deepEqual(r.delivered,['error','after']);}
   else assert.deepEqual(r.errors,[],'unexpected native errors');
   const records=r.sessions[0].records,regs=records.filter(x=>x.record==='TaskReg'),tasks=records.filter(x=>x.record==='Task');
   if(mode==='nil-stopped'||mode==='nil-prefault'){assert(r.callbackErrors[0].identity,'inactive native nil retains exact delivered error');assert.equal(regs.length,0);assert.equal(tasks.length,0);assert.equal(records.at(-1).record,mode==='nil-stopped'?'End':'Refusal');await context.close();continue;}
   if(mode==='sink'||mode==='encoder'){assert.equal(records.at(-1).record,'Refusal');assert.equal(records.at(-1).feature,'recorder-fault');assert.equal(r.delivered.length,4,'fault cannot swallow callback');await context.close();continue;}
   if(mode==='stopped'){assert.equal(regs.length,0);assert.equal(tasks.length,0);assert.equal(r.delivered.length,4);await context.close();continue;}
   if(mode==='after-end'){assert.equal(r.lateNative[0],r.lateNative[1]);assert.deepEqual(r.delivered,['outside']);assert.equal(tasks.length,0);await context.close();continue;}
   if(mode==='cancel-lifecycle'){assert.deepEqual(r.delivered,['one'],'timer semantic: nested cancelled callback remains absent after native fence');assert.deepEqual(r.clearHandles,[r.lifecycleHandles[0],0,r.lifecycleHandles[1],r.lifecycleHandles[0],r.lifecycleHandles[0]],'exact fired/unknown/nested/repeated native clear handles');assert.equal(regs.length,2);assert.equal(tasks.length,1);assert.equal(r.counts.clear,5);assert(r.trace.includes('micro'));await context.close();continue;}if(mode==='delays'){assert.deepEqual(r.nativeDelays,r.ordinaryDelays,'fresh actual RealClock/native helper delay argument parity');assert.deepEqual(regs.map(x=>x.delay_ms),r.nativeDelays);assert.deepEqual(regs.map(x=>x.delay_ms),[0,0,1,3,2147483647,0,0,0,0,0,0]);assert.equal(tasks.length,0);await context.close();continue;}
   if(mode==='namespace'){assert.deepEqual(regs.map(x=>x.task_id),['1','2'],'timer semantic: actual shared owner namespace');assert.deepEqual(r.sessions[1].records.filter(x=>x.record==='TaskReg').map(x=>x.task_id),['1']);await context.close();continue;}
   if(mode==='positive'){
    assert.equal(regs.length,4,'timer semantic: exact TaskReg count');assert(regs.every(x=>x.kind===1),'timer semantic: timeout kind');assert.deepEqual(regs.map(x=>x.delay_ms),[0,4,3,4],'timer semantic: normalized delay');assert.equal(new Set(regs.map(x=>x.task_id)).size,4,'timer semantic: actual shared owner namespace');
    assert.equal(r.nativeCallbackCount,4);assert.equal(r.applicationTrace.length,5);assert.equal(r.applicationTrace[r.applicationTrace.indexOf('zero')+1],'micro','native microtask drains before later callbacks');assert.equal(r.counts.set,4);assert.equal(tasks.length,4,'timer semantic: task before callback');for(let i=0;i<r.trace.length;i++)if(r.trace[i].startsWith('callback:'))assert.equal(r.trace[i-1],'Task','timer semantic: task before callback');assert.deepEqual([...r.delivered].sort(),['nested','tick1','tick2','zero']);assert(r.trace.indexOf('returned')<r.trace.indexOf('native-entry'));assert(r.trace.indexOf('micro')<r.trace.lastIndexOf('native-entry'));
   }
   if(mode==='cancel'||mode==='pending'){assert.equal(r.counts.set,1);assert.equal(r.counts.clear,1);assert.equal(regs.length,1);assert.equal(tasks.length,0,'timer semantic: cancelled callback remains absent');assert.deepEqual(r.delivered,[],'timer semantic: cancelled callback remains absent');}
   if(['positive','cancel','pending'].includes(mode)){
    assert.equal(r.sessions[0].termination,'Complete');assert.equal(records.at(-1).record,'End');assert.deepEqual(records.filter(x=>x.record==='Clock').map(x=>x.bits),r.bits);
    await replaySession(context,r.sessions[0],boot,mode,r.clocks,r.applicationTrace,r.delivered);console.log('timer '+arm+' '+mode+': real Record -> strict codec -> public Replay DONE');
   }
   await context.close();
  }
 }
}finally{await browser?.close();await new Promise(r=>server.close(r));}
