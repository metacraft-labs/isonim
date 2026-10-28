import std/jsffi
import isonim/core/private/record_media
proc uncalled() {.exportc:"rmUncalled".} =
  discard newInternalRecordMedia(default(JsObject),default(JsObject),default(JsObject))
echo "private Record media lazy import"
