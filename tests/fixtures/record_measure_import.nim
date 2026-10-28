import std/jsffi
import isonim/core/private/record_measure
proc rqUncalled() {.exportc.} =
  discard newInternalRecordMeasure(default(JsObject),default(JsObject),default(JsObject))
proc rqEarly(w,r,o:JsObject) {.exportc.} =
  discard newInternalRecordMeasure(w,r,o)
echo "private Record measure lazy import"
