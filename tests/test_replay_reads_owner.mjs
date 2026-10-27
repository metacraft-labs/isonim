/** Internal partial read foundation; actual owner artifact required. Deliberate
 * original env context is explicit configuration, NOT archive reconstruction.
 * Real platform traps discriminate raw fallback; no fake cursor/provider. */
import assert from "node:assert/strict";
import { readFileSync } from "node:fs";
import { createRequire } from "node:module";
import { createServer } from "node:http";
const root = process.cwd();
const { chromium } = await import(
  root + "/tests/browser/node_modules/playwright/index.mjs"
);
const artifact = process.env.CT_ARTIFACT;
assert(artifact, "actual owner artifact required");
const require = createRequire(
  artifact + "/packages/boundary-shim/package.json",
);
const esbuild = require("esbuild");
const owned = (
  await esbuild.build({
    stdin: {
      resolveDir: artifact,
      contents: `
import {Recorder,numberToBits} from '@codetracer/boundary-shim/dist/browser/recorder.js';
import {captureOriginals} from '@codetracer/boundary-shim/dist/browser/originals.js';
import {readEnvironment} from '@codetracer/boundary-shim/dist/browser/install.js';
import {domV1Hash} from '@codetracer/boundary-shim/dist/browser/dom-v1.js';
import {encodeLog,decodeRecord} from '@codetracer/boundary-format';
import {installReplayRuntime} from '@codetracer/boundary-replay/dist/browser/runtime.js';
globalThis.xrActualReadLog=(mode)=>{
 const orig=captureOriginals(window),frames=[],samples=[];
 localStorage.removeItem('missing');localStorage.setItem('empty','');localStorage.setItem('value','recorded-string');
 document.cookie='xr=original;path=/';
 const rec=new Recorder({checkpointScheme:'dom-v1',checkpointHash:()=>domV1Hash(document),sink:{append(f){frames.push(f);},end(){},halt(){}}});
 rec.start({vocab:1,protocol_level:0,recorder_id:'internal-read-foundation',framework:'',build_hash:'a'.repeat(64),session_id:'1'.repeat(32),prev_session:'',capabilities:'[]'},readEnvironment(window,orig));
 if(mode==='positive'||mode==='mutant'){
   for(let i=0;i<2;i++){let value=orig.performanceNow.call(performance);samples.push(value);rec.emit('Clock',{src:2,bits:numberToBits(value)});}
   for(const key of ['missing','empty','value']){const value=orig.storageGetItem.call(localStorage,key);rec.emit('StorageRead',{area:1,key,present:value===null?0:1,value:value??''});}
   rec.emit('StorageRead',{area:3,key:'',present:1,value:document.cookie});
   for(const key of ['missing','empty']){const value=orig.storageGetItem.call(localStorage,key);rec.emit('StorageRead',{area:1,key,present:value===null?0:1,value:value??''});}
 }else if(mode==='source-mismatch')rec.emit('Clock',{src:3,bits:numberToBits(Date.now())});
 else rec.emit('StorageRead',{area:mode==='area-mismatch'?2:1,key:'value',present:1,value:orig.storageGetItem.call(localStorage,'value')});
 rec.end(2);const records=frames.map(f=>decodeRecord(f.subarray(4))),log=encodeLog(records);let raw='';for(const b of log)raw+=String.fromCharCode(b);
 const replay=mode==='missing-runtime'?null:installReplayRuntime(window,{log:btoa(raw)});
 globalThis.xrReadNativeAdd=EventTarget.prototype.addEventListener;
 const counts={date:0,performance:0,crypto:0,storage:0,write:0,cookie:0,layout:0,history:0,timer:0,frame:0,fetch:0,listener:0,dispatch:0};
 const count=(name)=>{counts[name]++;throw new Error('RAW '+name);};
 const NativeDate=Date;window.Date=class extends NativeDate{constructor(...args){if(!args.length)count('date');super(...args);}};
 performance.now=()=>count('performance');crypto.getRandomValues=()=>count('crypto');
 Storage.prototype.getItem=function(key){counts.storage++;return 'RAW-'+key;};Storage.prototype.setItem=()=>count('write');
 Object.defineProperty(document,'cookie',{get:()=>count('cookie'),set:()=>count('write'),configurable:true});
 window.matchMedia=()=>count('layout');Element.prototype.getBoundingClientRect=()=>count('layout');
 history.pushState=()=>count('history');history.replaceState=()=>count('history');
 window.setTimeout=()=>count('timer');window.setInterval=()=>count('timer');window.clearTimeout=()=>count('timer');
 window.requestAnimationFrame=()=>count('frame');window.cancelAnimationFrame=()=>count('frame');window.fetch=()=>count('fetch');
 EventTarget.prototype.addEventListener=()=>count('listener');EventTarget.prototype.removeEventListener=()=>count('listener');EventTarget.prototype.dispatchEvent=()=>count('dispatch');
 globalThis.xrReadCounts=counts;return {samples,cookie:'xr=original'};
};`,
    },
    bundle: true,
    platform: "browser",
    format: "iife",
    write: false,
  })
).outputFiles[0].text;
const server = createServer((req, res) =>
  res.end('<!doctype html><main id="root">Internal read foundation</main>'),
);
await new Promise((r) => server.listen(0, "127.0.0.1", r));
let browser;
try {
  browser = await chromium.launch({
    executablePath: process.env.PLAYWRIGHT_CHROMIUM_EXECUTABLE,
  });
  const bundle = readFileSync(
    process.env.REPLAY_READS_BUNDLE || root + "/build/replay-reads.js",
    "utf8",
  );
  const capture = readFileSync(root + "/build/replay-reads-context.js", "utf8");
  for (const file of [
    "replay-reads-context.js",
    "replay-reads-context-recordable.js",
  ]) {
    const ordinary = readFileSync(root + "/build/" + file, "utf8");
    for (const leaked of [
      "guardInstalled",
      "newInternalReadReplay",
      "readReplayStorage",
      "readReplayViewport",
      "viewportRead",
      "readReplayMedia",
      "mediaRead",
      "internalReadReplay:true",
      'module replay_reads"',
    ]) {
      assert(
        !ordinary.includes(leaked),
        "ordinary/dormant artifact leaked private runtime: " + leaked,
      );
    }
  }
  const captureScript = readFileSync(
    root + "/build/replay-reads-capture-script.txt",
    "utf8",
  );
  const mutant = process.env.REPLAY_READS_MUTANT === "1";
  const nilInverse = process.env.REPLAY_READS_NIL_INVERSE === "1";
  const cases = nilInverse
    ? ["positive"]
    : mutant
      ? ["mutant"]
      : [
          "positive",
          "key-mismatch",
          "area-mismatch",
          "source-mismatch",
          "missing-runtime",
          "collision",
          "capture-before",
          "capture-after",
          "switch-away",
          "switch-real",
          "switch-custom",
          "switch-nil",
          "switch-direct-nil",
        ];
  for (const mode of cases) {
    const context = await browser.newContext();
    // A separate genuine prior realm avoids crossing two compiled Nim programs'
    // exported globals/hooks, which is not a supported application bootstrap.
    const prior = await context.newPage();
    await prior.goto(`http://127.0.0.1:${server.address().port}/`);
    await prior.evaluate(() => {
      globalThis._$HY = {
        seed: 731,
        buildId: "genuine-context",
        assignment: { read: "A" },
      };
    });
    await prior.addScriptTag({ content: capture });
    const bootContext = await prior.evaluate(() => {
      if (
        Object.getOwnPropertyDescriptor(
          globalThis,
          "__isonimInternalReadReplaySelected",
        ) !== undefined
      )
        throw Error("ordinary import allocated private guard");
      return xrReadBootContext;
    });
    await prior.close();
    const page = await context.newPage();
    await page.goto(`http://127.0.0.1:${server.address().port}/`);
    await page.addScriptTag({ content: owned });
    const outcome = await page.evaluate(
      ({ mode, bundle, bootContext, captureScript }) => {
        globalThis._$HY = {
          seed: 731,
          buildId: "genuine-context",
          assignment: { read: "A" },
        };
        globalThis.xrReadBootContext = bootContext;
        const saved = structuredClone(bootContext);
        if (mode === "capture-before") {
          delete globalThis._$HY;
          (0, eval)(captureScript);
        }
        let collisionCalls = 0;
        if (mode === "collision")
          Object.defineProperty(
            globalThis,
            "__isonimInternalReadReplaySelected",
            {
              get() {
                collisionCalls++;
                return () => {
                  collisionCalls++;
                };
              },
              configurable: true,
            },
          );
        if (mode === "collision") {
          const desc = Object.getOwnPropertyDescriptor(
            globalThis,
            "__isonimInternalReadReplaySelected",
          );
          (0, eval)(captureScript);
          if (
            Object.getOwnPropertyDescriptor(
              globalThis,
              "__isonimInternalReadReplaySelected",
            ).get !== desc.get
          )
            throw Error("collision changed");
        }
        const liveQueue = globalThis._$HY?.events;
        const recorded = xrActualReadLog(
          mode === "capture-after" || mode.startsWith("switch-")
            ? "positive"
            : mode,
        );
        if (mode === "missing-runtime") delete globalThis.__ctReplay;
        let error;
        try {
          (0, eval)(bundle);
        } catch (e) {
          error = e;
        }
        if (["capture-before", "missing-runtime", "collision"].includes(mode))
          return {
            error: String(error),
            counts: xrReadCounts,
            collisionCalls,
            queueSame: globalThis._$HY?.events === liveQueue,
            guardOwn:
              Object.getOwnPropertyDescriptor(
                globalThis,
                "__isonimInternalReadReplaySelected",
              )?.get !== undefined,
          };
        if (error) throw error;
        if (
          mode === "key-mismatch" ||
          mode === "area-mismatch" ||
          mode === "source-mismatch"
        ) {
          let first, second;
          try {
            mode === "source-mismatch"
              ? xrReadClock()
              : xrReadKey(mode === "key-mismatch" ? "WRONG" : "value");
          } catch (e) {
            first = e;
          }
          try {
            xrReadKey("value");
          } catch (e) {
            second = e;
          }
          let direct;
          try {
            __ctReplay.next("StorageRead", { area: 1, key: "value" });
          } catch (e) {
            direct = e;
          }
          return {
            samePayload:
              first?.divergence === second?.divergence &&
              second?.divergence === direct?.divergence,
            originalClass:
              first?.constructor === direct?.constructor &&
              second?.constructor === direct?.constructor,
            kind: first?.divergence?.kind,
            latched: first?.divergence === __ctReplay.failed,
            seq: first?.divergence?.seq,
            recorded: first?.divergence?.recorded,
            cursor: __ctReplay.status().cursor,
            state: __ctReplay.status().state,
            counts: xrReadCounts,
          };
        }
        if (mode === "capture-after") {
          delete globalThis._$HY;
          let message;
          try {
            (0, eval)(
              xrReadCaptureScript().slice(
                8,
                xrReadCaptureScript().indexOf("</script>"),
              ),
            );
          } catch (e) {
            message = String(e);
          }
          return { message, hy: globalThis._$HY, counts: xrReadCounts };
        }
        if (mode.startsWith("switch-")) {
          if (mode === "switch-nil") xrReadClear();
          else if (mode === "switch-direct-nil") xrReadDirectNil();
          else if (mode === "switch-real") xrReadSwitchReal();
          else if (mode === "switch-custom") xrReadSwitchCustom();
          else xrReadSwitchAway();
          delete globalThis._$HY;
          // Restore actual native listener methods, proving ordinary capture resumes.
          // Traps above intentionally threw before registering; captured original is retained below.
          const selected =
            globalThis.__isonimInternalReadReplaySelected.selected();
          EventTarget.prototype.addEventListener = function (...args) {
            xrReadCounts.listener++;
            return xrReadNativeAdd.apply(this, args);
          };
          (0, eval)(
            xrReadCaptureScript().slice(
              8,
              xrReadCaptureScript().indexOf("</script>"),
            ),
          );
          xrReadSelectAgain();
          if (!globalThis.__isonimInternalReadReplaySelected.selected())
            throw Error("active replay did not resume");
          let resumedRefusal;
          try {
            xrReadCalls.random();
          } catch (error) {
            resumedRefusal = String(error);
          }
          if (
            !resumedRefusal?.includes(
              "internal read Replay does not support random",
            )
          )
            throw Error("active Replay refusal did not resume");
          return {
            selected,
            hyCreated: Array.isArray(globalThis._$HY?.events),
            counts: xrReadCounts,
          };
        }
        const observation = JSON.parse(xrReadObserve());
        const presence =
          mode === "mutant"
            ? []
            : [
                JSON.parse(xrReadPresence("missing")),
                JSON.parse(xrReadPresence("empty")),
              ];
        xrReadConstructAgain();
        const refused = [];
        for (const [name, fn] of mode === "mutant"
          ? []
          : Object.entries(xrReadCalls)) {
          let message;
          try {
            fn();
          } catch (e) {
            message = String(e);
          }
          if (!message?.includes("internal read Replay does not support"))
            throw Error("missing refusal " + name + ":" + message);
          refused.push(name);
        }
        return {
          saved,
          recorded,
          observation,
          presence,
          refused,
          counts: xrReadCounts,
          next: __ctReplay.peek().kind,
        };
      },
      { mode, bundle, bootContext, captureScript },
    );
    const noRaw = (counts) =>
      assert.deepEqual(counts, {
        date: 0,
        performance: 0,
        crypto: 0,
        storage: 0,
        write: 0,
        cookie: 0,
        layout: 0,
        history: 0,
        timer: 0,
        frame: 0,
        fetch: 0,
        listener: 0,
        dispatch: 0,
      });
    if (mode === "positive" || mode === "mutant") {
      assert.deepEqual(outcome.observation.env, outcome.saved);
      assert.equal(
        outcome.observation.ticks,
        BigInt(Math.trunc(outcome.recorded.samples[0] * 1000000)).toString(),
      );
      assert.equal(
        outcome.observation.neMillis,
        BigInt(Math.trunc(outcome.recorded.samples[1])).toString(),
      );
      if (mutant) {
        assert.equal(outcome.observation.missing, "RAW-missing");
        assert.equal(outcome.next, "StorageRead");
        assert.equal(outcome.counts.storage, 3);
        assert.equal(outcome.counts.performance, 0);
        console.log(
          "read dispatch restoration: REJECTED raw storage AND unconsumed record; clock/context controls PASS",
        );
      } else {
        assert.equal(outcome.observation.missing, "");
        assert.equal(outcome.observation.empty, "");
        assert.equal(outcome.observation.value, "recorded-string");
        assert.equal(outcome.observation.cookie, outcome.recorded.cookie);
        assert.deepEqual(outcome.presence, [null, ""]);
        assert.equal(outcome.next, "Checkpoint");
        assert.equal(outcome.refused.length, 36);
        noRaw(outcome.counts);
      }
    } else if (mode.endsWith("mismatch")) {
      assert.equal(outcome.samePayload, true);
      assert.equal(outcome.originalClass, true);
      assert.equal(outcome.seq, "1");
      assert.equal(outcome.cursor, "1");
      assert.equal(outcome.state, "diverged");
      assert.ok(outcome.recorded);
      assert.equal(outcome.latched, true);
      assert.equal(outcome.kind, "ArgumentMismatch");
      noRaw(outcome.counts);
    } else if (mode === "capture-before") {
      assert.match(outcome.error, /live prehydration capture/);
      assert.equal(outcome.queueSame, true);
      noRaw(outcome.counts);
    } else if (mode === "missing-runtime") {
      assert.match(outcome.error, /requires actual __ctReplay/);
      noRaw(outcome.counts);
    } else if (mode === "collision") {
      assert.match(outcome.error, /guard name collision/);
      assert.equal(outcome.collisionCalls, 0);
      assert.equal(outcome.guardOwn, true);
      noRaw(outcome.counts);
    } else if (mode === "capture-after") {
      assert.match(outcome.message, /does not support prehydration capture/);
      assert.equal(outcome.hy, undefined);
      noRaw(outcome.counts);
    } else if (mode.startsWith("switch-")) {
      assert.equal(outcome.selected, false);
      assert.equal(outcome.hyCreated, true);
      assert.ok(outcome.counts.listener > 0);
      outcome.counts.listener = 0;
      noRaw(outcome.counts);
    }
    console.log(mode + ": PASS");
    await context.close();
  }
} finally {
  await browser?.close();
  await new Promise((r) => server.close(r));
}
