// Real SSR, hydration, event registrations and WeakRef index in Chromium.
// No mocks: an ephemeral local HTTP server serves the compiled artifacts.
import assert from 'node:assert/strict';
import {test} from 'node:test';
import {createServer} from 'node:http';
import {readFileSync} from 'node:fs';
import {execFileSync} from 'node:child_process';
import {resolve} from 'node:path';
import {resolveIidMetadata} from '../tools/isonim_manifest.mjs';
import {chromium} from './browser/node_modules/playwright/index.mjs';

const root = resolve('build/stable-ids');
const server = createServer((req, res) => {
  const name = req.url === '/' ? 'index.html' : req.url.slice(1);
  if (!['index.html', 'task-app.js', 'off.html', 'off.js', 'keyed.html', 'keyed.js', 'instances.html', 'instances.js', 'instances-keyed.html', 'instances-keyed.js'].includes(name)) {res.writeHead(404); res.end(); return;}
  res.setHeader('Content-Type', name.endsWith('.js') ? 'text/javascript' : 'text/html');
  res.end(readFileSync(resolve(root, name)));
});
await new Promise(done => server.listen(0, '127.0.0.1', done));
const browser = await chromium.launch({headless: true, executablePath: process.env.PLAYWRIGHT_CHROMIUM_EXECUTABLE || execFileSync('which', ['chromium'], {encoding:'utf8'}).trim(), args:['--no-sandbox']});
export async function e2e_iid_ssr_client_agree() {
try {
  const page = await browser.newPage();
  const errors=[];
  page.on('pageerror', e=>errors.push(e.message));
  await page.addInitScript(() => {
    globalThis.handlerTargets=[];
    const add=EventTarget.prototype.addEventListener;
    EventTarget.prototype.addEventListener=function(type, handler, options) {
      if (this instanceof Element) globalThis.handlerTargets.push(this);
      return add.call(this, type, handler, options);
    };
  });
  const url=`http://127.0.0.1:${server.address().port}`;
  await page.goto(url);
  await page.waitForFunction(()=>globalThis.iidClaims);
  const result=await page.evaluate(()=>({
    claims:globalThis.iidClaims,
    retained:globalThis.ssrIids.every(({el,iid})=>el.isConnected && el.getAttribute('data-iid')===iid && globalThis.__isonimIids.get(iid).deref()===el),
    handlers:globalThis.handlerTargets.map(el=>el.getAttribute('data-iid')),
    mismatches:globalThis._$HY.mismatches,
  }));
  assert.deepEqual(errors, []);
  assert.equal(result.claims.length,44);
  assert.equal(new Set(result.claims.map(x=>x.iid)).size,44);
  assert(result.claims.every(x=>x.same));
  assert(result.retained, 'client must claim the exact SSR node with the same iid');
  assert.equal(result.handlers.length,43);
  assert(result.handlers.every(Boolean),'every handler target is stamped');
  assert.equal(result.mismatches,0);
  console.log('e2e_iid_ssr_client_agree PASS (44 exact SSR node claims, 43 handlers)');
  await page.goto(url+'/off.html');
  assert.equal(await page.locator('input,button,form').count(),44, 'negative control must render the same task controls');
  const unstamped=await page.locator('[data-iid]').count();
  function requireStamped(count) {if (!count) throw new Error('not stamped');}
  assert.equal(unstamped,0);
  assert(await page.evaluate(()=>!('__isonimIids' in globalThis)), 'default build must erase the iid index');
  assert.throws(()=>requireStamped(unstamped),/not stamped/);
  console.log('e2e_iid_without_flag NEGATIVE CONTROL: not stamped');
  await page.goto(url+'/keyed.html');
  assert.equal(await page.locator('button').count(),3);
  const keyed = await page.evaluate(() => {
    const a=document.querySelectorAll('button')[0], b=document.querySelectorAll('button')[1];
    const aIid=a.getAttribute('data-iid'), bIid=b.getAttribute('data-iid');
    globalThis.setRows(0);
    const moved=document.querySelectorAll('button')[2]===a;
    globalThis.setRows(1);
    const removed=!b.isConnected;
    globalThis.setRows(2);
    const replacement=document.querySelectorAll('button')[0];
    return {moved,removed,aIid,bIid,replaced:replacement!==b,
      replacementIndexed:globalThis.__isonimIids.get(bIid).deref()===replacement,
      preserved:document.querySelectorAll('button')[2].getAttribute('data-iid')===aIid};
  });
  assert(keyed.moved && keyed.removed && keyed.replaced && keyed.replacementIndexed && keyed.preserved);
  assert(keyed.aIid.endsWith('#a') && keyed.bIid.endsWith('#b'));
  // A real V8 collection proves the index is weak. Retaining stale test-side
  // node handles here would invalidate this test, so only strings escape.
  await page.evaluate(()=>globalThis.handlerTargets=[]); // release instrumentation references
  const session=await page.context().newCDPSession(page);
  await session.send('HeapProfiler.collectGarbage');
  assert(await page.evaluate(iid=>globalThis.__isonimIids.get(iid).deref().isConnected,keyed.bIid), 'old-node finalization must not delete a new claim');
  await page.evaluate(()=>globalThis.disposeRows());
  // Blink retains detached layout nodes until the next rendering update.
  await page.evaluate(()=>new Promise(done=>requestAnimationFrame(()=>requestAnimationFrame(done))));
  assert.equal(await page.locator('button').count(),0);
  await session.send('HeapProfiler.collectGarbage');
  assert(await page.evaluate(()=>[...globalThis.__isonimIids.values()].every(ref=>!ref.deref())), 'disposed DOM must not be retained by iid map');
  assert.deepEqual(errors, []);
  console.log('e2e_iid_keyed_lifecycle PASS (reorder, replacement, disposal, real GC)');
  await page.goto(url+'/instances.html');
  await page.waitForFunction(()=>globalThis.instanceClaims);
  const instances=await page.evaluate(()=>({claims:globalThis.instanceClaims,
    retained:globalThis.instanceSsr.every(({el,iid})=>el.isConnected && el.getAttribute('data-iid')===iid && globalThis.__isonimIids.get(iid).deref()===el),
    mismatches:globalThis._$HY.mismatches}));
  assert.equal(instances.claims.length,5);
  assert.equal(new Set(instances.claims.map(x=>x.iid)).size,5);
  assert(instances.claims.every(x=>x.same));
  assert(instances.retained);
  assert.equal(instances.mismatches,0);
  const manifest=JSON.parse(readFileSync(root+'/instances/js.json','utf8'));
  for (const claim of instances.claims) assert.equal(resolveIidMetadata(manifest,claim.iid).tag,'button');
  console.log('e2e_iid_reusable_hydration PASS (five distinct nested instances, exact SSR nodes, manifest source mapping)');
  await page.goto(url+'/instances-keyed.html');
  assert.equal(await page.locator('button').count(),12);
  const keyedInstances=await page.evaluate(()=>{
    const ids=()=>[...document.querySelectorAll('ul')].map(list=>[...list.querySelectorAll('button')].map(el=>el.getAttribute('data-iid')));
    const initial=ids();
    const old=[...document.querySelectorAll('ul')[0].querySelectorAll('button')];
    globalThis.updateInstances(0);
    const reordered=ids();
    const retained=old.every(node=>node.isConnected && globalThis.__isonimIids.get(node.getAttribute('data-iid')).deref()===node);
    globalThis.updateInstances(1);
    globalThis.updateInstances(2);
    const reinserted=ids();
    globalThis.updateInstances(3);
    const added=ids();
    return {initial,reordered,reinserted,added,retained};
  });
  assert.equal(new Set(keyedInstances.initial.flat()).size,12);
  assert(keyedInstances.retained);
  assert.deepEqual(keyedInstances.reordered[0],[...keyedInstances.initial[0].slice(4,6),...keyedInstances.initial[0].slice(2,4),...keyedInstances.initial[0].slice(0,2)]);
  assert.deepEqual(keyedInstances.reordered[1],keyedInstances.initial[1]);
  assert.deepEqual(keyedInstances.reinserted[0].slice(0,2),keyedInstances.initial[0].slice(2,4));
  assert.deepEqual(keyedInstances.added[0].slice(0,2),keyedInstances.initial[0].slice(0,2).map(iid=>iid.replace(/#a$/,'#d')));
  assert.equal(new Set(keyedInstances.added.flat()).size,12);
  const keyedManifest=JSON.parse(readFileSync(root+'/instances-keyed.json','utf8'));
  assert.equal(Object.keys(keyedManifest.iids).length,2);
  for (const iid of keyedInstances.added.flat()) {
    const metadata=resolveIidMetadata(keyedManifest,iid);
    assert.equal(metadata.file,'tests/fixtures/stable_ids/instances_keyed.nim');
    assert(metadata.component.includes('.leaf/'));
  }
  await page.evaluate(iid=>globalThis.reclaimInstance(iid), keyedInstances.added[0][0]);
  // Outside-DSL calls carry no automatic caller slot. Resolve must refuse
  // two mounted copies; creating a detached successor must preserve a live
  // predecessor until the DOM batch has actually replaced it.
  const duplicates=await page.evaluate(()=>{
    globalThis.outsideTargets();
    const nodes=[...document.querySelectorAll('#root > button')];
    const iid=nodes[0].getAttribute('data-iid');
    const firstKept=globalThis.__isonimIids.get(iid).deref()===nodes[0];
    let rejection='';
    try {globalThis.resolveInstanceIid(iid);} catch(e) {rejection=e.message;}
    nodes[0].remove();
    const successor=globalThis.resolveInstanceIid(iid)===nodes[1];
    nodes[1].remove();
    return {firstKept,rejection,successor};
  });
  assert(duplicates.firstKept && duplicates.successor);
  assert.match(duplicates.rejection,/duplicate live stable iid:/);
  assert.deepEqual(errors, []);
  console.log('e2e_iid_reusable_keyed_instances PASS (two lists, twelve targets, reorder/reinsert/new-key scope, duplicate refusal, successor replacement)');
} finally {
  await browser.close();
  await new Promise(done=>server.close(done));
}
}
await test('e2e_iid_ssr_client_agree', e2e_iid_ssr_client_agree);
