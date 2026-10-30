## Must not compile: `csrfExempt("saml-acs")` on an `aSession` entry; every
## exemption but csp-report is bound to signature authentication
## (tests/routing/t_manifest_csrf_binding.nim).
import isonim/routing/manifest

type
  HookRequest = object
  HookResponse = object

routeManifest BadRoute:
  post rHook, "/hook", HookRequest, HookResponse, auth = aSession, csrf = csrfExempt("saml-acs")
