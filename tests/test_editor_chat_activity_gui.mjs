/**
 * Production mounted full-editor chat behavior and layout. A test-only entry
 * injects normalized external events and admission outcomes to make stream timing
 * deterministic; EditorVM, reducer, renderer, DOM, keyboard, scroll and previews
 * are real. This is presentation coverage, not a substitute for the registered
 * real REST/official scenario integration. No browser/VM/RPC mocks.
 * A local control-host fixture explicitly substitutes connected transport state;
 * its negative case retains genuine disconnected rejection before actual approval.
 * Admission starts after the visible production preview is complete and its
 * primary/secondary DOM identities appear in the real parent-side scene graph
 * (shell.nim polls at 300ms/700ms). Fonts and two normal frames settle before
 * admission; no revision polling, mutation retry or expected-revision rebasing.
 * Stored-operation diagnostics are read-only and never resolve pending work.
 * The toolbar negative control disables only its CSS size-container to expose
 * the retained original full strip at narrow width; it proves the bounds guard
 * rejects the original clipped controls, then restores the production container.
 * Geometry checks wait for font layout and two browser animation frames because
 * the real chat view follows output in requestAnimationFrame. This observes its
 * scheduled scroll; it does not scroll, focus, modify DOM or relax visible bounds.
 * Assert stable turn/tool nodes, unsafe text, IME, drafts/tabs, focus/selection, scrollback,
 * narrow/wide overflow and composer/preview reachability; capture named states.
 */
import assert from 'node:assert/strict';
import {sidebarSearchFocusEvidence,requireSidebarSearchFocus} from '../tools/chat-focus-guard.mjs';
import {horizontalChatGuard,oldClippedChatControl} from '../tools/chat-horizontal-guard.mjs';
import {spawn} from 'node:child_process';
import {mkdtempSync, writeFileSync, readFileSync} from 'node:fs';
import {tmpdir} from 'node:os';
import path from 'node:path';
import {fileURLToPath} from 'node:url';
import {chromium} from '../node_modules/playwright/index.mjs';
const repo=path.resolve(path.dirname(fileURLToPath(import.meta.url)),'..');
const artifacts=mkdtempSync(path.join(tmpdir(),'isonim-chat-activity-'));
const server=spawn('python3',['-u','-m','http.server','0','--bind','127.0.0.1','--directory',path.join(repo,'build/editor-chat')],{stdio:['ignore','pipe','pipe']});
let origin; let serverText='';
const startup=new Promise((resolve,reject)=>{
  server.stdout.on('data',chunk=>{serverText+=chunk;const match=serverText.match(/port (\d+)/);if(match){origin=`http://127.0.0.1:${match[1]}`;resolve();}});
  server.once('exit',code=>reject(new Error(`server exited ${code}`)));
  setTimeout(()=>reject(new Error('startup timeout')),10000).unref();
});
let browser;let count=0;
const record=name=>{count++;process.stdout.write(`PASS ${name}\n`);};
// Observe concrete initial mount completion, rather than the helper's existence:
// __chatTest is published synchronously before iframe load and scene-graph scan.
async function mountedReady(page, name) {
  await page.waitForFunction(()=>{
    if (!window.__chatTest || document.readyState!=='complete' || document.fonts.status!=='loaded') return false;
    const frames=Array.from(document.querySelectorAll('iframe[data-page-project-frame="true"]'))
      .filter(frame=>frame.getClientRects().length && frame.offsetParent!==null);
    if(frames.length!==1) return false;
    const doc=frames[0].contentDocument;
    if(!doc || doc.readyState!=='complete' || doc.fonts.status!=='loaded') return false;
    const state=JSON.parse(window.__chatTest.controlState());
    return ['primary','secondary'].every(id=>doc.querySelector(`[data-isonim-element-id="${id}"]`) && state.elements.some(row=>row.id===id));
  },null,{timeout:5000});
  const ready=await page.evaluate(async()=>{
    const frameTimes=await new Promise(resolve=>requestAnimationFrame(first=>requestAnimationFrame(second=>resolve([first,second]))));
    const frame=Array.from(document.querySelectorAll('iframe[data-page-project-frame="true"]')).find(frame=>frame.getClientRects().length&&frame.offsetParent!==null);
    return {frameTimes,documentReadyState:document.readyState,fontStatus:document.fonts.status,
      previewReadyState:frame.contentDocument.readyState,previewFontStatus:frame.contentDocument.fonts.status,
      state:JSON.parse(window.__chatTest.controlState())};
  });
  writeFileSync(path.join(artifacts,`mounted-ready-${name}.json`),JSON.stringify(ready,null,2));
  return ready;
}
async function controlDiagnostic(page,id,phase) {
  const actual=JSON.parse(await page.evaluate(id=>window.__chatTest.controlDiagnostics(id),id));
  actual.phase=phase;
  writeFileSync(path.join(artifacts,`control-${id}-${phase}.json`),JSON.stringify(actual,null,2));
  return actual;
}

try{
  await startup;
  browser=await chromium.launch({headless:true, executablePath:process.env.PLAYWRIGHT_CHROMIUM_EXECUTABLE ?? '/nix/store/1id5xlj91r8d5cj5ks4a5byrxdvr4b50-chromium-143.0.7499.192/bin/chromium', env:{...process.env,LD_LIBRARY_PATH:''},args:['--no-sandbox']});
  const page=await browser.newPage({viewport:{width:1440,height:900}});
  const errors=[];page.on('pageerror',e=>errors.push(e.message));
  // Separate mounted host: direct admission uses the real shared controller,
  // then the actual chat Approve button applies only after transport is ready.
  const controlPage=await browser.newPage({viewport:{width:1440,height:900}});
  await controlPage.goto(origin);await controlPage.waitForFunction(()=>window.__chatTest);
  await controlPage.evaluate(()=>window.__chatTest.localApprovals(false));
  await controlPage.getByRole('checkbox',{name:'Require approval for agent navigation'}).check();
  await mountedReady(controlPage,'disconnected-approval');
  const controlBefore=JSON.parse(await controlPage.evaluate(()=>window.__chatTest.controlState()));
  const admitted=JSON.parse(await controlPage.evaluate(()=>{
    const state=JSON.parse(window.__chatTest.controlState());
    return window.__chatTest.control(JSON.stringify({commandId:'fixture-disconnected',command:'open-story',storyId:state.stories.find(row=>row.name==='Details').id}));
  }));
  const admittedEvidence=await controlDiagnostic(controlPage,'fixture-disconnected','admitted');
  assert.equal(admitted.status,'pending',JSON.stringify(admittedEvidence));
  assert.deepEqual(admittedEvidence.operation,admitted);
  const denied=JSON.parse(await controlPage.evaluate(()=>window.__chatTest.approval('fixture-disconnected',true)));
  assert.equal(denied.error,'disconnected_instance');
  assert.equal(JSON.parse(await controlPage.evaluate(()=>window.__chatTest.controlState())).storyId,controlBefore.storyId);
  const pendingRow=controlPage.locator('[data-editor-control-operation="fixture-disconnected"]');
  assert.equal(await pendingRow.getAttribute('data-operation-status'),'pending');
  await controlPage.evaluate(()=>window.__chatTest.localApprovals(true));
  const beforeClick=await controlDiagnostic(controlPage,'fixture-disconnected','before-click');
  await controlPage.locator('[data-editor-control-approve="fixture-disconnected"]').click();
  const afterClick=await controlDiagnostic(controlPage,'fixture-disconnected','after-click');
  assert.equal(await pendingRow.getAttribute('data-operation-status'),'applied',JSON.stringify({admitted,beforeClick,afterClick}));
  assert.equal(afterClick.operation.status,'applied');
  const controlAfter=JSON.parse(await controlPage.evaluate(()=>window.__chatTest.controlState()));
  assert.equal(controlAfter.storyId,controlBefore.stories.find(row=>row.name==='Details').id);
  await controlPage.close();record('local transport boundary preserves disconnected rejection and real mounted approval');
  // Real mounted hidden/visible documents have the same element IDs. Commands
  // must affect the visible production page, without touching the retained hidden
  // document; this is the negative control for URL-order frame selection.
  for(const [width,panelWidth] of [[1440,420],[1024,240]]){
    const previewPage=await browser.newPage({viewport:{width,height:900}});
    await previewPage.goto(origin);await previewPage.waitForFunction(()=>window.__chatTest);
    await previewPage.evaluate(value=>{window.__chatTest.width(value);window.__chatTest.localApprovals(true);},panelWidth);
    await previewPage.getByRole('checkbox',{name:'Require approval for agent navigation'}).uncheck();
    await mountedReady(previewPage,`visible-preview-${width}`);
    const visible=previewPage.locator('iframe[data-page-project-frame="true"]:visible');
    assert.equal(await visible.count(),1);
    const visibleElement=await visible.elementHandle();const visibleFrame=await visibleElement.contentFrame();assert(visibleFrame);
    const hiddenFrame=previewPage.frames().find(frame=>frame!==previewPage.mainFrame()&&frame.url()==='about:srcdoc');
    assert(hiddenFrame&&hiddenFrame!==visibleFrame,'old first-srcdoc selection identifies another document');
    const hiddenElement=await hiddenFrame.frameElement();
    assert.equal(await hiddenElement.isVisible(),false,'retained duplicate document is hidden');
    const hiddenPrimary=hiddenFrame.locator('[data-isonim-element-id="primary"]');assert.equal(await hiddenPrimary.count(),1);
    for(const [command,target,focus] of [['select','primary',true],['highlight','secondary',false]]){
      const before=JSON.parse(await previewPage.evaluate(()=>window.__chatTest.controlState()));
      const result=JSON.parse(await previewPage.evaluate(request=>window.__chatTest.control(JSON.stringify(request)),{commandId:`visible-${width}-${command}`,command,target,focus,highlight:true}));
      assert.equal(result.status,'applied');
      const node=visibleFrame.locator(`[data-isonim-element-id="${target}"]`);
      assert.equal(await node.getAttribute('data-editor-agent-highlight'),'true');
      assert.equal(await node.evaluate(el=>getComputedStyle(el).outlineWidth),'2px');
      const after=JSON.parse(await previewPage.evaluate(()=>window.__chatTest.controlState()));
      if(command==='select'){
        assert(await node.evaluate(el=>el.ownerDocument.activeElement===el));assert.equal(after.selection,'primary');
      }else{
        assert.equal(after.selection,before.selection,'highlight alone preserves existing primary selection');
        assert(await visibleFrame.locator('[data-isonim-element-id="primary"]').evaluate(el=>el.ownerDocument.activeElement===el),'highlight alone preserves focus');
      }
      assert.equal(after.highlight,target);
      assert.equal(await hiddenFrame.locator(`[data-isonim-element-id="${target}"]`).getAttribute('data-editor-agent-highlight'),null,'hidden duplicate remains untouched');
      assert.equal(await hiddenPrimary.evaluate(el=>el.ownerDocument.activeElement===el),false);
    }
    await previewPage.close();record(`visible production preview identity and hidden negative at ${width}`);
  }
  // Read the actual mounted colors and real shared control admission. The
  // existing local transport fixture supplies connection timing only; keyboard,
  // focus paint, revision guards and DOM remain production implementations.
  for(const [width,height,rail] of [[1440,900,420],[1024,768,240]]) {
    const designPage=await browser.newPage({viewport:{width,height}});
    await designPage.goto(origin);await designPage.waitForFunction(()=>window.__chatTest);
    await designPage.evaluate(rail=>{window.__chatTest.width(rail);window.__chatTest.localApprovals(true);},rail);
    await mountedReady(designPage,`navigation-design-${width}`);
    const approval=designPage.getByRole('checkbox',{name:'Require approval for agent navigation',exact:true});
    const help=designPage.locator('[data-editor-control-approval-help="true"]');
    const manual=designPage.getByText('Manual Edit mode opens the source-backed inspector in this same sidebar space.',{exact:true});
    const hint=designPage.getByText('tap to insert',{exact:true});
    assert.equal(await help.innerText(),'Turn off to let the agent focus, select, and highlight items automatically.');
    assert.equal(await approval.getAttribute('aria-describedby'),await help.getAttribute('id'));
    async function readable(node) {
      assert(await node.isVisible());
      const colors=await node.evaluate(el=>{
        const css=getComputedStyle(el),box=el.getBoundingClientRect();let background=el;
        while(background&&getComputedStyle(background).backgroundColor==='rgba(0, 0, 0, 0)')background=background.parentElement;
        const rgb=value=>(value.match(/[\d.]+/g)||[]).slice(0,3).map(Number);
        const lum=values=>values.map(v=>{v/=255;return v<=0.04045?v/12.92:((v+0.055)/1.055)**2.4;}).reduce((sum,v,i)=>sum+v*[0.2126,0.7152,0.0722][i],0);
        const foreground=css.color,bg=getComputedStyle(background).backgroundColor,a=lum(rgb(foreground)),b=lum(rgb(bg));
        return {foreground,background:bg,contrast:(Math.max(a,b)+0.05)/(Math.min(a,b)+0.05),fontSize:css.fontSize,opacity:css.opacity,
          inside:box.width>0&&box.height>0&&box.left>=0&&box.top>=0&&box.right<=innerWidth&&box.bottom<=innerHeight};
      });
      assert(colors.inside,JSON.stringify(colors));assert.equal(colors.opacity,'1');assert(colors.contrast>=4.5,JSON.stringify(colors));return colors;
    }
    const contrast={manual:await readable(manual),hint:await readable(hint),support:await readable(help)};
    const search=designPage.locator('[data-sidebar-search="true"]');
    const composer=designPage.getByRole('textbox',{name:'Agent prompt'});
    await composer.fill('Retained draft while agent navigates');await composer.focus();
    await approval.check();assert(await approval.isChecked());assert.equal(await approval.getAttribute('aria-checked'),'true');
    await composer.focus();
    const before=JSON.parse(await designPage.evaluate(()=>window.__chatTest.controlState()));
    const pending=JSON.parse(await designPage.evaluate(id=>window.__chatTest.control(JSON.stringify({commandId:id,command:'focus',target:'sidebar-search'})),`design-pending-${width}`));
    assert.equal(pending.status,'pending');assert(await composer.evaluate(el=>document.activeElement===el));
    const waiting=JSON.parse(await designPage.evaluate(()=>window.__chatTest.controlState()));
    assert.equal(waiting.focus,before.focus);assert.equal(waiting.selection,before.selection);assert.equal(waiting.highlight,before.highlight);
    await designPage.locator(`[data-editor-control-reject="design-pending-${width}"]`).click();
    assert.equal(await designPage.locator(`[data-editor-control-operation="design-pending-${width}"]`).getAttribute('data-operation-status'),'rejected');
    assert.equal(JSON.parse(await designPage.evaluate(()=>window.__chatTest.controlState())).focus,before.focus);
    await approval.uncheck();assert.equal(await approval.isChecked(),false);assert.equal(await approval.getAttribute('aria-checked'),'false');
    const applied=JSON.parse(await designPage.evaluate(id=>window.__chatTest.control(JSON.stringify({commandId:id,command:'focus',target:'sidebar-search'})),`design-focus-${width}`));
    assert.equal(applied.status,'applied');
    const rpcFocus=requireSidebarSearchFocus(await designPage.evaluate(sidebarSearchFocusEvidence));
    const field=await designPage.locator('[data-sidebar-search-field="true"]').elementHandle();
    const original=await field.getAttribute('style');let missingRing;
    try {
      await field.evaluate(el=>el.style.setProperty('outline','none','important'));
      missingRing=await designPage.evaluate(sidebarSearchFocusEvidence);
      assert.equal(missingRing.active,true);assert.throws(()=>requireSidebarSearchFocus(missingRing),/visible sidebar search focus ring/);
    } finally {
      await field.evaluate((el,value)=>{if(value===null)el.removeAttribute('style');else el.setAttribute('style',value);},original);await field.dispose();
    }
    requireSidebarSearchFocus(await designPage.evaluate(sidebarSearchFocusEvidence));
    await search.press('Tab');
    const blurred=await designPage.evaluate(sidebarSearchFocusEvidence);
    assert.equal(blurred.active,false);assert.equal(blurred.outlineStyle,'none');
    await designPage.keyboard.press('Shift+Tab');
    const keyboardFocus=requireSidebarSearchFocus(await designPage.evaluate(sidebarSearchFocusEvidence));
    assert.equal(await composer.inputValue(),'Retained draft while agent navigates');
    const after=JSON.parse(await designPage.evaluate(()=>window.__chatTest.controlState()));
    assert.equal(after.selection,before.selection);assert.equal(after.highlight,before.highlight);
    writeFileSync(path.join(artifacts,`navigation-focus-intro-${width}.json`),JSON.stringify({contrast,pending,applied,rpcFocus,missingRing,blurred,keyboardFocus},null,2));
    await designPage.close();record(`navigation preference semantics, RPC and keyboard focus paint, blur and readable guidance at ${width}`);
  }
  // Actual production toolbar, sized by the available preview column rather
  // than the browser width. All backend/mode affordances remain reachable.
  const toolbarPage=await browser.newPage({viewport:{width:1440,height:900}});
  await toolbarPage.goto(origin);await toolbarPage.waitForFunction(()=>window.__chatTest);
  async function toolbarGeometry() {
    return toolbarPage.evaluate(()=>{
      const bar=document.querySelector('[data-preview-chrome-bar]');
      const b=bar.getBoundingClientRect();
      const controls=Array.from(bar.querySelectorAll('[role="button"]')).filter(el=>el.getClientRects().length);
      return {height:b.height,width:b.width,scrollWidth:bar.scrollWidth,
        controls:controls.map(el=>{const r=el.getBoundingClientRect();return {
          label:el.getAttribute('aria-label')||el.title,width:r.width,height:r.height, inside:r.width>0&&r.height>0&&r.left>=b.left&&r.right<=b.right&&r.top>=b.top&&r.bottom<=b.bottom,
          hit:el.contains(document.elementFromPoint(r.left+r.width/2,r.top+r.height/2))};})};
    });
  }
  async function settleToolbar() {
    await toolbarPage.evaluate(async()=>{await document.fonts.ready;await new Promise(resolve=>requestAnimationFrame(()=>requestAnimationFrame(resolve)));});
  }
  const bar=toolbarPage.locator('[data-preview-chrome-bar]');
  const overflow=bar.locator('[data-preview-viewport-overflow]');
  const pinned=bar.locator('[data-preview-viewport-strip-host]');
  for(const [width,height,rail] of [[1440,900,420],[1024,768,240]]) {
    await toolbarPage.setViewportSize({width,height});await toolbarPage.evaluate(rail=>window.__chatTest.width(rail),rail);await settleToolbar();
    const compact=width===1024;
    assert.equal(await pinned.isVisible(),!compact);
    const geometry=await toolbarGeometry();
    assert.equal(geometry.height,44);
    assert(geometry.scrollWidth<=geometry.width,JSON.stringify(geometry));
    assert(geometry.controls.every(row=>row.inside&&row.hit),JSON.stringify(geometry));
    // Full set still exists; compacting does not remove backend/Mode choices.
    assert.deepEqual(await bar.locator('[data-toolbar-cluster="backend"] [data-choice-group-label]').evaluateAll(nodes=>nodes.map(n=>n.getAttribute('data-choice-group-label'))),['Web','TUI','GPUI','Freya','Cocoa','Android','iOS']);
    assert.deepEqual(await bar.locator('[data-toolbar-cluster="mode"] [data-choice-group-label]').evaluateAll(nodes=>nodes.map(n=>n.getAttribute('data-choice-group-label'))),['Spec','View','Comment','Edit']);
    for(const slug of ['desktop','laptop','tablet','phone']) {
      if(compact) {
        await overflow.click();
        const option=bar.locator(`[data-preview-viewport-dropdown-option="${slug}"]`);
        assert(await option.isVisible());await option.click();
        assert.equal(await overflow.getAttribute('aria-expanded'),'false');
      } else {
        await pinned.locator(`[data-choice-group-label="${slug[0].toUpperCase()+slug.slice(1)}"]`).click();
      }
      assert.equal(JSON.parse(await toolbarPage.evaluate(()=>window.__chatTest.controlState())).viewport,slug);
      if(compact) assert.equal(await bar.locator('[data-preview-viewport-current]').innerText(),slug[0].toUpperCase()+slug.slice(1));
    }
    await overflow.click();
    const options=bar.locator('[data-preview-viewport-dropdown-option]:visible');
    const slugs=await options.evaluateAll(nodes=>nodes.map(n=>n.getAttribute('data-preview-viewport-dropdown-option')));
    assert(slugs.length>0);
    assert.equal(slugs.includes('desktop'),compact);
    for(const slug of slugs) {
      await bar.locator(`[data-preview-viewport-dropdown-option="${slug}"]`).click();
      assert.equal(JSON.parse(await toolbarPage.evaluate(()=>window.__chatTest.controlState())).viewport,slug);
      const selectedGeometry=await toolbarGeometry();
      assert(selectedGeometry.controls.every(row=>row.inside&&row.hit),JSON.stringify({slug,selectedGeometry}));
      assert(selectedGeometry.scrollWidth<=selectedGeometry.width,JSON.stringify({slug,selectedGeometry}));
      await overflow.click();
    }
    await toolbarPage.keyboard.press('Escape');
    assert(await overflow.evaluate(el=>el.ownerDocument.activeElement===el));
    await toolbarPage.keyboard.press('Enter');
    assert(await options.first().evaluate(el=>el.ownerDocument.activeElement===el),'keyboard opening focuses first VISIBLE option');
    const firstSlug=await options.first().getAttribute('data-preview-viewport-dropdown-option');
    await toolbarPage.keyboard.press('ArrowDown');await toolbarPage.keyboard.press('ArrowUp');await toolbarPage.keyboard.press('Enter');
    assert.equal(JSON.parse(await toolbarPage.evaluate(()=>window.__chatTest.controlState())).viewport,firstSlug);
    assert.equal(await overflow.getAttribute('aria-expanded'),'false');
    const modes=bar.locator('[data-toolbar-cluster="mode"]');
    await modes.getByRole('button',{name:'Spec',exact:true}).click();
    assert.equal(JSON.parse(await toolbarPage.evaluate(()=>window.__chatTest.controlState())).mode,'emSpec');
    await modes.getByRole('button',{name:'View',exact:true}).click();
    assert.equal(JSON.parse(await toolbarPage.evaluate(()=>window.__chatTest.controlState())).mode,'emView');
    await settleToolbar();
    writeFileSync(path.join(artifacts,`preview-toolbar-${width}.json`),JSON.stringify({geometry,slugs,firstSlug},null,2));
    await toolbarPage.screenshot({path:path.join(artifacts,`preview-toolbar-${width}.png`)});
    record(`production toolbar visible viewport choices, keyboard and mode behavior at ${width}`);
  }
  // Original full controls are retained in production. Removing the container
  // query at the real narrow column reproduces clipping, without a fake widget.
  await toolbarPage.locator('[data-preview-center-column]').evaluate(el=>el.style.containerType='normal');await settleToolbar();
  const oldGeometry=await toolbarGeometry();
  assert(oldGeometry.controls.some(row=>!row.inside),JSON.stringify(oldGeometry));
  assert(oldGeometry.scrollWidth>oldGeometry.width);
  await toolbarPage.locator('[data-preview-center-column]').evaluate(el=>el.style.removeProperty('container-type'));await settleToolbar();
  const restoredGeometry=await toolbarGeometry();
  assert(restoredGeometry.controls.every(row=>row.inside&&row.hit),JSON.stringify(restoredGeometry));
  writeFileSync(path.join(artifacts,'preview-toolbar-negative.json'),JSON.stringify({oldGeometry,restoredGeometry},null,2));
  // Resize reversibility: the original wide strip and popup-only menu return.
  await toolbarPage.setViewportSize({width:1440,height:900});await toolbarPage.evaluate(()=>window.__chatTest.width(420));await settleToolbar();
  assert(await pinned.isVisible());await overflow.click();
  assert.equal(await bar.locator('[data-preview-viewport-dropdown-option="desktop"]').isVisible(),false);
  await toolbarPage.close();record('toolbar clipping negative control and resize restoration');
  await page.goto(origin);await page.waitForFunction(()=>window.__chatTest);
  const input=page.getByRole('textbox',{name:'Agent prompt'});
  const event=payload=>page.evaluate(value=>window.__chatTest.event(JSON.stringify(value)),payload);
  const setBusy=value=>page.evaluate(value=>window.__chatTest.busy(value),value);
  const frames=()=>page.evaluate(()=>new Promise(resolve=>requestAnimationFrame(()=>requestAnimationFrame(resolve))));
  const captureEvidence=[];
  async function visibleText(locator,text) {
    await locator.waitFor({state:'visible'});
    await page.waitForFunction(({selector,text})=>{
      const element=document.querySelector(selector);
      if(!element) return false;
      const walker=document.createTreeWalker(element,NodeFilter.SHOW_TEXT);
      let node;
      while(node=walker.nextNode()) {
        const index=node.textContent.indexOf(text);
        if(index<0) continue;
        const range=document.createRange();range.setStart(node,index);range.setEnd(node,index+text.length);
        const box=range.getBoundingClientRect();
        const scroll=element.closest('[data-chat-scroll]');
        const bounds=scroll?.getBoundingClientRect() ?? {top:0,bottom:innerHeight,left:0,right:innerWidth};
        if(box.width>0 && box.height>0 && box.top>=bounds.top && box.bottom<=bounds.bottom && box.left>=bounds.left && box.right<=bounds.right) return true;
      }
      return false;
    },{selector:await locator.evaluate(el=>{
      const id='capture-'+Math.random().toString(36).slice(2);el.setAttribute('data-capture-anchor',id);return `[data-capture-anchor="${id}"]`;
    }),text},{timeout:5000});
  }
  async function followLatest() {
    const latest=page.locator('[data-chat-latest]');
    if(await latest.isVisible()) await latest.click();
    else await page.locator('[data-chat-scroll]').evaluate(el=>{el.scrollTop=el.scrollHeight;el.dispatchEvent(new Event('scroll'));});
    await page.waitForFunction(()=>{const el=document.querySelector('[data-chat-scroll]');return el.scrollHeight-el.scrollTop-el.clientHeight<=24;});
    await frames();
  }
  const shot=async(name,width=420)=>{
    await page.evaluate(value=>window.__chatTest.width(value),width);
    await page.waitForFunction(width=>Math.abs(document.querySelector('.editor-chat').getBoundingClientRect().width-width)<30,width);
    await frames();
    await horizontalChatGuard(page);
    if(name==='tool-heavy') {
      await page.locator('[data-chat-kind="tool_call"]').evaluate(el=>el.scrollIntoView({block:'start'}));
      await frames();
      const tool=page.locator('[data-chat-kind="tool_call"]');
      assert.equal(await tool.locator('details').getAttribute('open'),'');
      await visibleText(tool,'Compile story');await visibleText(tool,'failed');
      await visibleText(tool,'Compiler failed');await visibleText(tool.locator('[data-chat-detail]'),'"story":"Hero"');
      await visibleText(tool.locator('[data-chat-detail]'),'detailed diagnostic');
    } else if(name==='activity-details') {
      await followLatest();
      await visibleText(page.locator('[data-chat-kind="diff"]'),'Diff · stories.nim');
      await visibleText(page.locator('[data-chat-kind="diff"] [data-chat-detail]'),'- old');
      await visibleText(page.locator('[data-chat-kind="diff"] [data-chat-detail]'),'+ new');
      await visibleText(page.locator('[data-chat-kind="plan"]'),'Build source');
      await visibleText(page.locator('[data-chat-kind="plan"]'),'Open story');
      await visibleText(page.locator('[data-chat-kind="llm_request"] [data-chat-detail]'),'Reported model');
      await visibleText(page.locator('[data-chat-kind="llm_request"] [data-chat-detail]'),'120 input / 30 output tokens');
    } else if(name==='waiting') {
      await followLatest();
      const question=page.locator('[data-chat-kind="status"]').filter({hasText:'Which variant?'});
      await visibleText(question,'Which variant?');
      await visibleText(question.locator('[data-chat-availability]'),'This editor cannot answer this request.');
      assert.equal(await question.locator('details').getAttribute('open'),null);
      assert.equal(await question.locator('button').count(),0);
    } else if(name==='error') {
      await followLatest();
      const failure=page.locator('[data-chat-kind="error"]').filter({hasText:'The source build failed. Your draft is preserved.'});
      assert.equal(await failure.count(),1);
      await visibleText(failure,'The source build failed. Your draft is preserved.');
      assert.equal(await input.inputValue(),'draft while streaming');
      assert.equal(await page.getByRole('button',{name:'Close conversation'}).isVisible(),true);
    } else if(name==='long-history') {
      await followLatest();
      await visibleText(page.locator('[data-chat-kind="review"]').last(),'Review item 34');
      await visibleText(page.locator('[data-chat-role="arAssistant"]').last(),'Actual new assistant chunk');
      await visibleText(page.locator('[data-chat-kind="sub_agent"]'),'A new child result arrived');
    } else if(name==='empty') {
      await page.getByRole('button',{name:'Insert suggested prompt'}).first().waitFor({state:'visible'});
      assert.equal(await input.inputValue(),'');
    } else if(name==='streaming') {
      await followLatest();
      await visibleText(page.locator('[data-chat-role="arUser"]').last(),'line one');
      await visibleText(page.locator('[data-chat-role="arUser"]').last(),'line two');
      await visibleText(page.locator('[data-chat-markdown="heading"]'),'Design update');
      await visibleText(page.locator('[data-chat-markdown="list"]'),'Keep the preview usable');
      await visibleText(page.locator('[data-chat-markdown="code"]'),'let safe = "<script>"');
      assert.equal(await input.inputValue(),'draft while streaming');
      assert.equal(await page.getByRole('button',{name:'Send agent prompt'}).isDisabled(),true);
    }
    await page.screenshot({path:path.join(artifacts,`${name}-${width}.png`)});
    captureEvidence.push({name,width,visibleDOMAssertions:true});
    record(`visible required ${name} capture at ${width}`);
  };
  // Public producer DTOs exercise normalization and the actual mounted view.
  // Isolated pages keep each request visible without altering stream admission.
  const questionCorpus=JSON.parse(readFileSync(path.join(repo,'tests/scenarios/chat-activity/public-session-events.json')));
  for(const width of [420,240])for(const name of ['question','question-free-form','question-multi-choice','question-confirmation']){
    const questionPage=await browser.newPage({viewport:{width:width===420?1440:1024,height:width===420?900:768}});
    try{
      await questionPage.goto(origin);await questionPage.waitForFunction(()=>window.__chatTest);
      await questionPage.evaluate(value=>window.__chatTest.width(value),width);
      await mountedReady(questionPage,`question-${name}-${width}`);
      await horizontalChatGuard(questionPage);
      if(width===240&&name==='question') {
        const restored=await oldClippedChatControl(questionPage);
        writeFileSync(path.join(artifacts,'horizontal-clipping-control.json'),JSON.stringify({oldClippedStateRejected:true,restored},null,2));
        record('same horizontal guard rejects original tablet clipping and accepts restored layout');
      }
      const draft=questionPage.getByRole('textbox',{name:'Agent prompt'});
      await draft.fill('Retained next draft');
      const payload=questionCorpus.scenes[name][0];
      await questionPage.evaluate(value=>window.__chatTest.harborEvent(JSON.stringify(value)),payload);
      const card=questionPage.locator('[data-chat-source="agent_question"]');
      const notice=card.locator('[data-chat-availability]');
      assert.equal(await notice.innerText(),'This editor cannot answer this request.');
      assert(await notice.isVisible(),'availability visible before expansion');
      assert.equal(await notice.evaluate(el=>el.closest('details')),null);
      assert.equal(await card.locator('details').getAttribute('open'),null);
      // Render effects synchronously insert the card, but the production chat
      // schedules follow-output in RAF. Wait through that callback and the next
      // frame after font layout, then retain the exact whole-notice bounds check.
      // Match the existing visible-text readiness budget; missing/stuck fonts
      // fail explicitly rather than leaving an unbounded document.fonts.ready.
      await questionPage.waitForFunction(()=>document.fonts.status==='loaded',null,{timeout:5000});
      const readiness=await questionPage.evaluate(async()=>{
        const frameTimes=await new Promise(resolve=>requestAnimationFrame(first=>requestAnimationFrame(second=>resolve([first,second]))));
        const scroll=document.querySelector('[data-chat-scroll]');
        return {frameTimes,fontStatus:document.fonts.status,documentReadyState:document.readyState,
          scrollTop:scroll.scrollTop,scrollHeight:scroll.scrollHeight,clientHeight:scroll.clientHeight};
      });
      const box=await notice.boundingBox();const bounds=await questionPage.locator('[data-chat-scroll]').boundingBox();
      const geometry={name,width,box,bounds,readiness};
      writeFileSync(path.join(artifacts,`question-layout-${name}-${width}.json`),JSON.stringify(geometry,null,2));
      assert(box&&bounds&&box.y>=bounds.y&&box.y+box.height<=bounds.y+bounds.height,
        `notice inside visible scroll area: ${JSON.stringify(geometry)}`);
      assert((await card.innerText()).includes(payload.prompt));
      assert((await card.innerText()).includes(payload.request));
      assert((await card.innerText()).includes(payload.kind));
      for(const option of payload.options)assert((await card.innerText()).includes(option.label));
      assert.equal(await card.locator('button,input,textarea,select').count(),0);
      assert.equal(await draft.inputValue(),'Retained next draft');
      await card.locator('summary').click();
      assert(await card.locator('[data-chat-detail]').isVisible());
      assert((await card.locator('[data-chat-detail]').innerText()).includes(payload.request));
      assert.equal(await draft.inputValue(),'Retained next draft');
      record(`visible unavailable ${payload.kind} request at ${width}, expandable payload and draft retained`);
    }finally{await questionPage.close();}
  }
  await shot('empty');await shot('empty',240);
  await page.getByRole('button',{name:'Insert suggested prompt'}).first().click();
  assert((await input.inputValue()).length>0);
  await page.getByRole('button',{name:'Insert suggested prompt'}).first().waitFor({state:'visible'});
  record('suggestion only edits draft');
  await page.evaluate(()=>window.__chatTest.backend(false));
  await input.fill('retry draft');await page.getByRole('button',{name:'Send agent prompt'}).click();
  assert.equal(await input.inputValue(),'retry draft');
  await page.getByRole('button',{name:'Insert suggested prompt'}).first().waitFor({state:'hidden'});
  record('failed admission preserves draft and dismisses suggestions');
  await page.evaluate(()=>window.__chatTest.backend(true));
  await input.fill('line one');await input.press('Shift+Enter');await input.press('End');await input.type('line two');
  assert.equal(await input.inputValue(),'line one\nline two');
  await input.dispatchEvent('compositionstart');await input.press('Enter');
  assert.equal(await page.locator('[data-chat-role="arUser"]').count(),1);
  await input.dispatchEvent('compositionend');await input.press('Enter');
  await page.waitForFunction(()=>document.querySelectorAll('[data-chat-role="arUser"]').length===2);
  assert.equal(await input.inputValue(),'');record('multiline and IME send guard');
  await setBusy(true);await input.fill('draft while streaming');
  assert.equal(await page.getByRole('button',{name:'Send agent prompt'}).isDisabled(),true);
  await input.press('Enter');assert.equal(await input.inputValue(),'draft while streaming');
  await event({kind:'message_chunk',text:'# Design update\n- Keep the preview usable\n```nim\nlet safe = "<script>"\n```'});
  await page.locator('[data-chat-role="arAssistant"]').waitFor();
  await input.focus();await event({kind:'message_chunk',text:'\nStreaming continues'});
  assert.equal(await input.evaluate(el=>document.activeElement===el),true);
  assert.equal(await input.inputValue(),'draft while streaming');record('streaming draft and composer focus');
  assert.equal(await page.locator('[data-chat-markdown="heading"]').innerText(),'Design update');
  assert.equal(await page.locator('[data-chat-markdown="list"]').count(),1);
  assert((await page.locator('[data-chat-markdown="code"]').innerText()).includes('<script>'));
  assert.equal(await page.locator('.editor-chat script').count(),0);record('safe Markdown lists and code');
  await page.locator('[data-chat-markdown="heading"]').evaluate(el=>{const range=document.createRange();range.selectNodeContents(el);const selection=window.getSelection();selection.removeAllRanges();selection.addRange(range);});
  const selected=await page.evaluate(()=>window.getSelection().toString());
  await event({kind:'message_chunk',text:'\nMore output'});
  assert.equal(await page.evaluate(()=>window.getSelection().toString()),selected);record('stream updates preserve transcript selection');
  await shot('streaming');await shot('streaming',240);
  await event({kind:'tool_call',toolCallId:'tool-1',toolName:'Compile story',status:'running',toolArguments:'{"story":"Hero"}'});
  const tool=page.locator('[data-chat-kind="tool_call"]');await tool.waitFor();
  await tool.locator('summary').click();
  await event({kind:'tool_call_update',toolCallId:'tool-1',status:'failed',text:'Compiler failed\n'+('detailed diagnostic '.repeat(90))});
  assert.equal(await tool.count(),1);assert.equal(await tool.locator('details').getAttribute('open'),'');
  assert.equal(await tool.locator('[data-chat-activity-status]').innerText(),'failed');
  assert((await tool.innerText()).includes('Compiler failed'));record('one expandable stable tool result card');
  await event({kind:'diff',filePath:'stories.nim',diff:'- old\n+ new'});
  await event({kind:'plan',planEntries:['Build source','Open story']});
  await event({kind:'llm_request',model:'Reported model',hasUsage:true,inputTokens:120,outputTokens:30});
  await shot('tool-heavy');await shot('tool-heavy',240);
  await page.locator('[data-chat-kind="diff"] summary').click();
  await page.locator('[data-chat-kind="llm_request"] summary').click();
  await shot('activity-details');await shot('activity-details',240);
  await input.fill('newer in-flight draft 保持😀');await setBusy(true);
  const beforeBudget=JSON.parse(await page.evaluate(()=>window.__chatTest.state()));
  await event({kind:'status',sourceType:'editor_context_budget',
    text:'Backend quota rejected this turn before delivery. Retrying once with bounded optional context; exact user text and pending edits are retained.',
    presentationFields:[{name:'Remaining Unicode characters',value:'4260'},
      {name:'Optional context',value:'diagnostics: 1/80 records; quota truncated'}]});
  const budget=page.locator('[data-chat-kind="status"]').filter({hasText:'Backend quota rejected this turn before delivery'});
  await budget.waitFor();await budget.locator('summary').click();
  assert((await budget.innerText()).includes('4260'));
  assert((await budget.innerText()).includes('diagnostics: 1/80 records; quota truncated'));
  const afterBudget=JSON.parse(await page.evaluate(()=>window.__chatTest.state()));
  assert.deepEqual(afterBudget,beforeBudget,'Neutral safe status cannot admit or alter draft/edits/busy state');
  assert.equal(await input.inputValue(),'newer in-flight draft 保持😀');
  await shot('context-budget');await shot('context-budget',240);await setBusy(false);
  record('quota status and explicit availability render without changing admission/draft/edits');
  // Reestablish the original later error scenario's user draft through the
  // actual composer. The budget scenario's newer draft was asserted above.
  await input.fill('draft while streaming');
  await event({kind:'status',sourceType:'agent_question',question:'Which variant?',text:'Which variant?'});
  const question=page.locator('[data-chat-kind="status"]').filter({hasText:'Which variant?'});
  await question.waitFor();
  await shot('waiting');await shot('waiting',240);
  await event({kind:'error',text:'The source build failed. Your draft is preserved.'});
  await shot('error');await shot('error',240);
  for(let i=0;i<35;i++)await event({sessionId:'scroll-session',eventId:`history-${i}`,kind:'review',text:`Review item ${i}\n${'Long diagnostic '.repeat(25)}`,filePath:'stories.nim',reviewSeverity:'warning'});
  await frames();
  const latest=page.locator('[data-chat-latest]');
  if(await latest.isVisible())await latest.click();
  await frames();
  const scroll=page.locator('[data-chat-scroll]');await scroll.evaluate(el=>{el.scrollTop=20;el.dispatchEvent(new Event('scroll'));});
  await frames();
  const top=await scroll.evaluate(el=>el.scrollTop);
  assert.equal(await latest.isVisible(),false,'scrollback precondition: no unread visible output');
  await event({sessionId:'scroll-session',eventId:'input-ack',kind:'status',sourceType:'user_input',text:'Acknowledged input'});
  await frames();
  assert.equal(await page.locator('[data-chat-latest]').isVisible(),false);
  assert.equal(await scroll.evaluate(el=>el.scrollTop),top);record('typed input acknowledgement is not new visible output');
  await event({sessionId:'scroll-session',eventId:'history-34',kind:'review',text:`Review item 34\n${'Long diagnostic '.repeat(25)}`,filePath:'stories.nim',reviewSeverity:'warning'});
  await frames();
  assert.equal(await page.locator('[data-chat-latest]').isVisible(),false);
  assert.equal(await scroll.evaluate(el=>el.scrollTop),top);record('exact durable replay is not new visible output');
  await event({sessionId:'scroll-session',eventId:'actual-new-chunk',kind:'message_chunk',text:'Actual new assistant chunk'});
  await event({kind:'sub_agent',text:'A new child result arrived'});
  await page.locator('[data-chat-latest]').waitFor({state:'visible'});
  assert.equal(await scroll.evaluate(el=>el.scrollTop),top);record('scrollback stays fixed and exposes new output');
  await page.locator('[data-chat-latest]').click();
  await page.waitForFunction(()=>{const el=document.querySelector('[data-chat-scroll]');return el.scrollHeight-el.scrollTop-el.clientHeight<=24;});record('return to latest restores follow');
  await shot('long-history');await shot('long-history',240);
  for(const width of [240,420]){
    await page.evaluate(value=>window.__chatTest.width(value),width);
    const sizes=await page.evaluate(()=>{const input=document.querySelector('[aria-label="Agent prompt"]').getBoundingClientRect();const preview=Array.from(document.querySelectorAll('iframe')).map(el=>el.getBoundingClientRect()).find(rect=>rect.width>0) ?? {width:0};return{overflow:document.documentElement.scrollWidth>innerWidth,composer:input.bottom<=innerHeight&&input.width>100,preview:preview.width};});
    assert.equal(sizes.overflow,false);assert.equal(sizes.composer,true);assert(sizes.preview>300,JSON.stringify(sizes));record(`reachable composer and usable preview at sidebar ${width}`);
  }
  const second=await page.evaluate(()=>window.__chatTest.newChat());
  await page.getByRole('button',{name:'Insert suggested prompt'}).first().waitFor({state:'visible'});
  await input.fill('second chat draft');await page.evaluate(()=>window.__chatTest.switchChat('chat-1'));
  await page.waitForSelector('[data-chat-local-id="chat-1"]');
  const actualDrafts=await page.evaluate(()=>window.__chatTest.state());
  assert.equal(await input.inputValue(),'draft while streaming',actualDrafts);
  await page.getByRole('button',{name:'Insert suggested prompt'}).first().waitFor({state:'hidden'});
  assert((await page.locator('[data-chat-entry]').count())>30);
  await page.evaluate(value=>window.__chatTest.switchChat(value),second);assert.equal(await input.inputValue(),'second chat draft');record('independent tab draft and retained transcript');
  // Full current REST union, through production normalization/safe JSON/SSE
  // decoder and reducer. Deliberate event data is not a transport replacement.
  const corpus=JSON.parse(readFileSync(path.join(repo,'tests/fixtures/chat-session-events.json'),'utf8'));
  assert.equal(corpus.events.length,34);
  // Actual Rust-shaped file/status DTOs traverse parser, safe wire and the
  // production reducer/view. Provider labels must not change busy admission.
  const publicCorpus=JSON.parse(readFileSync(path.join(repo,'tests/scenarios/chat-activity/public-session-events.json'),'utf8'));
  for(const [width,panelWidth] of [[1440,420],[1024,240]]){
    const projectionPage=await browser.newPage({viewport:{width,height:768}});
    await projectionPage.goto(origin);await projectionPage.waitForFunction(()=>window.__chatTest);
    await projectionPage.evaluate(value=>window.__chatTest.width(value),panelWidth);
    await projectionPage.getByRole('textbox',{name:'Agent prompt'}).fill('Retained projection draft');
    await projectionPage.evaluate(()=>window.__chatTest.busy(true));
    const before=await projectionPage.evaluate(()=>JSON.parse(window.__chatTest.state()));
    await projectionPage.evaluate(payload=>window.__chatTest.harborEvent(JSON.stringify(payload)),publicCorpus.scenes.files[0]);
    await projectionPage.evaluate(payload=>window.__chatTest.harborEvent(JSON.stringify(payload)),publicCorpus.scenes.error[0]);
    await projectionPage.evaluate(async()=>{await document.fonts.ready;await new Promise(resolve=>requestAnimationFrame(()=>requestAnimationFrame(resolve)));});
    const file=projectionPage.locator('[data-chat-source="file_edit"]');
    const description=file.locator('[data-chat-markdown="paragraph"]');
    assert.equal(await description.innerText(),'Use shared spacing and preserve the title.');
    assert(await description.isVisible());assert.equal(await description.locator('xpath=ancestor::details').count(),0);
    assert.equal(await file.locator('details').getAttribute('open'),null);
    assert((await file.locator('[data-chat-fact="File"]').innerText()).includes('stories/hero.nim'));
    assert((await file.locator('[data-chat-fact="Changes"]').innerText()).includes('+4 / −2 lines'));
    const session=projectionPage.locator('[data-chat-source="status"]');
    assert.equal(await session.locator('[data-chat-activity-status]').innerText(),'running');
    const badge=session.locator('[data-chat-activity-status]');assert(await badge.isVisible());
    for(const content of [description,badge]){
      const bounds=await content.evaluate(el=>{
        const b=el.getBoundingClientRect(),s=el.closest('[data-chat-scroll]').getBoundingClientRect();
        return {inside:b.width>0&&b.height>0&&b.left>=s.left&&b.right<=s.right&&b.top>=s.top&&b.bottom<=s.bottom,
          box:{left:b.left,right:b.right,top:b.top,bottom:b.bottom},scroll:{left:s.left,right:s.right,top:s.top,bottom:s.bottom}};
      });assert(bounds.inside,JSON.stringify(bounds));
    }
    await horizontalChatGuard(projectionPage);
    const after=await projectionPage.evaluate(()=>JSON.parse(window.__chatTest.state()));
    assert.equal(after.busy,before.busy);assert.equal(after.admitted,before.admitted);
    assert.equal(after.connection,'streaming');assert.equal(after.sessionStatus,'asLoading');
    assert.equal(after.pendingEdits.length,before.pendingEdits.length+1);
    assert.equal(await projectionPage.getByRole('button',{name:'Send agent prompt'}).getAttribute('aria-disabled'),'true');
    assert.equal(await projectionPage.getByRole('textbox',{name:'Agent prompt'}).inputValue(),'Retained projection draft');
    const beforeHeartbeat=await session.count();
    await projectionPage.evaluate(payload=>window.__chatTest.harborEvent(JSON.stringify(payload)),publicCorpus.scenes.error[0]);
    assert.equal(await session.count(),beforeHeartbeat);
    await projectionPage.close();record(`safe file description and reported running status preserve admission at ${panelWidth}`);
  }
  // Public lifecycle reports describe the agent; the admitted reply remains
  // open until its host acknowledges completion. The footer must explain both.
  for(const [width,panelWidth] of [[1440,420],[1024,240]]){
    const statusPage=await browser.newPage({viewport:{width,height:768}});
    await statusPage.goto(origin);await statusPage.waitForFunction(()=>window.__chatTest);
    await statusPage.evaluate(value=>window.__chatTest.width(value),panelWidth);
    const status=statusPage.locator('[data-chat-session-status]');
    const summary=statusPage.locator('[data-chat-session-summary]');
    assert.equal(await summary.evaluate(el=>el.getBoundingClientRect().right<0),true);
    assert.equal(await summary.textContent(),'Start a conversation');
    assert.equal(await status.isVisible(),true);
    assert.equal(await status.innerText(),'Start a conversation');
    const draft=statusPage.getByRole('textbox',{name:'Agent prompt'});
    await draft.fill('Retained status draft');
    await statusPage.evaluate(()=>window.__chatTest.busy(true));
    const before=JSON.parse(await statusPage.evaluate(()=>window.__chatTest.state()));
    const feed=async payload=>statusPage.evaluate(value=>window.__chatTest.harborEvent(JSON.stringify(value)),payload);
    assert.equal(await status.innerText(),'Working');
    await feed(publicCorpus.scenes.question[0]);
    assert.equal(await status.innerText(),'Waiting for input\nReply still open');
    await feed(publicCorpus.scenes.login[0]);await feed(publicCorpus.scenes.login[1]);
    assert.equal(await status.innerText(),'Sign-in required\nReply still open');
    await feed({type:'log',level:'info',message:'Resumed authoring',eventId:'footer-output-1'});
    assert.equal(await status.innerText(),'Working');
    await feed({type:'log',level:'info',message:' with continued output',eventId:'footer-output-2'});
    assert.equal(await status.innerText(),'Working');
    assert.equal(await statusPage.locator('[data-chat-role="arAssistant"]').last().locator('[data-chat-markdown="paragraph"]').innerText(),'Resumed authoring with continued output');
    await feed(publicCorpus.scenes.question[0]);
    assert.equal(await status.innerText(),'Waiting for input\nReply still open');
    await feed(publicCorpus.scenes.lifecycle[2]);assert.equal(await status.innerText(),'Working');
    const ended={...publicCorpus.scenes.lifecycle[3],eventId:'footer-end'};
    await feed(ended);assert.equal(await status.innerText(),'Agent reported completion\nReply still open');
    await feed(ended);assert.equal(await status.innerText(),'Agent reported completion\nReply still open');
    assert.equal(await summary.textContent(),await status.textContent());
    const bounds=await status.evaluate(el=>{const a=el.getBoundingClientRect(),b=el.closest('.editor-chat').getBoundingClientRect();return {visible:a.x>=b.x&&a.y>=b.y&&a.right<=b.right&&a.bottom<=b.bottom,clientWidth:el.clientWidth,scrollWidth:el.scrollWidth};});
    assert(bounds.visible,JSON.stringify(bounds));assert(bounds.scrollWidth<=bounds.clientWidth,JSON.stringify(bounds));
    const after=JSON.parse(await statusPage.evaluate(()=>window.__chatTest.state()));
    for(const key of ['busy','admitted','connection','sessionStatus'])assert.equal(after[key],before[key],key);
    assert.equal(await statusPage.getByRole('button',{name:'Send agent prompt'}).getAttribute('aria-disabled'),'true');
    assert.equal(await draft.inputValue(),'Retained status draft');
    await statusPage.evaluate(()=>window.__chatTest.newChat());
    assert.equal(await statusPage.locator('[data-chat-session-status]').innerText(),'Start a conversation');
    await statusPage.evaluate(()=>window.__chatTest.switchChat('chat-1'));
    assert.equal(await statusPage.locator('[data-chat-session-status]').innerText(),'Agent reported completion\nReply still open');
    assert.equal(await statusPage.getByRole('textbox',{name:'Agent prompt'}).inputValue(),'Retained status draft');
    await statusPage.evaluate(()=>window.__chatTest.event(JSON.stringify({kind:'completed'})));
    assert.equal(await statusPage.locator('[data-chat-session-status]').innerText(),'Finishing reply');
    assert.equal(JSON.parse(await statusPage.evaluate(()=>window.__chatTest.state())).busy,true);
    await statusPage.evaluate(()=>window.__chatTest.busy(false));
    assert.equal(await statusPage.locator('[data-chat-session-status]').innerText(),'Ready for next message');
    await statusPage.evaluate(()=>window.__chatTest.event(JSON.stringify({kind:'error',text:'Connection lost'})));
    assert.equal(await statusPage.locator('[data-chat-session-status]').innerText(),'Reply failed');
    await statusPage.evaluate(()=>window.__chatTest.event(JSON.stringify({kind:'cancelled'})));
    assert.equal(await statusPage.locator('[data-chat-session-status]').innerText(),'Reply stopped');
    await horizontalChatGuard(statusPage);
    await statusPage.close();record(`current agent condition and open reply remain distinct at ${panelWidth}`);
  }
  // A waiting-only DTO has no correlated response operation in this editor.
  // Preserve the active reply's admission and draft while exposing that fact.
  for(const [width,panelWidth] of [[1440,420],[1024,240]]){
    const waitingPage=await browser.newPage({viewport:{width,height:768}});
    await waitingPage.goto(origin);await mountedReady(waitingPage,`waiting-only-${panelWidth}`);
    await waitingPage.evaluate(value=>window.__chatTest.width(value),panelWidth);
    const draft=waitingPage.getByRole('textbox',{name:'Agent prompt'});
    await draft.fill('Retained waiting draft');
    await waitingPage.evaluate(()=>window.__chatTest.busy(true));
    const before=JSON.parse(await waitingPage.evaluate(()=>window.__chatTest.state()));
    const payload=publicCorpus.scenes.login[1];assert.equal(payload.type,'session_awaiting_input');
    await waitingPage.evaluate(value=>window.__chatTest.harborEvent(JSON.stringify(value)),payload);
    await waitingPage.evaluate(async()=>{await document.fonts.ready;await new Promise(resolve=>requestAnimationFrame(()=>requestAnimationFrame(resolve)));});
    const row=waitingPage.locator('[data-chat-entry][data-chat-source="session_awaiting_input"]');
    assert.equal(await row.count(),1);
    assert.equal(await row.getByText('Waiting for input',{exact:true}).innerText(),'Waiting for input');
    assert((await row.locator('[data-chat-fact="Request"]').innerText()).includes(payload.request));
    const notice=row.locator('[data-chat-availability]');
    assert.equal(await notice.innerText(),'Waiting for input. This editor cannot respond to this request.');
    assert(await notice.isVisible());assert.equal(await row.locator('details').getAttribute('open'),null);
    assert(await notice.evaluate(el=>el.parentElement.hasAttribute('data-chat-entry')));
    const bounds=await notice.evaluate(el=>{
      const box=el.getBoundingClientRect(),scroll=el.closest('[data-chat-scroll]').getBoundingClientRect();
      return {inside:box.width>0&&box.height>0&&box.left>=scroll.left&&box.right<=scroll.right&&box.top>=scroll.top&&box.bottom<=scroll.bottom,
        box:{left:box.left,right:box.right,top:box.top,bottom:box.bottom}};
    });
    assert(bounds.inside,JSON.stringify(bounds));await horizontalChatGuard(waitingPage);
    assert.equal(await row.locator('button,input,textarea,select,a').count(),0);
    assert.equal(await waitingPage.getByRole('button',{name:'Send agent prompt'}).getAttribute('aria-disabled'),'true');
    assert.equal(await waitingPage.locator('[data-chat-session-status]').innerText(),'Waiting for input\nReply still open');
    await row.locator('summary').click();
    assert.notEqual(await row.locator('details').getAttribute('open'),null);
    assert((await row.locator('details').innerText()).includes(payload.request));
    assert.equal(await draft.inputValue(),'Retained waiting draft');
    const after=JSON.parse(await waitingPage.evaluate(()=>window.__chatTest.state()));
    assert.deepEqual(after,before);
    await waitingPage.close();record(`truthful waiting-only notice preserves admission and draft at ${panelWidth}`);
  }
  // Provider-supported recovery is readable with Details closed, at both real
  // mounted rail widths. No invented login action or credential input is offered.
  for(const [width,panelWidth] of [[1440,420],[1024,240]]){
    const loginPage=await browser.newPage({viewport:{width,height:768}});
    await loginPage.goto(origin);await loginPage.waitForFunction(()=>window.__chatTest);
    await loginPage.evaluate(value=>window.__chatTest.width(value),panelWidth);
    await loginPage.getByRole('textbox',{name:'Agent prompt'}).fill('Retained login draft');
    const loginPayload=corpus.events.find(event=>event.type==='login_required');assert(loginPayload);
    await loginPage.evaluate(payload=>window.__chatTest.harborEvent(JSON.stringify(payload)),loginPayload);
    await loginPage.evaluate(async()=>{await document.fonts.ready;await new Promise(resolve=>requestAnimationFrame(()=>requestAnimationFrame(resolve)));});
    const row=loginPage.locator('[data-chat-entry]').filter({hasText:'Provider login required'});
    const notice=row.locator('[data-chat-availability]');
    assert((await row.locator('[data-chat-fact="Request"]').innerText()).includes(loginPayload.request));
    assert((await row.locator('[data-chat-facts]').innerText()).includes(loginPayload.provider));
    assert((await notice.innerText()).includes("Sign in through the provider's supported login surface."));
    assert(await notice.isVisible());assert.equal(await row.locator('details').getAttribute('open'),null);
    const bounds=await notice.evaluate(el=>{
      const box=el.getBoundingClientRect(),scroll=el.closest('[data-chat-scroll]').getBoundingClientRect();
      return {inside:box.width>0&&box.height>0&&box.left>=scroll.left&&box.right<=scroll.right&&box.top>=scroll.top&&box.bottom<=scroll.bottom,box:{left:box.left,right:box.right,top:box.top,bottom:box.bottom}};
    });
    assert(bounds.inside,JSON.stringify(bounds));await horizontalChatGuard(loginPage);
    assert.equal(await row.locator('button,input,textarea,select,a').count(),0);
    assert.equal(await loginPage.getByRole('textbox',{name:'Agent prompt'}).inputValue(),'Retained login draft');
    await loginPage.close();record(`visible supported login guidance and whole notice bounds at ${panelWidth}`);
  }
  await page.evaluate(()=>window.__chatTest.newChat());
  for(const payload of corpus.events){
    await page.evaluate(payload=>window.__chatTest.harborEvent(JSON.stringify(payload)),payload);
  }
  assert.equal(await page.locator('[data-chat-role="arUser"]').count(),0);
  assert.equal(await page.locator('.editor-chat').getByText('Activity',{exact:true}).count(),0);
  assert((await page.locator('.editor-chat').innerText()).includes('Provider login required'));
  assert((await page.locator('.editor-chat').innerText()).includes('Agent question'));
  assert.equal((await page.locator('.editor-chat').textContent()).includes('PRIVATE_DO_NOT_RENDER'),false);
  record('full REST union safe purposeful presentation');
  assert.deepEqual(errors,[]);record('no browser runtime errors');
  writeFileSync(path.join(artifacts,'results.json'),JSON.stringify({passed:count,artifacts,views:['empty','streaming','tool-heavy','activity-details','waiting','error','long-history'],widths:[240,420],captureEvidence},null,2));
  process.stdout.write(`ARTIFACTS ${artifacts}\n`);
}finally{if(browser)await browser.close();server.kill('SIGTERM');}
