## Compiles: every signature-bound exemption with `auth = aSignature`, and
## csp-report (not bound) on a public entry (tests/routing/t_manifest_csrf_binding.nim).
import isonim/routing/manifest

type
  HookRequest = object
  HookResponse = object

routeManifest GoodRoute:
  post rBilling, "/billing", HookRequest, HookResponse, auth = aSignature, csrf = csrfExempt("billing-webhook")
  post rUnsub, "/unsub", HookRequest, HookResponse, auth = aSignature, csrf = csrfExempt("rfc8058")
  post rAcs, "/acs", HookRequest, HookResponse, auth = aSignature, csrf = csrfExempt("saml-acs")
  post rBcl, "/bcl", HookRequest, HookResponse, auth = aSignature, csrf = csrfExempt("oidc-backchannel")
  post rCsp, "/csp", HookRequest, HookResponse, auth = aPublic, csrf = csrfExempt("csp-report")
