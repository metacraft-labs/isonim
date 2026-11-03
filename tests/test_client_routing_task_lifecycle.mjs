// The complete production component, facade, reactive scheduler and real native
// DOM are exercised. Loopback serves an empty document only, replacing hosting.
// Forwarding spies retain actual receiver/argument/result/handler identities;
// they never allocate a substitute node, handler, context or ordinal.
import {chromium} from '../node_modules/playwright/index.mjs';
import {readFile,writeFile} from 'node:fs/promises';
import {createServer} from 'node:http';
import {readFileSync,statfsSync} from 'node:fs';
import assert from 'node:assert/strict';
const checks=[],observations={};
const check=(name,actual,expected)=>{checks.push({name,actual,expected});assert.deepEqual(actual,expected,'semantic: '+name);};
const server=createServer((req,res)=>res.end('<!doctype html><html><body></body></html>'));
await new Promise(resolve=>server.listen(0,'127.0.0.1',resolve));
let browser;
try {
 const disk=statfsSync(process.cwd()),mem=Number(/^MemAvailable:\s+(\d+)/m.exec(readFileSync('/proc/meminfo','utf8'))[1])*1024;
 const minimum=Math.max(8*1024**3,Number(process.env.ISONIM_TEST_MIN_AVAILABLE_BYTES||0));
 observations.admission={disk:disk.bavail*disk.bsize,MemAvailable:mem,minimum};
 assert.ok(Math.min(observations.admission.disk,mem)>=minimum,'BLOCKED: browser resource admission');
 browser=await chromium.launch({executablePath:process.env.PLAYWRIGHT_CHROMIUM_EXECUTABLE});
 observations.browser=browser.version();
 const page=await browser.newPage();const errors=[];page.on('pageerror',error=>errors.push(String(error)));
 await page.goto('http://127.0.0.1:'+server.address().port+'/');
 await page.addStyleTag({content:await readFile(new URL('../build/tailwind.css',import.meta.url),'utf8')});
 await page.evaluate(()=>{
  const nativeCreate=Document.prototype.createElement,nativeAdd=EventTarget.prototype.addEventListener,nativeRemove=EventTarget.prototype.removeEventListener;
  globalThis.witness={created:[],added:[],removed:[],checkpoints:[]};
  Document.prototype.createElement=function(...args){const result=Reflect.apply(nativeCreate,this,args);witness.created.push({receiver:this,args,result});return result;};
  EventTarget.prototype.addEventListener=function(...args){const result=Reflect.apply(nativeAdd,this,args);witness.added.push({receiver:this,args,result});return result;};
  EventTarget.prototype.removeEventListener=function(...args){const result=Reflect.apply(nativeRemove,this,args);witness.removed.push({receiver:this,args,result});return result;};
  globalThis.capture=label=>{
   const ordinals=witness.created.map(call=>brandedTaskApp.query(call.result));
   const reversed=[...witness.created].reverse().map(call=>brandedTaskApp.query(call.result));
   const native=witness.created.every(call=>call.receiver===document&&call.args.length===1&&call.args[0]===call.result.localName&&call.result instanceof HTMLElement);
   const value={label,count:witness.created.length,ordinals,reversed,native,detached:witness.created.filter(call=>!call.result.isConnected).map(call=>brandedTaskApp.query(call.result))};
   witness.checkpoints.push(value);return value;
  };
 });
 const source=await readFile(process.env.CLIENT_ROUTING_TASK_LIFECYCLE_BUNDLE,'utf8');await page.evaluate(source=>(0,eval)(source),source);
 await page.evaluate(()=>{globalThis.app=brandedTaskApp.open('first');});
 async function checkpoint(label){const row=await page.evaluate(label=>capture(label),label);observations[label]=row;check('native-'+label,row.native,true);check('nonempty-'+label,row.count>0,true);check('all-task-creates-have-ordinals',row.ordinals.every(value=>typeof value==='string'&&/^[1-9][0-9]*$/.test(value)),true);check('one-namespace-through-task-closures',row.ordinals,Array.from({length:row.count},(_,i)=>String(i+1)));check('production-query-is-required',row.reversed,[...row.ordinals].reverse());return row;}
 const initial=await checkpoint('initial');
 const root=page.locator('#first'),input=root.locator('input'),add=input.locator('..').locator(':scope > div');
 await input.fill('alpha');await add.click();
 const firstAdd=await checkpoint('first-keyed-row');check('deferred-creation-after-initial',firstAdd.count>initial.count,true);
 await page.evaluate(()=>{globalThis.alpha=[...app.root.querySelectorAll('span')].find(e=>e.textContent==='alpha').parentElement;globalThis.alphaOrd=brandedTaskApp.query(alpha);});
 await input.fill('beta');await add.click();
 check('keyed-retained-native-row',await page.evaluate(()=>alpha===[...app.root.querySelectorAll('span')].find(e=>e.textContent==='alpha').parentElement&&brandedTaskApp.query(alpha)===alphaOrd),true);
 await checkpoint('second-keyed-row');
 const row=text=>root.locator('span').filter({hasText:new RegExp('^'+text+'$')}).locator('..');
 await row('alpha').locator(':scope > div').first().click();
 const filter=name=>root.locator('div.rounded-2xl').filter({hasText:new RegExp('^'+name+'$')});
 await filter('Active').click();await checkpoint('filtered-detached-row');
 await filter('Completed').click();await filter('All').click();
 await row('beta').locator(':scope > div').last().click();
 await root.getByText('Clear Completed',{exact:true}).click();
 check('show-empty-restored',await root.getByText('No tasks yet.',{exact:false}).count(),1);
 const empty=await checkpoint('show-empty-again');check('removed-elements-retain-ordinals',empty.detached.length>0&&empty.detached.every(value=>value!==null),true);
 await page.evaluate(()=>{globalThis.second=brandedTaskApp.open('second');});
 const two=await checkpoint('copied-renderer-second-root');check('second-root-continues-namespace',two.count>empty.count,true);
 await input.fill('retained first');await add.click();
 await page.evaluate(()=>{
  globalThis.retainedAdd=app.root.querySelector('input').parentElement.children[1];globalThis.foreignCalls=0;
  retainedAdd.addEventListener('click',()=>foreignCalls++);
  globalThis.ownedAdd=witness.added.find(call=>call.receiver===retainedAdd&&call.args[0]==='click');
  app.dispose();globalThis.disposedMarkup=app.root.innerHTML;globalThis.disposedRenders=app.renders();
 });
 await input.fill('after disposal');await add.click();
 check('first-owner-cleanup',await page.evaluate(()=>JSON.parse(app.snapshot()).map(t=>t.text)),['retained first']);
 check('foreign-listener-retained',await page.evaluate(()=>foreignCalls),1);
 check('native-handler-removal-identity',await page.evaluate(()=>!!ownedAdd&&witness.removed.some(call=>call.receiver===ownedAdd.receiver&&call.args[0]===ownedAdd.args[0]&&call.args[1]===ownedAdd.args[1]&&call.result===undefined)),true);
 await page.evaluate(()=>app.add('mutable disposed store'));
 check('disposed-store-mutable',await page.evaluate(()=>JSON.parse(app.snapshot()).map(t=>t.text)),['retained first','mutable disposed store']);
 check('disposed-effects-stopped',await page.evaluate(()=>app.root.innerHTML===disposedMarkup&&app.renders()===disposedRenders),true);
 const second=page.locator('#second');await second.locator('input').fill('independent owner');await second.locator('input').locator('..').locator(':scope > div').click();
 check('second-owner-still-runs',await page.evaluate(()=>JSON.parse(second.snapshot()).map(t=>t.text)),['independent owner']);
 await page.evaluate(()=>{globalThis.third=brandedTaskApp.open('third');});
 await checkpoint('late-root-after-first-disposal');
 check('unexpected-page-errors',errors,[]);
} finally {if(browser)await browser.close();await new Promise(resolve=>server.close(resolve));await writeFile(process.env.CLIENT_ROUTING_TASK_LIFECYCLE_RESULTS,JSON.stringify({checks,observations},null,2)+'\n');}
console.log('PASS '+checks.length+' complete private task lifecycle assertions');
