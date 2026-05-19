## REV-M5 — design-review capture client for the ``isonim-render-serve``
## bridge.
##
## *No new packet types on the bridge.*  This module is a regular
## bridge client using the existing I/M/F/P/H/D protocol locked at
## RS-M0/RS-M12.  It:
##
##   1. Connects via WebSocket to ``ws://<host>:<port>/``.
##   2. Sends one ``I`` packet carrying a ``select-story`` body
##      (encoded the same way ``streaming_preview.encodeSelectStoryBody``
##      does it).
##   3. Reads incoming binary frames:
##      * Skips the bridge's mandatory ``M hello`` packet.
##      * Keeps the most recent ``M`` packet's surface dimensions
##        (``initialSize.width/height`` from ``hello``, ``width/height``
##        from any ``resize``).
##      * Returns the first ``F`` packet decoded as RGBA8888 pixels,
##        encoded into a PNG via ``png_codec.encodePng32``.
##   4. Raises ``BridgeTimeoutError`` if no F arrives within
##      ``timeoutMs``.
##
## The WS framing reuses the codecs in
## ``isonim_render_serve/ws_frame.nim``.  We hand-roll the HTTP/1.1
## upgrade handshake so we don't drag in another nimble dep ("ws").

import std/[asyncdispatch, asyncnet, base64, json, nativesockets,
            random, strutils, times]

import isonim_render_serve/ws_frame
import isonim_render_serve/packet
import isonim/editor/types
import isonim/editor/design_review/brief_format
import isonim/editor/design_review/png_codec

export brief_format.previewBackendToString

type
  BridgeCaptureResult* = object
    pngBytes*: seq[byte]
    width*, height*: int

  BridgeTimeoutError* = object of CatchableError
    ## Raised when no F packet arrives within ``timeoutMs``.

  BridgeProtocolError* = object of CatchableError
    ## Raised on any wire-protocol violation while talking to the
    ## bridge (bad upgrade response, malformed packets, unexpected
    ## opcodes, etc.).

# ---------------------------------------------------------------------------
# Low-level WS plumbing (mirrors isonim-render-serve/tests/ws_test_client.nim
# but exposed at module scope instead of test scope).
# ---------------------------------------------------------------------------

proc randMaskKey(): array[4, byte] =
  for i in 0 ..< 4: result[i] = byte(rand(0 .. 255))

proc recvSome(fd: AsyncFD; size: int): Future[string] {.async.} =
  var buf = newString(size)
  let n = await asyncdispatch.recvInto(fd, addr buf[0], size)
  if n <= 0: return ""
  buf.setLen(n)
  result = buf

proc parseHostPort(url: string): tuple[host: string; port: int; path: string] =
  ## Crude WebSocket-URL parser: ``ws://HOST[:PORT][/PATH]`` →
  ## ``(host, port, path)``.  Defaults: port 80 for ``ws://``,
  ## ``/`` for the path.  ``wss://`` is rejected (no TLS support
  ## in the capture client — tests / dev work over loopback ``ws://``).
  var s = url
  if s.startsWith("ws://"):
    s = s[5 .. ^1]
  elif s.startsWith("wss://"):
    raise newException(BridgeProtocolError,
      "captureViaBridge: wss:// not supported; use ws:// over loopback")
  var path = "/"
  let slashIdx = s.find('/')
  if slashIdx >= 0:
    path = s[slashIdx .. ^1]
    s = s[0 ..< slashIdx]
  var host = s
  var port = 80
  let colon = s.rfind(':')
  if colon >= 0:
    host = s[0 ..< colon]
    try:
      port = parseInt(s[colon + 1 .. ^1])
    except ValueError:
      discard
  (host: host, port: port, path: path)

proc handshake(sock: AsyncSocket; host: string; port: int;
               path: string) {.async.} =
  let key = encode("0123456789abcdef0123")
  let req = "GET " & path & " HTTP/1.1\r\n" &
            "Host: " & host & ":" & $port & "\r\n" &
            "Upgrade: websocket\r\n" &
            "Connection: Upgrade\r\n" &
            "Sec-WebSocket-Key: " & key & "\r\n" &
            "Sec-WebSocket-Version: 13\r\n\r\n"
  await sock.send(req)
  let fd = AsyncFD(getFd(sock))
  var resp = ""
  while not resp.contains("\r\n\r\n"):
    let chunk = await recvSome(fd, 4096)
    if chunk.len == 0: break
    resp.add chunk
  if not resp.startsWith("HTTP/1.1 101"):
    raise newException(BridgeProtocolError,
      "captureViaBridge: bridge refused WebSocket upgrade:\n" & resp)

proc sendBinaryFrame(sock: AsyncSocket; payload: string) {.async.} =
  let mask = randMaskKey()
  let frame = encodeWsClientFrame(wsOpBinary, payload, mask)
  await sock.send(frame)

# ---------------------------------------------------------------------------
# Bridge protocol — read the next M / F message
# ---------------------------------------------------------------------------

type
  ConnectionFrame = object
    isM, isF: bool
    metaJson: string         ## populated when isM
    frameBody: seq[byte]     ## raw F packet bytes when isF (decoded later)

  DecoderHandle = ref object
    ## ``WsFrameDecoder`` is a value type; wrapping it in a ``ref``
    ## allows the async ``readNextPacket`` to take a handle by
    ## value (closures cannot capture ``var`` parameters in Nim).
    dec: WsFrameDecoder

proc readNextPacket(sock: AsyncSocket; handle: DecoderHandle;
                    deadline: float): Future[ConnectionFrame] {.async.} =
  ## Pull one M or F packet off the socket; ignores everything else.
  ## Raises ``BridgeTimeoutError`` when ``deadline`` (epoch seconds)
  ## passes before a packet arrives.
  ##
  ## We avoid the ``await sleep or recv`` pattern (which strands the
  ## losing recv future and silently drops bytes between iterations).
  ## Instead we poll in short increments, checking the deadline + the
  ## socket's recv readiness on each tick.
  let fd = AsyncFD(getFd(sock))
  while true:
    var msg = handle.dec.popMessage()
    while msg.complete:
      if msg.opcode == wsOpClose:
        raise newException(BridgeProtocolError,
          "captureViaBridge: bridge closed connection")
      if msg.opcode == wsOpBinary and msg.payload.len > 0:
        let tag = char(msg.payload[0])
        case tag
        of 'M':
          let raw = stringToBytes(msg.payload)
          let meta = decodeMeta(raw)
          return ConnectionFrame(isM: true, metaJson: meta.json)
        of 'F':
          let raw = stringToBytes(msg.payload)
          return ConnectionFrame(isF: true, frameBody: raw)
        else:
          # P/H/D/I etc. — bridge never normally sends these to
          # the client; ignore unknown tags rather than crash.
          discard
      msg = handle.dec.popMessage()
    let now = epochTime()
    if now >= deadline:
      raise newException(BridgeTimeoutError,
        "captureViaBridge: no F packet within timeout")
    # Single recv with the full remaining budget.  ``withTimeout``
    # cancels the inner future on timeout, which is the only way to
    # avoid stranding an in-flight recv on the same FD (parallel
    # recvs on AsyncSocket interleave dangerously).
    let remainingMs = max(int((deadline - now) * 1000.0), 1)
    var recvFut = recvSome(fd, 16384)
    let ok = await withTimeout(recvFut, remainingMs)
    if not ok:
      raise newException(BridgeTimeoutError,
        "captureViaBridge: no F packet within timeout")
    let chunk = recvFut.read()
    if chunk.len == 0:
      raise newException(BridgeProtocolError,
        "captureViaBridge: bridge dropped connection")
    handle.dec.feed(chunk)

# ---------------------------------------------------------------------------
# select-story builder
# ---------------------------------------------------------------------------

proc jsonEscape(s: string): string =
  ## Minimal JSON string escaper — identical to the one in
  ## ``streaming_preview.nim`` so the bridge sees the same bytes
  ## the editor would emit.
  result = newStringOfCap(s.len + 2)
  result.add '"'
  for ch in s:
    case ch
    of '\\': result.add "\\\\"
    of '"': result.add "\\\""
    of '\n': result.add "\\n"
    of '\r': result.add "\\r"
    of '\t': result.add "\\t"
    else:
      if ch.uint8 < 0x20'u8:
        const hexChars = "0123456789abcdef"
        result.add "\\u00"
        result.add hexChars[int(ch.uint8 shr 4)]
        result.add hexChars[int(ch.uint8 and 0x0F'u8)]
      else:
        result.add ch
  result.add '"'

proc storyKindWire(kind: StoryKind): string =
  case kind
  of skFoundation: "skFoundation"
  of skComponent:  "skComponent"
  of skPattern:    "skPattern"
  of skPage:       "skPage"
  of skFlow:       "skFlow"
  of skGuideline:  "skGuideline"
  of skVectorSymbol: "skVectorSymbol"

proc buildSelectStoryIBody(storyRef: StoryRef): string =
  let storyId = storyRef.group & " / " & storyRef.name
  result = "{\"type\":\"select-story\""
  result.add ",\"group\":"
  result.add jsonEscape(storyRef.group)
  result.add ",\"name\":"
  result.add jsonEscape(storyRef.name)
  result.add ",\"kind\":"
  result.add jsonEscape(storyKindWire(storyRef.kind))
  result.add ",\"storyId\":"
  result.add jsonEscape(storyId)
  result.add "}"

proc encodeIPacket(body: string): string =
  ## Bytes for one I packet (no framing).  WS framing happens in
  ## ``sendBinaryFrame``.
  var accum = newStringOfCap(5 + body.len)
  accum.add 'I'
  let n = body.len
  accum.add char(n and 0xFF)
  accum.add char((n shr 8) and 0xFF)
  accum.add char((n shr 16) and 0xFF)
  accum.add char((n shr 24) and 0xFF)
  for ch in body: accum.add ch
  accum

# ---------------------------------------------------------------------------
# Public entry point
# ---------------------------------------------------------------------------

proc captureViaBridgeImpl(bridgeUrl: string; storyRef: StoryRef;
                          backend: PreviewBackend;
                          viewportWidth, viewportHeight: int;
                          timeoutMs: int): Future[BridgeCaptureResult]
                          {.async.} =
  ## Async implementation — public surface is the sync wrapper below.
  let parsed = parseHostPort(bridgeUrl)
  let sock = newAsyncSocket()
  await sock.connect(parsed.host, Port(parsed.port))
  try:
    await handshake(sock, parsed.host, parsed.port, parsed.path)
    let handle = DecoderHandle(dec: initWsFrameDecoder())

    # Send select-story.
    let body = buildSelectStoryIBody(storyRef)
    let iBytes = encodeIPacket(body)
    await sendBinaryFrame(sock, iBytes)

    let deadline = epochTime() + (timeoutMs.float / 1000.0)
    var surfaceWidth = max(viewportWidth, 1)
    var surfaceHeight = max(viewportHeight, 1)

    # Read packets until we see one F, updating surface dimensions
    # from any M packet we observe along the way.
    while true:
      let pkt = await readNextPacket(sock, handle, deadline)
      if pkt.isM:
        try:
          let node = parseJson(pkt.metaJson)
          if node.hasKey("type"):
            let kind = node["type"].getStr
            if kind == "hello" and node.hasKey("initialSize"):
              let sz = node["initialSize"]
              if sz.hasKey("width"): surfaceWidth = sz["width"].getInt
              if sz.hasKey("height"): surfaceHeight = sz["height"].getInt
            elif kind == "resize":
              if node.hasKey("width"): surfaceWidth = node["width"].getInt
              if node.hasKey("height"): surfaceHeight = node["height"].getInt
        except CatchableError:
          discard   # don't fail capture on malformed M
        continue
      if pkt.isF:
        let frame = decodeFrame(pkt.frameBody)
        if frame.kind != fkFull:
          # Capture pipeline expects the first F to be a full frame
          # (the bridge promises this — see ``bridge.buildOutgoingFrame``).
          # Diff-only first frames imply a stateful client, which we
          # don't impersonate.
          raise newException(BridgeProtocolError,
            "captureViaBridge: first F packet was a diff frame; " &
            "the bridge always sends the first frame full")
        # Use the F header's width/height as the authoritative source
        # (they always match the latest M's surface dims).
        let img = PngImage(
          width: frame.width,
          height: frame.height,
          pixels: frame.pixels,
        )
        let png = encodePng32(img)
        # Suppress the "unused" warning for backend without affecting
        # the public surface — backend is reserved for future cross-
        # bridge identification (e.g. when the capture pipeline grows
        # multi-bridge support).
        discard previewBackendToString(backend)
        return BridgeCaptureResult(
          pngBytes: png,
          width: frame.width,
          height: frame.height,
        )
  finally:
    try: sock.close() except CatchableError: discard

proc captureViaBridge*(bridgeUrl: string; storyRef: StoryRef;
                       backend: PreviewBackend;
                       viewportWidth, viewportHeight: int;
                       timeoutMs: int = 30_000): BridgeCaptureResult =
  ## Sync wrapper around the async implementation.  Drives the
  ## global ``asyncdispatch`` until the future completes.
  randomize()
  let fut = captureViaBridgeImpl(bridgeUrl, storyRef, backend,
                                 viewportWidth, viewportHeight, timeoutMs)
  result = waitFor fut
