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
 * Cases 33 onwards: a preview edit lands on the declaration the cascade
 * uses (importance, layers, specificity, order, conditions that hold), or,
 * where the writer says which rule it writes, on that rule, so the preview
 * renders what the written file will; where neither can be told soundly the
 * preview is left alone and the write's reload shows the result. Editor spec
 * "Saving" (an edit changes the one declaration that owns the property) and
 * "Visual box model" (the preview shows the same values before the write and
 * after it); https://www.w3.org/TR/css-cascade-5/#cascade-sort. isonim-pm
 * issue 2026-11-14-a-preview-edit-lands-on-a-later-less-specific-rule-than-
 * the-one-the-cascade-uses.
 *
 * Cases 46, 49 and 50 pause the editor's 900ms auto-save while they stage
 * edits (`holdAutoSave`: the timer the editor sets is cleared as it is set)
 * and then save with Mod+S, as a person can, so that what they exercise --
 * several edits in one write, an edit before the write -- does not depend on
 * how fast the host runs. Nothing is replaced: the save that follows is the
 * editor's own.
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
const page=(rule)=>index.replace('<script src="editor.js"></script>','<script>window.__isonimShorthandCardRule='+JSON.stringify(rule)+';window.__isonimShorthandExtraCss='+JSON.stringify(extraCss)+';window.__isonimShorthandKeepInlineRadius='+JSON.stringify(keepInline)+';window.__isonimShorthandOrderless='+JSON.stringify(orderlessHost)+';window.__isonimShorthandPrefixCss='+JSON.stringify(prefixCss)+';window.__isonimShorthandLink='+JSON.stringify(linkHref)+';window.__isonimShorthandAfterStyleScript='+JSON.stringify(afterStyleScript)+';window.__isonimShorthandCardId='+JSON.stringify(cardId)+';window.__isonimShorthandCardClass='+JSON.stringify(cardClass)+';window.__isonimShorthandStagingOnly='+JSON.stringify(stagingOnly)+';window.__isonimShorthandFailWrites='+JSON.stringify(failWrites)+';</script><script src="editor.js"></script>');
const types={'.js':'text/javascript','.html':'text/html'};
let rule='',extraCss='',keepInline=false,orderlessHost=false,prefixCss='',linkHref='',afterStyleScript='',cardId='',cardClass='',stagingOnly='',failWrites='';
const server=createServer((req,res)=>{const url=new URL(req.url,'http://x');const name=url.pathname==='/'?'index.html':url.pathname.slice(1);
  if(name==='index.html'){res.writeHead(200,{'content-type':'text/html'});res.end(page(rule));return;}
  // A stylesheet served without CORS, linked from the other host name, so
  // the preview can apply it but not read its rules.
  if(name==='xorigin.css'){res.writeHead(200,{'content-type':'text/css'});res.end('.destination-card { padding-right: 40px !important; }');return;}
  // The same, deciding every side; and a web font's stylesheet (only
  // `@font-face`), linked without `crossorigin` as such sheets often are.
  if(name==='xfull.css'){res.writeHead(200,{'content-type':'text/css'});res.end('.destination-card { padding: 40px !important; }');return;}
  if(name==='xfont.css'){res.writeHead(200,{'content-type':'text/css'});res.end('@font-face { font-family: WlFont; src: local(Arial); }');return;}
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
  async function open(startRule,startCss='',inline=false,noOrder=false,prefix='',link='',script='',id='',cls='',host={}){
    rule=startRule;extraCss=startCss;keepInline=inline;orderlessHost=noOrder;prefixCss=prefix;linkHref=link;afterStyleScript=script;cardId=id;cardClass=cls;stagingOnly=host.stagingOnly?'1':'';failWrites=host.failWrites?'1':'';await p.goto(origin+'/');
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

  // 33 onwards: which rule a preview edit lands on (isonim-pm issue
  // 2026-11-14-a-preview-edit-lands-on-a-later-less-specific-rule-...). Every
  // case reads each rule of the preview's stylesheets (named as the capture
  // names a rule) and the card's inline style before the commit, right after
  // it and after the write, and requires that only the rule the edit is
  // written to changed.
  const styleState=()=>card().evaluate((n)=>{const out=[];const visit=(rs)=>{for(const r of rs){if(r.style&&r.selectorText!==undefined)out.push(window.__isonimRuleIdentity(r)+' {'+r.style.cssText+'}');if(r.cssRules)visit(r.cssRules);}};for(const sh of document.styleSheets){const o=sh.ownerNode;if(o&&o.id&&o.id.startsWith('isonim-editor'))continue;try{visit(sh.cssRules);}catch(e){}}return {rules:out,inline:n.getAttribute('style')};});
  const onlyChanged=(before,after,target,what)=>{
    const strip=(state)=>({rules:state.rules.filter(r=>!r.startsWith(target+' {')),inline:state.inline});
    assert.deepEqual(strip(after),strip(before),what+': a rule other than `'+target+'` (or the inline style) changed');
  };
  const ruleText=async(name)=>(await styleState()).rules.filter(r=>r.startsWith(name+' {'));
  const settleWrite=async(expectedRule)=>{await settle(expectedRule);await p.waitForTimeout(1500);};
  // What the preview showed when the commit's declaration reached it, read in
  // the editor page's own listener for it (registered after the preview's,
  // so it runs right after the preview handled it, and long before the
  // automatic write can reload the preview): the rules, the card's inline
  // style, the card's computed `props`, and whether the preview showed it.
  const armCapture=(props)=>p.evaluate((props)=>{
    if(window.__isonimCaptureListener)window.removeEventListener('isonim-preview-set-declaration',window.__isonimCaptureListener);
    window.__isonimCaptured=[];
    const f=document.querySelector('iframe[title="Editable component preview"]');
    window.__isonimCaptureListener=(e)=>{const w=f.contentWindow,d=f.contentDocument;const n=d.querySelector('[data-testid="component-edit-preview"]');const out=[];
      const visit=(rs)=>{for(const r of rs){if(r.style&&r.selectorText!==undefined)out.push(w.__isonimRuleIdentity(r)+' {'+r.style.cssText+'}');if(r.cssRules)visit(r.cssRules);}};
      for(const sh of d.styleSheets){const o=sh.ownerNode;if(o&&o.id&&o.id.startsWith('isonim-editor'))continue;try{visit(sh.cssRules);}catch(x){}}
      const cs=w.getComputedStyle(n);window.__isonimCaptured.push({property:e.detail.property,applied:e.detail.applied===true,state:{rules:out,inline:n.getAttribute('style')},values:props.map(q=>cs.getPropertyValue(q))});};
    window.addEventListener('isonim-preview-set-declaration',window.__isonimCaptureListener);},props);
  const captured=async()=>{await assertPoll(()=>p.evaluate(()=>(window.__isonimCaptured||[]).length>0),true,'the commit reached the preview');return p.evaluate(()=>window.__isonimCaptured[0]);};
  const sides=['top','right','bottom','left'].map(x=>'padding-'+x);
  // The editor's auto-save timer, paused (`true`: each timer it sets is
  // cleared at once) or let run again and the pending edits saved now.
  const holdAutoSave=async(on)=>{
    await p.evaluate((on)=>{
      if(!window.__isonimSaveHoldInstalled){let t=null;window.__isonimSaveHoldInstalled=true;
        Object.defineProperty(window,'__isonimAutoSaveTimer',{configurable:true,get(){return t;},set(v){if(window.__isonimHoldSave&&v){clearTimeout(v);t=null;}else t=v;}});}
      window.__isonimHoldSave=on;},on);
    if(!on){await p.evaluate(()=>document.activeElement?.blur());await p.keyboard.press('ControlOrMeta+s');}
  };


  const dragHeld=async(host={},hold=false)=>{
    await open('padding: 18px;','body { container-type: inline-size; }\n@container (min-width: 99999px) { .long-tail-card { padding-top: 30px; } }\n',false,true,'','','','','',host);
    if(hold)await holdAutoSave(true);
    const handle=frame().getByLabel('Adjust padding top',{exact:true});
    const box=await handle.boundingBox();assert(box,'the padding top handle has no box');
    await p.mouse.move(box.x+box.width/2,box.y+box.height/2);await p.mouse.down();
    await p.mouse.move(box.x+box.width/2,box.y+box.height/2+12,{steps:3});
    const dragged=await computed('padding-top');
    assert.notEqual(dragged,'18px','the drag previews a new value');
    await p.mouse.up();
    return dragged;
  };
  const heldRules=()=>card().evaluate(()=>{const s=document.getElementById('isonim-editor-box-drag-preview');return s?s.textContent.trim():'';});

  // 33. The card's own id rule decides its padding, ahead of the class rule
  // the writer writes and a later class rule. The edit is written to the
  // card rule, which the id rule overrides, so the preview -- like the
  // written file -- shows no change, and neither the id rule nor the later
  // class rule gains the value.
  await open('padding: 18px;','#wl-card { padding: 10px; }\n.long-tail-card { padding: 30px; }\n',false,false,'','','','wl-card');
  await assertPoll(()=>rendered('padding-'),['10px','10px','10px','10px'],'the id rule decides');
  const before33=await styleState();
  await commit('Padding, all sides','20');
  await assertPoll(async()=>(await ruleText('.destination-card')),['.destination-card {padding: 20px;}'],'preview: the edit is in the card rule');
  assert.deepEqual(await rendered('padding-'),['10px','10px','10px','10px'],'preview right after the commit: the id rule still decides');
  onlyChanged(before33,await styleState(),'.destination-card','right after the commit');
  assert.equal(await field('Padding top').inputValue(),'10');
  await settleWrite('.destination-card { padding: 20px; }');
  assert.deepEqual(await rendered('padding-'),['10px','10px','10px','10px'],'preview after the write');
  onlyChanged(before33,await styleState(),'.destination-card','after the write');
  cases.push('an edit the writer puts in a rule an id rule overrides is previewed in that rule, with no change, before and after the write');
  // The same document, asked without the writer's rule (the issue's own
  // probe, on the genuine preview): the id rule is the one the cascade uses,
  // not the later class rule.
  const before33b=await styleState();
  const direct33=await card().evaluate((n)=>{const ok=window.__isonimSetDeclaration(n.getAttribute('data-isonim-element-id')||'','article[data-testid="component-edit-preview"]','padding','26px','sskSharedClass','');return {ok,right:getComputedStyle(n).paddingRight};});
  assert.deepEqual(direct33,{ok:true,right:'26px'},'without the writer\'s rule the edit lands on the id rule');
  assert.deepEqual(await ruleText('#wl-card'),['#wl-card {padding: 26px;}']);
  onlyChanged(before33b,await styleState(),'#wl-card','the cascade-resolved edit');
  cases.push('without the writer\'s rule an edit lands on the id rule the cascade uses, not on a later class rule');

  // 34. An `!important` declaration in an earlier rule decides the padding
  // over the card rule the writer writes, which comes later. The edit is
  // previewed in the card rule, with no change, as the written file shows
  // it; asked without the writer's rule, the resolver takes the important
  // rule, not the later one.
  await open('padding: 18px;','',false,false,'.long-tail-card { padding: 10px !important; }\n');
  await assertPoll(()=>rendered('padding-'),['10px','10px','10px','10px'],'the important rule decides');
  const before34=await styleState();
  await commit('Padding, all sides','20');
  await assertPoll(async()=>(await ruleText('.destination-card')),['.destination-card {padding: 20px;}'],'preview: the edit is in the card rule');
  assert.deepEqual(await rendered('padding-'),['10px','10px','10px','10px'],'preview right after the commit');
  onlyChanged(before34,await styleState(),'.destination-card','right after the commit');
  await settleWrite('.destination-card { padding: 20px; }');
  assert.deepEqual(await rendered('padding-'),['10px','10px','10px','10px'],'preview after the write');
  onlyChanged(before34,await styleState(),'.destination-card','after the write');
  const before34b=await styleState();
  const direct34=await card().evaluate((n)=>{const ok=window.__isonimSetDeclaration(n.getAttribute('data-isonim-element-id')||'','article[data-testid="component-edit-preview"]','padding','26px','sskSharedClass','');return {ok,right:getComputedStyle(n).paddingRight};});
  assert.deepEqual(direct34,{ok:true,right:'26px'},'without the writer\'s rule the edit lands on the important rule');
  assert((await ruleText('.long-tail-card')).includes('.long-tail-card {padding: 26px !important;}'));
  onlyChanged(before34b,await styleState(),'.long-tail-card','the cascade-resolved edit');
  cases.push('an !important rule earlier in the sheet decides: the writer\'s later rule shows no change, and the resolver takes the important rule');

  // 35. `@layer` order: the card rule sits in a layer declared after the
  // later rule's, so it decides although it comes first.
  await open('padding: 18px;','}\n@layer low { .long-tail-card { padding: 30px; } }\n',false,true,'@layer low, card; @layer card {');
  await assertPoll(()=>rendered('padding-'),['18px','18px','18px','18px'],'the later layer decides');
  const before35=await styleState();
  await commit('Padding, all sides','20');
  await assertPoll(()=>rendered('padding-'),['20px','20px','20px','20px'],'preview right after the commit');
  assert.deepEqual(await ruleText('@layer card .destination-card'),['@layer card .destination-card {padding: 20px;}']);
  onlyChanged(before35,await styleState(),'@layer card .destination-card','right after the commit');
  await settleWrite('.destination-card { padding: 20px; }');
  assert.deepEqual(await rendered('padding-'),['20px','20px','20px','20px'],'preview after the write');
  onlyChanged(before35,await styleState(),'@layer card .destination-card','after the write');
  cases.push('a rule in a later cascade layer takes the edit, not a later rule in an earlier layer');

  // 36. Conditions that do not hold: a later rule under `@supports` and one
  // under `@media` that do not apply are not the edit's home.
  await open('padding: 18px;','@supports (display: no-such-display) { .long-tail-card { padding: 30px; } }\n@media (max-width: 1px) { .long-tail-card { padding: 31px; } }\n',false,true);
  const before36=await styleState();
  await commit('Padding, all sides','20');
  await assertPoll(()=>rendered('padding-'),['20px','20px','20px','20px'],'preview right after the commit');
  onlyChanged(before36,await styleState(),'.destination-card','right after the commit');
  await settleWrite('.destination-card { padding: 20px; }');
  assert.deepEqual(await rendered('padding-'),['20px','20px','20px','20px'],'preview after the write');
  onlyChanged(before36,await styleState(),'.destination-card','after the write');
  cases.push('a later rule under a condition that does not hold does not take the edit');

  // 37. The card's inline corners decide its radius, and the writer does not
  // say which rule it writes: no rule is the edit's home, so the preview is
  // left alone (no rule and not the inline style changes) and still shows
  // the inline corners after the write.
  await open('padding: 18px; border-radius: 14px;','',true,true);
  const appearance37=p.locator('[data-inspector-section-header="appearance"]');
  if((await appearance37.getAttribute('aria-expanded'))!=='true')await appearance37.click();
  const radius37=p.locator('[data-inspector-section-body="appearance"] [data-property-row-css-property="border-radius"] [data-property-row-input]');
  const corners37=async()=>{const out=[];for(const c of ['top-left','top-right','bottom-right','bottom-left'])out.push(await computed('border-'+c+'-radius'));return out;};
  const before37=await styleState();
  await armCapture(['border-top-left-radius','border-top-right-radius','border-bottom-right-radius','border-bottom-left-radius']);
  await radius37.click();await radius37.press('ControlOrMeta+A');await p.keyboard.type('12');await radius37.press('Enter');
  const at37=await captured();
  assert.equal(at37.property,'border-radius');
  assert.equal(at37.applied,false,'the preview did not show it');
  assert.deepEqual(at37.values,['8px','8px','8px','8px'],'preview right after the commit');
  onlyChanged(before37,at37.state,'','right after the commit');
  await settleWrite('.destination-card { padding: 18px; border-radius: 12px; }');
  await assertPoll(corners37,['8px','8px','8px','8px'],'preview after the write');
  await assertPoll(async()=>(await ruleText('.destination-card')),['.destination-card {padding: 18px; border-radius: 12px;}'],'the written rule after the write');
  onlyChanged(before37,await styleState(),'.destination-card','after the write');
  cases.push('an edit the inline style overrides changes no rule in the preview, and the write shows the inline value still');

  // 38. A sheet the preview cannot read (cross-origin) decides the right
  // padding, and the writer does not say which rule it writes. The edit is
  // set on the best readable rule and kept because the card is seen to
  // render it: three sides move at once, the unread rule keeps the fourth.
  await open('padding: 18px;','',false,true,'',otherOrigin+'/xorigin.css');
  await assertPoll(()=>rendered('padding-'),['18px','40px','18px','18px'],'the cross-origin rule applies');
  const before38=await styleState();
  await armCapture(sides);
  await commit('Padding, all sides','20');
  const at38=await captured();
  assert.equal(at38.property,'padding');
  assert.equal(at38.applied,true,'the preview showed it');
  assert.deepEqual(at38.values,['20px','40px','20px','20px'],'preview right after the commit');
  onlyChanged(before38,at38.state,'.destination-card','right after the commit');
  await settleWrite('.destination-card { padding: 20px; }');
  assert.deepEqual(await rendered('padding-'),['20px','40px','20px','20px'],'preview after the write');
  onlyChanged(before38,await styleState(),'.destination-card','after the write');
  cases.push('with a sheet the preview cannot read, an edit the card is seen to render is shown at once');

  // 38b. The unread sheet decides every side: set on the readable rule, the
  // edit moves nothing, so it is taken back and the preview is left as it
  // was; the write's reload shows the result (still the unread rule's).
  await open('padding: 18px;','',false,true,'',otherOrigin+'/xfull.css');
  await assertPoll(()=>rendered('padding-'),['40px','40px','40px','40px'],'the cross-origin rule decides');
  const before38b=await styleState();
  await armCapture(sides);
  await commit('Padding, all sides','20');
  const at38b=await captured();
  assert.equal(at38b.applied,false,'the preview did not show it');
  assert.deepEqual(at38b.values,['40px','40px','40px','40px'],'preview right after the commit: left alone');
  onlyChanged(before38b,at38b.state,'','right after the commit (the readable rule was put back)');
  await settle('.destination-card { padding: 20px; }');
  await assertPoll(async()=>(await ruleText('.destination-card')),['.destination-card {padding: 20px;}'],'the reload shows the written rule');
  assert.deepEqual(await rendered('padding-'),['40px','40px','40px','40px'],'preview after the write');
  onlyChanged(before38b,await styleState(),'.destination-card','after the write');
  cases.push('with a sheet the preview cannot read deciding every side, the edit is taken back and the reload shows the result');

  // 39. The same fallback for a declaring rule under `@container`, a
  // condition the preview cannot evaluate.
  await open('padding: 18px;','body { container-type: inline-size; }\n@container (min-width: 99999px) { .long-tail-card { padding: 30px; } }\n',false,true);
  const before39=await styleState();
  await armCapture(sides);
  await commit('Padding, all sides','20');
  const at39=await captured();
  assert.equal(at39.property,'padding');
  assert.equal(at39.applied,false,'the preview did not show it');
  assert.deepEqual(at39.values,['18px','18px','18px','18px'],'preview right after the commit: left alone');
  onlyChanged(before39,at39.state,'','right after the commit');
  await settle('.destination-card { padding: 20px; }');
  await assertPoll(()=>rendered('padding-'),['20px','20px','20px','20px'],'preview after the write: the written result');
  onlyChanged(before39,await styleState(),'.destination-card','after the write');
  cases.push('with a declaring rule under @container, the preview is left alone until the write shows the result');

  // 40. A class that starts with a digit (Tailwind's `2xl:`), which a
  // selector writes as the escape `.\32 xl`: one class, not a class and a
  // type selector, so the card rule after it decides (same specificity,
  // later) and takes the edit.
  await open('padding: 18px;','',false,true,'.\\32 xl { padding: 10px; }\n','','','','2xl');
  await assertPoll(()=>rendered('padding-'),['18px','18px','18px','18px'],'the later card rule decides');
  const before40=await styleState();
  await armCapture(sides);
  await commit('Padding, all sides','20');
  const at40=await captured();
  assert.equal(at40.applied,true,'the preview showed it');
  assert.deepEqual(at40.values,['20px','20px','20px','20px'],'preview right after the commit');
  onlyChanged(before40,at40.state,'.destination-card','right after the commit');
  await settleWrite('.destination-card { padding: 20px; }');
  assert.deepEqual(await rendered('padding-'),['20px','20px','20px','20px'],'preview after the write');
  onlyChanged(before40,await styleState(),'.destination-card','after the write');
  cases.push('a selector with a hex escape is ranked as one class');

  // 41. At-rules that hold no declarations of an element's own style --
  // `@keyframes` (which animates padding), `@font-face`, `@page` -- do not
  // stop the preview from showing the edit.
  await open('padding: 18px;','@keyframes wl-pad { from { padding: 1px; } to { padding: 2px; } }\n@font-face { font-family: WlProbe; font-weight: 700; src: local(Arial); }\n@page { margin: 1cm; }\n',false,true);
  const before41=await styleState();
  await armCapture(sides);
  await commit('Padding, all sides','20');
  const at41=await captured();
  assert.equal(at41.applied,true,'the preview showed it');
  assert.deepEqual(at41.values,['20px','20px','20px','20px'],'preview right after the commit');
  onlyChanged(before41,at41.state,'.destination-card','right after the commit');
  await settleWrite('.destination-card { padding: 20px; }');
  assert.deepEqual(await rendered('padding-'),['20px','20px','20px','20px'],'preview after the write');
  cases.push('@keyframes, @font-face and @page do not stop the preview');

  // 42. A web font's cross-origin stylesheet (only `@font-face`, rules not
  // readable): the edit is shown at once, the card being seen to render it.
  await open('padding: 18px;','',false,true,'',otherOrigin+'/xfont.css');
  assert.equal(await card().evaluate(()=>[...document.styleSheets].some(s=>{try{s.cssRules;return false;}catch(e){return true;}})),true,'one sheet is unreadable');
  const before42=await styleState();
  await armCapture(sides);
  await commit('Padding, all sides','20');
  const at42=await captured();
  assert.equal(at42.applied,true,'the preview showed it');
  assert.deepEqual(at42.values,['20px','20px','20px','20px'],'preview right after the commit');
  onlyChanged(before42,at42.state,'.destination-card','right after the commit');
  await settleWrite('.destination-card { padding: 20px; }');
  assert.deepEqual(await rendered('padding-'),['20px','20px','20px','20px'],'preview after the write');
  onlyChanged(before42,await styleState(),'.destination-card','after the write');
  cases.push('a web font\'s unreadable stylesheet does not stop the preview');

  // 43. `!important` reverses layer order: an important declaration in a
  // layer beats an unlayered important one, even a more specific, later one.
  // The writer's card rule shows no change before or after the write; asked
  // without the writer's rule, the resolver takes the layered rule.
  await open('padding: 18px;','article.destination-card { padding: 30px !important; }\n',false,false,'@layer low { .long-tail-card { padding: 10px !important; } }\n');
  await assertPoll(()=>rendered('padding-'),['10px','10px','10px','10px'],'the layered important rule decides');
  const before43=await styleState();
  await commit('Padding, all sides','20');
  await assertPoll(async()=>(await ruleText('.destination-card')),['.destination-card {padding: 20px;}'],'preview: the edit is in the card rule');
  assert.deepEqual(await rendered('padding-'),['10px','10px','10px','10px'],'preview right after the commit');
  onlyChanged(before43,await styleState(),'.destination-card','right after the commit');
  await settleWrite('.destination-card { padding: 20px; }');
  assert.deepEqual(await rendered('padding-'),['10px','10px','10px','10px'],'preview after the write');
  onlyChanged(before43,await styleState(),'.destination-card','after the write');
  const before43b=await styleState();
  const direct43=await card().evaluate((n)=>{const ok=window.__isonimSetDeclaration(n.getAttribute('data-isonim-element-id')||'','article[data-testid="component-edit-preview"]','padding','26px','sskSharedClass','');return {ok,right:getComputedStyle(n).paddingRight};});
  assert.deepEqual(direct43,{ok:true,right:'26px'},'without the writer\'s rule the edit lands on the layered important rule');
  assert.deepEqual(await ruleText('@layer low .long-tail-card'),['@layer low .long-tail-card {padding: 26px !important;}']);
  onlyChanged(before43b,await styleState(),'@layer low .long-tail-card','the cascade-resolved edit');
  cases.push('an !important declaration in a layer beats an unlayered !important one');

  // 44. The writer names its rule (`.destination-card`) but the preview has
  // no rule by that name (here it sits in a layer the preview's page wraps
  // it in): the preview does not guess another rule, it is left alone and
  // the write's reload shows the result.
  await open('padding: 18px;','}\n',false,false,'@layer card {');
  const before44=await styleState();
  await armCapture(sides);
  await commit('Padding, all sides','20');
  const at44=await captured();
  assert.equal(at44.applied,false,'the preview did not show it');
  assert.deepEqual(at44.values,['18px','18px','18px','18px'],'preview right after the commit: left alone');
  onlyChanged(before44,at44.state,'','right after the commit');
  await settle('.destination-card { padding: 20px; }');
  await assertPoll(()=>rendered('padding-'),['20px','20px','20px','20px'],'preview after the write: the written result');
  onlyChanged(before44,await styleState(),'@layer card .destination-card','after the write');
  cases.push('a writer\'s rule the preview cannot find leaves the preview to the write\'s reload');

  // 45. A canvas drag whose commit the preview cannot show (a declaring rule
  // under `@container`): on release the box keeps the dragged value until the
  // write's reload shows it, rather than snapping back.
  await open('padding: 18px;','body { container-type: inline-size; }\n@container (min-width: 99999px) { .long-tail-card { padding-top: 30px; } }\n',false,true);
  const handle45=frame().getByLabel('Adjust padding top',{exact:true});
  const box45=await handle45.boundingBox();assert(box45,'the padding top handle has no box');
  await p.mouse.move(box45.x+box45.width/2,box45.y+box45.height/2);await p.mouse.down();
  await p.mouse.move(box45.x+box45.width/2,box45.y+box45.height/2+12,{steps:3});
  const dragged45=await computed('padding-top');
  assert.notEqual(dragged45,'18px','the drag previews a new value');
  // Every style change the frame makes from the release on, with the top
  // padding it then renders, recorded in the editor page (the reload
  // replaces the frame's window).
  await card().evaluate((n)=>{parent.__isonimDragTops=[];const o=new MutationObserver(()=>{parent.__isonimDragTops.push(getComputedStyle(n).paddingTop);});o.observe(document.head,{childList:true,subtree:true,characterData:true});o.observe(n,{attributes:true});});
  await p.mouse.up();
  await settle('.destination-card { padding: 18px; padding-top: '+dragged45+'; }');
  const tops45=await p.evaluate(()=>window.__isonimDragTops);
  assert.deepEqual(tops45.filter(t=>t!==dragged45),[],'the box snapped back after the release: '+JSON.stringify(tops45));
  await assertPoll(()=>computed('padding-top'),dragged45,'preview after the write');
  cases.push('a drag whose commit the preview cannot show keeps its value until the write shows it');

  // 46. A commit the preview cannot show, then one it can, written together:
  // the write still reloads the preview, so both show.
  await open('padding: 18px;','body { container-type: inline-size; }\n@container (min-width: 99999px) { .long-tail-card { padding: 30px; } }\n',false,true);
  await armCapture(sides);
  await holdAutoSave(true);
  await commit('Padding, all sides','20');
  await commit('Margin, all sides','6');
  assert.equal(await pending(),2,'both edits wait for one write');
  await holdAutoSave(false);
  await settle('.destination-card { padding: 20px; margin: 6px; }');
  const events46=await p.evaluate(()=>window.__isonimCaptured.map(c=>c.property+':'+c.applied));
  assert.deepEqual(events46.slice(0,2),['padding:false','margin:true'],'one commit not shown, one shown');
  await assertPoll(()=>rendered('padding-'),['20px','20px','20px','20px'],'preview after the write: the unshown edit');
  assert.equal(await computed('margin-top'),'6px');
  cases.push('an unshown commit followed by a shown one before the write still gets the write\'s reload');

  // 47. The verified path with a transition on the card: the edit starts a
  // transition, so the computed value still reads the old one at the commit
  // -- that is a change being rendered, and the edit is kept.
  await open('padding: 18px;','article.destination-card { transition: padding 1.5s linear; }\n',false,true,'',otherOrigin+'/xfont.css');
  await armCapture(sides);
  await commit('Padding, all sides','20');
  const at47=await captured();
  assert.equal(at47.applied,true,'the preview showed it');
  await assertPoll(()=>rendered('padding-'),['20px','20px','20px','20px'],'the transition ends at the edit');
  await settleWrite('.destination-card { padding: 20px; }');
  assert.deepEqual(await rendered('padding-'),['20px','20px','20px','20px'],'preview after the write');
  cases.push('with a sheet the preview cannot read, an edit that starts a transition is kept');

  // 48. The verified path on a block that does not survive being re-read from
  // its own text (a var() shorthand a later side partly overrides): it could
  // not be put back exactly, so it is not touched; the unread sheet decides
  // every side, and the write's reload shows the result.
  await open('padding: var(--wl-space-card); padding-top: 4px;','',false,true,'',otherOrigin+'/xfull.css');
  await assertPoll(()=>rendered('padding-'),['40px','40px','40px','40px'],'the cross-origin rule decides');
  const before48=await styleState();
  await armCapture(sides);
  await commit('Padding, all sides','20');
  const at48=await captured();
  assert.equal(at48.applied,false,'the preview did not show it');
  onlyChanged(before48,at48.state,'','right after the commit (the block was not touched)');
  await settle('.destination-card { padding: 20px; padding-top: 4px; }');
  await assertPoll(async()=>(await ruleText('.destination-card')),['.destination-card {padding: 4px 20px 20px;}'],'the reload shows the written rule');
  assert.deepEqual(await rendered('padding-'),['40px','40px','40px','40px'],'preview after the write');
  cases.push('with a sheet the preview cannot read, a block that does not round-trip is not touched');

  // 49-52. A drag held because its commit could not be shown (case 45's
  // setup), and what releases it.
  // 49. Another property's edit does not release the hold.
  const dragged49=await dragHeld({},true);
  await armCapture(['padding-top','margin-top']);
  await commit('Margin, all sides','6');
  const at49=await captured();
  assert.equal(at49.property,'margin');
  assert.deepEqual(at49.values,[dragged49,'6px'],'the held top survives a margin edit');
  assert.equal(await pending(),2,'nothing written yet');
  await holdAutoSave(false);
  await settle('.destination-card { padding: 18px; padding-top: '+dragged49+'; margin: 6px; }');
  await assertPoll(()=>computed('padding-top'),dragged49,'after the write');
  cases.push('a held drag survives an edit of another property');

  // 50. Undoing the held edit releases it (no write follows an undo that
  // withdraws a pending edit).
  const dragged50=await dragHeld({},true);
  assert.equal(await pending(),1,'the drag waits for its write');
  await armCapture(['padding-top']);
  await undoRedo(false);
  const at50=await captured();
  assert.equal(at50.property,'padding-top');
  assert.deepEqual(at50.values,['18px'],'the undo released the held top (dragged '+dragged50+')');
  await assertPoll(pending,0,'nothing pending');
  await p.evaluate(()=>{window.__isonimHoldSave=false;});
  assert.equal(await heldRules(),'');
  assert.equal(await computed('padding-top'),'18px');
  cases.push('undoing a held drag releases it');

  // 51. A project that only stages edits: the write does not reload, so the
  // hold is released when it ends.
  const dragged51=await dragHeld({stagingOnly:true});
  await assertPoll(pending,0,'the edit is staged');
  await assertPoll(()=>computed('padding-top'),'18px','the hold is released after a write with no reload (dragged '+dragged51+')');
  assert.equal(await heldRules(),'');
  cases.push('a staging-only write releases a held drag');

  // 52. A write that fails: no reload, the hold is released.
  const dragged52=await dragHeld({failWrites:true});
  await p.locator('[data-save-error]').waitFor({state:'visible'});
  await assertPoll(()=>computed('padding-top'),'18px','the hold is released after a failed write (dragged '+dragged52+')');
  assert.equal(await heldRules(),'');
  cases.push('a failed write releases a held drag');

  // 53. A declaration of the held property in another condition (a
  // responsive override's `@media` block) or another rule does not release
  // the hold; one in the same rule and condition does. Sent on the channel
  // every preview declaration takes (`isonim-preview-set-declaration`, as
  // `applyPreviewStyle` and the undo request dispatch it).
  const dragged53=await dragHeld({},true);
  const declare53=(detail)=>card().evaluate((n,detail)=>{parent.dispatchEvent(new CustomEvent('isonim-preview-set-declaration',{detail:Object.assign({id:n.getAttribute('data-isonim-element-id')||'',path:'article[data-testid="component-edit-preview"]',property:'padding-top',value:'5px',scope:'sskSharedClass',condition:'',rule:''},detail)}));return getComputedStyle(n).paddingTop;},detail);
  assert.equal(await declare53({condition:'@media (max-width: 1px)'}),dragged53,'a responsive override of the top leaves the hold');
  assert.equal(await declare53({rule:'.no-such-rule'}),dragged53,'the top in another rule leaves the hold');
  assert.notEqual(await heldRules(),'');
  assert.equal(await declare53({}),'18px','the top in the same rule and condition releases the hold');
  assert.equal(await heldRules(),'');
  await p.evaluate(()=>{window.__isonimHoldSave=false;});
  cases.push('a held drag is released only by its own property in the same rule and condition');

  assert.deepEqual(errors,[]);
  console.log('Shorthand order GUI passed:',pub,cases.length);
} finally {
  if(browser)await browser.close();
  await new Promise(resolve=>server.close(resolve));
}
