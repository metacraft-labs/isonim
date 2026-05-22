## TBAR-M5b — vendor/xterm.nim
##
## FFI binding for the ``xterm`` (xterm.js) JS library.  The bundle's
## entry script (``isonim/nix/entry-xterm.mjs``) assigns the
## ``Terminal`` constructor to ``globalThis.XtermTerminal`` and (for
## backwards compat with the existing ``streaming_preview.nim``
## ``{.emit.}`` block) aliases it as ``window.Terminal``.
##
## The new spec-pane code does not consume xterm directly — this
## module exists so the per-library FFI surface is complete and so
## future callers (the streaming-preview consumer, the TUI preview
## chrome) can migrate off the legacy ``window.Terminal`` global to a
## typed binding.

when defined(js):
  import std/jsffi
  import isonim/web/dom_api

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
  proc setConvertEol*(opts: XtermOptions; convert: bool) {.importjs: "#.convertEol = #".}

  proc newTerminal*(ns: XtermNamespace; opts: XtermOptions): XtermTerminalHandle
    {.importjs: "(new #.Terminal(#))".}

  proc open*(term: XtermTerminalHandle; host: Element)
    {.importjs: "#.open(#)".}

  proc write*(term: XtermTerminalHandle; data: cstring)
    {.importjs: "#.write(#)".}

  proc dispose*(term: XtermTerminalHandle)
    {.importjs: "#.dispose()".}

else:
  type
    XtermNamespace* = ref object
    XtermTerminalHandle* = ref object
    XtermOptions* = ref object
    Element* = ref object

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
  proc setConvertEol*(opts: XtermOptions; convert: bool) = discard
  proc newTerminal*(ns: XtermNamespace;
                    opts: XtermOptions): XtermTerminalHandle = XtermTerminalHandle()
  proc open*(term: XtermTerminalHandle; host: Element) = discard
  proc write*(term: XtermTerminalHandle; data: cstring) = discard
  proc dispose*(term: XtermTerminalHandle) = discard
