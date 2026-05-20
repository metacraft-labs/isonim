## Phase B — daemon ``/api/agent/*`` route tests.
##
## All tests boot the real ``isonim-review`` daemon in
## ``--agent-routes-only`` mode (no Postgres dependency) and drive it
## via ``std/httpclient`` + a fake ACP agent.  The fake agent is built
## once as ``build/bin/fake-acp-agent`` and lives at
## ``tests/helpers/fake_acp_agent.nim``.

import std/[json, net, os, strutils, times, unittest]

import helpers/agent_routes_fixture

# --------------------------------------------------------------------------- #
#  POST /api/agent/sessions                                                   #
# --------------------------------------------------------------------------- #

test "test_post_sessions_creates_session":
  let f = startAgentDaemon()
  defer: f.shutdown()
  let (code, body) = f.agentPost("/api/agent/sessions", "{}")
  check code == 200
  let node = parseJson(body)
  check node{"sessionId"}.getStr("").len > 0
  let caps = node{"agentCapabilities"}
  check caps != nil
  check caps{"streaming"}.getBool(false) == true

# --------------------------------------------------------------------------- #
#  POST /api/agent/prompts — SSE stream.                                      #
# --------------------------------------------------------------------------- #

proc rawPostStream(baseUrl, path, body: string;
                   timeoutMs = 10_000): tuple[status: int; raw: string] =
  ## Open a raw socket so we capture the SSE bytes verbatim — the
  ## ``std/httpclient`` request API drains the body internally and
  ## doesn't expose the individual frames.
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
  # Extract status line (HTTP/1.1 NNN ...).
  let firstLine = buf.split('\n', maxsplit = 1)
  var status = 0
  if firstLine.len > 0 and firstLine[0].startsWith("HTTP/"):
    let p = firstLine[0].split(' ')
    if p.len >= 2:
      try: status = parseInt(p[1]) except ValueError: discard
  # Strip headers from raw body.
  let split = buf.find("\r\n\r\n")
  let rawBody = if split >= 0: buf[split + 4 .. ^1] else: buf
  return (status, rawBody)

test "test_post_prompts_streams_session_updates":
  let f = startAgentDaemon()
  defer: f.shutdown()
  let (sCode, sBody) = f.agentPost("/api/agent/sessions", "{}")
  check sCode == 200
  let sessionId = parseJson(sBody){"sessionId"}.getStr("")
  check sessionId.len > 0
  let promptBody = $(%* {
    "sessionId": sessionId,
    "messages": [{
      "role": "user",
      "content": [{"type": "text", "text": "hi"}],
    }],
  })
  let (pCode, raw) = rawPostStream(f.baseUrl, "/api/agent/prompts",
                                    promptBody)
  check pCode == 200
  # The fake agent emits ``PHASE_B_OK`` as a session/update text chunk
  # then closes with ``end_turn``.  We assert both fingerprints land
  # in the SSE bytes.
  check raw.contains("session/update")
  check raw.contains("PHASE_B_OK")
  check raw.contains("event: end")
  check raw.contains("\"stopReason\":\"end_turn\"")

# --------------------------------------------------------------------------- #
#  POST /api/agent/cancel.                                                    #
# --------------------------------------------------------------------------- #

test "test_post_cancel_signals_agent":
  # Configure the fake agent to sleep ~600 ms inside ``session/prompt``
  # so the cancel notification arrives mid-flight.
  let f = startAgentDaemon(@[
    ("FAKE_ACP_SLOW_PROMPT_MS", "1500"),
  ])
  defer: f.shutdown()
  let (sCode, sBody) = f.agentPost("/api/agent/sessions", "{}")
  check sCode == 200
  let sessionId = parseJson(sBody){"sessionId"}.getStr("")
  check sessionId.len > 0

  # Fire the prompt request on a worker thread so the main test thread
  # can issue the cancel mid-flight.
  let promptBody = $(%* {
    "sessionId": sessionId,
    "messages": [{
      "role": "user",
      "content": [{"type": "text", "text": "go slow"}],
    }],
  })
  proc runPrompt(arg: tuple[baseUrl, body: string]) {.thread.} =
    discard rawPostStream(arg.baseUrl, "/api/agent/prompts", arg.body,
                          timeoutMs = 30_000)
  var t: Thread[tuple[baseUrl, body: string]]
  createThread(t, runPrompt, (f.baseUrl, promptBody))
  # Wait briefly so the prompt is in flight before we cancel.
  sleep(250)
  let (cCode, _) = f.agentPost("/api/agent/cancel",
    $(%* {"sessionId": sessionId}))
  check cCode == 202
  t.joinThread()
  # The fake agent appends ``<unix-ts> <sessionId>\n`` to
  # ``$FAKE_ACP_CANCEL_FILE`` whenever it processes ``session/cancel``.
  # Give the fake agent up to 2 s to write the file.
  let deadline = epochTime() + 2.0
  var saw = false
  while epochTime() < deadline:
    if fileExists(f.cancelFile):
      let content = readFile(f.cancelFile)
      if content.contains(sessionId):
        saw = true
        break
    sleep(50)
  check saw

# --------------------------------------------------------------------------- #
#  503 when the agent binary doesn't resolve.                                 #
# --------------------------------------------------------------------------- #

test "test_agent_route_returns_503_when_backend_unavailable":
  let f = startAgentDaemon(@[
    ("ISONIM_ACP_AGENT_CMD",
     "/definitely/not/on/path/missing-acp-binary"),
  ])
  defer: f.shutdown()
  let (code, body) = f.agentPost("/api/agent/sessions", "{}")
  check code == 503
  let node = parseJson(body)
  check node{"error"}.getStr("") == "agent_backend_unavailable"
  check node{"reason"}.getStr("").contains("missing-acp-binary")
