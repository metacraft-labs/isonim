## Must NOT compile: `json` on a data entry
## (tests/routing/t_manifest_negotiation.nim).
import isonim/routing/manifest

type
  ItemRequest = object
    id: int
  ItemResponse = object
    id: int

routeManifest JsonDataRoute:
  get rItem, "/items/:id", ItemRequest, ItemResponse, json = true
