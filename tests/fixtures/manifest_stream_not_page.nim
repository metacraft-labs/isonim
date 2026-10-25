## Must NOT compile: `stream` on a data entry
## (tests/routing/t_manifest_streaming.nim).
import isonim/routing/manifest

type
  ItemRequest = object
    id: int
  ItemResponse = object
    id: int

routeManifest StreamDataRoute:
  get rItem, "/items/:id", ItemRequest, ItemResponse, stream = true
