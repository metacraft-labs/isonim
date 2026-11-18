## Streamed service responses (`isonim/services/streams`), driven by fake
## time. Runs on the C and JS backends: streams use only closures and the
## nim-everywhere clock.

import std/unittest

import nim_everywhere
import isonim/services/streams

proc step(ctx: FakeAsyncContext; ms: int) =
  ## Advance one millisecond at a time so every callback fires at its own
  ## time and sees the clock it was scheduled for.
  for _ in 0 ..< ms:
    ctx.advance(1)
    ctx.runPending()

type Log = ref object
  chunks: seq[string]
  done: int
  errors: seq[string]

proc sinkFor(log: Log): StreamSink[string] =
  result.onChunk = proc(c: string) = log.chunks.add(c)
  result.onDone = proc() = inc log.done
  result.onError = proc(m: string) = log.errors.add(m)

suite "service streams":
  test "a paced stream delivers its chunks in order at the pacing":
    let ctx = newFakeAsyncContext()
    ctx.install()
    defer: ctx.uninstall()
    let log = Log()
    let sub = pacedStream(@["a", "b", "c"], firstDelayMs = 10,
                          intervalMs = 5)(sinkFor(log))
    check log.chunks.len == 0
    ctx.step(9)
    check log.chunks.len == 0
    ctx.step(1)
    check log.chunks == @["a"]
    ctx.step(4)
    check log.chunks == @["a"]
    ctx.step(1)
    check log.chunks == @["a", "b"]
    ctx.step(5)
    check log.chunks == @["a", "b", "c"]
    check log.done == 1
    check sub.isEnded
    check not sub.isActive

  test "delivery is asynchronous even at zero delay":
    let ctx = newFakeAsyncContext()
    ctx.install()
    defer: ctx.uninstall()
    let log = Log()
    discard pacedStream(@["x"])(sinkFor(log))
    check log.chunks.len == 0
    ctx.runPending()
    check log.chunks == @["x"]
    check log.done == 1

  test "cancel stops delivery and reaches the producer":
    let ctx = newFakeAsyncContext()
    ctx.install()
    defer: ctx.uninstall()
    let log = Log()
    var producerCancelled = 0
    let s = newServiceStream[string](proc(e: StreamEmitter[string]) =
      e.onCancel(proc() = inc producerCancelled)
      e.emit("one"))
    let sub = s(sinkFor(log))
    check log.chunks == @["one"]
    sub.cancel()
    sub.cancel()
    check producerCancelled == 1
    check sub.isCancelled
    let paced = pacedStream(@["a", "b", "c"], intervalMs = 10)(sinkFor(log))
    ctx.step(1)
    check log.chunks == @["one", "a"]
    paced.cancel()
    ctx.step(50)
    check log.chunks == @["one", "a"]
    check log.done == 0

  test "an error ends the stream once and nothing follows it":
    let ctx = newFakeAsyncContext()
    ctx.install()
    defer: ctx.uninstall()
    let log = Log()
    discard pacedStream(@["a", "b", "c"], intervalMs = 1, failAfter = 2,
                        failure = "boom")(sinkFor(log))
    ctx.step(10)
    check log.chunks == @["a", "b"]
    check log.errors == @["boom"]
    check log.done == 0
    var e: StreamEmitter[string]
    discard newServiceStream[string](proc(em: StreamEmitter[string]) =
      e = em)(sinkFor(log))
    e.fail("first")
    e.fail("second")
    e.emit("late")
    e.finish()
    check log.errors == @["boom", "first"]
    check log.chunks == @["a", "b"]
    check log.done == 0

  test "tee reports every event to the observer and forwards it":
    let ctx = newFakeAsyncContext()
    ctx.install()
    defer: ctx.uninstall()
    let seen = Log()
    let got = Log()
    discard tee(pacedStream(@["p", "q"]), sinkFor(seen))(sinkFor(got))
    ctx.step(5)
    check seen.chunks == @["p", "q"]
    check got.chunks == @["p", "q"]
    check seen.done == 1
    check got.done == 1

  test "chunkText splits on characters, not bytes":
    check chunkText("hello world", 4) == @["hell", "o wo", "rld"]
    check chunkText("", 3).len == 0
    check chunkText("abc", 0) == @["abc"]
    check chunkText("äöüß", 3) == @["äöü", "ß"]
