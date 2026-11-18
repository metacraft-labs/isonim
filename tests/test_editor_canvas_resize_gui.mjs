/** The selection overlay's resize handle moves the box edge by the distance
 * dragged, for `content-box` and `border-box` alike, at any preview scale,
 * and writes the `width` the box shows when `max-width` clamps it (Chromium).
 *
 * Editor spec "Edit Mode" ("resize handles on the selection box allow direct
 * width/height manipulation") and "Visual box model" (the overlay's resize
 * handles follow the drag contract: preview while the pointer moves, one
 * edit on release, Escape or pointer cancellation put back the value from
 * before the drag); operator ruling of 2026-11-08: a canvas handle edits the
 * property its row shows, so the drag starts from the used `width` in the box
 * `width` sets (https://www.w3.org/TR/css-sizing-3/#box-sizing). isonim-pm
 * issue 2026-10-23-the-canvas-resize-handle-sets-width-from-the-border-box.
 *
 * Every drag case asserts the preview during the drag, nothing committed
 * before release, the committed edit (one history entry), the written file,
 * and the restore on Escape or pointer cancellation.
 *
 * Round 2 (review residuals): the `height` handle and the absence of the
 * left/top corner handles (each handle moves the edge it sits on, a centred
 * box's edge included); "clamped" only for min-/max-*, and a press refused
 * with the reason where an `!important` rule or flex sizing holds the size,
 * or where the layout places the box from the handle's own edge; the margin
 * and padding handles placed on and following a zoomed card's edges; a
 * percentage gap dragged from its used pixels; the overlay on its element
 * under a transform on `body`; every handle refused on a rotated or skewed
 * element.
 *
 * Round 3 adds a trial size that wraps the card's line, a transition on the
 * size, and the trials on a scrolled page. Round 4 adds:
 *   - a wrap the press sees with no smaller trial to try, refused as a wrap;
 *   - the spacing, margin and padding handles holding a transition, as the
 *     resize handles do;
 *   - a keyframe animation of the width, named as what decides it.
 *
 * One stand-in, used only by the round-5 delayed-answer cases. A native project
 * answers a box handle's commit later, and the example's writer answers at
 * once, so those cases intercept the commit's request in the editor page
 * (`window.__holdCommits`) and call its `settle` themselves later. That is
 * the late answer the preview bridge waits for. The intercepted commit
 * writes nothing, and the cases assert only the preview and the transition
 * holds. Everything else below uses no mocks.
 *
 * The host is the shorthand-order host
 * (`tests/helpers/editor_shorthand_order_workspace.nim`: the editor example
 * with its real writer, preview document and selection bridge) with the card
 * rule's `width` mapped. Two things are set from outside the code under test,
 * and neither replaces any of it:
 *   - the 50% and 200% cases scale the component preview's device frame with
 *     a stylesheet in the editor page. The component view has no zoom control
 *     (spec "Preview Sizing And Zoom", open decision D4); its fit-to-column
 *     scale and the page preview's zoom are both a `scale()` transform on the
 *     frame, which is what the stylesheet sets.
 *   - the scaled-element, body-transform, rotation and flex cases put CSS in
 *     the preview's document (`__isonimShorthandPrefixCss`, before the
 *     example's rules), not in the written file; the percentage-gap case
 *     adds a style element to the preview document after it loads, because
 *     the example's later `.long-tail-card` rule sets `display` and `gap`.
 * External requests are aborted so the run is offline.
 */
import {createServer} from 'node:http';
import {mkdtempSync,readFileSync,copyFileSync,existsSync} from 'node:fs';
import {chromium} from '../node_modules/playwright/index.mjs';
import assert from 'node:assert/strict';
import path from 'node:path';
import {tmpdir} from 'node:os';
import {fileURLToPath} from 'node:url';
const repo=path.resolve(path.dirname(fileURLToPath(import.meta.url)),'..');
const bundle=repo+'/build/editor-shorthand/editor.js';
assert(existsSync(bundle),'build the host first: nim js -o:build/editor-shorthand/editor.js tests/helpers/editor_shorthand_order_workspace.nim');
const pub=mkdtempSync(path.join(process.env.ISONIM_POPUP_ARTIFACTS||tmpdir(),'canvas-resize-'));
copyFileSync(bundle,pub+'/editor.js');
for(const [from,to] of [['node_modules/fabric/dist/index.min.js','fabric.min.js'],['node_modules/paper/dist/paper-core.min.js','paper-core.min.js'],['node_modules/svgo/dist/svgo.browser.js','svgo.browser.js']])copyFileSync(repo+'/'+from,pub+'/'+to);
const index=readFileSync(repo+'/src/isonim/editor/index.html','utf8');
let rule='',prefixCss='',sourceReplace='',readOnly='';
const page=()=>index.replace('<script src="editor.js"></script>','<script>window.__isonimShorthandCardRule='+JSON.stringify(rule)+';window.__isonimShorthandPrefixCss='+JSON.stringify(prefixCss)+';window.__isonimShorthandSourceReplace='+JSON.stringify(sourceReplace)+';window.__isonimShorthandReadOnly='+JSON.stringify(readOnly)+';window.__isonimShorthandMapped="width,height";</script><script src="editor.js"></script>');
const types={'.js':'text/javascript','.html':'text/html'};
const server=createServer((req,res)=>{const url=new URL(req.url,'http://x');const name=url.pathname==='/'?'index.html':url.pathname.slice(1);
  if(name==='index.html'){res.writeHead(200,{'content-type':'text/html'});res.end(page());return;}
  const file=path.join(pub,path.basename(name));if(!existsSync(file)){res.writeHead(404);res.end();return;}
  res.writeHead(200,{'content-type':types[path.extname(file)]||'application/octet-stream'});res.end(readFileSync(file));});
// A fixed port when one is given (ISONIM_CANVAS_RESIZE_PORT), otherwise any.
await new Promise(resolve=>server.listen(Number(process.env.ISONIM_CANVAS_RESIZE_PORT||0),'127.0.0.1',resolve));
const origin='http://127.0.0.1:'+server.address().port;
const foundation='examples/wanderlust/design-system/foundations.css';
const cases=[],errors=[];
let browser;
try {
  const env={...process.env};delete env.LD_LIBRARY_PATH;
  browser=await chromium.launch({headless:true,env,executablePath:process.env.PLAYWRIGHT_CHROMIUM_EXECUTABLE});
  const p=await browser.newPage({viewport:{width:1440,height:900}});p.setDefaultTimeout(30000);
  p.on('pageerror',e=>errors.push(e.message));
  // The delayed-answer stand-in (see the header): off unless a case sets it.
  await p.addInitScript(()=>{if(window.top!==window)return;window.__held=[];window.__holdCommits=false;window.addEventListener('isonim-preview-box-drag',e=>{if(e.detail&&e.detail.phase==='commit'&&window.__holdCommits){e.stopImmediatePropagation();e.detail.reply='pending';window.__held.push(e.detail.settle);}},true);});
  await p.route(url=>!url.href.startsWith(origin),route=>route.abort());
  const frame=()=>p.frameLocator('iframe[title="Editable component preview"]');
  const card=()=>frame().getByTestId('component-edit-preview');
  const AXIS={width:{label:'Resize selected element',edge:'right',x:true},height:{label:'Adjust selected element height',edge:'bottom',x:false}};
  const handleOf=(axis='width')=>frame().getByLabel(AXIS[axis].label,{exact:true});
  const readout=()=>frame().getByLabel('Canvas spacing measurement');
  const note=()=>frame().locator('#isonim-editor-box-drag-message');
  const computed=(prop)=>card().evaluate((n,prop)=>getComputedStyle(n).getPropertyValue(prop),prop);
  // The card's border box in the preview document's client pixels.
  const cardRect=()=>card().evaluate((n)=>{const r=n.getBoundingClientRect();return {left:r.left,top:r.top,right:r.right,bottom:r.bottom,width:r.width,height:r.height};});
  const source=()=>p.evaluate(f=>window.__isonimDemoSources?.[f]??'',foundation);
  const cardRule=async()=>(await source()).match(/\.destination-card \{[^}]*\}/)[0];
  const pending=()=>p.evaluate(()=>window.__isonimEditor.pendingSourceEdits());
  const undoCount=()=>p.evaluate(()=>window.__isonimEditorVm.inspector.undoStack.value.length);
  // Screen (editor page) pixels per preview CSS pixel: the fit-to-column or
  // zoom transform on the frame.
  const frameScale=()=>p.evaluate(()=>{const n=document.querySelector('iframe[title="Editable component preview"]');return n.getBoundingClientRect().width/n.contentWindow.innerWidth;});
  // 60s: on a loaded host an automatic write can take well over 20s to settle.
  async function assertPoll(read,expected,what){
    const deadline=Date.now()+60000;let last;
    while(Date.now()<deadline){last=await read();try{assert.deepEqual(last,expected);return;}catch{}await p.waitForTimeout(100);}
    assert.deepEqual(last,expected,what);
  }
  // A physical click on the card itself (not its heading or text): the
  // first point, scanning its box, that hits the card, which also holds on
  // a rotated or skewed card.
  async function select(){
    const at=await card().evaluate(n=>{const r=n.getBoundingClientRect();for(let y=r.top+3;y<r.bottom;y+=4)for(let x=r.left+3;x<r.right;x+=4)if(document.elementFromPoint(x,y)===n)return {x,y};return null;});
    assert.ok(at,'a point of the card can be clicked');
    const f=await p.evaluate(()=>{const n=document.querySelector('iframe[title="Editable component preview"]');const r=n.getBoundingClientRect();return {x:r.x,y:r.y,s:r.width/n.contentWindow.innerWidth};});
    await p.mouse.click(f.x+at.x*f.s,f.y+at.y*f.s);
    await frame().locator('[data-isonim-selected="true"]').waitFor();
    await handleOf().waitFor();
  }
  async function open(startRule,{prefix='',zoom=0,replace='',readonly=false}={}){
    rule=startRule;prefixCss=prefix;sourceReplace=replace;readOnly=readonly?'1':'';
    await p.goto(origin+'/');
    await p.getByRole('button',{name:'Open Components section'}).click();
    await p.getByRole('button',{name:'Toggle DestinationCard stories'}).click();
    await p.getByRole('button',{name:'Select story DestinationCard / Default'}).click();
    await p.getByRole('button',{name:'Switch to edit mode'}).click();
    if(zoom)await p.addStyleTag({content:'[data-component-edit-device-frame]{transform:scale('+zoom+') !important}'});
    await select();
    if(zoom)assert.ok(Math.abs(await frameScale()-zoom)<1e-6,'the preview is shown at '+zoom);
  }
  async function centre(locator){const b=await locator.boundingBox();if(!b)throw new Error('no box');return {x:b.x+b.width/2,y:b.y+b.height/2};}
  // Press a handle and move the pointer by `screen` editor-page pixels along
  // its axis in `steps` moves.
  async function dragOn(locator,dx,dy,steps=3){
    const {x,y}=await centre(locator);
    await p.mouse.move(x,y);
    await p.mouse.down();
    for(let i=1;i<=steps;i++)await p.mouse.move(x+dx*i/steps,y+dy*i/steps);
    return {x,y};
  }
  const drag=(screen,axis='width',steps=3)=>AXIS[axis].x?dragOn(handleOf(axis),screen,0,steps):dragOn(handleOf(axis),0,screen,steps);
  const handleAt=async(axis='width')=>{const c=await centre(handleOf(axis));return AXIS[axis].x?c.x:c.y;};
  const edge=async(axis='width')=>(await cardRect())[AXIS[axis].edge];
  // Count the transition events that reach page code on the card, from now
  // on. First the card settles: on a loaded host the editor's own preview
  // work after a selection can still be running, and nothing a handle does
  // has started yet. Every property is counted: the selection and hover
  // outlines are overlays, so they change nothing on the card.
  async function countTransitions(){
    await card().evaluate(n=>{window.__transitions=0;window.__tlog=[];if(!window.__tlisten){window.__tlisten=true;for(const t of ['transitionrun','transitionstart'])n.addEventListener(t,(e)=>{window.__transitions++;window.__tlog.push(e.type+':'+e.propertyName);});}});
    await p.waitForTimeout(300);
    await assertPoll(()=>card().evaluate(n=>n.getAnimations().length),0,'the card settles before the drag');
    await card().evaluate(()=>{window.__transitions=0;window.__tlog=[];});
  }
  const transitionLog=()=>card().evaluate(()=>window.__tlog.join(','));
  // A press that starts no drag: the reason on the canvas, nothing previewed,
  // committed or written.
  // (`animated`: the property changes by itself, so the check is that no
  // drag set it inline.)
  async function refusedAtPress(name,locator,why,prop='width',animated=false){
    const history=await undoCount();
    const before=await source();
    const value=await computed(prop);
    const inline=()=>card().evaluate((n,prop)=>n.style.getPropertyValue(prop),prop);
    const inline0=await inline();
    await dragOn(locator,0,0,1);
    await assertPoll(async()=>(await note().count())?await note().textContent():'(no reason shown)',why,name+': the reason at the press');
    // Moving the pointer now drags nothing.
    const {x,y}=await centre(locator);
    await p.mouse.move(x-20,y-20,{steps:2});
    if(animated)assert.equal(await inline(),inline0,name+': nothing previewed');
    else assert.equal(await computed(prop),value,name+': nothing previewed');
    await p.mouse.up();
    await p.waitForTimeout(1200);
    assert.equal(await undoCount(),history,name+': nothing committed');
    assert.equal(await source(),before,name+': nothing written');
    cases.push(name);
  }
  // A case: from `startRule` (whose `axis` is `start`), a drag of
  // `distance.screen` editor-page pixels, or `distance.css` of the preview
  // document's pixels, previews `axis: shown px`, writes it on release, and
  // Escape and pointer cancellation each put the committed value back. The
  // handle's edge follows the pointer, unless `opts.clamped`.
  async function resizeCase(name,startRule,start,distance,shown,opts={}){
    const axis=opts.axis||'width';
    await open(startRule,opts);
    const scale=await frameScale();
    const screen=distance.screen??distance.css*scale;
    const original=await source();
    const history=await undoCount();
    const edge0=await edge(axis),at0=await handleAt(axis);
    // While the pointer moves: the preview, the readout, the handle; nothing
    // committed or written.
    await drag(screen,axis);
    await assertPoll(()=>computed(axis),shown+'px',name+': preview '+axis);
    if(!opts.clamped){
      // The edge the handle sits on moves by the distance dragged, in the
      // preview document's pixels, and the handle with it on screen.
      const moved=await edge(axis)-edge0;
      assert.ok(Math.abs(moved-screen/scale)<1.01,name+': the edge followed the pointer ('+moved+' for '+screen/scale+')');
      assert.ok(Math.abs((await handleAt(axis)-at0)-screen)<1.51,name+': the handle follows the pointer ('+(await handleAt(axis)-at0)+' for '+screen+')');
    } else {
      // Clamped: the handle shows the clamped edge, not the pointer.
      assert.ok(Math.abs((await handleAt(axis)-at0)-(await edge(axis)-edge0)*scale)<1.01,name+': the handle shows the clamped edge');
      assert.ok(Math.abs(await edge(axis)-edge0-(shown-start))<1.01,name+': the edge stops at the clamp');
    }
    assert.equal(await readout().textContent(),opts.readout||(axis+': '+shown+'px'));
    assert.equal(await undoCount(),history,name+': nothing committed during the drag');
    assert.equal(await source(),original,name+': nothing written during the drag');
    await p.mouse.up();
    // One edit, written.
    const written=startRule.replace(new RegExp('(^|; )'+axis+': \\d+px;'),'$1'+axis+': '+shown+'px;');
    await assertPoll(async()=>[await pending(),await cardRule()],[0,'.destination-card { '+written+' }'],name+': written rule');
    assert.equal(await undoCount(),history+1,name+': one history entry');
    assert.equal(await source(),original.replace('.destination-card { '+startRule+' }','.destination-card { '+written+' }'),name+': only the '+axis+' changed in the file');
    await assertPoll(()=>computed(axis),shown+'px',name+': '+axis+' after the write');
    cases.push(name+': preview, one edit on release, written');
    // Escape puts the committed value back.
    if(!(await card().getAttribute('data-isonim-selected')))await select();
    await drag(-screen,axis);
    await assertPoll(async()=>(await computed(axis))!==shown+'px',true,name+': preview of the drag back');
    await p.keyboard.press('Escape');
    await assertPoll(()=>computed(axis),shown+'px',name+': Escape restores');
    await p.mouse.up();
    await p.waitForTimeout(300);
    assert.equal(await undoCount(),history+1,name+': Escape commits nothing');
    assert.equal(await pending(),0);
    assert.equal(await cardRule(),'.destination-card { '+written+' }');
    // So does pointer cancellation.
    await handleOf(axis).evaluate((node)=>node.addEventListener('pointerdown',(event)=>{window.__resizePointer=event.pointerId;},{once:true}));
    await drag(-screen,axis);
    await assertPoll(async()=>(await computed(axis))!==shown+'px',true,name+': the cancelled drag previews');
    await card().evaluate(()=>window.dispatchEvent(new PointerEvent('pointercancel',{pointerId:window.__resizePointer,bubbles:true})));
    await assertPoll(()=>computed(axis),shown+'px',name+': pointer cancellation restores');
    await p.mouse.up();
    await p.waitForTimeout(300);
    assert.equal(await undoCount(),history+1,name+': cancellation commits nothing');
    assert.equal(await cardRule(),'.destination-card { '+written+' }');
    cases.push(name+': Escape and pointer cancellation put the value back');
    return {history,original,written,scale};
  }

  const padded='padding: 24px; border: 1px solid #CBD5E1;';
  // 1. The issue: a padded content-box card. A drag 30px inwards shrinks the
  // border box by 30px (it grew by 20px from the border-box start).
  await resizeCase('content-box, 30px inwards','box-sizing: content-box; '+padded+' width: 300px;',300,{css:-30},270);
  // 2. The same for border-box: the box `width` sets is the border box.
  await resizeCase('border-box, 30px inwards','box-sizing: border-box; '+padded+' width: 300px;',300,{css:-30},270);
  // 3 and 4. The preview at 50% and 200%: the pointer moves in screen pixels,
  // the edge with it; the width changes by the distance in the preview's CSS
  // pixels (40 screen px are 80 CSS px at 50%, 20 at 200%).
  await resizeCase('content-box at 50%','box-sizing: content-box; '+padded+' width: 300px;',300,{screen:-40},220,{zoom:0.5});
  await resizeCase('content-box at 200%','box-sizing: content-box; '+padded+' width: 300px;',300,{screen:-40},280,{zoom:2});
  // 5. A card scaled inside the preview (CSS `zoom: 2` on it): the edge
  // still follows the pointer, so `width` changes by half the distance.
  await resizeCase('a card zoomed 2x in the preview','box-sizing: content-box; '+padded+' width: 200px;',200,{css:-40},180,{prefix:'.destination-card{zoom:2}'});
  // 6. `max-width` (420px, inline on the example's card) clamps a drag
  // outwards: the handle shows the clamped edge, the readout says which
  // limit, and the value written is the one the box shows.
  {
    const {scale:s}=await resizeCase('max-width clamp','box-sizing: content-box; '+padded+' width: 400px;',400,{css:50},420,{clamped:true,readout:'width: 420px (clamped from 450px by max-width)'});
    // A drag that `max-width` holds at the value in place commits nothing.
    const history=await undoCount();
    const before=await source();
    if(!(await card().getAttribute('data-isonim-selected')))await select();
    await drag(30*s);
    await assertPoll(()=>readout().textContent(),'width: 420px (clamped from 450px by max-width)','clamped readout at the value in place');
    await p.mouse.up();
    await p.waitForTimeout(1200);
    assert.equal(await undoCount(),history,'a drag held at the value in place commits nothing');
    assert.equal(await pending(),0);
    assert.equal(await source(),before);
    assert.equal(await card().evaluate(n=>n.style.getPropertyValue('width')),'','the preview is put back');
    cases.push('a drag max-width holds at the value in place commits nothing');
  }
  // 6b. `min-width` clamps a drag inwards, and is named. (`!important`: the
  // example's later `.long-tail-card` rule sets `min-width: auto`.)
  await resizeCase('min-width clamp','box-sizing: content-box; '+padded+' min-width: 280px !important; width: 300px;',300,{css:-40},280,{clamped:true,readout:'width: 280px (clamped from 260px by min-width)'});
  // 7. `width` does not apply to an inline box: the press starts no drag and
  // says why on the canvas.
  await open('display: inline !important; '+padded+' width: 300px;');
  await refusedAtPress('an inline card refuses the resize at the press with the reason',handleOf(),'width does not apply to an element with display: inline.');
  // 8. The spacing handle: padding does not depend on `box-sizing`, and a
  // card zoomed 2x in the preview moves it by half the distance, so the
  // padding edge follows the pointer.
  {
    await open('box-sizing: content-box; padding: 18px; border: 1px solid #CBD5E1;',{prefix:'.destination-card{zoom:2}'});
    const s=await frameScale();
    const history=await undoCount();
    const {x,y}=await centre(frame().getByLabel('Adjust selected spacing',{exact:true}));
    await p.mouse.move(x,y);await p.mouse.down();
    await p.mouse.move(x,y+10*s,{steps:2});await p.mouse.move(x,y+20*s,{steps:2});
    await assertPoll(()=>computed('padding-top'),'28px','spacing preview on a zoomed card');
    assert.equal(await undoCount(),history);
    await p.mouse.up();
    await assertPoll(async()=>[await pending(),await cardRule()],[0,'.destination-card { box-sizing: content-box; padding: 28px; border: 1px solid #CBD5E1; }'],'spacing written');
    assert.equal(await undoCount(),history+1);
    cases.push('the spacing handle follows the pointer on a scaled card and writes once');
  }

  // --- Round 2 ---

  // 9. R1: an `!important` rule and flex sizing hold the width. Neither is a
  // clamp: the press is refused with what decides the width.
  await open('box-sizing: content-box; '+padded+' width: 300px !important;');
  await refusedAtPress('an !important width refuses the resize at the press',handleOf(),'width does not follow the drag: an !important width declaration decides it.');
  await open('box-sizing: content-box; '+padded+' flex: 1 1 auto; width: 300px;',{prefix:'body{display:flex}'});
  await refusedAtPress('a growing flex item refuses the resize at the press',handleOf(),'width does not follow the drag: flex layout decides it (flex: 1 1 auto).');

  // 10. R2: only the handles on the edges a size moves; a centred card's
  // right edge follows the pointer (width changes by twice the distance),
  // and a card laid out from its right edge refuses the press.
  {
    await open('box-sizing: content-box; '+padded+' width: 300px;');
    const names=await frame().locator('#isonim-editor-selection-handles > [data-handle]').evaluateAll(ns=>ns.map(n=>n.getAttribute('aria-label')));
    // No handle's name contains another's: a lookup by substring (Playwright's
    // non-exact getByLabel, as metacraft-web's consumer spec uses) finds one.
    for(const name of names)assert.equal(await frame().getByLabel(name).count(),1,'one handle answers to "'+name+'"');
    cases.push('each handle name finds one handle by substring');
    assert.deepEqual(names,['Resize selected element','Adjust selected element height','Adjust selected spacing']);
    cases.push('no handle sits on an edge a size cannot move (left, top)');
  }
  await resizeCase('a centred card: the right edge follows the pointer','box-sizing: content-box; '+padded+' margin: 0 auto; width: 300px;',300,{css:-30},240);
  await open('box-sizing: content-box; '+padded+' margin-left: auto; width: 300px;');
  await refusedAtPress('a card laid out from its right edge refuses the resize',handleOf(),'Resizing does not move the right edge of this element: its layout places it from that edge. Set width in the inspector.');

  // 11. R9: the height handle, with the same start, scale, clamp and no-op.
  await resizeCase('height, content-box, 30px up','box-sizing: content-box; '+padded+' height: 200px;',200,{css:-30},170,{axis:'height'});
  await resizeCase('height, border-box, at 50%','box-sizing: border-box; '+padded+' height: 200px;',200,{screen:-20},160,{axis:'height',zoom:0.5});

  // --- Round 3 ---

  // 16. B2: the trial size wraps the card's line. In a `flex-wrap` row with
  // under 20px of free space, +20 moves the card to the next line; -20 shows
  // the edge following the size. In centred text whose line wraps at +20, the
  // -20 trial shows the centred factor (1/2).
  const wrapRow='body{display:flex !important;flex-wrap:wrap;width:700px;align-items:flex-start} body::before{content:"";display:block;width:340px;height:30px;background:#eee;flex:none} .destination-card{flex:none}';
  await resizeCase('a nearly full flex-wrap row: the edge follows the pointer','box-sizing: content-box; '+padded+' width: 300px;',300,{css:-30},270,{prefix:wrapRow});
  const wrapLine='body{text-align:center;width:700px} body::before{content:"";display:inline-block;width:340px;height:30px;background:#eee} html body .destination-card{display:inline-block !important;vertical-align:top}';
  await resizeCase('a centred inline-block whose line wraps at +20: the edge follows the pointer','box-sizing: content-box; '+padded+' width: 300px;',300,{css:-30},240,{prefix:wrapLine});

  // 17. B3: a transition on the size. The press and the drag hold
  // `transition: none` inline, so the preview shows the dragged width at once
  // and no transition runs; the card's own transition is back afterwards.
  {
    const prefix='html body article.destination-card{transition:width 2s linear}';
    await open('box-sizing: content-box; '+padded+' width: 300px;',{prefix});
    assert.equal(await computed('transition'),'width 2s linear');
    await countTransitions();
    const s=await frameScale();
    const history=await undoCount();
    const edge0=await edge();
    await drag(-30*s);
    // At once, not after a poll: a running transition would show ~300px.
    assert.equal(await computed('width'),'270px','the preview shows the dragged width at once');
    assert.ok(Math.abs(await edge()-edge0+30)<1.01,'the edge is at the pointer at once');
    assert.equal(await card().evaluate(n=>n.getAnimations().length),0,'no transition runs during the drag');
    await p.keyboard.press('Escape');
    assert.equal(await computed('width'),'300px','Escape restores at once');
    await p.mouse.up();
    assert.equal(await card().evaluate(n=>n.style.getPropertyValue('transition-property')+'|'+n.style.getPropertyValue('transition-duration')),'|','the inline transition is put back exactly');
    assert.equal(await computed('transition'),'width 2s linear','the card\'s transition applies again');
    await p.waitForTimeout(300);
    assert.equal(await card().evaluate(n=>n.getAnimations().length),0,'restoring the width did not animate it');
    // Then a drag that commits.
    await drag(-30*s);
    assert.equal(await computed('width'),'270px');
    await p.mouse.up();
    await assertPoll(async()=>[await pending(),await cardRule()],[0,'.destination-card { box-sizing: content-box; '+padded+' width: 270px; }'],'the transition case writes once');
    assert.equal(await undoCount(),history+1);
    assert.equal(await card().evaluate(()=>window.__transitions??0),0,'no transition event reached the page ('+await card().evaluate(()=>(window.__tlog||[]).join(','))+')');
    cases.push('a transition on the width: preview at once, no transition events, transition restored, one edit');
  }

  // 18. N4: the trials on a scrolled page. The card's text reflows at +20,
  // so the trial shortens the page; scrolled to the bottom, the browser
  // would clamp the offset. After the press nothing has scrolled.
  {
    await open('box-sizing: content-box; '+padded+' width: 300px;');
    const found=await card().evaluate(n=>{const h=(w)=>{n.style.width=w+'px';const v=n.getBoundingClientRect().height;n.style.width='';return v;};for(let w=120;w<=400;w++)if(h(w+20)<h(w)-0.5)return w;return 0;});
    assert.ok(found>0,'a width where +20 removes a line of text');
    // A tall block above the card, the card's width set where its text
    // reflows, and the page scrolled to its bottom (preview document only).
    await card().evaluate((n,w)=>{const st=document.createElement('style');st.textContent='body::before{content:"";display:block;height:1600px}';document.head.appendChild(st);n.style.width=w+'px';const r=document.scrollingElement;r.scrollTop=r.scrollHeight;},found);
    await select();
    const y0=await card().evaluate(()=>{const r=document.scrollingElement;r.scrollTop=r.scrollHeight;return r.scrollTop;});
    assert.ok(y0>0,'the page is scrolled');
    const shorter=await card().evaluate((n,w)=>{const r=document.scrollingElement;n.style.width=(w+20)+'px';const max=r.scrollHeight-r.clientHeight;n.style.width=w+'px';return max;},found);
    assert.ok(shorter<y0,'the +20 trial shortens the page below the offset');
    await dragOn(handleOf(),0,0,1);
    assert.equal(await card().evaluate(()=>document.scrollingElement.scrollTop),y0,'the trials did not scroll the page');
    await p.waitForTimeout(200);
    assert.equal(await card().evaluate(()=>document.scrollingElement.scrollTop),y0,'nothing scrolled after the press');
    await p.keyboard.press('Escape');
    await p.mouse.up();
    cases.push('the trials on a page scrolled to its bottom leave the scroll offset');
  }

  // --- Round 4 ---

  // 19. A wrap seen without the other trial: a card under 20px tall at the
  // end of a full column `flex-wrap` container. +20 moves it to the next
  // column, and it has no -20 trial. (`overflow: hidden` lets a flex item be
  // that short; the side padding gives the click a point on the card. The
  // height handle, not the width one: on a card under 20px wide the corner
  // handle lies under the bottom padding handle.)
  await open('box-sizing: border-box; padding: 0 6px; border: 0; height: 15px;',{prefix:'body{display:flex !important;flex-direction:column;flex-wrap:wrap;height:300px;width:700px;align-content:flex-start} body::before{content:"";display:block;height:280px;width:300px;background:#eee;flex:none} html body article.destination-card{flex:none;overflow:hidden;width:300px}'});
  assert.equal(await computed('height'),'15px');
  await refusedAtPress('a card the +20 trial wraps, with no smaller trial, refuses the resize',handleOf('height'),'Resizing moves this element instead of its bottom edge (its line wraps). Set height in the inspector.','height');

  // 20. A transition on every property: the spacing, padding and margin
  // handles hold it too, so their preview shows the dragged value at once,
  // no transition runs or reaches page code, Escape restores at once, the
  // inline transition is put back exactly, and the release writes once.
  {
    const prefix='html body article.destination-card{transition:all 2s linear}';
    const startRule='box-sizing: content-box; padding: 18px; border: 1px solid #CBD5E1; width: 300px;';
    for(const [label,prop,dx,dy,during,writtenDecl] of [
      ['Adjust selected spacing','padding-top',0,6,'24px','padding: 24px;'],
      ['Adjust padding right','padding-right',-10,0,'28px','padding-right: 28px;'],
      ['Adjust margin bottom','margin-bottom',0,10,'10px','margin-bottom: 10px;']]){
      await open(startRule,{prefix});
      assert.equal(await computed('transition'),'2s linear');
      const s=await frameScale();
      const history=await undoCount();
      const before=await computed(prop);
      await countTransitions();
      const h=frame().getByLabel(label,{exact:true});
      await dragOn(h,dx*s,dy*s,2);
      assert.equal(await computed(prop),during,label+': the preview shows the dragged value at once');
      assert.equal(await card().evaluate(n=>n.getAnimations().length),0,label+': no transition runs during the drag');
      await p.keyboard.press('Escape');
      assert.equal(await computed(prop),before,label+': Escape restores at once');
      await p.mouse.up();
      assert.equal(await card().evaluate(n=>n.style.getPropertyValue('transition-property')+'|'+n.style.getPropertyValue('transition-duration')),'|',label+': the inline transition is put back exactly');
      assert.equal(await computed('transition'),'2s linear',label+': the card\'s transition applies again');
      await p.waitForTimeout(300);
      assert.equal(await card().evaluate(n=>n.getAnimations().length),0,label+': restoring did not animate');
      assert.equal(await card().evaluate(()=>window.__transitions),0,label+': no transition event reached the page ('+await transitionLog()+')');
      await dragOn(h,dx*s,dy*s,2);
      assert.equal(await computed(prop),during,label+': the committing drag previews at once');
      await p.mouse.up();
      await assertPoll(pending,0,label+': written');
      assert.equal(await undoCount(),history+1,label+': one edit');
      assert.ok((await cardRule()).includes(writtenDecl),label+': '+writtenDecl+' written ('+(await cardRule())+')');
      cases.push('a transition on the card: the '+label+' handle previews at once, restores exactly and writes once');
    }
  }

  // 21. A CSS animation of the width overrides the preview's declaration:
  // the press is refused, naming the animation (not an !important rule).
  await open('box-sizing: content-box; '+padded+' width: 300px;',{prefix:'@keyframes grow{from{width:300px}to{width:400px}} html body article.destination-card{animation:grow 60s linear infinite}'});
  await refusedAtPress('an animated width refuses the resize, naming the animation',handleOf(),'width does not follow the drag: an animation (grow) decides it.','width',true);

  // --- Round 5 ---

  // 22. B4: transition holds nest. A box handle's release waits for a late
  // answer and keeps its hold; a second drag on the same card (each handle
  // type) starts while it waits. When the answer lands mid-drag, the second
  // drag's preview still shows at once. When the second drag ends, the
  // card's inline transition is exactly as it was. Then the reverse: the
  // second drag ends first and the answer lands after it.
  {
    const prefix='html body article.destination-card{transition:all 2s linear}';
    const startRule='box-sizing: content-box; padding: 18px; border: 1px solid #CBD5E1; width: 300px; height: 120px;';
    const TRANSITIONS_JS='transition-property transition-duration transition-timing-function transition-delay transition-behavior';
    // [handle, property, drag, its preview, 2px further, its preview]
    for(const [label,prop,dx,dy,during,mx,my,further] of [
      ['Adjust selected spacing','padding-top',0,6,'24px',0,2,'26px'],
      ['Adjust margin bottom','margin-bottom',0,10,'10px',0,2,'12px'],
      ['Resize selected element','width',-30,0,'270px',-2,0,'268px'],
      ['Adjust selected element height','height',0,-20,'100px',0,-2,'98px']]){
      for(const answerDuring of [true,false]){
        await open(startRule,{prefix});
        await card().evaluate((n,keys)=>{window.TRANSITIONS=keys.split(' ');},TRANSITIONS_JS);
        const empty=await card().evaluate(n=>window.TRANSITIONS.map(k=>n.style.getPropertyValue(k)).join('|'));
        const inlineNow=()=>card().evaluate(n=>window.TRANSITIONS.map(k=>n.style.getPropertyValue(k)).join('|'));
        const s=await frameScale();
        await p.evaluate(()=>{window.__held=[];window.__holdCommits=true;});
        // The first drag: padding right, released; its answer waits.
        await dragOn(frame().getByLabel('Adjust padding right',{exact:true}),-10*s,0,2);
        await p.mouse.up();
        await assertPoll(()=>p.evaluate(()=>window.__held.length),1,label+': the first release waits for its answer');
        assert.equal(await computed('transition-property'),'none','the waiting release keeps its hold');
        // The second drag.
        const before=await computed(prop);
        const at=await dragOn(frame().getByLabel(label,{exact:true}),dx*s,dy*s,2);
        assert.equal(await computed(prop),during,label+': the second drag previews at once');
        if(answerDuring){
          await p.evaluate(()=>{window.__held.splice(0).forEach(f=>f(true,''));});
          assert.equal(await computed('transition-property'),'none',label+': the late answer leaves the second drag\'s hold');
          // The pointer moves on after the answer: the preview still keeps up.
          await p.mouse.move(at.x+(dx+mx)*s,at.y+(dy+my)*s);
          assert.equal(await computed(prop),further,label+': after the late answer the preview still shows at once');
        }
        // Moving on: still at once, no transition running.
        assert.equal(await card().evaluate(n=>n.getAnimations().length),0,label+': nothing animates during the second drag');
        await p.keyboard.press('Escape');
        assert.equal(await computed(prop),before,label+': Escape restores the second drag at once');
        await p.mouse.up();
        if(!answerDuring){
          assert.equal(await computed('transition-property'),'none','the waiting release still holds after the second drag');
          await p.evaluate(()=>{window.__held.splice(0).forEach(f=>f(true,''));});
        }
        await p.evaluate(()=>{window.__holdCommits=false;});
        assert.equal(await inlineNow(),empty,label+': the inline transition is exactly as before');
        assert.equal(await computed('transition'),'2s linear',label+': the card\'s transition applies again');
        cases.push('a '+label+' drag while a box handle\'s answer waits: holds nest ('+(answerDuring?'answer during':'answer after')+' the second drag)');
      }
    }
  }

  // Every handle can be pressed: its centre is in the preview's viewport and
  // a press there reaches it. A handle that was moved went outwards (in the
  // direction it faces) or along its edge, never inwards, unless the
  // viewport cut it off where it was.
  const OUTWARDS={'Resize selected element':[1,1],'Adjust selected element height':[0,1],'Adjust selected spacing':[0,1]};
  for(const side of ['top','right','bottom','left'])for(const box of ['margin','padding'])OUTWARDS['Adjust '+box+' '+side]={top:[0,-1],right:[1,0],bottom:[0,1],left:[-1,0]}[side];
  async function assertHandlesPressable(name){
    const hits=await frame().locator('#isonim-editor-selection-handles > span').evaluateAll(ns=>{const vw=document.documentElement.clientWidth,vh=document.documentElement.clientHeight,b=document.getElementById('isonim-editor-selection-handles').getBoundingClientRect();return ns.filter(n=>n.getClientRects().length).map(n=>{const r=n.getBoundingClientRect();const cx=r.left+r.width/2,cy=r.top+r.height/2;const at=document.elementFromPoint(cx,cy);const t=(n.style.translate||'').split(' ').map(parseFloat).filter(v=>!isNaN(v));return {label:n.getAttribute('aria-label'),ok:at===n&&cx>=0&&cx<=vw&&cy>=0&&cy<=vh,hit:at?(at.id||at.tagName)+'.'+(at.getAttribute('aria-label')||''):'none',dx:t[0]||0,dy:t.length>1?t[1]:0,atEdge:r.left<=1.5||r.top<=1.5||r.right>=vw-1.5||r.bottom>=vh-1.5,cutOff:(()=>{const dx=t[0]||0,dy=t.length>1?t[1]:0;return r.left-dx<1||r.top-dy<1||r.right-dx>vw-1||r.bottom-dy>vh-1;})(),rect:[r.left,r.top,r.right,r.bottom,vw,vh],cx,cy,box:[b.left,b.top,b.right,b.bottom]};});});
    assert.equal(hits.length,11,name+': eleven handles');
    for(const h of hits){
      assert.ok(h.ok,name+': the "'+h.label+'" handle can be pressed (hit: '+h.hit+' '+JSON.stringify(h.rect)+')');
      // Moved or not, some of an edge's handle lies over its edge: across
      // the bottom and top edges, or along the left and right ones.
      if(h.label!=='Resize selected element'){
        const w=OUTWARDS[h.label],[l,t,r,b]=h.rect,[bl,bt,br,bb]=h.box;
        const over=w[0]===0?(r>=bl-0.5&&l<=br+0.5):(b>=bt-0.5&&t<=bb+0.5);
        assert.ok(over,name+': the "'+h.label+'" handle lies over its edge (handle '+JSON.stringify([l,t,r,b])+', box '+JSON.stringify(h.box)+')');
      }
      if(h.dx||h.dy){
        const w=OUTWARDS[h.label];
        assert.ok(h.dx*w[0]+h.dy*w[1]>=0||h.atEdge||h.cutOff,name+': the "'+h.label+'" handle moved outwards or along its edge, or the viewport cut it off (moved '+h.dx+','+h.dy+')');
        // Along an edge it stops at the edge's far end: a corner handle moves
        // up its right edge or left along its bottom edge, a side handle along
        // its side, and none passes wholly beyond the box's other end.
        const alongX=w[0]===0||(w[1]!==0&&h.dx<0), alongY=w[1]===0||(w[0]!==0&&h.dy<0);
        const [bl,bt,br,bb]=h.box, [l,t,r,b]=h.rect;
        const past=(alongX&&((h.dx<0&&r<bl-0.5)||(h.dx>0&&l>br+0.5)))||(alongY&&((h.dy<0&&b<bt-0.5)||(h.dy>0&&t>bb+0.5)));
        assert.ok(!past,name+': the "'+h.label+'" handle stays over its edge (moved '+h.dx+','+h.dy+', handle '+JSON.stringify([l,t,r,b])+', box '+JSON.stringify(h.box)+')');
      }
    }
    return hits;
  }

  // 23. A card under 20px wide (and a short one): every handle has a centre
  // a press reaches, and the width handle resizes.
  for(const [name,startRule,axis,dist,shown] of [
    ['a card 15px wide','box-sizing: border-box; padding: 0 4px; border: 0; width: 15px;','width',30,45],
    ['a card 15px tall','box-sizing: border-box; padding: 0 4px; border: 0; width: 200px; height: 15px; overflow: hidden;','height',30,45]]){
    await open(startRule);
    const hits=await assertHandlesPressable(name);
    if(axis==='width')assert.ok(hits.some(h=>h.dx||h.dy),name+': some handle had to move');
    cases.push(name+': every handle can be pressed');
    const s=await frameScale();
    const history=await undoCount();
    if(axis==='width')await dragOn(handleOf(),dist*s,0,3);else await dragOn(handleOf('height'),0,dist*s,3);
    assert.equal(await computed(axis),shown+'px',name+': the '+axis+' handle previews');
    await p.mouse.up();
    await assertPoll(async()=>[await pending(),await cardRule()],[0,'.destination-card { '+startRule.replace(new RegExp(axis+': 15px;'),axis+': '+shown+'px;')+' }'],name+': written');
    assert.equal(await undoCount(),history+1);
    cases.push(name+': the '+axis+' handle resizes it and writes once');
  }

  // 24. A 15px-wide card flush with each edge of the preview's viewport,
  // and a 15px-tall one in the top-right corner: every handle stays inside
  // the viewport and can be pressed.
  {
    const flat='body{padding:0 !important;margin:0 !important}';
    const tiny='box-sizing: border-box; padding: 0 4px; border: 0; width: 15px;';
    for(const [edgeName,prefix,startRule] of [
      ['top and left',flat],
      ['right',flat+' html body .destination-card{margin-left:auto !important;margin-right:0 !important}'],
      ['bottom',flat+' html,body{height:100%} body{display:flex !important;flex-direction:column;justify-content:flex-end}'],
      ['bottom and right',flat+' html,body{height:100%} body{display:flex !important;flex-direction:column;justify-content:flex-end;align-items:flex-end}'],
      // A wide card 4px tall in the top-right corner: the right side's
      // handles cannot move outwards, and the first clear place along the
      // right edge (4px long, under 18px handles) lies past its far end.
      ['top and right',flat+' html body .destination-card{margin-left:auto !important;margin-right:0 !important}','box-sizing: border-box; padding: 0 4px; border: 0; width: 200px; height: 4px; overflow: hidden;']]){
      await open(startRule||tiny,{prefix});
      const r=await cardRect();
      const vp=await card().evaluate(()=>[document.documentElement.clientWidth,document.documentElement.clientHeight]);
      const flush={'top and left':r.top<=0.5&&r.left<=0.5,right:Math.abs(r.right-vp[0])<=0.5,bottom:Math.abs(r.bottom-vp[1])<=0.5,'bottom and right':Math.abs(r.bottom-vp[1])<=0.5&&Math.abs(r.right-vp[0])<=0.5,'top and right':r.top<=0.5&&Math.abs(r.right-vp[0])<=0.5}[edgeName];
      assert.ok(flush,'the card is flush with the viewport\'s '+edgeName+' edge ('+JSON.stringify([r,vp])+')');
      await assertHandlesPressable('a card flush with the '+edgeName+' edge');
      cases.push('a 15px card flush with the viewport\'s '+edgeName+' edge: every handle can be pressed');
    }
  }

  // 12. (b) The margin and padding handles on a card zoomed 2x: placed on
  // the zoomed edges, and the side follows the pointer.
  {
    await open('box-sizing: content-box; padding: 18px; border: 1px solid #CBD5E1; width: 200px;',{prefix:'.destination-card{zoom:2}'});
    const s=await frameScale();
    const r=await cardRect();
    // The right padding handle sits on the content edge: right minus
    // (border + padding) times 2. The bottom margin handle on the margin edge.
    const pr=await frame().getByLabel('Adjust padding right',{exact:true}).boundingBox();
    const contentRight=r.right-(1+18)*2;
    assert.ok(Math.abs((pr.x+pr.width/2)/s-(await p.evaluate(()=>document.querySelector('iframe[title="Editable component preview"]').getBoundingClientRect().x))/s-contentRight)<3,'the padding handle sits on the zoomed content edge');
    cases.push('a zoomed card\'s padding handle sits on its content edge');
    const history=await undoCount();
    const before=await source();
    await dragOn(frame().getByLabel('Adjust padding right',{exact:true}),-20*s,0,2);
    await assertPoll(()=>computed('padding-right'),'28px','padding preview on a zoomed card follows the pointer');
    assert.equal(await undoCount(),history);
    await p.mouse.up();
    await assertPoll(pending,0,'padding written');
    assert.equal(await undoCount(),history+1);
    assert.notEqual(await source(),before);
    assert.match(await cardRule(),/padding-right: 28px;/);
    cases.push('a zoomed card\'s padding handle follows the pointer and writes once');
    // Escape restores.
    if(!(await card().getAttribute('data-isonim-selected')))await select();
    await dragOn(frame().getByLabel('Adjust padding right',{exact:true}),-10*s,0,2);
    await assertPoll(()=>computed('padding-right'),'33px','second padding preview');
    await p.keyboard.press('Escape');
    await assertPoll(()=>computed('padding-right'),'28px','Escape restores the padding');
    await p.mouse.up();
    await p.waitForTimeout(600);
    assert.equal(await undoCount(),history+1);
    cases.push('Escape restores a zoomed card\'s padding drag');
  }

  // 13. (c) A percentage gap starts from its used pixels: 10% of a 300px
  // content box is 30px, and a 5px drag previews 35px. The percentage is the
  // long-tail rule's own `gap` -- the rule the writer writes `gap` to -- so the
  // written edit decides and renders (a gap another rule decides is refused:
  // case 13b).
  {
    await open('box-sizing: content-box; padding: 18px; border: 1px solid #CBD5E1; width: 300px;',
      {replace:'gap: normal;\tgap: 10%;\ndisplay: block;\tdisplay: flex;'});
    await p.evaluate(()=>{window.__spacingCommits=[];window.addEventListener('isonim-preview-direct-manipulation',e=>window.__spacingCommits.push(e.detail.property+': '+e.detail.value));});
    const s=await frameScale();
    const history=await undoCount();
    assert.equal(await computed('column-gap'),'10%');
    await dragOn(frame().getByLabel('Adjust selected spacing',{exact:true}),0,5*s,2);
    await assertPoll(()=>computed('column-gap'),'35px','a percentage gap previews from its used pixels');
    assert.equal(await undoCount(),history);
    await p.keyboard.press('Escape');
    await assertPoll(()=>computed('column-gap'),'10%','Escape restores the percentage gap');
    await p.mouse.up();
    await dragOn(frame().getByLabel('Adjust selected spacing',{exact:true}),0,5*s,2);
    await assertPoll(()=>computed('column-gap'),'35px','the second drag previews');
    await p.mouse.up();
    await assertPoll(()=>p.evaluate(()=>window.__spacingCommits),['gap: 35px'],'one edit, in pixels');
    await assertPoll(pending,0,'the gap edit settles');
    assert.equal(await undoCount(),history+1);
    assert.match(await source(),/\.long-tail-card \{[^}]*gap: 35px;/);
    await assertPoll(()=>computed('column-gap'),'35px','the written gap renders');
    cases.push('a percentage gap is dragged from its used pixels and written once in pixels');
  }

  // 13b. A canvas drag whose edit the editor refuses at the act -- a rule of
  // the page outranks the rule the writer would write -- leaves nothing in
  // the preview: on release it shows what the file renders again, the reason
  // is shown beside the selection, and nothing is staged or written (editor
  // spec "Saving": a refusal the editor can know at the act is made at the
  // act, so a refused change never reaches the preview). The spacing handle
  // on a gap and on padding, and the width and height handles. isonim-pm issue
  // 2026-11-18-a-refused-canvas-gap-drag-stays-in-the-preview-and-the-canvas-
  // resize-gui-expects-the-refused-edit.
  for(const [label,css,handle,prop,start,why,dx,dy] of [
    ['gap','.destination-card.long-tail-card{display:flex;gap:10%}','Adjust selected spacing','column-gap','10%',/`\.destination-card\.long-tail-card` decides gap for this element/,0,5],
    ['padding','.destination-card.long-tail-card{padding:18px}','Adjust selected spacing','padding-top','18px',/`\.destination-card\.long-tail-card` decides padding for this element/,0,5],
    ['width','.destination-card.long-tail-card{width:300px}','Resize selected element','width','300px',/`\.destination-card\.long-tail-card` decides width for this element/,-20,0],
    ['height','.destination-card.long-tail-card{height:200px}','Adjust selected element height','height','200px',/`\.destination-card\.long-tail-card` decides height for this element/,0,-20],
    // With a transition on the property: the snap-back is not animated -- the
    // value at release is the one from before the drag, and no transition
    // runs (review R1 of case-13 round 1).
    ['width with a transition','.destination-card.long-tail-card{width:300px;transition:width 2s linear}','Resize selected element','width','300px',/`\.destination-card\.long-tail-card` decides width for this element/,-40,0],
    ['gap with a transition','.destination-card.long-tail-card{display:flex;gap:10%;transition:gap 2s linear}','Adjust selected spacing','column-gap','10%',/`\.destination-card\.long-tail-card` decides gap for this element/,0,5]]){
    await open('box-sizing: content-box; padding: 18px; border: 1px solid #CBD5E1; width: 300px;');
    await card().evaluate((n,css)=>{const st=document.createElement('style');st.textContent=css;document.head.appendChild(st);},css);
    await select();
    const s=await frameScale();
    const history=await undoCount();
    const before=await source();
    assert.equal(await computed(prop),start,label+': the page rule decides');
    const animated=label.endsWith('with a transition');
    if(animated)await countTransitions();
    await dragOn(frame().getByLabel(handle,{exact:true}),dx*s,dy*s,2);
    await assertPoll(async()=>(await computed(prop))!==start,true,label+': the drag previews');
    await p.mouse.up();
    await note().waitFor({state:'visible'});
    assert.match(await note().textContent(),why,label+': the reason is shown beside the selection');
    assert.equal(await computed(prop),start,label+': the preview shows what the file renders at once');
    if(animated){
      assert.equal(await card().evaluate(n=>n.getAnimations().length),0,label+': no animation runs after the release');
      await p.waitForTimeout(300);
      assert.equal(await card().evaluate(()=>window.__transitions),0,label+': no transition ran ('+await transitionLog()+')');
    }
    await p.waitForTimeout(1500);
    assert.equal(await computed(prop),start,label+': and still does');
    if(animated){
      // The hold the restore ran under is released: no `transition` is left
      // in the card's style attribute, and the page's transition is back.
      assert.equal(await card().evaluate(n=>/transition/.test(n.getAttribute('style')||'')),false,label+': no transition hold is left on the card');
      assert.equal(await computed('transition-duration'),'2s',label+': the page\'s transition is back');
    }
    assert.equal(await card().evaluate(n=>n.getAttribute('style')).then(v=>/(^|;)\s*(gap|padding|width|height)\s*:/.test(v||'')),false,label+': no dragged declaration is left on the card');
    assert.equal(await undoCount(),history,label+': nothing in history');
    assert.equal(await pending(),0,label+': nothing staged');
    assert.equal(await source(),before,label+': nothing written');
    cases.push('a refused '+label+' drag: the preview is put back at release and the reason is shown; nothing is staged or written');
  }

  // 13c. A workspace read-only for source changes: every canvas handle's
  // release is refused at the act, with the reason a row's commit gives
  // ("This workspace is read-only for source changes."), shown beside the
  // selection; the preview is put back at release and nothing is staged or
  // written. The resize handles (width, height), the spacing handle on
  // padding and on a gap, and the margin and padding box handles. isonim-pm
  // issue 2026-11-18-a-canvas-drag-in-a-read-only-workspace-is-staged-
  // instead-of-refused-at-the-act; editor spec "Saving".
  {
    const readOnlyWhy=/This workspace is read-only for source changes\./;
    for(const [label,handle,prop,dx,dy,opts] of [
      ['width','Resize selected element','width',-20,0,{}],
      ['height','Adjust selected element height','height',0,-20,{}],
      ['padding (spacing handle)','Adjust selected spacing','padding-top',0,5,{}],
      ['gap (spacing handle)','Adjust selected spacing','column-gap',0,5,{replace:'gap: normal;\tgap: 10%;\ndisplay: block;\tdisplay: flex;'}],
      ['padding top (box handle)','Adjust padding top','padding-top',0,-5,{}],
      ['margin top (box handle)','Adjust margin top','margin-top',0,-5,{}]]){
      await open('box-sizing: content-box; padding: 18px; border: 1px solid #CBD5E1; width: 300px; height: 200px; margin: 10px;',{...opts,readonly:true});
      const s=await frameScale();
      const history=await undoCount();
      const before=await source();
      const start=await computed(prop);
      await dragOn(frame().getByLabel(handle,{exact:true}),dx*s,dy*s,2);
      await assertPoll(async()=>(await computed(prop))!==start,true,label+': the drag previews');
      await p.mouse.up();
      await note().waitFor({state:'visible'});
      assert.match(await note().textContent(),readOnlyWhy,label+': the row\'s reason is shown beside the selection');
      // At once: read as soon as the reason is shown, not after a reload.
      assert.equal(await computed(prop),start,label+': the preview is put back at release');
      await p.waitForTimeout(1500);
      assert.equal(await computed(prop),start,label+': and stays put back');
      assert.equal(await card().evaluate(n=>n.getAttribute('style')).then(v=>/(^|;)\s*(gap|padding|width|height|margin)[a-z-]*\s*:/.test(v||'')),false,label+': no dragged declaration is left on the card');
      assert.equal(await undoCount(),history,label+': nothing in history');
      assert.equal(await pending(),0,label+': nothing staged');
      assert.equal(await source(),before,label+': nothing written');
      cases.push('read-only workspace: a '+label+' drag is refused at release with the row\'s reason and put back; nothing is staged');
    }
  }

  // 13d. The same in a read-only workspace for the canvas commands that are
  // not handles: the context menu's Paste styles and Reset (which change the
  // preview before asking), Detach, Promote and Wrap (which change nothing
  // first), inline text and a reorder. Each is refused at the act with the
  // row's reason, shown beside the selection at once; whatever it changed in
  // the preview is put back at once; nothing is staged or written. isonim-pm
  // issue 2026-11-18-a-canvas-drag-in-a-read-only-workspace-is-staged-
  // instead-of-refused-at-the-act (review R1/R2 of ro-canvas round 1).
  {
    const readOnlyWhy=/This workspace is read-only for source changes\./;
    const startRule='box-sizing: content-box; padding: 18px; border: 1px solid #CBD5E1; width: 300px; height: 200px; margin: 10px;';
    const settledRefusal=async(label,history,before)=>{
      assert.equal(await undoCount(),history,label+': nothing in history');
      assert.equal(await pending(),0,label+': nothing staged');
      assert.equal(await source(),before,label+': nothing written');
    };
    for(const menuItem of ['Paste styles','Reset','Detach style','Promote style','Wrap selection']){
      const label='context '+menuItem;
      await open(startRule,{readonly:true});
      const history=await undoCount(),before=await source(),start=await computed('padding-top');
      const inlineDecls=()=>card().evaluate(n=>{const o={};for(const k of n.style)o[k]=n.style.getPropertyValue(k)+(n.style.getPropertyPriority(k)?' !'+n.style.getPropertyPriority(k):'');return o;});
      const inlineBefore=await inlineDecls();
      await card().click({button:'right',position:{x:5,y:5}});
      await frame().getByRole('menuitem',{name:menuItem,exact:true}).click();
      await note().waitFor({state:'visible'});
      assert.match(await note().textContent(),readOnlyWhy,label+': the row\'s reason is shown beside the selection');
      assert.equal(await computed('padding-top'),start,label+': the preview is put back at once');
      assert.deepEqual(await inlineDecls(),inlineBefore,label+': the card\'s inline declarations are as before');
      await p.waitForTimeout(1500);
      assert.equal(await computed('padding-top'),start,label+': and stays');
      await settledRefusal(label,history,before);
      cases.push('read-only workspace: '+label+' is refused with the row\'s reason and leaves the preview as it was');
    }
    // Create variant, Duplicate and Delete run their editor command, and the
    // reason shown is that command's own (review N1/V3 of ro-canvas round
    // 2): read-only, the workspace's; writable, the permission this
    // workspace does not grant.
    for(const [menuItem,readonly,why] of [
      ['Create variant',true,readOnlyWhy],
      ['Create variant',false,/This workspace does not allow variant creation\./],
      ['Duplicate',false,/This workspace does not allow duplicate operations\./],
      ['Delete',false,/This workspace does not allow delete operations\./]]){
      const label='context '+menuItem+(readonly?' (read-only)':' (writable)');
      await open(startRule,{readonly});
      const history=await undoCount(),before=await source(),start=await computed('padding-top');
      await card().click({button:'right',position:{x:5,y:5}});
      await frame().getByRole('menuitem',{name:menuItem,exact:true}).click();
      await note().waitFor({state:'visible'});
      assert.match(await note().textContent(),why,label+': the command\'s reason is shown beside the selection');
      assert.equal(await computed('padding-top'),start,label+': the preview is unchanged');
      await settledRefusal(label,history,before);
      cases.push(label+' is refused with its command\'s reason shown beside the selection');
    }
    {
      const label='inline text';
      await open(startRule,{readonly:true});
      const history=await undoCount(),before=await source();
      const leaf=card().locator('h1');
      const textBefore=(await leaf.textContent()).trim();
      await leaf.dblclick();
      await frame().locator('[data-isonim-inline-editing="true"]').waitFor();
      await p.keyboard.press('ControlOrMeta+A');await p.keyboard.type('Edited title');await p.keyboard.press('Enter');
      await note().waitFor({state:'visible'});
      assert.match(await note().textContent(),readOnlyWhy,label+': the row\'s reason is shown beside the selection');
      assert.equal((await leaf.textContent()).trim(),textBefore,label+': the text is put back at once');
      await p.waitForTimeout(1500);
      assert.equal((await leaf.textContent()).trim(),textBefore,label+': and stays');
      await settledRefusal(label,history,before);
      cases.push('read-only workspace: an inline text edit is refused with the row\'s reason and the text is put back');
    }
    {
      const label='reorder';
      await open(startRule,{readonly:true});
      const history=await undoCount(),before=await source();
      await card().locator('h1').click({position:{x:4,y:4}});
      const sel=frame().locator('[data-isonim-selected="true"]');
      assert.equal(await sel.evaluate(n=>n.tagName),'H1');
      const b=await sel.boundingBox();
      const x=b.x+Math.min(12,b.width/3),y=b.y+Math.min(8,b.height/3);
      const heading=card().locator('h1');
      await p.mouse.move(x,y);await p.mouse.down();
      for(let i=1;i<=4;i++)await p.mouse.move(x,y+i*6);
      // The reorder is asked for while the pointer moves; read its answer
      // before the release, whose click climbs the selection to the card
      // (and so hides the note, as any new selection does).
      await note().waitFor({state:'visible'});
      assert.match(await note().textContent(),readOnlyWhy,label+': the row\'s reason is shown beside the selection');
      assert.equal(await heading.evaluate(n=>n.style.order),'',label+': its order is put back at once');
      await p.mouse.up();
      await p.waitForTimeout(1500);
      assert.equal(await heading.evaluate(n=>n.style.order),'',label+': and stays');
      await settledRefusal(label,history,before);
      cases.push('read-only workspace: a reorder is refused with the row\'s reason and its order is put back');
    }
  }

  // 14. (d) A transform on `body` moves and scales the overlay's containing
  // block: the overlay still sits on the card, and the drag follows.
  {
    const prefix='body{transform:translateX(40px) scale(0.8);transform-origin:0 0}';
    await open('box-sizing: content-box; '+padded+' width: 300px;',{prefix});
    const r=await cardRect();
    const o=await frame().locator('#isonim-editor-selection-handles').evaluate(n=>{const b=n.getBoundingClientRect();return {left:b.left,top:b.top,width:b.width,height:b.height};});
    // The overlay's 1px border is drawn outside the element's border box.
    assert.ok(Math.abs(o.left-r.left)<1.01&&Math.abs(o.top-r.top)<1.01,'the overlay starts at the card ('+JSON.stringify([o,r])+')');
    assert.ok(Math.abs(o.width-r.width)<3&&Math.abs(o.height-r.height)<3,'the overlay is the card\'s size');
    cases.push('the overlay sits on the card under a transform on body');
  }
  // 24 document px are 30 CSS px of the card at 0.8.
  await resizeCase('resize under a transform on body','box-sizing: content-box; '+padded+' width: 300px;',300,{css:-24},270,{prefix:'body{transform:translateX(40px) scale(0.8);transform-origin:0 0}'});

  // 15. R7: a rotated or skewed element refuses every handle at the press.
  {
    const why='The canvas handles cannot follow the pointer on a rotated, skewed or mirrored element; use the inspector fields.';
    await open('box-sizing: content-box; '+padded+' width: 300px;',{prefix:'.destination-card{rotate:10deg}'});
    await refusedAtPress('a rotated card refuses the resize',handleOf(),why);
    await refusedAtPress('a rotated card refuses the height handle',handleOf('height'),why,'height');
    await refusedAtPress('a rotated card refuses the spacing handle',frame().getByLabel('Adjust selected spacing',{exact:true}),why,'padding-top');
    await refusedAtPress('a rotated card refuses the padding handles',frame().getByLabel('Adjust padding right',{exact:true}),why,'padding-right');
    await open('box-sizing: content-box; '+padded+' width: 300px;',{prefix:'body{transform:skewX(8deg)}'});
    await refusedAtPress('a card in a skewed body refuses the resize',handleOf(),why);
  }

  assert.deepEqual(errors,[]);
  console.log('Canvas resize GUI passed:',pub,cases.length);
} finally {
  if(browser)await browser.close();
  await new Promise(resolve=>server.close(resolve));
}
