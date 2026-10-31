/** Actual imported preparation, shipped Recorder/strict codec and real browser
 * platforms. A TEST-owned refuseOnce callback models the documented trusted
 * caller recording/dedup contract; it is not an owner context factory or privacy
 * proof. Actual owner sensitiveState/currentSensitiveValues supply the remaining
 * trusted context fields; a synthetic password field observes live holes policy,
 * without claiming privacy/provenance. Narrow current-native delegates return native objects/errors unchanged
 * and observe ordering/receiver/arguments/new.target. Sink and descriptor faults
 * are deliberate local fault controls. The HTTP server serves real worker/SW/
 * Wasm resources, replacing no platform API, recorder or codec. No forced GC.
 */
import assert from 'node:assert/strict';
import {readFileSync,writeFileSync} from 'node:fs';
import {createRequire} from 'node:module';
import {createServer} from 'node:http';
const artifact=process.env.CT_ARTIFACT;
assert(artifact,'CT_ARTIFACT required');
assert(process.env.REFUSALS_BUNDLE,'REFUSALS_BUNDLE required');
assert(process.env.REFUSALS_RESULTS,'REFUSALS_RESULTS required');
const require=createRequire(artifact+'/packages/boundary-shim/package.json');
const {build}=require('esbuild');
const {chromium}=await import(process.cwd()+'/tests/browser/node_modules/playwright/index.mjs');
const prelude=`
const refusals=require('@codetracer/boundary-shim/dist/browser/seams-refusals.js');
const actualInstall=refusals.patchRefusals;
globalThis.rfImportSnapshot=()=>[window.Worker,window.SharedWorker,window.BroadcastChannel,window.FinalizationRegistry,WebAssembly.instantiate,WebAssembly.instantiateStreaming,WebAssembly.compile,WebAssembly.compileStreaming,WebAssembly.Module,WebAssembly.Instance,window.IDBFactory?.prototype.open,window.IDBFactory?.prototype.deleteDatabase,window.IDBFactory?.prototype.databases,window.WeakRef?.prototype.deref,window.ServiceWorkerContainer?.prototype.addEventListener,Object.getOwnPropertyDescriptor(window.ServiceWorkerContainer?.prototype??{},'onmessage')?.get,Object.getOwnPropertyDescriptor(window.ServiceWorkerContainer?.prototype??{},'onmessage')?.set,window.ServiceWorker?.prototype.postMessage];
globalThis.rfBeforeImport=rfImportSnapshot();
globalThis.rfInstallCount=0;
refusals.patchRefusals=function(c){rfInstallCount++;return actualInstall(c);};
globalThis.rfOwner={...require('@codetracer/boundary-shim/dist/browser/recorder.js'),...require('@codetracer/boundary-shim/dist/browser/originals.js'),...require('@codetracer/boundary-shim/dist/browser/install.js'),...require('@codetracer/boundary-shim/dist/browser/sensitive.js'),...require('@codetracer/boundary-shim/dist/browser/dom-v1.js'),...require('@codetracer/boundary-format'),...require('@codetracer/boundary-replay/dist/browser/runtime.js')};
`;
const bundle=await build({stdin:{resolveDir:artifact,contents:prelude+readFileSync(process.env.REFUSALS_BUNDLE,'utf8')+'\nObject.assign(globalThis,{rfInstall,rfSelected,rfDispatch,rfSelect,rfFakeStart,rfFakeState,rfFakeAdvance,rfFakeEnd,rfHookStart,rfHook,rfHookValue});'},bundle:true,platform:'browser',format:'iife',write:false,metafile:true});
writeFileSync(process.env.REFUSALS_RESULTS+'-browser-bundle.js',bundle.outputFiles[0].text);
writeFileSync(process.env.REFUSALS_RESULTS+'-metafile.json',JSON.stringify(bundle.metafile,null,2));
const wasm=Buffer.from([0,97,115,109,1,0,0,0]);
const server=createServer((q,s)=>{
 if(q.url.startsWith('/worker')){s.setHeader('Content-Type','application/javascript');s.end("onmessage=e=>postMessage('worker:'+e.data)");}
 else if(q.url.startsWith('/shared')){s.setHeader('Content-Type','application/javascript');s.end("onconnect=e=>{const p=e.ports[0];p.onmessage=e=>p.postMessage('shared:'+e.data);p.start();}");}
 else if(q.url.startsWith('/sw.js')){s.setHeader('Content-Type','application/javascript');s.setHeader('Service-Worker-Allowed','/');s.end("self.addEventListener('install',e=>e.waitUntil(self.skipWaiting()));self.addEventListener('activate',e=>e.waitUntil(self.clients.claim()));self.addEventListener('message',e=>e.source.postMessage('sw:'+e.data));");}
 else if(q.url.startsWith('/wasm')){s.setHeader('Content-Type','application/wasm');s.end(wasm);}
 else{s.end('<!doctype html><main>Actual refusal preparation</main>');}
});
await new Promise(r=>server.listen(0,'127.0.0.1',r));
const base='http://127.0.0.1:'+server.address().port;
const browser=await chromium.launch({executablePath:process.env.PLAYWRIGHT_CHROMIUM_EXECUTABLE});
const results=[];
async function realm(){const context=await browser.newContext();const p=await context.newPage();await p.goto(base);await p.addScriptTag({content:bundle.outputFiles[0].text});return {context,p};}
// This function executes entirely in one actual browser realm. Its independent
// strict decoded frames are inspected by the Node assertions below.
async function exercise(p,op,mode='positive'){
 return p.evaluate(async({op,mode})=>{
  const importUnchanged=rfImportSnapshot().every((v,i)=>v===rfBeforeImport[i]);
  const a=rfOwner,frames=[],calls=[],refused=new Set(),faults={halts:0,ends:0};
  let failSink=false,escaped=null;
  const rec=new a.Recorder({checkpointScheme:'dom-v1',checkpointHash:()=>a.domV1Hash(document),sink:{append(f){if(failSink){failSink=false;throw new Error('actual sink fault');}frames.push(f);},end(u,f){faults.ends++;frames.push(f);},halt(){faults.halts++;}}});
  const originals=a.captureOriginals(window);
  rec.start({vocab:1,protocol_level:0,recorder_id:'private-refusals',framework:'',build_hash:'a'.repeat(64),session_id:'1'.repeat(32),prev_session:'',capabilities:'[]'},a.readEnvironment(window,originals));
  const decoded=()=>frames.map(f=>a.decodeRecord(f.subarray(4)));
  const markers=()=>decoded().filter(r=>r.record==='Refusal');
  const cursorRecorder=new a.Recorder({checkpointScheme:'dom-v1',checkpointHash:()=>a.domV1Hash(document)});
  cursorRecorder.start({vocab:1,protocol_level:0,recorder_id:'pending-cursor-control',framework:'',build_hash:'b'.repeat(64),session_id:'2'.repeat(32),prev_session:'',capabilities:'[]'},a.readEnvironment(window,originals));
  cursorRecorder.emit('Clock',{src:2,bits:a.numberToBits(originals.performanceNow.call(performance))});cursorRecorder.end(2);
  const cursorLog=a.encodeLog(cursorRecorder.frameList.map(f=>a.decodeRecord(f.subarray(4))));let raw='';for(const b of cursorLog)raw+=String.fromCharCode(b);
  const cursor=a.installReplayRuntime(window,{log:btoa(raw)});
  const snapshotCursor=()=>JSON.stringify({next:cursor.peek(),failed:cursor.failed},(k,v)=>typeof v==='bigint'?v.toString():v);
  const cursorBefore=snapshotCursor(),cursorObject=window.__ctReplay;
  const sensitive=a.sensitiveState(window);
  const policyField=document.createElement('input');policyField.type='password';policyField.value='owner-policy-fixture-first';document.body.append(policyField);
  const holes=()=>a.currentSensitiveValues(window,sensitive);
  const policyBefore=holes();policyField.value='owner-policy-fixture-next-longer';
  const ctx={w:window,rec,orig:originals,sensitive,holes,refuseOnce(feature,detail){if(!rec.recording||refused.has(feature))return;refused.add(feature);rec.guard(()=>rec.emit('Refusal',{feature,detail}));}};
  const expectation={worker:['worker','new Worker'],shared:['shared-worker','new SharedWorker'],broadcast:['broadcast-channel','new BroadcastChannel'],finalization:['finalization-registry','new FinalizationRegistry'],weak:['weakref','WeakRef.deref'],idbOpen:['indexeddb','indexedDB.open'],idbDelete:['indexeddb','indexedDB.deleteDatabase'],idbDatabases:['indexeddb','indexedDB.databases'],wasmInstantiate:['webassembly','WebAssembly.instantiate'],wasmInstantiateStreaming:['webassembly','WebAssembly.instantiateStreaming'],wasmCompile:['webassembly','WebAssembly.compile'],wasmCompileStreaming:['webassembly','WebAssembly.compileStreaming'],wasmModule:['webassembly','new Module'],wasmInstance:['webassembly','new Instance'],swListener:['service-worker-message','navigator.serviceWorker message listener'],swOnmessage:['service-worker-message','navigator.serviceWorker.onmessage'],swPost:['service-worker-message','ServiceWorker.postMessage']}[op];
  const [feature,detail]=expectation;
  const gates=['Worker','SharedWorker','BroadcastChannel','FinalizationRegistry','WeakRef','IDBFactory','ServiceWorkerContainer','ServiceWorker'];
  for(const k of gates)if(typeof window[k]!=='function')throw Error('HOST GATE required '+k);
  for(const k of ['instantiate','instantiateStreaming','compile','compileStreaming','Module','Instance'])if(typeof WebAssembly[k]!=='function')throw Error('HOST GATE required WebAssembly.'+k);
  for(const k of ['open','deleteDatabase','databases'])if(typeof IDBFactory.prototype[k]!=='function')throw Error('HOST GATE required indexedDB.'+k);
  const sd=Object.getOwnPropertyDescriptor(ServiceWorkerContainer.prototype,'onmessage');
  if(!sd?.get||!sd?.set)throw Error('HOST GATE required serviceWorker.onmessage descriptor');
  let owner,key,ctor=false,accessor=false;
  const constructors={worker:'Worker',shared:'SharedWorker',broadcast:'BroadcastChannel',finalization:'FinalizationRegistry',wasmModule:'Module',wasmInstance:'Instance'};
  if(constructors[op]){owner=op.startsWith('wasm')?WebAssembly:window;key=constructors[op];ctor=true;}
  else if(op.startsWith('wasm')){owner=WebAssembly;key={wasmInstantiate:'instantiate',wasmInstantiateStreaming:'instantiateStreaming',wasmCompile:'compile',wasmCompileStreaming:'compileStreaming'}[op];}
  else if(op.startsWith('idb')){owner=IDBFactory.prototype;key={idbOpen:'open',idbDelete:'deleteDatabase',idbDatabases:'databases'}[op];}
  else if(op==='weak'){owner=WeakRef.prototype;key='deref';}
  else if(op==='swPost'){owner=ServiceWorker.prototype;key='postMessage';}
  else {owner=ServiceWorkerContainer.prototype;key=op==='swListener'?'addEventListener':'onmessage';accessor=op==='swOnmessage';}
  let declaring=owner;while(declaring&&!Object.prototype.hasOwnProperty.call(declaring,key))declaring=Object.getPrototypeOf(declaring);
  const descriptor=declaring?Object.getOwnPropertyDescriptor(declaring,key):undefined;
  if(!descriptor||!descriptor.configurable)throw Error('HOST GATE replaceable '+key);
  const native=accessor?descriptor.set:owner[key];
  let latestError=null;
  function observe(receiver,args,newTarget,invoke){
   const call={receiver,args,newTarget,markers:markers().map(r=>({feature:r.feature,detail:r.detail})),result:null,error:null};calls.push(call);
   try{return call.result=invoke();}catch(e){call.error=e;latestError=e;throw e;}
  }
  let delegate;
  if(ctor){delegate=function(...args){const n=new.target;return observe(this,args,n,()=>n?Reflect.construct(native,args,n):Reflect.apply(native,this,args));};delegate.prototype=native.prototype;Object.setPrototypeOf(delegate,native);Object.defineProperty(delegate,'name',{value:native.name});Object.defineProperty(delegate,'length',{value:native.length});}
  else{delegate=function(...args){return observe(this,args,undefined,()=>Reflect.apply(native,this,args));};Object.defineProperty(delegate,'name',{value:key});Object.defineProperty(delegate,'length',{value:native.length});}
  if(accessor)Object.defineProperty(owner,key,{...descriptor,set:delegate});else Object.defineProperty(owner,key,{...descriptor,value:delegate});
  // A genuine pre-install current replacement, not ctx.orig, must be captured.
  const current=accessor?Object.getOwnPropertyDescriptor(owner,key).set:owner[key];
  const support={broadcastPeers:0,swListenerRegistrations:0,swPosts:0};
  const nativeSwAdd=ServiceWorkerContainer.prototype.addEventListener,nativeSwPost=ServiceWorker.prototype.postMessage;
  let sw,swRegistration;
  if(op.startsWith('sw')){
   swRegistration=await navigator.serviceWorker.register('/sw.js');
   await navigator.serviceWorker.ready;
   sw=swRegistration.active;
   if(!sw)throw Error('HOST GATE active local service worker');
   if(!navigator.serviceWorker.controller)await new Promise(resolve=>navigator.serviceWorker.addEventListener('controllerchange',resolve,{once:true}));
  }
  const setupNativePaths=calls.length;
  rfSelect(mode==='clock-real'?0:mode==='clock-custom'?2:1);
  rfHookStart();const hook=rfHook();const hookBefore=rfHookValue();
  const clock=rfSelected(),dispatch=rfDispatch();rfFakeStart();const fakeBefore=rfFakeState();
  if(mode==='end')rec.end(1);
  if(mode==='halt'||mode==='stopped')rec.halt();
  if(mode==='setup-fault')Object.defineProperty(window,'SharedWorker',{...Object.getOwnPropertyDescriptor(window,'SharedWorker'),writable:false,configurable:false});
  const instanceModule=op==='wasmInstance'?new WebAssembly.Module(new Uint8Array([0,97,115,109,1,0,0,0])):null;
  const beforeInstallMarkers=markers().length;
  if(mode!=='plain')try{rfInstall(ctx);}catch(e){escaped={name:e.name,message:e.message};}
  const installed=accessor?Object.getOwnPropertyDescriptor(owner,key).set:owner[key];
  const installCount=rfInstallCount;
  const afterInstallFrames=frames.length;
  const completeContext=Object.keys(ctx).sort().join(',')==='holes,orig,rec,refuseOnce,sensitive,w'&&ctx.w===window&&ctx.rec===rec&&rec instanceof a.Recorder&&ctx.orig===originals&&originals.fetch===window.fetch&&ctx.sensitive===a.sensitiveState(window)&&ctx.sensitive.getters.inputValue===Object.getOwnPropertyDescriptor(HTMLInputElement.prototype,'value').get&&ctx.holes===holes;
  const policyAfter=ctx.holes();
  if(mode==='sink-fault')failSink=true;
  const bytes=new Uint8Array([0,97,115,109,1,0,0,0]);
  const retained={actual:'retained-test-object'},weak=new WeakRef(retained);
  const id='rf-'+op+'-'+mode;
  const cleanup=[];
  let actualResult=null,behavior=null,errorIdentity=true,expectedArgs=null,expectedReceiver=null,expectedNewTarget=undefined,targetDelivery=null;
  async function operation(iteration){
   const invalid=mode==='new-failure'||mode==='method-failure';
   if(ctor){
    let args;
    if(op==='worker'||op==='shared')args=invalid?[]:[op==='worker'?'/worker.js':'/shared.js'];
    else if(op==='broadcast')args=invalid?[]:[id];
    else if(op==='finalization')args=[invalid?null:()=>{}];
    else if(op==='wasmModule')args=[invalid?null:bytes];
    else args=[invalid?null:instanceModule];
    expectedArgs=args;expectedReceiver=null;
    const C=owner[key];expectedNewTarget=mode==='no-new'?undefined:C;
    const result=mode==='no-new'?Reflect.apply(C,undefined,args):Reflect.construct(C,args,C);actualResult=result;
    if(op==='worker'){cleanup.push(()=>result.terminate());behavior=await new Promise((r,j)=>{result.onmessage=e=>r(e.data);result.onerror=j;result.postMessage('native'+iteration);});}
    else if(op==='shared'){result.port.start();cleanup.push(()=>result.port.close());behavior=await new Promise(r=>{result.port.onmessage=e=>r(e.data);result.port.postMessage('native'+iteration);});}
    else if(op==='broadcast'){const peer=Reflect.construct(native,[id]);support.broadcastPeers++;cleanup.push(()=>{peer.close();result.close();});behavior=await new Promise(r=>{result.onmessage=e=>r(e.data);peer.postMessage('native'+iteration);});}
    else if(op==='finalization'){result.register(retained,iteration,retained);behavior=result.unregister(retained);}
    else behavior=result instanceof (op==='wasmModule'?WebAssembly.Module:WebAssembly.Instance);
   }else{
    let receiver,args;
    if(op.startsWith('wasm')){receiver=WebAssembly;args=[invalid?null:op.endsWith('Streaming')?fetch('/wasm'):bytes];}
    else if(op.startsWith('idb')){receiver=indexedDB;args=op==='idbDatabases'?[]:[invalid?'':id];if(mode==='method-failure')receiver={};}
    else if(op==='weak'){receiver=mode==='method-failure'?{}:weak;args=[];}
    else if(op.startsWith('sw')){
     const expected='sw:native'+iteration;
     let deliver;
     const pending=new Promise(resolve=>{deliver=resolve;});
     function targetCallback(event){
      if(event.data!==expected)return;
      targetDelivery={data:event.data,receiver:this===navigator.serviceWorker,source:event.source===sw,trusted:event.isTrusted,target:op!=='swPost'};
      deliver(event.data);
     }
     if(op==='swPost'){
      receiver=mode==='method-failure'?{}:sw;args=['native'+iteration];
      if(mode!=='method-failure'){Reflect.apply(nativeSwAdd,navigator.serviceWorker,['message',targetCallback]);support.swListenerRegistrations++;cleanup.push(()=>navigator.serviceWorker.removeEventListener('message',targetCallback));}
     }else{receiver=navigator.serviceWorker;args=op==='swListener'?['message',targetCallback]:[targetCallback];}
     expectedReceiver=receiver;expectedArgs=args;
     if(op==='swOnmessage'){navigator.serviceWorker.onmessage=args[0];actualResult=undefined;}
     else actualResult=Reflect.apply(owner[key],receiver,args);
     if(op!=='swPost'){Reflect.apply(nativeSwPost,sw,['native'+iteration]);support.swPosts++;}
     behavior=await pending;
     if(op==='swListener')navigator.serviceWorker.removeEventListener('message',targetCallback);
     return;
    }
    expectedReceiver=receiver;expectedArgs=args;
    actualResult=Reflect.apply(owner[key],receiver,args);
    if(op.startsWith('wasm')){const r=await actualResult;behavior=op.startsWith('wasmCompile')?r instanceof WebAssembly.Module:r.instance instanceof WebAssembly.Instance;}
    else if(op==='idbOpen'||op==='idbDelete'){behavior=await new Promise((r,j)=>{actualResult.onsuccess=()=>{if(actualResult.result?.close)actualResult.result.close();r(true);};actualResult.onerror=()=>j(actualResult.error);});}
    else if(op==='idbDatabases'){behavior=Array.isArray(await actualResult);}
    else if(op==='weak'){behavior=actualResult===retained;}

   }
  }
  const invocationProof=[];
  for(let i=0;i<2;i++){
   const before=calls.length;targetDelivery=null;
   try{await operation(i);}catch(e){errorIdentity=errorIdentity&&e===latestError;behavior={error:e.name};}
   const relevant=calls.slice(before);const call=relevant[0];
   invocationProof.push({targetDelivery,count:relevant.length,argumentIdentity:!!call&&call.args.length===expectedArgs.length&&call.args.every((v,n)=>v===expectedArgs[n]),receiverIdentity:!!call&&(ctor||call.receiver===expectedReceiver),newTargetIdentity:!!call&&call.newTarget===expectedNewTarget,resultIdentity:!!call&&(call.error!==null||call.result===actualResult),nativeError:call?.error?.name??null,errorIdentity,markersAtEntry:call?.markers??[],behavior});
  }
  const sameClock=rfSelected()===clock,afterDispatch=rfDispatch(),sameHook=rfHook()===hook,fakeAfter=rfFakeState();rfFakeAdvance();const fakeAdvanced=rfFakeState();rfFakeEnd();const hookAfter=rfHookValue();
  for(const dispose of cleanup)dispose();
  if(swRegistration)await swRegistration.unregister();
  const allMarkers=markers().map(r=>({feature:r.feature,detail:r.detail}));
  const nativePaths=calls.length;
  return {completeContext,policyBefore,policyAfter,support,setupNativePaths,targetNativePaths:invocationProof.reduce((n,r)=>n+r.count,0),importUnchanged,cursorQuiet:cursorBefore===snapshotCursor()&&window.__ctReplay===cursorObject,cursorPending:cursor.peek()?.kind,op,mode,feature,detail,installCount,beforeInstallMarkers,afterInstallFrames,framesAtEnd:frames.length,markerCount:allMarkers.filter(r=>r.feature===feature).length,markers:allMarkers,recording:rec.recording,faults,escaped,invocationProof,nativePaths,sameClock,sameHook,hookBefore,hookAfter,dispatch,afterDispatch,fakeBefore,fakeAfter,fakeAdvanced,currentCaptured:current!==installed,prototype:!ctor||installed.prototype===native.prototype,statics:!ctor||Object.getPrototypeOf(installed)===(mode==='plain'?native:delegate),name:accessor?Object.getOwnPropertyDescriptor(owner,key).set.name===(mode==='plain'?'onmessage':'set'):installed.name===current.name,length:accessor?Object.getOwnPropertyDescriptor(owner,key).set.length===1:installed.length===(op==='swListener'&&mode!=='plain'?1:current.length),getterIdentity:!accessor||Object.getOwnPropertyDescriptor(owner,key).get===descriptor.get,descriptorIdentity:!accessor||['enumerable','configurable'].every(k=>Object.getOwnPropertyDescriptor(owner,key)[k]===descriptor[k])};
 },{op,mode});
}
function check(r){
 results.push(r);
 writeFileSync(process.env.REFUSALS_RESULTS,JSON.stringify(results,null,2));
 const inactive=['plain','end','halt','stopped','setup-fault'].includes(r.mode);
 // Native results are checked before semantic mutation assertions so an inverse
 // cannot count a missing platform execution or setup exception as a kill.
 assert(r.importUnchanged,'semantic: module import alone patches no native property');
 assert(r.completeContext,'semantic: full actual owner trusted context linkage');
 assert.deepEqual(r.policyBefore,['owner-policy-fixture-first'],'semantic: actual owner initial sensitive policy');
 assert.deepEqual(r.policyAfter,['owner-policy-fixture-next-longer'],'semantic: actual owner live holes policy');
 assert.equal(r.support.broadcastPeers,r.op==='broadcast'&&!['no-new','new-failure'].includes(r.mode)?2:0,'semantic: native auxiliary BC peers counted separately');
 assert.equal(r.support.swPosts,r.op==='swListener'||r.op==='swOnmessage'?2:0,'semantic: only support stimulus for listener target');
 assert.equal(r.support.swListenerRegistrations,r.op==='swPost'&&r.mode!=='method-failure'?2:0,'semantic: post observation armed before sole target');
 assert.equal(r.targetNativePaths,2,'semantic: exactly two measured native entries');
 assert.equal(r.nativePaths,r.setupNativePaths+r.targetNativePaths,'semantic: native setup and target accounting');
 for(const call of r.invocationProof){assert.equal(call.count,1,'semantic: exactly one native target invocation');assert(call.argumentIdentity,'native exact argument identity');assert(call.receiverIdentity,'native exact receiver');assert(call.newTargetIdentity,'native exact new.target');assert(call.resultIdentity,'native result/error identity');assert(call.errorIdentity,'native exception identity');}
 if(!['no-new','new-failure','method-failure'].includes(r.mode)){
  for(const call of r.invocationProof){const expected=r.op==='worker'?'worker:native':r.op==='shared'?'shared:native':r.op.startsWith('sw')?'sw:native':r.op==='broadcast'?'native':true;assert(typeof expected==='string'?call.behavior===expected+r.invocationProof.indexOf(call):call.behavior===true,'semantic: actual platform success');}
  if(r.op.startsWith('sw'))for(const call of r.invocationProof){assert(call.targetDelivery&&call.targetDelivery.receiver&&call.targetDelivery.source&&call.targetDelivery.trusted,'semantic: real service-worker callback delivery');assert.equal(call.targetDelivery.target,r.op!=='swPost','semantic: observed actual installed target callback');}
 }else for(const call of r.invocationProof)assert(call.nativeError,'semantic: actual native failure');
 assert(r.cursorQuiet&&r.cursorPending==='Clock','actual owner pending cursor identity/state unchanged');
 assert(r.sameHook&&r.hookBefore===777&&r.hookAfter===777,'NE explicit hook identity/value unchanged');
 assert(r.sameClock&&r.dispatch===r.afterDispatch,'same-program selected clock and dispatch unchanged');
 assert.deepEqual(r.fakeBefore,r.fakeAfter,'NE Fake priority unchanged');assert.equal(r.fakeAdvanced.milliseconds,19);assert.equal(r.fakeAdvanced.fired,1);
 assert.equal(r.beforeInstallMarkers,0,'import alone patches nothing');
 if(r.mode==='setup-fault'){
  assert.equal(r.escaped,null,'semantic: setup fault stays in actual Recorder.guard');
  assert.equal(r.recording,false,'semantic: setup fault stops actual Recorder');
  assert.equal(r.faults.halts,1,'semantic: setup fault halts actual sink');
  assert.equal(r.markers.filter(m=>m.feature==='recorder-fault').length,1,'semantic: actual setup recorder-fault');
  assert(r.currentCaptured,'partial earlier patch remains installed');
  assert.equal(r.framesAtEnd,r.afterInstallFrames,'semantic: no late frames after setup fault');
 }else if(r.mode==='no-new'){
  assert.equal(r.markerCount,0,'semantic: invalid no-new emits no feature Refusal');
 }else if(inactive){assert.equal(r.markerCount,0,'semantic: no late/plain feature records');if(r.mode!=='plain')assert.equal(r.framesAtEnd,r.afterInstallFrames,'no late frames');}
 else if(r.mode==='sink-fault'){assert.equal(r.framesAtEnd,r.afterInstallFrames+1,'semantic: single fault frame then no late frames');assert.equal(r.markerCount,0);assert.equal(r.recording,false);assert.equal(r.faults.halts,1);assert.equal(r.markers.filter(m=>m.feature==='recorder-fault').length,1);}
 else {
  assert.equal(r.markerCount,1,'semantic: exact first-use feature marker');
  assert(r.invocationProof[0].markersAtEntry.some(m=>m.feature===r.feature&&m.detail===r.detail),'semantic: named first Refusal before native entry');
  if(r.mode==='sink-fault'){assert.equal(r.recording,false);assert.equal(r.faults.halts,1);assert.equal(r.markers.filter(m=>m.feature==='recorder-fault').length,1);}
 }
 if(r.mode!=='plain')assert.equal(r.installCount,1,'semantic: actual owner installer called once');
 else assert.equal(r.installCount,0);
 assert(r.prototype&&r.statics&&r.name&&r.length&&r.getterIdentity&&r.descriptorIdentity,'exact owner constructor/method metadata retained');
}
try{
 const operations=['worker','shared','broadcast','finalization','wasmInstantiate','wasmInstantiateStreaming','wasmCompile','wasmCompileStreaming','wasmModule','wasmInstance','idbOpen','idbDelete','idbDatabases','weak','swListener','swOnmessage','swPost'];
 const inverse=process.env.REFUSALS_INVERSE;
 const cases=inverse==='remove-guard'?[['worker','setup-fault']]:inverse?[['worker','positive']]:[
 ...operations.map(op=>[op,'positive']),...operations.map(op=>[op,'plain']),...['worker','shared','broadcast','finalization','wasmModule','wasmInstance'].flatMap(op=>[[op,'no-new'],[op,'new-failure']]),['weak','method-failure'],['idbOpen','method-failure'],['swPost','method-failure'],...['end','halt','stopped','sink-fault','setup-fault','clock-real','clock-custom'].map(mode=>['worker',mode])];
 for(const [op,mode] of cases){const {context,p}=await realm();try{check(await exercise(p,op,mode));}finally{await context.close();}}
 console.log('Record refusal owner PASS '+results.length+' real fresh-realm cases');
}finally{await browser.close();await new Promise(r=>server.close(r));}
