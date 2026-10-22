## Clock abstraction for pluggable time in IsoNim.
##
## RealClock uses actual system/monotonic time.
## TestClock allows manual time advancement for deterministic testing.

import std/[algorithm, sequtils, tables, math, json, random]
import nim_everywhere/time as neTime
import nim_everywhere/platform
when not defined(js):
  import std/monotimes

type
  ScheduledCallback = object
    id: int
    time: float64      ## Absolute time in ms when callback should fire
    callback: proc()
    when defined(isonimRecordable):
      maintenance: bool

  ClockBase* = ref object of RootObj
    ## Base type for all clocks.
    dispatchSequence*: uint64
    when defined(isonimRecordable):
      randomDrawCount*: uint64
      checkpointDispatch*: proc()
    lastTimerId: int
    ## Boundary backend state shared by RealClock and TestClock.
    when defined(isonimNondetCoverage):
      seamCalls*: Table[string, int] ## Explicit test coverage instrumentation only.
    scripted*: bool
    reads*: Table[string, seq[JsonNode]]
    randomState*: Rand
    bootEnv*: JsonNode
    storage*: Table[string, string]
    nativeLocation*: string
    nextHandle*: int
    seamTimers*: Table[int, int]
    frameCancels*: Table[int, proc()]
    fetchResponse*: proc(request: HttpRequest): neTime.PlatformFuture[HttpResponse]

  RealClock* = ref object of ClockBase
    ## Production clock using real system time.
    platformTimers: Table[int, neTime.TimerHandle]

  TestClock* = ref object of ClockBase
    ## Deterministic clock for testing.
    ## Time only advances via explicit advance() or setTime() calls.
    currentTime*: float64
    scheduled: seq[ScheduledCallback]  ## Sorted by time
    nextId: int

# Current global clock (thread-local)
var currentClock* {.threadvar.}: ClockBase

when defined(isonimRecordable):
  template beginDispatch*(clock: ClockBase) =
    inc clock.dispatchSequence
    if clock.checkpointDispatch != nil: clock.checkpointDispatch()

method now*(clock: ClockBase): float64 {.base.} =
  raise newException(ValueError, "clock backend has no time source")

proc rawClockNow(): float64 {.tags: [neTime.RawNondet].} =
  ## Private Real backend primitive; components use nondet.now instead.
  {.cast(tags: []).}:
    when defined(js):
      {.emit: [result, " = performance.now();"].}
    else:
      let t = getMonoTime()
      result = t.ticks.float64 / 1_000_000.0

method now*(clock: RealClock): float64 =
  ## Returns current real time in milliseconds.
  rawClockNow()

method now*(clock: TestClock): float64 =
  ## Returns the fake clock's current time.
  clock.currentTime

method schedule*(clock: ClockBase; callback: proc(); delayMs: float64): int {.base.} =
  raise newException(ValueError, "clock backend has no timer source")

method cancel*(clock: ClockBase; id: int) {.base.} =
  raise newException(ValueError, "clock backend has no cancellation source")

method schedule*(clock: RealClock; callback: proc(); delayMs: float64): int =
  ## Always asynchronous, including zero-delay timers. Raw delegation avoids
  ## recursion when this clock is installed as the platform hook.
  inc clock.lastTimerId
  let id = clock.lastTimerId
  clock.platformTimers[id] = neTime.scheduleAtRaw(neTime.rawBackendAccess, max(0, ceil(delayMs).int), proc() =
    clock.platformTimers.del(id)
    when defined(isonimRecordable): beginDispatch(clock)
    else: inc clock.dispatchSequence
    callback())
  id

method cancel*(clock: RealClock; id: int) =
  if id in clock.platformTimers:
    neTime.cancelTimer(clock.platformTimers[id])
    clock.platformTimers.del(id)

method schedule*(clock: TestClock; callback: proc(); delayMs: float64): int =
  ## Schedules callback at currentTime + delayMs.
  ## Does NOT fire until advance() is called.
  let id = clock.nextId
  inc clock.nextId
  let targetTime = clock.currentTime + delayMs
  clock.scheduled.add(ScheduledCallback(id: id, time: targetTime, callback: callback))
  # Keep sorted by time
  clock.scheduled.sort(proc(a, b: ScheduledCallback): int = (if a.time == b.time: cmp(a.id, b.id) else: cmp(a.time, b.time)))
  return id

method cancel*(clock: TestClock; id: int) =
  ## Cancels a scheduled callback by ID.
  clock.scheduled.keepIf(proc(s: ScheduledCallback): bool = s.id != id)

proc advance*(clock: TestClock; durationMs: float64) =
  ## Advances time by durationMs. Fires all callbacks scheduled
  ## before the new time, in chronological order.
  ## This is instant -- no real time passes.
  let targetTime = clock.currentTime + durationMs
  while clock.scheduled.len > 0 and clock.scheduled[0].time <= targetTime:
    let cb = clock.scheduled[0]
    clock.scheduled.delete(0)
    clock.currentTime = cb.time
    when defined(isonimRecordable):
      if not cb.maintenance: beginDispatch(clock)
    else:
      inc clock.dispatchSequence
    cb.callback()
  clock.currentTime = targetTime

proc setTime*(clock: TestClock; t: float64) =
  ## Sets absolute time. Fires all due callbacks.
  let delta = t - clock.currentTime
  if delta > 0:
    advance(clock, delta)
  else:
    clock.currentTime = t

proc newTestClock*(startTime: float64 = 0.0): TestClock =
  TestClock(scripted: true, currentTime: startTime, scheduled: @[], nextId: 1)

proc newRealClock*(): RealClock =
  RealClock()

when defined(isonimRecordable):
  proc scheduleCheckpointMaintenance*(clock: ClockBase; cb: proc(); delayMs: float64): proc() =
    ## Private scheduler lane: never a real dispatch and never instrumented.
    if clock of TestClock:
      let test = TestClock(clock)
      let id = test.schedule(cb, delayMs)
      for scheduled in test.scheduled.mitems:
        if scheduled.id == id: scheduled.maintenance = true
      result = proc() = test.cancel(id)
    elif clock of RealClock:
      let handle = neTime.scheduleAtRaw(neTime.rawBackendAccess, max(0, ceil(delayMs).int), cb)
      result = proc() = neTime.cancelTimer(handle)
    else:
      raise newException(ValueError, "checkpoint maintenance requires RealClock or TestClock")
