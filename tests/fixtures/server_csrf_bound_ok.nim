## Compiles: a server function with a signature-bound exemption and
## `auth = aSignature` (tests/routing/t_manifest_csrf_binding.nim).
import std/asyncdispatch
import isonim/server

proc hook(ctx: RequestContext; a: string): Future[string] {.server(auth = aSignature,
    csrf = csrfExempt("email-webhook")).} =
  return a
