## Existing public custom-clock semantics must survive private subtype guards.
## No fake cursor/provider; the scripted queues and custom methods are supported
## deterministic framework APIs. Artifact-free C and windowless JS controls.
import std/[json, tables, monotimes, times]
import isonim/core/nondet
when defined(js) and defined(isonimInternalReplayReads):
  import isonim/core/private/replay_reads

type CustomClock = ref object of ClockBase
  registrations, cancellations: int
method now(c: CustomClock): float64 = 125.25
method schedule(c: CustomClock; cb: proc(); delayMs: float64): int =
  inc c.registrations
  83
method cancel(c: CustomClock; id: int) =
  doAssert id == 83
  inc c.cancellations
let c = CustomClock(scripted: true, bootEnv: %*{"custom":true})
install(c)
when defined(js) and defined(isonimInternalReplayReads):
  doAssert not c.isReadReplay
c.script("storageGet", @[newJNull(), %"", %"custom"])
c.script("cookieGet", @[%"custom-cookie"])
c.script("wallNow", @[%0.5])
c.script("random", @[%7])
c.script("randomFloat", @[%0.25])
c.script("viewport", @[%*{"x":1,"y":2,"width":333,"height":222}])
doAssert storageGet("a") == ""
doAssert storageGet("b") == ""
doAssert storageGet("c") == "custom"
doAssert cookieGet() == "custom-cookie"
doAssert env()["custom"].getBool()
doAssert nondet.now().ticks == 125250000
doAssert wallNow().toUnixFloat() == 0.5
doAssert nondet.random() == 7
doAssert randomFloat() == 0.25
let customViewport = viewport()
doAssert customViewport == Rect(x:1,y:2,width:333,height:222)
let id = nondet.scheduleAt(2, proc()=discard)
nondet.cancel(id)
doAssert c.registrations == 1 and c.cancellations == 1
storageSet("x","y")
doAssert c.storage["x"] == "y"
pushState("/custom")
doAssert c.nativeLocation == "/custom"
echo "custom clock private-guard compatibility: PASS"
