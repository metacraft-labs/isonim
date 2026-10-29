## Fixed actual native frame/timer/clock primitives; no selected Record backend.
import std/jsffi
import isonim/core/nondet
import isonim/core/private/[record_frames, record_timers, record_clocks]
let initialClock = currentClock
var frames: seq[RecordFramePrimitives]
var timers: seq[RecordTimerPrimitives]
var clocks: seq[RecordClockPrimitives]
proc init(w,r,o:JsObject):int {.exportc:"rfInit".} =
  let selected=currentClock
  let f=newInternalRecordFrames(w,r,o)
  frames.add(f)
  timers.add(newInternalRecordTimers(w,r,o))
  clocks.add(newInternalRecordClocks(w,r,o))
  doAssert selected==currentClock
  frames.high
proc request(index:int;cb:proc(ts:float64)):int {.exportc:"rfRequest".} = recordFrame(frames[index],cb)
proc cancel(index,handle:int) {.exportc:"rfCancel".} = cancelRecordFrame(frames[index],handle)
proc timer(index:int;delay:float64;cb:proc()):int {.exportc:"rfTimer".} = recordTimeout(timers[index],delay,cb)
proc cancelTimer(index,handle:int) {.exportc:"rfCancelTimer".} = cancelRecordTimeout(timers[index],handle)
proc mono(index:int):float64 {.exportc:"rfMono".} = recordMonotonicMs(clocks[index])
proc unchanged():bool {.exportc:"rfUnchanged".} = currentClock==initialClock
proc ordinary(cb:proc()):int {.exportc:"rfOrdinary".} = requestFrame(cb)
type FrameCustomClock = ref object of ClockBase
method now(c:FrameCustomClock):float64 = 321
proc select(kind:int) {.exportc:"rfSelect".} =
  case kind
  of 0: nondet.install(newRealBackend(1))
  of 1: nondet.install(newTestClock())
  of 2: nondet.install(FrameCustomClock())
  else: nondet.install(ClockBase(nil))
proc preserves(w,r,o:JsObject):bool {.exportc:"rfPreserves".} =
  let before=currentClock
  discard newInternalRecordFrames(w,r,o)
  before==currentClock
