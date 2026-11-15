/** Edits made within one auto-save debounce undo and redo one by one in the
 * packaged editor example (isonim-pm issue
 * 2026-10-23-undo-is-refused-after-a-batched-write-to-a-single-line-rule;
 * editor spec "Saving": undo/redo works across automatic saves, and edits
 * written together undo one by one, as when each is written separately).
 * Adapted from the reproduction written in the review of the fix.
 * The real packaged editor (`just editor-build`, src/isonim/editor/main.nim)
 * served statically, with its production example writer
 * (demo_workspace.demoVectorEditAdapter) over the example's foundation
 * source, whose `.long-tail-card` rule holds every declaration on one line.
 * Physical pointer and keyboard input; nothing is mocked. The page clock is
 * Playwright's fake clock, paused so the three commits fall in ONE 900ms
 * debounce whatever the host load, then advanced to fire each save.
 * Order: overflow Hidden, aspect-ratio 4 / 3, overflow Scroll -- the issue's
 * (1, 2, 3) shape on two declarations of the one-line rule. Then undo three
 * times and redo three times, each step written and compared with the bytes
 * the separate writes leave.
 */
import {spawn} from 'node:child_process';
import {mkdtempSync,writeFileSync} from 'node:fs';
import {createServer} from 'node:net';
import {chromium} from '../node_modules/playwright/index.mjs';
import assert from 'node:assert/strict';
import path from 'node:path';
import {tmpdir} from 'node:os';
import {fileURLToPath} from 'node:url';
const repo=path.resolve(path.dirname(fileURLToPath(import.meta.url)),'..');
const root=mkdtempSync(path.join(process.env.ISONIM_POPUP_ARTIFACTS||tmpdir(),'undo-batch-'));
const port=process.env.ISONIM_GUI_PORT?Number(process.env.ISONIM_GUI_PORT):await new Promise((resolve,reject)=>{const probe=createServer();probe.once('error',reject);probe.listen(0,'127.0.0.1',()=>{const {port}=probe.address();probe.close(()=>resolve(port));});});
const server=spawn(process.execPath,[repo+'/tests/browser/tools/static_server.mjs',repo+'/build/editor',String(port)],{stdio:'ignore'});
const proof={head:process.env.ISONIM_TEST_HEAD||'working copy',sourceState:process.env.ISONIM_TEST_SOURCE_STATE||'working copy',steps:[],errors:[]};
const record=()=>writeFileSync(root+'/proof.json',JSON.stringify(proof,null,2));
let browser;
try{
 const origin='http://127.0.0.1:'+port;
 for(let a=0;;a++){try{if((await fetch(origin+'/index.html')).ok)break;}catch(e){if(a>100)throw e;}await new Promise(r=>setTimeout(r,100));}
 const chromeEnv={...process.env};delete chromeEnv.LD_LIBRARY_PATH;
 browser=await chromium.launch({headless:true,env:chromeEnv,executablePath:process.env.PLAYWRIGHT_CHROMIUM_EXECUTABLE});
 const page=await browser.newPage({viewport:{width:1440,height:900}});page.setDefaultTimeout(60000);
 page.on('pageerror',e=>proof.errors.push(e.message));
 await page.clock.install();
 await page.goto(origin+'/');
 await page.getByRole('button',{name:'Open Components section'}).click();
 await page.getByRole('button',{name:'Toggle DestinationCard stories'}).click();
 await page.locator('[aria-label="Select story DestinationCard / Default"]').click();
 await page.locator('[aria-label="Preview mode"]').getByRole('button',{name:'Switch to edit mode',exact:true}).click();
 await page.frameLocator('iframe[title="Editable component preview"]').locator('[data-testid="component-edit-preview"]').click();
 const file='examples/wanderlust/design-system/foundations.css';
 const source=()=>page.evaluate(f=>(window.__isonimDemoSources||{})[f],file);
 const pending=()=>page.evaluate(()=>window.__isonimEditor.pendingSourceEdits());
 const saveError=()=>page.evaluate(()=>{const e=document.querySelector('[data-save-error]');return e?(e.getAttribute('title')||e.textContent||'').trim():'';});
 const overflow=page.locator('[data-property-row="overflow"]').first();
 const aspect=page.locator('[data-property-row="aspect-ratio"]').first();
 await overflow.waitFor({state:'visible'});
 // The page exposes the source on its first read: the row's actions menu
 // reads it.
 await overflow.locator('[data-property-row-field-label="true"]').click({button:'right'});
 await page.keyboard.press('Escape');
 const original=await source();
 assert(original&&original.includes('.long-tail-card {'),'the example source is exposed');
 assert(original.includes(' overflow: visible;')&&original.includes(' aspect-ratio: auto;'));
 const s1=original.replace(' overflow: visible;',' overflow: hidden;');
 const s2=s1.replace(' aspect-ratio: auto;',' aspect-ratio: 4 / 3;');
 const s3=s2.replace(' overflow: hidden;',' overflow: scroll;');
 const states=[original,s1,s2,s3];
 const chooseOverflow=async label=>{
  await overflow.locator('[data-choice-group-trigger]').click();
  await overflow.locator('[role="option"][data-choice-group-option-label="'+label+'"]').click();
 };
 // Freeze page time: no automatic save can fire until it is advanced.
 const now=await page.evaluate(()=>Date.now());
 await page.clock.pauseAt(now+5000);
 await chooseOverflow('Hidden');
 const input=aspect.locator('[data-property-row-input="true"]');
 await input.click();await input.fill('4 / 3');await input.press('Enter');
 await chooseOverflow('Scroll');
 assert.equal(await source(),original,'nothing was written before the debounce fired (one batch)');
 proof.steps.push({step:'three commits in one debounce window',pending:await pending()});
 await page.evaluate(()=>document.activeElement?.blur());
 await page.clock.runFor(1500);
 assert.equal(await pending(),0,'the debounced save wrote the batch');
 assert.equal(await source(),s3,'one write leaves the history-order result');
 proof.steps.push({step:'one write',ok:true});record();
 const step=async(keys,k,label)=>{
  await page.keyboard.press(keys);
  await page.clock.runFor(1500);
  const got=await source();const err=await saveError();
  proof.steps.push({step:label+' -> state '+k,match:got===states[k],saveError:err,pending:await pending()});record();
  assert.equal(err,'',label+' to state '+k+' is not refused');
  assert.equal(got,states[k],label+' to state '+k+' leaves the file exactly where separate writes would');
 };
 for(let k=2;k>=0;k--)await step('ControlOrMeta+Z',k,'undo');
 for(let k=1;k<=3;k++)await step('ControlOrMeta+Shift+Z',k,'redo');
 assert.deepEqual(proof.errors,[]);
 proof.result='PASS';record();
 console.log('Editor undo-batch GUI passed: '+root+' '+proof.steps.length);
}catch(e){proof.result='FAIL: '+e.message;record();console.error('Editor undo-batch GUI FAILED:',e.message);process.exitCode=1;}
finally{if(browser)await browser.close();server.kill('SIGTERM');}
