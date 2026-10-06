## Must not compile: a server function declaring csrfNone
## (tests/test_server_functions.nim).
import isonim/server/[pragma, rpc]

proc setName(name: string): Future[bool] {.server(csrf = csrfNone).} =
  return true
