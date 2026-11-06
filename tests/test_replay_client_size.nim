## PSZ-M3 review item 2: the clientSize seam's record and replay path.
##
## Artifact-free and in-repo. The owner harnesses that drive measure's replay
## need CT_ARTIFACT (the installed boundary shim), and no owner harness covers
## clientSize. This file runs the internal replay bridge (readReplayClientSize)
## against a checked fake of the owner cursor.
##
## Mocks, and why each is here:
## - ``globalThis.__ctReplay``: stands in for the installed owner's replay
##   cursor, which only an artifact provides. It serves the values a recording
##   captured, in order, and logs every request. The oracle is that log: each
##   request must be the clientSize LayoutRead for the registered iid, so a
##   replay that asks for any other property fails.
## - The element is a plain object with a stub ``Element`` prototype, because
##   node has no DOM. Its live clientWidth/clientHeight differ from the recorded
##   values, so a replay that reads the live element instead of the log fails.
##   Its getBoundingClientRect is a trap that counts calls and returns a box
##   that differs from the client box.
## - ``globalThis.__isonimIids`` / ``__isonimValidateIids``: the registry the
##   renderer owns. One registered element is enough for the iid lookup.
##
## Run through tools/test_replay_reads.py, which compiles this file with the
## internal read-replay and stable-id defines.
when defined(js) and defined(isonimInternalReplayReads) and defined(isonimStableIds):
  import std/[json, unittest, jsffi]
  import isonim/core/nondet
  import isonim/core/private/replay_reads

  proc setupFixture(): JsObject {.importjs: "(function(){function Element(){}globalThis.Element=Element;var el=Object.create(Element.prototype);el.clientWidth=640;el.clientHeight=480;el.getAttribute=function(n){return n==='data-iid'?'iid-7':null;};globalThis.fakeRectCalls=0;el.getBoundingClientRect=function(){globalThis.fakeRectCalls++;return {x:1,y:2,width:903,height:904,top:2,right:904,bottom:906,left:1};};globalThis.__isonimValidateIids=function(){};globalThis.__isonimIids=new Map([['iid-7',{deref:function(){return el;}}]]);globalThis.fakeEl=el;globalThis.fakeServed=[];globalThis.fakeRequests=[];globalThis.__ctReplay={protocol:1,level:0,failed:false,next:function(kind,payload){globalThis.fakeRequests.push({kind:kind,payload:payload});if(globalThis.fakeServed.length===0)throw new Error('unexpected owner read');return {value:globalThis.fakeServed.shift()};},registerTask:function(){},onTask:function(){},offTask:function(){},status:function(){return {state:'running'};}};return el;})()".}
  proc serveValue(value: cstring) {.importjs: "globalThis.fakeServed.push(#)".}
  proc requestCount(): int {.importjs: "(globalThis.fakeRequests.length)".}
  proc lastRequest(): cstring {.importjs: "(JSON.stringify(globalThis.fakeRequests[globalThis.fakeRequests.length-1]))".}
  proc rectCalls(): int {.importjs: "(globalThis.fakeRectCalls)".}
  proc setLiveBox(width, height: int) {.importjs: "(function(w,h){globalThis.fakeEl.clientWidth=w;globalThis.fakeEl.clientHeight=h;})(#,#)".}

  suite "clientSize record and replay":
    test "record: returns the live client box, never the bounding rectangle":
      install(newRealBackend(1))
      let el = setupFixture()
      let size = clientSize(el)
      check size.width == 640
      check size.height == 480
      check rectCalls() == 0

    test "replay: returns the logged client box, not the live element":
      let el = setupFixture()
      # The live element now disagrees with what was recorded.
      setLiveBox(1, 1)
      serveValue("{\"width\":640,\"height\":480}")
      install(newInternalReadReplay(%*{}))
      let size = clientSize(el)
      check size.width == 640
      check size.height == 480
      check rectCalls() == 0
      check requestCount() == 1
      let request = parseJson($lastRequest())
      check request["kind"].getStr() == "LayoutRead"
      check request["payload"]["target"].getStr() == "iid:iid-7"
      # Only the client-size property is asked of the log. A replay that asks
      # for getBoundingClientRect (the measure property) fails here.
      check request["payload"]["prop"].getStr() == "clientSize"

    test "replay: successive reads consume the logged values in order":
      let el = setupFixture()
      setLiveBox(1, 1)
      serveValue("{\"width\":640,\"height\":480}")
      serveValue("{\"width\":800,\"height\":600}")
      install(newInternalReadReplay(%*{}))
      let first = clientSize(el)
      let second = clientSize(el)
      check (first.width, first.height) == (640, 480)
      check (second.width, second.height) == (800, 600)
      check requestCount() == 2
      check rectCalls() == 0
