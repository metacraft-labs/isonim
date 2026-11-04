/** Actual compiled Nim -> installed Recorder/document progression/strict codec.
 * The local HTTP fixture supplies genuine parser scripts and image responses,
 * and the plan's allowed ingest stub. No parser/loading/resource algorithm,
 * recorder, clock, codec, checkpoint or transport is mocked. A supplied-listener
 * delegate may throw a deliberate sentinel AFTER its native call in one fault
 * case; this is fault injection, not a claim that valid native registration fails. Counted delegates
 * witness original listener installation; a one-shot sink exception or reentrant
 * halt selects the actual owner's fault boundary without replacing progression.
 */
import assert from 'node:assert/strict';
import {createHash} from 'node:crypto';
import {resolve} from 'node:path';
import {readFileSync,writeFileSync} from 'node:fs';
import {createRequire} from 'node:module';
import {createServer} from 'node:http';
const artifact=process.env.CT_ARTIFACT,root=process.cwd();
assert(artifact && process.env.DOCUMENT_PROGRESS_BUNDLE && process.env.DOCUMENT_PROGRESS_RECEIPT,'actual owner, compiled Nim and receipt required');
const req=createRequire(artifact+'/packages/boundary-shim/package.json'),{build}=req('esbuild'),fmt=req('@codetracer/boundary-format');
const {chromium}=await import(root+'/tests/browser/node_modules/playwright/index.mjs');
const built=await build({stdin:{resolveDir:artifact,contents:`
import {Recorder,CHECKPOINT_RECORDS} from '@codetracer/boundary-shim/dist/browser/recorder.js';
import {captureOriginals} from '@codetracer/boundary-shim/dist/browser/originals.js';
import {readEnvironment} from '@codetracer/boundary-shim/dist/browser/install.js';
import {domV1Hash} from '@codetracer/boundary-shim/dist/browser/dom-v1.js';
import {DocumentProgress} from '@codetracer/boundary-shim/dist/browser/document-progress.js';
import {targetOf} from '@codetracer/boundary-shim/dist/browser/targets.js';
import {RESOURCE_EVENT_TYPES} from '@codetracer/boundary-shim/dist/browser/resource-events.js';
import {HttpBatchTransport} from '@codetracer/runtime-browser/dist/batch-transport.js';
import {decodeRecord} from '@codetracer/boundary-format';
${readFileSync(process.env.DOCUMENT_PROGRESS_BUNDLE,'utf8')}
globalThis.dpApi={Recorder,CHECKPOINT_RECORDS,captureOriginals,readEnvironment,domV1Hash,HttpBatchTransport,DocumentProgress,targetOf,RESOURCE_EVENT_TYPES,decodeRecord};
Object.assign(globalThis,{dpAttach,dpClock,dpUpload,dpPair,dpCompletion,dpConsent,dpSelect,dpClockState,dpAdvanceFake});
`},bundle:true,platform:'browser',format:'iife',write:false,metafile:true});
writeFileSync(process.env.DOCUMENT_PROGRESS_RECEIPT+'-metafile.json',JSON.stringify(built.metafile,null,2));
const bound=JSON.parse(readFileSync(process.env.DOCUMENT_PROGRESS_INPUTS,'utf8'));
const actualBindings=new Map(Object.entries(bound).map(([path,hash])=>[resolve(path),hash]));
for(const path of Object.keys(built.metafile.inputs)){
 if(path==='<stdin>')continue;
 const actual=resolve(root,path);assert.equal(createHash('sha256').update(readFileSync(actual)).digest('hex'),actualBindings.get(actual),'actual bundler input must be prebound: '+actual);
}
writeFileSync(process.env.DOCUMENT_PROGRESS_RECEIPT+'-combined.js',built.outputFiles[0].text);
const boot=built.outputFiles[0].text+`;(${function(){
const a=dpApi,o=a.captureOriginals(window),mode=new URL(location).searchParams.get('mode');
const frames=[],events=[],snapshots=[],positions=[],listenerCalls=[],hashes=[],header={vocab:1,protocol_level:0,recorder_id:'private-document-progress',framework:'',build_hash:'a'.repeat(64),session_id:'1'.repeat(32),prev_session:'',capabilities:'[]'};
const decode=()=>frames.map(f=>a.decodeRecord(f.subarray(4)));
if(mode.startsWith('selection-'))dpSelect(mode.slice(10));const clockBefore=mode.startsWith('selection-')?JSON.parse(dpClockState()):null;
// position() is always called exactly once through its original receiver.
// fullPosition() only reads the live collections/getters and a newly created
// TreeWalker (no census drain, settlement mark, recorder call or mutation).
// Freeze both results before returning, so later owner marks cannot alter the
// correspondence oracle. The read-only reference does not select event order.
const position=a.DocumentProgress.prototype.position;
a.DocumentProgress.prototype.position=function(...args){const actual=position.apply(this,args),reference=this.fullPosition();positions.push({actual:actual===undefined?null:Object.freeze({...actual}),reference:reference===undefined?null:Object.freeze({...reference})});return actual;};
let rec,armed=mode==='reentrant-halt'||mode==='reentrant-fault',ownerPromise;
const nativeEnd=a.HttpBatchTransport.prototype.end;
a.HttpBatchTransport.prototype.end=function(...args){ownerPromise=nativeEnd.apply(this,args);return ownerPromise;};
const sink=mode==='upload'?dpUpload(window,o,{ingest:location.origin+'/ingest',sessionId:header.session_id,buildHash:header.build_hash,consentRequired:true}):{
 append(f){const row=a.decodeRecord(f.subarray(4));if(armed&&row.record==='Loading'){armed=false;if(mode==='reentrant-halt'){frames.push(f);rec.halt();return;}throw Error('one-shot progression sink fault');}frames.push(f);},
 end(u,f){frames.push(f);},halt(){events.push('sink-halt');}};
rec=new a.Recorder({checkpointScheme:'dom-v1',checkpointHash:()=>{const value=a.domV1Hash(document);hashes.push(value);return value;},sink});
if(mode==='upload')dpPair(rec);
rec.start(header,a.readEnvironment(window,o));
if(mode==='initial-ended')rec.end(2);
if(mode==='initial-halted')rec.halt();
const beforeFrames=frames.length,beforeAdd=EventTarget.prototype.addEventListener,beforeOnload=Object.getOwnPropertyDescriptor(HTMLElement.prototype,'onload');
if(typeof beforeOnload?.set!=='function')throw Error('actual HTMLElement onload setter required');
let installs=0;const originals={...o,addEventListener:function(...args){installs++;const [type,listener,options]=args;listenerCalls.push({receiver:this===window?'window':this===document?'document':this instanceof Element?'element':'other',type,listener:typeof listener,capture:options?.capture,argc:args.length});const returned=o.addEventListener.apply(this,args);if(mode==='attach-fault'&&installs===1)throw Error('deliberate supplied listener fault after native registration');return returned;}};
if(mode==='invalid'){
 const errors=[];for(const args of [[{},rec,originals],[window,{},originals],[window,rec,{addEventListener:null}]]){try{dpAttach(...args);errors.push(null);}catch(e){errors.push({name:e.name,message:e.message});}}
 globalThis.dpState={errors,installs,frames,beforeFrames};return;
}
dpAttach(window,rec,originals);
const installed={installs,addSame:beforeAdd===EventTarget.prototype.addEventListener,onloadSame:beforeOnload?.set===Object.getOwnPropertyDescriptor(HTMLElement.prototype,'onload')?.set};
const snapshot=label=>{const records=decode();snapshots.push({label,records:records.length,last:records.at(-1)?.record,phase:records.filter(r=>r.record==='Loading').at(-1)?.phase,doc:records.filter(r=>r.record==='DocTask').map(r=>({kind:r.kind,src:r.src,event:r.event,target:r.target}))});};
const clock=()=>dpClock(window,rec,o);
o.addEventListener.call(document,'DOMContentLoaded',()=>{events.push('page-dcl');snapshot('dcl');});
o.addEventListener.call(window,'load',()=>{events.push('page-load');snapshot('load');});
globalThis.dpState={a,o,rec,mode,frames,events,snapshots,installed,beforeFrames,positions,listenerCalls,hashes,clockBefore,decode,snapshot,clock,ownerPromise:()=>ownerPromise};
}.toString()})();`;
const receipts=new Map(),batches=[],requests=[];let held,release;
const persist=()=>writeFileSync(process.env.DOCUMENT_PROGRESS_RECEIPT,JSON.stringify({requests,cases:Object.fromEntries(receipts)},(_,v)=>typeof v==='bigint'?String(v):v,2));
const server=createServer(async(q,s)=>{
 requests.push(q.url);const u=new URL(q.url,'http://localhost');
 if(u.pathname==='/boot.js'){s.setHeader('Content-Type','text/javascript');s.end(boot);return;}
 if(u.pathname==='/seam.js'){s.setHeader('Content-Type','text/javascript');s.end(`dpState.events.push('seam');dpState.clock();dpState.snapshot('seam');`);return;}
 if(u.pathname==='/no-seam.js'){s.setHeader('Content-Type','text/javascript');s.end(`dpState.events.push('no-seam');`);return;}
 if(u.pathname==='/defer.js'){s.setHeader('Content-Type','text/javascript');s.end(`dpState.events.push('defer');dpState.clock();dpState.snapshot('defer');`);return;}
 if(u.pathname==='/parsing.js'){s.setHeader('Content-Type','text/javascript');s.end(`const d=dpState;if(d.mode==='parsing-end'||d.mode==='explicit'){for(let i=0;i<d.a.CHECKPOINT_RECORDS+1;i++)d.clock();d.snapshot('cadence-before');d.dueBefore=d.rec.checkpointDue();d.rec.macrotask();d.snapshot('cadence-after');if(d.mode==='explicit')d.rec.checkpoint();d.rec.end(2);d.snapshot('ended-parsing');}`);return;}
 if(u.pathname==='/image.png'){s.setHeader('Content-Type','image/png');s.end(Buffer.from('iVBORw0KGgoAAAANSUhEUgAAAAEAAAABCAQAAAC1HAwCAAAAC0lEQVR42mP8/x8AAwMCAO+a9l8AAAAASUVORK5CYII=','base64'));return;}
 if(u.pathname==='/bad-image'){s.statusCode=404;s.end('not an image');return;}
 if(u.pathname==='/ingest/config'){s.setHeader('Content-Type','application/json');s.end(JSON.stringify({enabled:true,sampling_rate:1,consent_required:true,scrub_headers:[],scrub_query_keys:[]}));return;}
 if(u.pathname==='/ingest/batches'){
 const chunks=[];for await(const c of q)chunks.push(c);const bytes=Buffer.concat(chunks),parsed=fmt.parseBatch(bytes);batches.push({bytes:bytes.toString('base64'),envelope:parsed.envelope,records:parsed.records});
 if(parsed.envelope.final){held=true;await new Promise(r=>{release=r;});held=false;}
 s.setHeader('Content-Type','application/json');s.end('{}');return;
 }
 if(u.searchParams.get('mode')==='invalid'){s.setHeader('Content-Type','text/html');s.end('<!doctype html><html><head><script data-codetracer-boundary-shim src="/boot.js"></script></head><body>Invalid-argument fixture only</body></html>');return;}
 s.setHeader('Content-Type','text/html');s.end(`<!doctype html><html><head><script data-codetracer-boundary-shim src="/boot.js"></script><script src="/seam.js#fragment"></script><script src="/no-seam.js"></script><script defer src="/defer.js"></script></head><body><main>Document progression</main><script src="/parsing.js"></script></body></html>`);
});
await new Promise(r=>server.listen(0,'127.0.0.1',r));const origin='http://127.0.0.1:'+server.address().port;
const check=(value,name)=>assert(value,'DP_ASSERT: '+name);
let browser;
try{
 browser=await chromium.launch({executablePath:process.env.PLAYWRIGHT_CHROMIUM_EXECUTABLE});
 const modes=process.env.DOCUMENT_PROGRESS_CASE?[process.env.DOCUMENT_PROGRESS_CASE]:['parser','parsing-end','explicit','initial-ended','initial-halted','terminal-end','terminal-halt','reentrant-halt','reentrant-fault','attach-fault','invalid','upload','selection-real','selection-test','selection-custom','selection-fake'];
 for(const mode of modes){
 const page=await browser.newPage();const errors=[];page.on('pageerror',e=>errors.push(String(e)));await page.goto(origin+'/?mode='+mode);
 check(errors.length===0,'actual-page-execution: '+errors.join('|'));
 if(mode==='invalid'){
  const r=await page.evaluate(()=>({errors:dpState.errors,installs:dpState.installs,frames:dpState.frames.length,before:dpState.beforeFrames}));receipts.set(mode,r);persist();
  const message='internal Record document progress requires actual Window, Recorder and captured addEventListener';
  assert.deepEqual(r.errors,Array.from({length:3},()=>({name:'TypeError',message})),'DP_ASSERT: exact-precondition-errors');
  check(r.installs===0&&r.frames===r.before,'precondition-before-owner');await page.close();continue;
 }
 if(mode==='upload'){
 const observation=await page.evaluate(async()=>{const d=dpState;d.rec.end(2);const completion=dpCompletion();let settled=false;completion.then(()=>{settled=true;});globalThis.dpUploadSettled=()=>settled;const same=completion===dpCompletion()&&completion===d.ownerPromise();await dpConsent(()=>true);return {same,hashes:d.hashes.slice(),events:d.events.slice()};});
 // Observed final request causally precedes checking unresolved completion.
 await new Promise((resolve,reject)=>{const start=Date.now();const probe=()=>{if(held)return resolve();if(Date.now()-start>10000)return reject(Error('final HTTP request did not arrive'));setTimeout(probe,5);};probe();});
 check(observation.same,'exact-upload-completion-promise');check(await page.evaluate(()=>!dpUploadSettled()),'completion-waits-for-final-ack');release();await page.waitForFunction(()=>dpUploadSettled());
 receipts.set(mode,{observation,batches});persist();const records=batches.flatMap(b=>b.records),seq=records.filter(r=>'seq'in r).map(r=>r.seq);check(records[0]?.record==='Header'&&records[1]?.record==='Env','upload-header-env');check(records.filter(r=>r.record==='End').length===1&&records.at(-1).record==='End','upload-one-final-end');check(seq.every((s,i)=>s===BigInt(i+1))&&records.at(-1).last_seq===(seq.at(-1)??0n),'upload-seq-and-last-seq');assert.deepEqual(records.filter(r=>r.record==='Checkpoint').map(x=>({hash:x.state_hash,scheme:x.scheme,ordinal:x.ordinal,dom:x.dom_digest})),observation.hashes.map((hash,ordinal)=>({hash,scheme:'dom-v1',ordinal,dom:''})),'DP_ASSERT: exact-upload-checkpoint-provider-fields');assert.deepEqual(observation.events.filter(x=>['seam','no-seam','defer','page-dcl','page-load'].includes(x)),['seam','no-seam','defer','page-dcl','page-load'],'DP_ASSERT: upload-authored-callback-order');check(records.some(r=>r.record==='Loading')&&records.some(r=>r.record==='DocTask')&&records.some(r=>r.record==='Clock')&&records.some(r=>r.record==='Checkpoint'),'upload-real-progress-checkpoint');receipts.set(mode,{observation,batches});await page.close();continue;
 }
 const r=await page.evaluate(async()=>{
 const d=dpState,resource=[];
 if(d.mode==='parser'){
 for(const connected of [true,false])for(const success of [true,false]){
 const image=new Image(),src=location.origin+(success?'/image.png':'/bad-image')+'?connected='+connected+'&success='+success;
 if(connected)document.body.append(image);
 const type=success?'load':'error';let syntheticCalls=0;
 await new Promise(resolve=>{const handler=ev=>{if(!ev.isTrusted){syntheticCalls++;return;}const rows=d.decode().filter(r=>r.record==='DocTask'&&r.kind===5&&r.src===src&&r.event===type);resource.push({connected,success,src,type,registration:connected===success?'property':'listener',trusted:ev.isTrusted,countBeforePage:rows.length,target:rows[0]?.target,expectedTarget:d.a.targetOf(image)});resolve();};if(connected===success)image['on'+type]=handler;else image.addEventListener(type,handler);image.src=src;});
 const before=d.frames.length;image.dispatchEvent(new Event(type));resource.at(-1).syntheticCalls=syntheticCalls;resource.at(-1).syntheticSilent=d.frames.length===before;
 }
 for(let i=0;i<d.a.CHECKPOINT_RECORDS+1;i++)d.clock();const due=d.rec.checkpointDue();const before=d.decode().filter(r=>r.record==='Checkpoint').length;d.rec.macrotask();d.loadedCadence={due,before,after:d.decode().filter(r=>r.record==='Checkpoint').length};d.clock();d.rec.end(2);
 }
 if(d.mode.startsWith('selection-')){d.clockAfter=JSON.parse(dpClockState());if(d.mode==='selection-fake'){dpAdvanceFake();d.clockAdvanced=JSON.parse(dpClockState());}d.rec.end(2);}
 if(d.mode==='terminal-end'||d.mode==='terminal-halt'){
 if(d.mode==='terminal-end')d.rec.end(2);else d.rec.halt();const before=d.frames.length;let calls=0;const image=new Image();await new Promise(resolve=>{image.onload=()=>{calls++;resolve();};image.src=location.origin+'/image.png?terminal='+d.mode;});d.clock();d.terminal={calls,unchanged:before===d.frames.length};
 }
 if(d.mode==='reentrant-halt'||d.mode==='reentrant-fault'||d.mode==='attach-fault'){const before=d.frames.length;let calls=0;const image=new Image();await new Promise(resolve=>{image.onload=()=>{calls++;resolve();};image.src=location.origin+'/image.png?terminal='+d.mode;});d.clock();d.terminal={calls,unchanged:before===d.frames.length};}
 const records=d.decode();return {mode:d.mode,records,frames:d.frames.map(f=>Array.from(f)),events:d.events,snapshots:d.snapshots,installed:d.installed,beforeFrames:d.beforeFrames,positions:d.positions,listenerCalls:d.listenerCalls,hashes:d.hashes,clockBefore:d.clockBefore,clockAfter:d.clockAfter,clockAdvanced:d.clockAdvanced,resource,loadedCadence:d.loadedCadence,dueBefore:d.dueBefore,terminal:d.terminal};
 });
 receipts.set(mode,r);persist();const records=r.records;for(const observation of r.positions)assert.deepEqual(observation.actual,observation.reference,'DP_ASSERT: exact-owner-position-reference');
 const loading=records.filter(x=>x.record==='Loading'),positionRows=r.positions.filter(x=>x.actual!==null);check(loading.every((x,i)=>JSON.stringify({phase:x.phase,elements:x.elements,scripts:x.scripts,text:x.text})===JSON.stringify(positionRows[i]?.actual)),'exact-loading-field-correspondence');
 const docs=records.filter(x=>x.record==='DocTask'),checkpoints=records.filter(x=>x.record==='Checkpoint');
 assert.deepEqual(checkpoints.map(x=>({hash:x.state_hash,scheme:x.scheme,ordinal:x.ordinal,dom:x.dom_digest})),r.hashes.map((hash,ordinal)=>({hash,scheme:'dom-v1',ordinal,dom:''})),'DP_ASSERT: exact-checkpoint-provider-fields');
 if(mode.startsWith('selection-')){assert.deepEqual(r.clockAfter,r.clockBefore,'DP_ASSERT: selected-clock-preserved');check(r.clockAfter.same&&r.clockBefore.hookSame&&r.clockAfter.hookSame,'selected-clock-and-global-backend-identity');if(mode==='selection-fake')check(r.clockBefore.fakeNow===0&&r.clockBefore.fakeInstalled&&r.clockBefore.globalFakeNow===0&&r.clockAfter.fakeInstalled&&r.clockAfter.globalFakeNow===0&&r.clockAfter.fired===0&&r.clockAdvanced.fakeInstalled&&r.clockAdvanced.hookSame&&r.clockAdvanced.fakeNow===2&&r.clockAdvanced.globalFakeNow===2&&r.clockAdvanced.fired===1,'actual-fake-context-retains-pending-work');}
 if(!mode.startsWith('initial-')){
 check(r.listenerCalls.every(x=>['window','document','element'].includes(x.receiver)&&typeof x.type==='string'&&x.listener==='function'&&x.capture===true&&x.argc===3),'captured-listener-receiver-arguments');
 if(mode!=='attach-fault'&&r.listenerCalls.length)assert.deepEqual(r.listenerCalls.slice(0,5).map(x=>[x.receiver,x.type]),[['document','load'],['document','error'],['window','readystatechange'],['window','load'],['window','DOMContentLoaded']],'DP_ASSERT: captured-initial-listener-order');
 }
 if(mode.startsWith('initial-')){check(r.installed.installs===0&&r.installed.addSame&&r.installed.onloadSame&&records.length===r.beforeFrames,'inactive-no-install');}
 else if(mode==='reentrant-halt'||mode==='reentrant-fault'||mode==='attach-fault'){
 check(r.terminal.calls===1&&r.terminal.unchanged,'reentrant-no-post-terminal');check(records.filter(x=>x.record==='Refusal').length===(['reentrant-fault','attach-fault'].includes(mode)?1:0)&&records.filter(x=>x.record==='Refusal').every(x=>x.feature==='recorder-fault'),'reentrant-owner-fault-order');check(records.filter(x=>x.record==='Clock'||x.record==='DocTask').length===0,'reentrant-no-late-progress');
 }else{
 if(mode==='parsing-end'||mode==='explicit')check(r.dueBefore===false,'parsing-cadence-suppressed');
 const seam=records.findIndex(x=>x.record==='DocTask'&&x.kind===1&&x.src===origin+'/seam.js'),clock=records.findIndex(x=>x.record==='Clock');
 check(seam>=0&&records[seam-1]?.record==='Loading'&&records[seam-1].phase===1&&seam<clock,'parser-loading-script-before-clock');
 check(r.installed.installs>0&&!r.installed.addSame&&!r.installed.onloadSame,'active-owner-installation');
 assert.deepEqual(records.slice(0,5).map(x=>x.record),['Header','Env','Loading','DocTask','Clock'],'DP_ASSERT: exact-start-loading-clock-prefix');
 assert.deepEqual(r.events.filter(x=>['seam','no-seam','defer','page-dcl','page-load'].includes(x)),['seam','no-seam','defer','page-dcl','page-load'],'DP_ASSERT: authored-callback-order');
 check(docs.some(x=>x.kind===4&&x.src===origin+'/no-seam.js'),'no-seam-script-settled');
 for(const [kind,path]of [[1,'/seam.js'],[4,'/no-seam.js']]){const row=docs.find(x=>x.kind===kind&&x.src===origin+path);assert.deepEqual({kind:row.kind,src:row.src,target:row.target,event:row.event},{kind,src:origin+path,target:'',event:''},'DP_ASSERT: exact-script-fields');}
 for(const row of docs.filter(x=>x.kind===2||x.kind===3))assert.deepEqual({kind:row.kind,src:row.src,target:row.target,event:row.event},{kind:row.kind,src:'',target:'',event:''},'DP_ASSERT: exact-document-event-fields');
 if(mode==='parser'||mode.startsWith('terminal-')){
 check(docs.filter(x=>x.kind===2).length===1&&docs.filter(x=>x.kind===3).length===1&&docs.some(x=>x.kind===1&&x.src===origin+'/defer.js'),'defer-dcl-load-tasks');
 check(r.snapshots.find(x=>x.label==='dcl').doc.some(x=>x.kind===2)&&r.snapshots.find(x=>x.label==='load').doc.some(x=>x.kind===3),'owner-before-page-event-delivery');
 for(const [kind,phase]of [[2,2],[3,3]]){const at=records.findIndex(x=>x.record==='DocTask'&&x.kind===kind);check(at>0&&records[at-1].record==='Loading'&&records[at-1].phase===phase,'actual-document-event-loading-phase');}
 const deferred=docs.find(x=>x.kind===1&&x.src===origin+'/defer.js');assert.deepEqual({kind:deferred.kind,src:deferred.src,target:deferred.target,event:deferred.event},{kind:1,src:origin+'/defer.js',target:'',event:''},'DP_ASSERT: exact-deferred-script-fields');
 }
 if(mode==='parsing-end'||mode==='explicit'){
 check(r.dueBefore===false,'parsing-cadence-suppressed');check(checkpoints.length===(mode==='explicit'?1:0),'parsing-automatic-end-suppressed-explicit-unconditional');check(records.at(-1).record==='End','parsing-end-terminal');
 }
 if(mode==='parser'){
 check(r.resource.length===4&&r.resource.every(x=>x.trusted&&x.countBeforePage===1&&x.target===x.expectedTarget&&x.syntheticCalls===1&&x.syntheticSilent),'trusted-resource-dedup-before-handler-synthetic-silence');
 check(r.loadedCadence.due&&r.loadedCadence.before===0&&r.loadedCadence.after===1&&checkpoints.length===2,'loaded-cadence-and-final-checkpoint');
 check(checkpoints.every(x=>x.scheme==='dom-v1'&&typeof x.state_hash==='string'&&x.state_hash.length>0),'actual-owner-dom-hashes');
 }
 if(mode.startsWith('terminal-'))check(r.terminal.calls===1&&r.terminal.unchanged,'terminal-no-late-records-app-delivery');
 }
 const seq=records.filter(x=>'seq'in x).map(x=>x.seq);check(seq.every((s,i)=>s===BigInt(i+1)),'contiguous-sequence');if(records.at(-1)?.record==='End')check(records.at(-1).last_seq===(seq.at(-1)??0n)&&records.filter(x=>x.record==='End').length===1,'one-end-last-seq');
 receipts.set(mode,r);await page.close();console.log(mode+' document progression PASS');
 }
 writeFileSync(process.env.DOCUMENT_PROGRESS_RECEIPT,JSON.stringify({requests,cases:Object.fromEntries(receipts)},(_,v)=>typeof v==='bigint'?String(v):v,2));
}finally{if(release)release();if(browser)await browser.close();await new Promise(r=>server.close(r));}
