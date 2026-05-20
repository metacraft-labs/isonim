## Phase B — minimal ACP server used by Phase B daemon/CLI tests.
##
## Speaks the JSON-RPC dialect over stdio that ``NativeStdioAcpTransport``
## expects.  Implements just enough of the protocol for our routes:
##
##   * ``initialize`` — responds with a fixed protocol version and the
##     ``streaming + text`` capability bits set.
##   * ``session/new`` — mints a deterministic session id based on the
##     command-line argument (or a counter if none is supplied).
##   * ``session/prompt`` — first emits one or more
##     ``session/update`` notifications with canned text chunks, then
##     returns a ``stopReason`` of ``end_turn``.  The canned text is
##     read from ``$FAKE_ACP_REPLY`` or the literal string
##     ``PHASE_B_OK``.
##   * ``session/cancel`` — recorded into ``$FAKE_ACP_CANCEL_FILE`` so
##     the test that drives cancellation can assert it actually
##     propagated.  Triggers an immediate ``stopReason: cancelled``
##     response on the in-flight prompt by signalling a guard flag.
##
## Streaming mode (set ``FAKE_ACP_STREAM_CHUNKS=N`` with ``N > 1``):
## the agent emits ``N`` ``session/update`` notifications, each
## carrying one segment of the canned text, separated by
## ``FAKE_ACP_STREAM_DELAY_MS`` milliseconds.  This lets daemon and
## CLI tests observe progressive delivery without a real LLM.
##
## The binary is intentionally minimal — REV-M11 will swap it for a
## richer mock once the ACP capability surface grows.

import std/[atomics, json, locks, os, strutils, times]

proc readFrame(): string =
  ## Read one ``\n``-delimited JSON-RPC frame from stdin.  Returns an
  ## empty string on EOF so the main loop can exit cleanly.
  var line = ""
  try:
    line = stdin.readLine()
  except IOError, EOFError:
    return ""
  return line

# --------------------------------------------------------------------------- #
# Concurrent stdin reader: ``session/cancel`` arrives as a JSON-RPC
# notification while the main thread is busy emitting streaming
# chunks.  A dedicated reader thread lets the agent notice the cancel
# without polling for it.                                                     #
# --------------------------------------------------------------------------- #

type
  FrameInbox = ref object
    lock: Lock
    frames: seq[string]
    closed: Atomic[bool]
    cancelRequested: Atomic[bool]
    cancelSessionFile: string

var inbox: FrameInbox

proc pushFrame(box: FrameInbox; frame: string) =
  acquire(box.lock)
  box.frames.add frame
  release(box.lock)

proc popFrame(box: FrameInbox; timeoutMs: int = -1): string =
  ## Blocking pop with optional polling timeout.  Returns "" if no
  ## frame is available before ``timeoutMs`` elapses.  Negative
  ## ``timeoutMs`` means "wait forever".
  let start = epochTime()
  while true:
    acquire(box.lock)
    if box.frames.len > 0:
      result = box.frames[0]
      box.frames.delete(0)
      release(box.lock)
      return result
    release(box.lock)
    if box.closed.load() and box.frames.len == 0:
      return ""
    if timeoutMs >= 0:
      if (epochTime() - start) * 1000 > timeoutMs.float:
        return ""
    sleep(5)

proc readerThreadMain(box: FrameInbox) {.thread.} =
  while not box.closed.load():
    let frame = readFrame()
    if frame.len == 0:
      box.closed.store(true)
      break
    # Peek for ``session/cancel`` so the main thread can short-circuit
    # an in-flight stream without waiting for ``popFrame`` to return.
    try:
      let node = parseJson(frame)
      if node{"method"}.getStr("") == "session/cancel":
        box.cancelRequested.store(true)
        if box.cancelSessionFile.len > 0:
          let sid = node{"params"}{"sessionId"}.getStr("")
          try:
            let f = open(box.cancelSessionFile, fmAppend)
            defer: f.close()
            f.write($epochTime() & " " & sid & "\n")
          except IOError:
            discard
    except JsonParsingError:
      discard
    pushFrame(box, frame)

proc emit(node: JsonNode) =
  stdout.write($node & "\n")
  flushFile(stdout)

proc emitResponse(id: JsonNode; payload: JsonNode) =
  emit(%*{"jsonrpc": "2.0", "id": id, "result": payload})

proc emitErrorResponse(id: JsonNode; code: int; message: string) =
  emit(%*{"jsonrpc": "2.0", "id": id,
          "error": {"code": code, "message": message}})

proc emitUpdate(sessionId, text: string) =
  emit(%*{"jsonrpc": "2.0", "method": "session/update",
          "params": {
            "sessionId": sessionId,
            "update": {
              "sessionUpdate": "agent_message_chunk",
              "content": {"type": "text", "text": text},
            }
          }})

proc splitForStreaming(text: string; chunks: int): seq[string] =
  ## Split ``text`` into ``chunks`` roughly-equal slices, preserving
  ## bytes and order.  Each output is non-empty unless ``text`` itself
  ## is empty.  Used to fan out a canned reply across multiple
  ## ``session/update`` notifications so tests can observe progressive
  ## delivery.
  if chunks <= 1 or text.len == 0:
    return @[text]
  result = newSeq[string](chunks)
  let base = text.len div chunks
  let extra = text.len mod chunks
  var idx = 0
  for i in 0 ..< chunks:
    let take = base + (if i < extra: 1 else: 0)
    result[i] =
      if take == 0: ""
      else: text[idx ..< idx + take]
    idx += take

proc consumeCancel(): bool =
  ## Atomically swap the cancel flag.  Returns ``true`` exactly once
  ## per cancel arrival so the prompt handler can decide which
  ## stopReason to send.
  inbox.cancelRequested.exchange(false)

proc main() =
  let cannedReply = getEnv("FAKE_ACP_REPLY", "PHASE_B_OK")
  let slowPromptMs =
    try: parseInt(getEnv("FAKE_ACP_SLOW_PROMPT_MS", "0"))
    except ValueError: 0
  let streamChunks =
    try: max(1, parseInt(getEnv("FAKE_ACP_STREAM_CHUNKS", "1")))
    except ValueError: 1
  let streamDelayMs =
    try: max(0, parseInt(getEnv("FAKE_ACP_STREAM_DELAY_MS", "0")))
    except ValueError: 0

  # Spawn the stdin reader so ``session/cancel`` is observable even
  # while the main thread is mid-prompt emitting streamed chunks.
  inbox = FrameInbox(cancelSessionFile: getEnv("FAKE_ACP_CANCEL_FILE"))
  initLock(inbox.lock)
  inbox.closed.store(false)
  inbox.cancelRequested.store(false)
  var reader: Thread[FrameInbox]
  createThread(reader, readerThreadMain, inbox)

  var sessionCounter = 0
  var nextSessionId = ""
  while true:
    let frame = popFrame(inbox)
    if frame.len == 0:
      break
    var node: JsonNode
    try:
      node = parseJson(frame)
    except JsonParsingError:
      continue
    let idNode = node{"id"}
    let rpcMethod = node{"method"}.getStr("")
    case rpcMethod
    of "initialize":
      emitResponse(idNode, %*{
        "protocolVersion": 1,
        "agentCapabilities": {
          "streaming": true,
          "text": true,
          "images": false,
          "audio": false,
          "resources": false,
          "permissions": false,
        }
      })
    of "session/new":
      inc sessionCounter
      nextSessionId = getEnv("FAKE_ACP_SESSION_ID",
        "fake-session-" & $sessionCounter)
      emitResponse(idNode, %*{"sessionId": nextSessionId})
    of "session/prompt":
      let params = node{"params"}
      let sid = params{"sessionId"}.getStr(nextSessionId)
      # Drain any stale cancel state from the previous turn so we
      # don't short-circuit this prompt with leftover state.
      discard consumeCancel()
      if slowPromptMs > 0:
        let deadline = epochTime() + (slowPromptMs / 1000)
        while epochTime() < deadline:
          sleep(20)
          if inbox.cancelRequested.load():
            break
      if consumeCancel():
        emitResponse(idNode, %*{"sessionId": sid,
                                "stopReason": "cancelled"})
      else:
        let pieces = splitForStreaming(cannedReply, streamChunks)
        var cancelledMidStream = false
        for i, piece in pieces:
          if inbox.cancelRequested.load():
            cancelledMidStream = true
            break
          emitUpdate(sid, piece)
          if streamDelayMs > 0 and i + 1 < pieces.len:
            let deadline = epochTime() + (streamDelayMs / 1000)
            while epochTime() < deadline:
              sleep(10)
              if inbox.cancelRequested.load():
                break
            if inbox.cancelRequested.load():
              cancelledMidStream = true
              break
        if cancelledMidStream or consumeCancel():
          discard consumeCancel()
          emitResponse(idNode, %*{"sessionId": sid,
                                  "stopReason": "cancelled"})
        else:
          emitResponse(idNode, %*{"sessionId": sid,
                                  "stopReason": "end_turn"})
    of "session/cancel":
      # Already recorded by the reader thread; this dispatcher branch
      # just keeps the case exhaustive.
      discard
    of "":
      discard
    else:
      if idNode != nil:
        emitErrorResponse(idNode, -32_601, "method not found: " & rpcMethod)

  inbox.closed.store(true)

when isMainModule:
  main()
