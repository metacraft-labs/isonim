## IsoNim-Resource-Async tests.
##
## Verifies the async overloads of `createResource` in
## `isonim/core/resource.nim`. Drives all timing through a
## `FakeAsyncContext` (from `nim_everywhere/fake_time`) so the suite is
## fully deterministic and runs in well under wall-clock latency.
##
## The async overloads transition through these states:
##   - simple overload: rsPending -> rsReady (or rsErrored)
##   - source-tracked: rsUnresolved -> rsPending -> rsReady (or rsErrored)
##   - refresh: rsReady -> rsRefreshing -> rsReady (or rsErrored); the
##              previous `data.val` stays visible during rsRefreshing
##
## Out-of-order completion handling: when refresh is triggered twice
## rapidly, the older fetch's late completion is discarded — only the
## most-recent fetch's result is applied.

import std/unittest
import nim_everywhere
import nim_everywhere/async_compat
import isonim/core/[signals, owner, resource]

suite "Resource async overload":

  test "completes to rsReady via fake-time advance":
    let ctx = newFakeAsyncContext()
    ctx.install()
    defer: ctx.uninstall()
    createRoot do (dispose: proc()):
      let r = createResource[int](
        proc(): PlatformFuture[int] =
          let f = newFuture[int]("test-fetch")
          ctx.schedule(50, proc() = f.complete(42))
          f,
        initialValue = 0)
      # Initial state: rsPending, data still at initial value.
      check r.state.val == rsPending
      check r.data.val == 0
      # Fake time has not advanced — callback has not fired.
      ctx.advance(49)
      ctx.runPending()
      drainPlatformCallbacks()
      check r.state.val == rsPending
      check r.data.val == 0
      # Advance past the scheduled time and drain.
      ctx.advance(1)
      ctx.runPending()
      drainPlatformCallbacks()
      check r.state.val == rsReady
      check r.data.val == 42
      check r.error.val == ""
      dispose()

  test "propagates error to rsErrored":
    let ctx = newFakeAsyncContext()
    ctx.install()
    defer: ctx.uninstall()
    createRoot do (dispose: proc()):
      let r = createResource[int](
        proc(): PlatformFuture[int] =
          let f = newFuture[int]("test-fail")
          ctx.schedule(20, proc() =
            f.fail(newException(CatchableError, "boom")))
          f,
        initialValue = -1)
      check r.state.val == rsPending
      ctx.advance(20)
      ctx.runPending()
      drainPlatformCallbacks()
      check r.state.val == rsErrored
      check r.error.val == "boom"
      # data.val stays at the initial value; the failed fetch must not
      # clobber it.
      check r.data.val == -1
      dispose()

  test "source-change refetches":
    let ctx = newFakeAsyncContext()
    ctx.install()
    defer: ctx.uninstall()
    createRoot do (dispose: proc()):
      let src = createSignal("a")
      let r = createResource[string, string](
        source = proc(): string = src.val,
        fetcher = proc(s: string): PlatformFuture[string] =
          let captured = s
          let f = newFuture[string]("test-source-refetch")
          ctx.schedule(50, proc() = f.complete("loaded:" & captured))
          f,
        initialValue = "")
      # Initial fetch is in flight after createResource (effect ran).
      check r.state.val == rsPending
      ctx.advance(50)
      ctx.runPending()
      drainPlatformCallbacks()
      check r.state.val == rsReady
      check r.data.val == "loaded:a"
      # Mutate source — effect fires again.
      src.val = "b"
      check r.state.val == rsRefreshing
      check r.data.val == "loaded:a"  # old value visible during refetch
      ctx.advance(50)
      ctx.runPending()
      drainPlatformCallbacks()
      check r.state.val == rsReady
      check r.data.val == "loaded:b"
      dispose()

  test "refresh keeps old value during rsRefreshing then updates":
    let ctx = newFakeAsyncContext()
    ctx.install()
    defer: ctx.uninstall()
    var values = @["v1", "v2"]
    var callCount = 0
    createRoot do (dispose: proc()):
      let r = createResource[string](
        proc(): PlatformFuture[string] =
          let myCall = callCount
          inc callCount
          let f = newFuture[string]("test-refresh")
          ctx.schedule(40, proc() = f.complete(values[myCall]))
          f,
        initialValue = "")
      check r.state.val == rsPending
      ctx.advance(40)
      ctx.runPending()
      drainPlatformCallbacks()
      check r.state.val == rsReady
      check r.data.val == "v1"

      # Trigger refresh — state goes to rsRefreshing, value stays "v1"
      # until the new future completes.
      r.refresh()
      check r.state.val == rsRefreshing
      check r.data.val == "v1"
      ctx.advance(40)
      ctx.runPending()
      drainPlatformCallbacks()
      check r.state.val == rsReady
      check r.data.val == "v2"
      dispose()

  test "out-of-order completions discarded — only newest wins":
    let ctx = newFakeAsyncContext()
    ctx.install()
    defer: ctx.uninstall()
    # First fetch is slow (100 ms), every subsequent refresh is fast
    # (10 ms). After we kick off a refresh while the first fetch is
    # still in flight, the late completion of the older fetch must be
    # discarded.
    var callCount = 0
    var latencies = @[100, 10, 10]
    var labels = @["slow", "fast1", "fast2"]
    createRoot do (dispose: proc()):
      let r = createResource[string](
        proc(): PlatformFuture[string] =
          let myCall = callCount
          inc callCount
          let f = newFuture[string]("test-ooo")
          let lat = latencies[myCall]
          let lbl = labels[myCall]
          ctx.schedule(lat, proc() = f.complete(lbl))
          f,
        initialValue = "")
      check r.state.val == rsPending
      # Don't let the initial fetch finish — refresh while it's pending.
      ctx.advance(10)
      ctx.runPending()
      drainPlatformCallbacks()
      check r.state.val == rsPending  # initial fetch is still pending

      # Trigger refresh (fetch #2 — fast, 10 ms).
      r.refresh()
      # Advance enough for fetch #2 to complete; the slow fetch #1 is
      # still pending at t=20 (it fires at t=100).
      ctx.advance(10)
      ctx.runPending()
      drainPlatformCallbacks()
      check r.state.val == rsReady
      check r.data.val == "fast1"

      # Now advance past t=100 and drain. Fetch #1's late completion
      # should be DISCARDED — data.val stays "fast1".
      ctx.advance(100)
      ctx.runPending()
      drainPlatformCallbacks()
      check r.state.val == rsReady
      check r.data.val == "fast1"
      dispose()

  test "refresh on source-tracked resource re-runs with current source":
    let ctx = newFakeAsyncContext()
    ctx.install()
    defer: ctx.uninstall()
    var counter = 0
    createRoot do (dispose: proc()):
      let src = createSignal(10)
      let r = createResource[int, string](
        source = proc(): int = src.val,
        fetcher = proc(s: int): PlatformFuture[string] =
          inc counter
          let myCounter = counter
          let captured = s
          let f = newFuture[string]("test-source-refresh")
          ctx.schedule(20, proc() =
            f.complete($captured & "#" & $myCounter))
          f,
        initialValue = "")
      # Drain the initial fetch.
      ctx.advance(20)
      ctx.runPending()
      drainPlatformCallbacks()
      check r.state.val == rsReady
      check r.data.val == "10#1"
      # Now call refresh — same source value, fetch reruns.
      r.refresh()
      check r.state.val == rsRefreshing
      ctx.advance(20)
      ctx.runPending()
      drainPlatformCallbacks()
      check r.state.val == rsReady
      check r.data.val == "10#2"
      dispose()
