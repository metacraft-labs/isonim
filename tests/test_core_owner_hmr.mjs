/** No mocks. Re-evaluates the same actually compiled Nim core program in one
 * JS runtime, then mutates and disposes its retained real reactive owner. */
import assert from "node:assert/strict";
import { readFileSync } from "node:fs";
import vm from "node:vm";
const source = readFileSync(
  process.env.ISONIM_CORE_HMR_BUILD || "build/editor-popup/core-owner-hmr.js",
  "utf8",
);
vm.runInThisContext(source, {
  filename: "actual-core-owner-first.js",
  timeout: 2000,
});
const original = globalThis.__isonimCoreOwnerHmr;
const snapshot = () => JSON.parse(globalThis.__coreOwnerHmr.snapshot());
assert.deepEqual(snapshot(), {
  value: 0,
  doubled: 0,
  runs: 1,
  cleanups: 0,
  valueObservers: 1,
  memoObservers: 1,
});
vm.runInThisContext(source, {
  filename: "actual-core-owner-identical-hmr.js",
  timeout: 2000,
});
assert.equal(globalThis.__isonimCoreOwnerHmr, original);
for (let i = 1; i <= 20; i++) {
  vm.runInThisContext("__coreOwnerHmr.step()", { timeout: 2000 });
  assert.deepEqual(
    snapshot(),
    {
      value: i,
      doubled: i * 2,
      runs: i + 1,
      cleanups: i,
      valueObservers: 1,
      memoObservers: 1,
    },
    "Identical-bundle HMR must clean original computation dependencies on every change",
  );
}
vm.runInThisContext("__coreOwnerHmr.dispose()", { timeout: 2000 });
assert.deepEqual(snapshot(), {
  value: 20,
  doubled: 40,
  runs: 21,
  cleanups: 21,
  valueObservers: 0,
  memoObservers: 0,
});
vm.runInThisContext("__coreOwnerHmr.step()", { timeout: 2000 });
assert.deepEqual(snapshot(), {
  value: 21,
  doubled: 40,
  runs: 21,
  cleanups: 21,
  valueObservers: 0,
  memoObservers: 0,
});
console.log(
  "Actual compiled owner HMR: twenty changes stay bounded; disposal removes source/memo observers and later callbacks",
);
