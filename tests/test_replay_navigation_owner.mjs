/** Actual public Nim facade/native History -> actual Recorder sanitizer/strict
 * codec/installed cursor+loop/checkpoint. Observation wrappers call native once.
 * No fake cursor/tape/URL or replacement privacy registry. Explicit fixture
 * partial-window substitution tests metadata absence/error order only; it cannot
 * make positive URL data. Level0 DOM-backed holing proof is not typed level1 or
 * complete privacy/conformance acceptance. Header1 is a strict-codec negative.
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
const bundle=async source=>(await esbuild.build({stdin:{resolveDir:artifact,contents:source},bundle:true,format:'iife',platform:'browser',write:false})).outputFiles[0].text;
const owner=await bundle(`
import {Recorder,numberToBits} from '@codetracer/boundary-shim/dist/browser/recorder.js';
import {captureOriginals} from '@codetracer/boundary-shim/dist/browser/originals.js';
import {readEnvironment} from '@codetracer/boundary-shim/dist/browser/install.js';
import {domV1Hash} from '@codetracer/boundary-shim/dist/browser/dom-v1.js';
import {sensitiveState,currentSensitiveValues,makeCtApi} from '@codetracer/runtime-browser/dist/sensitive.js';
import {sanitizeRecord} from '@codetracer/boundary-shim/dist/browser/record-scrub.js';
import {NO_SCRUB_LISTS} from '@codetracer/runtime-browser/dist/scrub.js';
import {encodeLog,decodeRecord} from '@codetracer/boundary-format';
import {installReplayRuntime} from '@codetracer/boundary-replay/dist/browser/runtime.js';
globalThis.markField=kind=>{const state=sensitiveState(window);const api=makeCtApi(window,state,(_id,fn,self,args)=>fn.apply(self,args));if(kind==='sensitive')api.sensitive(document.querySelector('input'));else if(kind==='public')api.public(document.querySelector('input'));};
globalThis.watchHoleReads=()=>{globalThis.holeReads=0;const state=sensitiveState(window),original=state.getters.querySelectorAll;state.getters.querySelectorAll=function(...args){holeReads++;return original.apply(this,args);};};
globalThis.startNavOwner=()=>{const orig=captureOriginals(window),state=sensitiveState(window),frames=[];
const rec=new Recorder({sanitize:r=>sanitizeRecord(r,NO_SCRUB_LISTS,()=>currentSensitiveValues(window,state)),checkpointScheme:'dom-v1',checkpointHash:()=>domV1Hash(document),sink:{append(f){frames.push(f)},end(){},halt(){}}});
rec.start({vocab:1,protocol_level:0,recorder_id:'native-navigation-observation',framework:'',build_hash:'a'.repeat(64),session_id:'1'.repeat(32),prev_session:'',capabilities:'[]'},readEnvironment(window,orig));
performance.now=()=>{const value=orig.performanceNow.call(performance);rec.guard(()=>rec.emit('Clock',{src:2,bits:numberToBits(value)}));return value;};
Storage.prototype.getItem=function(key){const value=orig.storageGetItem.call(this,key);rec.guard(()=>rec.emit('StorageRead',{area:1,key,present:value===null?0:1,value:value??''}));return value;};
globalThis.nativeHistoryCalls=[];
for(const [method,kind] of [['pushState',1],['replaceState',2]])history[method]=function(...args){nativeHistoryCalls.push({method,state:args[0],title:args[1],url:args[2],receiver:this===history});orig[method].apply(this,args);rec.guard(()=>rec.emit('Navigation',{kind,url:location.href}));};
globalThis.stopNavOwner=level=>{rec.end(2);const records=frames.map(f=>decodeRecord(f.subarray(4)));if(level===1){records[0].protocol_level=1;records[0].framework='fixture';records[0].capabilities='["input","targets","inject","checkpoint","sensitive"]';}const log=encodeLog(records);const serial=value=>JSON.parse(JSON.stringify(value,(_,v)=>typeof v==='bigint'?String(v):v));return {log:btoa(String.fromCharCode(...log)),records:records.map(serial),calls:nativeHistoryCalls};};};
globalThis.installNavOwner=log=>installReplayRuntime(window,{log});
`);
const source=readFileSync(process.env.REPLAY_NAV_BUNDLE||root+'/build/replay-navigation.js','utf8');
let program=await bundle(source);
if(process.env.REPLAY_NAV_MALFORMED==='1')program=program.replace(/function holeText\(/,'function missingHoleText(').replace(/holeText: \(\) => holeText/,'holeText: () => undefined');
// Fault controls wrap the real imported owner module at bundle time only.
// Every available method delegates unchanged; one throws the original fixture
// token AFTER real holeText, the other omits one required export before effects.
const faultProgram=async fault=>(await esbuild.build({stdin:{resolveDir:artifact,contents:source},bundle:true,format:'iife',platform:'browser',write:false,plugins:[{name:'delegating-owner-fault-control',setup(build){build.onResolve({filter:/^@codetracer\/runtime-browser\/dist\/sensitive\.js$/},()=>({path:'fault',namespace:'fault'}));build.onLoad({filter:/.*/,namespace:'fault'},()=>({contents:`const actual=require(${JSON.stringify(artifact+'/packages/runtime-browser/dist/sensitive.js')});module.exports={...actual,holeText:${fault==='missing'?'undefined':"function(...args){actual.holeText(...args);throw globalThis.navHelperToken;}"}};`,resolveDir:artifact}));}}]})).outputFiles[0].text;
const missingExport=await faultProgram('missing'),helperFault=await faultProgram('throw');
const native=readFileSync(process.env.REPLAY_NAV_NATIVE||root+'/build/replay-navigation.js','utf8');
const inverse=process.env.REPLAY_NAV_INVERSE||'';
const cases=['public','base','empty','unicode','password','marked','override','field-change','form','json','two','switch','exception','security','metadata','disagreement','missing-boot','level1','unbundled','missing-export','helper-fault'];
const server=createServer((req,res)=>res.end('<!doctype html><base href="/base/nested/"><main>History</main><input type=text data-ct-public>'));
await new Promise(r=>server.listen(0,'127.0.0.1',r));
const url='http://127.0.0.1:'+server.address().port+'/initial/page';
const browser=await chromium.launch({executablePath:process.env.PLAYWRIGHT_CHROMIUM_EXECUTABLE});
const receipts=[];
const page=async()=>{const p=await browser.newPage();await p.goto(url);await p.addScriptTag({content:owner});return p;};
const modeList=inverse==='state'?['two']:inverse==='location'?['public']:inverse==='holing'?['password']:inverse?['base']:cases;
try{for(const mode of modeList){
const capture=await page();await capture.addScriptTag({content:native});
const observed=await capture.evaluate(mode=>{
 const field=document.querySelector('input');if(mode==='password')field.type='password';
 if(mode==='marked'||mode==='field-change'||mode==='form'||mode==='json')markField('sensitive');if(mode==='override'){field.removeAttribute('data-ct-public');markField('public');}
 field.value=mode==='json'?'first\\secret':'first-secret';localStorage.setItem('nav-neutral','ordinary');
 navReal();const context=JSON.parse(navBoot());startNavOwner();const control=JSON.parse(navNeutral());
 const start=navLocation(),paths=[],results=[];
 const inputs=mode==='json'?['../one?q='+JSON.stringify(field.value).slice(1,-1),'?q='+JSON.stringify('second\\secret').slice(1,-1)]:mode==='empty'?['']:mode==='unicode'?['../%E2%98%83?x=one%20two#é']:mode==='password'||mode==='marked'||mode==='field-change'||mode==='form'?['../one?q=first-secret',mode==='form'?'?q=second+secret':'?q=second%20secret'] : ['../first?q=one#x','?q=two#y','','#last'];
 for(let i=0;i<inputs.length;i++){if(i===1)field.value=mode==='json'?'second\\secret':'second secret';const method=i%2?'replace':'push';(method==='push'?navPush:navReplace)(inputs[i]);paths.push(navLocation());results.push({method,input:inputs[i],href:location.href,length:history.length});}
 let failure;try{navPush('https://other.invalid/private');}catch(e){failure={name:e.name,message:e.message};}
 return {context,control,start,paths,results,failure,...stopNavOwner(mode==='level1'?1:0)};
},mode);
assert.equal(observed.failure.name,'SecurityError');assert.equal(observed.records.filter(r=>r.record==='Navigation').length,observed.results.length);
assert(observed.calls.every(c=>c.state===null&&c.title===''&&c.receiver));
await capture.close();
const replay=await page();await replay.evaluate(({context,log})=>{installNavOwner(log);globalThis.navContext=context;globalThis.xrReadBootContext=context;globalThis.ownerLoads=0;const original=Symbol.for;Symbol.for=function(key){if(key==='codetracer.boundary.sensitive')ownerLoads++;return original.call(this,key);};},{context:observed.context,log:observed.log});
await replay.addScriptTag({content:mode==='unbundled'?source:mode==='missing-export'?missingExport:mode==='helper-fault'?helperFault:program});
assert.equal(await replay.evaluate(()=>ownerLoads),0,'private generated module load must not initialize owner helpers');
const setup=await replay.evaluate(({observed,mode,inverse})=>{
 const field=document.querySelector('input');if(mode==='password')field.type='password';if(mode==='marked'||mode==='field-change'||mode==='form'||mode==='json')markField('sensitive');if(mode==='override'){field.removeAttribute('data-ct-public');markField('public');}field.value=mode==='override'||mode==='public'||mode==='base'||mode==='empty'||mode==='unicode'||mode==='two'||mode==='switch'||mode==='exception'||mode==='security'||mode==='metadata'||mode==='disagreement'||mode==='missing-boot'||mode==='level1'||mode==='unbundled'?'first-secret':'other-placeholder';if(mode==='json')field.value='other\\placeholder';
 if(mode==='missing-boot')delete navContext.url;navReplay();const initialLoads=ownerLoads;
 globalThis.historyCalls=[];const push=history.pushState,replace=history.replaceState;
 for(const method of ['pushState','replaceState'])history[method]=function(...args){historyCalls.push({method,state:args[0],title:args[1],url:args[2],receiver:this===history});return (method==='pushState'?push:replace).apply(this,args);};
 globalThis.rawClocks=0;performance.now=()=>{rawClocks++;throw Error('RAW clock');};const D=Date;globalThis.Date=new Proxy(D,{apply(){rawClocks++;throw Error('RAW clock');},construct(target,args,newTarget){if(args.length===0){rawClocks++;throw Error('RAW clock');}return Reflect.construct(target,args,newTarget);},get(target,key,receiver){if(key==='now')return()=>{rawClocks++;throw Error('RAW clock');};return Reflect.get(target,key,receiver);}});
 for(const invoke of [()=>performance.now(),()=>Date.now(),()=>new Date(),()=>Date()]){const before=rawClocks;let error;try{invoke();}catch(e){error=e;}if(error?.message!=='RAW clock'||rawClocks!==before+1)throw Error('clock witness');}if(rawClocks!==4)throw Error('clock witness count');const explicit=new Date(0);if(!(explicit instanceof D)||explicit.getTime()!==0||Date.prototype!==D.prototype)throw Error('Date explicit control');rawClocks=0;
 const control=JSON.parse(navNeutral());const before=__ctReplay.peek(),paths=[],actual=[],states=[];
 let error,shared=false,sameClass=false,latchedPath=false;
 const attempt=fn=>{try{fn();}catch(e){error={text:String(e),name:e.name,divergence:e.divergence};if(e.divergence){let again;try{__ctReplay.next('Navigation');}catch(other){again=other;}shared=e.divergence===again?.divergence&&e.divergence===__ctReplay.failed;sameClass=e.constructor===again?.constructor;try{navLocation();}catch(other){latchedPath=other.constructor===e.constructor&&other.divergence===e.divergence;}}}};
 if(mode==='exception')watchHoleReads();
 const initial=mode==='level1'||mode==='missing-boot'?observed.start:navLocation();
 if(mode==='disagreement'){navOtherBoot('https://different.invalid/');attempt(()=>navLocation());navReselect();}
 else if(mode==='missing-boot'){attempt(()=>navLocation());}
 else if(mode==='exception'){
  const token=Error('original History exception');let metadata=0;navPartial({history:{pushState(){throw token;}},get location(){metadata++;throw Error('metadata');}});let caught;try{navPush('/throws');}catch(e){caught=e;}navRestoreWindow();if(caught!==token||metadata!==0||holeReads!==0)throw Error('original exception identity/order');states.push('exception exact');
 }
 if(mode==='helper-fault'){
  globalThis.navHelperToken=Error('original postmutation helper token');let caught;const seq=__ctReplay.peek().seq;try{navPush('/helper-fault');}catch(e){caught=e;}if(caught!==navHelperToken||__ctReplay.failed||__ctReplay.peek().seq!==seq)throw Error('helper failure identity/latch/cursor');let blocked;try{navLocation();}catch(e){blocked=e;}if(!blocked)throw Error('helper fault left stale URL state valid');let ownerFailure;try{__ctReplay.next('Clock',{src:2});}catch(e){ownerFailure=e;}let forwarded;try{navLocation();}catch(e){forwarded=e;}if(!ownerFailure?.divergence||forwarded?.constructor!==ownerFailure.constructor||forwarded.divergence!==ownerFailure.divergence||forwarded.divergence!==__ctReplay.failed||__ctReplay.peek().seq!==seq)throw Error('owner latch must override unusable URL state');error={text:String(caught)};states.push('helper fault exact');
 }
 else if(mode==='level1'||mode==='unbundled'||mode==='missing-export')attempt(()=>navPush('/refused'));
 else if(!error){
 for(let i=0;i<observed.results.length;i++){
  const sample=observed.results[i];if(i===1){field.value=mode==='json'?'different\\placeholder':(mode==='password'||mode==='marked'||mode==='field-change'||mode==='form')?'different placeholder':'second secret';if(mode==='two'){navAgain();states.push(navLocation());}if(mode==='switch'){navTest();navReselect();}}
  const input=mode==='json'?sample.input.replace(JSON.stringify(i===0?'first\\secret':'second\\secret').slice(1,-1),JSON.stringify(i===0?'other\\placeholder':'different\\placeholder').slice(1,-1)):(mode==='password'||mode==='marked'||mode==='field-change'||mode==='form')?sample.input.replaceAll('first-secret','other-placeholder').replaceAll('second%20secret','different%20placeholder').replaceAll('second+secret','different+placeholder'):sample.input;
  attempt(()=>(sample.method==='push'?navPush:navReplace)(input));if(error)break;
  paths.push(navLocation());actual.push({href:location.href,length:history.length});
  if(inverse==='history')break;
 }
 if(mode==='security'&&!error){const prior=navLocation(),seq=__ctReplay.peek().seq;let caught;try{navPush('https://other.invalid/private');}catch(e){caught=e;}if(caught?.name!=='SecurityError'||navLocation()!==prior||seq!==__ctReplay.peek().seq)throw Error('native SecurityError changed cursor/state');states.push('security exact');}
 if(mode==='metadata'&&!error){const seq=__ctReplay.peek().seq;navPartial({history:{pushState(...args){push.apply(history,args);}},location:{}});attempt(()=>navPush('/actual-metadata-missing'));navRestoreWindow();let blocked;try{navLocation();}catch(e){blocked=e;}if(!blocked||__ctReplay.peek().seq!==seq)throw Error('unavailable URL continued');states.push('metadata refused');}
 if(mode==='exception'&&holeReads!==observed.results.length)throw Error('holing-read detector positive witness');
 if(inverse==='location'){replace.call(history,null,'','/external-change');paths.push(navLocation());}
 }
 return {control,initial,initialLoads,paths,actual,error,shared,sameClass,latchedPath,before,after:__ctReplay.peek(),calls:historyCalls,rawClocks,states};
},{observed,mode,inverse});
receipts.push({mode,observed,setup});
assert.deepEqual(setup.control,observed.control,'neutral actual reads');assert.equal(setup.initial,observed.start);assert.equal(setup.rawClocks,0);assert.equal(setup.initialLoads,0,'only explicit fixture marking may ask existing state before nav');
if(inverse==='history'){assert.equal(setup.error,undefined);assert.equal(setup.actual[0].href,observed.results[0].href);assert.equal(setup.paths[0],observed.start);assert.equal(setup.calls.length,1);assert.equal(setup.before.seq,setup.after.seq);console.log('raw history restoration REJECTED by actual mutation plus pending Navigation');}
else if(inverse==='kind'||inverse==='relative'||inverse==='holing'){assert.equal(setup.error?.divergence?.kind,'ArgumentMismatch');assert(setup.error.divergence.detail.includes('Navigation.'+(inverse==='kind'?'kind':'url')),'exact owner checked field');assert.equal(setup.error.divergence.seq,setup.before.seq);assert.equal(setup.before.seq,setup.after.seq);assert(setup.shared&&setup.sameClass&&setup.latchedPath);console.log(inverse+' inverse REJECTED at genuine Navigation with original class/shared latch/cursor');}
else if(inverse==='state'){assert.equal(setup.error,undefined);assert.deepEqual(setup.paths,observed.paths);assert.equal(setup.states[0],observed.start);assert.notEqual(setup.states[0],observed.paths[0]);console.log('per-clock state reset REJECTED by actual second-clock pathname');}
else
 if(inverse==='location'){assert.equal(setup.paths.at(-1),'/external-change');assert.notEqual(setup.paths.at(-1),observed.paths.at(-1));console.log('raw location restoration REJECTED by actual external native mutation');}
else if(['disagreement','missing-boot','level1','unbundled','missing-export','helper-fault','metadata'].includes(mode)){assert(setup.error,mode+' must refuse');const diagnostics={disagreement:'boot URL disagreement','missing-boot':'requires genuine boot URL',level1:'requires actual owner level 0',unbundled:'requires bundled owner URL helpers','missing-export':'requires owner holeText','helper-fault':'original postmutation helper token',metadata:'reflected URL unavailable'};assert(setup.error.text.includes(diagnostics[mode]),mode+' exact private boundary diagnostic');if(mode==='metadata')assert.equal(setup.after.kind,'Checkpoint');else assert.equal(setup.before.seq,setup.after.seq,mode+' cursor remains');if(mode==='helper-fault')assert.equal(setup.calls.length,1,'actual method precedes helper fault');else if(mode!=='metadata')assert.equal(setup.calls.length,0,mode+' preeffect refusal');}
else{assert.equal(setup.error,undefined);if(mode==='two')assert.equal(setup.states[0],observed.paths[0],'second clock retains checked URL before next mutation');assert.deepEqual(setup.paths,observed.paths);assert.deepEqual(setup.actual.map(v=>v.length),observed.results.map(v=>v.length));await replay.waitForFunction(()=>['done','diverged'].includes(__ctReplay.status().state));const status=await replay.evaluate(()=>__ctReplay.status());assert.equal(status.state,'done');receipts.at(-1).status=status;}
console.log(mode+' navigation assertions PASS');await replay.close();
}if(process.env.REPLAY_NAV_RECEIPT)writeFileSync(process.env.REPLAY_NAV_RECEIPT,JSON.stringify(receipts,(_,v)=>typeof v==='bigint'?String(v):v,2));}finally{await browser.close();await new Promise(r=>server.close(r));}
