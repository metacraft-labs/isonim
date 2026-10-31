/** Compiled private Record operations, real Chromium/local HTTP, actual Recorder,
 * strict codec and actual owned Replay. The fixture-only owner ReplayContext and
 * time seams supply the owner's own shared IDs; this does not qualify an IsoNim
 * Replay backend. The server controls genuine head/body delivery and failure.
 * Narrow original-throw/init-getter sentinels are fault controls, not transport
 * substitutes. Delegating native text and Promise resolution observations count
 * real consumption/completion; a one-shot actual sink failure exercises Recorder
 * faulting. No codec, body algorithm, cursor or scheduler is mocked.
 */
import assert from "node:assert/strict";
import { readFileSync, writeFileSync } from "node:fs";
import { createRequire } from "node:module";
import { createServer } from "node:http";
const root = process.cwd(),
  artifact = process.env.CT_ARTIFACT;
assert(artifact, "CT_ARTIFACT required");
for (const key of ["RECORD_HTTP_BUNDLE", "RECORD_HTTP_RESULTS"])
  assert(process.env[key], key + " required");
const require = createRequire(
  artifact + "/packages/boundary-shim/package.json",
);
const { build } = require("esbuild");
const { chromium } = await import(
  root + "/tests/browser/node_modules/playwright/index.mjs"
);
const prelude = `
import {Recorder,TaskKind} from '@codetracer/boundary-shim/dist/browser/recorder.js';
import {captureOriginals} from '@codetracer/boundary-shim/dist/browser/originals.js';
import {readEnvironment} from '@codetracer/boundary-shim/dist/browser/install.js';
import {sensitiveState,currentSensitiveValues} from '@codetracer/boundary-shim/dist/browser/sensitive.js';
import {createRecordFetch} from '@codetracer/boundary-shim/dist/browser/seams-net.js';
import {domV1Hash} from '@codetracer/boundary-shim/dist/browser/dom-v1.js';
import {decodeRecord,encodeLog} from '@codetracer/boundary-format';
import {installReplayRuntime} from '@codetracer/boundary-replay/dist/browser/runtime.js';
import {newReplayContext} from '@codetracer/boundary-shim/dist/browser/replay/context.js';
import {createReplayFetch,createFrameworkReplayFetch} from '@codetracer/boundary-shim/dist/browser/replay/net.js';
import {patchTimeSeams} from '@codetracer/boundary-shim/dist/browser/seams-time.js';
import {patchStorage} from '@codetracer/boundary-shim/dist/browser/seams-storage.js';
import {replayTimeSeams} from '@codetracer/boundary-shim/dist/browser/replay/time.js';
globalThis.rhOwner={TaskKind,Recorder,patchTimeSeams,patchStorage,captureOriginals,readEnvironment,sensitiveState,currentSensitiveValues,createRecordFetch,domV1Hash,decodeRecord,encodeLog,installReplayRuntime,newReplayContext,createReplayFetch,createFrameworkReplayFetch,replayTimeSeams};
`;
const replayMode = process.env.REPLAY_HTTP_BUNDLE !== undefined;
const bundle = await build({
  stdin: {
    resolveDir: artifact,
    contents:
      prelude +
      readFileSync(replayMode ? process.env.REPLAY_HTTP_BUNDLE : process.env.RECORD_HTTP_BUNDLE, "utf8") +
      (replayMode ? "\nObject.assign(globalThis,{rpInit,rpHttp,rpRpc,rpRaw,rpPreparedFetch,rpSelectedClock}); globalThis.rhUseReplayProduction=true;" : "") +
      "\nObject.assign(globalThis,{rhInit,rhHttp,rhRpc,rhView,rhReplayHttp,rhReplayRpc,rhTimerInit,rhTimer,rhPublicHttp,rhPublicRpc,rhPublicSelect,rhDispatch,rhRaw,rhPreparedFetch,rhCustomSelect,rhFakeStart,rhFakeState,rhFakeAdvance,rhFakeEnd});",
  },
  bundle: true,
  platform: "browser",
  format: "iife",
  write: false,
  metafile: true,
});
writeFileSync(
  process.env.RECORD_HTTP_RESULTS + "-metafile.json",
  JSON.stringify(bundle.metafile, null, 2),
);
const requests = [],
  slots = new Map(),
  failed = new Set();
const server = createServer(async (q, s) => {
  const u = new URL(q.url, "http://localhost");
  if (u.pathname === "/") {
    s.end("<!doctype html><main>Record HTTP composition</main>");
    return;
  }
  let body = "";
  for await (const c of q) body += c;
  const id = u.searchParams.get("id");
  requests.push({ id, method: q.method, body, headers: q.headers });
  if (failed.has(id)) {
    q.socket.destroy();
    return;
  }
  if (["/head", "/body"].includes(u.pathname)) {
    slots.set(id, s);
    if (u.pathname === "/body") {
      s.writeHead(207, {
        "Content-Type": "text/plain",
        "Retry-After": "3",
        "Isonim-Commit": "commit",
      });
      s.flushHeaders();
      s.write("first-");
    }
    return;
  }
  if (u.pathname === "/null") {
    s.writeHead(204);
    s.end();
    return;
  }
  s.writeHead(207, {
    "Content-Type": "text/plain",
    "Retry-After": "3",
    "Isonim-Commit": "commit",
    "X-Proof": "native",
  });
  s.end("actual:" + body);
});
await new Promise((r) => server.listen(0, "127.0.0.1", r));
const base = "http://127.0.0.1:" + server.address().port,
  results = [];
const browser = await chromium.launch({
  executablePath: process.env.PLAYWRIGHT_CHROMIUM_EXECUTABLE,
});
async function page() {
  const p = await browser.newPage();
  await p.goto(base);
  await p.addScriptTag({ content: bundle.outputFiles[0].text });
  return p;
}
async function slot(id) {
  for (let n = 0; n < 400; n++) {
    if (slots.has(id)) return slots.get(id);
    await new Promise((r) => setTimeout(r, 5));
  }
  assert.fail("actual local request missing " + id);
}
try {
  // Independent native reference: the existing compiled direct RPC composition
  // consumes a real held network body in a fresh realm before owner preparation.
  // Wait for the actual native text consumer, so this is a pending-body abort,
  // rather than the distinct pre-header signal rejection.
  const nativePage = await page();
  await nativePage.evaluate(() => {
    const text = Response.prototype.text;
    globalThis.nativeBodyAbort = { reads: 0, state: "pending" };
    globalThis.nativeController = new AbortController();
    Response.prototype.text = function (...args) {
      nativeBodyAbort.reads++;
      return text.apply(this, args);
    };
    rhReplayRpc(window.fetch, "/body?id=native-body-abort", "payload",
      nativeController.signal, null).then(value => {
        nativeBodyAbort.value = value;
        nativeBodyAbort.state = "fulfilled";
      }, error => {
        nativeBodyAbort.error = String(error);
        nativeBodyAbort.state = "rejected";
      });
  });
  await slot("native-body-abort");
  await nativePage.waitForFunction(() => nativeBodyAbort.reads === 1);
  assert.equal(await nativePage.evaluate(() => nativeBodyAbort.state), "pending",
    "native RPC body consumer is pending before abort");
  await nativePage.evaluate(() => nativeController.abort());
  await nativePage.waitForFunction(() => nativeBodyAbort.state !== "pending");
  const nativeBodyAbort = await nativePage.evaluate(() => nativeBodyAbort);
  assert.deepEqual(nativeBodyAbort, {
    reads: 1,
    state: "fulfilled",
    value: { status: -1, text: "AbortError: The user aborted a request.",
      retryAfter: "", commit: "" },
  }, "native pending-body abort retains exact RPC projection");
  results.push({ kind: "native-body-abort", observation: nativeBodyAbort });
  await nativePage.close();
  // Projection-fault sentinel on a real delivered response, not a fake body.
  const nativeFaultPage = await page();
  const nativeProjectionFault = await nativeFaultPage.evaluate(async () => {
    const controller = new AbortController();
    let faults = 0;
    Object.defineProperty(Response.prototype, "text", {
      configurable: true,
      get() {
        faults++;
        controller.abort();
        throw new TypeError("controlled RPC text projection fault");
      },
    });
    const value = await rhReplayRpc(window.fetch, "/ready?id=native-projection-fault",
      "payload", controller.signal, null);
    return { faults, value };
  });
  assert.deepEqual(nativeProjectionFault, { faults: 1,
    value: { status: -1, text: "TypeError: controlled RPC text projection fault",
      retryAfter: "", commit: "" } }, "native RPC projection fault uses aborted-signal fallback");
  assert.equal(requests.filter(r => r.id === "native-projection-fault").length, 1,
    "projection fault follows genuine native HTTP");
  results.push({ kind: "native-projection-fault", observation: nativeProjectionFault });
  await nativeFaultPage.close();
  for (const kind of replayMode && process.env.REPLAY_HTTP_CASE === "constructed-null" ? ["http"] : ["http", "rpc"])
    for (const scenario of replayMode && process.env.REPLAY_HTTP_CASE === "constructed-null" ? ["constructed-null", "ready"] : kind === "http"
      ? [
          "ready",
          "null",
          "constructed-null",
          "head-complete",
          "body-complete",
          "head-fail",
          "body-fail",
        ]
      : [
          "ready",
          "null",
          "constructed-null",
          "head-complete",
          "body-complete",
          "head-abort",
          "body-abort",
          "projection-abort",
          "head-fail",
          "body-fail",
        ]) {
      const p = await page(),
        id = kind + "-" + scenario,
        url = "/" + scenario.split("-")[0] + "?id=" + id;
      await p.evaluate(
        ({ kind, url, scenario }) => {
          const a = rhOwner,
            o = a.captureOriginals(window),
            frames = [],
            sensitive = a.sensitiveState(window),
            refused = new Set();
          const rec = new a.Recorder({
            checkpointScheme: "dom-v1",
            checkpointHash: () => a.domV1Hash(document),
            sink: {
              append: (f) => frames.push(f),
              end: (u, f) => frames.push(f),
              halt() {},
            },
          });
          rec.start(
            {
              vocab: 1,
              protocol_level: 0,
              recorder_id: "private-record-http",
              framework: "",
              build_hash: "a".repeat(64),
              session_id: "1".repeat(32),
              prev_session: "",
              capabilities: "[]",
            },
            a.readEnvironment(window, o),
          );
          const counts = { fetch: 0, text: 0, completions: 0, receivers: [] };
          const nativeFetch = o.fetch,
            nativeText = Response.prototype.text;
          o.fetch = function (...args) {
            counts.fetch++;
            counts.receivers.push(this === window);
            return scenario === "constructed-null"
              ? Promise.resolve(new Response(null, { status: 204 }))
              : nativeFetch.apply(this, args);
          };
          Response.prototype.text = function (...args) {
            counts.text++;
            counts.receivers.push(this instanceof o.Response);
            return nativeText.apply(this, args);
          };
          const ctx = {
            w: window,
            rec,
            orig: o,
            sensitive,
            holes: () => a.currentSensitiveValues(window, sensitive),
            refuseOnce(feature, detail) {
              if (!rec.recording || refused.has(feature)) return;
              refused.add(feature);
              rec.guard(() => rec.emit("Refusal", { feature, detail }));
            },
          };
          const before = window.fetch;
          rhInit(ctx);
          const preparedFetch = rhPreparedFetch();
          rhInit(ctx);
          if (preparedFetch !== rhPreparedFetch())
            throw Error("same context retains exact owner callable");
          if (window.fetch !== before) throw Error("global fetch changed");
          globalThis.rhState = {
            a,
            o,
            rec,
            ctx,
            frames,
            counts,
            resolutions: [],
          };
          globalThis.controller = new AbortController();
          globalThis.outcome = { state: "pending" };
          const NativePromise = Promise;
          if (kind === "http") {
            window.Promise = class extends NativePromise {
              constructor(executor) {
                const cell = { resolve: 0, reject: 0 };
                rhState.resolutions.push(cell);
                super((resolve, reject) =>
                  executor(
                    function (...args) {
                      cell.resolve++;
                      return resolve.apply(this, args);
                    },
                    function (...args) {
                      cell.reject++;
                      return reject.apply(this, args);
                    },
                  ),
                );
              }
            };
          }
          if (scenario === "projection-abort")
            Object.defineProperty(Response.prototype, "text", {
              configurable: true,
              get() {
                counts.projectionFaults = (counts.projectionFaults || 0) + 1;
                controller.abort();
                throw new TypeError("controlled RPC text projection fault");
              },
            });
          const pending =
            kind === "http"
              ? rhHttp(url, "payload")
              : rhRpc(url, "payload", controller.signal, {
                  "Isonim-After": "after",
                  "Idempotency-Key": "key",
                });
          window.Promise = NativePromise;
          pending.then(
            (value) => {
              counts.completions++;
              return (outcome = {
                state: "fulfilled",
                value: kind === "http" ? rhView(value) : value,
              });
            },
            (error) => {
              counts.completions++;
              return (outcome = { state: "rejected", error: String(error) });
            },
          );
        },
        { kind, url, scenario },
      );
      if (scenario.startsWith("head-") || scenario.startsWith("body-")) {
        const s = await slot(id);
        if (scenario.startsWith("body-")) {
          await p.waitForFunction((url) => {
            const { a, frames, counts } = rhState;
            const records = frames.map((f) => a.decodeRecord(f.subarray(4)));
            const request = records.find(
              (r) =>
                r.record === "NetRequest" &&
                r.url === new URL(url, location.href).href,
            );
            return (
              request &&
              counts.text === 1 &&
              records.some(
                (r) =>
                  r.record === "NetResponse" &&
                  r.req_id === request.req_id &&
                  r.outcome === 5,
              )
            );
          }, url);
        } else {
          const held = await p.evaluate(() => ({
            text: rhState.counts.text,
            heads: rhState.frames
              .map((f) => rhState.a.decodeRecord(f.subarray(4)))
              .filter((r) => r.record === "NetResponse").length,
          }));
          assert.deepEqual(
            held,
            { text: 0, heads: 0 },
            "head-held has no delivered owner head or body consumer",
          );
        }
        assert.equal(
          (await p.evaluate(() => outcome)).state,
          "pending",
          "delayed buffered completion remains pending",
        );
        if (scenario.endsWith("complete")) {
          if (scenario.startsWith("head"))
            s.writeHead(207, { "Content-Type": "text/plain" });
          s.end("last");
        } else if (scenario.endsWith("abort")) {
          await p.evaluate(() => controller.abort());
        } else {
          failed.add(id);
          s.destroy();
        }
      }
      await p.waitForFunction(() => outcome.state !== "pending");
      const record = await p.evaluate(() => {
        const { a, rec, frames } = rhState;
        rec.end(2);
        const records = frames.map((f) => a.decodeRecord(f.subarray(4)));
        let raw = "";
        for (const b of a.encodeLog(records)) raw += String.fromCharCode(b);
        return {
          outcome,
          counts: rhState.counts,
          resolutions: rhState.resolutions,
          log: btoa(raw),
          records: JSON.parse(
            JSON.stringify(records, (_, v) =>
              typeof v === "bigint" ? String(v) : v,
            ),
          ),
        };
      });
      writeFileSync(
        process.env.RECORD_HTTP_RESULTS + "-" + id + "-record.json",
        JSON.stringify(record, null, 2),
      );
      assert.equal(
        record.outcome.state,
        "fulfilled",
        "buffered failure projection fulfills",
      );
      const value = record.outcome.value;
      assert.equal(
        value.status,
        ["null", "constructed-null"].includes(scenario)
          ? 204
          : scenario.endsWith("abort") && kind === "rpc"
            ? -1
            : scenario.endsWith("fail") || scenario.endsWith("abort")
              ? kind === "http"
                ? 599
                : 0
              : 207,
        "semantic: exact buffered status",
      );
      let expectedText;
      if (scenario === "ready") expectedText = "actual:payload";
      else if (["null", "constructed-null"].includes(scenario))
        expectedText = "";
      else if (scenario === "head-complete") expectedText = "last";
      else if (scenario === "body-complete") expectedText = "first-last";
      else if (kind === "http") expectedText = "Failed to fetch";
      else if (scenario === "head-abort")
        expectedText = "AbortError: signal is aborted without reason";
      else if (scenario === "body-abort")
        expectedText = "AbortError: The user aborted a request.";
      else if (scenario === "projection-abort")
        expectedText = "TypeError: controlled RPC text projection fault";
      else expectedText = "TypeError: Failed to fetch";
      assert.equal(
        value.text,
        expectedText,
        "semantic: exact owning body/error projection",
      );
      if (scenario === "projection-abort") {
        assert.equal(record.counts.projectionFaults, 1, "one actual Record projection property fault");
        assert(record.records.some(r => r.record === "NetResponse" && r.outcome === 5),
          "projection fault follows actual owner response head");
        assert.deepEqual(value, nativeProjectionFault.value,
          "Record projection fault equals independent native RPC helper");
      }
      if (kind === "rpc" && scenario === "body-abort")
        assert.deepEqual(value, nativeBodyAbort.value,
          "owner pending-body abort equals independent native RPC projection");
      if (kind === "rpc") {
        assert.equal(
          value.retryAfter,
          ["ready", "body-complete"].includes(scenario) ? "3" : "",
          "exact Retry-After projection",
        );
        assert.equal(
          value.commit,
          ["ready", "body-complete"].includes(scenario) ? "commit" : "",
          "exact Isonim-Commit projection",
        );
      } else if (scenario.endsWith("fail"))
        assert.deepEqual(
          value.headers,
          [],
          "HTTP failure has no response headers",
        );
      else if (scenario === "ready")
        assert(
          value.headers.some(
            (h) => h.name === "x-proof" && h.value === "native",
          ),
          "actual HTTP response header projection",
        );
      const reqs = requests.filter((r) => r.id === id);
      if (scenario === "constructed-null")
        assert.equal(
          reqs.length,
          0,
          "constructed native null-body control has no server I/O",
        );
      else
        assert(reqs.length >= 1, "actual native request reached local server");
      for (const r of reqs) {
        assert.equal(r.method, "POST");
        assert.equal(r.body, "payload");
        if (kind === "http") assert.equal(r.headers["x-duplicate"], "last");
        else {
          assert.equal(r.headers["isonim-context"], "context");
          assert.equal(r.headers["isonim-after"], "after");
          assert.equal(r.headers["idempotency-key"], "key");
        }
      }
      if (process.env.RECORD_HTTP_INVERSE === "raw-global") {
        assert.equal(
          record.records.filter((r) => r.record === "NetRequest").length,
          0,
          "raw inverse actually omits owner request",
        );
        assert.equal(
          record.records.filter((r) => r.record === "TaskReg").length,
          0,
          "raw inverse actually omits owner registration",
        );
        const negative = await page();
        const actual = await negative.evaluate(
          ({ log, url }) => {
            const a = rhOwner,
              runner = a.installReplayRuntime(window, { log }),
              ctx = a.newReplayContext(window, runner),
              fetch = a.createFrameworkReplayFetch(ctx);
            try {
              rhReplayHttp(fetch, url, "payload").catch(() => {});
            } catch (e) {}
            return runner.status();
          },
          { log: record.log, url },
        );
        writeFileSync(
          process.env.RECORD_HTTP_RESULTS + "-raw-divergence.json",
          JSON.stringify(actual, null, 2),
        );
        console.log(
          "actual raw-global mutant owner divergence " + JSON.stringify(actual),
        );
        assert.deepEqual(
          actual.divergence,
          {
            kind: "ExtraRead",
            seq: "1",
            recorded: "End{last_seq=0, reason=2}",
            actual: `NetRequest{req_id=1, api=1, method="POST", url="${base + url}", body_digest="239f59ed55e737c77147cf55ad0c1b030b6d7ee748a7426952f9b852d5a935e5"}`,
            detail: "the page made a read after the log ended",
            cause: "mismatch",
            sensitiveRead: null,
            lastCheckpoint: null,
          },
          "exact owner divergence against actual raw-global mutant log",
        );

        await negative.close();
      }
      assert.equal(
        record.records.filter((r) => r.record === "NetRequest").length,
        1,
        "semantic: one actual owner NetRequest",
      );
      assert.equal(
        record.records.filter((r) => r.record === "TaskReg" && r.kind === 4)
          .length >= 1,
        true,
        "actual network registration",
      );
      assert.equal(
        record.counts.fetch,
        1,
        "exactly one captured native fetch invocation",
      );
      assert.equal(
        record.counts.completions,
        1,
        "exactly one buffered completion",
      );
      assert.equal(
        record.counts.text,
        (scenario.startsWith("head-") && !scenario.endsWith("complete")) || scenario === "projection-abort" ? 0 : 1,
        "exactly one actual native body consumer when a head arrived",
      );
      assert(
        record.counts.receivers.every(Boolean),
        "actual native fetch/body receiver identity",
      );
      if (kind === "http")
        assert.deepEqual(
          record.resolutions[0],
          { resolve: 1, reject: 0 },
          "exactly one HTTP resolver invocation",
        );

      if (scenario === "null") {
        const refusal = record.records.find((r) => r.record === "Refusal");
        assert.deepEqual(
          refusal,
          {
            record: "Refusal",
            seq: "4",
            feature: "unrecordable-response-body",
            detail: "fetch response basic 204",
          },
          "exact existing native HTTP204 refusal",
        );
        await p.close();
        const negative = await page();
        await negative.evaluate(
          ({ log, kind, url }) => {
            const a = rhOwner,
              runner = a.installReplayRuntime(window, { log }),
              ctx = a.newReplayContext(window, runner),
              fetch = globalThis.rhUseReplayProduction ? (rpInit(ctx), null) : a.createFrameworkReplayFetch(ctx);
            globalThis.nullError = undefined;
            try {
              const pending =
                kind === "http"
                  ? (globalThis.rhUseReplayProduction ? rpHttp(url,"payload") : rhReplayHttp(fetch, url, "payload"))
                  : (globalThis.rhUseReplayProduction ? rpRpc : rhReplayRpc.bind(null,fetch))(url, "payload", null, {
                      "Isonim-After": "after",
                      "Idempotency-Key": "key",
                    });
              pending.catch((e) => (nullError = e));
            } catch (e) {
              nullError = e;
            }
          },
          { log: record.log, kind, url },
        );
        await negative.waitForFunction(
          () => __ctReplay.status().state === "diverged",
        );
        const actual = await negative.evaluate(() => __ctReplay.status());
        assert.equal(actual.divergence.kind, "NonReplayable");
        assert.equal(
          String(actual.divergence.seq),
          "4",
          "actual native204 refusal sequence",
        );
        results.push({ kind, scenario, record, negative: actual });
        await negative.close();
        console.log("PASS exact native204 Refusal/NonReplayable " + kind);
        continue;
      }
      assert(
        !record.records.some((r) => r.record === "Refusal"),
        "no hidden refusal in normal request",
      );
      const beforeCount = requests.filter((r) => r.id === id).length;
      await p.close();
      const replay = await page();
      const replayed = await replay.evaluate(
        async ({ log, kind, url, abort, projectionFault }) => {
          const a = rhOwner;
          const runner = a.installReplayRuntime(window, { log });
          const ctx = a.newReplayContext(window, runner);
          if(globalThis.rhUseReplayProduction) {
            const task=ctx.nextTaskId,request=ctx.nextReqId;globalThis.rhReplayCounts={task:0,request:0};
            ctx.nextTaskId=()=>{rhReplayCounts.task++;return task();};ctx.nextReqId=()=>{rhReplayCounts.request++;return request();};
          }
          const fetch = globalThis.rhUseReplayProduction ? (rpInit(ctx), null) : a.createFrameworkReplayFetch(ctx),
            controller = new AbortController();
          globalThis.replayController = controller;
          const NativePromise=Promise;
          if(globalThis.rhUseReplayProduction) {
            const ownerText=Response.prototype.text;
            globalThis.rhReplayObservations={text:0,receivers:[],resolutions:[],completion:0,nativePromise:false,dispatchBefore:rhDispatch()};
            Response.prototype.text=function(...args){rhReplayObservations.text++;rhReplayObservations.receivers.push(this instanceof ctx.orig.Response&&args.length===0);return ownerText.apply(this,args);};
            if(kind==='http')window.Promise=class extends NativePromise {
              constructor(executor){const cell={resolve:0,reject:0};rhReplayObservations.resolutions.push(cell);
                super((resolve,reject)=>executor(function(...args){cell.resolve++;return resolve.apply(this,args);},function(...args){cell.reject++;return reject.apply(this,args);}));}
            };
          }
          if (projectionFault)
            Object.defineProperty(Response.prototype, "text", {
              configurable: true,
              get() {
                globalThis.rhProjectionFaults = (globalThis.rhProjectionFaults || 0) + 1;
                controller.abort();
                throw new TypeError("controlled RPC text projection fault");
              },
            });
          try {
          const pending =
            kind === "http"
              ? (globalThis.rhUseReplayProduction ? rpHttp(url, "payload") : rhReplayHttp(fetch, url, "payload"))
              : (globalThis.rhUseReplayProduction ? rpRpc : rhReplayRpc.bind(null,fetch))(url, "payload", controller.signal, {
                  "Isonim-After": "after",
                  "Idempotency-Key": "key",
                });
          if(globalThis.rhUseReplayProduction) {
            rhReplayObservations.nativePromise=pending instanceof NativePromise;
            ctx.orig.promiseThen.call(pending,()=>{rhReplayObservations.completion++;},()=>{rhReplayObservations.completion++;});
          }
          // Signal abort is page work, matching the same abort decision as record;
          // no cursor/task is forced and all completion delivery is owner-controlled.
          if (abort && kind === "rpc" && !projectionFault) controller.abort();
            const value = await pending;
            return kind === "http" ? rhView(value) : value;
          } catch(e) {
            if (!globalThis.rhUseReplayProduction) throw e;
            return {__privateReplayError: {name:e.name, message:e.message, divergence:e.divergence}, status:runner.status(), pending:runner.peek()};
          } finally {if(globalThis.rhUseReplayProduction){window.Promise=NativePromise;rhReplayObservations.dispatchAfter=rhDispatch();}}
        },
        { log: record.log, kind, url, abort: scenario.endsWith("abort"), projectionFault: scenario === "projection-abort" },
      );
      if (replayMode) {
        const snapshot=await replay.evaluate(() => ({status:__ctReplay.status(), pending:__ctReplay.peek(), counts:rhReplayCounts, observations:rhReplayObservations}));
        writeFileSync(process.env.RECORD_HTTP_RESULTS+"-replay-last.json",JSON.stringify({kind,scenario,replayed,snapshot},(_,v)=>typeof v==='bigint'?String(v):v,2));
        if (process.env.REPLAY_HTTP_INVERSE === "raw-global") {
          assert.equal(snapshot.pending.record.record,"NetRequest","raw Replay bypass leaves genuine pending request");
          assert.equal(snapshot.pending.record.url,new URL(url,base).href,"exact identified pending request");
          assert.equal(snapshot.pending.seq,"1","exact pending first request sequence");
          assert.equal(String(snapshot.pending.record.req_id),"1");assert.equal(snapshot.pending.record.api,1);
          assert.equal(snapshot.pending.record.method,"POST");assert.equal(snapshot.pending.record.body_digest,"239f59ed55e737c77147cf55ad0c1b030b6d7ee748a7426952f9b852d5a935e5");
          assert.deepEqual(snapshot.counts,{task:0,request:0},"raw Replay bypass performs no owner allocation");
          assert.equal(requests.filter(r=>r.id===id).length-beforeCount,1,"raw Replay bypass actually reaches identified server");
        }
        if (process.env.REPLAY_HTTP_INVERSE === "rpc-body" && kind === "rpc") {
          assert.equal(snapshot.status.state,"diverged","actual owner rejects mismatched private Replay body");
          const digest="239f59ed55e737c77147cf55ad0c1b030b6d7ee748a7426952f9b852d5a935e5";
          assert.deepEqual(snapshot.status.divergence,{
            kind:"ArgumentMismatch",seq:"1",
            recorded:`NetRequest{req_id=1, api=1, method="POST", url="${base+url}", body_digest="${digest}"}`,
            actual:`NetRequest{req_id=1, api=1, method="POST", url="${base+url}", body_digest=""}`,
            detail:`NetRequest.body_digest differs: recorded "${digest}", the page's ""`,
            cause:"mismatch",sensitiveRead:null,lastCheckpoint:null,
          },"precise actual owner body/digest checked divergence tuple");
        }
        assert.equal(requests.filter(r=>r.id===id).length-beforeCount,0,"semantic: private Replay performs no native HTTP");
        assert.equal(snapshot.status.divergence,undefined,"semantic: private Replay body matches recorded request");
        if (kind === "rpc" && scenario.endsWith("abort"))
          assert.equal(replayed.status,record.outcome.value.status,"semantic: private Replay preserves abort projection");
      }
      assert.deepEqual(
        replayed,
        record.outcome.value,
        "semantic: actual record/replay buffered result equality",
      );
      let replayObservations;
      if(replayMode) {
        replayObservations=await replay.evaluate(()=>rhReplayObservations);
        assert.equal(replayObservations.text,(scenario.startsWith("head-")&&!scenario.endsWith("complete"))||scenario==="projection-abort"?0:1,"semantic: private Replay consumes exactly one delivered body");
        assert(replayObservations.receivers.every(Boolean),"actual private Replay body receiver and argument identity");
        assert(replayObservations.nativePromise,"private Replay returns actual native Promise");
        assert.equal(replayObservations.completion,1,"semantic: private Replay completes exactly once");
        assert.equal(replayObservations.dispatchAfter,replayObservations.dispatchBefore,"semantic: private Replay adds no public dispatch");
        if(kind==='http')assert.deepEqual(replayObservations.resolutions[0],{resolve:1,reject:0},"semantic: private Replay HTTP resolves exactly once");
      }
      await replay.waitForFunction(() =>
        ["done", "diverged"].includes(__ctReplay.status().state),
      );
      assert.equal(
        (await replay.evaluate(() => __ctReplay.status())).state,
        "done",
        "actual owned Replay DONE",
      );
      assert.equal(
        requests.filter((r) => r.id === id).length,
        beforeCount,
        "owner Replay performs no raw HTTP",
      );
      if (scenario === "projection-abort")
        assert.equal(await replay.evaluate(() => rhProjectionFaults), 1,
          "one actual Replay projection property fault");
      results.push({ kind, scenario, record, replayed, ...(replayMode ? {replayObservations} : {}) });
      await replay.close();
      console.log("PASS actual owner roundtrip " + id);
    }
  // A genuine owner context with actual native originals. The controlled fetch
  // failures/ready Response below are isolated fault/timing controls only.
  async function setup(p, mode = "native") {
    await p.evaluate((mode) => {
      const a = rhOwner,
        o = a.captureOriginals(window),
        frames = [],
        sensitive = a.sensitiveState(window),
        refused = new Set();
      const rec = new a.Recorder({
        checkpointScheme: "dom-v1",
        checkpointHash: () => a.domV1Hash(document),
        sink: {
          append: (f) => {
            if (
              globalThis.control?.failNext &&
              a.decodeRecord(f.subarray(4)).record === "NetRequest"
            ) {
              control.failNext = false;
              throw new Error("one-shot actual network sink fault");
            }
            frames.push(f);
          },
          end: (u, f) => frames.push(f),
          halt() {},
        },
      });
      rec.start(
        {
          vocab: 1,
          protocol_level: 0,
          recorder_id: "private-record-http-controls",
          framework: "",
          build_hash: "a".repeat(64),
          session_id: "1".repeat(32),
          prev_session: "",
          capabilities: "[]",
        },
        a.readEnvironment(window, o),
      );
      const native = o.fetch,
        sentinel = { nativeFailure: true };
      let calls = 0,
        receiver = true,
        lastPromise;
      o.fetch = function (...args) {
        calls++;
        receiver &&= this === window;
        if (mode === "throw") throw sentinel;
        lastPromise =
          mode === "ready"
            ? Promise.resolve(new Response("ready", { status: 201 }))
            : native.apply(this, args);
        return lastPromise;
      };
      const ctx = {
        w: window,
        rec,
        orig: o,
        sensitive,
        holes: () => a.currentSensitiveValues(window, sensitive),
        refuseOnce(feature, detail) {
          if (!rec.recording || refused.has(feature)) return;
          refused.add(feature);
          rec.guard(() => rec.emit("Refusal", { feature, detail }));
        },
      };
      globalThis.control = {
        a,
        o,
        rec,
        ctx,
        frames,
        sentinel,
        observed: () => ({ calls, receiver, lastPromise }),
      };
    }, mode);
  }
  {
    const p = await page();
    await setup(p);
    const r = await p.evaluate(() => {
      const { a, ctx, rec, o, frames } = control,
        before = {
          fetch: window.fetch,
          xhr: window.XMLHttpRequest,
          beacon: navigator.sendBeacon,
          text: Response.prototype.text,
        };
      const errors = [];
      for (const c of [
        null,
        { ...ctx, rec: {} },
        { ...ctx, holes: null },
        { ...ctx, orig: { ...o, fetch: undefined } },
      ]) {
        try {
          rhInit(c);
          errors.push(null);
        } catch (e) {
          errors.push(e.message);
        }
      }
      rhInit(ctx);
      const text = Response.prototype.text;
      rhInit(ctx);
      const same = text === Response.prototype.text;
      let conflict;
      try {
        rhInit({ ...ctx });
      } catch (e) {
        conflict = { name: e.name, message: e.message };
      }
      let mixed;
      try {
        a.createFrameworkReplayFetch({ ...ctx });
      } catch (e) {
        mixed = { name: e.name, message: e.message };
      }
      return {
        errors,
        same,
        conflict,
        mixed,
        untouched:
          window.fetch === before.fetch &&
          window.XMLHttpRequest === before.xhr &&
          navigator.sendBeacon === before.beacon,
        frames: frames.map((f) => a.decodeRecord(f.subarray(4)).record),
      };
    });
    assert(
      r.errors.every(
        (x) =>
          x ===
          "internal Record HTTP requires actual Window, Recorder, captured fetch and owner context",
      ),
    );
    assert(
      r.same && r.untouched,
      "same-context reuse and unrelated seam identity",
    );
    assert.deepEqual(r.conflict, {
      name: "TypeError",
      message: "fetch preparation belongs to another context or mode",
    });
    assert.deepEqual(r.mixed, r.conflict);
    assert.deepEqual(r.frames, ["Header", "Env"]);
    await p.close();
  }
  {
    const p = await page();
    await setup(p);
    const r = await p.evaluate(() => {
      const errors = [];
      Object.defineProperty(Response.prototype, "text", {
        value: Response.prototype.text,
        writable: false,
        configurable: false,
      });
      for (let i = 0; i < 2; i++) {
        try {
          rhInit(control.ctx);
          errors.push(null);
        } catch (e) {
          errors.push({ name: e.name, message: e.message });
        }
      }
      return errors;
    });
    assert.equal(r[0].name, "TypeError");
    assert.deepEqual(
      r[1],
      {
        name: "TypeError",
        message: "fetch preparation is incomplete or failed",
      },
      "failed factory reservation remains failed",
    );
    await p.close();
  }
  // HTTP keeps synchronous fetch faults inside its Promise executor. RPC keeps
  // the exact synchronous throw, with actual owner pre-fetch writes retained.
  for (const active of [true, false]) {
    const p = await page();
    await setup(p, "throw");
    const r = await p.evaluate(async (active) => {
      const { a, ctx, rec, frames, sentinel } = control;
      rhInit(ctx);
      if (!active) rec.end(2);
      const before = frames.length;
      let httpSync = false,
        httpError;
      try {
        await rhHttp("/fault", "x").catch((e) => {
          httpError = e;
        });
      } catch (e) {
        httpSync = true;
      }
      let rpcSync = false,
        rpcSame = false;
      try {
        rhRpc("/fault", "x", null, null);
      } catch (e) {
        rpcSync = true;
        rpcSame = e === sentinel;
      }
      return {
        httpSync,
        httpSame: httpError === sentinel,
        rpcSync,
        rpcSame,
        calls: control.observed().calls,
        receiver: control.observed().receiver,
        records: frames
          .slice(before)
          .map((f) => a.decodeRecord(f.subarray(4)).record),
      };
    }, active);
    assert.equal(
      r.httpSync,
      false,
      "semantic: HTTP synchronous fetch fault becomes rejection",
    );
    assert.equal(r.httpSame, true);
    assert.equal(
      r.rpcSync,
      true,
      "semantic: RPC synchronous fetch fault remains synchronous",
    );
    assert.equal(r.rpcSame, true);
    assert.equal(r.calls, 2);
    assert(r.receiver);
    assert.deepEqual(
      r.records,
      active ? ["NetRequest", "TaskReg", "NetRequest", "TaskReg"] : [],
      "owner pre-fetch records are retained without invented rollback",
    );
    await p.close();
  }
  {
    const p = await page();
    await setup(p, "ready");
    const r = await p.evaluate(async () => {
      rhInit(control.ctx);
      control.rec.end(2);
      const n = control.frames.length,
        sentinel = { initFailure: true };
      let sync = false,
        same = false;
      Object.defineProperty(Object.prototype, "X-Duplicate", {
        configurable: true,
        set() {
          throw sentinel;
        },
      });
      let pending;
      try {
        pending = rhHttp("/init", "x");
      } catch (e) {
        sync = true;
        same = e === sentinel;
      } finally {
        delete Object.prototype["X-Duplicate"];
      }
      if (pending)
        await pending.catch((e) => {
          same = e === sentinel;
        });
      const extra = {};
      Object.defineProperty(extra, "X-Throw", {
        enumerable: true,
        get() {
          throw sentinel;
        },
      });
      let rpcSame = false;
      try {
        rhRpc("/init", "x", null, extra);
      } catch (e) {
        rpcSame = e === sentinel;
      }
      return {
        sync,
        same,
        rpcSame,
        calls: control.observed().calls,
        quiet: n === control.frames.length,
      };
    });
    assert.equal(
      r.sync,
      false,
      "semantic: HTTP throwable init remains inside executor",
    );
    assert(r.same && r.rpcSame);
    assert.equal(r.calls, 0);
    assert(r.quiet);
    await p.close();
  }
  // Observe delegating native Promise continuations and real native body work.
  // Compare to unchanged compiled helper composition, with no fixed readiness
  // sleeps or fabricated body Promise. The extra-continuation inverse must
  // change this trace while both native results remain successful.
  {
    const p = await page();
    await setup(p, "ready");
    const r = await p.evaluate(async () => {
      rhInit(control.ctx);
      control.rec.end(2);
      const native = Promise.prototype.then,
        rows = [];
      async function trace(which) {
        const events = [];
        Promise.prototype.then = function (ok, bad) {
          events.push("then");
          return native.call(
            this,
            typeof ok === "function"
              ? function (...args) {
                  events.push("fulfilled");
                  return ok.apply(this, args);
                }
              : ok,
            typeof bad === "function"
              ? function (...args) {
                  events.push("rejected");
                  return bad.apply(this, args);
                }
              : bad,
          );
        };
        try {
          const pending =
            which === "record"
              ? rhHttp("/ready", "x")
              : rhReplayHttp(control.o.fetch, "/ready", "x");
          const result = await pending;
          return { events, value: rhView(result) };
        } finally {
          Promise.prototype.then = native;
        }
      }
      rows.push(await trace("record"));
      rows.push(await trace("direct"));
      return rows;
    });
    assert.deepEqual(r[0].value, r[1].value);
    assert.deepEqual(
      r[0].events,
      r[1].events,
      "semantic: no extra private continuation before public settlement",
    );
    await p.close();
  }
  // One actual Recorder allocates IDs across compiled native timer and network
  // operations; the fixture's Replay uses one actual owner context for both.
  {
    const p = await page();
    await setup(p);
    const r = await p.evaluate(async () => {
      const { a, ctx, o, rec, frames } = control;
      rhInit(ctx);
      rhTimerInit(window, rec, o);
      const first = rhHttp("/ready?id=shared-first", "one");
      let fired = 0;
      const timer = new Promise((resolve) =>
        rhTimer(() => {
          fired++;
          resolve();
        }),
      );
      const second = rhRpc("/ready?id=shared-second", "two", null, null);
      const [h, r] = await Promise.all([first, second, timer]);
      rec.end(2);
      const records = frames.map((f) => a.decodeRecord(f.subarray(4)));
      let raw = "";
      for (const b of a.encodeLog(records)) raw += String.fromCharCode(b);
      return {
        values: [rhView(h), r],
        fired,
        log: btoa(raw),
        registrations: records
          .filter((r) => r.record === "TaskReg")
          .map((r) => ({ id: String(r.task_id), kind: r.kind })),
        requests: records
          .filter((r) => r.record === "NetRequest")
          .map((r) => String(r.req_id)),
      };
    });
    assert.equal(r.fired, 1);
    assert.deepEqual(r.registrations.slice(0, 3), [
      { id: "1", kind: 4 },
      { id: "2", kind: 1 },
      { id: "3", kind: 4 },
    ]);
    assert.deepEqual(r.requests, ["1", "2"]);
    await p.close();
    const q = await page();
    const replayed = await q.evaluate(async (log) => {
      const a = rhOwner,
        runner = a.installReplayRuntime(window, { log }),
        ctx = a.newReplayContext(window, runner),
        fetch = globalThis.rhUseReplayProduction ? (rpInit(ctx), null) : a.createFrameworkReplayFetch(ctx);
      a.replayTimeSeams(ctx);
      let fired = 0;
      const first = globalThis.rhUseReplayProduction ? rpHttp("/ready?id=shared-first", "one") : rhReplayHttp(fetch, "/ready?id=shared-first", "one"),
        timer = new Promise((resolve) =>
          setTimeout(() => {
            fired++;
            resolve();
          }, 1),
        ),
        second = (globalThis.rhUseReplayProduction ? rpRpc : rhReplayRpc.bind(null,fetch))(
          "/ready?id=shared-second",
          "two",
          null,
          null,
        );
      const [h, r] = await Promise.all([first, second, timer]);
      return { values: [rhView(h), r], fired };
    }, r.log);
    assert.deepEqual(replayed, { values: r.values, fired: 1 });
    await q.waitForFunction(() =>
      ["done", "diverged"].includes(__ctReplay.status().state),
    );
    assert.equal((await q.evaluate(() => __ctReplay.status())).state, "done");
    await q.close();
    results.push({ shared: r });
  }

  // Existing public native/scripted backends remain authoritative while the
  // Record owner's response wrappers exist. Private completion adds no dispatch.
  {
    const p = await page();
    await setup(p);
    const r = await p.evaluate(async () => {
      rhInit(control.ctx);
      const rows = [];
      for (const scripted of [false, true])
        for (const kind of ["http", "rpc"]) {
          rhPublicSelect(scripted);
          const before = control.frames.length;
          const value = await (kind === "http"
            ? rhPublicHttp("/ready?id=ordinary-" + kind)
            : rhPublicRpc("/ready?id=ordinary-" + kind));
          rows.push({
            scripted,
            kind,
            value,
            quiet: before === control.frames.length,
          });
        }
      rhPublicSelect(true);
      const before = rhDispatch();
      const value = rhView(
        await rhHttp("/ready?id=selected-private", "payload"),
      );
      return { rows, before, after: rhDispatch(), value };
    });
    for (const row of r.rows) {
      assert.deepEqual(
        row.value,
        {
          status: row.scripted ? 218 : 207,
          text: row.scripted ? "scripted" : "actual:",
          dispatch: 1,
        },
        "ordinary selected backend and sole public dispatch",
      );
      assert(row.quiet, "foreign ordinary body must not emit owner records");
    }
    assert.equal(r.before, 0);
    assert.equal(r.after, 0, "private completion adds no dispatch");
    assert.equal(r.value.text, "actual:payload");
    await p.close();
  }
  // Nil and empty RPC bodies remain distinct init shapes. Header construction
  // order is the current owning helper's order, including extra header values.
  for (const body of [null, "", "payload"]) {
    const p = await page();
    await setup(p);
    const observed = await p.evaluate(async (body) => {
      const { ctx, rec, o } = control,
        native = o.fetch;
      let init;
      o.fetch = function (url, value) {
        init = value;
        return native.call(this, url, value);
      };
      rhInit(ctx);
      rec.end(2);
      const value = await rhRpc(
        "/ready?id=body-shape-" + String(body),
        body,
        null,
        { "Isonim-After": "after", "Idempotency-Key": "key" },
      );
      return {
        value,
        bodyPresent: Object.hasOwn(init, "body"),
        body: init.body,
        keys: Object.keys(init.headers),
        headers: init.headers,
        credentials: init.credentials,
      };
    }, body);
    assert.equal(
      observed.bodyPresent,
      body !== null,
      "nil and empty RPC body distinction",
    );
    if (body !== null) assert.equal(observed.body, body);
    assert.equal(observed.value.text, "actual:" + (body ?? ""));
    assert.deepEqual(observed.keys, [
      "X-CSRF-Token",
      "Isonim-Context",
      "Content-Type",
      "Isonim-After",
      "Idempotency-Key",
    ]);
    assert.deepEqual(observed.headers, {
      "X-CSRF-Token": "csrf",
      "Isonim-Context": "context",
      "Content-Type": "text/plain",
      "Isonim-After": "after",
      "Idempotency-Key": "key",
    });
    assert.equal(observed.credentials, "same-origin");
    await p.close();
  }

  // A real one-shot sink fault is triggered by the compiled raw operation.
  // Both stopped and faulted owner calls preserve the exact native Promise;
  // native original throws preserve the original sentinel identity as well.
  for (const terminal of ["stopped", "faulted"]) {
    for (const mode of ["native", "throw"]) {
      const p = await page();
      await setup(p, mode);
      const actual = await p.evaluate(
        async ({ terminal, mode }) => {
          const { a, ctx, rec, frames, sentinel } = control;
          rhInit(ctx);
          if (terminal === "stopped") rec.end(2);
          else {
            control.failNext = true;
            let triggered;
            try {
              triggered = rhRaw("/ready?id=fault-trigger", { method: "GET" });
            } catch (error) {
              if (error !== sentinel) throw error;
            }
            if (triggered) await triggered;
            if (rec.recording)
              throw Error("actual sink fault did not close Recorder");
          }
          const before = frames.length;
          let pending, caught;
          try {
            pending = rhRaw("/ready?id=terminal-" + terminal, {
              method: "GET",
            });
          } catch (error) {
            caught = error;
          }
          const exactPromise = pending === control.observed().lastPromise;
          const response = pending ? await pending : undefined;
          const body = response ? await response.text() : undefined;
          return {
            exactPromise,
            nativePromise: pending instanceof ctx.orig.Promise,
            sameThrow: caught === sentinel,
            body,
            recording: rec.recording,
            quiet: before === frames.length,
            receiver: control.observed().receiver,
            refusals: frames
              .map((f) => a.decodeRecord(f.subarray(4)))
              .filter((r) => r.record === "Refusal")
              .map((r) => ({ feature: r.feature, detail: r.detail })),
          };
        },
        { terminal, mode },
      );
      assert.equal(actual.recording, false);
      assert(actual.quiet && actual.receiver);
      if (mode === "native") {
        assert(
          actual.exactPromise && actual.nativePromise,
          "semantic: terminal raw fetch returns exact native Promise",
        );
        assert.equal(actual.body, "actual:");
      } else assert(actual.sameThrow, "terminal raw original throw identity");
      assert.deepEqual(
        actual.refusals,
        terminal === "faulted"
          ? [
              {
                feature: "recorder-fault",
                detail: "Error: one-shot actual network sink fault",
              },
            ]
          : [],
        "exact actual sink fault versus ordinary stopped state",
      );
      results.push({ terminal, mode, actual });
      await p.close();
    }
  }
  // Delegating native descriptor observation causes actual same-context
  // reentry while owner preparation holds its reservation. The outer setup
  // still succeeds, and the same actual context remains usable afterwards.
  {
    const p = await page();
    await setup(p);
    const actual = await p.evaluate(async () => {
      const native = Object.getOwnPropertyDescriptor;
      let attempted = false,
        inner;
      Object.getOwnPropertyDescriptor = function (owner, name) {
        if (!attempted && owner === Response.prototype) {
          attempted = true;
          try {
            rhInit(control.ctx);
          } catch (error) {
            inner = { name: error.name, message: error.message };
          }
        }
        return native.call(this, owner, name);
      };
      try {
        rhInit(control.ctx);
      } finally {
        Object.getOwnPropertyDescriptor = native;
      }
      const response = rhView(
        await rhHttp("/ready?id=reentry-positive", "payload"),
      );
      return { attempted, inner, response };
    });
    assert(actual.attempted, "actual owner prototype preparation observed");
    assert.deepEqual(actual.inner, {
      name: "TypeError",
      message: "fetch preparation is incomplete or failed",
    });
    assert.equal(actual.response.text, "actual:payload");
    results.push({ reentry: actual });
    await p.close();
  }
  // Custom clock selection and NE FakeAsync priority coexist with prepared
  // Response wrappers. Scripted responses are the supported backend-control
  // seam, not a replacement for any actual network or owner algorithm.
  {
    const p = await page();
    await setup(p);
    const actual = await p.evaluate(async () => {
      rhInit(control.ctx);
      const rows = [];
      for (const kind of ["http", "rpc"]) {
        rhCustomSelect();
        const before = control.frames.length;
        const value = await (kind === "http"
          ? rhPublicHttp("/not-network")
          : rhPublicRpc("/not-network"));
        rows.push({ value, quiet: before === control.frames.length });
      }
      rhCustomSelect();
      const frameCount = control.frames.length;
      rhFakeStart();
      let initial, advanced, privateValue, after;
      try {
        initial = rhFakeState();
        rhFakeAdvance();
        advanced = rhFakeState();
        if (control.frames.length !== frameCount)
          throw Error("FakeAsync emitted owner records");
        privateValue = rhView(
          await rhHttp("/ready?id=fake-selected-private", "payload"),
        );
        after = rhFakeState();
      } finally {
        rhFakeEnd();
      }
      return { rows, initial, advanced, privateValue, after };
    });
    for (const row of actual.rows) {
      assert.deepEqual(row.value, { status: 219, text: "custom", dispatch: 1 });
      assert(row.quiet, "custom public result remains outside owner recording");
    }
    assert.deepEqual(actual.initial, {
      selected: true,
      milliseconds: 17,
      fired: 0,
      dispatch: 0,
    });
    assert.deepEqual(actual.advanced, {
      selected: true,
      milliseconds: 19,
      fired: 1,
      dispatch: 0,
    });
    assert.deepEqual(
      actual.after,
      actual.advanced,
      "private network does not select/advance fake or custom clocks or dispatch",
    );
    assert.equal(actual.privateValue.text, "actual:payload");
    results.push({ authority: actual });
    await p.close();
  }

  if (replayMode) {
    const {runReplayHttpControls}=await import("./replay_http_controls.mjs");
    await runReplayHttpControls({assert,page,results,requests,base,recordSetup:setup});
  }
  writeFileSync(
    process.env.RECORD_HTTP_RESULTS,
    JSON.stringify(results, null, 2) + "\n",
  );
} finally {
  await browser.close();
  for (const s of slots.values()) s.destroy();
  server.closeAllConnections();
  await new Promise((r) => server.close(r));
}
