## CSS value grammars the inspector checks a typed value against before it
## stages a source edit (editor spec "Planned interaction parity": invalid
## values are rejected without changing source). The check fails closed: a
## keyword-shaped value is accepted only as a CSS-wide keyword or by the
## property's own grammar here.
##
## Kept apart from `viewmodels` because the grammars name CSS keywords that
## look like presentation tokens, and the view-model module carries none.

import std/[math, sequtils, strutils]
from std/unicode import Rune, toUTF8
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

func structuralChars*(text: string): seq[bool] =
  ## For each byte of ``text``, whether it is markup a splitter may act on:
  ## outside a quoted string and not escaped by a backslash (CSS Syntax 3
  ## §4.3.4-4.3.5, §4.3.7). A paren or comma inside `'a)b'` or after `\`
  ## is part of a name or string, not structure.
  result = newSeq[bool](text.len)
  var quote = '\0'
  var i = 0
  while i < text.len:
    let ch = text[i]
    if ch == '\\':
      i += 2
      continue
    if quote != '\0':
      if ch == quote: quote = '\0'
    elif ch in {'"', '\''}:
      quote = ch
    else:
      result[i] = true
    inc i

func unterminatedCss(text: string): bool =
  ## An open quoted string, or a backslash with nothing after it to escape.
  var quote = '\0'
  var i = 0
  while i < text.len:
    let ch = text[i]
    if ch == '\\':
      if i + 1 >= text.len: return true
      i += 2
      continue
    if quote != '\0':
      if ch == quote: quote = '\0'
    elif ch in {'"', '\''}:
      quote = ch
    inc i
  quote != '\0'

func balancedCss*(text: string): bool =
  ## Structural parentheses and brackets nest and close, and no string or
  ## escape is left open.
  if unterminatedCss(text): return false
  let structural = structuralChars(text)
  var depth = 0
  for i, ch in text:
    if not structural[i]: continue
    if ch in {'(', '['}: inc depth
    elif ch in {')', ']'}:
      dec depth
      if depth < 0: return false
  depth == 0

func isCompleteFunction*(raw: string): bool =
  ## Balanced, and when it holds a call, it ends with the call's own `)`.
  let text = raw.strip()
  if not balancedCss(text): return false
  let structural = structuralChars(text)
  var opens = false
  for i, ch in text:
    if structural[i] and ch == '(': opens = true
  not opens or (text.endsWith(")") and structural[text.len - 1])

const cssWideKeywords* = ["inherit", "initial", "unset", "revert", "revert-layer"]
  ## The keywords every property accepts (CSS Cascade 5 §7.3).

func validRatio(text: string): bool =
  ## A `<ratio>` (CSS Values 4 §8.5): a number, optionally `/` a second one.
  ## The editor takes only positive numbers, so no ratio it writes is
  ## degenerate.
  var left, right: float
  let slash = text.find('/')
  if slash < 0:
    return tryParseFloatValue(text.strip(), left) and left > 0
  if slash == 0 or slash >= text.len - 1:
    return false
  tryParseFloatValue(text[0 ..< slash].strip(), left) and
    tryParseFloatValue(text[slash + 1 .. ^1].strip(), right) and
    left > 0 and right > 0

func validAspectRatio*(raw: string): bool =
  ## `aspect-ratio: auto || <ratio>` (CSS Sizing 4 §5.1), or a CSS-wide
  ## keyword.
  let text = raw.strip().toLowerAscii()
  if text in cssWideKeywords or text == "auto":
    return true
  var parts = text.splitWhitespace()
  if parts.len >= 2 and parts[0] == "auto":
    parts = parts[1 .. ^1]
  elif parts.len >= 2 and parts[^1] == "auto":
    parts = parts[0 ..< parts.len - 1]
  parts.len > 0 and "auto" notin parts and validRatio(parts.join(" "))

func splitCssTokens(text: string): seq[string] =
  ## ``text`` split on whitespace and on top-level commas and slashes, keeping
  ## a function call (`repeat(2, 1fr)`) or a bracketed name list (`[a b]`)
  ## whole. Commas and slashes are tokens of their own.
  let structural = structuralChars(text)
  var depth = 0
  var current = ""
  for i, ch in text:
    let markup = structural[i]
    if markup and ch in {'(', '['}: inc depth
    elif markup and ch in {')', ']'}: dec depth
    if markup and depth == 0 and ch in Whitespace:
      if current.len > 0: result.add current
      current = ""
    elif markup and depth == 0 and ch in {',', '/'}:
      if current.len > 0: result.add current
      result.add $ch
      current = ""
    else:
      current.add ch
  if current.len > 0: result.add current

func spaceItems(text: string): seq[string] =
  ## ``text`` split on top-level whitespace only, keeping calls, strings
  ## and bracketed lists whole (`calc(10% - 1px) 0` is two items).
  let structural = structuralChars(text)
  var depth = 0
  var current = ""
  for i, ch in text:
    let markup = structural[i]
    if markup and ch in {'(', '['}: inc depth
    elif markup and ch in {')', ']'}: dec depth
    if markup and depth == 0 and ch in Whitespace:
      if current.len > 0: result.add current
      current = ""
    else:
      current.add ch
  if current.len > 0: result.add current

func commaItems(text: string): seq[string] =
  ## ``text``'s top-level comma-separated items, stripped.
  let structural = structuralChars(text)
  var depth = 0
  var current = ""
  for i, ch in text:
    let markup = structural[i]
    if markup and ch == '(': inc depth
    elif markup and ch == ')': dec depth
    if markup and depth == 0 and ch == ',':
      result.add current.strip()
      current = ""
    else:
      current.add ch
  result.add current.strip()

func cssNumberToken(token: string): bool =
  var value = 0.0
  tryParseFloatValue(token, value)

func cssIntegerText*(token: string): bool =
  ## Whether ``token`` is written as an `<integer>`: an optional sign, then
  ## decimal digits only (CSS Values 4 §5.2: "one or more decimal digits 0
  ## through 9 ... The first digit of an integer may be immediately preceded
  ## by - or +"). A fraction or an exponent makes a `<number>`, not an
  ## integer, whatever its value (`1.0`, `1e2`, `1e0`; CSS Syntax 3 §4.3.12
  ## gives such a number token the type flag "number").
  var i = 0
  if i < token.len and token[i] in {'+', '-'}: inc i
  i < token.len and token[i .. ^1].allIt(it in {'0'..'9'})

const cssLengthUnits* = [
  # Font-relative lengths (CSS Values 4 §6.1.1).
  "em", "rem", "ex", "rex", "cap", "rcap", "ch", "rch", "ic", "ric", "lh",
  "rlh",
  # Viewport-percentage lengths with their small, large and dynamic forms
  # (§6.1.2).
  "vw", "vh", "vi", "vb", "vmin", "vmax", "svw", "svh", "svi", "svb",
  "svmin", "svmax", "lvw", "lvh", "lvi", "lvb", "lvmin", "lvmax", "dvw",
  "dvh", "dvi", "dvb", "dvmin", "dvmax",
  # Absolute lengths (§6.2).
  "cm", "mm", "q", "in", "pt", "pc", "px",
  # Container query lengths (CSS Containment 3 §6.1).
  "cqw", "cqh", "cqi", "cqb", "cqmin", "cqmax"]
  ## Every CSS length unit, lower case; units are ASCII case-insensitive
  ## (CSS Values 4 §6). A property row takes any of them as a value; its unit
  ## chip still offers only the field's own units.

type CssMathType* = enum
  ## The type a math expression resolves to (CSS Values 4 §10.9, reduced to
  ## the base types the editor's properties take). `cmtLengthPercent` is a
  ## sum of a length and a percentage; `cmtAny` is a `var()` reference, whose
  ## type is known only once it resolves.
  cmtInvalid, cmtNumber, cmtLength, cmtPercent, cmtLengthPercent, cmtTime,
  cmtAngle, cmtAny

const
  cssLengthPercentTypes* = {cmtLength, cmtPercent, cmtLengthPercent}
  cssLengthTypes* = {cmtLength}

func cssMathFunctionCall*(token: string;
    allowed: set[CssMathType] = cssLengthPercentTypes): bool

func splitCssDimension*(text: string): tuple[number, unit: string]

func cssLengthToken(token: string; percent = true): bool =
  ## A length (`4px`, `-1.5rem`, unitless `0`) or, with ``percent``, a
  ## percentage, or a complete `calc()`-family call.
  let text = token.toLowerAscii()
  if text == "0": return true
  if cssFunctionName(text) in ["calc", "min", "max", "clamp"]:
    # A math function whose arguments are well formed and of length type.
    return cssMathFunctionCall(text,
      if percent: cssLengthPercentTypes else: cssLengthTypes)
  if percent and text.len > 1 and text.endsWith("%"):
    return cssNumberToken(text[0 ..< text.len - 1])
  let (number, unit) = splitCssDimension(text)
  number.len > 0 and unit in cssLengthUnits and cssNumberToken(number)

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

func cssIdentifier*(text: string): bool =
  ## Whether the whole of ``text`` is one CSS identifier (CSS Syntax 3
  ## §4.3.10): it starts with a letter, `_`, a non-ASCII byte, or `-`
  ## followed by one of those or a second `-`. A word such as `contents`,
  ## `stretch` or `list-item` is an identifier, never a dimension, even when
  ## it ends in letters that spell a unit.
  if text.len == 0: return false
  const nameStart = {'a'..'z', 'A'..'Z', '_', '\x80'..'\xff'}
  const nameChar = nameStart + {'0'..'9', '-'}
  var i = 0
  if text[0] == '-':
    if text.len == 1: return false
    if text[1] != '-' and text[1] notin nameStart: return false
    i = 2
  elif text[0] notin nameStart:
    return false
  while i < text.len:
    if text[i] notin nameChar: return false
    inc i
  true

func splitCssDimension*(text: string): tuple[number, unit: string] =
  ## ``text`` split into a leading CSS number (sign, digits, fraction,
  ## exponent) and the rest. ``number`` is empty when no number leads.
  var i = 0
  if i < text.len and text[i] in {'+', '-'}: inc i
  var digits = false
  while i < text.len and text[i].isDigit:
    inc i
    digits = true
  if i + 1 < text.len and text[i] == '.' and text[i + 1].isDigit:
    inc i
    while i < text.len and text[i].isDigit:
      inc i
    digits = true
  if not digits: return ("", text)
  if i + 1 < text.len and text[i] in {'e', 'E'}:
    var j = i + 1
    if j < text.len and text[j] in {'+', '-'}: inc j
    if j < text.len and text[j].isDigit:
      while j < text.len and text[j].isDigit: inc j
      i = j
  (text[0 ..< i], text[i .. ^1])

const cssMathFunctions = ["calc", "min", "max", "clamp"]
const otherCssMathFunctions = ["round", "mod", "rem", "sin", "cos", "tan",
  "asin", "acos", "atan", "atan2", "pow", "sqrt", "hypot", "log", "exp",
  "abs", "sign"]
  ## The CSS Values 4 math functions (§10.3-10.8) besides
  ## ``cssMathFunctions``. Only an `<integer>` slot takes them
  ## (``integerMathType``); elsewhere the editor does not, as before.

type CssMathValue = object
  ## A math expression's type and, when it folds, its value: numbers, and a
  ## dimension scaled only by numbers, fold (CSS Values 4 §10.10); a sum of
  ## dimensions or a `var()` does not.
  t: CssMathType
  known: bool
  value: float
  unit: string  ## the unit ``value`` is in; empty for a number

func mathInvalid(): CssMathValue = CssMathValue(t: cmtInvalid)

func finiteValue(v: CssMathValue): CssMathValue =
  ## A folded value that is not finite makes the expression invalid (editor
  ## spec: non-finite values are rejected).
  if v.known and classify(v.value) in {fcNan, fcInf, fcNegInf}: mathInvalid()
  else: v

func cssMathCallValue(token: string): CssMathValue

func cssMathOperandValue(token: string): CssMathValue =
  let text = token.toLowerAscii()
  if text.startsWith("(") and text.endsWith(")") and isCompleteFunction(text):
    # A parenthesised sub-expression.
    return cssMathCallValue("calc" & text)
  if cssFunctionName(text) in cssMathFunctions:
    return cssMathCallValue(text)
  if cssFunctionName(text) == "var" and isCompleteFunction(text):
    return CssMathValue(t: cmtAny)
  # The finite numeric constants (CSS Values 4 §10.7.2); `infinity` and
  # `NaN` are not finite and are refused.
  if text == "pi": return CssMathValue(t: cmtNumber, known: true, value: PI)
  if text == "e": return CssMathValue(t: cmtNumber, known: true, value: E)
  let (number, unit) = splitCssDimension(text)
  var value = 0.0
  # A literal too large to be finite (`1e999`) does not parse.
  if number.len == 0 or not tryParseFloatValue(number, value):
    return mathInvalid()
  let t =
    if unit.len == 0: cmtNumber
    elif unit == "%": cmtPercent
    elif unit in cssLengthUnits: cmtLength
    elif unit in ["ms", "s"]: cmtTime
    elif unit in ["deg", "grad", "rad", "turn"]: cmtAngle
    else: cmtInvalid
  if t == cmtInvalid: return mathInvalid()
  CssMathValue(t: t, known: true, value: value, unit: unit)

func addTypes(a, b: CssMathType): CssMathType =
  ## `+` and `-` (§10.9): both sides of one type; a length and a percentage
  ## make a length-percentage.
  if a == cmtInvalid or b == cmtInvalid: return cmtInvalid
  if a == cmtAny: return b
  if b == cmtAny: return a
  if a == b: return a
  if a in cssLengthPercentTypes and b in cssLengthPercentTypes:
    return cmtLengthPercent
  cmtInvalid

func multiplyTypes(a, b: CssMathType): CssMathType =
  ## `*` (§10.9): at least one side is a number.
  if a == cmtInvalid or b == cmtInvalid: return cmtInvalid
  if a == cmtNumber: return b
  if b == cmtNumber: return a
  if a == cmtAny or b == cmtAny: return cmtAny
  cmtInvalid

func addValues(a, b: CssMathValue; subtract: bool): CssMathValue =
  let t = addTypes(a.t, b.t)
  if t == cmtInvalid: return mathInvalid()
  # Values in one unit are summed (and so checked for overflow); a sum
  # across units is not folded.
  let known = a.known and b.known and a.unit == b.unit
  finiteValue(CssMathValue(t: t, known: known, unit: a.unit,
    value: if known: (if subtract: a.value - b.value else: a.value + b.value)
           else: 0.0))

func multiplyValues(a, b: CssMathValue): CssMathValue =
  let t = multiplyTypes(a.t, b.t)
  if t == cmtInvalid: return mathInvalid()
  let known = a.known and b.known
  finiteValue(CssMathValue(t: t, known: known,
    unit: if a.unit.len > 0: a.unit else: b.unit,
    value: if known: a.value * b.value else: 0.0))

func divideValues(a, b: CssMathValue): CssMathValue =
  ## `/` (§10.9): the divisor is a number; one that folds to zero gives a
  ## non-finite result and is refused.
  if a.t == cmtInvalid or b.t notin {cmtNumber, cmtAny}: return mathInvalid()
  if b.known and b.value == 0: return mathInvalid()
  let known = a.known and b.known
  finiteValue(CssMathValue(t: a.t, known: known, unit: a.unit,
    value: if known: a.value / b.value else: 0.0))

func mathSumTokens(text: string): seq[string] =
  ## ``text``'s calc() sum cut into operands and the operators between them
  ## (`+` and `-` standing alone, `*` and `/` anywhere at the top level),
  ## alternating and starting with an operand; empty when it is not so
  ## shaped.
  var tokens: seq[string]
  let structural = structuralChars(text)
  var depth = 0
  var current = ""
  for k, ch in text:
    let markup = structural[k]
    if markup and ch == '(': inc depth
    elif markup and ch == ')': dec depth
    if markup and depth == 0 and ch in Whitespace:
      if current.len > 0: tokens.add current
      current = ""
    elif markup and depth == 0 and ch in {'*', '/'}:
      if current.len > 0: tokens.add current
      tokens.add $ch
      current = ""
    else:
      current.add ch
  if current.len > 0: tokens.add current
  if tokens.len == 0 or tokens.len mod 2 == 0: return @[]
  for i in countup(1, tokens.len - 2, 2):
    if tokens[i] notin ["+", "-", "*", "/"]: return @[]
  tokens

func cssMathSumValue(text: string): CssMathValue =
  ## A calc() sum (CSS Values 4 §10.1, §10.9): products of operands joined
  ## by `+` and `-`, which must be surrounded by whitespace (so `1px+2px` is
  ## one malformed operand). `*` needs a number on one side; `/` needs a
  ## number divisor that does not fold to zero.
  let tokens = mathSumTokens(text)
  if tokens.len == 0: return mathInvalid()
  var total: CssMathValue
  var first = true
  var subtract = false
  var j = 0
  while j < tokens.len:
    var product = cssMathOperandValue(tokens[j])
    while j + 2 < tokens.len and tokens[j + 1] in ["*", "/"]:
      let right = cssMathOperandValue(tokens[j + 2])
      product =
        if tokens[j + 1] == "*": multiplyValues(product, right)
        else: divideValues(product, right)
      if product.t == cmtInvalid: return mathInvalid()
      j += 2
    if product.t == cmtInvalid: return mathInvalid()
    total = if first: product else: addValues(total, product, subtract)
    first = false
    if total.t == cmtInvalid: return mathInvalid()
    # The `+` or `-` before the next product.
    if j + 1 < tokens.len: subtract = tokens[j + 1] == "-"
    j += 2
  total

func cssMathCallValue(token: string): CssMathValue =
  ## The type, and folded value, of a complete `calc()`, `min()`, `max()`
  ## or `clamp()` call: its arguments' common type (§10.9).
  let text = token.strip().toLowerAscii()
  let name = cssFunctionName(text)
  if name notin cssMathFunctions or not isCompleteFunction(text) or
      text.len < name.len + 2:
    return mathInvalid()
  let args = commaItems(text[name.len + 1 ..< text.len - 1])
  case name
  of "calc":
    if args.len != 1: return mathInvalid()
  of "clamp":
    if args.len != 3: return mathInvalid()
  else:
    if args.len < 1: return mathInvalid()
  var values: seq[CssMathValue]
  var t = cmtAny
  for i, arg in args:
    if arg.len == 0: return mathInvalid()
    let v = cssMathSumValue(arg)
    if v.t == cmtInvalid: return mathInvalid()
    t = if i == 0: v.t else: addTypes(t, v.t)
    if t == cmtInvalid: return mathInvalid()
    values.add v
  if name == "calc": return values[0]
  # min(), max() and clamp() over values in one unit fold.
  let known = values.allIt(it.known and it.unit == values[0].unit)
  var folded = 0.0
  if known:
    case name
    of "min": folded = values.mapIt(it.value).min
    of "max": folded = values.mapIt(it.value).max
    else: folded = max(values[0].value, min(values[1].value, values[2].value))
  finiteValue(CssMathValue(t: t, known: known, value: folded,
    unit: values[0].unit))

func cssMathCallType(token: string): CssMathType =
  cssMathCallValue(token).t

func cssMathFunctionCall*(token: string;
    allowed: set[CssMathType] = cssLengthPercentTypes): bool =
  ## A complete `calc()`, `min()`, `max()` or `clamp()` call (CSS Values 4
  ## §10) whose arguments are well-formed and well-typed, resolving to one
  ## of the ``allowed`` types (a `var()`-typed result is taken).
  let t = cssMathCallType(token)
  t != cmtInvalid and (t == cmtAny or t in allowed)

type
  MathDimension = enum
    ## The base types a dimension in a math expression has (CSS Values 4
    ## §10.9 and CSS Typed OM's base types); a percentage is not among them
    ## in an `<integer>` slot, which gives it nothing to resolve against.
    mdLength, mdAngle, mdTime, mdFrequency, mdResolution
  IntegerMathType = object
    ## A math expression's type as an `<integer>` slot reads it (CSS Values 4
    ## §10.9): the power of each base type, carried through `*` and `/`
    ## and judged only for the whole expression, so `2px * 2px / 1px / 1px`
    ## is a number. ``any`` is a `var()`, whose type is known only once it
    ## resolves; it matches every type. Never folded: an `<integer>` slot
    ## rounds and clamps its value (§10.12), so a division by zero or an
    ## infinite result is not an error there.
    ok, any: bool
    powers: array[MathDimension, int]

func intInvalid(): IntegerMathType = IntegerMathType()
func intNumber(): IntegerMathType = IntegerMathType(ok: true)
func intAny(): IntegerMathType = IntegerMathType(ok: true, any: true)
func intOf(d: MathDimension): IntegerMathType =
  result = IntegerMathType(ok: true)
  result.powers[d] = 1

func isNumber(t: IntegerMathType): bool =
  t.ok and (t.any or t.powers.allIt(it == 0))

func sameType(a, b: IntegerMathType): IntegerMathType =
  ## The type of a sum or of arguments that must agree (§10.9): one type;
  ## a `var()` takes the other's.
  if not a.ok or not b.ok: return intInvalid()
  if a.any: return b
  if b.any: return a
  if a.powers == b.powers: a else: intInvalid()

func combine(a, b: IntegerMathType; sign: int): IntegerMathType =
  ## `*` (``sign`` 1) or `/` (``sign`` -1): powers add or subtract.
  if not a.ok or not b.ok: return intInvalid()
  if a.any or b.any: return intAny()
  result = intNumber()
  for d in MathDimension: result.powers[d] = a.powers[d] + sign * b.powers[d]

func dimensionOfUnit(unit: string): tuple[ok: bool, d: MathDimension] =
  if unit in cssLengthUnits: (true, mdLength)
  elif unit in ["deg", "grad", "rad", "turn"]: (true, mdAngle)
  elif unit in ["s", "ms"]: (true, mdTime)
  elif unit in ["hz", "khz"]: (true, mdFrequency)
  elif unit in ["dpi", "dpcm", "dppx", "x"]: (true, mdResolution)
  else: (false, mdLength)

func integerMathCall(token: string): IntegerMathType

func integerMathOperand(token: string): IntegerMathType =
  ## A calc() operand (§10.1): a number or a dimension, a constant
  ## (§10.7.2: `e`, `pi`, `infinity`, `-infinity`, `NaN`), a `var()`, a
  ## parenthesised sum or a math function.
  let text = token.toLowerAscii()
  if text.startsWith("(") and text.endsWith(")") and isCompleteFunction(text):
    return integerMathCall("calc" & text)
  let name = cssFunctionName(text)
  if '(' in text and (name in cssMathFunctions or name in otherCssMathFunctions):
    return integerMathCall(text)
  if name == "var" and isCompleteFunction(text): return intAny()
  if text in ["e", "pi", "infinity", "-infinity", "nan"]: return intNumber()
  let (number, unit) = splitCssDimension(text)
  var value = 0.0
  if number.len == 0 or not tryParseFloatValue(number, value):
    return intInvalid()
  if unit.len == 0: return intNumber()
  let (known, d) = dimensionOfUnit(unit)
  if known: intOf(d) else: intInvalid()

func integerMathSum(text: string): IntegerMathType =
  ## A calc() sum (§10.1), cut as ``cssMathSumValue`` cuts it: products
  ## whose powers are carried, joined by `+` and `-` between terms of one
  ## type.
  let tokens = mathSumTokens(text)
  if tokens.len == 0: return intInvalid()
  var total = IntegerMathType()
  var first = true
  var j = 0
  while j < tokens.len:
    var product = integerMathOperand(tokens[j])
    while j + 2 < tokens.len and tokens[j + 1] in ["*", "/"]:
      product = combine(product, integerMathOperand(tokens[j + 2]),
        if tokens[j + 1] == "*": 1 else: -1)
      j += 2
    if not product.ok: return intInvalid()
    total = if first: product else: sameType(total, product)
    if not total.ok: return intInvalid()
    first = false
    j += 2
  total

func integerMathCall(token: string): IntegerMathType =
  ## The type of a complete math function call (CSS Values 4 §10.2-10.8).
  ## Each argument is a calc() sum, none empty; the arity and argument types
  ## are each function's own:
  ##
  ## * `calc(A)`; `min(A#)`, `max(A#)`, `clamp(A, B, C)`, `hypot(A#)`,
  ##   `mod(A, B)`, `rem(A, B)`: one type, the result's.
  ## * `round([<rounding-strategy>,]? A [, B]?)`: the strategy (`nearest`,
  ##   `up`, `down`, `to-zero`) only first; A and B of one type, B omitted
  ##   only when A is a number.
  ## * `abs(A)`: A's type. `sign(A)`: a number, whatever A's type.
  ## * `sin()`, `cos()`, `tan()`: a number or an angle, giving a number.
  ## * `asin()`, `acos()`, `atan()`: a number, giving an angle;
  ##   `atan2(A, B)`: one type, giving an angle.
  ## * `pow(A, B)`, `sqrt(A)`, `log(A [, B]?)`, `exp(A)`: numbers.
  let text = token.strip().toLowerAscii()
  let name = cssFunctionName(text)
  if (name notin cssMathFunctions and name notin otherCssMathFunctions) or
      not isCompleteFunction(text) or text.len < name.len + 2:
    return intInvalid()
  var args = commaItems(text[name.len + 1 ..< text.len - 1])
  if name == "round" and args.len > 0 and
      args[0] in ["nearest", "up", "down", "to-zero"]:
    args = args[1 .. ^1]
  var types: seq[IntegerMathType]
  for arg in args:
    if arg.len == 0: return intInvalid()
    let t = integerMathSum(arg)
    if not t.ok: return intInvalid()
    types.add t
  func common(ts: seq[IntegerMathType]): IntegerMathType =
    result = intAny()
    for t in ts:
      result = sameType(result, t)
      if not result.ok: return
  let n = types.len
  let angle = intOf(mdAngle)
  case name
  of "calc", "abs":
    if n == 1: types[0] else: intInvalid()
  of "min", "max", "hypot":
    if n >= 1: common(types) else: intInvalid()
  of "clamp":
    if n == 3: common(types) else: intInvalid()
  of "mod", "rem":
    if n == 2: common(types) else: intInvalid()
  of "round":
    if n == 2 or (n == 1 and types[0].isNumber): common(types)
    else: intInvalid()
  of "sign":
    if n == 1: intNumber() else: intInvalid()
  of "sin", "cos", "tan":
    if n == 1 and (types[0].isNumber or sameType(types[0], angle).ok):
      intNumber()
    else: intInvalid()
  of "asin", "acos", "atan":
    if n == 1 and types[0].isNumber: angle else: intInvalid()
  of "atan2":
    if n == 2 and common(types).ok: angle else: intInvalid()
  of "pow":
    if n == 2 and types.allIt(it.isNumber): intNumber() else: intInvalid()
  of "sqrt", "exp":
    if n == 1 and types[0].isNumber: intNumber() else: intInvalid()
  of "log":
    if n in 1 .. 2 and types.allIt(it.isNumber): intNumber()
    else: intInvalid()
  else: intInvalid()

type CssComponentCheck* = proc(property, value: string): bool {.closure.}
  ## Whether ``value``, one component or sample value, passes
  ## ``property``'s single-value rules (units, ranges, keywords).

proc cssMathTypesFor*(propName: string; single: CssComponentCheck):
    set[CssMathType] =
  ## The math result types ``propName`` takes, derived from its own
  ## single-value rule so the two cannot drift: a type is allowed when a
  ## plain value of that type is (`1px`, `10%`, `1`, `1s`, `1deg`).
  if propName == "transform":
    # A transform list holds functions only (CSS Transforms 1 §6).
    return {}
  if single(propName, "1px"): result.incl cmtLength
  if single(propName, "10%"): result.incl cmtPercent
  if cmtLength in result and cmtPercent in result:
    result.incl cmtLengthPercent
  if single(propName, "1"): result.incl cmtNumber
  if single(propName, "1s"): result.incl cmtTime
  if single(propName, "1deg"): result.incl cmtAngle

func lengthPercentToken(token: string; percent = true;
    negative = true): bool =
  ## A `<length>` (any CSS length unit, or unitless `0`), with ``percent``
  ## a `<length-percentage>`, or a math function. Without ``negative`` a
  ## literal below zero is refused (a math function is range-checked at
  ## computed-value time, CSS Values 4 §10.12).
  let text = token.toLowerAscii()
  if cssFunctionName(text) in cssMathFunctions:
    return cssMathFunctionCall(text,
      if percent: cssLengthPercentTypes else: cssLengthTypes)
  if cssFunctionName(text) == "var" and isCompleteFunction(text): return true
  if not cssLengthToken(text, percent): return false
  if negative: return true
  let (number, _) = splitCssDimension(text)
  var value = 0.0
  tryParseFloatValue(number, value) and value >= 0

func validPositionLayer(parts: seq[string]; threeValues: bool): bool =
  ## One `<bg-position>` (CSS Backgrounds 3 §3.6) or, without
  ## ``threeValues``, one `<position>` (CSS Values 4 §8.3), which has no
  ## three-value form.
  const horizontal = ["left", "right"]
  const vertical = ["top", "bottom"]
  func lp(token: string): bool = lengthPercentToken(token)
  case parts.len
  of 1:
    parts[0] in ["left", "center", "right", "top", "bottom"] or lp(parts[0])
  of 2:
    ((parts[0] in ["left", "center", "right"] or lp(parts[0])) and
      (parts[1] in ["top", "center", "bottom"] or lp(parts[1]))) or
      (parts[0] in ["top", "bottom", "center"] and
        parts[1] in ["left", "right", "center"])
  of 3, 4:
    if parts.len == 3 and not threeValues: return false
    # Two keyword groups, one per axis; an offset may follow any keyword
    # but `center`.
    var groups: seq[tuple[keyword: string, offset: bool]]
    var i = 0
    while i < parts.len:
      let keyword = parts[i]
      if keyword notin ["left", "right", "top", "bottom", "center"]:
        return false
      var offset = false
      if i + 1 < parts.len and lp(parts[i + 1]):
        if keyword == "center": return false
        offset = true
        inc i
      groups.add (keyword, offset)
      inc i
    if groups.len != 2: return false
    let a = groups[0].keyword
    let b = groups[1].keyword
    if a == "center" and b == "center": return false
    if (a in horizontal and b in horizontal) or
        (a in vertical and b in vertical):
      return false
    true
  else:
    false

func validBackgroundSize(text: string): bool =
  ## `background-size` (CSS Backgrounds 3 §3.9): per layer `cover`,
  ## `contain`, or one or two of `auto` and non-negative lengths or
  ## percentages.
  commaItems(text).allIt(block:
    let parts = spaceItems(it)
    (parts.len == 1 and parts[0] in ["cover", "contain"]) or
      (parts.len in 1..2 and parts.allIt(it == "auto" or
        lengthPercentToken(it, negative = false))))

func validTextDecoration(text: string; shorthand: bool): bool =
  ## `text-decoration-line` (CSS Text Decoration 4 §2.1) and, with
  ## ``shorthand``, `text-decoration` (§2.6): the line, style, color and
  ## thickness, each at most once and in any order.
  let tokens = splitCssTokens(text)
  if tokens.len == 0: return false
  var lines: seq[string]
  var lineAlone, style, color, thickness = false
  for token in tokens:
    if token in ["none", "spelling-error", "grammar-error"]:
      if lineAlone or lines.len > 0: return false
      lineAlone = true
    elif token in ["underline", "overline", "line-through", "blink"]:
      if lineAlone or token in lines: return false
      lines.add token
    elif not shorthand:
      return false
    elif token in ["solid", "double", "dotted", "dashed", "wavy"]:
      if style: return false
      style = true
    elif token in ["auto", "from-font"] or lengthPercentToken(token):
      if thickness: return false
      thickness = true
    elif isCssColorValue(token):
      if color: return false
      color = true
    else:
      return false
  true

# Whole-value grammars. A property row's single-value rules judge one value
# at a time; these accept the lists, multi-component values and function
# arguments those rules cannot see. Each answers only "valid": a value one of
# them does not accept is left to the single-value rules, which refuse it
# with their own reason (editor spec "Planned interaction parity": a value
# valid for its property is written; invalid values are rejected).


func cssVarCall(token: string): bool =
  cssFunctionName(token) == "var" and isCompleteFunction(token)

func functionArguments(token: string): seq[string] =
  ## The top-level comma-separated arguments of the call ``token``.
  let paren = token.find('(')
  if paren < 0 or not token.endsWith(")"): return @[]
  let inner = token[paren + 1 ..< token.len - 1]
  if inner.strip().len == 0: return @[]
  commaItems(inner)

func numberToken(token: string; min = NegInf; max = Inf): bool =
  var value = 0.0
  if cssFunctionName(token) in cssMathFunctions:
    return cssMathFunctionCall(token, {cmtNumber})
  tryParseFloatValue(token, value) and value >= min and value <= max

func integerToken(token: string; min: int): bool =
  var value = 0.0
  tryParseFloatValue(token, value) and value == floor(value) and
    value >= float(min) and token.allIt(it in {'0'..'9', '+', '-'})

func numberPercentToken(token: string; negative = true): bool =
  if cssFunctionName(token) in cssMathFunctions:
    return cssMathFunctionCall(token, {cmtNumber, cmtPercent})
  if token.len > 1 and token.endsWith("%"):
    return numberToken(token[0 ..< token.len - 1],
      min = (if negative: NegInf else: 0.0))
  numberToken(token, min = (if negative: NegInf else: 0.0))

func angleToken(token: string): bool =
  ## An `<angle>` or, as transform and filter functions allow, `<zero>`.
  if token == "0": return true
  if cssFunctionName(token) in cssMathFunctions:
    return cssMathFunctionCall(token, {cmtAngle})
  let (number, unit) = splitCssDimension(token)
  var value = 0.0
  number.len > 0 and unit in ["deg", "grad", "rad", "turn"] and
    tryParseFloatValue(number, value)

func timeToken(token: string; negative: bool): bool =
  ## A `<time>` (CSS Values 4 §7.2); a unitless number is not one.
  if cssFunctionName(token) in cssMathFunctions:
    return cssMathFunctionCall(token, {cmtTime})
  let (number, unit) = splitCssDimension(token)
  var value = 0.0
  number.len > 0 and unit in ["ms", "s"] and
    tryParseFloatValue(number, value) and (negative or value >= 0)

func validTransitionTimes(propName, text: string): bool =
  ## `transition-duration` (CSS Transitions 1 §2.2: non-negative times) and
  ## `transition-delay` (§2.4: any times, negative ones start part-way).
  let items = commaItems(text)
  items.len > 0 and items.allIt(cssVarCall(it) or
    timeToken(it, negative = propName == "transition-delay"))

func validEasingFunction(item: string): bool =
  ## One `<easing-function>` (CSS Easing 2 §2).
  if item in ["linear", "ease", "ease-in", "ease-out", "ease-in-out",
      "step-start", "step-end"] or cssVarCall(item):
    return true
  if not isCompleteFunction(item): return false
  let args = functionArguments(item)
  case cssFunctionName(item)
  of "cubic-bezier":
    # §3.2: x coordinates lie in [0, 1].
    args.len == 4 and numberToken(args[0], 0, 1) and numberToken(args[1]) and
      numberToken(args[2], 0, 1) and numberToken(args[3])
  of "steps":
    # §4.1: `steps(<integer>, <step-position>?)`; `jump-none` needs two.
    if args.len notin 1..2 or not integerToken(args[0], 1): return false
    if args.len == 1: return true
    if args[1] notin ["jump-start", "jump-end", "jump-none", "jump-both",
        "start", "end"]:
      return false
    args[1] != "jump-none" or integerToken(args[0], 2)
  of "linear":
    # §2.1: stops of a number and up to two percentages, in either order.
    if args.len < 2: return false
    for stop in args:
      let parts = stop.splitWhitespace()
      if parts.len notin 1..3: return false
      let numberAt = if numberToken(parts[0]): 0 else: parts.len - 1
      if not numberToken(parts[numberAt]): return false
      for i, part in parts:
        if i != numberAt and not (part.len > 1 and part.endsWith("%") and
            numberToken(part[0 ..< part.len - 1])):
          return false
      if numberAt != 0 and numberAt != parts.len - 1: return false
    true
  else:
    false

func validTimingFunctionList*(text: string): bool =
  let items = commaItems(text)
  items.len > 0 and items.allIt(validEasingFunction(it))

func validTransformFunction(token: string): bool =
  ## One `<transform-function>` (CSS Transforms 1 §11, Transforms 2 §13)
  ## with its argument count and types.
  if cssVarCall(token): return true
  if not isCompleteFunction(token) or '(' notin token: return false
  let args = functionArguments(token)
  if args.anyIt(cssVarCall(it)): return true
  func lp(arg: string): bool = lengthPercentToken(arg)
  func length(arg: string): bool = lengthPercentToken(arg, percent = false)
  func num(arg: string): bool = numberToken(arg)
  func scaleArg(arg: string): bool = numberPercentToken(arg)
  case cssFunctionName(token)
  of "translate": args.len in 1..2 and args.allIt(lp(it))
  of "translatex", "translatey": args.len == 1 and lp(args[0])
  of "translatez": args.len == 1 and length(args[0])
  of "translate3d":
    args.len == 3 and lp(args[0]) and lp(args[1]) and length(args[2])
  of "scale": args.len in 1..2 and args.allIt(scaleArg(it))
  of "scalex", "scaley", "scalez": args.len == 1 and scaleArg(args[0])
  of "scale3d": args.len == 3 and args.allIt(scaleArg(it))
  of "rotate", "rotatex", "rotatey", "rotatez":
    args.len == 1 and angleToken(args[0])
  of "rotate3d":
    args.len == 4 and num(args[0]) and num(args[1]) and num(args[2]) and
      angleToken(args[3])
  of "skew": args.len in 1..2 and args.allIt(angleToken(it))
  of "skewx", "skewy": args.len == 1 and angleToken(args[0])
  of "matrix": args.len == 6 and args.allIt(num(it))
  of "matrix3d": args.len == 16 and args.allIt(num(it))
  of "perspective":
    args.len == 1 and (args[0] == "none" or
      lengthPercentToken(args[0], percent = false, negative = false))
  else: false

func validTransformList*(text: string): bool =
  ## `transform: none | <transform-list>` (CSS Transforms 1 §6).
  let tokens = splitCssTokens(text)
  tokens.len > 0 and tokens.allIt(it notin [",", "/"] and
    validTransformFunction(it))

func validUrlCall*(token: string): bool =
  ## A complete `url()` (CSS Values 4 §4.5, CSS Syntax 3 §4.3.6): one quoted
  ## string, or an unquoted URL with no whitespace, quotes or parentheses
  ## (a backslash escapes the next character).
  if cssFunctionName(token) != "url" or not token.endsWith(")"): return false
  let inner = token[token.find('(') + 1 ..< token.len - 1].strip()
  # An empty `url()` is a well-formed url token that resolves to an invalid
  # resource (CSS Values 4 §4.5.1), so the value is valid.
  if inner.len == 0: return true
  if inner[0] in {'"', '\''}:
    var i = 1
    while i < inner.len and inner[i] != inner[0]:
      if inner[i] == '\\': inc i
      inc i
    return i == inner.len - 1
  var i = 0
  while i < inner.len:
    if inner[i] == '\\':
      # An escape needs a character after it, and a newline cannot be
      # escaped in a URL (CSS Syntax 3 §4.3.6, §4.3.8): `url(a\)` would
      # escape its own `)` and swallow what follows it.
      if i + 1 >= inner.len or inner[i + 1] in {'\n', '\r', '\f'}:
        return false
      i += 2
      continue
    if inner[i] in Whitespace + {'"', '\'', '(', ')'}: return false
    inc i
  true

func validFilterFunction(token: string): bool =
  ## One `<filter-function>` or `<url>` (Filter Effects 1 §5-6).
  if cssVarCall(token): return true
  if not isCompleteFunction(token) or '(' notin token: return false
  let name = cssFunctionName(token)
  if name == "url": return validUrlCall(token)
  let args = functionArguments(token)
  if args.anyIt(cssVarCall(it)): return true
  case name
  of "blur":
    args.len == 0 or (args.len == 1 and
      lengthPercentToken(args[0], percent = false, negative = false))
  of "brightness", "contrast", "grayscale", "invert", "opacity", "saturate",
      "sepia":
    args.len == 0 or (args.len == 1 and numberPercentToken(args[0],
      negative = false))
  of "hue-rotate":
    args.len == 0 or (args.len == 1 and angleToken(args[0]))
  of "drop-shadow":
    # `drop-shadow( [ <color>? && <length>{2,3} ] )`; the blur is not
    # negative.
    if args.len != 1: return false
    var lengths: seq[string]
    var colors = 0
    var group = -1
    for part in splitCssTokens(args[0]):
      if lengthPercentToken(part, percent = false):
        if group == 1: return false
        group = 0
        lengths.add part
      elif isCssColorValue(part):
        inc colors
        if group == 0 and lengths.len > 0: group = 1
      else:
        return false
    lengths.len in 2..3 and colors <= 1 and (lengths.len < 3 or
      lengthPercentToken(lengths[2], percent = false, negative = false))
  else:
    false

func validFilterList*(text: string): bool =
  ## `filter` / `backdrop-filter: none | <filter-value-list>`.
  if text == "none": return true
  let tokens = splitCssTokens(text)
  tokens.len > 0 and tokens.allIt(it notin [",", "/"] and
    validFilterFunction(it))

func validTrackBreadth(token: string; flexible = true): bool =
  if token in ["auto", "min-content", "max-content"]: return true
  if flexible and token.len > 2 and token.endsWith("fr"):
    return numberToken(token[0 ..< token.len - 2], min = 0)
  lengthPercentToken(token, negative = false)

func validTrackSize(token: string): bool =
  ## `<track-size>` (CSS Grid 2 §7.2.1).
  if validTrackBreadth(token): return true
  if not isCompleteFunction(token) or '(' notin token: return false
  let args = functionArguments(token)
  case cssFunctionName(token)
  of "minmax":
    args.len == 2 and validTrackBreadth(args[0], flexible = false) and
      validTrackBreadth(args[1])
  of "fit-content":
    args.len == 1 and lengthPercentToken(args[0], negative = false)
  else:
    false

func validLineNames(token: string): bool =
  token.len >= 2 and token[0] == '[' and token[^1] == ']' and
    token[1 ..< token.len - 1].splitWhitespace().allIt(cssIdentifier(it))

func validFixedSize(token: string): bool =
  ## `<fixed-size>` (CSS Grid 2 §7.2.1): a `<fixed-breadth>` (a
  ## non-negative length or percentage), or `minmax()` with one fixed side.
  if lengthPercentToken(token, negative = false): return true
  if cssFunctionName(token) != "minmax" or not isCompleteFunction(token):
    return false
  let args = functionArguments(token)
  args.len == 2 and (
    (lengthPercentToken(args[0], negative = false) and
      validTrackBreadth(args[1])) or
    (validTrackBreadth(args[0], flexible = false) and
      lengthPercentToken(args[1], negative = false)))

type TrackListShape = object
  ok, fixed: bool  ## well-formed; every track a fixed size
  tracks, autoRepeats: int

func trackListShape(text: string; insideRepeat: bool): TrackListShape =
  ## The tracks of a `<track-list>`/`<auto-track-list>` (CSS Grid 2 §7.2):
  ## line-name lists never adjacent, `repeat()` not nested, and its count
  ## and tracks checked.
  let tokens = splitCssTokens(text)
  result.fixed = true
  var lastWasNames = false
  for token in tokens:
    if token in [",", "/"]: return
    if validLineNames(token):
      if lastWasNames: return
      lastWasNames = true
      continue
    lastWasNames = false
    if validTrackSize(token):
      inc result.tracks
      if not validFixedSize(token): result.fixed = false
      continue
    if insideRepeat or cssFunctionName(token) != "repeat" or
        not isCompleteFunction(token):
      return
    let args = functionArguments(token)
    if args.len != 2: return
    let inner = trackListShape(args[1], insideRepeat = true)
    if not inner.ok or inner.tracks == 0: return
    if args[0] in ["auto-fill", "auto-fit"]:
      # §7.2.3.1: an auto repeat repeats fixed sizes only.
      if not inner.fixed: return
      inc result.autoRepeats
    elif integerToken(args[0], 1):
      if not inner.fixed: result.fixed = false
    else:
      return
    inc result.tracks
  result.ok = true

func validStrictTrackList(text: string): bool =
  ## A `<track-list>` or `<auto-track-list>` (CSS Grid 2 §7.2). An
  ## `<auto-track-list>` has exactly one auto repeat, and its other tracks
  ## are fixed sizes (§7.2.3.1).
  let shape = trackListShape(text, insideRepeat = false)
  shape.ok and shape.tracks > 0 and (shape.autoRepeats == 0 or
    (shape.autoRepeats == 1 and shape.fixed))

const boxComponentCounts = [("margin", 4), ("padding", 4), ("inset", 4),
  ("border-width", 4), ("gap", 2), ("overflow", 2),
  ("border-top-left-radius", 2), ("border-top-right-radius", 2),
  ("border-bottom-right-radius", 2), ("border-bottom-left-radius", 2)]
  ## Properties that take up to N space-separated values, each one the
  ## property's own single value (CSS Box 4 §3-4, Backgrounds 3 §4.4, Box
  ## Alignment 3 §8.3, Overflow 3 §3.1, Backgrounds 3 §5.1).

func multiComponentLimit*(propName: string): int =
  ## How many space-separated values ``propName`` takes as a list of its own
  ## single values (`boxComponentCounts`, border-radius per side of its
  ## `/`); 0 for a property that takes no such list.
  if propName == "border-radius": return 4
  for (name, most) in boxComponentCounts:
    if name == propName: return most
  0

func cssSpaceItems*(text: string): seq[string] =
  ## ``text`` split on top-level whitespace, keeping calls, strings and
  ## bracketed lists whole.
  spaceItems(text)

proc validComponents(propName: string; parts: seq[string]; most: int;
    component: CssComponentCheck): bool =
  # A CSS-wide keyword is a value only on its own (CSS Cascade 5 §7.3), never
  # one component among others.
  parts.len in 1..most and parts.allIt(it notin cssWideKeywords and
    (cssVarCall(it) or component(propName, it)))

proc validMultiComponent(propName, text: string;
    component: CssComponentCheck): bool =
  let tokens = splitCssTokens(text)
  if tokens.len < 2 or "," in tokens: return false
  if propName == "border-radius":
    # `<length-percentage>{1,4} [ / <length-percentage>{1,4} ]?`.
    let slash = tokens.find("/")
    if slash < 0:
      return validComponents(propName, tokens, 4, component)
    if tokens.count("/") != 1: return false
    return validComponents(propName, tokens[0 ..< slash], 4, component) and
      validComponents(propName, tokens[slash + 1 .. ^1], 4, component)
  if "/" in tokens: return false
  for (name, most) in boxComponentCounts:
    if name == propName:
      return validComponents(propName, tokens, most, component)
  false

const sizingProperties = ["width", "height", "min-width", "min-height",
  "max-width", "max-height"]

proc cssValueAcceptedByGrammar*(propName, raw: string;
    component: CssComponentCheck): bool =
  ## Whether ``raw`` is valid for ``propName`` by a whole-value grammar:
  ## a CSS-wide keyword, a multi-component or list value, or a function
  ## whose arguments are checked. False means only "not shown valid here":
  ## the row's single-value rules then decide. Text carrying a priority,
  ## a comment or a declaration boundary is never a value.
  let text = raw.strip().toLowerAscii()
  if text.len == 0 or text.contains({'!', ';', '{', '}'}) or "/*" in text:
    return false
  if text in cssWideKeywords: return true
  if not balancedCss(text): return false
  if validMultiComponent(propName, text, component): return true
  let single = splitCssTokens(text).len == 1
  if single and cssFunctionName(text) in cssMathFunctions:
    # One math function, of a type the property's own values have.
    let allowed = cssMathTypesFor(propName, component)
    return allowed.len > 0 and cssMathFunctionCall(text, allowed)
  if single and propName in sizingProperties and
      cssFunctionName(text) == "fit-content":
    # CSS Sizing 4 §3.1: `fit-content(<length-percentage [0,∞]>)`.
    let args = functionArguments(text)
    return isCompleteFunction(text) and args.len == 1 and
      lengthPercentToken(args[0], negative = false)
  case propName
  of "background-position":
    commaItems(text).allIt(validPositionLayer(spaceItems(it), true))
  of "object-position":
    validPositionLayer(spaceItems(text), false)
  of "background-size":
    validBackgroundSize(text)
  of "transition-duration", "transition-delay":
    validTransitionTimes(propName, text)
  of "transition-timing-function":
    validTimingFunctionList(text)
  of "text" & "-decoration":
    validTextDecoration(text, true)
  of "grid-template-columns", "grid-template-rows":
    validStrictTrackList(text)
  of "transform":
    validTransformList(text)
  of "filter", "backdrop-filter":
    validFilterList(text)
  of "aspect-ratio":
    validAspectRatio(text)
  else:
    false

func stripCssComments*(raw: string): tuple[ok: bool, text: string] =
  ## ``raw`` with each `/* ... */` outside a string or an unquoted `url()`
  ## removed (CSS Syntax 3 §4.3.2: a comment is not part of the value). A
  ## comment ends the token before it and separates it from the next, so it
  ## becomes a space. Inside a math function (`calc()`, `min()`, `max()`,
  ## `clamp()` and parentheses nested in them) a comment touching a `+` or
  ## `-` with no real whitespace on its other side is neither the whitespace
  ## an operator needs (CSS Values 4 §10.1) nor part of a signed number
  ## (`-/**/1px` is a `-` and then `1px`), so it becomes a character no math
  ## operand can hold, and the expression is refused. ``ok`` is false when a
  ## comment is left open.
  const nameChars = {'a'..'z', 'A'..'Z', '0'..'9', '-', '_'}
  result.ok = true
  var quote = '\0'
  var mathStack: seq[bool]  ## for each open parenthesis: inside math?
  var i = 0
  while i < raw.len:
    let ch = raw[i]
    if quote != '\0':
      result.text.add ch
      if ch == '\\' and i + 1 < raw.len:
        result.text.add raw[i + 1]
        inc i
      elif ch == quote:
        quote = '\0'
    elif ch == '\\' and i + 1 < raw.len:
      result.text.add ch
      result.text.add raw[i + 1]
      inc i
    elif ch in {'"', '\''}:
      quote = ch
      result.text.add ch
    elif ch == '(':
      var start = result.text.len
      while start > 0 and result.text[start - 1] in nameChars: dec start
      let name = result.text[start .. ^1].toLowerAscii()
      if name == "url":
        # An unquoted url token holds `/*` literally (CSS Syntax 3
        # §4.3.6): copy it to its `)`. A quoted one is a string.
        var j = i + 1
        while j < raw.len and raw[j] in Whitespace: inc j
        if j >= raw.len or raw[j] notin {'"', '\''}:
          while i < raw.len and raw[i] != ')':
            if raw[i] == '\\' and i + 1 < raw.len:
              result.text.add raw[i]
              inc i
            result.text.add raw[i]
            inc i
          if i < raw.len: result.text.add ')'
          inc i
          continue
      let enclosingMath = mathStack.len > 0 and mathStack[^1]
      mathStack.add(name in ["calc", "min", "max", "clamp"] or
        (name.len == 0 and enclosingMath))
      result.text.add ch
    elif ch == ')':
      if mathStack.len > 0: discard mathStack.pop()
      result.text.add ch
    elif ch == '/' and i + 1 < raw.len and raw[i + 1] == '*':
      let close = raw.find("*/", i + 2)
      if close < 0:
        result.ok = false
        return
      let before = if result.text.len > 0: result.text[^1] else: ' '
      let after = if close + 2 < raw.len: raw[close + 2] else: ' '
      let inMath = mathStack.len > 0 and mathStack[^1]
      # A sign right after the comment that is followed by whitespace is an
      # operator, and needs real whitespace before it; one followed by a
      # digit starts a signed number, which may follow `*`, `/`, `(` or `,`.
      let afterSign = if close + 3 < raw.len: raw[close + 3] else: ' '
      let signTouch = inMath and (
        (before in {'+', '-'} and after notin Whitespace) or
        (after in {'+', '-'} and before notin Whitespace and
          afterSign in Whitespace))
      result.text.add(if signTouch: '\x01' else: ' ')
      i = close + 1
    else:
      result.text.add ch
    inc i

func validFontFamilyList*(raw: string): bool =
  ## `font-family` (CSS Fonts 4 §2.1): a comma-separated list of family
  ## names, each a quoted string or a sequence of identifiers. A one-word
  ## family that is a CSS-wide keyword or `default` must be quoted. A value
  ## built from `var()` is judged by what it resolves to.
  let text = raw.strip()
  if text.toLowerAscii() in cssWideKeywords or "var(" in text: return true
  var items: seq[string]
  var current = ""
  var quote = '\0'
  var i = 0
  while i < text.len:
    let ch = text[i]
    if quote != '\0':
      current.add ch
      if ch == '\\' and i + 1 < text.len:
        current.add text[i + 1]
        inc i
      elif ch == quote:
        quote = '\0'
    elif ch == '\\':
      # An escaped character, `\,` included, belongs to the name; a newline
      # cannot be escaped outside a string (CSS Syntax 3 §4.3.8).
      if i + 1 >= text.len or text[i + 1] in {'\n', '\r', '\f'}: return false
      current.add ch
      current.add text[i + 1]
      inc i
    elif ch in {'"', '\''}:
      quote = ch
      current.add ch
    elif ch == ',':
      items.add current.strip()
      current = ""
    else:
      current.add ch
    inc i
  if quote != '\0': return false
  items.add current.strip()
  for item in items:
    if item.len == 0: return false
    if item[0] in {'"', '\''}:
      # One complete string and nothing after it.
      var j = 1
      while j < item.len and item[j] != item[0]:
        if item[j] == '\\': inc j
        inc j
      if j != item.len - 1: return false
    else:
      # Identifiers split at unescaped whitespace; an escape (`\,`, `\ `)
      # stands for a name character (CSS Syntax 3 §4.3.11).
      var words: seq[string]
      var word = ""
      var j = 0
      while j < item.len:
        if item[j] == '\\' and j + 1 < item.len:
          # An escape: up to six hex digits and one optional whitespace, or
          # any other single character (CSS Syntax 3 §4.3.7).
          word.add 'a'
          inc j
          if item[j] in HexDigits:
            var digits = 0
            while j < item.len and digits < 6 and item[j] in HexDigits:
              inc j
              inc digits
            # One whitespace ends the escape; CRLF counts as one (CSS
            # Syntax 3 §3.3 preprocessing).
            if j + 1 < item.len and item[j] == '\r' and item[j + 1] == '\n':
              j += 2
            elif j < item.len and item[j] in Whitespace: inc j
          else:
            inc j
          continue
        if item[j] in Whitespace:
          if word.len > 0: words.add word
          word = ""
        else:
          word.add item[j]
        inc j
      if word.len > 0: words.add word
      if not words.allIt(cssIdentifier(it)): return false
      if words.len == 1 and (words[0].toLowerAscii() in cssWideKeywords or
          words[0].toLowerAscii() == "default"):
        return false
  true

func validRotateProperty*(raw: string): bool
func validTranslateProperty*(raw: string): bool
func validScaleProperty*(raw: string): bool
func validTransformOrigin*(raw: string): bool
func validFontShorthandValue*(raw: string): bool

const keywordOnlyProperties* = ["display", "position", "visibility",
  "box-sizing", "flex-direction", "flex-wrap", "flex-flow", "align-items",
  "align-content", "align-self", "justify-content", "justify-items",
  "justify-self", "place-items", "place-content", "place-self", "overflow",
  "overflow-x", "overflow-y", "overscroll-behavior", "list-style-type",
  "text" & "-align", "text" & "-transform", "white-space", "text" & "-overflow",
  "object-fit", "isolation", "mix-blend-mode", "background-blend-mode",
  "background-repeat", "border-style", "border-top-style",
  "border-right-style", "border-bottom-style", "border-left-style",
  "outline-style", "grid-auto-flow", "pointer-events", "user-select",
  "touch-action", "cursor", "text" & "-decoration-style",
  "text" & "-decoration-line", "text" & "-wrap", "flex-grow", "flex-shrink",
  "order", "font-weight", "color", "background-color", "border-color",
  "border-top-color", "border-right-color", "border-bottom-color",
  "border-left-color", "outline-color", "fill", "stroke", "caret-color",
  "accent-color", "text" & "-decoration-color", "column-rule-color",
  # Grid lines and counters: names and `<integer>`s (CSS Grid 2 §8.3, CSS
  # Lists 3 §4), so `0.5px` or `2%` is refused.
  "grid-row", "grid-column", "grid-row-start", "grid-row-end",
  "grid-column-start", "grid-column-end", "grid-area", "counter-reset",
  "counter-set", "counter-increment"]
  ## Properties whose grammar takes no length or percentage (keywords,
  ## numbers or colours): a value that parses as one is judged by the
  ## keyword grammar, which refuses it.

const gridLineProperties* = ["grid-row", "grid-column", "grid-row-start",
  "grid-row-end", "grid-column-start", "grid-column-end", "grid-area"]
  ## The grid-placement properties (CSS Grid 2 §8.3-8.4), whose values are
  ## `<grid-line>`s.
const counterProperties* = ["counter-reset", "counter-set",
  "counter-increment"]
  ## The counter properties (CSS Lists 3 §4.1-4.3).

const cssWhitespaceChars = {' ', '\t', '\n', '\r', '\f'}
  ## CSS whitespace (CSS Syntax 3 §4.2).

func cssEscapeEnd(text: string; at: int): int =
  ## The index just past the escape that starts with the `\` at ``at``
  ## (CSS Syntax 3 §4.3.7): one to six hex digits and one optional
  ## whitespace after them, or any other code point (one UTF-8 sequence);
  ## ``at`` when the escape is not valid (CSS Syntax 3 §4.3.8: a `\`
  ## before a newline or at the end).
  var i = at + 1
  if i >= text.len or text[i] in {'\n', '\r', '\f'}: return at
  if text[i] in HexDigits:
    let start = i
    while i < text.len and i - start < 6 and text[i] in HexDigits: inc i
    if i < text.len and text[i] in cssWhitespaceChars:
      # `\r\n` is one whitespace (CSS Syntax 3 §3.3).
      if text[i] == '\r' and i + 1 < text.len and text[i + 1] == '\n': inc i
      inc i
    return i
  inc i
  while i < text.len and (ord(text[i]) and 0xC0) == 0x80: inc i
  i

func lineWords(text: string): tuple[ok: bool, parts: seq[seq[string]]] =
  ## ``text`` cut into its `/`-separated parts and each part into its words,
  ## at the whitespace and `/` outside parentheses: a function and its
  ## arguments are one word (`span calc(1 + 1)` is `span`, `calc(1 + 1)`).
  ## Not ``ok`` when a parenthesis is unmatched.
  result.ok = true
  var depth = 0
  var word = ""
  var part: seq[string]
  var i = 0
  while i < text.len:
    let c = text[i]
    if c == '\\':
      # An escape is part of the word it is in, the whitespace that may end a
      # hex escape included (CSS Syntax 3 §4.3.7): `\31 a` is one word.
      let e = max(cssEscapeEnd(text, i), i + 1)
      word.add text[i ..< min(e, text.len)]
      i = e
      continue
    inc i
    if c == '(':
      inc depth
      word.add c
    elif c == ')':
      if depth == 0: return (false, @[])
      dec depth
      word.add c
    elif depth == 0 and (c in Whitespace or c == '/'):
      if word.len > 0: part.add word
      word = ""
      if c == '/':
        result.parts.add part
        part = @[]
    else:
      word.add c
  if depth != 0: return (false, @[])
  if word.len > 0: part.add word
  result.parts.add part

func integerWord(word: string; positive = false; nonZero = false): bool =
  ## Whether ``word`` is an `<integer>` (``cssIntegerText``, CSS Values 4
  ## §5.2): a sign and digits only, so `1.5`, `1.0`, `1e2` and `0.5px` are
  ## not. ``positive`` asks for `[1,∞]` and ``nonZero`` excludes zero (CSS
  ## Grid 2 §8.3). A math function stands for an integer when it resolves to
  ## a number (CSS Values 4 §10.9: the result is rounded to the nearest
  ## integer), so `calc(1 + 1)` and `min(1, 2)` are integers and `calc(1px)`
  ## is not. A math function is not range-checked when parsed (CSS Values 4
  ## §10.12: an out-of-range result is clamped), so `span calc(0)` is taken.
  ## Every CSS Values 4 math function is typed by its signature
  ## (§10.2-10.8, ``integerMathCall``), with unit powers carried through
  ## `*` and `/`: `round(1.5)`, `abs(-2)`, `sign(1px)`, `sin(1deg)`,
  ## `abs(sign(1px))`, `abs(1dppx / 1x)` and `abs(2px * 2px / 1px / 1px)`
  ## are numbers; `abs(1px)`, `sin(1px)`, `asin(1)`, `sign()`, `abs(1, 2)`
  ## and `round(down)` are not.
  if '(' in word:
    let name = cssFunctionName(word)
    if name notin cssMathFunctions and name notin otherCssMathFunctions:
      return false
    return integerMathCall(word).isNumber
  if not cssIntegerText(word): return false
  let negative = word[0] == '-'
  let zero = word.allIt(it in {'+', '-', '0'})
  if positive: not negative and not zero
  elif nonZero: not zero
  else: true

func cssIdentifierName(word: string): tuple[ok: bool, name: string] =
  ## Whether ``word`` is exactly one CSS identifier (CSS Syntax 3 §4.3.9 "would
  ## start an ident sequence", §4.3.11 "consume an ident sequence"), and the
  ## name it spells with its escapes resolved (§4.3.7): ident code points
  ## are letters, digits, `-`, `_` and every non-ASCII code point, and any
  ## code point may be escaped, so `ä`, `名前`, `\31 a` (`1a`) and
  ## `c\ d` (`c d`) are identifiers. An escape of zero, a surrogate or a
  ## value past U+10FFFF names U+FFFD.
  const nameStart = {'a'..'z', 'A'..'Z', '_', '\x80'..'\xFF'}
  const nameChars = nameStart + {'0'..'9', '-'}
  if word.len == 0: return
  # Would start an identifier (§4.3.9).
  var i = 0
  let startOk =
    if word[0] == '-':
      word.len > 1 and (word[1] in nameStart + {'-'} or
        (word[1] == '\\' and cssEscapeEnd(word, 1) > 1))
    elif word[0] == '\\': cssEscapeEnd(word, 0) > 0
    else: word[0] in nameStart
  if not startOk: return
  var name = ""
  while i < word.len:
    let c = word[i]
    if c == '\\':
      let e = cssEscapeEnd(word, i)
      if e == i: return
      let body = word[i + 1 ..< e].strip(leading = false,
        chars = cssWhitespaceChars)
      if body.len > 0 and body.allIt(it in HexDigits) and body.len <= 6:
        var code = 0
        for h in body: code = code * 16 + parseHexInt($h)
        if code == 0 or code in 0xD800..0xDFFF or code > 0x10FFFF:
          code = 0xFFFD
        name.add Rune(code).toUTF8
      else:
        name.add word[i + 1 ..< e]
      i = e
    elif c in nameChars:
      name.add c
      inc i
    else:
      return
  (true, name)

func customIdentWord(word: string; excluded: openArray[string]): bool =
  ## A `<custom-ident>` (CSS Values 4 §4.2): an identifier
  ## (``cssIdentifierName``: non-ASCII and escaped code points included)
  ## that is not a CSS-wide keyword, not `default`, and none of the
  ## property's own ``excluded`` keywords. The reserved names are compared
  ## ASCII case-insensitively and as the identifier spells them, escapes
  ## resolved, so `SPAN` and `sp\61n` are `span`.
  let (ok, name) = cssIdentifierName(word)
  let lower = name.toLowerAscii()
  ok and lower notin cssWideKeywords and lower != "default" and
    lower notin excluded

func keywordText(word: string): string =
  ## ``word`` as a keyword is matched: an identifier by the name it spells,
  ## escapes resolved, in ASCII lower case (CSS Syntax 3 §4.3.11; CSS Values
  ## 4 §4.1: keywords are ASCII case-insensitive), so `SPAN` and `sp\61n` are
  ## `span`; any other word in lower case.
  let (ok, name) = cssIdentifierName(word)
  if ok: name.toLowerAscii() else: word.toLowerAscii()

func gridLineName(word: string): bool =
  ## A grid line's `<custom-ident>`: CSS Grid 2 §8.3 also excludes `span`
  ## and `auto`.
  customIdentWord(word, ["span", "auto"])

func validGridLine*(words: openArray[string]): bool =
  ## Whether ``words`` are one `<grid-line>` (CSS Grid 2 §8.3):
  ##
  ##   auto | <custom-ident> |
  ##   [ [ <integer [-∞,-1]> | <integer [1,∞]> ] && <custom-ident>? ] |
  ##   [ span && [ <integer [1,∞]> || <custom-ident> ] ]
  ##
  ## So `auto`, `a`, `2`, `-1`, `2 a`, `a 2`, `span 2`, `span a`,
  ## `span 2 a`, `span a 2`, `2 span` and `2 a span` are, and `0`, `span 0`,
  ## `span -1`, `auto 2`, `span`, `span span`, `2 3` and `a b` are not.
  ## `span` and its `[<integer> || <custom-ident>]` group are the two
  ## operands of `&&`, so the group's words stay together: `span` comes
  ## first or last (`2 span a` is not a grid line).
  if words.len == 0 or words.len > 3: return false
  let lower = words.mapIt(keywordText(it))
  let spans = lower.count("span")
  if spans > 1: return false
  if spans == 0:
    if words.len == 1:
      return lower[0] == "auto" or gridLineName(words[0]) or
        integerWord(lower[0], nonZero = true)
    if words.len == 2:
      return (integerWord(lower[0], nonZero = true) and gridLineName(words[1])) or
        (gridLineName(words[0]) and integerWord(lower[1], nonZero = true))
    return false
  let at = lower.find("span")
  if at != 0 and at != words.len - 1: return false
  var group: seq[string]
  for i, word in words:
    if i != at: group.add word
  case group.len
  of 1:
    integerWord(group[0].toLowerAscii(), positive = true) or gridLineName(group[0])
  of 2:
    (integerWord(group[0].toLowerAscii(), positive = true) and gridLineName(group[1])) or
      (gridLineName(group[0]) and integerWord(group[1].toLowerAscii(), positive = true))
  else:
    false

func validGridPlacement*(propName, raw: string): bool =
  ## Whether ``raw`` is a value of the grid-placement property ``propName``
  ## (CSS Grid 2 §8.4): `grid-row-start`, `grid-row-end`,
  ## `grid-column-start` and `grid-column-end` take one `<grid-line>`;
  ## `grid-row` and `grid-column` one or two, separated by `/`; `grid-area`
  ## one to four. A CSS-wide keyword is the whole value.
  let text = raw.strip()
  if keywordText(text) in cssWideKeywords: return true
  let (ok, parts) = lineWords(text)
  if not ok: return false
  let most =
    case propName
    of "grid-row", "grid-column": 2
    of "grid-area": 4
    else: 1
  parts.len in 1 .. most and parts.allIt(validGridLine(it))

func counterName(word: string; reversed: bool): bool =
  ## A `<counter-name>` (CSS Lists 3 §4: a `<custom-ident>` that is not
  ## `none`) or, with ``reversed``, a `reversed(<counter-name>)` (CSS Lists 3
  ## §4.1, `counter-reset` only).
  if customIdentWord(word, ["none"]): return true
  if not reversed: return false
  let lower = word.toLowerAscii()
  if not (lower.startsWith("reversed(") and lower.endsWith(")")): return false
  customIdentWord(word["reversed(".len ..< word.len - 1].strip(), ["none"])

func validCounterValue*(propName, raw: string): bool =
  ## Whether ``raw`` is a value of the counter property ``propName`` (CSS
  ## Lists 3 §4.1-4.3): `none`, or one or more counter names, each optionally
  ## followed by an `<integer>` (any sign, zero included). `counter-reset`
  ## also takes `reversed(<counter-name>)`. So `c`, `c 1`, `c -2 d`,
  ## `c calc(1 + 1)` and `none` are, and `1`, `c 1 2`, `none c`, `c 1.5`,
  ## `c 1px` and `none 1` are not. A CSS-wide keyword is the whole value.
  let text = raw.strip()
  if keywordText(text) in cssWideKeywords: return true
  let (ok, parts) = lineWords(text)
  if not ok or parts.len != 1 or parts[0].len == 0: return false
  let words = parts[0]
  if words.len == 1 and keywordText(words[0]) == "none": return true
  var i = 0
  while i < words.len:
    if not counterName(words[i], propName == "counter-reset"): return false
    inc i
    if i < words.len and integerWord(words[i].toLowerAscii()): inc i
  true

func validGridLineOrCounterValue*(propName, raw: string): bool =
  ## ``validGridPlacement`` or ``validCounterValue``, by ``propName``.
  if propName in counterProperties: validCounterValue(propName, raw)
  else: validGridPlacement(propName, raw)

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
    if propName == "font-size":
      # Checked before the line widths: `medium` is a font size too.
      return text in ["xx-small", "x-small", "small", "medium", "large",
        "x-large", "xx-large", "xxx-large", "smaller", "larger", "math"]
    if text in ["thin", "medium", "thick"]:
      return propName.endsWith("-width") and (propName.startsWith("border") or
        propName.startsWith("outline"))
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
    validBackgroundSize(text)
  of "background-position":
    commaItems(text).allIt(validPositionLayer(spaceItems(it), true))
  of "object-position":
    validPositionLayer(spaceItems(text), false)
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
    elif propName in ["caret-color", "accent-color"]:
      # CSS UI 4 §6.2.1 (caret-color) and §6.3 (accent-color): `auto |
      # <color>`.
      text == "auto" or isCssColorValue(text)
    elif propName in ["fill", "stroke"]:
      # `<paint>` (CSS Fill and Stroke 3 §2.1, §3.1; SVG 2 §13.2): `none`,
      # a colour, `context-fill`, `context-stroke`, or a `url()` with an
      # optional `none` or colour fallback.
      let parts = spaceItems(text)
      if parts.len == 1:
        text in ["none", "context-fill", "context-stroke"] or
          isCssColorValue(text) or validUrlCall(text)
      else:
        parts.len == 2 and validUrlCall(parts[0]) and
          (parts[1] == "none" or isCssColorValue(parts[1]))
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
  of "flex-grow", "flex-shrink":
    # `<number [0,∞]>` (CSS Flexbox 1 §7.3.1-7.3.2).
    numberToken(text, min = 0)
  of "order":
    # `<integer>` (CSS Display 3 §5.1).
    integerToken(text, int.low)
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
  of "grid-template-columns", "grid-template-rows":
    # `subgrid` with line names is left to the general track list.
    text in ["none", "subgrid", "masonry"] or validStrictTrackList(text) or
      (text.startsWith("subgrid") and validTrackList(text))
  of "grid-auto-columns", "grid-auto-rows":
    validTrackList(text)
  of "grid-auto-flow":
    cssAllIn(text, ["row", "column", "dense"], 2) and
      not (text.contains("row") and text.contains("column"))
  of "grid-column", "grid-row", "grid-column-start", "grid-column-end",
      "grid-row-start", "grid-row-end", "grid-area":
    # `<grid-line>`s (CSS Grid 2 §8.3-8.4, ``validGridPlacement``).
    validGridPlacement(propName, text)
  of "counter-reset", "counter-set", "counter-increment":
    # Counter names and `<integer>`s (CSS Lists 3 §4, ``validCounterValue``).
    validCounterValue(propName, text)
  of "grid-template-areas",
      "grid-template", "grid", "animation", "animation-name", "will-change",
      "content", "quotes",
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
    validFontShorthandValue(text)
  of "font-weight":
    var weight = 0.0
    text in ["normal", "bold", "bolder", "lighter"] or
      (tryParseFloatValue(text, weight) and weight >= 1 and weight <= 1000)
  of "font-style":
    text in ["normal", "italic", "oblique"] or text.startsWith("oblique ")
  of "line-height":
    # `normal | <number [0,∞]> | <length-percentage [0,∞]>` (CSS Inline 3
    # §4.2).
    text == "normal" or numberToken(text, min = 0) or
      lengthPercentToken(text, negative = false)
  of "text" & "-align":
    text in ["start", "end", "left", "right", "center", "justify",
      "justify-all", "match-parent"]
  of "text" & "-decoration":
    validTextDecoration(text, true)
  of "text" & "-decoration-line":
    validTextDecoration(text, false)
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
  of "transform":
    text == "none"
  of "rotate":
    validRotateProperty(text)
  of "translate":
    validTranslateProperty(text)
  of "scale":
    validScaleProperty(text)
  of "transform-origin":
    validTransformOrigin(text)
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

# A property row's value is one declaration's value. A `var()` reference may
# stand for any value (CSS Variables 1 §3.1: a property holding a well-formed
# `var()` is valid at parse time), but the text around it is still a single
# declaration value, and each reference is itself well formed.

func cssNameCodePoint(ch: char): bool =
  ## A code point an identifier may continue with (CSS Syntax 3 §4.2).
  ch in {'a'..'z', 'A'..'Z', '0'..'9', '-', '_', '\x80'..'\xff'}

func cssNameEnd*(text: string; start: int): int =
  ## The index just past the identifier code points and escapes that start
  ## at ``start`` (CSS Syntax 3 §4.3.11). A hex escape is up to six hex
  ## digits and one whitespace after them, CRLF counting as one (§4.3.7);
  ## any other escaped code point is itself part of the name.
  result = start
  while result < text.len:
    if text[result] == '\\' and result + 1 < text.len and
        text[result + 1] in HexDigits:
      inc result
      var digits = 0
      while result < text.len and digits < 6 and text[result] in HexDigits:
        inc result
        inc digits
      if result + 1 < text.len and text[result] == '\r' and
          text[result + 1] == '\n':
        result += 2
      elif result < text.len and text[result] in Whitespace:
        inc result
    elif text[result] == '\\' and result + 1 < text.len: result += 2
    elif cssNameCodePoint(text[result]): inc result
    else: break

func declarationValueProblem*(text: string): string =
  ## Why ``text`` is not one declaration value, or "" when it is one. Outside
  ## a quoted string and an unquoted `url()` (CSS Syntax 3 §4.3.5-4.3.6),
  ## a `;` ends the declaration, a `!` starts a priority (`!important`,
  ## CSS Cascade 5 §6.4), a `{` or `}` opens or closes a block (CSS Syntax 3
  ## §5.4.4, §5.4.6), and parentheses and brackets nest and close in pairs; a
  ## string, escape or comment may not be left open (CSS Syntax 3 §4.3.2,
  ## §4.3.5, §4.3.7). Any value holding one of these is refused, whatever
  ## its property (editor spec, "Raw CSS toggle": `!important`, an
  ## unterminated string, comment or bracket, a selector or brace).
  var closers: seq[char]
  var i = 0
  while i < text.len:
    let ch = text[i]
    case ch
    of '\\':
      if i + 1 >= text.len: return "A backslash at the end of a value escapes nothing."
      i += 2
      continue
    of '"', '\'':
      var j = i + 1
      while j < text.len and text[j] != ch:
        if text[j] == '\\': inc j
        inc j
      if j >= text.len: return "A string in the value is not closed."
      i = j + 1
      continue
    of '/':
      if i + 1 < text.len and text[i + 1] == '*':
        let close = text.find("*/", i + 2)
        if close < 0: return "A comment in the value is not closed."
        i = close + 2
        continue
    of '(':
      # The name before the parenthesis: an unquoted `url(` holds its URL
      # literally up to its `)`.
      var start = i
      while start > 0 and cssNameCodePoint(text[start - 1]): dec start
      if text[start ..< i].toLowerAscii() == "url":
        var j = i + 1
        while j < text.len and text[j] in Whitespace: inc j
        if j < text.len and text[j] notin {'"', '\''}:
          while j < text.len and text[j] != ')':
            if text[j] == '\\': inc j
            inc j
          if j >= text.len: return "A url() in the value is not closed."
          i = j + 1
          continue
      closers.add ')'
    of '[':
      closers.add ']'
    of ')', ']':
      if closers.len == 0 or closers[^1] != ch:
        return "The value's parentheses and brackets do not pair up."
      discard closers.pop()
    of ';':
      return "A value cannot hold `;`: it would end the declaration."
    of '!':
      return "A value cannot hold `!` or a priority such as `!important`."
    of '{', '}':
      return "A value cannot hold a brace."
    else: discard
    inc i
  if closers.len > 0:
    return "The value's parentheses and brackets do not pair up."
  ""

func varReferenceProblem*(text: string): string =
  ## Why a `var()` in ``text`` is malformed, or "" when every one is well
  ## formed: `var( <custom-property-name> [, <declaration-value>? ]? )`
  ## (CSS Variables 1 §3), where the name is a `<dashed-ident>` other than
  ## `--` itself (§2). The fallback may be empty or hold further `var()`s,
  ## which are checked in turn; the text around them is checked by
  ## `declarationValueProblem`.
  let lower = text.toLowerAscii()
  let structural = structuralChars(text)
  var at = lower.find("var(")
  while at >= 0:
    if structural[at] and (at == 0 or not cssNameCodePoint(text[at - 1])):
      var j = at + 4
      while j < text.len and text[j] in Whitespace: inc j
      if not (j + 1 < text.len and text[j] == '-' and text[j + 1] == '-'):
        return "var() must name a custom property, such as var(--name)."
      j += 2
      let nameStart = j
      j = cssNameEnd(text, j)
      if j == nameStart:
        return "var() must name a custom property, such as var(--name)."
      while j < text.len and text[j] in Whitespace: inc j
      if j >= text.len or text[j] notin {')', ','}:
        return "A var() name may be followed only by `,` and a fallback value."
    at = lower.find("var(", at + 1)
  ""

func hasVarReference*(text: string): bool =
  ## Whether ``text`` holds a `var()` call outside a string.
  let lower = text.toLowerAscii()
  let structural = structuralChars(text)
  var at = lower.find("var(")
  while at >= 0:
    if structural[at] and (at == 0 or not cssNameCodePoint(text[at - 1])):
      return true
    at = lower.find("var(", at + 1)
  false

# The individual transform properties, `transform-origin`, and the `font`
# and `transition` shorthands, each by its own grammar.

func validRotateProperty*(raw: string): bool =
  ## `rotate: none | <angle> | [ x | y | z | <number>{3} ] && <angle>`
  ## (CSS Transforms 2 §4, the rotate property). The property takes an
  ## `<angle>`, never the bare `<zero>` that transform functions allow (CSS
  ## Values 4 §7.1), so `rotate: 0` is refused and `0deg` is written.
  func angleToken(token: string): bool =
    token != "0" and css_value_grammar.angleToken(token)
  let text = raw.strip().toLowerAscii()
  if text == "none": return true
  let parts = spaceItems(text)
  case parts.len
  of 1: angleToken(parts[0])
  of 2:
    (parts[0] in ["x", "y", "z"] and angleToken(parts[1])) or
      (angleToken(parts[0]) and parts[1] in ["x", "y", "z"])
  of 4:
    (parts[0 .. 2].allIt(numberToken(it)) and angleToken(parts[3])) or
      (angleToken(parts[0]) and parts[1 .. 3].allIt(numberToken(it)))
  else: false

func validTranslateProperty*(raw: string): bool =
  ## `translate: none | <length-percentage> [ <length-percentage>
  ## <length>? ]?` (CSS Transforms 2 §4, the translate property).
  let text = raw.strip().toLowerAscii()
  if text == "none": return true
  let parts = spaceItems(text)
  parts.len in 1..3 and lengthPercentToken(parts[0]) and
    (parts.len < 2 or lengthPercentToken(parts[1])) and
    (parts.len < 3 or lengthPercentToken(parts[2], percent = false))

func validScaleProperty*(raw: string): bool =
  ## `scale: none | [ <number> | <percentage> ]{1,3}` (CSS Transforms 2 §4,
  ## the scale property).
  let text = raw.strip().toLowerAscii()
  if text == "none": return true
  let parts = spaceItems(text)
  parts.len in 1..3 and parts.allIt(numberPercentToken(it))

func validTransformOrigin*(raw: string): bool =
  ## `transform-origin` (CSS Transforms 1 §8): one keyword or
  ## `<length-percentage>`; or a horizontal then a vertical position, each a
  ## keyword or `<length-percentage>`, then an optional `<length>` for z; or
  ## the two keywords in either order, then an optional `<length>`.
  let text = raw.strip().toLowerAscii()
  let parts = spaceItems(text)
  func lp(token: string): bool = lengthPercentToken(token)
  case parts.len
  of 1:
    parts[0] in ["left", "center", "right", "top", "bottom"] or lp(parts[0])
  of 2, 3:
    if parts.len == 3 and not lengthPercentToken(parts[2], percent = false):
      return false
    ((parts[0] in ["left", "center", "right"] or lp(parts[0])) and
      (parts[1] in ["top", "center", "bottom"] or lp(parts[1]))) or
      (parts[0] in ["top", "bottom", "center"] and
        parts[1] in ["left", "right", "center"])
  else: false

const fontWidthKeywords = ["ultra-condensed", "extra-condensed", "condensed",
  "semi-condensed", "semi-expanded", "expanded", "extra-expanded",
  "ultra-expanded"]
  ## `<font-width-css3>` (CSS Fonts 4 §2.8).

const fontSizeKeywords = ["xx-small", "x-small", "small", "medium", "large",
  "x-large", "xx-large", "xxx-large", "smaller", "larger", "math"]
  ## `<absolute-size>`, `<relative-size>` and `math` (CSS Fonts 4 §2.5).

func obliqueAngle(token: string): bool =
  ## `oblique <angle [-90deg,90deg]>` (CSS Fonts 4 §2.4).
  if cssFunctionName(token) in cssMathFunctions:
    return cssMathFunctionCall(token, {cmtAngle})
  let (number, unit) = splitCssDimension(token)
  var value = 0.0
  if number.len == 0 or not tryParseFloatValue(number, value): return false
  let degrees =
    case unit
    of "deg": value
    of "grad": value * 0.9
    of "rad": value * 180 / PI
    of "turn": value * 360
    else: return false
  degrees >= -90 and degrees <= 90

func validFontShorthandValue*(raw: string): bool =
  ## `font` (CSS Fonts 4 §2.8): `[ [ <'font-style'> || <font-variant-css2>
  ## || <'font-weight'> || <font-width-css3> ]? <'font-size'>
  ## [ / <'line-height'> ]? <'font-family'># ] | <system-family-name>`.
  ## A size and a family are both required; each optional part appears at
  ## most once, and `normal` may stand for any of them.
  let text = raw.strip().toLowerAscii()
  if text in ["caption", "icon", "menu", "message-box", "small-caption",
      "status-bar"]:
    return true
  let tokens = splitCssTokens(text)
  var style, variant, weight, width = false
  var normals = 0
  var i = 0
  while i < tokens.len:
    let token = tokens[i]
    if token == "normal": inc normals
    elif token == "italic" and not style: style = true
    elif token == "oblique" and not style:
      style = true
      if i + 1 < tokens.len and obliqueAngle(tokens[i + 1]): inc i
    elif token == "small-caps" and not variant: variant = true
    elif token in ["bold", "bolder", "lighter"] and not weight: weight = true
    elif not weight and cssFunctionName(token) notin cssMathFunctions and
        splitCssDimension(token).unit.len == 0 and numberToken(token, 1, 1000):
      # `<font-weight-absolute>` takes a number in [1, 1000] (§2.2).
      weight = true
    elif not weight and cssFunctionName(token) in cssMathFunctions and
        cssMathFunctionCall(token, {cmtNumber}):
      weight = true
    elif token in fontWidthKeywords and not width: width = true
    else: break
    inc i
  if ord(style) + ord(variant) + ord(weight) + ord(width) + normals > 4:
    return false
  # <'font-size'>: a non-negative <length-percentage> (§2.5).
  if i >= tokens.len or not (tokens[i] in fontSizeKeywords or
      lengthPercentToken(tokens[i], negative = false)):
    return false
  inc i
  if i < tokens.len and tokens[i] == "/":
    # <'line-height'>: `normal`, or a non-negative number or
    # <length-percentage> (CSS Inline 3 §4.2).
    if i + 1 >= tokens.len: return false
    let lh = tokens[i + 1]
    if not (lh == "normal" or numberToken(lh, min = 0) or
        lengthPercentToken(lh, negative = false)):
      return false
    i += 2
  if i >= tokens.len: return false
  # A CSS-wide keyword is never one part of a value (CSS Cascade 5 §7.3).
  let family = tokens[i .. ^1].join(" ")
  family notin cssWideKeywords and validFontFamilyList(family)

func validTransitionShorthand*(raw: string): bool =
  ## `transition: <single-transition>#` (CSS Transitions 1 §2.5), each
  ## `[ none | <single-transition-property> ] || <time> || <easing-function>
  ## || <time>`, with `<transition-behavior-value>` (CSS Transitions 2
  ## §3.1). The first time is the duration, which is not negative (§2.2);
  ## `none` is valid only when it is the sole transition; a property name is
  ## `all` or a `<custom-ident>`, which is never a CSS-wide keyword or
  ## `default` (CSS Values 4 §4.2).
  let text = raw.strip().toLowerAscii()
  let items = commaItems(text)
  if items.len == 0: return false
  for item in items:
    let parts = spaceItems(item)
    if parts.len == 0: return false
    var times = 0
    var easing, property, behavior = false
    for part in parts:
      if timeToken(part, negative = times > 0):
        inc times
        if times > 2: return false
      elif timeToken(part, negative = true):
        return false
      elif validEasingFunction(part) and not cssVarCall(part):
        if easing: return false
        easing = true
      elif part in ["normal", "allow-discrete"]:
        if behavior: return false
        behavior = true
      elif part in ["none", "all"] or (cssCustomIdent(part) and
          part notin cssWideKeywords and part != "default"):
        if property: return false
        if part == "none" and items.len > 1: return false
        property = true
      else:
        return false
  true

func cssWideKeywordAmongParts*(raw: string): bool =
  ## Whether ``raw`` holds a CSS-wide keyword as one top-level part of a
  ## larger value. Such a keyword is valid only as the entire value (CSS
  ## Cascade 5 §7.3), and no `<custom-ident>` may spell one (CSS Values 4
  ## §4.2), so a family name, a transition property or a shadow colour
  ## cannot be one either. A quoted string or a function argument is not a
  ## top-level part.
  let tokens = splitCssTokens(raw.strip().toLowerAscii())
  tokens.len > 1 and tokens.anyIt(it in cssWideKeywords)

func validPerspectiveProperty*(raw: string): bool =
  ## `perspective: none | <length [0,∞]>` (CSS Transforms 2 §6.1); a math
  ## function is range-checked at computed-value time (CSS Values 4 §10.12).
  let text = raw.strip().toLowerAscii()
  text == "none" or (spaceItems(text).len == 1 and
    lengthPercentToken(text, percent = false, negative = false))

func validTextIndent*(raw: string): bool =
  ## `text-indent: <length-percentage> && hanging? && each-line?` (CSS Text
  ## 3 §8.1); the length may be negative.
  let parts = spaceItems(raw.strip().toLowerAscii())
  var length, hanging, eachLine = false
  for part in parts:
    if part == "hanging" and not hanging: hanging = true
    elif part == "each-line" and not eachLine: eachLine = true
    elif not length and lengthPercentToken(part): length = true
    else: return false
  length

func validFlexShorthand*(raw: string): bool =
  ## `flex: none | [ <'flex-grow'> <'flex-shrink'>? || <'flex-basis'> ]`
  ## (CSS Flexbox 1 §7.1). The factors are `<number [0,∞]>` (§7.3.1-7.3.2);
  ## the basis is `content` or a `<'width'>` (§7.3.3): `auto`, a sizing
  ## keyword or a non-negative `<length-percentage>`. A unitless zero is a
  ## factor unless two factors precede it (§7.1).
  let text = raw.strip().toLowerAscii()
  if text == "none": return true
  let parts = spaceItems(text)
  if parts.len notin 1..3: return false
  func factor(token: string): bool =
    cssFunctionName(token) notin cssMathFunctions and
      splitCssDimension(token).unit.len == 0 and numberToken(token, min = 0) or
      (cssFunctionName(token) in cssMathFunctions and
        cssMathFunctionCall(token, {cmtNumber}))
  func basis(token: string): bool =
    token in ["auto", "content", "min-content", "max-content",
      "fit-content"] or lengthPercentToken(token, negative = false)
  func factors(tokens: seq[string]): bool =
    tokens.len in 1..2 and tokens.allIt(factor(it))
  func leadingBasis(token: string): bool =
    # A leading unitless zero is a flex factor, never the basis.
    token != "0" and basis(token)
  case parts.len
  of 1: factor(parts[0]) or basis(parts[0])
  of 2:
    factors(parts) or (factor(parts[0]) and basis(parts[1])) or
      (leadingBasis(parts[0]) and factor(parts[1]))
  else:
    (factors(parts[0 .. 1]) and basis(parts[2])) or
      (leadingBasis(parts[0]) and factors(parts[1 .. 2]))
