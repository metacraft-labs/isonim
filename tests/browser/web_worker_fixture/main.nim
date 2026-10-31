## main.nim
##
## The web-worker fixture's page script (tests/browser/specs/web-worker.spec.ts).
## Posts revision-tagged preview requests through a `WorkerBridge` and
## applies only the newest result; records how long each keydown on
## #editor waited for the main thread.
##
## Built twice (just build-web-worker-fixture):
## * main.js: the bridge talks to preview.worker.js, a separate chunk;
## * main.inline.js (-d:previewInline): the negative control, the same
##   compile module linked into this bundle and run on the main thread
##   (`newInlineBridge`).

import std/jsffi
import isonim/web/worker
import preview_compile

when defined(previewInline):
  let bridge = newInlineBridge[PreviewRequest, PreviewResult](compilePreview)
else:
  let bridge = newWorkerBridge[PreviewRequest, PreviewResult]("preview.worker.js")

{.emit: """
window.fx = {applied: [], blocks: [], inWorker: null, busyFrom: 0, busyTo: 0,
             resultAt: 0, keyLatency: [], keyAt: [], keyCreated: []};
""".}

proc state(): JsObject =
  {.emit: [result, " = window.fx;"].}
proc epochNow(): float =
  {.emit: [result, " = performance.timeOrigin + performance.now();"].}
proc pushNum(a: JsObject; v: float) {.importjs: "#.push(#)".}
proc pushStr(a: JsObject; v: cstring) {.importjs: "#.push(#)".}

bridge.onResult proc(rev: int; res: PreviewResult) =
  state()["applied"].pushNum(float(rev))
  {.emit: "window.fx.blocks = [];".}
  for b in res.blocks:
    state()["blocks"].pushStr(cstring(b.html))
  state()["inWorker"] = toJs(res.inWorker)
  state()["busyFrom"] = toJs(res.busyFrom)
  state()["busyTo"] = toJs(res.busyTo)
  state()["resultAt"] = toJs(epochNow())

proc post(text: cstring; busyMs: int; announce: bool): int =
  bridge.post(PreviewRequest(text: $text, busyMs: busyMs, announce: announce))

proc stats(): JsObject =
  result = newJsObject()
  result["latest"] = toJs(bridge.latest)
  result["received"] = toJs(bridge.received)
  result["dropped"] = toJs(bridge.dropped)

state()["post"] = toJs(post)
state()["stats"] = toJs(stats)

{.emit: """
document.getElementById('editor').addEventListener('keydown', function (ev) {
  // How long the event waited for this thread: now minus its creation time.
  window.fx.keyLatency.push(performance.now() - ev.timeStamp);
  window.fx.keyAt.push(performance.timeOrigin + performance.now());
  window.fx.keyCreated.push(performance.timeOrigin + ev.timeStamp);
});
""".}
