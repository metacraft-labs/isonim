// TBAR-M5b: xterm UMD bundle entry point.
//
// Imports the ``Terminal`` constructor from the yarn-managed
// ``xterm`` package and assigns it to ``globalThis.XtermTerminal``.
// The Nim FFI module ``vendor/xterm.nim`` picks the namespace up via
// ``{.importc, nodecl.}``.  An auxiliary ``window.Terminal`` alias is
// also set so existing call-sites that reference the legacy
// ``window.Terminal`` global continue to compile + run without
// touching the (large) ``streaming_preview.nim`` ``{.emit.}`` block
// during this milestone.

import { Terminal } from "xterm";

globalThis.XtermTerminal = { Terminal };

// Legacy back-compat alias: the previous vendored xterm UMD attached
// the constructor directly as ``window.Terminal``.  Keep that name
// available so the streaming-preview ``{.emit.}`` block in
// ``src/isonim/editor/streaming_preview.nim`` (which still references
// ``window.Terminal``) keeps working.  Removing the alias is a
// follow-up clean-up; the FFI module is the new source of truth.
if (typeof window !== "undefined" && !window.Terminal) {
  window.Terminal = Terminal;
}
