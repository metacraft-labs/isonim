## Direct raw and exported operation ceilings, with separate raw/export/combined
## annotation-loss copies proving each effect boundary independently.
import std/jsffi
import nim_everywhere/raw_nondet
when defined(storageRaw):include ../../src/isonim/core/private/record_storage
else:import isonim/core/private/record_storage
template operation(s:RecordStoragePrimitives)=
  when defined(storageCookie):
    when defined(storageRaw):discard cookieRaw(s.linkage)
    else:discard recordCookieGet(s)
  else:
    when defined(storageRaw):discard localRaw(s.linkage,"key")
    else:discard recordStorageGet(s,"key")
when defined(storageReject):
  proc caller(s:RecordStoragePrimitives) {.tags:[].}=operation(s)
else:
  proc caller(s:RecordStoragePrimitives) {.tags:[RawNondet].}=operation(s)
proc stEffect(s:RecordStoragePrimitives) {.exportc.}=caller(s)
