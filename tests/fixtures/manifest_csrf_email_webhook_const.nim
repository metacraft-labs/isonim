## Must not compile: the `email-webhook` exemption through a named constant
## on an `aSession` entry (tests/routing/t_manifest_csrf_binding.nim): the
## binding is checked on the evaluated policy, not on its spelling.
import isonim/routing/manifest

type
  HookRequest = object
  HookResponse = object

const hookCsrf = csrfExempt("email-webhook")

routeManifest BadRoute:
  post rHook, "/hook", HookRequest, HookResponse, auth = aSession, csrf = hookCsrf
