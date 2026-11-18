## Readiness marks (`isonim/services/readiness`), driven by fake time. Runs on
## the C and JS backends.

import std/unittest

import nim_everywhere
import isonim/core/[signals, computation, owner]
import isonim/services/readiness

suite "readiness marks":
  test "marks are relative to the load's start and recorded once":
    let ctx = newFakeAsyncContext()
    ctx.install()
    defer: ctx.uninstall()
    ctx.advance(500)
    let r = newReadinessMarks()
    r.beginLoad()
    ctx.advance(40)
    r.markFirst("list")
    ctx.advance(60)
    r.markFirst("list")
    r.markComplete("list")
    check r.firstAt("list") == 40
    check r.completeAt("list") == 100
    check r.marks.value.len == 2
    check r.at("missing") == -1

  test "complete implies first when first was not marked":
    let ctx = newFakeAsyncContext()
    ctx.install()
    defer: ctx.uninstall()
    let r = newReadinessMarks()
    r.beginLoad()
    ctx.advance(25)
    r.markComplete("header")
    check r.firstAt("header") == 25
    check r.completeAt("header") == 25

  test "a new load clears the marks and resets the origin":
    let ctx = newFakeAsyncContext()
    ctx.install()
    defer: ctx.uninstall()
    let r = newReadinessMarks()
    r.beginLoad()
    ctx.advance(10)
    r.markComplete("a")
    ctx.advance(1000)
    r.beginLoad()
    check r.marks.value.len == 0
    check r.loads == 2
    ctx.advance(5)
    r.markComplete("a")
    check r.completeAt("a") == 5

  test "the marks are reactive":
    let ctx = newFakeAsyncContext()
    ctx.install()
    defer: ctx.uninstall()
    let r = newReadinessMarks()
    var seen: seq[int]
    createRoot proc(dispose: proc()) =
      createEffect proc() =
        seen.add r.marks.val.len
      r.beginLoad()
      r.markFirst("x")
      r.markComplete("x")
      dispose()
    check seen[^1] == 2
