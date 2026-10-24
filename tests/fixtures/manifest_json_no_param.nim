## Must NOT compile: `json` on a page whose pattern does not end in a :param
## (tests/routing/t_manifest_negotiation.nim).
import isonim/routing/manifest

type
  ListRequest = object
    id: int
  ListResponse = object
    id: int

routeManifest JsonListRoute:
  page rList, "/lists/:id/all", ListRequest, ListResponse, json = true
