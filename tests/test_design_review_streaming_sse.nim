## Progressive SSE delivery tests for ``POST /api/agent/prompts``.
##
## The daemon's chat route must forward each ``session/update``
## notification AS IT ARRIVES from the ACP agent — not buffered until
## the agent returns its final ``stopReason``.  These tests open a raw
## socket against the agent-routes daemon, drive a fake agent that
## emits chunks at a configurable cadence, and assert the SSE frames
## land at the client with timing gaps that match the agent's emit
## rhythm.
##
## The load-bearing assertion in
## ``test_sse_chunks_arrive_progressively`` is the timing gap between
## the first and last frame.  If the daemon batches notifications
## until the prompt response lands, every frame would arrive at once
## and the gap would be near-zero — that's the regression these tests
## protect against.

import std/[json, net, os, strutils, times, unittest]

import helpers/agent_routes_fixture

# --------------------------------------------------------------------------- #
#  Raw SSE reader with per-frame timing.                                      #
# --------------------------------------------------------------------------- #

type
  StreamFrame* = object
    eventType*: string
    data*: string
    arrivedAt*: float
      ## Wall-clock time (epochTime) when the ``\n\n`` terminator
      ## landed on the socket.  The deltas between frames are the
      ## load-bearing measurement.

proc parseUrl(baseUrl: string): tuple[host: string; port: int] =
  let parts = baseUrl.replace("http://", "").split(':')
  (parts[0], parseInt(parts[1]))

proc connectSse(baseUrl, path, body: string;
                timeoutMs = 5_000): Socket =
  ## Open a TCP socket, send the SSE POST request, then read & discard
  ## headers.  Returns the socket ready for ``recv`` of SSE frames.
  let (host, port) = parseUrl(baseUrl)
  let sock = newSocket()
  sock.connect(host, Port(port), timeout = timeoutMs)
  var req = "POST " & path & " HTTP/1.1\c\L"
  req.add "Host: " & host & ":" & $port & "\c\L"
  req.add "Content-Type: application/json\c\L"
  req.add "Content-Length: " & $body.len & "\c\L"
  req.add "Accept: text/event-stream\c\L"
  req.add "Connection: close\c\L"
  req.add "\c\L"
  req.add body
  sock.send(req)
  # Skip headers (up to and including \r\n\r\n).
  var hdr = ""
  while true:
    var ch: char
    let n = sock.recv(addr ch, 1, timeout = timeoutMs)
    if n != 1:
      raise newException(IOError, "headers truncated")
    hdr.add ch
    if hdr.endsWith("\r\n\r\n"):
      break
  return sock

proc readFrames(sock: Socket; timeoutMs = 30_000;
                maxFrames = 0): seq[StreamFrame] =
  ## Read SSE frames until the connection closes or ``maxFrames`` have
  ## arrived.  Each frame is timestamped at the moment its terminating
  ## ``\n\n`` lands on the socket.
  var buf = ""
  while true:
    var byte: char
    let n =
      try: sock.recv(addr byte, 1, timeout = timeoutMs)
      except TimeoutError: 0
    if n <= 0:
      break
    buf.add byte
    if buf.endsWith("\n\n") or buf.endsWith("\r\n\r\n"):
      let now = epochTime()
      var ev = StreamFrame(arrivedAt: now)
      for line in buf.splitLines:
        if line.startsWith("event:"):
          ev.eventType = line[6 .. ^1].strip()
        elif line.startsWith("data:"):
          if ev.data.len > 0: ev.data.add "\n"
          ev.data.add line[5 .. ^1].strip(leading = true, trailing = false)
      if ev.eventType.len > 0 or ev.data.len > 0:
        result.add ev
      buf.setLen(0)
      if maxFrames > 0 and result.len >= maxFrames:
        break

proc countUpdateFrames(frames: seq[StreamFrame]): int =
  for f in frames:
    if f.eventType == "session/update":
      inc result

# --------------------------------------------------------------------------- #
#  Progressive arrival.                                                       #
# --------------------------------------------------------------------------- #

test "test_sse_chunks_arrive_progressively":
  # Fake agent emits 5 chunks separated by 100 ms.  The total
  # inter-chunk distance is 4 × 100 = 400 ms — the assertion uses 350
  # ms as the threshold so a small amount of scheduler jitter
  # (~30-50 ms) doesn't flake the test.
  let f = startAgentDaemon(@[
    ("FAKE_ACP_STREAM_CHUNKS", "5"),
    ("FAKE_ACP_STREAM_DELAY_MS", "100"),
  ])
  defer: f.shutdown()
  let (sCode, sBody) = f.agentPost("/api/agent/sessions", "{}")
  check sCode == 200
  let sessionId = parseJson(sBody){"sessionId"}.getStr("")
  check sessionId.len > 0
  let promptBody = $(%* {
    "sessionId": sessionId,
    "messages": [{
      "role": "user",
      "content": [{"type": "text", "text": "stream"}],
    }],
  })
  let sock = connectSse(f.baseUrl, "/api/agent/prompts", promptBody)
  defer:
    try: sock.close() except CatchableError: discard
  let frames = readFrames(sock, timeoutMs = 15_000)
  # The fake agent emits exactly 5 ``session/update`` frames plus one
  # ``end`` frame.
  let updateFrames = block:
    var acc: seq[StreamFrame]
    for fr in frames:
      if fr.eventType == "session/update":
        acc.add fr
    acc
  check updateFrames.len == 5

  let firstAt = updateFrames[0].arrivedAt
  let lastAt = updateFrames[^1].arrivedAt
  let gapMs = (lastAt - firstAt) * 1000.0
  # Load-bearing assertion: frames really arrived progressively.  The
  # agent inserts 4 × 100 ms = 400 ms of inter-chunk delay.  We
  # require ≥ 350 ms wall-clock between first and last frame on the
  # client side — that proves the SSE write happened mid-prompt, not
  # at end-of-turn.
  checkpoint("gap_ms=" & $gapMs)
  check gapMs >= 350.0

  # End-frame sanity check (full assertion in the next test).
  var sawEnd = false
  for fr in frames:
    if fr.eventType == "end":
      sawEnd = true
  check sawEnd

# --------------------------------------------------------------------------- #
#  End frame carries stop reason.                                             #
# --------------------------------------------------------------------------- #

test "test_sse_final_end_event_carries_stop_reason":
  let f = startAgentDaemon(@[
    ("FAKE_ACP_STREAM_CHUNKS", "2"),
    ("FAKE_ACP_STREAM_DELAY_MS", "50"),
  ])
  defer: f.shutdown()
  let (sCode, sBody) = f.agentPost("/api/agent/sessions", "{}")
  check sCode == 200
  let sessionId = parseJson(sBody){"sessionId"}.getStr("")
  let promptBody = $(%* {
    "sessionId": sessionId,
    "messages": [{
      "role": "user",
      "content": [{"type": "text", "text": "go"}],
    }],
  })
  let sock = connectSse(f.baseUrl, "/api/agent/prompts", promptBody)
  defer:
    try: sock.close() except CatchableError: discard
  let frames = readFrames(sock, timeoutMs = 10_000)
  var endData = ""
  for fr in frames:
    if fr.eventType == "end":
      endData = fr.data
  check endData.len > 0
  let endNode = parseJson(endData)
  check endNode{"stopReason"}.getStr("") == "end_turn"

# --------------------------------------------------------------------------- #
#  Cancel mid-stream stops further events.                                    #
# --------------------------------------------------------------------------- #

test "test_sse_cancel_mid_stream_stops_events":
  # 10 chunks at 200 ms each = ~2 s of stream.  We connect, wait for
  # 2 chunks to land, then fire POST /api/agent/cancel.  Assert no
  # further chunks arrive after the cancel and the agent's cancel log
  # records the session id.
  let f = startAgentDaemon(@[
    ("FAKE_ACP_STREAM_CHUNKS", "10"),
    ("FAKE_ACP_STREAM_DELAY_MS", "200"),
  ])
  defer: f.shutdown()
  let (sCode, sBody) = f.agentPost("/api/agent/sessions", "{}")
  check sCode == 200
  let sessionId = parseJson(sBody){"sessionId"}.getStr("")
  let promptBody = $(%* {
    "sessionId": sessionId,
    "messages": [{
      "role": "user",
      "content": [{"type": "text", "text": "long"}],
    }],
  })
  let sock = connectSse(f.baseUrl, "/api/agent/prompts", promptBody)
  defer:
    try: sock.close() except CatchableError: discard
  # Read the first two update frames.
  let earlyFrames = readFrames(sock, timeoutMs = 5_000, maxFrames = 2)
  check countUpdateFrames(earlyFrames) == 2

  # Fire cancel.
  let cancelStart = epochTime()
  let (cCode, _) = f.agentPost("/api/agent/cancel",
    $(%* {"sessionId": sessionId}))
  check cCode == 202

  # Read the rest until the stream closes.  All frames after this
  # point must have arrived close enough to the cancel that we're not
  # seeing the full 10-chunk stream play through.
  let tailFrames = readFrames(sock, timeoutMs = 5_000)
  let cancelWindowEnd = cancelStart + 1.5  # ample slack for the
                                            # ``end`` frame to drain
  for fr in tailFrames:
    check fr.arrivedAt <= cancelWindowEnd

  let totalUpdates = countUpdateFrames(earlyFrames) +
                     countUpdateFrames(tailFrames)
  # Some implementations let one or two more chunks land before the
  # cancel reaches the agent; we must NOT see all 10.
  check totalUpdates < 10

  # The fake agent records cancels into FAKE_ACP_CANCEL_FILE — assert
  # the session id landed there.
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
