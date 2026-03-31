## isonim/dsl/transform.nim
##
## AST transform: converts DSL nodes into renderer API calls.
## The compile-time bridge between the user-facing DSL and the rendering backend.

import std/macros
import std/strutils

# Karax-style tag name mapping: Nim keyword conflicts use t-prefix
const tagAliases = {
  "tdiv": "div",
  "tspan": "span",
  "tdl": "dl",
  "tdt": "dt",
  "tdd": "dd",
  "taside": "aside",
  "tobject": "object",
  "tvar": "var",
  "ttype": "type",
  "ttemplate": "template",
  "tblock": "block",
  "tmethod": "method",
  "texport": "export",
  "timport": "import",
  "taddr": "addr",
  "tfor": "for",
}

proc resolveTagName*(name: string): string =
  ## Resolves a Nim identifier to an HTML tag name.
  for (alias, tag) in tagAliases:
    if name == alias:
      return tag
  return name

proc isDynamic*(node: NimNode): bool =
  ## Checks if an expression is dynamic (should be wrapped in an effect).
  ## Static: string/int/float literals, char literals.
  ## Dynamic: everything else (calls, dot exprs, ident, etc.)
  case node.kind
  of nnkStrLit, nnkRStrLit, nnkTripleStrLit:
    return false
  of nnkIntLit .. nnkFloat128Lit:
    return false
  of nnkCharLit:
    return false
  of nnkPrefix:
    # $"literal" is static, $expr is dynamic
    if node[0].kind == nnkIdent and node[0].strVal == "$":
      return isDynamic(node[1])
    return true
  else:
    return true

proc isEventHandler*(name: string): bool =
  ## Checks if an attribute name is an event handler (on*).
  name.len > 2 and name.startsWith("on")

proc eventName*(attrName: string): string =
  ## Extracts event name from on* attribute: "onclick" -> "click"
  attrName[2 .. ^1].toLowerAscii()
