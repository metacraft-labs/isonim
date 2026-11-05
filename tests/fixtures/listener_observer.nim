## Test bridge only: real nondet.listen, original owner lifecycle and same WeakMap.
## Existing registration fixture supplies exact JS callback identities and clocks;
## no observer/listener/Replay algorithm is reproduced here.
import std/[jsffi, json]
import isonim/core/[nondet, owner]
import ./registered_handler
when defined(isonimInternalReplayReads): import isonim/core/private/replay_reads

proc diagnostic(message: string): JsObject =
  result = newJsObject()
  result.name = "ValueError".cstring
  result.message = message.cstring
proc claim(callback: proc(record: JsObject)): JsObject =
  result = newJsObject()
  try: result.release = toJs(claimInternalListenerObserver(callback))
  except ValueError as error: result.error = diagnostic(error.msg)
proc release(handle: InternalListenerObserverRelease): JsObject =
  result = newJsObject()
  try: handle()
  except ValueError as error: result.error = diagnostic(error.msg)
proc publicSet(callback: proc(record: JsObject)): JsObject =
  result = newJsObject()
  try: setListenerHook(callback)
  except ValueError as error: result.error = diagnostic(error.msg)
proc owned(callback: proc(record: JsObject)): JsObject =
  let handle = claimInternalListenerObserver(callback)
  var dispose: proc()
  createRoot proc(stop: proc()) =
    dispose = stop
    onCleanup(proc() = handle())
  result = newJsObject()
  result.release = toJs(handle)
  result.dispose = toJs(dispose)
proc typed(node: JsObject): JsObject =
  var calls = 0
  let callback: proc(event: JsObject) {.closure.} = proc(event: JsObject) = inc calls
  let dispose = nondet.listen(node, "typed", callback)
  result = newJsObject()
  result.callback = toJs(callback)
  result.dispose = toJs(dispose)
  result.count = toJs(proc(): int = calls)
proc selectorNull() = currentClock = nil
proc selector(): bool = currentClock == nil
when defined(isonimInternalReplayReads):
  proc replay() =
    let boot = env()
    install(newInternalReadReplay(boot))
  {.emit: "globalThis.observerReplay=`replay`;".}
{.emit: "globalThis.observerClaim=`claim`;globalThis.observerRelease=`release`;globalThis.observerSet=`publicSet`;globalThis.observerOwned=`owned`;globalThis.observerTyped=`typed`;globalThis.observerNull=`selectorNull`;globalThis.observerIsNull=`selector`;".}


# A genuinely generated, capturing Nim OBSERVER callback, distinct from the
# application's typed callback above and the identity-level JS hook controls.
proc typedObserver(): JsObject =
  var calls = 0
  var saved: JsObject = nil
  let callback: proc(record: JsObject) {.closure.} = proc(record: JsObject) =
    inc calls
    saved = record
  let stop = claimInternalListenerObserver(callback)
  result = newJsObject()
  result.release = toJs(stop)
  result.count = toJs(proc(): int = calls)
  result.record = toJs(proc(): JsObject = saved)
{.emit: "globalThis.observerTypedObserver=`typedObserver`;".}
