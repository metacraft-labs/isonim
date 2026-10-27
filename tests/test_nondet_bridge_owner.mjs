/** API/bootstrap audit only, not a framework conformance/self-replay harness.
 * Actual installed Recorder/codec/runtime/cursor and real Chromium supply the
 * closed read data. Probe subclasses are intentionally incomplete: raw env/
 * storage and missing platform-hook dispatch remain visible, never accepted.
 */
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
globalThis.xrPrepareActualCursor=()=>{
 const orig=captureOriginals(window),frames=[],samples=[];
 localStorage.setItem('xr-probe','recorded-before');
 const rec=new Recorder({checkpointScheme:'dom-v1',checkpointHash:()=>domV1Hash(document),sink:{append(frame){frames.push(frame);},end(){},halt(){}}});
 rec.start({vocab:1,protocol_level:0,recorder_id:'initialization-audit',framework:'',build_hash:'a'.repeat(64),session_id:'1'.repeat(32),prev_session:'',capabilities:'[]'},readEnvironment(window,orig));
 for(let i=0;i<2;i++){const value=orig.performanceNow.call(performance);samples.push(value);rec.emit('Clock',{src:2,bits:numberToBits(value)});}
 rec.emit('StorageRead',{area:1,key:'xr-probe',present:1,value:localStorage.getItem('xr-probe')});
 rec.end(2);
 const records=frames.map(f=>decodeRecord(f.subarray(4)));
 const log=encodeLog(records);let raw='';for(const b of log)raw+=String.fromCharCode(b);
 const replay=installReplayRuntime(window,{log:btoa(raw)});
 globalThis.xrActualCursorNow=()=>{const r=replay.next('Clock',{src:2});const d=new DataView(new ArrayBuffer(8));d.setBigUint64(0,r.bits,true);return d.getFloat64(0,true);};
 localStorage.setItem('xr-probe','replay-wrong');
 const counts={crypto:0,date:0,performance:0,storage:0};
 const NativeDate=Date,cryptoRead=crypto.getRandomValues.bind(crypto),perfRead=performance.now.bind(performance),storageRead=localStorage.getItem.bind(localStorage);
 window.Date=class extends NativeDate{constructor(...args){super(...args);if(args.length===0)counts.date++;}};
 crypto.getRandomValues=(view)=>{counts.crypto++;return cryptoRead(view);};
 performance.now=()=>{counts.performance++;return perfRead();};
 localStorage.getItem=key=>{counts.storage++;return storageRead(key);};
 globalThis.xrAuditCounts=counts;
 return {samples,records:records.map(r=>({record:r.record,src:r.src,seq:r.seq?.toString()}))};
};`,
    },
    bundle: true,
    platform: "browser",
    format: "iife",
    write: false,
  })
).outputFiles[0].text;
const server = createServer((req, res) =>
  res.end("<!doctype html><main>Closed initialization audit</main>"),
);
await new Promise((r) => server.listen(0, "127.0.0.1", r));
let browser;
try {
  browser = await chromium.launch({
    executablePath: process.env.PLAYWRIGHT_CHROMIUM_EXECUTABLE,
  });
  const outcomes = [];
  for (const hy of [false, true])
    for (const name of ["default", "same_module", "early", "late"]) {
      const context = await browser.newContext();
      const page = await context.newPage();
      await page.goto(`http://127.0.0.1:${server.address().port}/`);
      await page.addScriptTag({ content: owned });
      const bundle = readFileSync(
        root + "/build/bridge-owner-" + name + ".js",
        "utf8",
      );
      const result = await page.evaluate(
        ({ bundle, hy }) => {
          if (hy)
            globalThis._$HY = {
              seed: 731,
              buildId: "closed-probe",
              assignment: {},
            };
          const log = xrPrepareActualCursor();
          let error;
          try {
            (0, eval)(bundle);
          } catch (e) {
            error = String(e);
          }
          return {
            log,
            error,
            observation: globalThis.xrNimObservation,
            counts: structuredClone(xrAuditCounts),
            next: __ctReplay.peek().kind,
            failed: __ctReplay.failed,
          };
        },
        { bundle, hy },
      );
      assert.equal(result.error, undefined);
      assert.equal(
        result.observation.storage,
        "replay-wrong",
        "unimplemented read dispatch remains explicit, not Replay acceptance",
      );
      if (name === "default") {
        assert.equal(result.counts.performance, 2);
        assert.equal(result.next, "Clock");
      } else {
        assert.equal(
          result.observation.ticks,
          BigInt(Math.trunc(result.log.samples[0] * 1000000)).toString(),
        );
        assert.equal(
          result.observation.neMillis,
          BigInt(Math.trunc(result.log.samples[1])).toString(),
          "NE facade must consume the actual second Clock2",
        );
        assert.equal(
          result.counts.performance,
          0,
          "selected actual cursor clock must not fall back to raw performance",
        );
        assert.equal(
          result.next,
          "StorageRead",
          "both actual owner Clock2 records must be consumed",
        );
      }
      assert.equal(result.counts.crypto, hy || name === "early" ? 0 : 1);
      assert.equal(
        result.counts.date,
        name === "same_module" || name === "late" ? 2 : 1,
      );
      outcomes.push({ name, hy, ...result });
      await context.close();
    }
  for (const result of outcomes.filter((r) => r.hy))
    assert.equal(
      result.observation.random,
      outcomes.find((r) => r.hy && r.name === "default").observation.random,
      "existing literal hydration seed is a real constructor input",
    );
  console.log("actual-owner cursor bridge: PASS");
  console.log(
    JSON.stringify(
      {
        scope:
          "Actual API and import-order audit only; intentionally incomplete probe backends, not accepted Replay backend/recording/conformance",
        browser: browser.version(),
        artifact,
        outcomes,
      },
      null,
      2,
    ),
  );
} finally {
  await browser?.close();
  await new Promise((r) => server.close(r));
}
