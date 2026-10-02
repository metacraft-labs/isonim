## Must compile: the negative control of server_fn_sync_return.nim and
## server_fn_csrf_none.nim (tests/test_server_functions.nim).
import isonim/server/[pragma, rpc]

proc getCount(): Future[int] {.server.} =
  return 42

proc setName(name: string): Future[bool] {.server(csrf = csrfAnon).} =
  return true
