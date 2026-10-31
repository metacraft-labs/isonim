## Compiler ceilings apply to actual bindings and the inferred renderer wrapper.
import isonim/web/[web_renderer, dom_api]
import nim_everywhere/raw_nondet
import std/times
when defined(rejectPublic):
  proc caller(r: WebRenderer): Element {.tags: [].} = r.createElement("div")
  discard caller(WebRenderer())
elif defined(rejectConstructor):
  proc caller(): InternalClientCreationOrdinals {.tags: [].} = newInternalClientCreationOrdinals()
  discard caller()
elif defined(rejectQuery):
  proc caller(c: InternalClientCreationOrdinals;e:Element): cstring {.tags: [].} = internalClientCreationOrdinal(c,e)
  discard caller(newInternalClientCreationOrdinals(),nil)
elif defined(privateRawOnly):
  proc caller(c: InternalClientCreationOrdinals): Element {.tags: [RawNondet].} = createInternalClientElement(c,WebRenderer(),"div")
  discard caller(newInternalClientCreationOrdinals())
elif defined(rejectPrivate):
  proc caller(c: InternalClientCreationOrdinals): Element {.tags: [TimeEffect].} = createInternalClientElement(c,WebRenderer(),"div")
  discard caller(newInternalClientCreationOrdinals())
else:
  proc publicCaller(r:WebRenderer): Element {.tags: [TimeEffect].} = r.createElement("div")
  proc privateCaller(c:InternalClientCreationOrdinals):Element {.tags:[TimeEffect,RawNondet].} = createInternalClientElement(c,WebRenderer(),"div")
  discard publicCaller(WebRenderer())
  discard privateCaller(newInternalClientCreationOrdinals())
