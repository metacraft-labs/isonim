## Must not compile: a server function with `csrfExempt("email-webhook")`
## and `auth = aSession` (tests/routing/t_manifest_csrf_binding.nim).
import std/asyncdispatch
import isonim/server

proc hook(ctx: RequestContext; a: string): Future[string] {.server(auth = aSession,
    csrf = csrfExempt("email-webhook")).} =
  return a
