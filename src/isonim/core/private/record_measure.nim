## Fixed native geometry for an existing registered IID, not a selected backend.
## Import/constructor never initialize renderer identity state or read geometry.
when defined(js) and defined(isonimInternalRecordLayout) and defined(isonimStableIds):
  import std/jsffi
  import nim_everywhere/raw_nondet
  import ./iid_lookup

  type RecordMeasurePrimitives* = ref object
    linkage: JsObject

  proc prepare(window, recorder, originals: JsObject): JsObject {.importjs: "(function(w,r,o){var m=require('\\x40codetracer/boundary-shim/dist/browser/recorder.js');if(!w||w.window!==w||typeof w.Window!=='function'||!(w instanceof w.Window)||!(r instanceof m.Recorder)||!o||typeof o.getBoundingClientRect!=='function')throw new TypeError('internal Record measure requires actual Window, captured originals and actual Recorder');return Object.freeze({window:w,rec:r,rect:o.getBoundingClientRect});})(#,#,#)".}

  proc newInternalRecordMeasure*(window, recorder, originals: JsObject): RecordMeasurePrimitives =
    ## Caller owns capture-before-patch in the matching realm and Recorder life.
    RecordMeasurePrimitives(linkage: prepare(window, recorder, originals))

  proc elementIid(linkage, el: JsObject): cstring {.importjs: "(function(c,e){if(!(e instanceof c.window.Element))throw new TypeError('internal Record measure requires a registered element');var iid=e.getAttribute('data-iid');if(typeof iid!=='string'||!iid)throw new TypeError('internal Record measure requires a stable iid');return iid;})(#,#)", tags: [RawNondet].}
  proc sameElement(el, resolved: JsObject): bool {.importjs: "(# === #)".}

  proc rectRaw(linkage, el: JsObject; iid: cstring): JsObject {.importjs: "(function(c,e,iid){var r=c.rect.call(e);var value={x:r.x,y:r.y,width:r.width,height:r.height,top:r.top,right:r.right,bottom:r.bottom,left:r.left};c.rec.guard(function(){c.rec.emit('LayoutRead',{target:'iid:'+iid,prop:'getBoundingClientRect',value:JSON.stringify(value)});});return r;})(#,#,#)", tags: [RawNondet].}

  proc recordElementRect*(measurement: RecordMeasurePrimitives; el: JsObject): JsObject {.tags: [RawNondet].} =
    ## Admit only the exact existing M6 claim before native geometry. Lookup's
    ## validation, weak dereference and original failures remain renderer-owned.
    let iid = elementIid(measurement.linkage, el)
    if not sameElement(el, resolveIidLookup(iid)):
      raise newException(ValueError, "internal Record measure requires the registered iid element")
    ## Native result/field reads precede guarded serialization, matching owner
    ## geometry policy. Return the original DOMRect even after recorder faults.
    rectRaw(measurement.linkage, el, iid)
