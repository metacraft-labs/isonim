## Actual private primitive, with unrelated public selection ownership controls.
import std/jsffi
import isonim/core/nondet
import isonim/core/private/record_layout
var layouts: seq[RecordLayoutPrimitives]
proc ctx(): JsObject {.importjs: "(globalThis.recordLayoutOwner)".}
proc init(): int {.exportc: "rlInit".} =
  let c = ctx()
  let selected = currentClock
  layouts.add(newInternalRecordLayout(c.window, c.rec, c.orig))
  doAssert selected == currentClock
  layouts.high
proc read(index: int): RecordViewportObservation {.exportc: "rlRead".} = layouts[index].recordViewport()
proc switchTest() {.exportc: "rlSwitchTest".} = install(newTestBackend(17.25))
proc selected(): float64 {.exportc: "rlSelected".} = currentClock.now()
