## `ResponseBody.outputStream` on a nil writer raises `ValueError`
## (response_body.nim; isonim-specs issues/2026-10-27-nil-ctx-bodywriter-
## write-crashes-the-process.md).
##
## `outputStream` exists only when compiled the way ngx-isonim builds its
## production module: `-d:useFaststreams -d:isServer -d:asyncBackend=nginx`
## (ngx-isonim's nim.cfg and scripts/build-module.sh).  `just test-c` runs
## this file with those flags, in the default build and with
## `-d:release -d:danger` (the module's release flags, under which the
## compiler's own nil checks are off).  Without the explicit check in
## `outputStream` the first access to the nil body's fields dies with
## SIGSEGV in both builds, so the test cannot pass vacuously.
##
## Negative control: the `outputStream` of a real writer (`newResponseBody`
## over closures, as a host makes it) delivers what is written through it
## to `write` and `flush`.  No mocks: the closures are the writer's own
## interface, which every host implements this way.

when not (defined(useFaststreams) and defined(isServer) and
          defined(asyncBackend)):
  {.error: "build with -d:useFaststreams -d:isServer -d:asyncBackend=nginx".}

import std/[unittest, strutils]
import isonim/server/response_body

suite "ResponseBody.outputStream (faststreams build)":
  test "outputStream on a nil writer raises ValueError":
    let b: ResponseBody = nil
    expect ValueError:
      discard b.outputStream
    try:
      discard b.outputStream
      check false
    except ValueError as e:
      check "outputStream on a nil response body writer" in e.msg

  test "negative control: a real writer's outputStream reaches write and flush":
    var written = ""
    var flushes = 0
    proc writeImpl(data: openArray[char]) =
      for c in data: written.add c
    proc flushImpl() = inc flushes
    let b = newResponseBody(writeImpl, flushImpl)
    let s = b.outputStream
    s.write("hello")
    s.flush()
    check written == "hello"
    check flushes >= 1
