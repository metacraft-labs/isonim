// Native DOM/event semantics; a blank browser document needs no hosting stub.
import {chromium} from './browser/node_modules/playwright/index.mjs';
import {readFile,writeFile} from 'node:fs/promises';
import assert from 'node:assert/strict';
const browser=await chromium.launch({executablePath:process.env.PLAYWRIGHT_CHROMIUM_EXECUTABLE});
try {
 const page=await browser.newPage();await page.setContent('<!doctype html><body></body>');
 await page.addScriptTag({content:await readFile(process.env.CLIENT_ROUTING_BUNDLE,'utf8')});
 const row=await page.evaluate(noMeter=>{
  const checks=[];function check(ok,label){checks.push({ok,label});if(!ok)throw Error('semantic: '+label);}
  const api=linkControls;api.reset();const append=Node.prototype.appendChild,prevent=Event.prototype.preventDefault;
  const nativeAppend=[],events=[];
  Node.prototype.appendChild=function(...args){const result=Reflect.apply(append,this,args);nativeAppend.push({receiver:this,args,result});return result;};
  Event.prototype.preventDefault=function(...args){events.push({event:this,current:this.currentTarget,target:this.target,args});return Reflect.apply(prevent,this,args);};
  try {
   const host=document.createElement('nav'),m=api.appends();api.links(host,'same#key%',false);const a=host.firstElementChild;
   check(api.arguments().join(',')==='1,1,1,1','private-Link-arguments-evaluated-once');
   check(a instanceof HTMLAnchorElement&&a.textContent==='Next'&&a.getAttribute('href')==='/next','real-projected-anchor');
   const tail=nativeAppend.filter(x=>x.receiver===host);check(tail.length===1&&tail[0].args.length===1&&tail[0].args[0]===a&&tail[0].result===a,'direct-single-native-append');
   check(api.appends()===m+(noMeter?0:1),'Link-tail-does-not-add-renderer-meter');
   const event=new MouseEvent('click',{bubbles:true,cancelable:true});a.dispatchEvent(event);
   check(events.length===1&&events[0].event===event&&events[0].current===a&&events[0].target===a&&events[0].args.length===0&&event.defaultPrevented,'original-native-event-and-currentTarget');
   const ordinary=document.createElement('nav');api.links(ordinary,'same#key%',true);
   check(api.arguments().join(',')==='1,2,2,2','ordinary-Link-arguments-evaluated-once');
   check(a.getAttribute('data-iid')===ordinary.firstElementChild.getAttribute('data-iid')&&a.getAttribute('data-iid').includes('#same%23key%25'),'public-private-same-source-IID-key-and-call-scope');
   const other=document.createElement('nav');api.links(other,'other',false);check(a.getAttribute('data-iid')!==other.firstElementChild.getAttribute('data-iid'),'different-keys-retain-distinct-IIDs');
   check(api.query(a)==='1'&&api.query(other.firstElementChild)==='2','Link-namespace-position-includes-keyed-copies');
   const reactive=document.createElement('div'),control=api.reactive(reactive);
   check(reactive.children.length===1&&reactive.textContent==='0'&&api.query(reactive.firstElementChild)==='3','actual-initial-reactive-facade');
   control.advance();check(reactive.children.length===2&&reactive.textContent==='01'&&api.query(reactive.lastElementChild)==='4','same-context-through-reactive-callback');
   control.dispose();control.advance();check(control.value()===2&&reactive.children.length===2,'disposed-owner-does-not-create-after-real-signal-change');
   return {ok:true,checks};
  }catch(e){return {ok:false,checks,error:String(e)};}finally{Node.prototype.appendChild=append;Event.prototype.preventDefault=prevent;}
 },process.env.CLIENT_NO_METER==='1');
 await writeFile(process.env.CLIENT_ROUTING_RESULTS,JSON.stringify(row,null,2)+'\n');assert.equal(row.ok,true,row.error);console.log('Link source/native/keys/reactive controls PASS');
}finally{await browser.close();}
