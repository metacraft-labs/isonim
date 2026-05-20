## CMP-M2 — fixture that boots the real ``isonim-review`` daemon with
## both ``/api/agent/*`` and ``/api/campaign/*`` routes against an
## ephemeral PostgreSQL cluster + the fake ACP agent.
##
## Differs from ``agent_routes_fixture`` in two ways:
##   1. It launches a real ``PgFixture`` so ``/api/campaign/start`` can
##      INSERT into ``design_review.campaigns``.
##   2. It does NOT pass ``--agent-routes-only`` — the campaign routes
##      live behind the design-review route mount path (they re-use the
##      shared ``ReviewDb`` connection).
##
## The ``ISONIM_REVIEW_DB`` env var is set to the fixture's connection
## string before the daemon is spawned so the long-lived DB connection
## inside the daemon points at our ephemeral cluster, not at the dev
## process-compose one.

import std/[net, os, osproc, posix, strtabs, strutils, times]
import std/httpclient

import ./design_review_pg_fixture

const RepoRoot* = currentSourcePath().parentDir().parentDir().parentDir()
const CliPath* = RepoRoot / "build" / "bin" / "isonim-review"
const FakeAcpPath* = RepoRoot / "build" / "bin" / "fake-acp-agent"

type
  CampaignFixture* = ref object
    daemon*: Process
    pg*: PgFixture
    port*: int
    baseUrl*: string
    promptDir*: string

proc pickFreePort*(): int =
  let s = newSocket()
  defer:
    try: s.close() except CatchableError: discard
  s.bindAddr(Port(0), "127.0.0.1")
  let (_, p) = s.getLocalAddr()
  return int(p)

proc writePromptFixture(dir: string): string =
  ## The campaign daemon reads the orchestrator prompt from
  ## ``<workspace>/isonim/prompts/campaign-orchestrator.md`` — we
  ## provision a minimal fixture under ``dir`` so the daemon doesn't
  ## need the repo checkout's prompt to satisfy tests.
  let isonimDir = dir / "isonim"
  let promptsDir = isonimDir / "prompts"
  createDir(promptsDir)
  let promptPath = promptsDir / "campaign-orchestrator.md"
  writeFile(promptPath,
    "# Test Campaign Orchestrator Prompt\n\n" &
    "You are a fake orchestrator. Just reply.\n")
  return isonimDir

proc startCampaignDaemon*(extraEnv: openArray[(string, string)] = @[]):
    CampaignFixture =
  if not fileExists(CliPath):
    raise newException(IOError,
      "campaign_routes_fixture: missing " & CliPath &
      " — run `just isonim-review-build` first")
  if not fileExists(FakeAcpPath):
    raise newException(IOError,
      "campaign_routes_fixture: missing " & FakeAcpPath &
      " — run `just fake-acp-agent-build` first")
  let pg = newPgFixture()

  let promptRoot = getTempDir() / ("cmp_m2_workspace_" &
                   $((int(epochTime() * 1000)) mod 1_000_000))
  removeDir(promptRoot)
  createDir(promptRoot)
  discard writePromptFixture(promptRoot)

  let port = pickFreePort()
  var env = newStringTable(modeCaseSensitive)
  for kv in envPairs():
    env[kv.key] = kv.value
  env["ISONIM_ACP_AGENT_CMD"] = FakeAcpPath
  env["ISONIM_REVIEW_PORT"] = $port
  env["ISONIM_REVIEW_DB"] = pg.connectionString
  env["ISONIM_REVIEW_PGPORT"] = $pg.port
  env["ISONIM_REVIEW_PGHOST"] = "127.0.0.1"
  env["ISONIM_REVIEW_WORKSPACE"] = promptRoot
  for kv in extraEnv:
    env[kv[0]] = kv[1]

  # Tell the daemon to read the orchestrator prompt from our fixture
  # dir (we do this by writing a TOML config with [workspace].root
  # pointing at it — the daemon resolves
  # ``<workspace>/isonim/prompts/campaign-orchestrator.md``).
  let configPath = promptRoot / "config.toml"
  writeFile(configPath,
    "[workspace]\nroot = \"" & promptRoot & "\"\n")

  let daemon = startProcess(CliPath,
    args = @["serve", "--config", configPath,
             "--migrations", RepoRoot / "db" / "migrations"],
    env = env,
    options = {poUsePath, poStdErrToStdOut})

  let curl = findExe("curl")
  if curl.len == 0:
    raise newException(IOError,
      "campaign_routes_fixture: curl required for readiness probe")

  let baseUrl = "http://127.0.0.1:" & $port
  let deadline = epochTime() + 15.0
  var ready = false
  while epochTime() < deadline:
    let r = execCmdEx(curl & " -s -o /dev/null --max-time 0.5 -w '%{http_code}' " &
                      baseUrl & "/health")
    if r.exitCode == 0 and r.output.len > 0 and r.output != "000":
      ready = true
      break
    if not daemon.running():
      break
    sleep(120)
  if not ready:
    try: discard kill(daemon.processID.Pid, SIGKILL)
    except: discard
    daemon.close()
    pg.shutdown()
    raise newException(IOError,
      "campaign_routes_fixture: daemon failed to bind on " & baseUrl)
  CampaignFixture(daemon: daemon, pg: pg, port: port, baseUrl: baseUrl,
                  promptDir: promptRoot)

proc shutdown*(f: CampaignFixture) =
  if f == nil: return
  if f.daemon != nil:
    try: discard kill(f.daemon.processID.Pid, SIGTERM)
    except: discard
    let deadline = epochTime() + 2.0
    while epochTime() < deadline:
      if not f.daemon.running(): break
      sleep(40)
    if f.daemon.running():
      try: discard kill(f.daemon.processID.Pid, SIGKILL)
      except: discard
    discard f.daemon.waitForExit()
    f.daemon.close()
    f.daemon = nil
  if f.pg != nil:
    f.pg.shutdown()
    f.pg = nil
  try: removeDir(f.promptDir) except OSError: discard

proc campaignPost*(f: CampaignFixture; path, body: string;
                   timeoutMs = 30_000):
    tuple[code: int; body: string] =
  let client = newHttpClient(timeout = timeoutMs)
  defer: client.close()
  let headers = newHttpHeaders([("Content-Type", "application/json")])
  let resp = client.request(f.baseUrl & path, httpMethod = HttpPost,
                            body = body, headers = headers)
  (code: parseInt(resp.status.split(' ')[0]), body: resp.body)

proc campaignGet*(f: CampaignFixture; path: string; timeoutMs = 10_000):
    tuple[code: int; body: string] =
  let client = newHttpClient(timeout = timeoutMs)
  defer: client.close()
  let resp = client.request(f.baseUrl & path, httpMethod = HttpGet)
  (code: parseInt(resp.status.split(' ')[0]), body: resp.body)

proc rawPostStream*(baseUrl, path, body: string;
                    timeoutMs = 30_000): tuple[status: int; raw: string] =
  ## Raw socket-level POST for SSE — same shape as the one in
  ## ``agent_routes_fixture`` / ``test_design_review_daemon_agent_routes``,
  ## copied here so the campaign tests don't need to import the agent
  ## fixture.
  let parts = baseUrl.replace("http://", "").split(':')
  let host = parts[0]
  let port = parseInt(parts[1])
  let sock = newSocket()
  defer:
    try: sock.close() except CatchableError: discard
  sock.connect(host, Port(port), timeout = 5_000)
  var req = "POST " & path & " HTTP/1.1\c\L"
  req.add "Host: " & host & ":" & $port & "\c\L"
  req.add "Content-Type: application/json\c\L"
  req.add "Content-Length: " & $body.len & "\c\L"
  req.add "Accept: text/event-stream\c\L"
  req.add "Connection: close\c\L"
  req.add "\c\L"
  req.add body
  sock.send(req)
  var buf = ""
  while true:
    var chunk = newString(1024)
    let n = sock.recv(addr chunk[0], 1024, timeout = timeoutMs)
    if n <= 0: break
    buf.add chunk[0 ..< n]
  let firstLine = buf.split('\n', maxsplit = 1)
  var status = 0
  if firstLine.len > 0 and firstLine[0].startsWith("HTTP/"):
    let p = firstLine[0].split(' ')
    if p.len >= 2:
      try: status = parseInt(p[1]) except ValueError: discard
  let split = buf.find("\r\n\r\n")
  let rawBody = if split >= 0: buf[split + 4 .. ^1] else: buf
  return (status, rawBody)

# ---------------------------------------------------------------------------
# Direct DB introspection for tests — bypasses the routine layer to verify
# rows were written.  Used to check campaign + event row counts and shapes.
# ---------------------------------------------------------------------------

import db_connector/db_postgres

proc connectMigrator*(f: CampaignFixture): DbConn =
  open("", "design_review_migrator", "",
       "host=127.0.0.1 port=" & $f.pg.port &
       " dbname=isonim_design_review user=design_review_migrator")

proc countCampaigns*(f: CampaignFixture): int =
  let db = connectMigrator(f)
  defer: db.close()
  parseInt(db.getValue(sql"SELECT count(*) FROM design_review.campaigns"))

proc fetchCampaignByDoc*(f: CampaignFixture; docPath: string): seq[seq[string]] =
  let db = connectMigrator(f)
  defer: db.close()
  for row in db.fastRows(sql"""
      SELECT campaign_id::text, status, max_iterations, manifest_hash,
             agent_backend, started_by, doc_sha
      FROM design_review.campaigns WHERE doc_path = ?""", docPath):
    result.add row

proc eventsForCampaign*(f: CampaignFixture; campaignId: string):
    seq[tuple[kind, payload: string]] =
  let db = connectMigrator(f)
  defer: db.close()
  for row in db.fastRows(sql"""
      SELECT event_kind, payload::text
      FROM design_review.campaign_events
      WHERE campaign_id = ?::uuid
      ORDER BY occurred_at ASC""", campaignId):
    result.add (kind: row[0], payload: row[1])
