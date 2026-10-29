## Must NOT compile: a streaming `get` entry that declares a response type
## (its handler writes the body through a DataStream;
## tests/routing/t_manifest_streaming.nim).
import isonim/routing/manifest

type
  ItemRequest = object
    id: int
  ItemResponse = object
    id: int

routeManifest StreamGetRoute:
  get rItem, "/items/:id", ItemRequest, ItemResponse, stream = true
