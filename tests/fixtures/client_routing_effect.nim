## Actual inferred facade effects and the direct raw context validator tag.
import isonim/web/web_renderer {.all.}
import isonim/web/dom_api
import nim_everywhere/raw_nondet
import std/times
when defined(rejectFactory):
  proc caller(c:InternalClientCreationOrdinals):InternalClientRenderer {.tags:[].} = newInternalClientRenderer(c)
  discard caller(newInternalClientCreationOrdinals())
elif defined(rejectRoute):
  proc caller(r:InternalClientRenderer):Element {.tags:[TimeEffect].} = r.createElement("div")
  discard caller(newInternalClientRenderer(newInternalClientCreationOrdinals()))
elif defined(rejectValidator):
  proc caller(c:InternalClientCreationOrdinals) {.tags:[].} = requireClientContext(c)
  caller(newInternalClientCreationOrdinals())
elif defined(rawOnly):
  proc caller(r:InternalClientRenderer):Element {.tags:[RawNondet].} = r.createElement("div")
  discard caller(newInternalClientRenderer(newInternalClientCreationOrdinals()))
else:
  proc caller(r:InternalClientRenderer):Element {.tags:[TimeEffect,RawNondet].} = r.createElement("div")
  discard caller(newInternalClientRenderer(newInternalClientCreationOrdinals()))
