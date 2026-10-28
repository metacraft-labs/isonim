// Compile real consumer/owner implementation mutations; keep actual HTTP,
// Chromium fetch, response streams and all browser assertions unchanged.
import { cp, mkdtemp, readFile, writeFile, rm } from "node:fs/promises";
import { tmpdir } from "node:os";
import { join, resolve } from "node:path";
import { spawnSync } from "node:child_process";
import assert from "node:assert/strict";
const work = await mkdtemp(join(tmpdir(), "http-response-mutants-"));
const mutations = [
  [
    "rpc-abort",
    "src",
    "isonim/core/private/rpc_http.nim",
    "aborted ? -1 : 0",
    "0",
    "RPC abort remains a fulfilled -1 outcome",
  ],
  [
    "buffered-error",
    "../nim-everywhere/src",
    "nim_everywhere/http.nim",
    "`finish`(599",
    "`finish`(0",
    "body failure keeps legacy fulfilled status",
  ],
];
try {
  for (const [
    name,
    source,
    relative,
    old,
    replacement,
    diagnostic,
  ] of mutations) {
    const dir = join(work, name);
    await cp(source, dir, { recursive: true });
    const file = join(dir, relative);
    const text = await readFile(file, "utf8");
    assert.equal(text.split(old).length - 1, 1);
    await writeFile(file, text.replace(old, replacement));
    const fixture = join(dir, "fixture.nim");
    await cp("tests/http_response_fixture.nim", fixture);
    const output = join(dir, "fixture.js");
    let run = spawnSync(
      "nim",
      [
        "js",
        "--path:" + resolve("../nim-everywhere/src"),
        "--path:" + resolve("src"),
        "--path:" + dir,
        "--out:" + output,
        fixture,
      ],
      { encoding: "utf8" },
    );
    await writeFile(join(dir, "compile.log"), run.stdout + run.stderr);
    assert.equal(run.status, 0, run.stdout + run.stderr);
    run = spawnSync(
      process.execPath,
      ["tests/test_http_response_browser.mjs"],
      {
        env: { ...process.env, HTTP_RESPONSE_FIXTURE: output },
        encoding: "utf8",
        timeout: 30000,
      },
    );
    await writeFile(join(dir, "browser.log"), run.stdout + run.stderr);
    assert.equal(run.signal, null, "must fail named assertion, not timeout");
    assert.notEqual(run.status, 0, "mutant passed " + name);
    assert(
      (run.stdout + run.stderr).includes(diagnostic),
      run.stdout + run.stderr,
    );
    console.log("rejected " + name + ": " + diagnostic);
  }
} finally {
  if (process.env.HTTP_RESPONSE_MUTATION_RECEIPTS)
    await cp(work, process.env.HTTP_RESPONSE_MUTATION_RECEIPTS, { recursive: true });
  await rm(work, { recursive: true, force: true });
}
