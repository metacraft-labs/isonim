## Clock abstraction for pluggable time in IsoNim.
##
## RealClock uses actual system/monotonic time.
## TestClock allows manual time advancement for deterministic testing.

import std/[algorithm, sequtils]
when not defined(js):
  import std/monotimes

type
  ScheduledCallback = object
    id: int
    time: float64      ## Absolute time in ms when callback should fire
    callback: proc()

  ClockBase* = ref object of RootObj
    ## Base type for all clocks.

  RealClock* = ref object of ClockBase
    ## Production clock using real system time.

  TestClock* = ref object of ClockBase
    ## Deterministic clock for testing.
    ## Time only advances via explicit advance() or setTime() calls.
    currentTime*: float64
    scheduled: seq[ScheduledCallback]  ## Sorted by time
    nextId: int

# Current global clock (thread-local)
var currentClock* {.threadvar.}: ClockBase

proc now*(clock: RealClock): float64 =
  ## Returns current real time in milliseconds.
  when defined(js):
    {.emit: "result = performance.now();".}
  else:
    let t = getMonoTime()
    result = t.ticks.float64 / 1_000_000.0

proc now*(clock: TestClock): float64 =
  ## Returns the fake clock's current time.
  clock.currentTime

proc schedule*(clock: RealClock; callback: proc(); delayMs: float64): int =
  ## Schedules callback after delayMs using real timer.
  ## Returns callback ID for cancellation.
  ## For now, executes immediately (real scheduling comes with async integration).
  callback()
  return 0

proc schedule*(clock: TestClock; callback: proc(); delayMs: float64): int =
  ## Schedules callback at currentTime + delayMs.
  ## Does NOT fire until advance() is called.
  let id = clock.nextId
  inc clock.nextId
  let targetTime = clock.currentTime + delayMs
  clock.scheduled.add(ScheduledCallback(id: id, time: targetTime, callback: callback))
  # Keep sorted by time
  clock.scheduled.sort(proc(a, b: ScheduledCallback): int = cmp(a.time, b.time))
  return id

proc cancel*(clock: TestClock; id: int) =
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
  TestClock(currentTime: startTime, scheduled: @[], nextId: 1)

proc newRealClock*(): RealClock =
  RealClock()
