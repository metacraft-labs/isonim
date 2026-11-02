// The actual frozen manifest component, native SSR/hydration and deferred reuse.
// No benchmark is run. Browser API spies forward the exact native call, and the
// copied component never substitutes an allocator or invents an ordinal.
import {chromium} from './browser/node_modules/playwright/index.mjs';
import {readFile,writeFile} from 'node:fs/promises';
import assert from 'node:assert/strict';
const browser=await chromium.launch({executablePath:process.env.PLAYWRIGHT_CHROMIUM_EXECUTABLE});
const rows=[];
try{
 const markup=await readFile(process.env.CLIENT_ROUTING_TASK_SSR,'utf8');
 const mismatchedMarkup=await readFile(process.env.CLIENT_ROUTING_TASK_MISMATCH_SSR,'utf8');
 const source=await readFile(process.env.CLIENT_ROUTING_BUNDLE,'utf8');
 for(const mismatch of [false,true]){
  const page=await browser.newPage();await page.setContent(mismatch?mismatchedMarkup:markup);
  const row=await page.evaluate(({source,mismatch})=>{
   const host=document.getElementById('root'),original=host.firstElementChild;
   const title=original.firstElementChild;const originalChildren=[...original.querySelectorAll('*')].filter(element=>!mismatch||element!==title);
   const native=document.createElement,calls=[];
   document.createElement=function(...args){const value=Reflect.apply(native,this,args);calls.push({receiver:this,args,value});return value;};
   try{
    (0,eval)(source);
    const api=actualTask,root=host.querySelector(':scope > .task-app'),initialCalls=calls.length;
    const adopted=[root,...root.querySelectorAll('*')];
    const initialOrdinals=adopted.map(element=>api.query(element));
    const last=root.lastElementChild;last.dispatchEvent(new Event('click'));
    const callsBefore=api.callCount(),late=api.later(),lateElements=[late,...late.querySelectorAll('*')];
    late.lastElementChild.dispatchEvent(new Event('click'));
    return {mismatch,rootCount:host.querySelectorAll(':scope > .task-app').length,rootTag:root.localName,rootIdentity:root===original,initialCalls,initialOrdinals,childrenAdopted:originalChildren.every(element=>root.contains(element)),elements:adopted.length,lateElements:lateElements.length,lateText:late.textContent,sameText:late.textContent===root.textContent,lateOrdinals:lateElements.map(element=>api.query(element)),callsBefore,callsAfter:api.callCount(),nativeIdentity:calls.every(call=>call.receiver===document&&call.args.length===1&&call.args[0]===call.value.localName),nativeOrdinals:calls.map(call=>api.query(call.value)),mismatches:globalThis._$HY.mismatches};
   }finally{document.createElement=native;}
  },{source,mismatch});
  rows.push(row);await page.close();
  assert.equal(row.rootCount,1);assert.equal(row.elements,67);assert.equal(row.lateElements,67);assert.equal(row.rootTag,'div');assert.equal(row.rootIdentity,true);
  assert.equal(row.initialCalls,mismatch?1:0,'only actual title mismatch falls back to native H1 creation');
  assert.equal(row.childrenAdopted,true,'actual original server descendants retained');
  assert.deepEqual(row.initialOrdinals,mismatch?[null,'1',...Array(65).fill(null)]:Array(67).fill(null));
  assert.equal(row.nativeIdentity,true);assert.equal(row.sameText,true);assert.ok(row.lateText.includes('Task 19'));
  assert.deepEqual(row.nativeOrdinals,Array.from({length:67+(mismatch?1:0)},(_,i)=>String(i+1)));
  assert.deepEqual(row.lateOrdinals,Array.from({length:67},(_,i)=>String(i+1+(mismatch?1:0))));
  assert.equal(row.callsBefore,1);assert.equal(row.callsAfter,2);assert.equal(row.mismatches,mismatch?1:0);
 }
 console.log('actual manifest task component/SSR/adoption/title-mismatch/deferred namespace PASS');
}finally{await writeFile(process.env.CLIENT_ROUTING_RESULTS,JSON.stringify(rows,null,2)+'\n');await browser.close();}
