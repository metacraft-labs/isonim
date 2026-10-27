// Compile the actual original projection back into the current source; the
// same real browser/public RPC regression must reject exactly the nil cases.
import { cp, mkdtemp, readFile, writeFile, rm } from "node:fs/promises";
import { tmpdir } from "node:os";
import { join, resolve } from "node:path";
import { spawnSync } from "node:child_process";
import assert from "node:assert/strict";
const work = await mkdtemp(join(tmpdir(), "scripted-rpc-body-mutant-"));
try {
  await cp("src", join(work, "src"), { recursive: true });
  const file = join(work, "src/isonim/core/nondet.nim");
  const source = await readFile(file, "utf8");
  const expression = '(if body == nil: "" else: $body)';
  assert.equal(source.split(expression).length - 1, 1);
  await writeFile(file, source.replace(expression, "$body"));
  // Compile a fixture outside tests/config.nims, whose local src path would
  // otherwise select the unchanged original before the mutated source root.
  const fixture = join(work, "fixture.nim");
  await cp("tests/scripted_rpc_body_fixture.nim", fixture);
  const output = join(work, "fixture.js");
  let run = spawnSync(
    "nim",
    [
      "js",
      "--path:" + resolve("../nim-everywhere/src"),
      "--path:" + join(work, "src"),
      "--out:" + output,
      fixture,
    ],
    { encoding: "utf8" },
  );
  assert.equal(run.status, 0, run.stdout + run.stderr);
  const receipt = join(work, "receipt.json");
  run = spawnSync(process.execPath, ["tests/test_scripted_rpc_body.mjs"], {
    env: {
      ...process.env,
      SCRIPTED_RPC_BODY_FIXTURE: output,
      SCRIPTED_RPC_BODY_RECEIPT: receipt,
    },
    encoding: "utf8",
    timeout: 30000,
  });
  assert.equal(run.signal, null, "mutant must fail assertions, not time out");
  assert.notEqual(
    run.status,
    0,
    "original nil-body projection unexpectedly passed",
  );
  const report = JSON.parse(await readFile(receipt, "utf8"));
  assert.equal(report.results.length, 6);
  assert.deepEqual(
    report.failures.map((f) => [f.method, f.rejects]),
    [
      ["publicGet", false],
      ["publicGet", true],
    ],
  );
  assert(
    report.failures.every((f) =>
      f.error.includes(
        "scripted RPC reaches the selected transport exactly once",
      ),
    ),
  );
  assert(
    report.results
      .filter((r) => r.method === "publicGet")
      .every(
        (r) =>
          r.observed.backend.calls === 0 &&
          r.observed.backend.dispatch === 0 &&
          r.observed.outcome.error.includes("null"),
      ),
  );
  console.log(
    "nil-body projection mutant REJECTED; four ordinary controls remain green",
  );
} finally {
  await rm(work, { recursive: true, force: true });
}
