## Phase B — daemon fixture for ``/api/agent/*`` tests.
##
## Spawns ``build/bin/isonim-review serve --agent-routes-only`` against
## an ephemeral port + a fake ACP agent.  No Postgres dependency — the
## agent routes are independent of REV-M7 design-review state.

import std/[net, os, osproc, posix, strtabs, strutils, times]
import std/httpclient

import ./daemon_ready_handshake

const RepoRoot* = currentSourcePath().parentDir().parentDir().parentDir()
const CliPath* = RepoRoot / "build" / "bin" / "isonim-review"
const FakeAcpPath* = RepoRoot / "build" / "bin" / "fake-acp-agent"

type
  AgentRoutesFixture* = ref object
    proc1*: Process
    drainer*: DaemonStderrDrainer
    port*: int
    baseUrl*: string
    cancelFile*: string
    contentLog*: string

proc pickFreePort*(): int {.deprecated:
    "prefer ISONIM_REVIEW_PORT=0 + waitForReady — see " &
    "tests/helpers/daemon_ready_handshake.nim".} =
  ## Retained only for API compatibility with any external caller.
  ## The fixture itself no longer uses this — it lets the daemon pick
  ## the port and reports it back via the READY handshake.
  let s = newSocket()
  defer:
    try: s.close() except CatchableError: discard
  s.bindAddr(Port(0), "127.0.0.1")
  let (_, p) = s.getLocalAddr()
  return int(p)

proc startAgentDaemon*(extraEnv: openArray[(string, string)] = @[];
                        configPath: string = ""): AgentRoutesFixture =
  if not fileExists(CliPath):
    raise newException(IOError,
      "agent_routes_fixture: missing " & CliPath &
      " — run `just isonim-review-build` first")
  if not fileExists(FakeAcpPath):
    raise newException(IOError,
      "agent_routes_fixture: missing " & FakeAcpPath &
      " — run `just fake-acp-agent-build` first")
  # ISONIM_REVIEW_PORT=0 → daemon picks any free port via Port(0) and
  # reports the actual port back via the ``READY <port>`` stderr line
  # (see daemon_ready_handshake.nim).  Eliminates the TOCTOU race the
  # pre-pick pattern suffered from.
  var env = newStringTable(modeCaseSensitive)
  for kv in envPairs():
    env[kv.key] = kv.value
  env["ISONIM_ACP_AGENT_CMD"] = FakeAcpPath
  env["ISONIM_REVIEW_PORT"] = "0"
  for kv in extraEnv:
    env[kv[0]] = kv[1]
  let cancelFile = getTempDir() / "fake_acp_cancel_" &
                   $((int(epochTime() * 1000)) mod 1_000_000) & ".log"
  env["FAKE_ACP_CANCEL_FILE"] = cancelFile
  let contentLog = getTempDir() / "fake_acp_content_" &
                   $((int(epochTime() * 1000)) mod 1_000_000) & ".log"
  env["FAKE_ACP_CONTENT_LOG"] = contentLog

  var args: seq[string] = @["serve", "--agent-routes-only"]
  if configPath.len > 0:
    args.add "--config"
    args.add configPath
  # ``poUsePath`` only — stderr must stay independently readable so
  # the drainer can pull READY off it.
  let proc1 = startProcess(CliPath,
    args = args,
    env = env,
    options = {poUsePath})

  let drainer = startStderrDrainer(proc1)
  var port: int
  try:
    port = waitForReady(drainer, timeoutSecs = 15.0)
  except IOError as e:
    drainer.shutdown()
    try: discard kill(proc1.processID.Pid, SIGKILL)
    except: discard
    proc1.close()
    raise newException(IOError, "agent_routes_fixture: " & e.msg)

  let baseUrl = "http://127.0.0.1:" & $port
  AgentRoutesFixture(proc1: proc1, drainer: drainer, port: port,
                     baseUrl: baseUrl, cancelFile: cancelFile,
                     contentLog: contentLog)

proc shutdown*(f: AgentRoutesFixture) =
  if f == nil or f.proc1 == nil: return
  try: discard kill(f.proc1.processID.Pid, SIGTERM)
  except: discard
  let deadline = epochTime() + 2.0
  while epochTime() < deadline:
    if not f.proc1.running(): break
    sleep(40)
  if f.proc1.running():
    try: discard kill(f.proc1.processID.Pid, SIGKILL)
    except: discard
  discard f.proc1.waitForExit()
  f.proc1.close()
  f.proc1 = nil
  if f.drainer != nil:
    f.drainer.shutdown()
    f.drainer = nil
  try: removeFile(f.cancelFile) except OSError: discard
  try: removeFile(f.contentLog) except OSError: discard

proc agentPost*(f: AgentRoutesFixture; path, body: string;
                timeoutMs = 10_000):
    tuple[code: int; body: string] =
  let client = newHttpClient(timeout = timeoutMs)
  defer: client.close()
  let headers = newHttpHeaders([("Content-Type", "application/json")])
  let resp = client.request(f.baseUrl & path, httpMethod = HttpPost,
                            body = body, headers = headers)
  (code: parseInt(resp.status.split(' ')[0]), body: resp.body)

import std/json as agentRoutesFixtureJson

proc readContentLogEntries*(f: AgentRoutesFixture): seq[agentRoutesFixtureJson.JsonNode] =
  ## CMP-M5 — read the fixture's content log so chat-priming tests can
  ## inspect the primer prompt body the daemon shipped to the fake-ACP.
  if f == nil or f.contentLog.len == 0: return @[]
  if not fileExists(f.contentLog): return @[]
  let raw = readFile(f.contentLog)
  for line in raw.splitLines():
    let s = line.strip()
    if s.len == 0: continue
    try:
      result.add agentRoutesFixtureJson.parseJson(s)
    except agentRoutesFixtureJson.JsonParsingError:
      discard

proc primerEntries*(f: AgentRoutesFixture): seq[agentRoutesFixtureJson.JsonNode] =
  ## CMP-M5 — filter the content log down to primer entries (those
  ## written by ``logPrimerPrompt``).
  for e in readContentLogEntries(f):
    if e == nil: continue
    if e{"source"}.getStr("") == "primer":
      result.add e

proc latestPrimerPromptText*(f: AgentRoutesFixture): string =
  ## CMP-M5 — return the ``promptText`` field of the most recent primer
  ## entry, or ``""`` when none exists.
  let entries = primerEntries(f)
  if entries.len == 0: return ""
  entries[^1]{"promptText"}.getStr("")

proc countPrompts*(f: AgentRoutesFixture; sessionId: string = ""): int =
  ## CMP-M5 — count the ``session/prompt`` entries the fake-ACP
  ## recorded.  Filter by ``sessionId`` when non-empty.  Used by
  ## ``test_chat_session_primer_is_one_turn`` to assert the primer
  ## counts as exactly one round-trip.
  for e in readContentLogEntries(f):
    if e == nil: continue
    if e{"source"}.getStr("") != "fake_acp": continue
    if sessionId.len > 0 and e{"sessionId"}.getStr("") != sessionId:
      continue
    inc result
