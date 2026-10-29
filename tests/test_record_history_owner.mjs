/** Real compiled captured History -> genuine configured Recorder/strict codec ->
 * existing private Replay/owned loop/dom-v1 DONE. Independent compiled ordinary
 * observations and delegating native wrappers supply typed/native authorities.
 * Local static HTTP avoids external services; a real FrameSink retains frames.
 * Named stock/native/sanitizer/encoder/sink faults are bounded identity/guard
 * controls, never fake Window/History/Recorder/cursor. An explicitly modified
 * own-source None stimulus tests policy, not native Location getter failure. */
import assert from 'node:assert/strict';
import {readFileSync,appendFileSync} from 'node:fs';
import {createRequire} from 'node:module';
import {createServer} from 'node:http';
const root=process.cwd(),artifact=process.env.CT_ARTIFACT;
assert(artifact,'CT_ARTIFACT required; no skip');
for(const key of ['HISTORY_BUNDLE','HISTORY_COMPANION','HISTORY_REPLAY','HISTORY_CONTEXT','HISTORY_IMPORT'])assert(process.env[key],key+' required');
const {build}=createRequire(artifact+'/packages/boundary-shim/package.json')('esbuild');
const {HOLE_TOKEN}=createRequire(artifact+'/packages/boundary-shim/package.json')('@codetracer/boundary-format');
const {chromium}=await import(root+'/tests/browser/node_modules/playwright/index.mjs');
const imports=`import {Recorder,numberToBits} from '@codetracer/boundary-shim/dist/browser/recorder.js';
import {captureOriginals} from '@codetracer/boundary-shim/dist/browser/originals.js';
import {readEnvironment} from '@codetracer/boundary-shim/dist/browser/install.js';
import {domV1Hash} from '@codetracer/boundary-shim/dist/browser/dom-v1.js';
import {encodeLog,decodeLog,decodeRecord} from '@codetracer/boundary-format';
import {installReplayRuntime} from '@codetracer/boundary-replay/dist/browser/runtime.js';
import {sensitiveState,currentSensitiveValues,makeCtApi} from '@codetracer/runtime-browser/dist/sensitive.js';
import {sanitizeRecord} from '@codetracer/boundary-shim/dist/browser/record-scrub.js';
import {NO_SCRUB_LISTS} from '@codetracer/runtime-browser/dist/scrub.js';
globalThis.hOwner={Recorder,numberToBits,captureOriginals,readEnvironment,domV1Hash,encodeLog,decodeLog,decodeRecord,installReplayRuntime,sensitiveState,currentSensitiveValues,makeCtApi,sanitizeRecord,NO_SCRUB_LISTS};`;
const bundle=async text=>(await build({stdin:{resolveDir:artifact,contents:text},bundle:true,platform:'browser',format:'iife',write:false})).outputFiles[0].text;
const exports='\nObject.assign(globalThis,{hSet,hInit,hClocks,hClock,hRead,hAuthority,hPublic,hSelection});';
const compiled=await bundle(imports+readFileSync(process.env.HISTORY_BUNDLE,'utf8')+exports);
const companion=await bundle(imports+readFileSync(process.env.HISTORY_COMPANION,'utf8')+exports);
const replay=await bundle(imports+readFileSync(process.env.HISTORY_REPLAY,'utf8')+'\nObject.assign(globalThis,{hRpInit,hRpClock,hRpNe,hRpRead});');
const early=await bundle(readFileSync(process.env.HISTORY_IMPORT,'utf8')+'\nglobalThis.hUncalled=hUncalled;');
const bootCode=readFileSync(process.env.HISTORY_CONTEXT,'utf8');
const receipt=v=>{if(process.env.HISTORY_RESULTS)appendFileSync(process.env.HISTORY_RESULTS,JSON.stringify(v)+'\n');};
const semantic=(a,b,name)=>assert.deepEqual(a,b,'history semantic: '+name);
const bits=x=>{const d=new DataView(new ArrayBuffer(8));d.setFloat64(0,x,true);return d.getBigUint64(0,true).toString();};
const cases=['relative','empty','default','literal-null','unicode','absolute','password','marked','public','site','credential','fresh'];
const server=createServer((req,res)=>res.end('<!doctype html><base href="/base/nested/"><main>history witness</main><input type="text" data-ct-public>'));
await new Promise(r=>server.listen(0,'127.0.0.1',r));const url='http://127.0.0.1:'+server.address().port+'/initial/page';
let browser,done=0;
async function chain(code,mode){
 const context=await browser.newContext(),p=await context.newPage();await p.goto(url);await p.addScriptTag({content:bootCode});const boot=await p.evaluate(()=>xrReadBootContext);await p.addScriptTag({content:code});
 const r=await p.evaluate(({mode,url})=>{
  const a=hOwner,n=a.captureOriginals(window),field=document.querySelector('input'),state=a.sensitiveState(window),api=a.makeCtApi(window,state,(_id,fn,self,args)=>fn.apply(self,args));
  if(mode==='password'){field.type='password';field.removeAttribute('data-ct-public');}
  if(mode==='marked')api.sensitive(field);if(mode==='public')api.public(field);field.value='first-secret';
  const lists=mode==='site'?{...a.NO_SCRUB_LISTS,queryKeys:['site-secret']}:a.NO_SCRUB_LISTS;
  const calls=[],authorityCalls=[],latePerRead=[],late={pushState:0,replaceState:0},frames=[],ordinary=[],actual=[],paths=[],inputs=[],rawUrls=[],trace=[];
  let depth=0,authority=false;
  const o={...n};
  for(const method of ['pushState','replaceState']){
   const original=n[method];o[method]=function(...args){calls.push({method,receiver:this===history,state:args[0],title:args[1],argument:args[2],argumentType:typeof args[2],depth});return original.apply(this,args);};
   history[method]=function(...args){late[method]++;authorityCalls.push({method,receiver:this===history,state:args[0],title:args[1],argument:args[2],argumentType:typeof args[2]});return original.apply(this,args);};
   history[method](null,'','/positive-'+method);n.replaceState.call(history,null,'',url);
  }
  const witnesses={...late};late.pushState=late.replaceState=0;authorityCalls.length=0;
  const rec=new a.Recorder({checkpointScheme:'dom-v1',checkpointHash:()=>a.domV1Hash(document),sanitize:r=>a.sanitizeRecord(r,lists,()=>a.currentSensitiveValues(window,state)),sink:{append(f){frames.push(f);},end(u,f){frames.push(f);},halt(){}}});
  rec.start({vocab:1,protocol_level:0,recorder_id:'isonim-history',framework:'',build_hash:'a'.repeat(64),session_id:'1'.repeat(32),prev_session:'',capabilities:'[]'},a.readEnvironment(window,n));
  const guard=rec.guard;rec.guard=function(fn){return guard.call(this,()=>{depth++;try{return fn();}finally{depth--;}});};
  const before=frames.length;hInit(window,rec,{pushState:o.pushState,replaceState:o.replaceState});const constructor={calls:calls.length,frames:frames.length-before};hClocks(window,rec,n);const clocks=[hClock(),hClock()];
  let pop=0,hash=0;window.addEventListener('popstate',()=>pop++);window.addEventListener('hashchange',()=>hash++);
  for(let i=0;i<2;i++){
   if(mode==='fresh'&&i===1)document.querySelector('base').href='/fresh/base/';
   if(i===1)field.value='second secret';
   const credential='eyJhbGciOiJIUzI1NiJ9.eyJzdWIiOiIxMjM0NTY3ODkwIn0.abcdefghijklmnopqrstuvwxyz1234567890';
   const value=mode==='empty'||mode==='default'?'':mode==='literal-null'?'null':mode==='unicode'?'../%E2%98%83?q=é#雪':mode==='absolute'?location.origin+'/absolute?p='+i:mode==='password'||mode==='marked'?'../one?q='+encodeURIComponent(field.value):mode==='public'?'../one?q='+encodeURIComponent(field.value)+'#public='+encodeURIComponent(field.value):mode==='site'?'../one?site-secret=site-value#site-secret=fragment-value':mode==='credential'?'../one?token='+credential+'#token='+credential:'../one?q='+i+'#hash';
   const push=i===0,old=location.href;hSet(mode==='default',value);ordinary.push(JSON.parse(hAuthority(push)));n.replaceState.call(history,null,'',old);late.pushState=late.replaceState=0;
   const before=frames.length;actual.push(JSON.parse(hRead(push)));latePerRead.push({...late});trace.push(frames.length-before);rawUrls.push(location.href);paths.push(location.pathname);inputs.push({push,defaultInput:mode==='default',value});
  }
  const marker='history:'+mode;document.querySelector('main').textContent=marker;rec.end(2);const records=frames.map(f=>a.decodeRecord(f.subarray(4))),log=a.encodeLog(records),strict=a.decodeLog(log);let binary='';for(const byte of log)binary+=String.fromCharCode(byte);
  return {mode,ordinary,actual,calls,authorityCalls,latePerRead,late,witnesses,constructor,paths,inputs,rawUrls,trace,pop,hash,marker,clocks,records:JSON.parse(JSON.stringify(strict.records,(_,v)=>typeof v==='bigint'?v.toString():v)),log:btoa(binary),termination:strict.termination};
 },{mode,url});receipt({stage:'record',r});
 semantic(r.witnesses,{pushState:1,replaceState:1},'live lookup positive witnesses');semantic(r.late,{pushState:0,replaceState:0},'captured native lookup');
 semantic(r.latePerRead,[{pushState:0,replaceState:0},{pushState:0,replaceState:0}],'captured native lookup');
 semantic(r.constructor,{calls:0,frames:0},'constructor inert');semantic(r.calls.length,2,'native call count');semantic(r.calls.map(x=>x.depth),[0,0],'native outside guard');
 semantic(r.calls.map(({depth,...c})=>c),r.authorityCalls,'stock authority exact native arguments');
 semantic(r.calls.map(x=>[x.receiver,x.state,x.title]),[[true,null,''],[true,null,'']],'native receiver state title');semantic(r.pop+r.hash,0,'no synthetic history events');
 const nav=r.records.filter(x=>x.record==='Navigation');semantic(nav.length,2,'navigation record count');semantic(nav.map(x=>x.kind),[1,2],'navigation kind');
 semantic(r.actual.map(x=>x.bytes),r.ordinary.map(x=>x.bytes),'ordinary returned bytes');semantic(r.actual.map(x=>x.present),[true,true],'ordinary observation available');
 semantic(r.records.filter(x=>x.record==='Clock').map(x=>({src:x.src,bits:x.bits})),r.clocks.map(v=>({src:2,bits:bits(v)})),'Clock2 prefix');semantic(r.termination,'Complete','strict codec complete');
 semantic(r.records.map(x=>x.record),['Header','Env','Clock','Clock','Navigation','Navigation','Checkpoint','End'],'exact record vocabulary/order');
 for(let i=0;i<2;i++){
  if(['password','marked'].includes(mode)){semantic(nav[i].url.includes(i?'second%20secret':'first-secret'),false,'actual sensitive URL holing');assert(nav[i].url.includes(HOLE_TOKEN),'history semantic: actual sensitive URL hole token');}
  else if(mode==='site'){
   const prefix=new URL(url).origin+'/base/one';
   semantic(r.ordinary[i].projection,prefix+'?site-secret=site-value#site-secret=fragment-value','ordinary site query and fragment retained');
   semantic(nav[i].url,prefix+'?site-secret=<scrubbed>#site-secret=<scrubbed>','actual site query and fragment separately scrubbed');
  }
  else if(mode==='credential'){
   const prefix=new URL(url).origin+'/base/one',token='eyJhbGciOiJIUzI1NiJ9.eyJzdWIiOiIxMjM0NTY3ODkwIn0.abcdefghijklmnopqrstuvwxyz1234567890';
   semantic(r.ordinary[i].projection,prefix+'?token='+token+'#token='+token,'ordinary credential query and fragment retained');
   semantic(nav[i].url,prefix+'?token=<scrubbed>#token=<scrubbed>','actual credential query and fragment separately scrubbed');
  }
  else if(mode==='public'){
   const prefix=new URL(url).origin+'/base/one',value=i?'second%20secret':'first-secret';
   semantic(r.ordinary[i].projection,prefix+'?q='+value+'#public='+value,'ordinary public query and fragment retained');
   semantic(nav[i].url,prefix+'?q='+value+'#public='+value,'public query and fragment retained');
  }
  else semantic(nav[i].url,r.ordinary[i].projection,'reflected wire URL');
 }
 await p.close();const rp=await context.newPage();await rp.goto(url);await rp.addScriptTag({content:replay});
 const observed=await rp.evaluate(({r,boot})=>{
  const a=hOwner,field=document.querySelector('input'),s=a.sensitiveState(window),api=a.makeCtApi(window,s,(_id,fn,self,args)=>fn.apply(self,args));if(r.mode==='password'){field.type='password';field.removeAttribute('data-ct-public');}if(r.mode==='marked')api.sensitive(field);if(r.mode==='public')api.public(field);
  a.installReplayRuntime(window,{log:r.log});hRpInit(JSON.stringify(boot));const clocks=[hRpClock(),hRpNe()],paths=[];
  for(let i=0;i<r.inputs.length;i++){
   if(r.mode==='fresh'&&i===1)document.querySelector('base').href='/fresh/base/';field.value=['password','marked'].includes(r.mode)?(i?'different placeholder':'other-placeholder'):(i?'second secret':'first-secret');const x=r.inputs[i];let value=x.value;if(['password','marked'].includes(r.mode))value='../one?q='+encodeURIComponent(field.value);paths.push(hRpRead(x.push,x.defaultInput,value));
  }
  document.querySelector('main').textContent=r.marker;return {clocks,paths};
 },{r,boot});await rp.waitForFunction(()=>['done','diverged'].includes(__ctReplay.status().state));const status=await rp.evaluate(()=>__ctReplay.status());receipt({stage:'replay',mode,observed,status});
 semantic(observed.paths,r.paths,'Replay native checked paths');semantic(observed.clocks,[r.clocks[0],String(BigInt(Math.trunc(r.clocks[1])))],'actual public NE clocks');semantic(status.state,'done','actual owned Replay DONE');done++;await context.close();
}
async function controls(code,only=''){
 const p=await browser.newPage();await p.goto(url);await p.addScriptTag({content:code});
 const rows=await p.evaluate(({only,url,pushArm})=>{
  const a=hOwner,n=a.captureOriginals(window),rows=[];
  const modes=only==='none'?['none',...['halted','prefaulted','ended'].map(s=>s+':none')]:only?[only]:['minimal','missing-push','missing-replace','bad-push','bad-replace','missing-window','bad-window','missing-originals','fake-recorder','key-error','native','security','P','Q','sanitize','encoder','sink','halted','prefaulted','ended','none',...['halted','prefaulted','ended'].flatMap(s=>[s+':Q',s+':native'])];
  for(const push of pushArm==='push'?[true]:pushArm==='replace'?[false]:[true,false])for(const label of modes){
   const [life,mode]=label.includes(':')?label.split(':'):['',label];
   const frames=[],calls=[],guardErrors=[],qWitnesses=[],token={historyFault:label},method=push?'pushState':'replaceState';let depth=0,pHits=0,qHits=0,phase='',pSeen=false,nativeError,armed=false;
   const o={pushState:n.pushState,replaceState:n.replaceState};o[method]=function(...args){calls.push({receiver:this===history,args,depth});if(mode==='native')throw token;try{const result=n[method].apply(this,args);phase='after-native';return result;}catch(e){nativeError=e;throw e;}};
   const sensitive=a.sensitiveState(window);
   const rec=new a.Recorder({checkpointScheme:'dom-v1',checkpointHash:()=>a.domV1Hash(document),sanitize:r=>{const actual=a.sanitizeRecord(r,a.NO_SCRUB_LISTS,()=>a.currentSensitiveValues(window,sensitive));if(armed&&mode==='sanitize'&&r.record==='Navigation')throw token;return actual;},sink:{append(f){if(armed&&mode==='sink'){armed=false;throw token;}frames.push(f);},end(u,f){frames.push(f);},halt(){}}});rec.start({vocab:1,protocol_level:0,recorder_id:'history-control',framework:'',build_hash:'a'.repeat(64),session_id:'1'.repeat(32),prev_session:'',capabilities:'[]'},a.readEnvironment(window,n));
   const guard=rec.guard;const guardWitness=guard.call(rec,()=>token)===token;let guardCalls=0;rec.guard=function(fn){guardCalls++;return guard.call(this,()=>{depth++;try{return fn();}catch(e){guardErrors.push({same:e===token,depth});throw e;}finally{depth--;}});};
   if(mode==='missing-push')delete o.pushState;if(mode==='missing-replace')delete o.replaceState;if(mode==='bad-push')o.pushState=0;if(mode==='bad-replace')o.replaceState=0;let constructed=false,caught;
   const before=frames.length;try{hInit(mode==='missing-window'?null:mode==='bad-window'?{}:window,mode==='fake-recorder'?{}:rec,mode==='missing-originals'?null:o);constructed=true;}catch(e){caught=e;}
   const row={mode,life,label,push,constructed,constructorCalls:calls.length,constructorFrames:frames.length-before,guardWitness};if(!constructed){row.error=caught?.name;rows.push(row);continue;}
   if(mode==='minimal'){row.selection=[0,1,2,3].map(k=>hSelection(k,window,rec,o));rows.push(row);continue;}
   if(mode==='halted'||life==='halted')rec.halt();if(mode==='prefaulted'||life==='prefaulted')guard.call(rec,()=>{throw token;});if(mode==='ended'||life==='ended')rec.end(2);
   hSet(false,mode==='security'?'https://other.invalid/private':'../control?q=1');
   if(['Q','sanitize','encoder','sink','halted','prefaulted','ended'].includes(mode)){
    // Independent compiled ordinary P for THIS input, before any fault is armed.
    // Restoring the URL does not roll back an authority push's history entry.
    const saved=history[method],trace=[],beforeURL=location.href,lengthBefore=history.length,guardsBefore=guardCalls,framesBefore=frames.length;
    history[method]=function(...args){trace.push({receiver:this===history,args,depth});return n[method].apply(this,args);};
    let ordinary;try{ordinary=JSON.parse(hAuthority(push));}finally{history[method]=saved;}
    const authorityURL=location.href,lengthAfterAuthority=history.length;
    n.replaceState.call(history,null,'',beforeURL);
    row.successAuthority={observed:{present:ordinary.present,bytes:ordinary.bytes},trace,beforeURL,authorityURL,restoredURL:location.href,lengthBefore,lengthAfterAuthority,lengthAfterRestore:history.length,guardCalls:guardCalls-guardsBefore,frames:frames.length-framesBefore};
   }
   const char=String.prototype.charCodeAt,from=String.fromCharCode,encode=TextEncoder.prototype.encode;
   const positive={char:'A'.charCodeAt(0)===65,from:String.fromCharCode(65)==='A',guard:guardWitness};
   const baseline=frames.map(f=>Array.from(f));guardCalls=0;armed=true;
   String.prototype.charCodeAt=function(...args){if(phase==='after-native'&&String(this)===location.href){pHits++;pSeen=true;if(mode==='P'){phase='faulted';throw token;}}return char.apply(this,args);};
   String.fromCharCode=function(...args){if(mode==='key-error'&&phase===''&&armed){armed=false;qHits++;throw token;}if(mode==='Q'&&phase==='after-native'&&pSeen){qWitnesses.push({afterNative:true,stockPSeen:true,depth});phase='faulted';qHits++;throw token;}return from.apply(this,args);};
   TextEncoder.prototype.encode=function(v){if(armed&&mode==='encoder'&&String(v).includes('/control')){armed=false;throw token;}return encode.call(this,v);};
   if(mode==='P'){
    const original=history[method];history[method]=o[method];let authorityError;try{hAuthority(push);}catch(e){authorityError=e;}finally{history[method]=original;}row.authority={same:authorityError===token,nativeCalls:calls.length,guardCalls,pHits};calls.length=0;guardCalls=0;pHits=0;pSeen=false;phase='';
   }
   let result;try{result=JSON.parse(hRead(push));}catch(e){caught=e;}finally{String.prototype.charCodeAt=char;String.fromCharCode=from;TextEncoder.prototype.encode=encode;armed=false;}
   const later=frames.map(f=>a.decodeRecord(f.subarray(4))),frozen=!!life||['halted','prefaulted','ended'].includes(mode);row.nativeCalls=calls.length;row.nativeTrace=calls;row.depths=calls.map(x=>x.depth);row.guardCalls=guardCalls;row.pHits=pHits;row.qHits=qHits;row.qWitnesses=qWitnesses;row.guardErrors=guardErrors;row.same=caught!==undefined&&(caught===token||caught===nativeError);row.threw=!!caught;row.name=caught?.name;row.result=result;row.positive=positive;row.frozen=!frozen||JSON.stringify(baseline)===JSON.stringify(frames.map(f=>Array.from(f)));row.navigation=later.filter(x=>x.record==='Navigation').length;row.refusals=later.filter(x=>x.record==='Refusal').map(x=>x.feature);row.nativeHref=location.href;
   // The explicitly modified None source uses this arm; ordinary source has Some.
   rows.push(row);n.replaceState.call(history,null,'',url);
  }return rows;
 },{only,url,pushArm:process.env.HISTORY_PUSH||''});receipt({stage:'controls',rows});await p.close();
 for(const r of rows){semantic(r.guardWitness,true,'actual guard positive');semantic(r.constructorCalls,0,'constructor no native calls');semantic(r.constructorFrames,0,'constructor no frames');
  if(['missing-push','missing-replace','bad-push','bad-replace','missing-window','bad-window','missing-originals','fake-recorder'].includes(r.mode)){semantic(r.constructed,false,'missing linkage rejection');continue;}
  semantic(r.constructed,true,'actual minimal constructor');if(r.mode==='minimal'){semantic(r.selection,[true,true,true,true],'selection unchanged');continue;}
  semantic(Object.values(r.positive).every(Boolean),true,'stock path positive witnesses');
  if(r.mode==='key-error'){semantic(r.same,true,'input error identity');semantic(r.nativeCalls,0,'input failure before native');continue;}
  semantic(r.nativeCalls,1,'control original native count');semantic(r.depths,[0],'native outside guard');
  if(r.life)semantic(r.frozen,true,'terminal wire frozen on fresh fault');
  if(['native','security'].includes(r.mode)){semantic(r.same,true,'native exception identity');semantic(r.guardCalls,0,'native failure zero guard');semantic(r.pHits,0,'native failure zero P');semantic(r.navigation,0,'native failure zero emission');if(r.mode==='security')semantic(r.name,'SecurityError','real native SecurityError');continue;}
  if(r.mode==='P'){semantic(r.authority.same,true,'ordinary authority P exception identity');semantic(r.authority.nativeCalls,1,'ordinary authority P native call');semantic(r.authority.guardCalls,0,'ordinary authority P zero guard');assert(r.authority.pHits>0,'history semantic: ordinary stock P witness');semantic(r.same,true,'P exception identity outside guard');semantic(r.guardCalls,0,'P outside guard');semantic(r.navigation,0,'P failure zero emission');continue;}
  semantic(r.threw,false,'logging cannot replace native success');semantic(r.guardCalls,1,'one logging guard');
  if(r.mode==='Q'){semantic(r.qHits,1,'actual stock Q fault reached');semantic(r.qWitnesses,[{afterNative:true,stockPSeen:true,depth:1}],'production Q inside guard before diagnostics');semantic(r.guardErrors,[{same:true,depth:1}],'Q inside guard');}
  if(['Q','sanitize','encoder','sink'].includes(r.mode)){semantic(r.result.present,true,'logging preserves P');semantic(r.guardErrors,[{same:true,depth:1}],'named logging fault token caught inside guard');if(!r.life)semantic(r.refusals.includes('recorder-fault'),true,'actual terminal recorder fault');}
  if(r.life)semantic(r.frozen,true,'terminal wire frozen on fresh fault');
  if(['halted','prefaulted','ended'].includes(r.mode)){semantic(r.frozen,true,'terminal wire frozen');semantic(r.result.present,true,'terminal native P continues');}
  if(r.successAuthority){
   const a=r.successAuthority;semantic(a.trace.length,1,'successful ordinary authority native count');semantic(a.trace,r.nativeTrace,'successful ordinary authority exact native operation');semantic(a.guardCalls,0,'successful ordinary authority zero guard');semantic(a.frames,0,'successful ordinary authority zero emission');semantic(a.restoredURL,a.beforeURL,'authority URL restored before Record');semantic(a.lengthAfterRestore,a.lengthAfterAuthority,'URL restoration does not claim history-length rollback');semantic(r.nativeHref,a.authorityURL,'successful fault terminal native URL fidelity');
   semantic({present:r.result.present,bytes:r.result.bytes},a.observed,'fault and terminal exact ordinary Option bytes');
  }
  if(r.mode==='none'&&process.env.HISTORY_NONE==='1'){semantic(r.result.present,false,'manufactured None retained');semantic(r.navigation,0,'manufactured None no URL invented');semantic(r.refusals,r.life==='halted'||r.life==='ended'?[]:['recorder-fault'],'manufactured None guarded fault');}
 }
}
try{
 browser=await chromium.launch({executablePath:process.env.PLAYWRIGHT_CHROMIUM_EXECUTABLE});
 const p=await browser.newPage();await p.goto(url);await p.addScriptTag({content:early});semantic(await p.evaluate(()=>typeof hUncalled),'function','deliberate inert linked import');await p.close();
 await chain(companion,'relative');console.log('history companion positive: real Record -> strict codec -> Replay DONE');
 const inverse=process.env.HISTORY_INVERSE||'';
 if(inverse){if(inverse==='fault-return')await controls(compiled,process.env.HISTORY_FAULT_MODE);else if(['native-guard','P-guard','Q-before'].includes(inverse))await controls(compiled,inverse==='P-guard'?'P':inverse==='Q-before'?'Q':'native');else await chain(compiled,'relative');}
 else if(process.env.HISTORY_NONE==='1')await controls(compiled,'none');
 else{for(const mode of cases)await chain(compiled,mode);await controls(compiled);}
 console.log('history actual owner DONE count: '+done);
}finally{await browser?.close();await new Promise(r=>server.close(r));}
