// Same real renderer import graph twice in fresh native Chromium pages. Native
// wrappers only count and delegate exact receiver/arguments/results; no fake API.
import {chromium} from './browser/node_modules/playwright/index.mjs';
import assert from 'node:assert/strict';
import {readFile,writeFile} from 'node:fs/promises';
const browser=await chromium.launch({executablePath:process.env.PLAYWRIGHT_CHROMIUM_EXECUTABLE});
const results=[];
try{
 for(const path of [process.env.CLIENT_OMISSION_A,process.env.CLIENT_OMISSION_B]){
  const page=await browser.newPage();const errors=[];page.on('pageerror',e=>errors.push(String(e)));
  await page.goto('about:blank');
  await page.evaluate(()=>{
   const counts={};const bump=n=>counts[n]=(counts[n]||0)+1;
   for(const name of ['WeakMap','Map','WeakSet','TextEncoder','TextDecoder','Uint8Array']){const ctor=globalThis[name];globalThis[name]=new Proxy(ctor,{construct(t,args,newTarget){bump(name);return Reflect.construct(t,args,newTarget);}});}
   for(const [obj,name] of [[Date,'now'],[performance,'now'],[Math,'random'],[crypto,'getRandomValues'],[crypto,'randomUUID'],[document,'createElement'],[document,'createTextNode'],[globalThis,'setTimeout'],[globalThis,'setInterval'],[globalThis,'requestAnimationFrame']]){
    const fn=obj[name];obj[name]=function(...args){bump((obj===document?'document.':'')+name);return Reflect.apply(fn,this,args);};
   }
   const globals=()=>Object.fromEntries(Reflect.ownKeys(globalThis).filter(k=>typeof k==='string'&&!k.startsWith('omission')&&!k.startsWith('__probe')).sort().map(k=>{const d=Object.getOwnPropertyDescriptor(globalThis,k);return[k,{configurable:d.configurable,enumerable:d.enumerable,writable:d.writable,get:d.get?.name,set:d.set?.name,type:typeof d.value}];}));
   globalThis.__probe={counts,globals,before:globals()};
  });
  await page.addScriptTag({content:await readFile(path,'utf8')});
  const result=await page.evaluate(()=>{
   const clock=omittedClock(),hook=omittedHook(),shared=omittedSharedConfig();
   if(!shared||typeof shared!=='object'||!['context','registry','completed','events','done','gather','load','has'].every(k=>Object.hasOwn(shared,k)))throw Error('actual production SharedConfig required');
   const typed=v=>v===null?{type:'null'}:v===undefined?{type:'undefined'}:Array.isArray(v)?{type:'array',length:v.length}:typeof v==='bigint'?{type:'bigint',decimal:v.toString()}:{type:typeof v,...(['boolean','number','string'].includes(typeof v)?{value:v}:{})};
   const context=shared.context===null?typed(null):{type:'object',id:typed(shared.context.id),count:typed(shared.context.count),noHydrate:typed(shared.context.noHydrate)};
   const registry=shared.registry===null?typed(null):{type:'object',mapType:Object.prototype.toString.call(shared.registry.map),size:shared.registry.map.size,keys:Array.from(shared.registry.map.keys())};
   const hydration={context,registry,completed:typed(shared.completed),events:typed(shared.events),done:typed(shared.done),gather:typed(shared.gather),load:typed(shared.load),has:typed(shared.has),nativeHydration:{adopted:typed(isonimHy.adopted),mismatches:typed(isonimHy.mismatches),append:typeof isonimHy.append,finish:typeof isonimHy.finish}};
   const iid={present:Object.hasOwn(globalThis,'__isonimIids'),registryType:typeof globalThis.__isonimIids,size:globalThis.__isonimIids?.size??null,keys:globalThis.__isonimIids?Array.from(globalThis.__isonimIids.keys()):null,validate:typeof globalThis.__isonimValidateIids,remember:typeof globalThis.__isonimRememberIid,finalizer:typeof globalThis.__isonimIidFinalizer}; const e=omittedPublic('article'); if(!(e instanceof Element)||e.localName!=='article')throw Error('actual ordinary factory required');
   const after=__probe.globals(),delta={};for(const [k,v]of Object.entries(after))if(JSON.stringify(v)!==JSON.stringify(__probe.before[k]))delta[k]=v;
   return {counts:__probe.counts,clockPresent:clock!=null,hookPresent:hook!=null,clockConstructor:clock?.m_type?.name,dispatchSequence:{type:typeof clock?.dispatchSequence,decimal:String(clock?.dispatchSequence)},globals:delta,hydration,iid,owner:typeof globalThis.__ctBoundaryProtocol,ready:omissionReady};
  });
  assert.deepEqual(errors,[]);assert.equal(result.ready,true);assert.deepEqual(result.hydration.context,{type:'null'});assert.deepEqual(result.hydration.registry,{type:'null'});assert.deepEqual(result.hydration.done,{type:'boolean',value:false});assert.deepEqual(result.hydration.nativeHydration.adopted,{type:'array',length:0});assert.deepEqual(result.hydration.nativeHydration.mismatches,{type:'number',value:0});assert.equal(result.iid.present,false);assert.equal(result.iid.registryType,'undefined');assert.equal(result.owner,'undefined');results.push(result);await page.close();
 }
 assert.deepEqual(results[0],results[1],'unused define has zero runtime delta across actual graph');
 console.log('same renderer import graph exact native/state/descriptor delta PASS');
}finally{await browser.close();await writeFile(process.env.CLIENT_OMISSION_RESULTS,JSON.stringify(results,null,2)+'\n');}
