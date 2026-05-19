## REV-M5 — bridge client unit tests.
##
## We boot a tiny WebSocket fake-bridge server (real ``asyncnet``,
## real RFC 6455 framing, real F/M packets — *not* an in-process
## function call) and assert the client decodes the canned frame
## byte-for-byte.
##
## The fake bridge is intentionally minimal: one connection at a
## time, no diff frames, no element-tree manifest.  It exists only
## so the client side has a real, isolated server to talk to.

import std/[asyncdispatch, asyncnet, nativesockets, net,
            strutils, times, unittest]

import isonim_render_serve/packet
import isonim_render_serve/ws_frame
import isonim_render_serve/bridge  # for computeAcceptKey
import isonim/editor/design_review/bridge_client
import isonim/editor/design_review/png_codec
import isonim/editor/types

# ---------------------------------------------------------------------------
# Fake bridge — minimal WS upgrade + canned packets.
# ---------------------------------------------------------------------------

type
  FakeBridge = ref object
    port: int
    listener: AsyncSocket
    width, height: int
    pixels: seq[byte]
    refuseFrame: bool      ## when true, accept the I but never send F

proc pickPort(): int =
  let s = newSocket()
  s.bindAddr(Port(0))
  let p = s.getLocalAddr()[1]
  s.close()
  int(p)

proc handleClient(fb: FakeBridge; client: AsyncSocket) {.async.} =
  # Read the HTTP upgrade request line + headers up to \r\n\r\n.
  let fd = AsyncFD(getFd(client))
  var req = ""
  while not req.contains("\r\n\r\n"):
    var buf = newString(4096)
    let n = await asyncdispatch.recvInto(fd, addr buf[0], buf.len)
    if n <= 0:
      try: client.close() except CatchableError: discard
      return
    buf.setLen(n)
    req.add buf
  # Pull out Sec-WebSocket-Key.
  var key = ""
  for line in req.splitLines():
    if line.toLowerAscii.startsWith("sec-websocket-key:"):
      key = line.split(':', 1)[1].strip()
  let accept = computeAcceptKey(key)
  let resp = "HTTP/1.1 101 Switching Protocols\r\n" &
             "Upgrade: websocket\r\nConnection: Upgrade\r\n" &
             "Sec-WebSocket-Accept: " & accept & "\r\n\r\n"
  await client.send(resp)

  # Send the M hello packet first.
  let hello = MetaPacket(json:
    "{\"type\":\"hello\",\"protocolVersion\":1,\"backend\":\"stub\"," &
    "\"capabilities\":{}," &
    "\"initialSize\":{\"width\":" & $fb.width &
    ",\"height\":" & $fb.height & "}}")
  let helloBytes = encodeMeta(hello)
  await client.send(encodeWsBinaryFrame(bytesToString(helloBytes)))

  # Wait for the client's I packet (we don't actually decode it for
  # this test — we just want to make sure the round-trip works).
  var dec = initWsFrameDecoder()
  var sawI = false
  while not sawI:
    var buf = newString(4096)
    let n = await asyncdispatch.recvInto(fd, addr buf[0], buf.len)
    if n <= 0: break
    buf.setLen(n)
    dec.feed(buf)
    while true:
      let msg = dec.popMessage()
      if not msg.complete: break
      if msg.opcode == wsOpBinary and msg.payload.len > 0:
        sawI = true
        break

  if fb.refuseFrame:
    # Stay open without sending F: let the client time out.
    while not client.isClosed:
      await sleepAsync(50)
    return

  # Send one full F packet carrying the canned pixels.
  let frame = Frame(kind: fkFull,
                    flags: FrameFlags(isDiff: false, isVideo: false),
                    width: fb.width, height: fb.height,
                    pixels: fb.pixels)
  let frameBytes = encodeFrame(frame)
  await client.send(encodeWsBinaryFrame(bytesToString(frameBytes)))

  # Hold the connection open briefly so the client has time to
  # finish reading.
  for _ in 0 ..< 20:
    if client.isClosed: break
    await sleepAsync(50)
  try: client.close() except CatchableError: discard

proc startFakeBridge(width, height: int; pixels: seq[byte];
                     refuseFrame = false): FakeBridge =
  let port = pickPort()
  let listener = newAsyncSocket()
  listener.setSockOpt(OptReuseAddr, true)
  listener.bindAddr(Port(port))
  listener.listen()
  result = FakeBridge(port: port, listener: listener,
                      width: width, height: height,
                      pixels: pixels, refuseFrame: refuseFrame)
  let fbRef = result
  proc loop() {.async.} =
    try:
      let client = await fbRef.listener.accept()
      await handleClient(fbRef, client)
    except CatchableError:
      discard
  asyncCheck loop()
  # Drive the dispatcher long enough for the listen socket to bind.
  for _ in 0 .. 3: poll(20)

proc stopFakeBridge(fb: FakeBridge) =
  try: fb.listener.close() except CatchableError: discard

# ---------------------------------------------------------------------------
# Helpers for the canned pixel buffer
# ---------------------------------------------------------------------------

proc checkerboard(width, height: int): seq[byte] =
  ## 32×32 RGBA checker — each 16×16 block alternates white/black.
  result = newSeq[byte](width * height * 4)
  for y in 0 ..< height:
    for x in 0 ..< width:
      let blockId = ((x div 16) + (y div 16)) mod 2
      let off = (y * width + x) * 4
      if blockId == 0:
        result[off] = 0xFF'u8
        result[off + 1] = 0xFF'u8
        result[off + 2] = 0xFF'u8
      else:
        result[off] = 0x00'u8
        result[off + 1] = 0x00'u8
        result[off + 2] = 0x00'u8
      result[off + 3] = 0xFF'u8

# ---------------------------------------------------------------------------
# Tests
# ---------------------------------------------------------------------------

const story = StoryRef(group: "Fixture", name: "Index",
                       kind: skPage, index: 0)

suite "REV-M5 bridge client":

  test "test_bridge_client_decodes_canned_frame":
    let pixels = checkerboard(300, 200)
    let fb = startFakeBridge(300, 200, pixels)
    defer: stopFakeBridge(fb)
    let res = captureViaBridge(
      bridgeUrl = "ws://127.0.0.1:" & $fb.port,
      storyRef = story,
      backend = pbWeb,
      viewportWidth = 300, viewportHeight = 200,
      timeoutMs = 5000)
    check res.width == 300
    check res.height == 200
    # Decode the PNG back; pixels must byte-equal the input.
    let img = decodePng32(res.pngBytes)
    check img.width == 300
    check img.height == 200
    check img.pixels == pixels

  test "test_bridge_client_times_out_when_no_frame":
    let fb = startFakeBridge(64, 64, checkerboard(64, 64),
                             refuseFrame = true)
    defer: stopFakeBridge(fb)
    var raised = false
    let t0 = epochTime()
    try:
      discard captureViaBridge(
        bridgeUrl = "ws://127.0.0.1:" & $fb.port,
        storyRef = story,
        backend = pbWeb,
        viewportWidth = 64, viewportHeight = 64,
        timeoutMs = 1000)
    except BridgeTimeoutError:
      raised = true
    let elapsedMs = int((epochTime() - t0) * 1000.0)
    check raised
    # Within the documented "1100 ms" budget.
    check elapsedMs <= 2200
