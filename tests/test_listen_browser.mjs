// Real SSR output and actual browser dispatch; no substituted DOM or events.
import { chromium } from './browser/node_modules/playwright/index.mjs';
import { createServer } from 'node:http';
import { readFile } from 'node:fs/promises';
import { execFileSync } from 'node:child_process';
import assert from 'node:assert/strict';
import test from 'node:test';
const markup = execFileSync('build/listen_ssr', {encoding:'utf8'});
const bundle = await readFile('build/listen.js');
const plainMarkup=execFileSync('build/listen_plain_ssr',{encoding:'utf8'});
const plainBundle=await readFile('build/listen_plain.js');
const server = createServer((req,res) => { res.setHeader('Content-Type',req.url.endsWith('.js') ? 'text/javascript':'text/html'); res.end(req.url === '/app.js' ? bundle : req.url === '/plain.js' ? plainBundle : req.url === '/normal' ? plainMarkup : markup); });
await new Promise(r => server.listen(0,'127.0.0.1',r));
let browser;
try {
  browser = await chromium.launch({executablePath:process.env.PLAYWRIGHT_CHROMIUM_EXECUTABLE});
  const page = await browser.newPage();
  const errors=[]; page.on('pageerror',e=>errors.push(String(e)));
  await page.goto(`http://127.0.0.1:${server.address().port}/`);
  // Queue BEFORE loading application: preserve every intermediate value.
  await page.locator('#secret').fill('early-secret');
  await page.locator('#secret').fill('later-secret');
  await page.locator('#check').click();
  await page.locator('#notes').fill('early-notes');
  const early = await page.evaluate(() => _$HY.events.map(([el,ev,state])=>({type:ev.type,id:ev.target.id,timeStamp:ev.timeStamp,value:state.value,checked:state.checked})));
  assert(early.length>=4);
  await page.addScriptTag({url:'/app.js'});
  await page.evaluate(() => startApp());
  for (const selector of ['#scoped-links a','#keyed-links a']) {
    const ids=await page.locator(selector).evaluateAll(nodes=>nodes.map(n=>n.dataset.iid));
    assert.equal(ids.length,2); assert.equal(new Set(ids).size,2); assert(ids.every(Boolean));
  }
  // e2e_prehydration_events_logged
  async function e2e_prehydration_events_logged() {
    const pre = await page.evaluate(() => ({records, handlerCalls,callOrder,mismatches:_$HY.mismatches,done:_$HY.done}));
    assert.equal(pre.mismatches,0); assert(pre.done);
    assert.equal(pre.records.length,pre.handlerCalls.length);
    assert.deepEqual(pre.records.map(r=>({type:r.type,iid:r.targetIid})),pre.callOrder);
    assert(pre.records.every(r=>r.phase==='prehydration' && r.finalized));
    assert.deepEqual(pre.records.map(r=>r.timeStamp),early.filter(r=>!(r.id==='check' && r.type==='input')).map(r=>r.timeStamp));
    assert.deepEqual(pre.handlerCalls.filter(r=>r.type==='input' && r.current==='secret').map(r=>r.value),['early-secret','later-secret']);
    assert(pre.handlerCalls.filter(r=>r.current==='check').every(r=>r.checked===true));
  }
  await test('e2e_prehydration_events_logged', e2e_prehydration_events_logged);
  async function e2e_listen_wraps_every_handler() {
    await page.evaluate(() => { records.length=0; handlerCalls.length=0; callOrder.length=0; });
    let interactions=0;
    for (let i=0;i<8;i++) { await page.locator('#plain').click(); interactions++; }
    for (let i=0;i<3;i++) { await page.locator('#secret').press('a'); interactions++; }
    await page.locator('#submit').click(); interactions++;
    await page.locator('#check').click(); interactions++;
    await page.locator('#multi').click(); interactions++;
    await page.locator('#link-host a').click(); interactions++;
    assert(page.url().endsWith('/next'));
    const beforeBack = await page.evaluate(()=>records.length);
    await page.goBack(); interactions++;
    await page.waitForFunction(n=>records.length>n,beforeBack);
    assert(interactions>=15);
    // e2e_listen_wraps_every_handler: independently count application callbacks.
    const live = await page.evaluate(() => ({records, handlerCalls,plainCalls,special,callOrder,iids:[...document.querySelectorAll('[data-iid]')].map(e=>e.dataset.iid)}));
    assert.equal(live.records.length,live.handlerCalls.length+live.plainCalls+live.special.length+2); // Link and popstate
    assert(live.records.every(r=>r.finalized && (r.targetIid==='win'||live.iids.includes(r.targetIid))));
    assert(live.records.every((r,i)=>!i||r.seq>live.records[i-1].seq));
    const linkIid=await page.locator('#link-host a').getAttribute('data-iid');
    const navigation=live.records.filter(r=>r.targetIid===linkIid||r.targetIid==='win');
    assert.deepEqual(navigation.map(r=>({type:r.type,iid:r.targetIid})),[{type:'click',iid:linkIid},{type:'popstate',iid:'win'}]);
    assert.deepEqual(live.records.filter(r=>r.targetIid!==linkIid&&r.targetIid!=='win').map(r=>({type:r.type,iid:r.targetIid})),live.callOrder);
    assert.deepEqual(live.special,['multi','multi','nested']);
    const multiIid=await page.locator('#multi').getAttribute('data-iid');
    const nestedIid=await page.locator('#nested').getAttribute('data-iid');
    const span=live.records.filter(r=>r.targetIid===multiIid||r.targetIid===nestedIid);
    assert.deepEqual(span.map(r=>r.targetIid),[multiIid,multiIid,nestedIid]);
    assert.equal(span[1].payload.defaultPrevented,true);
    assert.equal(span[2].payload.defaultPrevented,false);
    assert.equal(live.records.at(-2).payload.defaultPrevented,true); // Link
    assert.equal(live.records.at(-1).targetIid,'win');
    assert(live.records.some(r=>r.type==='keydown'&&r.payload.key==='a'&&r.payload.code==='KeyA'&&r.payload.ctrlKey===false));
    assert(live.records.some(r=>r.type==='click'&&Number.isFinite(r.payload.clientX)&&Number.isFinite(r.payload.clientY)&&r.payload.button===0));
    const beforeRaw=await page.evaluate(()=>records.length);
    await page.locator('#raw').click();
    assert.equal(await page.evaluate(()=>records.length),beforeRaw);
    assert.equal(await page.evaluate(()=>rawCalls),1);
  }
  await test('e2e_listen_wraps_every_handler', e2e_listen_wraps_every_handler);
  async function e2e_input_values_scrubbed() {
    // Actual editable target and UTF-16 length.
    const secret='private-😀-é';
    for (const id of ['secret','explicit-false','password','notes','private-child']) await page.locator('#'+id).fill(secret);
    await page.locator('#editable').fill(secret);
    await page.locator('#verbatim').fill(secret);
    const scrub = await page.evaluate(() => records.filter(r=>r.type==='input').slice(-7));
    assert.equal(scrub.length,7);
    assert(scrub.slice(0,6).every(r=>r.payload.value==='*'.repeat(secret.length)));
    assert.equal(scrub[6].payload.value,secret);
    const serialized=JSON.stringify(scrub.slice(0,6));
    assert(!serialized.includes(secret));
    assert(!serialized.includes('early-secret'));
    assert.equal(await page.locator('#secret').inputValue(),secret);
    const applicationValues=await page.evaluate(()=>Object.fromEntries(handlerCalls.filter(c=>c.type==='input').map(c=>[c.current,c.current==='editable'?c.textContent:c.value])));
    for (const id of ['secret','explicit-false','password','notes','private-child','editable','verbatim']) assert.equal(applicationValues[id],secret);

  }
  await test('e2e_input_values_scrubbed', e2e_input_values_scrubbed);
  const count=await page.evaluate(()=>records.length);
  await page.evaluate(()=>disposeApp());
  await page.locator('#plain').click(); await page.locator('#multi').click();
  assert.equal(await page.evaluate(()=>records.length),count);
  // Disabled observation preserves callbacks; observer failures cannot suppress
  // callbacks, and callback exceptions still escape through the native DOM.
  const applicationFailure = page.waitForEvent('pageerror');
  const failureControl = await page.evaluate(() => {
    const node=document.createElement('button');
    node.dataset.iid='failure-control';
    let calls=0;
    const remove=registerListener(node,'click',()=>{ calls++; },false);
    observeListeners(null);
    const before=records.length;
    node.click();
    if(records.length!==before) throw new Error('disabled hook observed input');
    observeListeners(()=>{ throw new Error('expected observer failure'); });
    node.click();
    remove();
    observeListeners(record=>records.push(record));
    const removeThrow=registerListener(node,'click',()=>{ throw new Error('expected application failure'); },false);
    node.click(); removeThrow();
    return {calls,record:records.at(-1)};
  });
  assert.match(String(await applicationFailure),/expected application failure/);
  assert.equal(failureControl.calls,2);
  assert(failureControl.record.finalized);
  assert.equal(failureControl.record.targetIid,'failure-control');
  assert.equal(failureControl.record.payload.defaultPrevented,false);
  assert.equal(errors.length,1);
  assert.match(errors.pop(),/expected application failure/);
  const lifecycle = await page.evaluate(() => {
    records.length=0;
    const parent=document.createElement('div'), child=document.createElement('button');
    parent.dataset.iid='lifecycle-parent'; child.dataset.iid='lifecycle-child';
    parent.append(child); document.body.append(parent);
    const calls=[];
    const capture=registerListener(parent,'click',e=>{if(e.currentTarget!==parent||e.target!==child||e.eventPhase!==1)throw new Error('capture semantics'); calls.push('capture');},true);
    const bubble=registerListener(parent,'click',e=>{if(e.currentTarget!==parent||e.target!==child||e.eventPhase!==3)throw new Error('bubble semantics'); calls.push('bubble');},false);
    let stop;
    const handler=e=>{ calls.push('self'); stop(); child.click(); };
    stop=registerListener(child,'click',handler,false);
    const same=registerListener(child,'click',handler,false);
    if (same!==stop) throw new Error('dedup disposer identity');
    child.click();
    capture(); bubble();
    let removeLater;
    const first=registerListener(child,'click',e=>{ calls.push('first'); removeLater(); },false);
    removeLater=registerListener(child,'click',e=>calls.push('removed'),false);
    child.click(); first();
    const prevent=registerListener(child,'click',e=>{ calls.push('stop'); e.stopPropagation(); e.preventDefault(); },false);
    const noBubble=registerListener(parent,'click',e=>calls.push('unreachable'),false);
    const afterStop=registerListener(child,'click',e=>{if(!e.cancelBubble||!e.defaultPrevented)throw new Error('cancellation semantics'); calls.push('afterStop');},false);
    child.click(); prevent(); noBubble(); afterStop();
    const focusCapture=registerListener(parent,'focus',e=>calls.push('focusCapture'),true);
    const focusBubble=registerListener(parent,'focus',e=>calls.push('unreachableFocus'),false);
    const focusTarget=registerListener(child,'focus',e=>calls.push('focusTarget'),false);
    child.focus(); focusCapture(); focusBubble(); focusTarget();
    const owned=e=>calls.push('owned');
    const owner1=registerOwnedListener(child,'click',owned);
    const owner2=registerOwnedListener(child,'click',owned);
    owner2(); child.click(); owner1(); child.click();
    const doc=registerListener(document,'click',e=>calls.push('doc'),false);
    child.click(); doc();
    // Registration predates backend selection; dispatch must use current backend.
    const dynamic=registerListener(child,'click',()=>calls.push('clock'),false);
    selectTestClock(); child.click(); dynamic();
    const final=records.at(-1);
    parent.remove();
    return {calls, records, final};
  });
  assert.deepEqual(lifecycle.calls,['capture','self','bubble','first','stop','afterStop','focusCapture','focusTarget','owned','doc','clock']);
  assert.equal(lifecycle.records.length,lifecycle.calls.length);
  assert(lifecycle.records.some(r=>r.targetIid==='doc'));
  assert.equal(lifecycle.final.timeStamp,123);
  assert.equal(lifecycle.final.seq,1);
  assert(lifecycle.records.find(r=>r.payload.defaultPrevented)?.payload.defaultPrevented);
  await page.evaluate(() => {
    (()=>{
      const node=document.createElement('button'), captured={token:'closure'};
      node.dataset.iid='weak-lifecycle';
      registerListener(node,'click',()=>captured.token,false);
      globalThis.weakNode=new WeakRef(node);
      globalThis.weakClosure=new WeakRef(captured);
    })();
  });
  const cdp=await page.context().newCDPSession(page);
  await cdp.send('HeapProfiler.collectGarbage');
  await cdp.send('HeapProfiler.collectGarbage');
  assert(await page.evaluate(()=>!weakNode.deref()&&!weakClosure.deref()));
  await cdp.detach();
  const normal=await browser.newPage();
  normal.on("pageerror",e=>errors.push(String(e)));
  await normal.goto(`http://127.0.0.1:${server.address().port}/normal`);
  await normal.addScriptTag({url:'/plain.js'});
  // Re-evaluating a normal bundle must not redeclare module-level lexical constants.
  await normal.addScriptTag({url:'/plain.js'});
  await normal.evaluate(()=>startApp());
  await normal.locator('#plain').click();
  const smoke=await normal.evaluate(()=>({records,plainCalls}));
  assert.equal(smoke.plainCalls,1); assert.equal(smoke.records.length,1);
  assert.equal(smoke.records[0].targetIid,''); assert(smoke.records[0].finalized);
  await normal.close();
  assert.deepEqual(errors,[]);
} finally { await browser?.close(); await new Promise(r=>server.close(r)); }
