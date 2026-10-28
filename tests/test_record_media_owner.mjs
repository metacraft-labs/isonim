/** Actual compiled Nim -> captured Chromium media originals -> installed Recorder
 * -> strict codec -> existing public Replay -> owned loop/real DOM-v1 DONE.
 * Wrappers count and forward real native functions with exact receivers. Narrow
 * native throw/media-serialization faults test owner policy, not invented MQLs.
 * No fake recorder/provider/cursor/tape/task/checkpoint/DONE/hash is used.
 */
import assert from 'node:assert/strict';
import {readFileSync,appendFileSync} from 'node:fs';
import {createRequire} from 'node:module';
import {createServer} from 'node:http';
const root=process.cwd(),artifact=process.env.CT_ARTIFACT;
assert(artifact,'CT_ARTIFACT required: actual installed owner integration cannot skip');
for(const key of ['RECORD_MEDIA_BUNDLE','RECORD_MEDIA_REPLAY','RECORD_MEDIA_CONTEXT','RECORD_MEDIA_COMPANION'])assert(process.env[key],key+' required: explicit current compiled input');
const {build}=createRequire(artifact+'/packages/boundary-shim/package.json')('esbuild');
const {chromium}=await import(root+'/tests/browser/node_modules/playwright/index.mjs');
const imports=`
import {Recorder,numberToBits} from '@codetracer/boundary-shim/dist/browser/recorder.js';
import {captureOriginals} from '@codetracer/boundary-shim/dist/browser/originals.js';
import {readEnvironment} from '@codetracer/boundary-shim/dist/browser/install.js';
import {domV1Hash} from '@codetracer/boundary-shim/dist/browser/dom-v1.js';
import {encodeLog,decodeLog,decodeRecord} from '@codetracer/boundary-format';
import {installReplayRuntime} from '@codetracer/boundary-replay/dist/browser/runtime.js';
globalThis.mediaApi={Recorder,numberToBits,captureOriginals,readEnvironment,domV1Hash,encodeLog,decodeLog,decodeRecord,installReplayRuntime};`;
async function bundle(source){return(await build({stdin:{resolveDir:artifact,contents:source},bundle:true,platform:'browser',format:'iife',write:false})).outputFiles[0].text;}
const suffix='\nObject.assign(globalThis,{rmInit,rmRead,rmSwitchTest,rmSelected,rmRecordClock});';
const compiled=await bundle(imports+readFileSync(process.env.RECORD_MEDIA_BUNDLE,'utf8')+suffix);
const companion=await bundle(imports+readFileSync(process.env.RECORD_MEDIA_COMPANION,'utf8')+suffix);
const owner=await bundle(imports),replay=readFileSync(process.env.RECORD_MEDIA_REPLAY,'utf8'),capture=readFileSync(process.env.RECORD_MEDIA_CONTEXT,'utf8');
const server=createServer((req,res)=>res.end('<!doctype html><main>Private media</main>'));
await new Promise(r=>server.listen(0,'127.0.0.1',r));const url='http://127.0.0.1:'+server.address().port;
function receipt(value){if(process.env.RECORD_MEDIA_RESULTS)appendFileSync(process.env.RECORD_MEDIA_RESULTS,JSON.stringify(value)+'\n');}
let browser;
try{
 browser=await chromium.launch({executablePath:process.env.PLAYWRIGHT_CHROMIUM_EXECUTABLE});
 const cases=[['companion',companion,'positive'],...(process.env.RECORD_MEDIA_INVERSE?[['inverse',compiled,'positive']]:['positive','ownership','match-throw','matches-throw','stopped','faulted','invalid','media-throw','conversion-throw','null-media','undefined-media'].map(mode=>['candidate',compiled,mode]))];
 for(const [arm,code,mode] of cases){
  const context=await browser.newContext({viewport:{width:733,height:457},colorScheme:'light'});
  const prior=await context.newPage();await prior.goto(url);await prior.addScriptTag({content:capture});const boot=await prior.evaluate(()=>xrReadBootContext);await prior.close();
  const page=await context.newPage();await page.goto(url);await page.addScriptTag({content:code});
  const setup=await page.evaluate(mode=>{
   const a=mediaApi,native=a.captureOriginals(window),mediaDescriptor=Object.getOwnPropertyDescriptor(MediaQueryList.prototype,'media');
   const counts={match:0,matches:0,media:0},receivers=[],trace=[],sentinel={nativeMediaFailure:true};let throwAt='',mediaFault='';let last;
   window.matchMedia=function(q){counts.match++;receivers.push(this===window);trace.push('match');if(throwAt==='match')throw sentinel;last=native.matchMedia.call(this,q);return last;};
   Object.defineProperty(MediaQueryList.prototype,'matches',{configurable:true,get(){counts.matches++;receivers.push(this===last);trace.push('matches');if(throwAt==='matches')throw sentinel;return native.mediaQueryMatches.descriptor.get.call(this);}});
   Object.defineProperty(MediaQueryList.prototype,'media',{configurable:true,get(){counts.media++;receivers.push(this===last);trace.push('media');if(mediaFault==='media-throw')throw sentinel;if(mediaFault==='conversion-throw')return{toString(){throw sentinel;}};if(mediaFault==='null-media')return null;if(mediaFault==='undefined-media')return undefined;return mediaDescriptor.get.call(this);}});
   const captured=a.captureOriginals(window),owners=[];
   function make(id){const frames=[];let fail=false;const rec=new a.Recorder({checkpointScheme:'dom-v1',checkpointHash:()=>a.domV1Hash(document),sink:{append(f){const r=a.decodeRecord(f.subarray(4));if(r.record==='LayoutRead')trace.push('wire');if(fail&&r.record==='LayoutRead'){fail=false;throw Error('actual media sink fault');}frames.push(f);},end(unloading,frame){frames.push(frame);},halt(){}}});rec.start({vocab:1,protocol_level:0,recorder_id:'private-media-'+id,framework:'',build_hash:'a'.repeat(64),session_id:String(id).repeat(32),prev_session:'',capabilities:'[]'},a.readEnvironment(window,native));const o={rec,frames,fault(){fail=true;}};owners.push(o);return o;}
   const first=make(1),second=mode==='ownership'?make(2):null;Object.keys(counts).forEach(k=>counts[k]=0);receivers.length=trace.length=0;
   globalThis.recordMediaOwner={window,rec:first.rec,orig:captured};const initial=first.frames.length;
   const s={native,mediaDescriptor,captured,owners,first,second,counts,receivers,trace,sentinel,setThrow(v){throwAt=v;},setMediaFault(v){mediaFault=v;}};globalThis.mediaState=s;
   if(mode==='invalid'){
    const errors=[];for(const c of [{window:{},rec:first.rec,orig:captured},{window,rec:{},orig:captured},{window,rec:first.rec,orig:{}},{window,rec:first.rec,orig:{matchMedia:null,mediaQueryMatches:captured.mediaQueryMatches}},{window,rec:first.rec,orig:{matchMedia:captured.matchMedia}},{window,rec:first.rec,orig:{matchMedia:captured.matchMedia,mediaQueryMatches:{descriptor:{get:null}}}}]){globalThis.recordMediaOwner=c;try{rmInit();errors.push(null);}catch(e){errors.push({name:e.name,message:e.message});}}
    return{counts,initial,after:first.frames.length,errors};
   }
   const ids=[rmInit()];if(second){ids.push(rmInit());recordMediaOwner={window,rec:second.rec,orig:captured};ids.push(rmInit());rmSwitchTest();if(rmSelected()!==17.25)throw Error('unrelated selected clock');ids.push(ids[0]);}s.ids=ids;
   const late={match:0,matches:0};window.matchMedia=function(){late.match++;throw sentinel;};Object.defineProperty(MediaQueryList.prototype,'matches',{configurable:true,get(){late.matches++;throw sentinel;}});
   let error;try{window.matchMedia('all');}catch(e){error=e;}if(error!==sentinel||late.match!==1)throw Error('independent late match witness');late.match=0;
   error=undefined;try{void native.matchMedia.call(window,'all').matches;}catch(e){error=e;}if(error!==sentinel||late.matches!==1)throw Error('independent late matches witness');late.matches=0;s.late=late;
   return{counts:{...counts},initial,after:first.frames.length};
  },mode);
  receipt({arm,mode,stage:'construction',setup});assert.deepEqual(setup.counts,{match:0,matches:0,media:0},'constructor no native observation');assert.equal(setup.initial,setup.after,'constructor no emission');
  if(mode==='invalid'){assert(setup.errors.every(e=>e?.name==='TypeError'&&e.message==='internal Record media requires actual Window, captured originals and actual Recorder'));await context.close();console.log('media invalid: PASS');continue;}
  await page.evaluate(()=>{const s=mediaState;s.clockValues=s.owners.map((o,i)=>{const id=s.ids[i===0?0:2];return[rmRecordClock(id),rmRecordClock(id)];});});
  if(mode==='positive')await page.evaluate(()=>{
   const s=mediaState,expected=[],out=[],failures=[];
   for(const query of ['(min-width: 800px)','(prefers-color-scheme: dark)']){
    const m=s.native.matchMedia.call(window,query);expected.push({query,media:s.mediaDescriptor.get.call(m),matches:s.native.mediaQueryMatches.descriptor.get.call(m)});
    try{out.push(rmRead(s.ids[0],query));}catch(e){failures.push(e===s.sentinel);}
   }
   s.pre={expected,out,failures};
  });
  await page.setViewportSize({width:811,height:509});await page.emulateMedia({colorScheme:'dark'});
  const result=await page.evaluate(mode=>{
   const s=mediaState,a=mediaApi,queries=['(min-width: 800px)',' ( MIN-width : 1px ) ','(max-width: 700px)','(prefers-color-scheme: dark)','screen and (width >= 800px)','print, screen','invalid ???','','all',' ( MIN-width : 1px ) '];
   const current=queries.map(q=>{const m=s.native.matchMedia.call(window,q);return{query:q,media:s.mediaDescriptor.get.call(m),matches:s.native.mediaQueryMatches.descriptor.get.call(m)};});
   const expected=[...(s.pre?.expected??[]),...current],out=[...(s.pre?.out??[])],failures=[...(s.pre?.failures??[])];
   function call(id,q){try{out.push(rmRead(id,q));}catch(e){failures.push(e===s.sentinel);}}
   if(mode==='stopped')s.first.rec.end(2);const before=s.first.frames.length;if(mode==='faulted')s.first.fault();
   if(mode==='match-throw'||mode==='matches-throw'){s.setThrow(mode.split('-')[0]);call(s.ids[0],'all');s.setThrow('');}
   if(['media-throw','conversion-throw','null-media','undefined-media'].includes(mode))s.setMediaFault(mode);
   for(const id of s.ids)for(const q of queries)call(id,q);
   for(const o of s.owners)o.rec.end(2);
   const sessions=s.owners.map((o,i)=>{const records=o.frames.map(f=>a.decodeRecord(f.subarray(4))),bytes=a.encodeLog(records),decoded=a.decodeLog(bytes);let raw='';for(const b of bytes)raw+=String.fromCharCode(b);return{clocks:s.clockValues[i],clockBits:s.clockValues[i].map(v=>a.numberToBits(v).toString()),records:JSON.parse(JSON.stringify(decoded.records,(_,v)=>typeof v==='bigint'?String(v):v)),log:btoa(raw),termination:decoded.termination};});
   return{expected,out,failures,counts:s.counts,receivers:s.receivers,trace:s.trace,late:s.late,sessions,before,after:s.first.frames.length,ids:s.ids.length};
  },mode);receipt({arm,mode,stage:'record',result});
  if(mode==='positive'){for(const q of ['(min-width: 800px)','(prefers-color-scheme: dark)']){const pair=result.expected.filter(v=>v.query===q);assert.equal(pair.length,2,'same native query observed twice');assert.deepEqual(pair.map(v=>v.matches),[false,true],'genuine same-query native media changes after viewport/preference perturbation');}}
  assert(result.expected.some(v=>v.query!==v.media),'native canonical serialization differs authored query witness');
  assert.deepEqual(result.late,{match:0,matches:0},'media semantic: captured originals bypass witnessed late replacements');
  assert(result.receivers.length>0&&result.receivers.every(Boolean),'media semantic: exact Window and MediaQueryList receivers');
  const calls=result.expected.length*result.ids,extraMatch=mode.endsWith('throw')&&['match-throw','matches-throw'].includes(mode)?1:0,extraMatches=mode==='matches-throw'?1:0;
  assert.deepEqual(result.failures,extraMatch?[true]:[],'native throw identity only');
  assert.deepEqual(result.out,Array.from({length:result.ids},()=>result.expected.map(v=>v.matches)).flat(),'media semantic: unchanged native boolean');
  for(const session of result.sessions){const clocks=session.records.filter(r=>r.record==='Clock');assert.equal(clocks.length,2,'two genuine RecordClock observations per owner');assert.deepEqual(clocks.map(r=>r.src),[2,2]);assert.deepEqual(clocks.map(r=>r.bits),session.clockBits,'exact captured native Clock2 double bits');}
  if(mode==='stopped'){assert.deepEqual(result.counts,{match:calls,matches:calls,media:calls});assert.equal(result.before,result.after);assert.equal(result.sessions[0].termination,'Complete');console.log('media stopped: PASS');await context.close();continue;}
  if(mode==='faulted'){assert.deepEqual(result.counts,{match:calls,matches:calls,media:calls});assert.deepEqual(result.sessions[0].records.filter(r=>!['Header','Env'].includes(r.record)).map(r=>r.record),['Clock','Clock','Refusal']);assert.equal(result.sessions[0].records.at(-1).feature,'recorder-fault');assert.equal(result.sessions[0].termination,'TruncatedUnterminated');console.log('media faulted: PASS');await context.close();continue;}
  assert.deepEqual(result.counts,{match:calls+extraMatch,matches:calls+extraMatches,media:calls},'media semantic: one captured match and matches per call');
  const prefix=mode==='match-throw'?['match']:mode==='matches-throw'?['match','matches']:[];
  assert.deepEqual(result.trace,[...prefix,...Array.from({length:calls},()=>['match','matches','media','wire']).flat()],'media semantic: native getter before guarded serialization and wire');
  for(let si=0;si<result.sessions.length;si++){
   const session=result.sessions[si],reads=session.records.filter(r=>r.record==='LayoutRead'),repeats=mode==='ownership'?(si===0?3:1):1;
   assert.equal(session.termination,'Complete');assert.equal(reads.length,result.expected.length*repeats,'media semantic: nonempty exact successful observation count');
   const expected=Array.from({length:repeats},()=>result.expected).flat();
   assert(reads.every(r=>r.target==='win'),'media semantic: exact Window target');
   assert.deepEqual(reads.map(r=>r.prop),expected.map(v=>'matchMedia:'+(['media-throw','conversion-throw','null-media','undefined-media'].includes(mode)?'':v.media)),'media semantic: exact native serialized media key');
   assert.deepEqual(reads.map(r=>r.value),expected.map(v=>JSON.stringify({matches:v.matches})),'media semantic: exact native boolean wire');
   // Injected serialization errors intentionally make empty keys; those verify
   // owner fallback only. Native sessions must pass public checked Replay.
   if(['media-throw','conversion-throw','null-media','undefined-media'].includes(mode))continue;
   const rp=await context.newPage();await rp.goto(url);await rp.addScriptTag({content:owner});
   const replayed=await rp.evaluate(({log,replay,boot,queries})=>{
    mediaApi.installReplayRuntime(window,{log});globalThis.xrReadBootContext=boot;const counts={match:0,matches:0,clock:0},sentinel=Error('live Replay media');
    const native=mediaApi.captureOriginals(window);performance.now=function(){counts.clock++;throw sentinel;};window.matchMedia=function(){counts.match++;throw sentinel;};Object.defineProperty(MediaQueryList.prototype,'matches',{configurable:true,get(){counts.matches++;throw sentinel;}});
    let e;try{window.matchMedia('all');}catch(x){e=x;}if(e!==sentinel||counts.match!==1)throw Error('Replay match trap witness');counts.match=0;e=undefined;try{void native.matchMedia.call(window,'all').matches;}catch(x){e=x;}if(e!==sentinel||counts.matches!==1)throw Error('Replay matches trap witness');counts.matches=0;e=undefined;try{performance.now();}catch(x){e=x;}if(e!==sentinel||counts.clock!==1)throw Error('Replay clock trap witness');counts.clock=0;
    (0,eval)(replay);const clocks=[rmReplayMono(),rmReplayNeMono()];const out=queries.map(q=>rmReplay(q));globalThis.mediaReplayCounts=counts;return{out,counts,clocks};
   },{log:session.log,replay,boot,queries:expected.map(v=>v.query)});
   assert.equal(replayed.clocks[0],session.clocks[0],'public ClockBase consumes exact genuine Clock2 double');assert.equal(replayed.clocks[1],String(BigInt(Math.trunc(session.clocks[1]))),'NE consumes genuine Clock2 with unchanged integer projection');
   assert.deepEqual(replayed.out,expected.map(v=>v.matches),'actual public Replay media values');assert.deepEqual(replayed.counts,{match:0,matches:0,clock:0});
   await rp.waitForFunction(()=>['done','diverged'].includes(__ctReplay.status().state));const done=await rp.evaluate(()=>({status:__ctReplay.status(),counts:mediaReplayCounts}));receipt({arm,mode,stage:'replay',owner:si,replayed,done});assert.equal(done.status.state,'done');assert.equal(done.status.tasks,0);assert.deepEqual(done.counts,{match:0,matches:0,clock:0});assert.equal(session.records.filter(r=>r.record==='Checkpoint').length,1);assert.equal(session.records.at(-1).record,'End');await rp.close();
   console.log('media '+arm+' '+mode+' owner '+si+': actual compiled Record -> strict reader -> public Replay DONE');
  }
  await context.close();
 }
}finally{await browser?.close();await new Promise(r=>server.close(r));}
