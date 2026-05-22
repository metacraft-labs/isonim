// TBAR-M5b: xterm UMD bundle entry point.
//
// Imports the ``Terminal`` constructor from the yarn-managed
// ``xterm`` package and assigns it to ``globalThis.XtermTerminal``.
// The Nim FFI module ``vendor/xterm.nim`` picks the namespace up via
// ``{.importc, nodecl.}``.

import { Terminal } from "xterm";

globalThis.XtermTerminal = { Terminal };
