/** Import-only controls execute real generated code in VM and native Chromium.
 * VM getter traps fail on an unintended observation, never supply fake values.
 * Browser delegates preserve the original Date/media/add/remove functions;
 * compare enabled-unused with the genuine define-absent module's existing boot.
 */
import assert from 'node:assert/strict';import {readFileSync,writeFileSync} from 'node:fs';import vm from 'node:vm';
import {chromium} from './browser/node_modules/playwright/index.mjs';
const files=process.argv.slice(2),sources=files.map(p=>readFileSync(p,'utf8'));assert.equal(files.length,2);
assert(!/observerFree|claimObserver|releaseObserver|isonimListenerInstallation/.test(sources[0]),'OBSERVER_OMIT: define-absent implementation omitted');
for(const source of sources){assert(!/claimInternalListenerObserver|releaseInternalListenerObserver|@codetracer|__ctBoundaryProtocol/.test(source),'OBSERVER_OMIT: unused API/owner omitted');const context={console};for(const name of ['Date','Intl','performance','document','require'])Object.defineProperty(context,name,{get(){throw Error('OBSERVER_OMIT: unintended VM '+name);}});vm.runInNewContext(source,context);assert.equal(context.observerUnusedLoaded,true);}
const browser=await chromium.launch({headless:true,executablePath:process.env.PLAYWRIGHT_CHROMIUM_EXECUTABLE});const rows=[];
try{assert.equal(browser.version(),'147.0.7727.15');for(let i=0;i<2;i++){
 const page=await browser.newPage();await page.goto('about:blank');await page.evaluate(()=>{globalThis.unusedCounts={date:0,media:0,add:0,remove:0};const D=Date;globalThis.Date=new Proxy(D,{construct(t,a,n){unusedCounts.date++;return Reflect.construct(t,a,n);},apply(t,r,a){unusedCounts.date++;return Reflect.apply(t,r,a);}});const media=matchMedia;window.matchMedia=function(...a){unusedCounts.media++;return media.apply(this,a);};for(const k of ['addEventListener','removeEventListener']){const original=EventTarget.prototype[k];EventTarget.prototype[k]=function(...args){unusedCounts[k==='addEventListener'?'add':'remove']++;return original.apply(this,args);};}const n=new EventTarget(),f=()=>{};n.addEventListener('witness',f);n.removeEventListener('witness',f);new Date();matchMedia('(prefers-color-scheme: dark)');if(Object.values(unusedCounts).some(n=>n<1))throw Error('OBSERVER_OMIT: positive controls');for(const k of Object.keys(unusedCounts))unusedCounts[k]=0;});
 await page.evaluate(source=>(0,eval)(source),sources[i]);rows.push(await page.evaluate(()=>({counts:unusedCounts,loaded:observerUnusedLoaded,ct:typeof __ctBoundaryProtocol,observerExports:typeof observerClaim})));await page.close();
}assert.deepEqual(rows[1],rows[0],'OBSERVER_OMIT: enabled-unused adds no observers/backend effects');assert.equal(rows[0].counts.add,0);assert.equal(rows[0].counts.remove,0);assert.equal(rows[0].ct,'undefined');assert.equal(rows[0].observerExports,'undefined');}finally{await browser.close();}
writeFileSync(process.env.OBSERVER_UNUSED_RECEIPT,JSON.stringify(rows,null,2));console.log('observer absence and enabled-unused PASS');
