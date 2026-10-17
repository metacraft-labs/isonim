## Variant-preserving Tailwind expansion (opt-in via
## `-d:isonimTailwindVariants`).
##
## Compiled twice by the `test-dsl` recipe against the fixture map
## `tests/dsl/tailwind/variant-styles.json` (via
## `-d:tailwindStylesPathOverride=…`), once per mode:
## - default (no switch): the negative control — styles arrive exactly as
##   today (variant conditions dropped, px-stripped values, no metadata or
##   `@`-prefixed keys in the setStyle calls);
## - `-d:isonimTailwindVariants`: variant classes arrive as
##   `@<variant>:`-prefixed keys with units restored from the `units`
##   record, while unlisted variants keep today's flat shape.
##
## Fixture values mirror real Tailwind v4 extractor output
## (`text-decoration-line`, `#fff`, stripped numbers). `md:p-6` carries
## `units` but no `variant`, as the extractor emits for unlisted variants.
##
## C backend only: class expansion to setStyle calls is native-only (the
## ui.nim call site is `when not defined(js)`); on JS, classes pass
## through to the browser untouched, so there is nothing to assert there.
##
## MOCK POLICY (workspace rule: every mock justified in the header).
## Templates build with MockRenderer, the framework's shipped
## in-memory `RendererBackend` (`isonim/testing/mock_dom`), whose
## recorded setStyle calls are the real boundary for asserting what the
## macro expanded each class to. The fixture map mirrors real Tailwind
## v4 extractor output; a live browser style engine would test style
## resolution, not the compile-time expansion this file pins.
import std/tables
import unittest
import isonim/core/[owner, batch]
import isonim/testing/mock_dom
import isonim/dsl/ui
import isonim/dsl/tailwind

template classStyles(lit: untyped): Table[string, string] =
  ## Render `tdiv(class = lit)` and return its styles. `lit` must be a
  ## string literal: only static class strings expand to setStyle calls.
  var res: Table[string, string]
  createRoot do (dispose: proc()):
    let r = MockRenderer()
    let root = ui(r):
      tdiv(class = lit):
        text "x"
    check root.attributes["class"] == lit
    res = root.styles
  res

suite "variant-preserving tailwind expansion":
  test "fixture map loaded through the override":
    check tailwindStyles.len == 5
    check "sm:p-2" in tailwindStyles

  when defined(isonimTailwindVariants):
    test "opt-in: variant classes arrive as @-prefixed keys with units":
      let s = classStyles("sm:p-2 dark:text-white")
      check s.len == 2
      check s["@sm:padding"] == "8px"
      check s["@dark:color"] == "#fff"

    test "opt-in: hover variant and plain-class units":
      let h = classStyles("hover:underline")
      check h.len == 1
      check h["@hover:text-decoration-line"] == "underline"
      let p = classStyles("p-2")
      check p.len == 1
      check p["padding"] == "8px"

    test "opt-in: unlisted variant keeps today's flat shape":
      let m = classStyles("md:p-6")
      check m.len == 1
      check m["padding"] == "24px"
  else:
    test "default: variant conditions dropped as today":
      let s = classStyles("sm:p-2 dark:text-white")
      check s.len == 2
      check s["padding"] == "8"
      check s["color"] == "#fff"
      let h = classStyles("hover:underline")
      check h.len == 1
      check h["text-decoration-line"] == "underline"
      let p = classStyles("p-2")
      check p.len == 1
      check p["padding"] == "8"
      let m = classStyles("md:p-6")
      check m.len == 1
      check m["padding"] == "24"

    test "default: no metadata or @-prefixed keys leak into setStyle calls":
      for styles in [classStyles("sm:p-2 dark:text-white"),
          classStyles("hover:underline"), classStyles("p-2"),
          classStyles("md:p-6")]:
        for key in styles.keys:
          check key != "variant"
          check key != "units"
          check key[0] != '@'
