## Must not compile: the `email-webhook` exemption on an `any` entry with
## the default authentication (`aOptional`; tests/routing/t_manifest_csrf_binding.nim).
import isonim/routing/manifest

routeManifest BadRoute:
  any rHook, "/hook", csrf = csrfExempt("email-webhook")
