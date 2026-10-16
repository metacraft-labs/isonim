/** Scheduling tests execute the exact browser-evaluated capture helper. The
 * deterministic scheduler is justified solely to supply otherwise rare duplicate,
 * stalled, invalid, late and throwing callback boundaries and to inspect ownership
 * of every pending RAF/timer. It never produces captured corpus evidence. The
 * real-browser positive runs with the existing pinned executable, flags and
 * environment at both original widths, without replacing browser APIs. Complete
 * production readiness/PNG evidence is separately required by the strict campaign.
 */
import assert from 'node:assert/strict';
import {test} from 'node:test';
import {readFileSync} from 'node:fs';
import {createHash} from 'node:crypto';
import {chromium} from '../node_modules/playwright/index.mjs';
import {waitForAdvancingFrames} from '../tools/chat-capture-frames.mjs';

function controlledScheduler() {
  let now=0, next=1;
  const frames=new Map(), timers=new Map();
  return {
    performance:{now:()=>now}, frames, timers,
    requestAnimationFrame(callback){const id=next++;frames.set(id,callback);return id;},
    cancelAnimationFrame(id){frames.delete(id);},
    setTimeout(callback,ms){const id=next++;timers.set(id,{callback,at:now+ms});return id;},
    clearTimeout(id){timers.delete(id);},
    fire(time){assert.equal(frames.size,1);const [id,callback]=frames.entries().next().value;frames.delete(id);callback(time);},
    advance(ms,runTimers=true){now+=ms;if(runTimers)for(const [id,timer] of [...timers])if(timer.at<=now){timers.delete(id);timer.callback();}},
    clean(){assert.equal(frames.size,0,'no pending frame callback');assert.equal(timers.size,0,'no pending timer');}
  };
}

test('duplicates cannot settle until supplied advancing observations',async()=>{
  const scheduler=controlledScheduler();let settled=false;
  const pending=waitForAdvancingFrames(5000,scheduler).finally(()=>{settled=true;});
  scheduler.fire(19);scheduler.fire(19);scheduler.fire(19);
  await Promise.resolve();assert.equal(settled,false);assert.equal(scheduler.frames.size,1);
  scheduler.fire(23);assert.deepEqual(await pending,[19,23]);scheduler.clean();
});
for(const mode of ['stalled','never advancing'])test(`${mode} expires at original 5000ms budget and cancels ownership`,async()=>{
  const scheduler=controlledScheduler();const pending=waitForAdvancingFrames(5000,scheduler);
  const rejected=assert.rejects(pending,/deadline exceeded/);
  if(mode==='never advancing'){scheduler.fire(19);for(let i=0;i<8;i++)scheduler.fire(19);}
  scheduler.advance(4999);assert.equal(scheduler.frames.size,1);scheduler.advance(1);
  await rejected;scheduler.clean();
});
for(const value of [NaN,Infinity,-Infinity,-1,'20',undefined])test(`invalid callback ${String(value)} rejects and cleans ownership`,async()=>{
  const scheduler=controlledScheduler();const pending=waitForAdvancingFrames(5000,scheduler);
  const rejected=assert.rejects(pending,/invalid animation frame observation/);
  scheduler.fire(19);scheduler.fire(value);await rejected;scheduler.clean();
});
test('backward callback rejects rather than recovering into success',async()=>{
  const scheduler=controlledScheduler();const pending=waitForAdvancingFrames(5000,scheduler);
  const rejected=assert.rejects(pending,/backward animation frame observation/);
  scheduler.fire(19);scheduler.fire(18);await rejected;scheduler.clean();
});
test('late advancing callback cannot win against a delayed deadline timer',async()=>{
  const scheduler=controlledScheduler();const pending=waitForAdvancingFrames(5000,scheduler);
  const rejected=assert.rejects(pending,/deadline exceeded/);
  scheduler.fire(19);scheduler.advance(5000,false);scheduler.fire(23);
  await rejected;scheduler.clean();
});
test('remaining budget expires without extending the original deadline',async()=>{
  const scheduler=controlledScheduler();scheduler.advance(4900);
  const pending=waitForAdvancingFrames(100,scheduler);const rejected=assert.rejects(pending,/deadline exceeded/);
  scheduler.fire(19);scheduler.fire(19);scheduler.advance(100);await rejected;scheduler.clean();
});
test('request error after first observation rejects and clears the timer',async()=>{
  const scheduler=controlledScheduler();const pending=waitForAdvancingFrames(5000,scheduler);
  const rejected=assert.rejects(pending,/controlled scheduling failure/);
  scheduler.requestAnimationFrame=()=>{throw new Error('controlled scheduling failure');};
  scheduler.fire(19);await rejected;scheduler.clean();
});
test('rejected late callbacks cannot schedule further work',async()=>{
  const scheduler=controlledScheduler();const pending=waitForAdvancingFrames(5000,scheduler);
  const rejected=assert.rejects(pending,/deadline exceeded/);
  const callback=[...scheduler.frames.values()][0];scheduler.advance(5000);
  await rejected;callback(23);scheduler.clean();
});
test('pinned real browser records advancing actual callback arguments at both widths',async()=>{
  const runtime=JSON.parse(readFileSync(new URL('../tools/chat-visual-runtime.json',import.meta.url)));
  const executablePath='/ms-playwright/chromium-1217/chrome-linux64/chrome';
  assert.equal(createHash('sha256').update(readFileSync(executablePath)).digest('hex'),runtime.browserExecutableSha256);
  assert.equal(process.version,runtime.node);
  const flags=['--no-sandbox','--disable-gpu','--force-color-profile=srgb','--font-render-hinting=none','--disable-lcd-text'];
  const environment={deviceScaleFactor:1,locale:'en-US',timezoneId:'UTC',colorScheme:'dark',reducedMotion:'reduce'};
  const browser=await chromium.launch({headless:true,executablePath,args:flags});
  try {
    assert.equal(browser.version(),runtime.browser);
    for(const [size,viewport] of Object.entries({wide:{width:1440,height:900},narrow:{width:1024,height:768}})){
      const context=await browser.newContext({...environment,viewport});
      try {
        const page=await context.newPage();await page.setContent('<!doctype html><title>Frame boundary control</title>');
        const frameTimes=await page.evaluate(waitForAdvancingFrames,5000);
        assert.equal(frameTimes.length,2);assert(frameTimes.every(Number.isFinite));assert(frameTimes[1]>frameTimes[0]);
        console.log(JSON.stringify({size,frameTimes,browser:browser.version(),node:process.version,scope:'real scheduler control; production corpus requires strict campaign'}));
      }finally{await context.close();}
    }
  }finally{await browser.close();}
});
