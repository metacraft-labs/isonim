## `ResponseBody` (isonim/server/response_body.nim) on a host that gives the
## handler no writer: `ctx.bodyWriter` is nil there, and a write or flush on
## it raises `ValueError` instead of dereferencing nil, which kills the
## process (under ngx-isonim an nginx worker with every request in flight
## on it; isonim-specs issues/2026-10-27-nil-ctx-bodywriter-write-crashes-
## the-process.md).
##
## `just test-c` runs this file twice: in the default build and with
## `-d:release -d:danger`, ngx-isonim's release flags, under which the
## compiler's own nil checks are off.  Only the explicit check in
## response_body.nim can raise there; without it both builds die with
## SIGSEGV, so the test cannot pass vacuously.
##
## Negative control: a real writer (`newResponseBody` over closures, as a
## host makes it) receives every write and flush, and its own errors
## propagate with their type.
##
## The server function runs through `dispatchRpc` in-process, the registry
## path ngx-isonim's `isonim_rpc` locations run (rpc.nim); no transport is
## needed, because the misuse fails before reaching one.

import std/[unittest, json, strutils, asyncdispatch]
import isonim/server/[rpc, pragma, context, response_body]

var sawNilWriter = false

proc misuse(ctx: RequestContext; n: int): Future[int] {.server(auth = aPublic, csrf = csrfAnon).} =
  ## The misuse of the issue: a server function writing to the writer the
  ## registry never gives it.
  sawNilWriter = ctx.bodyWriter.isNil
  ctx.bodyWriter.write("oops")
  return n

proc fine(n: int): Future[int] {.server(auth = aPublic, csrf = csrfAnon).} =
  return n

proc rpcRequest(path, body: string): RequestContext =
  newRequestContext(newSsrRequest("POST", path, path, "",
    @[("Host", "forum.test"), ("Content-Type", "application/json"),
      ("Origin", "https://forum.test"), ("Sec-Fetch-Site", "same-origin"),
      (csrfHeaderName, "anon-tok"), ("Cookie", anonCsrfCookieName & "=anon-tok")],
    "127.0.0.1", body))

suite "ResponseBody: a nil writer raises":
  test "write (string and openArray) and flush on nil raise ValueError":
    let b: ResponseBody = nil
    expect ValueError:
      b.write("x")
    expect ValueError:
      let data = ['a', 'b']
      b.write(data)
    expect ValueError:
      b.flush()
    try:
      b.write("x")
      check false
    except ValueError as e:
      check "nil response body writer" in e.msg
      check "ctx.responseBody" in e.msg   # says what to do instead

  test "a context the host gave no writer: ctx.bodyWriter is nil and raises":
    let ctx = newRequestContext(newSsrRequest("GET", "/", "/", "", @[], "127.0.0.1"))
    check ctx.bodyWriter.isNil            # vacuity guard: the documented nil
    expect ValueError:
      ctx.bodyWriter.write("x")
    expect ValueError:
      ctx.bodyWriter.flush()

  test "negative control: a real writer receives writes and flushes":
    var written = ""
    var flushes = 0
    proc writeImpl(data: openArray[char]) =
      for c in data: written.add c
    proc flushImpl() = inc flushes
    let b = newResponseBody(writeImpl, flushImpl)
    b.write("ab")
    b.write(['c'])
    b.flush()
    check written == "abc"
    check flushes == 1
    let ctx = newRequestContext(newSsrRequest("GET", "/", "/", "", @[], "127.0.0.1"))
    ctx.setBodyWriter(b)
    ctx.bodyWriter.write("d")
    check written == "abcd"

  test "negative control: a real writer's own errors keep their type":
    proc writeImpl(data: openArray[char]) =
      raise newException(ClientConnectionError, "gone")
    proc flushImpl() =
      raise newException(ResponseTooLargeError, "too large")
    let b = newResponseBody(writeImpl, flushImpl)
    expect ClientConnectionError:
      b.write("x")
    expect ResponseTooLargeError:
      b.flush()

suite "dispatchRpc: a server function writing to the nil writer":
  test "is answered 500 internal, the ValueError kept for the log":
    sawNilWriter = false
    let ctx = rpcRequest("/api/test_response_body/misuse", """{"n": 3}""")
    waitFor dispatchRpc(ctx)
    check sawNilWriter                    # vacuity guard: it ran, writer nil
    check ctx.response.status == 500
    check parseJson(ctx.responseBody)["error"].getStr == "internal"
    require ctx.failure != nil
    check ctx.failure of ValueError
    check "nil response body writer" in ctx.failure.msg
    check "oops" notin ctx.responseBody

  test "negative control: the same request shape to a function that does not write is 200":
    let ctx = rpcRequest("/api/test_response_body/fine", """{"n": 3}""")
    waitFor dispatchRpc(ctx)
    check ctx.response.status == 200
    check parseJson(ctx.responseBody).getInt == 3
    check ctx.failure.isNil
