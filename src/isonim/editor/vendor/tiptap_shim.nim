## TBAR-M4 — Nim shim around the vendored TipTap + marked bundle.
##
## The vendor file ``vendor/tiptap/isonim-tiptap.umd.min.js`` is loaded
## by the editor HTML scaffold via a ``<script>`` tag (see
## ``isonim-examples/editor/index.html``). It attaches
## ``window.IsoNimTipTap`` whose shape is documented in
## ``vendor/tiptap/MANIFEST.txt``. This module exposes the small Nim
## surface the editor's spec-pane mount consumes:
##
##   * ``mountTipTapViewer(container, markdown)`` — initialises a
##     read-only TipTap editor on ``container`` showing the markdown
##     rendered to HTML. A subsequent call on the same container
##     destroys the previous Editor instance to avoid ProseMirror
##     state leakage.
##   * ``unmountTipTapViewer(container)`` — explicit teardown.
##   * ``isTipTapAvailable()`` — true when ``window.IsoNimTipTap`` is
##     defined (i.e. the vendor bundle loaded successfully). The
##     editor's spec-pane mount falls back to a raw-markdown
##     rendering when this is false so a dev build that forgot to
##     copy ``vendor/tiptap/`` to ``build/editor/`` does not hard
##     crash.
##   * ``isTipTapEditableContainer(container)`` — exposes the
##     vendored shim's editability flag so the e2e test can assert
##     that a View-mode mount is non-editable.
##
## The native build (when ``not defined(js)``) compiles all of the
## procs as inert stubs returning sentinel values. This lets the
## headless VM test (``test_editor_spec_pane_vm``) compile + run on
## the native target without pulling in browser APIs.

when defined(js):
  import std/dom

  type
    JsObject {.importc.} = ref object

  proc isTipTapAvailable*(): bool =
    ## Returns ``true`` when ``window.IsoNimTipTap`` is defined on the
    ## global object. The editor's spec-pane mount uses this to fall
    ## back to a raw-markdown rendering when the vendor UMD didn't
    ## load (e.g. ``build/editor/vendor/tiptap/`` is missing in a dev
    ## build).
    var present = 0
    {.emit: ["""
      try {
        if (typeof window !== 'undefined' &&
            window.IsoNimTipTap &&
            typeof window.IsoNimTipTap.mountViewer === 'function') {
          """, present, """ = 1;
        }
      } catch (_) {}
    """].}
    present == 1

  proc mountTipTapViewer*(container: Element; markdown: string) =
    ## Initialise a read-only TipTap editor on ``container``, renders
    ## ``markdown`` through the vendored ``marked`` parser, and sets
    ## that HTML as the editor's content. A second call on the same
    ## container destroys the prior Editor first, so there is no
    ## ProseMirror state leak across re-mounts (the vendor shim holds
    ## the per-container Editor in a ``WeakMap`` keyed by the DOM
    ## node).
    if container == nil:
      return
    let md = markdown.cstring
    {.emit: ["""
      try {
        if (typeof window !== 'undefined' &&
            window.IsoNimTipTap &&
            typeof window.IsoNimTipTap.mountViewer === 'function') {
          window.IsoNimTipTap.mountViewer(""", container, """, """, md, """);
        }
      } catch (e) {
        try { console.error('mountTipTapViewer failed', e); } catch (_) {}
      }
    """].}

  proc unmountTipTapViewer*(container: Element) =
    ## Tear down the TipTap editor mounted on ``container`` (if any).
    ## Safe to call when nothing was ever mounted.
    if container == nil:
      return
    {.emit: ["""
      try {
        if (typeof window !== 'undefined' &&
            window.IsoNimTipTap &&
            typeof window.IsoNimTipTap.unmount === 'function') {
          window.IsoNimTipTap.unmount(""", container, """);
        }
      } catch (_) {}
    """].}

  proc isTipTapEditableContainer*(container: Element): bool =
    ## Returns the read-only editability flag reported by the vendor
    ## shim for ``container``. The TBAR-M4 mount sets the editor to
    ## ``editable: false`` so this returns ``false`` after a
    ## ``mountTipTapViewer`` call.
    if container == nil:
      return false
    var editable = 0
    {.emit: ["""
      try {
        if (typeof window !== 'undefined' &&
            window.IsoNimTipTap &&
            typeof window.IsoNimTipTap.isEditableContainer === 'function') {
          if (window.IsoNimTipTap.isEditableContainer(""", container, """)) {
            """, editable, """ = 1;
          }
        }
      } catch (_) {}
    """].}
    editable == 1

else:
  # Native (non-JS) build: the shim exists so modules that import it
  # compile in the headless test pipeline. None of these are called on
  # the native target — the editor's spec_pane VM tests never mount
  # TipTap; only the JS bundle does.
  type Element* = ref object

  proc isTipTapAvailable*(): bool = false

  proc mountTipTapViewer*(container: Element; markdown: string) =
    discard

  proc unmountTipTapViewer*(container: Element) =
    discard

  proc isTipTapEditableContainer*(container: Element): bool = false
