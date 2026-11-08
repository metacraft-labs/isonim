## steps_main.nim
##
## The worker-steps fixture's page script (tests/browser/specs/worker-steps.spec.ts):
## a supervised bridge (`newSupervisedBridge`, overrun 32 ms) to
## steps.worker.js, recording every result, error and replacement on
## `window.fx` with its time.

import std/jsffi
import isonim/web/worker
import steps_compile

let bridge = newSupervisedBridge[StepsRequest, StepsResult]("steps.worker.js", 32)

{.emit: "window.fx = {results: [], errors: [], restarts: []};".}

proc state(): JsObject =
  {.emit: [result, " = window.fx;"].}
proc push(a, v: JsObject) {.importjs: "#.push(#)".}
proc nowMs(): float {.importjs: "performance.now()".}

proc entry(rev: int): JsObject =
  result = newJsObject()
  result["rev"] = toJs(rev)
  result["at"] = toJs(nowMs())

bridge.onResult proc(rev: int; res: StepsResult) =
  let e = entry(rev)
  e["tag"] = toJs(cstring(res.tag))
  e["steps"] = toJs(res.steps)
  state()["results"].push(e)

bridge.onError proc(rev: int; msg: string) =
  let e = entry(rev)
  e["msg"] = toJs(cstring(msg))
  state()["errors"].push(e)

bridge.onRestart proc(rev: int) =
  state()["restarts"].push(entry(rev))

proc post(stepMs: seq[int]; throwAt: int; tag: cstring): int =
  bridge.post(StepsRequest(stepMs: stepMs, throwAt: throwAt, tag: $tag))

proc stats(): JsObject =
  result = newJsObject()
  result["latest"] = toJs(bridge.latest)
  result["received"] = toJs(bridge.received)
  result["dropped"] = toJs(bridge.dropped)
  result["restarts"] = toJs(bridge.restarts)
  result["now"] = toJs(nowMs())

proc postJs(stepMs: JsObject; throwAt: int; tag: cstring): int =
  var ms: seq[int]
  for i in 0 ..< stepMs["length"].to(int): ms.add stepMs[i].to(int)
  post(ms, throwAt, tag)

state()["post"] = toJs(postJs)
state()["stats"] = toJs(stats)
