/** Native Chromium events and real installed owner construction/log/owned loop.
 * Local HTTP provides only static markup. Counted event/property/clock wrappers
 * are individually witnessed fault controls for the before-effects boundary;
 * they do not replace native delivery, DOM, private backend or owner cursor. */
import assert from 'node:assert/strict';
import {readFileSync,appendFileSync} from 'node:fs';
import {createRequire} from 'node:module';
import {createServer} from 'node:http';
const root=process.cwd(),artifact=process.env.CT_ARTIFACT;
assert(artifact,'actual owner artifact required');
assert(process.env.DELIVERY_CONTEXT,'DELIVERY_CONTEXT required: just-compiled context must be explicit');
const {chromium}=await import(root+'/tests/browser/node_modules/playwright/index.mjs');
const require=createRequire(artifact+'/packages/boundary-shim/package.json');
const {build}=require('esbuild');
const owner=(await build({stdin:{resolveDir:artifact,contents:`
import {Recorder,numberToBits} from '@codetracer/boundary-shim/dist/browser/recorder.js';
import {captureOriginals} from '@codetracer/boundary-shim/dist/browser/originals.js';
import {readEnvironment} from '@codetracer/boundary-shim/dist/browser/install.js';
import {domV1Hash} from '@codetracer/boundary-shim/dist/browser/dom-v1.js';
import {encodeLog,decodeRecord} from '@codetracer/boundary-format';
import {installReplayRuntime} from '@codetracer/boundary-replay/dist/browser/runtime.js';
globalThis.deliveryStart=()=>{
 const orig=captureOriginals(window),frames=[],samples=[];
 const rec=new Recorder({checkpointScheme:'dom-v1',checkpointHash:()=>domV1Hash(document),sink:{append(f){frames.push(f)},end(){},halt(){}}});
 rec.start({vocab:1,protocol_level:0,recorder_id:'listener-delivery',framework:'',build_hash:'a'.repeat(64),session_id:'1'.repeat(32),prev_session:'',capabilities:'[]'},readEnvironment(window,orig));
 for(let i=0;i<2;i++){const value=orig.performanceNow.call(performance);samples.push(value);rec.emit('Clock',{src:2,bits:numberToBits(value)});}
 rec.end(2);const records=frames.map(f=>decodeRecord(f.subarray(4))),log=encodeLog(records);let bytes='';for(const b of log)bytes+=String.fromCharCode(b);
 installReplayRuntime(window,{log:btoa(bytes)});return {samples,kinds:records.map(r=>r.record)};
};`},bundle:true,platform:'browser',format:'iife',write:false})).outputFiles[0].text;
const bundle=readFileSync(process.env.DELIVERY_BUNDLE,'utf8');
const capture=readFileSync(process.env.DELIVERY_CONTEXT,'utf8');
const mutant=process.env.DELIVERY_MUTANT;
const server=createServer((req,res)=>res.end('<!doctype html><main id="root"><button id="child">Native delivery</button></main>'));
await new Promise(r=>server.listen(0,'127.0.0.1',r));
const url=`http://127.0.0.1:${server.address().port}/`;
let browser;
function receipt(value){if(process.env.DELIVERY_RECEIPTS)appendFileSync(process.env.DELIVERY_RECEIPTS,JSON.stringify(value)+'\n');}
try{
 browser=await chromium.launch({executablePath:process.env.PLAYWRIGHT_CHROMIUM_EXECUTABLE});
 // Companion session finishes before either inverse's intentionally failing case.
 const paths=mutant?(mutant==='listen'?['delegate','listen']:['listen','delegate'].includes(mutant)?['listen','delegate']:['delegate','listen']):['listen','delegate'];
 for(const path of paths){
  const context=await browser.newContext();
  const prior=await context.newPage();await prior.goto(url);
  await prior.evaluate(()=>{globalThis._$HY={seed:731,buildId:'genuine-context',assignment:{read:'A'}};});
  await prior.addScriptTag({content:capture});const boot=await prior.evaluate(()=>xrReadBootContext);await prior.close();
  const page=await context.newPage();await page.goto(url);await page.addScriptTag({content:owner});
  const unexpected=[];page.on('pageerror',e=>unexpected.push(String(e)));
  const setup=await page.evaluate(({bundle,boot,path})=>{
   globalThis.deliveryBoot=boot;const recorded=deliveryStart();(0,eval)(bundle);deliveryInitialize();
   const node=document.getElementById('child'),eventName='delivery-'+path;
   const counters={native:0,handler:0,hook:0,time:0,target:0,type:0,node:0,parent:0},errors=[];
   const nativeAdd=EventTarget.prototype.addEventListener,nativeDispatch=EventTarget.prototype.dispatchEvent;
   nativeAdd.call(window,'error',e=>{errors.push(String(e.error||e.message));e.preventDefault();});
   nativeAdd.call(node,eventName,()=>counters.native++);
   const observations=[],hookRecords=[],nativeTimes=[];
   const callback=function(ev){
    counters.handler++;
    const observation={receiver:this,event:ev,target:ev.target,currentTarget:ev.currentTarget,phase:ev.eventPhase,preventedBefore:ev.defaultPrevented};
    if(globalThis.deliveryState?.resuming)ev.preventDefault();
    observation.preventedAfter=ev.defaultPrevented;observations.push(observation);
   };
   if(path==='listen'){deliveryHook(record=>{counters.hook++;hookRecords.push(record)});globalThis.deliveryRemove=deliveryRegister(node,eventName,callback,false);}
   else {deliveryDelegate(node,eventName,callback);deliveryDelegateType(eventName);}
   const nativeNow=performance.now;performance.now=function(){counters.time++;const value=nativeNow.call(this);nativeTimes.push(value);return value};
   performance.now();if(counters.time!==1)throw Error('time trap witness');counters.time=0;nativeTimes.length=0;
   function eventWithProbe(probe){
    const ev=new Event(eventName,{bubbles:true,cancelable:true});
    if(probe==='target'||probe==='type'){
     const desc=Object.getOwnPropertyDescriptor(Event.prototype,probe);
     Object.defineProperty(ev,probe,{configurable:true,get(){counters[probe]++;return desc.get.call(this)}});
     void ev[probe];if(counters[probe]!==1)throw Error('event trap witness '+probe);counters[probe]=0;
    }
    return ev;
   }
   // Node property and parent traversal are separately witnessed; no first
   // throwing getter conceals the remaining independent controls.
   function probeNode(probe){
    if(probe==='node'){
     const key='$$'+eventName,value=node[key];
     Object.defineProperty(node,key,{configurable:true,get(){counters.node++;return value}});
     void node[key];if(counters.node!==1)throw Error('node trap witness');counters.node=0;
     return ()=>{Object.defineProperty(node,key,{value,writable:true,configurable:true})};
    }
    if(probe==='parent'){
     const desc=Object.getOwnPropertyDescriptor(Node.prototype,'parentNode');
     Object.defineProperty(node,'parentNode',{configurable:true,get(){counters.parent++;return desc.get.call(this)}});
     void node.parentNode;if(counters.parent!==1)throw Error('parent trap witness');counters.parent=0;
     return ()=>delete node.parentNode;
    }
    return ()=>{};
   }
   globalThis.deliveryState={path,node,eventName,counters,errors,nativeDispatch,eventWithProbe,probeNode,recorded,observations,hookRecords,nativeNow,nativeTimes,resuming:false};
   deliveryReplay();const first=deliveryClock();
   return {first,recorded};
  },{bundle,boot,path});
  assert.equal(setup.first,BigInt(Math.trunc(setup.recorded.samples[0]*1e6)).toString(),'actual public Clock2 before native delivery');
  const probes=path==='listen'?['target','type']:['target','type','node','parent'];
  for(const probe of probes){
   const result=await page.evaluate(probe=>{
    const s=deliveryState;for(const k of Object.keys(s.counters))s.counters[k]=0;s.errors.length=0;
    const ev=s.eventWithProbe(probe),restore=s.probeNode(probe),before=deliveryReplaySequence();
    const returned=s.nativeDispatch.call(s.node,ev);restore();
    return {before,after:deliveryReplaySequence(),returned,counters:{...s.counters},errors:[...s.errors]};
   },probe);receipt({path,probe,result});
   assert.equal(result.counters.native,1,'native delivery witness');
   // Semantic assertions deliberately precede message checks for compiled inverses.
   assert.equal(result.after,result.before,'listener-delivery-before-dispatch');
   assert.equal(result.counters[probe],0,path==='delegate'?'delegated-delivery-before-metadata':'listener-delivery-before-event-metadata');
   assert.equal(result.counters.handler,0,'listener-delivery-before-handler');
   assert.equal(result.counters.hook,0,'listener-delivery-before-hook');
   assert.equal(result.counters.time,0,'listener-delivery-before-clock');
   assert.equal(result.returned,true,'native dispatch returns normally for listener refusal');
   assert.equal(result.errors.length,1,'one native window error');
   assert.match(result.errors[0],new RegExp('internal read Replay does not support '+(path==='listen'?'listen':'delegateEvents')));
  }
  const consumed=await page.evaluate(()=>({millis:deliveryNeClock(),sequence:deliveryReplaySequence()}));
  assert.equal(consumed.millis,BigInt(Math.trunc(setup.recorded.samples[1])).toString(),'remaining public NE Clock2 after refused native delivery');
  assert.equal(consumed.sequence,'0');
  await page.waitForFunction(()=>['done','diverged'].includes(__ctReplay.status().state));
  const done=await page.evaluate(()=>__ctReplay.status());receipt({path,stage:'done',done});
  assert.equal(done.state,'done','actual owned loop DOM checkpoint and End');assert.equal(done.tasks,0);
  assert.deepEqual(unexpected,[]);
  console.log(path+': native refusal before effects, actual public Clock2 and owner DONE PASS');
  // Retained registrations resume with actual native delivery after switching
  // away; the new guard must query current selection, not a stale boolean.
  for(const mode of ['test','custom','real','nil','direct-nil']){
   const resumed=await page.evaluate(mode=>{
    const s=deliveryState;deliveryChoose(mode);for(const k of Object.keys(s.counters))s.counters[k]=0;s.errors.length=0;
    s.observations.length=0;s.hookRecords.length=0;s.nativeTimes.length=0;
    // These captured-native bounds never call backend() or initialize a nil
    // selector; only delivery is allowed to perform the existing lazy reentry.
    const beforeSequence=deliverySequence(),lower=s.nativeNow.call(performance);
    const ev=new Event(s.eventName,{bubbles:true,cancelable:true});s.resuming=true;
    const returned=s.nativeDispatch.call(s.node,ev);s.resuming=false;
    const upper=s.nativeNow.call(performance);
    return {counters:{...s.counters},errors:[...s.errors],sequence:deliverySequence(),beforeSequence,lower,upper,returned,
     identities:s.observations.map(o=>({receiver:o.receiver===s.node,event:o.event===ev,target:o.target===s.node,currentTarget:o.currentTarget===(s.path==='listen'?s.node:document),phase:o.phase,preventedBefore:o.preventedBefore,preventedAfter:o.preventedAfter})),
     records:s.hookRecords.map(r=>({seq:r.seq,timeStamp:r.timeStamp,finalized:r.finalized,defaultPrevented:r.payload.defaultPrevented})),nativeTimes:[...s.nativeTimes]};
   },mode);receipt({path,mode,resumed});
   assert.equal(resumed.counters.handler,1,'retained handler resumes '+mode);assert.equal(resumed.errors.length,0);
   if(path==='listen'){assert.equal(resumed.counters.hook,1);assert.equal(resumed.sequence,'1');}
   assert.equal(resumed.counters.native,1,'retained-resume genuine native delivery');
   assert.equal(resumed.identities.length,1,'retained-resume one callback observation');
   assert.equal(resumed.identities[0].receiver,true,'retained-resume receiver identity');
   assert.equal(resumed.identities[0].event,true,'retained-resume original event identity');
   assert.equal(resumed.identities[0].target,true,'retained-resume target identity');
   assert.equal(resumed.identities[0].currentTarget,true,'retained-resume currentTarget identity');
   assert.equal(resumed.identities[0].phase,path==='listen'?2:3,'retained-resume native event phase');
   assert.equal(resumed.identities[0].preventedBefore,false,'retained-resume initial default state');
   assert.equal(resumed.identities[0].preventedAfter,true,'retained-resume callback prevention');
   assert.equal(resumed.returned,false,'retained-resume native cancellation result');
   if(mode==='nil'||mode==='direct-nil')assert.equal(resumed.beforeSequence,'nil','retained-resume nil remains lazy before native event');
   if(path==='listen'){
    assert.equal(resumed.records.length,1,'retained-resume one actual hook record');
    assert.equal(resumed.records[0].seq,1,'retained-resume hook sequence');
    assert.equal(resumed.records[0].finalized,true,'retained-resume actual hook finalized');
    assert.equal(resumed.records[0].defaultPrevented,true,'retained-resume final hook defaultPrevented');
    if(mode==='test'||mode==='custom'){
     assert.equal(resumed.records[0].timeStamp,mode==='test'?123:321,'retained-resume timestamp: '+mode);
     assert.deepEqual(resumed.nativeTimes,[],'retained-resume scripted timestamp avoids native clock');
    }else{
     assert(Number.isFinite(resumed.records[0].timeStamp),'retained-resume finite native timestamp');
     assert.equal(resumed.nativeTimes.length,1,'retained-resume one selected native time sample');
     assert.equal(resumed.records[0].timeStamp,resumed.nativeTimes[0],'retained-resume timestamp equals selected native sample');
     assert(resumed.records[0].timeStamp>=resumed.lower&&resumed.records[0].timeStamp<=resumed.upper,'retained-resume timestamp inside captured native bounds');
    }
   }
  }
  const compatibility=await page.evaluate(()=>{
   const s=deliveryState;deliveryChoose('test');s.errors.length=0;
   const parent=document.createElement('div'),child=document.createElement('button');parent.append(child);document.body.append(parent);
   const calls=[],records=[];deliveryHook(r=>records.push(r));
   if(s.path==='listen'){
    const capture=deliveryRegister(parent,'compat',function(e){if(this!==parent||e.target!==child||e.currentTarget!==parent||e.eventPhase!==1)throw Error('capture receiver');calls.push('capture')},true);
    const handler=function(e){if(this!==child||e.currentTarget!==child)throw Error('target receiver');calls.push('target');e.preventDefault()};
    const first=deliveryRegister(child,'compat',handler,false),duplicate=deliveryRegister(child,'compat',handler,false);
    if(first!==duplicate)throw Error('duplicate disposer identity');
    child.dispatchEvent(new Event('compat',{bubbles:true,cancelable:true}));first();duplicate();capture();
    let remove;remove=deliveryRegister(child,'compat',function(){calls.push('outer');remove();child.dispatchEvent(new Event('compat'))},false);
    child.dispatchEvent(new Event('compat'));remove();
    const owned=()=>calls.push('owned');const owner1=deliveryOwned(child,'compat',owned),owner2=deliveryOwned(child,'compat',owned);
    owner2();child.dispatchEvent(new Event('compat'));owner1();child.dispatchEvent(new Event('compat'));
    deliveryHook(null);const off=deliveryRegister(child,'compat',()=>calls.push('disabled'),false);child.dispatchEvent(new Event('compat'));off();
    deliveryHook(()=>{throw Error('expected hook fault')});const hookFault=deliveryRegister(child,'compat',()=>calls.push('hook-fault'),false);child.dispatchEvent(new Event('compat'));hookFault();
    deliveryHook(r=>records.push(r));const throwing=deliveryRegister(child,'compat',()=>{calls.push('throw');throw Error('expected compatibility handler fault')},false);child.dispatchEvent(new Event('compat'));throwing();
   }else{
    deliveryDelegateType('compat');deliveryDelegate(parent,'compat',function(e){if(this!==parent||e.currentTarget!==document)throw Error('delegated parent receiver');calls.push('parent')});
    deliveryDelegate(child,'compat',function(data,e){if(this!==child||data.token!==731)throw Error('delegated data receiver');calls.push('data')});child.$$compatData={token:731};
    child.dispatchEvent(new Event('compat',{bubbles:true}));delete child.$$compatData;
    deliveryDelegate(child,'compat',function(e){if(this!==child)throw Error('delegated receiver');calls.push('stop');e.stopPropagation()});
    child.dispatchEvent(new Event('compat',{bubbles:true}));deliveryClear();child.dispatchEvent(new Event('compat',{bubbles:true}));
   }
   parent.remove();return {path:s.path,calls,records:records.map(r=>({finalized:r.finalized,prevented:r.payload.defaultPrevented})),errors:[...s.errors]};
  });receipt({stage:'compatibility',compatibility});
  if(path==='listen'){
   assert.deepEqual(compatibility.calls,['capture','target','outer','owned','disabled','hook-fault','throw']);
   assert.equal(compatibility.records.length,5);assert(compatibility.records.every(r=>r.finalized));assert(compatibility.records.some(r=>r.prevented));
   assert.equal(compatibility.errors.length,1);assert.match(compatibility.errors[0],/expected compatibility handler fault/);
  }else{assert.deepEqual(compatibility.calls,['data','parent','stop']);assert.deepEqual(compatibility.errors,[]);}
  assert.deepEqual(unexpected,[]);console.log(path+': native receiver/capture/duplicate/disposal/nesting/error compatibility PASS');
  await context.close();
 }
}finally{await browser?.close();await new Promise(r=>server.close(r));}
