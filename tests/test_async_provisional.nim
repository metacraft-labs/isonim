## Declared placeholders and readiness marks of an async value
## (`isonim/services/async_value`), under fake time: a placeholder is shown
## and flagged as provisional until the first answer; the `:first`
## readiness mark is not recorded for it and is recorded for the first real
## answer or chunk; completion is recorded when a future answers and when a
## stream is done, and not when it breaks off.
##
## MOCK POLICY (workspace rule: every mock justified in the header). One
## recording service (`helpers/async_recording_service`): its futures are
## real `Deferred`s and its streams real `newServiceStream`s, settled and
## paced by timers on the nim-everywhere clock driven by
## `FakeAsyncContext`. The readiness marks, the primitive and its signals
## are the real ones. On the JS backend a future answers at the next drain
## rather than after its latency (see the helper's header), so the time of
## a future's mark is checked on C only; stream marks are timed on both.

import std/[options, tables, unittest]

import nim_everywhere
import isonim/core/[signals, owner, computation]
import isonim/services/[async_value, readiness]

import helpers/async_recording_service

proc fetchOf(svc: RecordingService): proc(q: string): PlatformFuture[string] =
  result = proc(q: string): PlatformFuture[string] = svc.fetch(q)

proc streamOf(svc: RecordingService): proc(q: string): ServiceStream[string] =
  result = proc(q: string): ServiceStream[string] = svc.stream(q)

suite "async value placeholders and readiness marks":
  test "a placeholder is shown and flagged as provisional":
    let ctx = newFakeAsyncContext()
    ctx.install()
    defer: ctx.uninstall()
    let svc = newRecordingService(latencyMs = 20)
    let q = createSignal("a")
    let av = createAsync(proc(): string = q.val, svc.fetchOf,
                         placeholder = some("(loading...)"))
    check av.val == "(loading...)"
    check av.provisional
    check av.loading          # a placeholder is not an answer
    check not av.ready
    check not av.done
    ctx.step(20)
    check av.val == answerFor("a", 1)
    check not av.provisional
    check av.ready
    # A new question holds the real answer, never the placeholder again.
    q.val = "b"
    check av.pending
    check not av.provisional
    check av.val == answerFor("a", 1)
    av.dispose()

  test "a failed first load keeps the placeholder flagged":
    let ctx = newFakeAsyncContext()
    ctx.install()
    defer: ctx.uninstall()
    let svc = newRecordingService()
    svc.failures["a"] = "offline"
    let q = createSignal("a")
    let av = createAsync(proc(): string = q.val, svc.fetchOf,
                         placeholder = some("(loading...)"))
    ctx.step(10)
    check av.status == AsyncStatus.failed
    check av.error == "offline"
    check av.provisional
    check av.val == "(loading...)"
    av.dispose()

  test ":first is not recorded for a placeholder, and is for the first answer":
    let ctx = newFakeAsyncContext()
    ctx.install()
    defer: ctx.uninstall()
    let svc = newRecordingService(latencyMs = 20)
    let marks = newReadinessMarks()
    marks.beginLoad()
    let q = createSignal("a")
    let av = createAsync(proc(): string = q.val, svc.fetchOf,
                         placeholder = some("(loading...)"),
                         marks = marks, element = "item")
    check av.provisional
    check not marks.has("item:first")
    check not marks.has("item")
    when not defined(js):
      ctx.step(5)
      check av.provisional
      check not marks.has("item:first")
      ctx.step(10)
    ctx.step(5)
    check marks.has("item:first")
    check marks.has("item")     # a future's answer is complete at once
    when not defined(js):
      check marks.firstAt("item") == 20
      check marks.completeAt("item") == 20
    # Marks are once per load: a later answer leaves them as they were.
    let first = marks.firstAt("item")
    q.val = "b"
    ctx.step(20)
    check marks.firstAt("item") == first
    check marks.marks.value.len == 2
    av.dispose()

  test "a stream marks its first chunk, and completion when done":
    let ctx = newFakeAsyncContext()
    ctx.install()
    defer: ctx.uninstall()
    let svc = newRecordingService(intervalMs = 10, chunkCount = 3)
    let marks = newReadinessMarks()
    marks.beginLoad()
    let q = createSignal("a")
    let av = createAsyncStream(proc(): string = q.val, svc.streamOf,
                               placeholder = some(@["(typing)"]),
                               marks = marks, element = "reply")
    check av.val == @["(typing)"]
    check av.provisional
    ctx.step(5)
    check not marks.has("reply:first")
    ctx.step(5)
    check not av.provisional
    check av.val == @[chunkFor("a", 1)]
    check marks.firstAt("reply") == 10
    check not marks.has("reply")
    ctx.step(20)
    check not marks.has("reply")  # all chunks, but not yet done
    ctx.step(10)
    check av.done
    check marks.completeAt("reply") == 40
    av.dispose()

  test "a stream that breaks off records no completion":
    let ctx = newFakeAsyncContext()
    ctx.install()
    defer: ctx.uninstall()
    let svc = newRecordingService(intervalMs = 10, chunkCount = 3)
    svc.streamFailAfter["a"] = 1
    let marks = newReadinessMarks()
    marks.beginLoad()
    let q = createSignal("a")
    let av = createAsyncStream(proc(): string = q.val, svc.streamOf,
                               marks = marks, element = "reply")
    ctx.step(30)
    check av.status == AsyncStatus.failed
    check marks.firstAt("reply") == 10
    check not marks.has("reply")
    av.dispose()
