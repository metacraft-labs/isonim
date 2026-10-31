/** Real local HTTP config/batches, real Chromium, compiled Nim and owner Recorder/
 * HttpBatchTransport/codecs. The server is the explicitly allowed local ingest
 * stub. Delegating prototype observations witness frame/seq/receiver identity;
 * they never replace batching, network or parsing. Narrow config/rewriter/native
 * traps are deliberate fault controls, never substitutes for a transport.
 */
import assert from "node:assert/strict";
import { readFileSync, writeFileSync, mkdirSync } from "node:fs";
import { createRequire } from "node:module";
import { createServer } from "node:http";
const root = process.cwd(),
  artifact = process.env.CT_ARTIFACT;
assert(artifact, "CT_ARTIFACT required");
for (const k of ["UPLOAD_BUNDLE", "UPLOAD_CONTEXT", "UPLOAD_RESULTS"])
  assert(process.env[k], k + " required: current input");
const req = createRequire(artifact + "/packages/boundary-shim/package.json");
const { build } = req("esbuild"),
  fmt = req("@codetracer/boundary-format");
const { chromium } = await import(
  root + "/tests/browser/node_modules/playwright/index.mjs"
);
const imports = `import {Recorder,numberToBits} from '@codetracer/boundary-shim/dist/browser/recorder.js';
import {captureOriginals} from '@codetracer/boundary-shim/dist/browser/originals.js';
import {readEnvironment} from '@codetracer/boundary-shim/dist/browser/install.js';
import {domV1Hash} from '@codetracer/boundary-shim/dist/browser/dom-v1.js';
import {HttpBatchTransport} from '@codetracer/runtime-browser/dist/batch-transport.js';
import {sanitizeRecord,rescrubFrame} from '@codetracer/boundary-shim/dist/browser/record-scrub.js';
import {NO_SCRUB_LISTS} from '@codetracer/boundary-shim/dist/browser/scrub.js';
import {decodeRecord} from '@codetracer/boundary-format';
globalThis.uploadApi={Recorder,numberToBits,captureOriginals,readEnvironment,domV1Hash,HttpBatchTransport,sanitizeRecord,rescrubFrame,NO_SCRUB_LISTS,decodeRecord};`;
const bundled = await build({
  stdin: {
    resolveDir: artifact,
    contents:
      imports +
      readFileSync(process.env.UPLOAD_BUNDLE, "utf8") +
      "\nObject.assign(globalThis,{ruInit,ruSink,ruAttach,ruComplete,ruConsent,ruFlush,ruStatus,ruClock});",
  },
  bundle: true,
  platform: "browser",
  format: "iife",
  write: false,
  metafile: true,
});
const contextSource = readFileSync(process.env.UPLOAD_CONTEXT, "utf8");
writeFileSync(
  process.env.UPLOAD_RESULTS + "-metafile.json",
  JSON.stringify(bundled.metafile, null, 2),
);
const receipts = new Map();
const server = createServer(async (q, s) => {
  const u = new URL(q.url, "http://localhost"),
    parts = u.pathname.split("/"),
    id = parts[1],
    mode = parts[2],
    action = parts[3];
  if (!action) {
    s.end("<!doctype html><main>Private upload</main>");
    return;
  }
  const r = receipts.get(id);
  assert(r, "unexpected local ingest request");
  if (action === "audit") {
    s.setHeader("Content-Type", "application/json");
    s.end(
      JSON.stringify({
        requests: r.requests.length,
        held: r.held === true,
        refusalSeen: r.batches.some((b) =>
          b.records.some((x) => x.record === "Refusal"),
        ),
      }),
    );
    return;
  }
  if (action === "release") {
    assert.equal(r.held, true, "real final batch must be held before release");
    r.released = true;
    r.release();
    s.end("released");
    return;
  }
  r.requests.push({ method: q.method, path: q.url, headers: q.headers });
  if (action === "config") {
    if (mode === "config403") {
      s.statusCode = 403;
      s.end("forbidden");
      return;
    }
    if (mode === "malformed") {
      s.end("bad JSON");
      return;
    }
    const enabled = !["disabled", "async-callback-throw"].includes(mode);
    s.setHeader("Content-Type", "application/json");
    s.end(
      JSON.stringify({
        enabled,
        sampling_rate: 1,
        consent_required: mode === "config-consent",
        scrub_headers: [],
        scrub_query_keys: ["private"],
      }),
    );
    return;
  }
  assert.equal(action, "batches");
  const chunks = [];
  for await (const c of q) chunks.push(c);
  const bytes = Buffer.concat(chunks),
    parsed = fmt.parseBatch(bytes);
  r.batches.push({
    bytes: bytes.toString("base64"),
    envelope: parsed.envelope,
    records: parsed.records,
  });
  if (mode === "delayed" && parsed.envelope.final) {
    r.held = true;
    await new Promise((resolve) => {
      r.release = resolve;
    });
    r.held = false;
  }
  s.setHeader("Content-Type", "application/json");
  s.end("{}");
});
await new Promise((resolve) => server.listen(0, "127.0.0.1", resolve));
const url = "http://127.0.0.1:" + server.address().port,
  all = [];
let browser;
async function run(mode, code = bundled.outputFiles[0].text) {
  const id = String(all.length + 1),
    receipt = { id, mode, requests: [], batches: [] };
  receipts.set(id, receipt);
  const ctx = await browser.newContext();
  const page = await ctx.newPage();
  await page.goto(url);
  await page.addScriptTag({ content: contextSource });
  assert(await page.evaluate(() => !!xrReadBootContext));
  await page.addScriptTag({ content: code });
  const result = await page.evaluate(
    async ({ mode, base }) => {
      const a = uploadApi,
        native = a.captureOriginals(window),
        observed = [],
        callbacks = [],
        traps = { fetch: 0, set: 0, add: 0 },
        sentinel = { disabledThrow: true };
      const delay = (ms) =>
        new native.Promise((resolve) =>
          native.setTimeout.call(window, resolve, ms),
        );
      async function waitFor(f, label) {
        for (let n = 0; n < 200; n++) {
          if (f()) return;
          await delay(5);
        }
        throw Error("native observation deadline " + label);
      }
      if (mode === "dnt")
        Object.defineProperty(navigator, "doNotTrack", {
          configurable: true,
          value: "1",
        });
      if (mode === "gpc")
        Object.defineProperty(navigator, "globalPrivacyControl", {
          configurable: true,
          value: true,
        });
      // All-present captured originals retain actual realm functions. Optional absent
      // properties deliberately follow owner fallback and do not promise absence.
      const supplied = { fetch: 0, set: 0, clear: 0, add: 0, receivers: [] };
      const originals = {
        ...native,
        fetch: function (...args) {
          supplied.fetch++;
          supplied.receivers.push(this === window);
          return native.fetch.apply(this, args);
        },
        setTimeout: function (...args) {
          supplied.set++;
          supplied.receivers.push(this === window);
          return native.setTimeout.apply(this, args);
        },
        clearTimeout: function (...args) {
          supplied.clear++;
          supplied.receivers.push(this === window);
          return native.clearTimeout.apply(this, args);
        },
        addEventListener: function (...args) {
          supplied.add++;
          supplied.receivers.push(this === window || this === document);
          return native.addEventListener.apply(this, args);
        },
      };
      if (mode === "optional") {
        delete originals.sendBeacon;
        delete originals.getEntriesByType;
        delete originals.visibilityState;
      }
      const oldAppend = a.HttpBatchTransport.prototype.append,
        oldEnd = a.HttpBatchTransport.prototype.end,
        oldHalt = a.HttpBatchTransport.prototype.halt;
      let transport,
        realEndPromise,
        haltCalls = 0;
      const expected = [];
      let expectedEnd;
      a.HttpBatchTransport.prototype.append = function (f, seq) {
        transport = this;
        observed.push({
          kind: a.decodeRecord(f.subarray(4)).record,
          type: typeof seq,
          seq: seq === undefined ? null : String(seq),
          frame: f instanceof Uint8Array,
          identity: expected.at(-1)?.f === f,
          seqIdentity: expected.at(-1)?.s === seq,
        });
        return oldAppend.call(this, f, seq);
      };
      a.HttpBatchTransport.prototype.end = function (u, f) {
        transport = this;
        observed.push({
          kind: "sink-End",
          unloading: u,
          frame: f instanceof Uint8Array,
          identity: expectedEnd?.f === f,
          unloadingIdentity: expectedEnd?.u === u,
        });
        realEndPromise = oldEnd.call(this, u, f);
        return realEndPromise;
      };
      a.HttpBatchTransport.prototype.halt = function () {
        haltCalls++;
        return oldHalt.call(this);
      };
      let rec;
      const opts = {
        ingest: base,
        sessionId: "1".repeat(32),
        buildHash: "a".repeat(64),
        consentRequired: [
          "consent-yes",
          "consent-bool",
          "consent-no",
          "consent-throw",
          "consent-reject",
        ].includes(mode),
        onDisabled: function (reason) {
          callbacks.push({
            reason,
            receiver: this instanceof a.HttpBatchTransport,
            halted: rec === undefined ? null : !rec.recording,
          });
          if (["callback-throw", "async-callback-throw"].includes(mode))
            throw sentinel;
        },
      };
      if (mode === "invalid-id" || mode === "callback-throw")
        opts.sessionId = "bad";
      if (mode === "invalid-build") opts.buildHash = "bad";
      let lists = a.NO_SCRUB_LISTS;
      opts.onConfig = function (config) {
        if (mode === "rewriter-throw")
          return () => {
            throw sentinel;
          };
        lists = {
          headers: config.scrubHeaders,
          queryKeys: config.scrubQueryKeys,
        };
        return (f) => a.rescrubFrame(f, lists);
      };
      // Actual transport's originals must survive these independently witnessed live
      // replacements; construction and all network requests still use native calls.
      window.fetch = function () {
        traps.fetch++;
        throw Error("late live fetch");
      };
      window.setTimeout = function () {
        traps.set++;
        throw Error("late live timer");
      };
      window.addEventListener = function () {
        traps.add++;
        throw Error("late live listener");
      };
      for (const fn of [
        () => window.fetch("/trap"),
        () => window.setTimeout(() => {}, 0),
        () => window.addEventListener("x", () => {}),
      ])
        try {
          fn();
        } catch {}
      if (mode === "invalid-linkage") {
        const missing = [
          "setTimeout",
          "clearTimeout",
          "Promise",
          "promiseThen",
          "mathRandom",
        ].map((k) => {
          const o = { ...native };
          delete o[k];
          return [window, o, opts];
        });
        const invalid = [];
        for (const args of [
          [{}, native, opts],
          [window, {}, opts],
          [window, native, null],
          ...missing,
        ]) {
          try {
            ruInit(...args);
            invalid.push("accepted");
          } catch (e) {
            invalid.push(e.name);
          }
        }
        return { invalid, traps, supplied };
      }
      const index = ruInit(window, originals, opts),
        sink = ruSink(index),
        stable = sink === ruSink(index);
      let premature = "";
      try {
        ruComplete(index);
      } catch (e) {
        premature = e.message;
      }
      rec = new a.Recorder({
        checkpointScheme: "dom-v1",
        checkpointHash: () => a.domV1Hash(document),
        sanitize: (r) => a.sanitizeRecord(r, lists, () => []),
        sink: {
          append(f, s) {
            expected.push({ f, s });
            return sink.append(f, s);
          },
          end(u, f) {
            expectedEnd = { u, f };
            return sink.end(u, f);
          },
          halt() {
            return sink.halt();
          },
        },
      });
      const invalidAttach = [];
      for (const r of [null, {}])
        try {
          ruAttach(index, r);
          invalidAttach.push("accepted");
        } catch (e) {
          invalidAttach.push(e.name);
        }
      ruAttach(index, rec);
      ruAttach(index, rec);
      let conflict = "";
      try {
        ruAttach(
          index,
          new a.Recorder({
            checkpointScheme: "dom-v1",
            checkpointHash: () => a.domV1Hash(document),
          }),
        );
      } catch (e) {
        conflict = e.message;
      }
      const attachedActive = rec.recording;
      const header = {
        vocab: 1,
        protocol_level: 0,
        recorder_id: "private-upload",
        framework: "",
        build_hash: "a".repeat(64),
        session_id: "1".repeat(32),
        prev_session: "",
        capabilities: "[]",
      };
      rec.start(header, a.readEnvironment(window, native));
      if (
        [
          "consent-yes",
          "consent-bool",
          "consent-no",
          "consent-throw",
          "consent-reject",
        ].includes(mode)
      ) {
        await delay(30);
        const before = ruStatus(index).state;
        const beforeRequests = await (
          await native.fetch.call(window, base + "/audit")
        ).json();
        if (beforeRequests.requests !== 0)
          throw Error("pre-consent native server request count");
        let called = 0;
        let resolveConsent;
        const pendingConsent = new native.Promise(
          (resolve) => (resolveConsent = resolve),
        );
        ruConsent(index, () => {
          called++;
          if (mode === "consent-throw") throw sentinel;
          if (mode === "consent-reject") return native.Promise.reject(sentinel);
          return mode === "consent-yes"
            ? pendingConsent
            : mode === "consent-bool";
        });
        if (mode === "consent-yes") {
          await delay(30);
          const pendingRequests = await (
            await native.fetch.call(window, base + "/audit")
          ).json();
          if (pendingRequests.requests !== 0)
            throw Error("pending-consent native server request count");
          resolveConsent(true);
        }
        if (before !== "waiting-for-consent" || called !== 1)
          throw Error("consent immediate callback/state");
      }
      if (mode === "config-consent") {
        await waitFor(
          () => ruStatus(index).state === "waiting-for-consent",
          "config consent",
        );
        ruConsent(index, () => true);
      }
      const offModes = [
        "dnt",
        "gpc",
        "invalid-id",
        "invalid-build",
        "callback-throw",
        "async-callback-throw",
        "disabled",
        "malformed",
        "config403",
        "consent-no",
        "consent-throw",
        "consent-reject",
        "rewriter-throw",
      ];
      if (offModes.includes(mode)) {
        await waitFor(() => ruStatus(index).state === "off", "off");
        const activeAtOff = rec.recording;
        const before = observed.length;
        rec.start(header, a.readEnvironment(window, native));
        rec.emit("Clock", { src: 2, bits: a.numberToBits(99) });
        rec.end(2);
        ruFlush(index);
        await delay(30);
        return {
          stable,
          premature,
          invalidAttach,
          conflict,
          attachedActive,
          active: rec.recording,
          activeAtOff,
          callbacks,
          observed,
          traps,
          supplied,
          status: ruStatus(index),
          afterOffWrites: observed.length - before,
          haltCalls,
        };
      }
      if (mode === "scrub")
        rec.emit("Navigation", {
          kind: 1,
          url: base + "?private=secret",
          state: "null",
        });
      await waitFor(
        () => ["open", "off"].includes(ruStatus(index).state),
        "open or precise off",
      );
      if (ruStatus(index).state === "off")
        return { traps, supplied, status: ruStatus(index) };
      const clock = ruClock(window, rec, native);
      if (typeof clock !== "number") throw Error("actual fixed clock");
      if (mode === "fault") {
        rec.injectEncoderFault();
        ruClock(window, rec, native);
        ruFlush(index);
        let refusalReceived = false;
        for (let n = 0; n < 200; n++) {
          const audit = await (
            await native.fetch.call(window, base + "/audit")
          ).json();
          if (audit.refusalSeen) {
            refusalReceived = true;
            break;
          }
          await delay(5);
        }
        if (!refusalReceived)
          throw Error(
            "actual local server did not receive the strict Refusal frame",
          );
        return {
          stable,
          premature,
          invalidAttach,
          conflict,
          observed,
          traps,
          supplied,
          callbacks,
          haltCalls,
          active: rec.recording,
          status: ruStatus(index),
        };
      }
      rec.end(2, mode === "unloading");
      const complete = ruComplete(index);
      let settled = false;
      complete.then(() => (settled = true));
      let heldObserved = false;
      if (mode === "delayed") {
        for (let n = 0; n < 200; n++) {
          const audit = await (
            await native.fetch.call(window, base + "/audit")
          ).json();
          if (audit.held) {
            heldObserved = true;
            break;
          }
          await delay(5);
        }
        if (!heldObserved)
          throw Error("actual final response was not held by local server");
      }
      // This observation precedes the only release path: the server cannot
      // acknowledge the final batch yet, regardless of host scheduling delays.
      const early = settled;
      if (mode === "delayed")
        await native.fetch.call(window, base + "/release");
      await complete;
      const same = complete === ruComplete(index),
        actual = complete === realEndPromise;
      rec.end(2);
      rec.emit("Clock", { src: 2, bits: a.numberToBits(7) });
      await delay(20);
      return {
        stable,
        premature,
        invalidAttach,
        conflict,
        observed,
        traps,
        supplied,
        callbacks,
        early,
        heldObserved,
        same,
        actual,
        active: rec.recording,
        status: ruStatus(index),
        haltCalls,
      };
    },
    { mode, base: url + "/" + id + "/" + mode },
  );
  receipt.result = result;
  all.push(receipt);
  await ctx.close();
  const semantic = (condition, label) =>
    assert(condition, "upload semantic: " + label);
  semantic(
    JSON.stringify(result.traps) ===
      JSON.stringify({ fetch: 1, set: 1, add: 1 }),
    "captured transport originals",
  );
  if (mode === "invalid-linkage") {
    assert.deepEqual(result.invalid, Array(8).fill("TypeError"));
    return;
  }
  semantic(result.stable, "stable sink");
  semantic(
    result.premature.includes("no End completion"),
    "premature completion",
  );
  assert.deepEqual(result.invalidAttach, ["TypeError", "TypeError"]);
  semantic(
    result.conflict.includes("already attached"),
    "conflicting attachment",
  );
  const offModes = [
    "dnt",
    "gpc",
    "invalid-id",
    "invalid-build",
    "callback-throw",
    "async-callback-throw",
    "disabled",
    "malformed",
    "config403",
    "consent-no",
    "consent-throw",
    "consent-reject",
    "rewriter-throw",
  ];
  if (offModes.includes(mode)) {
    if (mode === "config403")
      semantic(
        result.callbacks[0]?.reason === "config answered 403",
        "actual HTTP config rejection",
      );
    semantic(
      result.status.state === "off" && !result.active && !result.activeAtOff,
      "disabled recorder halted",
    );
    semantic(
      result.callbacks.length === 1 && result.callbacks[0].receiver,
      "disabled callback receiver/count",
    );
    semantic(
      result.callbacks[0].halted !== false,
      "halt before disabled callback",
    );
    semantic(result.afterOffWrites === 0, "no writes after off");
    semantic(receipt.batches.length === 0, "no disabled upload");
    if (
      ["dnt", "gpc", "invalid-id", "invalid-build", "callback-throw"].includes(
        mode,
      )
    ) {
      semantic(!result.attachedActive, "synchronous off attachment halted");
      semantic(
        receipt.requests.length === 0,
        "synchronous rejection no requests",
      );
    }
    return;
  }
  if (mode !== "fault") {
    const expectedKinds =
      mode === "scrub"
        ? ["Header", "Env", "Navigation", "Clock", "Checkpoint", "sink-End"]
        : ["Header", "Env", "Clock", "Checkpoint", "sink-End"];
    semantic(
      JSON.stringify(result.observed.map((x) => x.kind)) ===
        JSON.stringify(expectedKinds),
      "exact forwarding order",
    );
  }
  semantic(
    result.supplied.fetch === receipt.requests.length &&
      result.supplied.fetch > 0 &&
      result.supplied.add === 2 &&
      result.supplied.receivers.every(Boolean),
    "supplied native originals used",
  );
  if (mode === "basic")
    semantic(
      result.supplied.set > 0 && result.supplied.clear > 0,
      "supplied native timer originals used",
    );
  semantic(
    result.observed.length > 0 &&
      result.observed.every((x) => x.frame && x.identity),
    "exact native frame identity",
  );
  semantic(
    result.observed
      .filter((x) => x.kind !== "sink-End")
      .every((x) => x.seqIdentity),
    "exact native sequence identity",
  );
  semantic(
    result.observed
      .filter((x) => x.kind === "Clock" || x.kind === "Checkpoint")
      .every((x) => x.type === "bigint"),
    "native bigint sequence forwarding",
  );
  semantic(
    result.observed
      .filter((x) => x.kind === "Header" || x.kind === "Env")
      .every((x) => x.type === "undefined"),
    "header env undefined sequence forwarding",
  );
  const records = receipt.batches.flatMap((x) => x.records),
    kinds = records.map((x) => x.record);
  if (mode === "fault") {
    semantic(
      !result.active && result.haltCalls === 1,
      "fault sink halt forwarding",
    );
    semantic(
      receipt.batches.every((x) => !x.envelope.final),
      "fault never final",
    );
    semantic(
      kinds.includes("Refusal") && !kinds.includes("End"),
      "fault strict partial refusal",
    );
    return;
  }
  const forwardKinds =
    mode === "scrub"
      ? ["Header", "Env", "Navigation", "Clock", "Checkpoint", "sink-End"]
      : ["Header", "Env", "Clock", "Checkpoint", "sink-End"];
  semantic(
    JSON.stringify(result.observed.map((x) => x.kind)) ===
      JSON.stringify(forwardKinds),
    "exact forwarding order",
  );
  const seqs = result.observed
    .filter((x) => x.type === "bigint")
    .map((x) => x.seq);
  semantic(
    JSON.stringify(seqs) ===
      JSON.stringify(mode === "scrub" ? ["1", "2", "3"] : ["1", "2"]),
    "exact forwarded sequence values",
  );
  semantic(
    result.observed.at(-1).unloading === (mode === "unloading") &&
      result.observed.at(-1).unloadingIdentity,
    "exact End unloading forwarding",
  );
  semantic(result.actual && result.same, "actual stable completion promise");
  if (mode === "delayed")
    semantic(
      result.heldObserved && receipt.released === true && !result.early,
      "completion awaits final acknowledgement",
    );
  semantic(
    JSON.stringify(kinds) ===
      JSON.stringify(
        mode === "scrub"
          ? ["Header", "Env", "Navigation", "Clock", "Checkpoint", "End"]
          : ["Header", "Env", "Clock", "Checkpoint", "End"],
      ),
    "exact complete log including final checkpoint",
  );
  semantic(
    receipt.batches.filter((x) => x.envelope.final).length === 1,
    "exact final batch",
  );
  semantic(
    result.status.state === "ended" && !result.active,
    "normal terminal state",
  );
  semantic(records.at(-1).reason === 2, "End stop reason");
  const log = fmt.encodeLog(records);
  assert.deepEqual(fmt.encodeLog(fmt.decodeLog(log).records), log); // actual complete-log stream validation
  for (let n = 0; n < receipt.batches.length; n++) {
    const e = receipt.batches[n].envelope;
    assert.equal(e.batch_seq, n);
    assert.equal(e.session_id, "1".repeat(32));
    assert.equal(e.build_hash, "a".repeat(64));
    assert.deepEqual(e.dropped, []);
  }
  if (mode === "scrub")
    semantic(
      records.find((x) => x.record === "Navigation").url ===
        url + "/" + id + "/scrub?private=<scrubbed>",
      "held frame owner scrubbing",
    );
}
try {
  browser = await chromium.launch({
    headless: true,
    executablePath: process.env.PLAYWRIGHT_CHROMIUM_EXECUTABLE || undefined,
    args: ["--no-sandbox"],
  });
  const modes = process.env.UPLOAD_MODE
    ? [process.env.UPLOAD_MODE]
    : [
        "basic",
        "delayed",
        "unloading",
        "optional",
        "invalid-linkage",
        "dnt",
        "gpc",
        "invalid-id",
        "invalid-build",
        "callback-throw",
        "async-callback-throw",
        "disabled",
        "malformed",
        "config403",
        "consent-yes",
        "consent-bool",
        "consent-no",
        "consent-throw",
        "consent-reject",
        "config-consent",
        "rewriter-throw",
        "scrub",
        "fault",
      ];
  if (process.env.UPLOAD_COMPANION) {
    const companion = (
      await build({
        stdin: {
          resolveDir: artifact,
          contents:
            imports +
            readFileSync(process.env.UPLOAD_COMPANION, "utf8") +
            "\nObject.assign(globalThis,{ruInit,ruSink,ruAttach,ruComplete,ruConsent,ruFlush,ruStatus,ruClock});",
        },
        bundle: true,
        platform: "browser",
        format: "iife",
        write: false,
      })
    ).outputFiles[0].text;
    await run(modes[0], companion);
    console.log("upload inverse actual baseline companion PASS");
  }
  for (const mode of modes) {
    await run(mode);
    console.log("upload real owner " + mode + " PASS");
  }
  console.log("upload real owner integration PASS");
} finally {
  writeFileSync(
    process.env.UPLOAD_RESULTS,
    JSON.stringify(all, (_, v) => (typeof v === "bigint" ? String(v) : v), 2) +
      "\n",
  );
  await browser?.close();
  await new Promise((resolve) => server.close(resolve));
}
