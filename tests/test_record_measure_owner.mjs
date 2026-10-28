/** Real DSL/M6 -> captured Chromium geometry -> installed Recorder/strict codec
 * -> public/private Replay -> actual owner loop/DOM-v1 DONE. Forwarding wrappers
 * count native calls and actual DOMRect getters. Narrow native/getter/validator/
 * sink faults make deterministic error identity/order observable without unsafe
 * host faults; they are not alternative geometry, identity or cursor providers.
 */
import assert from 'node:assert/strict';
import {readFileSync,appendFileSync} from 'node:fs';
import {createRequire} from 'node:module';
import {createServer} from 'node:http';
const root=process.cwd(),artifact=process.env.CT_ARTIFACT;
assert(artifact,'CT_ARTIFACT required: actual installed owner integration cannot skip');
for(const k of ['RECORD_MEASURE_BUNDLE','RECORD_MEASURE_REPLAY','RECORD_MEASURE_CONTEXT','RECORD_MEASURE_COMPANION','RECORD_MEASURE_IMPORT'])assert(process.env[k],k+' required: explicit current compiled input');
const {build}=createRequire(artifact+'/packages/boundary-shim/package.json')('esbuild');
const {chromium}=await import(root+'/tests/browser/node_modules/playwright/index.mjs');
const imports=`
import {Recorder,numberToBits} from '@codetracer/boundary-shim/dist/browser/recorder.js';
import {captureOriginals} from '@codetracer/boundary-shim/dist/browser/originals.js';
import {readEnvironment,installBoundaryShim} from '@codetracer/boundary-shim/dist/browser/install.js';
import {domV1Hash} from '@codetracer/boundary-shim/dist/browser/dom-v1.js';
import {encodeLog,decodeLog,decodeRecord} from '@codetracer/boundary-format';
import {installReplayRuntime} from '@codetracer/boundary-replay/dist/browser/runtime.js';
globalThis.measureApi={Recorder,numberToBits,captureOriginals,readEnvironment,installBoundaryShim,domV1Hash,encodeLog,decodeLog,decodeRecord,installReplayRuntime};`;
async function bundle(text){return(await build({stdin:{resolveDir:artifact,contents:text},bundle:true,platform:'browser',format:'iife',write:false})).outputFiles[0].text;}
const suffix='\nObject.assign(globalThis,{rqInit,rqRead,rqClock,rqSwitchTest,rqSelected,rqMount,rqResolve});';
const compiled=await bundle(imports+readFileSync(process.env.RECORD_MEASURE_BUNDLE,'utf8')+suffix);
const companion=await bundle(imports+readFileSync(process.env.RECORD_MEASURE_COMPANION,'utf8')+suffix);
const early=await bundle(imports+readFileSync(process.env.RECORD_MEASURE_IMPORT,'utf8')+'\nglobalThis.rqEarly=rqEarly;');
const replay=await bundle(imports+readFileSync(process.env.RECORD_MEASURE_REPLAY,'utf8')+'\nObject.assign(globalThis,{rqMount,rqResolve,rqSelect,rqReplay,rqReplayPrivate,rqMono,rqNeMono});');
const capture=readFileSync(process.env.RECORD_MEASURE_CONTEXT,'utf8');
const fields=['x','y','width','height','top','right','bottom','left'];
const server=createServer((req,res)=>res.end('<!doctype html><main id="root"></main>'));
await new Promise(r=>server.listen(0,'127.0.0.1',r));const url='http://127.0.0.1:'+server.address().port;
function receipt(v){if(process.env.RECORD_MEASURE_RESULTS)appendFileSync(process.env.RECORD_MEASURE_RESULTS,JSON.stringify(v)+'\n');}
let browser;
try{
 browser=await chromium.launch({executablePath:process.env.PLAYWRIGHT_CHROMIUM_EXECUTABLE});
 const earlyPage=await browser.newPage();await earlyPage.goto(url);await earlyPage.addScriptTag({content:early});
 const earlyResult=await earlyPage.evaluate(()=>{const a=measureApi,orig=a.captureOriginals(window);let reads=0;orig.getBoundingClientRect=function(){reads++;throw Error('early geometry');};const rec=new a.Recorder({checkpointScheme:'dom-v1',checkpointHash:()=>a.domV1Hash(document),sink:{append(){},end(){},halt(){}}});const before=['__isonimIids','__isonimValidateIids','__isonimRememberIid'].map(k=>Object.hasOwn(globalThis,k));rqEarly(window,rec,orig);return {before,after:['__isonimIids','__isonimValidateIids','__isonimRememberIid'].map(k=>Object.hasOwn(globalThis,k)),reads};});
 assert.deepEqual(earlyResult,{before:[false,false,false],after:[false,false,false],reads:0});receipt({stage:'early-constructor',earlyResult});await earlyPage.close();
 const inverse=process.env.RECORD_MEASURE_INVERSE||'';
 const modes=['positive','ownership','detached','invalid','unknown','missing','empty','non-element','forged','stale','duplicate','validator','registry-missing','native-throw',...fields.map(k=>'field-'+k),'stopped','faulted','factory'];
 for(const [arm,code,mode] of [['companion',companion,'positive'],...(inverse?[['inverse',compiled,['identity','early'].includes(inverse)?'forged':'positive']]:modes.map(m=>['candidate',compiled,m]))]){
  const context=await browser.newContext({viewport:{width:733,height:457}});
  const prior=await context.newPage();await prior.goto(url);await prior.addScriptTag({content:capture});const boot=await prior.evaluate(()=>xrReadBootContext);await prior.close();
  const page=await context.newPage();await page.goto(url);await page.addScriptTag({content:code});
  const result=await page.evaluate(({mode,fields})=>{
   const a=measureApi,native=a.captureOriginals(window),nodes=[rqMount('primary')],node=nodes[0],iid=node.getAttribute('data-iid');
   if(mode==='factory'){
    const factory=a.installBoundaryShim(window,{buildHash:'a'.repeat(64)});rqResolve(iid);
    const refusals=a.decodeLog(factory.log()).records.filter(r=>r.record==='Refusal').map(r=>({feature:r.feature,detail:r.detail}));
    return {factory:refusals};
   }
   const nativeGetters=Object.fromEntries(fields.map(k=>[k,Object.getOwnPropertyDescriptor(DOMRectReadOnly.prototype,k).get]));
   const counts={calls:0,fields:[]},receivers=[],trace=[],late={calls:0},sentinel={exactMeasurementFailure:true};let fail='',last,nativeValue;
   Element.prototype.getBoundingClientRect=function(){
    counts.calls++;receivers.push(this===target);trace.push('native');if(fail==='native')throw sentinel;
    last=native.getBoundingClientRect.call(this);nativeValue=Object.fromEntries(fields.map(k=>[k,nativeGetters[k].call(last)]));
    for(const k of fields)Object.defineProperty(last,k,{configurable:true,get(){counts.fields.push(k);trace.push(k);if(fail===k)throw sentinel;return nativeGetters[k].call(this);}});
    return last;
   };
   const captured=a.captureOriginals(window),owners=[];
   function make(id){const frames=[];let sinkFail=false;const rec=new a.Recorder({checkpointScheme:'dom-v1',checkpointHash:()=>a.domV1Hash(document),sink:{append(f){const row=a.decodeRecord(f.subarray(4));if(row.record==='LayoutRead'){trace.push('wire');if(sinkFail){sinkFail=false;throw sentinel;}}frames.push(f);},end(unloading,frame){frames.push(frame);},halt(){}}});rec.start({vocab:1,protocol_level:0,recorder_id:'private-measure-'+id,framework:'',build_hash:'a'.repeat(64),session_id:String(id).repeat(32),prev_session:'',capabilities:'[]'},a.readEnvironment(window,native));const owner={rec,frames,setFault(){sinkFail=true;}};owners.push(owner);return owner;}
   const first=make(1);let target=node;
   if(mode==='detached')node.remove();
   if(mode==='stale'){node.remove();nodes.push(rqMount('primary'));}
   if(mode==='duplicate')nodes.push(rqMount('primary'));
   if(['forged','unknown','missing','empty'].includes(mode)){target=document.createElement('button');if(mode==='forged')target.setAttribute('data-iid',iid);if(mode==='unknown')target.setAttribute('data-iid','unknown');if(mode==='empty')target.setAttribute('data-iid','');}
   if(mode==='non-element')target={getAttribute(){throw sentinel;}};
   globalThis.recordMeasureOwner={window,rec:first.rec,orig:captured};const initial=first.frames.length;
   if(mode==='invalid'){
    const errors=[];for(const c of [{window:{},rec:first.rec,orig:captured},{window,rec:{},orig:captured},{window,rec:first.rec,orig:{}},{window,rec:first.rec,orig:{getBoundingClientRect:null}}]){recordMeasureOwner=c;try{rqInit();errors.push(null);}catch(e){errors.push({name:e.name,message:e.message});}}
    return {invalid:errors,counts,initial,after:first.frames.length};
   }
   const beforeConstructor={registry:globalThis.__isonimIids,validate:globalThis.__isonimValidateIids};
   const ids=[rqInit()];if(mode==='ownership'){ids.push(rqInit());const other=make(2);recordMeasureOwner={window,rec:other.rec,orig:captured};ids.push(rqInit());ids.push(ids[0]);rqSwitchTest();}
   const constructor={calls:counts.calls,fields:[...counts.fields],sameRegistry:beforeConstructor.registry===globalThis.__isonimIids,sameValidator:beforeConstructor.validate===globalThis.__isonimValidateIids};
   Element.prototype.getBoundingClientRect=function(){late.calls++;return native.getBoundingClientRect.call(this);};
   void node.getBoundingClientRect();if(late.calls!==1)throw Error('late native replacement witness');late.calls=0;
   const clocks=owners.map((o,i)=>[rqClock(ids[i===0?0:2]),rqClock(ids[i===0?0:2])]);
   const validate=globalThis.__isonimValidateIids;
   if(mode==='validator')globalThis.__isonimValidateIids=()=>{throw sentinel;};
   if(mode==='registry-missing')delete globalThis.__isonimValidateIids;
   if(mode==='native-throw')fail='native';if(mode.startsWith('field-'))fail=mode.slice(6);
   if(mode==='stopped')first.rec.end(2);if(mode==='faulted')first.setFault();
   const before=first.frames.length,rows=[];
   const styles=['position:absolute;left:-13.25px;top:27.5px;width:141.75px;height:39.25px;box-sizing:border-box;transform:translate(2.125px,3.375px) scale(1.125)','position:absolute;left:2500.5px;top:-2000.25px;width:0;height:0;padding:0;border:0;min-width:0;min-height:0','position:absolute;left:65.125px;top:33.375px;width:81.75px;height:17.25px'];
   for(const id of ids)for(const style of styles){
    if(target instanceof Element)target.style.cssText=style;
    const start={calls:counts.calls,fields:counts.fields.length,trace:trace.length,frames:owners[id===ids[2]&&mode==='ownership'?1:0].frames.length};
    let value,error;try{value=rqRead(id,target);}catch(e){error=e;}
    rows.push({calls:counts.calls-start.calls,fields:counts.fields.slice(start.fields),trace:trace.slice(start.trace),same:value===last,expected:nativeValue,error:error?{name:error.name,message:error.message,sentinel:error===sentinel}:null});
   }
   globalThis.__isonimValidateIids=validate;
   if(mode==='duplicate')nodes[1].remove();
   const lifecycle=mode==='stale'?rqResolve(iid)===nodes[1]:mode==='detached'?rqResolve(iid)===node:true;
   const framesBeforeEnd=first.frames.length;
   for(const o of owners)o.rec.end(2);
   const sessions=owners.map((o,i)=>{const records=o.frames.map(f=>a.decodeRecord(f.subarray(4))),bytes=a.encodeLog(records),decoded=a.decodeLog(bytes);let raw='';for(const b of bytes)raw+=String.fromCharCode(b);return {clocks:clocks[i],clockBits:clocks[i].map(v=>a.numberToBits(v).toString()),records:JSON.parse(JSON.stringify(decoded.records,(_,v)=>typeof v==='bigint'?String(v):v)),termination:decoded.termination,log:btoa(raw)};});
   return {iid,rows,constructor,late,receivers,counts,sessions,before,framesBeforeEnd,lifecycle,selected:mode==='ownership'?rqSelected():null};
  },{mode,fields});receipt({arm,mode,stage:'record',result});
  if(mode==='factory'){assert(result.factory.some(r=>r.feature==='weakref'&&r.detail==='WeakRef.deref'));console.log('measure factory weak lookup: Refusal PRESERVED; not accepted recording');await context.close();continue;}
  if(mode==='invalid'){assert(result.invalid.every(e=>e?.name==='TypeError'&&e.message==='internal Record measure requires actual Window, captured originals and actual Recorder'));assert.equal(result.counts.calls,0);assert.equal(result.initial,result.after);await context.close();continue;}
  assert.deepEqual(result.constructor,{calls:0,fields:[],sameRegistry:true,sameValidator:true});assert(result.lifecycle);if(mode==='ownership')assert.equal(result.selected,17.25);
  const invalid=['unknown','missing','empty','non-element','forged','stale','duplicate','validator','registry-missing'].includes(mode);
  if(invalid){
   if(arm==='inverse'&&inverse==='identity')assert(result.rows.every(r=>r.error),'measure semantic: require exact registered object');
   assert(result.rows.every(r=>r.calls===0),'measure semantic: validate identity before native read');
   assert(result.rows.every(r=>r.error),'measure semantic: require exact registered object');
   assert.equal(result.framesBeforeEnd,result.before);assert.deepEqual(result.counts.fields,[]);
   if(mode==='validator')assert(result.rows.every(r=>r.error.sentinel));
   if(mode==='duplicate')assert(result.rows.every(r=>r.error.message==='duplicate live stable iid: '+result.iid));
   if(mode==='registry-missing')assert(result.rows.every(r=>r.error.name==='TypeError'));
  }else if(mode==='native-throw'||mode.startsWith('field-')){
   assert(result.rows.every(r=>r.error?.sentinel));assert.equal(result.framesBeforeEnd,result.before);
   for(const r of result.rows){assert.equal(r.calls,1);assert.deepEqual(r.fields,mode==='native-throw'?[]:fields.slice(0,fields.indexOf(mode.slice(6))+1));assert(!r.trace.includes('wire'));}
   assert(result.sessions[0].records.every(r=>r.record!=='Refusal'),'native field error must not fault owner');
  }else{
   assert.equal(result.late.calls,0,'measure semantic: captured original bypasses late replacement');
   for(const r of result.rows){assert.equal(r.error,null);assert.equal(r.calls,1);assert.deepEqual(r.fields,fields,'measure semantic: exact snapshot field order');assert(r.same,'measure semantic: original native DOMRect identity');}
   assert(result.receivers.every(Boolean));
   if(mode==='stopped'||mode==='faulted'){
    assert(result.sessions.every(s=>s.records.every(r=>r.record!=='LayoutRead')));
    if(mode==='faulted')assert(result.sessions[0].records.some(r=>r.record==='Refusal'));
   }else{
    const wire=result.sessions.flatMap(s=>s.records.filter(r=>r.record==='LayoutRead'));
    assert.equal(wire.length,result.rows.length,'measure semantic: exactly one layout emission per read');
    // Owners share capture primitives but keep their own ordered record streams.
    for(const s of result.sessions){for(const r of s.records.filter(r=>r.record==='LayoutRead')){assert.equal(r.target,'iid:'+result.iid);assert.equal(r.prop,'getBoundingClientRect');assert.deepEqual(Object.keys(JSON.parse(r.value)),fields,'measure semantic: exact eight wire fields');}}
    const expectedByOwner=mode==='ownership'?[result.rows.slice(0,6).concat(result.rows.slice(9)),result.rows.slice(6,9)]:[result.rows];
    for(let i=0;i<result.sessions.length;i++){
     const session=result.sessions[i],expected=expectedByOwner[i].map(r=>r.expected),records=session.records.filter(r=>r.record==='LayoutRead');
     assert.deepEqual(records.map(r=>JSON.parse(r.value)),expected,'exact actual native geometry wire');
     if(mode==='detached')assert(expected.every(r=>fields.every(k=>r[k]===0)),'native detached geometry stays zero');
     else{assert(expected.some(r=>r.width===0));assert(expected.some(r=>r.x<0));assert(expected.some(r=>r.x>2000));assert(expected.some(r=>r.width%1!==0));}
     const replayPage=await context.newPage();await replayPage.goto(url);await replayPage.addScriptTag({content:replay});
     const replayed=await replayPage.evaluate(({session,boot,expected,fields,mode})=>{
      const a=measureApi,node=rqMount('primary');globalThis.xrReadBootContext=boot;
      // Checkpoint compares the exact final Record DOM, not live layout.
      node.style.cssText='position:absolute;left:65.125px;top:33.375px;width:81.75px;height:17.25px';
      if(mode==='detached')node.remove();
      a.installReplayRuntime(window,{log:session.log});rqSelect();
      const raw=[],sentinel={rawGeometry:true};Element.prototype.getBoundingClientRect=function(){raw.push('rect');throw sentinel;};window.getComputedStyle=function(){raw.push('style');throw sentinel;};performance.now=function(){raw.push('clock');throw sentinel;};
      for(const call of [()=>node.getBoundingClientRect(),()=>getComputedStyle(node),()=>performance.now()]){let error;try{call();}catch(e){error=e;}if(error!==sentinel)throw Error('private raw trap identity witness');}if(raw.join(',')!=='rect,style,clock')throw Error('private raw trap count witness');raw.length=0;
      const clocks=[rqMono(),rqNeMono()],out=[];
      for(let i=0;i<expected.length;i++){const privateRect=JSON.parse(rqReplayPrivate(node));out.push(privateRect);}
      // Separate actual-owner session below exercises public projection; do not consume twice.
      return {out,raw,clocks,clockBits:a.numberToBits(clocks[0]).toString()};
     },{session,boot,expected,fields,mode});await replayPage.waitForFunction(()=>['done','diverged'].includes(__ctReplay.status().state));replayed.state=await replayPage.evaluate(()=>__ctReplay.status().state);receipt({arm,mode,stage:'private-replay',owner:i,replayed});
     assert.deepEqual(replayed.out,expected);assert.deepEqual(replayed.raw,[]);assert.equal(replayed.state,'done');assert.equal(replayed.clockBits,session.clockBits[0]);assert.equal(replayed.clocks[1],BigInt(Math.trunc(session.clocks[1])).toString());await replayPage.close();
     const publicPage=await context.newPage();await publicPage.goto(url);await publicPage.addScriptTag({content:replay});
     const pub=await publicPage.evaluate(({session,boot,expected,mode})=>{const a=measureApi,node=rqMount('primary');node.style.cssText='position:absolute;left:65.125px;top:33.375px;width:81.75px;height:17.25px';if(mode==='detached')node.remove();globalThis.xrReadBootContext=boot;a.installReplayRuntime(window,{log:session.log});rqSelect();let raw=0;const sentinel={rawPublic:true};Element.prototype.getBoundingClientRect=()=>{raw++;throw sentinel;};window.getComputedStyle=()=>{raw++;throw sentinel;};performance.now=()=>{raw++;throw sentinel;};for(const call of [()=>node.getBoundingClientRect(),()=>getComputedStyle(node),()=>performance.now()]){let error;try{call();}catch(e){error=e;}if(error!==sentinel)throw Error('public raw trap identity witness');}if(raw!==3)throw Error('public raw trap count witness');raw=0;const mono=rqMono(),ne=rqNeMono(),out=expected.map(()=>JSON.parse(rqReplay(node)));return {out,raw,bits:a.numberToBits(mono).toString(),ne};},{session,boot,expected,mode});await publicPage.waitForFunction(()=>['done','diverged'].includes(__ctReplay.status().state));pub.state=await publicPage.evaluate(()=>__ctReplay.status().state);receipt({arm,mode,stage:'public-replay',owner:i,pub});
     assert.deepEqual(pub.out,expected.map(r=>Object.fromEntries(fields.slice(0,4).map(k=>[k,r[k]]))));assert.equal(pub.raw,0);assert.equal(pub.state,'done');assert.equal(pub.bits,session.clockBits[0]);assert.equal(pub.ne,BigInt(Math.trunc(session.clocks[1])).toString());await publicPage.close();
     console.log('measure '+arm+' positive owner '+i+': actual compiled Record -> strict reader -> public/private Replay DONE');
    }
   }
  }
  console.log('measure '+arm+' '+mode+': PASS');await context.close();
 }
}finally{await browser?.close();await new Promise(r=>server.close(r));}
