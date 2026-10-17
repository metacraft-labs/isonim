## Must compile: the control of the manifest_csrf_* fixtures, the same
## entries with valid CSRF policies (tests/test_route_manifest.nim).
import isonim/routing/manifest

type
  NoteRequest = object
    text: string
  NoteResponse = object
    id: int
  DeleteNoteRequest = object
    id: int
  HookRequest = object
  HookResponse = object

routeManifest GoodRoute:
  post   rNote, "/notes", NoteRequest, NoteResponse, auth = aSession, csrf = csrfSession
  delete rDeleteNote, "/notes/:id", DeleteNoteRequest, NoteResponse, auth = aSession,
         csrf = csrfSession
  post   rHook, "/hook", HookRequest, HookResponse, auth = aSignature,
         csrf = csrfExempt("billing-webhook")
