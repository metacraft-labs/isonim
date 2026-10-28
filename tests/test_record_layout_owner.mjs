/** Actual compiled Nim -> installed Recorder/strict reader -> public Replay.
 * Primary values come from Chromium's native Window accessors after real resize.
 * Counted accessors delegate to those exact native getters with actual receiver.
 * Narrow getter throw/numeric controls and a one-shot real sink fault test
 * exception/JSON edges, not native production of fractional/-0/NaN viewport.
 * No fake writer, tape, cursor, scheduler, checkpoint or provider is used.
 */
import assert from 'node:assert/strict';
import {readFileSync,appendFileSync} from 'node:fs';
import {createRequire} from 'node:module';
import {createServer} from 'node:http';
const root=process.cwd(),artifact=process.env.CT_ARTIFACT;
assert(artifact,'CT_ARTIFACT required: actual installed owner integration cannot skip');
const {build}=createRequire(artifact+'/packages/boundary-shim/package.json')('esbuild');
const {chromium}=await import(root+'/tests/browser/node_modules/playwright/index.mjs');
const imports=`
import {Recorder} from '@codetracer/boundary-shim/dist/browser/recorder.js';
import {captureOriginals} from '@codetracer/boundary-shim/dist/browser/originals.js';
import {readEnvironment} from '@codetracer/boundary-shim/dist/browser/install.js';
import {domV1Hash} from '@codetracer/boundary-shim/dist/browser/dom-v1.js';
import {encodeLog,decodeLog,decodeRecord} from '@codetracer/boundary-format';
import {installReplayRuntime} from '@codetracer/boundary-replay/dist/browser/runtime.js';
globalThis.layoutApi={Recorder,captureOriginals,readEnvironment,domV1Hash,encodeLog,decodeLog,decodeRecord,installReplayRuntime};`;
async function bundle(source){return (await build({stdin:{resolveDir:artifact,contents:source},bundle:true,platform:'browser',format:'iife',write:false})).outputFiles[0].text;}
// One bundle shares the exact Recorder class across Nim require and imports.
const compiled=await bundle(imports+readFileSync(process.env.RECORD_LAYOUT_BUNDLE,'utf8')+'\nObject.assign(globalThis,{rlInit,rlRead,rlSwitchTest,rlSelected});');
const owner=await bundle(imports), replay=readFileSync(process.env.RECORD_LAYOUT_REPLAY,'utf8');
assert(process.env.RECORD_LAYOUT_CONTEXT,'RECORD_LAYOUT_CONTEXT required: current compiled context cannot fall back');
const capture=readFileSync(process.env.RECORD_LAYOUT_CONTEXT,'utf8');
const modes=process.env.RECORD_LAYOUT_INVERSE?['positive']:['positive','ownership','width-throw','height-throw','stopped','faulted','invalid','numeric'];
const server=createServer((req,res)=>res.end('<!doctype html><main>Private viewport</main>'));
await new Promise(r=>server.listen(0,'127.0.0.1',r));const url='http://127.0.0.1:'+server.address().port;
function receipt(value){if(process.env.RECORD_LAYOUT_RESULTS)appendFileSync(process.env.RECORD_LAYOUT_RESULTS,JSON.stringify(value,(_,v)=>typeof v==='bigint'?String(v):typeof v==='number'&&!Number.isFinite(v)?String(v):Object.is(v,-0)?'-0':v)+'\n');}
let browser;
try{
 browser=await chromium.launch({executablePath:process.env.PLAYWRIGHT_CHROMIUM_EXECUTABLE});
 for(const mode of modes){
  const context=await browser.newContext({viewport:{width:733,height:457}});
  const prior=await context.newPage();await prior.goto(url);await prior.addScriptTag({content:capture});
  const boot=await prior.evaluate(()=>xrReadBootContext);await prior.close();
  const page=await context.newPage();await page.goto(url);await page.addScriptTag({content:compiled});
  const setup=await page.evaluate(mode=>{
   const a=layoutApi,orig=a.captureOriginals(window),native={width:orig.layoutGetters.get('innerWidth').descriptor.get,height:orig.layoutGetters.get('innerHeight').descriptor.get};
   const counts={width:0,height:0},receivers=[],trace=[],sentinel={nativeLayoutFailure:true};let throwAt='',numeric=null;
   for(const prop of ['width','height'])Object.defineProperty(window,prop==='width'?'innerWidth':'innerHeight',{configurable:true,get(){counts[prop]++;receivers.push(this===window);trace.push(prop);if(throwAt===prop)throw sentinel;return numeric?numeric[prop]:native[prop].call(this);}});
   const captured=a.captureOriginals(window),owners=[];
   function make(id){const frames=[];let fail=false;const rec=new a.Recorder({checkpointScheme:'dom-v1',checkpointHash:()=>a.domV1Hash(document),sink:{append(f){const r=a.decodeRecord(f.subarray(4));if(r.record==='LayoutRead')trace.push(r.prop);if(fail&&r.record==='LayoutRead'){fail=false;throw Error('actual viewport sink fault');}frames.push(f);},end(unloading,frame){frames.push(frame);},halt(){}}});const env=a.readEnvironment(window,orig);rec.start({vocab:1,protocol_level:0,recorder_id:'private-layout-'+id,framework:'',build_hash:'a'.repeat(64),session_id:String(id).repeat(32),prev_session:'',capabilities:'[]'},env);const o={rec,frames,env,fault(){fail=true;}};owners.push(o);return o;}
   const first=make(1),second=mode==='ownership'?make(2):null;
   counts.width=counts.height=0;receivers.length=trace.length=0;
   const before={...counts},initial=first.frames.length;
   globalThis.recordLayoutOwner={window,rec:first.rec,orig:captured};
   const api={owners,counts,receivers,trace,sentinel,orig:captured,first,second,setThrow(v){throwAt=v;},setNumeric(v){numeric=v;}};globalThis.layoutState=api;
   if(mode==='invalid'){
    const errors=[];for(const c of [{window:{window:null},rec:first.rec,orig:captured},{window,rec:{guard(){},emit(){}},orig:captured},{window,rec:first.rec,orig:{layoutGetters:new Map()}},{window,rec:first.rec,orig:{layoutGetters:new Map([['innerWidth',{get:native.width}],['innerHeight',{descriptor:{get:native.height}}]])}},{window,rec:first.rec,orig:{layoutGetters:new Map([['innerWidth',{descriptor:{get:native.width}}],['innerHeight',{descriptor:{get:null}}]])}}]){globalThis.recordLayoutOwner=c;try{rlInit();errors.push(null);}catch(e){errors.push({name:e.name,message:e.message});}}
    return {before,after:{...counts},initial,frames:first.frames.length,errors};
   }
   const p0=rlInit(),ids=[p0];if(second){ids.push(rlInit());globalThis.recordLayoutOwner={window,rec:second.rec,orig:captured};ids.push(rlInit());rlSwitchTest();if(rlSelected()!==17.25)throw Error('unrelated Test selection');ids.push(p0);}
   api.ids=ids;
   const late={width:0,height:0};for(const [key,prop] of [['width','innerWidth'],['height','innerHeight']])Object.defineProperty(window,prop,{configurable:true,get(){late[key]++;throw sentinel;}});
   for(const [key,prop] of [['width','innerWidth'],['height','innerHeight']]){let error;try{void window[prop];}catch(e){error=e;}if(error!==sentinel||late[key]!==1)throw Error('independent late trap witness '+key);late[key]=0;}
   api.late=late;
   return {before,after:{...counts},initial,frames:first.frames.length,boot:{width:first.env.viewport_w,height:first.env.viewport_h}};
  },mode);
  receipt({mode,stage:'construction',setup});
  if(mode==='invalid'){assert.deepEqual(setup.after,setup.before,'invalid constructor zero reads');assert.equal(setup.frames,setup.initial,'invalid constructor zero records');assert(setup.errors.every(e=>e?.name==='TypeError'));console.log('layout invalid linkage: PASS');await context.close();continue;}
  assert.deepEqual(setup.before,setup.after,'constructor zero viewport observation');assert.equal(setup.initial,setup.frames,'constructor zero emission');assert.deepEqual(setup.boot,{width:733,height:457});
  await page.setViewportSize({width:811,height:509});
  const result=await page.evaluate(mode=>{
   const s=layoutState,a=layoutApi,out=[],failures=[];
   const call=id=>{try{const v=rlRead(id);out.push({width:v.width,height:v.height,negativeZeroWidth:Object.is(v.width,-0),nanWidth:Number.isNaN(v.width),infiniteWidth:v.width===Infinity});}catch(e){failures.push({same:e===s.sentinel});}};
   if(mode==='stopped')s.first.rec.end(2);
   const before=s.first.frames.length;
   if(mode==='faulted')s.first.fault();
   if(mode==='width-throw'||mode==='height-throw'){s.setThrow(mode.split('-')[0]);call(s.ids[0]);s.setThrow('');}
   if(mode==='numeric')for(const value of [1.25,-0,NaN,Infinity,-Infinity]){s.setNumeric({width:value,height:2.75});call(s.ids[0]);}
   else for(const id of s.ids)call(id);
   for(const o of s.owners)o.rec.end(2);
   const sessions=s.owners.map(o=>{const frameRecords=o.frames.map(f=>a.decodeRecord(f.subarray(4))),bytes=a.encodeLog(frameRecords);const decoded=a.decodeLog(bytes),records=decoded.records;let raw='';for(const b of bytes)raw+=String.fromCharCode(b);return {records:JSON.parse(JSON.stringify(records,(_,v)=>typeof v==='bigint'?String(v):v)),log:btoa(raw),strict:{termination:decoded.termination,records:decoded.records.length},env:{width:o.env.viewport_w,height:o.env.viewport_h}};});
   return {out,failures,counts:s.counts,receivers:s.receivers,trace:s.trace,late:s.late,sessions,before,after:s.first.frames.length};
  },mode);
  receipt({mode,stage:'record',result});
  for(const session of result.sessions){assert.equal(session.strict.records,session.records.length);assert.equal(session.strict.termination,mode==='faulted'?'TruncatedUnterminated':'Complete','actual strict reader termination');}
  // Every mutant must reach these semantic assertions, never a startup failure.
  assert.deepEqual(result.late,{width:0,height:0},'layout semantic: captured getters bypass witnessed late raw traps');
  assert(result.receivers.every(Boolean),'layout semantic: original Window receiver');
  const reads=mode==='numeric'?5:mode==='ownership'?4:1;
  assert.deepEqual(result.counts,{width:reads+(mode==='width-throw'||mode==='height-throw'?1:0),height:reads+(mode==='height-throw'?1:0)},'layout semantic: exactly one width then height read');
  if(mode.endsWith('throw'))assert.deepEqual(result.failures,[{same:true}],'native throw exact identity');else assert.deepEqual(result.failures,[],'layout semantic: successful captured reads return');
  if(mode!=='numeric')assert.deepEqual(result.out.map(v=>({width:v.width,height:v.height})),Array.from({length:reads},()=>({width:811,height:509})),'layout semantic: exact native returned values');
  const layout=session=>session.records.filter(r=>r.record==='LayoutRead');
  if(mode==='stopped'){assert.deepEqual(result.trace,['width','height'],'stopped native order, no wire output');assert.equal(result.before,result.after,'stopped owner silent');assert.equal(layout(result.sessions[0]).length,0);console.log('layout stopped native values: PASS');await context.close();continue;}
  if(mode==='faulted'){assert.deepEqual(result.trace,['width','innerWidth','height'],'fault stops logging, preserves height native observation');assert.deepEqual(result.sessions[0].records.filter(r=>!['Header','Env'].includes(r.record)).map(r=>r.record),['Refusal']);assert.equal(result.sessions[0].records.at(-1).feature,'recorder-fault');console.log('layout sink fault native values: PASS');await context.close();continue;}
  if(mode==='numeric'){
   assert.equal(result.out[0].width,1.25);assert.equal(result.out[1].negativeZeroWidth,true);assert.equal(result.out[2].nanWidth,true);assert.equal(result.out[3].infiniteWidth,true);assert.equal(result.out[4].width,-Infinity);
   assert.deepEqual(layout(result.sessions[0]).filter(r=>r.prop==='innerWidth').map(r=>r.value),['1.25','0','null','null','null'],'raw numeric passthrough distinct from owner JSON projection');
   assert.deepEqual(layout(result.sessions[0]).filter(r=>r.prop==='innerHeight').map(r=>r.value),Array(5).fill('2.75'));console.log('layout numeric fault controls: PASS');await context.close();continue;
  }
  for(let si=0;si<result.sessions.length;si++){
   const session=result.sessions[si],records=layout(session),pairs=mode==='ownership'?(si===0?3:1):1,partial=mode==='height-throw'?1:0;
   assert.equal(records.length,pairs*2+partial,'layout semantic: one nonempty record for each successful getter');
   const expectedProps=[...(partial?['innerWidth']:[]),...Array.from({length:pairs},()=>['innerWidth','innerHeight']).flat()];
   assert.deepEqual(records.map(r=>r.prop),expectedProps,'layout semantic: width emission before height observation');
   assert(records.every(r=>r.target==='win'),'layout semantic: checked Window target');
   assert.deepEqual(records.map(r=>r.value),expectedProps.map(p=>p==='innerWidth'?'811':'509'),'layout semantic: exact JSON value');
   const prefix=mode==='width-throw'?['width']:mode==='height-throw'?['width','innerWidth','height']:[];assert.deepEqual(result.trace,[...prefix,...Array.from({length:reads},()=>['width','innerWidth','height','innerHeight']).flat()],'layout semantic: native/read/wire order');
   // Error/partial modes establish source order above; replay whole successful sessions.
   if(mode.endsWith('throw'))continue;
   const rp=await context.newPage();await rp.goto(url);await rp.addScriptTag({content:owner});
   const replayed=await rp.evaluate(({log,replay,boot,pairs})=>{
    layoutApi.installReplayRuntime(window,{log});globalThis.xrReadBootContext=boot;
    const counts={width:0,height:0},sentinel=Error('live Replay viewport');
    for(const [key,prop] of [['width','innerWidth'],['height','innerHeight']])Object.defineProperty(window,prop,{configurable:true,get(){counts[key]++;throw sentinel;}});
    for(const [key,prop] of [['width','innerWidth'],['height','innerHeight']]){let e;try{void window[prop];}catch(x){e=x;}if(e!==sentinel||counts[key]!==1)throw Error('Replay independent trap witness '+key);counts[key]=0;}
    (0,eval)(replay);const out=[];for(let i=0;i<pairs;i++)out.push(JSON.parse(rlReplay()));globalThis.layoutReplayCounts=counts;
    return {out,counts};
   },{log:session.log,replay,boot,pairs});
   assert.deepEqual(replayed.out,Array.from({length:pairs},()=>({x:0,y:0,width:811,height:509})),'actual public Replay viewport projection');assert.deepEqual(replayed.counts,{width:0,height:0});
   await rp.waitForFunction(()=>['done','diverged'].includes(__ctReplay.status().state));const done=await rp.evaluate(()=>({status:__ctReplay.status(),counts:layoutReplayCounts}));receipt({mode,stage:'replay',owner:si,replayed,done});assert.equal(done.status.state,'done');assert.equal(done.status.tasks,0);assert.deepEqual(done.counts,{width:0,height:0});assert.equal(session.records.filter(r=>r.record==='Checkpoint').length,1);assert.equal(session.records.at(-1).record,'End');
   await rp.close();console.log('layout '+mode+' owner '+si+': actual compiled Record -> strict reader -> public Replay DONE');
  }
  if(mode.endsWith('throw'))console.log('layout '+mode+': exact native throw identity and partial wire order PASS');
  await context.close();
 }
}finally{await browser?.close();await new Promise(r=>server.close(r));}
