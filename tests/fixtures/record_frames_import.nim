import std/jsffi
import isonim/core/private/record_frames
proc rfUncalled(w,r,o:JsObject):RecordFramePrimitives {.exportc.} = newInternalRecordFrames(w,r,o)
