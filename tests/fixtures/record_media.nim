## Actual fixed media primitive; unrelated public clock selection stays inert.
import std/jsffi
import isonim/core/nondet
import isonim/core/private/[record_media, record_clocks]
var media: seq[RecordMediaPrimitives]
var clocks: seq[RecordClockPrimitives]
proc ctx(): JsObject {.importjs: "(globalThis.recordMediaOwner)".}
proc init(): int {.exportc: "rmInit".} =
  let c = ctx()
  let selected = currentClock
  media.add(newInternalRecordMedia(c.window,c.rec,c.orig))
  clocks.add(newInternalRecordClocks(c.window,c.rec,c.orig))
  doAssert selected == currentClock
  media.high
proc read(index:int; query:cstring):bool {.exportc:"rmRead".} = media[index].recordMediaMatches($query)
proc switchTest() {.exportc:"rmSwitchTest".} = install(newTestBackend(17.25))
proc selected():float64 {.exportc:"rmSelected".} = currentClock.now()

proc clock(index:int):float64 {.exportc:"rmRecordClock".} = clocks[index].recordMonotonicMs()
