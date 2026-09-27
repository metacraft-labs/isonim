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
import ../../core/owner
import ../types
import ../viewmodels

type
  PreviewMountState* = ref object
    ## Per-frame mount bookkeeping. One of these per view, not per mount: it
    ## remembers what is currently mounted so a re-render that changes nothing
    ## does not tear the preview down and build it again.
    dispose*: proc()
    lastStory*: StoryRef

proc newPreviewMountState*(): PreviewMountState =
  PreviewMountState(dispose: nil, lastStory: StoryRef())

proc whenFrameReady[E](frame: E; reloaded: bool; then: proc()) =
  ## Run `then` once the frame's document is the one we just asked for.
  ##
  ## A srcdoc write reloads the frame asynchronously, so mounting straight
  ## after it would build into a document about to be thrown away. When nothing
  ## was rewritten the current document is already the right one and `then`
  ## runs now -- the common case, because selecting a different story inside an
  ## unchanged shell reloads nothing.
  when defined(js):
    let cb = then
    {.emit: ["""
      (function (frame, reloaded, cb) {
        if (!reloaded) { cb(); return; }
        frame.addEventListener('load', function onLoad() {
          frame.removeEventListener('load', onLoad);
          cb();
        });
      })(""", frame, ", ", reloaded, ", ", cb, ");"].}
  else:
    discard frame
    discard reloaded
    then()

proc mountNow[E](frame: E; story: StoryRef; hook: PreviewMountHook;
                 state: PreviewMountState) =
  when defined(js):
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
    createRoot proc(dispose: proc()) =
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
                          state: PreviewMountState; reloaded: bool) =
  ## Mount `story` into `frame`, unless it is already the one mounted.
  ##
  ## Re-mounting on every render would discard the tree the user is working in
  ## several times a second, so this returns early when nothing relevant moved.
  ## A srcdoc rewrite counts as relevant even for the same story: the document
  ## it mounted into no longer exists.
  if hook.isNil: return
  if not reloaded and story == state.lastStory: return
  state.lastStory = story
  let captured = state
  let capturedHook = hook
  let capturedStory = story
  whenFrameReady(frame, reloaded, proc() =
    mountNow(frame, capturedStory, capturedHook, captured))
