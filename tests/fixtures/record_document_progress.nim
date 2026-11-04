## Real private production entry points; the browser supplies an actual owner.
import std/jsffi
import isonim/core/private/[record_document_progress, record_clocks, record_upload]
proc attach(w,r,o:JsObject) {.exportc:"dpAttach".} = attachInternalRecordDocumentProgress(w,r,o)
proc clock(w,r,o:JsObject):float64 {.exportc:"dpClock".} = recordMonotonicMs(newInternalRecordClocks(w,r,o))
var upload:RecordUploadPrimitives
proc init(w,o,options:JsObject):JsObject {.exportc:"dpUpload".} =
  upload=newInternalRecordUpload(w,o,options)
  recordUploadSink(upload)
proc pair(r:JsObject) {.exportc:"dpPair".} = attachRecordUploadRecorder(upload,r)
proc completion():JsObject {.exportc:"dpCompletion".} = recordUploadCompletion(upload)
proc consent(callback:JsObject) {.exportc:"dpConsent".} = recordUploadConsent(upload,callback)

# Actual ordinary framework clocks remain selected independently of CT owner work.
import std/json
import isonim/core/nondet
import nim_everywhere/[fake_time, backend]
import nim_everywhere/time as neTime
type DocumentCountingClock = ref object of ClockBase
var reads,scheduled,cancelled,fired:int
method now(c:DocumentCountingClock):float64 =
  inc reads
  321.0
method schedule(c:DocumentCountingClock;cb:proc();delay:float64):int =
  inc scheduled
  1
method cancel(c:DocumentCountingClock;id:int) = inc cancelled
var fake:FakeAsyncContext
var selected:ClockBase
var selectedHook:PlatformBackendHook
proc select(kind:cstring) {.exportc:"dpSelect".} =
  case $kind
  of "real": install(newRealBackend(1))
  of "test": install(newTestBackend(123))
  of "custom": install(DocumentCountingClock())
  of "fake":
    install(newTestBackend(123))
    fake=newFakeAsyncContext()
    fake.install()
    discard neTime.scheduleAt(2,proc() = inc fired)
  else: raise newException(ValueError,"unknown clock selection")
  selected=currentClock
  selectedHook=currentBackendHook
proc state():cstring {.exportc:"dpClockState".} =
  var value = %*{"same":currentClock==selected,"hookSame":currentBackendHook==selectedHook,"reads":reads,"scheduled":scheduled,"cancelled":cancelled,"fired":fired,"sequence": $currentClock.dispatchSequence}
  if fake!=nil:
    value["fakeNow"] = %fake.now()
    value["fakeInstalled"] = %(currentFakeContext()==fake)
    value["globalFakeNow"] = %neTime.monotonicNowMs()
  ($value).cstring
proc advance() {.exportc:"dpAdvanceFake".} = fake.advance(2)
