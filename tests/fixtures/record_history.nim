## Real captured production and independent ordinary observation; witnesses use
## integer Nim bytes. Inputs are prepared before separately armed stock faults.
import std/[json, options, jsffi]
import isonim/core/nondet {.all.}
import isonim/core/private/[record_history, record_clocks]
var history: RecordHistoryPrimitives
var clocks: RecordClockPrimitives
var input: string
proc hSet(defaultInput: bool; raw: cstring) {.exportc.} =
  if defaultInput:
    var empty: string
    input = empty
  else: input = $raw
proc snapshot(value: Option[string]): cstring =
  var bytes = newJArray()
  if value.isSome:
    for ch in value.get(): bytes.add(%ord(ch))
  ($(%*{"present": value.isSome, "bytes": bytes,
    "projection": (if value.isSome: $value.get().cstring else: "")})).cstring
proc hInit(w,r,o: JsObject) {.exportc.} =
  history = newInternalRecordHistory(w,r,o)
proc hClocks(w,r,o: JsObject) {.exportc.} =
  clocks = newInternalRecordClocks(w,r,o)
proc hClock(): float64 {.exportc.} = recordMonotonicMs(clocks)
proc hRead(push: bool): cstring {.exportc.} =
  snapshot(if push: recordPushState(history,input) else: recordReplaceState(history,input))
proc hAuthority(push: bool): cstring {.exportc.} =
  snapshot(historyObservation((if push: "pushState" else: "replaceState"),input).browserUrl)
proc hPublic(push: bool) {.exportc.} =
  if push: pushState(input)
  else: replaceState(input)
type HistoryCustomClock = ref object of ClockBase
proc hSelection(kind:cint;w,r,o:JsObject):bool {.exportc.} =
  case kind
  of 0: install(newRealBackend(1))
  of 1: install(newTestClock())
  of 2: install(HistoryCustomClock())
  else: install(ClockBase(nil))
  let before=currentClock
  discard newInternalRecordHistory(w,r,o)
  currentClock==before
