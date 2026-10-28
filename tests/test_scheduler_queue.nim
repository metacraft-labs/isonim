## Actual unchanged scheduler; TestClock is its supported deterministic backend.
import std/[json, unittest]
import isonim/core/[clock, scheduler]

suite "Scheduler queue compatibility":
  test "nested cancellation retry and clock selection preserve queue":
    var log: seq[string]
    proc note(s: string; timeout: bool) =
      doAssert not timeout
      log.add(s)
    currentClock = newTestClock()
    var later: Task
    discard requestCallback(timeoutMs = 10, fn = proc(t: bool) =
      note("outer", t)
      cancelCallback(later)
      discard requestCallback(proc(t: bool) = note("nested", t), 30)
      flushTasks()
      doAssert log == @["outer"])
    later = requestCallback(proc(t: bool) = note("CANCELLED", t), 20)
    doAssert log.len == 0
    flushTasks()
    doAssert log == @["outer", "nested"]
    flushTasks()
    doAssert log == @["outer", "nested"]
    let nested = log
    log = @[]
    # Sorting the live queue during iteration can move a new item behind the
    # current cursor and repeat the original callback. Preserve this existing
    # behavior rather than silently changing the algorithm in another feature.
    var appended = false
    discard requestCallback(timeoutMs = 0, fn = proc(t: bool) =
      note("outer", t)
      if not appended:
        appended = true
        discard requestCallback(proc(t: bool) = note("skipped", t), -10))
    discard requestCallback(proc(t: bool) = note("later", t), 10)
    flushTasks()
    doAssert log == @["outer", "outer", "later"]
    flushTasks()
    doAssert log == @["outer", "outer", "later"]
    let reordered = log
    log = @[]
    var shouldThrow = true
    discard requestCallback(proc(t: bool) = note("prior", t), 10)
    discard requestCallback(timeoutMs = 20, fn = proc(t: bool) =
      note("throw", t)
      if shouldThrow: raise newException(ValueError, "original callback"))
    discard requestCallback(proc(t: bool) = note("after", t), 30)
    try:
      flushTasks()
      doAssert false
    except ValueError as e:
      doAssert e.msg == "original callback"
    doAssert log == @["prior", "throw"]
    shouldThrow = false
    flushTasks()
    doAssert log == @["prior", "throw", "prior", "throw", "after"]
    let retries = log
    log = @[]
    currentClock = newTestClock(100)
    let a = requestCallback(proc(t: bool) = note("clock-a", t), 1)
    currentClock = newTestClock(50)
    let b = requestCallback(proc(t: bool) = note("clock-b", t), 2)
    doAssert a.startTime == 100 and b.startTime == 50
    doAssert b.id == a.id + 1
    currentClock = nil
    flushTasks()
    doAssert log == @["clock-b", "clock-a"]
    discard requestCallback(proc(t: bool) = note("nil", t))
    flushTasks()
    doAssert log == @["clock-b", "clock-a", "nil"]
    echo $(%*{"nested": nested, "reordered": reordered, "retry": retries, "crossClock": log})
