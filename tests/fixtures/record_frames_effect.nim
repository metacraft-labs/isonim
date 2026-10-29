import std/jsffi
import nim_everywhere/raw_nondet
when defined(frameRaw):
  include ../../src/isonim/core/private/record_frames
else:
  import isonim/core/private/record_frames
when defined(frameReject):
  proc caller(f:RecordFramePrimitives) {.tags:[].} =
    when defined(frameCancel):
      when defined(frameRaw): cancelRaw(f.linkage,0)
      else: cancelRecordFrame(f,0)
    else:
      when defined(frameRaw): discard requestRaw(f.linkage,proc(ts:float64)=discard)
      else: discard recordFrame(f,proc(ts:float64)=discard)
else:
  proc caller(f:RecordFramePrimitives) {.tags:[RawNondet].} =
    when defined(frameCancel):
      when defined(frameRaw): cancelRaw(f.linkage,0)
      else: cancelRecordFrame(f,0)
    else:
      when defined(frameRaw): discard requestRaw(f.linkage,proc(ts:float64)=discard)
      else: discard recordFrame(f,proc(ts:float64)=discard)
proc keep(f:RecordFramePrimitives) {.exportc:"rfEffect".} = caller(f)
