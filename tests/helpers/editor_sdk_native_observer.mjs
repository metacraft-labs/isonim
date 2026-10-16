/** Private diagnostic observer, never a substitute provider.
 * Real SDK/native/ACP bytes remain unchanged. Pure parser fixtures are separately
 * justified in their test file; neither they nor this observer prove API prompt
 * placement or model compliance. stdin.write/stdout.push delegation preserves
 * original return values, callback arguments, encoding, flow and emitted errors.
 * No data listener or reader is added to stdout. Preload env is restored before
 * importing the SDK; only the configured native stream-json child is observed.
 */
import childProcess from "node:child_process";
import { syncBuiltinESMExports } from "node:module";
import { createHash } from "node:crypto";
import { TextDecoder } from "node:util";
import {
  readFileSync,
  writeFileSync,
  renameSync,
  lstatSync,
  readlinkSync,
  constants,
  openSync,
  closeSync,
  fsyncSync,
} from "node:fs";
import path from "node:path";
export const sha = (value) => createHash("sha256").update(value).digest("hex");
const canonical = (value) =>
  JSON.stringify(value, (key, item) =>
    item && typeof item === "object" && !Array.isArray(item)
      ? Object.fromEntries(
          Object.keys(item)
            .sort()
            .map((key) => [key, item[key]]),
        )
      : item,
  );
export class ProtocolEvidence {
  constructor(expected, { replayUserMessages = false } = {}) {
    this.expected = expected;
    this.replayUserMessages = replayUserMessages;
    this.decoders = {
      input: new TextDecoder("utf8", { fatal: true }),
      output: new TextDecoder("utf8", { fatal: true }),
    };
    this.pending = { input: Buffer.alloc(0), output: Buffer.alloc(0) };
    this.requests = new Map();
    this.nativeRequests = new Map();
    this.ackIds = new Set();
    this.nativeResponses = new Map();
    this.echoIds = new Set();
    this.records = [];
    this.errors = [];
    this.initialize = [];
    this.users = [];
    this.roleChanging = [];
    this.outputKinds = {};
  }
  error(where, error) {
    this.errors.push({
      where,
      errorName: error?.name ?? "Error",
      messageSha256: sha(String(error?.message ?? error)),
    });
  }
  feed(direction, bytes) {
    this.pending[direction] = Buffer.concat([
      this.pending[direction],
      Buffer.from(bytes),
    ]);
    while (this.pending[direction].includes(10)) {
      const at = this.pending[direction].indexOf(10),
        raw = this.pending[direction].subarray(0, at);
      this.pending[direction] = this.pending[direction].subarray(at + 1);
      if (!raw.length) continue;
      let line;
      try {
        line = new TextDecoder("utf8", { fatal: true }).decode(raw);
      } catch (e) {
        this.records.push({
          order: this.records.length,
          direction,
          sha256: sha(raw),
          utf8Bytes: raw.length,
          type: null,
          valid: false,
        });
        this.error(direction, e);
        continue;
      }
      try {
        this.frame(direction, line);
      } catch (e) {
        this.error(direction, e);
      }
    }
  }
  finish(direction) {
    if (this.pending[direction].length) {
      this.records.push({
        order: this.records.length,
        direction,
        sha256: sha(this.pending[direction]),
        utf8Bytes: this.pending[direction].length,
        type: null,
        valid: false,
        eofIncomplete: true,
      });
      this.error(
        direction + "EOF",
        new Error("Incomplete protocol bytes at EOF"),
      );
    }
  }
  frame(direction, line) {
    const record = {
      order: this.records.length,
      direction,
      sha256: sha(line),
      utf8Bytes: Buffer.byteLength(line),
      valid: false,
    };
    this.records.push(record);
    const frame = JSON.parse(line);
    if (!frame || typeof frame !== "object" || Array.isArray(frame))
      throw new Error("Protocol frame must be object");
    record.type = typeof frame.type === "string" ? frame.type : null;
    if (direction === "output")
      this.outputKinds[record.type] = (this.outputKinds[record.type] ?? 0) + 1;
    if (frame.type === "control_request") {
      record.requestIdSha256 =
        typeof frame.request_id === "string" ? sha(frame.request_id) : null;
      record.subtype =
        typeof frame.request?.subtype === "string"
          ? frame.request.subtype
          : null;
      if (
        !record.requestIdSha256 ||
        frame.request_id.length === 0 ||
        !record.subtype
      )
        throw new Error("Malformed control request");
      if (
        this.requests.has(frame.request_id) ||
        this.nativeRequests.has(frame.request_id)
      )
        throw new Error("Repeated control request ID");
      const map = direction === "input" ? this.requests : this.nativeRequests;
      map.set(frame.request_id, record);
      record.transaction =
        direction === "input" ? "sdk-request" : "native-request";
      const changing = [
        "systemPrompt",
        "appendSystemPrompt",
        "excludeDynamicSections",
        "planModeInstructions",
        "appendSubagentSystemPrompt",
      ].filter(
        (k) =>
          Object.hasOwn(frame.request, k) ||
          Object.hasOwn(frame.request.settings ?? {}, k),
      );
      if (record.subtype === "initialize" && direction === "input") {
        const text = frame.request.appendSystemPrompt;
        record.appendPresent = typeof text === "string";
        record.appendSha256 = record.appendPresent ? sha(text) : null;
        record.appendUtf8Bytes = record.appendPresent
          ? Buffer.byteLength(text)
          : null;
        record.exactAppend =
          record.appendSha256 === this.expected.sha256 &&
          record.appendUtf8Bytes === this.expected.utf8Bytes;
        record.replacementSystemPromptPresent = Object.hasOwn(
          frame.request,
          "systemPrompt",
        );
        this.initialize.push(record);
      } else if (changing.length) {
        record.roleChangingKeys = changing;
        this.roleChanging.push(record);
      }
    }
    if (direction === "input" && frame.type === "user") {
      if (frame.message?.role !== "user")
        throw new Error("Malformed human frame");
      record.contentSha256 = sha(JSON.stringify(frame.message.content));
      record.sessionIdSha256 =
        typeof frame.session_id === "string" ? sha(frame.session_id) : null;
      this.users.push(record);
    }
    if (frame.type === "control_response") {
      const response = frame.response;
      record.requestIdSha256 =
        typeof response?.request_id === "string"
          ? sha(response.request_id)
          : null;
      record.subtype =
        typeof response?.subtype === "string" ? response.subtype : null;
      if (
        !record.requestIdSha256 ||
        response.request_id.length === 0 ||
        !["success", "error"].includes(record.subtype) ||
        (Object.hasOwn(response, "response") &&
          (typeof response.response !== "object" ||
            response.response === null ||
            Array.isArray(response.response)))
      )
        throw new Error("Malformed control ACK");
      record.responseSha256 = sha(canonical(response));
      record.success = response.subtype === "success";
      if (direction === "input") {
        const request = this.nativeRequests.get(response.request_id);
        record.requestSubtype = request?.subtype ?? null;
        record.requestOrder = request?.order ?? null;
        record.transaction = "sdk-response";
        if (!request) throw new Error("Uncorrelated SDK response");
        if (this.nativeResponses.has(response.request_id))
          throw new Error("Duplicate SDK response");
        this.nativeResponses.set(response.request_id, record);
        if (!record.success) throw new Error("SDK auxiliary response error");
      } else {
        const request = this.requests.get(response.request_id);
        record.requestSubtype =
          request?.subtype ??
          this.nativeRequests.get(response.request_id)?.subtype ??
          null;
        if (request) {
          record.requestOrder = request.order;
          record.transaction = "native-ack";
          if (this.ackIds.has(response.request_id))
            throw new Error("Duplicate control ACK");
          this.ackIds.add(response.request_id);
        } else {
          record.transaction = "native-response-replay";
          const answered = this.nativeResponses.get(response.request_id);
          record.requestOrder =
            this.nativeRequests.get(response.request_id)?.order ?? null;
          record.responseOrder = answered?.order ?? null;
          if (
            !this.replayUserMessages ||
            !answered ||
            !answered.valid ||
            record.responseSha256 !== answered.responseSha256
          )
            throw new Error(
              "Uncorrelated or mismatched native response replay",
            );
          if (this.echoIds.has(response.request_id))
            throw new Error("Duplicate native response replay");
          this.echoIds.add(response.request_id);
        }
        if (!record.success) throw new Error("Native control response error");
      }
    }
    record.valid = true;
  }
  summary() {
    return {
      inflight: Object.fromEntries(
        Object.entries(this.pending).map(([direction, bytes]) => [
          direction,
          { utf8Bytes: bytes.length, sha256: sha(bytes) },
        ]),
      ),
      replayUserMessages: this.replayUserMessages,
      initialize: this.initialize,
      users: this.users,
      roleChanging: this.roleChanging,
      records: this.records,
      errors: this.errors,
      outputKinds: this.outputKinds,
    };
  }
  validate(expectedUsers) {
    const directionalControlsComplete = this.records
      .filter((x) => x.direction === "output" && x.type === "control_request")
      .every((request) => {
        const responses = this.records.filter(
          (x) =>
            x.transaction === "sdk-response" &&
            x.requestIdSha256 === request.requestIdSha256 &&
            x.valid &&
            x.success &&
            x.requestOrder === request.order &&
            x.order > request.order,
        );
        if (responses.length !== 1) return false;
        const echoes = this.records.filter(
          (x) =>
            x.transaction === "native-response-replay" &&
            x.requestIdSha256 === request.requestIdSha256 &&
            x.valid &&
            x.success &&
            x.responseOrder === responses[0].order &&
            x.order > responses[0].order &&
            x.responseSha256 === responses[0].responseSha256,
        );
        return echoes.length === (this.replayUserMessages ? 1 : 0);
      });
    const checks = {
      noInflightFrames: Object.values(this.pending).every(
        (bytes) => bytes.length === 0,
      ),
      directionalControlsComplete,
      parserClean: this.errors.length === 0,
      oneInitialize: this.initialize.length === 1,
      exactAppend:
        this.initialize.length === 1 && this.initialize[0].exactAppend,
      presetRetained:
        this.initialize.length === 1 &&
        !this.initialize[0].replacementSystemPromptPresent,
      realCorrelatedInitializeSuccess:
        this.records.filter(
          (x) =>
            x.direction === "output" &&
            x.type === "control_response" &&
            x.requestSubtype === "initialize" &&
            x.transaction === "native-ack" &&
            x.valid &&
            x.success,
        ).length === 1,
      noRoleChangingControls: this.roleChanging.length === 0,
      userCount: this.users.length === expectedUsers,
    };
    return { checks, accepted: Object.values(checks).every(Boolean) };
  }
}
const configPath = process.env.ISONIM_SDK_OBSERVER_CONFIG;
if (configPath) {
  const config = JSON.parse(readFileSync(configPath, "utf8"));
  // Consume observer-only env before any SDK module executes or env is snapped.
  delete process.env.ISONIM_SDK_OBSERVER_CONFIG;
  if (config.originalNodeOptions.present)
    process.env.NODE_OPTIONS = config.originalNodeOptions.value;
  else delete process.env.NODE_OPTIONS;
  if ((lstatSync(config.directory).mode & 0o777) !== 0o700)
    throw new Error("Observer directory must be private0700");
  const expected = config.expected;
  const allowed = new Set(config.commands);
  const spawn = childProcess.spawn;
  childProcess.spawn = function (...args) {
    const [command, argv = []] = args;
    const target =
      allowed.has(command) &&
      argv.includes("--input-format") &&
      argv.includes("stream-json");
    // Original receiver/arguments, defaults, and spawn errors retained exactly.
    const child = Reflect.apply(spawn, this, args);
    if (!target) return child;
    const tracker = new ProtocolEvidence(expected, {
      replayUserMessages: argv.includes("--replay-user-messages"),
    });
    const state = {
      observerPid: process.pid,
      nativePid: child.pid,
      parentIdentity: {
        pid: process.pid,
        node: process.execPath,
        loadedSha256: sha(readFileSync(`/proc/${process.pid}/exe`)),
      },
      spawn: {
        commandSha256: sha(command),
        argvSha256: sha(JSON.stringify(argv)),
        cwdExpectedSha256: sha(path.resolve(args[2]?.cwd ?? process.cwd())),
        environmentSha256: sha(
          JSON.stringify(Object.entries(args[2]?.env ?? process.env).sort()),
        ),
        observerEnvAbsent: !Object.hasOwn(
          args[2]?.env ?? process.env,
          "ISONIM_SDK_OBSERVER_CONFIG",
        ),
        parentNodeOptionsRestored:
          process.env.NODE_OPTIONS ===
          (config.originalNodeOptions.present
            ? config.originalNodeOptions.value
            : undefined),
        nodeOptionsRestored: !Object.hasOwn(
          args[2]?.env ?? process.env,
          "NODE_OPTIONS",
        ),
      },
      identity: null,
      lifecycle: [],
      writeCalls: 0,
      pushCalls: 0,
      errors: [],
    };
    const destination = path.join(
      config.directory,
      `sdk-native-${process.pid}-${child.pid}.json`,
    );
    let identityChecked = false;
    function identity() {
      if (identityChecked) return;
      try {
        const exe = readlinkSync(`/proc/${child.pid}/exe`);
        if (exe !== config.loadedExecutable) return;
        const start = readFileSync(`/proc/${child.pid}/stat`, "utf8")
          .split(") ")[1]
          .split(" ")[19];
        const loadedSha256 = sha(readFileSync(`/proc/${child.pid}/exe`));
        state.identity = {
          pid: child.pid,
          starttime: start,
          executable: exe,
          loadedSha256,
          loadedMatches: loadedSha256 === config.loadedSha256,
          cwdMatches:
            sha(readlinkSync(`/proc/${child.pid}/cwd`)) ===
            state.spawn.cwdExpectedSha256,
          argvSha256: sha(readFileSync(`/proc/${child.pid}/cmdline`)),
          environmentSha256: sha(readFileSync(`/proc/${child.pid}/environ`)),
        };
        identityChecked = true;
      } catch (e) {
        if (e.code !== "ENOENT" && e.code !== "ESRCH")
          tracker.error("processIdentity", e);
      }
    }
    function flush() {
      try {
        identity();
        const file = destination + ".pending";
        const fd = openSync(
          file,
          constants.O_WRONLY |
            constants.O_CREAT |
            constants.O_TRUNC |
            constants.O_NOFOLLOW,
          0o600,
        );
        try {
          writeFileSync(
            fd,
            JSON.stringify({ ...state, protocol: tracker.summary() }, null, 2) +
              "\n",
          );
          fsyncSync(fd);
        } finally {
          closeSync(fd);
        }
        renameSync(file, destination);
      } catch (e) {
        state.errors.push({
          where: "privateRecorder",
          errorName: e.name,
          messageSha256: sha(String(e.message)),
        });
      }
    }
    function bytes(chunk, encoding) {
      return typeof chunk === "string"
        ? Buffer.from(chunk, typeof encoding === "string" ? encoding : "utf8")
        : Buffer.from(chunk);
    }
    const write = child.stdin.write;
    child.stdin.write = function (...writeArgs) {
      let returned;
      try {
        returned = Reflect.apply(write, this, writeArgs);
      } catch (e) {
        tracker.error("stdinWrite", e);
        flush();
        throw e;
      }
      try {
        state.writeCalls++;
        tracker.feed("input", bytes(writeArgs[0], writeArgs[1]));
        flush();
      } catch (e) {
        tracker.error("stdinObserver", e);
        flush();
      }
      return returned;
    };
    const push = child.stdout.push;
    child.stdout.push = function (...pushArgs) {
      try {
        state.pushCalls++;
        if (pushArgs[0] === null) tracker.finish("output");
        else tracker.feed("output", bytes(pushArgs[0], pushArgs[1]));
        flush();
      } catch (e) {
        tracker.error("stdoutObserver", e);
        flush();
      }
      return Reflect.apply(push, this, pushArgs);
    };
    for (const [label, stream] of [
      ["stdin", child.stdin],
      ["stdout", child.stdout],
    ]) {
      const originalEmit = stream.emit;
      stream.emit = function (event, ...values) {
        if (event === "error") {
          tracker.error(label + "Stream", values[0]);
          flush();
        }
        return Reflect.apply(originalEmit, this, [event, ...values]);
      };
    }
    const emit = child.emit;
    child.emit = function (event, ...values) {
      if (["error", "exit", "close"].includes(event)) {
        try {
          if (event === "error") tracker.error("child", values[0]);
          else
            state.lifecycle.push({ event, code: values[0], signal: values[1] });
          if (event === "close") tracker.finish("input");
          flush();
        } catch (e) {
          tracker.error("childObserver", e);
        }
      }
      return Reflect.apply(emit, this, [event, ...values]);
    };
    flush();
    return child;
  };
  syncBuiltinESMExports();
}
