/** Exact host /proc checkpoint to native namespace mapping; no process mocks. */
import assert from "node:assert/strict";
import { readFileSync } from "node:fs";
export function assertKernelCheckpoints(identity, checkpoints) {
  assert(
    Number.isInteger(identity.pid) && identity.pid > 0,
    "native namespace PID required",
  );
  assert(
    typeof identity.starttime === "string" && /^\d+$/.test(identity.starttime),
    "native kernel startticks required",
  );
  assert(
    typeof identity.loadedSha256 === "string" &&
      /^[a-f0-9]{64}$/.test(identity.loadedSha256),
    "actual loaded native SHA required",
  );
  assert.deepEqual(Object.keys(checkpoints).sort(), [
    "first-complete",
    "second-complete",
  ]);
  for (const point of Object.values(checkpoints)) {
    assert(
      Number.isInteger(point.pid) && point.pid > 0,
      "actual host PID required",
    );
    assert(
      Array.isArray(point.namespace_pids) &&
        point.namespace_pids.length > 0 &&
        point.namespace_pids.every((pid) => Number.isInteger(pid) && pid > 0),
      "actual host NSpid mapping required",
    );
    assert.equal(
      point.namespace_pids[0],
      point.pid,
      "NSpid begins with original host PID",
    );
    assert.equal(
      point.namespace_pids.at(-1),
      identity.pid,
      "native namespace PID maps to original host kernel",
    );
    assert.equal(
      point.starttime,
      identity.starttime,
      "original same kernel startticks",
    );
    assert.equal(
      point.loaded_sha256,
      identity.loadedSha256,
      "original loaded native bytes",
    );
  }
  assert.deepEqual(
    checkpoints["first-complete"],
    checkpoints["second-complete"],
    "same original host kernel at both checkpoints",
  );
  return checkpoints["second-complete"].pid;
}

export function assertKernelReaped(pid, starttime) {
  assert(Number.isInteger(pid) && pid > 0);
  assert(
    typeof starttime === "string" && /^\d+$/.test(starttime),
    "original startticks required before reap",
  );
  let current;
  try {
    current = readFileSync(`/proc/${pid}/stat`, "utf8")
      .split(") ")[1]
      .split(" ")[19];
  } catch (error) {
    if (error.code === "ENOENT" || error.code === "ESRCH") return;
    throw error;
  }
  assert.notEqual(
    current,
    starttime,
    "original host PID/startticks still exists, including zombies",
  );
}
