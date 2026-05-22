## TBAR-M5b — vendor/tiptap_starter_kit.nim
##
## FFI binding for ``@tiptap/starter-kit`` — the standard collection
## of TipTap nodes / marks the spec-pane editor needs (paragraph,
## heading, bullet/ordered list, code block, etc.).  The bundle's
## entry script (``isonim/nix/entry-tiptap.mjs``) assigns the
## ``StarterKit`` extension constructor to
## ``globalThis.TipTapStarterKit``.
##
## ``StarterKit`` is itself a TipTap extension factory — calling
## ``StarterKit.configure({...})`` returns an extension instance you
## can drop into the ``extensions`` array passed to ``newEditor``.

when defined(js):
  import std/jsffi

  type
    StarterKitNamespace* = JsObject
      ## ``globalThis.TipTapStarterKit``.

  var TipTapStarterKit* {.importc, nodecl.}: StarterKitNamespace

  proc isAvailable*(): bool
    {.importjs: "(typeof globalThis !== 'undefined' && !!globalThis.TipTapStarterKit && !!globalThis.TipTapStarterKit.StarterKit)".}

  proc configure*(ns: StarterKitNamespace; opts: JsObject): JsObject
    {.importjs: "#.StarterKit.configure(#)".}
    ## Configure the starter-kit extension; returns the extension
    ## instance ready to be added to ``TipTapEditorOptions.extensions``.

  proc default*(ns: StarterKitNamespace): JsObject
    {.importjs: "#.StarterKit".}
    ## The bare extension constructor without configuration overrides.
    ## TipTap accepts either ``StarterKit`` or ``StarterKit.configure({})``
    ## in the extensions array; ``default`` is the path with default
    ## options.

else:
  type
    StarterKitNamespace* = ref object

  var TipTapStarterKit*: StarterKitNamespace

  proc isAvailable*(): bool = false
  proc configure*(ns: StarterKitNamespace; opts: pointer): pointer = nil
  proc default*(ns: StarterKitNamespace): pointer = nil
