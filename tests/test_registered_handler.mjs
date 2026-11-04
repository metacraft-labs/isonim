// Real Chromium DOM and compiled production listen/owner/helper only. The
// callback references are test-local identities; no substitute registration map.
import {chromium} from './browser/node_modules/playwright/index.mjs';
import {readFile,writeFile} from 'node:fs/promises';
import assert from 'node:assert/strict';
import {createServer} from 'node:http';
const bundle=process.env.REGISTERED_BUNDLE;
assert(bundle,'REGISTERED_BUNDLE required');
const server=createServer((req,res)=>res.end('<!doctype html><body></body>'));
await new Promise(resolve=>server.listen(0,'127.0.0.1',resolve));
const browser=await chromium.launch({executablePath:process.env.PLAYWRIGHT_CHROMIUM_EXECUTABLE});
try {
 const page=await browser.newPage();
 await page.goto('http://127.0.0.1:'+server.address().port);
 await page.addScriptTag({content:await readFile(bundle,'utf8')});
 const result=await page.evaluate(({only,nativeOnly})=>{
  const receipts=[];
  function check(ok,name){if(!ok)throw new Error('REGISTERED_ASSERT: '+name);receipts.push(name);}
  const call=(n,t,h,c,e)=>registeredCall(n,t,h,c,e);
  const state=()=>registeredState();
  const attempt=(fn)=>{try{return {ok:true,value:fn()};}catch(error){return {ok:false,error};}};
  const absent=(f,name)=>{const before=state();let a,b;try{f();}catch(e){a=e;}try{f();}catch(e){b=e;}
   check(a instanceof Error&&b instanceof Error&&Object.getPrototypeOf(a)===Error.prototype&&Object.getPrototypeOf(b)===Error.prototype&&state()===before&&a!==b&&a.message==='isonim registered handler is not active'&&b.message===a.message,name);};
  function test(name,body){if(!only||only===name)body();}
  registeredSelect('test');
  test('active',()=>{let hits=0,receiver,event;const n=document.createElement('div');document.body.append(n);
   function h(e){hits++;receiver=this;event=e;}const d=registeredListen(n,'click',h,false);
   const native=new Event('click');n.dispatchEvent(native);check(hits===1&&receiver===n&&event===native,'native-registration');
   if(!nativeOnly){const e=new Event('different');const delivered=attempt(()=>call(n,'click',h,false,e));check(delivered.ok&&hits===2&&receiver===n&&event===e,'active-registration');}d();n.remove();});
  if(nativeOnly)return receipts;
  test('tuple',()=>{const n=document.createElement('div'),other=document.createElement('div');let a=0,b=0;
   function h(){a++;}function h2(){b++;}
   const d=registeredListen(n,'click',h,false);n.dispatchEvent(new Event('click'));check(a===1,'tuple-native-positive');
   call(n,'click',h,false,new Event('change'));check(a===2,'tuple-exact-positive');
   absent(()=>call(n,'change',h,false,new Event('change')),'tuple-type');
   absent(()=>call(n,'click',h2,false,new Event('click')),'tuple-handler');
   absent(()=>call(n,'click',h,true,new Event('click')),'tuple-capture');
   absent(()=>call(other,'click',h,false,new Event('click')),'tuple-target');check(a===2&&b===0,'tuple-zero-effects');
   const d2=registeredListen(n,'change',h,false),d3=registeredListen(n,'click',h2,true);
   call(n,'change',h,false,new Event('click'));call(n,'click',h2,true,new Event('change'));check(a===3&&b===1,'tuple-distinct-positives');d();d2();d3();});
  test('owners',()=>{const n=document.createElement('div');let hits=0;function h(){hits++;}
   const first=registeredListen(n,'click',h,false);n.dispatchEvent(new Event('click'));check(hits===1,'duplicate-native-positive');const second=registeredListen(n,'click',h,false);check(first===second,'duplicate-disposer');first();second();hits=0;
   const release1=registeredOwned(n,'click',h,false),release2=registeredOwned(n,'click',h,false);
   n.dispatchEvent(new Event('click'));check(hits===1,'owner-native-positive');release2();
   const delivered=attempt(()=>call(n,'click',h,false,new Event('click')));check(delivered.ok&&hits===2,'first-owner-retained');release1();
   absent(()=>call(n,'click',h,false,new Event('click')),'first-owner-removal');n.dispatchEvent(new Event('click'));check(hits===2,'owner-native-removal');release1();release2();});
  test('removal',()=>{const n=document.createElement('div'),other=document.createElement('div');let hits=0,unrelated=0;function h(){hits++;}function u(){unrelated++;}
   const d=registeredListen(n,'click',h,false),du=registeredListen(other,'click',u,false),dt=registeredListen(n,'change',u,false);
   n.dispatchEvent(new Event('click'));check(hits===1,'removal-native-positive');d();d();
   absent(()=>call(n,'click',h,false,new Event('click')),'explicit-removal');call(other,'click',u,false,new Event('click'));call(n,'change',u,false,new Event('click'));check(unrelated===2,'unrelated-survives');
   const d2=registeredListen(n,'click',h,false);call(n,'click',h,false,new Event('click'));check(hits===2,'reregistration');d2();du();dt();
   let release;function self(){hits++;release();hits++;}release=registeredListen(n,'click',self,false);call(n,'click',self,false,new Event('click'));check(hits===4,'inflight-completes');absent(()=>call(n,'click',self,false,new Event('click')),'fresh-lookup-after-disposal');let changed=0,replace;function next(){changed++;}function first(){changed++;replace();replace=registeredListen(n,'click',next,false);changed++;}replace=registeredListen(n,'click',first,false);call(n,'click',first,false,new Event('click'));check(changed===2,'inflight-reregistration-completes');absent(()=>call(n,'click',first,false,new Event('click')),'old-callable-after-reregistration');call(n,'click',next,false,new Event('click'));check(changed===3,'fresh-callable-after-reregistration');replace();});
  test('detached',()=>{for(const n of [document.createElement('div'),document,window]){let receiver;function h(){receiver=this;}const d=registeredListen(n,'click',h,false);n.dispatchEvent(new Event('click'));check(receiver===n,'detached-native-positive');receiver=null;const delivered=attempt(()=>call(n,'click',h,false,new Event('click')));check(delivered.ok&&receiver===n,'detached-live-target');d();}});
  test('values',()=>{const n=document.createElement('div'),typed=registeredTyped(n),before=registeredTypedCount();n.dispatchEvent(new Event('click'));check(registeredTypedCount()===before+1,'values-native-positive');call(n,'click',typed.handler,false,new Event('different'));check(registeredTypedCount()===before+2,'typed-void-control');typed.dispose();for(const value of [{opaque:1},undefined,Promise.resolve(1)]){function h(){return value;}const d=registeredListen(n,'click',h,false);check(call(n,'click',h,false,new Event('click'))===value,'return-identity');d();}
   for(const value of [{opaque:2},Symbol('throw'),null]){function h(){throw value;}const d=registeredListen(n,'click',h,false);let caught=false,actual;try{call(n,'click',h,false,new Event('click'));}catch(e){caught=true;actual=e;}check(caught&&actual===value,'throw-identity');d();}});
  test('event',()=>{const n=document.createElement('div'),e=new Event('different',{cancelable:true});let actual,receiver;const descriptors=Object.getOwnPropertyDescriptors(e),refs=[e.target,e.currentTarget,e.isTrusted,e.type,e.timeStamp];function h(ev){actual=ev;receiver=this;}const d=registeredListen(n,'click',h,false);call(n,'click',h,false,e);
   check(actual===e&&receiver===n,'event-identity');check(Reflect.ownKeys(e).length===Reflect.ownKeys(descriptors).length&&Reflect.ownKeys(descriptors).every(key=>{const a=descriptors[key],b=Object.getOwnPropertyDescriptor(e,key);return b&&Reflect.ownKeys(a).length===Reflect.ownKeys(b).length&&Reflect.ownKeys(a).every(k=>Object.is(a[k],b[k]));})&&[e.target,e.currentTarget,e.isTrusted,e.type,e.timeStamp].every((v,i)=>v===refs[i]),'event-fields-untouched');d();});
  test('accounting',()=>{for(const mode of ['real','test','custom','fake']){registeredSelect(mode);const n=document.createElement('div');let hits=0,hooks=0;registeredHook(()=>hooks++);function h(){hits++;}const d=registeredListen(n,'click',h,false);const before=JSON.parse(state());n.dispatchEvent(new Event('click'));const native=JSON.parse(state());check(hits===1&&hooks===1,'accounting-native-positive');
   const direct=globalThis.registeredDirect;
   check(direct?native.sequence===before.sequence:BigInt(native.sequence)===BigInt(before.sequence)+1n,'accounting-native-sequence');
   check((native.checkpoints-before.checkpoints)===(globalThis.registeredRecordable&&!direct?1:0),'accounting-native-checkpoint');
   check(native.clockReads-before.clockReads===(mode==='custom'&&!direct?1:0),'accounting-native-clock');
   const frozen=state();call(n,'click',h,false,new Event('different'));check(hits===2&&hooks===1&&state()===frozen,'no-extra-bookkeeping');
   if(mode==='fake'){registeredAdvanceFake();check(JSON.parse(state()).fakeFired===native.fakeFired+1,'fake-real-scheduler-positive');}d();registeredHook(null);}});
  return receipts;
 },{only:process.env.REGISTERED_CASE||'',nativeOnly:process.env.REGISTERED_NATIVE_ONLY==='1'});
 await writeFile(process.env.REGISTERED_RECEIPT||bundle+'.receipt.json',JSON.stringify(result,null,2)+'\n');
 console.log('REGISTERED_PASS '+result.length);
}finally{await browser.close();await new Promise(resolve=>server.close(resolve));}
