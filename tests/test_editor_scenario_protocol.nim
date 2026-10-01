## Only the upstream HTTP peer is controlled, to force short live frames,
## fragmented chunked encoding, rejected admission and EOF without completion.
## These are transport contracts, not Harbor/authoring integration evidence.
## The actual native host reader and production EditorVM/callbacks are included;
## no decoder output or VM result is fabricated. M5 E2E uses the real daemon.
const EditorScenarioProtocolTest = true
include ./test_editor_scenario_host
import std/[unittest, times, sequtils]

type ProtocolCase = enum pcShortTail, pcChunked, pcRejected, pcInterrupted

proc exercise(mode: ProtocolCase) {.async.} =
  let server = newAsyncHttpServer()
  server.listen(Port(0), "127.0.0.1")
  origin = "http://127.0.0.1:" & $server.getPort().uint16
  # This protocol-only peer grants no real editor credential or permissions.
  scope = newJObject()
  let releaseStream = newFuture[void]("observable protocol release")
  var stopping = false
  var admissions = 0
  proc respond(req: Request) {.async, gcsafe.} =
    {.cast(gcsafe).}:
      if req.url.path == "/api/agent/sessions":
        await req.respond(Http200, $(%*{"sessionId": "protocol-" & $mode,
          "sessionCapabilities":{"cancelTurn": false}}))
      else:
        inc admissions
        if mode == pcRejected:
          await req.respond(Http409, "{\"error\":\"busy\"}")
          return
        let first = "event: session/update\r\ndata: " & $(%*{
          "kind":"message_chunk", "sourceType":"log", "text":"SHORT_LIVE_TAIL"}) & "\r\n\r\n"
        let ending = "event: end\r\ndata: {\"stopReason\":\"end_turn\"}\r\n\r\n"
        if mode == pcChunked:
          await req.client.send("HTTP/1.1 200 OK\r\nContent-Type: text/event-stream\r\nTransfer-Encoding: chunked\r\n\r\n")
          # Split a chunk header and its payload across real socket writes.
          let encoded = toHex(first.len).strip(leading = true, trailing = false, chars = {'0'}) & ";fixture=yes\r\n" & first & "\r\n"
          await req.client.send(encoded[0..1])
          await req.client.send(encoded[2..^1])
        else:
          await req.client.send("HTTP/1.1 200 OK\r\nContent-Type: text/event-stream\r\nConnection: close\r\n\r\n" & first)
        if mode != pcInterrupted:
          await releaseStream
          if mode == pcChunked:
            await req.client.send(toHex(ending.len) & "\r\n" & ending & "\r\n0\r\n\r\n")
          else: await req.client.send(ending)
        req.client.close()
  proc accepting() {.async.} =
    while not stopping:
      try: await server.acceptRequest(respond)
      except OSError:
        if not stopping: raise
  let acceptFuture = accepting()
  discard vm.createNewChat()
  let chat = vm.chat
  let errorsBefore = transportErrors.len
  chat.inputText.val = "Protocol request"
  check vm.sendAgentPrompt()
  let deadline = epochTime()+2
  if mode == pcRejected:
    while chat.connectionState.val != "failed" and epochTime() < deadline: await sleepAsync(1)
    check not chat.promptInFlight
    check chat.connectionState.val == "failed"
  else:
    while not chat.messages.val.anyIt(it.text == "SHORT_LIVE_TAIL") and epochTime() < deadline: await sleepAsync(1)
    check chat.messages.val.anyIt(it.text == "SHORT_LIVE_TAIL")
    check not releaseStream.finished
    check chat.promptInFlight
    if mode == pcInterrupted:
      while chat.connectionState.val != "interrupted" and epochTime() < deadline: await sleepAsync(1)
      check chat.connectionState.val == "interrupted"
      check chat.promptInFlight
      chat.inputText.val = "Must remain blocked"
      check not vm.sendAgentPrompt()
      check admissions == 1
    else:
      releaseStream.complete()
      while chat.promptInFlight and epochTime() < deadline: await sleepAsync(1)
      check not chat.promptInFlight
      check chat.stopReason.val == "end_turn"
      check transportErrors.len == errorsBefore
  stopping = true
  server.close()
  await acceptFuture

for mode in ProtocolCase:
  test "native real TCP SSE contract " & $mode:
    waitFor exercise(mode)
