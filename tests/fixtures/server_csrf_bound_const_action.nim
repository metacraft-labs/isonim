## Must not compile: an `{.action.}` with a signature-bound exemption
## through a named constant and the default auth (`aOptional`)
## (tests/routing/t_manifest_csrf_binding.nim).
import std/asyncdispatch
import isonim/server

const hookCsrf = csrfExempt("rfc8058")

proc hook(ctx: RequestContext; a: string): Future[string] {.action(csrf = hookCsrf).} =
  return a
