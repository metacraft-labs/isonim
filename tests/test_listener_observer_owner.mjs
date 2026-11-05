/** Real compiled Nim listener slot, native Chromium callbacks and actual owners.
 * A local HTTP server serves only compiled fixture/real owner bytes; it replaces
 * no DOM, WeakMap, observer, backend or Replay cursor. Observation delegates call
 * real getters/methods. Only non-sensitive button/event stimuli are used.
 */
import assert from 'node:assert/strict';
import {readFileSync,writeFileSync} from 'node:fs';
import {createServer} from 'node:http';
import {createRequire} from 'node:module';
import {createHash} from 'node:crypto';
import {chromium} from './browser/node_modules/playwright/index.mjs';
const bundle=readFileSync(process.env.OBSERVER_BUNDLE,'utf8'),output=process.env.OBSERVER_RECEIPT,selected=process.env.OBSERVER_CASE||'all',replay=process.env.OBSERVER_REPLAY==='1';
assert(output&&process.env.PLAYWRIGHT_CHROMIUM_EXECUTABLE,'explicit compiled bundle, receipt and actual browser required');
let owner='';const inputs={};
if(replay){
 const artifact=process.env.CT_ARTIFACT;assert(artifact,'immutable actual owner artifact required');const require=createRequire(artifact+'/packages/boundary-shim/package.json');const {build}=require('esbuild');
 const result=await build({stdin:{resolveDir:artifact,contents:`import {Recorder} from '@codetracer/boundary-shim/dist/browser/recorder.js';import {captureOriginals} from '@codetracer/boundary-shim/dist/browser/originals.js';import {readEnvironment} from '@codetracer/boundary-shim/dist/browser/install.js';import {encodeLog,decodeRecord} from '@codetracer/boundary-format';import {installReplayRuntime} from '@codetracer/boundary-replay/dist/browser/runtime.js';globalThis.observerOwner=()=>{const frames=[],orig=captureOriginals(window),rec=new Recorder({checkpointScheme:'dom-v1',checkpointHash:()=>'',sink:{append:f=>frames.push(f),end:(_u,f)=>frames.push(f),halt(){}}});rec.start({vocab:1,protocol_level:0,recorder_id:'observer-test-only',framework:'',build_hash:'a'.repeat(64),session_id:'1'.repeat(32),prev_session:'',capabilities:'[]'},readEnvironment(window,orig));rec.end(2);const records=frames.map(f=>decodeRecord(f.subarray(4)));let bytes='';for(const b of encodeLog(records))bytes+=String.fromCharCode(b);installReplayRuntime(window,{log:btoa(bytes)});return records.map(r=>r.record);};`},bundle:true,platform:'browser',format:'iife',write:false,metafile:true});owner=result.outputFiles[0].text;writeFileSync(output+'-owner.js',owner);writeFileSync(output+'-owner-inputs.json',JSON.stringify(result.metafile,null,2));for(const p of Object.keys(result.metafile.inputs))if(p!=='<stdin>')inputs[p]=createHash('sha256').update(readFileSync(p)).digest('hex');
}
const server=createServer((q,s)=>{s.setHeader('content-type','text/html');s.end('<!doctype html><button id="button" data-iid="observer-button">Observer fixture</button>');});await new Promise(r=>server.listen(0,'127.0.0.1',r));let browser;
const receipt={selected,replay,inputs,results:[]};function save(){writeFileSync(output,JSON.stringify(receipt,null,2));}
try{
 browser=await chromium.launch({headless:true,executablePath:process.env.PLAYWRIGHT_CHROMIUM_EXECUTABLE});receipt.browser=browser.version();assert.equal(receipt.browser,'147.0.7727.15');
 const page=await browser.newPage();await page.goto('http://127.0.0.1:'+server.address().port);if(owner)await page.addScriptTag({content:owner});await page.addScriptTag({content:bundle});
 const result=await page.evaluate(({selected,replay})=>{
  const checks=[];function check(ok,name,detail={}){checks.push({name,ok,detail});if(!ok){globalThis.observerFailure={checks,name,detail};throw new Error('OBSERVER_ASSERT: '+name);}}
  const include=n=>selected==='all'||selected===n;const nilMessage='internal listener observer requires non-nil hook',occupied='internal listener observer slot is occupied';
  const err=(value,message,name)=>check(value?.error?.name==='ValueError'&&value.error.message===message,name,{actual:value,expected:message});
  const ok=(value,name)=>check(value&&!value.error,name,{actual:value});
  function claim(callback,name){const x=observerClaim(callback);ok(x,name);check(typeof x.release==='function',name);return x.release;}
  function release(handle,name){const x=observerRelease(handle);ok(x,name);}
  function set(callback,name){ok(observerSet(callback),name);}
  registeredSelect('custom');set(null,'initial-clear');
  const node=document.getElementById('button');let handlers=0,observers=0,native=0,last=null,records=[],observations=[];
  const callback=function(event){handlers++;observations.push({receiver:this===node,event:event===last,target:event.target===node,current:event.currentTarget===node});event.preventDefault();return marker;};
  const marker={returnIdentity:true};node.addEventListener('click',()=>native++);
  const dispose=registeredListen(node,'click',callback,false);check(dispose===registeredListen(node,'click',callback,false),'native-tuple-dedup');
  const normalHook=record=>{observers++;records.push(record);check(record.finalized===false,'entered-snapshot-not-final');};
  let read=0,time=0;const descriptor=Object.getOwnPropertyDescriptor(MouseEvent.prototype,'clientX'),realNow=performance.now;performance.now=function(){time++;return realNow.call(this);};
  function event(){const ev=new MouseEvent('click',{bubbles:true,cancelable:true,clientX:19});Object.defineProperty(ev,'clientX',{configurable:true,get(){read++;return descriptor.get.call(this);}});return ev;}
  function stamp(){const s=JSON.parse(registeredState());return {sequence:BigInt(s.sequence),clock:s.clockReads,read,time,handlers,observers,native};}
  function dispatch(){last=event();const before=stamp();const result=node.dispatchEvent(last);const after=stamp();return{before,after,result,event:last};}
  function observedOne(name){const p=dispatch();check(p.after.handlers-p.before.handlers===1&&p.after.native-p.before.native===1&&p.after.observers-p.before.observers===1,name);check(p.after.read>p.before.read&&(p.after.clock>p.before.clock||p.after.time>p.before.time),name);check(records.at(-1).finalized&&records.at(-1).payload.defaultPrevented===true,name);check(!p.result&&observations.at(-1).receiver&&observations.at(-1).event&&observations.at(-1).target&&observations.at(-1).current,name);return p;}
  function unobservedOne(name){const p=dispatch();check(p.after.handlers-p.before.handlers===1&&p.after.native-p.before.native===1&&p.after.observers===p.before.observers,name);check(p.after.read===p.before.read&&p.after.clock===p.before.clock&&p.after.time===p.before.time,name);if(!globalThis.registeredDirect)check(p.after.sequence===p.before.sequence+1n,name);check(!p.result&&observations.at(-1).receiver&&observations.at(-1).event,name);return p;}
  // Independently witness every observation delegate before testing its absence.
  const probe=event();void probe.clientX;performance.now();check(read===1&&time===1,'delegated-read-positive-witness');read=0;time=0;
  if(include('entered-snapshot-not-final')){const stop=claim(normalHook,'entered-snapshot-not-final');observedOne('entered-snapshot-not-final');release(stop,'entered-snapshot-not-final');unobservedOne('entered-snapshot-not-final');}
  if(include('release-observation-only')){const stop=claim(normalHook,'release-observation-only');observedOne('release-observation-only');const seq=Number(records.at(-1).seq);release(stop,'release-observation-only');unobservedOne('release-observation-only');release(stop,'release-observation-only');unobservedOne('release-observation-only');const next=claim(normalHook,'release-observation-only');observedOne('release-observation-only');check(Number(records.at(-1).seq)===seq+3,'release-observation-only',{before:seq,after:Number(records.at(-1).seq),expectedGap:3});release(next,'release-observation-only');}
  if(include('nil-occupied-precedence')){
   err(observerClaim(null),nilMessage,'nil-occupied-precedence');const a=claim(normalHook,'nil-occupied-precedence');err(observerClaim(null),nilMessage,'nil-occupied-precedence');err(observerClaim(normalHook),occupied,'nil-occupied-precedence');err(observerClaim(()=>{}),occupied,'nil-occupied-precedence');observedOne('nil-occupied-precedence');release(a,'nil-occupied-precedence');unobservedOne('nil-occupied-precedence');set(normalHook,'nil-occupied-precedence');err(observerClaim(normalHook),occupied,'nil-occupied-precedence');set(null,'nil-occupied-precedence');
  }
  if(include('public-same-reinstall')){const a=claim(normalHook,'public-same-reinstall');set(normalHook,'public-same-reinstall');release(a,'public-same-reinstall');observedOne('public-same-reinstall');set(null,'public-same-reinstall');unobservedOne('public-same-reinstall');}
  if(include('new-lease-stale-release')){const a=claim(normalHook,'new-lease-stale-release');set(null,'new-lease-stale-release');const b=claim(normalHook,'new-lease-stale-release');release(a,'new-lease-stale-release');observedOne('new-lease-stale-release');release(b,'new-lease-stale-release');release(a,'new-lease-stale-release');release(b,'new-lease-stale-release');unobservedOne('new-lease-stale-release');}
  if(include('reentrant-entry-finally')){
   const order=[];let a,b,entered;const second=r=>{order.push('second');records.push(r);};a=claim(r=>{entered=r;order.push('first');release(a,'reentrant-entry-finally');b=claim(second,'reentrant-entry-finally');const nested=new MouseEvent('click',{cancelable:true});node.dispatchEvent(nested);},'reentrant-entry-finally');const before=handlers;node.dispatchEvent(new MouseEvent('click',{cancelable:true}));check(handlers===before+2&&order.join(',')==='first,second'&&entered.finalized&&entered.payload.defaultPrevented,'reentrant-entry-finally');release(b,'reentrant-entry-finally');unobservedOne('reentrant-entry-finally');
   const replacement=[];let c;c=claim(r=>{replacement.push(r);set(normalHook,'reentrant-entry-finally');release(c,'reentrant-entry-finally');},'reentrant-entry-finally');const h=handlers;node.dispatchEvent(new MouseEvent('click',{cancelable:true}));check(handlers===h+1&&replacement[0].finalized,'reentrant-entry-finally');observedOne('reentrant-entry-finally');set(null,'reentrant-entry-finally');
  }
  if(include('hook-handler-errors')){
   const failures=[],logs=[],thrown={handler:true},hookThrown={hook:true};const onError=e=>{failures.push(e.error);e.preventDefault();};window.addEventListener('error',onError);const realError=console.error;console.error=(...a)=>logs.push(a);let retained;
   const stop=claim(r=>{retained=r;throw hookThrown;},'hook-handler-errors');const bad=function(e){check(this===node&&e===badEvent,'hook-handler-errors');e.preventDefault();throw thrown;};const remove=registeredListen(node,'error-case',bad,false);const badEvent=new Event('error-case',{cancelable:true});node.dispatchEvent(badEvent);check(logs.length===1&&logs[0][0]==='isonim listener hook:'&&logs[0][1]===hookThrown&&failures.length===1&&failures[0]===thrown&&retained.finalized&&retained.payload.defaultPrevented,'hook-handler-errors');release(stop,'hook-handler-errors');remove();console.error=realError;window.removeEventListener('error',onError);
   // A snapshot failure occurs before handler/finally in the genuine source.
   const snapshotError={snapshot:true},seen=[];const errorListener=e=>{seen.push(e.error);e.preventDefault();};window.addEventListener('error',errorListener);const q=claim(normalHook,'hook-handler-errors');const ev=new MouseEvent('click');Object.defineProperty(ev,'clientX',{get(){throw snapshotError;}});const h=handlers;node.dispatchEvent(ev);check(handlers===h&&seen[0]===snapshotError,'hook-handler-errors');release(q,'hook-handler-errors');window.removeEventListener('error',errorListener);
  }
  if(include('owner-and-registration')){
   const owner=observerOwned(normalHook);observedOne('owner-and-registration');owner.dispose();unobservedOne('owner-and-registration');release(owner.release,'owner-and-registration');
   const typed=observerTyped(node);node.dispatchEvent(new Event('typed'));check(typed.count()===1,'owner-and-registration');typed.dispose();node.dispatchEvent(new Event('typed'));check(typed.count()===1,'owner-and-registration');
   let count=0;const f=()=>count++;const original=registeredOwned(node,'owned-event',f,true),duplicate=registeredOwned(node,'owned-event',f,true);duplicate();node.dispatchEvent(new Event('owned-event'));check(count===1,'owner-and-registration');original();node.dispatchEvent(new Event('owned-event'));check(count===1,'owner-and-registration');
  }
  if(include('typed-nim-observer')){
   const typed=observerTypedObserver();check(typed.count()===0&&typed.record()===null,'typed-nim-observer');let applications=0,nativeWitness=0,firstEvent;const nativeSeen=()=>nativeWitness++;
   node.addEventListener('nim-observer',nativeSeen);const app=function(ev){applications++;check(this===node&&ev.currentTarget===node&&ev.target===node,'typed-nim-observer');if(applications===1)check(ev===firstEvent&&typed.count()===1&&typed.record().finalized===false,'typed-nim-observer');ev.preventDefault();};
   const remove=registeredListen(node,'nim-observer',app,false);firstEvent=new Event('nim-observer',{cancelable:true});node.dispatchEvent(firstEvent);const retained=typed.record();check(applications===1&&nativeWitness===1&&typed.count()===1&&retained.finalized===true&&retained.payload.defaultPrevented===true&&retained.type==='nim-observer','typed-nim-observer');records.push(retained);
   release(typed.release,'typed-nim-observer');const before=stamp();node.dispatchEvent(new Event('nim-observer',{cancelable:true}));const after=stamp();check(applications===2&&nativeWitness===2&&typed.count()===1&&typed.record()===retained&&after.clock===before.clock&&after.time===before.time&&after.read===before.read,'typed-nim-observer');release(typed.release,'typed-nim-observer');remove();node.removeEventListener('nim-observer',nativeSeen);
  }
  if(include('same-map-direct-call')){
   const stop=claim(normalHook,'same-map-direct-call');const e=new Event('click',{cancelable:true});last=e;const before=stamp();const returned=registeredCall(node,'click',callback,false,e);const after=stamp();check(returned===marker&&handlers===before.handlers+1&&after.observers===before.observers&&after.native===before.native&&after.clock===before.clock&&after.read===before.read&&after.time===before.time&&after.sequence===before.sequence,'same-map-direct-call');
   const error={identity:true},bad=()=>{throw error;};const remove=registeredListen(node,'direct-error',bad,true);let actual;try{registeredCall(node,'direct-error',bad,true,e);}catch(ex){actual=ex;}check(actual===error,'same-map-direct-call');remove();let missing;try{registeredCall(node,'direct-error',bad,true,e);}catch(ex){missing=ex;}check(missing?.message==='isonim registered handler is not active','same-map-direct-call');release(stop,'same-map-direct-call');
  }
  if(replay&&include('replay-refusal-retry')){
   const a=claim(normalHook,'replay-refusal-retry');const stale=claimAfterClear();function claimAfterClear(){const x=observerClaim(normalHook);err(x,occupied,'replay-refusal-retry');set(null,'replay-refusal-retry');return claim(normalHook,'replay-refusal-retry');}
   const done=(()=>{set(null,'replay-refusal-retry');const r=claim(normalHook,'replay-refusal-retry');release(r,'replay-refusal-retry');return r;})();const active=claim(normalHook,'replay-refusal-retry');const kinds=observerOwner();check(kinds.join(',')==='Header,Env,End','actual-owner-Replay-log');observerReplay();
   for(const callback of [null,normalHook])err(observerClaim(callback),'internal read Replay does not support claimInternalListenerObserver','replay-refusal-retry');
   err(observerSet(null),'internal read Replay does not support setListenerHook','replay-refusal-retry');err(observerSet(normalHook),'internal read Replay does not support setListenerHook','replay-refusal-retry');
   for(const r of [active,a,stale,done])err(observerRelease(r),'internal read Replay does not support releaseInternalListenerObserver','replay-refusal-retry');
   registeredSelect('custom');release(a,'replay-refusal-retry');release(stale,'replay-refusal-retry');release(done,'replay-refusal-retry');observedOne('replay-refusal-retry');release(active,'replay-refusal-retry');unobservedOne('replay-refusal-retry');
  }
  set(null,'final-clear');dispose();observerNull();check(observerIsNull(),'null-selector-positive');const nullStop=claim(()=>{},'null-selector-positive');release(nullStop,'null-selector-positive');check(observerIsNull(),'null-selector-no-backend-allocation');
  check(records.every(r=>r.finalized),'retained-finalized');
  return {checks,handlers,observers,native,retainedFinalized:records.every(r=>r.finalized)};
 },{selected,replay}).catch(async error=>{receipt.failure=await page.evaluate(()=>globalThis.observerFailure||null);save();throw error;});receipt.results.push(result);
 // Native observer/handler boundaries deliberately catch exceptions. Consume
 // EVERY returned check here, outside those production callback catches.
 const failed=result.checks.filter(check=>!check.ok);
 if(failed.length){receipt.failure={checks:result.checks,name:failed[0].name,detail:failed[0].detail,failedChecks:failed};save();throw new Error('OBSERVER_ASSERT: '+failed[0].name);}
 save();console.log('listener observer '+selected+' PASS');
}finally{if(browser)await browser.close();await new Promise(r=>server.close(r));}
