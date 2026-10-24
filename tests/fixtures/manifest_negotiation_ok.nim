## Must compile: the control of the manifest_override_weaker and
## manifest_json_* fixtures, the same entries declared validly
## (tests/routing/t_manifest_negotiation.nim).
import isonim/routing/manifest

type
  SecretRequest = object
    id: int
  SecretResponse = object
    id: int
  ListRequest = object
    id: int
  ListResponse = object
    id: int

routeManifest GoodNegotiationRoute:
  page rSecret, "/secret/:id", SecretRequest, SecretResponse,
       cacheOverrides = [cpPrivateNoStore, cpPrivateRevalidate]
  page rList, "/lists/all/:id", ListRequest, ListResponse, json = true
