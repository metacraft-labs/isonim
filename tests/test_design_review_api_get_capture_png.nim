## REV-M7 — ``GET /api/design-review/get-capture-png`` tests.
##
## Streams content-addressed PNG bytes for a known capture.  We seed a
## small but valid PNG into the store, write a ``captures`` row that
## points at it, and assert the API returns the same bytes back with
## ``Content-Type: image/png`` and the ``immutable`` Cache-Control.

import std/[strutils, unittest]

import helpers/design_review_http_fixture
import isonim/editor/design_review/capture_store

# A 1x1 PNG (8-bit RGB, all-black).  The simplest valid byte sequence
# the server can stream back; the test asserts byte-identity so the
# pixel data doesn't matter — only that ``readFile`` round-trips
# whatever we wrote.
const TinyPng = "\x89PNG\r\n\x1A\n" &
                "\x00\x00\x00\rIHDR\x00\x00\x00\x01\x00\x00\x00\x01" &
                "\x08\x02\x00\x00\x00\x90wS\xDE" &
                "\x00\x00\x00\x0CIDATx\x9Cc\x00\x01\x00\x00\x05\x00\x01" &
                "\r\n\x2D\xB4\x00\x00\x00\x00IEND\xAEB`\x82"

proc bytesOf(s: string): seq[byte] =
  result = newSeq[byte](s.len)
  for i in 0 ..< s.len: result[i] = byte(s[i])

suite "REV-M7 get-capture-png API":

  test "test_api_get_capture_png_returns_bytes":
    let f = startServeAndSeed()
    defer: f.shutdown()
    let cs = f.pg.connectionString
    # Write the PNG into the store the daemon was configured with.
    let store = newCaptureStore(f.storePath)
    let put = store.put(bytesOf(TinyPng))
    let runId = seedRunInDb(cs, "render.png-test", "h")
    let capId = seedCaptureInDb(cs, runId, "p/a:page#0@web",
                                "web", "tablet", put.sha256, put.path,
                                10, 10)
    check capId.len == 36
    let resp = httpGet(f,
        "/api/design-review/get-capture-png?id=" & capId)
    check resp.code == 200
    check resp.contentType == "image/png"
    check "immutable" in resp.cacheControl
    check resp.body.len == TinyPng.len
    check resp.body == TinyPng

  test "test_api_get_capture_png_404_for_unknown":
    let f = startServeAndSeed()
    defer: f.shutdown()
    let resp = httpGet(f,
        "/api/design-review/get-capture-png?id=00000000-0000-0000-0000-000000000000")
    check resp.code == 404
    # No body leak: the response message must not contain SQL
    # fragments or the literal capture-id (which is fine in normal
    # not-found messages but we keep them out per the security
    # constraint).
    check "SELECT" notin resp.body
    check "design_review" notin resp.body

  test "test_api_get_capture_png_missing_id_400":
    let f = startServeAndSeed()
    defer: f.shutdown()
    let resp = httpGet(f, "/api/design-review/get-capture-png")
    check resp.code == 400
