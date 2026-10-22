/** Actual component preview srcdocs and real selection bridges in Chromium.
 * The fixture's declared workspace documents replace one another; observing
 * forwarding wrappers do not substitute restoration or renderer behavior.
 */
import {chromium} from '../node_modules/playwright/index.mjs';
import {spawn} from 'node:child_process';
import {createServer} from 'node:net';
import {writeFileSync} from 'node:fs';
import {fileURLToPath} from 'node:url';
import path from 'node:path';
import assert from 'node:assert/strict';
const repo=path.resolve(path.dirname(fileURLToPath(import.meta.url)),'..');
const root=path.join(repo,'build/editor-generation');
writeFileSync(path.join(root,'index.html'),'<!doctype html><html><body><script src="fixture.js"></script></body></html>');
const port=await new Promise((resolve,reject)=>{const probe=createServer();probe.once('error',reject);probe.listen(0,'127.0.0.1',()=>{const value=probe.address().port;probe.close(()=>resolve(value));});});
const server=spawn(process.execPath,[repo+'/tests/browser/tools/static_server.mjs',root,String(port)],{stdio:['ignore','pipe','pipe']});
await new Promise((resolve,reject)=>{server.once('error',reject);server.once('exit',code=>reject(new Error('fixture server exited '+code)));server.stdout.once('data',resolve);});
let browser;
try {
 const env={...process.env};delete env.LD_LIBRARY_PATH;
 browser=await chromium.launch({headless:true,env,executablePath:process.env.PLAYWRIGHT_CHROMIUM_EXECUTABLE});
 for (const surface of ['detail','edit']) {
 const page=await browser.newPage({viewport:{width:1280,height:720}});
 const errors=[];page.on('pageerror',error=>errors.push(error.message));
 await page.goto('http://127.0.0.1:'+port+'/?surface='+surface);
 const frame=page.frameLocator('iframe');
 for(let version=0;version<3;version++) {
  if(version)await page.locator('#next-document').click();
  assert.deepEqual(await page.evaluate(()=>window.generationProbe.requests),Array.from({length:version+1},(_,value)=>({version:value,id:'restore-target'})),'each later generation notifies the restoration consumer exactly once');
  await frame.locator(`body[data-version="${version}"] [data-isonim-selected="true"]`).waitFor();
  const restored=await page.evaluate(()=>window.generationProbe.restores);
  // The existing consumer may attempt restoration before and on load. Keep
  // that behavior and require real bridge execution/selection in every doc.
  assert.deepEqual([...new Set(restored.map(value=>value.version))],Array.from({length:version+1},(_,value)=>value));
  assert(restored.every(value=>value.id==='restore-target'));
  assert.equal(await page.evaluate(()=>window.generationProbe.documents),version+1,surface+': generation notification must not re-enter the document producer');
  if(surface==='detail')assert.equal(await page.evaluate(()=>window.generationProbe.panels),version+1);
 }
 assert.deepEqual(errors,[]);
 await page.close();
 console.log('PASS '+surface+': three actual documents notify restoration once each and select the same element, without producer self-invalidation');
 }
} finally {if(browser)await browser.close();server.kill();}
