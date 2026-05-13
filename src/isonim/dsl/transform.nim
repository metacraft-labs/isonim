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

# CSS style properties recognized by the DSL.
# These are emitted as setStyle calls instead of setAttribute.
const styleProperties* = [
  # Layout (Yoga / flexbox / grid)
  "width", "height", "min-width", "min-height", "max-width", "max-height",
  "padding", "padding-left", "padding-right", "padding-top", "padding-bottom",
  "margin", "margin-left", "margin-right", "margin-top", "margin-bottom",
  "gap", "flex", "flex-grow", "flex-shrink", "flex-wrap",
  "flex-direction", "align-items", "align-self", "justify-content",
  "column-gap", "row-gap", "justify-items", "align-content", "place-items",
  "grid-template-columns", "grid-template-rows", "grid-auto-flow",
  "grid-auto-columns", "grid-auto-rows", "grid-column", "grid-row",
  "display", "position", "top", "right", "bottom", "left", "z-index",
  "overflow", "overflow-x", "overflow-y",
  # Visual
  "background-color", "background", "background-image", "background-size",
  "color", "opacity",
  "font-size", "font-weight", "font-family", "font-style",
  "text-align", "text-decoration", "text-transform", "text-overflow",
  "letter-spacing", "line-height", "white-space", "word-wrap",
  "border", "border-radius", "border-color", "border-width", "border-style",
  "border-top", "border-right", "border-bottom", "border-left",
  "box-shadow", "outline", "cursor", "transition", "list-style",
  "transform", "transform-origin",
  # Scrollbar
  "scrollbar-width",
  # Interaction / sizing model — used by overlay layers that must
  # not capture clicks meant for the underlying canvas (M-EVP-10).
  "pointer-events", "box-sizing", "user-select", "touch-action",
]

proc toStyleName*(nimName: string): string =
  ## Converts a Nim identifier to a CSS property name.
  ## Underscores become hyphens: background_color -> background-color.
  ## Backtick-quoted names (already resolved by the parser) pass through.
  nimName.replace("_", "-")

proc isStyleProperty*(name: string): bool =
  ## Checks if an attribute name (after underscore-to-hyphen conversion)
  ## is a recognized CSS style property.
  let cssName = toStyleName(name)
  for sp in styleProperties:
    if cssName == sp:
      return true
  return false
