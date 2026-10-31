/** Real production DOMRenderer shell starts with no story. The authored project
 * HTML/mount callback supplies a declared DOM fixture, not source/compiler/native
 * ACK/Harbor results. Native browser loading, physical selection and ownership
 * run. Read-only method wrappers record identities without changing outcomes. */
import { spawn } from "node:child_process";
import {
  mkdtempSync,
  readFileSync,
  writeFileSync,
  copyFileSync,
} from "node:fs";
import { tmpdir } from "node:os";
import path from "node:path";
import { fileURLToPath } from "node:url";
import assert from "node:assert/strict";
import { createHash } from "node:crypto";
import { chromium } from "../node_modules/playwright/index.mjs";
const repo = path.resolve(path.dirname(fileURLToPath(import.meta.url)), "..");
const root = mkdtempSync(
  path.join(process.env.ISONIM_POPUP_ARTIFACTS || tmpdir(), "preview-mount-"),
);
copyFileSync(
  repo + "/build/editor-preview-mount/editor.js",
  root + "/editor.js",
);
const traceScript =
  "\n" +
  "window.__previewTrace=[];\n" +
  "const ids=new WeakMap();let serial=0;\n" +
  "const id=doc=>doc?(ids.get(doc)||(ids.set(doc,++serial),serial)):0;\n" +
  "const snapshot=()=>window.__mountProbe?JSON.parse(window.__mountProbe.snapshot()):null;\n" +
  "const frameName=frame=>frame.getAttribute('data-component-project-frame')?'detail':frame.getAttribute('data-component-edit-frame')?'edit':'other';\n" +
  "const installed=new WeakSet();\n" +
  "const saved=[];const live=new Map();\n" +
  "const add=Element.prototype.addEventListener;const remove=Element.prototype.removeEventListener;\n" +
  "Element.prototype.addEventListener=function(type,callback,...rest){\n" +
  " if(this.tagName==='IFRAME'&&type==='load'&&callback.name==='onPreviewMountDocumentLoad'){\n" +
  "  saved.push({frame:this,callback});let handlers=live.get(this);if(!handlers)live.set(this,handlers=new Set());handlers.add(callback);\n" +
  " }\n" +
  " return add.call(this,type,callback,...rest);\n" +
  "};\n" +
  "Element.prototype.removeEventListener=function(type,callback,...rest){\n" +
  " if(type==='load')live.get(this)?.delete(callback);\n" +
  " return remove.call(this,type,callback,...rest);\n" +
  "};\n" +
  'window.__mountLoadCallbacks={invokeSaved:()=>saved.forEach(({frame,callback})=>callback.call(frame,new Event(\'load\'))),active:()=>[...live.values()].reduce((n,s)=>n+s.size,0),describe:()=>[...live].filter(([frame,handlers])=>handlers.size).map(([frame,handlers])=>({frame:frameName(frame),connected:frame.isConnected,handlers:handlers.size,ready:frame.contentDocument?.readyState,loadedRevision:frame.contentDocument?.querySelector(\'meta[name="isonim-mount-document"]\')?.content,requestedRevision:frame.srcdoc.match(/name="isonim-mount-document" content="(\\d+)"/)?.[1]}))};\n' +
  "const actual=Element.prototype.setAttribute;\n" +
  "Element.prototype.setAttribute=function(name,value){\n" +
  " if(this.tagName==='IFRAME'&&name==='srcdoc'){\n" +
  "  const frame=this;\n" +
  "  if(!installed.has(frame)){installed.add(frame);frame.addEventListener('load',()=>window.__previewTrace.push({kind:'load',frame:frameName(frame),doc:id(frame.contentDocument),ready:frame.contentDocument?.readyState,button:!!frame.contentDocument?.querySelector('#fixture-action'),state:snapshot()}));}\n" +
  "  window.__previewTrace.push({kind:'srcdoc-request',frame:frameName(frame),previousDoc:id(frame.contentDocument),state:snapshot()});\n" +
  " }\n" +
  " return actual.call(this,name,value);\n" +
  "};\n" +
  "window.__recordPreviewMount=host=>window.__previewTrace.push({kind:'mount-hook',frame:frameName(host.ownerDocument.defaultView.frameElement),doc:id(host.ownerDocument),state:snapshot()});\n" +
  "window.__previewDocumentId=id;\n";
writeFileSync(
  root + "/index.html",
  "<!doctype html><html><head><style>html,body{height:100%;margin:0;overflow:hidden}</style></head><body><script>" +
    traceScript +
    '</script><script src="editor.js"></script></body></html>',
);
const proof = {
  head: process.env.ISONIM_TEST_HEAD,
  sourceState: process.env.ISONIM_TEST_SOURCE_STATE,
  bundleSha256: createHash("sha256")
    .update(readFileSync(root + "/editor.js"))
    .digest("hex"),
  cases: [],
  errors: [],
  requests: [],
};
const server = spawn(
  "python3",
  ["-u", "-m", "http.server", "0", "--bind", "127.0.0.1", "--directory", root],
  { stdio: ["ignore", "pipe", "pipe"] },
);
let browser;
let page;
try {
  const origin = await new Promise((resolve, reject) => {
    let text = "";
    server.stdout.on("data", (d) => {
      text += d;
      const m = text.match(/port (\d+)/);
      if (m) resolve("http://127.0.0.1:" + m[1]);
    });
    server.once("exit", (c) => reject(Error("server exit " + c)));
    setTimeout(() => reject(Error("server startup timeout")), 10000).unref();
  });
  const env = { ...process.env };
  delete env.LD_LIBRARY_PATH;
  browser = await chromium.launch({
    headless: true,
    env,
    executablePath: process.env.PLAYWRIGHT_CHROMIUM_EXECUTABLE,
  });
  page = await browser.newPage({ viewport: { width: 1440, height: 900 } });
  page.setDefaultTimeout(30000);
  page.on("pageerror", (e) => proof.errors.push(e.message));
  page.on("request", (request) => {
    if (new URL(request.url()).pathname.startsWith("/api/"))
      proof.requests.push({ url: request.url(), method: request.method() });
  });
  await page.goto(origin, { waitUntil: "load" });
  await page.waitForFunction(() => window.__mountProbe);
  const state = async () =>
    JSON.parse(await page.evaluate(() => window.__mountProbe.snapshot()));
  proof.initial = await state();
  assert.equal(proof.initial.story, "");
  assert.equal(proof.initial.view, "evStoryboard");
  assert.equal(proof.initial.mounts, 0);
  assert.equal(await page.evaluate(() => window.__mountProbe.select(0)), true);
  const frame = page.locator('iframe[data-component-project-frame="true"]');
  assert.equal(await frame.count(), 1);
  await frame.waitFor({ state: "visible" });
  const waitCurrentDocument = async (expectButton = true) => {
    const revision = await frame.evaluate(
      (el) =>
        el.srcdoc.match(/name="isonim-mount-document" content="(\d+)"/)?.[1],
    );
    assert(revision);
    await page.waitForFunction(
      ({ revision, expectButton }) => {
        const frame = document.querySelector(
          'iframe[data-component-project-frame="true"]',
        );
        const doc = frame?.contentDocument;
        return (
          doc?.readyState === "complete" &&
          doc.querySelector('meta[name="isonim-mount-document"]')?.content ===
            revision &&
          (!expectButton || !!doc.querySelector("#fixture-action"))
        );
      },
      { revision, expectButton },
    );
  };
  const button = frame
    .contentFrame()
    .getByRole("button", { name: "Fixture action", exact: true });
  await button.click();
  await page.waitForFunction(
    () => JSON.parse(window.__mountProbe.snapshot()).selectedTag === "button",
  );
  proof.first = await state();
  assert.equal(proof.first.mounts, 1);
  assert.equal(proof.first.unmounts, 0);
  const current = await frame.evaluate((el) => ({
    doc: window.__previewDocumentId(el.contentDocument),
    connected: el.isConnected,
    ready: el.contentDocument.readyState,
    button: !!el.contentDocument.querySelector("#fixture-action"),
  }));
  assert.equal(current.connected, true);
  assert.equal(current.ready, "complete");
  assert.equal(current.button, true);
  proof.currentFrame = current;
  proof.cases.push(
    "empty Storyboard selection mounts into the requested connected document; physical button selection crosses production bridge",
  );
  // Same loaded story must remain mounted without replacing its document/root.
  const originalDoc = current.doc;
  assert.equal(await page.evaluate(() => window.__mountProbe.select(0)), true);
  assert.deepEqual(await state(), proof.first);
  assert.equal(
    await frame.evaluate((el) =>
      window.__previewDocumentId(el.contentDocument),
    ),
    originalDoc,
  );
  proof.cases.push(
    "unchanged current document and same story retain the live mount exactly once",
  );
  // Detector positive control: a real registered leftover is counted and the
  // SAME exact zero-listener oracle rejects it before cleanup. This controls
  // instrumentation only; it supplies no mount/readiness/source outcome.
  const injected = await frame.evaluate((el) => {
    function onPreviewMountDocumentLoad() {}
    el.addEventListener("load", onPreviewMountDocumentLoad);
    window.__removeInjectedMountListener = () =>
      el.removeEventListener("load", onPreviewMountDocumentLoad);
    return window.__mountLoadCallbacks.active();
  });
  assert.equal(injected, 1);
  assert.throws(() => assert.equal(injected, 0));
  await page.evaluate(() => window.__removeInjectedMountListener());
  assert.equal(
    await page.evaluate(() => window.__mountLoadCallbacks.active()),
    0,
  );
  proof.leftoverReadinessListenerDetector = {
    realRegisteredListenerCount: injected,
    exactZeroOracleRejected: true,
    removedCount: 0,
  };
  const beforeReload = await state();
  await page.evaluate(() => window.__mountProbe.reload());
  await waitCurrentDocument();
  await button.click();
  const reloaded = await state();
  assert.equal(reloaded.mounts, beforeReload.mounts + 1);
  assert.equal(reloaded.unmounts, beforeReload.unmounts + 1);
  assert.notEqual(
    await frame.evaluate((el) =>
      window.__previewDocumentId(el.contentDocument),
    ),
    originalDoc,
  );
  proof.readinessBeforeAssertion = await page.evaluate(() =>
    window.__mountLoadCallbacks.describe(),
  );
  await page.waitForFunction(() => window.__mountLoadCallbacks.active() === 0);
  assert.equal(
    await page.evaluate(() => window.__mountLoadCallbacks.active()),
    0,
  );
  proof.cases.push(
    "actual reload replaces the old reactive root and mounts the physical current button exactly once",
  );
  const beforeRace = await state();
  assert.deepEqual(
    await page.evaluate(() => [
      window.__mountProbe.select(1),
      window.__mountProbe.select(0),
    ]),
    [true, true],
  );
  await waitCurrentDocument();
  await button.click();
  const raced = await state();
  assert.equal(raced.mounts, beforeRace.mounts + 1);
  assert.equal(raced.unmounts, beforeRace.unmounts + 1);
  assert.equal(await button.getAttribute("data-probe-story"), raced.story);
  await page.evaluate(() => window.__mountLoadCallbacks.invokeSaved());
  assert.deepEqual(await state(), raced);
  assert.equal(
    await page.evaluate(() => window.__mountLoadCallbacks.active()),
    0,
  );
  proof.cases.push(
    "two real pending story requests publish only the latest document; saved obsolete load callbacks remain inert",
  );
  const beforeHidden = await state();
  const beforeHiddenDoc = await frame.evaluate((el) =>
    window.__previewDocumentId(el.contentDocument),
  );
  await page.evaluate(() => {
    window.__mountProbe.storyboard();
    window.__mountProbe.reload();
  });
  await waitCurrentDocument(false);
  assert.notEqual(
    await frame.evaluate((el) =>
      window.__previewDocumentId(el.contentDocument),
    ),
    beforeHiddenDoc,
  );
  const hidden = await state();
  assert.equal(hidden.mounts, beforeHidden.mounts);
  assert.equal(hidden.unmounts, beforeHidden.unmounts + 1);
  assert.equal(hidden.view, "evStoryboard");
  assert.equal(
    await frame.evaluate(
      (el) => !!el.contentDocument.querySelector("#fixture-action"),
    ),
    false,
  );
  proof.readinessBeforeAssertion = await page.evaluate(() =>
    window.__mountLoadCallbacks.describe(),
  );
  await page.waitForFunction(() => window.__mountLoadCallbacks.active() === 0);
  assert.equal(
    await page.evaluate(() => window.__mountLoadCallbacks.active()),
    0,
  );
  assert.equal(await page.evaluate(() => window.__mountProbe.select(0)), true);
  await button.click();
  const returned = await state();
  assert.equal(returned.mounts, hidden.mounts + 1);
  assert.equal(returned.unmounts, hidden.unmounts);
  proof.cases.push(
    "hidden requested document loads without mounting; activating that loaded document uses the valid immediate path",
  );
  proof.beforeDispose = returned;
  const pendingListeners = await page.evaluate(() => {
    window.__mountProbe.reload();
    const pending = window.__mountLoadCallbacks.active();
    window.__mountProbe.dispose();
    window.__mountLoadCallbacks.invokeSaved();
    return pending;
  });
  assert(pendingListeners > 0);
  proof.pendingListenersBeforeDispose = pendingListeners;
  const retired = await state();
  assert.equal(retired.disposed, true);
  assert.equal(retired.mounts, returned.mounts);
  assert.equal(retired.unmounts, returned.unmounts + 1);
  assert.equal(await page.locator("iframe").count(), 0);
  assert.equal(
    await page.evaluate(() => window.__mountLoadCallbacks.active()),
    0,
  );
  await page.evaluate(() => window.__mountLoadCallbacks.invokeSaved());
  assert.deepEqual(await state(), retired);
  proof.cases.push(
    "disposal cancels a genuine queued document request, removes its load listener and makes retained callbacks inert",
  );
  assert.equal(retired.pending, 0);
  assert.equal(retired.messages, 0);
  assert.deepEqual(proof.errors, []);
  assert(proof.requests.every((request) => request.method === "GET"));
} finally {
  if (page && !page.isClosed())
    proof.final = await page.evaluate(() => ({
      trace: window.__previewTrace,
      state: JSON.parse(window.__mountProbe.snapshot()),
      frames: [
        ...document.querySelectorAll("iframe[data-component-project-frame]"),
      ].map((el) => ({
        connected: el.isConnected,
        doc: window.__previewDocumentId(el.contentDocument),
        ready: el.contentDocument?.readyState,
        button: !!el.contentDocument?.querySelector("#fixture-action"),
      })),
    }));
  if (browser) await browser.close();
  server.kill("SIGTERM");
  await new Promise((resolve) => server.once("exit", resolve));
  writeFileSync(root + "/proof-final.json", JSON.stringify(proof, null, 2));
  console.log(root + "/proof-final.json");
}
