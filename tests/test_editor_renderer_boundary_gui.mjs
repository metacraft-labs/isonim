/** Real browser/DOMRenderer full-shell browser hook controls.
 * Authored ownership fixtures pass through the real normalizer/schema resolver;
 * this proves presentation and public frames, not native discovery/source/compiler
 * or Harbor E2E. No renderer, browser event or ownership outcome is mocked. */
import {spawn} from 'node:child_process';
import {mkdtempSync,readFileSync,writeFileSync,copyFileSync} from 'node:fs';
import {tmpdir} from 'node:os';
import path from 'node:path';
import {fileURLToPath} from 'node:url';
import assert from 'node:assert/strict';
import {createHash} from 'node:crypto';
import {chromium} from '../node_modules/playwright/index.mjs';
const repo=path.resolve(path.dirname(fileURLToPath(import.meta.url)),'..');
const root=mkdtempSync(path.join(process.env.ISONIM_POPUP_ARTIFACTS||tmpdir(),'renderer-boundary-'));
copyFileSync(repo+'/build/editor-renderer-boundaries/editor.js',root+'/editor.js');
writeFileSync(root+'/index.html','<!doctype html><html><head><style>html,body{height:100%;margin:0;overflow:hidden}</style></head><body><script src="editor.js"></script></body></html>');
const proof={head:process.env.ISONIM_TEST_HEAD,sourceState:process.env.ISONIM_TEST_SOURCE_STATE,
 bundleSha256:createHash('sha256').update(readFileSync(root+'/editor.js')).digest('hex'),cases:[],errors:[],requests:[]};
const server=spawn('python3',['-u','-m','http.server','0','--bind','127.0.0.1','--directory',root],{stdio:['ignore','pipe','pipe']});
let browser;
try{
 const origin=await new Promise((resolve,reject)=>{let text='';server.stdout.on('data',d=>{text+=d;const m=text.match(/port (\d+)/);if(m)resolve('http://127.0.0.1:'+m[1]);});server.once('exit',c=>reject(Error('server exit '+c)));setTimeout(()=>reject(Error('server startup timeout')),10000).unref();});
 const env={...process.env};delete env.LD_LIBRARY_PATH;
 browser=await chromium.launch({headless:true,env,executablePath:process.env.PLAYWRIGHT_CHROMIUM_EXECUTABLE});
 const page=await browser.newPage({viewport:{width:1440,height:900}});page.setDefaultTimeout(30000);
 page.on('pageerror',e=>proof.errors.push(e.message));page.on('request',r=>{if(new URL(r.url()).pathname.startsWith('/api/'))proof.requests.push(r.url());});
 await page.goto(origin,{waitUntil:"load"});await page.waitForFunction(()=>window.__rendererBoundary);
 const state=async()=>JSON.parse(await page.evaluate(()=>window.__rendererBoundary.state()));
 const canvas=page.locator('[data-figma-canvas="true"]');assert.equal(await canvas.count(),1);await canvas.waitFor({state:'visible'});
 const box=await canvas.boundingBox();assert(box&&box.width>0&&box.height>0);
 const viewport=page.viewportSize();const point={x:(Math.max(0,box.x)+Math.min(viewport.width,box.x+box.width))/2,y:(Math.max(0,box.y)+Math.min(viewport.height,box.y+box.height))/2};
 assert(await canvas.evaluate((el,p)=>el.contains(document.elementFromPoint(p.x,p.y)),point));
 const before=await state();await page.mouse.move(point.x,point.y);await page.mouse.wheel(37,83);
 await page.waitForFunction(before=>{const s=JSON.parse(window.__rendererBoundary.state());return s.panX!==before.panX||s.panY!==before.panY||s.zoom!==before.zoom;},before);
 assert.equal(await canvas.evaluate(el=>getComputedStyle(el).cursor),'grab');
 proof.cases.push('real full-shell Storyboard wheel changes production navigation state and retains actual DOM canvas cursor');
 assert.equal(await page.evaluate(()=>window.__rendererBoundary.stage(0)),true);
 const frame=page.locator('iframe[data-component-project-frame="true"]');assert.equal(await frame.count(),1);await frame.waitFor({state:'visible'});
 proof.mountBefore={state:await state(),frame:await frame.evaluate(el=>({srcdoc:el.srcdoc,ready:el.contentDocument?.readyState,body:el.contentDocument?.body?.innerHTML,connected:el.isConnected}))};
 await frame.contentFrame().getByRole('button',{name:'Fixture action',exact:true}).click();
 await page.waitForFunction(()=>JSON.parse(window.__rendererBoundary.state()).tag==='button');
 const visibility=page.getByRole('button',{name:'Toggle selection visibility',exact:true});assert.equal(await visibility.count(),1);
 await visibility.click();assert.equal((await state()).visible,false);
 await frame.contentFrame().getByRole('button',{name:'Fixture action',exact:true}).waitFor({state:'hidden'});
 await visibility.click();assert.equal((await state()).visible,true);
 await frame.contentFrame().getByRole('button',{name:'Fixture action',exact:true}).waitFor({state:'visible'});
 const mounted=await state();assert(mounted.mounts>0);
 await page.evaluate(()=>window.__rendererBoundary.reload());
 await page.waitForFunction(before=>{const s=JSON.parse(window.__rendererBoundary.state());return s.mounts>before.mounts&&s.unmounts>before.unmounts;},mounted);
 await frame.contentFrame().getByRole('button',{name:'Fixture action',exact:true}).waitFor({state:'visible'});
 const header=page.locator('[data-inspector-section-header="source"]');await header.click();
 const expanded=await header.getAttribute('aria-expanded');await header.press('Space');assert.notEqual(await header.getAttribute('aria-expanded'),expanded);
 await header.press('Tab');assert.notEqual(await header.getAttribute('aria-expanded'),expanded);
 proof.cases.push('actual iframe load/selection bridge normalizes physical selection; typed-host visibility dispatch affects preview; Source keyboard activation stays live');
 assert.equal(await page.evaluate(()=>window.__rendererBoundary.stage(1)),true);
 const pageFrames=page.locator('iframe[data-page-project-frame="true"]');assert.equal(await pageFrames.count(),1);await pageFrames.waitFor({state:'visible'});
 assert.equal(await pageFrames.contentFrame().getByRole('button',{name:'Fixture action',exact:true}).count(),1);
 assert.equal(await page.evaluate(()=>window.__rendererBoundary.stage(2)),true);
 const categories=page.locator('[data-foundation-category]');assert((await categories.count())>1);
 await categories.nth(1).click();assert.equal(await categories.nth(1).getAttribute('aria-pressed'),'true');assert.equal(await categories.nth(0).getAttribute('aria-pressed'),'false');
 proof.cases.push('actual Page and Foundations renderer branches preserve preview and physical category DOM/VM controls');
 const toolbar=page.locator('[data-browser-boundary-toolbar="true"]');
 const link=toolbar.locator('[data-spec-editor-toolbar-button="link"]');assert.equal(await link.count(),1);await link.click();
 const url=toolbar.getByRole('textbox',{name:'Link URL',exact:true});await url.fill('https://example.test/');await url.press('Escape');assert.equal((await state()).linkOpen,false);
 await link.click();await url.fill('https://example.test/');await url.press('Enter');assert.equal((await state()).linkOpen,false);
 proof.cases.push('actual DOM toolbar Event-typed Enter/Escape works with absent optional TipTap editor; genuine preview mount callback is replaced/disposed on real iframe reload');
 assert.equal((await state()).pending,0);assert.equal((await state()).messages,0);
 assert.deepEqual(proof.errors,[]);// Read-only discovery polling is recorded, not mistaken for source/model writes.
 assert(proof.requests.every(url=>!url.includes("/agent")&&!url.includes("/inspector")));
}finally{
 if(browser)await browser.close();server.kill('SIGTERM');await new Promise(resolve=>server.once('exit',resolve));
 writeFileSync(root+'/proof-final.json',JSON.stringify(proof,null,2));console.log(root+'/proof-final.json');
}
