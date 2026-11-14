/** Shorthand sides follow the card rule's real declaration order, in the
 * inspector and in the rendered preview (Chromium), before and after the
 * automatic write, and through undo and redo.
 *
 * Editor spec "Native project source capabilities" (sides "respect
 * declaration order"), "Visual box model" (an all-sides field is `Mixed`
 * when the sides differ) and the UX-M3 control/preview/history parity
 * requirement; CSS cascade within one rule
 * (https://www.w3.org/TR/css-cascade-4/#cascade-sort). isonim-pm issue
 * 2026-10-23-a-shorthand-edit-is-shown-on-sides-a-later-longhand-still-overrides.
 *
 * No mocks. The host (`tests/helpers/editor_shorthand_order_workspace.nim`)
 * is the editor example with its real writer, preview document and browser
 * selection bridge, plus schema entries for the card's sides. The page is
 * served by a plain static file server started here. External requests (the
 * example page's Tailwind CDN script) are aborted so the run is offline.
 */
import {createServer} from 'node:http';
import {mkdtempSync,readFileSync,writeFileSync,copyFileSync,existsSync} from 'node:fs';
import {chromium} from '../node_modules/playwright/index.mjs';
import assert from 'node:assert/strict';
import path from 'node:path';
import {tmpdir} from 'node:os';
import {fileURLToPath} from 'node:url';
const repo=path.resolve(path.dirname(fileURLToPath(import.meta.url)),'..');
const bundle=repo+'/build/editor-shorthand/editor.js';
assert(existsSync(bundle),'build the host first: nim js -o:build/editor-shorthand/editor.js tests/helpers/editor_shorthand_order_workspace.nim');
const pub=mkdtempSync(path.join(process.env.ISONIM_POPUP_ARTIFACTS||tmpdir(),'shorthand-order-'));
copyFileSync(bundle,pub+'/editor.js');
for(const [from,to] of [['node_modules/fabric/dist/index.min.js','fabric.min.js'],['node_modules/paper/dist/paper-core.min.js','paper-core.min.js'],['node_modules/svgo/dist/svgo.browser.js','svgo.browser.js']])copyFileSync(repo+'/'+from,pub+'/'+to);
const index=readFileSync(repo+'/src/isonim/editor/index.html','utf8');
const page=(rule)=>index.replace('<script src="editor.js"></script>','<script>window.__isonimShorthandCardRule='+JSON.stringify(rule)+';window.__isonimShorthandExtraCss='+JSON.stringify(extraCss)+';window.__isonimShorthandKeepInlineRadius='+JSON.stringify(keepInline)+';window.__isonimShorthandOrderless='+JSON.stringify(orderlessHost)+';window.__isonimShorthandPrefixCss='+JSON.stringify(prefixCss)+';window.__isonimShorthandLink='+JSON.stringify(linkHref)+';window.__isonimShorthandAfterStyleScript='+JSON.stringify(afterStyleScript)+';</script><script src="editor.js"></script>');
const types={'.js':'text/javascript','.html':'text/html'};
let rule='',extraCss='',keepInline=false,orderlessHost=false,prefixCss='',linkHref='',afterStyleScript='';
const server=createServer((req,res)=>{const url=new URL(req.url,'http://x');const name=url.pathname==='/'?'index.html':url.pathname.slice(1);
  if(name==='index.html'){res.writeHead(200,{'content-type':'text/html'});res.end(page(rule));return;}
  // A stylesheet served without CORS, linked from the other host name, so
  // the preview can apply it but not read its rules.
  if(name==='xorigin.css'){res.writeHead(200,{'content-type':'text/css'});res.end('.destination-card { padding-right: 40px !important; }');return;}
  const file=path.join(pub,path.basename(name));if(!existsSync(file)){res.writeHead(404);res.end();return;}
  res.writeHead(200,{'content-type':types[path.extname(file)]||'application/octet-stream'});res.end(readFileSync(file));});
await new Promise(resolve=>server.listen(0,'127.0.0.1',resolve));
const origin='http://127.0.0.1:'+server.address().port;
const otherOrigin='http://localhost:'+server.address().port;
const foundation='examples/wanderlust/design-system/foundations.css';
const cases=[],errors=[];
let browser;
try {
  const env={...process.env};delete env.LD_LIBRARY_PATH;
  browser=await chromium.launch({headless:true,env,executablePath:process.env.PLAYWRIGHT_CHROMIUM_EXECUTABLE});
  const p=await browser.newPage({viewport:{width:1440,height:900}});p.setDefaultTimeout(30000);
  p.on('pageerror',e=>errors.push(e.message));
  await p.route(url=>!url.href.startsWith(origin)&&!url.href.startsWith(otherOrigin),route=>route.abort());
  const card=()=>p.frameLocator('iframe[title="Editable component preview"]').getByTestId('component-edit-preview');
  const computed=(prop)=>card().evaluate((n,prop)=>getComputedStyle(n).getPropertyValue(prop),prop);
  const rendered=async(prefix)=>{const out=[];for(const side of ['top','right','bottom','left'])out.push(await computed(prefix+side));return out;};
  const source=()=>p.evaluate(f=>window.__isonimDemoSources?.[f]??'',foundation);
  const cardRule=async()=>(await source()).match(/\.destination-card \{[^}]*\}/)[0];
  const pending=()=>p.evaluate(()=>window.__isonimEditor.pendingSourceEdits());
  const field=(name)=>p.getByRole('textbox',{name,exact:true});
  async function open(startRule,startCss='',inline=false,noOrder=false,prefix='',link='',script=''){
    rule=startRule;extraCss=startCss;keepInline=inline;orderlessHost=noOrder;prefixCss=prefix;linkHref=link;afterStyleScript=script;await p.goto(origin+'/');
    await p.getByRole('button',{name:'Open Components section'}).click();
    await p.getByRole('button',{name:'Toggle DestinationCard stories'}).click();
    await p.getByRole('button',{name:'Select story DestinationCard / Default'}).click();
    await p.getByRole('button',{name:'Switch to edit mode'}).click();
    await selectExactly();
    const layout=p.locator('[data-inspector-section-header="layout"]');
    if((await layout.getAttribute('aria-expanded'))!=='true')await layout.click();
    const toggle=p.getByRole('button',{name:'Show box model controls'});
    if((await toggle.getAttribute('aria-expanded'))!=='true')await toggle.click();
  }
  // The selection's measurement must not change what the preview renders:
  // every rule block (cssText, and each longhand's value and priority) and
  // the card's inline style are compared before and after a selection, and
  // no MutationObserver record touches the card's `style` attribute.
  const frame=()=>p.frameLocator('iframe[title="Editable component preview"]');
  async function blocks(){return card().evaluate((n)=>{const out=[];const visit=(rules)=>{for(const r of rules){if(r.style)out.push((r.selectorText||'')+'{'+window.__isonimShorthandBlockSnapshot(r.style)+'}');if(r.cssRules)visit(r.cssRules);}};for(const sh of document.styleSheets){if(sh.ownerNode&&sh.ownerNode.id==='isonim-editor-selection-paint-style')continue;try{visit(sh.cssRules);}catch(e){}}return {rules:out,inline:n.getAttribute('style'),sides:['top','right','bottom','left'].map(s=>getComputedStyle(n).getPropertyValue('padding-'+s)).concat(['top-left','top-right','bottom-right','bottom-left'].map(c=>getComputedStyle(n).getPropertyValue('border-'+c+'-radius'))),animations:n.getAnimations().length};});}
  async function selectExactly(){
    const before=await blocks();
    await card().evaluate((n)=>{window.__isonimStyleRecords=0;const o=new MutationObserver(rs=>{for(const r of rs)if(r.attributeName==='style')window.__isonimStyleRecords++;});o.observe(n,{attributes:true});window.__isonimStyleObserver=o;});
    await card().click({force:true,position:{x:3,y:3}});
    await frame().locator('[data-isonim-selected="true"]').waitFor();
    await p.waitForTimeout(300);
    const records=await card().evaluate(()=>{window.__isonimStyleObserver.disconnect();return window.__isonimStyleRecords;});
    const after=await blocks();
    assert.deepEqual(after,before,'the selection measurement changed the preview');
    assert.equal(records,0,'the selection measurement wrote the card\'s style attribute');
  }
  async function commit(name,value){const f=field(name);await f.click();await f.press('ControlOrMeta+A');await p.keyboard.type(value);await f.press('Enter');}
  async function settle(expectedRule){
    await assertPoll(async()=>[await pending(),await cardRule()],[0,expectedRule],'written rule');
  }
  async function assertPoll(read,expected,what){
    const deadline=Date.now()+20000;let last;
    while(Date.now()<deadline){last=await read();try{assert.deepEqual(last,expected);return;}catch{}await p.waitForTimeout(100);}
    assert.deepEqual(last,expected,what);
  }
  async function undoRedo(redo){await p.evaluate(()=>document.activeElement?.blur());await p.keyboard.press(redo?'ControlOrMeta+Shift+z':'ControlOrMeta+z');}

  // 1. The case in the issue: a later side keeps its value.
  await open('padding: 18px;');
  await commit('Padding top','24');
  await settle('.destination-card { padding: 18px; padding-top: 24px; }');
  await commit('Padding, all sides','20');
  // At once, from the CSSOM edit: the later side is still shown.
  await assertPoll(()=>rendered('padding-'),['24px','20px','20px','20px'],'preview right after the shorthand edit');
  assert.equal(await field('Padding top').inputValue(),'24');
  assert.equal(await field('Padding, all sides').inputValue(),'');
  assert.equal(await field('Padding, all sides').getAttribute('placeholder'),'Mixed');
  await settle('.destination-card { padding: 20px; padding-top: 24px; }');
  await assertPoll(()=>rendered('padding-'),['24px','20px','20px','20px'],'preview after the write');
  cases.push('later side keeps its value in inspector and preview, before and after the write');
  await undoRedo(false);
  await assertPoll(()=>rendered('padding-'),['24px','18px','18px','18px'],'preview after undo');
  assert.equal(await field('Padding top').inputValue(),'24');
  await undoRedo(true);
  await assertPoll(()=>rendered('padding-'),['24px','20px','20px','20px'],'preview after redo');
  assert.equal(await field('Padding top').inputValue(),'24');
  cases.push('undo and redo of the shorthand keep the later side in the preview');
  // Recapture: select the card again, then set all sides.
  await settle('.destination-card { padding: 20px; padding-top: 24px; }');
  await selectExactly();
  await commit('Padding, all sides','22');
  await assertPoll(()=>rendered('padding-'),['24px','22px','22px','22px'],'preview after recapture and shorthand edit');
  assert.equal(await field('Padding top').inputValue(),'24');
  cases.push('a recaptured selection is settled from the file again');

  // 2. A shorthand inserted after its side reaches it.
  await open('padding: 18px;');
  await commit('Margin top','10');
  await commit('Margin, all sides','6');
  await assertPoll(()=>rendered('margin-'),['6px','6px','6px','6px'],'preview after inserting margin');
  assert.equal(await field('Margin top').inputValue(),'6');
  await settle('.destination-card { padding: 18px; margin-top: 10px; margin: 6px; }');
  await assertPoll(()=>rendered('margin-'),['6px','6px','6px','6px'],'preview after the margin write');
  await undoRedo(false);
  await assertPoll(()=>rendered('margin-'),['10px','0px','0px','0px'],'preview after undoing the inserted shorthand');
  assert.equal(await field('Margin top').inputValue(),'10');
  cases.push('a margin shorthand inserted after its side reaches it; undo restores the side');

  // 3 and 4. A side a later or !important shorthand in the same rule
  // overrides: the edit is refused at the act with the reason (operator
  // decision of 2026-11-05, option B); nothing is written and nothing moves.
  const refusedAtAct=async(startRule,why)=>{
    await open(startRule);
    await commit('Padding top','30');
    const message=p.locator('[data-box-model-message]');
    await message.waitFor({state:'visible'});
    assert.match(await message.textContent(),why);
    assert.equal(await field('Padding top').inputValue(),'18');
    await p.waitForTimeout(1500);
    assert.equal(await pending(),0);
    assert.equal(await cardRule(),'.destination-card { '+startRule+' }');
    assert.deepEqual(await rendered('padding-'),['18px','18px','18px','18px']);
  };
  await refusedAtAct('padding-top: 24px; padding: 18px;',/A later `padding` declaration in `\.destination-card` overrides padding-top/);
  cases.push('a side edit a later shorthand in the same rule overrides is refused at the act');
  await refusedAtAct('padding: 18px !important; padding-top: 24px;',/The `!important` `padding` declaration in `\.destination-card` overrides padding-top/);
  cases.push('a side edit an !important shorthand in the same rule overrides is refused at the act');

  // 5. A conditional rule decides the top in another unit than the base
  // rule's (isonim-pm issue 2026-11-04-...-when-units-differ, case 1): the
  // capture measures which rule decides it, so the base rule's shorthand
  // does not move it. `@supports` rather than the example's `@media`: at
  // the compact width the box model edits the `@media` rule itself (a
  // responsive override), which is not this case.
  const conditional='@supports (display: block) { .destination-card { padding-top: 30px; } }\n';
  await open('padding: 1rem;',conditional);
  await assertPoll(()=>rendered('padding-'),['30px','16px','16px','16px'],'the conditional rule applies');
  await commit('Padding, all sides','20');
  await assertPoll(()=>rendered('padding-'),['30px','20px','20px','20px'],'preview: the conditional top is kept');
  assert.equal(await field('Padding top').inputValue(),'30');
  assert.equal(await field('Padding, all sides').inputValue(),'');
  await settle('.destination-card { padding: 20px; }');
  await assertPoll(()=>rendered('padding-'),['30px','20px','20px','20px'],'preview after the write: the conditional top is kept');
  cases.push('a side another rule decides in another unit is not moved by the base shorthand');

  // 6. The same with coinciding values (case 3).
  await open('padding: 18px;','@supports (display: block) { .destination-card { padding-top: 18px; } }\n');
  await commit('Padding, all sides','20');
  await assertPoll(()=>rendered('padding-'),['18px','20px','20px','20px'],'preview: a coinciding conditional top is kept');
  assert.equal(await field('Padding top').inputValue(),'18');
  cases.push('a side another rule decides with the same value is not moved');

  // 7. A shorthand set to a variable shows the variable on every side
  // (isonim-pm issue 2026-10-23-a-shorthand-set-to-a-variable-...).
  await open('padding: 18px;');
  await commit('Padding, all sides','1.5rem');
  await assertPoll(()=>field('Padding top').inputValue(),'1.5rem','side after a length');
  await commit('Padding, all sides','var(--wl-space-card)');
  for(const side of ['top','right','bottom','left'])await assertPoll(()=>field('Padding '+side).inputValue(),'token(wl-space-card)','side '+side+' after a variable');
  assert.equal(await field('Padding, all sides').inputValue(),'token(wl-space-card)');
  await assertPoll(()=>rendered('padding-'),['16px','16px','16px','16px'],'preview renders the variable');
  cases.push('a shorthand set to a variable shows it on every side and the all-sides field');

  // 8. Corner radius order in Chromium.
  await open('padding: 18px; border-radius: 14px; border-top-left-radius: 8px;');
  const appearance=p.locator('[data-inspector-section-header="appearance"]');
  if((await appearance.getAttribute('aria-expanded'))!=='true')await appearance.click();
  const radiusRow=p.locator('[data-inspector-section-body="appearance"] [data-property-row-css-property="border-radius"] [data-property-row-input]');
  await radiusRow.click();await radiusRow.press('ControlOrMeta+A');await p.keyboard.type('12');await radiusRow.press('Enter');
  const corners=async()=>{const out=[];for(const c of ['top-left','top-right','bottom-right','bottom-left'])out.push(await computed('border-'+c+'-radius'));return out;};
  await assertPoll(corners,['8px','12px','12px','12px'],'preview: a later corner keeps its radius');
  await settle('.destination-card { padding: 18px; border-radius: 12px; border-top-left-radius: 8px; }');
  await assertPoll(corners,['8px','12px','12px','12px'],'preview after the radius write');
  await undoRedo(false);
  await assertPoll(corners,['8px','14px','14px','14px'],'preview after undoing the radius');
  cases.push('a corner radius declared after border-radius keeps its value in Chromium, through undo');

  // 9. The preview resolver reads `! important` with a space as a priority
  // (supplementary: a direct resolver call on the same genuine document).
  const spaced=await card().evaluate((n)=>{const ok=window.__isonimSetDeclaration(n.getAttribute('data-isonim-element-id')||'','article[data-testid="component-edit-preview"]','padding-left','41px ! important','sskSharedClass');const rule=[...document.styleSheets].flatMap(s=>[...s.cssRules]).find(r=>r.selectorText==='.destination-card');return {ok,computed:getComputedStyle(n).paddingLeft,priority:rule.style.getPropertyPriority('padding-left')};});
  assert.deepEqual(spaced,{ok:true,computed:'41px',priority:'important'});
  cases.push('the preview resolver takes `! important` with a space as a priority');

  // 10. A side a partly overridden var() shorthand gives: the measurement
  // must leave the rule as it was (review: re-parsing its text dropped the
  // other longhands, turning 24/16/16/16 into 24/0/0/0 on the next selection).
  await open('padding: 18px;');
  await commit('Padding, all sides','var(--wl-space-card)');
  await settle('.destination-card { padding: token(wl-space-card); }');
  await commit('Padding top','24');
  await settle('.destination-card { padding: token(wl-space-card); padding-top: 24px; }');
  await assertPoll(()=>rendered('padding-'),['24px','16px','16px','16px'],'preview after the side edit');
  await selectExactly();
  await assertPoll(()=>rendered('padding-'),['24px','16px','16px','16px'],'preview after selecting again');
  assert.equal(await field('Padding right').inputValue(),'16');
  cases.push('selecting a card whose var() shorthand a side overrides changes nothing in the preview');

  // 11. A rule inside @container decides the top; it is named with its
  // condition, so the base rule's shorthand does not move it.
  await open('padding: 1rem;','body { container-type: inline-size; }\n@container (min-width: 1px) { .destination-card { padding-top: 30px; } }\n');
  await assertPoll(()=>rendered('padding-'),['30px','16px','16px','16px'],'the @container rule applies');
  await commit('Padding, all sides','20');
  await assertPoll(()=>rendered('padding-'),['30px','20px','20px','20px'],'preview: the @container top is kept');
  assert.equal(await field('Padding top').inputValue(),'30');
  cases.push('a side an @container rule decides is not moved by the base shorthand');

  // 12. A padding transition does not hide the measurement, and the
  // measurement starts no transition.
  await open('padding: 1rem;','article.destination-card.long-tail-card { transition-property: padding; transition-duration: 10s; }\n@supports (display: block) { .destination-card { padding-top: 30px; } }\n');
  await assertPoll(()=>rendered('padding-'),['30px','16px','16px','16px'],'the conditional rule applies under a transition');
  await commit('Padding, all sides','20');
  assert.equal(await field('Padding top').inputValue(),'30');
  cases.push('a padding transition neither hides the measurement nor is started by it');

  // 13. The example's own inline corners decide the radius: a Corner radius
  // edit of the rule leaves them, in the preview and in the inspector.
  await open('padding: 18px; border-radius: 14px;','',true);
  const appearance2=p.locator('[data-inspector-section-header="appearance"]');
  if((await appearance2.getAttribute('aria-expanded'))!=='true')await appearance2.click();
  const radius2=p.locator('[data-inspector-section-body="appearance"] [data-property-row-css-property="border-radius"] [data-property-row-input]');
  await radius2.click();await radius2.press('ControlOrMeta+A');await p.keyboard.type('12');await radius2.press('Enter');
  const corners2=async()=>{const out=[];for(const c of ['top-left','top-right','bottom-right','bottom-left'])out.push(await computed('border-'+c+'-radius'));return out;};
  await settle('.destination-card { padding: 18px; border-radius: 12px; }');
  await assertPoll(corners2,['8px','8px','8px','8px'],'preview: the inline corners hold');
  const cornerValues=await p.evaluate(()=>{const props=globalThis.__isonimEditorVm.inspector.selectedElement.value.properties;const str=(v)=>typeof v==='string'?v:String.fromCharCode(...v);return props.filter(q=>str(q.name).startsWith('border-')&&str(q.name).endsWith('-radius')&&str(q.name)!=='border-radius').map(q=>str(q.name)+'='+str(q.value));});
  assert.deepEqual(cornerValues.sort(),['border-bottom-left-radius=8px','border-bottom-right-radius=8px','border-top-left-radius=8px','border-top-right-radius=8px']);
  cases.push('corners the inline style decides are not moved by a Corner radius edit of the rule');

  // 14. A side a variable decides, as a fresh capture (after a reload) sees
  // it: the field shows the variable, and a press on its canvas handle
  // starts no drag and shows the field's reason ("Visual box model": a side
  // that is not a number cannot be dragged without replacing it).
  await open('padding: var(--wl-space-card);');
  await assertPoll(()=>rendered('padding-'),['16px','16px','16px','16px'],'the variable renders');
  assert.equal(await field('Padding top').inputValue(),'var(--wl-space-card)');
  const history14=await p.evaluate(()=>globalThis.__isonimEditorVm.inspector.undoStack.value.length);
  const handle14=frame().getByLabel('Adjust padding top',{exact:true});
  const box14=await handle14.boundingBox();assert(box14,'the padding top handle has no box');
  await p.mouse.move(box14.x+box14.width/2,box14.y+box14.height/2);await p.mouse.down();
  await p.mouse.move(box14.x+box14.width/2,box14.y+box14.height/2+12,{steps:3});
  const canvasMessage14=frame().locator('#isonim-editor-box-drag-message');
  await canvasMessage14.waitFor({state:'visible'});
  assert.match(await canvasMessage14.textContent(),/Type a numeric value to replace var\(--wl-space-card\)/);
  assert.deepEqual(await rendered('padding-'),['16px','16px','16px','16px']);
  await p.mouse.up();
  await p.waitForTimeout(1200);
  assert.equal(await p.evaluate(()=>globalThis.__isonimEditorVm.inspector.undoStack.value.length),history14);
  assert.equal(await cardRule(),'.destination-card { padding: var(--wl-space-card); }');
  cases.push('a side a variable decides is shown as the variable after a fresh capture, and its handle refuses a drag');

  // 15. A host whose writer reports no rule order: "without either, every
  // side follows the shorthand". The variable the capture read for the
  // sides is shown, but is no own declaration, so all sides follow.
  await open('padding: var(--wl-space-card);','',false,true);
  assert.equal(await field('Padding top').inputValue(),'var(--wl-space-card)');
  await commit('Padding, all sides','20');
  for(const side of ['top','right','bottom','left'])await assertPoll(()=>field('Padding '+side).inputValue(),'20','side '+side+' follows the shorthand without writer order');
  assert.equal(await field('Padding, all sides').inputValue(),'20');
  await settle('.destination-card { padding: 20px; }');
  await assertPoll(()=>rendered('padding-'),['20px','20px','20px','20px'],'preview without writer order');
  cases.push('without writer order every side follows the shorthand, a captured variable included');

  // 16. A fresh capture of a var() shorthand a later side partly overrides:
  // the sides the variable gives show it, and their handles refuse a drag
  // (review r2, R1); the variable rule is reported as deciding them (R3).
  await open('padding: var(--wl-space-card); padding-top: 24px;');
  await assertPoll(()=>rendered('padding-'),['24px','16px','16px','16px'],'the partly overridden variable renders');
  assert.equal(await field('Padding top').inputValue(),'24');
  for(const side of ['right','bottom','left'])assert.equal(await field('Padding '+side).inputValue(),'var(--wl-space-card)','Padding '+side);
  const history16=await p.evaluate(()=>globalThis.__isonimEditorVm.inspector.undoStack.value.length);
  const handle16=frame().getByLabel('Adjust padding right',{exact:true});
  const box16=await handle16.boundingBox();assert(box16,'the padding right handle has no box');
  await p.mouse.move(box16.x+box16.width/2,box16.y+box16.height/2);await p.mouse.down();
  await p.mouse.move(box16.x+box16.width/2-12,box16.y+box16.height/2,{steps:3});
  const canvasMessage16=frame().locator('#isonim-editor-box-drag-message');
  await canvasMessage16.waitFor({state:'visible'});
  assert.match(await canvasMessage16.textContent(),/Type a numeric value to replace var\(--wl-space-card\)/);
  await p.mouse.up();
  await p.waitForTimeout(1200);
  assert.deepEqual(await rendered('padding-'),['24px','16px','16px','16px']);
  assert.equal(await p.evaluate(()=>globalThis.__isonimEditorVm.inspector.undoStack.value.length),history16);
  cases.push('a fresh capture shows the sides a partly overridden variable gives as the variable, and refuses their drag');

  // 17. A transition running on another element of the preview keeps running
  // through a selection's measurement (review r2, R2).
  await open('padding: 18px;','h1 { transition: margin-left 3s linear; }\n');
  const heading=frame().locator('h1').first();
  await heading.evaluate((h)=>{window.__isonimTransitionCancels=0;h.addEventListener('transitioncancel',()=>window.__isonimTransitionCancels++);getComputedStyle(h).marginLeft;h.style.marginLeft='200px';getComputedStyle(h).marginLeft;});
  assert.equal(await heading.evaluate((h)=>h.getAnimations().length),1,'the heading transition runs');
  await selectExactly();
  const running=await heading.evaluate((h)=>({animations:h.getAnimations().length,cancels:window.__isonimTransitionCancels,left:parseFloat(getComputedStyle(h).marginLeft)}));
  assert.equal(running.animations,1,'the heading transition still runs after the selection');
  assert.equal(running.cancels,0,'the selection cancelled no transition');
  assert(running.left<200,'the heading did not snap to its end state: '+running.left);
  cases.push('a selection measurement leaves a transition on another element running');

  // 18. A stylesheet the capture cannot read (cross-origin) decides a side:
  // the side is not claimed by the one readable rule that declares it (review
  // r3, N1); it keeps what renders after a shorthand edit of that rule.
  await open('padding: 18px;','',false,false,'',otherOrigin+'/xorigin.css');
  await assertPoll(()=>rendered('padding-'),['18px','40px','18px','18px'],'the cross-origin rule applies');
  assert.equal(await card().evaluate(()=>[...document.styleSheets].some(s=>{try{s.cssRules;return false;}catch(e){return true;}})),true,'one sheet is unreadable');
  await commit('Padding, all sides','20');
  await assertPoll(()=>rendered('padding-'),['20px','40px','20px','20px'],'preview with the cross-origin side');
  assert.equal(await field('Padding right').inputValue(),'40');
  cases.push('a side an unreadable sheet decides is not claimed by the readable rule');

  // 19. A comment with the card's selector and an unbalanced brace before
  // its rule is not read as the rule (review r3, N2a).
  await open('padding: var(--wl-space-card); padding-top: 24px;','',false,false,'/* .destination-card{padding: var(--wl-radius-card); */\n');
  await assertPoll(()=>rendered('padding-'),['24px','16px','16px','16px'],'the variable renders past the comment');
  assert.equal(await field('Padding right').inputValue(),'var(--wl-space-card)');
  cases.push('a commented-out rule with an unbalanced brace is not read as the card rule');

  // 20. The shorthand changed in place in the preview's CSSOM, the <style>
  // text now stale: the stale variable is not reported (review r3, N2b).
  await open('padding: var(--wl-space-card); padding-top: 24px;');
  // Changed by a page script, as the review's standalone case did: the card
  // rule's CSSOM, in place, keeping the later side.
  await card().evaluate(()=>{const rule=[...document.styleSheets].flatMap(s=>{try{return [...s.cssRules];}catch(e){return [];}}).find(r=>r.selectorText==='.destination-card'&&!r.parentRule);rule.style.setProperty('padding','var(--wl-radius-card)');rule.style.setProperty('padding-top','24px');});
  await assertPoll(()=>rendered('padding-'),['24px','14px','14px','14px'],'the in-place shorthand renders');
  await selectExactly();
  assert.notEqual(await field('Padding right').inputValue(),'var(--wl-space-card)');
  assert.equal(await field('Padding right').inputValue(),'14');
  cases.push('a shorthand changed in place in the CSSOM is not reported from stale <style> text');

  // 21. The shorthand changed in place to another variable of the same value
  // (review r4, S1): the value cannot tell them apart, so the old variable's
  // name must not be read from the stale <style> text. The side is measured
  // not to depend on the old variable; it shows what renders.
  await open('padding: var(--wl-space-card); padding-top: 24px;',':root { --wl-same-space: 16px; }\n');
  await card().evaluate(()=>{const rule=[...document.styleSheets].flatMap(s=>{try{return [...s.cssRules];}catch(e){return [];}}).find(r=>r.selectorText==='.destination-card'&&!r.parentRule);rule.style.setProperty('padding','var(--wl-same-space)');rule.style.setProperty('padding-top','24px');});
  await assertPoll(()=>rendered('padding-'),['24px','16px','16px','16px'],'the same-value variable renders');
  await selectExactly();
  assert.equal(await field('Padding right').inputValue(),'16');
  cases.push('a shorthand changed in place to another variable of the same value is not reported by the old name');

  // 22. A page script that ran before the editor's runtime changed another
  // declaration of the block: the side the variable still gives is still
  // read, as the variable, since the side is measured to depend on it.
  await open('padding: var(--wl-space-card); padding-top: 24px;','',false,false,'','',
    "[...document.styleSheets].flatMap(s=>{try{return [...s.cssRules];}catch(e){return [];}}).find(r=>r.selectorText==='.destination-card'&&!r.parentRule).style.setProperty('padding-top','30px');");
  await assertPoll(()=>rendered('padding-'),['30px','16px','16px','16px'],'the unseen edit renders');
  assert.equal(await field('Padding right').inputValue(),'var(--wl-space-card)');
  cases.push('a side still given by the variable is read as the variable after another declaration changed');

  // 23. A shorthand edit on a rule whose padding is a partly overridden var()
  // is previewed on that rule (isonim-pm issue 2026-11-14-a-shorthand-edit-is-
  // previewed-on-another-matching-rule-...): 24/20/20/20 at once and after
  // the write, and no other rule gains the declarations.
  await open('padding: var(--wl-space-card); padding-top: 24px;');
  await commit('Padding, all sides','20');
  await assertPoll(()=>rendered('padding-'),['24px','20px','20px','20px'],'preview right after the commit');
  const others=()=>card().evaluate((n)=>[...document.styleSheets].flatMap(s=>{try{return [...s.cssRules];}catch(e){return [];}}).filter(r=>{let m=false;try{m=n.matches(r.selectorText);}catch(e){}return m&&r.selectorText!=='.destination-card'&&!r.parentRule&&[...r.style].some(k=>k.startsWith('padding'));}).map(r=>r.selectorText));
  assert.deepEqual(await others(),[]);
  await settle('.destination-card { padding: 20px; padding-top: 24px; }');
  await p.waitForTimeout(1500);
  await assertPoll(()=>rendered('padding-'),['24px','20px','20px','20px'],'preview after the write');
  assert.deepEqual(await others(),[]);
  cases.push('a shorthand edit on a partly overridden var() rule is previewed on that rule');

  // 24 and 25. The shorthand changed in place to a same-valued variable by
  // the property accessor, and by a setProperty reference a page saved
  // before the editor's runtime loaded (review r5, T1): neither reports the
  // old variable's name.
  const sameValueSwap=async(how)=>{
    await open('padding: var(--wl-space-card); padding-top: 24px;',':root { --wl-same-space: 16px; }\n',false,false,'','',
      "window.__isonimSavedSetProperty = CSSStyleDeclaration.prototype.setProperty;");
    await card().evaluate((n,how)=>{const rule=[...document.styleSheets].flatMap(s=>{try{return [...s.cssRules];}catch(e){return [];}}).find(r=>r.selectorText==='.destination-card'&&!r.parentRule);
      if(how==='accessor'){rule.style.padding='var(--wl-same-space)';rule.style['padding-top']='24px';}
      else{window.__isonimSavedSetProperty.call(rule.style,'padding','var(--wl-same-space)');window.__isonimSavedSetProperty.call(rule.style,'padding-top','24px');}},how);
    await assertPoll(()=>rendered('padding-'),['24px','16px','16px','16px'],'the swapped variable renders ('+how+')');
    await selectExactly();
    assert.equal(await field('Padding right').inputValue(),'16',how);
  };
  await sameValueSwap('accessor');
  cases.push('a same-value variable swap by the property accessor is not reported by the old name');
  await sameValueSwap('saved-setProperty');
  cases.push('a same-value variable swap by a pre-saved setProperty is not reported by the old name');

  // 26. The shorthand changed in place to a calc() of the same variable
  // (review r6, U1): it still depends on the variable, but renders 48px, not
  // the variable's 16px, so the stale `var(--wl-space-card)` is not reported.
  await open('padding: var(--wl-space-card); padding-top: 24px;');
  await card().evaluate(()=>{const rule=[...document.styleSheets].flatMap(s=>{try{return [...s.cssRules];}catch(e){return [];}}).find(r=>r.selectorText==='.destination-card'&&!r.parentRule);rule.style.setProperty('padding','calc(var(--wl-space-card) * 3)');rule.style.setProperty('padding-top','24px');});
  await assertPoll(()=>rendered('padding-'),['24px','48px','48px','48px'],'the calc() renders');
  await selectExactly();
  assert.equal(await field('Padding right').inputValue(),'48');
  cases.push('a shorthand changed in place to calc() of the variable is not reported as the variable');

  // 27. The shorthand changed in place to an alias of the variable, declared
  // by a rule that matches the card (review r6, U1): same value, depends on
  // it, so only the alias declaration says the name cannot be told.
  await open('padding: var(--wl-space-card); padding-top: 24px;','article.destination-card { --wl-alias-space: var(--wl-space-card); }\n');
  await card().evaluate(()=>{const rule=[...document.styleSheets].flatMap(s=>{try{return [...s.cssRules];}catch(e){return [];}}).find(r=>r.selectorText==='.destination-card'&&!r.parentRule);rule.style.setProperty('padding','var(--wl-alias-space)');rule.style.setProperty('padding-top','24px');});
  await assertPoll(()=>rendered('padding-'),['24px','16px','16px','16px'],'the alias renders');
  await selectExactly();
  assert.equal(await field('Padding right').inputValue(),'16');
  cases.push('a shorthand changed in place to an alias of the variable is not reported as the variable');

  // 28. An alias of the variable on a rule that matches neither the card nor
  // an ancestor cannot reach it (custom properties inherit only from
  // ancestors): the side keeps its variable, and its handle refuses a drag
  // (review r7, V2).
  await open('padding: var(--wl-space-card); padding-top: 24px;','.nowhere-card { --wl-alias-space: var(--wl-space-card); }\n');
  assert.equal(await field('Padding right').inputValue(),'var(--wl-space-card)');
  const handle28=frame().getByLabel('Adjust padding right',{exact:true});
  const box28=await handle28.boundingBox();assert(box28,'the padding right handle has no box');
  await p.mouse.move(box28.x+box28.width/2,box28.y+box28.height/2);await p.mouse.down();
  await p.mouse.move(box28.x+box28.width/2-12,box28.y+box28.height/2,{steps:3});
  await frame().locator('#isonim-editor-box-drag-message').waitFor({state:'visible'});
  assert.match(await frame().locator('#isonim-editor-box-drag-message').textContent(),/Type a numeric value to replace var\(--wl-space-card\)/);
  await p.mouse.up();
  cases.push('an alias on a rule that cannot reach the card does not stop the variable being read');

  // 29. An alias set inline on the card itself (review r7, V3).
  await open('padding: var(--wl-space-card); padding-top: 24px;');
  await card().evaluate((n)=>n.style.setProperty('--wl-alias-space','var(--wl-space-card)'));
  await selectExactly();
  assert.equal(await field('Padding right').inputValue(),'16');
  cases.push('an alias set inline on the card falls back to what renders');

  // 30. An alias in a nested rule that does reach the card (`body { &
  // .destination-card { ... } }`): its own selector is relative to its
  // parent's and cannot be judged alone, so it counts (review r8, X1).
  await open('padding: var(--wl-space-card); padding-top: 24px;','body { & .destination-card { --wl-alias-space: var(--wl-space-card); } }\n');
  assert.equal(await field('Padding right').inputValue(),'16');
  cases.push('an alias in a nested rule counts as reaching the card');

  // 31. The card made a shadow host whose shadow tree declares an alias for
  // it (`:host`): the capture cannot judge it and falls back (review r8, X2).
  await open('padding: var(--wl-space-card); padding-top: 24px;');
  await card().evaluate((n)=>{const root=n.attachShadow({mode:'open'});root.innerHTML='<style>:host { --wl-alias-space: var(--wl-space-card); }</style><slot></slot>';});
  await selectExactly();
  assert.equal(await field('Padding right').inputValue(),'16');
  cases.push('a shadow host card falls back to what renders');

  // 32. An alias in a rule under @scope that reaches the card (`@scope
  // (body) { :scope .destination-card { ... } }`): `:scope` means the scoping
  // root there, not the element `matches` is asked about, so the rule's own
  // selector cannot be judged and it counts (review r9, Y1).
  await open('padding: var(--wl-space-card); padding-top: 24px;','@scope (body) { :scope .destination-card { --wl-alias-space: var(--wl-space-card); } }\n');
  await assertPoll(()=>rendered('padding-'),['24px','16px','16px','16px'],'renders under the scoped alias');
  assert.equal(await field('Padding right').inputValue(),'16');
  cases.push('an alias in a rule under @scope counts as reaching the card');

  assert.deepEqual(errors,[]);
  console.log('Shorthand order GUI passed:',pub,cases.length);
} finally {
  if(browser)await browser.close();
  await new Promise(resolve=>server.close(resolve));
}
