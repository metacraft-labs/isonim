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

# --------------------------------------------------------------------------- #
#  Follow-up 5 — PNG image-content-block bundling in /api/agent/prompts.      #
# --------------------------------------------------------------------------- #

# Minimal valid PNG (1x1 RGBA, identical signature to the one used in
# tests/test_design_review_cli_seed_run.nim).  We need a real PNG
# signature here because the daemon validates the header before
# trusting the bytes.
const PngOnePx = [
  byte(0x89), byte(0x50), byte(0x4E), byte(0x47),
  byte(0x0D), byte(0x0A), byte(0x1A), byte(0x0A),
  byte(0x00), byte(0x00), byte(0x00), byte(0x0D),
  byte('I'), byte('H'), byte('D'), byte('R'),
  byte(0x00), byte(0x00), byte(0x00), byte(0x01),
  byte(0x00), byte(0x00), byte(0x00), byte(0x01),
  byte(0x08), byte(0x06), byte(0x00), byte(0x00), byte(0x00),
  byte(0x1F), byte(0x15), byte(0xC4), byte(0x89),
  byte(0x00), byte(0x00), byte(0x00), byte(0x10),
  byte('I'), byte('D'), byte('A'), byte('T'),
  byte(0x78), byte(0x01), byte(0x01), byte(0x05), byte(0x00),
  byte(0xFA), byte(0xFF), byte(0x00), byte(0xFF), byte(0x00),
  byte(0x00), byte(0xFF), byte(0x00), byte(0x09), byte(0x00),
  byte(0x04),
  byte(0x00), byte(0x00), byte(0x00), byte(0x00),
  byte(0x00), byte(0x00), byte(0x00), byte(0x00),
  byte('I'), byte('E'), byte('N'), byte('D'),
  byte(0xAE), byte(0x42), byte(0x60), byte(0x82),
]

proc writeFixturePng(path: string; tag: byte) =
  ## Materialise a tiny but valid PNG at ``path``.  ``tag`` mutates one
  ## byte in the IDAT payload so concurrent tests with different
  ## fixtures produce distinct sha256s — useful when extending to
  ## content-addressed storage later.
  var bytes = newSeq[byte](PngOnePx.len)
  for i in 0 ..< PngOnePx.len: bytes[i] = PngOnePx[i]
  bytes[44] = tag
  var asStr = newString(bytes.len)
  for i in 0 ..< bytes.len: asStr[i] = char(bytes[i])
  writeFile(path, asStr)

proc lastContentLogEntry(path: string): JsonNode =
  ## Each daemon ``/api/agent/prompts`` invocation appends one JSON
  ## summary line to ``$FAKE_ACP_CONTENT_LOG``.  We read the file and
  ## return the parsed last non-empty line so tests can assert on the
  ## inbound prompt shape directly.
  if not fileExists(path):
    return nil
  let raw = readFile(path)
  var last = ""
  for line in raw.splitLines():
    let s = line.strip()
    if s.len > 0: last = s
  if last.len == 0: return nil
  parseJson(last)

test "test_prompt_with_pngs_forwards_image_blocks":
  ## REGRESSION — the daemon must convert ``pngPaths`` entries into
  ## ACP image content blocks, NOT drop them.  Previously the handler
  ## only forwarded the text block (promptBlocks=1) which left
  ## reviewers blind to the captures.
  let f = startAgentDaemon()
  defer: f.shutdown()
  let png1 = getTempDir() / "agent_routes_img_1.png"
  let png2 = getTempDir() / "agent_routes_img_2.png"
  defer:
    try: removeFile(png1) except OSError: discard
    try: removeFile(png2) except OSError: discard
  writeFixturePng(png1, byte(0x11))
  writeFixturePng(png2, byte(0x22))

  let (sCode, sBody) = f.agentPost("/api/agent/sessions", "{}")
  check sCode == 200
  let sessionId = parseJson(sBody){"sessionId"}.getStr("")
  check sessionId.len > 0

  let promptBody = $(%* {
    "sessionId": sessionId,
    "messages": [{
      "role": "user",
      "content": [{"type": "text", "text": "review these"}],
    }],
    "pngPaths": [png1, png2],
  })
  let (pCode, raw) = rawPostStream(f.baseUrl, "/api/agent/prompts",
                                    promptBody)
  check pCode == 200
  check raw.contains("event: end")

  # The daemon writes a JSON summary of the inbound content blocks to
  # $FAKE_ACP_CONTENT_LOG.  Wait briefly (the handler logs synchronously
  # before kicking off the prompt worker, but file I/O can lag a few
  # ms behind the SSE prelude under load).
  let deadline = epochTime() + 2.0
  var entry: JsonNode = nil
  while epochTime() < deadline:
    entry = lastContentLogEntry(f.contentLog)
    if entry != nil and entry{"sessionId"}.getStr("") == sessionId:
      break
    sleep(50)
  check entry != nil
  check entry["sessionId"].getStr == sessionId
  check entry["promptBlocks"].getInt == 3
  check entry["textBlocks"].getInt == 1
  check entry["imageBlocks"].getInt == 2
  let blocks = entry["blocks"]
  check blocks.kind == JArray
  check blocks.len == 3
  check blocks[0]["type"].getStr == "text"
  check blocks[1]["type"].getStr == "image"
  check blocks[1]["mimeType"].getStr == "image/png"
  check blocks[1]["dataLen"].getInt > 0
  check blocks[2]["type"].getStr == "image"
  check blocks[2]["mimeType"].getStr == "image/png"
  check blocks[2]["dataLen"].getInt > 0

test "test_prompt_with_missing_png_returns_400":
  ## REGRESSION — bad pngPaths entries must be reported with HTTP 400
  ## and a body that names the offending path, not silently dropped.
  let f = startAgentDaemon()
  defer: f.shutdown()
  let (sCode, sBody) = f.agentPost("/api/agent/sessions", "{}")
  check sCode == 200
  let sessionId = parseJson(sBody){"sessionId"}.getStr("")

  let missingPath = getTempDir() / "does-not-exist-png-fixture.png"
  try: removeFile(missingPath) except OSError: discard
  let promptBody = $(%* {
    "sessionId": sessionId,
    "messages": [{
      "role": "user",
      "content": [{"type": "text", "text": "hi"}],
    }],
    "pngPaths": [missingPath],
  })
  let (code, body) = f.agentPost("/api/agent/prompts", promptBody)
  check code == 400
  let node = parseJson(body)
  check node{"error"}.getStr("") == "bad_png_attachment"
  check node{"path"}.getStr("") == missingPath
  check node{"reason"}.getStr("").contains(missingPath)

test "test_prompt_with_non_png_returns_400":
  ## A text file masquerading as a PNG must be caught by the signature
  ## check before it reaches the ACP transport.
  let f = startAgentDaemon()
  defer: f.shutdown()
  let (sCode, sBody) = f.agentPost("/api/agent/sessions", "{}")
  check sCode == 200
  let sessionId = parseJson(sBody){"sessionId"}.getStr("")

  let fakePng = getTempDir() / "fake-not-actually-a-png.png"
  writeFile(fakePng, "this is plainly not a PNG, sorry!\n")
  defer:
    try: removeFile(fakePng) except OSError: discard
  let promptBody = $(%* {
    "sessionId": sessionId,
    "messages": [{
      "role": "user",
      "content": [{"type": "text", "text": "hi"}],
    }],
    "pngPaths": [fakePng],
  })
  let (code, body) = f.agentPost("/api/agent/prompts", promptBody)
  check code == 400
  let node = parseJson(body)
  check node{"error"}.getStr("") == "bad_png_attachment"
  check node{"path"}.getStr("") == fakePng
  check node{"reason"}.getStr("").contains("not a valid PNG")
