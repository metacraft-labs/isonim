## RS-M7 — IsoNim Editor streaming-preview widget tests.
##
## Three layers:
##
##   1. Compile + ViewModel tests: the standalone widget module
##      compiles cleanly; the ViewModel's signals, mode selector,
##      and backend-availability detection behave as advertised.
##   2. Backend-detection test: `detectAvailableBackends()` mirrors
##      the host's actual capability matrix; Cocoa/Android appear
##      only on macOS / Android hosts.
##   3. Bridge-launcher integration test: spawns the *real*
##      `isonim-render-serve` binary as a child process, connects
##      via a real WebSocket, asserts the first server frame is the
##      `hello` M packet announcing the backend identifier the
##      launcher passed via `--backend`. This is the no-mocks
##      strong integration test required by the milestone spec.
##
## The integration test relies on the `isonim-render-serve` binary
## being available on `$PATH` or pointed at via
## `$ISONIM_RENDER_SERVE_BIN`. The `setUp` block in this file
## tries `findExe` first and falls back to `nim c`-ing the binary
## from the sibling repo when it can find the source — so running
## inside the metacraft workspace works out of the box.

import std/[asyncdispatch, asyncnet, base64, json, nativesockets,
            net, os, osproc, random, strutils, unittest]

import isonim/core/[signals, computation, owner]
import isonim/editor/types
import isonim/editor/streaming_preview

# Reuse the vendored RFC 6455 frame decoder so the client side
# matches what `isonim-render-serve`'s own integration tests use
# — no mock decoder, no looser parser.
import isonim_render_serve/ws_frame

# ---------------------------------------------------------------------------
# Real WebSocket client (hand-rolled, no network mocks)
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

proc recvOneBinaryMessage(sock: AsyncSocket;
                          timeoutPolls: int = 200):
                          Future[string] {.async.} =
  ## Pump the vendored `WsFrameDecoder` until it yields a complete
  ## message. Returns the payload string; empty string on timeout.
  let fd = AsyncFD(getFd(sock))
  var dec = initWsFrameDecoder()
  var msg = dec.popMessage()
  var attempts = 0
  while not msg.complete and attempts < timeoutPolls:
    let chunk = await recvSome(fd, 16384)
    if chunk.len == 0: break
    dec.feed(chunk)
    msg = dec.popMessage()
    inc attempts
  if msg.complete: return msg.payload
  result = ""

# ---------------------------------------------------------------------------
# Locate the bridge binary
# ---------------------------------------------------------------------------

proc tryBuildBridgeBinary(): string =
  ## Best-effort: if neither `$ISONIM_RENDER_SERVE_BIN` nor
  ## `findExe("isonim-render-serve")` resolves but the sibling repo
  ## is checked out at the workspace's expected path, compile a
  ## one-shot binary under `tests/_build/`.
  let repoRoot = currentSourcePath().parentDir().parentDir()
  let sibling = repoRoot.parentDir() / "isonim-render-serve"
  let srcMain = sibling / "src" / "isonim_render_serve.nim"
  if not fileExists(srcMain): return ""
  let buildDir = repoRoot / "tests" / "_build"
  createDir(buildDir)
  let outPath = buildDir / "isonim-render-serve-rsm7"
  if fileExists(outPath): return outPath
  let cmd = "nim c -d:release --hints:off --warnings:off " &
            "-o:" & quoteShell(outPath) & " " &
            "--path:" & quoteShell(sibling / "src") & " " &
            quoteShell(srcMain)
  let (output, exitCode) = execCmdEx(cmd)
  if exitCode != 0:
    echo "rs-m7 test: failed to build sibling bridge: ", output
    return ""
  result = outPath

proc resolveBridgeBinary(): string =
  let envPath = getEnv("ISONIM_RENDER_SERVE_BIN")
  if envPath.len > 0 and fileExists(envPath):
    return envPath
  let onPath = findExe("isonim-render-serve")
  if onPath.len > 0:
    return onPath
  tryBuildBridgeBinary()

# ---------------------------------------------------------------------------
# Suite 1 — ViewModel + selector
# ---------------------------------------------------------------------------

suite "RS-M7: streaming-preview ViewModel":

  test "newStreamingPreviewVM defaults to pbWeb and lists host backends":
    createRoot do (dispose: proc()):
      let vm = newStreamingPreviewVM()
      check vm.selectedBackend.val == pbWeb
      check vm.status.val == bsIdle
      check vm.bridgePort.val == 0
      check vm.lastError.val == ""
      check vm.needsBridge.val == false
      check vm.bridgeUrl.val == ""
      # Web + TUI are always available; native back-ends depend on host.
      check pbWeb in vm.availableBackends.val
      check pbTui in vm.availableBackends.val
      # The full list never exceeds the enum.
      check vm.availableBackends.val.len <= ord(high(PreviewBackend)) + 1
      dispose()

  test "selectBackend pbGpui sets status to bsLaunching and bridge memo follows port":
    createRoot do (dispose: proc()):
      let vm = newStreamingPreviewVM(initial = pbWeb,
        available = @[pbWeb, pbTui, pbGpui, pbFreya])
      vm.selectBackend(pbGpui)
      check vm.selectedBackend.val == pbGpui
      check vm.needsBridge.val == true
      check vm.status.val == bsLaunching
      check vm.bridgeUrl.val == ""
      # Simulate the launcher binding to a port.
      vm.bridgePort.val = 17234
      vm.status.val = bsRunning
      check vm.bridgeUrl.val == "http://127.0.0.1:17234/"
      dispose()

  test "selectBackend rejects an unavailable backend with bsError":
    createRoot do (dispose: proc()):
      # Available list deliberately excludes Cocoa to simulate a
      # Linux host.
      let vm = newStreamingPreviewVM(initial = pbWeb,
        available = @[pbWeb, pbTui, pbGpui, pbFreya])
      vm.selectBackend(pbCocoa)
      check vm.status.val == bsError
      check vm.lastError.val.contains("Cocoa")
      # Selection should not have flipped to Cocoa.
      check vm.selectedBackend.val == pbWeb
      dispose()

  test "needsBridge and bridgeUrl reflect Web (no bridge) vs GPUI":
    createRoot do (dispose: proc()):
      let vm = newStreamingPreviewVM(initial = pbWeb,
        available = @[pbWeb, pbTui, pbGpui])
      check vm.needsBridge.val == false
      vm.selectBackend(pbTui)
      check vm.needsBridge.val == false   # TUI runs via isonim-tui-serve
      vm.selectBackend(pbGpui)
      check vm.needsBridge.val == true
      dispose()

  test "bumpReloadGeneration increments the reload signal":
    createRoot do (dispose: proc()):
      let vm = newStreamingPreviewVM()
      check vm.reloadGeneration.val == 0
      vm.bumpReloadGeneration()
      vm.bumpReloadGeneration()
      check vm.reloadGeneration.val == 2
      dispose()

  test "backendLabel and backendId match the spec table":
    check backendLabel(pbWeb) == "Web"
    check backendLabel(pbTui) == "TUI"
    check backendLabel(pbGpui) == "GPUI"
    check backendLabel(pbFreya) == "Freya"
    check backendLabel(pbCocoa) == "Cocoa"
    check backendLabel(pbAndroid) == "Android"
    check backendId(pbGpui) == "gpui"
    check backendId(pbFreya) == "freya"
    check backendNeedsRenderServe(pbWeb) == false
    check backendNeedsRenderServe(pbTui) == false
    check backendNeedsRenderServe(pbGpui) == true
    check backendNeedsRenderServe(pbFreya) == true
    check backendNeedsRenderServe(pbCocoa) == true
    check backendNeedsRenderServe(pbAndroid) == true

# ---------------------------------------------------------------------------
# Suite 2 — Backend availability detection (host-aware)
# ---------------------------------------------------------------------------

suite "RS-M7: backend availability detection":

  test "Web and TUI always present":
    let backends = detectAvailableBackends()
    check pbWeb in backends
    check pbTui in backends

  test "Cocoa gated to macOS hosts":
    let backends = detectAvailableBackends()
    when defined(macosx):
      check pbCocoa in backends
    else:
      check pbCocoa notin backends

  test "Android gated to macOS-with-android-sdk or Android hosts":
    let backends = detectAvailableBackends()
    when defined(android):
      check pbAndroid in backends
    elif defined(macosx):
      # macOS host without the android compile flag should NOT
      # advertise the Android adapter through default detection
      # (RS-M6 needs an emulator). The detection treats this as
      # opt-in via the user/editor settings; the default list
      # excludes it.
      check pbAndroid notin backends
    else:
      check pbAndroid notin backends

# ---------------------------------------------------------------------------
# Suite 3 — Bridge launcher integration test (real subprocess + WS)
# ---------------------------------------------------------------------------

suite "RS-M7: bridge launcher integration":

  setup:
    randomize()

  test "launchBridge spawns isonim-render-serve and emits hello M":
    when defined(windows):
      skip()
    else:
      let bin = resolveBridgeBinary()
      if bin.len == 0:
        skip()
      else:
        # Point the registry's defaultStubBinary at the resolved
        # binary by setting the env var the helper consults. This
        # mirrors how the editor's launcher would be configured.
        putEnv(DefaultBridgeBinaryEnv, bin)
        let reg = newBackendBinaryRegistry()
        # We deliberately do NOT call registerBackendBinary so the
        # launcher falls back to `defaultStubBinary` — proves the
        # default lookup path works.
        var bridge: BridgeProcess
        var launchFailed = false
        try:
          bridge = launchBridge(reg, pbGpui, width = 256,
                                height = 256, fps = 5)
        except OSError as e:
          fail()
          echo "launchBridge raised: ", e.msg
          launchFailed = true

        if launchFailed:
          discard
        else:
          check bridge.process.running
          check bridge.port > 0
          check bridge.backend == pbGpui
          check bridge.binary == bin

          proc flow(): Future[string] {.async.} =
            let sock = await connectWs(bridge.port)
            let payload = await recvOneBinaryMessage(sock)
            sock.close()
            return payload

          var helloPayload = ""
          try:
            helloPayload = waitFor flow()
          finally:
            bridge.stop()

          # First server message must be `M` hello announcing
          # protocolVersion=1 and the backend identifier the
          # launcher requested.
          check helloPayload.len > 0
          check helloPayload[0] == 'M'
          # `M` packet layout: byte 0 = 'M', bytes 1..4 = u32 LE
          # length, bytes 5.. = UTF-8 JSON.
          check helloPayload.len >= 5
          let jsonLen = int(byte(helloPayload[1])) or
                        (int(byte(helloPayload[2])) shl 8) or
                        (int(byte(helloPayload[3])) shl 16) or
                        (int(byte(helloPayload[4])) shl 24)
          check jsonLen == helloPayload.len - 5
          let body = helloPayload[5 .. ^1]
          let node = parseJson(body)
          check node["type"].getStr == "hello"
          check node["protocolVersion"].getInt == 1
          check node["backend"].getStr == backendId(pbGpui)
          check node["initialSize"]["width"].getInt == 256
          check node["initialSize"]["height"].getInt == 256

  test "launchBridge raises OSError when binary not registered or found":
    when defined(windows):
      skip()
    else:
      # Snapshot the env, blank the bridge path, and clear $PATH so
      # the lookup fails cleanly.
      let savedEnv = getEnv(DefaultBridgeBinaryEnv)
      let savedPath = getEnv("PATH")
      putEnv(DefaultBridgeBinaryEnv, "")
      putEnv("PATH", "")
      defer:
        putEnv(DefaultBridgeBinaryEnv, savedEnv)
        putEnv("PATH", savedPath)
      let reg = newBackendBinaryRegistry()
      expect OSError:
        discard launchBridge(reg, pbFreya, width = 64,
                            height = 64, fps = 5)

  test "bridgeUrlFor builds the canonical http://127.0.0.1:<port>/ URL":
    check bridgeUrlFor(8765) == "http://127.0.0.1:8765/"
    check bridgeUrlFor(0) == "http://127.0.0.1:0/"

  test "hot-reload signal drives a render effect (real subscription)":
    when defined(windows):
      skip()
    else:
      createRoot do (dispose: proc()):
        let vm = newStreamingPreviewVM()
        var observedGenerations: seq[int] = @[]
        createRenderEffect proc() =
          observedGenerations.add vm.reloadGeneration.val
        vm.bumpReloadGeneration()
        vm.bumpReloadGeneration()
        vm.bumpReloadGeneration()
        # Initial run + three bumps = 4 observations.
        check observedGenerations == @[0, 1, 2, 3]
        dispose()

# ---------------------------------------------------------------------------
# Suite 4 — RS-M12 publish-path invariants
# ---------------------------------------------------------------------------

suite "RS-M12: streaming-preview publish paths":

  test "encodeSelectStoryBody matches a hand-rolled reference":
    let body = encodeSelectStoryBody(
      storyGroup = "Settings App / Pages",
      storyName = "Appearance Group",
      storyKind = "skPage",
      storyId = "Settings App / Pages / Appearance Group")
    let expected = """{"type":"select-story","group":"Settings App / Pages",""" &
                   """"name":"Appearance Group","kind":"skPage",""" &
                   """"storyId":"Settings App / Pages / Appearance Group"}"""
    check body == expected

  test "encodeApplyMutationBody supports primitive scalar literals":
    let bodyBool = encodeApplyMutationBody(
      target = "settings_app/views/Toggle#DarkMode",
      key = "checked",
      valueLiteral = "true",
      scope = msLocalScope)
    let expectedBool = """{"type":"apply-mutation",""" &
                       """"target":"settings_app/views/Toggle#DarkMode",""" &
                       """"key":"checked","value":true,"scope":"local"}"""
    check bodyBool == expectedBool

    let bodyStr = encodeApplyMutationBody(
      target = "settings_app/views/Choice#Theme",
      key = "selected",
      valueLiteral = valueLiteralForString("solarized"),
      scope = msSharedScope)
    let expectedStr = """{"type":"apply-mutation",""" &
                      """"target":"settings_app/views/Choice#Theme",""" &
                      """"key":"selected","value":"solarized","scope":"shared"}"""
    check bodyStr == expectedStr

  test "storyKindWire / storyIdFor cover every editor story kind":
    check storyKindWire(skPage) == "skPage"
    check storyKindWire(skComponent) == "skComponent"
    check storyKindWire(skPattern) == "skPattern"
    check storyKindWire(skFoundation) == "skFoundation"
    check storyKindWire(skFlow) == "skFlow"
    check storyKindWire(skGuideline) == "skGuideline"
    check storyKindWire(skVectorSymbol) == "skVectorSymbol"
    check storyIdFor(StoryRef(group: "Settings App / Pages",
                              name: "Appearance Group",
                              kind: skPage)) ==
      "Settings App / Pages / Appearance Group"

  test "publishSelectStory routes through the registered publisher":
    createRoot do (dispose: proc()):
      let vm = newStreamingPreviewVM()
      var captured: seq[tuple[group, name, kind, storyId: string]] = @[]
      vm.setStoryPublisher(
        sendStory = proc(g, n, k, sid: string) =
          captured.add((g, n, k, sid)),
        sendMutation = proc(t, k, v: string; s: MutationScopeKind) =
          discard
      )
      vm.publishSelectStory("A", "B", "skPage", "A / B")
      vm.publishSelectStory("X", "Y", "skComponent", "X / Y")
      check captured.len == 2
      check captured[0] == ("A", "B", "skPage", "A / B")
      check captured[1] == ("X", "Y", "skComponent", "X / Y")
      dispose()

  test "publishApplyMutation is a no-op for the Web backend":
    createRoot do (dispose: proc()):
      let vm = newStreamingPreviewVM()
      # Default selected backend is Web.
      var captured: seq[string] = @[]
      vm.setStoryPublisher(
        sendStory = proc(g, n, k, sid: string) =
          discard,
        sendMutation = proc(t, k, v: string; s: MutationScopeKind) =
          captured.add(t & "." & k))
      vm.publishApplyMutation("x", "y", "1", msLocalScope)
      check captured.len == 0
      # Switch to a non-Web backend → mutations flow through.
      vm.selectedBackend.val = pbGpui
      vm.publishApplyMutation("x", "y", "1", msLocalScope)
      check captured == @["x.y"]
      dispose()

  test "clearStoryPublisher silences subsequent publishes":
    createRoot do (dispose: proc()):
      let vm = newStreamingPreviewVM()
      vm.selectedBackend.val = pbTui
      var hits = 0
      let sendStoryFn = proc(g, n, k, sid: string) =
        inc hits
      let sendMutationFn = proc(t, k, v: string; s: MutationScopeKind) =
        discard
      vm.setStoryPublisher(sendStory = sendStoryFn,
                            sendMutation = sendMutationFn)
      vm.publishSelectStory("A", "B", "skPage", "A / B")
      check hits == 1
      vm.clearStoryPublisher()
      vm.publishSelectStory("C", "D", "skPage", "C / D")
      check hits == 1  # no-op after clear

# ---------------------------------------------------------------------------
# Suite 5 — ERV-M2 canvas-blank-on-resize regression guards
# ---------------------------------------------------------------------------

## ERV-M2 (2026-05-31): the browser-side bridge client lives in a
## ``{.emit: ...}`` block — there is no Nim-callable surface for the
## ``handleW`` / ``handleF`` packet handlers, so we can't drive them
## from a unit test without standing up a real browser (forbidden by
## the milestone: no ``just editor-build`` and no playwright in this
## fix's test surface). Instead we use ``staticRead`` to snapshot the
## emitted JS source at compile time and assert that the load-bearing
## guards stay in place. If a future refactor strips the partial-
## draw skip or the snapshot-preserve in ``ensureSize`` the test
## fails at compile time with a precise pointer to the bug class
## (canvas blank flash after resize). The browser-side behaviour is
## covered by the existing playwright VRS regression suites the
## orchestrator runs after the milestone lands.

const streamingPreviewSrc = staticRead(
  "../src/isonim/editor/streaming_preview.nim")

suite "ERV-M2: canvas-blank-on-resize guards":

  test "pendingResizeNeedsFullFrame flag declared in bridge JS closure":
    check streamingPreviewSrc.contains(
      "var pendingResizeNeedsFullFrame = false;")

  test "ensureSize snapshots prior canvas before resizing":
    check streamingPreviewSrc.contains(
      "snapshotCanvas =\n                  document.createElement('canvas');")
    check streamingPreviewSrc.contains("snapCtx.drawImage(canvas, 0, 0);")
    check streamingPreviewSrc.contains(
      "rctx.drawImage(snapshotCanvas, 0, 0,\n                                 width, height);")

  test "ensureSize arms the partial-draw guard on dim change":
    check streamingPreviewSrc.contains(
      "if (hadPriorContent) {\n              pendingResizeNeedsFullFrame = true;")

  test "W-diff partial-draw branch skips when the guard is set":
    # The dispatch-time check (before kicking off bitmap decode).
    check streamingPreviewSrc.contains(
      "if (pendingResizeNeedsFullFrame) {\n            try {")
    # The promise-resolution check (covers the resize-during-decode race).
    check streamingPreviewSrc.contains(
      "if (pendingResizeNeedsFullFrame) {\n                for (var i = 0; i < decoded.length; i++) {")

  test "F-diff partial-draw branch skips when the guard is set":
    check streamingPreviewSrc.contains(
      "if (pendingResizeNeedsFullFrame) {\n              try {\n                if (window.__isonimTestMode === true) {\n                  if (!Array.isArray(\n                      window.__isonimFDiffSkippedAfterResize)) {")

  test "W-full / F-full / V-frame paths clear the guard":
    # Counts: declaration (false) + W-full clear + F-full clear + V-frame
    # clear = 4 occurrences of the explicit reset.
    var clears = 0
    var i = 0
    while true:
      let j = streamingPreviewSrc.find(
        "pendingResizeNeedsFullFrame = false;", i)
      if j < 0: break
      inc clears
      i = j + 1
    # 1 for the declaration line, 3 for the explicit per-path clears.
    check clears >= 4
