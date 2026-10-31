## Actual owner upload linkage. No backend is selected and no log is fabricated.
import std/jsffi
import isonim/core/private/record_upload
var uploads: seq[RecordUploadPrimitives]
proc init(w,o,options:JsObject):int {.exportc:"ruInit".} =
  uploads.add(newInternalRecordUpload(w,o,options))
  uploads.high
proc sink(i:int):JsObject {.exportc:"ruSink".} = recordUploadSink(uploads[i])
proc attach(i:int;r:JsObject) {.exportc:"ruAttach".} = attachRecordUploadRecorder(uploads[i],r)
proc complete(i:int):JsObject {.exportc:"ruComplete".} = recordUploadCompletion(uploads[i])
proc consent(i:int;callback:JsObject) {.exportc:"ruConsent".} = recordUploadConsent(uploads[i],callback)
proc flush(i:int) {.exportc:"ruFlush".} = recordUploadFlush(uploads[i])
proc status(i:int):JsObject {.exportc:"ruStatus".} = recordUploadStatus(uploads[i])
import isonim/core/private/record_clocks
proc clock(w,r,o:JsObject):float64 {.exportc:"ruClock".} =
  recordMonotonicMs(newInternalRecordClocks(w,r,o))
