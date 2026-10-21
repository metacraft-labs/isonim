/** Real production browser mount/lifecycle/control bridge. The fixture's
 * explicit offline adapter records real physical prompt admission, not a
 * simulated provider result. The default case observes actual HTTP against a
 * static server (404), proving daemon selection without claiming daemon success.
 * No browser transport, DOM event, adapter-selection or control result is mocked.
 */
import {spawn} from 'node:child_process';
import {createServer} from 'node:net';
import path from 'node:path';
import {fileURLToPath} from 'node:url';
import assert from 'node:assert/strict';
import {chromium} from '../node_modules/playwright/index.mjs';
const repo=path.resolve(path.dirname(fileURLToPath(import.meta.url)),'..');
const port=await new Promise((resolve,reject)=>{const server=createServer();server.once('error',reject);server.listen(0,'127.0.0.1',()=>{const port=server.address().port;server.close(()=>resolve(port));});});
const server=spawn(process.execPath,[repo+'/tests/browser/tools/static_server.mjs',repo+'/build/editor-workspace-adapters',String(port)],{stdio:'ignore'});
let browser;
try {
 const origin='http://127.0.0.1:'+port;
 for(let attempt=0;;attempt++){try{if((await fetch(origin)).ok)break;}catch(e){if(attempt>=100)throw e;}await new Promise(resolve=>setTimeout(resolve,50));}
 const env={...process.env};delete env.LD_LIBRARY_PATH;
 browser=await chromium.launch({headless:true,env,executablePath:process.env.PLAYWRIGHT_CHROMIUM_EXECUTABLE});
 const page=await browser.newPage({viewport:{width:1440,height:900}});
 const requests=[];const errors=[];
 page.on('request',r=>{if(new URL(r.url()).pathname.startsWith('/api/agent/'))requests.push(r.url());});
 page.on('pageerror',e=>errors.push(e.message));
 const state=async()=>JSON.parse(await page.evaluate(()=>window.__adapterProbe.state()));
 const send=async text=>{await page.getByRole('textbox',{name:'Agent prompt',exact:true}).fill(text);await page.getByRole('button',{name:'Send agent prompt',exact:true}).click();await page.getByText('Authored reply: '+text,{exact:true}).waitFor();assert.equal(await page.locator('[data-chat-role=arAssistant] [data-chat-activity-status]').last().textContent(),'completed');};
 await page.goto(origin);await send('first');
 assert.deepEqual((await state()).prompts,['chat-1:first']);assert.deepEqual(requests,[]);
 await page.evaluate(()=>{window.__oldSend=document.querySelector('[aria-label="Send agent prompt"]');window.__adapterProbe.unmount();});
 const retained=await state();assert.equal(await page.locator('[data-preview-center-column]').count(),0);
 await page.evaluate(()=>window.__oldSend.click());assert.deepEqual(await state(),retained);
 assert.equal(await page.evaluate(()=>window.__adapterProbe.focusComposer()),false);
 await page.evaluate(()=>window.__adapterProbe.remount());
 assert.deepEqual(await state(),retained);
 assert.equal(await page.evaluate(()=>window.__adapterProbe.focusComposer()),true);
 assert.equal(await page.getByRole('textbox',{name:'Agent prompt',exact:true}).evaluate(n=>document.activeElement===n),true);
 await send('after remount');
 await page.evaluate(()=>window.__adapterProbe.newChat());await send('new conversation');
 assert.deepEqual((await state()).prompts,['chat-1:first','chat-1:after remount','chat-2:new conversation']);
 assert.equal((await state()).chats.length,2);assert.deepEqual(requests,[]);assert.deepEqual(errors,[]);
 const normal=await browser.newPage({viewport:{width:1440,height:900}});
 const daemonRequest=normal.waitForRequest(r=>new URL(r.url()).pathname==='/api/editor/rpc'&&r.method()==='POST');
 await normal.goto(origin+'/?default');
 await normal.getByRole('textbox',{name:'Agent prompt',exact:true}).fill('normal daemon transport');
 await normal.getByRole('button',{name:'Send agent prompt',exact:true}).click();
 await daemonRequest;
 await normal.waitForFunction(()=>JSON.parse(window.__adapterProbe.state()).chats[0].status==='asError');
 await normal.getByText('Editor control registration is unavailable.',{exact:true}).waitFor();
 assert.deepEqual(JSON.parse(await normal.evaluate(()=>window.__adapterProbe.state())).prompts,[]);
 console.log('PASS: explicit authored adapter survives remount/new conversations; stale controls inert; current control focus works; default requests actual control registration and reports its failure');
} finally {
 await browser?.close();server.kill();await new Promise(resolve=>server.once('exit',resolve));
}
