## Real frame delivery observed with actual owner methods, not a Recording
## backend substitute. Include the existing real timer instrumentation to prove
## mixed task identity against the same Recorder without another Nim runtime.
include ./replay_timers
import isonim/core/nondet {.all.}
import std/[options, tables]

proc frameValue(value: float64) {.importjs: "globalThis.frameValue(#)".}
proc observation(observed: FrameObservation) =
  doAssert observed.browserTimestamp.isSome
  frameValue(observed.browserTimestamp.get())
proc observedFrame(cb: proc()): int =
  requestFrameObservation(proc(value: FrameObservation) =
    observation(value)
    cb())
proc frameMaps(): cstring {.exportc: "frameMaps".} =
  ($(%*{"selected":selected.frameCancels.len,
    "other":(if other == nil: 0 else: other.frameCancels.len)})).cstring
proc frameDisposed() {.exportc: "frameDisposed".} =
  discard observedFrame(proc() = trace("disposed"))
proc frameStart(mode: cstring) {.exportc: "frameStart".} =
  case $mode
  of "public":
    discard requestFrame(proc() = trace("public"))
  of "positive":
    let canceled = requestFrame(proc() = trace("CANCELED"))
    nondet.cancel(canceled)
    nondet.cancel(canceled)
    discard observedFrame(proc() =
      doAssert selected.frameCancels.len == 1
      trace("first")
      microtask(proc() = trace("micro"))
      let nested = requestFrame(proc() = trace("CANCELED nested"))
      nondet.cancel(nested)
      discard observedFrame(proc() = trace("nested")))
    discard observedFrame(proc() = trace("second"))
    trace("registered")
  of "same-frame-cancel":
    var canceled: int
    discard observedFrame(proc() =
      trace("cancel-inside")
      nondet.cancel(canceled))
    canceled = requestFrame(proc() = trace("CANCELED same-frame"))
  of "error":
    discard observedFrame(proc() =
      trace("error")
      raise newException(ValueError, "frame callback"))
    discard observedFrame(proc() = trace("after-error"))
  of "premature":
    discard observedFrame(proc() =
      try:
        disposeInternalReadReplay(selected)
        trace("WRONG disposed")
      except ValueError:
        trace("dispose-refused"))
    discard observedFrame(proc() = trace("after-refused"))
  of "mixed", "timer-first", "two":
    if $mode == "timer-first":
      discard nondet.scheduleAt(0, proc() = trace("timer"))
    saveHandle("first", observedFrame(proc() = trace("first")))
    if $mode != "timer-first":
      discard nondet.scheduleAt(0, proc() = trace("timer"))
    if $mode == "two":
      if selected of ObservedClock: other = ObservedClock()
      else: other = newInternalReadReplay(parseJson($suppliedContext()))
      install(other)
      saveHandle("second", observedFrame(proc() = trace("second")))
      install(selected)
  of "pending", "cancel-mismatch", "task-kind":
    retainedHandle = observedFrame(proc() = trace("required"))
  of "after-fire":
    retainedHandle = observedFrame(proc() = trace("fired"))
  of "switch-nil", "switch-test", "switch-real", "switch-custom":
    discard observedFrame(proc() = trace("owned-after-switch"))
    case $mode
    of "switch-nil": install(ClockBase(nil))
    of "switch-test": install(newTestBackend())
    of "switch-real": install(newRealBackend(731))
    else: install(TimerCustomClock())
  else:
    raise newException(ValueError, "unknown frame test mode")
