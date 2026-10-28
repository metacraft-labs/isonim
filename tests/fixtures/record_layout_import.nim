## Deliberate import retains real uncalled constructor in artifact-free Node.
import std/jsffi
import isonim/core/private/record_layout
proc keep(w,r,o: JsObject): RecordLayoutPrimitives {.exportc: "rlUncalled".} = newInternalRecordLayout(w,r,o)
