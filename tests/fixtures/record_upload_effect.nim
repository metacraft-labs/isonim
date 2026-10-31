import std/jsffi
import nim_everywhere/raw_nondet
when defined(uploadRaw):
  include ../../src/isonim/core/private/record_upload
else:
  import isonim/core/private/record_upload
const uploadBoundary {.intdefine.} = 0
# Every operation has a positive caller and the same exact forbidden caller.
# Including the production module makes raw-helper effect inference observable.
template operation(u,x:untyped) =
  when uploadBoundary == 0:
    when defined(uploadRaw): discard prepare(x,x,x)
    else: discard newInternalRecordUpload(x,x,x)
  elif uploadBoundary == 1:
    when defined(uploadRaw): discard sinkRaw(u.linkage)
    else: discard recordUploadSink(u)
  elif uploadBoundary == 2:
    when defined(uploadRaw): attachRaw(u.linkage,x)
    else: attachRecordUploadRecorder(u,x)
  elif uploadBoundary == 3:
    when defined(uploadRaw): discard completionRaw(u.linkage)
    else: discard recordUploadCompletion(u)
  elif uploadBoundary == 4:
    when defined(uploadRaw): consentRaw(u.linkage,x)
    else: recordUploadConsent(u,x)
  elif uploadBoundary == 5:
    when defined(uploadRaw): flushRaw(u.linkage)
    else: recordUploadFlush(u)
  elif uploadBoundary == 6:
    when defined(uploadRaw): discard statusRaw(u.linkage)
    else: discard recordUploadStatus(u)
when defined(uploadReject):
  proc caller(u:RecordUploadPrimitives;x:JsObject) {.tags:[].} = operation(u,x)
else:
  proc caller(u:RecordUploadPrimitives;x:JsObject) {.tags:[RawNondet].} = operation(u,x)
proc keep(u:RecordUploadPrimitives;x:JsObject) {.exportc:"ruEffect".} = caller(u,x)
