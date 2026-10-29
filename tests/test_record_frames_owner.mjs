/** Actual Chromium frames -> fixed compiled Nim -> actual owner codec/loop/DONE.
 * Native callback witnesses delegate to real rAF/CAF. Only explicit native throw,
 * encoder/sink and preexisting owner fault cases inject faults. No fake timestamp,
 * tape, cursor, checkpoint provider or manual owner completion is used. */
import assert from 'node:assert/strict';
import {readFileSync,appendFileSync} from 'node:fs';
import {createRequire} from 'node:module';
import {createServer} from 'node:http';
const root=process.cwd(),artifact=process.env.CT_ARTIFACT;
assert(artifact,'CT_ARTIFACT required');
for(const key of ['FRAME_BUNDLE','FRAME_REPLAY','FRAME_CONTEXT','FRAME_COMPANION'])assert(process.env[key],key+' required: current input');
const {build}=createRequire(artifact+'/packages/boundary-shim/package.json')('esbuild');
const {chromium}=await import(root+'/tests/browser/node_modules/playwright/index.mjs');
const imports=`import {Recorder,numberToBits} from '@codetracer/boundary-shim/dist/browser/recorder.js';
import {captureOriginals} from '@codetracer/boundary-shim/dist/browser/originals.js';
import {readEnvironment} from '@codetracer/boundary-shim/dist/browser/install.js';
import {domV1Hash} from '@codetracer/boundary-shim/dist/browser/dom-v1.js';
import {encodeLog,decodeLog,decodeRecord} from '@codetracer/boundary-format';
import {installReplayRuntime} from '@codetracer/boundary-replay/dist/browser/runtime.js';
globalThis.frameApi={Recorder,numberToBits,captureOriginals,readEnvironment,domV1Hash,encodeLog,decodeLog,decodeRecord,installReplayRuntime};`;
async function bundle(text){return(await build({stdin:{resolveDir:artifact,contents:text},bundle:true,platform:'browser',format:'iife',write:false})).outputFiles[0].text;}
const suffix='\nObject.assign(globalThis,{rfInit,rfRequest,rfCancel,rfTimer,rfCancelTimer,rfMono,rfUnchanged,rfSelect,rfPreserves,rfOrdinary});';
const candidate=await bundle(imports+readFileSync(process.env.FRAME_BUNDLE,'utf8')+suffix),companion=await bundle(imports+readFileSync(process.env.FRAME_COMPANION,'utf8')+suffix),owner=await bundle(imports),replay=readFileSync(process.env.FRAME_REPLAY,'utf8'),capture=readFileSync(process.env.FRAME_CONTEXT,'utf8');
const server=createServer((q,s)=>s.end('<!doctype html><main>Private frames</main>'));await new Promise(r=>server.listen(0,'127.0.0.1',r));
const url='http://127.0.0.1:'+server.address().port;let browser;
const receipt=v=>{if(process.env.FRAME_RESULTS)appendFileSync(process.env.FRAME_RESULTS,JSON.stringify(v)+'\n');};
async function record(context,code,mode){
 const page=await context.newPage();await page.goto(url);await page.addScriptTag({content:capture});const boot=await page.evaluate(()=>xrReadBootContext);await page.addScriptTag({content:code});
 const result=await page.evaluate(async mode=>{
  const a=frameApi,native=a.captureOriginals(window),counts={request:0,cancel:0,lateRequest:0,lateCancel:0,lateClock:0,lateSet:0,lateClear:0},trace=[],nativeValues=[],values=[],receivers=[],clearHandles=[],handles=[],expectedKinds=[],errors=[],nativeErrors=[],appTrace=[],sentinel={frameError:true};let failNative=false,failCancel=false,failSink=false,lastHandle;
  window.requestAnimationFrame=function(cb){counts.request++;receivers.push(this===window);if(failNative)throw sentinel;const h=native.requestAnimationFrame.call(this,function(ts){const bits=a.numberToBits(ts).toString();nativeValues.push(bits);trace.push({type:'native-entry',bits});receivers.push(this===window);try{return cb.call(this,ts);}catch(e){nativeErrors.push(e);trace.push({type:'native-error',name:e?.name||'object',sentinel:e===sentinel});throw e;}});lastHandle=h;return h;};
  window.cancelAnimationFrame=function(h){counts.cancel++;clearHandles.push(h);receivers.push(this===window);if(failCancel)throw sentinel;return native.cancelAnimationFrame.call(this,h);};
  const captured=a.captureOriginals(window),owners=[];
  function make(n){const frames=[],rec=new a.Recorder({checkpointScheme:'dom-v1',checkpointHash:()=>a.domV1Hash(document),sink:{append(f){const x=a.decodeRecord(f.subarray(4));if(x.record==='Task')trace.push({type:'Task',kind:x.kind});if(x.record==='Clock'&&x.src===4)trace.push({type:'Clock',src:x.src,bits:String(x.bits)});if(failSink&&x.record==='TaskReg'){failSink=false;throw sentinel;}frames.push(f);},end(u,f){frames.push(f);},halt(){}}});rec.start({vocab:1,protocol_level:0,recorder_id:'private-frames',framework:'',build_hash:'a'.repeat(64),session_id:String(n).repeat(32),prev_session:'',capabilities:'[]'},a.readEnvironment(window,native));const o={rec,frames};owners.push(o);return o;}
  const o=make(1),before=o.frames.length;
  if(mode==='invalid'){const invalid=[];for(const args of [[{},o.rec,captured],[window,{},captured],[window,o.rec,{}],[window,o.rec,{requestAnimationFrame:captured.requestAnimationFrame}],[window,o.rec,{cancelAnimationFrame:captured.cancelAnimationFrame}]]){try{rfInit(...args);invalid.push(null);}catch(e){invalid.push(e.name);}}return{invalid,counts,before,after:o.frames.length};}
  const id=rfInit(window,o.rec,captured),second=rfInit(window,o.rec,captured),constructor={before,after:o.frames.length,counts:{...counts},unselected:rfUnchanged()};
  if(!rfPreserves(window,o.rec,{requestAnimationFrame:captured.requestAnimationFrame,cancelAnimationFrame:captured.cancelAnimationFrame}))throw Error('minimal frame-only originals factory changed selection');
  for(const kind of [0,1,2,3]){rfSelect(kind);if(!rfPreserves(window,o.rec,captured))throw Error('explicit selector changed');}
  const clocks=[rfMono(id),rfMono(id)];
  native.addEventListener.call(window,'error',e=>{if(e.error===sentinel&&nativeErrors.includes(e.error)){errors.push({identity:true,async:trace.some(x=>x.type==='returned')});e.preventDefault();}else if(['nil','nil-stopped','nil-prefault','ordinary-nil'].includes(mode)&&e.error instanceof TypeError&&nativeErrors.includes(e.error)){errors.push({identity:true,name:e.error.name,async:trace.some(x=>x.type==='returned')});e.preventDefault();}else errors.push({unexpected:String(e.error||e.message)});});
  native.addEventListener.call(window,'unhandledrejection',e=>errors.push({unexpectedRejection:String(e.reason)}));
  // Replacement traps delegate so a capture inverse reaches its exact semantic
  // assertion instead of failing incidentally at startup or callback delivery.
  window.requestAnimationFrame=function(cb){counts.lateRequest++;return captured.requestAnimationFrame.call(window,cb);};window.cancelAnimationFrame=function(h){counts.lateCancel++;return captured.cancelAnimationFrame.call(window,h);};
  const witness=window.requestAnimationFrame(()=>{});window.cancelAnimationFrame(witness);if(counts.lateRequest!==1||counts.lateCancel!==1)throw Error('late native traps not live');counts.request=counts.cancel=counts.lateRequest=counts.lateCancel=0;clearHandles.length=0;
  performance.now=()=>{counts.lateClock++;throw sentinel;};window.setTimeout=()=>{counts.lateSet++;throw sentinel;};window.clearTimeout=()=>{counts.lateClear++;throw sentinel;};
  for(const [key,call] of [['lateClock',()=>performance.now()],['lateSet',()=>window.setTimeout(()=>{},0)],['lateClear',()=>window.clearTimeout(0)]]){let caught;try{call();}catch(e){caught=e;}if(caught!==sentinel||counts[key]!==1)throw Error('late Record trap witness '+key);counts[key]=0;}
  // Ordinary public compatibility has its own legitimate ambient platform path.
  if(mode==='ordinary'||mode==='ordinary-nil'){performance.now=native.performanceNow;window.setTimeout=native.setTimeout;window.clearTimeout=native.clearTimeout;}
  const fence=()=>new Promise(resolve=>native.requestAnimationFrame.call(window,()=>native.requestAnimationFrame.call(window,resolve)));
  const bounded=async(p,label)=>{let h;try{return await Promise.race([p,new Promise((_,reject)=>h=native.setTimeout.call(window,()=>reject(Error('positive completion timeout: '+label)),5000))]);}finally{native.clearTimeout.call(window,h);}};
  const app=n=>{appTrace.push(n);document.querySelector('main').textContent='frame:'+appTrace.join(',');};
  const emit=(n,ts)=>{values.push(a.numberToBits(ts).toString());trace.push({type:'callback',name:n,bits:a.numberToBits(ts).toString()});app(n);};
  const request=(index,cb)=>{expectedKinds.push(3);const h=rfRequest(index,cb);handles.push({handle:h,native:lastHandle});return h;};
  const timer=(index,cb)=>{expectedKinds.push(1);return rfTimer(index,0,cb);};
  let lifecycle=[],micro=0,terminalFramesBefore,cancelThrowIdentity;const causal=[];let parentCompleted=false,firstFrameFence=false;
  if(mode==='nil-stopped'||mode==='stopped')o.rec.end(2);if(mode==='nil-prefault')o.rec.fault(sentinel);if(['nil-stopped','nil-prefault','stopped'].includes(mode))terminalFramesBefore=o.frames.map(f=>Array.from(f));
  if(mode==='sink')failSink=true;if(mode==='encoder')o.rec.injectEncoderFault();
  if(mode==='native-throw'){failNative=true;let identity=false;try{request(id,()=>{});}catch(e){identity=e===sentinel;}failNative=false;return{constructor,identity,next:String(o.rec.nextTaskId()),records:o.frames.map(f=>a.decodeRecord(f.subarray(4)).record),counts};}
  if(mode==='cancel-throw'){const h=request(id,ts=>emit('leaked',ts));failCancel=true;try{rfCancel(id,h);}catch(e){cancelThrowIdentity=e===sentinel;}failCancel=false;rfCancel(id,h);await bounded(fence(),'successful native cancellation after throw');}
  else if(mode==='namespace'){request(id,ts=>emit('first',ts));request(second,ts=>emit('second',ts));const other=make(2),third=rfInit(window,other.rec,captured);rfRequest(third,()=>{});await bounded(fence(),'separate owners');}
  else if(mode==='cancel'||mode==='pending'){const h=request(id,ts=>emit('cancelled',ts));if(mode==='pending')o.rec.end(2);rfCancel(second,h);await bounded(fence(),'cancellation');}
  else if(mode==='cancel-lifecycle'){
   let done;const complete=new Promise(resolve=>done=resolve);let first,sibling;
   first=request(id,ts=>{emit('one',ts);rfCancel(second,sibling);rfCancel(second,first);rfCancel(id,0);const child=request(second,t=>emit('nested',t));lifecycle=[first,sibling,child];rfCancel(id,child);queueMicrotask(()=>app('micro'));native.requestAnimationFrame.call(window,()=>native.requestAnimationFrame.call(window,done));});
   sibling=request(second,ts=>emit('sibling',ts));await bounded(complete,'nested child cancellation');rfCancel(id,first);rfCancel(id,first);
  }else if(mode==='callback-error'||mode==='guard-inverse'){request(id,ts=>{try{emit('error',ts);throw sentinel;}finally{app('finally');}});request(second,ts=>emit('after',ts));trace.push({type:'returned'});await bounded(fence(),'callback error fence');}
  else if(['nil','nil-stopped','nil-prefault','ordinary-nil'].includes(mode)){if(mode==='ordinary-nil'){window.requestAnimationFrame=captured.requestAnimationFrame;rfSelect(0);rfOrdinary(null);}else request(id,null);trace.push({type:'returned'});await bounded(fence(),'nil error fence');}
  else if(mode==='after-end'){request(id,ts=>emit('outside',ts));o.rec.end(2);terminalFramesBefore=o.frames.map(f=>Array.from(f));lifecycle=[o.frames.length];await bounded(fence(),'post-End native delivery');lifecycle.push(o.frames.length);}
  else if(mode==='ordinary'){window.requestAnimationFrame=captured.requestAnimationFrame;rfSelect(0);let done;const complete=new Promise(resolve=>done=resolve);rfOrdinary(()=>{app('ordinary');done();});await bounded(complete,'ordinary public frame');}
  else{
   let done;const complete=new Promise(resolve=>done=resolve);const first=()=>request(id,ts=>{emit('first',ts);queueMicrotask(()=>{micro=1;app('micro');});request(second,t=>{causal.push({nested:true,parentCompleted,firstFrameFence});emit('nested',t);done();});parentCompleted=true;causal.push('parent-complete');});
   if(mode==='mixed-timer-first')timer(id,()=>app('timer'));first();request(second,ts=>{if(micro!==1)throw Error('microtask must affect subsequent frame callback');emit('second',ts);});native.requestAnimationFrame.call(window,()=>{firstFrameFence=true;causal.push('first-frame-fence');});if(mode==='mixed-frame-first')timer(second,()=>app('timer'));
   trace.push({type:'returned'});await bounded(complete,'native nested frame callbacks');await bounded(fence(),'native completion fence');
  }
  for(const x of owners)x.rec.end(2);
  const terminalFramesAfter=terminalFramesBefore&&o.frames.map(f=>Array.from(f));const terminalNext=terminalFramesBefore?String(o.rec.nextTaskId()):undefined;
  const sessions=owners.map(x=>{const records=x.frames.map(f=>a.decodeRecord(f.subarray(4))),bytes=a.encodeLog(records),decoded=a.decodeLog(bytes);let raw='';for(const b of bytes)raw+=String.fromCharCode(b);return{records:JSON.parse(JSON.stringify(decoded.records,(_,v)=>typeof v==='bigint'?String(v):v)),log:btoa(raw),termination:decoded.termination};});
  return{constructor,clocks,clockBits:clocks.map(v=>a.numberToBits(v).toString()),counts,trace,nativeValues,values,receivers,clearHandles,handles,expectedKinds,errors,appTrace,lifecycle,sessions,causal,cancelThrowIdentity,terminalFramesBefore,terminalFramesAfter,terminalNext};
 },mode);receipt({mode,stage:'record',result});await page.close();return{result,boot};
}
async function replaySession(context,session,boot,mode,expected){
 const page=await context.newPage();await page.goto(url);await page.addScriptTag({content:owner});
 const initial=await page.evaluate(({log,boot,replay,mode})=>{
  frameApi.installReplayRuntime(window,{log});const cursor=__ctReplay,on=cursor.onTask,off=cursor.offTask,observation={on:[],off:[],active:new Set(),callbacks:0};
  cursor.onTask=function(task,cb){observation.on.push(String(task));observation.active.add(String(task));return on.call(this,task,function(...args){observation.callbacks++;try{return cb.apply(this,args);}finally{observation.callbacks--;}});};
  cursor.offTask=function(task){const result=off.call(this,task);observation.off.push(String(task));observation.active.delete(String(task));return result;};globalThis.frameObservation=observation;
  globalThis.xrReadBootContext=boot;(0,eval)(replay);
  const counts={clock:0,request:0,cancel:0,set:0,clear:0},sentinel={rawFrame:true};performance.now=()=>{counts.clock++;throw sentinel;};
  for(const [name,key] of [['requestAnimationFrame','request'],['cancelAnimationFrame','cancel'],['setTimeout','set'],['clearTimeout','clear']])window[name]=()=>{counts[key]++;throw sentinel;};
  for(const [key,call] of [['clock',()=>performance.now()],['request',()=>window.requestAnimationFrame(()=>{})],['cancel',()=>window.cancelAnimationFrame(0)],['set',()=>window.setTimeout(()=>{},0)],['clear',()=>window.clearTimeout(0)]]){let caught;try{call();}catch(e){caught=e;}if(caught!==sentinel||counts[key]!==1)throw Error('Replay trap witness '+key);counts[key]=0;}
  globalThis.frameRawCounts=counts;const clocks=[rfReplayMono(),rfReplayNeMono()],values=[],appTrace=[];let micro=0;
  const app=n=>{appTrace.push(n);document.querySelector('main').textContent='frame:'+appTrace.join(',');};globalThis.replayFrameValue=ts=>values.push(frameApi.numberToBits(ts).toString());globalThis.frameReplayValues=values;globalThis.frameReplayApps=appTrace;
  const request=mode==='public'?rfReplayPublicFrame:rfReplayFrame;
  if(mode==='cancel'||mode==='pending'){const h=request(()=>app('cancelled'));globalThis.oldFrame=h;if(mode==='cancel')rfReplayCancel(h);}
  else{if(mode==='mixed-timer-first')rfReplayTimer(0,()=>app('timer'));request(()=>{app('first');queueMicrotask(()=>{micro=1;app('micro');});request(()=>app('nested'));});request(()=>{if(micro!==1)throw Error('Replay microtask must affect subsequent callback');app('second');});if(mode==='mixed-frame-first')rfReplayTimer(0,()=>app('timer'));}
  const before={off:observation.off.slice(),active:[...observation.active],callbacks:observation.callbacks};let refusal;try{rfReplayDispose();}catch(e){refusal=String(e);}
  return{clocks,counts,refusal,before,after:{off:observation.off.slice(),active:[...observation.active],callbacks:observation.callbacks}};
 },{log:session.log,boot,replay,mode});
 assert.equal(initial.clocks[0],expected.clocks[0]);assert.equal(initial.clocks[1],String(BigInt(Math.trunc(expected.clocks[1]))));assert.match(initial.refusal,/requires completed owner outside callbacks/);assert.deepEqual(initial.after,initial.before,'premature disposal preserves actual handlers');if(mode==='pending')assert.equal(initial.before.active.length,1);
 await page.waitForFunction(()=>['done','diverged'].includes(__ctReplay.status().state));
 const end=await page.evaluate(()=>{const o=frameObservation,before={off:o.off.slice(),active:[...o.active],callbacks:o.callbacks},status=__ctReplay.status();rfReplayDispose();const after={off:o.off.slice(),active:[...o.active],callbacks:o.callbacks};rfReplayDispose();const twice=o.off.slice(),onBefore=o.on.slice(),offBefore=o.off.slice();let disposed;try{rfReplayFrame(()=>{});}catch(e){disposed=String(e);}if(globalThis.oldFrame!==undefined)rfReplayCancel(oldFrame);return{status,afterStatus:__ctReplay.status(),before,after,twice,disposed,onBefore,onAfter:o.on.slice(),offBefore,offAfter:o.off.slice(),counts:frameRawCounts,values:frameReplayValues,appTrace:frameReplayApps};});
 receipt({mode,stage:'replay',end});assert.equal(end.status.state,'done','frame semantic: actual public owner completion');assert.deepEqual(end.appTrace,expected.appTrace,'actual callback/microtask observable DOM order');assert.deepEqual(end.values,mode==='public'?[]:expected.values,'exact private delivered Replay timestamp bits before public erasure');assert.deepEqual(end.counts,{clock:0,request:0,cancel:0,set:0,clear:0},'Replay raw effects zero through completion/disposal');assert.equal(end.before.callbacks,0);assert.deepEqual(end.after.active,[]);assert.deepEqual(end.twice,end.after.off,'second disposal no additional release');assert.equal(end.afterStatus.state,'done');assert.match(end.disposed,/frame clock is disposed/);assert.deepEqual(end.onAfter,end.onBefore);assert.deepEqual(end.offAfter,end.offBefore,'old frame cancel idempotent');
 if(mode==='pending'){assert.deepEqual(end.before.active,['1']);assert.deepEqual(end.before.off,[]);assert.deepEqual(end.after.off,['1'],'actual pending handler released once after DONE');}else assert.deepEqual(end.after.off,end.before.off);
 await page.close();
}
try{
 browser=await chromium.launch({executablePath:process.env.PLAYWRIGHT_CHROMIUM_EXECUTABLE});
 const inverse=process.env.FRAME_INVERSE;
 const modes=inverse?[inverse==='cancel'?'cancel':inverse==='cancel-lifecycle'?'cancel-lifecycle':inverse==='guard'?'guard-inverse':'positive']:['positive','mixed-frame-first','mixed-timer-first','public','cancel','pending','cancel-lifecycle','namespace','callback-error','nil','nil-stopped','nil-prefault','ordinary-nil','ordinary','stopped','sink','encoder','after-end','native-throw','cancel-throw','invalid'];
 for(const [arm,code,list] of [['companion',companion,['positive']],['candidate',candidate,modes]])for(const mode of list){
  const context=await browser.newContext();const {result:r,boot}=await record(context,code,mode);
  if(mode==='invalid'){assert(r.invalid.every(x=>x==='TypeError'));assert.equal(r.before,r.after);assert.equal(r.counts.request,0);assert.equal(r.counts.cancel,0);await context.close();continue;}
  assert.deepEqual(r.constructor.counts,{request:0,cancel:0,lateRequest:0,lateCancel:0,lateClock:0,lateSet:0,lateClear:0});assert.equal(r.constructor.before,r.constructor.after);assert(r.constructor.unselected);
  if(mode==='native-throw'){assert(r.identity);assert.equal(r.next,'2');assert.equal(r.records.filter(x=>x==='TaskReg').length,0);await context.close();continue;}
  assert(r.receivers.every(Boolean),'actual native Window receiver');assert.equal(r.counts.lateRequest,0,'frame semantic: captured native scheduling');assert.equal(r.counts.lateCancel,0);assert.equal(r.counts.lateClock,0,'private Record live clock effects');assert.equal(r.counts.lateSet,0,'private Record live timer effects');assert.equal(r.counts.lateClear,0,'private Record live cancellation effects');assert(r.handles.every(x=>x.handle===x.native),'unchanged native handles; numeric namespaces need not be unequal');
  if(['nil','nil-stopped','nil-prefault','ordinary-nil'].includes(mode)){assert.equal(r.errors.length,1,'asynchronous nil error count');assert(r.errors[0].identity&&r.errors[0].async);assert.equal(r.errors[0].name,'TypeError');}
  else if(mode==='callback-error'||mode==='guard-inverse'){assert.equal(r.errors.length,1,'frame semantic: callback error delivered outside guard');assert(r.errors[0].identity&&r.errors[0].async);assert.deepEqual(r.appTrace,['error','finally','after']);}
  else assert.deepEqual(r.errors,[],'unexpected native errors');
  const records=r.sessions[0].records,regs=records.filter(x=>x.record==='TaskReg'),tasks=records.filter(x=>x.record==='Task'),clocks=records.filter(x=>x.record==='Clock'&&x.src===4);
  if(['nil-stopped','nil-prefault','stopped'].includes(mode)){assert.equal(regs.length,0);assert.equal(tasks.length,0);assert.equal(clocks.length,0);assert.deepEqual(r.terminalFramesAfter,r.terminalFramesBefore,'exact terminal wire bytes remain unchanged');assert.equal(records.at(-1).record,mode==='nil-prefault'?'Refusal':'End');assert.equal(r.terminalNext,'1','inactive registration allocates no owner task ID');if(mode==='stopped'){assert.deepEqual(r.appTrace,['first','micro','second','nested']);assert.deepEqual(r.values,r.nativeValues,'inactive native callback timestamp bits');assert.equal(r.values.length,3);}await context.close();continue;}
  if(mode==='sink'||mode==='encoder'){assert.equal(records.at(-1).record,'Refusal');assert.equal(records.at(-1).feature,'recorder-fault');assert.deepEqual(r.appTrace,['first','micro','second','nested']);assert.equal(r.values.length,3);assert.deepEqual(r.values,r.nativeValues,'owner fault preserves exact original native callback timestamp bits');await context.close();continue;}
  if(mode==='after-end'){assert.equal(r.lifecycle[0],r.lifecycle[1]);assert.deepEqual(r.terminalFramesAfter,r.terminalFramesBefore,'post-End exact terminal bytes unchanged');assert.equal(records.at(-1).record,'End');assert.equal(r.terminalNext,'2','post-End delivery allocates no additional owner ID');assert.deepEqual(r.appTrace,['outside']);assert.deepEqual(r.values,r.nativeValues,'post-End native callback timestamp bits');assert.equal(r.values.length,1);assert.equal(tasks.length,0);assert.equal(clocks.length,0);await context.close();continue;}
  if(mode==='cancel-throw'){assert(r.cancelThrowIdentity,'original native cancellation thrown object');assert.equal(r.counts.cancel,2);assert.equal(r.handles.length,1);const h=r.handles[0].handle;assert.deepEqual(r.clearHandles,[h,h],'throw and successful cleanup retain exact native handle');assert(r.receivers.every(Boolean));assert.deepEqual(r.nativeValues,[],'independent native completion fence proves cancellation');assert.deepEqual(r.values,[]);assert.deepEqual(r.appTrace,[]);assert.equal(regs.length,1);assert.equal(regs[0].kind,3);assert.equal(regs[0].delay_ms,0);assert.equal(tasks.length,0);assert.equal(clocks.length,0);assert.equal(r.sessions[0].termination,'Complete');assert.equal(records.at(-1).record,'End');assert(!records.some(x=>x.record==='Refusal'));await context.close();continue;}
  if(mode==='nil'||mode==='callback-error'||mode==='guard-inverse'){
   const expected=mode==='nil'?1:2;assert.equal(regs.length,expected,'active error successful registration count');assert.equal(tasks.length,expected,'active error actual native task count');assert.equal(clocks.length,expected,'active error delivered Clock4 count');assert(regs.every(x=>x.kind===3&&x.delay_ms===0));assert(tasks.every(x=>x.kind===3));assert.deepEqual(clocks.map(x=>x.bits),r.nativeValues,'active error exact native versus wire bits');assert.equal(r.sessions[0].termination,'Complete');assert.equal(records.at(-1).record,'End');assert(!records.some(x=>x.record==='Refusal'),'application error remains outside owner fault guard');
   if(mode==='nil'){const i=r.trace.findIndex(x=>x.type==='native-error'),bits=r.nativeValues[0];assert.deepEqual(r.trace.slice(i-3,i),[{type:'native-entry',bits},{type:'Task',kind:3},{type:'Clock',src:4,bits}],'active nil native Task Clock error boundary');}
   else{assert.deepEqual(r.values,r.nativeValues,'throwing callback exact native timestamp bits');for(let i=0;i<r.trace.length;i++)if(r.trace[i].type==='callback'){const bits=r.trace[i].bits;assert.deepEqual(r.trace.slice(i-3,i),[{type:'native-entry',bits},{type:'Task',kind:3},{type:'Clock',src:4,bits}],'throwing callback immediate Task Clock boundary');}}
  }
  if(mode==='cancel-lifecycle'){assert(!r.appTrace.includes('nested'),'frame semantic: nested cancelled callback remains absent after native fence');assert(!r.appTrace.includes('sibling'),'same-frame sibling cancellation');assert.deepEqual(r.appTrace,['one','micro']);const [first,sibling,child]=r.lifecycle;assert.deepEqual(r.clearHandles,[sibling,first,0,child,first,first]);assert.equal(regs.length,3);assert.equal(tasks.length,1);assert.equal(clocks.length,1);assert.equal(r.nativeValues.length,1);assert.deepEqual(clocks.map(x=>x.bits),r.nativeValues,'cancel lifecycle exact single delivered Clock4 bits');assert.deepEqual(r.values,r.nativeValues);await context.close();continue;}
  if(mode==='namespace'){assert.deepEqual(regs.map(x=>x.task_id),['1','2']);assert.deepEqual(r.sessions[1].records.filter(x=>x.record==='TaskReg').map(x=>x.task_id),['1']);await context.close();continue;}
  if(['positive','mixed-frame-first','mixed-timer-first','public'].includes(mode)){
   assert.equal(regs.length,r.expectedKinds.length,'frame semantic: exact TaskReg count');assert.deepEqual(regs.map(x=>x.kind),r.expectedKinds,'frame semantic: registration kind');assert(regs.every(x=>x.delay_ms===0),'frame semantic: zero registration delay');assert.equal(new Set(regs.map(x=>x.task_id)).size,regs.length,'frame semantic: actual shared owner namespace');assert.deepEqual(regs.map(x=>x.task_id),regs.map((_,i)=>String(i+1)),'frame semantic: actual shared owner namespace');
   assert.equal(tasks.length,r.expectedKinds.length,'frame semantic: task before callback');const byId=new Map(regs.map((x,i)=>[x.task_id,r.expectedKinds[i]]));assert(tasks.every(x=>x.kind===byId.get(x.task_id)),'frame semantic: delivered Task kind');assert.equal(clocks.length,3,'frame semantic: delivered Clock4 count');assert.equal(r.values.length,3);assert.deepEqual(r.values,r.nativeValues,'frame semantic: original native callback timestamp bits');assert.deepEqual(clocks.map(x=>x.bits),r.nativeValues,'frame semantic: delivered timestamp bits');
   for(let i=0;i<r.trace.length;i++)if(r.trace[i].type==='callback'){const bits=r.trace[i].bits;assert.deepEqual(r.trace.slice(i-3,i),[{type:'native-entry',bits},{type:'Task',kind:3},{type:'Clock',src:4,bits}],'frame semantic: immediate native Task Clock callback order');}
   assert.equal(r.nativeValues[0],r.nativeValues[1],'same native animation frame timestamp');assert.deepEqual(r.causal.filter(x=>typeof x==='object'),[{nested:true,parentCompleted:true,firstFrameFence:true}],'nested callback causally follows parent completion and base-native first-frame fence');assert(r.trace.findIndex(x=>x.type==='returned')<r.trace.findIndex(x=>x.type==='native-entry'));assert(r.appTrace.indexOf('micro')<r.appTrace.indexOf('second'));
  }
  if(mode==='cancel'||mode==='pending'){assert.equal(regs.length,1);assert.equal(tasks.length,0,'frame semantic: cancelled callback remains absent');assert.equal(clocks.length,0);assert.deepEqual(r.appTrace,[],'frame semantic: cancelled callback remains absent');assert.equal(r.counts.cancel,1);}
  if(['positive','mixed-frame-first','mixed-timer-first','public','cancel','pending'].includes(mode)){
   assert.equal(r.sessions[0].termination,'Complete');assert.equal(records.at(-1).record,'End');assert.deepEqual(records.filter(x=>x.record==='Clock'&&x.src===2).map(x=>x.bits),r.clockBits);await replaySession(context,r.sessions[0],boot,mode,r);console.log('frame '+arm+' '+mode+': real Record -> strict codec -> public Replay DONE');
  }
  await context.close();
 }
}finally{await browser?.close();await new Promise(resolve=>server.close(resolve));}
