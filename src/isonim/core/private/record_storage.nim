## Fixed captured-native reads, retaining the ordinary stock Nim observation.
## Import is inert; the caller owns matching original capture and owner lifetime.
when defined(js) and defined(isonimInternalRecordStorage):
  import std/[jsffi, json]
  import nim_everywhere/raw_nondet

  type
    RecordStorageObservation* = object
      present*: bool
      value*: string
    RecordStoragePrimitives* = ref object
      linkage: JsObject

  proc prepare(window, recorder, originals: JsObject): JsObject {.importjs: "(function(w,r,o){var m=require('\\x40codetracer/boundary-shim/dist/browser/recorder.js');if(!w||w.window!==w||typeof w.Window!=='function'||!(w instanceof w.Window)||!w.document||!(w.document instanceof w.Document)||w.document.defaultView!==w||!(r instanceof m.Recorder)||!o||!(o.storageAreas instanceof Map))throw new TypeError('internal Record storage requires actual Window, Document, Recorder and captured originals');var a=o.storageAreas.get('localStorage'),b=o.cookie;if(!a||!a.descriptor||typeof a.descriptor.get!=='function'||typeof o.storageGetItem!=='function'||!b||!b.descriptor||typeof b.descriptor.get!=='function')throw new TypeError('internal Record storage requires captured area, getItem and cookie getters');return Object.freeze({window:w,document:w.document,rec:r,area:a.descriptor.get,item:o.storageGetItem,cookie:b.descriptor.get});})(#,#,#)".}

  proc newInternalRecordStorage*(window, recorder, originals: JsObject): RecordStoragePrimitives =
    ## Structural checks cannot authenticate capture provenance or owner level.
    ## Those remain trusted-caller preconditions; no native area/cookie is read.
    RecordStoragePrimitives(linkage: prepare(window, recorder, originals))

  proc localRaw(linkage: JsObject; key: cstring): JsObject {.importjs: "(function(c,k){var s=c.area.call(c.window);return c.item.call(s,k);})(#,#)", tags: [RawNondet].}
  proc cookieRaw(linkage: JsObject): JsObject {.importjs: "(function(c){return c.cookie.call(c.document);})(#)", tags: [RawNondet].}
  proc serialize(value: JsObject): cstring {.importjs: "JSON.stringify(#)".}
  proc ordinaryObservation(value: JsObject): JsonNode =
    # Stock parseJson's cross-target declaration carries ReadIOEffect. Its JS
    # implementation is JSON.parse plus stock conversion, with no IO. Narrow
    # only that nominal tag, as the ordinary nondet facade already does; native
    # observations remain explicit/inferred RawNondet at their actual calls.
    {.cast(tags: []).}:
      parseJson($serialize(value))
  proc guarded(linkage: JsObject; logging: proc()) {.importjs: "#.rec.guard(#)".}
  proc emitLocal(linkage: JsObject; key: cstring; present: bool; value: cstring) {.importjs: "(function(c,k,p,v){c.rec.emit('StorageRead',{area:1,key:String(k),present:p?1:0,value:p?v:''});})(#,#,#,#)".}
  proc emitCookie(linkage: JsObject; value: cstring) {.importjs: "(function(c,v){c.rec.emit('StorageRead',{area:3,key:'',present:1,value:v});})(#,#)".}

  proc recordStorageGet*(storage: RecordStoragePrimitives; key: string): RecordStorageObservation {.tags: [RawNondet].} =
    let nativeKey = key.cstring
    let raw = localRaw(storage.linkage, nativeKey)
    # Preserve ordinary JSON/string projection and its failures outside guard.
    let observed = ordinaryObservation(raw)
    let present = observed.kind != JNull
    let value = observed.getStr()
    guarded(storage.linkage, proc() =
      # Logging-only conversion MUST execute in the guarded closure body.
      emitLocal(storage.linkage, nativeKey, present, value.cstring))
    RecordStorageObservation(present: present, value: value)

  proc recordCookieGet*(storage: RecordStoragePrimitives): string {.tags: [RawNondet].} =
    let raw = cookieRaw(storage.linkage)
    let observed = ordinaryObservation(raw)
    let value = observed.getStr()
    guarded(storage.linkage, proc() =
      emitCookie(storage.linkage, value.cstring))
    value
