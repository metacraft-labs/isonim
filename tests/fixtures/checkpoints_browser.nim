## Real browser callbacks exercise task and microtask ordering without a shim.
import std/jsffi
import isonim/core/[signals, computation, owner, checkpoints, nondet]
import isonim/web/dom_api
import nim_everywhere/platform
var states: seq[Signal[int]]
var stopOwner: proc()
let selected = newRealBackend(1)
install(selected)
{.emit: "globalThis.checkpoints=[];globalThis.stages=[];".}
proc observed(c: SignalCheckpoint) =
  let seq = c.afterSeq.int
  let hash = c.hash.cstring
  let derived = states[1].val
  {.emit: "globalThis.checkpoints.push({afterSeq:`seq`,hash:`hash`,derived:`derived`});".}
var session = startCheckpoints(selected, observed, every=1, idleMs=30)
createRoot proc(dispose: proc()) =
  stopOwner = dispose
  for i in 0..<10: states.add(createSignal(i))
  createEffect(proc() = states[1].val = states[0].val * 10)
  discard listen(cast[JsObject](document.getElementById("run")), "click", proc(ev: Event) =
    states[0].val = 2
    # A real Promise continuation must settle before a maintenance checkpoint.
    proc later() =
      states[0].val = 3
      {.emit: "globalThis.stages.push('microtask');".}
    {.emit: "Promise.resolve().then(`later`);".})
proc timer() =
  discard scheduleAt(1, proc() = states[0].val = 4)
proc frame() =
  discard requestFrame(proc() = states[0].val = 5)
proc network() =
  let pending = nondet.fetch(HttpRequest(url:"/data"))
  pending.onComplete(proc(response: HttpResponse) = states[0].val = 6,
    proc(message: string) = raise newException(ValueError,message))
proc status(): int = liveSignalCount()
proc seq(): int = selected.dispatchSequence.int
proc draws(): int = selected.randomDrawCount.int
proc collectable() =
  discard createSignal(12345)
proc idleOnly() =
  session.stop()
  session = startCheckpoints(selected, observed, every=16, idleMs=30)
proc cancelInitialIdle() =
  session.stop()
  session = startCheckpoints(selected, observed, every=16, idleMs=30)
  session.stop()
proc stateHash(): cstring = signalStateHash(selected.randomDrawCount).cstring
proc dispose() =
  stopOwner()
  session.stop()
{.emit: "globalThis.startTimer=`timer`;globalThis.startFrame=`frame`;globalThis.startNetwork=`network`;globalThis.liveSignals=`status`;globalThis.dispatchSeq=`seq`;globalThis.rngDraws=`draws`;globalThis.collectableSignal=`collectable`;globalThis.disposeCheckpointApp=`dispose`;".}
{.emit: "globalThis.checkpointIdleOnly=`idleOnly`;".}
{.emit: "globalThis.cancelInitialIdle=`cancelInitialIdle`;globalThis.checkpointStateHash=`stateHash`;".}
