## CHRM-M4 — vendor/tiptap_link.nim
##
## FFI binding for ``@tiptap/extension-link``.  The bundle's entry
## script (``isonim/nix/entry-tiptap.mjs``) assigns the ``Link``
## extension factory to ``globalThis.TipTapLink``.
##
## ``Link`` is a TipTap mark extension that ships the standard
## inline-link affordance (anchor rendering + the ``link`` mark) plus
## ``setLink`` / ``unsetLink`` editor commands.  The CHRM-M4 toolbar
## consumes it for the Link button (Ctrl/Cmd+K).
##
## No ``{.emit.}`` blocks: pure ``{.importjs.}`` typed bindings, in
## keeping with the per-library FFI module discipline TBAR-M5b
## established (vendor/tiptap.nim et al).

when defined(js):
  import std/jsffi

  type
    LinkNamespace* = JsObject
      ## ``globalThis.TipTapLink``.

  var TipTapLink* {.importc, nodecl.}: LinkNamespace

  proc isAvailable*(): bool
    {.importjs: "(typeof globalThis !== 'undefined' && !!globalThis.TipTapLink && !!globalThis.TipTapLink.Link)".}

  proc linkExtension*(ns: LinkNamespace): JsObject
    {.importjs: "#.Link".}
    ## The bare ``Link`` extension class.  Drop it into the editor's
    ## extensions array.  StarterKit does NOT include this extension
    ## by default in TipTap 3.x — installing it here is what makes
    ## ``editor.commands.setLink`` / ``unsetLink`` / ``isActive('link')``
    ## resolve.

  proc configure*(ns: LinkNamespace; opts: JsObject): JsObject
    {.importjs: "#.Link.configure(#)".}
    ## Configure the Link extension.  Useful for setting options
    ## like ``openOnClick: false`` (so clicking a link in the editor
    ## doesn't navigate while editing) or ``autolink: true``.

else:
  type
    LinkNamespace* = ref object

  var TipTapLink*: LinkNamespace

  proc isAvailable*(): bool = false
  proc linkExtension*(ns: LinkNamespace): pointer = nil
  proc configure*(ns: LinkNamespace; opts: pointer): pointer = nil
