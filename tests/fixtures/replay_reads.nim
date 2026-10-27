## Real owner integration only; missing owner/context must fail closed.
import ./replay_reads_bootstrap
import std/[json,monotimes,options]
import isonim/core/nondet
import isonim/core/private/replay_reads
import nim_everywhere/time as neTime
import nim_everywhere/platform
import nim_everywhere/http as neHttp
import isonim/core/scheduler
import isonim/web/[dom_api,events,hydration]
import isonim/ssr/markers
when defined(js): import std/jsffi

proc exported(name: cstring; fn: proc()) {.importjs: "(globalThis.xrReadCalls||(globalThis.xrReadCalls={}))[#]=#".}
proc observe(): cstring =
  let snapshot = env()
  let saved = snapshot.copy()
  snapshot["buildId"] = %"mutated-return"
  snapshot["viewport"]["width"] = %999
  doAssert env() == saved
  let ticks = $nondet.now().ticks
  let neMillis = $neTime.monotonicNowMs()
  let missing = storageGet("missing")
  let empty = storageGet("empty")
  let value = storageGet("value")
  let cookie = when defined(replayReadMutant): "" else: cookieGet()
  let values = %*{"ticks": ticks, "neMillis": neMillis,
    "missing":missing,"empty":empty,
    "value":value,"cookie":cookie,"env":env()}
  ($values).cstring
proc observeJs(): cstring {.exportc:"xrReadObserve".} = observe()
proc readKey(key: cstring): cstring {.exportc:"xrReadKey".} = storageGet($key).cstring
proc clockAgain() {.exportc:"xrReadClock".} = discard nondet.now()
proc constructAgain() {.exportc:"xrReadConstructAgain".} =
  let b = newInternalReadReplay(env())
  b.bootEnv["buildId"] = %"different-backend"
  doAssert env()["buildId"].getStr() != "different-backend"
type FreeCustomClock = ref object of ClockBase
method now(c:FreeCustomClock):float64 = 13.0
proc switchReal() {.exportc:"xrReadSwitchReal".} = install(newRealBackend(731))
proc switchCustom() {.exportc:"xrReadSwitchCustom".} = install(FreeCustomClock())
proc switchAway() {.exportc:"xrReadSwitchAway".} = install(newTestBackend())
proc selectAgain() {.exportc:"xrReadSelectAgain".} = install(selected)
proc script(): cstring {.exportc:"xrReadCaptureScript".} = generateHydrationScript().cstring

exported("wallNow",proc()=discard wallNow())
exported("random",proc()=discard nondet.random())
exported("randomFloat",proc()=discard randomFloat())
exported("scheduleAt",proc()=discard nondet.scheduleAt(0,proc()=discard))
exported("scheduleEvery",proc()=discard nondet.scheduleEvery(1,proc()=discard))
exported("requestFrame",proc()=discard requestFrame(proc()=discard))
exported("cancel",proc()=nondet.cancel(1))
exported("fetch",proc()=discard nondet.fetch(HttpRequest(url:"/must-not-fetch")))
exported("browserFetch",proc()=discard browserFetch("GET","/must-not-rpc",nil,"","","",nil))
exported("storageSet",proc()=storageSet("key","must-not-write"))
exported("location",proc()=discard nondet.location())
exported("pushState",proc()=pushState("/must-not-push"))
exported("replaceState",proc()=replaceState("/must-not-replace"))
exported("measure",proc()=discard measure(cast[JsObject](document.getElementById("root"))))
exported("listen",proc()=discard nondet.listen(cast[JsObject](document.getElementById("root")),"click",proc(ev:Event)=discard))
exported("delegateEventsC",proc()=delegateEvents([cstring"click"]))
exported("delegateEventsString",proc()=delegateEvents(["click"]))
exported("addEventListenerWeb",proc()=addEventListenerWeb(document.getElementById("root").Node,cstring"click",proc(ev:Event)=discard))
exported("addEventListenerWebDelegated",proc()=addEventListenerWeb(document.getElementById("root").Node,cstring"click",proc(ev:Event)=discard,true))
exported("runHydrationEvents",proc()=runHydrationEvents())
exported("hydrate",proc()=hydrate(proc():Node= document.getElementById("root").Node, document.getElementById("root")))
proc presence(key:cstring): cstring {.exportc:"xrReadPresence".} =
  ($readReplayStorage(selected,1,$key)).cstring

exported("setListenerHook",proc()=setListenerHook(nil))
exported("clearDelegatedEvents",proc()=clearDelegatedEvents())
exported("requestCallback",proc()=discard requestCallback(proc(didTimeout:bool)=discard))
exported("cancelCallback",proc()=cancelCallback(nil))
exported("flushTasks",proc()=flushTasks())
exported("neScheduleAt",proc()=discard neTime.scheduleAt(1,proc()=discard))
exported("neScheduleEvery",proc()=discard neTime.scheduleEvery(1,proc()=discard))
exported("neFetch",proc()=discard neHttp.fetchHttp(HttpRequest(url:"/never")))
exported("gatherHydratable",proc()=gatherHydratable(document.getElementById("root").Node))
exported("getNextElement",proc()=discard getNextElement(proc():Node=raise newException(ValueError,"RAW CALLBACK")))
exported("getNextMatch",proc()=discard getNextMatch(document.getElementById("root").Node,"main"))
exported("getNextMarker",proc()=discard getNextMarker(document.getElementById("root").Node))
exported("claimElement",proc()=discard claimElement("main"))
exported("hydrationAppend",proc()=discard hydrationAppend(document.getElementById("root").Node,document.getElementById("root").Node))
exported("hydrationMismatches",proc()=discard hydrationMismatches())

proc clearRead() {.exportc:"xrReadClear".} = nondet.install(ClockBase(nil))
proc directNil() {.exportc:"xrReadDirectNil".} = currentClock = nil
