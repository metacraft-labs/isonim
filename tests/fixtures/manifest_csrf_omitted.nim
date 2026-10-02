## Must not compile: a DELETE entry without a CSRF policy (the default is
## csrfNone) (tests/test_route_manifest.nim).
import isonim/routing/manifest

type
  NoteRequest = object
    id: int
  NoteResponse = object
    id: int

routeManifest BadRoute:
  delete rNote, "/notes/:id", NoteRequest, NoteResponse, auth = aSession
