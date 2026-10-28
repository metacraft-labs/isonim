## Deliberate one-shot media observation, not a selected Recording backend.
## The boolean seam exposes no MediaQueryList or change-event subscription.
when defined(js) and defined(isonimInternalRecordLayout):
  import std/jsffi
  import nim_everywhere/raw_nondet

  type RecordMediaPrimitives* = ref object
    linkage: JsObject

  proc prepare(window, recorder, originals: JsObject): JsObject {.importjs: "(function(w,r,o){var m=require('\\x40codetracer/boundary-shim/dist/browser/recorder.js');if(!w||w.window!==w||typeof w.Window!=='function'||!(w instanceof w.Window)||!(r instanceof m.Recorder)||!o||typeof o.matchMedia!=='function'||!o.mediaQueryMatches||!o.mediaQueryMatches.descriptor||typeof o.mediaQueryMatches.descriptor.get!=='function')throw new TypeError('internal Record media requires actual Window, captured originals and actual Recorder');return Object.freeze({window:w,rec:r,match:o.matchMedia,matches:o.mediaQueryMatches.descriptor.get});})(#,#,#)".}

  proc newInternalRecordMedia*(window, recorder, originals: JsObject): RecordMediaPrimitives =
    ## Caller captures originals before patching and owns Recorder start/end.
    ## Matching realm/capture identity is a precondition, not an invented brand.
    RecordMediaPrimitives(linkage: prepare(window, recorder, originals))

  proc matchesRaw(linkage: JsObject; query: cstring): bool {.importjs: "(function(c,q){var list=c.match.call(c.window,q);var value=c.matches.call(list);c.rec.guard(function(){var media='';try{media=String(list.media??'');}catch{}c.rec.emit('LayoutRead',{target:'win',prop:'matchMedia:'+media,value:JSON.stringify({matches:value})});});return value;})(#,#)", tags: [RawNondet].}

  proc recordMediaMatches*(media: RecordMediaPrimitives; query: string): bool {.tags: [RawNondet].} =
    ## Native observation precedes guarded serialization, matching owner policy.
    ## Native throws escape unchanged; recorder faults preserve successful values.
    matchesRaw(media.linkage, query.cstring)
