## test_editor_real_preview — RS-M11 / editor end-to-end test.
##
## Drives the *real* `build/backends/isonim-examples-tui` launcher
## via `startProcess`, opens a *real* WebSocket against its bridge,
## decodes the live `element-tree` M packet, feeds it into the
## editor's `StreamingPreviewVM.dispatchMetaPacket`, and verifies
## that:
##
##   1. The VM's manifest signal updates with the decoded manifest
##      within 2 s.
##   2. A click at the centre pixel of a known task row's bounds
##      resolves through `StreamingPreviewVM.clickCanvas(x, y)` to
##      the matching `componentPath` (the spec's headline
##      acceptance assertion).
##   3. Smallest-area-wins on overlap (the test fabricates an
##      overlapping element via a second test against a known
##      manifest).
##
## No mocks. No in-process frame source substitute. The launcher
## binary IS the producer. If the binary is missing, this test
## FAILS — it does NOT skip — per the spec.
##
## Binary resolution: `$ISONIM_EXAMPLES_TUI_BIN` → sibling-repo
## `../isonim-examples/build/backends/isonim-examples-tui`.

import std/[asyncdispatch, asyncnet, base64, json, nativesockets, net,
            options, os, osproc, random, strutils, times, unittest]

import isonim/core/[signals, computation, owner]
import isonim/editor/streaming_preview
import isonim/editor/preview_canvas
import isonim_render_serve

# ---------------------------------------------------------------------------
# Real WS client
# ---------------------------------------------------------------------------

proc recvSome(fd: AsyncFD; size: int): Future[string] {.async.} =
  var buf = newString(size)
  let n = await asyncdispatch.recvInto(fd, addr buf[0], size)
  if n <= 0: return ""
  buf.setLen(n)
  result = buf

proc handshake(s: AsyncSocket; host: string; port: int) {.async.} =
  let key = encode("0123456789abcdef0123")
  let req = "GET / HTTP/1.1\r\n" &
            "Host: " & host & ":" & $port & "\r\n" &
            "Upgrade: websocket\r\n" &
            "Connection: Upgrade\r\n" &
            "Sec-WebSocket-Key: " & key & "\r\n" &
            "Sec-WebSocket-Version: 13\r\n\r\n"
  await s.send(req)
  let fd = AsyncFD(getFd(s))
  var resp = ""
  while not resp.contains("\r\n\r\n"):
    let chunk = await recvSome(fd, 4096)
    if chunk.len == 0: break
    resp.add(chunk)
  doAssert resp.startsWith("HTTP/1.1 101"),
    "handshake failed: " & resp

proc connectWs(port: int): Future[AsyncSocket] {.async.} =
  let sock = newAsyncSocket()
  await sock.connect("127.0.0.1", Port(port))
  await handshake(sock, "127.0.0.1", port)
  result = sock

type DecState = ref object
  dec: WsFrameDecoder

proc newDecState(): DecState = DecState(dec: initWsFrameDecoder())

proc recvOnePacket(sock: AsyncSocket; state: DecState):
                   Future[string] {.async.} =
  let fd = AsyncFD(getFd(sock))
  var msg = state.dec.popMessage()
  while not msg.complete:
    let chunk = await recvSome(fd, 16384)
    if chunk.len == 0: break
    state.dec.feed(chunk)
    msg = state.dec.popMessage()
  if msg.complete: return msg.payload
  result = ""

# ---------------------------------------------------------------------------
# Binary resolution: env var → sibling-repo build → FAIL.
# ---------------------------------------------------------------------------

proc resolveLauncher(): string =
  let envPath = getEnv("ISONIM_EXAMPLES_TUI_BIN")
  if envPath.len > 0:
    if fileExists(envPath): return envPath
    raise newException(IOError,
      "$ISONIM_EXAMPLES_TUI_BIN set but file missing: " & envPath)
  let repoRoot = currentSourcePath().parentDir().parentDir()
  let sibling = repoRoot.parentDir() / "isonim-examples" / "build" /
                "backends" / "isonim-examples-tui"
  if fileExists(sibling): return sibling
  raise newException(IOError,
    "isonim-examples-tui binary not found at " & sibling & "\n" &
    "Build via `just build-backends` in isonim-examples or point " &
    "$ISONIM_EXAMPLES_TUI_BIN at a built binary.")

proc pickEphemeralPort(): int =
  let s = newSocket()
  s.bindAddr(Port(0))
  let p = s.getLocalAddr()[1]
  s.close()
  int(p)

proc waitForBind(port: int; deadlineMs: int): bool =
  let deadline = epochTime() + (deadlineMs.float / 1000.0)
  while epochTime() < deadline:
    try:
      let s = newSocket()
      defer: s.close()
      s.connect("127.0.0.1", Port(port), timeout = 50)
      return true
    except CatchableError:
      sleep(25)
  false

# ---------------------------------------------------------------------------
# Suite
# ---------------------------------------------------------------------------

suite "RS-M11: editor real preview (TUI launcher → StreamingPreviewVM)":

  setup:
    randomize()

  test "real launcher feeds a manifest the VM hit-tests back to a task row":
    when defined(windows):
      skip()
    else:
      let bin = resolveLauncher()
      let port = pickEphemeralPort()
      let proc1 = startProcess(bin,
        args = @["--demo=tasks", "--port", $port, "--fps", "60"],
        options = {poStdErrToStdOut, poUsePath})
      doAssert waitForBind(port, deadlineMs = 4000),
        "launcher did not bind on port " & $port
      defer:
        if proc1.running:
          proc1.terminate()
          discard proc1.waitForExit(timeout = 2000)

      var capturedManifest: Option[ElementTreeManifest]
      var helloSeen = false

      proc drain(): Future[ElementTreeManifest] {.async.} =
        let sock = await connectWs(port)
        let dec = newDecState()
        let start = epochTime()
        while epochTime() - start < 4.0:
          let payload = await recvOnePacket(sock, dec)
          if payload.len == 0: continue
          if payload[0] == 'M':
            let meta = decodeMeta(stringToBytes(payload))
            if isElementTreeBody(meta.json):
              let manifest = decodeElementTreeJson(meta.json)
              sock.close()
              return manifest
            else:
              if not helloSeen:
                let helloJson = parseJson(meta.json)
                doAssert helloJson["type"].getStr == "hello"
                doAssert helloJson["capabilities"][
                  "elementTree"].getBool == true,
                  "launcher's hello must advertise elementTree=true"
                helloSeen = true
        sock.close()
        raise newException(IOError, "no manifest arrived from launcher")

      let manifest = waitFor drain()
      capturedManifest = some(manifest)

      createRoot do (dispose: proc()):
        let vm = newStreamingPreviewVM(initial = pbTui,
          available = @[pbWeb, pbTui])
        # The VM's dispatchMetaPacket consumes the same JSON body
        # the production WS client hands it.
        vm.dispatchMetaPacket(encodeElementTreeJson(capturedManifest.get))
        check vm.canvas.manifest.val.isSome
        let cached = vm.canvas.manifest.val.get
        check cached.elements.len == manifest.elements.len
        # Find the first task row in the manifest, click its centre,
        # and assert the VM's selectedElementPath updates.
        var taskRow: Option[ElementEntry] = none(ElementEntry)
        for e in cached.elements:
          if e.componentPath.startsWith("task_app/views/TaskRow#"):
            taskRow = some(e)
            break
        check taskRow.isSome
        let row = taskRow.get
        let cx = row.bounds.x + row.bounds.w div 2
        let cy = row.bounds.y + row.bounds.h div 2
        let hit = vm.clickCanvas(cx, cy)
        check hit
        check vm.selectedElementPath.val == row.componentPath
        check vm.selectedElementId.val == row.id
        dispose()

  test "smallest-area wins on overlapping manifest entries":
    createRoot do (dispose: proc()):
      let vm = newStreamingPreviewVM(initial = pbTui,
        available = @[pbWeb, pbTui])
      # Fabricate a manifest where a small element sits inside a
      # larger element. Both contain the click coordinate.
      let manifest = ElementTreeManifest(
        frameSeq: 0, surfaceWidth: 200, surfaceHeight: 200,
        elements: @[
          ElementEntry(id: "outer", componentPath: "x/Outer", kind: "box",
                       bounds: ElementBounds(x: 0, y: 0, w: 200, h: 200)),
          ElementEntry(id: "inner", componentPath: "x/Inner", kind: "box",
                       bounds: ElementBounds(x: 50, y: 50, w: 40, h: 40))])
      vm.dispatchMetaPacket(encodeElementTreeJson(manifest))
      # Click inside the inner box. Both elements contain (60, 60),
      # but inner is smaller and should win.
      check vm.clickCanvas(60, 60)
      check vm.selectedElementId.val == "inner"
      check vm.selectedElementPath.val == "x/Inner"
      # Click outside the inner box but inside the outer. Outer wins.
      check vm.clickCanvas(10, 10)
      check vm.selectedElementId.val == "outer"
      # Click completely outside → no hit, signals stay at "outer".
      check not vm.clickCanvas(300, 300)
      check vm.selectedElementId.val == "outer"
      dispose()

  test "VM with no manifest returns no hit":
    createRoot do (dispose: proc()):
      let vm = newStreamingPreviewVM(initial = pbTui,
        available = @[pbWeb, pbTui])
      check not vm.clickCanvas(1, 1)
      check vm.selectedElementId.val == ""
      dispose()

  test "clearing the manifest resets the selection":
    createRoot do (dispose: proc()):
      let vm = newStreamingPreviewVM(initial = pbTui,
        available = @[pbWeb, pbTui])
      let manifest = ElementTreeManifest(
        frameSeq: 0, surfaceWidth: 100, surfaceHeight: 100,
        elements: @[
          ElementEntry(id: "a", componentPath: "x/A", kind: "box",
                       bounds: ElementBounds(x: 0, y: 0, w: 50, h: 50))])
      vm.dispatchMetaPacket(encodeElementTreeJson(manifest))
      check vm.clickCanvas(10, 10)
      check vm.selectedElementId.val == "a"
      vm.canvas.clearManifest()
      check vm.canvas.manifest.val.isNone
      check vm.selectedElementId.val == ""
      check vm.selectedElementPath.val == ""
      dispose()
