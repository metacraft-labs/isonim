## Must not compile: the `email-webhook` CSRF exemption on an entry whose
## authentication is not the signature (`auth = aPublic`; isonim-auth.md §2.5,
## tests/routing/t_manifest_csrf_binding.nim).
import isonim/routing/manifest

type
  HookRequest = object
  HookResponse = object

routeManifest BadRoute:
  post rHook, "/hook", HookRequest, HookResponse, auth = aPublic,
       csrf = csrfExempt("email-webhook")
