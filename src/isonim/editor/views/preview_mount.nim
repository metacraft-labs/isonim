## Mounting a project's UI into a preview frame.
##
## Shared by the two views that host a project preview -- `component_edit` and
## `component_detail` -- because they must behave identically and have already
## drifted apart once by holding two copies of one rule. The first cut of
## mounting lived only in the edit view, and the consequence was immediate and
## invisible to every test: a project that adopted mounting returned a shell
## with an empty body, the edit view filled it, and the DETAIL view -- which is
## where the editor lands by default -- rendered a blank white rectangle.
##
## What a mount is, and why it is not an injection. The project is handed an
## element inside the preview frame and renders into it with its own code. The
## editor never parses, rewrites or re-serialises the project's markup; the
## values in the resulting tree are cells (`editor/editable_cells`), so an edit
## is a signal write and the framework's own reactivity carries it to the DOM.

# No `std/dom` import: this module names no DOM type. `PreviewMountHost` comes
# from `viewmodels`, which resolves it to `Element` in a JS build and to a
# stand-in natively, and everything DOM-shaped here happens inside `{.emit.}`.
# Importing `std/dom` unconditionally broke every native test that reaches a
# view, because that module refuses to compile off the JavaScript platform.
import std/options
import ../../core/[owner, signals, computation, batch]
import ../../services/[async_value, streams]
import ./view_lifecycle
import ../types
import ../preview_identity
import ../viewmodels

type
  PreviewMountState* = ref object
    ## Per-frame mount bookkeeping. One of these per view, not per mount: it
    ## remembers what is currently mounted so a re-render that changes nothing
    ## does not tear the preview down and build it again.
    dispose*: proc()
    lastStory*: StoryRef
    documentGeneration*: int
      ## The number of the document last requested. It is stamped into the
      ## document, because a frame's `load` event does not say which srcdoc
      ## loaded, and it makes a request of the same markup a new question.
    mountedDocumentGeneration*: int
    ownerDisposed*: bool
    requestedDocument: Signal[Option[int]]
      ## The document whose load is awaited (`none`: no document).
    documentLoad: AsyncValue[seq[int]]
      ## The answer to "has the requested document loaded": `ready` once it
      ## has. A new request replaces the wait for the previous document,
      ## whose load listener the stream's cancellation removes, and the
      ## view's disposal ends it, so a load of an earlier document is never
      ## taken for the current one.
    observeDocument: proc(revision: int; loaded: StreamEmitter[int])
      ## Waits for the requested document in the frame of the last request.
    pendingMount: proc()
    generation*: int
      ## Bumped on every mount request. A pending mount that is waiting for a
      ## frame `load` compares against it and gives up if another request has
      ## arrived since -- without this, two callbacks both run, both call
      ## `createRoot`, and the second overwrites `dispose` so the first root is
      ## never torn down. Its effects stay subscribed to the cells they read,
      ## so every later edit does their work again as well as the real one.

proc cancelPendingPreviewMount*(state: PreviewMountState) =
  ## Retire the action, retaining a loaded document and its live mounted root.
  state.generation = state.generation + 1
  state.pendingMount = nil

proc readyDocumentGeneration*(state: PreviewMountState): int =
  ## The requested document's number once it has loaded, else 0 (untracked).
  if state.ownerDisposed: return 0
  if untrack(proc(): bool = state.documentLoad.ready): state.documentGeneration
  else: 0

proc newPreviewMountState*(): PreviewMountState =
  result = PreviewMountState(requestedDocument: createSignal(none(int)))
  let state = result
  state.documentLoad = createAsyncStream(
    proc(): Option[int] = state.requestedDocument.val,
    proc(revision: Option[int]): ServiceStream[int] =
      let observe = state.observeDocument
      newServiceStream(proc(loaded: StreamEmitter[int]) =
        observe(revision.get, loaded)))
  # A mount that waits for its document runs once the document has loaded.
  # In an effect rather than in the answer's completion hook, which runs
  # inside a batch: the project's own writes during the mount must take
  # effect before the mount re-applies the pending declarations, as they do
  # when the document was already loaded.
  createEffect proc() =
    if state.documentLoad.ready:
      untrack(proc() =
        if state.pendingMount != nil: state.pendingMount())
  onCleanup proc() =
    state.ownerDisposed = true
    state.cancelPendingPreviewMount()
    if state.dispose != nil:
      state.dispose()
      state.dispose = nil

proc observeRequestedDocument[E](frame: E; revision: int;
    loaded: StreamEmitter[int]) =
  ## Finishes `loaded` when document `revision` has loaded in `frame`; its
  ## cancellation removes the listener. A load after the stream has ended or
  ## was cancelled finishes nothing (stream protocol).
  when isDomViewHost(E):
    let ready = proc() = loaded.finish()
    var stop: proc()
    {.emit: [stop, " = ", """
      (function (frame, revision, ready) {
        function onPreviewMountDocumentLoad() {
          if (frame.__isonimViewDisposed || !frame.isConnected) return;
          const doc = frame.contentDocument;
          if (!doc || doc.readyState !== 'complete' || !doc.body ||
              doc.querySelector('meta[name="isonim-mount-document"]')?.content !== String(revision)) return;
          frame.removeEventListener('load', onPreviewMountDocumentLoad);
          ready();
        }
        // Registered BEFORE srcdoc is assigned, including a hidden view's
        // request. An earlier navigation's load cannot satisfy this revision.
        frame.addEventListener('load', onPreviewMountDocumentLoad);
        return function () {
          frame.removeEventListener('load', onPreviewMountDocumentLoad);
        };
      })(""", frame, ", ", revision, ", ", ready, ");"].}
    loaded.onCancel(stop)
  else:
    # Logical renderer hosts have no load to wait for.
    discard frame
    discard revision
    loaded.finish()

proc requestedPreviewMountDocument*[E](frame: E; state: PreviewMountState;
    html: string): string =
  ## Called on EVERY actual srcdoc rewrite, before assigning it. Readiness is
  ## per requested document, not the latest render effect's changed boolean.
  if state.ownerDisposed: return html
  state.cancelPendingPreviewMount()
  if state.dispose != nil:
    state.dispose()
    state.dispose = nil
  state.documentGeneration = state.documentGeneration + 1
  state.observeDocument = proc(revision: int; loaded: StreamEmitter[int]) =
    observeRequestedDocument(frame, revision, loaded)
  # Asking about the new document replaces the wait for the previous one.
  # Called as a procedure: in a generic, Nim 2.2 resolves the `.val =`
  # setter sugar only in the instantiating module, which may not import it
  # (https://github.com/nim-lang/Nim/issues/26402).
  `val=`(state.requestedDocument,
    if html.len == 0: none(int) else: some(state.documentGeneration))
  if html.len == 0: return ""
  stampedPreviewDocument(html, "<meta name=\"isonim-mount-document\" content=\"" &
    $state.documentGeneration & "\">")

proc mountNow[E](frame: E; story: StoryRef; hook: PreviewMountHook;
                 state: PreviewMountState) =
  when isDomViewHost(E):
    var body: PreviewMountHost = nil
    {.emit: [body, " = ", frame, ".contentDocument && ",
             frame, ".contentDocument.body;"].}
    if body.isNil: return

    if not state.dispose.isNil:
      # The previous story's effects are still subscribed to the cells they
      # read. Disposing the root they were created in is what stops them.
      state.dispose()
      state.dispose = nil

    # Build into a detached fragment, then swap it in as one mutation.
    #
    # Clearing the body and rendering into it leaves a window -- however short
    # -- in which the document holds a partial tree, and the editor's
    # scene-graph reader polls that document. It sampled mid-mount and
    # labelled the selected element `h1` instead of `h1.tagline`, because the
    # element existed and its class effect had not run yet. Reactive attributes
    # widen that window: an attribute is no longer set as part of creating the
    # element.
    #
    # A fragment has an `ownerDocument`, so the project still derives its
    # renderer from the host exactly as before, and node identity survives the
    # swap, so effects created during the mount keep working once their nodes
    # are in the document.
    var host: PreviewMountHost = nil
    {.emit: [host, " = ", frame, ".contentDocument.createDocumentFragment();"].}
    # Detached: the mount lives until the next mount or the owner's disposal
    # (`state.dispose`), not until the computation that asked for it re-runs.
    createDetachedRoot proc(dispose: proc()) =
      state.dispose = dispose
      hook(story, host)

    # Replace only what a previous mount put here -- NOT the whole body.
    #
    # `body.replaceChildren(fragment)` looks like the obvious swap and it
    # destroys the editor's own furniture. The selection bridge is injected
    # before `</body>`, so its `<style id="isonim-editor-selection-style">`
    # lives IN the body -- and that style is the entire mechanism by which a
    # selected element gets its outline. Mounting over it left the attribute
    # meaning nothing: the borders around the selected element in Edit and
    # Comment mode simply stopped being drawn. The overlay divs come back
    # because the bridge recreates them lazily; a removed `<style>` does not.
    #
    # Inserted at the FRONT, so the bridge's absolutely-positioned overlays
    # stay after the content in DOM order and therefore on top of it. That is
    # the order the injected document has always had.
    #
    # The node list is kept on the frame's own window rather than in this
    # module's state: it describes that document, it has to die with it, and a
    # frame that reloads must not be cleaned up against a list of nodes that no
    # longer exist.
    {.emit: [
      "(function (frame, body, fragment) {",
      "  const w = frame.contentWindow;",
      "  const previous = (w && w.__isonimMountedNodes) || [];",
      "  previous.forEach(function (node) {",
      "    if (node.parentNode === body) body.removeChild(node);",
      "  });",
      "  const added = Array.prototype.slice.call(fragment.childNodes);",
      "  body.insertBefore(fragment, body.firstChild);",
      "  if (w) w.__isonimMountedNodes = added;",
      "})(", frame, ", ", body, ", ", host, ");"].}

    # Re-apply pending stylesheet declarations, AFTER the mount.
    #
    # The injected bridge also does this on frame start, and that is too early
    # for a mounted preview: the bridge runs at the end of `<body>`, which is an
    # EMPTY body -- the project has not rendered yet, so there is no element for
    # a declaration to resolve against and the edit is silently dropped. It
    # reached the user as the preview flashing back to the old value about a
    # second after an edit, once the write triggered a reload.
    #
    # Here the tree exists. Idempotent, so the bridge's earlier attempt costing
    # nothing is fine.
    {.emit: """
      (function () {
        const pending = window.__isonimPreviewDeclarations;
        if (!pending) return;
        Object.keys(pending).forEach(function (key) {
          window.dispatchEvent(new CustomEvent(
            'isonim-preview-set-declaration', { detail: pending[key] }));
        });
      })();
    """.}
  else:
    discard frame
    discard story
    discard hook.isNil
    discard state

proc mountPreviewInto*[E](frame: E; story: StoryRef; hook: PreviewMountHook;
                          state: PreviewMountState; reloaded: bool;
                          stillCurrent: proc(): bool = nil) =
  ## Request only one mount of this story in this exact loaded document.
  if state.ownerDisposed or hook.isNil: return
  if not reloaded and story == state.lastStory and
      state.mountedDocumentGeneration == state.documentGeneration: return
  state.cancelPendingPreviewMount()
  state.lastStory = story
  let mine = state.generation
  let revision = state.documentGeneration
  let current = stillCurrent
  # Runs at once when the document has loaded, else from the effect in
  # `newPreviewMountState` once it has; a new document request clears it.
  state.pendingMount = proc() =
    if state.generation != mine or (current != nil and not current()): return
    state.pendingMount = nil
    mountNow(frame, story, hook, state)
    state.mountedDocumentGeneration = revision
  # Logical renderer hosts retain their prior non-DOM behavior. A real host
  # reaches this fast path only after its matching actual document load.
  if state.readyDocumentGeneration == revision:
    state.pendingMount()
