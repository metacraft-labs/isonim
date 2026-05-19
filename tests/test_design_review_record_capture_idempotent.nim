## REV-M5 — idempotency under re-run.
##
## Drives the same (preview, viewport) capture twice against a fake
## bridge and asserts the DB's natural-key dedup contract:
##
##   * Re-recording the same ``(run_id, preview_id, viewport_label)``
##     tuple inserts no new row in ``captures``.
##   * The corresponding ``capture.recorded`` audit event is emitted
##     *only* for the first insert; the retry is silent.
##
## This exercises the SQL routine ``design_review.record_capture``'s
## documented idempotency contract directly through the orchestrator
## helpers in ``capture.nim``.

import std/[asyncdispatch, asyncnet, nativesockets, net, os,
            strutils, times, unittest]

import db_connector/db_postgres

import isonim_render_serve/packet
import isonim_render_serve/ws_frame
import isonim_render_serve/bridge   # computeAcceptKey

import isonim/editor/design_review/bridge_client
import isonim/editor/design_review/capture
import isonim/editor/design_review/capture_store
import isonim/editor/design_review/db as dr_db
import isonim/editor/design_review/brief_format
import isonim/editor/types

import helpers/design_review_pg_fixture

# ---------------------------------------------------------------------------
# Fake bridge
# ---------------------------------------------------------------------------

type FakeBridge = ref object
  port: int
  listener: AsyncSocket
  closing: bool

proc pickPort(): int =
  let s = newSocket()
  s.bindAddr(Port(0))
  let p = s.getLocalAddr()[1]
  s.close()
  int(p)

proc respondOnce(client: AsyncSocket) {.async.} =
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
    "{\"type\":\"hello\",\"protocolVersion\":1,\"backend\":\"web\"," &
    "\"capabilities\":{},\"initialSize\":{\"width\":32,\"height\":32}}")
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
      if msg.opcode == wsOpBinary: sawI = true; break
  var pixels = newSeq[byte](32 * 32 * 4)
  for i in 0 ..< pixels.len: pixels[i] = byte(i and 0xFF)
  let frame = Frame(kind: fkFull,
                    flags: FrameFlags(isDiff: false, isVideo: false),
                    width: 32, height: 32, pixels: pixels)
  await client.send(encodeWsBinaryFrame(bytesToString(encodeFrame(frame))))
  for _ in 0 ..< 20:
    if client.isClosed: break
    await sleepAsync(25)
  try: client.close() except CatchableError: discard

proc startFakeBridge(): FakeBridge =
  let port = pickPort()
  let listener = newAsyncSocket()
  listener.setSockOpt(OptReuseAddr, true)
  listener.bindAddr(Port(port))
  listener.listen()
  result = FakeBridge(port: port, listener: listener, closing: false)
  let fbRef = result
  proc loop() {.async.} =
    while not fbRef.closing:
      try:
        let client = await fbRef.listener.accept()
        asyncCheck respondOnce(client)
      except CatchableError:
        break
  asyncCheck loop()
  for _ in 0 .. 3: poll(20)

proc stop(fb: FakeBridge) =
  fb.closing = true
  try: fb.listener.close() except CatchableError: discard

# ---------------------------------------------------------------------------
# Test
# ---------------------------------------------------------------------------

const Cov = BriefPreviewCoverage(
  storyRef: StoryRef(group: "G", name: "N", kind: skPage, index: 0),
  backends: @[pbWeb])

suite "REV-M5 record_capture idempotency":

  test "test_record_capture_idempotent_on_retry":
    let pgf = newPgFixture()
    defer: pgf.shutdown()
    let fb = startFakeBridge()
    defer: fb.stop()

    let appConn = open("", "design_review_app", "",
                       "host=127.0.0.1 port=" & $pgf.port &
                       " dbname=isonim_design_review user=design_review_app")
    let dr = ReviewDb(conn: appConn)
    defer: dr.close()

    let migConn = open("", "design_review_migrator", "",
                       "host=127.0.0.1 port=" & $pgf.port &
                       " dbname=isonim_design_review user=design_review_migrator")
    defer: migConn.close()

    let storePath = getTempDir() / ("isonim_idem_store_" &
                                     $epochTime().int)
    defer: removeDir(storePath)
    let store = newCaptureStore(storePath)

    let bridgeUrl = "ws://127.0.0.1:" & $fb.port
    let previewId = canonicalPreviewId(Cov.storyRef, pbWeb)

    proc oneRun(): string =
      let runId = startRun(dr, "render.fixture", "abc123", "tester")
      let res = captureViaBridge(bridgeUrl, Cov.storyRef, pbWeb,
                                 32, 32, 8_000)
      let stored = store.put(res.pngBytes)
      discard recordCapture(dr, runId, previewId, "web", "tablet",
                            stored.sha256, stored.path,
                            res.width, res.height)
      finishCaptures(dr, runId)
      runId

    let r1 = oneRun()
    let r2 = oneRun()
    check r1 != r2

    proc countAll(q: string): int =
      parseInt(migConn.getValue(sql(q)))

    let firstCaptures = countAll("SELECT count(*) FROM design_review.captures")
    let firstAudits   = countAll("SELECT count(*) FROM design_review.audit_events")
    check firstCaptures == 2  # one per run

    # Now exercise the *direct* idempotent-retry path.  Open a new
    # run, insert the same preview twice — second insert must be a
    # natural no-op (ON CONFLICT DO NOTHING + the routine's audit
    # gate).
    let r3 = startRun(dr, "render.fixture", "abc123", "tester")
    discard recordCapture(dr, r3, previewId, "web", "tablet",
                          "sha-x", "/path/x", 32, 32)
    discard recordCapture(dr, r3, previewId, "web", "tablet",
                          "sha-x", "/path/x", 32, 32)
    finishCaptures(dr, r3)
    let secondCaptures = countAll("SELECT count(*) FROM design_review.captures")
    check secondCaptures == 3  # exactly +1, not +2

    # Audit deltas: start_run (+1) + capture.recorded (+1) +
    # run.captures_finished (+1) = +3.  No duplicate capture.recorded.
    let secondAudits = countAll("SELECT count(*) FROM design_review.audit_events")
    check (secondAudits - firstAudits) == 3
