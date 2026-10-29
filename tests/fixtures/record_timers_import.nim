import std/jsffi
import isonim/core/private/record_timers
proc rtUncalled(w,r,o:JsObject):RecordTimerPrimitives {.exportc.} = newInternalRecordTimers(w,r,o)
