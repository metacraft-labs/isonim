// Run actual emitted Nim against native Chromium DOM/EventTarget. Observer
// wrappers capture arguments and delegate every call with original receiver
// and all arguments to the real native methods; they do not mock dispatch.
// Foreign native, direct-node and nondet callbacks are independent controls.
// The inverse delivery assertion runs before the separate identity assertion
// so a genuine retained-delivery regression cannot be masked by observation.
import assert from 'node:assert/strict';
import {readFileSync} from 'node:fs';
import {chromium} from './browser/node_modules/playwright/index.mjs';
const bundle=readFileSync(process.env.DELEGATED_CLEAR_BUNDLE,'utf8');
const browser=await chromium.launch({executablePath:process.env.PLAYWRIGHT_CHROMIUM_EXECUTABLE});
try {
  const page=await browser.newPage();
  const errors=[];
  page.on('pageerror',error=>errors.push(String(error)));
  await page.setContent('<div id="parent"><button id="child">native</button></div>');
  await page.evaluate(()=>{
    globalThis.dcNativeCalls=[];globalThis.dcForeign=0;globalThis.dcDirect=0;globalThis.dcNondet=0;
    globalThis.dcForeignCallback=()=>dcForeign++;
    globalThis.dcDirectCallback=()=>dcDirect++;
    document.addEventListener('dc-main',dcForeignCallback);
    document.getElementById('child').addEventListener('dc-main',dcDirectCallback);
    const add=EventTarget.prototype.addEventListener,remove=EventTarget.prototype.removeEventListener;
    document.addEventListener=function(...args){dcNativeCalls.push(['add',...args]);return Reflect.apply(add,this,args)};
    document.removeEventListener=function(...args){dcNativeCalls.push(['remove',...args]);return Reflect.apply(remove,this,args)};
  });
  await page.addScriptTag({content:bundle});
  const initial=await page.evaluate(()=>{
    dcSetup();dcClear();dcClear();
    const noRegistration=dcNativeCalls.length;
    dcRegisterObserved();
    dcRegisterNative();dcRegisterStrings();dcRegisterNative();
    // Snapshot before clear: the foreign/direct/nondet paths must all fire.
    const dispatch=type=>{globalThis.dcEvent=new Event(type,{bubbles:true});document.getElementById('child').dispatchEvent(dcEvent)};
    dispatch('dc-main');dispatch('dc-other');
    const before=dcCalls.slice(),neutral=[dcForeign,dcDirect,dcNondet];
    const beforeCount=dcCalls.length;
    dcClear();dispatch('dc-main');dispatch('dc-other');
    const after=dcCalls.slice(),survivors=[dcForeign,dcDirect,dcNondet];
    const operationsBeforeRepeat=dcNativeCalls.length;dcClear();
    return {noRegistration,before,beforeCount,after,survivors,neutral,idempotent:dcNativeCalls.length===operationsBeforeRepeat};
  });
  assert.equal(initial.noRegistration,0,'clear semantic: empty clear has no native removals');
  assert.deepEqual(initial.before,[{who:'child',receiver:'child',same:true},{who:'parent',receiver:'parent',same:true,data:true},{who:'other',receiver:'child',same:true}],'clear semantic: original receiver/data/bubbling/cancelBubble');
  assert.deepEqual(initial.neutral,[1,1,1],'clear semantic: native foreign/direct/nondet controls before clear');
  assert.deepEqual(initial.survivors,[2,2,2],'clear semantic: native foreign/direct/nondet listeners survive clear');
  console.log('clear neutral before/foreign/direct/nondet: PASS');
  assert.equal(initial.after.length,initial.beforeCount,'clear semantic: no delegated delivery after clear');
  assert.equal(initial.idempotent,true,'clear semantic: idempotent clear');
  const identities=await page.evaluate(()=>{
    const calls=dcNativeCalls.filter(c=>c[1]==='dc-main'||c[1]==='dc-other');
    // Do not infer the callback from equality: identify the registration as
    // the second dc-main add (the first is nondet), and first dc-other add.
    const adds=calls.filter(c=>c[0]==='add'),removes=calls.filter(c=>c[0]==='remove');
    const main=adds.filter(c=>c[1]==='dc-main')[1],other=adds.find(c=>c[1]==='dc-other');
    return {addCounts:[adds.filter(c=>c[1]==='dc-main').length,adds.filter(c=>c[1]==='dc-other').length],removeCounts:[removes.filter(c=>c[1]==='dc-main').length,removes.filter(c=>c[1]==='dc-other').length],sameMain:main[2]===removes.find(c=>c[1]==='dc-main')[2],sameOther:other[2]===removes.find(c=>c[1]==='dc-other')[2],shared:main[2]===other[2],capture:[main[3]??false,other[3]??false,...removes.map(c=>c[3]??false)]};
  });
  assert.deepEqual(identities,{addCounts:[2,1],removeCounts:[1,1],sameMain:true,sameOther:true,shared:true,capture:[false,false,false,false]},'clear identity: actual native callback equality and mixed overload dedup');
  const cycles=await page.evaluate(()=>{
    const counts=[];
    for(let i=0;i<3;i++){
      if(i%2)dcRegisterNative();else dcRegisterStrings();
      const old=dcCalls.length;
      globalThis.dcEvent=new Event('dc-main',{bubbles:true});document.getElementById('child').dispatchEvent(dcEvent);
      counts.push(dcCalls.length-old);
      dcClear();const cleared=dcCalls.length;
      globalThis.dcEvent=new Event('dc-main',{bubbles:true});document.getElementById('child').dispatchEvent(dcEvent);
      counts.push(dcCalls.length-cleared);
    }
    const beforeCleanup=[dcForeign,dcDirect,dcNondet];
    dcRemoveObserved();document.removeEventListener('dc-main',dcForeignCallback);document.getElementById('child').removeEventListener('dc-main',dcDirectCallback);
    document.getElementById('child').dispatchEvent(new Event('dc-main',{bubbles:true}));
    return {counts,beforeCleanup,afterCleanup:[dcForeign,dcDirect,dcNondet]};
  });
  assert.deepEqual(cycles.counts,[2,0,2,0,2,0],'clear semantic: reregister exactly one delegated callback');
  assert.deepEqual(cycles.afterCleanup,cycles.beforeCleanup,'clear semantic: original listener cleanup remains valid');
  assert.deepEqual(errors,[],'clear semantic: no native page errors');
  console.log('delegated clear native identity/delivery/cycles: PASS');
}finally{await browser.close()}
