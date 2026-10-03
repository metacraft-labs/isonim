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
 * Geometry checks wait for font layout and two browser animation frames because
 * the real chat view follows output in requestAnimationFrame. This observes its
 * scheduled scroll; it does not scroll, focus, modify DOM or relax visible bounds.
 * Assert stable turn/tool nodes, unsafe text, IME, drafts/tabs, focus/selection, scrollback,
 * narrow/wide overflow and composer/preview reachability; capture named states.
 */
import assert from 'node:assert/strict';
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
  await controlPage.getByRole('checkbox',{name:'Approve agent navigation'}).check();
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
    await previewPage.getByRole('checkbox',{name:'Approve agent navigation'}).uncheck();
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
