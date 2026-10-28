## Genuine native event delivery integration. Narrow custom clock and hook
## counters witness dispatch effects; actual owner construction remains real.
import std/[json, jsffi, monotimes]
import isonim/core/nondet
import isonim/core/owner
import isonim/web/[events, dom_api]
import nim_everywhere/time as neTime
when defined(isonimInternalReplayReads):
  import isonim/core/private/replay_reads

let originalReal = currentClock
type DeliveryClock = ref object of ClockBase
method now(c: DeliveryClock): float64 = 321.0
var selected: ClockBase
proc boot(): cstring {.importjs: "JSON.stringify(globalThis.deliveryBoot)".}
proc initialize() {.exportc: "deliveryInitialize".} =
  when defined(isonimInternalReplayReads):
    selected = newInternalReadReplay(parseJson($boot()))
proc selectReplay() {.exportc: "deliveryReplay".} = install(selected)
proc choose(mode: cstring) {.exportc: "deliveryChoose".} =
  case $mode
  of "real": install(originalReal)
  of "test": install(newTestBackend(123))
  of "custom": install(DeliveryClock())
  of "nil": install(ClockBase(nil))
  of "direct-nil": currentClock = nil
  else: raise newException(ValueError,"unknown delivery backend")
proc selectedSequence(): cstring {.exportc: "deliverySequence".} =
  if currentClock == nil: "nil" else: ($currentClock.dispatchSequence).cstring
proc replaySequence(): cstring {.exportc: "deliveryReplaySequence".} = ($selected.dispatchSequence).cstring
proc publicClock(): cstring {.exportc: "deliveryClock".} = ($nondet.now().ticks).cstring
proc publicNeClock(): cstring {.exportc: "deliveryNeClock".} = ($neTime.monotonicNowMs()).cstring
proc register(node: JsObject; event: cstring; callback: EventHandler; capture: bool): ListenerDisposer =
  nondet.listen(node, $event, callback, capture)
proc registerOwned(node: JsObject; event: cstring; callback: EventHandler): ListenerDisposer =
  var release: ListenerDisposer
  createRoot proc(dispose: proc()) =
    release = dispose
    discard nondet.listen(node, $event, callback)
  release
proc hook(callback: proc(record: JsObject)) = setListenerHook(callback)
proc delegate(node: Node; event: cstring; callback: EventHandler) = addEventListenerWeb(node,event,callback,true)
proc delegateType(event: cstring) = delegateEvents([event])
proc clearDelegate() = clearDelegatedEvents()
{.emit: "globalThis.deliveryRegister=`register`;globalThis.deliveryOwned=`registerOwned`;globalThis.deliveryHook=`hook`;globalThis.deliveryDelegate=`delegate`;globalThis.deliveryDelegateType=`delegateType`;globalThis.deliveryClear=`clearDelegate`;".}
