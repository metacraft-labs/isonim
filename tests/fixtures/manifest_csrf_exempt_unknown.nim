## Must not compile: csrfExempt naming no isonim-auth.md §2.5 exemption
## (tests/test_route_manifest.nim).
import isonim/routing/manifest

type
  HookRequest = object
  HookResponse = object

routeManifest BadRoute:
  post rHook, "/hook", HookRequest, HookResponse, auth = aSignature,
       csrf = csrfExempt("trust-me")
