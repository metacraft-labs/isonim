import std/jsffi
import nim_everywhere/raw_nondet
when defined(recordMediaRaw):
  include ../../src/isonim/core/private/record_media
else:
  import isonim/core/private/record_media
when defined(recordMediaReject):
  proc caller(media: RecordMediaPrimitives):bool {.tags:[].} =
    when defined(recordMediaRaw): matchesRaw(media.linkage,cstring"all")
    else: media.recordMediaMatches("all")
else:
  proc caller(media: RecordMediaPrimitives):bool {.tags:[RawNondet].} =
    when defined(recordMediaRaw): matchesRaw(media.linkage,cstring"all")
    else: media.recordMediaMatches("all")
proc keep(media: RecordMediaPrimitives):bool {.exportc:"rmEffect".} = caller(media)
