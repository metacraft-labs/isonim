// Execute the ENTIRE exact fixed artifact, including module initialization and
// its saved callback, in native Chromium. No surrogate allocator or source copy.
import {chromium} from './browser/node_modules/playwright/index.mjs';
import {readFile,writeFile} from 'node:fs/promises';
import assert from 'node:assert/strict';
const source=await readFile(process.env.CLIENT_ROUTING_BUNDLE,'utf8');
const browser=await chromium.launch({executablePath:process.env.PLAYWRIGHT_CHROMIUM_EXECUTABLE});
try{
 const page=await browser.newPage();await page.setContent('<!doctype html><main id="root"></main>');
 const result=await page.evaluate(source=>{
  const original=document.createElement,calls=[];
  document.createElement=function(...args){const value=Reflect.apply(original,this,args);calls.push({receiver:this,args,value});return value;};
  try{
   (0,eval)(source); // test harness only; the admitted artifact contains no eval.
   const api=fixedClientCreation,first=calls.length;
   const deferred=api.saved();
   const event=new MouseEvent('click',{cancelable:true});document.querySelector('a').dispatchEvent(event);
   return {first,total:calls.length,tags:calls.map(x=>x.value.localName),ordinals:calls.map(x=>api.query(x.value)),exactNative:calls.every(x=>x.receiver===document&&x.args.length===1&&x.args[0]===x.value.localName),mounted:document.getElementById('root').textContent,deferred:deferred.textContent,empty:api.empty.childNodes.length,prevented:event.defaultPrevented};
  }finally{document.createElement=original;}
 },source);
 assert.deepEqual(result,{first:6,total:10,tags:['section','button','br','span','a','aside','section','button','br','span'],ordinals:['1','2','3','4','5','6','7','8','9','10'],exactNative:true,mounted:'ChildFixed entryNext',deferred:'ChildFixed entry',empty:0,prevented:true});
 await writeFile(process.env.CLIENT_ROUTING_RESULTS,JSON.stringify(result,null,2)+'\n');console.log('entire fixed artifact/init/deferred/native site accounting PASS');
}finally{await browser.close();}
