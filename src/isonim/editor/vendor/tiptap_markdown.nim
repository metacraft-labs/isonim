## TBAR-M5b — vendor/tiptap_markdown.nim
##
## FFI binding for the ``tiptap-markdown`` community extension.  The
## bundle's entry script (``isonim/nix/entry-tiptap.mjs``) assigns the
## extension's ``Markdown`` factory to ``globalThis.TipTapMarkdown``.
##
## ``Markdown`` is a TipTap extension exposing two flows we use:
##
##   1. Parse: when added to the editor's ``extensions`` array, it
##      teaches ``editor.commands.setContent(md, true)`` to interpret
##      its first argument as a markdown string and build the
##      ProseMirror document from the parsed tree.
##   2. Serialize: it attaches a ``storage.markdown.getMarkdown()``
##      helper that re-serialises the current ProseMirror document
##      back to markdown.
##
## Both directions are what TBAR-M5b's real-TipTap Edit mode needs to
## round-trip the user's edits through the daemon's
## ``POST /api/design-review/save-brief`` endpoint without the lossy
## intermediate HTML representation TBAR-M5's textarea overlay
## avoided by side-stepping the round-trip altogether.

when defined(js):
  import std/jsffi
  import isonim/editor/vendor/tiptap as tiptap_core

  type
    MarkdownNamespace* = JsObject
      ## ``globalThis.TipTapMarkdown``.

  var TipTapMarkdown* {.importc, nodecl.}: MarkdownNamespace

  proc isAvailable*(): bool
    {.importjs: "(typeof globalThis !== 'undefined' && !!globalThis.TipTapMarkdown && !!globalThis.TipTapMarkdown.Markdown)".}

  proc markdownExtension*(ns: MarkdownNamespace): JsObject
    {.importjs: "#.Markdown".}
    ## The bare ``Markdown`` extension class.  Drop it into the
    ## editor's ``extensions`` array.

  proc configure*(ns: MarkdownNamespace; opts: JsObject): JsObject
    {.importjs: "#.Markdown.configure(#)".}
    ## Configure the markdown extension.  Useful for setting options
    ## like ``html: false`` / ``linkify: true`` / ``tightLists: true``.

  proc getMarkdown*(editor: tiptap_core.TipTapEditor): cstring
    {.importjs: "#.storage.markdown.getMarkdown()".}
    ## Pull the current editor content as a markdown string.
    ## Requires the ``Markdown`` extension to be installed in the
    ## editor's extensions array — otherwise ``storage.markdown`` is
    ## undefined and this throws.  The consuming module guards the
    ## call with ``isAvailable()`` on startup.

else:
  import isonim/editor/vendor/tiptap as tiptap_core

  type
    MarkdownNamespace* = ref object

  var TipTapMarkdown*: MarkdownNamespace

  proc isAvailable*(): bool = false
  proc markdownExtension*(ns: MarkdownNamespace): pointer = nil
  proc configure*(ns: MarkdownNamespace; opts: pointer): pointer = nil
  proc getMarkdown*(editor: tiptap_core.TipTapEditor): cstring = ""
