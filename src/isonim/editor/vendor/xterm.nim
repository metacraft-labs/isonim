## TBAR-M5b — vendor/xterm.nim
##
## FFI binding for the ``xterm`` (xterm.js) JS library.  The bundle's
## entry script (``isonim/nix/entry-xterm.mjs``) assigns the
## ``Terminal`` constructor to ``globalThis.XtermTerminal``.
##
## The streaming-preview TUI consumer (``streaming_preview.nim``)
## migrated off the legacy ``window.Terminal`` global to this typed
## binding; the ``entry-xterm.mjs`` legacy alias was dropped in the
## same change.

when defined(js):
  import std/jsffi

  type
    XtermNamespace* = JsObject
      ## ``globalThis.XtermTerminal``.

    XtermTerminalHandle* = JsObject
      ## Opaque handle to a live ``Terminal`` instance.

    XtermOptions* = JsObject
      ## Plain-JS-object configuration passed to the ``Terminal``
      ## constructor (cols, rows, scrollback, fontFamily, fontSize,
      ## theme, disableStdin, cursorBlink, cursorStyle, ...).

  var XtermTerminal* {.importc, nodecl.}: XtermNamespace

  proc isAvailable*(): bool
    {.importjs: "(typeof globalThis !== 'undefined' && !!globalThis.XtermTerminal && !!globalThis.XtermTerminal.Terminal)".}

  proc newOptions*(): XtermOptions
    {.importjs: "({})".}

  proc setCols*(opts: XtermOptions; cols: int) {.importjs: "#.cols = #".}
  proc setRows*(opts: XtermOptions; rows: int) {.importjs: "#.rows = #".}
  proc setScrollback*(opts: XtermOptions; n: int) {.importjs: "#.scrollback = #".}
  proc setFontFamily*(opts: XtermOptions; family: cstring) {.importjs: "#.fontFamily = #".}
  proc setFontSize*(opts: XtermOptions; size: int) {.importjs: "#.fontSize = #".}
  proc setDisableStdin*(opts: XtermOptions; disabled: bool) {.importjs: "#.disableStdin = #".}
  proc setCursorBlink*(opts: XtermOptions; blink: bool) {.importjs: "#.cursorBlink = #".}
  proc setCursorStyle*(opts: XtermOptions; style: cstring) {.importjs: "#.cursorStyle = #".}
  proc setConvertEol*(opts: XtermOptions; convert: bool) {.importjs: "#.convertEol = #".}
  proc setAllowProposedApi*(opts: XtermOptions; allow: bool)
    {.importjs: "#.allowProposedApi = #".}
  proc setTheme*(opts: XtermOptions; background, foreground: cstring)
    {.importjs: "#.theme = { background: #, foreground: # }".}

  proc newTerminal*(ns: XtermNamespace; opts: XtermOptions): XtermTerminalHandle
    {.importjs: "(new #.Terminal(#))".}

  proc open*(term: XtermTerminalHandle; host: JsObject)
    {.importjs: "#.open(#)".}
    ## ``host`` is a DOM ``Element``.  The parameter is typed as
    ## ``JsObject`` so consumers can pass either an
    ## ``isonim/web/dom_api.Element`` or a ``std/dom.Element`` via a
    ## ``cast[JsObject](...)`` — both resolve to the same JS object at
    ## runtime.  This mirrors how ``vendor/tiptap.setElement`` is
    ## typed.

  proc write*(term: XtermTerminalHandle; data: cstring)
    {.importjs: "#.write(#)".}

  proc dispose*(term: XtermTerminalHandle)
    {.importjs: "#.dispose()".}

else:
  type
    XtermNamespace* = ref object
    XtermTerminalHandle* = ref object
    XtermOptions* = ref object
    JsObject* = ref object
      ## Inert native stub mirroring the JS-target ``JsObject`` so the
      ## shared ``open`` proc signature compiles under both targets.

  var XtermTerminal*: XtermNamespace

  proc isAvailable*(): bool = false
  proc newOptions*(): XtermOptions = XtermOptions()
  proc setCols*(opts: XtermOptions; cols: int) = discard
  proc setRows*(opts: XtermOptions; rows: int) = discard
  proc setScrollback*(opts: XtermOptions; n: int) = discard
  proc setFontFamily*(opts: XtermOptions; family: cstring) = discard
  proc setFontSize*(opts: XtermOptions; size: int) = discard
  proc setDisableStdin*(opts: XtermOptions; disabled: bool) = discard
  proc setCursorBlink*(opts: XtermOptions; blink: bool) = discard
  proc setCursorStyle*(opts: XtermOptions; style: cstring) = discard
  proc setConvertEol*(opts: XtermOptions; convert: bool) = discard
  proc setAllowProposedApi*(opts: XtermOptions; allow: bool) = discard
  proc setTheme*(opts: XtermOptions; background, foreground: cstring) = discard
  proc newTerminal*(ns: XtermNamespace;
                    opts: XtermOptions): XtermTerminalHandle = XtermTerminalHandle()
  proc open*(term: XtermTerminalHandle; host: JsObject) = discard
  proc write*(term: XtermTerminalHandle; data: cstring) = discard
  proc dispose*(term: XtermTerminalHandle) = discard
