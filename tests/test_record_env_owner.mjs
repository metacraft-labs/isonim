/** Actual compiled Nim -> immutable installed Recorder -> strict wire decoder.
 * Local HTTP serves the actual compiler output and native serialized SSR only;
 * it substitutes no environment, renderer, owner or codec. Browser observation
 * delegates call the original getters/methods with their original receiver.
 * Table inputs are typed validation data, not a hand-written projector.
 * Literal JSON is encoded before Playwright transport so prototype-named data
 * reaches the actual Nim parser without the protocol normalizing object keys.
 */
import assert from 'node:assert/strict';
import {readFileSync,writeFileSync} from 'node:fs';
import {createHash} from 'node:crypto';
import {createRequire} from 'node:module';
import {createServer} from 'node:http';
import {chromium} from './browser/node_modules/playwright/index.mjs';
const artifact=process.env.CT_ARTIFACT,receipt=process.env.RECORD_ENV_RECEIPT,selected=process.env.RECORD_ENV_CASE||'all';
assert(artifact&&receipt&&process.env.RECORD_ENV_BUNDLE,'actual artifact, compiled bundle and receipt required');
const req=createRequire(artifact+'/packages/boundary-shim/package.json');
const {build}=req('esbuild');
const built=await build({stdin:{resolveDir:artifact,contents:`
import {Recorder} from '@codetracer/boundary-shim/dist/browser/recorder.js';
import {decodeRecord} from '@codetracer/boundary-format';
${readFileSync(process.env.RECORD_ENV_BUNDLE,'utf8')}
globalThis.envTest={project:envProject,ownership:envOwnership,failureOwnership:envFailureOwnership,cached:envCached,cacheOwnership:envCacheOwnership,backendSnapshot:envBackendSnapshot,backendControl:envBackendControl,Recorder,decodeRecord};
`},bundle:true,platform:'browser',format:'iife',write:false,metafile:true});
writeFileSync(receipt+'-combined.js',built.outputFiles[0].text);writeFileSync(receipt+'-metafile.json',JSON.stringify(built.metafile,null,2));
const bundleInputs={};for(const path of Object.keys(built.metafile.inputs)){if(path!=='<stdin>')bundleInputs[path]=createHash('sha256').update(readFileSync(path)).digest('hex');}
const baseline={ua:'Chromium/123.4',browserMajor:"91",viewport:{width:801.9,height:603.4},dpr:1.25,language:'en-US',timeZone:'Europe/Paris',timezoneOffset:-60,colorScheme:1,prefersReducedMotion:true,url:'https://fixture.test/path?q=1#fragment',referrerOrigin:'https://source.test',traceparent:'00-12345678901234567890123456789012-1234567890123456-01',assignment:{checkout:0},buildId:'ignored',bootDateEpochMs:123,prefersDark:false};
const expected={ua:'Chromium/123.4',ua_major:123,viewport_w:801,viewport_h:603,dpr:1.25,locale:'en-US',tz:'Europe/Paris',fonts_digest:'',color_scheme:1,reduced_motion:1,arms:'{"checkout":"1"}',url:baseline.url,referrer_origin:baseline.referrerOrigin,traceparent:baseline.traceparent};
const resource={assign:{checkout:1},exposed:[{key:'checkout',arm:1,callSite:'fixture'}],day:'2026-11-04'};
const cases=[];const include=name=>selected==='all'||selected===name||selected.startsWith(name+'-');
function check(value,name){assert(value,'ENV_ASSERT: '+name);}
function equal(actual,wanted,name){assert.deepEqual(actual,wanted,'ENV_ASSERT: '+name);}
const result={selected,bundleInputs,cases};const persist=()=>writeFileSync(receipt,JSON.stringify(result,(_,v)=>typeof v==='bigint'?String(v):v,2));
const boot=built.outputFiles[0].text;
const scripts=process.env.RECORD_ENV_SSR?Object.fromEntries(['SSR','HYDRATE','PLAIN','SSR_EMPTY'].map(k=>[k,readFileSync(process.env['RECORD_ENV_'+k],'utf8')])):{};
const server=createServer((q,s)=>{const u=new URL(q.url,'http://localhost');if(u.pathname==='/boot.js'){s.setHeader('content-type','application/javascript');s.end(boot);return;}if(u.pathname==='/hydrate.js'){s.setHeader('content-type','application/javascript');s.end(u.searchParams.has('plain')?scripts.PLAIN:scripts.HYDRATE);return;}if(u.pathname==='/ssr'){const markup=u.searchParams.has('empty')?scripts.SSR_EMPTY:scripts.SSR;const split=markup.indexOf('<script>');s.setHeader('content-type','text/html');s.end('<!doctype html><div id="root">'+markup.slice(0,split)+'</div>'+markup.slice(split));return;}s.setHeader('content-type','text/html');s.end('<!doctype html><html><head><meta name="traceparent" content="frozen-trace"><script>globalThis._$HY={seed:1,assignment:{checkout:0},r:{}};</script><script src="/boot.js"></script></head><body>Actual ordinary env boot</body></html>');});
await new Promise(r=>server.listen(0,'127.0.0.1',r));const origin='http://127.0.0.1:'+server.address().port;
let browser;
try{
 browser=await chromium.launch({headless:true,executablePath:process.env.PLAYWRIGHT_CHROMIUM_EXECUTABLE});
 const page=await browser.newPage({viewport:{width:1001,height:701},colorScheme:'light',reducedMotion:'reduce',timezoneId:'Europe/Paris'});
 const pageErrors=[];page.on('pageerror',e=>pageErrors.push(String(e)));await page.goto(origin+'/?boot=original#anchor');equal(pageErrors,[],'actual-page-execution');
 async function project(input=baseline,exp=resource,special=''){
  const text=JSON.stringify(input),resourceText=exp==='nil'?'nil':JSON.stringify(exp);
  const actual=await page.evaluate(({text,resourceText,special})=>{const actual=envTest.project(text,resourceText,special);if(actual.value){const descriptors=Object.getOwnPropertyDescriptors(actual.value);actual.shape={plain:Object.getPrototypeOf(actual.value)===Object.prototype,keys:Object.keys(descriptors),ownData:Object.values(descriptors).every(d=>'value'in d&&d.enumerable&&d.writable&&d.configurable&&!('get'in d)&&!('set'in d))};}return actual;},{text,resourceText,special});
  if(actual.value){check(actual.shape.plain&&actual.shape.ownData,'actual-plain-own-data-output');equal([...actual.shape.keys].sort(),Object.keys(expected).sort(),'actual-exact-fourteen-own-fields');}
  if(!special&&exp!=='nil'&&input&&typeof input==='object'&&input.ua!==undefined&&(selected==='all'||selected==='own-key-order')){
   const echo=await page.evaluate(({text,resourceText})=>envTest.failureOwnership(text,resourceText),{text,resourceText});
   cases.push({name:'literal-typed-input-binding',text,resourceText,typedBefore:echo.before,typedAfter:echo.after});persist();
   equal(echo.before,echo.after,'actual-typed-input-unchanged');
   if(exp!=='nil'&&exp?.assign){const parsed=JSON.parse(echo.before.split('\n')[1]);equal(Object.keys(parsed.assign).sort(),Object.keys(exp.assign).sort(),'actual-typed-key-inventory');}
  }
  return actual;
 }
 async function decode(value,target=page){return target.evaluate(env=>{const frames=[],header={vocab:1,protocol_level:0,recorder_id:'test-only-cached-env',framework:'',build_hash:'a'.repeat(64),session_id:'1'.repeat(32),prev_session:'',capabilities:'[]'},r=new envTest.Recorder({checkpointScheme:'dom-v1',checkpointHash:()=>'',sink:{append:f=>frames.push(f),end:(_u,f)=>frames.push(f),halt(){}}});r.start(header,env);r.end(2);return frames.map(f=>envTest.decodeRecord(f.subarray(4)));},value);}
 async function valid(name,input,wanted,exp=resource,special=''){
  const actual=await project(input,exp,special);cases.push({name:name+'-typed-result',input,exp,special,actual});persist();check(!actual.error,name);const rows=await decode(actual.value);cases.push({name,rows});persist();equal(rows.map(x=>x.record),['Header','Env','End'],name);const {record,...fields}=rows[1];equal(fields,wanted,name);return fields;
 }
 async function error(name,input,exp,path,reason,special=''){
  const actual=await project(input,exp,special);cases.push({name,actual});persist();equal(actual,{error:{name:'ValueError',message:'internal Record Env: '+path+': '+reason}},name);
 }
 if(include('all-fields')){
  const name=selected.startsWith('all-fields-')?selected:'all-fields';await valid(name,baseline,expected);
 }
 if(include('ua-owner-match')){
  const observations=[];
  for(const [ua,major]of [['Chromium/00042',42],['Edg/77',0],['Chrome/12.3',12],['Firefox/65535',65535],['Version/123',123],['Chrome/65536',0],['Chrome/'+'9'.repeat(400),0],['Chrome/-1',0],['Chrome/1e3',1],['Version/0042 Chromium/5',42]]){
   const input={...baseline,ua,browserMajor:"91"},actual=await project(input);check(!actual.error,'ua-owner-match');const rows=await decode(actual.value);cases.push({name:'ua-owner-match',input,rows,wantedMajor:major});persist();equal(rows.map(x=>x.record),['Header','Env','End'],'ua-owner-match');observations.push({ua,actual:rows[1].ua_major,expected:major});
  }
  cases.push({name:'ua-owner-match-summary',observations});persist();check(observations.every(x=>x.actual===x.expected),'ua-owner-match');
 }
 if(include('viewport-boundaries')){
  for(const [value,out]of [[0,0],[-1,0],[-0,0],[1.9,1],[4294967295.9,4294967295],[4294967296,0],[-0.1,0]])await valid('viewport-boundaries',{...baseline,viewport:{width:value,height:value}},{...expected,viewport_w:out,viewport_h:out});
  for(const [special,patch]of [['nan-width',{viewport_w:0}],['inf-height',{viewport_h:0}],['huge-viewport',{viewport_w:0,viewport_h:0}]])await valid('viewport-boundaries',baseline,{...expected,...patch},resource,special);
  await error('viewport-boundaries',{...baseline,viewport:{width:'1',height:2}},resource,'cachedEnv.viewport.width','expected number');
  await error('viewport-boundaries',{...baseline,viewport:{width:1e100,height:2}},resource,'cachedEnv.viewport.width','expected number'); // stock parser deliberately preserves this unsafe raw integer as JString

 }
 if(include('finite-dpr')){
  for(const special of ['nan-dpr','inf-dpr','neginf-dpr'])await error('finite-dpr',baseline,resource,'cachedEnv.dpr','expected finite number',special);
  await valid('finite-dpr',baseline,{...expected,dpr:1e100},resource,'huge-dpr');
  await valid('finite-dpr',baseline,{...expected,viewport_w:0,viewport_h:0,dpr:-0},resource,'negative-zero');
  for(const dpr of [-1,0,0.5,2.75])await valid('finite-dpr',{...baseline,dpr},{...expected,dpr});
  await error('finite-dpr',{...baseline,dpr:null},resource,'cachedEnv.dpr','expected number');
 }
 if(include('preference-enums')){
  for(const colorScheme of [0,1,2])for(const prefersReducedMotion of [false,true])await valid('preference-enums',{...baseline,colorScheme,prefersReducedMotion},{...expected,color_scheme:colorScheme,reduced_motion:+prefersReducedMotion});
  for(const colorScheme of [-1,3,true,'1',null])await error('preference-enums',{...baseline,colorScheme},resource,'cachedEnv.colorScheme','expected integer 0..2');
  await error('preference-enums',baseline,resource,'cachedEnv.colorScheme','expected integer 0..2','float-color');
  await error('preference-enums',{...baseline,prefersReducedMotion:1},resource,'cachedEnv.prefersReducedMotion','expected boolean');
 }
 if(include('iana-same-offset')){
  const offsets=[],observations=[];
  for(const tz of ['Europe/Paris','Europe/Berlin']){
   const context=await browser.newContext({timezoneId:tz});const p=await context.newPage();await p.goto(origin);const cached=JSON.parse(await p.evaluate(()=>envTest.cached()));offsets.push(cached.timezoneOffset);equal(cached.timeZone,tz,'iana-same-offset');
   const actual=await p.evaluate(({text,resourceText})=>envTest.project(text,resourceText,''),{text:JSON.stringify(cached),resourceText:JSON.stringify(resource)});check(!actual.error,'iana-same-offset');const rows=await decode(actual.value,p);equal(rows.map(x=>x.record),['Header','Env','End'],'iana-same-offset');observations.push({tz,actual:rows[1].tz,offset:cached.timezoneOffset,rows});await context.close();
  }
  cases.push({name:'iana-same-offset-both-contexts',observations});persist();equal(offsets[0],offsets[1],'iana-same-offset');check(observations.every(x=>x.actual===x.tz),'iana-same-offset');await valid('iana-same-offset',{...baseline,timeZone:''},{...expected,tz:''});
 }
 if(include('flat-string-arms')){
  const actual=await project();check(!actual.error,'flat-string-arms');const rows=await decode(actual.value);cases.push({name:'flat-string-arms-parsed',rows,parsed:JSON.parse(rows[1].arms)});persist();equal(rows.map(x=>x.record),['Header','Env','End'],'flat-string-arms');equal(JSON.parse(rows[1].arms),{checkout:'1'},'flat-string-arms');equal(rows[1].arms,expected.arms,'flat-string-arms');for(const exp of [null,'nil',{assign:{}}])await valid('flat-string-arms',baseline,{...expected,arms:'{}'},exp);
  await valid('flat-string-arms',baseline,{...expected,arms:'{"checkout":"9007199254740991"}'},{assign:{checkout:9007199254740991}});
 }
 if(include('own-key-order')){
  const pairs=[['2',2],['10',1],['__proto__',3],['constructor',4],['toString',5],['a"\\\n',6],['\ue000',7],['😀',8],['A',0]];
  const ordered=[...pairs].sort(([a],[b])=>a<b?-1:a>b?1:0);const arms='{'+ordered.map(([k,v])=>JSON.stringify(k)+':'+JSON.stringify(String(v))).join(',')+'}';
  for(const entries of [pairs,[...pairs].reverse()]){const actual=await project(baseline,{assign:Object.fromEntries(entries)});check(!actual.error,'own-key-order');const rows=await decode(actual.value);cases.push({name:'own-key-order',rows});persist();equal(rows.map(x=>x.record),['Header','Env','End'],'own-key-order');const fields=rows[1],parsed=JSON.parse(fields.arms);const membership=pairs.map(([key,value])=>({key,own:Object.prototype.hasOwnProperty.call(parsed,key),actual:parsed[key],expected:String(value)}));cases.push({name:'own-key-order-membership',membership,actualBytes:fields.arms,expectedBytes:arms});persist();check(membership.every(x=>x.own&&x.actual===x.expected),'own-key-order');equal(fields.arms,arms,'own-key-order');}
  for(const key of ['a'.repeat(256),'😀'.repeat(128)])await valid('own-key-order',baseline,{...expected,arms:'{'+JSON.stringify(key)+':"1"}'},{assign:{[key]:1}});
  const sixtyfour=Object.fromEntries(Array.from({length:64},(_,i)=>['k'+String(i).padStart(2,'0'),i]));await valid('own-key-order',baseline,{...expected,arms:'{'+Object.entries(sixtyfour).map(([k,v])=>JSON.stringify(k)+':"'+v+'"').join(',')+'}'},{assign:sixtyfour});
 }
 if(include('malformed-arms-fail-closed')){
  const p='completedExperimentResource.assign';
  for(const exp of [1,'bad',[],true])await error('malformed-arms-fail-closed',baseline,exp,'completedExperimentResource','expected object or null');
  for(const exp of [{},{assign:null},{assign:[]},{assign:1}])await error('malformed-arms-fail-closed',baseline,exp,p,'expected object');
  for(const value of [-1,9007199254740992,true,'1',null,{}])await error('malformed-arms-fail-closed',baseline,{assign:{checkout:value}},p+'["checkout"]','expected nonnegative safe integer');
  await error('malformed-arms-fail-closed',baseline,resource,p+'["checkout"]','expected nonnegative safe integer','float-arm');
  await error('malformed-arms-fail-closed',baseline,resource,p+'["checkout"]','expected nonnegative safe integer','unsafe-arm');
  for(const key of ['', 'a'.repeat(257),'😀'.repeat(128)+'a'])await error('malformed-arms-fail-closed',baseline,{assign:{[key]:1}},p+'['+JSON.stringify(key)+']','key length must be 1..256 UTF-16 units');
  await error('malformed-arms-fail-closed',baseline,{assign:Object.fromEntries(Array.from({length:65},(_,i)=>['k'+i,0]))},p,'at most 64 entries');
  await error('malformed-arms-fail-closed',baseline,{assign:{z:'bad',a:'bad'}},p+'["a"]','expected nonnegative safe integer');
 }
 if(include('result-ownership')){
  const actual=await page.evaluate(({c,r})=>envTest.ownership(JSON.stringify(c),JSON.stringify(r)),{c:baseline,r:resource});cases.push({name:'result-ownership',actual});persist();equal(actual.before,actual.after,'result-ownership');equal(actual.second,expected,'result-ownership');equal(actual.third,expected,'result-ownership');equal(actual.first,{...expected,url:'mutated-result'},'result-ownership');
  const bad={assign:{a:1,z:'malformed'}};
  const failed=await page.evaluate(({c,r})=>envTest.failureOwnership(JSON.stringify(c),JSON.stringify(r)),{c:baseline,r:bad});cases.push({name:'failure-input-ownership',failed});persist();equal(failed.before,failed.after,'result-ownership');equal(failed.outcome,{error:{name:'ValueError',message:'internal Record Env: completedExperimentResource.assign["z"]: expected nonnegative safe integer'}},'result-ownership');
  const copy=JSON.parse(await page.evaluate(()=>envTest.cacheOwnership()));cases.push({name:'actual-cache-copy-ownership',copy});persist();equal(copy.before,copy.after,'result-ownership');equal(copy.second,copy.before,'result-ownership');
 }
 if(selected==='all'){
  const invalid=[['ua','expected string'],['viewport','expected object'],['dpr','expected number'],['language','expected string'],['timeZone','expected string'],['colorScheme','expected integer 0..2'],['prefersReducedMotion','expected boolean'],['url','expected string'],['referrerOrigin','expected string'],['traceparent','expected string']];
  for(const [key,reason]of invalid)for(const absent of [true,false]){const c={...baseline};if(absent)delete c[key];else c[key]=null;await error('validation-'+key,c,resource,'cachedEnv.'+key,reason);}
  await error('validation-priority',{ua:1,viewport:[],dpr:'x'},1,'cachedEnv.ua','expected string');await error('validation-root',null,resource,'cachedEnv','expected object');await error('validation-root-nil',baseline,resource,'cachedEnv','expected object','nil-cached');
  for(const c of [{...baseline,language:'',timeZone:'',traceparent:'',referrerOrigin:''}])await valid('empty-provenance',c,{...expected,locale:'',tz:'',traceparent:'',referrer_origin:''});
 }
 if(include('cached-world-isolation')){
  const before=JSON.parse(await page.evaluate(()=>envTest.cached()));
  await page.evaluate(()=>{globalThis.envOwnerRecords=0;const push=envTest.Recorder.prototype.push;envTest.Recorder.prototype.push=function(...args){envOwnerRecords++;return push.apply(this,args);};});
  await decode(expected);check(await page.evaluate(()=>envOwnerRecords>0),'cached-world-isolation');
  // Delegating accessors witness real reads; no sampled values are mocked.
  await page.evaluate(()=>{
   const counters={reads:0,dates:0,by:{}},scope=[];
   const note=name=>{counters.reads++;counters.by[name]=(counters.by[name]||0)+1;};
   globalThis.envObservations=counters;
   function getter(object,key,label){
    const d=Object.getOwnPropertyDescriptor(object,key);if(typeof d?.get!=='function'||!d.configurable)throw Error('actual configurable getter required: '+label);
    scope.push({label,configurable:d.configurable,nativeGetter:true});Object.defineProperty(object,key,{...d,get(){note(label);return d.get.call(this);}});
   }
   for(const key of ['innerWidth','innerHeight','devicePixelRatio'])getter(window,key,key);
   getter(Navigator.prototype,'userAgent','navigator.userAgent');getter(Navigator.prototype,'language','navigator.language');getter(Document.prototype,'referrer','document.referrer');
   const dtf=Intl.DateTimeFormat;Intl.DateTimeFormat=new Proxy(dtf,{apply(t,r,a){note('Intl.DateTimeFormat');return Reflect.apply(t,r,a);},construct(t,a,n){note('Intl.DateTimeFormat');return Reflect.construct(t,a,n);}});
   const hyDescriptor=Object.getOwnPropertyDescriptor(globalThis,'_$HY');if(!hyDescriptor?.configurable||!hyDescriptor.writable||!('value'in hyDescriptor))throw Error('actual writable HY data property required');let hy=hyDescriptor.value;
   Object.defineProperty(globalThis,'_$HY',{configurable:true,enumerable:hyDescriptor.enumerable,get(){note('HY');return hy;},set(value){hy=value;}});
   const media=window.matchMedia;window.matchMedia=function(...args){note('matchMedia');return media.apply(this,args);};
   const query=document.querySelector;document.querySelector=function(...args){note('document.querySelector');return query.apply(this,args);};
   const NativeDate=Date;globalThis.Date=new Proxy(NativeDate,{construct(t,a,n){note('Date.construct');counters.dates++;return Reflect.construct(t,a,n);},apply(t,r,a){note('Date.call');return Reflect.apply(t,r,a);},get(t,k,r){const value=Reflect.get(t,k,r);if(k==='now')return function(...args){note('Date.now');return Reflect.apply(value,t,args);};return value;}});
   const href=Object.getOwnPropertyDescriptor(location,'href'),windowLocation=Object.getOwnPropertyDescriptor(window,'location');
   globalThis.envObservationScope={delegated:scope,locationHref:{configurable:href?.configurable??null,nativeGetter:typeof href?.get==='function',wrapped:false},windowLocation:{configurable:windowLocation?.configurable??null,wrapped:false},urlProof:'actual mutated URL and strict decoded frozen URL; Location is never substituted'};
   void innerWidth;void innerHeight;void devicePixelRatio;void navigator.userAgent;void navigator.language;void document.referrer;Intl.DateTimeFormat().resolvedOptions();void globalThis._$HY;matchMedia('(prefers-color-scheme: light)');document.querySelector('meta[name=traceparent]');new Date();Date();Date.now();
   globalThis.envPositive={...counters,by:{...counters.by}};
  });
  const backendControl=await page.evaluate(()=>{globalThis.envBackendUnchanged=envTest.backendSnapshot();return {detectsChange:envTest.backendControl(),restored:envBackendUnchanged()};});check(backendControl.detectsChange&&backendControl.restored,'actual-backend-identity-positive-control');
  await page.setViewportSize({width:777,height:555});await page.emulateMedia({colorScheme:'dark',reducedMotion:'no-preference'});await page.evaluate(()=>{history.replaceState(null,'','/changed?after=1#new');document.querySelector('meta[name=traceparent]').content='changed-trace';globalThis._$HY.assignment={checkout:8};globalThis._$HY.r.$exp={assign:{checkout:9}};});
  const probe=await page.evaluate(({cached,resource})=>{const counts={...envObservations,by:{...envObservations.by},ownerRecords:envOwnerRecords};const first=envTest.project(JSON.stringify(cached),JSON.stringify(resource),'');const after={...envObservations,by:{...envObservations.by},ownerRecords:envOwnerRecords};const again=JSON.parse(envTest.cached());return {first,counts,after,again,positive:envPositive,scope:envObservationScope,backendUnchanged:envBackendUnchanged(),live:{width:innerWidth,height:innerHeight,url:location.href,dark:matchMedia('(prefers-color-scheme: dark)').matches}};},{cached:before,resource});
  cases.push({name:'cached-world-isolation',before,probe});persist();check(['innerWidth','innerHeight','devicePixelRatio','navigator.userAgent','navigator.language','document.referrer','Intl.DateTimeFormat','HY','matchMedia','document.querySelector','Date.construct','Date.call','Date.now'].every(name=>probe.positive.by[name]>0)&&probe.positive.dates>0,'cached-world-isolation');check(probe.backendUnchanged,'cached-world-isolation');equal(probe.again,before,'cached-world-isolation');check(probe.live.width!==before.viewport.width&&probe.live.url!==before.url&&probe.live.dark,'cached-world-isolation');check(!probe.first.error,'cached-world-isolation');const fields=probe.first.value;const rows=await decode(fields);probe.rows=rows;persist();equal(rows.map(x=>x.record),['Header','Env','End'],'cached-world-isolation');const actual={url:rows[1].url,viewport_w:rows[1].viewport_w,viewport_h:rows[1].viewport_h,color_scheme:rows[1].color_scheme,reduced_motion:rows[1].reduced_motion,traceparent:rows[1].traceparent};const wanted={url:before.url,viewport_w:before.viewport.width,viewport_h:before.viewport.height,color_scheme:before.colorScheme,reduced_motion:+before.prefersReducedMotion,traceparent:before.traceparent};probe.exactDecoded=JSON.stringify(actual)===JSON.stringify(wanted);probe.zeroObservationDelta=JSON.stringify(probe.counts)===JSON.stringify(probe.after);persist();check(probe.exactDecoded&&probe.zeroObservationDelta,'cached-world-isolation');
 }
 if(include('frozen-effective-arms')){
  for(const plain of [false,true]){const p=await browser.newPage();const errors=[];p.on('pageerror',e=>errors.push(String(e)));await p.goto(origin+'/ssr');const frozen=await p.evaluate(()=>JSON.parse(JSON.stringify(globalThis._$HY.r.$exp)));equal(frozen.assign,{checkout:1},'frozen-effective-arms');equal(frozen.exposed.map(x=>[x.key,x.arm]),[['checkout',1]],'frozen-effective-arms');await p.addScriptTag({content:boot});const frozenCached=JSON.parse(await p.evaluate(()=>envTest.cached()));await p.addScriptTag({url:origin+'/hydrate.js'+(plain?'?plain':'')});equal(errors,[],'actual-hydration-execution');const state=await p.evaluate(()=>({mismatches:isonimHy.mismatches,text:document.querySelector('#root').textContent,resource:envClientResource}));cases.push({name:'frozen-effective-arms',plain,frozen,state});persist();if(plain)check(state.mismatches>0&&state.text.trim()==='Control','plain-hydrate-mismatch');else{equal(state.mismatches,0,'frozen-effective-arms');equal(state.text.trim(),'Variant','frozen-effective-arms');equal(state.resource,frozen,'frozen-effective-arms');}
  await p.evaluate(()=>{envMutateExperimentHost();globalThis._$HY.assignment={checkout:7};globalThis._$HY.r.$exp.assign.checkout=8;globalThis._$HY.r.$exp.exposed=[];});
  const projected=await p.evaluate(({c,r})=>envTest.project(JSON.stringify(c),JSON.stringify(r),''),{c:frozenCached,r:frozen});check(!projected.error,'frozen-effective-arms');const rows=await decode(projected.value,p);cases.push({name:'frozen-effective-arms-actual-resource',plain,frozen,rows});persist();equal(rows.map(x=>x.record),['Header','Env','End'],'frozen-effective-arms');equal(rows[1].arms,'{"checkout":"1"}','frozen-effective-arms');equal(frozen.assign,{checkout:1},'frozen-effective-arms');await p.close();}
  const frozen=JSON.parse(JSON.stringify(resource));const c={...baseline,assignment:{checkout:0}};await page.evaluate(()=>{globalThis._$HY.assignment={checkout:7};globalThis._$HY.r.$exp={assign:{checkout:8},exposed:[]};});await valid('frozen-effective-arms',c,expected,frozen);
  // Actual no-resource hydrate uses control without a fabricated enrollment.
  const p=await browser.newPage();await p.goto(origin+'/ssr?empty');check(await p.evaluate(()=>!Object.hasOwn(globalThis._$HY.r,'$exp')),'frozen-effective-arms');await p.addScriptTag({content:boot});const cachedText=await p.evaluate(()=>envTest.cached());await p.addScriptTag({content:scripts.HYDRATE});equal(await p.evaluate(()=>({text:document.querySelector('#root').textContent.trim(),mismatches:isonimHy.mismatches})),{text:'Control',mismatches:0},'frozen-effective-arms');const emptyProjection=await p.evaluate(text=>envTest.project(text,'null',''),cachedText);check(!emptyProjection.error,'frozen-effective-arms');const rows=await decode(emptyProjection.value,p);cases.push({name:'actual-no-resource-ssr-hydrate-project',rows});persist();equal(rows.map(x=>x.record),['Header','Env','End'],'frozen-effective-arms');equal(rows[1].arms,'{}','frozen-effective-arms');await p.close();
 }
 await page.close();persist();console.log('Record Env '+selected+' PASS');
}finally{persist();await browser?.close();await new Promise(r=>server.close(r));}
