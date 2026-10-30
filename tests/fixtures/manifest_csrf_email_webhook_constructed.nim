## Must not compile: the `email-webhook` exemption as a constructed
## `CsrfPolicy` on an `aSession` entry (tests/routing/t_manifest_csrf_binding.nim).
import isonim/routing/manifest

type
  HookRequest = object
  HookResponse = object

routeManifest BadRoute:
  post rHook, "/hook", HookRequest, HookResponse, auth = aSession,
       csrf = CsrfPolicy(kind: ckExempt, exemption: "email-webhook")
