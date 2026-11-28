## A preview mount and the frame's `load` events, when they arrive late.
##
## A preview view rewrites its frame's srcdoc and asks for a mount of the
## selected story. The mount must go into the document just requested, so
## it waits for that document's `load`. The browser fires `load` later, and
## a `load` of the document requested before may still arrive after the
## next request. These tests check that a mount waits for the current
## document, that a late `load` of an earlier document mounts nothing, that
## a superseded or disposed wait leaves no listener behind, that a load
## after the view has gone mounts nothing, and that a mount hook that raises
## does not stop the next document's mount.
##
## Stand-in: the frame is a plain object with the members the mount code
## uses (`addEventListener`, `contentDocument`, `contentWindow`, ...), and
## the test fires its `load` listeners itself. A real frame loads in its own
## time and cannot be made to deliver an earlier document's `load` after a
## later request, which is the case under test. Everything else (the
## request, the wait, the mount, the reactive wiring) is the production
## code. Real frames are covered by `tests/test_editor_preview_mount_gui.mjs`.
##
## JS only (node): `nim js -d:nodejs`, run with `tools/run_nim_js_test.py`.

when not defined(js):
  {.error: "This test drives the browser frame path: compile with nim js.".}

import std/[unittest, dom]

import isonim/core/owner
import isonim/editor/[types, viewmodels]
import isonim/editor/views/preview_mount

proc newFakeFrame(): Element =
  ## A frame showing no document yet. `showDocument` loads one.
  {.emit: """
  globalThis.window = globalThis.window || globalThis;
  const frame = {
    isConnected: true,
    listeners: [],
    contentWindow: {},
    contentDocument: null,
    addEventListener(kind, fn) { if (kind === 'load') this.listeners.push(fn); },
    removeEventListener(kind, fn) {
      if (kind === 'load') this.listeners = this.listeners.filter(f => f !== fn);
    },
  };
  `result` = frame;
  """.}

proc showDocument(frame: Element; revision: int) =
  ## The frame now holds the document stamped `revision` (fully loaded),
  ## without firing `load`.
  {.emit: """
  const body = {
    children: [], firstChild: null,
    insertBefore(fragment, before) {
      this.children = fragment.childNodes.concat(this.children);
      this.firstChild = this.children[0] || null;
    },
    removeChild(node) { this.children = this.children.filter(n => n !== node); },
  };
  `frame`.contentWindow = {};
  `frame`.contentDocument = {
    revision: `revision`,
    readyState: 'complete',
    body: body,
    querySelector(selector) {
      return selector === 'meta[name="isonim-mount-document"]'
        ? { content: String(`revision`) } : null;
    },
    createDocumentFragment() { return { childNodes: [], revision: `revision` }; },
  };
  """.}

proc fireLoad(frame: Element) =
  ## Deliver `load` to every listener registered now, as the browser does.
  {.emit: "`frame`.listeners.slice().forEach(fn => fn());".}

proc saveListeners(frame: Element) =
  ## Keep the listeners registered now, as a load already being dispatched
  ## holds them after they are removed.
  {.emit: "`frame`.saved = `frame`.listeners.slice();".}

proc fireSaved(frame: Element) =
  {.emit: "`frame`.saved.forEach(fn => fn());".}

proc listenerCount(frame: Element): int =
  {.emit: "`result` = `frame`.listeners.length;".}

proc hostRevision(host: PreviewMountHost): int =
  ## The document number of the fragment a mount was given.
  {.emit: "`result` = `host`.revision;".}

let story = StoryRef(group: "Cards", name: "First", kind: skComponent)

suite "Preview mount waits for the requested document's load":
  test "a mount waits for the new document; an earlier load mounts nothing":
    createRoot do(dispose: proc()):
      let state = newPreviewMountState()
      let frame = newFakeFrame()
      var mounts: seq[int]
      let hook: PreviewMountHook = proc(s: StoryRef; host: PreviewMountHost) =
        mounts.add hostRevision(host)
      discard requestedPreviewMountDocument(frame, state, "<body></body>")
      frame.showDocument(1)
      frame.fireLoad()
      check state.readyDocumentGeneration == 1
      mountPreviewInto(frame, story, hook, state, true)
      check mounts == @[1]
      # A new document is requested; the frame still shows the first one.
      discard requestedPreviewMountDocument(frame, state, "<body>2</body>")
      check state.readyDocumentGeneration == 0
      mountPreviewInto(frame, story, hook, state, true)
      check mounts == @[1]
      # A late load of the first document is not the second one's.
      frame.fireLoad()
      check mounts == @[1]
      check state.readyDocumentGeneration == 0
      frame.showDocument(2)
      frame.fireLoad()
      check mounts == @[1, 2]
      check state.readyDocumentGeneration == 2
      check state.mountedDocumentGeneration == 2
      check frame.listenerCount == 0
      dispose()

  test "a mount requested before the load runs once, on the load":
    createRoot do(dispose: proc()):
      let state = newPreviewMountState()
      let frame = newFakeFrame()
      var mounts: seq[int]
      let hook: PreviewMountHook = proc(s: StoryRef; host: PreviewMountHost) =
        mounts.add hostRevision(host)
      discard requestedPreviewMountDocument(frame, state, "<body></body>")
      mountPreviewInto(frame, story, hook, state, true)
      check mounts.len == 0
      frame.showDocument(1)
      frame.fireLoad()
      check mounts == @[1]
      frame.fireLoad()
      mountPreviewInto(frame, story, hook, state, false)
      check mounts == @[1]
      dispose()

  test "superseded and disposed waits leave no load listener":
    var state: PreviewMountState
    let frame = newFakeFrame()
    var mounts = 0
    let hook: PreviewMountHook = proc(s: StoryRef; host: PreviewMountHost) =
      inc mounts
    createRoot do(dispose: proc()):
      state = newPreviewMountState()
      discard requestedPreviewMountDocument(frame, state, "<body>1</body>")
      discard requestedPreviewMountDocument(frame, state, "<body>2</body>")
      discard requestedPreviewMountDocument(frame, state, "<body>3</body>")
      check frame.listenerCount == 1
      discard requestedPreviewMountDocument(frame, state, "")
      check frame.listenerCount == 0
      discard requestedPreviewMountDocument(frame, state, "<body>5</body>")
      mountPreviewInto(frame, story, hook, state, true)
      check frame.listenerCount == 1
      frame.saveListeners()
      dispose()
    check frame.listenerCount == 0
    frame.showDocument(5)
    frame.fireLoad()
    frame.fireSaved()
    check mounts == 0
    check state.readyDocumentGeneration == 0

  test "a mount hook that raises on a load does not stop later mounts":
    createRoot do(dispose: proc()):
      let state = newPreviewMountState()
      let frame = newFakeFrame()
      var mounts: seq[int]
      let hook: PreviewMountHook = proc(s: StoryRef; host: PreviewMountHost) =
        mounts.add hostRevision(host)
        if mounts.len == 1: raise newException(ValueError, "project failed")
      discard requestedPreviewMountDocument(frame, state, "<body></body>")
      mountPreviewInto(frame, story, hook, state, true)
      frame.showDocument(1)
      # The error reaches the load listener, as an error of the project's
      # own code does in the browser.
      expect ValueError:
        frame.fireLoad()
      check mounts == @[1]
      discard requestedPreviewMountDocument(frame, state, "<body>2</body>")
      mountPreviewInto(frame, story, hook, state, true)
      frame.showDocument(2)
      frame.fireLoad()
      check mounts == @[1, 2]
      check state.mountedDocumentGeneration == 2
      dispose()
