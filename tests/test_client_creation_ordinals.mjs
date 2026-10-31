// Real SSR, production hydration and Chromium DOM. The loopback origin is the
// sole hosting replacement; no substitute DOM, renderer or ordinal allocator.
import {chromium} from './browser/node_modules/playwright/index.mjs';
import {createServer} from 'node:http';
import {readFile,writeFile} from 'node:fs/promises';
import assert from 'node:assert/strict';
const script=await readFile(process.env.CLIENT_ORDINALS_BUNDLE);
const markup=await readFile(process.env.CLIENT_ORDINALS_SSR,'utf8');
const server=createServer((req,res)=>{res.setHeader('Content-Type',req.url==='/app.js'?'text/javascript':'text/html');res.end(req.url==='/app.js'?script:markup);});
await new Promise(r=>server.listen(0,'127.0.0.1',r));
let browser;const results=[];
try {
 browser=await chromium.launch({executablePath:process.env.PLAYWRIGHT_CHROMIUM_EXECUTABLE});
 const names=['creation-order-before-lookup','created-element-has-ordinal','fresh-adopted-element-has-no-ordinal','native-failure-does-not-consume','production-query-is-required','lifetime-and-contexts','mismatch-and-public','bigint-and-reentry'];
 const selection=process.env.CLIENT_ORDINALS_CASE;
 assert.ok(!selection||names.includes(selection),'unknown required scenario fails loudly');
 const scenarios=selection?[selection]:names;
 assert.equal(scenarios.length,selection?1:8);
 for(const name of scenarios){
  const page=await browser.newPage();const errors=[];page.on('pageerror',e=>errors.push(String(e)));
  await page.addInitScript(v=>{globalThis.CLIENT_NO_METER=v;},process.env.CLIENT_NO_METER==='1');
  await page.goto(`http://127.0.0.1:${server.address().port}/`);await page.addScriptTag({url:'/app.js'});
  const row=await page.evaluate(name=>{
   const checks=[];const check=(ok,label)=>{checks.push({label,ok});if(!ok)throw Error('semantic: '+label);};
   const api=globalThis.cc,c=api.context();api.meter(true);
   const native=document.createElement, calls=[];let lastError;
   document.createElement=function(...args){
    const before=api.count();
    try{const result=Reflect.apply(native,this,args);calls.push({receiver:this,args,result,before});return result;}
    catch(error){lastError=error;calls.push({receiver:this,args,error,before});throw error;}
   };
   let targetCalls=0;
   let counting=true;const expectedMeter=n=>globalThis.CLIENT_NO_METER||!counting?0:n;
   function make(tag,ctx=c,ordinary=false){
    const start=calls.length,m=api.count();const e=ordinary?api.publicCreate(tag):api.create(ctx,tag);
    const rows=calls.slice(start);targetCalls+=rows.length;
    check(rows.length===1&&rows[0].receiver===document&&rows[0].args.length===1&&rows[0].args[0]===tag&&rows[0].result===e,'exact-native-creation');
    check(rows[0].before===m+expectedMeter(1)&&api.count()===m+expectedMeter(1),'meter-precedes-native');return e;
   }
   const queryWitnesses=[];
   const query=(e,ctx=c)=>{
    const n=calls.length,m=api.count(),clock=api.clock(),reads=[],restores=[],get=WeakMap.prototype.get;
    WeakMap.prototype.get=function(...args){const value=Reflect.apply(get,this,args);reads.push({receiver:this,args,value});return value;};
    const work=[];
    for(const [obj,key] of [[Date,'now'],[performance,'now'],[globalThis,'setTimeout'],[globalThis,'setInterval'],[globalThis,'requestAnimationFrame'],[globalThis,'__isonimValidateIids']]){
     if(typeof obj[key]!=='function')continue;
     const fn=obj[key],descriptor=Object.getOwnPropertyDescriptor(obj,key);obj[key]=function(...args){work.push(key);return Reflect.apply(fn,this,args);};restores.push(()=>{if(descriptor)Object.defineProperty(obj,key,descriptor);else delete obj[key];});
    }
    const protocol=globalThis.__ctBoundaryProtocol;let v;
    try{v=api.query(ctx,e);}finally{WeakMap.prototype.get=get;for(const restore of restores)restore();}
    check(calls.length===n&&api.count()===m&&api.clock()===clock&&work.length===0&&globalThis.__ctBoundaryProtocol===protocol,'query-has-no-native-meter-timer-clock-IID-wire-work');
    queryWitnesses.push({reads,e,ctx,v});return v;
   };
   try{
    if(name==='creation-order-before-lookup'){
     const a=make('article');api.text('between');const b=make('aside'),d=make('footer');
     for(const e of [d,b,a])api.handler(e);
     for(const e of [d,b,a])e.dispatchEvent(new Event('click'));
     check(ccHandlerCalls===3,'actual-reverse-handlers');
     const ds=query(d),bs=query(b),as=query(a);
     check(ds==='3'&&bs==='2'&&as==='1',name);
     for(const [e,v] of [[a,'1'],[b,'2'],[d,'3']]){e.setAttribute('data-iid','later-'+v);check(query(e)===v,'later-iid-retains-creation-order');}
    }else if(name==='created-element-has-ordinal'||name==='production-query-is-required'){
     const e=make('div');check(e instanceof Element&&e.localName==='div','real-native-node-before-query');check(query(e)==='1',name);
    }else if(name==='fresh-adopted-element-has-no-ordinal'){
     const root=document.getElementById('root'),saved=root.firstElementChild;const n=calls.length,m=api.count();const got=api.hydrate(c,root,'section');
     check(got===saved&&got.isConnected&&calls.length===n&&api.count()===m+expectedMeter(1),'real-fresh-SSR-adoption-identity');check(query(got)===null,name);
     check(query(make('nav'))==='1','SSR-adoption-does-not-consume');
    }else if(name==='native-failure-does-not-consume'){
     const n=calls.length,m=api.count();let caught;try{api.create(c,'invalid tag');}catch(e){caught=e;}
     targetCalls+=calls.length-n;
     check(caught===lastError&&caught instanceof DOMException&&caught.name==='InvalidCharacterError'&&calls.length===n+1&&calls.at(-1).receiver===document&&calls.at(-1).args[0]==='invalid tag'&&api.count()===m+expectedMeter(1),'exact-native-error-identity');
     const e=make('p');check(query(e)==='1',name);
    }else if(name==='lifetime-and-contexts'){
     const e=make('section');check(query(e)==='1','first-retained-ordinal');document.body.append(e);e.remove();check(query(e)==='1','removed-retained-ordinal');
     const c2=api.context();check(query(e,c2)===null,'separate-context-unknown');const fresh=make('section',c2);check(query(fresh,c2)==='1'&&query(fresh)===null,'independent-namespace');
     const root=document.getElementById('root'),hk=root.firstElementChild.getAttribute('data-hk');root.replaceChildren(e);e.setAttribute('data-hk',hk);const n=calls.length;const got=api.hydrate(c,root,'section');check(got===e&&calls.length===n,'real-re-adoption-same-numbered-node');check(query(got)==='1','re-adoption-preserves-ordinal');check(query(make('aside'))==='2','re-adoption-does-not-consume');
     const foreign=Reflect.apply(native,document,['b']);check(query(foreign)===null,'unknown-native-element');
    }else if(name==='mismatch-and-public'){
     const root=document.getElementById('root'),old=root.firstElementChild,n=calls.length,m=api.count();const e=api.hydrate(c,root,'article');targetCalls+=calls.length-n;
     check(e!==old&&e.localName==='article'&&e.isConnected&&calls.length===n+1&&calls.at(-1).result===e&&calls.at(-1).receiver===document&&calls.at(-1).args[0]==='article'&&calls.at(-1).before===m+expectedMeter(1)&&_$HY.mismatches===1,'real-hydration-mismatch-native-fallback');check(query(e)==='1','mismatch-created-node-numbered');
     check(query(make('div',c,true))===null,'ordinary-public-not-numbered');api.meter(false);counting=false;const off=make('em');check(api.count()===0&&query(off)==='2','meter-disabled-real-creation');
    }else if(name==='bigint-and-reentry'){
     c.next=9007199254740992n;const a=make('b'),b=make('i');check(query(a)==='9007199254740992'&&query(b)==='9007199254740993'&&c.next===9007199254740994n,'production-bigint-beyond-Number');
     const nested=api.context();let inner;customElements.define('ordinal-nested',class extends HTMLElement{constructor(){super();inner=api.create(nested,'span');}});
     const n=calls.length,m=api.count();const outer=api.create(nested,'ordinal-nested');targetCalls+=calls.length-n;check(calls.length===n+2&&calls[n].result===inner&&calls[n+1].result===outer&&calls[n].receiver===document&&calls[n+1].receiver===document&&api.count()===m+expectedMeter(2),'actual-custom-element-nested-creation');check(query(inner,nested)==='1'&&query(outer,nested)==='2','read-next-after-native-completes');
     check(Object.keys(c).sort().join(',')==='next,ordinals'&&c.ordinals instanceof WeakMap&&typeof c.next==='bigint','only-weak-forward-metadata');
    }
    for(const q of queryWitnesses)check(q.reads.length===1&&q.reads[0].receiver===q.ctx.ordinals&&q.reads[0].args.length===1&&q.reads[0].args[0]===q.e&&(q.reads[0].value===undefined?q.v===null:q.v===q.reads[0].value.toString(10)),'actual-production-WeakMap-get-forwarding');
    check(targetCalls===calls.length,'exact-target-native-call-accounting');return {name,checks,targetCalls,ok:true};
   }catch(e){return {name,checks,targetCalls,ok:false,error:String(e)};}finally{document.createElement=native;}
  },name);
  results.push(row);await page.close();assert.deepEqual(errors,[]);assert.equal(row.ok,true,row.error);
 }
 assert.equal(results.length,selection?1:8,'all required scenarios executed');
 console.log('actual renderer client creation ordinals PASS: '+results.length+' scenarios');
}finally{await writeFile(process.env.CLIENT_ORDINALS_RESULTS,JSON.stringify(results,null,2)+'\n');await browser?.close();await new Promise(r=>server.close(r));}
