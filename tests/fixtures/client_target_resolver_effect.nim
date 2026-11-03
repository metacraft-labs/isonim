## Compile-time ceilings on the real direct bindings and inferred wrappers.
## Deliberate all-import is test-only access to the owning private declarations.
import isonim/web/web_renderer {.all.}
import isonim/web/dom_api
import nim_everywhere/raw_nondet
import std/[jsffi, times]

template selected(c, f, e, r: untyped): untyped =
  when defined(effectMake): discard makeInternalClientTargetContext(f)
  elif defined(effectForward): discard targetForwardContext(c)
  elif defined(effectRequire): requireInternalClientTargetContext(c)
  elif defined(effectLink): requireInternalClientTargetLink(c, f)
  elif defined(effectHas): discard hasInternalClientTargets(c)
  elif defined(effectIndex): discard indexInternalClientTarget(c, e)
  elif defined(effectIid): discard internalClientTargetIid(cstring"iid:test")
  elif defined(effectLookup): discard lookupInternalClientTarget(c, cstring"ord:1")
  elif defined(effectConstructor): discard newInternalClientTargetContext()
  elif defined(effectRenderer): discard newInternalClientTargetRenderer(c)
  elif defined(effectQuery): discard internalClientTargetOrdinal(c, e)
  elif defined(effectResolver): discard resolveInternalClientTarget(c, cstring"ord:1")
  elif defined(effectCreation): discard r.createElement("div")
  else: {.error: "select an actual target operation".}

when defined(effectRejectRaw):
  proc caller(c: InternalClientTargetContext; f: InternalClientCreationOrdinals;
      e: Element; r: InternalClientRenderer) {.tags: [TimeEffect].} =
    selected(c, f, e, r)
elif defined(effectRawOnly):
  proc caller(c: InternalClientTargetContext; f: InternalClientCreationOrdinals;
      e: Element; r: InternalClientRenderer) {.tags: [RawNondet].} =
    selected(c, f, e, r)
else:
  proc caller(c: InternalClientTargetContext; f: InternalClientCreationOrdinals;
      e: Element; r: InternalClientRenderer) {.tags: [TimeEffect, RawNondet].} =
    selected(c, f, e, r)
