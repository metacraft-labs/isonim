## CMP-M2 — ``isonim-review campaign`` subcommand.
##
## Drives the daemon's ``/api/campaign/*`` endpoints from the command
## line.  Six sub-subcommands:
##
##   * ``start --doc <path>``    — open the campaign doc, validate
##     brief references, POST ``/api/campaign/start``, stream the SSE
##     response.  Stdout receives the orchestrator's text chunks;
##     lifecycle events land on stderr.
##   * ``list   [--status]``     — GET ``/api/campaign/list`` and pretty-
##     print a table.
##   * ``show   <id>``           — GET ``/api/campaign/fetch`` and pretty-
##     print the campaign row + most-recent events.
##   * ``tail   <id> [--follow]``— GET ``/api/campaign/events`` once (or
##     in a polling loop with ``--follow``) and stream events to stdout.
##   * ``tick   <id>``           — POST ``/api/campaign/tick`` and stream
##     the SSE response (same shape as ``start`` but without opening a
##     new session).
##   * ``stop   <id>``           — POST ``/api/campaign/stop``; prints
##     the new status on stdout.
##
## Output discipline mirrors ``isonim-review chat``: agent text →
## stdout, lifecycle/chronicles → stderr.

import std/[httpclient, json, net, os, sha1, strutils, tables]

import isonim/editor/design_review/brief_format
import isonim/editor/design_review/brief_index
import isonim/editor/design_review/campaign_format
import isonim/editor/design_review/log_setup

import ./cmd_chat
import ./config

logScope:
  topics = "cli"

type
  CampaignStartOptions* = object
    docPath*:   string
    backend*:   string
    daemonUrl*: string
    noTail*:    bool
    briefsDir*: string
    projectDir*: string
    startedBy*: string

  CampaignListOptions* = object
    daemonUrl*: string
    status*:    string
    limit*:     int
    offset*:    int

  CampaignShowOptions* = object
    daemonUrl*: string
    campaignId*: string
    eventLimit*: int

  CampaignTailOptions* = object
    daemonUrl*: string
    campaignId*: string
    follow*:    bool
    intervalMs*: int

  CampaignTickOptions* = object
    daemonUrl*: string
    campaignId*: string
    noTail*: bool

  CampaignStopOptions* = object
    daemonUrl*: string
    campaignId*: string
    reason*:    string

# --------------------------------------------------------------------------
# Helpers — doc hashing and brief resolution.
# --------------------------------------------------------------------------

proc sha256OfFile*(path: string): string =
  ## SHA-256 of the file at ``path`` as lowercase hex.  We shell out via
  ## the existing ``shasum -a 256`` path used by ``cmd_init.nim`` so the
  ## hash format matches the migration manifest verbatim.
  let exe = findExe("shasum")
  let r =
    if exe.len > 0:
      execShellCmd(exe & " -a 256 " & quoteShell(path) &
                   " > " & quoteShell(path & ".sha"))
    else:
      execShellCmd("sha256sum " & quoteShell(path) &
                   " > " & quoteShell(path & ".sha"))
  if r != 0:
    raise newException(IOError,
      "isonim-review campaign: sha256 of " & path & " failed")
  let raw = readFile(path & ".sha")
  removeFile(path & ".sha")
  let parts = raw.splitWhitespace()
  if parts.len == 0:
    raise newException(IOError,
      "isonim-review campaign: sha256 of " & path & " returned no output")
  parts[0].toLowerAscii()

proc sha256OfString(s: string): string =
  ## Deterministic content hash from the in-memory bytes.  We use Nim's
  ## SHA-1 (stdlib) as the in-memory hash because the dev shell has no
  ## stable in-process SHA-256, and the doc hash is only used as an
  ## idempotency key inside ``design_review.campaigns``.  The disk path
  ## above is the canonical hash; this is a fallback used only when
  ## tests construct a CampaignStartBody in memory.
  $secureHash(s)

proc resolveBriefBodies*(refs: seq[string]; briefsDir: string):
    tuple[bodies: seq[tuple[briefId, body: string]]; missing: seq[string]] =
  ## Walk ``briefsDir`` (recursively) for ``*.md`` brief files; for each
  ## ``briefId`` in ``refs`` return the full markdown body via
  ## :proc:`brief_format.parseBrief`.  Missing briefs land in
  ## ``result.missing`` so the caller can surface a clear error.
  let idx = buildBriefIndex(briefsDir)
  for r in refs:
    if idx.byBriefId.hasKey(r):
      result.bodies.add (briefId: r, body: idx.byBriefId[r].bodyMarkdown)
    else:
      result.missing.add r

proc guessBriefsDir*(docPath: string; explicit: string): string =
  ## Pick the directory we walk to resolve ``briefRefs``.  Resolution
  ## order:
  ##   1. ``--briefs-dir`` if non-empty.
  ##   2. ``<project>/briefs`` where ``<project>`` is two directories up
  ##      from ``docPath`` (matches the on-disk layout
  ##      ``<project>/campaigns/<slug>.md``).
  ##   3. ``<cwd>/briefs`` as a last resort.
  if explicit.len > 0:
    return explicit
  let docDir = docPath.parentDir
  let projectRoot = docDir.parentDir
  let candidate = projectRoot / "briefs"
  if dirExists(candidate):
    return candidate
  return getCurrentDir() / "briefs"

# --------------------------------------------------------------------------
# Subcommand: start
# --------------------------------------------------------------------------

proc loadCampaignDocOrDie(path: string): CampaignDoc =
  if not fileExists(path):
    stderr.writeLine "isonim-review campaign: doc not found: " & path
    quit(2)
  let raw =
    try: readFile(path)
    except IOError as e:
      stderr.writeLine "isonim-review campaign: cannot read " & path & ": " & e.msg
      quit(2)
  try:
    return parseCampaignDoc(path, raw)
  except CampaignDocParseError as e:
    stderr.writeLine "isonim-review campaign: parse error: " & e.msg
    quit(2)

proc streamCampaignSse(daemonUrl, path, body: string;
                       campaignIdOut: var string;
                       stopReasonOut: var string;
                       sawTextOut: var bool;
                       writeText: bool = true) =
  ## Send a POST to the daemon and stream the SSE response.  Text chunks
  ## go to stdout; non-text frames go to stderr (parsed compactly).
  let parsed = parseUrl(daemonUrl)
  let sock = newSocket()
  defer:
    try: sock.close() except CatchableError: discard
  try:
    sock.connect(parsed.host, Port(parsed.port), timeout = 5_000)
  except OSError as e:
    raise newException(IOError,
      "campaign stream: cannot connect to " & daemonUrl & ": " & e.msg)
  let base =
    if parsed.path == "/": ""
    elif parsed.path.endsWith("/"): parsed.path[0 .. ^2]
    else: parsed.path
  var req = "POST " & base & path & " HTTP/1.1\c\L"
  req.add "Host: " & parsed.host & ":" & $parsed.port & "\c\L"
  req.add "Content-Type: application/json\c\L"
  req.add "Content-Length: " & $body.len & "\c\L"
  req.add "Accept: text/event-stream\c\L"
  req.add "Connection: close\c\L"
  req.add "\c\L"
  req.add body
  sock.send(req)
  let (status, _) = readHttpHeader(sock)
  if status != 200:
    var remainder = ""
    while true:
      var chunk = newString(1024)
      let n = sock.recv(addr chunk[0], 1024, timeout = 1_000)
      if n <= 0: break
      remainder.add chunk[0 ..< n]
    raise newException(IOError,
      "campaign stream: daemon rejected (" & $status & "): " & remainder)
  while true:
    let (event, eof) = readSseEvent(sock)
    if eof and event.data.len == 0 and event.eventType.len == 0:
      break
    case event.eventType
    of "session/update", "":
      if event.data.len == 0:
        if eof: break
        continue
      try:
        let node = parseJson(event.data)
        let update = node{"update"}
        let kind = update{"sessionUpdate"}.getStr("")
        if kind == "agent_message_chunk":
          let content = update{"content"}
          if content != nil and content{"type"}.getStr("") == "text":
            let text = content{"text"}.getStr("")
            if text.len > 0:
              sawTextOut = true
              if writeText:
                stdout.write text
                flushFile(stdout)
              continue
        stderr.writeLine "campaign.update " & kind
      except JsonParsingError:
        stderr.writeLine "campaign.update (unparsed)"
    of "end":
      try:
        let node = parseJson(event.data)
        stopReasonOut = node{"stopReason"}.getStr("")
        let cid = node{"campaignId"}.getStr("")
        if cid.len > 0 and campaignIdOut.len == 0:
          campaignIdOut = cid
      except JsonParsingError: discard
      return
    of "error":
      stderr.writeLine "campaign.error " & event.data
    else:
      stderr.writeLine "campaign.event(" & event.eventType & ") " & event.data
    if eof: break

proc cmdCampaignStart*(cfg: ReviewConfig; opts: CampaignStartOptions): int =
  let doc = loadCampaignDocOrDie(opts.docPath)
  let docSha =
    try: sha256OfFile(opts.docPath)
    except IOError as e:
      stderr.writeLine "isonim-review campaign start: " & e.msg
      return 4

  # Resolve brief bodies.  Missing briefs are a fatal error — the
  # orchestrator can't begin without them.
  let briefsDir = guessBriefsDir(opts.docPath, opts.briefsDir)
  let resolution = resolveBriefBodies(doc.briefRefs, briefsDir)
  if resolution.missing.len > 0:
    stderr.writeLine "isonim-review campaign start: missing brief(s): " &
      resolution.missing.join(", ") &
      " (searched in " & briefsDir & ")"
    return 4

  if doc.maxIterations <= 0:
    stderr.writeLine "isonim-review campaign start: maxIterations must be positive"
    return 4
  if doc.hasTargetScore and (doc.targetScore <= 0.0 or doc.targetScore > 10.0):
    stderr.writeLine "isonim-review campaign start: targetScore out of range (0..10): " & $doc.targetScore
    return 4

  let baseUrl =
    if opts.daemonUrl.len > 0: opts.daemonUrl
    else: daemonBaseUrl(cfg)

  var briefsJson = newJArray()
  for b in resolution.bodies:
    briefsJson.add(%*{"briefId": b.briefId, "body": b.body})
  var refsJson = newJArray()
  for r in doc.briefRefs: refsJson.add(%r)

  let manifestHash = "local"
  var startedBy = opts.startedBy
  if startedBy.len == 0:
    startedBy = getEnv("USER", "cli")

  var payload = %* {
    "docPath":      opts.docPath.absolutePath(),
    "docSha":       docSha,
    "briefRefs":    refsJson,
    "maxIterations": doc.maxIterations,
    "body":         doc.bodyMarkdown,
    "briefs":       briefsJson,
    "latestReport": "",
    "manifestHash": manifestHash,
    "startedBy":    startedBy,
    "notesToOrchestrator": doc.notesToOrchestrator,
  }
  if doc.hasTargetScore:
    payload["targetScore"] = %doc.targetScore
  info "campaign start", docPath = opts.docPath, docSha = docSha,
    briefRefs = doc.briefRefs.join(","), maxIterations = doc.maxIterations,
    daemon = baseUrl

  if opts.noTail:
    # Fire and discard the SSE — but we still need to read at least the
    # ``end`` event so the daemon's worker thread completes the first
    # round.  Stream silently (writeText = false).
    var cid, stopReason: string
    var sawText = false
    try:
      streamCampaignSse(baseUrl, "/api/campaign/start", $payload,
                        cid, stopReason, sawText, writeText = false)
    except IOError as e:
      stderr.writeLine "isonim-review campaign start: " & e.msg
      return 5
    if cid.len == 0:
      stderr.writeLine "isonim-review campaign start: no campaignId returned"
      return 5
    echo cid
    return 0

  var campaignId, stopReason: string
  var sawText = false
  try:
    streamCampaignSse(baseUrl, "/api/campaign/start", $payload,
                      campaignId, stopReason, sawText)
  except IOError as e:
    stderr.writeLine "isonim-review campaign start: " & e.msg
    return 5
  if sawText:
    stdout.write "\n"
    flushFile(stdout)
  if campaignId.len > 0:
    stderr.writeLine "campaign started: " & campaignId
  stderr.writeLine "round complete (stopReason=" & stopReason & ")"
  return 0

# --------------------------------------------------------------------------
# Subcommand: list
# --------------------------------------------------------------------------

proc httpGet(daemonUrl, path: string; timeoutMs = 10_000):
    tuple[code: int; body: string] =
  let client = newHttpClient(timeout = timeoutMs)
  defer: client.close()
  let resp = client.request(daemonUrl & path, httpMethod = HttpGet)
  let status = parseInt(resp.status.split(' ')[0])
  return (code: status, body: resp.body)

proc httpPostJson(daemonUrl, path, body: string; timeoutMs = 10_000):
    tuple[code: int; body: string] =
  let client = newHttpClient(timeout = timeoutMs)
  defer: client.close()
  let headers = newHttpHeaders([("Content-Type", "application/json")])
  let resp = client.request(daemonUrl & path,
                            httpMethod = HttpPost,
                            body = body, headers = headers)
  let status = parseInt(resp.status.split(' ')[0])
  return (code: status, body: resp.body)

proc cmdCampaignList*(cfg: ReviewConfig; opts: CampaignListOptions): int =
  let baseUrl =
    if opts.daemonUrl.len > 0: opts.daemonUrl
    else: daemonBaseUrl(cfg)
  var q = "?limit=" & $opts.limit & "&offset=" & $opts.offset
  if opts.status.len > 0:
    q.add "&status=" & opts.status
  let (code, body) = httpGet(baseUrl, "/api/campaign/list" & q)
  if code != 200:
    stderr.writeLine "isonim-review campaign list: " &
      $code & " " & body
    return 5
  var arr: JsonNode
  try: arr = parseJson(body)
  except JsonParsingError as e:
    stderr.writeLine "isonim-review campaign list: bad JSON: " & e.msg
    return 5
  if arr.kind != JArray:
    stderr.writeLine "isonim-review campaign list: unexpected payload"
    return 5
  if arr.len == 0:
    echo "(no campaigns)"
    return 0
  echo "campaign_id                          status      iter  doc"
  echo "------------------------------------ ----------- ----- -----------------------------------------"
  for c in arr.items:
    let id = c{"campaign_id"}.getStr("")
    let status = c{"status"}.getStr("")
    let mi = c{"max_iterations"}.getInt(0)
    let docPath = c{"doc_path"}.getStr("")
    let truncDoc =
      if docPath.len <= 50: docPath else: "..." & docPath[docPath.len - 47 .. ^1]
    let row = id & "  " & status.alignLeft(10) & " " & ("/" & $mi).alignLeft(5) & " " & truncDoc
    echo row
  return 0

# --------------------------------------------------------------------------
# Subcommand: show
# --------------------------------------------------------------------------

proc cmdCampaignShow*(cfg: ReviewConfig; opts: CampaignShowOptions): int =
  let baseUrl =
    if opts.daemonUrl.len > 0: opts.daemonUrl
    else: daemonBaseUrl(cfg)
  if opts.campaignId.len == 0:
    stderr.writeLine "isonim-review campaign show: <campaign_id> required"
    return 2
  let q = "?campaignId=" & opts.campaignId &
          "&eventLimit=" & $opts.eventLimit
  let (code, body) = httpGet(baseUrl, "/api/campaign/fetch" & q)
  if code == 404:
    stderr.writeLine "isonim-review campaign show: not found: " & opts.campaignId
    return 4
  if code != 200:
    stderr.writeLine "isonim-review campaign show: " & $code & " " & body
    return 5
  var node: JsonNode
  try: node = parseJson(body)
  except JsonParsingError as e:
    stderr.writeLine "isonim-review campaign show: bad JSON: " & e.msg
    return 5
  echo "campaign_id:    " & node{"campaign_id"}.getStr("")
  echo "doc_path:       " & node{"doc_path"}.getStr("")
  echo "doc_sha:        " & node{"doc_sha"}.getStr("")
  let refs = node{"brief_refs"}
  if refs != nil and refs.kind == JArray:
    var rs = newSeq[string]()
    for r in refs.items: rs.add r.getStr("")
    echo "brief_refs:     " & rs.join(", ")
  echo "target_score:   " & $node{"target_score"}
  echo "max_iterations: " & $node{"max_iterations"}.getInt(0)
  echo "manifest_hash:  " & node{"manifest_hash"}.getStr("")
  echo "status:         " & node{"status"}.getStr("")
  let reason = node{"status_reason"}.getStr("")
  if reason.len > 0:
    echo "status_reason:  " & reason
  echo "started_by:     " & node{"started_by"}.getStr("")
  echo "started_at:     " & $node{"started_at"}
  echo "agent_backend:  " & node{"agent_backend"}.getStr("")
  echo "acp_session_id: " & node{"acp_session_id"}.getStr("")
  let events = node{"events"}
  echo "recent_events:"
  if events != nil and events.kind == JArray:
    for e in events.items:
      let kind = e{"event_kind"}.getStr("")
      let occ = e{"occurred_at"}.getStr("")
      echo "  - " & occ & "  " & kind
  return 0

# --------------------------------------------------------------------------
# Subcommand: tail
# --------------------------------------------------------------------------

proc renderEventLine(e: JsonNode): string =
  let kind = e{"event_kind"}.getStr("")
  let occ = e{"occurred_at"}.getStr("")
  result = occ & "  " & kind
  let payload = e{"payload"}
  if payload != nil and payload.kind == JObject:
    let stopReason = payload{"stopReason"}.getStr("")
    if stopReason.len > 0:
      result.add "  stopReason=" & stopReason

proc cmdCampaignTail*(cfg: ReviewConfig; opts: CampaignTailOptions): int =
  let baseUrl =
    if opts.daemonUrl.len > 0: opts.daemonUrl
    else: daemonBaseUrl(cfg)
  if opts.campaignId.len == 0:
    stderr.writeLine "isonim-review campaign tail: <campaign_id> required"
    return 2
  var lastSeen = ""
  while true:
    var q = "?campaignId=" & opts.campaignId & "&limit=200"
    if lastSeen.len > 0:
      q.add "&since=" & lastSeen
    let (code, body) = httpGet(baseUrl, "/api/campaign/events" & q)
    if code != 200:
      stderr.writeLine "isonim-review campaign tail: " & $code & " " & body
      return 5
    var arr: JsonNode
    try: arr = parseJson(body)
    except JsonParsingError as e:
      stderr.writeLine "isonim-review campaign tail: bad JSON: " & e.msg
      return 5
    if arr.kind == JArray:
      for e in arr.items:
        echo renderEventLine(e)
        lastSeen = e{"occurred_at"}.getStr(lastSeen)
    if not opts.follow:
      return 0
    sleep(max(50, opts.intervalMs))

# --------------------------------------------------------------------------
# Subcommand: tick
# --------------------------------------------------------------------------

proc cmdCampaignTick*(cfg: ReviewConfig; opts: CampaignTickOptions): int =
  let baseUrl =
    if opts.daemonUrl.len > 0: opts.daemonUrl
    else: daemonBaseUrl(cfg)
  if opts.campaignId.len == 0:
    stderr.writeLine "isonim-review campaign tick: <campaign_id> required"
    return 2
  let body = $(%* {"campaignId": opts.campaignId})
  if opts.noTail:
    # Tick streams via SSE just like start.  In ``--no-tail`` mode we
    # consume the stream silently (no stdout writes) so the only
    # output for scripts is the exit code.
    var cid = opts.campaignId
    var stopReason: string
    var sawText = false
    try:
      streamCampaignSse(baseUrl, "/api/campaign/tick", body,
                        cid, stopReason, sawText, writeText = false)
    except IOError as e:
      stderr.writeLine "isonim-review campaign tick: " & e.msg
      return 5
    return 0
  var cid, stopReason: string
  var sawText = false
  cid = opts.campaignId
  try:
    streamCampaignSse(baseUrl, "/api/campaign/tick", body,
                      cid, stopReason, sawText)
  except IOError as e:
    stderr.writeLine "isonim-review campaign tick: " & e.msg
    return 5
  if sawText:
    stdout.write "\n"
    flushFile(stdout)
  stderr.writeLine "round complete (stopReason=" & stopReason & ")"
  return 0

# --------------------------------------------------------------------------
# Subcommand: stop
# --------------------------------------------------------------------------

proc cmdCampaignStop*(cfg: ReviewConfig; opts: CampaignStopOptions): int =
  let baseUrl =
    if opts.daemonUrl.len > 0: opts.daemonUrl
    else: daemonBaseUrl(cfg)
  if opts.campaignId.len == 0:
    stderr.writeLine "isonim-review campaign stop: <campaign_id> required"
    return 2
  let body = $(%* {"campaignId": opts.campaignId, "reason": opts.reason})
  let (code, respBody) = httpPostJson(baseUrl, "/api/campaign/stop", body)
  if code != 200:
    stderr.writeLine "isonim-review campaign stop: " & $code & " " & respBody
    return 5
  echo respBody
  return 0
