## Actual private fixed timers; no selected Recording clock is introduced.
import std/jsffi
import isonim/core/nondet
import isonim/core/private/[record_timers, record_clocks]
let initialClock = currentClock
var timers: seq[RecordTimerPrimitives]
var clocks: seq[RecordClockPrimitives]
proc init(window, recorder, originals: JsObject): int {.exportc: "rtInit".} =
  let selected = currentClock
  timers.add(newInternalRecordTimers(window, recorder, originals))
  clocks.add(newInternalRecordClocks(window, recorder, originals))
  doAssert selected == currentClock
  timers.high
proc schedule(index: int; delay: float64; cb: proc()): int {.exportc: "rtSchedule".} =
  recordTimeout(timers[index], delay, cb)
proc cancel(index, handle: int) {.exportc: "rtCancel".} =
  cancelRecordTimeout(timers[index], handle)
proc mono(index: int): float64 {.exportc: "rtMono".} = recordMonotonicMs(clocks[index])
var ordinaryClock: RealClock
proc ordinary(delay: float64; cb: proc()): int {.exportc: "rtOrdinary".} =
  ordinaryClock = newRealClock()
  ordinaryClock.schedule(cb, delay)
proc selected(): bool {.exportc: "rtUnselected".} = currentClock == initialClock

type FixedCustomClock = ref object of ClockBase
method now(c:FixedCustomClock):float64 = 321
var selectedTest: TestClock
proc select(kind:int) {.exportc:"rtSelect".} =
  case kind
  of 0: nondet.install(newRealBackend(1))
  of 1:
    selectedTest = newTestClock()
    nondet.install(selectedTest)
  of 2: nondet.install(FixedCustomClock())
  else: nondet.install(ClockBase(nil))
proc preserves(w,r,o:JsObject):bool {.exportc:"rtPreserves".} =
  let before=currentClock
  discard newInternalRecordTimers(w,r,o)
  before == currentClock
proc publicEvery(delay:float64;cb:proc()):int {.exportc:"rtEvery".} = scheduleEvery(delay,cb)
proc publicCancel(id:int) {.exportc:"rtPublicCancel".} = nondet.cancel(id)
proc advance(ms:float64) {.exportc:"rtAdvance".} = selectedTest.advance(ms)

proc ordinaryDispatch():int {.exportc:"rtOrdinaryDispatch".} = ordinaryClock.dispatchSequence.int
