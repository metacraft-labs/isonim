/** Production mounted editor campaign. Synthetic DTO corpus substitutes external
 * transport timing only; actual normalization/reducer/VM/view/DOM are unchanged.
 * Real Rust mock REST scenarios are separately required, never claimed here.
 * Local control-host fixture substitutes connected transport timing only; real
 * admission/approval and production DOM adapters remain installed. Initial control
 * admission requires complete visible preview/documents, loaded fonts, actual DOM
 * targets in the production published scene graph (300ms/700ms scanner), then two
 * normal frames. No revision polling/rebasing, forced result or mutation retry.
 * Read-only stored-operation diagnostics persist before assertions.
 * Run inside the pinned capture container via chat-visual-campaign.py.
 */
import assert from 'node:assert/strict';
import {horizontalChatGuard,oldClippedChatControl} from './chat-horizontal-guard.mjs';
import {execFileSync} from 'node:child_process';
import {createServer} from 'node:http';
import {readFileSync,writeFileSync,mkdirSync,readdirSync,rmSync,existsSync} from 'node:fs';
import {createHash} from 'node:crypto';
import path from 'node:path';
import {chromium} from '../node_modules/playwright/index.mjs';
const args=process.argv.slice(2);const option=(name,fallback)=>args.includes(name)?args[args.indexOf(name)+1]:fallback;
const output=option('--output','/captures'); const filter=option('--view','');const sizeFilter=option('--size','');
const hash=buffer=>createHash('sha256').update(buffer).digest('hex');
const corpus=JSON.parse(readFileSync(new URL('../tests/scenarios/chat-activity/public-session-events.json',import.meta.url)));
const thresholds=JSON.parse(readFileSync(new URL('./chat-visual-thresholds.json',import.meta.url)));
const sizes={wide:{width:1440,height:900,panel:420},narrow:{width:1024,height:768,panel:240}};
const singleEvents=Object.fromEntries(Object.values(corpus.scenes).flat().map(event=>['event-'+event.type,[event]]));
singleEvents['event-agent_question']=[corpus.scenes.question[0]];
const sceneEvents={...corpus.scenes,...singleEvents,...corpus.normalizedScenes,"event-log-bottom":singleEvents["event-log"]};
const allViews=['empty',...Object.keys(sceneEvents),...Object.keys(corpus.behaviorScenes)];
const lineage={bundleSha256:hash(readFileSync(new URL('../build/editor-chat/editor.js',import.meta.url))),sceneSha256:hash(readFileSync(new URL('../tests/scenarios/chat-activity/public-session-events.json',import.meta.url))),captureSha256:hash(readFileSync(new URL(import.meta.url))),browserExecutableSha256:hash(readFileSync('/ms-playwright/chromium-1217/chrome-linux64/chrome')),fonts:[...new Set(execFileSync('fc-list',['--format','%{file}\n'],{encoding:'utf8'}).trim().split('\n'))].sort().map(file=>({file,sha256:hash(readFileSync(file))}))};
const flags=['--no-sandbox','--disable-gpu','--force-color-profile=srgb','--font-render-hinting=none','--disable-lcd-text'];
const environment={deviceScaleFactor:1,locale:'en-US',timezoneId:'UTC',colorScheme:'dark',reducedMotion:'reduce'};
lineage.horizontalGuardSha256=hash(readFileSync(new URL('./chat-horizontal-guard.mjs',import.meta.url)));
lineage.expectedSha256=hash(readFileSync(new URL('./chat-visual-expected.json',import.meta.url)));
lineage.thresholdsSha256=hash(readFileSync(new URL('./chat-visual-thresholds.json',import.meta.url)));
const expected=JSON.parse(readFileSync(new URL('./chat-visual-expected.json',import.meta.url)));
assert.deepEqual(Object.keys(expected).sort(),allViews.slice().sort(),'exact expected view inventory');
assert.deepEqual(Object.keys(thresholds).sort(),allViews.slice().sort(),'exact threshold view inventory');
lineage.mountedAssets=['editor.js','index.html','fabric.min.js','paper-core.min.js','svgo.browser.js'].map(file=>({file,sha256:hash(readFileSync(new URL('../build/editor-chat/'+file,import.meta.url)))}));
const canary=args.includes('--canary');const views=filter?[filter]:canary?['conversation','plan']:allViews;
for(const name of views)assert(allViews.includes(name),`unknown view ${name}`);
for(const name of sizeFilter?[sizeFilter]:Object.keys(sizes))assert(sizes[name],`unknown viewport ${name}`);
mkdirSync(output,{recursive:true});
const targeted=Boolean(filter||sizeFilter);
let previous=null;
if(targeted){
 assert(existsSync(path.join(output,'manifest.json')),'targeted capture requires full current corpus');
 previous=JSON.parse(readFileSync(path.join(output,'manifest.json')));
 assert.equal(previous.schema,2,'full regeneration required for old manifest');
 assert.deepEqual(previous.lineage,lineage,'changed capture closure requires full regeneration');
 assert.equal(previous.container,'mcr.microsoft.com/playwright@sha256:eac9b0a5312cdab40ee8c2429df5bf19bffdccf8f3bf3c42268e173f97541645');
 assert.equal(previous.browser,'147.0.7727.15');assert.equal(previous.node,process.version);
 assert.deepEqual(previous.flags,flags);assert.deepEqual(previous.environment,environment);assert.deepEqual(previous.sizes,sizes);
 const keys=new Set();for(const row of previous.views){
  const key=row.view+'/'+row.size;assert(allViews.includes(row.view)&&sizes[row.size]&&!keys.has(key),'unknown/duplicate prior key');keys.add(key);
  assert.equal(row.file,`${row.view}-${row.size}.png`);const png=readFileSync(path.join(output,row.file));assert.equal(hash(png),row.sha256,'prior PNG altered');
  assert.equal(png.subarray(0,8).toString('hex'),'89504e470d0a1a0a');
  assert.deepEqual(row.dimensions,[sizes[row.size].width,sizes[row.size].height]);assert.deepEqual(row.dimensions,[png.readUInt32BE(16),png.readUInt32BE(20)]);
  assert.equal(row.scope,'full editor viewport');assert.equal(row.browser,previous.browser);assert.deepEqual(row.perceptualThreshold,{maximumChangedPixelRatio:thresholds[row.view]});
 }
 assert.equal(keys.size,allViews.length*2,'missing prior views');
}else for(const name of readdirSync(output))if(name.endsWith('.png')||['manifest.json','review.html','findings-ledger.json','perceptual-gates.json','missing-element-control.json'].includes(name))rmSync(path.join(output,name));
async function composerGuard(page,viewport){
 const input=page.getByRole('textbox',{name:'Agent prompt'});
 assert.equal(await input.count(),1,'required composer missing');assert(await input.isVisible(),'composer visible');
 const box=await input.boundingBox();assert(box&&box.y>=0&&box.y+box.height<=viewport.height,'anchored composer');
 await horizontalChatGuard(page);
 return input;
}
async function controlReady(page,view,size){
 await page.waitForFunction(()=>{
   if(!window.__chatTest || document.readyState!=='complete' || document.fonts.status!=='loaded')return false;
   const frames=Array.from(document.querySelectorAll('iframe[data-page-project-frame="true"]'))
     .filter(frame=>frame.getClientRects().length && frame.offsetParent!==null);
   if(frames.length!==1)return false;
   const doc=frames[0].contentDocument;
   if(!doc || doc.readyState!=='complete' || doc.fonts.status!=='loaded')return false;
   const state=JSON.parse(window.__chatTest.controlState());
   return ['primary','secondary'].every(id=>doc.querySelector(`[data-isonim-element-id="${id}"]`) && state.elements.some(row=>row.id===id));
 },null,{timeout:5000});
 const readiness=await page.evaluate(async()=>{
   const frameTimes=await new Promise(resolve=>requestAnimationFrame(first=>requestAnimationFrame(second=>resolve([first,second]))));
   const frame=Array.from(document.querySelectorAll('iframe[data-page-project-frame="true"]')).find(frame=>frame.getClientRects().length && frame.offsetParent!==null);
   return {frameTimes,documentReadyState:document.readyState,fontStatus:document.fonts.status,
     previewReadyState:frame.contentDocument.readyState,previewFontStatus:frame.contentDocument.fonts.status,
     state:JSON.parse(window.__chatTest.controlState())};
 });
 writeFileSync(path.join(output,`control-${view}-${size}-readiness.json`),JSON.stringify(readiness,null,2));
 return readiness;
}
async function controlDiagnostic(page,id,size,phase){
 const actual=JSON.parse(await page.evaluate(id=>window.__chatTest.controlDiagnostics(id),id));
 actual.phase=phase;
 writeFileSync(path.join(output,`control-${id}-${size}-${phase}.json`),JSON.stringify(actual,null,2));
 return actual;
}
async function behavioralScene(page,view,size){
 const input=page.getByRole('textbox',{name:'Agent prompt'});
 const panel=page.locator('.editor-chat');
 const inject=payload=>page.evaluate(value=>window.__chatTest.event(JSON.stringify(value)),payload);
 const state=async()=>JSON.parse(await page.evaluate(()=>window.__chatTest.controlState()));
 const command=payload=>page.evaluate(value=>JSON.parse(window.__chatTest.control(JSON.stringify(value))),payload);
 const settle=async()=>page.evaluate(()=>new Promise(resolve=>requestAnimationFrame(()=>requestAnimationFrame(resolve))));
 await page.evaluate(()=>window.__chatTest.localApprovals(true));
 if(view.startsWith('navigation-')||['focus-auto','selection-highlight-auto','highlight-auto'].includes(view)){
   await input.focus();await settle();
   const approval=page.getByRole('checkbox',{name:'Approve agent navigation'});
   if(view!=='navigation-auto'&&view.startsWith('navigation-'))await approval.check();else await approval.uncheck();
   const readiness=await controlReady(page,view,size);
   const initial=await state();
   let request={commandId:view,command:'open-story',storyId:initial.stories.find(row=>row.name==='Details').id};
   if(view==='focus-auto')request={commandId:view,command:'focus',target:'sidebar-search'};
   if(['selection-highlight-auto','highlight-auto'].includes(view)){
     await page.waitForFunction(()=>JSON.parse(window.__chatTest.controlState()).elements.some(row=>row.id==='primary'));
     request={commandId:view,command:view==='highlight-auto'?'highlight':'select',target:view==='highlight-auto'?'secondary':'primary',focus:view!=='highlight-auto',highlight:true};
   }
   const admitted=await command(request);
   const admittedDiagnostic=await controlDiagnostic(page,view,size,'admitted');
   assert.deepEqual(admittedDiagnostic.operation,admitted,'stored actual admission');
   assert.equal(admitted.status,view.startsWith('navigation-')&&view!=='navigation-auto'?'pending':'applied','actual command admission '+JSON.stringify(admittedDiagnostic));
   const beforeClick=await controlDiagnostic(page,view,size,'before-click');
   if(view==='navigation-approved')await page.locator(`[data-editor-control-approve="${view}"]`).click();
   if(view==='navigation-rejected')await page.locator(`[data-editor-control-reject="${view}"]`).click();
   if(view==='navigation-stale'){
      assert.equal((await command({commandId:'human-viewport-change',command:'viewport',viewport:'tablet',expectedRevision:(await state()).revision})).status,'pending');
      await page.locator('[data-editor-control-approve="human-viewport-change"]').click();
      await page.locator(`[data-editor-control-approve="${view}"]`).click();
   }
   const afterClick=await controlDiagnostic(page,view,size,'after-click');
   const expectedStatus=view==='navigation-pending'?'pending':view==='navigation-rejected'?'rejected':view==='navigation-stale'?'failed':'applied';
   const row=panel.locator(`[data-editor-control-operation="${view}"]`);await row.waitFor();
   assert.equal(await row.getAttribute('data-operation-status'),expectedStatus,'rendered shared command result '+JSON.stringify({readiness,admitted,beforeClick,afterClick}));
   assert.equal(await row.locator('button').count(),expectedStatus==='pending'?2:0,'only live approval controls');
   const final=await state();
   if(view.startsWith('navigation-'))assert.equal(final.storyId,initial.stories.find(row=>row.name===(['navigation-approved','navigation-auto'].includes(view)?'Details':'Home')).id,'actual selected story');
   if(view==='focus-auto')assert(await page.locator('.editor-sidebar input').evaluate(el=>document.activeElement===el),'actual sidebar focus');
   if(['selection-highlight-auto','highlight-auto'].includes(view)){
      // The shell retains hidden preview documents. Identify the visible production
      // page iframe first, then use its associated frame, never frame URL order.
      const preview=page.locator('iframe[data-page-project-frame="true"]:visible');
      assert.equal(await preview.count(),1,'one visible mounted page preview');
      const previewElement=await preview.elementHandle();
      const frame=await previewElement.contentFrame();assert(frame,'actual visible preview document');
      const target=frame.locator(`[data-isonim-element-id="${request.target}"]`);
      assert.equal(await target.getAttribute('data-editor-agent-highlight'),'true','actual preview highlight');
      if(view==='selection-highlight-auto'){
        assert(await target.evaluate(el=>el.ownerDocument.activeElement===el),'actual preview element focus');
        assert.equal(final.selection,'primary','actual selection');
      }else assert.equal(final.selection,initial.selection,'highlight preserves selection');
   }
   return {admission:admitted.status,status:expectedStatus,selectedStory:final.storyId,focus:final.focus,selectedElement:final.selection,highlight:final.highlight};
 }
 await page.evaluate(value=>window.__chatTest.backend(value),view!=='chat-send-failed');
 const send=async(text)=>{await input.fill(text);await page.getByRole('button',{name:'Send agent prompt',exact:true}).click();};
 if(view==='chat-send-failed'){
   await send('Retry this website request.');assert.equal(await input.inputValue(),'Retry this website request.');
   assert.equal(await panel.getByRole('button',{name:'Insert suggested prompt'}).count(),0);return {draftPreserved:true,suggestionsDismissed:true};
 }
 await send('Improve the hero spacing.');
 assert.equal(await panel.locator('[data-chat-role="arUser"]').count(),1);
 assert.equal(await panel.getByRole('button',{name:'Insert suggested prompt'}).count(),0);
 if(view==='chat-first-send')return {actualUserCount:1,suggestionsDismissed:true};
 if(view.startsWith('chat-independent-')){
   await inject({kind:'message_chunk',text:'First conversation website update.'});
   await input.fill('First conversation draft.');
   const second=await page.evaluate(()=>window.__chatTest.newChat());await input.fill('Second conversation draft.');
   if(view==='chat-independent-first'){
     await page.evaluate(()=>window.__chatTest.switchChat('chat-1'));
     assert.equal(await input.inputValue(),'First conversation draft.');assert.equal(await panel.locator('[data-chat-role="arUser"]').count(),1);
     assert.equal(await panel.getByRole('button',{name:'Insert suggested prompt'}).count(),0);
   }else{
     assert.equal(await input.inputValue(),'Second conversation draft.');assert.equal(await panel.locator('[data-chat-entry]').count(),0);
     assert(await panel.getByRole('button',{name:'Insert suggested prompt'}).first().isVisible());
   }
   return {active:(JSON.parse(await page.evaluate(()=>window.__chatTest.state()))).active,second,draftsRetained:true};
 }
 await page.evaluate(()=>window.__chatTest.busy(true));await input.fill('Next website change.');
 if(view.startsWith('chat-scroll-')){
   for(let index=0;index<26;index++){
      await inject({kind:'message_chunk',text:`# History ${index}\nWebsite activity ${index}.`});await inject({kind:'completed',stopReason:'end_turn'});
   }
   const scroll=panel.locator('[data-chat-scroll]');await scroll.evaluate(el=>{el.scrollTop=0;el.dispatchEvent(new Event('scroll'));});await settle();
   const before=await scroll.evaluate(el=>el.scrollTop);
   await inject({kind:'message_chunk',text:'# Newest website activity\nPreview compilation finished.'});await settle();
   assert.equal(await scroll.evaluate(el=>el.scrollTop),before,'scrollback retained');
   await panel.locator('[data-chat-latest]').waitFor({state:'visible'});
   if(view==='chat-scroll-latest'){
      await panel.locator('[data-chat-latest]').click();await settle();
      assert.equal(await panel.locator('[data-chat-latest]').isVisible(),false);
      assert(await panel.getByText('Newest website activity',{exact:true}).isVisible());
      assert(await scroll.evaluate(el=>el.scrollTop+el.clientHeight>=el.scrollHeight-2),'latest scroll position');
   }
   assert.equal(await input.inputValue(),'Next website change.');return {scrollbackRetained:true,latest:view==='chat-scroll-latest',draftRetained:true};
 }
 await inject({kind:'message_chunk',text:'# Website update\nThe hero remains spacious.'});
 if(view==='chat-selection-streaming'){
   const heading=panel.locator('[data-chat-markdown="heading"]');
   await heading.evaluate(el=>{const range=document.createRange();range.selectNodeContents(el);const selection=window.getSelection();selection.removeAllRanges();selection.addRange(range);});
   const selected=await page.evaluate(()=>getSelection().toString());assert.equal(selected,'Website update');
   await inject({kind:'message_chunk',text:'\nStreaming continuation preserves the selected text.'});assert.equal(await page.evaluate(()=>getSelection().toString()),selected);
   return {selectedText:selected,selectionRetained:true};
 }
 assert.equal(await page.getByRole('button',{name:'Send agent prompt',exact:true}).isDisabled(),true);
 assert.equal(await input.inputValue(),'Next website change.');return {draftRetained:true,busySendDisabled:true};
}
const root=path.resolve(path.dirname(new URL(import.meta.url).pathname),'../build/editor-chat');
const server=createServer((req,res)=>{
 const target=path.resolve(root,'.'+decodeURIComponent(req.url.split('?')[0]==='/'?'/index.html':req.url.split('?')[0]));
 if(!target.startsWith(root+path.sep)||!existsSync(target)){res.writeHead(404);res.end();return;}
 res.setHeader('Content-Type',target.endsWith('.js')?'application/javascript':target.endsWith('.css')?'text/css':'text/html');res.end(readFileSync(target));
});await new Promise(resolve=>server.listen(0,'127.0.0.1',resolve));
let browser;const manifest=[];
try{
 browser=await chromium.launch({headless:true,executablePath:'/ms-playwright/chromium-1217/chrome-linux64/chrome',args:flags});
 for(const view of views)for(const size of sizeFilter?[sizeFilter]:Object.keys(sizes)){
  const viewport=sizes[size];const context=await browser.newContext({viewport:{width:viewport.width,height:viewport.height},...environment});
  const page=await context.newPage();const errors=[];page.on('pageerror',error=>errors.push(error.message));
  await page.goto(`http://127.0.0.1:${server.address().port}/`);await page.waitForFunction(()=>window.__chatTest);
  // Capture discrete focus states, not the wall-clock phase of focus transitions.
  // No content, state, selection, outlines or controls are hidden.
  await page.addStyleTag({content:'*,*::before,*::after { transition-duration: 0s !important; animation-duration: 0s !important; }'});
  await page.evaluate(panel=>window.__chatTest.width(panel),viewport.panel);
  let behaviorEvidence=null;
  if(corpus.behaviorScenes[view])behaviorEvidence=await behavioralScene(page,view,size);
  else if(view!=='empty'){
   await page.evaluate(()=>window.__chatTest.backend(true));
   await page.getByRole('textbox',{name:'Agent prompt'}).fill('Improve the hero spacing.');
   await page.getByRole('button',{name:'Send agent prompt',exact:true}).click();
   for(const event of sceneEvents[view])await page.evaluate(payload=>payload.type?window.__chatTest.harborEvent(JSON.stringify(payload)):window.__chatTest.event(JSON.stringify(payload)),event);
  }
  await page.evaluate(async()=>{await document.fonts.ready;await new Promise(resolve=>requestAnimationFrame(()=>requestAnimationFrame(resolve)));});
  const panel=page.locator('.editor-chat');await panel.waitFor({state:'visible'});
  const input=await composerGuard(page,viewport);
  if(view==='empty'&&size==='narrow'){
   const restored=await oldClippedChatControl(page);
   writeFileSync(path.join(output,'horizontal-clipping-control.json'),JSON.stringify({oldClippedStateRejected:true,guard:'horizontalChatGuard used by every composerGuard',restored},null,2));
  }
  const layout=await panel.evaluate(el=>{
   const box=el.getBoundingClientRect();const composer=el.querySelector('textarea').getBoundingClientRect();
   const overflow=[...el.querySelectorAll('[data-chat-entry], [data-chat-facts], [data-chat-markdown]')].filter(node=>node.scrollWidth>node.clientWidth+1).map(node=>node.getAttribute('data-chat-entry')||node.getAttribute('data-chat-markdown'));
   return {width:box.width,composer:{top:composer.top,bottom:composer.bottom,left:composer.left,right:composer.right},overflow,visibleEntries:[...el.querySelectorAll('[data-chat-entry]')].length};
  });
  assert.equal(layout.overflow.length,0,`horizontal overflow ${view}/${size}: ${layout.overflow}`);
  assert(layout.composer.bottom<=viewport.height&&layout.composer.top>=0,'anchored composer');
  assert.equal(errors.length,0,`browser exceptions ${errors}`);
  const geometry=await page.evaluate(()=>{
    const iframe=[...document.querySelectorAll('iframe')].find(el=>el.getBoundingClientRect().width>0);
    return {pageOverflow:document.documentElement.scrollWidth>innerWidth,previewWidth:iframe?.getBoundingClientRect().width||0};
  });
  assert.equal(geometry.pageOverflow,false,'no horizontal page overflow');
  assert(geometry.previewWidth>300,'website preview retains usable working space');
  const contrast=await panel.evaluate(el=>{
    const rgb=value=>{const match=value.match(/rgba?\(([^)]+)\)/);return match?match[1].split(',').map(Number):null;};
    const luminance=color=>{const values=color.slice(0,3).map(value=>{const x=value/255;return x<=0.04045?x/12.92:((x+0.055)/1.055)**2.4;});return values[0]*.2126+values[1]*.7152+values[2]*.0722;};
    const rows=[];
    for(const node of el.querySelectorAll('[data-chat-entry] *')){
      if(![...node.childNodes].some(child=>child.nodeType===3&&child.textContent.trim())||!node.getClientRects().length)continue;
      let bg=node,background=null;
      while(bg){const value=rgb(getComputedStyle(bg).backgroundColor);if(value&&(value.length<4||value[3]===1)){background=value;break;}bg=bg.parentElement;}
      const foreground=rgb(getComputedStyle(node).color);if(!foreground||!background)continue;
      const a=luminance(foreground),b=luminance(background);rows.push({text:node.textContent.slice(0,60),ratio:(Math.max(a,b)+.05)/(Math.min(a,b)+.05)});
    }
    return rows;
  });
  assert(contrast.every(row=>row.ratio>=4.5),`chat text contrast ${JSON.stringify(contrast.filter(row=>row.ratio<4.5))}`);
  assert(!await panel.innerText().then(text=>text.includes('PRIVATE_CAMPAIGN_SECRET')),'credentials excluded');
  if(view==='plan')assert.equal(await panel.locator('[data-chat-surface="plan"] [data-chat-fact]').count(),3);
  if(view==='model-context')assert(await panel.getByText('1260',{exact:true}).isVisible(),'actual token usage');
  if(view==='question')assert(await panel.getByText('Which hero spacing should I use?',{exact:true}).isVisible(),'question shown');
  if(view==='files')assert(await panel.getByText('Before',{exact:true}).isVisible(),'visible before/after diff');
  // Keyboard reachability uses the actual composer and native focus styling.
  await page.mouse.move(0,0);
  const preserveFocus=['focus-auto','selection-highlight-auto','chat-selection-streaming'].includes(view);
  if(!preserveFocus){await input.focus();assert(await input.evaluate(el=>document.activeElement===el),'composer keyboard focus');}
  await page.evaluate(()=>new Promise(resolve=>requestAnimationFrame(()=>requestAnimationFrame(resolve))));
  if(view.startsWith('event-')){
    const bottom=view==='event-log-bottom';
    await panel.locator('[data-chat-scroll]').evaluate((el,bottom)=>{el.scrollTop=bottom?el.scrollHeight:0;},bottom);
    await page.evaluate(()=>new Promise(resolve=>requestAnimationFrame(()=>requestAnimationFrame(resolve))));
    const source=bottom?'log':view.slice(6);
    if(source==='user_input')assert.equal(await panel.locator('[data-chat-role="arUser"]').count(),1,'typed acknowledgement coalesces into local human message');
    else if(source==='log')assert(await panel.locator('[data-chat-role="arAssistant"]').isVisible(),'assistant content shown');
    else await panel.locator(`[data-chat-source="${source}"]`).waitFor({state:'visible'});
    const visibleContent=await panel.locator('[data-chat-scroll]').evaluate((el,bottom)=>{
      const viewport=el.getBoundingClientRect();
      const cards=[...el.querySelectorAll('[data-chat-entry]')];
      const card=cards.at(-1);const box=card.getBoundingClientRect();
      return {viewport:{top:viewport.top,bottom:viewport.bottom},card:{top:box.top,bottom:box.bottom},bottom};
    },bottom);
    if(bottom)assert(visibleContent.card.bottom<=visibleContent.viewport.bottom+1,'bottom companion shows final content');
    else assert(visibleContent.card.top>=visibleContent.viewport.top-1&&visibleContent.card.top<visibleContent.viewport.bottom-20,'event card heading inside actual visible frame');
  }
  if(view==='files'){
    const before=panel.locator('[data-chat-fact="Before"]');assert.equal(await before.locator('span').last().innerText(),sceneEvents[view].find(event=>event.type==='diff').oldText,'diff line boundaries preserved');
    assert.equal(await before.locator('span').last().evaluate(el=>getComputedStyle(el).whiteSpace),'pre-wrap');
  }
  if(view==='question'||view.startsWith('question-')){
    const question=panel.locator('[data-chat-source="agent_question"]');
    assert.equal(await question.locator('[data-chat-availability]').innerText(),'This editor cannot answer this request.');
    assert(await question.locator('[data-chat-availability]').isVisible());
    assert.equal(await question.locator('details').getAttribute('open'),null,'availability precedes expansion');
    assert.equal(await question.locator('button,input,textarea,select').count(),0,'unavailable answers have no fake controls');
  }
  const focusPaint=await input.evaluate(el=>{const s=getComputedStyle(el);return {border:s.borderColor,outline:s.outline,animation:s.animation,transition:s.transition,active:document.activeElement===el,animations:document.getAnimations().map(a=>({state:a.playState,time:a.currentTime}))};});
  const target=canary?page.locator('[data-chat-scroll]'):page;
  if(canary){
    if(view==='conversation'){
      await panel.getByText('Hero refreshed',{exact:true}).waitFor({state:'visible'});
      await panel.locator('[data-chat-markdown="code"]').waitFor({state:'visible'});
    } else {
      for(const label of ['completed','in progress','pending'])await panel.getByText(label,{exact:true}).waitFor({state:'visible'});
    }
  }
  const file=`${view}-${size}.png`;const png=await target.screenshot({path:path.join(output,file),animations:'disabled',caret:'hide'});
  let positiveControl=null;
  if(canary){
    const payload=view==='conversation'?{type:'log',level:'info',message:'CANARY POSITIVE CONTROL: changed actual assistant content.',timestamp:1700000000,eventId:'canary-negative'}:{type:'plan',entries:[{content:'CANARY POSITIVE CONTROL: changed actual plan layout.',priority:'high',status:'failed'}],is_update:true,timestamp:1700000000,eventId:'canary-negative'};
    await page.evaluate(payload=>window.__chatTest.harborEvent(JSON.stringify(payload)),payload);
    await page.evaluate(()=>new Promise(resolve=>requestAnimationFrame(()=>requestAnimationFrame(resolve))));
    const changed=await target.screenshot({path:path.join(output,`${view}-${size}-positive-control.png`),animations:'disabled',caret:'hide'});
    assert(!changed.equals(png),'exact image gate must reject changed actual prose/plan');
    positiveControl={changedSha256:hash(changed),mutation:'actual production event alters conversation/plan'};
  }
  manifest.push({view,size,file,behaviorEvidence,positiveControl,contentVerified:canary,dimensions:[png.readUInt32BE(16),png.readUInt32BE(20)],scope:canary?'actual production conversation scroll surface; excludes editor chrome, preview and composer':'full editor viewport',sha256:createHash('sha256').update(png).digest('hex'),layout,geometry,contrast,focusPaint,boundary:corpus.boundary,events:(sceneEvents[view]||[]).map(e=>e.type||e.kind),baseline:'candidate; human acceptance pending',perceptualThreshold:{maximumChangedPixelRatio:thresholds[view]},browser:browser.version()});
  if(args.includes('--missing-element-control')&&view==='empty'&&size==='wide'){
    await input.evaluate(el=>el.remove());
    await assert.rejects(()=>composerGuard(page,viewport),/required composer missing/,'same positive composer guard rejects removed composer');
    await page.screenshot({path:path.join(output,'positive-control-missing-composer.png'),animations:'disabled',caret:'hide'});
    writeFileSync(path.join(output,'missing-element-control.json'),JSON.stringify({view:'empty',size:'wide',requiredElement:'Agent prompt composer',domGateRejected:true,guard:'composerGuard used by every normal capture',independentVisualReviewerDetection:'pending'},null,2)+'\n');
  }
  await context.close();process.stdout.write(`PASS ${view}/${size}\n`);
 }
 const replaced=new Set(manifest.map(row=>row.view+'/'+row.size));
 const merged=[...(previous?.views||[]).filter(row=>!replaced.has(row.view+'/'+row.size)),...manifest].sort((a,b)=>(a.view+'/'+a.size).localeCompare(b.view+'/'+b.size));
 writeFileSync(path.join(output,'manifest.json'),JSON.stringify({schema:2,lineage,container:'mcr.microsoft.com/playwright@sha256:eac9b0a5312cdab40ee8c2429df5bf19bffdccf8f3bf3c42268e173f97541645',flags,environment,sizes,browser:browser.version(),node:process.version,views:merged},null,2)+'\n');
}finally{if(browser)await browser.close();await new Promise(resolve=>server.close(resolve));}
