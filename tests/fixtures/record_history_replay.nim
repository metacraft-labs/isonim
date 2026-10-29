## Existing real private Replay; no substitute cursor, URL state or loop.
import std/[json,jsffi]
import isonim/core/[clock,nondet]
import isonim/core/private/replay_reads
import nim_everywhere/time as neTime
proc hRpInit(context:cstring) {.exportc.} =
  currentClock=newInternalReadReplay(parseJson($context))
proc hRpClock():float64 {.exportc.}=currentClock.now()
proc hRpNe():cstring {.exportc.}=($neTime.monotonicNowMs()).cstring
proc hRpRead(push,defaultInput:bool;raw:cstring):cstring {.exportc.} =
  var input:string
  if not defaultInput:input= $raw
  if push:pushState(input)
  else:replaceState(input)
  location().cstring
