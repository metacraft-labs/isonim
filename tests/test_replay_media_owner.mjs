/** Mandatory real-browser/Recorder/strict-codec/cursor media integration.
 * Platform traps and parser failures are deliberate fault injection: they reveal
 * raw fallback and failure swallowing, never replace owner cursor or matching.
 */
import assert from 'node:assert/strict';
import {readFileSync} from 'node:fs';
import {createRequire} from 'node:module';
import {createServer} from 'node:http';
const root=process.cwd();
const {chromium}=await import(root+'/tests/browser/node_modules/playwright/index.mjs');
const artifact=process.env.CT_ARTIFACT;
assert(artifact,'actual owner artifact required');
const require=createRequire(artifact+'/packages/boundary-shim/package.json');
const {build}=require('esbuild');
const owned=(await build({stdin:{resolveDir:artifact,contents:`
import {Recorder,numberToBits} from '@codetracer/boundary-shim/dist/browser/recorder.js';
import {captureOriginals} from '@codetracer/boundary-shim/dist/browser/originals.js';
import {readEnvironment} from '@codetracer/boundary-shim/dist/browser/install.js';
import {mediaQueryProp} from '@codetracer/boundary-shim/dist/browser/seams-dom.js';
import {domV1Hash} from '@codetracer/boundary-shim/dist/browser/dom-v1.js';
import {encodeLog,decodeRecord} from '@codetracer/boundary-format';
import {installReplayRuntime} from '@codetracer/boundary-replay/dist/browser/runtime.js';
globalThis.xrMediaBegin=()=>{
 const orig=captureOriginals(window),frames=[],samples=[],rows=[];
 localStorage.removeItem('missing');localStorage.setItem('empty','');localStorage.setItem('value','recorded-string');
 document.cookie='xr=original;path=/';const cookie=document.cookie;
 const rec=new Recorder({checkpointScheme:'dom-v1',checkpointHash:()=>domV1Hash(document),sink:{append(f){frames.push(f)},end(){},halt(){}}});
 const boot=readEnvironment(window,orig);
 rec.start({vocab:1,protocol_level:0,recorder_id:'internal-media',framework:'',build_hash:'a'.repeat(64),session_id:'1'.repeat(32),prev_session:'',capabilities:'[]'},boot);
 for(let i=0;i<2;i++){let value=orig.performanceNow.call(performance);samples.push(value);rec.emit('Clock',{src:2,bits:numberToBits(value)});}
 for(const key of ['missing','empty','value']){const value=orig.storageGetItem.call(localStorage,key);rec.emit('StorageRead',{area:1,key,present:value===null?0:1,value:value??''});}
 rec.emit('StorageRead',{area:3,key:'',present:1,value:cookie});
 globalThis.xrMediaViewport=()=>{for(const prop of ['innerWidth','innerHeight'])rec.emit('LayoutRead',{target:'win',prop,value:JSON.stringify(window[prop])});};
 globalThis.xrMediaSample=(queries,mode)=>{for(const query of queries){const m=orig.matchMedia.call(window,query),prop=mediaQueryProp(m),matches=m.matches;
 rows.push({query,prop,matches});const first=rows.length===1;
 rec.emit('LayoutRead',{target:first&&mode==='target'?'doc':'win',prop:first&&mode==='prop'?'matchMedia:WRONG':prop,
 value:JSON.stringify(first&&mode==='malformed'?{missing:true}:first&&mode==='nonboolean'?{matches:1}:{matches})});}};
 globalThis.xrMediaPrepare=()=>{
 rec.end(2);const records=frames.map(f=>decodeRecord(f.subarray(4))),log=encodeLog(records);let raw='';for(const b of log)raw+=String.fromCharCode(b);installReplayRuntime(window,{log:btoa(raw)});
 const effects=[],rawMatching=[];globalThis.xrMediaEffects=effects;globalThis.xrMediaRaw=rawMatching;
 const refuse=n=>{effects.push(n);throw Error('RAW '+n)};
 // Raw matching returns an opposite value instead of throwing, so restoration
 // must prove BOTH effects and the unconsumed record, not a generic rejection.
 window.matchMedia=q=>{rawMatching.push('matchMedia:'+q);return {get matches(){rawMatching.push('matches');return !rows[0].matches;}}};
 Object.defineProperty(MediaQueryList.prototype,'matches',{configurable:true,get(){return refuse('native.matches')}});
 for(const prop of ['innerWidth','innerHeight','devicePixelRatio','scrollX','scrollY'])Object.defineProperty(window,prop,{configurable:true,get(){return refuse(prop)}});
 for(const prop of ['offsetWidth','offsetHeight','offsetTop','offsetLeft','clientWidth','clientHeight','scrollWidth','scrollHeight'])Object.defineProperty(HTMLElement.prototype,prop,{configurable:true,get(){return refuse(prop)}});
 for(const name of ['getBoundingClientRect','getClientRects'])Element.prototype[name]=()=>refuse(name);
 window.getComputedStyle=()=>refuse('getComputedStyle');
 for(const name of ['appendChild','insertBefore','replaceChild'])Node.prototype[name]=()=>refuse(name);
 for(const proto of [Document.prototype,ShadowRoot.prototype])Object.defineProperty(proto,'adoptedStyleSheets',{configurable:true,get(){return []},set(){refuse('sheet adoption')}});
 EventTarget.prototype.addEventListener=()=>refuse('listener');window.setTimeout=()=>refuse('timer');window.requestAnimationFrame=()=>refuse('frame');window.MutationObserver=class{constructor(){refuse('observer')}};
 const NativeDate=Date;window.Date=class extends NativeDate{constructor(...args){if(!args.length)refuse('Date');super(...args)}};
 performance.now=()=>refuse('performance');crypto.getRandomValues=()=>refuse('crypto');Storage.prototype.getItem=()=>refuse('storage');Object.defineProperty(document,'cookie',{get:()=>refuse('cookie'),configurable:true});
 globalThis.xrMediaGlobals=()=>Object.getOwnPropertyNames(globalThis).filter(k=>k.startsWith('__ct'));
 return {rows,samples,cookie,bootViewport:{width:boot.viewport_w,height:boot.viewport_h},records:records.filter(r=>r.record==='LayoutRead').map(r=>({seq:r.seq.toString(),target:r.target,prop:r.prop,value:r.value}))};
 };return {width:boot.viewport_w,height:boot.viewport_h};
};`},bundle:true,platform:'browser',format:'iife',write:false})).outputFiles[0].text;
const queries=['(prefers-color-scheme: dark)','  SCREEN and ( min-width : 500px ) ','(width >= 500px)','(500px <= width <= 1000px)','screen, print','screen ,\n( color )','not all','only SCREEN and (COLOR)','(unknown: foo)','(width >)','not (width > 10px)','(','screen and','foo','','   ',',','screen,,print','screen and (min-width: 1EM)','(resolution: 1dppx)','(width: calc(1px + 2px))','(width: var(--q))','all/*comment*/and (color)','screen; color:red','(any-hover: hover) or (any-pointer: fine)','not screen and (color)','\\73 creen','(color) and ((hover) or (pointer: fine))'];
const normalized='  SCREEN and ( min-width : 500px ) ';
const capture=readFileSync(root+'/build/replay-reads-context.js','utf8');
const bundle=readFileSync(process.env.REPLAY_MEDIA_BUNDLE||root+'/build/replay-media.js','utf8');
const inverse=process.env.REPLAY_MEDIA_MUTANT||'';
const modes=inverse?['positive']:['positive','target','prop','constructor-missing','constructor-throws','accessor-throws','media-text-throws','serialization-missing','malformed','nonboolean'];
const server=createServer((req,res)=>res.end('<!doctype html><main>Media</main>'));
await new Promise(r=>server.listen(0,'127.0.0.1',r));let browser;
try{browser=await chromium.launch({executablePath:process.env.PLAYWRIGHT_CHROMIUM_EXECUTABLE});
for(const mode of modes){
 const context=await browser.newContext({viewport:{width:733,height:457},colorScheme:'light'});
 const prior=await context.newPage();await prior.goto('http://127.0.0.1:'+server.address().port+'/');await prior.evaluate(()=>{globalThis._$HY={seed:731,buildId:'genuine-context',assignment:{read:'A'}}});await prior.addScriptTag({content:capture});const bootContext=await prior.evaluate(()=>xrReadBootContext);await prior.close();
 const page=await context.newPage();await page.goto('http://127.0.0.1:'+server.address().port+'/');await page.addScriptTag({content:owned});assert.deepEqual(await page.evaluate(()=>xrMediaBegin()),{width:733,height:457});
 await page.setViewportSize({width:811,height:509});await page.evaluate(()=>xrMediaViewport());
 await page.evaluate(({queries,mode})=>xrMediaSample(queries,mode),{queries,mode});
 await page.evaluate(()=>xrMediaSample(['(min-width: 800px)'],'positive'));
 await page.setViewportSize({width:733,height:457});await page.evaluate(()=>xrMediaSample([' ( min-width : 800px ) '],'positive'));
 await page.setViewportSize({width:901,height:902});await page.emulateMedia({colorScheme:'dark'});
 const result=await page.evaluate(({mode,bundle,bootContext,inverse,normalized})=>{
  globalThis.xrReadBootContext=bootContext;
  // Controls consume genuine Clock2/storage/viewport before raw traps. Install
  // runtime and traps after exporting originals, then only permit logged reads.
  const recorded=xrMediaPrepare();
  // Viewport positive control must exercise the logged path under traps.
  (0,eval)(bundle);const controls=JSON.parse(xrMediaControls()),before=__ctReplay.status().cursor;
  const globals=xrMediaGlobals(),html=document.documentElement.outerHTML,sheets=document.styleSheets.length;
  const NativeSheet=CSSStyleSheet,sentinel=new Error('parser sentinel');
  if(mode==='constructor-missing')globalThis.CSSStyleSheet=undefined;
  if(mode==='constructor-throws')globalThis.CSSStyleSheet=class{constructor(){throw sentinel}};
  if(mode==='accessor-throws')globalThis.CSSStyleSheet=class{get media(){throw sentinel}};
  if(mode==='media-text-throws')globalThis.CSSStyleSheet=class{get media(){return {get mediaText(){throw sentinel}}}};
  if(mode==='serialization-missing')globalThis.CSSStyleSheet=class{get media(){return {}}};
  const observed=[];let first,second,direct;
  const input=inverse==='serialization'?[recorded.rows[0].query,normalized]:recorded.rows.map(row=>row.query);
  try{for(const query of input)observed.push(xrMedia(query));}catch(error){first=error}
  const afterFirst=__ctReplay.status().cursor;
  if(first?.divergence){try{xrMedia(input[0])}catch(error){second=error}try{__ctReplay.next('LayoutRead',{target:'win',prop:recorded.rows[0].prop})}catch(error){direct=error}}
  globalThis.CSSStyleSheet=NativeSheet;
  const parserCase=mode.startsWith('constructor')||mode==='accessor-throws'||mode==='media-text-throws'||mode==='serialization-missing';
  let recovered;if(parserCase){recovered=xrMedia(recorded.rows[0].query)}
  return {recorded,controls,bootContext,before,afterFirst,after:__ctReplay.status().cursor,state:__ctReplay.status().state,next:__ctReplay.peek()?.kind,observed,recovered,
   effects:xrMediaEffects,raw:xrMediaRaw,globalsUnchanged:JSON.stringify(globals)===JSON.stringify(xrMediaGlobals()),htmlUnchanged:html===document.documentElement.outerHTML,sheetsUnchanged:sheets===document.styleSheets.length,
   error:first?{name:first.name,sentinel:first===sentinel,kind:first.divergence?.kind,seq:first.divergence?.seq,perCall:first!==second&&second!==direct,originalClass:first.constructor===direct?.constructor&&second?.constructor===direct?.constructor,payload:first.divergence===second?.divergence&&second?.divergence===direct?.divergence&&direct?.divergence===__ctReplay.failed}:null};
 },{mode,bundle,bootContext,inverse,normalized});
 assert.deepEqual(result.controls.env,result.bootContext);assert.deepEqual(result.bootContext.viewport,result.recorded.bootViewport);assert.deepEqual(result.bootContext.viewport,{width:733,height:457});
 assert.equal(result.controls.tick,BigInt(Math.trunc(result.recorded.samples[0]*1000000)).toString());assert.equal(result.controls.neMillis,BigInt(Math.trunc(result.recorded.samples[1])).toString());
 assert.equal(result.controls.missing,'');assert.equal(result.controls.empty,'');assert.equal(result.controls.value,'recorded-string');assert.equal(result.controls.cookie,result.recorded.cookie);assert.deepEqual(result.controls.viewport,{x:0,y:0,width:811,height:509});
 assert.deepEqual(result.effects,[]);assert.equal(result.globalsUnchanged,true);assert.equal(result.htmlUnchanged,true);assert.equal(result.sheetsUnchanged,true);
 assert.equal(result.recorded.rows.at(-2).matches,true);assert.equal(result.recorded.rows.at(-1).matches,false);assert.equal(result.recorded.rows.at(-2).prop,result.recorded.rows.at(-1).prop);
 const cursor=BigInt(result.before);
 if(inverse==='raw'){
  assert.equal(result.error,null);assert.equal(result.after,result.before);assert.equal(result.next,'LayoutRead');assert.equal(result.raw.length,result.recorded.rows.length*2);assert.equal(result.observed[0],!result.recorded.rows[0].matches);console.log('media restoration: REJECTED raw matching AND pending LayoutRead; Clock2/storage/viewport/context positives PASS');
 }else if(mode==='target'||mode==='prop'||inverse==='serialization'){
  const consumed=inverse==='serialization'?1:0;
  assert.equal(BigInt(result.afterFirst),cursor+BigInt(consumed));assert.equal(result.after,result.afterFirst);assert.equal(result.state,'diverged');assert.equal(result.error.kind,'ArgumentMismatch');assert.equal(result.error.seq,result.recorded.records[2+consumed].seq);assert.equal(result.error.originalClass,true);assert.equal(result.error.perCall,true);assert.equal(result.error.payload,true);assert.deepEqual(result.raw,[]);
  if(inverse){assert.deepEqual(result.observed,[result.recorded.rows[0].matches]);}if(inverse)console.log('authored-query serialization: REJECTED exact owner ArgumentMismatch; other controls PASS');
 }else if(mode.startsWith('constructor')||mode==='accessor-throws'||mode==='media-text-throws'||mode==='serialization-missing'){
  assert.ok(result.error);assert.equal(result.error.sentinel,mode==='constructor-throws'||mode==='accessor-throws'||mode==='media-text-throws');assert.equal(result.afterFirst,result.before);assert.equal(BigInt(result.after),cursor+1n);assert.equal(result.recovered,result.recorded.rows[0].matches);assert.deepEqual(result.raw,[]);
 }else if(mode==='malformed'||mode==='nonboolean'){
  assert.equal(result.error.name,'TypeError');assert.equal(BigInt(result.afterFirst),cursor+1n);assert.equal(result.next,'LayoutRead');assert.deepEqual(result.observed,[]);assert.deepEqual(result.raw,[]);
 }else{
  assert.equal(result.error,null);assert.deepEqual(result.observed,result.recorded.rows.map(row=>row.matches));assert.equal(BigInt(result.after),cursor+BigInt(result.recorded.rows.length));assert.equal(result.next,'Checkpoint');assert.deepEqual(result.raw,[]);
 }
 console.log('media '+mode+': PASS');await context.close();
}}finally{await browser?.close();await new Promise(r=>server.close(r));}
