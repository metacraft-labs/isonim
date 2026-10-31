import std/jsffi
import nim_everywhere/raw_nondet
import isonim/core/private/record_refusals
when defined(refusalsReject):
  proc limited(c: JsObject) {.tags: [].} = installInternalRecordRefusals(c)
else:
  proc limited(c: JsObject) {.tags: [RawNondet].} = installInternalRecordRefusals(c)
proc use(c: JsObject) {.exportc: "rfEffect".} = limited(c)
