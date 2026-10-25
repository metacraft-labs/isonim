// Real SSR/Chromium benchmark. The local server serves genuine compiled apps;
// there is no mocked renderer, event handler, clock, recorder or transport.
import assert from 'node:assert/strict';
import {createServer} from 'node:http';
import {openSync, closeSync, ftruncateSync, readFileSync, writeSync} from 'node:fs';
import {createHash} from 'node:crypto';
import {execFileSync} from 'node:child_process';
import {cpus, hostname, loadavg, release} from 'node:os';
import {resolve} from 'node:path';
import {pathToFileURL} from 'node:url';

export const protocol = Object.freeze({pairs:30, cycles:1000, eventsPerCycle:43,
  warmups:3, warmupCycles:100, bootstrap:10000, seed:20261025,
  recorderBudgetUs:10, maximumNoiseUs:1, controlPairs:3, controlCycles:100,
  slowdownUs:50});
export const median = a => {
  assert(a.length > 0 && a.every(Number.isFinite), 'invalid samples');
  const s=[...a].sort((x,y)=>x-y), m=Math.floor(s.length/2);
  return s.length%2 ? s[m] : (s[m-1]+s[m])/2;
};
export function interval(samples) {
  let state=protocol.seed;
  const random=()=>{state=(Math.imul(state,1664525)+1013904223)>>>0; return state/4294967296;};
  const medians=Array.from({length:protocol.bootstrap},()=>median(samples.map(()=>samples[Math.floor(random()*samples.length)]))).sort((a,b)=>a-b);
  return [medians[249],medians[9749]];
}
export function noiseBand(differences, quantumMs) {
  assert(Number.isFinite(quantumMs) && quantumMs>0, 'invalid clock quantum');
  const sorted=differences.map(Math.abs).sort((a,b)=>a-b);
  assert(sorted.length===protocol.pairs && sorted.every(Number.isFinite), 'invalid calibration');
  const band=Math.max(sorted[Math.ceil(.95*sorted.length)-1],
    2*quantumMs*1000/(protocol.cycles*protocol.eventsPerCycle));
  assert(band>0 && band<=protocol.maximumNoiseUs, 'environmental noise exceeds predeclared precision ceiling');
  return band;
}
export function qualify(differences, band) {
  assert(Number.isFinite(band) && band>0 && band<=protocol.maximumNoiseUs, 'invalid noise band');
  const ci=interval(differences);
  return {medianDifferenceUs:median(differences), intervalUs:ci,
    withinNoise:ci[0]>=-band && ci[1]<=band,
    withinRecorderBudget:ci[1]<=protocol.recorderBudgetUs};
}
const sha = path => createHash('sha256').update(readFileSync(path)).digest('hex');

export async function benchmark({root, playwright, executable, output, controlsCalibration}) {
  let receiptFd;
  try {receiptFd=openSync(output,'wx');}
  catch(error) {if(error.code==='EEXIST') throw new Error('receipt already exists: preserve every attempt');throw error;}
  const receipt={protocol, harnessSha256:sha(new URL(import.meta.url)), calibration:[],comparison:[],controls:[]};
  const save=()=>{const bytes=JSON.stringify(receipt,null,2)+'\n';ftruncateSync(receiptFd,0);writeSync(receiptFd,bytes,0,'utf8');};
  let browser,server;
  try {
  save();
  const provenance=JSON.parse(readFileSync(resolve(root,'provenance.json'),'utf8'));
  // Fail before launching a browser on absent or mismatched app artifacts.
  for (const arm of ['m5','current']) for (const [file,key] of [['index.html','html_sha256'],['app.js','js_sha256'],['ssr','ssr_sha256']]) {
    assert.equal(sha(resolve(root,arm,file)),provenance[arm][key], 'artifact provenance mismatch');
  }
  const {chromium}=await import(pathToFileURL(resolve(playwright)).href);
  const browserHash=sha(executable); // Missing browser fails before opening a server.
  const before=loadavg();
  server=createServer((req,res)=>{
    const match=/^\/(m5|current)\/(index\.html|app\.js)$/.exec(req.url);
    if (!match) {res.writeHead(404).end(); return;}
    res.setHeader('Content-Type',match[2].endsWith('.js')?'text/javascript':'text/html');
    res.end(readFileSync(resolve(root,match[1],match[2])));
  });
  await new Promise(done=>server.listen(0,'127.0.0.1',done));
  Object.assign(receipt,{provenance,
    host:{hostname:hostname(), kernel:release(), cpus:cpus().length, loadBefore:before},
    browser:{executable, sha256:browserHash}, calibration:[], comparison:[], controls:[]});
    browser=await chromium.launch({headless:true, executablePath:executable, args:['--no-sandbox']});
    receipt.browser.version=browser.version();
    const browserSession=await browser.newBrowserCDPSession();
    const commandLine=await browserSession.send('Browser.getBrowserCommandLine');
    receipt.browser.commandLine=commandLine.arguments;
    receipt.browser.engine=commandLine.arguments[0];
    receipt.browser.engineSha256=sha(receipt.browser.engine);
    async function sample(arm, cycles=protocol.cycles, slowdown=0, mutation='') {
      const page=await browser.newPage();
      const errors=[];
      page.on('pageerror', e=>errors.push(e.message));
      try {
        await page.addInitScript(({mutation,slowdown})=>{
          globalThis.overheadMicrotaskCalls=0;
          globalThis.overheadHandlers=[];
          let removed=false;
          const add=EventTarget.prototype.addEventListener;
          EventTarget.prototype.addEventListener=function(type,handler,options) {
            if (this instanceof Element) globalThis.overheadHandlers.push({target:this,type});
            // Remove a genuine app registration while leaving observation
            // metadata intact: only independently checked app calls catch it.
            if(mutation==='delete-handler' && this instanceof Element && !removed) {
              removed=true;return;
            }
            if(this instanceof Element && slowdown) {
              const original=handler;
              handler=function(...args) {
                const work=()=>{const until=performance.now()+slowdown/1000;while(performance.now()<until){};};
                if(mutation==='microtask-slowdown')queueMicrotask(()=>{work();globalThis.overheadMicrotaskCalls++;});
                else work();
                return typeof original==='function'?original.apply(this,args):original.handleEvent.apply(original,args);
              };
            }
            return add.call(this,type,handler,options);
          };
        },{mutation,slowdown});
        await page.goto(`http://127.0.0.1:${server.address().port}/${arm}/index.html`);
        await page.waitForFunction(()=>typeof taskOverheadCalls==='function');
        const result=await page.evaluate(async ({cycles,slowdown,mutation,warmups,warmupCycles})=>{
          const check=(ok,why)=>{if(!ok)throw new Error(why);};
          check(document.querySelectorAll('input,button,form').length===44,'44 controls required');
          if(mutation==='zero-ssr')overheadSsrNodes=[];
          if(mutation==='truncated-ssr')overheadSsrNodes=overheadSsrNodes.slice(1);
          const controls=[...document.querySelectorAll('input,button,form')];
          check(overheadSsrNodes.length===44,'44 captured SSR nodes required');
          check(overheadSsrNodes.every((node,i)=>node===controls[i] && node.isConnected),'SSR nodes not retained');
          check(globalThis._$HY.mismatches===0,'hydration mismatch');
          let handlers=overheadHandlers;
          check(handlers.length===43,'43 handlers required');
          check(new Set(handlers.map(h=>h.target)).size===43,'duplicate handler target');
          check(handlers.filter(h=>h.type==='submit').length===1 && handlers.filter(h=>h.type==='click').length===42,'event plan mismatch');
          handlers=[...handlers].sort((a,b)=>a.target===b.target?0:
            a.target.compareDocumentPosition(b.target)&Node.DOCUMENT_POSITION_FOLLOWING?-1:1);
          const events=handlers.map(({type})=>{const event=new Event(type,{bubbles:true,cancelable:true});event.preventDefault();return event;});
          const channel=new MessageChannel();
          let continuation;
          channel.port1.onmessage=()=>continuation();
          const settle=()=>new Promise(done=>{continuation=done;channel.port2.postMessage(null);});
          let quantum=Infinity, previous=performance.now();
          for(let i=0;i<100000;i++){const now=performance.now();if(now>previous)quantum=Math.min(quantum,now-previous);previous=now;}
          if(mutation==='invalid-clock') quantum=0;
          check(Number.isFinite(quantum)&&quantum>0,'invalid clock quantum');
          async function batch(count) {
            const startCalls=taskOverheadCalls(), startMicrotasks=overheadMicrotaskCalls, started=performance.now();
            for(let cycle=0;cycle<count;cycle++) for(let i=0;i<handlers.length;i++) {
              handlers[i].target.dispatchEvent(events[i]);
              await settle();
            }
            const elapsed=performance.now()-started, calls=taskOverheadCalls()-startCalls;
            check(count>0 && calls===count*43,'incorrect or zero actual handler count');
            if(mutation==='microtask-slowdown')check(overheadMicrotaskCalls-startMicrotasks===calls,'microtasks not settled');
            check(Number.isFinite(elapsed)&&elapsed>0,'invalid elapsed clock');
            return {elapsedMs:elapsed,calls,usPerEvent:elapsed*1000/calls};
          }
          try {
            for(let i=0;i<warmups;i++)await batch(warmupCycles);
            const measured=await batch(mutation==='zero-events'?0:cycles);
            return {...measured, quantumMs:quantum, handlers:handlers.length, cycles};
          } finally {channel.port1.close();channel.port2.close();}
        },{cycles,slowdown,mutation,warmups:protocol.warmups,warmupCycles:protocol.warmupCycles});
        assert.deepEqual(errors,[],'browser app errors');
        return result;
      } finally {await page.close();}
    }
    async function paired(target,left,right,count,cycles,slowdown=0,mutation='') {
      for(let i=0;i<count;i++) {
        let a,b;
        if(i%2===0){a=await sample(left,cycles);b=await sample(right,cycles,slowdown,mutation);}
        else{b=await sample(right,cycles,slowdown,mutation);a=await sample(left,cycles);}
        target.push({order:i%2?'BA':'AB',a,b,differenceUs:b.usPerEvent-a.usPerEvent});
        save();
      }
    }
    if(controlsCalibration) {
      const prior=JSON.parse(readFileSync(controlsCalibration,'utf8'));
      assert.deepEqual(prior.protocol,protocol,'control calibration protocol changed');
      assert.deepEqual(prior.provenance,provenance,'control calibration artifact provenance changed');
      receipt.noiseBandUs=noiseBand(prior.calibration.map(p=>p.differenceUs),Math.max(...prior.calibration.flatMap(p=>[p.a.quantumMs,p.b.quantumMs])));
      assert.equal(receipt.noiseBandUs,prior.noiseBandUs,'invalid prior calibration band');
      receipt.controlsOnlyCalibration={path:controlsCalibration,sha256:sha(controlsCalibration)};
    } else {
      await paired(receipt.calibration,'m5','m5',protocol.pairs,protocol.cycles);
      receipt.noiseBandUs=noiseBand(receipt.calibration.map(p=>p.differenceUs),Math.max(...receipt.calibration.flatMap(p=>[p.a.quantumMs,p.b.quantumMs])));
      save(); // Frozen before any candidate sample.
      await paired(receipt.comparison,'m5','current',protocol.pairs,protocol.cycles);
      receipt.defaultComparison=qualify(receipt.comparison.map(p=>p.differenceUs),receipt.noiseBandUs);
      receipt.absoluteMediansUs={m5:median(receipt.comparison.map(p=>p.a.usPerEvent)),current:median(receipt.comparison.map(p=>p.b.usPerEvent))};
      receipt.ratioCurrentToM5=receipt.absoluteMediansUs.current/receipt.absoluteMediansUs.m5;
    }
    for(const mutation of ['callback-slowdown','microtask-slowdown']) {
      const slow=[];
      await paired(slow,'m5','m5',protocol.controlPairs,protocol.controlCycles,protocol.slowdownUs,mutation);
      const rejected=qualify(slow.map(p=>p.differenceUs),receipt.noiseBandUs);
      assert(!rejected.withinNoise && !rejected.withinRecorderBudget,'real callback slowdown must fail both gates');
      receipt.controls.push({name:mutation,samples:slow,result:rejected});save();
    }
    for(const [mutation,reason] of [['delete-handler','actual handler count'],['zero-events','zero actual'],['invalid-clock','invalid clock'],['zero-ssr','44 captured SSR'],['truncated-ssr','44 captured SSR']]) {
      await assert.rejects(()=>sample('m5',1,0,mutation),new RegExp(reason));
      receipt.controls.push({name:mutation,result:'required refusal'});save();
    }
    receipt.recordingGate='PENDING: genuine CT recording adapter not implemented';
    receipt.dormantRecordableGate='PENDING: ordinary/default arm does not establish recordable-dormant qualification';
    receipt.status=controlsCalibration?'controls-only-no-performance-qualification':
      receipt.defaultComparison.withinNoise?'default-within-noise':'default-outside-noise';
    save();
    return receipt;
  } catch(error) {receipt.failure=String(error);save();throw error;}
  finally {
    if(receipt.host)receipt.host.loadAfter=loadavg();
    try {save();if(browser)await browser.close();if(server)await new Promise(done=>server.close(done));}
    finally {closeSync(receiptFd);}
  }
}

if(process.argv[1] && import.meta.url===pathToFileURL(resolve(process.argv[1])).href) {
  const [root,output,playwright,controlsCalibration]=process.argv.slice(2);
  assert(root && output && playwright,'usage: task_overhead.mjs ARTIFACT_DIR RECEIPT_JSON PLAYWRIGHT_INDEX');
  const executable=process.env.PLAYWRIGHT_CHROMIUM_EXECUTABLE || execFileSync('which',['chromium'],{encoding:'utf8'}).trim();
  const result=await benchmark({root:resolve(root),output:resolve(output),playwright,executable,controlsCalibration});
  console.log(JSON.stringify({status:result.status,noiseBandUs:result.noiseBandUs,defaultComparison:result.defaultComparison,recordingGate:result.recordingGate},null,2));
  if(result.defaultComparison && !result.defaultComparison.withinNoise)process.exitCode=1;
}
