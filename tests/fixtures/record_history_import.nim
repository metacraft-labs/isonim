## Deliberately linked constructor remains uncalled under windowless import.
import std/jsffi
import isonim/core/private/record_history
proc hUncalled(w,r,o:JsObject) {.exportc.} =
  discard newInternalRecordHistory(w,r,o)
