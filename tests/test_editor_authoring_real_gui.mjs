/** Actual Claude -> Harbor REST -> production EditorVM/CLI/RPC/Nim compiler/DOM.
 * No model, transport, tool result, dispatcher, source producer or renderer is
 * mocked. The thin composition exposes only ephemeral context insertion and
 * read-only busy/draft probes. Browser interactions and mounted documents are real.
 * A first-turn context-only nonce proves continuous native model memory; it is
 * removed before follow-up, never persisted in project source/catalog/CLI state.
 */
import assert from 'node:assert/strict';
import {readFileSync, writeFileSync} from 'node:fs';
import {execFile} from 'node:child_process';
import {promisify} from 'node:util';
import {randomBytes} from 'node:crypto';
import path from 'node:path';
import {createPreparationClock} from './helpers/editor_preparation_clock.mjs';
import {chromium} from '../node_modules/playwright/index.mjs';
import {assertCloseAcknowledgement} from './helpers/editor_close_ack.mjs';
const data=JSON.parse(readFileSync(process.argv[2],'utf8'));
const {origin, repo, project, artifacts}=data;
const preparationClock=await createPreparationClock(data.preparationClock);
const exec=promisify(execFile);
async function until(probe,label,ms=120000){
 const started=preparationClock.now();
 while(preparationClock.elapsed(started)<ms){const value=await probe();if(value)return value;await new Promise(r=>setTimeout(r,50));}
 throw new Error('Actual model observable deadline: '+label);
}
const env={...process.env};delete env.LD_LIBRARY_PATH;
const browser=await chromium.launch({headless:true,env,executablePath:process.env.PLAYWRIGHT_CHROMIUM_EXECUTABLE??'/nix/store/1id5xlj91r8d5cj5ks4a5byrxdvr4b50-chromium-143.0.7499.192/bin/chromium'});
const page=await browser.newPage({viewport:{width:1440,height:1000}});
const errors=[];page.on('pageerror',e=>errors.push(e.message));
const requests=[], acknowledgements=[];let turn=0;
const timings={};
function recordTiming(key){
 timings[turn]??={};timings[turn][key]=Date.now();
 if(key==='submittedWallMs')timings[turn].submittedMonotonicNs=String(preparationClock.now());
 writeFileSync(path.join(artifacts,'real-turn-timing.json'),JSON.stringify({
  terminalWaitBoundMs:120000,enteredWaitBoundMs:30000,mountedWaitBoundMs:30000,turns:timings},null,2));
}
// Observe unchanged real browser ACK requests; correlate immutable operations to
// this actual conversation/turn instead of parsing model-selected shell syntax.
page.on('request',r=>{
 if(r.url().endsWith('/api/agent/prompts')){
  const body=r.postDataJSON();requests.push(body);
  writeFileSync(path.join(artifacts,'private/turn-'+requests.length+'-editor-request.json'),JSON.stringify(body),{mode:0o600});
 }
 if(r.url().endsWith('/api/editor/rpc')){const body=r.postDataJSON();
  if(body?.method==='editor.ack')acknowledgements.push({turn,operation:body.params.operation});}
});
function saveOperations(phase){
 const conversation=requests[turn-1].sessionId;
 const operations=acknowledgements.filter(row=>row.turn===turn&&row.operation?.request?.conversation===conversation).map(row=>row.operation);
 assert(operations.length>0,'actual conversation-scoped browser operation acknowledgements required');
 writeFileSync(path.join(artifacts,'private/'+phase+'-operations.json'),JSON.stringify({conversation,operations}),{mode:0o600});
}
let scope;
async function cli(args){
 const response=await exec(path.join(repo,'build/bin/isonim'),['editor',...args],{timeout:70000,env:{...env,
  ISONIM_EDITOR_ENDPOINT:origin,ISONIM_EDITOR_WORKSPACE:scope.workspace,ISONIM_EDITOR_INSTANCE:scope.instance,
  ISONIM_EDITOR_EPOCH:scope.epoch,ISONIM_EDITOR_TOKEN:scope.controlToken}});
 return JSON.parse(response.stdout);
}
const composer=page.locator('[data-editor-control-focus="composer"]');
async function send(text){recordTiming('submittedWallMs');await composer.fill(text);await composer.press('Enter');await until(()=>page.evaluate(()=>window.__authoringAcceptance.busy()),'model request entered',30000);recordTiming('busyObservedWallMs');}
async function ended(){
 recordTiming('terminalWaitStartedWallMs');
 // Official playback can issue capture immediately after navigation. Its tool
 // waits for the same actual DOM/generation oracle; only that scripted decision
 // boundary needs a filesystem barrier. The live model path stays unchanged.
 const ready=data.scriptedNonce?mounted('Hero pane / example '+turn).then(()=>{
  writeFileSync(path.join(artifacts,'authoring-capture-ready-'+turn),'mounted');
 }):Promise.resolve();
 const scriptedRemaining=()=>Math.max(0,120000-(preparationClock.elapsed(BigInt(timings[turn].submittedMonotonicNs))));
 await Promise.all([until(()=>page.evaluate(()=>!window.__authoringAcceptance.busy()),'actual provider terminal',data.scriptedNonce?scriptedRemaining():120000),ready]);
 if(data.scriptedNonce){
  const prefix=turn===1?'first':'second';
  writeFileSync(path.join(artifacts,'phase'),prefix+'-awaiting-terminal');
  await until(()=>Promise.resolve(readFileSync(path.join(artifacts,'phase'),'utf8')===prefix+'-terminal-fenced'),
   'actual scripted terminal completion and answered RPCs',scriptedRemaining());
  const proof=JSON.parse(readFileSync(path.join(artifacts,'private/scripted-turn-'+turn+'-terminal-fence.json'),'utf8'));
  assert.equal(proof.complete,true);assert.equal(proof.turn,turn);
  assert(preparationClock.elapsed(BigInt(timings[turn].submittedMonotonicNs))<120000,'original scripted TURN-START120s bound');
 }

 timings[turn].excludedPreparationMs=Number(preparationClock.excluded(BigInt(timings[turn].submittedMonotonicNs)))/1_000_000;
 timings[turn].activeElapsedMs=preparationClock.elapsed(BigInt(timings[turn].submittedMonotonicNs));
 recordTiming('terminalObservedWallMs');
}
async function mounted(story){
 recordTiming('mountedWaitStartedWallMs');
 await until(async()=>{
  const state=await cli(['state']);
  if(state.storyId!==story||state.buildStage!=='wesClean'||state.elements.length===0)return false;
  const iframe=page.frameLocator('iframe[data-component-project-frame="true"]');
  const document = await iframe.locator('body').evaluate(node => ({
   story: node.ownerDocument.querySelector('meta[name=isonim-rendered-story]')?.content,
   generation: Number(node.ownerDocument.querySelector('meta[name=isonim-rendered-generation]')?.content),
   elements: [...node.ownerDocument.querySelectorAll('[data-isonim-element-id]')].map(element=>element.getAttribute('data-isonim-element-id')).sort()
  }));
  return document.story===story && document.generation===state.previewGeneration &&
   JSON.stringify(document.elements)===JSON.stringify(state.elements.map(element=>element.id).sort()) &&
   await iframe.locator('body').isVisible() && document.elements.length>0;
 },'actual compiled GRIP document mounted',30000);
 const body=await page.frameLocator('iframe[data-component-project-frame="true"]').locator('body').innerText();
 assert(body.length>50,'real GRIP content mounted');
 recordTiming('mountedObservedWallMs');
 return {state:await cli(['state']),body};
}
try{
 const registration=page.waitForResponse(r=>r.url().endsWith('/api/editor/rpc')&&r.request().postDataJSON()?.method==='editor.register');
 await page.goto(origin);
 scope=(await (await registration).json()).result;assert.equal(scope.workspace,'grip-web-site');
 writeFileSync(path.join(artifacts,'private/registration.json'),JSON.stringify(scope),{mode:0o600});
 await until(async()=>(await cli(['state'])).capabilities.includes('create-story'),'actual source bridge',30000);
 const nonce=data.scriptedNonce??('memory-'+randomBytes(12).toString('hex'));
 writeFileSync(path.join(artifacts,'private/context-nonce.json'),JSON.stringify({nonce}),{mode:0o600});
 await page.evaluate(value=>window.__authoringAcceptance.context(value),'Project session label: '+nonce+'.');
 turn=1;writeFileSync(path.join(artifacts,'phase'),'first-start');
 await send('Help me develop this website: add the supported Hero pane example state 1 story, run a separate normal editor build after its creation completes, navigate to it, and capture its actual mounted HTML through the documented editor workflow. Use normal tools and report what you actually observed. Do not inspect or modify .scenario test artifacts.');
 await ended();
 const first=await mounted('Hero pane / example 1');
 const firstReply=await page.locator('[data-chat-role="arAssistant"]').allTextContents();
 writeFileSync(path.join(artifacts,'private/first-complete-mounted.json'),JSON.stringify({workspace:scope.workspace,instance:scope.instance,epoch:scope.epoch,story:first.state.storyId,generation:first.state.previewGeneration,elements:first.state.elements.map(row=>row.id).sort()}),{mode:0o600});
 saveOperations('first-complete');
 writeFileSync(path.join(artifacts,'phase'),'first-complete');
 await until(()=>Promise.resolve(readFileSync(path.join(artifacts,'phase'),'utf8')==='first-observed'),'native model identity recorded',30000);
 // No first-turn nonce in the second context/request, source/catalog or CLI state.
 await page.evaluate(()=>window.__authoringAcceptance.context('Current website authoring work: develop the next supported Hero pane example.'));
 assert(!JSON.stringify(await cli(['state'])).includes(nonce));
 for(const filename of ['src/editor/catalog.nim','.isonim/catalog.json'])assert(!readFileSync(path.join(project,filename),'utf8').includes(nonce));
 turn=2;writeFileSync(path.join(artifacts,'phase'),'second-start');
 await send('Continue in this same conversation. First recall the project session label from the preceding turn without reading files/history or retrieving it with tools. Then add Hero pane example state 2, run a separate normal editor build after its creation completes, navigate to it, and capture its mounted HTML. Briefly describe the actual result and the capture format. Do not inspect or modify .scenario test artifacts.');
 await ended();
 const second=await mounted('Hero pane / example 2');
 const replies=await page.locator('[data-chat-role="arAssistant"]').allTextContents();
 const responseChecks={contextOnlyNonce:replies.slice(firstReply.length).join('\n').includes(nonce),
  actualHtmlDescription:/HTML/i.test(replies.slice(firstReply.length).join('\n'))};
 writeFileSync(path.join(artifacts,'private/response-checks.json'),JSON.stringify(responseChecks),{mode:0o600});
 assert.equal(requests.length,2);assert(!JSON.stringify(requests[1]).includes(nonce));
 assert(requests[0].context.designSystemConstraints[0].includes(nonce));
 assert.equal(requests[0].context.backend,'absAgentHarbor');
 assert.equal(requests[1].context.backend,'absAgentHarbor');
 for(const field of ['accumulatedEdits','sourceMap','selectedElement','renderedComponentTree','availableTailwindClasses','themeTokens','platform','activeThemeContext'])assert(field in requests[0].context&&field in requests[1].context);
 assert(!JSON.stringify(await cli(['state'])).includes(nonce));
 for(const filename of ['src/editor/catalog.nim','.isonim/catalog.json'])assert(!readFileSync(path.join(project,filename),'utf8').includes(nonce));
 writeFileSync(path.join(artifacts,'private/second-complete-mounted.json'),JSON.stringify({workspace:scope.workspace,instance:scope.instance,epoch:scope.epoch,story:second.state.storyId,generation:second.state.previewGeneration,elements:second.state.elements.map(row=>row.id).sort()}),{mode:0o600});
 saveOperations('second-complete');
 writeFileSync(path.join(artifacts,'phase'),'second-complete');
 await until(()=>Promise.resolve(readFileSync(path.join(artifacts,'phase'),'utf8')==='second-observed'),'continuous model identity recorded',30000);
 writeFileSync(path.join(artifacts,'real-authoring.json'),JSON.stringify({first:{story:first.state.storyId,revision:first.state.revision,previewGeneration:first.state.previewGeneration,mountedBytes:first.body.length},second:{story:second.state.storyId,revision:second.state.revision,previewGeneration:second.state.previewGeneration,mountedBytes:second.body.length},responseChecks,contextFields:Object.keys(requests[0].context)},null,2));
 const close=page.waitForResponse(r=>r.url().endsWith('/api/agent/close'));
 await page.locator('[data-agent-close="true"]').click();
 const closeResponse=await close;
 assertCloseAcknowledgement(closeResponse.status(),await closeResponse.json());
 assert.deepEqual(errors,[]);
 writeFileSync(path.join(artifacts,'browser-close.json'),JSON.stringify({httpStatus:closeResponse.status(),closed:true}));
 console.log('Collected actual authoring, mounted GRIP and explicit close; host acceptance pending');
} finally {await browser.close();}
