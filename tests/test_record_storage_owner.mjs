/** Real native Storage/cookie -> compiled production -> installed Recorder and
 * strict codec -> actual private/public Replay and owned dom-v1 DONE. Ordinary
 * compiled public reads independently supply byte authorities. Local static HTTP
 * avoids external services; FrameSink captures actual frames without transport.
 * Delegating native wrappers witness exact receivers/counts/order. Named native,
 * JSON frontend, real encoder and sink faults are bounded identity/lifecycle
 * controls, never replacement Storage/Recorder/cursor implementations. */
import assert from 'node:assert/strict';
import {readFileSync,appendFileSync} from 'node:fs';
import {createRequire} from 'node:module';
import {createServer} from 'node:http';
const root=process.cwd(),artifact=process.env.CT_ARTIFACT;
assert(artifact,'CT_ARTIFACT required: actual installed storage owner cannot skip');
for(const k of ['STORAGE_BUNDLE','STORAGE_COMPANION','STORAGE_REPLAY','STORAGE_CONTEXT','STORAGE_IMPORT'])assert(process.env[k],k+' required: explicit current compiled input');
const {build}=createRequire(artifact+'/packages/boundary-shim/package.json')('esbuild');
const {chromium}=await import(root+'/tests/browser/node_modules/playwright/index.mjs');
const cases=[['ascii',[112,114,105,118,97,99,121]],['bmp',[955,28450]],['combining',[101,769]],['nonbmp',[55357,56832]],['high',[55296]],['low',[56320]],['high-ascii',[55296,65]],['low-ascii',[56320,65]],['high-repeat',[55296,55296]],['low-repeat',[56320,56320]],['literal-escape',[92,117,100,56,48,48]],['nul',[0]],['empty',[]],['absent',null]].map(([id,units])=>({id,units}));
const imports=`import {Recorder,numberToBits} from '@codetracer/boundary-shim/dist/browser/recorder.js';
import {captureOriginals} from '@codetracer/boundary-shim/dist/browser/originals.js';
import {readEnvironment} from '@codetracer/boundary-shim/dist/browser/install.js';
import {domV1Hash} from '@codetracer/boundary-shim/dist/browser/dom-v1.js';
import {encodeLog,decodeLog,decodeRecord} from '@codetracer/boundary-format';
import {installReplayRuntime} from '@codetracer/boundary-replay/dist/browser/runtime.js';
globalThis.stOwner={Recorder,numberToBits,captureOriginals,readEnvironment,domV1Hash,encodeLog,decodeLog,decodeRecord,installReplayRuntime};`;
async function bundle(text){return(await build({stdin:{resolveDir:artifact,contents:text},bundle:true,platform:'browser',format:'iife',write:false})).outputFiles[0].text;}
const exports='\nObject.assign(globalThis,{stKey,stInit,stMinimal,stClock,stRead,stAuthority,stSelection});';
const compiled=await bundle(imports+readFileSync(process.env.STORAGE_BUNDLE,'utf8')+exports);
const companion=await bundle(imports+readFileSync(process.env.STORAGE_COMPANION,'utf8')+exports);
const replay=await bundle(imports+readFileSync(process.env.STORAGE_REPLAY,'utf8')+'\nObject.assign(globalThis,{stRpInit,stRpMono,stRpNeMono,stReplay});');
const early=await bundle(readFileSync(process.env.STORAGE_IMPORT,'utf8')+'\nglobalThis.stUncalled=stUncalled;');
const bootCode=readFileSync(process.env.STORAGE_CONTEXT,'utf8');
const server=createServer((req,res)=>res.end('<!doctype html><main>storage privacy control</main>'));
await new Promise(r=>server.listen(0,'127.0.0.1',r));const url='http://127.0.0.1:'+server.address().port;
let browser,done=0;const receipt=v=>{if(process.env.STORAGE_RESULTS)appendFileSync(process.env.STORAGE_RESULTS,JSON.stringify(v)+'\n');};
const semantic=(actual,expected,name)=>assert.deepEqual(actual,expected,'storage semantic: '+name);
const codeUnits=value=>Array.from({length:value.length},(_,i)=>value.charCodeAt(i));
const floatBits=value=>{const view=new DataView(new ArrayBuffer(8));view.setFloat64(0,value,true);return view.getBigUint64(0,true).toString();};
async function chain(code,category,test,fresh=false){
 const context=await browser.newContext(),page=await context.newPage();await page.goto(url);await page.addScriptTag({content:bootCode});const boot=await page.evaluate(()=>xrReadBootContext);await page.addScriptTag({content:code});
 const r=await page.evaluate(({category,test,fresh})=>{
  const a=stOwner,n=a.captureOriginals(window),area=n.storageAreas.get('localStorage').descriptor.get,item=n.storageGetItem,cookie=n.cookie.descriptor.get,cookieSet=n.cookie.descriptor.set;
  const store=area.call(window),units=v=>v===null?null:Array.from({length:v.length},(_,i)=>v.charCodeAt(i));
  const raw=test.units===null?null:String.fromCharCode(...test.units),defaultKey=test.id==='default-key',kind=category==='cookies'?3:1;
  const inputKey=category==='keys'?raw:'storage-value';const projected=JSON.parse(stKey(defaultKey,inputKey));const key=projected.units===null?null:String.fromCharCode(...projected.units);
  store.clear();store.setItem('','marker-empty');store.setItem('null','marker-null');
  if(category==='keys'&&!['empty','default-key'].includes(test.id))store.setItem(key,'key-marker-'+test.id);
  if(category==='values'&&raw!==null)store.setItem(key,raw);
  const assignment={requested:raw,attempted:kind===3};
  if(kind===3){n.cookie.descriptor.set.call(document,'st=;max-age=0;path=/');try{n.cookie.descriptor.set.call(document,raw===null?'st=;max-age=0;path=/':'st='+raw+';path=/');assignment.setter='returned';}catch(e){assignment.setter='threw';assignment.error={name:e.name,message:e.message};}assignment.admitted=cookie.call(document);assignment.admittedUnits=units(assignment.admitted);}
  const counts={area:0,item:0,cookie:0},late={area:0,item:0,cookie:0},trace=[],rawAuthority=[],nativeResults=[];let authority=false;
  n.storageAreas=new Map([['localStorage',{descriptor:{get:function(){counts.area++;trace.push({op:'area',receiver:this===window});return area.call(this);}}}]]);
  n.storageGetItem=function(k){counts.item++;trace.push({op:'item',receiver:this===store,keyType:typeof k,key:units(k)});const v=item.call(this,k);nativeResults.push({present:v!==null,value:units(v)});return v;};
  n.cookie={descriptor:{get:function(){counts.cookie++;trace.push({op:'cookie',receiver:this===document});const v=cookie.call(this);nativeResults.push({present:true,value:units(v)});return v;}}};
  // All replacements delegate; each is positively witnessed then reset.
  Object.defineProperty(window,'localStorage',{configurable:true,get(){late.area++;return area.call(this);}});
  Storage.prototype.getItem=function(k){late.item++;const v=item.call(this,k);if(authority)rawAuthority.push({receiver:this===store,keyType:typeof k,key:units(k),present:v!==null,value:units(v)});return v;};
  Object.defineProperty(document,'cookie',{configurable:true,get(){late.cookie++;const v=cookie.call(this);if(authority)rawAuthority.push({receiver:this===document,present:true,value:units(v)});return v;}});
  const witnesses={};for(const [name,call]of[['area',()=>Object.getOwnPropertyDescriptor(window,'localStorage').get.call(window)],['item',()=>Storage.prototype.getItem.call(store,key)],['cookie',()=>document.cookie]]){call();witnesses[name]=late[name];late[name]=0;}
  const frames=[],rec=new a.Recorder({checkpointScheme:'dom-v1',checkpointHash:()=>a.domV1Hash(document),sink:{append(f){frames.push(f);},end(u,f){frames.push(f);},halt(){}}});
  rec.start({vocab:1,protocol_level:0,recorder_id:'isonim-storage-private',framework:'',build_hash:'a'.repeat(64),session_id:'1'.repeat(32),prev_session:'',capabilities:'[]'},a.readEnvironment(window,n));
  stInit(window,rec,n);const clocks=[stClock(),stClock()];const ordinary=[],actual=[],latePerRead=[];
  for(let i=0;i<2;i++){
   if(fresh&&i===1){if(kind===3)cookieSet.call(document,'st=fresh;path=/');else store.setItem(key,'fresh-observation');}
   authority=true;ordinary.push(JSON.parse(stAuthority(kind,defaultKey,inputKey)));authority=false;
   for(const k of Object.keys(late))late[k]=0;
   actual.push(JSON.parse(stRead(kind,defaultKey,inputKey)));
   latePerRead.push({...late});
  }
  const marker='storage:'+category+':'+test.id+':2';document.querySelector('main').textContent=marker;rec.end(2);
  const records=frames.map(f=>a.decodeRecord(f.subarray(4))),bytes=a.encodeLog(records),strict=a.decodeLog(bytes);let s='';for(const b of bytes)s+=String.fromCharCode(b);
  return {kind,inputKey,defaultKey,keyUnits:units(key),ordinary,actual,rawAuthority,nativeResults,counts,trace,late,latePerRead,witnesses,assignment,clocks,clockFields:strict.records.filter(x=>x.record==='Clock').map(x=>({src:x.src,bits:x.bits.toString()})),marker,log:btoa(s),termination:strict.termination,fields:strict.records.filter(x=>x.record==='StorageRead').map(x=>({area:x.area,key:units(x.key),present:x.present,value:units(x.value)})),kinds:strict.records.map(x=>x.record)};
 },{category,test,fresh});
 receipt({stage:'record',category,test,fresh,r});
 semantic(r.witnesses,{area:1,item:1,cookie:1},'positive late original witnesses');
 semantic(r.late,{area:0,item:0,cookie:0},'captured originals survive live replacements');
 for(const count of r.latePerRead)semantic(count,{area:0,item:0,cookie:0},'captured originals survive live replacements');
 semantic(r.counts,r.kind===3?{area:0,item:0,cookie:2}:{area:2,item:2,cookie:0},'exact native read counts');
 semantic(r.trace.map(x=>x.op),r.kind===3?['cookie','cookie']:['area','item','area','item'],'exact native read order');
 semantic(r.trace.every(x=>x.receiver),true,'original native receiver');
 semantic(r.fields.length,2,r.kind===3?'cookie record count':'local record count');
 semantic(r.termination,'Complete','strict complete log');
 semantic(r.kinds,['Header','Env','Clock','Clock','StorageRead','StorageRead','Checkpoint','End'],'exact owner record vocabulary/order');
 semantic(r.clockFields,r.clocks.map(v=>({src:2,bits:floatBits(v)})),'independent actual Clock2 bits');semantic(r.nativeResults.length,2,'captured native result count');semantic(r.rawAuthority.length,2,'ordinary native result count');
 if(r.kind===3){
  semantic(r.assignment.setter,'returned','actual cookie assignment returned');
  const ignored=['high','low','high-ascii','low-ascii','high-repeat','low-repeat','nul','absent'].includes(test.id);
  const expected=ignored?'':'st='+String.fromCharCode(...test.units);semantic(r.assignment.admitted,expected,'independent finite native cookie admission');
  for(let i=0;i<2;i++)semantic(r.rawAuthority[i].value,codeUnits(fresh&&i===1?'st=fresh':expected),'native cookie authority matches actual admission');
 }
 if(fresh){
  assert.notDeepEqual(r.rawAuthority[1].value,r.rawAuthority[0].value,'storage semantic: independently changed fresh native authority');
  const expected=Array.from(r.kind===3?'st=fresh':'fresh-observation',c=>c.charCodeAt(0));semantic(r.rawAuthority[1].value,expected,'independent second fresh native value');semantic(r.ordinary[1].bytes,expected,'independent second fresh ordinary bytes');
 }
 const fidelity=[];const compare=(actual,expected,name)=>{try{semantic(actual,expected,name);fidelity.push({name,outcome:'PASS',actual,expected});}catch(e){assert.equal(e.code,'ERR_ASSERTION');fidelity.push({name,outcome:'RED',actual,expected});}};
 for(let i=0;i<2;i++){
  const f=r.fields[i],expected=r.ordinary[i],native=r.rawAuthority[i];semantic(native.receiver,true,'ordinary native receiver');
  semantic(r.nativeResults[i],{present:native.present,value:native.value},'independent captured native result');
  semantic(f.area,r.kind,r.kind===3?'cookie area':'local area');semantic(f.key,r.kind===3?[]:r.keyUnits,r.kind===3?'cookie key':'local native key');
  semantic(f.present,r.kind===3?1:(native.present?1:0),r.kind===3?'cookie present':'local presence');
  compare(f.value,expected.projection.units??[],r.kind===3?'cookie wire value':'local wire value');
  compare(r.actual[i].bytes,expected.bytes,r.kind===3?'cookie returned bytes':'local returned bytes');
  semantic(r.actual[i].present,r.kind===3?true:native.present,'private Record presence');
  if(r.kind!==3){semantic(r.trace.filter(x=>x.op==='item')[i].keyType,'string','exact native typed key kind');semantic(native.keyType,'string','ordinary native key kind');semantic(r.trace.filter(x=>x.op==='item')[i].key,r.keyUnits,'exact native typed key');semantic(native.key,r.keyUnits,'ordinary native key');}
 }
 await page.close();const rp=await context.newPage();await rp.goto(url);await rp.addScriptTag({content:replay});
 const observed=await rp.evaluate(({r,boot})=>{
  const a=stOwner,n=a.captureOriginals(window),store=n.storageAreas.get('localStorage').descriptor.get.call(window);store.clear();n.cookie.descriptor.set.call(document,'st=changed-before-replay;path=/');
  a.installReplayRuntime(window,{log:r.log});stRpInit(JSON.stringify(boot));
  const counts={area:0,item:0,cookie:0},sentinel={lateNative:true};
  Object.defineProperty(window,'localStorage',{configurable:true,get(){counts.area++;throw sentinel;}});Storage.prototype.getItem=function(){counts.item++;throw sentinel;};Object.defineProperty(document,'cookie',{configurable:true,get(){counts.cookie++;throw sentinel;}});
  const witnesses={};for(const [name,call]of[['area',()=>window.localStorage],['item',()=>Storage.prototype.getItem.call(store,'witness')],['cookie',()=>document.cookie]]){let caught;try{call();}catch(e){caught=e;}witnesses[name]=caught===sentinel&&counts[name]===1;counts[name]=0;}
  globalThis.stLate=counts;const clocks=[stRpMono(),stRpNeMono()],values=[];
  for(let i=0;i<2;i++)values.push(JSON.parse(stReplay(r.kind,i,r.defaultKey,r.inputKey)));
  document.querySelector('main').textContent=r.marker;return {clocks,values,witnesses};
 },{r,boot});
 await rp.waitForFunction(()=>['done','diverged'].includes(__ctReplay.status().state),null,{timeout:10000});
 const ending=await rp.evaluate(()=>({status:__ctReplay.status(),late:stLate}));receipt({stage:'replay',category,test,observed,ending});
 semantic(observed.witnesses,{area:true,item:true,cookie:true},'Replay positive native traps');semantic(ending.late,{area:0,item:0,cookie:0},'Replay native reads zero');
 semantic(observed.clocks,[r.clocks[0],String(BigInt(Math.trunc(r.clocks[1])))],'public NE actual Clock2 prefix');semantic(ending.status.state,'done','actual owned Replay DONE');done++;
 semantic(observed.values[0].kind,r.rawAuthority[0].present?'JString':'JNull','private Replay absence before erasure');
 for(let i=0;i<2;i++)compare(observed.values[i].bytes,r.ordinary[i].bytes,'typed frontier phase'+i);
 receipt({stage:'fidelity',category,test,done:ending.status.state,fidelity});
 await context.close();
 const failed=fidelity.find(x=>x.outcome==='RED');if(failed)semantic(failed.actual,failed.expected,failed.name);
}
async function controls(code,only=''){
 const p=await browser.newPage();await p.goto(url);await p.addScriptTag({content:code});
 const result=await p.evaluate(({only})=>{
  const a=stOwner,native=a.captureOriginals(window),area=native.storageAreas.get('localStorage').descriptor.get,item=native.storageGetItem,cookie=native.cookie.descriptor.get,store=area.call(window);
  store.setItem('k','authority-value');native.cookie.descriptor.set.call(document,'st=authority-value;path=/');
  const results=[];const modes=only?[only]:['minimal','missing-window','bad-window','bad-document','missing-originals','missing-map','bad-map','missing-area','bad-area-descriptor','bad-area-getter','missing-item','bad-item','missing-cookie','bad-cookie-descriptor','bad-cookie-getter','fake-recorder','key-error','area-error','item-error','cookie-error','projection-error','cookie-projection-error','logging-projection','cookie-logging-projection','encoder','cookie-encoder','sink','cookie-sink','end-sink','cookie-end-sink','halted','cookie-halted','prefaulted','cookie-prefaulted','ended','cookie-ended'];
  for(const mode of modes){
   const sentinel={storageControl:mode},counts={area:0,item:0,cookie:0},frames=[],trace=[];let encoderCalls=0,sinkCalls=0,errorAt='',phase='';
   const o={storageAreas:new Map([['localStorage',{descriptor:{get:function(){counts.area++;trace.push({op:'area',receiver:this===window});if(errorAt==='area')throw sentinel;return area.call(this);}}}]]),storageGetItem:function(k){counts.item++;trace.push({op:'item',receiver:this===store,key:k});if(errorAt==='item')throw sentinel;return item.call(this,k);},cookie:{descriptor:{get:function(){counts.cookie++;trace.push({op:'cookie',receiver:this===document});if(errorAt==='cookie')throw sentinel;return cookie.call(this);}}}};
   const rec=new a.Recorder({checkpointScheme:'dom-v1',checkpointHash:()=>a.domV1Hash(document),sink:{append(f){sinkCalls++;if(phase==='sink'){phase='';throw sentinel;}frames.push(f);},end(u,f){frames.push(f);if(mode.endsWith('end-sink'))throw sentinel;},halt(){}}});
   rec.start({vocab:1,protocol_level:0,recorder_id:'storage-controls',framework:'',build_hash:'a'.repeat(64),session_id:'1'.repeat(32),prev_session:'',capabilities:'[]'},a.readEnvironment(window,native));
   const realGuard=rec.guard,guardErrors=[];let guardDepth=0;const guardWitness=realGuard.call(rec,()=>sentinel)===sentinel;
   rec.guard=function(callback){return realGuard.call(this,()=>{guardDepth++;try{return callback();}catch(e){guardErrors.push(e===sentinel);throw e;}finally{guardDepth--;}});};
   if(mode==='missing-map')delete o.storageAreas;if(mode==='missing-area')o.storageAreas.clear();if(mode==='missing-item')delete o.storageGetItem;if(mode==='missing-cookie')delete o.cookie;
   if(mode==='bad-map')o.storageAreas={get:()=>({})};if(mode==='bad-area-descriptor')o.storageAreas.set('localStorage',{});if(mode==='bad-area-getter')o.storageAreas.set('localStorage',{descriptor:{get:0}});if(mode==='bad-item')o.storageGetItem=0;if(mode==='bad-cookie-descriptor')o.cookie={};if(mode==='bad-cookie-getter')o.cookie={descriptor:{get:0}};
   let w=window;if(mode==='missing-window')w=null;if(mode==='bad-window')w={};if(mode==='bad-document'){let proxy;proxy=new Proxy(window,{get(target,name){if(name==='window')return proxy;if(name==='document')return {};return Reflect.get(target,name,target);}});w=proxy;}
   let caught,constructed=false;const before=frames.length;try{stMinimal(w,mode==='fake-recorder'?{}:rec,mode==='missing-originals'?null:o);constructed=true;}catch(e){caught=e;}
   const row={mode,constructed,guardWitness,constructorReads:{...counts},constructorFrames:frames.length-before,constructorError:caught?.name};
   if(mode==='bad-document')row.documentControl={self:w.window===w,window:w instanceof w.Window,document:w.document instanceof w.Document};
   if(!constructed){results.push(row);continue;}
   if(mode==='minimal'){row.selection=[0,1,2,3].map(k=>stSelection(k,window,rec,o));results.push(row);continue;}
   if(mode.endsWith('-error')&&!mode.includes('projection'))errorAt=mode.split('-')[0];
   if(mode.endsWith('halted'))rec.halt();if(mode.endsWith('prefaulted'))rec.guard(()=>{throw sentinel;});if(mode.endsWith('ended'))rec.end(2);
   const terminal=frames.map(f=>Array.from(f)),initial=frames.length,kind=mode.startsWith('cookie')?3:1;
   const stringify=JSON.stringify,encode=TextEncoder.prototype.encode,parse=JSON.parse,from=String.fromCharCode;let qArmed=false,qHits=0,keyArmed=false,keyHits=0;const qFaults=[];
   const armQ=()=>{JSON.parse=function(v,...args){const result=parse.call(this,v,...args);if(v===stringify(kind===3?'st=authority-value':'authority-value'))qArmed=true;return result;};String.fromCharCode=function(...args){
    // Stock JSON classification also projects '[object String]' after parse.
    // Neither target data prefix ('a'/'s') occurs in that fixed classifier.
    if(qArmed&&args[0]===(kind===3?115:97)){qFaults.push({targetParseReturned:true,insideGuard:guardDepth>0,code:args[0]});qArmed=false;qHits++;throw sentinel;}return from.apply(this,args);
   };};
   if(mode.endsWith('projection-error'))JSON.stringify=function(v,...args){if(v==='authority-value'||v==='st=authority-value')throw sentinel;return stringify.call(this,v,...args);};
   if(mode.endsWith('logging-projection'))armQ();
   if(mode==='key-error'){keyArmed=true;String.fromCharCode=function(...args){if(keyArmed&&args[0]===107){keyArmed=false;keyHits++;throw sentinel;}return from.apply(this,args);};}
   row.stockDelegation=JSON.parse('"delegate-positive"')==='delegate-positive'&&String.fromCharCode.call(String,65)==='A';
   if(mode.includes('encoder'))TextEncoder.prototype.encode=function(v){encoderCalls++;if(v==='authority-value'||v==='st=authority-value')throw sentinel;return encode.call(this,v);};
   if(mode==='sink'||mode==='cookie-sink')phase='sink';
   if(mode.endsWith('projection-error')||mode==='key-error'){
    const areaDescriptor=Object.getOwnPropertyDescriptor(window,'localStorage'),cookieDescriptor=Object.getOwnPropertyDescriptor(document,'cookie'),method=Storage.prototype.getItem;row.authorityTrace=[];
    Object.defineProperty(window,'localStorage',{configurable:true,get(){row.authorityTrace.push({op:'area',receiver:this===window});return area.call(this);}});
    Storage.prototype.getItem=function(k){row.authorityTrace.push({op:'item',receiver:this===store,key:k});return item.call(this,k);};
    Object.defineProperty(document,'cookie',{configurable:true,get(){row.authorityTrace.push({op:'cookie',receiver:this===document});return cookie.call(this);}});
    let expectedError;try{stAuthority(kind,false,'k');}catch(e){expectedError=e;}row.authorityError=expectedError===sentinel;
    if(areaDescriptor)Object.defineProperty(window,'localStorage',areaDescriptor);else delete window.localStorage;Storage.prototype.getItem=method;if(cookieDescriptor)Object.defineProperty(document,'cookie',cookieDescriptor);else delete document.cookie;
    if(mode==='key-error')keyArmed=true;
   }
   let value;try{value=JSON.parse(stRead(kind,false,'k'));}catch(e){caught=e;}
   JSON.stringify=stringify;TextEncoder.prototype.encode=encode;JSON.parse=parse;String.fromCharCode=from;row.qHits=qHits;row.keyHits=keyHits;
   row.errorIdentity=caught===sentinel;row.errorName=caught?.name;row.value=value;row.counts={...counts};row.trace=trace.slice();row.added=frames.length-initial;row.terminalFrozen=stringify(frames.map(f=>Array.from(f)))===stringify(terminal);row.encoderCalls=encoderCalls;row.guardErrors=guardErrors.slice();row.qFaults=qFaults.slice();
   row.recording=rec.recording;
   if(!mode.includes('error')){
    if(mode.endsWith('end-sink')){rec.end(2);row.recording=rec.recording;}
    const frozen=stringify(frames.map(f=>Array.from(f)));row.later=JSON.parse(stRead(kind,false,'k'));row.laterFrozen=frozen===stringify(frames.map(f=>Array.from(f)));row.afterCounts={...counts};
    errorAt=kind===3?'cookie':'item';let laterError;try{stRead(kind,false,'k');}catch(e){laterError=e;}row.terminalNativeError=laterError===sentinel;row.errorFrozen=frozen===stringify(frames.map(f=>Array.from(f)));
    const terminalRecords=frames.map(f=>a.decodeRecord(f.subarray(4)));row.records=terminalRecords.map(r=>r.record);row.refusals=terminalRecords.filter(r=>r.record==='Refusal').map(r=>r.feature);
    // A fresh guarded serialization failure on an already terminal owner must
    // not append even a second Refusal; the successful native value still wins.
    errorAt='';const terminalBefore=stringify(frames.map(f=>Array.from(f)));
    armQ();let terminalValue,terminalThrown;try{terminalValue=JSON.parse(stRead(kind,false,'k'));}catch(e){terminalThrown=e;}JSON.parse=parse;String.fromCharCode=from;
    row.terminalLogging={value:terminalValue,threw:!!terminalThrown,wireFrozen:terminalBefore===stringify(frames.map(f=>Array.from(f))),qHits:qHits-row.qHits,originalObject:guardErrors.at(-1)===true,fault:qFaults.at(-1),counts:{...counts}};
   }
   results.push(row);
  }
  return results;
 },{only});
 receipt({stage:'controls',result});
 for(const r of result){
  semantic(r.guardWitness,true,'actual owner guard delegation');semantic(r.constructorReads,{area:0,item:0,cookie:0},'constructor lazy natives');semantic(r.constructorFrames,0,'constructor lazy emission');
  if(r.mode.startsWith('missing')||r.mode.startsWith('bad-')||r.mode==='fake-recorder'){semantic(r.constructed,false,'invalid linkage rejected');semantic(r.constructorError,'TypeError','precise linkage failure');if(r.mode==='bad-document')semantic(r.documentControl,{self:true,window:true,document:false},'document-only invalid linkage control');continue;}
  semantic(r.constructed,true,'minimal actual linkage');if(r.mode==='minimal'){semantic(r.selection,[true,true,true,true],'public selector unchanged');continue;}
  semantic(r.stockDelegation,true,'stock frontend delegation positive');
  const cookie=r.mode.startsWith('cookie');
  if(r.mode.includes('error')){
   if(r.mode.includes('projection')||r.mode==='key-error'){semantic(r.authorityError,true,'independent ordinary frontend error');semantic(r.authorityTrace.map(t=>t.op),r.mode==='key-error'?[]:cookie?['cookie']:['area','item'],'ordinary frontend authority exact native order');semantic(r.authorityTrace.every(t=>t.receiver),true,'ordinary frontend authority native receivers');}semantic(r.errorIdentity,true,r.mode.includes('projection')?'ordinary frontend error outside guard':r.mode+' outside guard');semantic(r.added,0,'native/frontend error emits nothing');
   semantic(r.counts,r.mode==='key-error'?{area:0,item:0,cookie:0}:cookie?{area:0,item:0,cookie:1}:r.mode==='area-error'?{area:1,item:0,cookie:0}:{area:1,item:1,cookie:0},'error exact original calls');semantic(r.trace.every(t=>t.receiver),true,'error original receivers');semantic(r.trace.map(t=>t.op),r.mode==='key-error'?[]:cookie?['cookie']:r.mode==='area-error'?['area']:['area','item'],'error exact original order');if(!cookie&&!['key-error','area-error'].includes(r.mode))semantic(r.trace[1].key,'k','error original key');if(r.mode==='key-error')semantic(r.keyHits,2,'ordinary and private key failure witnessed');continue;
  }
  const expected=cookie?'st=authority-value':'authority-value';semantic(r.value?.bytes,Array.from(expected,c=>c.charCodeAt(0)),'owner fault preserves typed result');semantic(r.later.bytes,r.value.bytes,'terminal native result');
  semantic(r.counts,cookie?{area:0,item:0,cookie:1}:{area:1,item:1,cookie:0},'fault original calls');
  semantic(r.laterFrozen,true,'terminal later wire frozen');semantic(r.terminalNativeError,true,'terminal native error identity');semantic(r.errorFrozen,true,'terminal native error wire frozen');
  semantic(r.afterCounts,cookie?{area:0,item:0,cookie:2}:{area:2,item:2,cookie:0},'terminal subsequent exact native calls');
  semantic(r.terminalLogging.value.bytes,r.value.bytes,'terminal logging returns native value');semantic(r.terminalLogging.threw,false,'terminal logging error swallowed');semantic(r.terminalLogging.wireFrozen,true,'terminal logging failure wire frozen');
  semantic(r.terminalLogging.qHits,1,'actual terminal stock Q failure witnessed');semantic(r.terminalLogging.originalObject,true,'actual terminal guard original Q object');if(r.mode.endsWith('logging-projection')){semantic(r.qHits,1,'actual active stock Q failure witnessed');semantic(r.guardErrors,[true],'actual active guard original Q object');}
  semantic(r.terminalLogging.fault,{targetParseReturned:true,insideGuard:true,code:cookie?115:97},'actual terminal stock Q fault inside guard');semantic(r.terminalLogging.counts,cookie?{area:0,item:0,cookie:4}:{area:4,item:4,cookie:0},'terminal final exact native calls');if(r.mode.endsWith('logging-projection'))semantic(r.qFaults,[{targetParseReturned:true,insideGuard:true,code:cookie?115:97}],'actual active stock Q fault inside guard');
  const fault=!['halted','ended','end-sink'].some(m=>r.mode.endsWith(m));
  const expectedKinds=r.mode.endsWith('halted')?['Header','Env']:r.mode.endsWith('ended')?['Header','Env','End']:r.mode.endsWith('end-sink')?['Header','Env','StorageRead','Checkpoint','End']:['Header','Env','Refusal'];
  semantic(r.records,expectedKinds,'exact actual terminal record kinds');semantic(r.refusals,fault?['recorder-fault']:[],'actual terminal Refusal feature');
  if(['halted','prefaulted','ended'].some(m=>r.mode.endsWith(m)))semantic(r.terminalFrozen,true,'preterminal wire frozen');
  else{semantic(r.recording,false,'actual owner fault terminal');if(r.mode.includes('encoder'))assert(r.encoderCalls>0,'actual TextEncoder failure invoked');}
 }
 await p.close();
}
async function opaqueControl(code){
 const p=await browser.newPage();await p.goto(url);await p.evaluate(()=>{const f=document.createElement('iframe');f.sandbox='allow-scripts';f.srcdoc='<!doctype html><main>opaque native denial</main>';document.body.append(f);});
 await p.waitForFunction(()=>document.querySelector('iframe')!==null);const frame=await new Promise((resolve,reject)=>{const existing=p.frames().find(f=>f!==p.mainFrame());if(existing)return resolve(existing);const timeout=setTimeout(()=>reject(new Error('opaque iframe missing')),10000);p.once('frameattached',f=>{clearTimeout(timeout);resolve(f);});});
 await frame.waitForLoadState('domcontentloaded');await frame.addScriptTag({content:code});
 const r=await frame.evaluate(()=>{
  const a=stOwner,o=a.captureOriginals(window),area=o.storageAreas.get('localStorage').descriptor.get;let positive;try{area.call(window);}catch(e){positive=e.name;}
  let calls=0,items=0,original;const frames=[];o.storageAreas=new Map([['localStorage',{descriptor:{get:function(){calls++;try{return area.call(this);}catch(e){original=e;throw e;}}}}]]);const item=o.storageGetItem;o.storageGetItem=function(k){items++;return item.call(this,k);};
  const rec=new a.Recorder({checkpointScheme:'dom-v1',checkpointHash:()=>a.domV1Hash(document),sink:{append(f){frames.push(f);},end(u,f){frames.push(f);},halt(){}}});rec.start({vocab:1,protocol_level:0,recorder_id:'opaque-storage',framework:'',build_hash:'a'.repeat(64),session_id:'1'.repeat(32),prev_session:'',capabilities:'[]'},a.readEnvironment(window,o));
  stMinimal(window,rec,o);const constructorCalls=calls,before=frames.length;let caught;try{stRead(1,false,'k');}catch(e){caught=e;}return {positive,constructorCalls,calls,items,error:caught?.name,identity:caught===original,added:frames.length-before};
 });receipt({stage:'opaque-native',r});semantic(r,{positive:'SecurityError',constructorCalls:0,calls:1,items:0,error:'SecurityError',identity:true,added:0},'actual opaque native SecurityError identity');await p.close();
}
try{
 browser=await chromium.launch({executablePath:process.env.PLAYWRIGHT_CHROMIUM_EXECUTABLE});
 const e=await browser.newPage();await e.goto(url);
 const importWitness=await e.evaluate(()=>{
  const descriptor=(target,key)=>{for(let o=target;o;o=Object.getPrototypeOf(o)){const d=Object.getOwnPropertyDescriptor(o,key);if(d)return d;}};
  const area=descriptor(window,'localStorage').get,cookie=descriptor(document,'cookie').get,item=Storage.prototype.getItem,store=area.call(window),counts={area:0,item:0,cookie:0};
  Object.defineProperty(window,'localStorage',{configurable:true,get(){counts.area++;return area.call(this);}});Storage.prototype.getItem=function(k){counts.item++;return item.call(this,k);};Object.defineProperty(document,'cookie',{configurable:true,get(){counts.cookie++;return cookie.call(this);}});
  void window.localStorage;Storage.prototype.getItem.call(store,'witness');void document.cookie;const witness={...counts};for(const k of Object.keys(counts))counts[k]=0;globalThis.stImportReads=counts;return witness;
 });semantic(importWitness,{area:1,item:1,cookie:1},'import native positive witnesses');
 await e.addScriptTag({content:early});const lazy=await e.evaluate(()=>({storage:typeof stUncalled,reads:stImportReads,globals:['__ctBoundaryProtocol','__ctReplay','__ctBoundaryShim'].filter(k=>Object.hasOwn(globalThis,k))}));semantic(lazy,{storage:'function',reads:{area:0,item:0,cookie:0},globals:[]},'deliberate import dormant');await e.close();
 await chain(companion,'values',cases[0]);console.log('storage companion positive: real Record -> strict codec -> public Replay DONE');
 const inverse=process.env.STORAGE_INVERSE||'';
 if(inverse){
  if(inverse.startsWith('guard-'))await controls(compiled,inverse.slice(6)+'-error');
  else if(inverse==='projection-guard')await controls(compiled,'projection-error');
  else if(inverse==='cookie-projection-guard')await controls(compiled,'cookie-projection-error');
  else if(inverse==='logging-guard')await controls(compiled,'logging-projection');
  else if(inverse==='cookie-logging-guard')await controls(compiled,'cookie-logging-projection');
  else await chain(compiled,inverse.startsWith('cookie')?'cookies':'values',cases.find(c=>c.id===(inverse==='frontier'?'high':inverse==='presence'?'absent':'ascii')));
 }else{
  for(const category of ['values','keys','cookies'])for(const test of category==='keys'?[...cases.filter(c=>c.id!=='absent'),{id:'default-key',units:[]}]:cases)await chain(compiled,category,test);
  await chain(compiled,'values',cases[0],true);await chain(compiled,'cookies',cases[0],true);await controls(compiled);await opaqueControl(compiled);
 }
 receipt({stage:'summary',done,inverse});console.log(JSON.stringify({storageDone:done,inverse}));
}finally{await browser?.close();await new Promise(r=>server.close(r));}
