## Actual private production calls and an independent ordinary public authority.
## Integer bytes avoid converting returned Nim strings through the witness.
import std/[json, jsffi]
import isonim/core/nondet
import isonim/core/private/[record_storage, record_clocks]
var storage: RecordStoragePrimitives
var clocks: RecordClockPrimitives
proc key(defaultKey: bool; raw: cstring): string =
  if defaultKey:
    var empty: string
    return empty
  $raw
proc units(value: cstring): JsonNode =
  proc describe(v: cstring): cstring {.importjs: "(function(v){return JSON.stringify({type:typeof v,units:v===null?null:Array.from({length:v.length},(_,i)=>v.charCodeAt(i))});})(#)".}
  parseJson($describe(value))
proc snapshot(value: string; present: bool): cstring =
  var bytes = newJArray()
  for ch in value: bytes.add(%ord(ch))
  ($(%*{"bytes":bytes,"projection":units(value.cstring),"present":present})).cstring
proc stKey(defaultKey: bool; raw: cstring): cstring {.exportc.} =
  ($units(key(defaultKey,raw).cstring)).cstring
proc stInit(w,r,o:JsObject) {.exportc.} =
  let previous=currentClock
  storage=newInternalRecordStorage(w,r,o)
  clocks=newInternalRecordClocks(w,r,o)
  doAssert currentClock==previous
proc stMinimal(w,r,o:JsObject) {.exportc.} =
  let previous=currentClock
  storage=newInternalRecordStorage(w,r,o)
  doAssert currentClock==previous
proc stClock():float64 {.exportc.} = recordMonotonicMs(clocks)
proc stRead(kind:cint; defaultKey:bool; raw:cstring):cstring {.exportc.} =
  if kind==3: snapshot(recordCookieGet(storage),true)
  else:
    let value=recordStorageGet(storage,key(defaultKey,raw))
    snapshot(value.value,value.present)
proc stAuthority(kind:cint; defaultKey:bool; raw:cstring):cstring {.exportc.} =
  snapshot((if kind==3:cookieGet() else:storageGet(key(defaultKey,raw))),true)
type StorageCustomClock=ref object of ClockBase
proc stSelection(kind:cint;w,r,o:JsObject):bool {.exportc.} =
  case kind
  of 0: install(newRealBackend(1))
  of 1: install(newTestClock())
  of 2: install(StorageCustomClock())
  else: install(ClockBase(nil))
  let before=currentClock
  discard newInternalRecordStorage(w,r,o)
  currentClock==before
