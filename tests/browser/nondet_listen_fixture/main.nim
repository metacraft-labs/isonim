## The nondet listen bridge's page script (tests/browser/e2e_nondet_listen_bridge.mjs).
##
## It registers listeners through ``previewListenOn``, the seam the editor shell
## uses for its pointer and full-screen listeners (page_preview.nim), which goes
## to ``nondet.listen``. Nothing is mocked: the DOM, the event dispatch and the
## listener bridge are the browser's own. The test drives the page; this file
## only registers and records.
##
## Build (the test does this itself, into build/nondet_listen_fixture/):
##   nim js --path:src --path:. --path:../nim-everywhere/src \
##     --path:../isonim-render-serve/src --path:../nim-acp/src \
##     --path:../nim-agent-harbor/src --path:../nim-agents/src \
##     -o:build/nondet_listen_fixture/main.js tests/browser/nondet_listen_fixture/main.nim
import std/jsffi
import isonim/editor/views/page_preview

proc recordCall(tag: cstring) {.importjs: "(window.__calls = window.__calls || []).push(#)".}
proc byId(id: cstring): JsObject {.importjs: "document.getElementById(#)".}
proc frameDocument(id: cstring): JsObject {.importjs: "(document.getElementById(#).contentDocument)".}
proc exposeGlobal(name: cstring; fn: proc()) {.importjs: "(window[#] = #)".}

proc listenOnElement() =
  ## An element target, named by a literal. The handler records its call.
  discard previewListenOn(byId("target"), "pointermove",
    proc(ev: JsObject) = recordCall("element:pointermove"))

proc listenOnFrameDocument() =
  ## The iframe's document: a non-element target, which the listener bridge
  ## must accept (it has no getAttribute).
  discard previewListenOn(frameDocument("frame"), "pointermove",
    proc(ev: JsObject) = recordCall("frame-document:pointermove"))

exposeGlobal("listenOnElement", listenOnElement)
exposeGlobal("listenOnFrameDocument", listenOnFrameDocument)
