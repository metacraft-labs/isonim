## Actual private Nim primitive entry points; no substitute writer or cursor.
import std/[jsffi, times, json, monotimes]
import isonim/core/nondet
import isonim/core/private/record_clocks

var clocks: RecordClockPrimitives
static:
  doAssert not compiles(clocks.recordStorageGet("x"))
  doAssert not compiles(clocks.recordRandom())
  doAssert not compiles(clocks.schedule(proc() = discard, 0.0))
  doAssert not compiles(ClockBase(clocks))
proc owner(): JsObject {.importjs: "(globalThis.recordClockOwner)".}
proc actualWindow(): JsObject {.importjs: "(window)".}
proc init() {.exportc: "rcInit".} =
  let ctx = owner()
  let selected = currentClock
  clocks = newInternalRecordClocks(actualWindow(), ctx.rec, ctx.orig)
  doAssert currentClock == selected
proc mono(): float64 {.exportc: "rcMono".} = clocks.recordMonotonicMs()
proc wall(): float64 {.exportc: "rcWall".} = clocks.recordWallEpochMs()
proc switchTest() {.exportc: "rcSwitchTest".} = install(newTestBackend(17.25))
proc selected(): float64 {.exportc: "rcSelected".} = currentClock.now()
proc publicWall(): cstring {.exportc: "rcPublicWall".} =
  let value = nondet.wallNow()
  ($(%*{"seconds": $value.toUnix, "nanoseconds": value.nanosecond})).cstring
proc publicMono(): cstring {.exportc: "rcPublicMono".} = ($nondet.now().ticks).cstring
