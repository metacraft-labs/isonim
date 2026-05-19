## REV-M5 (follow-up) — real backend-launcher orchestration for the
## design-review capture pipeline.
##
## Until this module landed, ``capture.nim`` talked to a single fixed
## ``bridgeUrl`` — fine for the fake-bridge unit tests but unable to
## exercise the production code path where each capture spawns a real
## per-backend demo binary from ``isonim-examples`` (one per backend
## in the brief's ``coversPreviews[*].backends`` list).
##
## This module owns the launcher side of that integration:
##
##   1. *Binary lookup.* Resolves the per-backend executable from
##      either an explicit override directory, ``$ISONIM_REVIEW_BACKEND_BIN_DIR``,
##      ``~/.isonim/backends/``, or the sibling
##      ``<workspace>/isonim-examples/build/backends/`` tree.
##
##   2. *Port allocation.* Picks a free TCP port from the
##      ``8200..8299`` range — high enough not to collide with the
##      editor's 8090, the daemon's 8113, or the dev PG cluster's 5533;
##      narrow enough that an operator can grep ``netstat`` without
##      noise.
##
##   3. *Spawn.* Launches ``isonim-examples-<backend> --port <N>
##      --backend <id> --demo <task|settings>`` as a detached
##      subprocess; the launcher pattern matches what
##      ``editor/backends/common.nim`` already accepts (see EX-M14).
##
##   4. *Readiness probe.* Polls a loopback TCP connect against the
##      chosen port (the same "wait until the kernel binds" trick
##      ``streaming_preview.waitForListen`` uses) and times out after
##      ``timeoutMs`` (default 30 s).
##
##   5. *Shutdown.* SIGTERM, wait up to 5 s, SIGKILL fallback.  The
##      capture orchestrator calls this from a ``defer:`` so a panicking
##      capture still tears the launcher down.
##
## The orchestrator (``capture.nim``) spawns *one launcher per
## (preview, backend, viewport) tuple* and tears it down before moving
## to the next.  Sharing a launcher across backends would conflate
## process identity with backend identity — each ``isonim-examples-<X>``
## binary advertises itself as a single backend, so the cost of a
## fresh spawn per capture is the price of preserving that invariant.

import std/[net, os, osproc, times]

import isonim/editor/types
import ./brief_format

type
  LauncherSpawnError* = object of CatchableError
    ## Raised when the requested binary cannot be found or fails
    ## to bind to its assigned port within the timeout budget.

  LauncherSpec* = object
    backend*: PreviewBackend
    binaryPath*: string
      ## Absolute path to the ``isonim-examples-<backend>`` binary.
    component*: string
      ## ``"task"``, ``"settings"``, or any other value forwarded as
      ## ``--demo``.  Empty string means "don't pass ``--demo``"; the
      ## launcher's own default (``task``) wins.
    width*: int
      ## Optional starting viewport width — forwarded to the launcher
      ## via ``--width``.  0 means "let the launcher pick its default".
    height*: int

  BackendLauncher* = ref object
    backend*: PreviewBackend
    process*: Process
    bridgeUrl*: string
      ## ``ws://127.0.0.1:<port>`` once the launcher's WebSocket
      ## server is accepting connections.
    pgPort*: int
      ## Confusingly named (legacy spec wording).  This is the TCP port
      ## the *bridge* bound to, not the Postgres port.  Kept as
      ## ``pgPort`` for parity with the spec's API surface.
    binaryPath*: string
    stopped: bool

const
  LauncherPortRangeStart* = 8200
  LauncherPortRangeEnd*   = 8299
    ## Tight range so dev-shell users can `lsof -iTCP:8200-8299` and
    ## know exactly what they're seeing.  Clashes with the editor
    ## (8090) / daemon (8113) / PG (5533) are impossible by
    ## construction.

  LauncherPollMs* = 25
  LauncherTermWaitMs* = 5_000

# ---------------------------------------------------------------------------
# Binary lookup
# ---------------------------------------------------------------------------

proc backendBinaryName*(backend: PreviewBackend): string =
  ## Filename of the per-backend launcher binary as shipped by
  ## ``isonim-examples`` under ``build/backends/``.  Matches the
  ## convention documented in ``isonim-examples/CLAUDE.md``.
  case backend
  of pbWeb:     "isonim-examples-web"
  of pbTui:     "isonim-examples-tui"
  of pbGpui:    "isonim-examples-gpui"
  of pbFreya:   "isonim-examples-freya"
  of pbCocoa:   "isonim-examples-cocoa"
  of pbAndroid: "isonim-examples-android"
  of pbIos:     "isonim-examples-ios"

proc backendIdFor*(backend: PreviewBackend): string =
  ## Wire identifier passed to the launcher via ``--backend <id>``.
  ## Matches ``streaming_preview.backendId``; duplicated here so this
  ## module doesn't pull in the entire streaming-preview surface.
  case backend
  of pbWeb:     "web"
  of pbTui:     "tui"
  of pbGpui:    "gpui"
  of pbFreya:   "freya"
  of pbCocoa:   "cocoa"
  of pbAndroid: "android"
  of pbIos:     "ios"

proc resolveBackendBinary*(backend: PreviewBackend;
                           overrideDir: string = "";
                           workspaceRoot: string = ""): string =
  ## Walk the documented search order and return the first existing
  ## absolute path; empty string on miss.  Search order:
  ##
  ##   1. Explicit ``overrideDir`` (the ``--backend-binary-dir`` CLI
  ##      flag).
  ##   2. ``$ISONIM_REVIEW_BACKEND_BIN_DIR``.
  ##   3. ``~/.isonim/backends/``.
  ##   4. ``<workspaceRoot>/isonim-examples/build/backends/``.
  ##
  ## We deliberately do *not* fall back to ``findExe`` on ``$PATH``:
  ## the launcher binaries are not normally installed onto ``$PATH``,
  ## and a stale ``isonim-examples-<X>`` from a previous nix profile
  ## entry could shadow the one the user just rebuilt.  Explicit > PATH.
  let name = backendBinaryName(backend)
  var candidates: seq[string] = @[]
  if overrideDir.len > 0:
    candidates.add(overrideDir / name)
  let envDir = getEnv("ISONIM_REVIEW_BACKEND_BIN_DIR")
  if envDir.len > 0:
    candidates.add(envDir / name)
  candidates.add(getHomeDir() / ".isonim" / "backends" / name)
  if workspaceRoot.len > 0:
    candidates.add(workspaceRoot / "isonim-examples" / "build" /
                   "backends" / name)
  for c in candidates:
    if fileExists(c):
      return c
  ""

# ---------------------------------------------------------------------------
# Port allocation
# ---------------------------------------------------------------------------

proc isPortFree(port: int): bool =
  ## True if we can bind a fresh listener to ``127.0.0.1:port``.  The
  ## socket is closed before we return, so a launcher spawned the
  ## millisecond after this returns can claim the port.  Yes, a TOCTOU
  ## race; in practice the 100-port range and per-test-process scope
  ## make collisions vanishingly unlikely.
  let s = newSocket()
  defer: s.close()
  try:
    s.setSockOpt(OptReuseAddr, false)
    s.bindAddr(Port(port), "127.0.0.1")
    s.listen()
    return true
  except OSError, IOError:
    return false

proc pickLauncherPort*(): int =
  ## Pick a free TCP port in the ``LauncherPortRangeStart``..
  ## ``LauncherPortRangeEnd`` range.  Raises ``LauncherSpawnError``
  ## when every port in the range is occupied (a strong signal that
  ## either tests are leaking processes or the dev box is under
  ## unusual load).
  for p in LauncherPortRangeStart .. LauncherPortRangeEnd:
    if isPortFree(p):
      return p
  raise newException(LauncherSpawnError,
    "pickLauncherPort: no free TCP port in " &
    $LauncherPortRangeStart & ".." & $LauncherPortRangeEnd)

# ---------------------------------------------------------------------------
# Readiness probe
# ---------------------------------------------------------------------------

proc waitForReady(host: string; port: int;
                  timeoutMs: int): bool =
  ## Poll-connect until the launcher binds.  Returns true on success.
  let deadline = epochTime() + (timeoutMs.float / 1000.0)
  while epochTime() < deadline:
    block tryConnect:
      let s = newSocket()
      try:
        s.connect(host, Port(port), timeout = LauncherPollMs)
        s.close()
        return true
      except CatchableError:
        try: s.close() except CatchableError: discard
        break tryConnect
    sleep(LauncherPollMs)
  false

# ---------------------------------------------------------------------------
# Launch + shutdown
# ---------------------------------------------------------------------------

proc launchBackend*(spec: LauncherSpec;
                    timeoutMs: int = 30_000): BackendLauncher =
  ## Spawn the per-backend launcher binary; block until it accepts a
  ## loopback TCP connection on the picked port; return the handle.
  ##
  ## Raises ``LauncherSpawnError`` when:
  ##   - ``spec.binaryPath`` is empty / not a real file,
  ##   - port allocation fails,
  ##   - ``startProcess`` itself fails (OSError surfaced through),
  ##   - the launcher does not bind within ``timeoutMs``.
  if spec.binaryPath.len == 0:
    raise newException(LauncherSpawnError,
      "launchBackend: no binary path provided for backend " &
      previewBackendToString(spec.backend))
  if not fileExists(spec.binaryPath):
    raise newException(LauncherSpawnError,
      "launchBackend: binary not found: " & spec.binaryPath)

  let port = pickLauncherPort()

  var args = @[
    "--port", $port,
    "--backend", backendIdFor(spec.backend)]
  if spec.component.len > 0:
    args.add @["--demo", spec.component]
  if spec.width > 0:
    args.add @["--width", $spec.width]
  if spec.height > 0:
    args.add @["--height", $spec.height]

  let process =
    try:
      startProcess(spec.binaryPath, args = args,
                   options = {poStdErrToStdOut, poUsePath})
    except OSError as e:
      raise newException(LauncherSpawnError,
        "launchBackend: startProcess failed for " & spec.binaryPath &
        ": " & e.msg)

  let ok = waitForReady("127.0.0.1", port, timeoutMs)
  if not ok:
    # Tear the child down — leaving it parked on a port we're about
    # to abandon would just rot.
    try: process.terminate() except CatchableError: discard
    try: discard process.waitForExit(timeout = 1000)
    except CatchableError: discard
    try: process.close() except CatchableError: discard
    raise newException(LauncherSpawnError,
      "launchBackend: " & spec.binaryPath &
      " did not bind to 127.0.0.1:" & $port &
      " within " & $timeoutMs & "ms")

  BackendLauncher(
    backend: spec.backend,
    process: process,
    bridgeUrl: "ws://127.0.0.1:" & $port,
    pgPort: port,
    binaryPath: spec.binaryPath,
    stopped: false)

proc shutdown*(l: BackendLauncher) =
  ## SIGTERM, wait up to 5 s, SIGKILL fallback.  Idempotent: safe to
  ## call twice; second call is a no-op.
  if l == nil or l.stopped or l.process == nil:
    if l != nil: l.stopped = true
    return
  l.stopped = true
  try:
    if l.process.running:
      l.process.terminate()
      discard l.process.waitForExit(timeout = LauncherTermWaitMs)
      if l.process.running:
        l.process.kill()
        discard l.process.waitForExit(timeout = 1000)
  except CatchableError:
    discard
  try: l.process.close() except CatchableError: discard
