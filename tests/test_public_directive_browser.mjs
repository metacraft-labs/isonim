/** Real shipped WebRenderer runs in real Chromium. No DOM/prototype stubs. */
import assert from 'node:assert/strict';
import {readFileSync,writeFileSync} from 'node:fs';
import {createServer} from 'node:http';
const {chromium}=await import(process.env.ISONIM_PLAYWRIGHT_MODULE ?? new URL('./browser/node_modules/playwright/index.mjs',import.meta.url).href);
const server=createServer((req,res)=>res.end('<!doctype html><body>public directive</body>'));
await new Promise(r=>server.listen(0,'127.0.0.1',r));
let browser;
try {
 browser=await chromium.launch({executablePath:process.env.PLAYWRIGHT_CHROMIUM_EXECUTABLE});
 const page=await browser.newPage(),errors=[];page.on('pageerror',e=>errors.push(String(e)));
 await page.goto(`http://127.0.0.1:${server.address().port}/`);
 await page.addScriptTag({content:readFileSync(process.argv[2],'utf8')});
 assert.deepEqual(errors,[],'actual WebRenderer assertions raised');
 assert.equal(await page.evaluate(()=>globalThis.publicDirectivePassed),true,'compiled actual browser checks did not finish');
 writeFileSync(process.argv[3],JSON.stringify({status:'PASS',browser:await browser.version(),realWebRenderer:true},null,2)+'\n');
}finally{if(browser)await browser.close();await new Promise(r=>server.close(r));}
