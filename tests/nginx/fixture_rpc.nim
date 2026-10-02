## fixture_rpc.nim
##
## Server functions of the nginx fixture (tests/nginx/README.md), compiled
## into the ngx-isonim module (C) and into the browser client (JS), with
## `-d:isonimRpcPrefix=/api/v1/rpc`: their endpoints are
## `/api/v1/rpc/fixture_rpc/<proc>`.  Anonymous callers carry the anonymous
## CSRF token (`csrfAnon`), as a forum visitor would.

import isonim/server/[pragma, rpc, context]

type
  Pair* = object
    a*: int
    b*: int
    sum*: int
    label*: string

proc sum*(a, b: int): Future[int] {.server(auth = aPublic, csrf = csrfAnon).} =
  return a + b

proc describe*(a, b: int; label: string): Future[Pair]
    {.server(auth = aPublic, csrf = csrfAnon).} =
  return Pair(a: a, b: b, sum: a + b, label: label)

proc bodySize*(data: string): Future[int] {.server(auth = aPublic, csrf = csrfAnon).} =
  return data.len

var slowInFlight: int
  ## `slowOp` calls suspended right now (server side).

proc slowOp*(ms: int): Future[string] {.server(auth = aPublic, csrf = csrfAnon).} =
  ## Suspends in the server's event loop for `ms` milliseconds.
  inc slowInFlight
  try:
    await sleepAsync(ms)
  finally:
    dec slowInFlight
  return "slow:" & $ms

proc slowPending*(): Future[int] {.server(auth = aPublic, csrf = csrfAnon).} =
  ## How many `slowOp` calls the server is in the middle of: lets a test
  ## wait until one is inside its handler.
  return slowInFlight

proc fastOp*(): Future[string] {.server(auth = aPublic, csrf = csrfAnon).} =
  return "fast"

proc subscribeNews*(email: string): Future[bool]
    {.action(auth = aPublic, csrf = csrfAnon, target = "/thanks").} =
  return email.len > 0
