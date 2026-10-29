## Compiles: `json` on a page whose pattern does not end in a :param answers
## its JSON variant by `Accept` alone: no `.json` suffix applies to it
## (tests/routing/t_manifest_negotiation.nim).
import isonim/routing/manifest

type
  ListRequest = object
    id: int
  ListResponse = object
    id: int

routeManifest JsonListRoute:
  page rList, "/lists/:id/all", ListRequest, ListResponse, json = true

static:
  doAssert routeSpecs(JsonListRoute)[0].json
  doAssert not jsonSuffixApplies(routeSpecs(JsonListRoute)[0].path)
