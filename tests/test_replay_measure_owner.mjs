/** Genuine registered framework nodes and native geometry; actual Recorder/strict codec/cursor.
 * One compiled Nim runtime per realm. Raw traps and source inverses are fault
 * injection, not alternate registry, target codec, cursor or geometry providers.
 */
import assert from 'node:assert/strict';
import {readFileSync} from 'node:fs';
import {createRequire} from 'node:module';
import {createServer} from 'node:http';
const root=process.cwd(),artifact=process.env.CT_ARTIFACT;
assert(artifact,'CT_ARTIFACT required: real owner cannot skip');
const {chromium}=await import(root+'/tests/browser/node_modules/playwright/index.mjs');
const require=createRequire(artifact+'/packages/boundary-shim/package.json'),{build}=require('esbuild');
const owned=(await build({stdin:{resolveDir:artifact,contents:`
import {Recorder,numberToBits} from '@codetracer/boundary-shim/dist/browser/recorder.js';
import {captureOriginals} from '@codetracer/boundary-shim/dist/browser/originals.js';
import {readEnvironment,installBoundaryShim} from '@codetracer/boundary-shim/dist/browser/install.js';
import {mediaQueryProp} from '@codetracer/boundary-shim/dist/browser/seams-dom.js';
import {domV1Hash} from '@codetracer/boundary-shim/dist/browser/dom-v1.js';
import {encodeLog,decodeRecord,decodeLog} from '@codetracer/boundary-format';
import {installReplayRuntime} from '@codetracer/boundary-replay/dist/browser/runtime.js';
globalThis.xrMeasureFactory=()=>{const c=installBoundaryShim(window,{buildHash:'a'.repeat(64)});globalThis.xrMeasureFactoryRecords=()=>decodeLog(c.log()).records.filter(r=>r.record==='Refusal').map(r=>({feature:r.feature,detail:r.detail}));};
globalThis.xrMeasurePrepare=(node,mode)=>{
 const orig=captureOriginals(window),frames=[],samples=[],rects=[];
 localStorage.removeItem('missing');localStorage.setItem('empty','');localStorage.setItem('value','recorded-string');document.cookie='xr=original;path=/';const cookie=document.cookie;
 const rec=new Recorder({checkpointScheme:'dom-v1',checkpointHash:()=>domV1Hash(document),sink:{append(f){frames.push(f)},end(){},halt(){}}});
 const boot=readEnvironment(window,orig);
 rec.start({vocab:1,protocol_level:0,recorder_id:'internal-measure',framework:'',build_hash:'a'.repeat(64),session_id:'1'.repeat(32),prev_session:'',capabilities:'[]'},boot);
 for(let i=0;i<2;i++){const value=orig.performanceNow.call(performance);samples.push(value);rec.emit('Clock',{src:2,bits:numberToBits(value)});}
 for(const key of ['missing','empty','value']){const value=orig.storageGetItem.call(localStorage,key);rec.emit('StorageRead',{area:1,key,present:value===null?0:1,value:value??''});}
 rec.emit('StorageRead',{area:3,key:'',present:1,value:cookie});
 for(const prop of ['innerWidth','innerHeight'])rec.emit('LayoutRead',{target:'win',prop,value:JSON.stringify(window[prop])});
 const m=orig.matchMedia.call(window,'screen'),media=m.matches;rec.emit('LayoutRead',{target:'win',prop:mediaQueryProp(m),value:JSON.stringify({matches:media})});
 const iid=node.getAttribute('data-iid');
 for(let i=0;i<2;i++){node.style.cssText='position:absolute;left:13.25px;top:27.5px;width:141.75px;height:39.25px;box-sizing:border-box;transform:translate(2.125px,3.375px) scale(1.125)';
 const r=orig.getBoundingClientRect.call(node),rect={};for(const k of ['x','y','width','height','top','right','bottom','left'])rect[k]=r[k];rects.push(rect);
 rec.emit('LayoutRead',{target:mode==='target'&&i===0?'iid:WRONG':'iid:'+iid,prop:mode==='prop'&&i===0?'offsetWidth':'getBoundingClientRect',value:JSON.stringify(rect)});}
 rec.end(2);const records=frames.map(f=>decodeRecord(f.subarray(4))),log=encodeLog(records);let raw='';for(const b of log)raw+=String.fromCharCode(b);installReplayRuntime(window,{log:btoa(raw)});
 // Perturb real geometry AFTER native observations, then trap all geometry reads.
 node.style.cssText='position:absolute;left:500px;top:400px;width:800px;height:900px';
 const effects=[],rawReads=[];globalThis.xrMeasureEffects=effects;globalThis.xrMeasureRaw=rawReads;
 const refuse=n=>{effects.push(n);throw Error('RAW '+n)};
 Element.prototype.getBoundingClientRect=function(){rawReads.push(this===node?'original':'other');return {x:901,y:902,width:903,height:904,top:902,right:1804,bottom:1806,left:901}};
 Element.prototype.getClientRects=()=>refuse('getClientRects');window.getComputedStyle=()=>refuse('getComputedStyle');
 for(const prop of ['innerWidth','innerHeight','devicePixelRatio','scrollX','scrollY'])Object.defineProperty(window,prop,{configurable:true,get(){return refuse(prop)}});
 for(const prop of ['offsetWidth','offsetHeight','offsetTop','offsetLeft','clientWidth','clientHeight','scrollWidth','scrollHeight'])Object.defineProperty(HTMLElement.prototype,prop,{configurable:true,get(){return refuse(prop)}});
 window.matchMedia=()=>refuse('matchMedia');Object.defineProperty(MediaQueryList.prototype,'matches',{configurable:true,get(){return refuse('matches')}});
 EventTarget.prototype.addEventListener=()=>refuse('listener');window.setTimeout=()=>refuse('timer');window.requestAnimationFrame=()=>refuse('frame');window.MutationObserver=class{constructor(){refuse('observer')}};
 const NativeDate=Date;window.Date=class extends NativeDate{constructor(...a){if(!a.length)refuse('Date');super(...a)}};performance.now=()=>refuse('performance');crypto.getRandomValues=()=>refuse('crypto');Storage.prototype.getItem=()=>refuse('storage');Object.defineProperty(document,'cookie',{configurable:true,get:()=>refuse('cookie')});
 return {iid,samples,cookie,media,rects,bootViewport:{width:boot.viewport_w,height:boot.viewport_h},records:records.filter(r=>r.record==='LayoutRead'&&r.target.startsWith('iid:')).map(r=>({seq:r.seq.toString(),target:r.target,prop:r.prop,value:r.value}))};
};`},bundle:true,platform:'browser',format:'iife',write:false})).outputFiles[0].text;
const capture=readFileSync(root+'/build/replay-reads-context.js','utf8'),bundle=readFileSync(process.env.REPLAY_MEASURE_BUNDLE||root+'/build/replay-measure.js','utf8'),inverse=process.env.REPLAY_MEASURE_MUTANT||'';
const server=createServer((req,res)=>res.end('<!doctype html><main id="root"></main>'));await new Promise(r=>server.listen(0,'127.0.0.1',r));let browser;
try{browser=await chromium.launch({executablePath:process.env.PLAYWRIGHT_CHROMIUM_EXECUTABLE});
 const modes=inverse==='raw'?['positive']:inverse==='identity'?['positive','forged','stale']:['positive','detached','forged','unknown','missing','empty','non-element','duplicate','stale','validator','registry-missing','target','prop','factory'];
 for(const mode of modes){const context=await browser.newContext({viewport:{width:733,height:457}}),prior=await context.newPage();await prior.goto('http://127.0.0.1:'+server.address().port+'/');await prior.evaluate(()=>{globalThis._$HY={seed:731,buildId:'genuine-context',assignment:{read:'A'}}});await prior.addScriptTag({content:capture});const bootContext=await prior.evaluate(()=>xrReadBootContext);await prior.close();
 const page=await context.newPage();await page.goto('http://127.0.0.1:'+server.address().port+'/');await page.addScriptTag({content:owned});await page.addScriptTag({content:bundle});
 const result=await page.evaluate(({mode,bootContext,inverse})=>{
  globalThis.xrReadBootContext=bootContext;const node=xrMeasureMount('primary'),iid=node.getAttribute('data-iid');
  if(mode==='factory'){xrMeasureFactory();xrMeasureResolve(iid);return {refusals:xrMeasureFactoryRecords()};}
  let target=node,duplicate,successor;
  if(mode==='detached')node.remove();
  if(mode==='duplicate')duplicate=xrMeasureMount('primary');
  if(mode==='stale'){node.remove();successor=xrMeasureMount('primary');}
  if(['forged','unknown','missing','empty'].includes(mode)){target=document.createElement('button');if(mode==='forged')target.setAttribute('data-iid',iid);if(mode==='unknown')target.setAttribute('data-iid','unknown');if(mode==='empty')target.setAttribute('data-iid','');}
  if(mode==='non-element')target={getAttribute(){throw Error('must not call')}};
  const recorded=xrMeasurePrepare(node,mode);xrMeasureSelect();const controls=JSON.parse(xrMeasureControls()),before=__ctReplay.status().cursor;
  const originalValidate=__isonimValidateIids,sentinel=new Error('original validation sentinel');
  if(mode==='validator')globalThis.__isonimValidateIids=()=>{throw sentinel};
  if(mode==='registry-missing')delete globalThis.__isonimValidateIids;
  let first,second,direct,observed,privateRect;
  try{observed=JSON.parse(xrMeasure(target));if(mode==='positive'||mode==='detached')privateRect=JSON.parse(xrMeasurePrivate(node));}catch(e){first=e}
  const afterFirst=__ctReplay.status().cursor;
  if(first?.divergence){try{xrMeasure(target)}catch(e){second=e}try{__ctReplay.next('LayoutRead',{target:'iid:'+iid,prop:'getBoundingClientRect'})}catch(e){direct=e}}
  globalThis.__isonimValidateIids=originalValidate;
  if(duplicate)duplicate.remove();
  const lifecycle=mode==='stale'?xrMeasureResolve(iid)===successor:mode==='detached'?xrMeasureResolve(iid)===node:true;
  return {recorded,controls,bootContext,before,afterFirst,after:__ctReplay.status().cursor,state:__ctReplay.status().state,next:__ctReplay.peek()?.kind,observed,privateRect,lifecycle,raw:xrMeasureRaw,effects:xrMeasureEffects,error:first?{message:first.message,sentinel:first===sentinel,name:first.name,kind:first.divergence?.kind,seq:first.divergence?.seq,perCall:first!==second&&second!==direct,originalClass:first.constructor===direct?.constructor&&second?.constructor===direct?.constructor,payload:first.divergence===second?.divergence&&second?.divergence===direct?.divergence&&direct?.divergence===__ctReplay.failed}:null};
 },{mode,bootContext,inverse});
 if(mode==='factory'){assert(result.refusals.some(r=>r.feature==='weakref'&&r.detail==='WeakRef.deref'));console.log('actual factory weak lookup: Refusal PRESERVED; not accepted recording');await context.close();continue;}
 assert.deepEqual(result.controls.env,result.bootContext);assert.deepEqual(result.recorded.bootViewport,result.bootContext.viewport);assert.deepEqual(result.controls.viewport,{x:0,y:0,width:733,height:457});assert.equal(result.controls.media,result.recorded.media);
 assert.equal(result.controls.tick,BigInt(Math.trunc(result.recorded.samples[0]*1000000)).toString());assert.equal(result.controls.neMillis,BigInt(Math.trunc(result.recorded.samples[1])).toString());assert.equal(result.controls.missing,'');assert.equal(result.controls.empty,'');assert.equal(result.controls.value,'recorded-string');assert.equal(result.controls.cookie,result.recorded.cookie);assert.deepEqual(result.effects,[]);assert.equal(result.lifecycle,true);
 const cursor=BigInt(result.before);
 if(inverse==='raw'){assert.equal(result.error,null);assert.deepEqual(result.observed,{x:901,y:902,width:903,height:904});assert.deepEqual(result.privateRect,result.recorded.rects[0]);assert.deepEqual(result.raw,['original']);assert.equal(BigInt(result.after),cursor+1n);assert.equal(result.next,'LayoutRead');console.log('raw measure restoration REJECTED: raw effect AND original record pending; Clock2/storage/cookie/viewport/media/context PASS');}
 else if(inverse==='identity'&&(mode==='forged'||mode==='stale')){assert.equal(result.error,null);assert.equal(BigInt(result.after),cursor+1n);assert.equal(result.next,'LayoutRead');assert.deepEqual(result.raw,[]);console.log('identity bypass REJECTED: forged/stale element consumed registered target record; genuine target/controls PASS');}
 else if(mode==='positive'||mode==='detached'){assert.equal(result.error,null);assert.deepEqual(result.observed,Object.fromEntries(['x','y','width','height'].map(k=>[k,result.recorded.rects[0][k]])));assert.deepEqual(result.privateRect,result.recorded.rects[1]);assert.equal(Object.keys(result.privateRect).length,8);if(mode==='positive'){assert(result.privateRect.x%1!==0);assert(result.privateRect.width%1!==0);assert.equal(result.privateRect.top,result.privateRect.y);assert.equal(result.privateRect.right,result.privateRect.x+result.privateRect.width);}assert.equal(BigInt(result.after),cursor+2n);assert.equal(result.next,'Checkpoint');assert.deepEqual(result.raw,[]);}
 else if(mode==='target'||mode==='prop'){assert.equal(result.after,result.before);assert.equal(result.state,'diverged');assert.equal(result.error.kind,'ArgumentMismatch');assert.equal(result.error.seq,result.recorded.records[0].seq);assert.equal(result.error.perCall,true);assert.equal(result.error.originalClass,true);assert.equal(result.error.payload,true);assert.deepEqual(result.raw,[]);}
 else{assert(result.error,'identity/validation must reject');assert.equal(result.after,result.before);assert.equal(result.next,'LayoutRead');assert.deepEqual(result.raw,[]);if(mode==='validator')assert.equal(result.error.sentinel,true);else if(mode==='duplicate')assert.equal(result.error.message,'duplicate live stable iid: '+result.recorded.iid);else if(mode==='registry-missing')assert.equal(result.error.name,'TypeError');else assert.match(result.error.message,/does not support measure/);}
 console.log('measure '+mode+': PASS');await context.close();
 }
}finally{await browser?.close();await new Promise(r=>server.close(r));}
