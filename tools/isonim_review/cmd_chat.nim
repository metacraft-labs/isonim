## Phase B — ``isonim-review chat`` subcommand.
##
## Drives the daemon's ``/api/agent/*`` endpoints from the command line.
## Two modes:
##
##   * One-shot: ``isonim-review chat 'hi there'`` — POSTs a single
##     prompt, prints the agent's reply on stdout, exits.
##   * REPL: ``isonim-review chat --interactive`` — keeps the same
##     session id across prompts so the agent retains context.
##
## Output discipline (load-bearing for piping):
##
##   * Agent **text** chunks → ``stdout``.
##   * Tool calls, status updates, stop reason, chronicles diagnostics
##     → ``stderr``.
##
## SSE parsing uses a tiny line-based reader on ``std/httpclient``'s
## socket so the daemon can stream events incrementally.  A failed POST
## (daemon down, 503 from the agent route, etc.) is mapped to a non-zero
## exit so shell wrappers can detect it.

import std/[httpclient, json, net, strutils]

import isonim/editor/design_review/log_setup

import ./config

logScope:
  topics = "cli"

type
  ChatOptions* = object
    daemonUrl*: string
    sessionId*: string
    interactive*: bool
    streamOutput*: bool
    promptText*: string

  SseEvent* = object
    eventType*: string
    data*: string

# --------------------------------------------------------------------------- #
#  Low-level SSE reader.                                                       #
# --------------------------------------------------------------------------- #

proc readHttpHeader*(sock: Socket): tuple[status: int; body: string] =
  ## Read until ``\r\n\r\n``.  Returns the status line int + any body
  ## bytes that were read past the headers (rare for SSE but possible
  ## when the daemon writes the prelude + first event in one go).
  var headerBuf = ""
  while true:
    var ch: char
    let n = sock.recv(addr ch, 1, timeout = 30_000)
    if n != 1:
      raise newException(IOError,
        "chat: connection closed before headers complete")
    headerBuf.add ch
    if headerBuf.endsWith("\r\n\r\n"):
      break
  let statusLine =
    if headerBuf.startsWith("HTTP/"):
      headerBuf.splitLines[0]
    else: ""
  let parts = statusLine.split(' ')
  let statusCode =
    if parts.len >= 2:
      try: parseInt(parts[1]) except ValueError: 0
    else: 0
  return (statusCode, "")

proc readSseEvent*(sock: Socket): tuple[event: SseEvent; eof: bool] =
  ## Read one SSE event — fields separated by blank line.  Returns
  ## ``eof = true`` when the peer closes the connection cleanly between
  ## events.
  var event = SseEvent()
  var line = ""
  var anyData = false
  while true:
    line.setLen(0)
    while true:
      var ch: char
      let n = sock.recv(addr ch, 1, timeout = 60_000)
      if n != 1:
        if anyData:
          return (event, false)
        return (event, true)
      if ch == '\n':
        if line.len > 0 and line[^1] == '\r':
          line.setLen(line.len - 1)
        break
      line.add ch
    if line.len == 0:
      if anyData: return (event, false)
      continue
    anyData = true
    if line.startsWith("event:"):
      event.eventType = line[6 .. ^1].strip()
    elif line.startsWith("data:"):
      if event.data.len > 0: event.data.add "\n"
      event.data.add line[5 .. ^1].strip(leading = true, trailing = false)
    else:
      discard  # ignore comments / unknown fields

# --------------------------------------------------------------------------- #
#  Daemon round-trips.                                                         #
# --------------------------------------------------------------------------- #

proc createSession*(daemonUrl: string): string =
  ## POST /api/agent/sessions and return the session id.
  let client = newHttpClient(timeout = 30_000)
  defer: client.close()
  let headers = newHttpHeaders([("Content-Type", "application/json")])
  let resp = client.request(daemonUrl & "/api/agent/sessions",
                            httpMethod = HttpPost,
                            body = "{}", headers = headers)
  let body = resp.body
  let status = parseInt(resp.status.split(' ')[0])
  if status != 200:
    error "agent session creation rejected", status = status, body = body
    raise newException(IOError,
      "chat: daemon refused session creation (" & $status & "): " & body)
  let node = parseJson(body)
  result = node{"sessionId"}.getStr("")
  if result.len == 0:
    raise newException(IOError,
      "chat: daemon returned empty sessionId; body=" & body)
  info "agent session minted", sessionId = result

proc cancelSession*(daemonUrl, sessionId: string) =
  ## Fire-and-forget cancel.  Swallows errors — the daemon side may
  ## already have cleaned up.
  try:
    let client = newHttpClient(timeout = 5_000)
    defer: client.close()
    let headers = newHttpHeaders([("Content-Type", "application/json")])
    let body = $(%* {"sessionId": sessionId})
    discard client.request(daemonUrl & "/api/agent/cancel",
                           httpMethod = HttpPost, body = body, headers = headers)
  except CatchableError as e:
    debug "cancel-session HTTP call failed", reason = e.msg

# --------------------------------------------------------------------------- #
#  SSE prompt round-trip.                                                      #
# --------------------------------------------------------------------------- #

proc parseUrl*(url: string): tuple[host: string; port: int; path: string] =
  ## Tiny URL parser for ``http://host[:port]/path``.  Avoids the
  ## ``std/uri`` import (which doesn't expose enough port-default logic
  ## without further plumbing).
  var s = url
  if s.startsWith("http://"):
    s = s[7 .. ^1]
  elif s.startsWith("https://"):
    s = s[8 .. ^1]
  let slash = s.find('/')
  let hostPart = if slash >= 0: s[0 ..< slash] else: s
  let pathPart = if slash >= 0: s[slash .. ^1] else: "/"
  let colon = hostPart.rfind(':')
  if colon < 0:
    return (hostPart, 80, pathPart)
  let port =
    try: parseInt(hostPart[colon + 1 .. ^1])
    except ValueError: 80
  (hostPart[0 ..< colon], port, pathPart)

proc submitPromptStream*(
    daemonUrl, sessionId, promptText: string;
    onTextChunk: proc(chunk: string) {.closure.};
    onUpdate: proc(event: SseEvent) {.closure.};
    onEnd: proc(stopReason: string) {.closure.}) =
  ## POST /api/agent/prompts, parse the SSE stream, dispatch each event.
  ##
  ## ``onTextChunk`` fires when the event is a ``session/update`` that
  ## carries an agent message text chunk.  ``onUpdate`` is the catch-all
  ## for non-text updates.  ``onEnd`` fires once when the ``end`` event
  ## arrives or the stream closes; ``stopReason`` is empty if the daemon
  ## closed without an explicit terminator.
  let body = $(%* {
    "sessionId": sessionId,
    "messages": [{
      "role": "user",
      "content": [{"type": "text", "text": promptText}],
    }],
  })
  let parsed = parseUrl(daemonUrl)
  let sock = newSocket()
  defer:
    try: sock.close() except CatchableError: discard
  try:
    sock.connect(parsed.host, Port(parsed.port), timeout = 5_000)
  except OSError as e:
    raise newException(IOError,
      "chat: failed to connect to daemon at " & daemonUrl & ": " & e.msg)

  # ``parsed.path`` is either "/" (no extra prefix) or a base-path the
  # operator provided (rare for the daemon).  Trim the trailing slash
  # before appending the route, otherwise we generate "//api/agent/...".
  let base =
    if parsed.path == "/": ""
    elif parsed.path.endsWith("/"): parsed.path[0 .. ^2]
    else: parsed.path
  var req = "POST " & base & "/api/agent/prompts HTTP/1.1\c\L"
  req.add "Host: " & parsed.host & ":" & $parsed.port & "\c\L"
  req.add "Content-Type: application/json\c\L"
  req.add "Content-Length: " & $body.len & "\c\L"
  req.add "Accept: text/event-stream\c\L"
  req.add "Connection: close\c\L"
  req.add "\c\L"
  req.add body
  sock.send(req)
  debug "SSE request sent", host = parsed.host, port = parsed.port,
    promptBytes = promptText.len

  let (status, _) = readHttpHeader(sock)
  debug "SSE headers received", status = status
  if status != 200:
    var remainder = ""
    while true:
      var chunk = newString(1024)
      let n = sock.recv(addr chunk[0], 1024, timeout = 1_000)
      if n <= 0: break
      remainder.add chunk[0 ..< n]
    error "agent prompt rejected", status = status, body = remainder
    raise newException(IOError,
      "chat: daemon rejected prompt (" & $status & "): " & remainder)

  var stopReason = ""
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
              onTextChunk(text)
            else:
              onUpdate(event)
          else:
            onUpdate(event)
        else:
          onUpdate(event)
      except JsonParsingError:
        onUpdate(event)
    of "end":
      try:
        let node = parseJson(event.data)
        stopReason = node{"stopReason"}.getStr("")
      except JsonParsingError:
        discard
      onEnd(stopReason)
      return
    of "error":
      onUpdate(event)
    else:
      onUpdate(event)
    if eof: break
  onEnd(stopReason)

# --------------------------------------------------------------------------- #
#  Subcommand entrypoint.                                                      #
# --------------------------------------------------------------------------- #

proc runOnePrompt(opts: ChatOptions; sessionId: string): int =
  info "chat session", sessionId = sessionId,
    promptBytes = opts.promptText.len
  var stopReasonOut = ""
  var sawText = false
  let textCb = proc(chunk: string) =
    sawText = true
    debug "cli.chunk", sessionId = sessionId, bytes = chunk.len,
      preview = (if chunk.len > 40: chunk[0 ..< 40] & "…" else: chunk)
    if opts.streamOutput:
      stdout.write chunk
      flushFile(stdout)
  let updateCb = proc(event: SseEvent) =
    debug "agent update", eventType = event.eventType,
      dataBytes = event.data.len
  let endCb = proc(stopReason: string) =
    debug "agent end event", stopReason = stopReason
    stopReasonOut = stopReason
  try:
    submitPromptStream(opts.daemonUrl, sessionId, opts.promptText,
                       onTextChunk = textCb, onUpdate = updateCb,
                       onEnd = endCb)
  except IOError as e:
    error "chat round-trip failed", reason = e.msg
    return 5
  if sawText and opts.streamOutput:
    stdout.write "\n"
    flushFile(stdout)
  stderr.writeLine "stopReason=" & stopReasonOut
  info "chat round-trip complete", sessionId = sessionId,
    stopReason = stopReasonOut, sawText = sawText
  return 0

proc runInteractive(opts: ChatOptions; sessionId: string): int =
  stderr.writeLine "isonim-review chat (interactive). " &
    "Type your prompt then Enter; EOF to quit."
  while true:
    stdout.write "> "
    flushFile(stdout)
    var line = ""
    try:
      line = stdin.readLine()
    except IOError, EOFError:
      stderr.writeLine ""
      break
    if line.len == 0:
      continue
    var inner = opts
    inner.promptText = line
    discard runOnePrompt(inner, sessionId)
  return 0

proc cmdChat*(cfg: ReviewConfig; opts: ChatOptions): int =
  let baseUrl =
    if opts.daemonUrl.len > 0: opts.daemonUrl
    else: daemonBaseUrl(cfg)
  if not opts.interactive and opts.promptText.len == 0:
    stderr.writeLine "isonim-review chat: prompt text required " &
      "(or pass --interactive)"
    return 2
  var resolved = opts
  resolved.daemonUrl = baseUrl
  if resolved.sessionId.len == 0:
    try:
      resolved.sessionId = createSession(baseUrl)
    except IOError as e:
      error "session creation failed", reason = e.msg
      stderr.writeLine "isonim-review chat: " & e.msg
      return 6
  info "cli chat starting", daemon = baseUrl,
    session = resolved.sessionId, interactive = resolved.interactive
  if resolved.interactive:
    let exitCode = runInteractive(resolved, resolved.sessionId)
    info "cli chat exited", exitCode = exitCode
    return exitCode
  let exitCode = runOnePrompt(resolved, resolved.sessionId)
  info "cli chat exited", exitCode = exitCode
  return exitCode
