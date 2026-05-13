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
    selectedElementPath: canvas.selectedComponentPath)

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
