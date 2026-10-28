## Deliberate fixed viewport preparation, not a selected Recording backend.
## Importing this module never loads an owner, reads layout or patches a global.
when defined(js) and defined(isonimInternalRecordLayout):
  import std/jsffi
  import nim_everywhere/raw_nondet

  type
    RecordViewportObservation* = object
      width*, height*: float64
    RecordLayoutPrimitives* = ref object
      linkage: JsObject

  proc prepare(window, recorder, originals: JsObject): JsObject {.importjs: "(function(w,r,o){var m=require('\\x40codetracer/boundary-shim/dist/browser/recorder.js');if(!w||w.window!==w||typeof w.Window!=='function'||!(w instanceof w.Window)||!(r instanceof m.Recorder)||!o||!(o.layoutGetters instanceof Map))throw new TypeError('internal Record layout requires actual Window, captured originals and actual Recorder');var a=o.layoutGetters.get('innerWidth'),b=o.layoutGetters.get('innerHeight');if(!a||!a.descriptor||typeof a.descriptor.get!=='function'||!b||!b.descriptor||typeof b.descriptor.get!=='function')throw new TypeError('internal Record layout requires captured viewport getters');return Object.freeze({window:w,rec:r,width:a.descriptor.get,height:b.descriptor.get});})(#,#,#)".}

  proc newInternalRecordLayout*(window, recorder, originals: JsObject): RecordLayoutPrimitives =
    ## The trusted caller captures originals before patching and owns start/end.
    ## Matching realm/capture identity is a precondition, not a new native brand.
    RecordLayoutPrimitives(linkage: prepare(window, recorder, originals))

  proc viewportRaw(linkage: JsObject): RecordViewportObservation {.importjs: "(function(c){var width=c.width.call(c.window);c.rec.guard(function(){c.rec.emit('LayoutRead',{target:'win',prop:'innerWidth',value:JSON.stringify(width===undefined?null:width)});});var height=c.height.call(c.window);c.rec.guard(function(){c.rec.emit('LayoutRead',{target:'win',prop:'innerHeight',value:JSON.stringify(height===undefined?null:height)});});return {width:width,height:height};})(#)", tags: [RawNondet].}

  proc recordViewport*(layout: RecordLayoutPrimitives): RecordViewportObservation {.tags: [RawNondet].} =
    ## Log each successful original before the next read, as the owner does.
    ## Native throws precede that read's logging; owner faults preserve values.
    viewportRaw(layout.linkage)
