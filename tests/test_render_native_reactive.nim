## NH-M1 — the shared reactive-root scaffold, `renderNative`.
##
## MOCK POLICY (per the workspace rule that every mock is justified in the
## test file's header): there are NO mocks here. `NativeRenderer` /
## `NativeWidget` from `isonim/renderers/native` are the module under test's
## own in-repo renderer backend, not a stand-in for one — they are the same
## objects `tests/test_native_renderer.nim` exercises. The reactive core
## (`createRoot`, `createRenderEffect`, `Signal`) is the real one. Nothing is
## stubbed, faked or intercepted.
##
## WHAT THIS PROVES, AND HOW IT DISCRIMINATES. The claim NH-M1 makes is not
## "a proc named renderNative exists" — it is "the mount site is a render
## effect, so a signal write re-runs it". A test that only mounts and asserts
## the first frame would pass against a `renderNative` that called the
## accessor once and never again. So every reactive case below is paired with
## a CONTROL that mounts the identical tree WITHOUT the seam (or with the seam
## explicitly untracked) and asserts the re-render does NOT happen. If the
## effect wiring is removed from `renderNative`, the reactive cases go red;
## if the controls were themselves reactive by accident, they go red instead.

import std/strutils
import unittest

import isonim/renderers/native
import isonim/core/signals

proc buildLabelTree(r: NativeRenderer; text: string): NativeWidget =
  ## Build a fresh two-node tree. A NEW root every call, on purpose: the
  ## root-swap path is what NH-M2's hot-component proxy will drive.
  let root = r.createElement("div")
  r.setAttribute(root, "class", "app-root")
  r.appendChild(root, r.createTextNode(text))
  root

suite "NH-M1: renderNative reactive root scaffold":

  test "test_render_native_mounts_through_a_reactive_root":
    let renderer = NativeRenderer()
    let host = renderer.createElement("host")
    let label = createSignal("alpha")

    let handle = renderNative(renderer, host,
      NativeRootAccessor[NativeWidget](proc(): NativeWidget =
        buildLabelTree(renderer, label.val)))

    check handle.renders == 1
    check handle.rootSwaps == 1
    check host.children.len == 1
    check textContent(host) == "alpha"
    check not isDisposed(handle)
    handle.dispose()
    check isDisposed(handle)

  test "test_render_native_signal_write_reruns_the_render_effect":
    # The reactive arm. Same tree, same renderer, same host as the control
    # below; the ONLY difference is that the mount goes through renderNative.
    let renderer = NativeRenderer()
    let host = renderer.createElement("host")
    let label = createSignal("alpha")

    let handle = renderNative(renderer, host,
      NativeRootAccessor[NativeWidget](proc(): NativeWidget =
        buildLabelTree(renderer, label.val)))
    check handle.renders == 1
    check textContent(host) == "alpha"

    label.val = "beta"

    check handle.renders == 2
    check handle.rootSwaps == 2
    # The reactive insert REPLACED the old root rather than appending a
    # second one: exactly one child, and it is the new tree.
    check host.children.len == 1
    check textContent(host) == "beta"
    check not contains(textContent(host), "alpha")

    label.val = "gamma"
    check handle.renders == 3
    check host.children.len == 1
    check textContent(host) == "gamma"
    handle.dispose()

  test "test_control_imperative_mount_does_not_rerender_on_signal_write":
    # DISCRIMINATION CONTROL #1 — today's non-HMR call shape: build the tree
    # and attach it by hand, no reactive root, no effect. If this went green
    # with "beta" the previous case would be proving nothing about the seam.
    let renderer = NativeRenderer()
    let host = renderer.createElement("host")
    let label = createSignal("alpha")

    renderer.appendChild(host, buildLabelTree(renderer, label.val))
    check textContent(host) == "alpha"

    label.val = "beta"

    check textContent(host) == "alpha"
    check host.children.len == 1

  test "test_control_static_native_root_keeps_build_once_semantics":
    # DISCRIMINATION CONTROL #2 — the seam is present, but the accessor is
    # wrapped in `staticNativeRoot` (the analogue of web `render()`'s
    # `untrack`). This is the shape non-HMR callers use, and it must behave
    # exactly like control #1: the effect body runs once and tracks nothing.
    let renderer = NativeRenderer()
    let host = renderer.createElement("host")
    let label = createSignal("alpha")

    let handle = renderNative(renderer, host,
      staticNativeRoot(proc(): NativeWidget =
        buildLabelTree(renderer, label.val)))
    check handle.renders == 1
    check textContent(host) == "alpha"

    label.val = "beta"

    check handle.renders == 1
    check textContent(host) == "alpha"
    handle.dispose()

  test "test_render_native_mount_callback_runs_on_every_render":
    # The `mount` callback overload — the shape the TUI/GPUI/Freya entry
    # points use, where the surface is not a parent element. `mount` must run
    # on EVERY effect pass (a signal write that mutates the tree in place
    # still has to reach the surface), which is a stronger contract than
    # "run when the root identity changes".
    let renderer = NativeRenderer()
    let counter = createSignal(0)
    var mountCalls = 0
    var lastSeen = ""
    let stableRoot = renderer.createElement("div")

    let handle = renderNative(
      NativeRootAccessor[NativeWidget](proc(): NativeWidget =
        # Same root object every time; only its text changes.
        renderer.setTextContent(stableRoot, "n=" & $counter.val)
        stableRoot),
      NativeRootMount[NativeWidget](proc(node: NativeWidget) =
        inc mountCalls
        lastSeen = textContent(node)))

    check handle.renders == 1
    check handle.rootSwaps == 1
    check mountCalls == 1
    check lastSeen == "n=0"

    counter.val = 1
    check handle.renders == 2
    # Root identity never changed, so no swap …
    check handle.rootSwaps == 1
    # … but the surface was still refreshed.
    check mountCalls == 2
    check lastSeen == "n=1"
    handle.dispose()

  test "test_render_native_rejects_nil_accessor_and_nil_mount":
    # Loud prerequisites, not silent no-ops: a nil accessor would otherwise
    # mount an empty root and every later assertion in a consumer's suite
    # would be vacuously true.
    expect ValueError:
      discard renderNative(NativeRootAccessor[NativeWidget](nil),
                           NativeRootMount[NativeWidget](proc(n: NativeWidget) =
                             discard))
    expect ValueError:
      discard renderNative(
        NativeRootAccessor[NativeWidget](proc(): NativeWidget = nil),
        NativeRootMount[NativeWidget](nil))
    expect ValueError:
      discard staticNativeRoot[NativeWidget](nil)

  test "test_render_native_dispose_stops_the_render_effect":
    let renderer = NativeRenderer()
    let host = renderer.createElement("host")
    let label = createSignal("alpha")

    let handle = renderNative(renderer, host,
      NativeRootAccessor[NativeWidget](proc(): NativeWidget =
        buildLabelTree(renderer, label.val)))
    label.val = "beta"
    check handle.renders == 2

    handle.dispose()
    label.val = "gamma"
    # Disposal cleaned the root's owned computations, so the effect is gone.
    check handle.renders == 2
    check textContent(host) == "beta"
    # Idempotent.
    handle.dispose()
    check isDisposed(handle)
