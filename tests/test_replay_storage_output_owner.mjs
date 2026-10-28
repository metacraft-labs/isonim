/** Actual Nim/native Storage outputs, actual Recorder/strict codec/runtime/loop
 * and dom-v1. Captured originals are test-only independent persisted-state
 * observations, never a production bypass. Getter/method token faults isolate
 * native error identity; genuine denied-origin SecurityError is not fabricated.
 * No fake cursor/tape/provider/registry. Level0 proof is not typed privacy or
 * complete framework Recording/Replay acceptance.
 */
import assert from 'node:assert/strict';
import {readFileSync,writeFileSync} from 'node:fs';
import {createRequire} from 'node:module';
import {createServer} from 'node:http';
const root=process.cwd(),artifact=process.env.CT_ARTIFACT;
assert(artifact,'CT_ARTIFACT required; no skipping');
const require=createRequire(artifact+'/packages/boundary-shim/package.json');
const esbuild=require('esbuild');
const {chromium}=await import(root+'/tests/browser/node_modules/playwright/index.mjs');
const bundle=async contents=>(await esbuild.build({stdin:{resolveDir:artifact,contents},bundle:true,format:'iife',platform:'browser',write:false})).outputFiles[0].text;
const owner=await bundle(`
import {Recorder,numberToBits} from '@codetracer/boundary-shim/dist/browser/recorder.js';
import {captureOriginals} from '@codetracer/boundary-shim/dist/browser/originals.js';
import {readEnvironment} from '@codetracer/boundary-shim/dist/browser/install.js';
import {domV1Hash} from '@codetracer/boundary-shim/dist/browser/dom-v1.js';
import {encodeLog,decodeRecord} from '@codetracer/boundary-format';
import {installReplayRuntime} from '@codetracer/boundary-replay/dist/browser/runtime.js';
globalThis.storageOriginals=captureOriginals(window);
globalThis.storageNative=(area,key)=>{const o=storageOriginals,s=o.storageAreas.get(area).descriptor.get.call(window);return o.storageGetItem.call(s,key);};
globalThis.storageNativeSet=(area,key,value)=>{const o=storageOriginals,s=o.storageAreas.get(area).descriptor.get.call(window);return o.storageMethods.get('setItem').call(s,key,value);};
globalThis.startStorageOwner=()=>{const o=storageOriginals,frames=[];const rec=new Recorder({checkpointScheme:'dom-v1',checkpointHash:()=>domV1Hash(document),sink:{append(f){frames.push(f)},end(){},halt(){}}});rec.start({vocab:1,protocol_level:0,recorder_id:'native-storage-output-observation',framework:'',build_hash:'a'.repeat(64),session_id:'1'.repeat(32),prev_session:'',capabilities:'[]'},readEnvironment(window,o));performance.now=()=>{const v=o.performanceNow.call(performance);rec.guard(()=>rec.emit('Clock',{src:2,bits:numberToBits(v)}));return v;};Storage.prototype.getItem=function(key){const v=o.storageGetItem.call(this,key);rec.guard(()=>rec.emit('StorageRead',{area:1,key,present:v===null?0:1,value:v??''}));return v;};globalThis.stopStorageOwner=level=>{rec.end(2);const records=frames.map(f=>decodeRecord(f.subarray(4)));if(level===1){records[0].protocol_level=1;records[0].framework='fixture';records[0].capabilities='["input","targets","inject","checkpoint","sensitive"]';}return{log:btoa(String.fromCharCode(...encodeLog(records))),records:JSON.parse(JSON.stringify(records,(_,v)=>typeof v==='bigint'?String(v):v))};};};
globalThis.installStorageOwner=log=>installReplayRuntime(window,{log});
`);
const source=readFileSync(process.env.REPLAY_STORAGE_BUNDLE||root+'/build/replay-storage.js','utf8');
const program=await bundle(source),native=readFileSync(process.env.REPLAY_STORAGE_NATIVE||root+'/build/replay-storage-native.js','utf8');
const inverse=process.env.REPLAY_STORAGE_INVERSE||'';
const modes=inverse?['outputs']:['outputs','getter-error','method-error','denied','level1','latch','switch','nil','custom','second'];
const pairs=[['key','ordinary'],['empty',''],['snow☃','é\u0000雪'],['key','replacement'],['nil',null]];
const server=createServer((req,res)=>res.end('<!doctype html><main>storage</main>'));
await new Promise(r=>server.listen(0,'127.0.0.1',r));
const origin='http://127.0.0.1:'+server.address().port+'/storage';
const browser=await chromium.launch({executablePath:process.env.PLAYWRIGHT_CHROMIUM_EXECUTABLE});
const receipts=[];
async function page(mode){const context=await browser.newContext();const p=await context.newPage();await p.goto(mode==='denied'?'data:text/html,<main>storage</main>':origin);await p.addScriptTag({content:owner});return {p,context};}
try{for(const mode of modes){
 const capture=await page(mode);await capture.p.addScriptTag({content:native});
 const observed=await capture.p.evaluate(({mode,pairs})=>{
  soReal();const context=JSON.parse(soBoot());if(mode!=='denied')storageNativeSet('localStorage','neutral','logged-neutral');
  startStorageOwner();const control=mode==='denied'?null:JSON.parse(soNeutral());const values=[],errors=[];
  if(mode==='denied'){try{soWrite('key','value');}catch(e){errors.push({name:e.name,message:e.message});}}
  else if(!['level1','latch'].includes(mode))for(const [key,value]of pairs){value===null?soWriteNil(key):soWrite(key,value);values.push({key,value:storageNative('localStorage',key),session:storageNative('sessionStorage',key),read:soRead(key)});}
  soShow(JSON.stringify(mode==='denied'?errors.map(e=>e.name):values.map(v=>v.read)));
  return {context,control,values,errors,...stopStorageOwner(mode==='level1'?1:0)};
 },{mode,pairs});
 assert.equal(observed.records.filter(r=>r.record==='Task'||r.record==='TaskReg').length,0,'native synchronous write creates no task');
 assert.equal(observed.records.filter(r=>r.record==='Clock').length,mode==='denied'?0:1);
 assert.equal(observed.records.filter(r=>r.record==='StorageRead').length,mode==='denied'?0:1+observed.values.length);
 if(mode==='denied')assert.equal(observed.errors[0]?.name,'SecurityError','genuine native denied origin');
 await capture.context.close();
 const replay=await page(mode);await replay.p.evaluate(({observed,mode})=>{globalThis.storageContext=observed.context;installStorageOwner(observed.log);if(mode!=='denied')storageNativeSet('localStorage','neutral','different-live-neutral');},{observed,mode});
 await replay.p.addScriptTag({content:program});
 const result=await replay.p.evaluate(({observed,mode,pairs})=>{
  soReplay();let rawClocks=0;const D=Date;
  performance.now=()=>{rawClocks++;throw Error('RAW clock');};
  globalThis.Date=new Proxy(D,{apply(){rawClocks++;throw Error('RAW clock');},construct(target,args,newTarget){if(args.length===0){rawClocks++;throw Error('RAW clock');}return Reflect.construct(target,args,newTarget);},get(target,key,receiver){if(key==='now')return()=>{rawClocks++;throw Error('RAW clock');};return Reflect.get(target,key,receiver);}});
  for(const call of[()=>performance.now(),()=>Date.now(),()=>new Date(),()=>Date()]){const before=rawClocks;let caught;try{call();}catch(e){caught=e;}if(caught?.message!=='RAW clock'||rawClocks!==before+1)throw Error('independent clock witness');}
  const explicit=new Date(0);if(explicit.getTime()!==0||!(explicit instanceof D)||Date.prototype!==D.prototype||rawClocks!==4)throw Error('explicit Date control');rawClocks=0;
  const control=mode==='denied'?null:JSON.parse(soNeutral()),before=__ctReplay.peek(),initialDispatch=soDispatch();
  const calls=[],values=[],errors=[],checks=[];let getterCount=0;
  const descriptor=Object.getOwnPropertyDescriptor(window,'localStorage'),original=Storage.prototype.setItem;
  if(mode!=='denied')Object.defineProperty(window,'localStorage',{configurable:true,get(){getterCount++;return descriptor.get.call(window);}});
  Storage.prototype.setItem=function(...args){calls.push({args,local:mode==='denied'?false:this===storageOriginals.storageAreas.get('localStorage').descriptor.get.call(window),session:mode==='denied'?false:this===storageOriginals.storageAreas.get('sessionStorage').descriptor.get.call(window)});return original.apply(this,args);};
  if(mode==='getter-error'||mode==='method-error'){
   const token=Error('original Storage '+mode);const seq=__ctReplay.peek().seq;let methodCalls=0;
   if(mode==='getter-error')Object.defineProperty(window,'localStorage',{configurable:true,get(){getterCount++;throw token;}});
   else Storage.prototype.setItem=function(){methodCalls++;throw token;};
   let caught;try{soWrite('key','fault');}catch(e){caught=e;}
   if(caught!==token||__ctReplay.peek().seq!==seq||methodCalls!==(mode==='method-error'?1:0)||getterCount!==1)throw Error('original Storage fault identity/order');
   checks.push(mode+' exact');Object.defineProperty(window,'localStorage',{configurable:true,get(){getterCount++;return descriptor.get.call(window);}});Storage.prototype.setItem=function(...args){calls.push({args,local:this===descriptor.get.call(window),session:false});return original.apply(this,args);};getterCount=0;
  }
  if(mode==='denied'){const seq=__ctReplay.peek().seq;let caught;try{soWrite('key','value');}catch(e){caught=e;}if(caught?.name!=='SecurityError'||seq!==__ctReplay.peek().seq||calls.length!==0)throw Error('native denied-origin SecurityError/cursor');errors.push({name:caught.name,message:caught.message});}
  else if(mode==='level1'){
   const seq=__ctReplay.peek().seq;let caught;try{soWrite('key','blocked');}catch(e){caught=e;}if(!String(caught).includes('requires actual owner level 0')||getterCount!==0||calls.length!==0||seq!==__ctReplay.peek().seq||storageNative('localStorage','key')!==null)throw Error('level1 preeffect exact refusal');checks.push('level1 preeffect exact');
  }
  else if(mode==='latch'){
   const seq=__ctReplay.peek().seq;let first;try{__ctReplay.next('Clock',{src:1});}catch(e){first=e;}
   if(!first?.divergence||first.divergence!==__ctReplay.failed)throw Error('actual owner latch witness');
   soWrite('after-latch','output');let later;try{soRead('after-latch');}catch(e){later=e;}
   if(storageNative('localStorage','after-latch')!=='output'||later?.constructor!==first.constructor||later.divergence!==first.divergence||__ctReplay.peek().seq!==seq)throw Error('native output after actual owner latch');checks.push('latched owner/native write exact');
  }
  else for(const [key,value]of pairs){
   if(mode==='switch'){soTest();soWrite('scripted','table');if(soScriptedValue()!=='table'||storageNative('localStorage','scripted')!==null)throw Error('scripted write escaped');soReselect();}
   if(mode==='nil'){soNil();soWrite('nil-control','native');if(storageNative('localStorage','nil-control')!=='native')throw Error('nil native write');soReselect();calls.pop();getterCount--;}
   if(mode==='custom'){soCustom();soWrite('custom-control','native');if(storageNative('localStorage','custom-control')!=='native')throw Error('custom native write');soReselect();calls.pop();getterCount--;}
   if(mode==='second')soAgain();
   const prior=__ctReplay.peek();value===null?soWriteNil(key):soWrite(key,value);const after=__ctReplay.peek();
   if(prior.kind!==after.kind||prior.seq!==after.seq)throw Error('storage output advanced cursor');
   const local=storageNative('localStorage',key),session=storageNative('sessionStorage',key);
   storageNativeSet('localStorage',key,'different-live-output');
   const logged=soRead(key);values.push({key,local,session,logged});
   if(storageNative('localStorage',key)!=='different-live-output')throw Error('independent live/logged read detector');
  }
  soShow(JSON.stringify(mode==='denied'?errors.map(e=>e.name):values.map(v=>v.logged)));
  const after=__ctReplay.peek();if(rawClocks!==0||soDispatch()!==initialDispatch)throw Error('storage produced clock/dispatch');
  return {control,before,after,values,errors,calls,getterCount,checks,rawClocks,dispatch:soDispatch()-initialDispatch};
 },{observed,mode,pairs});
 assert.deepEqual(result.control,observed.control,'neutral Clock2 and logged storage must remain positive');
 assert.equal(result.rawClocks,0);assert.equal(result.dispatch,0);if(mode==='denied')assert.deepEqual(result.errors,observed.errors,'original native SecurityError name/message parity');
 if(!['denied','level1','latch'].includes(mode)){
  assert.deepEqual(result.values.map(v=>v.logged),observed.values.map(v=>v.read),'independent logged reads/cursor remain positive');
  assert.equal(result.after.kind,'Checkpoint','all genuine reads consumed');
  const expected=observed.values.map(v=>v.value),actual=result.values.map(v=>v.local);
  if(inverse==='omit'){assert.notDeepEqual(actual,expected);assert.equal(result.calls.length,0);assert(result.values.every(v=>v.session===null));console.log('omit inverse REJECTED only by native persisted output; logged positives PASS');}
  else if(inverse==='value'){assert.notDeepEqual(actual,expected);assert(result.calls.every(v=>v.args[1]==='wrong-output'));assert(result.values.every(v=>v.session===null));console.log('value inverse REJECTED only by native persisted output; logged positives PASS');}
  else if(inverse==='area'){assert.notDeepEqual(actual,expected);assert.deepEqual(result.values.map(v=>v.session),expected);assert(result.calls.every(v=>!v.local&&v.session));console.log('area inverse REJECTED only by native local/session output; logged positives PASS');}
  else{assert.equal(result.getterCount,pairs.length,'exact native getter count');assert.deepEqual(actual,expected,'exact native persisted write');assert(result.values.every(v=>v.session===null));assert.equal(result.calls.length,pairs.length);assert(result.calls.every(v=>v.local&&!v.session));assert.deepEqual(result.calls.map(v=>v.args),pairs.map(([k,v])=>[k,v===null?'':v]));}
 }
 receipts.push({mode,observed,result});
 if(mode!=='level1'&&mode!=='latch'){await replay.p.waitForFunction(()=>['done','diverged'].includes(__ctReplay.status().state));const status=await replay.p.evaluate(()=>__ctReplay.status());assert.equal(status.state,'done','actual owned loop/dom-v1 checkpoint');receipts.at(-1).status=status;}
 console.log(mode+' native storage output assertions PASS');await replay.context.close();
}if(process.env.REPLAY_STORAGE_RECEIPT)writeFileSync(process.env.REPLAY_STORAGE_RECEIPT,JSON.stringify(receipts,(_,v)=>typeof v==='bigint'?String(v):v,2));}finally{await browser.close();await new Promise(r=>server.close(r));}
