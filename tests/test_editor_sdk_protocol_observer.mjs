/** Pure parser/validator controls only. Synthetic JSON protocol frames are
 * explicitly justified to exhaustively exercise fragmented UTF-8, correlation,
 * invalid input and continuity errors without sending user prompts/inference.
 * These fixtures cannot substitute for the separately measured real native ACK.
 * No mocked process/provider/model or simulated runtime acceptance is involved.
 */
import assert from "node:assert/strict";
import {
  ProtocolEvidence,
  sha,
} from "./helpers/editor_sdk_native_observer.mjs";
import { writeFileSync } from "node:fs";
const text = "Unicode role é ☃ 🧪 e\u0301";
const expected = { sha256: sha(text), utf8Bytes: Buffer.byteLength(text) };
const request = (append = text) => ({
  type: "control_request",
  request_id: "fixture-init",
  request: {
    subtype: "initialize",
    ...(append === null ? {} : { appendSystemPrompt: append }),
  },
});
const ack = (id) => ({
  type: "control_response",
  response: { subtype: "success", request_id: id, response: {} },
});
function send(t, dir, frame, fragment = false) {
  const b = Buffer.from(JSON.stringify(frame) + "\n");
  if (fragment) for (const byte of b) t.feed(dir, Buffer.from([byte]));
  else t.feed(dir, b);
}
function ready(append = text, id = "fixture-init", fragment = false) {
  const t = new ProtocolEvidence(expected);
  send(t, "input", request(append), fragment);
  send(t, "output", ack(id), fragment);
  return t;
}
const cases = [];
function test(name, fn) {
  fn();
  cases.push({ name, pass: true });
}
test("complete Unicode exact hash and byte length", () =>
  assert(ready().validate(0).accepted));
test("every-byte fragmented multibyte UTF8 unchanged", () => {
  const t = ready(text, "fixture-init", true);
  assert(t.validate(0).accepted);
  assert.equal(t.initialize[0].appendSha256, expected.sha256);
  assert.equal(t.initialize[0].appendUtf8Bytes, expected.utf8Bytes);
});
test("missing append with correlated ACK rejected", () => {
  const v = ready(null).validate(0);
  assert(!v.accepted);
  assert(v.checks.realCorrelatedInitializeSuccess);
  assert(!v.checks.exactAppend);
});
test("changed append with correlated ACK rejected", () => {
  const v = ready(text + "!").validate(0);
  assert(!v.accepted);
  assert(v.checks.realCorrelatedInitializeSuccess);
  assert(!v.checks.exactAppend);
});
test("uncorrelated actual-shape ACK rejected as parser evidence error", () => {
  const t = ready(text, "different-id");
  assert(!t.validate(0).accepted);
  assert.equal(t.errors.length, 1);
  assert(!t.validate(0).checks.realCorrelatedInitializeSuccess);
});
test("duplicate correlated ACK rejected", () => {
  const t = ready();
  send(t, "output", ack("fixture-init"));
  assert(!t.validate(0).accepted);
  assert.equal(t.errors.length, 1);
});
test("reinitialization rejected even with identical append", () => {
  const t = ready();
  const r = request();
  r.request_id = "second-init";
  send(t, "input", r);
  send(t, "output", ack("second-init"));
  assert(!t.validate(0).checks.oneInitialize);
});
test("role changing control after valid initialize rejected", () => {
  const t = ready();
  send(t, "input", {
    type: "control_request",
    request_id: "change",
    request: {
      subtype: "apply_flag_settings",
      settings: { appendSystemPrompt: "changed" },
    },
  });
  send(t, "output", ack("change"));
  assert(!t.validate(0).checks.noRoleChangingControls);
});
test("two exact user frames retain hashes and session identity", () => {
  const t = ready();
  for (const content of ["first 🧪", "second é"])
    send(
      t,
      "input",
      {
        type: "user",
        session_id: "same-fixture-session",
        message: { role: "user", content },
      },
      true,
    );
  assert(t.validate(2).accepted);
  assert.deepEqual(
    t.users.map((x) => x.contentSha256),
    ["first 🧪", "second é"].map((x) => sha(JSON.stringify(x))),
  );
  assert.equal(t.users[0].sessionIdSha256, t.users[1].sessionIdSha256);
});
test("third hidden user frame rejected by expected continuity count", () => {
  const t = ready();
  for (const content of ["first", "second", "hidden"])
    send(t, "input", {
      type: "user",
      session_id: "same",
      message: { role: "user", content },
    });
  assert(!t.validate(2).accepted);
  assert(!t.validate(2).checks.userCount);
});
test("truncated Unicode at EOF retained as failure", () => {
  const t = ready();
  t.feed("output", Buffer.from([0xf0, 0x9f]));
  t.finish("output");
  assert(!t.validate(0).accepted);
  assert.equal(t.errors.length, 1);
});
test("truncated JSON line at EOF retained as failure", () => {
  const t = ready();
  t.feed("input", Buffer.from("{"));
  t.finish("input");
  assert(!t.validate(0).accepted);
});
test("malformed JSON retained as failure", () => {
  const t = ready();
  t.feed("output", Buffer.from("{bad}\n"));
  assert(!t.validate(0).accepted);
});
test("replacement system prompt rejected", () => {
  const t = new ProtocolEvidence(expected),
    r = request();
  r.request.systemPrompt = ["replacement"];
  send(t, "input", r);
  send(t, "output", ack("fixture-init"));
  assert(!t.validate(0).checks.presetRetained);
});
console.log(
  JSON.stringify({ passed: cases.length, scope: "pure codec controls", cases }),
);
// Grounded in owning SDK handleControlRequest and native StructuredIO replay:
// native requests first, SDK answers that ID, native replays the SAME response.
function auxiliary(
  t,
  {
    id = "native-hook",
    answerId = id,
    response = { continue: true },
    echo = response,
  } = {},
) {
  send(t, "output", {
    type: "control_request",
    request_id: id,
    request: {
      subtype: "hook_callback",
      callback_id: "fixture-callback",
      input: {},
    },
  });
  send(t, "input", {
    type: "control_response",
    response: { subtype: "success", request_id: answerId, response },
  });
  send(t, "output", {
    type: "control_response",
    response: { subtype: "success", request_id: id, response: echo },
  });
}
test("native request SDK response exact single replay retains directions and order", () => {
  const t = ready();
  t.replayUserMessages = true;
  auxiliary(t);
  assert(t.validate(0).accepted);
  assert.deepEqual(
    t.records.slice(-3).map((x) => x.transaction),
    ["native-request", "sdk-response", "native-response-replay"],
  );
  const [request, response, replay] = t.records.slice(-3);
  assert.equal(response.requestOrder, request.order);
  assert.equal(replay.responseOrder, response.order);
  assert.equal(replay.responseSha256, response.responseSha256);
});
test("native replay without enabled owning replay flag rejects", () => {
  const t = ready();
  auxiliary(t);
  assert(!t.validate(0).accepted);
  assert.equal(t.records.at(-1).transaction, "native-response-replay");
  assert.equal(t.records.at(-1).valid, false);
});
test("wrong SDK response ID and resulting native replay reject retaining hashes", () => {
  const t = ready();
  t.replayUserMessages = true;
  auxiliary(t, { answerId: "wrong-id" });
  assert(!t.validate(0).accepted);
  assert.equal(t.records.at(-2).requestIdSha256, sha("wrong-id"));
  assert.equal(t.records.at(-2).valid, false);
});
test("changed native replay payload rejects although IDs and counts match", () => {
  const t = ready();
  t.replayUserMessages = true;
  auxiliary(t, { echo: { continue: false } });
  assert(!t.validate(0).accepted);
  assert.notEqual(
    t.records.at(-1).responseSha256,
    t.records.at(-2).responseSha256,
  );
});
test("unsolicited reverse response and output replay reject", () => {
  const t = ready();
  t.replayUserMessages = true;
  send(t, "input", ack("absent"));
  send(t, "output", ack("absent"));
  assert.equal(t.errors.length, 2);
  assert(!t.validate(0).accepted);
});
test("duplicate reverse response and duplicate replay reject", () => {
  const t = ready();
  t.replayUserMessages = true;
  auxiliary(t);
  send(t, "input", {
    type: "control_response",
    response: {
      subtype: "success",
      request_id: "native-hook",
      response: { continue: true },
    },
  });
  send(t, "output", {
    type: "control_response",
    response: {
      subtype: "success",
      request_id: "native-hook",
      response: { continue: true },
    },
  });
  assert.equal(t.errors.length, 2);
  assert(!t.validate(0).accepted);
});
test("replay before actual SDK response fails despite later matching input", () => {
  const t = ready();
  t.replayUserMessages = true;
  send(t, "output", {
    type: "control_request",
    request_id: "native-hook",
    request: { subtype: "hook_callback" },
  });
  send(t, "output", ack("native-hook"));
  send(t, "input", ack("native-hook"));
  assert(!t.validate(0).accepted);
});
test("native auxiliary and SDK error responses reject with metadata", () => {
  for (const direction of ["input", "output"]) {
    const t = ready();
    t.replayUserMessages = true;
    send(t, "output", {
      type: "control_request",
      request_id: "aux",
      request: { subtype: "hook_callback" },
    });
    send(t, direction, {
      type: "control_response",
      response: {
        subtype: "error",
        request_id: "aux",
        error: "synthetic-error",
      },
    });
    assert(!t.validate(0).accepted);
    assert.equal(t.records.at(-1).subtype, "error");
    assert.equal(t.records.at(-1).valid, false);
  }
});
test("malformed ACK preserves sanitized direction type ID order before failure", () => {
  const t = ready();
  send(t, "output", {
    type: "control_response",
    response: { request_id: "bad", subtype: 17 },
  });
  const last = t.records.at(-1);
  assert.equal(last.type, "control_response");
  assert.equal(last.direction, "output");
  assert.equal(last.requestIdSha256, sha("bad"));
  assert.equal(last.order, 2);
  assert.equal(last.valid, false);
  assert(!t.validate(0).accepted);
});
test("malformed JSON retains line digest and later valid frames still observed", () => {
  const t = ready();
  t.feed(
    "output",
    Buffer.from(
      "{bad}\n" + JSON.stringify({ type: "system", subtype: "fixture" }) + "\n",
    ),
  );
  assert.equal(t.records.length, 4);
  assert.equal(t.records[2].valid, false);
  assert.equal(t.records[3].type, "system");
  assert(!t.validate(0).accepted);
});
test("native-origin role-changing request cannot bypass original role guard", () => {
  const t = ready();
  t.replayUserMessages = true;
  send(t, "output", {
    type: "control_request",
    request_id: "role",
    request: {
      subtype: "apply_flag_settings",
      settings: { appendSystemPrompt: "fixture-change" },
    },
  });
  assert(!t.validate(0).checks.noRoleChangingControls);
});
console.log(
  JSON.stringify({
    passed: cases.length,
    scope: "grounded pure bidirectional controls",
    cases,
  }),
);

test("missing actual SDK auxiliary response rejects despite valid initialize", () => {
  const t = ready();
  t.replayUserMessages = true;
  send(t, "output", {
    type: "control_request",
    request_id: "pending",
    request: { subtype: "hook_callback" },
  });
  assert(!t.validate(0).checks.directionalControlsComplete);
});
test("missing native exact replay rejects completed reverse answer under replay flag", () => {
  const t = ready();
  t.replayUserMessages = true;
  send(t, "output", {
    type: "control_request",
    request_id: "pending",
    request: { subtype: "hook_callback" },
  });
  send(t, "input", ack("pending"));
  assert(!t.validate(0).checks.directionalControlsComplete);
});
console.log(
  JSON.stringify({
    passed: cases.length,
    scope: "complete grounded bidirectional controls",
    cases,
  }),
);

test("inflight unterminated bytes reject even before killed parent could deliver EOF", () => {
  const t = ready();
  t.feed("output", Buffer.from('{"type":'));
  assert(!t.validate(0).checks.noInflightFrames);
  const retained = t.summary().inflight.output;
  assert.equal(retained.utf8Bytes, 8);
  assert.equal(retained.sha256, sha(Buffer.from('{"type":')));
});
test("malformed UTF8 line is retained and subsequent valid line is observed", () => {
  const t = ready();
  t.feed(
    "output",
    Buffer.concat([
      Buffer.from([0xff, 10]),
      Buffer.from('{"type":"system"}\n'),
    ]),
  );
  assert.equal(t.records.at(-2).valid, false);
  assert.equal(t.records.at(-2).sha256, sha(Buffer.from([0xff])));
  assert.equal(t.records.at(-1).type, "system");
  assert(!t.validate(0).accepted);
});
console.log(
  JSON.stringify({
    passed: cases.length,
    scope: "all grounded protocol controls",
    cases,
  }),
);
