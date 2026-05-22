## TBAR-M5b — vendor/tiptap.nim
##
## Typed Nim FFI binding for the ``@tiptap/core`` JS library.
##
## The library is loaded via a ``<script>`` tag in the editor's
## ``index.html`` from ``build/editor/vendor/tiptap.umd.js`` (produced
## by the ``editor-vendor`` Nix derivation).  The bundle's entry
## script (``isonim/nix/entry-tiptap.mjs``) assigns the imported
## ``Editor`` constructor to ``globalThis.TipTap`` — this module
## picks the namespace up via ``{.importc, nodecl.}`` and exposes the
## constructor + the small set of instance methods the spec-pane
## consumer needs through ``{.importjs.}`` procs.
##
## No ``{.emit.}`` blocks: this is a pure FFI module per the TBAR-M5b
## milestone brief.  Application logic (instance tracking,
## mode-flip handling, etc.) lives in the consuming module
## (``views/spec_pane.nim``), not here.
##
## The native build (``when not defined(js)``) provides inert stubs so
## the headless-VM test pipeline can compile against the same imports
## without a JS runtime.

when defined(js):
  import std/jsffi

  type
    TipTapNamespace* = JsObject
      ## Opaque alias for the JS object assigned to
      ## ``globalThis.TipTap`` by the bundle's entry script.

    TipTapEditor* = JsObject
      ## Opaque handle to a live TipTap ``Editor`` instance.
      ## Returned by ``newEditor`` + threaded through the per-instance
      ## helpers.  The consuming module stores this on its VM (or in
      ## a per-mount local closure) and calls ``destroy`` on re-mount.

    TipTapEditorOptions* = JsObject
      ## Plain-JS-object configuration passed to ``newEditor``.
      ## Construct via ``newEditorOptions`` + the ``set*`` helpers
      ## below; mirrors the documented TipTap option shape
      ## (``element``, ``extensions``, ``content``, ``editable``,
      ## ``onUpdate``).

  var TipTap* {.importc, nodecl.}: TipTapNamespace
    ## Global namespace object the UMD bundle attaches to
    ## ``globalThis`` (see ``isonim/nix/entry-tiptap.mjs``).

  proc isAvailable*(): bool
    {.importjs: "(typeof globalThis !== 'undefined' && !!globalThis.TipTap && !!globalThis.TipTap.Editor)".}
    ## Return true when the bundle is loaded.  Spec-pane fallback path
    ## consults this to decide between TipTap rendering and a raw-
    ## markdown ``<pre>`` rendering.

  proc newEditorOptions*(): TipTapEditorOptions
    {.importjs: "({})".}
    ## Construct an empty option-bag.  Use the setters below to
    ## populate fields.

  proc setElement*(opts: TipTapEditorOptions; el: JsObject)
    {.importjs: "#.element = #".}
  proc setExtensions*(opts: TipTapEditorOptions; exts: JsObject)
    {.importjs: "#.extensions = #".}
  proc setContentOption*(opts: TipTapEditorOptions; content: cstring)
    {.importjs: "#.content = #".}
  proc setEditableOption*(opts: TipTapEditorOptions; editable: bool)
    {.importjs: "#.editable = #".}
  proc setOnUpdate*(opts: TipTapEditorOptions;
                    handler: proc(payload: JsObject)) {.importjs: "#.onUpdate = #".}

  proc newEditor*(ns: TipTapNamespace; opts: TipTapEditorOptions): TipTapEditor
    {.importjs: "(new #.Editor(#))".}
    ## Construct an editor instance bound to ``opts.element``.
    ## Subsequent calls construct fresh instances; the previous
    ## instance MUST be torn down via ``destroy`` first.

  proc destroy*(editor: TipTapEditor)
    {.importjs: "#.destroy()".}
    ## Tear down a TipTap instance.  Safe to call on a ``nil`` /
    ## undefined value (the JS engine treats the call as a no-op).

  proc setEditable*(editor: TipTapEditor; editable: bool)
    {.importjs: "#.setEditable(#)".}
    ## Flip the editor's editable flag.  Used to swap the spec-pane
    ## between View (read-only) and Edit (writable) modes.

  proc isEditable*(editor: TipTapEditor): bool
    {.importjs: "(!!#.isEditable)".}
    ## Report the current editable flag.  The e2e test consults this
    ## to assert View mode is non-editable.

  proc replaceContent*(editor: TipTapEditor; content: cstring; parseMd: bool)
    {.importjs: "#.commands.setContent(#, #)".}
    ## Replace the editor's content with the supplied string.  When
    ## ``parseMd`` is true (and ``tiptap-markdown`` is installed) the
    ## string is parsed as markdown; otherwise it's interpreted as
    ## HTML.

else:
  ## Native-target stub surface.  The spec-pane VM tests compile this
  ## module without ever calling into the runtime, so we keep the
  ## minimal type aliases + no-op procs needed for the import to
  ## type-check.

  type
    TipTapNamespace* = ref object
    TipTapEditor* = ref object
    TipTapEditorOptions* = ref object

  var TipTap*: TipTapNamespace

  proc isAvailable*(): bool = false
  proc newEditorOptions*(): TipTapEditorOptions = TipTapEditorOptions()
  proc setElement*(opts: TipTapEditorOptions; el: pointer) = discard
  proc setExtensions*(opts: TipTapEditorOptions; exts: pointer) = discard
  proc setContentOption*(opts: TipTapEditorOptions; content: cstring) = discard
  proc setEditableOption*(opts: TipTapEditorOptions; editable: bool) = discard
  proc setOnUpdate*(opts: TipTapEditorOptions;
                    handler: proc(payload: pointer)) = discard
  proc newEditor*(ns: TipTapNamespace;
                  opts: TipTapEditorOptions): TipTapEditor = TipTapEditor()
  proc destroy*(editor: TipTapEditor) = discard
  proc setEditable*(editor: TipTapEditor; editable: bool) = discard
  proc isEditable*(editor: TipTapEditor): bool = false
  proc replaceContent*(editor: TipTapEditor;
                       content: cstring; parseMd: bool) = discard
