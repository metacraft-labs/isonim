## Must not compile: a POST entry declared with csrfNone
## (tests/test_route_manifest.nim, negative control).
import isonim/routing/manifest

type
  NoteRequest = object
    text: string
  NoteResponse = object
    id: int

routeManifest BadRoute:
  post rNote, "/notes", NoteRequest, NoteResponse, auth = aSession, csrf = csrfNone
