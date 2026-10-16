/** Direct actual delivery proof. Actual retained native records are checked
 * against full instructions, actual exported owning ACP conversion, and original
 * independently observed kernel checkpoints. No mocks, inference, outputs or
 * input alterations. This proves delivery; behavioral tests remain mandatory.
 */
import { readFileSync, readdirSync, writeFileSync, existsSync } from "node:fs";
import { pathToFileURL } from "node:url";
import assert from "node:assert/strict";
import {
  assertKernelCheckpoints,
  assertKernelReaped,
} from "./editor_sdk_kernel_evidence.mjs";
import { ProtocolEvidence, sha } from "./editor_sdk_native_observer.mjs";
const [
  directory,
  wirePath,
  instructionsPath,
  checkpointsPath,
  manifestPath,
  count,
] = process.argv.slice(2);
const runtime = JSON.parse(readFileSync(manifestPath, "utf8"));
for (const [file, digest] of Object.entries(runtime.files))
  assert.equal(
    sha(readFileSync(file)),
    digest,
    "owning runtime bytes unchanged",
  );
const modulePath = runtime.paths.converter;
const expectedUsers = Number(count);
assert([0, 2].includes(expectedUsers));
const files = readdirSync(directory).filter((x) =>
  /^sdk-native-.*\.json$/.test(x),
);
assert.equal(files.length, 1, "exactly one observed owning native kernel");
const state = JSON.parse(readFileSync(directory + "/" + files[0], "utf8"));
const expected = readFileSync(instructionsPath);
assert.equal(state.errors.length, 0);
assert.equal(state.identity.loadedMatches, true);
assert.equal(state.identity.cwdMatches, true);
assert.equal(state.spawn.nodeOptionsRestored, true);
assert.equal(
  state.spawn.parentNodeOptionsRestored,
  true,
  "ACP parent original NODE_OPTIONS restored",
);
assert.equal(state.spawn.observerEnvAbsent, true);
assert.equal(state.parentIdentity.node, runtime.paths.node);
assert.equal(
  state.parentIdentity.loadedSha256,
  runtime.files[runtime.paths.node],
);
assert.equal(state.identity.executable, runtime.paths.native);
assert.equal(state.identity.loadedSha256, runtime.files[runtime.paths.native]);
const protocol = state.protocol;
assert.deepEqual(Object.keys(protocol.inflight).sort(), ["input", "output"]);
for (const frame of Object.values(protocol.inflight)) {
  assert.equal(frame.utf8Bytes, 0);
  assert.equal(frame.sha256, sha(Buffer.alloc(0)));
}
const validator = new ProtocolEvidence({});
Object.assign(validator, {
  replayUserMessages: protocol.replayUserMessages,
  initialize: protocol.initialize,
  users: protocol.users,
  roleChanging: protocol.roleChanging,
  records: protocol.records,
  errors: protocol.errors,
});
assert(validator.validate(expectedUsers).accepted);
assert.equal(protocol.initialize[0].appendSha256, sha(expected));
assert.equal(protocol.initialize[0].appendUtf8Bytes, expected.length);
const wire = readFileSync(wirePath, "utf8");
const rows = wirePath.endsWith(".jsonl")
  ? wire
      .trim()
      .split("\n")
      .map((x) => JSON.parse(x))
  : JSON.parse(wire);
const requests = rows
  .filter((x) => x.direction === "request")
  .map((x) => x.message);
assert.equal(requests.filter((x) => x.method === "initialize").length, 1);
assert.equal(requests.filter((x) => x.method === "session/new").length, 1);
const prompts = requests.filter((x) => x.method === "session/prompt");
assert.equal(prompts.length, expectedUsers);
const { promptToClaude } = await import(pathToFileURL(modulePath).href);
const mapped = prompts.map((x) => promptToClaude(x.params));
assert.deepEqual(
  protocol.users.map((x) => x.contentSha256),
  mapped.map((x) => sha(JSON.stringify(x.message.content))),
  "actual SDK user content equals actual owning ACP conversion, in order",
);
assert.deepEqual(
  protocol.users.map((x) => x.sessionIdSha256),
  mapped.map((x) => sha(x.session_id)),
  "actual SDK users target original same session",
);
let hostPid = state.nativePid;
if (expectedUsers === 2) {
  hostPid = assertKernelCheckpoints(
    state.identity,
    JSON.parse(readFileSync(checkpointsPath, "utf8")),
  );
  assert.equal(
    protocol.users[0].sessionIdSha256,
    protocol.users[1].sessionIdSha256,
  );
}
assertKernelReaped(hostPid, state.identity.starttime);
let lifecycleOrigin = "native-node-close";
if (!state.lifecycle.some((x) => x.event === "close")) {
  assert.equal(
    expectedUsers,
    2,
    "zero-user native control must retain genuine Node close",
  );
  const completion = JSON.parse(
    readFileSync(
      new URL("provider-wire-state.json", pathToFileURL(wirePath)),
      "utf8",
    ),
  );
  assert.equal(completion.origin, "host-quiescence");
  assert.equal(completion.complete, true);
  assert.deepEqual(completion.errors, []);
  assert.equal(completion.traceSha256, sha(readFileSync(wirePath)));
  assert.equal(completion.native.pid, hostPid);
  assert.equal(completion.native.starttime, state.identity.starttime);
  assert.equal(completion.native.loadedSha256, state.identity.loadedSha256);
  assert.equal(completion.native.namespacePids.at(-1), state.identity.pid);
  assert.deepEqual(Object.keys(completion.completionProbe.processes).sort(), [
    "acp",
    "native",
    "observer",
  ]);
  assert.equal(
    completion.writers.acp.namespacePids.at(-1),
    state.parentIdentity.pid,
  );
  assert.equal(
    completion.writers.acp.loadedSha256,
    state.parentIdentity.loadedSha256,
  );
  assert(
    Number.isFinite(completion.completionProbe.elapsed) &&
      completion.completionProbe.elapsed >= 0 &&
      completion.completionProbe.elapsed < 15,
  );
  for (const [label, point] of Object.entries(
    completion.completionProbe.processes,
  )) {
    if (label === "native" && point.state === "reused")
      assert.notEqual(point.observedStarttime, point.originalStarttime);
    else assert.equal(point.state, "absent");
    const original =
      label === "native" ? completion.native : completion.writers[label];
    assert.equal(point.pid, original.pid);
    assert.equal(point.originalStarttime, original.starttime);
    assertKernelReaped(point.pid, point.originalStarttime);
  }
  assert.equal(completion.childFinallyObserved, false);
  assert.equal(completion.providerExit, null);
  assert.equal(completion.requestReaderAliveAtProviderExit, null);
  lifecycleOrigin = "independent-host-quiescence";
}
const proof = {
  scope:
    "Direct actual native initialization/user-stream delivery; NOT model API system-placement or compliance replacement",
  lifecycleOrigin,
  guideSha256: sha(expected),
  guideUtf8Bytes: expected.length,
  nativeNamespacePid: state.nativePid,
  nativeHostPid: hostPid,
  starttime: state.identity.starttime,
  loadedSha256: state.identity.loadedSha256,
  actualInitializeAck: true,
  actualSdkUserFrames: expectedUsers,
  actualMappedContentSessionOrderEqual: true,
  kernelCheckpointsMatched: expectedUsers === 2,
  originalKernelReaped: true,
};
writeFileSync(
  directory + "/delivery-proof.json",
  JSON.stringify(proof, null, 2) + "\n",
  { mode: 0o600 },
);
console.log(JSON.stringify(proof));
