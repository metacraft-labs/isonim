// Real HTTP, Chromium, events, Promise microtasks, timers, frame and fetch.
import { chromium } from './browser/node_modules/playwright/index.mjs';
import {createServer} from 'node:http';
import {readFile} from 'node:fs/promises';
import assert from 'node:assert/strict';
const bundle = await readFile(process.argv[2] ?? 'build/checkpoints_browser.js');
const server=createServer((req,res)=>{
  if(req.url==='/app.js'){res.setHeader('Content-Type','text/javascript');res.end(bundle);}
  else if(req.url==='/data'){res.setHeader('Content-Type','application/json');res.end('{"ok":true}');}
  else res.end('<!doctype html><button id="run">Run</button><script src="/app.js"></script>');
});
await new Promise(resolve=>server.listen(0,'127.0.0.1',resolve));
let browser;
try {
  browser=await chromium.launch({executablePath:process.env.PLAYWRIGHT_CHROMIUM_EXECUTABLE,args:['--js-flags=--expose-gc']});
  const page=await browser.newPage();
  const errors=[];page.on('pageerror',e=>errors.push(String(e)));
  await page.goto(`http://127.0.0.1:${server.address().port}/`);
  assert.equal(await page.evaluate(()=>liveSignals()),10);
  await page.waitForFunction(()=>checkpoints.length===1);
  assert.deepEqual(await page.evaluate(()=>({seq:dispatchSeq(),draws:rngDraws(),initial:checkpoints[0]})),
    {seq:0,draws:0,initial:{afterSeq:0,derived:0,hash:await page.evaluate(()=>checkpointStateHash())}});
  await page.waitForTimeout(100);
  assert.equal(await page.evaluate(()=>checkpoints.length),1);
  await page.click('#run');
  await page.waitForFunction(()=>checkpoints.length===2);
  assert.deepEqual(await page.evaluate(()=>({seq:dispatchSeq(),derived:checkpoints.at(-1).derived,stages})),{seq:1,derived:30,stages:['microtask']});
  for(const [trigger,derived,seq] of [['startTimer',40,2],['startFrame',50,3],['startNetwork',60,4]]){
    await page.evaluate(name=>globalThis[name](),trigger);
    await page.waitForFunction(n=>checkpoints.length===n+1,seq);
    assert.deepEqual(await page.evaluate(()=>({seq:dispatchSeq(),last:checkpoints.at(-1).derived})),{seq,last:derived});
  }
  const hashes=await page.evaluate(()=>checkpoints.filter(c=>c.afterSeq>0).map(c=>c.hash));
  assert.equal(new Set(hashes).size,4);
  // Idle executes once but deduplicates the already-emitted sequence. A real
  // later host task observes that maintenance did not count/rearm itself.
  await page.waitForTimeout(100);
  assert.deepEqual(await page.evaluate(()=>({count:checkpoints.length,seq:dispatchSeq(),draws:rngDraws()})),{count:5,seq:4,draws:0});
  // The fifth dispatch is below interval 16: only a real idle callback can
  // emit this checkpoint. Deleting idle scheduling must time out this oracle.
  await page.evaluate(()=>{checkpointIdleOnly();document.querySelector('#run').click();});
  await page.waitForFunction(()=>checkpoints.length===6);
  assert.deepEqual(await page.evaluate(()=>({seq:dispatchSeq(),last:checkpoints.at(-1).derived})),{seq:5,last:30});
  await page.waitForTimeout(100);
  assert.equal(await page.evaluate(()=>checkpoints.length),6);
  await page.evaluate(()=>cancelInitialIdle());
  await page.waitForTimeout(100);
  assert.equal(await page.evaluate(()=>checkpoints.length),6);
  await page.evaluate(()=>collectableSignal());
  // WeakRef targets are kept until the end of the creating/dereferencing job.
  // Force GC in a later task, then read the registry in another task.
  await page.evaluate(()=>gc());
  assert.equal(await page.evaluate(()=>liveSignals()),10);
  await page.evaluate(()=>disposeCheckpointApp());
  assert.equal(await page.evaluate(()=>liveSignals()),0);
  assert.deepEqual(errors,[]);
  console.log('checkpoint browser events/microtasks/timer/frame/network/idle/GC: PASS');
} finally {
  if(browser)await browser.close();
  await new Promise(resolve=>server.close(resolve));
}
