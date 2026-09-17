## NH-M2 — the ``-d:isonimHmr``-OFF half of the contract.
##
## MOCK POLICY: no mocks. This file deliberately cannot import the HCR
## stub: without ``-d:isonimHmr`` there is no agent seam to install into,
## and ``tests/helpers/hcr_stub.nim`` refuses to compile in that
## configuration with a message saying so. That refusal is the point —
## the flag-off build must have no HMR machinery at all, not a dormant
## copy of it.
##
## WHY THIS FILE EXISTS. ``test_native_hmr.nim`` is compiled with the flag
## and would never notice if the fallback branch of
## ``isonim/native/hmr.nim`` rotted, or if it quietly gained reactive
## behaviour a production binary must not have. The two properties
## asserted here are:
##
## 1. **It compiles and runs at all.** An app written against
##    ``mountUiHot`` / ``hmrSignal`` / ``HmrRoot`` builds unchanged with
##    the flag off. If the fallback drops a proc or changes a signature,
##    this file fails to compile and the failure is loud.
## 2. **It is build-once, exactly like a non-HMR launcher.** The fallback
##    ``mountUiHot`` wraps the accessor in ``staticNativeRoot``, which is
##    what NH-M1 measured as the only safe shape against a real
##    composition root. A signal write must NOT re-run the mount.
##
## NO SKIP ARMS.

when defined(isonimHmr):
  {.error: "test_native_hmr_inactive asserts the -d:isonimHmr-OFF " &
      "behaviour of isonim/native/hmr and must be compiled WITHOUT the " &
      "flag. With it, `mountUiHot` is the reactive variant and the " &
      "build-once assertions below would be measuring the wrong branch. " &
      "Run: nim c -r tests/test_native_hmr_inactive.nim".}

import unittest

import isonim/renderers/native
import isonim/native/hmr
import isonim/core/signals

suite "NH-M2: native HMR with -d:isonimHmr off":

  test "test_inactive_mount_ui_hot_is_build_once":
    var r = NativeRenderer()
    let host = r.createElement("host")
    let label = createSignal("alpha")
    var builds = 0

    let mount = mountUiHot(r, host, proc(): NativeWidget =
      inc builds
      let n = r.createElement("div")
      r.appendChild(n, r.createTextNode(label.val))
      n)

    check builds == 1
    check textContent(host) == "alpha"
    check mount.handle.renders == 1

    label.val = "beta"

    # Build-once: the flag-off mount is untracked, so the write does not
    # reach the seam. Identical to `staticNativeRoot` in NH-M1's control.
    check builds == 1
    check mount.handle.renders == 1
    check textContent(host) == "alpha"
    mount.dispose()
    check mount.isDisposed()

  test "test_inactive_hmr_signal_is_a_plain_signal":
    let a = hmrSignal(1)
    let b = hmrSignal(1)
    a.val = 9
    check a.val == 9
    check b.val == 1
    # No registry, so two hmrSignals at different call sites are two
    # different signals — the same as `createSignal`.
    check a != b

  test "test_inactive_hmr_root_is_inert_but_runs_the_entry_once":
    var entryRuns = 0
    let root = newHmrRoot(proc() = inc entryRuns)
    root.start()
    check entryRuns == 1
    root.start()          # idempotent
    check entryRuns == 1
    check root.slotCount == 0
    check root.signalCount == 0
    check root.currentGeneration == 0
    # There is no agent and no pending patch, so the poll is false.
    check not root.pumpReload()
    root.stop()

  test "test_inactive_mount_rejects_nil_arguments_loudly":
    # Loud prerequisites, not silent no-ops: a nil factory would mount an
    # empty root and every later assertion in a consumer's suite would be
    # vacuously true.
    var r = NativeRenderer()
    let host = r.createElement("host")
    let nilFactory: proc(): NativeWidget = nil
    expect ValueError:
      discard mountUiHot(r, host, nilFactory)
    expect ValueError:
      discard mountUiHot(
        proc(): NativeWidget = r.createElement("div"),
        NativeRootMount[NativeWidget](nil))
