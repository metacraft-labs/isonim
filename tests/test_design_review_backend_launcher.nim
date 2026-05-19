## REV-M5 (follow-up) — unit tests for the per-backend launcher
## orchestrator under
## ``isonim/editor/design_review/backend_launcher.nim``.
##
## These tests drive the real ``isonim-examples-web`` binary from the
## sibling repo's ``build/backends/`` tree.  The launcher is the
## smallest of the seven backends (no GPU, no device, no emulator), so
## using it as the launcher-under-test keeps these tests reliable in
## CI without pulling extra deps.

import std/[os, osproc, strutils, times, unittest]

import isonim/editor/design_review/backend_launcher
import isonim/editor/design_review/brief_format

const RepoRootHere = currentSourcePath().parentDir().parentDir()
const ExamplesRoot = RepoRootHere.parentDir() / "isonim-examples"
const WebLauncherBin =
  ExamplesRoot / "build" / "backends" / "isonim-examples-web"

proc shouldHaveLauncher() =
  if not fileExists(WebLauncherBin):
    raise newException(IOError,
      "test_design_review_backend_launcher: " & WebLauncherBin &
      " not found.  Build it via " &
      "`direnv exec ~/metacraft/isonim-examples just build-backends`.")

suite "REV-M5 follow-up: backend_launcher":

  setup:
    shouldHaveLauncher()

  test "test_launch_web_binary_succeeds":
    let spec = LauncherSpec(
      backend: pbWeb,
      binaryPath: WebLauncherBin,
      component: "task")
    let l = launchBackend(spec, timeoutMs = 20_000)
    check l != nil
    check l.bridgeUrl.startsWith("ws://127.0.0.1:")
    check l.pgPort >= LauncherPortRangeStart
    check l.pgPort <= LauncherPortRangeEnd
    check l.binaryPath == WebLauncherBin
    check l.process != nil
    check running(l.process)
    l.shutdown()
    check not running(l.process)

  test "test_launch_unknown_binary_returns_error":
    let spec = LauncherSpec(
      backend: pbWeb,
      binaryPath: "/nonexistent/path/isonim-examples-web",
      component: "task")
    expect LauncherSpawnError:
      discard launchBackend(spec, timeoutMs = 500)

    # Empty path is also an error — the launcher must not pretend a
    # missing override is OK; let the caller decide whether to skip.
    let emptySpec = LauncherSpec(
      backend: pbWeb,
      binaryPath: "",
      component: "task")
    expect LauncherSpawnError:
      discard launchBackend(emptySpec, timeoutMs = 500)

  test "test_shutdown_idempotent":
    let spec = LauncherSpec(
      backend: pbWeb,
      binaryPath: WebLauncherBin,
      component: "task")
    let l = launchBackend(spec, timeoutMs = 20_000)
    check running(l.process)
    l.shutdown()
    check not running(l.process)
    # Second call must not crash, must not hang.
    let t0 = epochTime()
    l.shutdown()
    let elapsed = epochTime() - t0
    check elapsed < 1.0   # generous; second call should be near-instant

  test "test_port_allocation_avoids_collisions":
    # Three launchers held concurrently must each have a distinct
    # port within the documented range.  Verifies the ``pickLauncherPort``
    # bind-and-release pattern doesn't hand out the same port to back-
    # to-back callers.
    let spec = LauncherSpec(
      backend: pbWeb,
      binaryPath: WebLauncherBin,
      component: "task")
    let a = launchBackend(spec, timeoutMs = 20_000)
    let b = launchBackend(spec, timeoutMs = 20_000)
    let c = launchBackend(spec, timeoutMs = 20_000)
    try:
      check a.pgPort != b.pgPort
      check b.pgPort != c.pgPort
      check a.pgPort != c.pgPort
      for p in [a.pgPort, b.pgPort, c.pgPort]:
        check p >= LauncherPortRangeStart
        check p <= LauncherPortRangeEnd
    finally:
      a.shutdown()
      b.shutdown()
      c.shutdown()

  test "test_resolve_backend_binary_honours_override_dir":
    # The override-dir search wins over env / home / workspace.
    let dir = ExamplesRoot / "build" / "backends"
    let resolved = resolveBackendBinary(pbWeb, overrideDir = dir)
    check resolved == WebLauncherBin
    # Unknown override returns "" — the orchestrator's "skip with
    # warning" path depends on this.
    let missing = resolveBackendBinary(pbWeb,
                                       overrideDir = "/tmp/nope-nope")
    check missing == ""

  test "test_resolve_backend_binary_uses_workspace_fallback":
    # When no overrides are supplied, the ``<ws>/isonim-examples/build/
    # backends/`` fallback wins.
    let ws = RepoRootHere.parentDir()   # the metacraft workspace root
    let resolved = resolveBackendBinary(pbWeb, workspaceRoot = ws)
    check resolved == WebLauncherBin
