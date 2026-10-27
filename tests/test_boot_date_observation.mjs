/** Real compiled env() and real Chromium Date instances. Controlled native Date
 * constructor inputs test DST/sample identity separately from the live clock.
 * Partial hosts test optional metadata failure, not fake browser qualification.
 * Owner mode imports its actual generated bit conversion/strict codec. */
import assert from "node:assert/strict";
import { readFileSync } from "node:fs";
import { createRequire } from "node:module";
import { createServer } from "node:http";
import vm from "node:vm";
import { chromium } from "./browser/node_modules/playwright/index.mjs";
const source = readFileSync(process.env.ISONIM_BOOT_DATE_BUNDLE, "utf8");
const ownerMode = process.env.ISONIM_BOOT_DATE_OWNER === "1";
let ownerBundle;
if (ownerMode) {
  const artifact = process.env.CT_ARTIFACT;
  assert(artifact, "CT_ARTIFACT is required for boot Date owner integration");
  const require = createRequire(
    artifact + "/packages/boundary-shim/package.json",
  );
  const esbuild = require("esbuild");
  ownerBundle = (
    await esbuild.build({
      stdin: {
        resolveDir: artifact,
        contents:
          "import {numberToBits} from '@codetracer/boundary-shim/dist/browser/recorder.js';import {encodeFrame,decodeRecord} from '@codetracer/boundary-format';globalThis.xrDateOwnerBits=value=>{const bits=numberToBits(value);const encoded=encodeFrame({record:'Clock',seq:1n,src:3,bits});const decoded=decodeRecord(encoded.subarray(4));if(decoded.record!=='Clock'||decoded.src!==3||decoded.seq!==1n||decoded.bits!==bits)throw Error('actual Clock3 codec disagreement');return bits.toString(16);};",
      },
      bundle: true,
      platform: "browser",
      format: "iife",
      write: false,
    })
  ).outputFiles[0].text;
}
function partial(Date, window = {}) {
  const context = vm.createContext({
    Date,
    window,
    console,
    crypto: globalThis.crypto,
    performance: globalThis.performance,
    setTimeout,
    clearTimeout,
    queueMicrotask,
  });
  vm.runInContext(source, context, { timeout: 2000 });
  return JSON.parse(context.isonimBootEnv);
}
const noTime = {
  getTimezoneOffset() {
    return 123;
  },
};
for (const payload of [
  noTime,
  { ...noTime, getTime: null },
  {
    ...noTime,
    get getTime() {
      throw Error("new getter");
    },
  },
  {
    ...noTime,
    getTime() {
      throw Error("new method");
    },
  },
  {
    ...noTime,
    getTime() {
      return "not numeric";
    },
  },
  {
    ...noTime,
    getTime() {
      return NaN;
    },
  },
  {
    ...noTime,
    getTime() {
      return Infinity;
    },
  },
  {
    ...noTime,
    getTime() {
      return -Infinity;
    },
  },
]) {
  const result = partial(function Date() {
    return payload;
  });
  assert.equal(result.timezoneOffset, 123);
  console.log("legacy-boot-Date-offset: PASS");
  assert.equal(
    result.bootDateEpochMs,
    null,
    "boot Date epoch must retain same-instance metadata or explicit null",
  );
}
// Native TimeClip values include legitimate epoch zero and negative epochs.
// They are metadata, never the unavailable null sentinel.
for (const epoch of [0, -1]) {
  const actual = new Date(epoch);
  const observed = partial(function Date() {
    return actual;
  });
  assert.equal(observed.timezoneOffset, actual.getTimezoneOffset());
  assert.equal(observed.bootDateEpochMs, epoch);
}
{
  const failure = new Error("legacy dark failure");
  let epochGets = 0,
    offsets = 0;
  assert.throws(
    () =>
      partial(
        function Date() {
          return {
            getTimezoneOffset() {
              offsets++;
              return 123;
            },
            get getTime() {
              epochGets++;
              return () => 0;
            },
          };
        },
        {
          matchMedia() {
            throw failure;
          },
        },
      ),
    (error) => error === failure,
  );
  assert.equal(offsets, 1);
  assert.equal(epochGets, 0);
}
let gets = 0,
  calls = 0;
const payload = {
  getTimezoneOffset() {
    assert.equal(this, payload);
    return 123;
  },
  get getTime() {
    gets++;
    return function () {
      calls++;
      assert.equal(this, payload);
      return 0;
    };
  },
};
assert.equal(
  partial(function Date() {
    return payload;
  }).bootDateEpochMs,
  0,
);
assert.equal(gets, 1);
assert.equal(calls, 1);
for (const failureAt of ["construct", "offset"]) {
  const original = new Error("legacy " + failureAt);
  let getTimeCalls = 0,
    darkCalls = 0;
  assert.throws(
    () =>
      partial(
        function Date() {
          if (failureAt === "construct") throw original;
          return {
            getTimezoneOffset() {
              throw original;
            },
            get getTime() {
              getTimeCalls++;
              return () => 0;
            },
          };
        },
        {
          matchMedia() {
            darkCalls++;
            return { matches: false };
          },
        },
      ),
    (e) => e === original,
  );
  assert.equal(getTimeCalls, 0);
  assert.equal(darkCalls, 0);
}
console.log("boot-Date-partial-error-order: PASS");
const server = createServer((req, res) => {
  if (req.url === "/suite.js") {
    res.setHeader("Content-Type", "text/javascript");
    res.end(source);
  } else res.end('<!doctype html><script src="/suite.js"></script>');
});
await new Promise((r) => server.listen(0, "127.0.0.1", r));
let browser;
try {
  browser = await chromium.launch({
    executablePath: process.env.PLAYWRIGHT_CHROMIUM_EXECUTABLE,
  });
  const receipts = [];
  for (const mode of ["live", "winter", "summer"]) {
    const context = await browser.newContext({
      timezoneId: "America/New_York",
    });
    await context.addInitScript((mode) => {
      const NativeDate = window.Date;
      const winter = NativeDate.UTC(2026, 0, 15, 12),
        summer = NativeDate.UTC(2026, 6, 15, 12);
      const probe = {
        constructs: [],
        offsets: [],
        times: [],
        getters: 0,
        nowCalls: 0,
      };
      globalThis.xrDateProbe = probe;
      globalThis.xrDateBits = (value) => {
        const view = new DataView(new ArrayBuffer(8));
        view.setFloat64(0, value, true);
        return view.getBigUint64(0, true).toString(16);
      };
      const ids = new WeakMap();
      class ObservedDate extends NativeDate {
        constructor(...args) {
          if (args.length === 0 && mode !== "live")
            super(
              probe.constructs.length === 0
                ? mode === "winter"
                  ? winter
                  : summer
                : mode === "winter"
                  ? summer
                  : winter,
            );
          else super(...args);
          if (args.length === 0) {
            const id = probe.constructs.length;
            ids.set(this, id);
            probe.constructs.push({
              id,
              epoch: NativeDate.prototype.getTime.call(this),
              offset: NativeDate.prototype.getTimezoneOffset.call(this),
            });
          }
        }
        getTimezoneOffset() {
          probe.offsets.push(ids.get(this));
          return super.getTimezoneOffset();
        }
        get getTime() {
          probe.getters++;
          return function () {
            probe.times.push(ids.get(this));
            return NativeDate.prototype.getTime.call(this);
          };
        }
        static now() {
          probe.nowCalls++;
          return NativeDate.now();
        }
      }
      window.Date = ObservedDate;
    }, mode);
    const page = await context.newPage();
    const errors = [];
    page.on("pageerror", (e) => errors.push(String(e)));
    await page.goto(`http://127.0.0.1:${server.address().port}/`);
    if (ownerMode) await page.addScriptTag({ content: ownerBundle });
    const result = await page.evaluate((ownerMode) => {
      const boot = JSON.parse(isonimBootEnv),
        before = structuredClone(xrDateProbe);
      isonimReadEnv();
      isonimMutateEnv();
      const after = JSON.parse(isonimReadEnv()),
        cached = structuredClone(xrDateProbe);
      isonimResetEnv();
      const fresh = JSON.parse(isonimReadEnv()),
        afterFresh = structuredClone(xrDateProbe);
      isonimReadEnv();
      return {
        boot,
        after,
        fresh,
        before,
        cached,
        afterFresh,
        final: structuredClone(xrDateProbe),
        bits: xrDateBits(boot.bootDateEpochMs),
        expectedBits: xrDateBits(before.constructs[0].epoch),
        ownerBits: ownerMode ? xrDateOwnerBits(boot.bootDateEpochMs) : null,
        hasCt: Object.keys(globalThis).some((k) => k.startsWith("__ct")),
      };
    }, ownerMode);
    assert.deepEqual(errors, []);
    assert.equal(
      result.boot.timezoneOffset,
      result.before.constructs[0].offset,
    );
    console.log("legacy-boot-Date-offset: PASS");
    assert.equal(
      result.before.constructs.length,
      1,
      "same-instance boot Date must not construct another clock",
    );
    assert.equal(
      result.boot.bootDateEpochMs,
      result.before.constructs[0].epoch,
      "boot Date epoch must retain same-instance metadata or explicit null",
    );
    assert.equal(result.bits, result.expectedBits);
    if (ownerMode)
      assert.equal(
        result.ownerBits,
        result.expectedBits,
        "actual owner Clock3 codec must preserve original Date bits",
      );
    assert.deepEqual(result.before.offsets, [0]);
    assert.deepEqual(result.before.times, [0]);
    assert.equal(result.before.getters, 1);
    assert.equal(result.before.nowCalls, 0);
    assert.deepEqual(
      result.after,
      result.boot,
      "actual returned Nim copy mutation must not alter cached epoch",
    );
    assert.deepEqual(
      result.cached,
      result.before,
      "cached reads must not observe a Date",
    );
    assert.equal(result.afterFresh.constructs.length, 2);
    assert.deepEqual(result.afterFresh.offsets, [0, 1]);
    assert.deepEqual(result.afterFresh.times, [0, 1]);
    assert.equal(result.afterFresh.getters, 2);
    assert.equal(result.afterFresh.nowCalls, 0);
    assert.equal(
      result.fresh.bootDateEpochMs,
      result.afterFresh.constructs[1].epoch,
    );
    assert.equal(
      result.fresh.timezoneOffset,
      result.afterFresh.constructs[1].offset,
    );
    assert.deepEqual(result.final, result.afterFresh);
    assert.equal(result.hasCt, false);
    receipts.push({
      mode,
      epoch: result.boot.bootDateEpochMs,
      offset: result.boot.timezoneOffset,
      bits: result.bits,
    });
    await context.close();
  }
  assert.equal(receipts[1].offset, 300);
  assert.equal(receipts[2].offset, 240);
  assert.notEqual(receipts[1].epoch, receipts[2].epoch);
  console.log(
    `boot-Date-${ownerMode ? "owner" : "platform"}: PASS browser=${browser.version()} ${JSON.stringify(receipts)}`,
  );
} finally {
  await browser?.close();
  await new Promise((r) => server.close(r));
}
