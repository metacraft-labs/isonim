## Phase B — daemon fixture for ``/api/agent/*`` tests.
##
## Spawns ``build/bin/isonim-review serve --agent-routes-only`` against
## an ephemeral port + a fake ACP agent.  No Postgres dependency — the
## agent routes are independent of REV-M7 design-review state.

import std/[net, os, osproc, posix, strtabs, strutils, times]
import std/httpclient

const RepoRoot* = currentSourcePath().parentDir().parentDir().parentDir()
const CliPath* = RepoRoot / "build" / "bin" / "isonim-review"
const FakeAcpPath* = RepoRoot / "build" / "bin" / "fake-acp-agent"

type
  AgentRoutesFixture* = ref object
    proc1*: Process
    port*: int
    baseUrl*: string
    cancelFile*: string
    contentLog*: string

proc pickFreePort*(): int =
  ## Bind a temporary listener to find a free port, then close it.
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
  let port = pickFreePort()
  var env = newStringTable(modeCaseSensitive)
  for kv in envPairs():
    env[kv.key] = kv.value
  env["ISONIM_ACP_AGENT_CMD"] = FakeAcpPath
  env["ISONIM_REVIEW_PORT"] = $port
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
  let proc1 = startProcess(CliPath,
    args = args,
    env = env,
    options = {poUsePath, poStdErrToStdOut})

  let curl = findExe("curl")
  if curl.len == 0:
    raise newException(IOError,
      "agent_routes_fixture: curl required for readiness probe")

  let baseUrl = "http://127.0.0.1:" & $port
  let deadline = epochTime() + 10.0
  var ready = false
  while epochTime() < deadline:
    # ``/health`` is unimplemented when --agent-routes-only is set (the
    # DB probes can't run without a PG), but the listener will respond
    # with 503 once it's bound.  We accept any HTTP status as "ready".
    let r = execCmdEx(curl & " -s -o /dev/null --max-time 0.5 -w '%{http_code}' " &
                      baseUrl & "/health")
    if r.exitCode == 0 and r.output.len > 0 and r.output != "000":
      ready = true
      break
    sleep(80)
  if not ready:
    try: discard kill(proc1.processID.Pid, SIGKILL)
    except: discard
    proc1.close()
    raise newException(IOError,
      "agent_routes_fixture: daemon failed to bind on " & baseUrl)
  AgentRoutesFixture(proc1: proc1, port: port, baseUrl: baseUrl,
                     cancelFile: cancelFile, contentLog: contentLog)

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
