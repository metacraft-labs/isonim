## REV-M8 follow-up — the *production* gallery Save-layout chip must
## reach the daemon.
##
## Why this file exists
## --------------------
##
## ``mountGalleryOverlay`` takes an ``onSave`` callback and, when it is
## nil, falls back to a VM-local ``markSaved("", 0)`` that clears the
## dirty flag without persisting anything.  The production mount
## (``mountGalleryHostForEditor`` → ``shell.nim``) shipped WITHOUT that
## argument, so the chip cleared the dirty flag and the user's
## rearranged layout was gone on the next reload.  Every test that
## "covered" the chip either passed its own fake ``onSave``
## (``test_design_review_gallery_vm``) or drove a hand-written harness
## page that re-implemented the POST in JavaScript
## (``e2e_design_review_gallery_save_layout.mjs``) — so the
## nil-``onSave`` fallback was the only path production ever took and
## nothing went red.
##
## These tests close that hole at the layer where it broke: they mount
## the REAL production host (``mountGalleryHostForEditor``) under the
## MockRenderer, fire a real click on the chip the production DSL
## emitted, and assert the bytes that reached a stub daemon socket.
## Deleting ``onSave = ...`` from the mount site turns
## ``test_production_save_chip_posts_to_daemon`` red immediately: no
## request arrives and ``activeLayoutId`` never leaves "".
##
## The stub server is a raw ``std/net`` socket on a background thread —
## no Postgres, no ``isonim-review`` binary.  The contract under test
## is "the production view is wired to the production HTTP client",
## not "the SQL routine works"; the latter is already covered by
## ``test_design_review_api_save_layout.nim`` against a real database.

import std/[unittest, net, options, os, strutils, tables]

import isonim/core/[signals, computation, owner]
import isonim/testing/mock_dom
import isonim/editor/types
import isonim/editor/viewmodels
import isonim/editor/design_review/editor_http_client
import isonim/editor/views/design_review_mount
import isonim/editor/views/gallery_overlay

# --------------------------------------------------------------------------- #
#  Stub daemon — a single-threaded HTTP/1.1 responder good enough for the
#  two routes the gallery mount touches.  Requests are shipped back to the
#  test thread over a Channel so assertions can inspect the exact bytes.
# --------------------------------------------------------------------------- #

type StubReply = object
  status: string
  body: string

var reqChan: Channel[string]
var portChan: Channel[int]
var replyChan: Channel[StubReply]

# One thread slot per test.  The threads are deliberately never joined:
# a stub that is still parked in ``accept`` (which is exactly what a RED
# run looks like — the production mount never issued the request) must
# not be able to wedge the test process.  Each test binds its own
# ephemeral port, so a leftover listener is inert and the OS reaps it at
# process exit.
var serverThreads: array[8, Thread[int]]
var nextThreadSlot = 0

reqChan.open()
portChan.open()
replyChan.open()

proc recvExact(client: Socket; n: int): string =
  result = ""
  while result.len < n:
    var c = ""
    let got = client.recv(c, 1, 5000)
    if got <= 0: break
    result.add(c)

proc readRequest(client: Socket): string =
  var head = ""
  while not head.endsWith("\r\n\r\n"):
    var c = ""
    let got = client.recv(c, 1, 5000)
    if got <= 0: return head
    head.add(c)
  var contentLength = 0
  let lower = head.toLowerAscii
  let idx = lower.find("content-length:")
  if idx >= 0:
    var j = idx + "content-length:".len
    while j < head.len and head[j] == ' ': inc j
    let start = j
    while j < head.len and head[j] in {'0' .. '9'}: inc j
    if j > start:
      contentLength = parseInt(head[start ..< j])
  head & (if contentLength > 0: recvExact(client, contentLength) else: "")

proc stubServer(requestCount: int) {.thread.} =
  var server = newSocket()
  server.setSockOpt(OptReuseAddr, true)
  server.bindAddr(Port(0), "127.0.0.1")
  let (_, boundPort) = server.getLocalAddr()
  portChan.send(int(boundPort))
  server.listen()
  for _ in 0 ..< requestCount:
    var client: Socket
    server.accept(client)
    let req = readRequest(client)
    reqChan.send(req)
    let reply = replyChan.recv()
    client.send("HTTP/1.1 " & reply.status & "\r\n" &
                "Content-Type: application/json\r\n" &
                "Content-Length: " & $reply.body.len & "\r\n" &
                "Connection: close\r\n\r\n" & reply.body)
    client.close()
  server.close()

proc startStub(requestCount: int): int =
  doAssert nextThreadSlot < serverThreads.len
  createThread(serverThreads[nextThreadSlot], stubServer, requestCount)
  inc nextThreadSlot
  portChan.recv()

proc recvRequest(timeoutMs = 5000): string =
  ## Deadline-bounded ``reqChan.recv``.  Returns "" when nothing
  ## arrived — a missing request is an assertion failure, never a hang.
  var waited = 0
  while waited < timeoutMs:
    let (ok, msg) = reqChan.tryRecv()
    if ok: return msg
    sleep(20)
    waited += 20
  ""

# --------------------------------------------------------------------------- #
#  Mock-DOM helpers.
# --------------------------------------------------------------------------- #

proc findByAttr(node: MockNode; key, value: string): MockNode =
  if node == nil: return nil
  if node.attributes.getOrDefault(key) == value:
    return node
  for child in node.children:
    let hit = findByAttr(child, key, value)
    if hit != nil: return hit
  nil

proc mkTile(captureId, previewId: string): GalleryTile =
  GalleryTile(
    captureId: captureId,
    runId: "run-" & captureId,
    previewId: previewId,
    status: "complete",
    pngUrl: "/api/design-review/get-capture-png?id=" & captureId,
    width: 320, height: 568)

suite "REV-M8 follow-up — production save-layout wiring":

  test "test_production_save_chip_posts_to_daemon":
    ## The chip the PRODUCTION mount renders must reach
    ## ``POST /api/design-review/save-layout`` and feed the daemon's
    ## reply back into the VM.  Fails if ``onSave`` is dropped from
    ## ``mountGalleryHostForEditor``: no request is ever accepted and
    ## the VM's ``activeLayoutId`` stays empty.
    let port = startStub(1)

    createRoot do (dispose: proc()):
      let vm = createEditorVM()
      let st = ensureDesignReviewState(vm)
      st.httpClient = newEditorHttpClient("http://127.0.0.1:" & $port)
      st.briefId.val = "render.task-app"
      st.galleryVm.briefId.val = "render.task-app"
      st.galleryVm.currentPreviewId.val = ""
      st.galleryVm.tiles.val = @[
        mkTile("cap-a", "p/render.task-app#0@web"),
        mkTile("cap-b", "p/render.task-app#0@web")]

      let r = MockRenderer()
      let parent = createElement(r, "div")
      let host = mountGalleryHostForEditor[MockRenderer, MockNode](
        r, parent, vm)

      let chip = findByAttr(host, "data-design-review-gallery-save-button",
                            "true")
      check chip != nil

      # Drag "cap-a" to (0, 1) — the same VM call the production drop
      # handler makes.  Flips ``isDirty`` and surfaces the chip.
      st.galleryVm.registerDragMove("cap-a", 0, 1)
      check st.galleryVm.isDirty.val
      check chip.attributes.getOrDefault(
        "data-design-review-gallery-save-visible") == "true"

      # Queue the daemon's answer, then click.  ``postNative`` is
      # synchronous, so the round trip completes inside ``fireEvent``.
      replyChan.send(StubReply(status: "200 OK",
        body: """{"layout_id":"11111111-2222-3333-4444-555555555555",""" &
              """"version":7}"""))
      fireEvent(chip, "click")

      let req = recvRequest()
      check req.startsWith("POST /api/design-review/save-layout ")
      check "\"briefId\":\"render.task-app\"" in req
      check "\"name\":" in req
      check "\"cap-a\"" in req
      check "\"row\":0" in req
      check "\"col\":1" in req

      # The daemon's reply must land in the VM — this is what makes the
      # next save an UPDATE (optimistic concurrency) instead of a second
      # INSERT, and what the conflict path keys off.
      check st.galleryVm.activeLayoutId.val ==
        "11111111-2222-3333-4444-555555555555"
      check st.galleryVm.activeLayoutVersion.val == 7
      check st.galleryVm.isDirty.val == false
      dispose()

  test "test_production_save_chip_surfaces_version_conflict":
    ## A 409 from the daemon must drive ``markConflict`` (the overlay
    ## renders the reload-or-overwrite dialog off it) and must NOT
    ## clear the dirty flag — the user's work is still unsaved.
    let port = startStub(1)

    createRoot do (dispose: proc()):
      let vm = createEditorVM()
      let st = ensureDesignReviewState(vm)
      st.httpClient = newEditorHttpClient("http://127.0.0.1:" & $port)
      st.briefId.val = "render.task-app"
      st.galleryVm.briefId.val = "render.task-app"
      st.galleryVm.currentPreviewId.val = ""
      st.galleryVm.tiles.val = @[mkTile("cap-a", "p/render.task-app#0@web")]
      st.galleryVm.activeLayoutId.val = "99999999-8888-7777-6666-555555555555"
      st.galleryVm.activeLayoutVersion.val = 3

      let r = MockRenderer()
      let parent = createElement(r, "div")
      let host = mountGalleryHostForEditor[MockRenderer, MockNode](
        r, parent, vm)
      let chip = findByAttr(host, "data-design-review-gallery-save-button",
                            "true")
      check chip != nil
      st.galleryVm.registerDragMove("cap-a", 1, 0)

      replyChan.send(StubReply(status: "409 Conflict",
        body: """{"error":"layout_version_conflict","current":""" &
              """{"version":9}}"""))
      fireEvent(chip, "click")

      let req = recvRequest()
      check req.startsWith("POST /api/design-review/save-layout ")
      # The stale version must be on the wire — without it the daemon
      # can never detect the conflict.
      check "\"expectedVersion\":3" in req
      check "\"layoutId\":\"99999999-8888-7777-6666-555555555555\"" in req

      check st.galleryVm.conflict.val.layoutId ==
        "99999999-8888-7777-6666-555555555555"
      check "\"version\":9" in st.galleryVm.conflict.val.currentRow
      # Still dirty — nothing was persisted.
      check st.galleryVm.isDirty.val == true
      dispose()

  test "test_production_gallery_open_restores_saved_layout":
    ## The other half of "the layout survives a reload": opening the
    ## gallery host must GET ``list-layouts`` and re-hydrate
    ## ``pendingLayout`` from the stored document.  Without this the
    ## save round trip is write-only and the user still sees the
    ## default order after a refresh.
    ##
    ## Two requests are served: ``list-history`` (the pre-existing
    ## tile fetch, answered with an empty history) and
    ## ``list-layouts``.
    let port = startStub(2)

    createRoot do (dispose: proc()):
      let vm = createEditorVM()
      let st = ensureDesignReviewState(vm)
      st.httpClient = newEditorHttpClient("http://127.0.0.1:" & $port)
      st.briefId.val = "render.task-app"
      st.galleryVm.briefId.val = "render.task-app"

      let r = MockRenderer()
      let parent = createElement(r, "div")
      discard mountGalleryHostForEditor[MockRenderer, MockNode](r, parent, vm)

      replyChan.send(StubReply(status: "200 OK", body: """{"runs":[]}"""))
      replyChan.send(StubReply(status: "200 OK",
        body: """[{"layout_id":"aaaaaaaa-bbbb-cccc-dddd-eeeeeeeeeeee",""" &
              """"version":4,"scope":"user","name":"default",""" &
              """"layout":{"version":1,"entries":""" &
              """[{"captureId":"cap-a","row":0,"col":1}]}}]"""))

      st.galleryHostState.val = ghsOpen

      var sawListLayouts = false
      for _ in 0 ..< 2:
        let req = recvRequest()
        if req.startsWith("GET /api/design-review/list-layouts"):
          sawListLayouts = true
          check "briefId=render.task-app" in req
      check sawListLayouts

      check st.galleryVm.activeLayoutId.val ==
        "aaaaaaaa-bbbb-cccc-dddd-eeeeeeeeeeee"
      check st.galleryVm.activeLayoutVersion.val == 4
      check st.galleryVm.pendingLayout.val.len == 1
      check st.galleryVm.pendingLayout.val[0].captureId == "cap-a"
      check st.galleryVm.pendingLayout.val[0].columnIndex == 1
      check st.galleryVm.isDirty.val == false
      dispose()
