## Actual public facade/native Storage in one Nim runtime per realm.
## The driver alone observes captured originals; production retains its native
## expression. Fault controls supply throwing getters/methods, never valid data.
when defined(replayStorageEarly):
  import ./replay_storage_output_bootstrap
import std/[json,monotimes,tables]
import isonim/core/nondet
import isonim/core/private/replay_reads
var selected: ClockBase
proc context(): cstring {.importjs: "JSON.stringify(globalThis.storageContext)".}
proc boot(): cstring {.exportc:"soBoot".} = ($env()).cstring
proc real() {.exportc:"soReal".} = install(newRealBackend(7))
proc replay() {.exportc:"soReplay".} =
  selected = newInternalReadReplay(parseJson($context()))
  install(selected)
proc again() {.exportc:"soAgain".} = install(newInternalReadReplay(parseJson($context())))
proc reselect() {.exportc:"soReselect".} = install(selected)
proc test() {.exportc:"soTest".} = install(newTestBackend())
proc nilClock() {.exportc:"soNil".} = install(ClockBase(nil))
type CustomClock = ref object of ClockBase
method now(c:CustomClock):float64 = 17.0
proc custom() {.exportc:"soCustom".} = install(CustomClock())
proc write(key,value:cstring) {.exportc:"soWrite".} = storageSet($key,$value)
proc writeNil(key:cstring) {.exportc:"soWriteNil".} =
  var empty: string
  storageSet($key,empty)
proc read(key:cstring):cstring {.exportc:"soRead".} = storageGet($key).cstring
proc neutral():cstring {.exportc:"soNeutral".} =
  ($(%*{"tick": $nondet.now().ticks,"value":storageGet("neutral")})).cstring
proc scriptedValue():cstring {.exportc:"soScriptedValue".} = currentClock.storage.getOrDefault("scripted").cstring
proc showNative(value:cstring) {.importjs:"document.querySelector('main').textContent=#".}
proc show(value:cstring) {.exportc:"soShow".} = showNative(value)
proc dispatch():int {.exportc:"soDispatch".} = currentClock.dispatchSequence.int
{.emit: "Object.assign(globalThis,{soBoot,soReal,soReplay,soAgain,soReselect,soTest,soNil,soCustom,soWrite,soWriteNil,soRead,soNeutral,soScriptedValue,soShow,soDispatch});".}
