/** Reset, set, undo, undo in the packaged editor example (isonim-pm issue
 * 2026-10-16-editor-example-writer-re-sets-a-reset-property-outside-any-rule;
 * editor spec "Universal Patterns": Reset is "written and undoable like any
 * edit", and setting the property again writes a declaration inside the rule
 * that owns it, so the value applies to the element).
 * The real packaged editor (`just editor-build`, src/isonim/editor/main.nim)
 * served statically, with its production example writer
 * (demo_workspace.demoVectorEditAdapter) writing the example's foundation
 * source, which the page exposes as window.__isonimDemoSources after every
 * read and write. Physical pointer and keyboard input; nothing is mocked.
 * The destination card's padding row: Reset removes `padding: 18px;` from
 * `.destination-card { ... }`, a typed 20px is inserted back into that rule,
 * and undo, undo return the exact bytes.
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
const root=mkdtempSync(path.join(process.env.ISONIM_POPUP_ARTIFACTS||tmpdir(),'example-reset-'));
const port=await new Promise((resolve,reject)=>{const probe=createServer();probe.once('error',reject);probe.listen(0,'127.0.0.1',()=>{const {port}=probe.address();probe.close(()=>resolve(port));});});
const server=spawn(process.execPath,[repo+'/tests/browser/tools/static_server.mjs',repo+'/build/editor',String(port)],{stdio:'ignore'});
const proof={head:process.env.ISONIM_TEST_HEAD||'working copy',sourceState:process.env.ISONIM_TEST_SOURCE_STATE||'working copy',cases:[],errors:[]};
const record=name=>{proof.cases.push(name);writeFileSync(root+'/proof-partial.json',JSON.stringify(proof,null,2));};
let browser;
try {
 const origin='http://127.0.0.1:'+port;
 for(let attempt=0;;attempt++){try{const reply=await fetch(origin+'/index.html');if(reply.ok)break;}catch(error){if(attempt>100)throw error;}await new Promise(resolve=>setTimeout(resolve,100));}
 const chromeEnv={...process.env};delete chromeEnv.LD_LIBRARY_PATH;
 browser=await chromium.launch({headless:true,env:chromeEnv,executablePath:process.env.PLAYWRIGHT_CHROMIUM_EXECUTABLE});
 const page=await browser.newPage({viewport:{width:1440,height:900}});page.setDefaultTimeout(30000);
 page.on('pageerror',error=>proof.errors.push(error.message));
 await page.goto(origin+'/');
 await page.getByRole('button',{name:'Open Components section'}).click();
 await page.getByRole('button',{name:'Toggle DestinationCard stories'}).click();
 await page.locator('[aria-label="Select story DestinationCard / Default"]').click();
 await page.locator('[aria-label="Preview mode"]').getByRole('button',{name:'Switch to edit mode',exact:true}).click();
 await page.frameLocator('iframe[title="Editable component preview"]').locator('[data-testid="component-edit-preview"]').click();
 const file='examples/wanderlust/design-system/foundations.css';
 const source=()=>page.evaluate(file=>(window.__isonimDemoSources||{})[file],file);
 const settled=()=>page.waitForFunction(()=>window.__isonimEditor.pendingSourceEdits()===0,null,{timeout:30000});
 const undoCount=()=>page.evaluate(()=>window.__isonimEditorVm.inspector.undoStack.value.length);
 const row=page.locator('[data-property-row="padding"][data-property-row-css-property="padding"]').first();
 // The destination card's own properties are in its Component properties
 // section, collapsed by default.
 if(!(await row.isVisible()))await page.locator('[data-inspector-section-header="component-properties"]').click();
 await row.waitFor({state:'visible'});
 const input=row.locator('[data-property-row-input="true"]');
 const label=row.locator('[data-property-row-field-label="true"]');
 const menu=row.locator('[data-property-actions-menu="true"]');
 const reset=menu.getByRole('menuitem',{name:'Reset'});
 // The page exposes the source on its first read; Reset's menu reads it.
 await label.click({button:'right'});await menu.waitFor({state:'visible'});
 const original=await source();
 assert(original&&original.includes('.destination-card { padding: 18px; }\n'),'the example source is exposed');
 const removed=original.replace('.destination-card { padding: 18px; }','.destination-card { }');
 const set=original.replace('.destination-card { padding: 18px; }','.destination-card { padding: 20px; }');
 const start=await undoCount();
 assert.equal(await reset.getAttribute('aria-disabled'),'false');
 await reset.click();await settled();
 assert.equal(await source(),removed,'Reset removes exactly the padding declaration');
 assert.equal(await undoCount(),start+1);
 record('Reset removes the destination card padding declaration through the example writer');

 await input.click();await input.fill('20px');await input.press('Enter');await settled();
 assert.equal(await undoCount(),start+2);
 assert.equal(await source(),set,'Setting padding again writes it inside .destination-card, not after the rule');
 assert(!(await source()).includes('}\npadding:'),'nothing is appended outside the rule');
 record('after Reset a typed padding is written inside the .destination-card rule');

 await page.evaluate(()=>document.activeElement?.blur());
 await page.keyboard.press('ControlOrMeta+Z');await settled();
 await page.waitForFunction(count=>window.__isonimEditorVm.inspector.undoStack.value.length===count,start+1);
 assert.equal(await source(),removed,'Undo of the set removes exactly the inserted declaration');
 await page.keyboard.press('ControlOrMeta+Z');await settled();
 await page.waitForFunction(count=>window.__isonimEditorVm.inspector.undoStack.value.length===count,start);
 assert.equal(await source(),original,'Undo of the Reset restores the exact original bytes');
 record('undo, undo return to the exact original source');
 assert.deepEqual(proof.errors,[]);
 writeFileSync(root+'/proof.json',JSON.stringify(proof,null,2));console.log('Editor example Reset GUI passed:',root,proof.cases.length);
} finally {
 if(browser)await browser.close();
 server.kill('SIGTERM');
 writeFileSync(root+'/proof-final.json',JSON.stringify(proof,null,2));
}
