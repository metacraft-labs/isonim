## Captured-native history with ordinary stock observation before guarded logging.
## Import is inert. Matching originals and configured owner lifetime are trusted.
when defined(js) and defined(isonimInternalRecordHistory):
  import std/[jsffi, options]
  import nim_everywhere/raw_nondet

  type RecordHistoryPrimitives* = ref object
    linkage: JsObject

  proc prepare(window, recorder, originals: JsObject): JsObject {.importjs: "(function(w,r,o){var m=require('\\x40codetracer/boundary-shim/dist/browser/recorder.js');if(!w||w.window!==w||typeof w.Window!=='function'||!(w instanceof w.Window)||!(r instanceof m.Recorder)||!o||typeof o.pushState!=='function'||typeof o.replaceState!=='function')throw new TypeError('internal Record history requires actual Window, Recorder and captured history originals');return Object.freeze({window:w,rec:r,push:o.pushState,replace:o.replaceState});})(#,#,#)".}
  proc newInternalRecordHistory*(window, recorder, originals: JsObject): RecordHistoryPrimitives =
    ## Structural admission cannot authenticate realm capture or owner policy.
    RecordHistoryPrimitives(linkage: prepare(window, recorder, originals))

  proc mutate(linkage: JsObject; push: bool; url: cstring): cstring {.importjs: "(function(c,p,u){var h=c.window.history;(p?c.push:c.replace).call(h,null,'',u);try{var l=c.window.location,v=l&&l.href;return typeof v==='string'?v:null;}catch(e){return null;}})(#,#,#)", tags: [RawNondet].}
  proc guarded(linkage: JsObject; logging: proc()) {.importjs: "#.rec.guard(#)".}
  proc unavailable() {.importjs: "(function(){throw new Error('internal Record history reflected URL unavailable');})()".}
  proc emitNavigation(linkage: JsObject; kind: int; url: cstring) {.importjs: "#.rec.emit('Navigation',{kind:#,url:#})".}

  proc record(history: RecordHistoryPrimitives; push: bool;
      url: string): Option[string] {.tags: [RawNondet].} =
    let nativeArgument = url.cstring
    let raw = mutate(history.linkage, push, nativeArgument)
    # This is direct stock conversion, not the storage JSON frontend. Keep P
    # outside the metadata catch and actual owner's logging-fault boundary.
    let observed = if raw.isNil: none(string) else: some($raw)
    guarded(history.linkage, proc() =
      if observed.isNone:
        unavailable()
      else:
        emitNavigation(history.linkage, (if push: 1 else: 2), observed.get().cstring))
    observed

  proc recordPushState*(history: RecordHistoryPrimitives;
      url: string): Option[string] {.tags: [RawNondet].} =
    record(history, true, url)

  proc recordReplaceState*(history: RecordHistoryPrimitives;
      url: string): Option[string] {.tags: [RawNondet].} =
    record(history, false, url)
