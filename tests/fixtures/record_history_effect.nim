## Explicit and inferred RawNondet ceilings, each fixed operation and combined.
import std/[jsffi,options]
import nim_everywhere/raw_nondet
when defined(historyRaw):include ../../src/isonim/core/private/record_history
else:import isonim/core/private/record_history
var h:RecordHistoryPrimitives
when defined(historyCombined):
  proc invoke()=
    discard recordPushState(h,"/")
    discard recordReplaceState(h,"/")
elif defined(historyRaw):
  proc invoke()=discard mutate(h.linkage,true,"/")
elif defined(historyReplace):
  proc invoke()=discard recordReplaceState(h,"/")
else:
  proc invoke()=discard recordPushState(h,"/")
when defined(historyReject):
  proc ceiling() {.tags:[].}=invoke()
else:
  proc ceiling() {.tags:[RawNondet].}=invoke()
proc combined() {.tags:[RawNondet].}=
  discard recordPushState(h,"/");discard recordReplaceState(h,"/")
static:doAssert declared(ceiling) and declared(combined)
