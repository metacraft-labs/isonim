/** Real production DOMRenderer shell starts with no story. The authored project
 * HTML/mount callback supplies a declared DOM fixture, not source/compiler/native
 * ACK/Harbor results. Native browser loading, physical selection and ownership
 * run. Read-only method wrappers record identities without changing outcomes.
 *
 * Whole-UI disposal of the page preview's area measurement (PSZ-M1): the
 * resource audit wraps ResizeObserver and EventTarget listener registration.
 * Each wrapper forwards to the native method unchanged and only records the
 * creation stack, so the checks attribute a resource to renderPagePreview.
 * The window-resize fallback scenario deletes window.ResizeObserver before the
 * bundle loads. That is not a mock: it reproduces a browser without the API,
 * the condition under which the view takes its real fallback path.
 *
 * Whole-UI disposal of the shell's full-screen listeners and of the inspector's
 * pending focus-restore frame: the listener inventory is Chromium's own
 * (CDP DOMDebugger.getEventListeners), read in each target's execution
 * context, and the frame audit wraps requestAnimationFrame and
 * cancelAnimationFrame, forwarding to the native functions. The fixture's
 * disposeRetainingDom keeps the shell attached, so a listener counts as
 * released only if disposal removed it, not because its node left the page.
 *
 * The lifetime assertions use no wall-clock budget: each runs after a
 * synchronous disposal, and the pending-frame check disposes in the same task
 * that scheduled the frame, before any frame can run. The file still runs
 * under Playwright's default action timeout (30 s) and the recipe's 180 s
 * limit. */
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
const resourceAudit = () => {
  // Attribution reads creation stacks; the default limit of 10 frames would
  // cut off renderPagePreview on the deeper listen-seam path.
  Error.stackTraceLimit = Infinity;
  // Forwarding wrappers only: native observe/disconnect and add/remove run
  // unchanged; the audit records which live resources renderPagePreview made.
  const pagePreview = (stack) => stack.includes("renderPagePreview");
  const observers = new Set();
  const resize = [];
  if (window.ResizeObserver) {
    const Native = window.ResizeObserver;
    window.ResizeObserver = class AuditedResizeObserver extends Native {
      constructor(callback) {
        super(callback);
        this.auditStack = new Error().stack || "";
      }
      observe(...args) {
        observers.add(this);
        return super.observe(...args);
      }
      disconnect() {
        observers.delete(this);
        return super.disconnect();
      }
    };
  }
  const add = EventTarget.prototype.addEventListener;
  const remove = EventTarget.prototype.removeEventListener;
  const capture = (o) => (typeof o === "boolean" ? o : !!o?.capture);
  EventTarget.prototype.addEventListener = function (type, fn, options) {
    if (this === window && type === "resize")
      resize.push({ fn, capture: capture(options), stack: new Error().stack || "" });
    return add.call(this, type, fn, options);
  };
  EventTarget.prototype.removeEventListener = function (type, fn, options) {
    if (this === window && type === "resize") {
      const at = resize.findIndex((r) => r.fn === fn && r.capture === capture(options));
      if (at >= 0) resize.splice(at, 1);
    }
    return remove.call(this, type, fn, options);
  };
  const frames = new Map();
  const request = window.requestAnimationFrame;
  const cancel = window.cancelAnimationFrame;
  window.requestAnimationFrame = function (callback) {
    const stack = new Error().stack || "";
    let id;
    id = request.call(window, function (...args) {
      frames.delete(id);
      return callback.apply(this, args);
    });
    frames.set(id, stack);
    return id;
  };
  window.cancelAnimationFrame = function (id) {
    frames.delete(id);
    return cancel.call(window, id);
  };
  window.__pendingFocusRestoreFrames = () =>
    [...frames.values()].filter((stack) => stack.includes("focusInspectorControl"))
      .length;
  window.__previewAreaResources = () => ({
    observers: [...observers].filter((o) => pagePreview(o.auditStack)).length,
    resizeListeners: resize.filter((r) => pagePreview(r.stack)).length,
    allObservers: observers.size,
    allResizeListeners: resize.length,
  });
};
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
  await page.addInitScript(resourceAudit);
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
  // Positive control for the disposal check below: the audit sees the page
  // preview's live area observer while the UI is mounted.
  proof.previewAreaMounted = await page.evaluate(() =>
    window.__previewAreaResources(),
  );
  assert.equal(proof.previewAreaMounted.observers, 1);
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
  // Whole-UI disposal releases the page preview's area observer (PSZ-M1).
  proof.previewAreaDisposed = await page.evaluate(() =>
    window.__previewAreaResources(),
  );
  assert.equal(
    proof.previewAreaDisposed.observers,
    0,
    "Whole UI disposal disconnects the page preview's ResizeObserver",
  );
  proof.cases.push(
    "whole UI disposal disconnects the page preview area ResizeObserver",
  );
  assert.equal(retired.pending, 0);
  assert.equal(retired.messages, 0);
  assert.deepEqual(proof.errors, []);
  assert(proof.requests.every((request) => request.method === "GET"));
  // Window-resize fallback: without ResizeObserver the view measures on the
  // window resize event through the nondet listen seam. Its registration has
  // no reactive owner, so only the view's own cleanup can release it.
  const fallback = await browser.newPage({ viewport: { width: 1440, height: 900 } });
  try {
    await fallback.addInitScript(() => {
      delete window.ResizeObserver;
    });
    await fallback.addInitScript(resourceAudit);
    fallback.on("pageerror", (e) => proof.errors.push("fallback: " + e.message));
    await fallback.goto(origin, { waitUntil: "load" });
    await fallback.waitForFunction(() => window.__mountProbe);
    proof.fallbackMounted = await fallback.evaluate(() => ({
      api: typeof window.ResizeObserver,
      ...window.__previewAreaResources(),
    }));
    assert.equal(proof.fallbackMounted.api, "undefined");
    assert.equal(proof.fallbackMounted.resizeListeners, 1);
    // The fallback listener stays exactly one across selection, reload, a
    // view switch and a whole-UI remount; a remount releases the old one.
    proof.fallbackCycle = [];
    for (const step of ["select", "reload", "storyboard", "remount", "select"]) {
      const count = await fallback.evaluate((step) => {
        const probe = window.__mountProbe;
        if (step === "select") probe.select(0);
        else if (step === "reload") probe.reload();
        else if (step === "storyboard") probe.storyboard();
        else probe.remount();
        return window.__previewAreaResources().resizeListeners;
      }, step);
      proof.fallbackCycle.push({ step, resizeListeners: count });
      assert.equal(count, 1, "Fallback resize listener stays one after " + step);
    }
    await fallback.evaluate(() => window.__mountProbe.dispose());
    proof.fallbackDisposed = await fallback.evaluate(() =>
      window.__previewAreaResources(),
    );
    assert.equal(
      proof.fallbackDisposed.resizeListeners,
      0,
      "Whole UI disposal removes the page preview's window resize listener",
    );
    assert.deepEqual(proof.errors, []);
    proof.cases.push(
      "without ResizeObserver, whole UI disposal removes the page preview's window resize listener",
    );
  } finally {
    await fallback.close();
  }
  // Full-screen listeners (PSZ-M2) and the inspector's focus-restore frame.
  // The shell registers the full-screen listeners at mount through the nondet
  // listen seam with no owner; only the cleanup on the centre column can
  // remove them. Chromium's listener inventory is the oracle: a seam listener
  // is one whose handler is the seam's wrapper function, located by its source
  // position in the bundle (CDP reports 0-based lines and the column of the
  // parameter list).
  const bundleLines = readFileSync(root + "/editor.js", "utf8").split("\n");
  const wrapperLine = bundleLines.findIndex((line) => line.includes("entry.wrapped = function("));
  assert(wrapperLine >= 0, "The listen seam's wrapper is in the bundle");
  const wrapperColumn = bundleLines[wrapperLine].indexOf("function(") + "function".length;
  const lifetime = await browser.newPage({ viewport: { width: 1440, height: 900 } });
  try {
    await lifetime.addInitScript(resourceAudit);
    lifetime.on("pageerror", (e) => proof.errors.push("lifetime: " + e.message));
    await lifetime.goto(origin, { waitUntil: "load" });
    await lifetime.waitForFunction(() => window.__mountProbe);
    const cdp = await lifetime.context().newCDPSession(lifetime);
    const contexts = new Set();
    cdp.on("Runtime.executionContextCreated", (e) => contexts.add(e.context.id));
    cdp.on("Runtime.executionContextDestroyed", (e) =>
      contexts.delete(e.executionContextId),
    );
    await cdp.send("Runtime.enable");
    const fullScreenTypes = {
      center: ["pointermove", "pointerleave"],
      host: ["focusin", "focusout"],
      frame: ["load"],
      frameDocument: ["pointermove"],
    };
    // Targets are read in the context that owns them: the frame document's
    // listeners are only visible from the frame's own context.
    const targetIds = async () => {
      // The frame document is read once its srcdoc document has loaded, so
      // the document queried is the one the shell has bound.
      await lifetime.waitForFunction(() => {
        const frame = document.querySelector('[data-page-project-frame="true"]');
        const doc = frame?.contentDocument;
        return doc?.URL === "about:srcdoc" && doc.readyState === "complete" &&
          doc.__isonimFsBound === true;
      });
      await lifetime.evaluate(() => {
        const host = document.querySelector('[data-preview-fullscreen-controls="true"]');
        const center = host.parentElement;
        window.__fullScreenTargets = {
          host, center, frame: center.querySelector('[data-page-project-frame="true"]'),
        };
      });
      const ids = {};
      for (const key of ["center", "host", "frame"])
        ids[key] = (await cdp.send("Runtime.evaluate", {
          expression: "window.__fullScreenTargets." + key,
        })).result.objectId;
      for (const contextId of contexts) {
        const owned = await cdp.send("Runtime.evaluate", {
          expression: "window.frameElement !== null && window.frameElement === window.top.__fullScreenTargets.frame",
          contextId,
        }).catch(() => null);
        if (owned?.result?.value === true)
          ids.frameDocument = (await cdp.send("Runtime.evaluate", {
            expression: "document", contextId,
          })).result.objectId;
      }
      assert(ids.frameDocument, "The page preview frame document is reachable");
      return ids;
    };
    const seamListeners = async (ids) => {
      const counts = {};
      for (const [key, types] of Object.entries(fullScreenTypes)) {
        const { listeners } = await cdp.send("DOMDebugger.getEventListeners", {
          objectId: ids[key],
        });
        counts[key] = listeners.filter((listener) => types.includes(listener.type) &&
          listener.lineNumber === wrapperLine && listener.columnNumber === wrapperColumn).length;
      }
      return counts;
    };
    const mountedCounts = { center: 2, host: 2, frame: 1, frameDocument: 1 };
    const firstIds = await targetIds();
    proof.fullScreenMounted = await seamListeners(firstIds);
    assert.deepEqual(proof.fullScreenMounted, mountedCounts,
      "The full-screen listeners are registered while the shell is mounted");
    // A remount disposes the first shell (its DOM is removed by the fixture,
    // so only the elements are queried) and registers exactly one new set.
    await lifetime.evaluate(() => window.__mountProbe.remount());
    const remountIds = await targetIds();
    const replaced = await seamListeners({ ...firstIds, frameDocument: remountIds.frameDocument });
    proof.fullScreenReplacedShell = { center: replaced.center, host: replaced.host, frame: replaced.frame };
    assert.deepEqual(proof.fullScreenReplacedShell, { center: 0, host: 0, frame: 0 },
      "A disposed shell keeps no full-screen listener");
    proof.fullScreenRemounted = await seamListeners(remountIds);
    assert.deepEqual(proof.fullScreenRemounted, mountedCounts,
      "A remounted shell registers one set of full-screen listeners");
    // The inspector's focus restore schedules its first attempt on the next
    // animation frame. Disposing in the same task, after the request's
    // microtasks, leaves that frame pending at disposal: whole-UI disposal must
    // cancel it. No frame can run inside one task, so this does not race.
    proof.focusRestoreFrames = await lifetime.evaluate(async () => {
      window.__mountProbe.requestFocusRestore("section-search");
      for (let i = 0; i < 5; i++) await Promise.resolve();
      const pending = window.__pendingFocusRestoreFrames();
      window.__mountProbe.disposeRetainingDom();
      return { pending, afterDisposal: window.__pendingFocusRestoreFrames() };
    });
    assert.equal(proof.focusRestoreFrames.pending, 1,
      "A focus restore request schedules one animation frame");
    assert.equal(proof.focusRestoreFrames.afterDisposal, 0,
      "Whole UI disposal cancels the inspector's pending focus-restore frame");
    proof.fullScreenDisposed = await seamListeners(remountIds);
    assert.deepEqual(proof.fullScreenDisposed,
      { center: 0, host: 0, frame: 0, frameDocument: 0 },
      "Whole UI disposal removes every full-screen listener");
    assert.deepEqual(proof.errors, []);
    proof.cases.push(
      "whole UI disposal removes the full-screen listeners, including the frame document's, and a remount registers one set",
    );
    proof.cases.push(
      "whole UI disposal cancels the inspector's pending focus-restore animation frame",
    );
  } finally {
    await lifetime.close();
  }
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
