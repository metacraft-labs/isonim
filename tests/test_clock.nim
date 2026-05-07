import unittest
when not defined(js):
  import std/times
import isonim/core/clock
import isonim/core/scheduler
import isonim/core/[types, graph, signals, owner, computation, batch]
import isonim/testing/test_utils

suite "TestClock":
  test "initial time is 0":
    let tc = newTestClock()
    check tc.now() == 0.0

  test "advance moves time forward":
    let tc = newTestClock()
    tc.advance(100.0)
    check tc.now() == 100.0

  test "advance fires scheduled callbacks in order":
    let tc = newTestClock()
    var order: seq[int] = @[]
    discard tc.schedule(proc() = order.add(2), 200.0)
    discard tc.schedule(proc() = order.add(1), 100.0)
    discard tc.schedule(proc() = order.add(3), 300.0)
    tc.advance(300.0)
    check order == @[1, 2, 3]

  test "advance only fires callbacks up to target time":
    let tc = newTestClock()
    var fired: seq[int] = @[]
    discard tc.schedule(proc() = fired.add(1), 100.0)
    discard tc.schedule(proc() = fired.add(2), 200.0)
    discard tc.schedule(proc() = fired.add(3), 300.0)
    tc.advance(250.0)
    check fired == @[1, 2]
    check tc.now() == 250.0

  test "cancel prevents callback from firing":
    let tc = newTestClock()
    var fired = false
    let id = tc.schedule(proc() = fired = true, 100.0)
    tc.cancel(id)
    tc.advance(200.0)
    check fired == false

  test "setTime advances and fires callbacks":
    let tc = newTestClock()
    var fired = false
    discard tc.schedule(proc() = fired = true, 50.0)
    tc.setTime(100.0)
    check fired == true
    check tc.now() == 100.0

  test "TestClock completes instantly (no real delay)":
    let tc = newTestClock()
    var callbackFired = false
    # Schedule something "1 hour" in the future
    discard tc.schedule(proc() = callbackFired = true, 3_600_000.0)
    when not defined(js):
      let start = cpuTime()
      tc.advance(3_600_000.0)
      let elapsed = cpuTime() - start
      check callbackFired == true
      check elapsed < 0.1  # Must complete in under 100ms real time
    else:
      tc.advance(3_600_000.0)
      check callbackFired == true

suite "withTestClock":
  test "sets and restores global clock":
    let tc = newTestClock()
    let prevClock = currentClock
    withTestClock(tc):
      check currentClock == tc
    check currentClock == prevClock

suite "Scheduler":
  test "requestCallback schedules and flushTasks executes":
    var executed = false
    let task = requestCallback(proc(didTimeout: bool) = executed = true)
    check executed == false or executed == true  # May execute immediately with RealClock
    flushTasks()
    check executed == true

  test "cancelCallback prevents execution":
    var executed = false
    let task = requestCallback(proc(didTimeout: bool) = executed = true)
    cancelCallback(task)
    flushTasks()
    check executed == false

  test "tasks execute in expiration order":
    var order: seq[int] = @[]
    discard requestCallback(proc(didTimeout: bool) = order.add(2), 2000.0)
    discard requestCallback(proc(didTimeout: bool) = order.add(1), 1000.0)
    discard requestCallback(proc(didTimeout: bool) = order.add(3), 3000.0)
    flushTasks()
    check order == @[1, 2, 3]

suite "Effects with fake time":
  test "deferred effects work under fake time":
    withFakeTime:
      var observed = -1
      createRoot do (dispose: proc()):
        let s = createSignal(0)
        createEffect do:
          observed = s.val
        check observed == 0
        s.val = 5
        check observed == 5  # Effects fire synchronously for now
