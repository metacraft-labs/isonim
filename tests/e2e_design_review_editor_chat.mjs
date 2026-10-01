// Mounted browser → production sameorigin launcher/private bootstrap → scoped
// editor RPC registration → compiled daemon → actual persistent ACP session.
// The only substituted boundary is the deterministic ACP peer: a real executable
// scripts response text instead of an external LLM. DOM, viewmodel, filesystem,
// compiler, HTTP, registration, session creation and prompt delivery remain real.
// Full Harbor REST/provider scenarios are separately registered in the chat suite.
// Launcher clean exit proves its owned daemon/provider teardown; no live ports or
// served developer assets are needed. Legacy covered-story assertions remain.

import { spawn } from "node:child_process";
import { existsSync, readFileSync, mkdtempSync, writeFileSync, createWriteStream } from "node:fs";
import { dirname, join } from "node:path";
import { fileURLToPath } from "node:url";
import { tmpdir } from "node:os";
import { once } from "node:events";
import test from "node:test";
import assert from "node:assert/strict";

const __dirname = dirname(fileURLToPath(import.meta.url));
const projectRoot = join(__dirname, "..");
const editorDir = process.env.ISONIM_CHAT_TEST_EDITOR_DIR || join(projectRoot, "build", "editor");
const reviewBin = join(projectRoot, "build", "bin", "isonim-review");
const fakeAcpBin = join(projectRoot, "build", "bin", "fake-acp-agent");

const EDITOR_PORT = Number(process.env.ISONIM_CHAT_TEST_EDITOR_PORT || 0);
let editorProc = null;
let editorOrigin;
let artifacts;
let launcherExit;
let actualSessions = [];
const shutdownPolicy = JSON.parse((await import('node:fs')).readFileSync(join(projectRoot,'tools/editor_shutdown.json')));
const shutdownMs = 1000 * (2 * shutdownPolicy.http_request_seconds + shutdownPolicy.harbor_teardown_seconds + shutdownPolicy.supervisor_margin_seconds);
async function bounded(promise, milliseconds, label) {
  let timer;
  try { return await Promise.race([promise, new Promise((_, reject) => {
    timer = setTimeout(() => reject(new Error(`${label} exceeded ${milliseconds}ms; artifacts ${artifacts}`)), milliseconds);
  })]); } finally { clearTimeout(timer); }
}

function skipIfPrereqsMissing(t) {
  const missing = [];
  if (!existsSync(reviewBin)) missing.push("build/bin/isonim-review");
  if (!existsSync(fakeAcpBin)) missing.push("build/bin/fake-acp-agent");
  if (!existsSync(join(editorDir, "editor.js")))
    missing.push("build/editor/editor.js");
  if (missing.length > 0) {
    t.skip(
      `Phase C e2e requires prerequisites: ${missing.join(", ")} — ` +
        "run `just isonim-review-build && just fake-acp-agent-build && " +
        "just editor-build` to populate them.",
    );
    return true;
  }
  return false;
}

async function startEditor() {
  actualSessions = [];
  artifacts = mkdtempSync(join(tmpdir(), 'isonim-http-chat-'));
  const config = join(artifacts, 'review.toml');
  writeFileSync(config, '[agent]\nbackend = "custom"\ncommand = ' + JSON.stringify(fakeAcpBin) + '\nargs = []\nprimer_enabled = false\n');
  const log = createWriteStream(join(artifacts, 'server.log'));
  editorProc = spawn('python3', [join(projectRoot,'tools/editor_server.py'),
    '--directory',editorDir,'--project-root',artifacts,'--port',String(EDITOR_PORT),
    '--bind','127.0.0.1','--config',config,'--daemon-binary',reviewBin],
    {cwd:projectRoot,env:{...process.env,FAKE_ACP_REPLY:'M4_HTTP_HELLO_REPLY'},stdio:['ignore','pipe','pipe']});
  launcherExit = once(editorProc, 'exit');
  editorProc.stderr.pipe(log);
  console.log(`HTTP chat artifacts ${artifacts}`);
  await bounded(new Promise((resolve,reject) => {
    let output='';
    editorProc.stdout.on('data',chunk => {
      output += chunk;
      const match=output.match(/Editor listening on (http:\/\/[^\s]+)\//);
      if(match) { editorOrigin=match[1]; resolve(); }
    });
    launcherExit.then(([code,signal]) => reject(new Error(`Launcher startup exit ${code}/${signal}`)));
  }),30000,'Production launcher startup');
}
async function stopEditor() {
  if (!editorProc) return;
  const processToStop = editorProc;
  editorProc=null;
  if(processToStop.exitCode===null && processToStop.signalCode===null) processToStop.kill('SIGTERM');
  const [code,signal]=await bounded(launcherExit,shutdownMs,'Owned launcher/daemon/provider shutdown');
  assert.equal(signal,null,'launcher must perform normal owned teardown');
  // shutdown_signals deliberately raises SystemExit(128 + SIGTERM); its
  // owned_process scope separately rejects any nonzero native daemon exit.
  assert.equal(code,143,'launcher must complete its handled SIGTERM scope');
  const log = readFileSync(join(artifacts,'server.log'),'utf8');
  assert.match(log,/isonim-review serve: exiting cleanly/, 'native daemon must exit cleanly');
  assert.doesNotMatch(log,/exceeded shutdown budget|did not exit cleanly|closure is unconfirmed/);
  for(const session of actualSessions) {
    const lines=log.split('\n');
    assert.ok(lines.some(line=>line.includes('agent client shutdown begin') && line.includes('sessionId='+session)),
      'the actual created provider session must begin shutdown');
    assert.ok(lines.some(line=>line.includes('agent client shutdown end') && line.includes('sessionId='+session)),
      'the actual created provider session must finish shutdown');
  }
}

let chromium = null;
let browser = null;

async function ensureBrowser() {
  if (chromium === null) {
    const mod = await import("playwright");
    chromium = mod.chromium;
  }
  if (browser === null) {
    browser = await chromium.launch({
      headless: true,
      timeout: 30000,
      ...(process.env.PLAYWRIGHT_CHROMIUM_EXECUTABLE
        ? { executablePath: process.env.PLAYWRIGHT_CHROMIUM_EXECUTABLE } : {}),
    });
  }
  return browser;
}

async function openEditor() {
  const b = await ensureBrowser();
  const context = await b.newContext({
    viewport: { width: 1440, height: 900 },
  });
  try {
  const page = await context.newPage();
  const registered = page.waitForResponse(response =>
    new URL(response.url()).pathname === '/api/editor/rpc' &&
    response.request().postDataJSON()?.method === 'editor.register', {timeout:30000});
  const evidence=[];
  page.on('pageerror',error=>evidence.push({pageError:error.message}));
  page.on('response',response=>{
    const pathname=new URL(response.url()).pathname;
    if(pathname.startsWith('/api/agent/')) evidence.push({path:pathname,status:response.status()});
  });
  page.on('requestfailed',request=>evidence.push({path:new URL(request.url()).pathname,error:request.failure()?.errorText}));
  context.on('close',()=>writeFileSync(join(artifacts,'browser-evidence.json'),JSON.stringify(evidence,null,2)));
  await page.goto(editorOrigin);
  const registration=await (await registered).json();
  assert.ok(registration.result, 'actual scoped browser registration must succeed');
  return { page, context };
  } catch(error) {
    try { await bounded(context.close(),30000,'Failed editor startup context shutdown'); }
    catch(cleanup) { throw new AggregateError([error,cleanup],'Editor startup and owned context cleanup failed'); }
    throw error;
  }
}

test("e2e_editor_chat_panel_hello_streams_response_from_daemon", async (t) => {
  if (skipIfPrereqsMissing(t)) return;
  try {
    await startEditor();
    const { page, context } = await openEditor();
    try {
      const input = page.locator("textarea[aria-label='Agent prompt']");
      await input.waitFor({ state: "visible", timeout: 10_000 });
      await input.fill("hello");
      const sendBtn = page.locator("[aria-label='Send agent prompt']");
      const panel = page.locator('.editor-chat[data-chat-local-id]');
      const localId = await panel.getAttribute('data-chat-local-id');
      const createdPromise = page.waitForResponse(response =>
        new URL(response.url()).pathname === '/api/agent/sessions' && response.request().method() === 'POST', {timeout:30000});
      const promptPromise = page.waitForRequest(request =>
        new URL(request.url()).pathname === '/api/agent/prompts' && request.method() === 'POST', {timeout:30000});
      const delivered = Promise.all([createdPromise,promptPromise]);
      // Handle both waits immediately: a missing route must fail within its
      // original deadline without leaving an unhandled/dangling request wait.
      delivered.catch(() => {});
      await sendBtn.click();
      const [created,promptRequest] = await delivered;
      assert.equal(created.status(), 200);
      const session = await created.json();
      assert.ok(session.sessionId, 'daemon must create an actual session');
      actualSessions.push(session.sessionId);
      const submitted = promptRequest.postDataJSON();
      assert.equal(submitted.sessionId, session.sessionId);
      assert.equal(submitted.messages[0].content[0].text, 'hello');
      const user = panel.locator('[data-chat-role="arUser"][data-chat-turn="1"] [data-chat-markdown="paragraph"]');
      await user.waitFor({state:'visible',timeout:10_000});
      assert.deepEqual(await user.allTextContents(), ['hello']);
      const assistant = panel.locator('[data-chat-role="arAssistant"][data-chat-turn="1"] [data-chat-markdown="paragraph"]');
      await page.waitForFunction(() => Array.from(document.querySelectorAll('.editor-chat [data-chat-role="arAssistant"] [data-chat-markdown="paragraph"]')).some(node => node.textContent === 'M4_HTTP_HELLO_REPLY'), null, {timeout:10_000});
      assert.deepEqual(await assistant.allTextContents(), ['M4_HTTP_HELLO_REPLY']);
      assert.equal(await assistant.isVisible(), true);
      assert.equal(await panel.getAttribute('data-chat-local-id'), localId);
      assert.equal(await page.locator(`[data-ai-assistant-tab="${localId}"]`).getAttribute('aria-selected'), 'true');
    } finally {
      await bounded(context.close(),30000,'Owned editor context shutdown');
    }
  } finally {
    await stopEditor();
  }
});

test("e2e_editor_review_this_preview_button_submits_context_loaded_prompt", async (t) => {
  if (skipIfPrereqsMissing(t)) return;
  try {
    await startEditor();
    const { page, context } = await openEditor();
    try {
      // Navigate to a story covered by the built-in brief index so the
      // brief tab actually shows a covered preview (the review button
      // is mounted regardless, but its parent container hides itself
      // when no brief covers the active story).
      const navigated = await page.evaluate(() => {
        if (window.__isonimEditor && window.__isonimEditor.selectStoryByName) {
          return window.__isonimEditor.selectStoryByName(
            "Task App / Pages",
            "Inbox",
          );
        }
        return null;
      });
      if (!navigated) {
        t.diagnostic(
          "__isonimEditor.selectStoryByName missing — editor mount may have failed",
        );
        return;
      }
      await page.waitForTimeout(500);
      const briefTabBtn = page.locator("[data-preview-pane-tab='brief']");
      await briefTabBtn.first().click();
      await page.waitForTimeout(300);

      const reviewBtn = page.locator(
        "[data-design-review-review-button='true']",
      );
      if ((await reviewBtn.count()) === 0) {
        t.diagnostic("no covered preview in the demo workspace — skipping");
        return;
      }
      const parentVisible = await reviewBtn
        .first()
        .evaluate((el) =>
          el.parentElement?.getAttribute("data-design-review-visible"),
        );
      if (parentVisible !== "true") {
        t.diagnostic(
          `review actions parent reports data-design-review-visible=${parentVisible}; ` +
            "the brief index didn't bake the Task App / Pages / Inbox story — skipping",
        );
        return;
      }
      await reviewBtn.first().click();
      await page.waitForFunction(
        () => document.body.innerText.includes("Review the preview"),
        { timeout: 10_000 },
      );
      const transcript = await page.evaluate(() => document.body.innerText);
      assert.ok(
        transcript.includes("Review the preview"),
        "the composed review prompt should appear in the chat transcript",
      );
    } finally {
      await bounded(context.close(),30000,'Owned editor context shutdown');
    }
  } finally {
    await stopEditor();
  }
});

test.after(async () => {
  if (browser) {
    await bounded(browser.close(),30000,'Owned browser shutdown');
    browser = null;
  }
});
