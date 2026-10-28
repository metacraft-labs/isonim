import std/[jsffi,json]
import isonim/core/nondet
import isonim/core/private/replay_reads
import nim_everywhere/time as neTime
include ./record_measure_nodes
proc rqSelect() {.exportc.} =
  proc context():cstring {.importjs: "JSON.stringify(globalThis.xrReadBootContext)".}
  install(newInternalReadReplay(parseJson($context())))
proc rqReplay(el:JsObject):cstring {.exportc.} =
  let r = measure(el)
  ($(%*{"x":r.x,"y":r.y,"width":r.width,"height":r.height})).cstring
proc rqReplayPrivate(el:JsObject):cstring {.exportc.} = ($readReplayMeasure(currentClock,el)).cstring
proc rqMono():float64 {.exportc.} = currentClock.now()
proc rqNeMono():cstring {.exportc.} = ($neTime.monotonicNowMs()).cstring
