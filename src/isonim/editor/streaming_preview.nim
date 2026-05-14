## IsoNim Editor — streaming-preview widget (RS-M7).
##
## Standalone, reusable module that wires the editor's preview pane
## to `isonim-render-serve` (see the IsoNim render-stream spec under
## `Front-Ends/IsoNim/isonim-render-stream.status.org` in the
## cross-project specs repo).
## The editor's preview pane today (`views/page_preview.nim`) does
## HTML-only previews via an iframe with `srcdoc`. For native
## back-ends that don't run in the browser (GPUI / Freya / Cocoa /
## Android) the preview switches to streaming-bridge mode: a child
## `isonim-render-serve`-style process runs the user's compiled app,
## captures frames, and streams F/M/I packets over a WebSocket; the
## preview pane's iframe loads the bridge's `static/index.html`
## canvas client and connects to `ws://127.0.0.1:<port>/`.
##
## *Status (RS-M7 scope-down).* The editor's `ProjectPreviewVM`
## still serves HTML payloads; native back-end pipelines are M55+
## scope. This module is the *standalone widget/module* the editor
## can drop into its preview pane once those pipelines land: a
## headless ViewModel + a subprocess launcher + an iframe-src builder
## + a hot-reload hook. RS-M7's integration tests exercise it
## against the real `isonim-render-serve` binary so the
## drop-in is proved end-to-end against the locked wire protocol.
##
## *Backend availability.* The widget exposes
## `detectAvailableBackends` so the editor's Mode menu surfaces only
## modes the running host can actually serve:
##
##   * Web — always (renders in the iframe natively, no bridge).
##   * TUI — always (the `isonim-tui-serve` M26 bridge is
##     Linux-buildable everywhere our editor runs).
##   * GPUI — Linux-real (RS-M2).
##   * Freya — Linux-real (RS-M4).
##   * Cocoa — macOS host only (RS-M5 is partial-linux; the
##     selector lists it but the launcher returns a clear error if
##     the host is not macOS).
##   * Android — macOS host with an emulator only (RS-M6 same
##     gating; clear error otherwise).
##
## The Cocoa/Android entries in the selector mirror the spec's
## "mode is listed; the bridge fails gracefully" behaviour.
##
## *Bridge launcher mechanism.* `launchBridge` shells out to a
## per-backend binary via `std/osproc`. The default binary is
## `isonim-render-serve` (the stub source, RS-M7 extends its CLI
## with `--backend <name>`); the editor swaps in per-back-end binary
## paths via `registerBackendBinary` once `isonim-examples` ships
## per-backend streaming demos. The launcher passes
## `--port <ephemeral> --backend <name>`, waits briefly for the
## listening socket, and yields a `BridgeProcess` handle the editor
## stores for the lifetime of the preview tab. Stopping the bridge
## terminates the child process.
##
## *Hot-reload.* The editor already maintains
## `EditorVM.livePreviewReloadGeneration: Signal[int]` that ticks
## every time the workspace adapter applies an edit and the live
## preview should reload (see `viewmodels.nim` ~line 6760). When the
## streaming widget is mounted it subscribes via a render effect:
## each bump of the generation signal stops the current bridge and
## relaunches it, so the freshly-recompiled native binary takes
## over and the canvas client reconnects on the same iframe.
##
## *No mocks.* Tests under `tests/test_editor_streaming_preview_*.nim`
## spawn the real `isonim-render-serve` binary, connect via a real
## WebSocket client, and assert the `hello` M packet announces the
## backend identifier the launcher requested.

import std/[options, tables]
when not defined(js):
  import std/[net, os, osproc, times]
when defined(js):
  import std/jsffi
  import std/dom

import isonim/core/[signals, computation]
import isonim/editor/types
import isonim/editor/preview_canvas
import isonim_render_serve

export types.PreviewBackend
export preview_canvas
export isonim_render_serve.ElementTreeManifest
export isonim_render_serve.ElementEntry
export isonim_render_serve.ElementBounds

type
  MutationScopeKind* = enum
    ## RS-M12. Editor → launcher ``apply-mutation`` scope. Mirrors
    ## ``isonim_render_serve.MutationScope`` 1:1 but is duplicated
    ## here so callers don't have to import `isonim_render_serve`
    ## for the public API.
    msLocalScope = "local"
    msSharedScope = "shared"

func mutationScopeWire*(scope: MutationScopeKind): string =
  ## Wire string for the ``scope`` field of ``apply-mutation``.
  case scope
  of msLocalScope: "local"
  of msSharedScope: "shared"

type
  BridgeStatus* = enum
    bsIdle       ## No bridge running (Web/TUI default).
    bsLaunching  ## Subprocess spawned; waiting for listen.
    bsRunning    ## Bridge serving on the assigned port.
    bsError      ## Last launch failed; see `lastError`.

  BridgeProcess* = ref object
    ## Handle returned by `launchBridge`. Owns the child process.
    backend*: PreviewBackend
    port*: int
    when not defined(js):
      process*: Process
    binary*: string

  StreamingPreviewVM* = ref object
    ## Headless ViewModel for the streaming-preview widget. The
    ## editor's preview-pane view binds to this VM: the Mode menu
    ## reads `availableBackends` + `selectedBackend`; the iframe's
    ## `src` reads `bridgeUrl`; the launching/error UI reads
    ## `status` + `lastError`. Pure signals/memos — no DOM bindings
    ## live here so the same VM drives both the JS-target preview
    ## pane and the native test harness.
    selectedBackend*: Signal[PreviewBackend]
    availableBackends*: Signal[seq[PreviewBackend]]
    status*: Signal[BridgeStatus]
    lastError*: Signal[string]
    bridgePort*: Signal[int]
    componentPath*: Signal[string]
    reloadGeneration*: Signal[int]
    bridgeUrl*: Memo[string]
    needsBridge*: Memo[bool]
    canvas*: PreviewCanvasVM
      ## RS-M11: per-canvas state holder. Mirrors the surface
      ## dimensions, the latest `element-tree` manifest, and the
      ## selected element id. The editor's `component_detail.nim`
      ## wires pointer events on the mounted `<canvas>` into this
      ## VM via `selectAt(x, y)`.
    selectedElementId*: Signal[string]
      ## Convenience proxy — `vm.canvas.selectedElementId` is the
      ## same signal, but having it on the top-level VM keeps the
      ## test assertion shape simple (`vm.selectedElementPath.val`
      ## per the spec).
    selectedElementPath*: Signal[string]
      ## Convenience proxy — see `selectedElementId`.
    publisher*: StoryPublisher
      ## RS-M12. Set by the view layer when a bridge attaches; the
      ## viewmodel layer publishes ``select-story`` /
      ## ``apply-mutation`` packets through this hook.

  StoryPublisher* = ref object
    ## RS-M12. Optional hook that the view layer wires up so editor-
    ## side code paths (viewmodels, inspector edits) can publish
    ## ``select-story`` / ``apply-mutation`` packets to the active
    ## bridge without taking a transitive dependency on
    ## `BridgeClientHandle`. The view layer registers concrete
    ## closures via `setStoryPublisher`; consumers call the publish
    ## procs below. Calls when no publisher is registered are no-ops.
    sendStoryFn*: proc(storyGroup, storyName, storyKind,
                       storyId: string) {.closure.}
    sendMutationFn*: proc(target, key, valueLiteral: string;
                          scope: MutationScopeKind) {.closure.}

  BackendBinaryRegistry* = ref object
    ## Maps `PreviewBackend` -> path of the executable that hosts
    ## the bridge for that back-end. The editor populates this via
    ## `registerBackendBinary`. For the stub backend the default is
    ## the `isonim-render-serve` binary on `$PATH` (or the
    ## sibling-repo build output when running uninstalled).
    binaries: Table[PreviewBackend, string]

const
  DefaultBridgeBinaryEnv* = "ISONIM_RENDER_SERVE_BIN"
    ## Tests/editors point this at the build of
    ## `isonim-render-serve` they want spawned (the binary the
    ## flake or `nimble build` produced).

  BridgeListenTimeoutMs* = 5000
    ## Generous upper bound; the bridge typically binds in <50ms.

  BridgeListenPollMs* = 25
    ## Poll interval while waiting for the child process to bind.

# ---------------------------------------------------------------------------
# Backend metadata + selector helpers
# ---------------------------------------------------------------------------

func backendLabel*(b: PreviewBackend): string =
  ## Human-readable name suitable for the Mode menu.
  case b
  of pbWeb: "Web"
  of pbTui: "TUI"
  of pbGpui: "GPUI"
  of pbFreya: "Freya"
  of pbCocoa: "Cocoa"
  of pbAndroid: "Android"

func backendId*(b: PreviewBackend): string =
  ## Wire identifier passed to the bridge via `--backend <id>` and
  ## echoed back in the hello M packet's `backend` field.
  case b
  of pbWeb: "web"
  of pbTui: "tui"
  of pbGpui: "gpui"
  of pbFreya: "freya"
  of pbCocoa: "cocoa"
  of pbAndroid: "android"

func backendFromId*(id: string): PreviewBackend =
  ## Inverse of `backendId`. Used by the M58 thunk-driven chip rebuild
  ## path to recover the `PreviewBackend` enum value from the
  ## `data-preview-backend` data attribute baked into each chip option.
  ## Returns `pbWeb` for unrecognised inputs (callers normally only feed
  ## values produced by `backendId` so this is a guard, not a contract).
  case id
  of "web": pbWeb
  of "tui": pbTui
  of "gpui": pbGpui
  of "freya": pbFreya
  of "cocoa": pbCocoa
  of "android": pbAndroid
  else: pbWeb

func backendNeedsRenderServe*(b: PreviewBackend): bool =
  ## True if the back-end is served by `isonim-render-serve`
  ## (i.e. not Web and not TUI, which have other transports).
  case b
  of pbWeb, pbTui: false
  of pbGpui, pbFreya, pbCocoa, pbAndroid: true

func detectAvailableBackends*(): seq[PreviewBackend] =
  ## Returns the back-ends the *current host* can serve. The Cocoa
  ## and Android adapters are partial-linux at RS-M5/M6 — the spec
  ## lists them in the menu and the bridge launcher emits a clear
  ## error if the host can't honour them, so this list includes
  ## them only when the host can actually serve them. Web + TUI are
  ## universal because they don't depend on `isonim-render-serve`.
  result = @[pbWeb, pbTui]
  when defined(linux) or defined(macosx) or defined(bsd) or
      defined(windows):
    # GPUI + Freya are Linux-real but their backend binaries can be
    # cross-compiled / shipped to macOS as well; the canonical
    # builds today are Linux. Surface them everywhere; the launcher
    # surfaces a clear "binary not found" error if the host can't
    # produce them.
    result.add pbGpui
    result.add pbFreya
  when defined(macosx):
    result.add pbCocoa
    when defined(android):
      result.add pbAndroid
  when defined(android):
    if pbAndroid notin result:
      result.add pbAndroid

proc backendIsAvailable*(vm: StreamingPreviewVM;
                        b: PreviewBackend): bool =
  b in vm.availableBackends.val

# ---------------------------------------------------------------------------
# Backend binary registry
# ---------------------------------------------------------------------------

proc newBackendBinaryRegistry*(): BackendBinaryRegistry =
  BackendBinaryRegistry(binaries: initTable[PreviewBackend, string]())

proc registerBackendBinary*(reg: BackendBinaryRegistry;
                            backend: PreviewBackend; path: string) =
  ## Editor calls this once per backend it wants to support, passing
  ## the absolute path to the executable that hosts the
  ## bridge for that back-end (the stub binary, or a per-backend
  ## demo binary from `isonim-examples`).
  reg.binaries[backend] = path

proc binaryFor*(reg: BackendBinaryRegistry;
                backend: PreviewBackend): Option[string] =
  if backend in reg.binaries:
    some(reg.binaries[backend])
  else:
    none(string)

when not defined(js):
  proc defaultStubBinary*(): string =
    ## Resolve the stub `isonim-render-serve` binary. Order:
    ##
    ##   1. `$ISONIM_RENDER_SERVE_BIN` (set by the test harness).
    ##   2. `findExe("isonim-render-serve")` on `$PATH`.
    ##   3. Empty string — caller treats as "binary not found".
    let envPath = getEnv(DefaultBridgeBinaryEnv)
    if envPath.len > 0:
      return envPath
    let path = findExe("isonim-render-serve")
    if path.len > 0:
      return path
    ""

# ---------------------------------------------------------------------------
# Port allocation + bridge launcher (native-only — `std/net`/`std/osproc`
# don't compile under the JS target)
# ---------------------------------------------------------------------------

when not defined(js):
  proc pickEphemeralPort*(): int =
    ## Bind a temporary socket to port 0; read the kernel-assigned
    ## port; close. Same pattern the `isonim-render-serve` tests use
    ## (`ws_test_client.pickPort`).
    let s = newSocket()
    s.bindAddr(Port(0))
    let p = s.getLocalAddr()[1]
    s.close()
    int(p)

  proc waitForListen(host: string; port: int;
                    timeoutMs: int): bool =
    ## Poll-connect until the bridge binds. Returns true on success.
    let deadline = epochTime() + (timeoutMs.float / 1000.0)
    while epochTime() < deadline:
      try:
        let s = newSocket()
        defer: s.close()
        s.connect(host, Port(port), timeout = BridgeListenPollMs)
        return true
      except CatchableError:
        sleep(BridgeListenPollMs)
    false

  proc launchBridge*(reg: BackendBinaryRegistry;
                    backend: PreviewBackend;
                    componentPath: string = "";
                    port: int = 0;
                    width: int = 640;
                    height: int = 480;
                    fps: int = 20;
                    staticDir: string = ""): BridgeProcess =
    ## Spawn the bridge child process for `backend`. Returns a
    ## `BridgeProcess` whose `port` field tells the editor where to
    ## point its iframe. Raises `OSError` if the binary is not
    ## registered or fails to bind.
    ##
    ## The widget calls this on Mode menu transitions to a non-Web /
    ## non-TUI backend, and again on hot-reload after the editor's
    ## recompile pipeline produces a fresh per-backend binary.
    doAssert backendNeedsRenderServe(backend),
      "launchBridge is only for native render-serve backends"
    let bin = block:
      let b = reg.binaryFor(backend)
      if b.isSome: b.get()
      else: defaultStubBinary()
    if bin.len == 0:
      raise newException(OSError,
        "no bridge binary registered for " & backendLabel(backend) &
        " and " & DefaultBridgeBinaryEnv & " / $PATH lookup failed")
    if not fileExists(bin):
      raise newException(OSError,
        "bridge binary not found: " & bin)
    let assigned = if port > 0: port else: pickEphemeralPort()
    var args = @[
      "--port", $assigned,
      "--backend", backendId(backend),
      "--width", $width,
      "--height", $height,
      "--fps", $fps]
    if staticDir.len > 0:
      args.add @["--static", staticDir]
    if componentPath.len > 0:
      # Forwarded to the per-backend adapter binary's CLI when one is
      # registered. The stub `isonim-render-serve` binary ignores
      # unknown args via `quit(... , 1)`, so we only add this flag
      # when the registered binary is not the stub.
      let stub = defaultStubBinary()
      if stub.len == 0 or bin != stub:
        args.add @["--component", componentPath]
    let p = startProcess(bin, args = args,
                        options = {poStdErrToStdOut, poUsePath})
    let ok = waitForListen("127.0.0.1", assigned, BridgeListenTimeoutMs)
    if not ok:
      p.terminate()
      discard p.waitForExit(timeout = 1000)
      raise newException(OSError,
        "bridge " & bin & " did not bind to 127.0.0.1:" & $assigned &
        " within " & $BridgeListenTimeoutMs & "ms")
    BridgeProcess(backend: backend, port: assigned, process: p,
                  binary: bin)

  proc stop*(bp: BridgeProcess) =
    ## Tear down the child process. Safe to call twice.
    if bp.process != nil and bp.process.running:
      bp.process.terminate()
      discard bp.process.waitForExit(timeout = 2000)

proc bridgeUrlFor*(port: int): string =
  ## Builds the iframe `src` the preview pane should load. The
  ## bridge serves `static/index.html` (the canvas client) at `/`
  ## and the WebSocket upgrade at the same origin.
  "http://127.0.0.1:" & $port & "/"

# ---------------------------------------------------------------------------
# ViewModel constructor
# ---------------------------------------------------------------------------

proc newStreamingPreviewVM*(initial: PreviewBackend = pbWeb;
                            available: seq[PreviewBackend] =
                              detectAvailableBackends()):
                              StreamingPreviewVM =
  ## Construct the widget's ViewModel. Must be called inside a
  ## `createRoot` so the memos own their effects.
  let selectedBackend = createSignal(initial)
  let availableBackends = createSignal(available)
  let status = createSignal(bsIdle)
  let lastError = createSignal("")
  let bridgePort = createSignal(0)
  let componentPath = createSignal("")
  let reloadGeneration = createSignal(0)

  let needsBridge = createMemo[bool](proc(): bool =
    backendNeedsRenderServe(selectedBackend.val))

  let bridgeUrl = createMemo[string](proc(): string =
    let port = bridgePort.val
    if needsBridge.val and port > 0:
      bridgeUrlFor(port)
    else:
      "")

  let canvas = newPreviewCanvasVM()

  StreamingPreviewVM(
    selectedBackend: selectedBackend,
    availableBackends: availableBackends,
    status: status,
    lastError: lastError,
    bridgePort: bridgePort,
    componentPath: componentPath,
    reloadGeneration: reloadGeneration,
    bridgeUrl: bridgeUrl,
    needsBridge: needsBridge,
    canvas: canvas,
    selectedElementId: canvas.selectedElementId,
    selectedElementPath: canvas.selectedComponentPath,
    publisher: nil)

proc setStoryPublisher*(vm: StreamingPreviewVM;
                        sendStory: proc(storyGroup, storyName,
                                        storyKind, storyId: string)
                                    {.closure.};
                        sendMutation: proc(target, key,
                                           valueLiteral: string;
                                           scope: MutationScopeKind)
                                       {.closure.}) =
  ## RS-M12: the view layer registers concrete bridge senders here
  ## once a bridge has attached; pass nil-fn arguments to clear (on
  ## detach). Idempotent — the binding installs the same closures
  ## across re-attaches so consumer call-sites can keep firing
  ## without dropping packets during reconnects.
  vm.publisher = StoryPublisher(sendStoryFn: sendStory,
                                sendMutationFn: sendMutation)

proc clearStoryPublisher*(vm: StreamingPreviewVM) =
  ## RS-M12. Call on bridge detach; subsequent publish attempts are
  ## silent no-ops.
  vm.publisher = nil

proc publishSelectStory*(vm: StreamingPreviewVM;
                          storyGroup, storyName, storyKind,
                          storyId: string) =
  ## RS-M12: fire ``select-story`` through the registered publisher.
  ## No-op when no bridge is attached.
  if vm == nil or vm.publisher == nil or vm.publisher.sendStoryFn == nil:
    return
  vm.publisher.sendStoryFn(storyGroup, storyName, storyKind, storyId)

proc publishApplyMutation*(vm: StreamingPreviewVM;
                            target, key, valueLiteral: string;
                            scope: MutationScopeKind) =
  ## RS-M12: fire ``apply-mutation`` through the registered
  ## publisher. No-op when no bridge is attached or when the active
  ## backend is Web (Web renders via iframe `srcdoc`; the wire path
  ## is non-Web only).
  if vm == nil or vm.selectedBackend.val == pbWeb: return
  if vm.publisher == nil or vm.publisher.sendMutationFn == nil:
    return
  vm.publisher.sendMutationFn(target, key, valueLiteral, scope)

proc selectBackend*(vm: StreamingPreviewVM; backend: PreviewBackend) =
  ## Mode menu wiring. Editor calls this on user click; clears any
  ## previous error state and resets `bridgePort` so the caller's
  ## launch-on-change effect re-fires.
  if backend notin vm.availableBackends.val:
    vm.lastError.val = backendLabel(backend) &
      " is not available on this host"
    vm.status.val = bsError
    return
  vm.selectedBackend.val = backend
  vm.lastError.val = ""
  vm.bridgePort.val = 0
  vm.status.val = if backendNeedsRenderServe(backend): bsLaunching
                  else: bsIdle

proc onBridgeLaunched*(vm: StreamingPreviewVM; bp: BridgeProcess) =
  ## Editor calls this after `launchBridge` returns. Wires the port
  ## back into the VM so the iframe-src memo refreshes.
  vm.bridgePort.val = bp.port
  vm.status.val = bsRunning
  vm.lastError.val = ""

proc onBridgeError*(vm: StreamingPreviewVM; message: string) =
  vm.bridgePort.val = 0
  vm.status.val = bsError
  vm.lastError.val = message

proc bumpReloadGeneration*(vm: StreamingPreviewVM) =
  ## Editor calls this when the upstream `livePreviewReloadGeneration`
  ## (or a file-watcher) fires. Anything observing
  ## `vm.reloadGeneration` re-runs.
  vm.reloadGeneration.val = vm.reloadGeneration.val + 1

# ---------------------------------------------------------------------------
# RS-M11: M-packet dispatch + canvas hit-test forwarding
# ---------------------------------------------------------------------------

proc dispatchMetaPacket*(vm: StreamingPreviewVM; jsonBody: string) =
  ## Dispatch one decoded M-packet JSON body. Today the only sub-kind
  ## the editor consumes from a launcher is `element-tree`; other
  ## sub-kinds (`hello`, `resize`, `hot-reload`, …) are handled by
  ## the existing bridge plumbing or simply ignored. Unknown sub-
  ## kinds are intentionally non-fatal per RS-M0 § "Error handling".
  if isElementTreeBody(jsonBody):
    try:
      let manifest = decodeElementTreeJson(jsonBody)
      vm.canvas.updateManifest(manifest)
    except PacketProtocolError:
      # Malformed manifest: drop it. The bridge will re-emit on the
      # next change.
      discard

proc clickCanvas*(vm: StreamingPreviewVM; x, y: int): bool =
  ## Editor's pointer handler calls this. Returns true if the click
  ## resolved to a manifest entry. The selection signals
  ## (`selectedElementId` / `selectedElementPath`) update reactively
  ## so subscribers (e.g. the sidebar selection memo) re-run on
  ## change.
  vm.canvas.selectAt(x, y)

proc hoverCanvas*(vm: StreamingPreviewVM; x, y: int): bool =
  ## M-EVP-10: Editor's mousemove handler calls this. Forwards to
  ## `PreviewCanvasVM.hoverAt`, which updates `hoveredElementId` /
  ## `hoveredComponentPath` so the overlay's hover label re-renders.
  vm.canvas.hoverAt(x, y)

# ---------------------------------------------------------------------------
# RS-M11 Pattern A: browser-side bridge client (JS target only).
# ---------------------------------------------------------------------------
#
# When the editor bundle runs in a real browser and the user selects a
# non-Web preview backend, we need to:
#   1. Open a WebSocket to the per-backend launcher's bridge port.
#   2. Decode incoming binary `F` packets and paint them on the
#      mounted `<canvas data-canvas-active="true">` element.
#   3. Decode `M` packets and route their JSON body through
#      ``dispatchMetaPacket``. The `element-tree` sub-kind feeds the
#      `PreviewCanvasVM` manifest cache; the editor's sidebar selection
#      memo reactively follows.
#   4. Forward `mousedown` / `mouseup` / `mousemove` / `click` / `wheel`
#      events from the canvas back to the launcher as `I` packets.
#
# The wire layout is the RS-M0 protocol (see
# `isonim-render-serve/static/index.html` for the reference JS).
# Per-backend launcher ports come from `playwright.config.ts` /
# `BridgePortFor`:
#
#   pbTui     → 8102
#   pbGpui    → 8103
#   pbFreya   → 8104
#   pbCocoa   → 8105
#   pbAndroid → 8106
#
# These ports are the bridge ports `isonim-examples` uses. They are
# also exposed to the playwright suite via `BRIDGE_PORTS`. The editor
# binds them through ``bridgeUrlForBackend`` so tests and runtime
# agree on a single source of truth.

func bridgePortForBackend*(backend: PreviewBackend): int =
  ## Default per-backend bridge port. Matches
  ## `isonim-examples/tests/browser/playwright.config.ts`. Web has no
  ## bridge (the editor renders Web in an iframe), so it returns 0.
  case backend
  of pbWeb: 0
  of pbTui: 8102
  of pbGpui: 8103
  of pbFreya: 8104
  of pbCocoa: 8105
  of pbAndroid: 8106

when defined(js):
  proc jsBridgeUrl(slug: cstring; fallbackPort: int): cstring {.importjs:
    """
    (function(slug, fallbackPort) {
      var scheme = 'ws';
      var host = '';
      try {
        if (window.location.protocol === 'https:') scheme = 'wss';
        host = window.location.host || '';
      } catch (_) {}
      if (!host) host = '127.0.0.1:' + fallbackPort;
      return scheme + '://' + host + '/bridge/' + slug;
    })(#, #)
    """.}

func bridgeUrlForBackend*(backend: PreviewBackend): string =
  ## WebSocket URL for ``backend``'s default bridge launcher. Empty
  ## for ``pbWeb`` (which uses the iframe path).
  ##
  ## On JS targets we use a same-origin path-based URL
  ## (``ws://<location.host>/bridge/<backend>``) so the page works
  ## when the browser is on a different machine from the editor host
  ## — ``tools/editor-server.mjs`` proxies these paths to the
  ## launcher's localhost port. On native targets (tests, headless)
  ## we keep the direct ``ws://127.0.0.1:<port>`` URL so the
  ## launcher-subprocess tests don't need a proxy in the loop.
  let port = bridgePortForBackend(backend)
  if port == 0: return ""
  when defined(js):
    let slug =
      case backend
      of pbWeb: ""
      of pbTui: "tui"
      of pbGpui: "gpui"
      of pbFreya: "freya"
      of pbCocoa: "cocoa"
      of pbAndroid: "android"
    $jsBridgeUrl(slug.cstring, port)
  else:
    "ws://127.0.0.1:" & $port & "/"

# ---------------------------------------------------------------------------
# RS-M12 — JSON body builders for `select-story` and `apply-mutation`.
# Used by the JS-side WS sender (below) and the native test harness.
# The byte shape is hand-rolled here so the editor's outbound JSON is
# deterministic (the launcher's reference round-trip test pins it).
# ---------------------------------------------------------------------------

proc jsonEscapeString(s: string): string =
  ## Minimal RFC 8259 escaper for ASCII property strings the editor
  ## emits. Mirrors the launcher-side helper in
  ## ``isonim-render-serve/src/isonim_render_serve/event_dispatch.nim``.
  result = newStringOfCap(s.len + 2)
  result.add '"'
  for ch in s:
    case ch
    of '\\': result.add "\\\\"
    of '"': result.add "\\\""
    of '\b': result.add "\\b"
    of '\f': result.add "\\f"
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

proc encodeSelectStoryBody*(storyGroup, storyName, storyKind,
                            storyId: string): string =
  ## Build the ``select-story`` JSON body. Field order locked to
  ## ``type, group, name, kind, storyId`` — see RS-M12 § *Wire
  ## protocol changes*.
  result = newStringOfCap(96 + storyId.len + storyGroup.len +
                          storyName.len + storyKind.len)
  result.add "{\"type\":\"select-story\""
  result.add ",\"group\":"
  result.add jsonEscapeString(storyGroup)
  result.add ",\"name\":"
  result.add jsonEscapeString(storyName)
  result.add ",\"kind\":"
  result.add jsonEscapeString(storyKind)
  result.add ",\"storyId\":"
  result.add jsonEscapeString(storyId)
  result.add "}"

proc encodeApplyMutationBody*(target, key, valueLiteral: string;
                              scope: MutationScopeKind): string =
  ## Build the ``apply-mutation`` JSON body. ``valueLiteral`` must
  ## be the *JSON literal* of the value (e.g. ``"true"``, ``"14"``,
  ## ``"\"solarized\""``) — the editor's inspector knows the
  ## value's primitive type at edit time and emits the matching
  ## literal so the launcher can decode it as the right JSON node
  ## without a separate type tag. Field order locked to ``type,
  ## target, key, value, scope``.
  result = newStringOfCap(96 + target.len + key.len + valueLiteral.len)
  result.add "{\"type\":\"apply-mutation\""
  result.add ",\"target\":"
  result.add jsonEscapeString(target)
  result.add ",\"key\":"
  result.add jsonEscapeString(key)
  result.add ",\"value\":"
  result.add valueLiteral
  result.add ",\"scope\":"
  result.add jsonEscapeString(mutationScopeWire(scope))
  result.add "}"

proc valueLiteralForString*(s: string): string =
  ## Convenience for callers that have a raw string value to inject
  ## as a JSON string literal in the ``apply-mutation`` body.
  jsonEscapeString(s)

func storyKindWire*(kind: StoryKind): string =
  ## Wire identifier for ``select-story.kind``. Mirrors the editor
  ## enum but ships as a flat string so the launcher can dispatch
  ## without importing the editor types.
  case kind
  of skFoundation: "skFoundation"
  of skComponent: "skComponent"
  of skPattern: "skPattern"
  of skPage: "skPage"
  of skFlow: "skFlow"
  of skGuideline: "skGuideline"
  of skVectorSymbol: "skVectorSymbol"

proc storyIdFor*(story: StoryRef): string =
  ## Canonical ``"<group> / <name>"`` identifier the editor sends to
  ## the launcher. Mirrors the format the launcher's story-id
  ## taxonomy modules (``task_app/core/story_ids.nim`` /
  ## ``settings_app/core/story_ids.nim``) declare.
  story.group & " / " & story.name

when defined(js):
  type BridgeClientHandle* = ref object
    ## Opaque handle stored on `StreamingPreviewVM` while a bridge
    ## client is attached. Holds the live `WebSocket` JS object plus
    ## the canvas element so ``detachBridgeClient`` can close cleanly.
    socket*: JsObject
    canvas*: Element
    url*: string

  proc attachBridgeClient*(vm: StreamingPreviewVM; canvas: Element;
                          bridgeUrl: string;
                          onVectorSymbolDblClick: proc(componentPath: string)
                              = nil;
                          onWsOpen: proc() = nil): BridgeClientHandle =
    ## Open a WebSocket from the editor bundle to ``bridgeUrl`` and
    ## wire its F/M/I packet stream into ``vm`` + ``canvas``.
    ##
    ## The implementation is a thin Nim wrapper around an `{.emit.}`
    ## JS block — same wire decoding as
    ## `isonim-render-serve/static/index.html`. The reason we don't
    ## use individual `importjs` procs for every step is that the WS
    ## listeners need to close over the VM dispatch callbacks via a
    ## tiny shim object, and an inline emit keeps the byte-level
    ## decoding tracing the reference one-to-one.
    ##
    ## ``onVectorSymbolDblClick`` is the M-EVP-11 hook: when the user
    ## double-clicks a manifest entry whose ``kind == "vector-symbol"``,
    ## the JS shim resolves the hit through ``PreviewCanvasVM.elementAt``
    ## and invokes the callback with the matching ``componentPath``.
    ## The callback walks the editor's sidebar for the seeded
    ## ``skVectorSymbol`` story and calls ``openVectorEditor`` — that
    ## bridge runs in the editor's view layer (``component_detail.nim``)
    ## because ``streaming_preview`` cannot import ``viewmodels``
    ## without creating a circular dependency.
    var socket: JsObject
    let dispatchMeta = proc(body: cstring) =
      vm.dispatchMetaPacket($body)
    let onClick = proc(x: int; y: int) =
      discard vm.clickCanvas(x, y)
      when defined(js):
        # Test-only side channel: mirror the resolved component path to
        # window so the playwright Pattern-A spec can assert the
        # editor's sidebar selection followed the click. Gated on
        # `__isonimTestMode === true` so production builds never write.
        let path = vm.canvas.selectedComponentPath.val
        let id = vm.canvas.selectedElementId.val
        let bOpt = vm.canvas.boundsOf(id)
        # Surface the selected element's bounds (in F-packet pixel
        # space) so the overlay can sanity-check its CSS-space
        # transform and the playwright suite can assert outline
        # positioning. `__isonimSelectedBounds` is null when no
        # selection is active, an `{x,y,w,h}` object otherwise.
        var boundsX = 0
        var boundsY = 0
        var boundsW = 0
        var boundsH = 0
        var haveBounds = false
        if bOpt.isSome:
          let b = bOpt.get
          boundsX = b.x
          boundsY = b.y
          boundsW = b.w
          boundsH = b.h
          haveBounds = true
        let haveBoundsFlag = if haveBounds: 1 else: 0
        {.emit: ["""
          try {
            if (window.__isonimTestMode === true) {
              window.__isonimSelectedComponentPath = """, path.cstring, """;
              window.__isonimSelectedElementId = """, id.cstring, """;
              if (""", haveBoundsFlag, """) {
                window.__isonimSelectedBounds = {
                  x: """, boundsX, """,
                  y: """, boundsY, """,
                  w: """, boundsW, """,
                  h: """, boundsH, """
                };
              } else {
                window.__isonimSelectedBounds = null;
              }
            }
          } catch (_) {}
        """].}
    let onHover = proc(x: int; y: int) =
      discard vm.hoverCanvas(x, y)
      when defined(js):
        # Test-only side channel: mirror the hover signals to window
        # so the playwright M-EVP-10 spec can assert hover labels
        # follow the cursor. Same `__isonimTestMode === true` gate as
        # the click-side channel above — production never writes.
        let pOpt = vm.canvas.hoveredComponentPath.val
        let iOpt = vm.canvas.hoveredElementId.val
        let hovered = if pOpt.isSome: pOpt.get else: ""
        let hoveredId = if iOpt.isSome: iOpt.get else: ""
        let hasHoverFlag = if pOpt.isSome: 1 else: 0
        {.emit: ["""
          try {
            if (window.__isonimTestMode === true) {
              if (""", hasHoverFlag, """) {
                window.__isonimHoveredComponentPath = """, hovered.cstring, """;
                window.__isonimHoveredElementId = """, hoveredId.cstring, """;
              } else {
                window.__isonimHoveredComponentPath = null;
                window.__isonimHoveredElementId = null;
              }
            }
          } catch (_) {}
        """].}
    let onDblClick = proc(x: int; y: int) =
      ## M-EVP-11: hit-test the manifest at the dblclick coordinate.
      ## When the resolved entry's ``kind == "vector-symbol"``, fire
      ## the editor's vector-editor open path through the supplied
      ## callback. Non-vector-symbol entries are intentional no-ops —
      ## the Pattern A click → selection invariant must NOT regress.
      let hit = vm.canvas.elementAt(x, y)
      if hit.isNone:
        return
      let entry = hit.get
      if entry.kind != "vector-symbol":
        return
      if onVectorSymbolDblClick != nil:
        onVectorSymbolDblClick(entry.componentPath)
    {.emit: ["""
      (function (canvas, url, dispatchMeta, onClick, onHover, onDblClick, onWsOpen) {
        if (!canvas || !url) return null;
        var ws = new WebSocket(url);
        ws.binaryType = 'arraybuffer';
        // RS-M12: fire the onWsOpen Nim callback once the socket
        // reaches OPEN state so the editor can flush queued sends
        // (e.g. the initial `select-story` packet) without polling.
        ws.addEventListener('open', function () {
          try { if (onWsOpen) onWsOpen(); } catch (_) {}
        });
        function readU32LE(view, offset) {
          return view.getUint32(offset, true);
        }
        function ensureSize(width, height) {
          if (canvas.width !== width || canvas.height !== height) {
            canvas.width = width;
            canvas.height = height;
          }
        }
        function handleF(bytes) {
          var view = new DataView(bytes.buffer, bytes.byteOffset, bytes.byteLength);
          var flags = bytes[1];
          if ((flags & 0xFC) !== 0) { ws.close(1002, 'reserved flag bits set'); return; }
          var isDiff = (flags & 0x01) !== 0;
          var isVideo = (flags & 0x02) !== 0;
          if (isVideo) { ws.close(1002, 'video bit set at protocolVersion=1'); return; }
          var width = readU32LE(view, 2);
          var height = readU32LE(view, 6);
          var length = readU32LE(view, 10);
          var payload = bytes.subarray(14, 14 + length);
          ensureSize(width, height);
          var ctx = canvas.getContext('2d');
          if (!ctx) return;
          if (!isDiff) {
            if (payload.length !== width * height * 4) {
              ws.close(1002, 'full frame length mismatch'); return;
            }
            var img = new ImageData(new Uint8ClampedArray(payload), width, height);
            ctx.putImageData(img, 0, 0);
          } else {
            var count = new DataView(payload.buffer, payload.byteOffset).getUint32(0, true);
            var off = 4;
            for (var i = 0; i < count; i++) {
              var rv = new DataView(payload.buffer, payload.byteOffset + off);
              var rx = rv.getUint32(0, true);
              var ry = rv.getUint32(4, true);
              var rw = rv.getUint32(8, true);
              var rh = rv.getUint32(12, true);
              var rlen = rv.getUint32(16, true);
              off += 20;
              var rectBytes = payload.subarray(off, off + rlen);
              off += rlen;
              var rimg = new ImageData(new Uint8ClampedArray(rectBytes), rw, rh);
              ctx.putImageData(rimg, rx, ry);
            }
          }
        }
        function handleM(bytes) {
          var view = new DataView(bytes.buffer, bytes.byteOffset, bytes.byteLength);
          var length = readU32LE(view, 1);
          var json = new TextDecoder('utf-8').decode(bytes.subarray(5, 5 + length));
          var node;
          try { node = JSON.parse(json); } catch (_) { return; }
          if (node) {
            if (node.type === 'hello' && node.initialSize) {
              ensureSize(node.initialSize.width, node.initialSize.height);
            } else if (node.type === 'resize') {
              ensureSize(node.width, node.height);
            } else if (node.type === 'hot-reload') {
              var ctx = canvas.getContext('2d');
              if (ctx) ctx.clearRect(0, 0, canvas.width, canvas.height);
            }
          }
          dispatchMeta(json);
          // Test-only instrumentation. Production builds leave
          // `window.__isonimTestMode` unset (or set to anything other
          // than `true`); the strict `=== true` guard keeps this side
          // channel firmly out of production page lifetimes. The
          // playwright suite flips the flag on via addInitScript and
          // mirrors the latest element-tree manifest onto window.
          try {
            if (window.__isonimTestMode === true && node && node.type === 'element-tree') {
              window.__isonimManifest = node;
              if (!Array.isArray(window.__isonimManifests)) {
                window.__isonimManifests = [];
              }
              window.__isonimManifests.push(node);
            }
          } catch (_) {}
        }
        function encodeI(jsonStr) {
          var enc = new TextEncoder();
          var body = enc.encode(jsonStr);
          var buf = new Uint8Array(5 + body.length);
          buf[0] = 0x49;
          var n = body.length;
          buf[1] = n & 0xFF;
          buf[2] = (n >>> 8) & 0xFF;
          buf[3] = (n >>> 16) & 0xFF;
          buf[4] = (n >>> 24) & 0xFF;
          buf.set(body, 5);
          return buf;
        }
        function sendInput(obj) {
          if (ws.readyState !== WebSocket.OPEN) return;
          try { ws.send(encodeI(JSON.stringify(obj))); } catch (_) {}
        }
        function modsFromEvent(e) {
          return { ctrl: !!e.ctrlKey, shift: !!e.shiftKey,
                   alt: !!e.altKey, meta: !!e.metaKey };
        }
        function pointFromEvent(e) {
          var rect = canvas.getBoundingClientRect();
          var x = Math.round((e.clientX - rect.left) * (canvas.width / rect.width));
          var y = Math.round((e.clientY - rect.top) * (canvas.height / rect.height));
          return { x: x, y: y };
        }
        ws.addEventListener('message', function (e) {
          if (!(e.data instanceof ArrayBuffer)) return;
          var bytes = new Uint8Array(e.data);
          if (bytes.length === 0) return;
          var kind = String.fromCharCode(bytes[0]);
          if (kind === 'F') { handleF(bytes); }
          else if (kind === 'M') { handleM(bytes); }
        });
        function onMouseDown(e) {
          var p = pointFromEvent(e);
          sendInput({ type: 'mouse', action: 'down', button: e.button,
                      x: p.x, y: p.y, modifiers: modsFromEvent(e) });
        }
        function onMouseUp(e) {
          var p = pointFromEvent(e);
          sendInput({ type: 'mouse', action: 'up', button: e.button,
                      x: p.x, y: p.y, modifiers: modsFromEvent(e) });
        }
        function onMouseMove(e) {
          var p = pointFromEvent(e);
          sendInput({ type: 'mouse', action: 'move', button: -1,
                      x: p.x, y: p.y, modifiers: modsFromEvent(e) });
          // M-EVP-10: drive the editor's hover hit-test on every
          // mousemove. The Nim side updates the hover signals and the
          // overlay re-renders. Also publishes the latest pointer
          // CSS coords on the canvas DOM node so the overlay's hover
          // label can anchor near the cursor without subscribing to
          // pointer events itself.
          try {
            canvas.__isonimPointerCss = {
              clientX: e.clientX,
              clientY: e.clientY,
            };
          } catch (_) {}
          onHover(p.x, p.y);
        }
        function onMouseLeave() {
          // Clear hover state when the pointer leaves the canvas so
          // the overlay's hover label vanishes.
          try { canvas.__isonimPointerCss = null; } catch (_) {}
          onHover(-1, -1);
        }
        function onClickEvt(e) {
          var p = pointFromEvent(e);
          sendInput({ type: 'mouse', action: 'click', button: e.button,
                      x: p.x, y: p.y, modifiers: modsFromEvent(e) });
          onClick(p.x, p.y);
        }
        // M-EVP-11: dblclick path. The Nim closure first hit-tests the
        // manifest and only invokes the editor's openVectorEditor when
        // the resolved entry's kind === 'vector-symbol'. Non-vector
        // dblclicks are deliberate no-ops so the Pattern A
        // click → selection invariant is not perturbed.
        function onDblClickEvt(e) {
          var p = pointFromEvent(e);
          sendInput({ type: 'mouse', action: 'dblclick', button: e.button,
                      x: p.x, y: p.y, modifiers: modsFromEvent(e) });
          onDblClick(p.x, p.y);
        }
        function onWheel(e) {
          var p = pointFromEvent(e);
          sendInput({ type: 'scroll', x: p.x, y: p.y,
                      deltaX: e.deltaX, deltaY: e.deltaY,
                      modifiers: modsFromEvent(e) });
        }
        canvas.addEventListener('mousedown', onMouseDown);
        canvas.addEventListener('mouseup', onMouseUp);
        canvas.addEventListener('mousemove', onMouseMove);
        canvas.addEventListener('mouseleave', onMouseLeave);
        canvas.addEventListener('click', onClickEvt);
        canvas.addEventListener('dblclick', onDblClickEvt);
        canvas.addEventListener('wheel', onWheel);
        ws.__isonimHandlers = {
          mousedown: onMouseDown, mouseup: onMouseUp,
          mousemove: onMouseMove, mouseleave: onMouseLeave,
          click: onClickEvt, dblclick: onDblClickEvt, wheel: onWheel,
        };
        ws.__isonimCanvas = canvas;
        """, socket, """ = ws;
      })(""", canvas, ", ", bridgeUrl.cstring, ", ",
       dispatchMeta, ", ", onClick, ", ", onHover, ", ", onDblClick,
       ", ", onWsOpen, """);
    """].}
    BridgeClientHandle(socket: socket, canvas: canvas, url: bridgeUrl)

  proc sendSelectStory*(handle: BridgeClientHandle;
                        storyGroup, storyName, storyKind,
                        storyId: string) =
    ## RS-M12: send a ``select-story`` I packet over the bridge's
    ## WebSocket. The launcher's `StoryDispatchSink` decodes it and
    ## reconfigures the live VM. No-op when the socket isn't open
    ## yet — callers re-fire on bridge reconnect via the editor's
    ## attach lifecycle.
    if handle == nil: return
    var sock = handle.socket
    let body = encodeSelectStoryBody(storyGroup, storyName, storyKind,
                                     storyId)
    {.emit: ["""
      (function (ws, jsonStr) {
        if (!ws || ws.readyState !== WebSocket.OPEN) return;
        try {
          var enc = new TextEncoder();
          var bodyBytes = enc.encode(jsonStr);
          var buf = new Uint8Array(5 + bodyBytes.length);
          buf[0] = 0x49; // 'I'
          var n = bodyBytes.length;
          buf[1] = n & 0xFF;
          buf[2] = (n >>> 8) & 0xFF;
          buf[3] = (n >>> 16) & 0xFF;
          buf[4] = (n >>> 24) & 0xFF;
          buf.set(bodyBytes, 5);
          ws.send(buf);
        } catch (_) {}
      })(""", sock, ", ", body.cstring, ");"].}

  proc sendApplyMutation*(handle: BridgeClientHandle;
                          target, key, valueLiteral: string;
                          scope: MutationScopeKind) =
    ## RS-M12: send an ``apply-mutation`` I packet. ``valueLiteral``
    ## is the JSON literal of the value (see
    ## ``encodeApplyMutationBody`` for the contract). No-op when the
    ## socket isn't open.
    if handle == nil: return
    var sock = handle.socket
    let body = encodeApplyMutationBody(target, key, valueLiteral, scope)
    {.emit: ["""
      (function (ws, jsonStr) {
        if (!ws || ws.readyState !== WebSocket.OPEN) return;
        try {
          var enc = new TextEncoder();
          var bodyBytes = enc.encode(jsonStr);
          var buf = new Uint8Array(5 + bodyBytes.length);
          buf[0] = 0x49; // 'I'
          var n = bodyBytes.length;
          buf[1] = n & 0xFF;
          buf[2] = (n >>> 8) & 0xFF;
          buf[3] = (n >>> 16) & 0xFF;
          buf[4] = (n >>> 24) & 0xFF;
          buf.set(bodyBytes, 5);
          ws.send(buf);
        } catch (_) {}
      })(""", sock, ", ", body.cstring, ");"].}

  proc isBridgeOpen*(handle: BridgeClientHandle): bool =
    ## Probe whether the bridge socket is OPEN — used by reactive
    ## senders to delay the initial select-story until the WS
    ## handshake completes.
    if handle == nil or handle.socket == nil: return false
    var sock = handle.socket
    var ready = 0
    {.emit: ["""
      try { """, ready, """ = """, sock, """.readyState; } catch (_) {}
    """].}
    ready == 1  # WebSocket.OPEN

  proc detachBridgeClient*(handle: BridgeClientHandle) =
    ## Close the WebSocket and unbind the canvas mouse listeners. Safe
    ## to call when the handle is nil — the editor calls this on
    ## backend switches even when no bridge was attached.
    if handle == nil: return
    var sock = handle.socket
    let canvas = handle.canvas
    {.emit: ["""
      (function (ws, canvas) {
        if (!ws) return;
        try {
          if (ws.__isonimHandlers && canvas) {
            for (var k in ws.__isonimHandlers) {
              canvas.removeEventListener(k, ws.__isonimHandlers[k]);
            }
            ws.__isonimHandlers = null;
          }
        } catch (_) {}
        try { ws.close(); } catch (_) {}
      })(""", sock, ", ", canvas, ");"].}
    handle.socket = nil
    handle.canvas = nil
