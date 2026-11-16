/** Edit mode's hover and selection outlines are editor chrome drawn over the
 * page, not a change to the page's own element (Chromium).
 *
 * Editor spec "Edit Mode" (the selected element gets a blue highlight
 * outline; hover inspection) and "View Mode and Edit Mode" (a mode only
 * overlays its affordances on the same rendered preview). isonim-pm issue
 * 2026-11-16-edit-mode-draws-its-hover-and-selection-outline-on-the-page-element:
 * the outline used to be an `!important` outline on the hovered and selected
 * element, so a page `transition: all` animated it, page code received
 * `transitionrun`/`transitionend` whenever the pointer crossed an element, and
 * `getAnimations()` reported transitions the editor made.
 *
 * The preview card carries `transition: all .4s linear`. In Edit mode the
 * pointer hovers its heading, then the card, and clicks it, and each case
 * asserts:
 *   - no transition or animation event reaches the page's document, on the
 *     card or anywhere else (the editor's chrome lives in the same document);
 *   - the card's `getAnimations()` is empty while its transition would run;
 *   - every computed property of the card is what it was before, its outline
 *     included;
 *   - the hover outline (dashed, 1px, 3px out) and the selection outline
 *     (solid #3B82F6, 2px, 2px out) are overlays on the card's border box,
 *     and the screen shows their colour there.
 * Cases: in place, on a scrolled page (the page's scroller scrolled before
 * the hover and again once the card is selected), at a 200% preview scale, on a card with `zoom`, and under a
 * transform on `body`. A last case gives every element of the page
 * `transition: all`, the editor's chrome included. In every case a page
 * MutationObserver sees no child-list change from the hover at all, and none
 * outside the editor's chrome container from the selection.
 *
 * Movement the page drives, with the pointer still (round 2): a banner
 * inserted above, a margin change under a transition, a keyframe animation,
 * a transition of `left` and a transform on an ancestor move the selected
 * card, and a banner the hovered one; the selection outline, the handles
 * and the hover outline are on the card's border box part-way (the card's
 * animation held part-way through) and after.
 *
 * The agent's highlight (the control CLI's `select --highlight`, called
 * through the editor's own adapter, `controlHighlightAdapter`): chrome over
 * the element, no transition event, the element's style and style attribute
 * untouched; beside the selection outline (indigo ring outside the blue one)
 * when the element is also selected; following the element; moved to the
 * next element highlighted.
 *
 * The follow loop (round 3), counted by wrapping the preview window's
 * requestAnimationFrame: one loop per frame while the selected card is still,
 * after it has animated for 1.3 s and after it stops; none once nothing is
 * marked, once the pointer has left the preview (which ends the hover), once
 * an agent-highlighted element is removed, while the preview frame is
 * display:none (one loop again, and following, once it is shown) and once the
 * bridge is disposed. Its time per frame, still and animated, is printed.
 *
 * Every frame of a move (round 4), sampled right after the loop placed the
 * chrome: a card moved by a margin-left transition keeps its margin-left
 * handle on its margin edge part-way, and a card moved under a body scaled
 * to 0.5 keeps the handles box on its border box. Round 5: a padding-left
 * transition under border-box, which leaves the border box where it is,
 * keeps the padding-left handle on the content edge part-way.
 *
 * The host is the shorthand-order host
 * (`tests/helpers/editor_shorthand_order_workspace.nim`: the editor example
 * with its real preview document and selection bridge). Two things are set
 * from outside the code under test, and neither replaces any of it: the 200%
 * case scales the component preview's device frame with a stylesheet in the
 * editor page (its fit-to-column and zoom scales are a `scale()` transform on
 * the frame, which is what the stylesheet sets), and the page's CSS is added
 * to the preview document (`__isonimShorthandExtraCss` and
 * `__isonimShorthandPrefixCss`). The screen is read from a Playwright
 * screenshot decoded in a second, blank page. No mocks. External requests are
 * aborted so the run is offline.
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
const pub=mkdtempSync(path.join(process.env.ISONIM_POPUP_ARTIFACTS||tmpdir(),'edit-outline-'));
copyFileSync(bundle,pub+'/editor.js');
for(const [from,to] of [['node_modules/fabric/dist/index.min.js','fabric.min.js'],['node_modules/paper/dist/paper-core.min.js','paper-core.min.js'],['node_modules/svgo/dist/svgo.browser.js','svgo.browser.js']])copyFileSync(repo+'/'+from,pub+'/'+to);
const index=readFileSync(repo+'/src/isonim/editor/index.html','utf8');
let extraCss='',prefixCss='';
const page=()=>index.replace('<script src="editor.js"></script>','<script>window.__isonimShorthandExtraCss='+JSON.stringify(extraCss)+';window.__isonimShorthandPrefixCss='+JSON.stringify(prefixCss)+';</script><script src="editor.js"></script>');
const types={'.js':'text/javascript','.html':'text/html'};
const server=createServer((req,res)=>{const url=new URL(req.url,'http://x');const name=url.pathname==='/'?'index.html':url.pathname.slice(1);
  if(name==='index.html'){res.writeHead(200,{'content-type':'text/html'});res.end(page());return;}
  const file=path.join(pub,path.basename(name));if(!existsSync(file)){res.writeHead(404);res.end();return;}
  res.writeHead(200,{'content-type':types[path.extname(file)]||'application/octet-stream'});res.end(readFileSync(file));});
// A fixed port when one is given (ISONIM_EDIT_OUTLINE_PORT), otherwise any.
await new Promise(resolve=>server.listen(Number(process.env.ISONIM_EDIT_OUTLINE_PORT||0),'127.0.0.1',resolve));
const origin='http://127.0.0.1:'+server.address().port;
const TRANSITION='.destination-card{transition:all .4s linear}';
// The preview's frame is as tall as its document, so the page scrolls in a
// scroller of its own: its body (`html` clips, so the body keeps its own
// `overflow`), with the card below the fold.
const SCROLLER='html{overflow:hidden}body{height:380px;overflow:auto;box-sizing:border-box}.destination-card{margin-top:520px}';
// The outlines the editor spec's selection and hover show, as the element
// used to draw them: [style, width, colour, offset].
const SELECTION=['solid','2px','rgb(59, 130, 246)','2px'];
const HOVER=['dashed','1px','rgba(59, 130, 246, 0.75)','3px'];
const cases=[],errors=[],proof=[];
// ISONIM_EDIT_OUTLINE_ONLY: a regular expression; only the cases whose name
// matches run (the fault controls use it to run the cases a mutant is about).
const want=(name)=>!process.env.ISONIM_EDIT_OUTLINE_ONLY||new RegExp(process.env.ISONIM_EDIT_OUTLINE_ONLY).test(name);
let browser;
try {
  const env={...process.env};delete env.LD_LIBRARY_PATH;
  browser=await chromium.launch({headless:true,env,executablePath:process.env.PLAYWRIGHT_CHROMIUM_EXECUTABLE});
  const p=await browser.newPage({viewport:{width:1440,height:900}});p.setDefaultTimeout(30000);
  // Loading the editor on a loaded host can take well over 30 s.
  p.setDefaultNavigationTimeout(120000);
  p.on('pageerror',e=>errors.push(e.message));
  await p.route(url=>!url.href.startsWith(origin),route=>route.abort());
  // Decodes screenshots; a blank page, so nothing in it touches the editor.
  const decoder=await browser.newPage();
  const frame=()=>p.frameLocator('iframe[title="Editable component preview"]');
  const card=()=>frame().getByTestId('component-edit-preview');
  const frameGeometry=()=>p.evaluate(()=>{const n=document.querySelector('iframe[title="Editable component preview"]');const r=n.getBoundingClientRect();return {x:r.x,y:r.y,s:r.width/n.contentWindow.innerWidth};});
  const rectOf=(locator)=>locator.evaluate(n=>{const r=n.getBoundingClientRect();return {left:r.left,top:r.top,right:r.right,bottom:r.bottom,width:r.width,height:r.height};});
  // Every computed property of the card, as page code reads it.
  const cardStyle=()=>card().evaluate(n=>{const s=getComputedStyle(n);return Array.from(s).map(k=>k+':'+s.getPropertyValue(k)).join(';');});
  const cardOutline=()=>card().evaluate(n=>{const s=getComputedStyle(n);return [s.outlineStyle,s.outlineWidth,s.outlineColor,s.outlineOffset];});
  const marks=()=>card().evaluate(n=>[n.getAttribute('data-isonim-hovered')||'',n.getAttribute('data-isonim-selected')||'']);
  // Every transition and animation event the page's document receives, from
  // now on, on any element.
  async function listen(){
    await card().evaluate(n=>{
      const doc=n.ownerDocument;window.__pageEvents=[];
      if(!window.__pageListening){window.__pageListening=true;
        for(const t of ['transitionrun','transitionstart','transitionend','transitioncancel','animationstart','animationend','animationcancel'])
          doc.addEventListener(t,e=>window.__pageEvents.push(e.type+':'+(e.target.id||e.target.getAttribute?.('data-testid')||e.target.tagName)+':'+(e.propertyName||e.animationName)),true);}
    });
  }
  const pageEvents=()=>card().evaluate(()=>window.__pageEvents.slice());
  // A page MutationObserver on the whole document, from now on: its
  // child-list records, each with whether its target is inside the editor's
  // chrome container. The data-isonim-* attributes are allowed and not
  // collected.
  async function observe(){
    await card().evaluate(n=>{
      const doc=n.ownerDocument;
      if(window.__pageObserver)window.__pageObserver.disconnect();
      window.__childList=[];
      window.__keepRecords=records=>{for(const r of records){
        const t=r.target.nodeType===1?r.target:r.target.parentElement;
        window.__childList.push({target:(t&&(t.id||t.tagName))||'?',inChrome:!!(t&&t.closest&&t.closest('#isonim-editor-chrome')),
          added:[...r.addedNodes].map(x=>x.id||x.nodeName),removed:[...r.removedNodes].map(x=>x.id||x.nodeName)});}};
      window.__pageObserver=new MutationObserver(window.__keepRecords);
      window.__pageObserver.observe(doc.documentElement,{subtree:true,childList:true});
    });
  }
  const childList=()=>card().evaluate(()=>{window.__keepRecords(window.__pageObserver.takeRecords());return window.__childList.slice();});
  const animations=()=>card().evaluate(n=>n.getAnimations().map(a=>a.transitionProperty||a.animationName||a.constructor.name));
  // The overlay `id`'s box (the frame's client pixels) and outline, while it
  // is shown (an overlay with nothing to mark is hidden, not removed).
  const overlay=(id)=>frame().locator('#'+id).evaluateAll(ns=>ns.filter(n=>!n.hidden&&getComputedStyle(n).display!=='none').map(n=>{const r=n.getBoundingClientRect(),s=getComputedStyle(n);return {left:r.left,top:r.top,width:r.width,height:r.height,outline:[s.outlineStyle,s.outlineWidth,s.outlineColor,s.outlineOffset],visibility:s.visibility,display:s.display,pointerEvents:s.pointerEvents};}));
  // The colours on screen at points given in the frame's client pixels.
  async function screenAt(points){
    const f=await frameGeometry();
    const png=(await p.screenshot({type:'png'})).toString('base64');
    return decoder.evaluate(async([png,points])=>{
      const img=new Image();img.src='data:image/png;base64,'+png;await img.decode();
      const c=document.createElement('canvas');c.width=img.width;c.height=img.height;
      const g=c.getContext('2d');g.drawImage(img,0,0);
      // Off the screen: no colour.
      return points.map(([x,y])=>x<0||y<0||x>=img.width||y>=img.height?null:
        Array.from(g.getImageData(Math.round(x),Math.round(y),1,1).data).slice(0,3));
    },[png,points.map(([x,y])=>[f.x+x*f.s,f.y+y*f.s])]);
  }
  // Blue as the outlines are, and not the page's near-white background or
  // the card's grey shadow. The preview is usually shown scaled down (fit to
  // the column), so a 1px line is blended with the background.
  const blue=(c)=>c[0]<=200&&c[2]-c[0]>=40;
  // Along the card's left edge, `out` of the preview document's pixels (times
  // the scale of the chrome's containing block, `chrome`) outside its border
  // box: the screen there, from the upper half, clear of the margin handle at
  // mid-height.
  async function strip(out,chrome=1){
    const r=await rectOf(card());
    const pts=[];for(let y=r.top+r.height*0.12;y<r.top+r.height*0.42;y+=1)pts.push([r.left-out*chrome,y]);
    return screenAt(pts);
  }
  // The outline is on screen there.
  async function shown(name,out,chrome=1){
    const px=(await strip(out,chrome)).filter(Boolean);
    assert.ok(px.length>=8,name+': the card\'s left edge is on the screen');
    assert.ok(px.some(blue),name+': the outline is on screen at the card\'s left edge ('+JSON.stringify(px.slice(0,6))+')');
  }
  async function open({extra=TRANSITION,prefix='',zoom=0}={}){
    extraCss=extra;prefixCss=prefix;
    await p.goto(origin+'/');
    await p.getByRole('button',{name:'Open Components section'}).click();
    await p.getByRole('button',{name:'Toggle DestinationCard stories'}).click();
    await p.getByRole('button',{name:'Select story DestinationCard / Default'}).click();
    await p.getByRole('button',{name:'Switch to edit mode'}).click();
    if(zoom)await p.addStyleTag({content:'[data-component-edit-device-frame]{transform:scale('+zoom+') !important}'});
    await card().waitFor();
    await frame().locator('#isonim-editor-selection-paint-style').waitFor({state:'attached'});
    if(zoom)assert.ok(Math.abs((await frameGeometry()).s-zoom)<1e-6,'the preview is shown at '+zoom);
    // The pointer starts outside the preview.
    await p.mouse.move(2,2);
    await p.waitForTimeout(500);
  }
  // A point of the card itself (not its heading or text), or of its heading
  // (`heading`), in editor-page pixels.
  async function cardPoint(heading=false){
    const at=await card().evaluate((n,heading)=>{const t=heading?n.querySelector('h1'):n;const r=t.getBoundingClientRect();for(let y=r.top+3;y<r.bottom;y+=4)for(let x=r.left+3;x<r.right;x+=4)if(document.elementFromPoint(x,y)===t)return {x,y};return null;},heading);
    assert.ok(at,'a point of the card can be pointed at');
    const f=await frameGeometry();return {x:f.x+at.x*f.s,y:f.y+at.y*f.s};
  }
  // A point of the preview's body clear of the card (below, right of or above
  // it), nearest first.
  async function bodyPoint(){
    const at=await card().evaluate(n=>{const r=n.getBoundingClientRect();const pts=[];
      for(let x=4;x<innerWidth-4;x+=6)for(let y=4;y<innerHeight-4;y+=6){
        const d=Math.max(r.left-x,x-r.right,r.top-y,y-r.bottom);
        if(d>=12&&document.elementFromPoint(x,y)===document.body)pts.push({x,y,d});}
      pts.sort((a,b)=>a.d-b.d);return pts[0]||null;});
    assert.ok(at,'a point of the body below the card');
    const f=await frameGeometry();return {x:f.x+at.x*f.s,y:f.y+at.y*f.s};
  }
  // The overlay `id` lies on the card's border box and draws `outline`.
  async function onBorderBox(name,id,outline){
    const r=await rectOf(card());
    const o=await overlay(id);
    assert.equal(o.length,1,name+': one '+id);
    const b=o[0];
    assert.ok(Math.abs(b.left-r.left)<0.05&&Math.abs(b.top-r.top)<0.05&&Math.abs(b.width-r.width)<0.05&&Math.abs(b.height-r.height)<0.05,
      name+': '+id+' lies on the card\'s border box ('+JSON.stringify([b,r])+')');
    assert.deepEqual(b.outline,outline,name+': '+id+' draws the outline');
    assert.equal(b.visibility,'visible');assert.equal(b.pointerEvents,'none');
  }
  // The card is unchanged and page code has seen nothing: the transition
  // events, the card's animations (while its .4s transition would run) and
  // every computed property.
  async function untouched(name,style0){
    assert.deepEqual(await animations(),[],name+': the card\'s getAnimations() is empty');
    await p.waitForTimeout(550);
    assert.deepEqual(await pageEvents(),[],name+': no transition or animation event reaches the page');
    assert.deepEqual(await animations(),[],name+': the card\'s getAnimations() is still empty');
    const style=await cardStyle();
    if(style!==style0){
      const a=style0.split(';'),b=style.split(';');
      assert.fail(name+': the card\'s computed style changed: '+b.filter(x=>!a.includes(x)).join('; '));
    }
  }
  // One case: hover the card, select it, move off it; `scroll` scrolls the
  // preview before the hover and again once the card is selected.
  async function outlineCase(name,{extra=TRANSITION,prefix='',zoom=0,scroll=0,chrome=1}={}){
    if(!want(name))return;
    await open({extra,prefix,zoom});
    if(scroll){
      await card().evaluate((n,s)=>{n.ownerDocument.body.scrollTop=s;},scroll);
      assert.equal(await card().evaluate(n=>n.ownerDocument.body.scrollTop),scroll,name+': the page scrolled');
      await p.waitForTimeout(100);
    }
    const style0=await cardStyle(),outline0=await cardOutline();
    // The control for the screen check: nothing blue there before the hover.
    const bare=(await strip(3.5,chrome)).filter(Boolean);
    assert.ok(bare.length>=8,name+': the card\'s left edge is on the screen');
    assert.ok(!bare.some(blue),name+': nothing blue at the card\'s left edge before the hover ('+JSON.stringify(bare.filter(blue).slice(0,4))+')');
    await listen();
    await observe();
    // Hover the heading, then the card: the hover outline moves from one to
    // the other.
    const head=await cardPoint(true);
    await p.mouse.move(head.x,head.y,{steps:3});
    assert.equal(await card().evaluate(n=>n.querySelector('h1').getAttribute('data-isonim-hovered')),'true',name+': the heading is hovered');
    await p.waitForTimeout(100);
    const at=await cardPoint();
    await p.mouse.move(at.x,at.y,{steps:3});
    assert.deepEqual(await marks(),['true',''],name+': the card is hovered');
    await untouched(name+' (hover)',style0);
    assert.deepEqual(await cardOutline(),outline0,name+' (hover): the card\'s outline');
    await onBorderBox(name+' (hover)','isonim-editor-hover-outline',HOVER);
    assert.equal((await overlay('isonim-editor-selection-outline')).length,0,name+' (hover): no selection outline');
    await shown(name+' (hover)',3.5,chrome);
    // The hover added and removed nothing anywhere in the document: the
    // chrome it shows was made when the bridge started.
    assert.deepEqual(await childList(),[],name+' (hover): a page MutationObserver sees no child-list change');
    // Select. The pointer is still over the card, so its hover outline shows,
    // as when the hover rule came after the selection's.
    await p.mouse.click(at.x,at.y);
    await frame().locator('[data-isonim-selected="true"]').waitFor();
    assert.deepEqual(await marks(),['true','true'],name+': the card is selected');
    await untouched(name+' (select)',style0);
    assert.deepEqual(await cardOutline(),outline0,name+' (select): the card\'s outline');
    await onBorderBox(name+' (select, hovered)','isonim-editor-hover-outline',HOVER);
    // Off the card: the selection outline.
    const off=await bodyPoint();
    await p.mouse.move(off.x,off.y,{steps:3});
    assert.deepEqual(await marks(),['','true'],name+': the card is selected, not hovered');
    await untouched(name+' (selected)',style0);
    await onBorderBox(name+' (selected)','isonim-editor-selection-outline',SELECTION);
    assert.equal((await overlay('isonim-editor-hover-outline')).length,0,name+' (selected): no hover outline');
    await shown(name+' (selected)',3,chrome);
    if(scroll){
      // Scrolled on with the card selected: the outline follows it.
      await card().evaluate((n,s)=>{n.ownerDocument.body.scrollTop=s;},scroll+30);
      await p.waitForTimeout(100);
      await onBorderBox(name+' (selected, scrolled on)','isonim-editor-selection-outline',SELECTION);
      await shown(name+' (selected, scrolled on)',3,chrome);
      await untouched(name+' (scrolled on)',style0);
    }
    // Selecting and moving off added and removed nothing in the page's own
    // nodes; what changed is inside the editor's chrome container.
    const outside=(await childList()).filter(r=>!r.inChrome);
    assert.deepEqual(outside,[],name+' (select): a page MutationObserver sees no child-list change outside the editor\'s chrome');
    // Clearing the selection (Escape) removes the outline.
    await p.keyboard.press('Escape');
    await p.waitForTimeout(150);
    assert.deepEqual(await marks(),['',''],name+': Escape clears the selection');
    assert.equal((await overlay('isonim-editor-selection-outline')).length,0,name+': no outline once nothing is selected');
    await untouched(name+' (cleared)',style0);
    proof.push({name,outline0,events:await pageEvents()});
    cases.push(name);
  }

  await outlineCase('in place');
  await outlineCase('on a scrolled page',{extra:TRANSITION+SCROLLER,scroll:240});
  await outlineCase('at a 200% preview scale, scrolled',{extra:TRANSITION+SCROLLER,scroll:240,zoom:2});
  await outlineCase('on a card with zoom',{extra:TRANSITION+'.destination-card{zoom:1.5}'});
  await outlineCase('under a transform on body',{prefix:'body{transform:translate(30px,12px) scale(0.8);transform-origin:0 0}',chrome:0.8});
  // Every element transitions, so the editor's chrome does too unless it
  // holds its own.
  await outlineCase('every element of the page transitions',{extra:'*,*::before,*::after{transition:all .4s linear !important}'});

  // The chrome follows movement the page drives, with the pointer still.
  // Each case moves the selected card (or, `hoverOnly`, the hovered one)
  // by page code only; mid-motion cases pause the card's animation part-way.
  const handlesBox=()=>frame().locator('#isonim-editor-selection-handles').evaluate(n=>{const b=n.getBoundingClientRect();return {left:b.left,top:b.top,width:b.width,height:b.height};});
  const frames=(k=2)=>frame().locator('body').evaluate((n,k)=>new Promise(res=>{const w=n.ownerDocument.defaultView;let i=0;const f=()=>{if(++i>=k)res();else w.requestAnimationFrame(f);};w.requestAnimationFrame(f);}),k);
  async function followed(name,hoverOnly){
    await frames(3);
    if(hoverOnly){await onBorderBox(name,'isonim-editor-hover-outline',HOVER);return;}
    await onBorderBox(name,'isonim-editor-selection-outline',SELECTION);
    const r=await rectOf(card()),h=await handlesBox();
    assert.ok(Math.abs(h.left-r.left)<1.01&&Math.abs(h.top-r.top)<1.01&&Math.abs(h.width-r.width)<3&&Math.abs(h.height-r.height)<3,
      name+': the selection handles lie on the card ('+JSON.stringify([h,r])+')');
  }
  async function movementCase(name,move,{hoverOnly=false,midway=0,setup=null,extra=''}={}){
    if(!want(name))return;
    await open({extra});
    if(setup)await card().evaluate(setup);
    const at=await cardPoint();
    if(hoverOnly){await p.mouse.move(at.x,at.y,{steps:3});assert.deepEqual(await marks(),['true',''],name+': hovered');}
    else{
      await p.mouse.click(at.x,at.y);
      await frame().locator('[data-isonim-selected="true"]').waitFor();
      const off=await bodyPoint();await p.mouse.move(off.x,off.y,{steps:3});
      assert.deepEqual(await marks(),['','true'],name+': selected, the pointer off the card');
    }
    const before=await rectOf(card());
    await followed(name+' (before)',hoverOnly);
    await card().evaluate(move);
    if(midway){
      // Part-way: the card's own animations held at `midway` ms.
      await card().evaluate((n,t)=>n.getAnimations().forEach(a=>{a.pause();a.currentTime=t;}),midway);
      const mid=await rectOf(card());
      assert.ok(Math.abs(mid.left-before.left)+Math.abs(mid.top-before.top)>5,name+': the card is part-way');
      await followed(name+' (part-way)',hoverOnly);
      await card().evaluate(n=>n.getAnimations().forEach(a=>a.finish()));
    } else await p.waitForTimeout(700);
    const after=await rectOf(card());
    const moved=Math.abs(after.left-before.left)+Math.abs(after.top-before.top);
    assert.ok(moved>=20,name+': the page moved the card ('+moved+'px)');
    await followed(name+' (after)',hoverOnly);
    proof.push({name,before,after});
    cases.push(name);
  }
  // As the reviewer measured them: a banner inserted above (80px), the
  // card's margin (70px, under its .4s transition), a keyframe animation, a
  // transition of `left`, and a transform on an ancestor.
  const banner=(n)=>{const b=n.ownerDocument.createElement('div');b.style.height='80px';b.textContent='banner';n.parentNode.insertBefore(b,n);};
  await movementCase('moves: a banner inserted above',banner);
  await movementCase('moves: a margin change, part-way and after',n=>{n.style.marginLeft='70px';},{extra:TRANSITION,midway:200});
  await movementCase('moves: a keyframe animation, part-way and after',n=>{n.style.animation='isonim-test-slide 1s linear forwards';},
    {extra:'@keyframes isonim-test-slide{from{transform:translateX(0)}to{transform:translateX(160px)}}',midway:450});
  await movementCase('moves: a transition on left, part-way and after',n=>{n.style.left='150px';},
    {extra:'.destination-card{position:relative;left:0;transition:left .4s linear}',midway:200});
  await movementCase('moves: an ancestor\'s transform',n=>{n.parentElement.style.transform='translateY(40px)';},
    {setup:n=>{const w=n.ownerDocument.createElement('div');w.id='wrap';n.parentNode.insertBefore(w,n);w.appendChild(n);}});
  await movementCase('moves: a banner inserted above a hovered card',banner,{hoverOnly:true});

  // The agent's highlight (control CLI `select --highlight`, through the
  // editor's own adapter): chrome over the element, not a style on it; with
  // the selection outline beside it; following the element; moved to the
  // next element it highlights. At a 200% preview scale, so each ring is
  // several screen pixels wide.
  if(want('agent highlight')){
    const name='agent highlight';
    await open({zoom:2});
    const style0=await cardStyle();
    const attr0=await card().evaluate(n=>n.getAttribute('style'));
    const indigo=(c)=>c[2]-c[0]>=30&&c[1]-c[0]<=20&&c[0]<=215;
    const highlight=(id)=>p.evaluate(id=>globalThis.__isonimEditorVm.controlHighlightAdapter(makeNimstrLit(id)),id);
    const id=await card().evaluate(n=>n.getAttribute('data-isonim-element-id'));
    assert.ok(id,name+': the card has its element id');
    await listen();
    await observe();
    assert.equal(await highlight(id),true,name+': the adapter applied it');
    assert.equal(await card().getAttribute('data-editor-agent-highlight'),'true');
    await untouched(name,style0);
    assert.equal(await card().evaluate(n=>n.getAttribute('style')),attr0,name+': the card\'s style attribute is unchanged');
    assert.deepEqual((await childList()).filter(r=>!r.inChrome),[],name+': nothing added to the page\'s nodes');
    await onBorderBox(name,'isonim-editor-agent-highlight',['solid','2px','rgb(129, 140, 248)','3px']);
    const ring=async(out)=>(await strip(out)).filter(Boolean);
    assert.ok((await ring(4)).some(indigo),name+': the indigo ring is on screen 4px out ('+JSON.stringify((await ring(4)).slice(0,4))+')');
    // Selected as well: the blue ring at 2-4px, the indigo one moved out to
    // 5-7px, both on screen.
    const at=await cardPoint();
    await p.mouse.click(at.x,at.y);
    await frame().locator('[data-isonim-selected="true"]').waitFor();
    const off=await bodyPoint();await p.mouse.move(off.x,off.y,{steps:3});
    await onBorderBox(name+' (selected)','isonim-editor-selection-outline',SELECTION);
    await onBorderBox(name+' (selected)','isonim-editor-agent-highlight',['solid','2px','rgb(129, 140, 248)','5px']);
    assert.ok((await ring(3)).some(c=>blue(c)&&!indigo(c)),name+' (selected): the blue ring 3px out ('+JSON.stringify((await ring(3)).slice(0,4))+')');
    assert.ok((await ring(6)).some(indigo),name+' (selected): the indigo ring 6px out ('+JSON.stringify((await ring(6)).slice(0,4))+')');
    // It follows the card.
    await card().evaluate(banner);
    await frames(3);
    await onBorderBox(name+' (moved)','isonim-editor-agent-highlight',['solid','2px','rgb(129, 140, 248)','5px']);
    // Highlighting the heading moves it there and clears the card.
    const headId=await card().evaluate(n=>n.querySelector('h1').getAttribute('data-isonim-element-id'));
    assert.ok(headId,name+': the heading has its element id');
    assert.equal(await highlight(headId),true);
    assert.equal(await card().getAttribute('data-editor-agent-highlight'),null,name+': the card is no longer marked');
    await frames(2);
    const h=await card().evaluate(n=>{const r=n.querySelector('h1').getBoundingClientRect();return {left:r.left,top:r.top,width:r.width,height:r.height};});
    const o=(await overlay('isonim-editor-agent-highlight'))[0];
    assert.ok(o&&Math.abs(o.left-h.left)<0.05&&Math.abs(o.top-h.top)<0.05&&Math.abs(o.width-h.width)<0.05,name+': on the heading now ('+JSON.stringify([o,h])+')');
    assert.equal(o.outline[3],'3px',name+': the heading carries no other outline, so 3px');
    await untouched(name+' (moved on)',await cardStyle());
    cases.push(name);
  }

  // The chrome's requestAnimationFrame loop (round 3): exactly one, and
  // stopped when there is nothing to follow. Counted by wrapping the
  // preview window's requestAnimationFrame (page-side, no hook in the
  // bridge): each call of the bridge's `watchTick` is one tick, and a second
  // requestAnimationFrame loop of the test's own counts frames, so the ticks
  // between two of its frames are the loops running in that frame.
  const installCounter=()=>card().evaluate(n=>{
    const w=n.ownerDocument.defaultView;if(w.__watch)return;
    const orig=w.requestAnimationFrame.bind(w);
    const st=w.__watch={ticks:0,cost:0,frames:0,max:0,last:0};
    w.requestAnimationFrame=function(cb){return orig(function(t){
      if(cb.name==='watchTick'){st.ticks++;const s0=w.performance.now();try{cb(t);}finally{st.cost+=w.performance.now()-s0;}
        // Right after the tick placed the chrome, in the same frame: where
        // the selected card, the handles box and its margin-left handle are.
        if(st.sample){const d=w.document,c=d.querySelector('[data-isonim-selected="true"]'),hb=d.getElementById('isonim-editor-selection-handles'),
          mh=d.querySelector('[data-box-handle="margin-left"]'),ph=d.querySelector('[data-box-handle="padding-left"]');
          if(c&&hb&&mh&&ph){const r=c.getBoundingClientRect(),h=hb.getBoundingClientRect(),m=mh.getBoundingClientRect(),cs=w.getComputedStyle(c);
            st.sample.push({card:[r.left,r.top,r.width,r.height],box:[h.left,h.top,h.width,h.height],marginHandleRight:m.right,marginLeft:parseFloat(cs.marginLeft),
              paddingHandleLeft:ph.getBoundingClientRect().left,paddingLeft:parseFloat(cs.paddingLeft)});}}}
      else cb(t);});};
    const count=function(){st.frames++;st.max=Math.max(st.max,st.ticks-st.last);st.last=st.ticks;orig(count);};
    orig(count);
  });
  const watchStats=()=>p.evaluate(()=>{const f=[...document.querySelectorAll('iframe[title="Editable component preview"]')][0];const st=f.contentWindow.__watch;return {ticks:st.ticks,cost:st.cost,frames:st.frames};});
  // Ticks, frames, the most ticks in one frame and the watcher's time per
  // frame over `k` frames (or, when the frame is hidden, `ms` of time).
  async function sampleWatch(k=30){
    await p.evaluate(()=>{const f=[...document.querySelectorAll('iframe[title="Editable component preview"]')][0];const st=f.contentWindow.__watch;st.max=0;st.last=st.ticks;});
    const a=await watchStats();const deadline=Date.now()+15000;let b=a;
    while(Date.now()<deadline){await p.waitForTimeout(100);b=await watchStats();if(b.frames-a.frames>=k)break;}
    const max=await p.evaluate(()=>[...document.querySelectorAll('iframe[title="Editable component preview"]')][0].contentWindow.__watch.max);
    const frames=b.frames-a.frames;
    return {ticks:b.ticks-a.ticks,frames,max,msPerFrame:frames?(b.cost-a.cost)/frames:0};
  }
  const pointerOutside=()=>p.mouse.move(2,2,{steps:4});
  async function selectCardPointerOff(){
    const at=await cardPoint();
    await p.mouse.click(at.x,at.y);
    await frame().locator('[data-isonim-selected="true"]').waitFor();
    const off=await bodyPoint();await p.mouse.move(off.x,off.y,{steps:3});
  }
  if(want('one loop while selected and moving; stops')){
    const name='one loop while selected and moving; stops';
    await open({extra:'@keyframes isonim-test-bob{from{transform:translateX(0)}to{transform:translateX(120px)}}'});
    await installCounter();
    await selectCardPointerOff();
    let w=await sampleWatch();
    assert.ok(w.frames>=20,name+': frames counted ('+JSON.stringify(w)+')');
    assert.equal(w.max,1,name+': selected and still, one loop ('+JSON.stringify(w)+')');
    assert.ok(w.ticks>=w.frames-2,name+': the loop runs every frame ('+JSON.stringify(w)+')');
    const still=w.msPerFrame;
    await card().evaluate(n=>{n.style.animation='isonim-test-bob .7s linear infinite alternate';});
    await p.waitForTimeout(1300);
    w=await sampleWatch(40);
    assert.equal(w.max,1,name+': after 1.3 s of animation, still one loop ('+JSON.stringify(w)+')');
    const moving=w.msPerFrame;
    await card().evaluate(n=>{n.getAnimations().forEach(a=>{a.pause();a.currentTime=350;});});
    await followed(name+' (held part-way)',false);
    await card().evaluate(n=>{n.style.animation='';});
    await followed(name+' (stopped)',false);
    w=await sampleWatch();
    assert.equal(w.max,1,name+': after the animation, one loop ('+JSON.stringify(w)+')');
    // Nothing marked (Escape with the pointer on the preview's body): no loop.
    await p.keyboard.press('Escape');
    assert.deepEqual(await marks(),['',''],name+': nothing marked');
    await frames(3);
    w=await sampleWatch(20);
    assert.equal(w.ticks,0,name+': nothing marked, no loop ('+JSON.stringify(w)+')');
    console.log('COST watcher ms/frame: selected still',still.toFixed(3),'| selected, animated',moving.toFixed(3));
    proof.push({name,msPerFrame:{still,moving}});
    cases.push(name);
  }
  // Every frame of a move, sampled right after the loop placed the chrome
  // (round 4): a card moved by its own margin keeps its margin-left handle on
  // its margin edge, part-way and not only once it stops; a card moved under
  // a scaled body keeps the handles box on its border box.
  async function sampleMove(name,move,stop,frames){
    await card().evaluate(n=>{n.ownerDocument.defaultView.__watch.sample=[];});
    await card().evaluate(move);
    const deadline=Date.now()+20000;let got=[];
    while(Date.now()<deadline){await p.waitForTimeout(100);got=await card().evaluate(n=>n.ownerDocument.defaultView.__watch.sample.length);if(got>=frames)break;}
    const sample=await card().evaluate(n=>{const w=n.ownerDocument.defaultView;const s=w.__watch.sample;w.__watch.sample=null;return s;});
    if(stop)await card().evaluate(stop);
    assert.ok(sample.length>=frames,name+': '+frames+' frames sampled ('+sample.length+')');
    return sample;
  }
  if(want('follows every frame: a card moved by its own margin')){
    const name='follows every frame: a card moved by its own margin';
    await open({extra:'.destination-card{transition:margin-left 2.5s linear}'});
    await installCounter();
    await selectCardPointerOff();
    await frames(3);
    const sample=await sampleMove(name,n=>{n.style.marginLeft='300px';},null,30);
    // The margin-left handle keeps its place relative to the margin edge
    // (border-box left minus the used margin), as in the first frame sampled.
    const rel=(f)=>f.marginHandleRight-(f.card[0]-f.marginLeft);
    const at0=rel(sample[0]);
    const moving=sample.filter(f=>f.marginLeft>5&&f.marginLeft<295);
    assert.ok(moving.length>=10,name+': frames part-way ('+moving.length+')');
    const off=moving.map(f=>Math.abs(rel(f)-at0));
    assert.ok(Math.max(...off)<1.5,name+': the margin-left handle on the margin edge in every frame (worst '+Math.max(...off).toFixed(2)+'px; at margin '+moving[off.indexOf(Math.max(...off))].marginLeft.toFixed(1)+'px)');
    const box=moving.map(f=>Math.abs(f.box[0]-f.card[0])+Math.abs(f.box[1]-f.card[1]));
    assert.ok(Math.max(...box)<1.5,name+': the handles box on the card in every frame (worst '+Math.max(...box).toFixed(2)+'px)');
    proof.push({name,frames:moving.length,worstMarginHandle:Math.max(...off),worstBox:Math.max(...box)});
    cases.push(name);
  }
  if(want('follows: padding under border-box, the border box still')){
    const name='follows: padding under border-box, the border box still';
    await open({extra:'.destination-card{box-sizing:border-box}'});
    await installCounter();
    await selectCardPointerOff();
    await frames(3);
    const p0=await card().evaluate(n=>parseFloat(getComputedStyle(n).paddingLeft));
    const sample=await sampleMove(name,n=>{n.style.transition='padding-left 2s linear';n.style.paddingLeft='120px';},null,40);
    // The padding-left handle keeps its place relative to the content edge
    // (border-box left plus the used padding), as in the first frame sampled.
    const rel=(f)=>f.paddingHandleLeft-(f.card[0]+f.paddingLeft);
    const at0=rel(sample[0]);
    const moving=sample.filter(f=>f.paddingLeft>p0+5&&f.paddingLeft<115);
    assert.ok(moving.length>=10,name+': frames part-way ('+moving.length+')');
    const still=sample.every(f=>Math.abs(f.card[0]-sample[0].card[0])<0.01&&Math.abs(f.card[2]-sample[0].card[2])<0.01);
    assert.ok(still,name+': the border box does not move or resize');
    const off=moving.map(f=>Math.abs(rel(f)-at0));
    assert.ok(Math.max(...off)<1.5,name+': the padding-left handle on the content edge within a frame (worst '+Math.max(...off).toFixed(2)+'px; at padding '+moving[off.indexOf(Math.max(...off))].paddingLeft.toFixed(1)+'px)');
    proof.push({name,frames:moving.length,worstPaddingHandle:Math.max(...off)});
    cases.push(name);
  }
  if(want('follows every frame: under a scaled body')){
    const name='follows every frame: under a scaled body';
    await open({prefix:'body{transform:scale(0.5);transform-origin:0 0}',
      extra:'@keyframes isonim-test-glide{from{transform:translateX(0)}to{transform:translateX(600px)}}'});
    await installCounter();
    await selectCardPointerOff();
    await frames(3);
    const sample=await sampleMove(name,n=>{n.style.animation='isonim-test-glide 1.5s linear forwards';},n=>{n.style.animation='';},40);
    const travelled=Math.max(...sample.map(f=>f.card[0]))-Math.min(...sample.map(f=>f.card[0]));
    assert.ok(travelled>30,name+': the card moved ('+travelled.toFixed(1)+'px)');
    const box=sample.map(f=>Math.abs(f.box[0]-f.card[0])+Math.abs(f.box[1]-f.card[1]));
    assert.ok(Math.max(...box)<1.5,name+': the handles box on the card in every frame (worst '+Math.max(...box).toFixed(2)+'px)');
    proof.push({name,frames:sample.length,travelled,worstBox:Math.max(...box)});
    cases.push(name);
  }
  if(want('the pointer leaving the preview ends the hover')){
    const name='the pointer leaving the preview ends the hover';
    await open();
    await installCounter();
    const at=await cardPoint();
    await p.mouse.move(at.x,at.y,{steps:3});
    assert.deepEqual(await marks(),['true',''],name+': hovered');
    await onBorderBox(name,'isonim-editor-hover-outline',HOVER);
    await pointerOutside();
    await frames(3);
    assert.deepEqual(await marks(),['',''],name+': the hover marker is gone');
    assert.equal((await overlay('isonim-editor-hover-outline')).length,0,name+': no hover outline');
    assert.equal(await frame().locator('#isonim-editor-hover-label').evaluate(n=>n.hidden),true,name+': no hover label');
    const w=await sampleWatch(20);
    assert.equal(w.ticks,0,name+': no loop ('+JSON.stringify(w)+')');
    cases.push(name);
  }
  if(want('an agent-highlighted element the page removes')){
    const name='an agent-highlighted element the page removes';
    await open();
    await installCounter();
    const id=await card().evaluate(n=>n.getAttribute('data-isonim-element-id'));
    assert.equal(await p.evaluate(id=>globalThis.__isonimEditorVm.controlHighlightAdapter(makeNimstrLit(id)),id),true);
    await onBorderBox(name,'isonim-editor-agent-highlight',['solid','2px','rgb(129, 140, 248)','3px']);
    let w=await sampleWatch(15);
    assert.ok(w.ticks>0&&w.max===1,name+': one loop follows it ('+JSON.stringify(w)+')');
    await card().evaluate(n=>{window.__removedCard=n;n.remove();});
    await frames(3);
    assert.equal(await frame().locator('#isonim-editor-agent-highlight').evaluate(n=>n.hidden),true,name+': its overlay is hidden');
    w=await sampleWatch(20);
    assert.equal(w.ticks,0,name+': no loop ('+JSON.stringify(w)+')');
    cases.push(name);
  }
  if(want('a hidden preview frame, shown again')){
    const name='a hidden preview frame, shown again';
    await open();
    await installCounter();
    await selectCardPointerOff();
    let w=await sampleWatch(15);
    assert.ok(w.ticks>0,name+': the loop runs while selected ('+JSON.stringify(w)+')');
    await p.evaluate(()=>{document.querySelector('iframe[title="Editable component preview"]').style.display='none';});
    await p.waitForTimeout(400);
    const a=await watchStats();await p.waitForTimeout(1200);const b=await watchStats();
    assert.equal(b.ticks-a.ticks,0,name+': hidden, no loop ('+JSON.stringify({a,b})+')');
    await p.evaluate(()=>{document.querySelector('iframe[title="Editable component preview"]').style.display='';});
    await frames(3);
    await card().evaluate(n=>{n.style.marginLeft='40px';});
    await p.waitForTimeout(700);
    await followed(name+' (shown again, moved)',false);
    w=await sampleWatch(15);
    assert.equal(w.max,1,name+': shown again, one loop ('+JSON.stringify(w)+')');
    cases.push(name);
  }
  if(want('a disposed bridge')){
    const name='a disposed bridge';
    await open();
    await installCounter();
    await selectCardPointerOff();
    let w=await sampleWatch(15);
    assert.ok(w.ticks>0,name+': the loop runs while selected');
    await p.evaluate(()=>{const f=document.querySelector('iframe[title="Editable component preview"]');f.__isonimEmbeddedBridgeCleanup();});
    await p.waitForTimeout(200);
    w=await sampleWatch(20);
    assert.equal(w.ticks,0,name+': disposed, no loop ('+JSON.stringify(w)+')');
    cases.push(name);
  }

  assert.deepEqual(errors,[]);
  writeFileSync(pub+'/proof.json',JSON.stringify(proof,null,2));
  console.log('Edit outline GUI passed:',pub,cases.length,'cases:',cases.join(' | '));
} finally {
  if(browser)await browser.close();
  await new Promise(resolve=>server.close(resolve));
}
