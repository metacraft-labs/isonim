## Compiles: the `email-webhook` exemption with `auth = aSignature`, on a
## typed entry and on an `any` entry (tests/routing/t_manifest_csrf_binding.nim).
import isonim/routing/manifest

type
  HookRequest = object
  HookResponse = object

routeManifest GoodRoute:
  post rHook, "/hook", HookRequest, HookResponse, auth = aSignature,
       csrf = csrfExempt("email-webhook")
  any rRawHook, "/raw-hook", auth = aSignature, csrf = csrfExempt("email-webhook")
