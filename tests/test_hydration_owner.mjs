// Real HTTP, SSR markup and Chromium; onCleanup is independent of listeners.
import {chromium} from './browser/node_modules/playwright/index.mjs';
import {createServer} from 'node:http';
import {readFile} from 'node:fs/promises';
import {execFileSync} from 'node:child_process';
import assert from 'node:assert/strict';
const markup=execFileSync('build/hydration_owner_ssr',{encoding:'utf8'});
const js=await readFile('build/hydration_owner.js');
const server=createServer((req,res)=>{
  res.setHeader('Content-Type',req.url==='/app.js'?'text/javascript':'text/html');
  res.end(req.url==='/app.js'?js:(req.url==='/fallback'?"<!doctype html><body><main id='root'></main>":markup));
});
await new Promise(r=>server.listen(0,'127.0.0.1',r));
let browser;
try {
  browser=await chromium.launch({executablePath:process.env.PLAYWRIGHT_CHROMIUM_EXECUTABLE});
  for(const path of ['/','/fallback']) {
    const page=await browser.newPage(); const errors=[]; page.on('pageerror',e=>errors.push(String(e)));
    await page.goto(`http://127.0.0.1:${server.address().port}${path}`);
    await page.addScriptTag({url:'/app.js'});
    await page.waitForFunction(()=>globalThis.hydrationReady);
    assert.equal(await page.locator('h1').textContent(),'Owned hydration');
    assert.equal(await page.evaluate(()=>hydrationCleanups),0);
    await page.evaluate(()=>releaseHydration());
    assert.equal(await page.evaluate(()=>hydrationCleanups),1);
    await page.evaluate(()=>releaseHydration());
    assert.equal(await page.evaluate(()=>hydrationCleanups),1);
    assert.deepEqual(errors,[]); await page.close();
  }
  console.log('nested hydration roots follow parent disposal: PASS');
} finally {await browser?.close(); await new Promise(r=>server.close(r));}
