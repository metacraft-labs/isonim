import std/jsffi
import nim_everywhere/raw_nondet
when defined(timerRaw):
  include ../../src/isonim/core/private/record_timers
else:
  import isonim/core/private/record_timers
when defined(timerReject):
  proc caller(t:RecordTimerPrimitives) {.tags:[].} =
    when defined(timerCancel):
      when defined(timerRaw): cancelRaw(t.linkage,0)
      else: cancelRecordTimeout(t,0)
    else:
      when defined(timerRaw): discard scheduleRaw(t.linkage,0,proc()=discard)
      else: discard recordTimeout(t,0,proc()=discard)
else:
  proc caller(t:RecordTimerPrimitives) {.tags:[RawNondet].} =
    when defined(timerCancel):
      when defined(timerRaw): cancelRaw(t.linkage,0)
      else: cancelRecordTimeout(t,0)
    else:
      when defined(timerRaw): discard scheduleRaw(t.linkage,0,proc()=discard)
      else: discard recordTimeout(t,0,proc()=discard)
proc keep(t:RecordTimerPrimitives) {.exportc:"rtEffect".} = caller(t)
