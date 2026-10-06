## Must not compile: a server function returning a plain value
## (tests/test_server_functions.nim).
import isonim/server/[pragma, rpc]

proc getCount(): int {.server.} =
  42
