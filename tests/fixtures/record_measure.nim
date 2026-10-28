import std/jsffi
import isonim/core/nondet
import isonim/core/private/[record_measure, record_clocks]
include ./record_measure_nodes
var measures: seq[RecordMeasurePrimitives]
var clocks: seq[RecordClockPrimitives]
proc context(): JsObject {.importjs: "(globalThis.recordMeasureOwner)".}
proc rqInit(): int {.exportc.} =
  let c = context()
  let selected = currentClock
  measures.add(newInternalRecordMeasure(c.window,c.rec,c.orig))
  clocks.add(newInternalRecordClocks(c.window,c.rec,c.orig))
  doAssert selected == currentClock
  measures.high
proc rqRead(index:int; el:JsObject):JsObject {.exportc.} = measures[index].recordElementRect(el)
proc rqClock(index:int):float64 {.exportc.} = clocks[index].recordMonotonicMs()
proc rqSwitchTest() {.exportc.} = install(newTestBackend(17.25))
proc rqSelected():float64 {.exportc.} = currentClock.now()
