## Uncalled constructor must not eagerly require owner or native browser globals.
import std/jsffi
import isonim/core/private/record_storage
proc stUncalled(w,r,o:JsObject):RecordStoragePrimitives {.exportc.}=
  newInternalRecordStorage(w,r,o)
