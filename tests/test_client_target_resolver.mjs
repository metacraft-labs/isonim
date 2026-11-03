// Compiled production renderer/resolver in real Chromium. Loopback substitutes
// hosting only. Delegating native witnesses preserve receivers/results/errors.
// Controlled Map/WeakRef failures test precise resource-fault ordering after real
// native positives; they do not replace platform liveness or force collection.
// The bounded next-counter setup exercises exact BigInt arithmetic beyond 2^53,
// not a claim to have initially created that many elements.
import {chromium} from '../node_modules/playwright/index.mjs';
import {readFile,writeFile} from 'node:fs/promises';
import {createServer} from 'node:http';
import {readFileSync,statfsSync} from 'node:fs';
import assert from 'node:assert/strict';
import {createRequire} from 'node:module';
import {resolve} from 'node:path';
const checks=[],observations={};
const check=(name,actual,expected)=>{checks.push({name,actual,expected});assert.deepEqual(actual,expected,'semantic: '+name);};
const artifact=process.env.CT_ARTIFACT;
assert.ok(artifact,'actual installed supported SDK is mandatory');
const {build}=createRequire(artifact+'/packages/boundary-shim/package.json')('esbuild');
const sdk=await build({stdin:{resolveDir:artifact,contents:`
import {installBoundaryShim} from '@codetracer/boundary-shim/dist/browser/install.js';
import {decodeLog} from '@codetracer/boundary-format';
globalThis.targetSdk={installBoundaryShim,decodeLog};`},bundle:true,platform:'browser',format:'iife',write:false,metafile:true});
const sdkInputs={};for(const path of Object.keys(sdk.metafile.inputs)){if(path!=='<stdin>'){const absolute=resolve(path);sdkInputs[absolute]=await readFile(absolute,'utf8');}}
// The controller binds the immutable installed graph before/after this consumer.
// Preserve actual esbuild input names and exact emitted output for review.
await writeFile(process.env.CLIENT_TARGET_RESULTS+'.SDK.json',JSON.stringify({metafile:sdk.metafile,inputs:Object.keys(sdkInputs)},null,2)+'\n');
await writeFile(process.env.CLIENT_TARGET_RESULTS+'.SDK.js',sdk.outputFiles[0].text);
const html=await readFile(process.env.CLIENT_TARGET_SSR,'utf8');
const server=createServer((req,res)=>res.end(html));
await new Promise(resolve=>server.listen(0,'127.0.0.1',resolve));let browser;
try {
 const disk=statfsSync(process.cwd()),mem=Number(/^MemAvailable:\s+(\d+)/m.exec(readFileSync('/proc/meminfo','utf8'))[1])*1024,minimum=Math.max(8*1024**3,Number(process.env.ISONIM_TEST_MIN_AVAILABLE_BYTES||0));
 observations.admission={disk:disk.bavail*disk.bsize,MemAvailable:mem,minimum};assert.ok(Math.min(disk.bavail*disk.bsize,mem)>=minimum,'BLOCKED: browser resource admission');
 browser=await chromium.launch({executablePath:process.env.PLAYWRIGHT_CHROMIUM_EXECUTABLE});observations.browser=browser.version();
 const page=await browser.newPage();const errors=[];page.on('pageerror',e=>errors.push(String(e)));
 await page.goto('http://127.0.0.1:'+server.address().port+'/');
 // Host CSS is loaded before the native witness and explicit contexts exist.
 await page.addStyleTag({content:await readFile(new URL('../build/tailwind.css',import.meta.url),'utf8')});
 await page.evaluate(()=>{
  const create=Document.prototype.createElement;
  globalThis.nativeCalls=[];globalThis.nativeFailures=[];globalThis.nativeListeners=[];
  const add=EventTarget.prototype.addEventListener;EventTarget.prototype.addEventListener=function(...args){const result=Reflect.apply(add,this,args);nativeListeners.push({receiver:this,args,result});return result;};
  Document.prototype.createElement=function(...args){try{const before=globalThis.ctTarget?.count();const result=Reflect.apply(create,this,args);if(globalThis.creationTrace)creationTrace.push('native');nativeCalls.push({receiver:this,args,result,before});return result;}catch(error){nativeFailures.push(error);throw error;}};
 });
 await page.evaluate(source=>(0,eval)(source),await readFile(process.env.CLIENT_TARGET_BUNDLE,'utf8'));
 async function probe(name,fn){check(name,await page.evaluate(fn),true);}
 async function freshHydrationProbe(name,fn){
  const fresh=await browser.newPage();fresh.on('pageerror',e=>errors.push(String(e)));
  try{await fresh.goto('http://127.0.0.1:'+server.address().port+'/');
   await fresh.addStyleTag({content:await readFile(new URL('../build/tailwind.css',import.meta.url),'utf8')});
   await fresh.evaluate(()=>{const original=Document.prototype.createElement;globalThis.nativeCalls=[];Document.prototype.createElement=function(...args){const result=Reflect.apply(original,this,args);nativeCalls.push({receiver:this,args,result});return result;};});
   await fresh.evaluate(source=>(0,eval)(source),await readFile(process.env.CLIENT_TARGET_BUNDLE,'utf8'));
   check(name,await fresh.evaluate(fn),true);
  }finally{await fresh.close();}
 }

 await probe('native-initial',()=>{
  ctTarget.meter(true);globalThis.c=ctTarget.context();globalThis.other=ctTarget.context();
  globalThis.a=ctTarget.create(c,'section');globalThis.b=ctTarget.create(c,'button');
  ctTarget.text('text consumes no ordinal');globalThis.d=ctTarget.create(c,'span');document.body.append(a,b,d);
  globalThis.directNativeSpan={start:0,end:nativeCalls.length};
  globalThis.appNativeStart=nativeCalls.length;
  globalThis.witnessApp=brandedTaskApp.open('resolver-witness-first');
  globalThis.initialAppCount=nativeCalls.length;
  witnessApp.add('first deferred row');
  globalThis.witnessSecond=brandedTaskApp.open('resolver-witness-second');
  witnessSecond.add('second owner row');
  witnessApp.dispose();globalThis.stoppedHtml=witnessApp.root.innerHTML;globalThis.stoppedRenders=witnessApp.renders();
  witnessApp.add('mutable disposed store');
  witnessSecond.add('second deferred row');
  globalThis.witnessLate=brandedTaskApp.open('resolver-witness-late');witnessLate.add('late deferred row');
  globalThis.composedDsl=ctTarget.dslControl();document.body.append(composedDsl);composedDsl.click();
  // This is the entire contiguous app-native span, including removed/transient
  // nodes and all roots. No native app call is silently filtered out.
  globalThis.appNativeSpan={start:appNativeStart,end:nativeCalls.length};
  globalThis.appNativeCalls=nativeCalls.slice(appNativeSpan.start,appNativeSpan.end);
  return directNativeSpan.end===3&&appNativeSpan.end>appNativeSpan.start&&nativeCalls.every(x=>x.receiver===document&&x.args.length===1&&x.args[0]===x.result.localName&&x.result instanceof HTMLElement);
 });
 await probe('nonempty-initial',()=>nativeCalls.length>0);
 await probe('full-task-app-deferred-multiroot-disposal-witness',()=>
  appNativeCalls.length>0&&nativeCalls.length>initialAppCount&&
  directNativeSpan.end===appNativeSpan.start&&appNativeSpan.end===nativeCalls.length&&appNativeCalls.length===appNativeSpan.end-appNativeSpan.start&&
  witnessApp.root instanceof HTMLElement&&witnessSecond.root instanceof HTMLElement&&witnessLate.root instanceof HTMLElement&&
  witnessApp.root.isConnected&&witnessSecond.root.isConnected&&witnessLate.root.isConnected&&
  JSON.parse(witnessApp.snapshot()).map(t=>t.text).join('|')==='first deferred row|mutable disposed store'&&
  witnessApp.root.innerHTML===stoppedHtml&&witnessApp.renders()===stoppedRenders&&
  JSON.parse(witnessSecond.snapshot()).map(t=>t.text).join('|')==='second owner row|second deferred row'&&
  [...witnessSecond.root.querySelectorAll('span')].some(e=>e.textContent==='second deferred row')&&
  JSON.parse(witnessLate.snapshot()).map(t=>t.text).join('|')==='late deferred row'&&
  [...witnessLate.root.querySelectorAll('span')].some(e=>e.textContent==='late deferred row')&&
  ctTarget.dslCalls()===1&&nativeListeners.length>0&&nativeListeners.some(call=>call.receiver===composedDsl&&call.args[0]==='click'&&typeof call.args[1]==='function'&&call.result===undefined));
 observations.nativeSpans=await page.evaluate(()=>({direct:directNativeSpan,app:appNativeSpan,total:nativeCalls.length}));
 // Resolving BEFORE any forward observation is the shared oracle for ALL builds.
 check('meter-precedes-native',await page.evaluate(()=>nativeCalls.map(call=>call.before)),Array.from({length:observations.nativeSpans.total},(_,i)=>process.env.CLIENT_TARGET_NO_METER==='1'?0:i+1));
 await probe('inverse-is-at-creation',()=>ctTarget.resolve(c,'ord:3')===d&&ctTarget.resolve(c,'ord:2')===b&&ctTarget.resolve(c,'ord:1')===a);
 await probe('detached-live-ordinal-resolves',()=>{a.remove();return !a.isConnected&&ctTarget.resolve(c,'ord:1')===a;});
 await probe('every-created-node-resolves-exactly',()=>nativeCalls.slice(directNativeSpan.start,directNativeSpan.end).every((call,i)=>ctTarget.resolve(c,'ord:'+(i+1))===call.result)&&appNativeCalls.every((call,i)=>ctTarget.resolve(ctTarget.taskContext,'ord:'+(i+1))===call.result));
 await probe('forward-metadata-exact',()=>[a,b,d].every((node,i)=>ctTarget.query(c,node)===String(i+1)));
 await probe('removed-live-ordinal-resolves',()=>{document.body.append(a);a.remove();return ctTarget.resolve(c,'ord:1')===a;});
 await probe('context-own-ordinal-resolves',()=>{globalThis.own=ctTarget.create(other,'aside');return ctTarget.resolve(other,'ord:1')===own&&ctTarget.resolve(c,'ord:1')===a&&ctTarget.resolve(other,'ord:2')===null&&ctTarget.query(other,a)===null;});
 await probe('doc-win-exact',()=>ctTarget.resolve(c,'doc')===document&&ctTarget.resolve(c,'win')===window);
 await probe('canonical-ordinal-is-required',()=>['ord:0','ord:01','ord:+1','ord:-1','ord: 1','ord:1 ','ord:1e0','ord:1.0','ord:','ord:１','ord:1\n','ord:1\0','path:1','data-hk:1','mql:a','mql:1','viewport','visualViewport','notification','notification:1','Doc','win:','iid:'].every(t=>ctTarget.resolve(c,t)===null));
 await probe('no-user-string-coercion',()=>{let calls=0;const value={toString(){calls++;throw Error('conversion');}};return [null,undefined,1,1n,true,value,Symbol('target')].every(t=>ctTarget.resolve(c,t)===null)&&calls===0;});
 await probe('malformed-before-map-and-bigint',()=>{const original=c.targets.get;let calls=0;c.targets.get=function(){calls++;throw Error('lookup');};try{return ['ord:0','ord:01','ord:-1','ord:1.0'].every(t=>ctTarget.resolve(c,t)===null)&&calls===0;}finally{c.targets.get=original;}});
 await probe('malformed-before-bigint',()=>{const Orig=BigInt;let calls=0;globalThis.BigInt=()=>{calls++;throw Error('parse');};try{return ['ord:0','ord:01','ord:-1','ord:1.0','ord:1\n'].every(t=>ctTarget.resolve(c,t)===null)&&calls===0;}finally{globalThis.BigInt=Orig;}});
 await probe('unknown-ordinal-only-context-map',()=>{const get=c.targets.get,forward=c.forward.ordinals.get,validator=globalThis.__isonimValidateIids,hadValidator=Object.hasOwn(globalThis,'__isonimValidateIids'),query=Document.prototype.querySelector;let keys=[],forwards=0,validations=0,queries=0;c.targets.get=function(n){keys.push(n);return Reflect.apply(get,this,[n]);};c.forward.ordinals.get=function(){forwards++;throw Error('forward lookup');};globalThis.__isonimValidateIids=()=>{validations++;throw Error('iid lookup');};Document.prototype.querySelector=function(){queries++;throw Error('DOM query');};try{return ctTarget.resolve(c,'ord:9999999999999999999999999')===null&&keys.length===1&&keys[0]===9999999999999999999999999n&&forwards===0&&validations===0&&queries===0;}finally{c.targets.get=get;c.forward.ordinals.get=forward;if(hadValidator)globalThis.__isonimValidateIids=validator;else delete globalThis.__isonimValidateIids;Document.prototype.querySelector=query;}});
 await probe('huge-unknown-is-exact',()=>ctTarget.resolve(c,'ord:999999999999999999999999999999999999999999999')===null);
 await probe('beyond-safe-range-controlled-setup',()=>{const huge=ctTarget.context();huge.forward.next=9007199254740993n;const first=ctTarget.create(huge,'strong'),second=ctTarget.create(huge,'em');return ctTarget.query(huge,first)==='9007199254740993'&&ctTarget.query(huge,second)==='9007199254740994'&&ctTarget.resolve(huge,'ord:9007199254740993')===first&&ctTarget.resolve(huge,'ord:9007199254740994')===second&&ctTarget.resolve(huge,'ord:9007199254740992')===null;});
 await probe('invalid-context-before-native',()=>{const before=nativeCalls.length;let create=false,resolve=false;try{ctTarget.create(null,'div');}catch(e){create=e instanceof TypeError;}try{ctTarget.resolve(null,'doc');}catch(e){resolve=e instanceof TypeError;}return create&&resolve&&nativeCalls.length===before;});
 await probe('invalid-facade-and-link-before-native',()=>{const before=nativeCalls.length;let invalid=false,mismatch=false;try{ctTarget.invalidDefault();}catch(e){invalid=e instanceof TypeError;}try{ctTarget.mismatched();}catch(e){mismatch=e instanceof TypeError;}return invalid&&mismatch&&nativeCalls.length===before;});
 await probe('old-facade-allocates-no-inverse',()=>{const OrigMap=Map,OrigWeak=WeakRef;let maps=0,refs=0;function MapWitness(...args){maps++;return Reflect.construct(OrigMap,args,new.target);}MapWitness.prototype=OrigMap.prototype;function WeakWitness(...args){refs++;return Reflect.construct(OrigWeak,args,new.target);}WeakWitness.prototype=OrigWeak.prototype;globalThis.Map=MapWitness;globalThis.WeakRef=WeakWitness;let result;try{result=ctTarget.oldCreate();}finally{globalThis.Map=OrigMap;globalThis.WeakRef=OrigWeak;}return maps===0&&refs===0&&result===nativeCalls.at(-1).result;});
 await probe('native-error-identity',()=>{globalThis.failed=ctTarget.context();globalThis.nativeError=null;try{ctTarget.create(failed,'invalid tag');}catch(e){nativeError=e;}globalThis.afterFailure=ctTarget.create(failed,'i');return nativeError instanceof DOMException&&nativeError===nativeFailures.at(-1)&&nativeCalls.at(-1).result===afterFailure;});
 await probe('native-error-preserves-next',()=>ctTarget.query(failed,afterFailure)==='1'&&ctTarget.resolve(failed,'ord:1')===afterFailure);
 await probe('native-SSR-adoption-identity',()=>{globalThis.hy=ctTarget.context();globalThis.ssr=document.querySelector('#root section');globalThis.adopted=ctTarget.hydrate(hy,document.querySelector('#root'),'section');return adopted===ssr&&ssr instanceof HTMLElement;});
 await probe('adopted-node-consumes-no-inverse',()=>ctTarget.query(hy,adopted)===null&&ctTarget.resolve(hy,'ord:1')===null);
 await probe('after-adoption-first-native',()=>{const n=ctTarget.create(hy,'u');return ctTarget.query(hy,n)==='1'&&ctTarget.resolve(hy,'ord:1')===n;});
 await freshHydrationProbe('same-created-node-readoption-keeps-inverse',()=>{const context=ctTarget.context(),root=document.querySelector('#root'),key=root.firstElementChild.getAttribute('data-hk'),node=ctTarget.create(context,'section');root.replaceChildren(node);node.setAttribute('data-hk',key);const before=nativeCalls.length,result=ctTarget.hydrate(context,root,'section');const same=result===node&&nativeCalls.length===before&&ctTarget.query(context,node)==='1'&&ctTarget.resolve(context,'ord:1')===node;const next=ctTarget.create(context,'aside');return same&&ctTarget.query(context,next)==='2'&&ctTarget.resolve(context,'ord:2')===next;});
 await probe('native-reentrant-creation-uses-actual-assigned-value',()=>{const context=ctTarget.context();let inner;customElements.define('target-reentrant',class extends HTMLElement{constructor(){super();inner=ctTarget.create(context,'span');}});const outer=ctTarget.create(context,'target-reentrant');return inner instanceof HTMLElement&&outer instanceof HTMLElement&&inner!==outer&&ctTarget.query(context,inner)==='1'&&ctTarget.query(context,outer)==='2'&&ctTarget.resolve(context,'ord:1')===inner&&ctTarget.resolve(context,'ord:2')===outer;});
 await probe('ordered-actual-forward-then-inverse',()=>{
  const context=ctTarget.context(),forward=context.forward,originalWeak=WeakRef;
  const set=forward.ordinals.set,get=forward.ordinals.get,index=context.targets.set;
  let next=forward.next,assigned,node;globalThis.creationTrace=[];
  Object.defineProperty(forward,'next',{get(){creationTrace.push('read-next');return next;},set(n){creationTrace.push('commit-next');next=n;},configurable:true});
  forward.ordinals.set=function(e,n){creationTrace.push('set-forward');assigned=n;return Reflect.apply(set,this,[e,n]);};
  forward.ordinals.get=function(e){creationTrace.push('read-assigned');return Reflect.apply(get,this,[e]);};
  function Witness(...args){creationTrace.push('weakref');node=args[0];return Reflect.construct(originalWeak,args,new.target);}Witness.prototype=originalWeak.prototype;globalThis.WeakRef=Witness;
  context.targets.set=function(n,ref){creationTrace.push('index');return Reflect.apply(index,this,[n,ref]);};
  let actual;try{actual=ctTarget.create(context,'button');creationTrace.push('returned');}finally{globalThis.WeakRef=originalWeak;}
  const ordered=creationTrace.slice(creationTrace.indexOf('native'));delete globalThis.creationTrace;
  const indexed=context.targets.get(1n);
  return actual===node&&nativeCalls.at(-1).result===actual&&assigned===1n&&next===2n&&indexed.deref()===actual&&ordered.join(',')==='native,read-next,set-forward,commit-next,read-assigned,weakref,index,returned';
 });
 await freshHydrationProbe('mismatch-counts-real-native',()=>{const root=document.querySelector('#root'),ssr=root.firstElementChild,context=ctTarget.context(),before=nativeCalls.length;const actual=ctTarget.hydrate(context,root,'article');return actual!==ssr&&actual.localName==='article'&&actual.isConnected&&nativeCalls.length===before+1&&nativeCalls.at(-1).receiver===document&&nativeCalls.at(-1).result===actual&&_$HY.mismatches===1&&ctTarget.query(context,actual)==='1'&&ctTarget.resolve(context,'ord:1')===actual;});
 await probe('partial-weakref-failure-exact',()=>{const ctx=ctTarget.context(),Orig=WeakRef,error={phase:'weakref'};globalThis.WeakRef=function(){throw error;};let thrown;try{ctTarget.create(ctx,'small');}catch(e){thrown=e;}finally{globalThis.WeakRef=Orig;}const node=nativeCalls.at(-1).result;return thrown===error&&ctx.forward.next===2n&&ctTarget.query(ctx,node)==='1'&&ctx.targets.size===0;});
 await probe('partial-index-failure-exact',()=>{const ctx=ctTarget.context(),error={phase:'index'},original=ctx.targets.set;let args;ctx.targets.set=function(...values){args=values;throw error;};let thrown;try{ctTarget.create(ctx,'label');}catch(e){thrown=e;}finally{ctx.targets.set=original;}const node=nativeCalls.at(-1).result;return thrown===error&&ctx.forward.next===2n&&ctTarget.query(ctx,node)==='1'&&ctx.targets.size===0&&args[0]===1n&&args[1] instanceof WeakRef&&args[1].deref()===node;});
 await probe('dynamic-deref-error-is-original',()=>{const ref=c.targets.get(1n),original=ref.deref,error={phase:'deref'};ref.deref=()=>{throw error;};let actual;try{ctTarget.resolve(c,'ord:1');}catch(e){actual=e;}finally{ref.deref=original;}return actual===error;});
 await probe('forward-only-shape-unchanged',()=>Object.keys(c.forward).sort().join(',')==='next,ordinals'&&Object.keys(c).sort().join(',')==='forward,targets');
 if(process.env.CLIENT_TARGET_STABLE==='1'){
  await probe('composed-real-dsl-iid-resolves-build-wide',()=>{const node=composedDsl,iid=node.getAttribute('data-iid');return node instanceof HTMLButtonElement&&typeof iid==='string'&&iid.length>0&&ctTarget.resolve(other,'iid:'+iid)===node;});
  await probe('iid-global-detached-and-cross-context',()=>{ctTarget.stamp(a,'private-target-iid');return ctTarget.resolve(c,'iid:private-target-iid')===a&&ctTarget.resolve(other,'iid:private-target-iid')===a;});
  await probe('iid-forged-attribute-is-not-registration',()=>{const fake=ctTarget.create(c,'mark');fake.setAttribute('data-iid','unregistered-target');return ctTarget.resolve(c,'iid:unregistered-target')===null;});
  await probe('production-iid-validation-is-required',()=>{const one=ctTarget.create(c,'div'),two=ctTarget.create(c,'div');ctTarget.stamp(one,'duplicate-iid');ctTarget.stamp(two,'duplicate-iid');document.body.append(one,two);const validate=__isonimValidateIids;let original,actual;try{validate('duplicate-iid');}catch(e){original=e;}globalThis.__isonimValidateIids=function(iid){try{return validate(iid);}catch(e){actual=e;throw original;}};let thrown;try{ctTarget.resolve(c,'iid:duplicate-iid');}catch(e){thrown=e;}finally{globalThis.__isonimValidateIids=validate;one.remove();two.remove();}return original instanceof Error&&actual instanceof Error&&thrown===original&&original.message==='duplicate live stable iid: duplicate-iid';});
  await probe('iid-latest-detached-and-mounted-preference',()=>{const first=ctTarget.create(c,'div'),last=ctTarget.create(c,'div');ctTarget.stamp(first,'replacement-iid');document.body.append(first);ctTarget.stamp(last,'replacement-iid');const mounted=ctTarget.resolve(other,'iid:replacement-iid')===first;first.remove();return mounted&&ctTarget.resolve(c,'iid:replacement-iid')===last;});
  await probe('iid-exact-suffix-without-new-grammar',()=>{const key='opaque:#suffix\u0000',node=ctTarget.create(c,'div'),validator=globalThis.__isonimValidateIids;ctTarget.stamp(node,key);let received;globalThis.__isonimValidateIids=value=>{received=value;return validator(value);};try{return ctTarget.resolve(other,'iid:'+key)===node&&received===key;}finally{globalThis.__isonimValidateIids=validator;}});
  await probe('iid-registry-error-propagates',()=>{const original=globalThis.__isonimValidateIids,error={phase:'validator'};globalThis.__isonimValidateIids=()=>{throw error;};let actual;try{ctTarget.resolve(c,'iid:private-target-iid');}catch(e){actual=e;}finally{globalThis.__isonimValidateIids=original;}return actual===error;});
 }else await probe('iid-omission-without-registry',()=>ctTarget.resolve(c,'iid:anything')===null&&typeof globalThis.__isonimIids==='undefined');
 // Each kind gets its OWN real factory realm: weakref dedup in an ordinal
 // lookup must not hide whether the separate M6 IID path also refuses.
 const factoryResults=[];
 for(const kind of process.env.CLIENT_TARGET_STABLE==='1'?['ordinal','iid']:['ordinal']){
  const factoryPage=await browser.newPage();factoryPage.on('pageerror',e=>errors.push(String(e)));
  try{
   await factoryPage.goto('http://127.0.0.1:'+server.address().port+'/');
   await factoryPage.evaluate(source=>(0,eval)(source),await readFile(process.env.CLIENT_TARGET_BUNDLE,'utf8'));
   await factoryPage.evaluate(source=>(0,eval)(source),sdk.outputFiles[0].text);
   const factory=await factoryPage.evaluate(kind=>{
    const context=ctTarget.context(),node=ctTarget.create(context,'button');
    if(kind==='iid')ctTarget.stamp(node,'factory-target');
    const factory=targetSdk.installBoundaryShim(window,{buildHash:'a'.repeat(64)});
    const refusals=()=>targetSdk.decodeLog(factory.log()).records.filter(r=>r.record==='Refusal').map(r=>({feature:r.feature,detail:r.detail}));
    const before=refusals();
    const actual=ctTarget.resolve(context,kind==='ordinal'?'ord:1':'iid:factory-target');
    return {kind,exactNative:actual===node,before,records:refusals()};
   },kind);
   factoryResults.push(factory);
   check('installed-factory-'+kind+'-before-no-refusal',factory.before,[]);
   check('installed-factory-'+kind+'-native-result',factory.exactNative,true);
   check('installed-factory-'+kind+'-weakref-refusal',factory.records.filter(r=>r.feature==='weakref'&&r.detail==='WeakRef.deref').length,1);
  }finally{await factoryPage.close();}
 }
 observations.installedFactory=factoryResults;
 check('unexpected-page-errors',errors,[]);
} finally {if(browser)await browser.close();await new Promise(resolve=>server.close(resolve));await writeFile(process.env.CLIENT_TARGET_RESULTS,JSON.stringify({checks,observations},null,2)+'\n');}
console.log('PASS '+checks.length+' private target resolver assertions');
