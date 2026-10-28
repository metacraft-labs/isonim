## Genuine public facade in one Nim runtime per realm. Native calls use actual
## browser History; Replay uses actual owner cursor and linked owner exports.
## The explicit lexical window substitution tests partial-host metadata absence
## and exception ordering only; it never supplies a successful replay URL.
when defined(replayNavEarly):
  import ./replay_reads_bootstrap
import std/[json, jsffi, monotimes]
import isonim/core/nondet
import isonim/core/private/replay_reads
{.emit: "var window=globalThis;".}
var selected: ClockBase
proc context(): cstring {.importjs: "JSON.stringify(globalThis.navContext)".}
proc boot(): cstring {.exportc: "navBoot".} = ($env()).cstring
proc real() {.exportc: "navReal".} = install(newRealBackend(7))
proc replay() {.exportc: "navReplay".} =
  selected = newInternalReadReplay(parseJson($context()))
  install(selected)
proc again() {.exportc: "navAgain".} = install(newInternalReadReplay(parseJson($context())))
proc otherBoot(url: cstring) {.exportc: "navOtherBoot".} =
  let snapshot = parseJson($context())
  snapshot["url"] = %($url)
  install(newInternalReadReplay(snapshot))
proc reselect() {.exportc: "navReselect".} = install(selected)
proc switchTest() {.exportc: "navTest".} = install(newTestBackend())
proc path(): cstring {.exportc: "navLocation".} = nondet.location().cstring
proc push(url: cstring) {.exportc: "navPush".} = nondet.pushState($url)
proc replace(url: cstring) {.exportc: "navReplace".} = nondet.replaceState($url)
proc neutral(): cstring {.exportc: "navNeutral".} =
  ($(%*{"tick": $nondet.now().ticks,"value":storageGet("nav-neutral")})).cstring
proc partial(w: JsObject) {.exportc: "navPartial".} =
  {.emit: "window=`w`;".}
proc restore() {.exportc: "navRestoreWindow".} =
  {.emit: "window=globalThis;".}
# Fixture entrypoints only; owner/helper bindings remain lexical, never injected.
{.emit: "Object.assign(globalThis,{navBoot,navReal,navReplay,navAgain,navOtherBoot,navReselect,navTest,navLocation,navPush,navReplace,navNeutral,navPartial,navRestoreWindow});".}
