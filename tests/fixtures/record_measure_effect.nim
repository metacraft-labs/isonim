import std/jsffi
import nim_everywhere/raw_nondet
when defined(recordMeasureRaw) or defined(recordMeasureIid):
  include ../../src/isonim/core/private/record_measure
else:
  import isonim/core/private/record_measure
when defined(recordMeasureReject):
  proc caller(m:RecordMeasurePrimitives;el:JsObject):JsObject {.tags:[].} =
    when defined(recordMeasureIid):
      discard elementIid(m.linkage,el)
      default(JsObject)
    elif defined(recordMeasureRaw): rectRaw(m.linkage,el,cstring"iid")
    else: m.recordElementRect(el)
else:
  proc caller(m:RecordMeasurePrimitives;el:JsObject):JsObject {.tags:[RawNondet].} =
    when defined(recordMeasureIid):
      discard elementIid(m.linkage,el)
      default(JsObject)
    elif defined(recordMeasureRaw): rectRaw(m.linkage,el,cstring"iid")
    else: m.recordElementRect(el)
proc rqEffect(m:RecordMeasurePrimitives;el:JsObject):JsObject {.exportc.} = caller(m,el)
