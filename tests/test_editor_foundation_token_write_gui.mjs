/** A Foundations token edit writes only that token's declaration (Chromium).
 *
 * isonim-pm issue 2026-11-23-a-foundation-token-edit-rewrites-every-token-
 * that-shares-its-old-value; editor spec "Native project source
 * capabilities" (editing a token changes its owner declaration and keeps the
 * use-site `var()` binding) and "Saving" (an applied edit is written
 * automatically; an edit changes exactly the one owning declaration).
 *
 * The example's foundation source declares `--wl-type-body-size` and
 * `--wl-space-card` both as `16px`. Through the Foundations page's real
 * value field and Apply button, and the editor's real auto-save, over the
 * example's production writer (`demo_workspace.demoVectorEditAdapter`, in
 * the shorthand-order host, `tests/helpers/editor_shorthand_order_workspace.nim`):
 *   1. one edit of `space.card` to `20px` writes that declaration and leaves
 *      `--wl-type-body-size: 16px;`;
 *   2. two edits made inside one auto-save debounce (the page clock paused),
 *      `type.body.size` to `18px` and `space.card` to `24px`, are written
 *      together by one save, and nothing else in the file changes;
 *   3. with a second `--wl-space-card` declaration in the file (appended
 *      through the host's `__isonimShorthandExtraCss` knob), an edit of
 *      `space.card` is refused at Apply with the writer's reason shown in the
 *      page's diagnostics, nothing is staged or written, and a following
 *      `type.body.size` edit is written.
 * No mocks; external requests aborted.
 */
import {createServer} from 'node:http';
import {mkdtempSync,readFileSync,copyFileSync,existsSync,writeFileSync} from 'node:fs';
import {chromium} from '../node_modules/playwright/index.mjs';
import assert from 'node:assert/strict';
import path from 'node:path';
import {tmpdir} from 'node:os';
import {fileURLToPath} from 'node:url';
const repo=path.resolve(path.dirname(fileURLToPath(import.meta.url)),'..');
const bundle=repo+'/build/editor-shorthand/editor.js';
assert(existsSync(bundle),'build the host first: nim js -o:build/editor-shorthand/editor.js tests/helpers/editor_shorthand_order_workspace.nim');
const pub=mkdtempSync(path.join(process.env.ISONIM_POPUP_ARTIFACTS||tmpdir(),'foundation-token-write-'));
copyFileSync(bundle,pub+'/editor.js');
for(const [from,to] of [['node_modules/fabric/dist/index.min.js','fabric.min.js'],['node_modules/paper/dist/paper-core.min.js','paper-core.min.js'],['node_modules/svgo/dist/svgo.browser.js','svgo.browser.js']])copyFileSync(repo+'/'+from,pub+'/'+to);
const index=readFileSync(repo+'/src/isonim/editor/index.html','utf8');
let knobs={};
const page=()=>index.replace('<script src="editor.js"></script>','<script>'+Object.entries(knobs).map(([k,v])=>'window.'+k+'='+JSON.stringify(v)+';').join('')+'</script><script src="editor.js"></script>');
const server=createServer((req,res)=>{const url=new URL(req.url,'http://x');const name=url.pathname==='/'?'index.html':url.pathname.slice(1);
  if(name==='index.html'){res.writeHead(200,{'content-type':'text/html'});res.end(page());return;}
  const file=path.join(pub,path.basename(name));if(!existsSync(file)){res.writeHead(404);res.end();return;}
  res.writeHead(200,{'content-type':file.endsWith('.js')?'text/javascript':'application/octet-stream'});res.end(readFileSync(file));});
await new Promise(resolve=>server.listen(Number(process.env.ISONIM_FOUNDATION_TOKEN_PORT||0),'127.0.0.1',resolve));
const origin='http://127.0.0.1:'+server.address().port;
const foundation='examples/wanderlust/design-system/foundations.css';
const proof={head:process.env.ISONIM_TEST_HEAD||'working copy',cases:[],failures:[],errors:[]};
let browser;
try {
  const env={...process.env};delete env.LD_LIBRARY_PATH;
  browser=await chromium.launch({headless:true,env,executablePath:process.env.PLAYWRIGHT_CHROMIUM_EXECUTABLE});
  const p=await browser.newPage({viewport:{width:1440,height:900}});p.setDefaultTimeout(60000);
  await p.clock.install();
  p.on('pageerror',e=>proof.errors.push(e.message));
  await p.route(url=>!url.href.startsWith(origin),route=>route.abort());
  const source=()=>p.evaluate(f=>window.__isonimDemoSources?.[f]??'',foundation);
  const pending=()=>p.evaluate(()=>Number(window.__isonimEditor.pendingSourceEdits()));
  async function poll(read,expected,ms=60000){const deadline=Date.now()+ms;let last;while(Date.now()<deadline){last=await read();try{assert.deepEqual(last,expected);return {ok:true,last};}catch{}await new Promise(r=>setTimeout(r,150));}return {ok:false,last};}
  async function open(withKnobs={}){
    knobs=withKnobs;
    await p.goto(origin+'/');
    await p.getByRole('button',{name:'Open Foundations section'}).click();
    const toggle=p.getByRole('button',{name:'Toggle Foundations stories'});
    if(await toggle.count())await toggle.click();
    await p.getByRole('button',{name:'Select story Foundations / Colors'}).click();
    await p.locator('[data-foundations-page="true"]').waitFor();
  }
  async function apply(category,key,value){
    await p.getByRole('button',{name:'Select foundation category '+category,exact:true}).click();
    await p.locator('[data-foundation-token="'+key+'"]').click();
    const field=p.getByRole('textbox',{name:'Foundation token value',exact:true});
    await field.fill(value);
    await p.getByRole('button',{name:'Apply foundation token value',exact:true}).click();
  }
  async function caseRun(name,fn){const trail=[];try{await fn(trail);proof.cases.push({name,ok:true,trail});}catch(error){proof.cases.push({name,ok:false,trail,error:String(error.message)});proof.failures.push(name+': '+error.message);}}

  await caseRun('one edit writes that token only',async(trail)=>{
    await open();
    const before=await source();
    assert.match(before,/--wl-type-body-size: 16px;/);
    assert.match(before,/--wl-space-card: 16px;/);
    await apply('Spacing','space.card','20px');
    const want=before.replace('--wl-space-card: 16px;','--wl-space-card: 20px;');
    const written=await poll(source,want);
    trail.push({after:(written.last.match(/--wl-[a-z-]+:[^;]*;/g)||[]).join(' ')});
    assert.ok(written.ok,'only --wl-space-card changes: '+JSON.stringify(written.last.split('.destination-card')[0]));
    assert.equal(await pending(),0,'nothing is left pending');
  });

  await caseRun('two edits inside one debounce are written together',async(trail)=>{
    await open();
    const before=await source();
    const now=await p.evaluate(()=>Date.now());
    await p.clock.pauseAt(now+60000);
    let pendingBefore=-1;
    try{
      await apply('Typography','type.body.size','18px');
      await apply('Spacing','space.card','24px');
      pendingBefore=await pending();
    }finally{await p.clock.resume();}
    assert.equal(pendingBefore,2,'both edits are pending before the save');
    const want=before.replace('--wl-type-body-size: 16px;','--wl-type-body-size: 18px;')
      .replace('--wl-space-card: 16px;','--wl-space-card: 24px;');
    const written=await poll(source,want);
    trail.push({after:(written.last.match(/--wl-[a-z-]+:[^;]*;/g)||[]).join(' ')});
    assert.ok(written.ok,'both tokens are written and nothing else: '+JSON.stringify(written.last.split('.destination-card')[0]));
    const diagnostics=await p.locator('[data-save-indicator], [data-workspace-edit-diagnostic]').allTextContents().catch(()=>[]);
    trail.push({diagnostics});
    assert.equal(await pending(),0,'nothing is left pending');
  });

  await caseRun('a token declared twice is refused at Apply; a later edit is written',async(trail)=>{
    await open({__isonimShorthandExtraCss:'.compact { --wl-space-card: 16px; }\n'});
    const before=await source();
    assert.equal((before.match(/--wl-space-card:/g)||[]).length,2,'the file declares the token twice');
    await apply('Spacing','space.card','20px');
    const reason=foundation+' has 2 --wl-space-card declarations, so the one this edit owns cannot be identified. Nothing was changed.';
    const shown=await poll(()=>p.locator('[data-foundation-diagnostics="true"]').textContent().then(t=>t.includes(reason)),true);
    trail.push({diagnostics:(await p.locator('[data-foundation-diagnostics="true"]').textContent()).trim()});
    assert.ok(shown.ok,'the writer\'s reason is shown');
    assert.equal(await pending(),0,'nothing is staged');
    assert.equal(await source(),before,'nothing is written');
    await apply('Typography','type.body.size','18px');
    const want=before.replace('--wl-type-body-size: 16px;','--wl-type-body-size: 18px;');
    const written=await poll(source,want);
    assert.ok(written.ok,'the later edit is written: '+JSON.stringify(written.last.split('.destination-card')[0]));
    assert.equal(await pending(),0,'nothing is left pending');
  });
} catch(error) {
  proof.failures.push('harness: '+error.message);
} finally {
  await browser?.close();
  server.close();
  writeFileSync(path.join(pub,'proof.json'),JSON.stringify(proof,null,2));
  console.log(JSON.stringify(proof,null,2));
}
if(proof.failures.length||proof.errors.length){console.error('FAILED: '+proof.failures.concat(proof.errors).join('\n'));process.exit(1);}
console.log('PASSED test_editor_foundation_token_write_gui ('+proof.cases.length+' cases)');
