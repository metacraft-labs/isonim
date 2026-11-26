## Simulated network conditions (`isonim/services/network`), driven by fake
## time. The stream cases run on the C and JS backends; the future cases need
## a synchronous drain of future callbacks, which the JS backend's promises do
## not offer, so they run on the C backend only.

import std/[strutils, unittest]

import nim_everywhere
import nim_everywhere/async_compat
import isonim/services/network

proc step(ctx: FakeAsyncContext; ms: int) =
  for _ in 0 ..< ms:
    ctx.advance(1)
    ctx.runPending()
    when not defined(js):
      drainPlatformCallbacks()
      ctx.runPending()

proc settle(ctx: FakeAsyncContext) =
  ## Fire what is due now, without advancing the clock.
  ctx.runPending()
  when not defined(js):
    drainPlatformCallbacks()
    ctx.runPending()

type Log = ref object
  chunks: seq[string]
  chunkAt: seq[int64]
  done: int
  doneAt: int64
  errors: seq[string]

proc sinkFor(log: Log): StreamSink[string] =
  result.onChunk = proc(c: string) =
    log.chunks.add(c)
    log.chunkAt.add(monotonicNowMs())
  result.onDone = proc() =
    inc log.done
    log.doneAt = monotonicNowMs()
  result.onError = proc(m: string) = log.errors.add(m)

suite "network profiles":
  test "transfer time follows the bandwidth":
    let p = NetworkProfile(name: "t", latencyMs: 100, downKbps: 8)
    check p.transferMs(0) == 0
    check p.transferMs(1) == 1      # 8 bits at 8 bits/ms
    check p.transferMs(1000) == 1000
    check InstantNetwork.transferMs(1_000_000) == 0
    check networkPreset("4g").latencyMs == FourGNetwork.latencyMs
    expect ValueError:
      discard networkPreset("carrier-pigeon")

  test "a wrapped stream waits the latency, then each chunk's transfer":
    let ctx = newFakeAsyncContext()
    ctx.install()
    defer: ctx.uninstall()
    # 10 bytes take 10 ms at 8 kbps.
    let sim = newNetworkSimulator(NetworkProfile(name: "t", label: "T",
      latencyMs: 100, downKbps: 8))
    let log = Log()
    let start = monotonicNowMs()
    discard sim.simulateStream("reply", pacedStream(@["0123456789",
      "abcdefghij"]), textBytes)(sinkFor(log))
    ctx.settle()
    ctx.step(109)
    check log.chunks.len == 0
    ctx.step(1)
    check log.chunks == @["0123456789"]
    check log.chunkAt[0] - start == 110
    ctx.step(9)
    check log.chunks.len == 1
    ctx.step(1)
    check log.chunks.len == 2
    check log.chunkAt[1] - start == 120
    check log.done == 1
    check log.doneAt - start == 120

  test "a chunk produced after earlier deliveries still travels the latency":
    let ctx = newFakeAsyncContext()
    ctx.install()
    defer: ctx.uninstall()
    let sim = newNetworkSimulator(NetworkProfile(name: "t", label: "T",
      latencyMs: 100))
    let log = Log()
    let start = monotonicNowMs()
    discard sim.simulateStream("s", pacedStream(@["a", "b"],
      intervalMs = 300), textBytes)(sinkFor(log))
    ctx.settle()
    ctx.step(400)
    check log.chunkAt.len == 2
    check log.chunkAt[0] - start == 100
    check log.chunkAt[1] - start == 400

  test "the instant profile adds no delay and keeps order":
    let ctx = newFakeAsyncContext()
    ctx.install()
    defer: ctx.uninstall()
    let sim = newNetworkSimulator(InstantNetwork)
    let log = Log()
    discard sim.simulateStream("s", pacedStream(@["a", "b", "c"],
      intervalMs = 3), textBytes)(sinkFor(log))
    ctx.step(1)
    check log.chunks == @["a"]
    ctx.step(6)
    check log.chunks == @["a", "b", "c"]
    check log.done == 1

  test "a delivered chunk stays alive while the subscriber runs":
    # The chunks are built at run time (string literals are never freed
    # under ARC/ORC, so they would hide the defect), and the subscriber
    # allocates a string of the same size before it reads each chunk. If
    # the simulator released a chunk before handing it over, that
    # allocation would reuse its memory and the chunk would read as it.
    # Run under ORC, ARC and refc (the Justfile builds all three).
    let ctx = newFakeAsyncContext()
    ctx.install()
    defer: ctx.uninstall()
    let sim = newNetworkSimulator(InstantNetwork)
    var got: seq[string]
    let source = pacedStream(chunkText("abcdefghijkl", 4),
      intervalMs = 50)
    var sink: StreamSink[string]
    sink.onChunk = proc(c: string) =
      let noise = repeat("Z", 4)
      got.add c
      check noise == "ZZZZ"
    sink.onDone = proc() = discard
    sink.onError = proc(message: string) = discard
    discard sim.simulateStream("s", source, textBytes)(sink)
    ctx.step(200)
    check got == @["abcd", "efgh", "ijkl"]

  test "cancelling a wrapped stream cancels the source":
    let ctx = newFakeAsyncContext()
    ctx.install()
    defer: ctx.uninstall()
    let sim = newNetworkSimulator(FourGNetwork)
    var sourceCancelled = false
    var emitter: StreamEmitter[string]
    let source = newServiceStream[string](proc(e: StreamEmitter[string]) =
      emitter = e
      e.onCancel(proc() = sourceCancelled = true))
    let log = Log()
    let sub = sim.simulateStream("s", source, textBytes)(sinkFor(log))
    emitter.emit("queued")
    sub.cancel()
    check sourceCancelled
    ctx.step(1000)
    check log.chunks.len == 0

  test "a failure rate of 1 fails the stream after one latency":
    let ctx = newFakeAsyncContext()
    ctx.install()
    defer: ctx.uninstall()
    var subscribed = false
    let source = newServiceStream[string](proc(e: StreamEmitter[string]) =
      subscribed = true)
    let sim = newNetworkSimulator(NetworkProfile(name: "down", label: "Down",
      latencyMs: 50, failureRate: 1.0))
    let log = Log()
    discard sim.simulateStream("s", source, textBytes)(sinkFor(log))
    ctx.step(49)
    check log.errors.len == 0
    ctx.step(1)
    check log.errors.len == 1
    check not subscribed

  when not defined(js):
    test "a wrapped operation completes after latency + transfer, not before":
      let ctx = newFakeAsyncContext()
      ctx.install()
      defer: ctx.uninstall()
      let sim = newNetworkSimulator(NetworkProfile(name: "t", label: "T",
        latencyMs: 100, downKbps: 8))
      var got = ""
      var calls = 0
      let fut = sim.simulate[:string]("load",
        proc(): PlatformFuture[string] =
          inc calls
          newCompletedFuture(repeat("x", 20)),
        textBytes)
      fut.onComplete(proc(v: string) = got = v, proc(m: string) = discard)
      check calls == 1
      ctx.settle()
      ctx.step(119)
      check got == ""
      ctx.step(1)
      check got.len == 20

    test "a failure rate of 1 fails every call without reaching the service":
      let ctx = newFakeAsyncContext()
      ctx.install()
      defer: ctx.uninstall()
      let sim = newNetworkSimulator(NetworkProfile(name: "down",
        label: "Down", latencyMs: 30, failureRate: 1.0))
      var calls = 0
      var errors = 0
      for _ in 0 ..< 3:
        sim.simulate[:int]("op", proc(): PlatformFuture[int] =
            inc calls
            newCompletedFuture(1),
          proc(v: int): int = 4).onComplete(
          proc(v: int) = discard, proc(m: string) = inc errors)
      ctx.step(30)
      check errors == 3
      check calls == 0

    test "jitter is deterministic under a seed":
      let a = newNetworkSimulator(FourGNetwork, seed = 7)
      let b = newNetworkSimulator(FourGNetwork, seed = 7)
      for _ in 0 ..< 20:
        check a.responseDelayMs(100) == b.responseDelayMs(100)

when defined(js):
  # Promises settle on the microtask queue, after `unittest` has finished its
  # synchronous cases, so these report their own [OK] / [FAILED] lines, which
  # tools/run_nim_js_test.py checks.
  # The process fails unless all three asynchronous checks report success,
  # so a check whose callback never runs cannot pass by saying nothing.
  const asyncChecks = 3
  var passed = 0
  {.emit: "process.exitCode = 1;".}
  proc report(ok: bool; what: string) =
    echo (if ok: "  [OK] " else: "  [FAILED] "), what
    if ok:
      inc passed
      if passed == asyncChecks:
        {.emit: "process.exitCode = 0;".}

  block:
    let d = newDeferred[int]("js-resolve")
    d.resolve(3)
    d.resolve(4)
    d.reject("ignored")
    proc resolvedOk(v: int) = report(v == 3, "a deferred resolves once on the JS backend")
    proc resolvedErr(m: string) = report(false, "a resolved deferred rejected: " & m)
    d.future.onComplete(resolvedOk, resolvedErr)

    let r = newDeferred[int]("js-reject")
    r.reject("no")
    r.resolve(5)
    proc rejectedOk(v: int) = report(false, "a rejected deferred resolved")
    proc rejectedErr(m: string) = report(m == "no", "a deferred rejects once on the JS backend")
    r.future.onComplete(rejectedOk, rejectedErr)

    # Real timers (no fake context): the wrapped operation resolves after the
    # latency on the runtime's own clock.
    let sim = newNetworkSimulator(NetworkProfile(name: "t", label: "T",
      latencyMs: 20))
    let started = monotonicNowMs()
    proc op(): PlatformFuture[int] = newCompletedFuture(9)
    proc size(v: int): int = 1
    proc wrappedOk(v: int) =
      let waited = monotonicNowMs() - started
      report(v == 9 and waited >= 19,
        "a wrapped operation resolves after the latency on JS (" & $waited & " ms)")
    proc wrappedErr(m: string) = report(false, "wrapped operation failed: " & m)
    sim.simulate[:int]("op", op, size).onComplete(wrappedOk, wrappedErr)
