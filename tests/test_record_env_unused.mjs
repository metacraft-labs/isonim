/** Import-only probes use the real generated module in VM and real Chromium.
 * Getter delegates preserve actual browser behavior; forbidden VM accessors
 * deliberately fail on observation instead of supplying fake environment data.
 */
import assert from 'node:assert/strict';
import {readFileSync,writeFileSync} from 'node:fs';
import vm from 'node:vm';
import {chromium} from './browser/node_modules/playwright/index.mjs';
const sources=process.argv.slice(2).map(p=>[p,readFileSync(p,'utf8')]);
for(const [path,source]of sources){
 assert(!/@codetracer|projectInternalRecordEnv|currentClock|currentBackendHook|isonimDirect/.test(source),'ENV_IMPORT_ASSERT: absent API, owner and backend '+path);
 const context={console};for(const name of ['window','document','Date','Intl','require'])Object.defineProperty(context,name,{get(){throw Error('ENV_IMPORT_ASSERT: import observed '+name);}});
 vm.runInNewContext(source,context);
}
const browser=await chromium.launch({headless:true,executablePath:process.env.PLAYWRIGHT_CHROMIUM_EXECUTABLE});
const rows=[];
try{
 for(const [path,source]of sources){
  const page=await browser.newPage();await page.goto('about:blank');
  await page.evaluate(()=>{globalThis.importReads=0;const Date0=Date;globalThis.Date=new Proxy(Date0,{construct(t,a,n){importReads++;return Reflect.construct(t,a,n);}});const media=matchMedia;window.matchMedia=function(...args){importReads++;return media.apply(this,args);};new Date();matchMedia('(prefers-color-scheme: dark)');globalThis.importPositive=importReads;});
  const before=await page.evaluate(()=>importReads);assert(before>=2,'ENV_IMPORT_ASSERT: actual positive observation controls');
  await page.addScriptTag({content:source});const after=await page.evaluate(()=>importReads);assert.equal(after,before,'ENV_IMPORT_ASSERT: enabled-unused real-browser observation');rows.push({path,before,after});await page.close();
 }
}finally{await browser.close();}
writeFileSync(process.env.RECORD_ENV_UNUSED_RECEIPT,JSON.stringify(rows,null,2));
console.log('Record Env omission and enabled-unused import PASS');
