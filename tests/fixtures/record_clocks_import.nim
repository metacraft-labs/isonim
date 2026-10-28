## Keep real constructor code, but deliberately never construct or select it.
import std/jsffi
import isonim/core/private/record_clocks
proc deliberate(window, recorder, originals: JsObject): RecordClockPrimitives
    {.exportc: "rcDeliberateUncalled".} =
  newInternalRecordClocks(window, recorder, originals)
echo "private Record constructor retained but uncalled"
