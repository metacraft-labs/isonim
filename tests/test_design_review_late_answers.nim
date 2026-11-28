## The design-review gallery's daemon answers, when they arrive out of order.
##
## The editor asks the review daemon three things for the active brief:
## whether it has history (the history button), its tiles and its saved
## layout (when the gallery opens). The user can move to another story
## before an answer arrives, so an answer for the brief shown earlier can
## arrive after the next brief's question was sent, or after its answer.
## These tests check that such an answer changes nothing, and that a
## saved layout arriving after a story change does not replace an
## arrangement the user has not saved.
##
## Stand-in: the browser's `fetch` is replaced by one that records each
## request and answers only when the test says so, synchronously. A real
## daemon answers in its own order and cannot be made to answer an earlier
## request last, which is the case under test. Everything between `fetch`
## and the ViewModel (the editor's HTTP client, the reply parsers, the
## reactive wiring) is the production code. The real daemon is covered by
## `test_design_review_gallery_fetch_on_open` and
## `test_design_review_gallery_save_layout_wired` (native).
##
## JS only (node): `nim js -d:nodejs`, run with `tools/run_nim_js_test.py`.

when not defined(js):
  {.error: "This test drives the browser fetch path: compile with nim js.".}

import std/[unittest, strutils]

import isonim/core/[signals, computation, owner]
import isonim/testing/mock_dom
import isonim/editor/viewmodels
import isonim/editor/design_review/editor_http_client
import isonim/editor/views/design_review_mount
import isonim/editor/views/gallery_overlay

proc installHeldFetch() =
  ## Replace `fetch` with one that holds every request until `answer`.
  ## Its promises are synchronous thenables: `then` runs its handler at
  ## once when the value is there, so an answer reaches the editor inside
  ## the test's own call.
  {.emit: """
  (function () {
    function Held() { this.done = false; this.value = undefined; this.waiting = []; }
    Held.prototype.resolve = function (v) {
      if (this.done) return;
      this.done = true; this.value = v;
      var w = this.waiting; this.waiting = [];
      for (var i = 0; i < w.length; i++) w[i](v);
    };
    Held.prototype.then = function (onValue) {
      var next = new Held();
      var run = function (v) {
        var out = onValue ? onValue(v) : v;
        if (out && typeof out.then === 'function') out.then(function (x) { next.resolve(x); });
        else next.resolve(out);
      };
      if (this.done) run(this.value); else this.waiting.push(run);
      return next;
    };
    Held.prototype.catch = function () { return this; };
    globalThis.__heldRequests = [];
    globalThis.fetch = function (url) {
      var reply = new Held();
      globalThis.__heldRequests.push({ url: String(url), reply: reply, answered: false });
      return reply;
    };
  })();
  """.}

proc requestCount(fragment: string): int =
  ## Requests whose URL contains `fragment`, answered or not.
  let f: cstring = fragment
  var n = 0
  {.emit: [n, """ = globalThis.__heldRequests.filter(function (r) {
    return r.url.indexOf(""", f, """) >= 0; }).length;"""].}
  n

proc answer(fragment: string; body: string; status = 200) =
  ## Answer the first unanswered request whose URL contains `fragment`.
  let f: cstring = fragment
  let b: cstring = body
  var found = false
  {.emit: ["""
    var reqs = globalThis.__heldRequests;
    for (var i = 0; i < reqs.length; i++) {
      var r = reqs[i];
      if (!r.answered && r.url.indexOf(""", f, """) >= 0) {
        r.answered = true;
        """, found, """ = true;
        var text = """, b, """;
        var held = r.reply;
        var textReply = new held.constructor();
        textReply.resolve(text);
        held.resolve({ status: """, status, """, text: function () { return textReply; } });
        break;
      }
    }
  """].}
  doAssert found, "no unanswered request for " & fragment

proc layoutRow(layoutId, captureId: string): string =
  "[{\"layout_id\":\"" & layoutId & "\",\"version\":2,\"scope\":\"user\"," &
    "\"name\":\"default\",\"layout\":{\"version\":1,\"entries\":" &
    "[{\"captureId\":\"" & captureId & "\",\"row\":0,\"col\":1}]}}]"

proc runReply(runId, captureId, previewId: string): string =
  "{\"run_id\":\"" & runId & "\",\"captures\":[{\"capture_id\":\"" & captureId &
    "\",\"preview_id\":\"" & previewId & "\",\"status\":\"complete\"," &
    "\"width\":320,\"height\":568}]}"

type Mounted = object
  vm: EditorVM
  st: DesignReviewState
  r: MockRenderer
  parent: MockNode

proc newState(): Mounted =
  ## A fresh editor state talking to the held `fetch`, with no request
  ## held yet. The test mounts what the editor shell mounts.
  {.emit: "globalThis.__heldRequests = [];".}
  result.vm = createEditorVM()
  result.st = ensureDesignReviewState(result.vm)
  result.st.httpClient = newEditorHttpClient("http://daemon.test")
  result.r = MockRenderer()
  result.parent = createElement(result.r, "div")

proc mountHistoryButton(m: Mounted) =
  mountHistoryButtonForEditor[MockRenderer, MockNode](m.r, m.parent, m.vm)

proc mountGalleryHost(m: Mounted) =
  discard mountGalleryHostForEditor[MockRenderer, MockNode](m.r, m.parent, m.vm)

installHeldFetch()

suite "Design-review answers for an earlier brief":

  test "a late history answer for an earlier brief does not show the button":
    createRoot proc(dispose: proc()) =
      let m = newState()
      let st = m.st
      m.mountHistoryButton()
      st.briefId.val = "render.first"
      st.briefId.val = "render.second"
      check requestCount("brief-has-history?briefId=render.first") == 1
      check requestCount("brief-has-history?briefId=render.second") == 1
      answer("briefId=render.second", "{\"hasHistory\":false,\"runCount\":0}")
      check st.briefHasHistory.val == false
      # The first brief's answer arrives last.
      answer("briefId=render.first", "{\"hasHistory\":true,\"runCount\":3}")
      check st.briefHasHistory.val == false
      check st.historyVm.briefHasHistory.val == false
      dispose()

  test "the history answer for the brief shown is applied":
    createRoot proc(dispose: proc()) =
      let m = newState()
      let st = m.st
      m.mountHistoryButton()
      st.briefId.val = "render.first"
      st.briefId.val = "render.second"
      answer("briefId=render.first", "{\"hasHistory\":false,\"runCount\":0}")
      answer("briefId=render.second", "{\"hasHistory\":true,\"runCount\":1}")
      check st.briefHasHistory.val == true
      check st.historyVm.briefHasHistory.val == true
      dispose()

  test "a late saved layout for an earlier brief is not restored":
    createRoot proc(dispose: proc()) =
      let m = newState()
      let st = m.st
      m.mountGalleryHost()
      st.briefId.val = "render.first"
      st.galleryHostState.val = ghsOpen
      check requestCount("list-layouts?briefId=render.first") == 1
      # The user moves to another story while the gallery is open.
      st.briefId.val = "render.second"
      check requestCount("list-layouts?briefId=render.second") == 1
      answer("list-layouts?briefId=render.second",
             layoutRow("22222222-2222-2222-2222-222222222222", "cap-second"))
      check st.galleryVm.activeLayoutId.val ==
        "22222222-2222-2222-2222-222222222222"
      # The first brief's layout arrives last.
      answer("list-layouts?briefId=render.first",
             layoutRow("11111111-1111-1111-1111-111111111111", "cap-first"))
      check st.galleryVm.activeLayoutId.val ==
        "22222222-2222-2222-2222-222222222222"
      check st.galleryVm.pendingLayout.val.len == 1
      check st.galleryVm.pendingLayout.val[0].captureId == "cap-second"
      st.galleryHostState.val = ghsClosed
      dispose()

  test "late tiles for an earlier brief are not shown":
    createRoot proc(dispose: proc()) =
      let m = newState()
      let st = m.st
      m.mountGalleryHost()
      st.briefId.val = "render.first"
      st.galleryHostState.val = ghsOpen
      st.briefId.val = "render.second"
      answer("list-history?briefId=render.second",
             "[{\"run_id\":\"run-second\"}]")
      answer("fetch-run?runId=run-second",
             runReply("run-second", "cap-second", "p/render.second#0@web"))
      check st.galleryVm.tiles.val.len == 1
      check st.galleryVm.tiles.val[0].captureId == "cap-second"
      # The first brief's history arrives last: its runs are not fetched.
      answer("list-history?briefId=render.first",
             "[{\"run_id\":\"run-first\"}]")
      check requestCount("fetch-run?runId=run-first") == 0
      check st.galleryVm.tiles.val.len == 1
      check st.galleryVm.tiles.val[0].captureId == "cap-second"
      check "render.first" notin st.galleryVm.tiles.val[0].previewId
      st.galleryHostState.val = ghsClosed
      dispose()

suite "Design-review saved layouts and an unsaved arrangement":

  test "an unsaved arrangement survives a story change and back":
    createRoot proc(dispose: proc()) =
      let m = newState()
      let st = m.st
      m.mountGalleryHost()
      st.briefId.val = "render.first"
      st.galleryHostState.val = ghsOpen
      answer("list-history?briefId=render.first",
             "[{\"run_id\":\"run-first\"}]")
      answer("fetch-run?runId=run-first",
             runReply("run-first", "cap-first", "p/render.first#0@web"))
      answer("list-layouts?briefId=render.first", "[]")
      # The user rearranges the tiles and does not save.
      registerDragMove(st.galleryVm, "cap-first", 2, 0)
      check st.galleryVm.isDirty.val
      # A look at another story with a saved layout, then back, with the
      # gallery open throughout. Whatever the editor asks on the way is
      # answered: the case is the arrangement, not whether it asks.
      st.briefId.val = "render.second"
      for fragment in ["list-history?briefId=render.second",
                       "list-layouts?briefId=render.second"]:
        if requestCount(fragment) > 0:
          answer(fragment,
                 if "layouts" in fragment:
                   layoutRow("22222222-2222-2222-2222-222222222222", "cap-second")
                 else: "[]")
      st.briefId.val = "render.first"
      for fragment in ["list-history?briefId=render.first",
                       "list-layouts?briefId=render.first"]:
        if requestCount(fragment) > 1:
          answer(fragment,
                 if "layouts" in fragment:
                   layoutRow("11111111-1111-1111-1111-111111111111", "cap-first")
                 else: "[{\"run_id\":\"run-first\"}]")
      if requestCount("fetch-run?runId=run-first") > 1:
        answer("fetch-run?runId=run-first",
               runReply("run-first", "cap-first", "p/render.first#0@web"))
      # The drag is still there, still unsaved.
      check st.galleryVm.isDirty.val
      check st.galleryVm.pendingLayout.val.len == 1
      check st.galleryVm.pendingLayout.val[0].captureId == "cap-first"
      check st.galleryVm.pendingLayout.val[0].rowIndex == 2
      st.galleryHostState.val = ghsClosed
      dispose()
