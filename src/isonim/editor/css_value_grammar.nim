## CSS value grammars the inspector checks a typed value against before it
## stages a source edit (editor spec "Planned interaction parity": invalid
## values are rejected without changing source). The check fails closed: a
## keyword-shaped value is accepted only as a CSS-wide keyword or by the
## property's own grammar here.
##
## Kept apart from `viewmodels` because the grammars name CSS keywords that
## look like presentation tokens, and the view-model module carries none.

import std/[math, sequtils, strutils]
import isonim/editor/css_color_literal
import isonim/editor/css_compound_values

proc tryParseFloatValue*(raw: string; value: var float): bool =
  try:
    value = raw.parseFloat()
    classify(value) notin {fcNan, fcInf, fcNegInf}
  except ValueError:
    false

func cssFunctionName*(raw: string): string =
  let text = raw.strip().toLowerAscii()
  let paren = text.find('(')
  if paren <= 0:
    return text
  text[0 ..< paren]

func cssFunctionCalls*(raw: string): seq[string] =
  for part in raw.splitWhitespace:
    let fn = cssFunctionName(part)
    if fn.len > 0:
      result.add fn

func isCompleteFunction*(raw: string): bool =
  let text = raw.strip()
  if '(' notin text:
    return true
  text.count('(') == text.count(')') and text.endsWith(")")

func validAspectRatio*(raw: string): bool =
  let text = raw.strip()
  if text in ["auto", "inherit", "initial", "unset"]:
    return true
  let slash = text.find('/')
  if slash <= 0 or slash >= text.len - 1:
    return false
  var left, right: float
  tryParseFloatValue(text[0 ..< slash].strip(), left) and
    tryParseFloatValue(text[slash + 1 .. ^1].strip(), right) and
    left > 0 and right > 0

const cssWideKeywords* = ["inherit", "initial", "unset", "revert", "revert-layer"]
  ## The keywords every property accepts (CSS Cascade 5 §7.3).

func splitCssTokens(text: string): seq[string] =
  ## ``text`` split on whitespace and on top-level commas and slashes, keeping
  ## a function call (`repeat(2, 1fr)`) or a bracketed name list (`[a b]`)
  ## whole. Commas and slashes are tokens of their own.
  var depth = 0
  var current = ""
  for ch in text:
    if ch in {'(', '['}: inc depth
    elif ch in {')', ']'}: dec depth
    if depth == 0 and ch in Whitespace:
      if current.len > 0: result.add current
      current = ""
    elif depth == 0 and ch in {',', '/'}:
      if current.len > 0: result.add current
      result.add $ch
      current = ""
    else:
      current.add ch
  if current.len > 0: result.add current

func commaItems(text: string): seq[string] =
  ## ``text``'s top-level comma-separated items, stripped.
  var depth = 0
  var current = ""
  for ch in text:
    if ch == '(': inc depth
    elif ch == ')': dec depth
    if depth == 0 and ch == ',':
      result.add current.strip()
      current = ""
    else:
      current.add ch
  result.add current.strip()

func cssNumberToken(token: string): bool =
  var value = 0.0
  tryParseFloatValue(token, value)

const cssLengthUnits = ["px", "rem", "em", "vw", "vh", "vmin", "vmax", "ch",
  "ex", "cm", "mm", "in", "pt", "pc", "q", "lh", "rlh", "svw", "svh", "lvw",
  "lvh", "dvw", "dvh", "cqw", "cqh"]

func cssLengthToken(token: string; percent = true): bool =
  ## A length (`4px`, `-1.5rem`, unitless `0`) or, with ``percent``, a
  ## percentage, or a complete `calc()`-family call.
  let text = token.toLowerAscii()
  if text == "0": return true
  if (text.startsWith("calc(") or text.startsWith("min(") or
      text.startsWith("max(") or text.startsWith("clamp(")) and
      isCompleteFunction(text):
    return true
  if percent and text.len > 1 and text.endsWith("%"):
    return cssNumberToken(text[0 ..< text.len - 1])
  for unit in cssLengthUnits:
    if text.len > unit.len and text.endsWith(unit) and
        cssNumberToken(text[0 ..< text.len - unit.len]):
      return true
  false

func cssTimeToken(token: string): bool =
  let text = token.toLowerAscii()
  for unit in ["ms", "s"]:
    if text.len > unit.len and text.endsWith(unit) and
        cssNumberToken(text[0 ..< text.len - unit.len]):
      return true
  false

func cssAllIn(text: string; allowed: openArray[string];
    maxTokens = 1): bool =
  let tokens = text.splitWhitespace()
  tokens.len >= 1 and tokens.len <= maxTokens and
    tokens.allIt(it in allowed)

const alignmentKeywords = ["normal", "stretch", "center", "start", "end",
  "flex-start", "flex-end", "self-start", "self-end", "baseline", "first",
  "last", "safe", "unsafe", "left", "right", "space-between", "space-around",
  "space-evenly", "auto", "legacy", "anchor-center"]
  ## CSS Box Alignment 3 values of the align-*/justify-*/place-* properties.

const displayKeywords = ["block", "inline", "run-in", "flow", "flow-root",
  "table", "flex", "grid", "ruby", "math", "list-item", "contents", "none",
  "inline-block", "inline-flex", "inline-grid", "inline-table",
  "table-row-group", "table-header-group", "table-footer-group", "table-row",
  "table-cell", "table-column-group", "table-column", "table-caption",
  "ruby-base", "ruby-text", "ruby-base-container", "ruby-text-container",
  "-webkit-box", "-webkit-inline-box"]
  ## CSS Display 3 values, plus the legacy `-webkit-box` and
  ## `-webkit-inline-box` that line clamping still needs (CSS Overflow 4
  ## §5.3; the example's card title uses `display: -webkit-box`).

const borderStyleKeywords = ["none", "hidden", "dotted", "dashed", "solid",
  "double", "groove", "ridge", "inset", "outset"]

const listStyleTypeKeywords = ["none", "disc", "circle", "square", "decimal",
  "decimal-leading-zero", "lower-roman", "upper-roman", "lower-greek",
  "lower-alpha", "lower-latin", "upper-alpha", "upper-latin", "armenian",
  "georgian", "hebrew", "cjk-decimal", "cjk-ideographic",
  "cjk-earthly-branch", "cjk-heavenly-stem", "hiragana", "hiragana-iroha",
  "katakana", "katakana-iroha", "japanese-informal", "japanese-formal",
  "korean-hangul-formal", "korean-hanja-informal", "korean-hanja-formal",
  "simp-chinese-informal", "simp-chinese-formal", "trad-chinese-informal",
  "trad-chinese-formal", "ethiopic-numeric", "arabic-indic", "bengali",
  "cambodian", "devanagari", "gujarati", "gurmukhi", "kannada", "khmer",
  "lao", "malayalam", "mongolian", "myanmar", "oriya", "persian", "tamil",
  "telugu", "thai", "tibetan", "disclosure-open", "disclosure-closed"]
  ## The predefined counter styles (CSS Counter Styles 3 §6-7). A project's
  ## own `@counter-style` name is not known to the editor and is refused.

const cssPropertyNames = ["all", "accent-color", "align-content",
  "align-items", "align-self", "aspect-ratio", "backdrop-filter",
  "background", "background-color", "background-image", "background-position",
  "background-repeat", "background-size", "block-size", "border",
  "border-bottom", "border-bottom-color", "border-bottom-left-radius",
  "border-bottom-right-radius", "border-bottom-width", "border-color",
  "border-left", "border-left-color", "border-left-width", "border-radius",
  "border-right", "border-right-color", "border-right-width", "border-top",
  "border-top-color", "border-top-left-radius", "border-top-right-radius",
  "border-top-width", "border-width", "bottom", "box-shadow", "caret-color",
  "clip-path", "color", "column-gap", "fill", "filter", "flex", "flex-basis",
  "flex-grow", "flex-shrink", "font", "font-size", "font-weight", "gap",
  "grid-template-columns", "grid-template-rows", "height", "inline-size",
  "inset", "left", "letter-spacing", "line-height", "margin",
  "margin-bottom", "margin-left", "margin-right", "margin-top", "mask",
  "max-height", "max-width", "min-height", "min-width", "object-position",
  "opacity", "outline", "outline-color", "outline-offset", "outline-width",
  "padding", "padding-bottom", "padding-left", "padding-right",
  "padding-top", "right", "rotate", "row-gap", "scale", "stroke",
  "text-decoration", "text-decoration-color", "text-shadow", "top",
  "transform", "transform-origin", "translate", "visibility", "width",
  "word-spacing", "z-index"]
  ## Property names `transition-property` accepts: the animatable properties
  ## this editor knows (CSS Transitions 1 §2.1), plus custom properties.

func cssCustomIdent(token: string): bool =
  ## A CSS identifier (CSS Syntax 3 §4.3.11): an optional `-` (or `--`), then
  ## a letter or `_`, then letters, digits, `-` and `_`. Escapes and non-ASCII
  ## identifiers are not recognised.
  var i = 0
  if i < token.len and token[i] == '-':
    inc i
    if i < token.len and token[i] == '-': inc i
  if i >= token.len or token[i] notin {'a'..'z', 'A'..'Z', '_'}:
    return token.startsWith("--") and token.len > 2 and
      token[2 .. ^1].allIt(it in {'a'..'z', 'A'..'Z', '0'..'9', '-', '_'})
  token[i .. ^1].allIt(it in {'a'..'z', 'A'..'Z', '0'..'9', '-', '_'})

func validTrackList(text: string): bool =
  ## A grid track list (CSS Grid 2 §7.2): `none`, `subgrid`, `masonry`, or
  ## tracks, each a size, a sizing function or a bracketed line-name list.
  if text in ["none", "subgrid", "masonry"]: return true
  let tokens = splitCssTokens(text)
  if tokens.len == 0: return false
  for token in tokens:
    if token.startsWith("[") and token.endsWith("]"): continue
    if token in ["auto", "min-content", "max-content"]: continue
    if token.len > 2 and token.endsWith("fr") and
        cssNumberToken(token[0 ..< token.len - 2]):
      continue
    if cssLengthToken(token): continue
    let fn = cssFunctionName(token)
    if fn in ["repeat", "minmax", "fit-content"] and isCompleteFunction(token):
      continue
    return false
  true

func validFontShorthand(text: string): bool =
  ## `font`: a system font keyword, or a size (with an optional
  ## `/line-height`) followed by a family (CSS Fonts 4 §2.8).
  if text in ["caption", "icon", "menu", "message-box", "small-caption",
      "status-bar"]:
    return true
  let tokens = splitCssTokens(text)
  for i, token in tokens:
    if (cssLengthToken(token) or token in ["xx-small", "x-small", "small",
        "medium", "large", "x-large", "xx-large", "xxx-large", "smaller",
        "larger"]) and i + 1 < tokens.len:
      return true
  false

func validKeywordForProperty*(propName, raw: string): bool =
  ## Whether a keyword-shaped value is one ``propName`` accepts. Fails closed:
  ## a value is accepted only as a CSS-wide keyword or by the property's own
  ## grammar below; a property this editor has no grammar for accepts only
  ## the CSS-wide keywords (editor spec "Planned interaction parity": invalid
  ## values are rejected without changing source).
  let text = raw.strip().toLowerAscii()
  if text in cssWideKeywords: return true
  case propName
  of "width", "height", "min-width", "min-height", "max-width", "max-height",
      "top", "right", "bottom", "left", "inset", "margin", "margin-top",
      "margin-right", "margin-bottom", "margin-left", "padding", "padding-top",
      "padding-right", "padding-bottom", "padding-left", "gap", "row-gap",
      "column-gap", "font-size", "letter-spacing", "word-spacing", "border-width",
      "border-radius", "border-top-left-radius", "border-top-right-radius",
      "border-bottom-right-radius", "border-bottom-left-radius", "border-top-width", "border-right-width", "border-bottom-width",
      "border-left-width", "outline-offset", "outline-width":
    var numeric = 0.0
    if tryParseFloatValue(text, numeric): return numeric == 0
    if text == "auto": return propName in ["width", "height", "min-width", "min-height",
      "top", "right", "bottom", "left", "inset", "margin", "margin-top", "margin-right", "margin-bottom", "margin-left"]
    if text == "none": return propName in ["max-width", "max-height"]
    if text == "normal": return propName in ["gap", "row-gap", "column-gap", "letter-spacing", "word-spacing"]
    if text in ["min-content", "max-content", "fit-content", "stretch"]:
      return propName in ["width", "height", "min-width", "min-height", "max-width", "max-height"]
    if text in ["thin", "medium", "thick"]:
      return propName.endsWith("-width") and (propName.startsWith("border") or
        propName.startsWith("outline"))
    if propName == "font-size":
      return text in ["xx-small", "x-small", "small", "medium", "large",
        "x-large", "xx-large", "xxx-large", "smaller", "larger", "math"]
    false
  of "overflow", "overflow-x", "overflow-y":
    text in ["visible", "hidden", "clip", "scroll", "auto"]
  of "overscroll-behavior":
    text in ["auto", "contain", "none"]
  of "position":
    text in ["static", "relative", "absolute", "fixed", "sticky"]
  of "border-style", "border-top-style", "border-right-style",
      "border-bottom-style", "border-left-style":
    cssAllIn(text, borderStyleKeywords, if propName == "border-style": 4 else: 1)
  of "outline-style":
    text == "auto" or text in borderStyleKeywords
  of "text" & "-transform":
    text in ["none", "capitalize", "uppercase", "lowercase", "full-width",
      "full-size-kana"]
  of "white-space":
    text in ["normal", "nowrap", "pre", "pre-wrap", "pre-line",
      "break-spaces"]
  of "text" & "-overflow":
    text in ["clip", "ellipsis"]
  of "background-size":
    # `cover`, `contain`, or one or two of `auto` and lengths.
    if text in ["cover", "contain"]: return true
    commaItems(text).allIt(block:
      let parts = it.splitWhitespace()
      parts.len in 1..2 and parts.allIt(it == "auto" or cssLengthToken(it)))
  of "background-position", "object-position":
    commaItems(text).allIt(block:
      let parts = it.splitWhitespace()
      parts.len in 1..4 and parts.allIt(it in ["left", "right", "top",
        "bottom", "center"] or cssLengthToken(it)))
  of "background-repeat":
    commaItems(text).allIt(cssAllIn(it, ["repeat", "repeat-x", "repeat-y",
      "no-repeat", "space", "round"], 2))
  of "background-image":
    commaItems(text).allIt(it == "none" or
      (cssFunctionName(it) in ["url", "image-set", "cross-fade", "element",
        "image", "linear-gradient", "radial-gradient", "conic-gradient",
        "repeating-linear-gradient", "repeating-radial-gradient",
        "repeating-conic-gradient"] and isCompleteFunction(it)))
  of "mix-blend-mode", "background-blend-mode":
    text in ["normal", "multiply", "screen", "overlay", "darken", "lighten",
      "color-dodge", "color-burn", "hard-light", "soft-light", "difference",
      "exclusion", "hue", "saturation", "color", "luminosity", "plus-darker",
      "plus-lighter"]
  of "color", "background-color", "border-color", "border-top-color",
      "border-right-color", "border-bottom-color", "border-left-color",
      "outline-color", "fill", "stroke", "caret-color", "accent-color",
      "text-decoration-color", "column-rule-color":
    if propName == "border-color":
      let tokens = splitCssTokens(text)
      tokens.len in 1..4 and tokens.allIt(isCssColorValue(it))
    elif propName == "outline-color":
      # CSS UI 4 §3.4: `auto | <color>`, and the UA-dependent `invert`.
      text in ["auto", "invert"] or isCssColorValue(text)
    else:
      isCssColorValue(text)
  of "display":
    cssAllIn(text, displayKeywords, 3)
  of "visibility":
    text in ["visible", "hidden", "collapse"]
  of "box-sizing":
    text in ["content-box", "border-box"]
  of "flex-direction":
    text in ["row", "row-reverse", "column", "column-reverse"]
  of "flex-wrap":
    text in ["nowrap", "wrap", "wrap-reverse"]
  of "flex-flow":
    cssAllIn(text, ["row", "row-reverse", "column", "column-reverse",
      "nowrap", "wrap", "wrap-reverse"], 2)
  of "flex-grow", "flex-shrink", "order":
    cssNumberToken(text)
  of "flex-basis":
    text in ["auto", "content", "min-content", "max-content", "fit-content"] or
      cssLengthToken(text)
  of "flex":
    text in ["none", "auto"] or (block:
      let parts = text.splitWhitespace()
      parts.len in 1..3 and parts.allIt(cssNumberToken(it) or
        cssLengthToken(it) or it in ["auto", "content"]))
  of "align-items", "align-content", "align-self", "justify-content",
      "justify-items", "justify-self", "place-items", "place-content",
      "place-self":
    cssAllIn(text, alignmentKeywords, 4)
  of "grid-template-columns", "grid-template-rows", "grid-auto-columns",
      "grid-auto-rows":
    validTrackList(text)
  of "grid-auto-flow":
    cssAllIn(text, ["row", "column", "dense"], 2) and
      not (text.contains("row") and text.contains("column"))
  of "grid-column", "grid-row", "grid-column-start", "grid-column-end",
      "grid-row-start", "grid-row-end", "grid-area", "grid-template-areas",
      "grid-template", "grid", "animation", "animation-name", "will-change",
      "content", "quotes", "counter-reset", "counter-increment",
      "font-feature-settings", "font-variation-settings":
    # These grammars take author-chosen names (grid lines and areas,
    # animation and counter names, strings): any non-empty value.
    text.len > 0
  of "aspect-ratio":
    validAspectRatio(text)
  of "font-family":
    # A family name is any author-chosen identifier or string.
    text.len > 0
  of "box-shadow", "text-shadow":
    text == "none"
  of "font":
    validFontShorthand(text)
  of "font-weight":
    var weight = 0.0
    text in ["normal", "bold", "bolder", "lighter"] or
      (tryParseFloatValue(text, weight) and weight >= 1 and weight <= 1000)
  of "font-style":
    text in ["normal", "italic", "oblique"] or text.startsWith("oblique ")
  of "line-height":
    text == "normal" or cssNumberToken(text) or cssLengthToken(text)
  of "text" & "-align":
    text in ["start", "end", "left", "right", "center", "justify",
      "justify-all", "match-parent"]
  of "text" & "-decoration", "text" & "-decoration-line":
    let tokens = splitCssTokens(text)
    tokens.len >= 1 and tokens.allIt(it in ["none", "underline", "overline",
      "line-through", "blink", "solid", "double", "dotted", "dashed", "wavy",
      "auto", "from-font", "spelling-error", "grammar-error"] or
      cssLengthToken(it) or isCssColorValue(it))
  of "text" & "-decoration-style":
    text in ["solid", "double", "dotted", "dashed", "wavy"]
  of "list-style-type":
    # CSS Lists 3 §3.1: `<counter-style> | <string> | none`. A counter style
    # is a predefined one or the name of an `@counter-style` the project
    # defines, which the editor cannot see, so any custom identifier is
    # taken; `none` and the CSS-wide keywords are handled as keywords.
    text in listStyleTypeKeywords or cssCustomIdent(text) or
      (text.len >= 2 and text[0] in {'"', '\''} and text[^1] == text[0])
  of "text" & "-wrap", "text" & "-wrap-mode", "text" & "-wrap-style":
    cssAllIn(text, ["wrap", "nowrap", "balance", "pretty", "stable", "auto"], 2)
  of "cursor":
    text in ["auto", "default", "none", "context-menu", "help", "pointer",
      "progress", "wait", "cell", "crosshair", "text", "vertical-text",
      "alias", "copy", "move", "no-drop", "not-allowed", "grab", "grabbing",
      "all-scroll", "col-resize", "row-resize", "n-resize", "e-resize",
      "s-resize", "w-resize", "ne-resize", "nw-resize", "se-resize",
      "sw-resize", "ew-resize", "ns-resize", "nesw-resize", "nwse-resize",
      "zoom-in", "zoom-out"] or text.startsWith("url(")
  of "pointer-events":
    text in ["auto", "none", "visiblepainted", "visiblefill",
      "visiblestroke", "visible", "painted", "fill", "stroke", "all",
      "bounding-box"]
  of "user-select":
    text in ["auto", "text", "none", "contain", "all"]
  of "touch-action":
    text in ["auto", "none", "manipulation"] or cssAllIn(text, ["pan-x",
      "pan-left", "pan-right", "pan-y", "pan-up", "pan-down", "pinch-zoom"], 3)
  of "object-fit":
    text in ["fill", "contain", "cover", "none", "scale-down"]
  of "isolation":
    text in ["auto", "isolate"]
  of "z-index":
    text == "auto" or cssNumberToken(text)
  of "transform", "translate", "scale", "rotate":
    text == "none"
  of "transform-origin":
    let parts = text.splitWhitespace()
    parts.len in 1..3 and parts.allIt(it in ["left", "right", "top",
      "bottom", "center"] or cssLengthToken(it))
  else:
    false

func validTransitionValue*(propName, raw: string): bool =
  ## `transition-property`, `-duration` and `-delay`: comma lists of property
  ## names, or of times (CSS Transitions 1 §2.1-2.4).
  let text = raw.strip().toLowerAscii()
  if text in cssWideKeywords or "var(" in text: return true
  let items = commaItems(text)
  case propName
  of "transition-property":
    if text == "none": return true
    items.allIt(it in cssPropertyNames or it.startsWith("--"))
  of "transition-duration", "transition-delay":
    items.allIt(cssTimeToken(it))
  else:
    true

func validShadowValue*(raw: string): bool =
  ## `box-shadow` / `text-shadow`: `none` or shadow layers (CSS Backgrounds 3
  ## §7.1). A reference is a value only by what it resolves to.
  let text = raw.strip().toLowerAscii()
  if text in cssWideKeywords or text == "none": return true
  if "var(" in text or "token(" in text: return true
  parseCssShadowList(raw).ok
