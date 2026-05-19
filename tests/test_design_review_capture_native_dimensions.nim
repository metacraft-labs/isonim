## REV-M5 — native dimensions preserved end-to-end.
##
## The capture pipeline must never resample / downscale F packet
## pixels.  Here we boot a fake bridge advertising 1080×2340 (an
## Android phone surface), hand it a deterministic reference
## buffer, run ``captureViaBridge``, decode the resulting PNG, and
## assert byte-identical pixels.

import std/[asyncdispatch, asyncnet, nativesockets, net,
            strutils, unittest]

import isonim_render_serve/packet
import isonim_render_serve/ws_frame
import isonim_render_serve/bridge   # computeAcceptKey
import isonim/editor/design_review/bridge_client
import isonim/editor/design_review/png_codec
import isonim/editor/types

# ---------------------------------------------------------------------------
# Minimal fake bridge (same shape as test_design_review_bridge_client.nim
# but stripped to the one shape this test needs).
# ---------------------------------------------------------------------------

proc pickPort(): int =
  let s = newSocket()
  s.bindAddr(Port(0))
  let p = s.getLocalAddr()[1]
  s.close()
  int(p)

proc handleClient(client: AsyncSocket; width, height: int;
                  pixels: seq[byte]) {.async.} =
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
  var key = ""
  for line in req.splitLines():
    if line.toLowerAscii.startsWith("sec-websocket-key:"):
      key = line.split(':', 1)[1].strip()
  let accept = computeAcceptKey(key)
  await client.send("HTTP/1.1 101 Switching Protocols\r\n" &
                    "Upgrade: websocket\r\nConnection: Upgrade\r\n" &
                    "Sec-WebSocket-Accept: " & accept & "\r\n\r\n")
  let hello = MetaPacket(json:
    "{\"type\":\"hello\",\"protocolVersion\":1,\"backend\":\"android\"," &
    "\"capabilities\":{},\"initialSize\":{\"width\":" & $width &
    ",\"height\":" & $height & "}}")
  await client.send(encodeWsBinaryFrame(bytesToString(encodeMeta(hello))))
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
  let frame = Frame(kind: fkFull,
                    flags: FrameFlags(isDiff: false, isVideo: false),
                    width: width, height: height, pixels: pixels)
  await client.send(encodeWsBinaryFrame(bytesToString(encodeFrame(frame))))
  for _ in 0 ..< 20:
    if client.isClosed: break
    await sleepAsync(50)
  try: client.close() except CatchableError: discard

proc startFakeBridge(width, height: int; pixels: seq[byte]): int =
  let port = pickPort()
  let listener = newAsyncSocket()
  listener.setSockOpt(OptReuseAddr, true)
  listener.bindAddr(Port(port))
  listener.listen()
  proc loop() {.async.} =
    try:
      let client = await listener.accept()
      await handleClient(client, width, height, pixels)
      try: listener.close() except CatchableError: discard
    except CatchableError:
      discard
  asyncCheck loop()
  for _ in 0 .. 3: poll(20)
  port

# ---------------------------------------------------------------------------
# Reference pixel buffer
# ---------------------------------------------------------------------------

proc referencePixels(width, height: int): seq[byte] =
  ## Deterministic gradient: R = x mod 256, G = y mod 256,
  ## B = (x + y) mod 256, A = 255.  Reproducible by both sides
  ## of the equality assertion.
  result = newSeq[byte](width * height * 4)
  for y in 0 ..< height:
    for x in 0 ..< width:
      let off = (y * width + x) * 4
      result[off]     = byte(x and 0xFF)
      result[off + 1] = byte(y and 0xFF)
      result[off + 2] = byte((x + y) and 0xFF)
      result[off + 3] = 0xFF'u8

# ---------------------------------------------------------------------------
# Test
# ---------------------------------------------------------------------------

const TestStory = StoryRef(group: "Phone", name: "Home",
                           kind: skPage, index: 0)

suite "REV-M5 native dimensions":

  test "test_capture_native_dimensions_preserved":
    const w = 1080
    const h = 2340
    let pixels = referencePixels(w, h)
    let port = startFakeBridge(w, h, pixels)
    let res = captureViaBridge(
      bridgeUrl = "ws://127.0.0.1:" & $port,
      storyRef = TestStory,
      backend = pbAndroid,
      viewportWidth = w, viewportHeight = h,
      timeoutMs = 15_000)
    check res.width == w
    check res.height == h
    let img = decodePng32(res.pngBytes)
    check img.width == w
    check img.height == h
    check img.pixels == pixels
