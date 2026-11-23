## The editor's one evaluator for typed numeric arithmetic.
##
## Editor spec "Numeric Inputs" (the arithmetic precision rules) and
## "Planned interaction parity" ("Typed arithmetic, units and arrow
## adjustments obey the same property constraints"): a typed expression
## gives the same result whichever control commits it. The numeric property
## row, the box model and compound number fields (``parseNumericInput``) and
## the text commit path of a property text row or Raw CSS
## (``normalizePrimitiveInputValue`` in ``viewmodels``,
## ``evaluateNumericExpression``) all evaluate through this module.
##
## Pure and target-independent: native and JS give the same results.

import std/[math, options, strutils]
import isonim/editor/numeric_precision

#
# Supports ``+ - * / ^`` with the usual precedence, parenthesised
# sub-expressions and exponent notation (`1e2`). ``parseNumericInput``
# returns the value and the explicit CSS unit, if any;
# ``evaluateNumericExpression`` the value of an expression without a unit.
#
# Every intermediate result carries the decimal precision it is exact to, so
# the binary64 residue of the arithmetic never reaches the field or the
# source (editor spec "Numeric Inputs"): a sum or difference is exact to the
# finest precision among its operands (`0.1+0.2` is `0.3`), a product to the
# sum of its operands' places (`1.1*3` is `3.3`), and a whole-number power
# to its base's places times the exponent. A quotient, and a power with a
# negative or fractional exponent, is kept exactly when its decimal
# terminates within 15 significant digits (`1/8` is `0.125`, `1/1024` is
# `0.0009765625`). Otherwise it has no exact decimal: it is marked inexact,
# the rest of the expression is computed with its unrounded value, and the
# result is rounded once, at the end (`roundInexact`): `(1/3)*3` is `1` and
# `100/3*2` is `66.6667`, where rounding each step would give `0.9999` and
# `66.6666`.
#
# Implementation is intentionally small (recursive descent) — the
# inspector only ever sees short expressions so we don't need a full
# tokenizer.

const inexactPlaces* = 4
  ## The decimal places an inexact result is rounded to when its operands
  ## are not finer (and four significant digits when that keeps more):
  ## far below a rendered pixel in every CSS unit the rows accept, and short
  ## enough to read in the field.

type
  MathParser = object
    src: string
    pos: int
  ExactNumber = tuple[value: float, places: int, inexact: bool]
    ## A value and the decimal places it is exact to. An ``inexact`` value
    ## holds a non-terminating part, unrounded; ``places`` is then the finest
    ## precision among the literals it was computed from.

func exact(value: float; places: int): Option[ExactNumber] =
  some((roundToDecimals(value, places), places, false))

func combined(a, b: ExactNumber; value: float; exactPlaces: int): Option[ExactNumber] =
  ## The result of an exact operation on ``a`` and ``b``: rounded to
  ## ``exactPlaces`` when both are exact, carried unrounded when either is
  ## inexact.
  if a.inexact or b.inexact:
    some((value, max(a.places, b.places), true))
  else:
    exact(value, exactPlaces)

func quotientLike(a, b: ExactNumber; value: float): Option[ExactNumber] =
  ## A quotient or fractional power: exact when both operands are and its
  ## decimal terminates within `maxExactSignificantDigits` (`1/1024` is
  ## `0.0009765625`); otherwise inexact, unrounded.
  if not a.inexact and not b.inexact and
      significantDigits(value) <= maxExactSignificantDigits:
    some((value, decimalPlaces(value), false))
  else:
    some((value, max(a.places, b.places), true))

func finalValue(n: ExactNumber): float =
  ## The expression's value: an inexact one rounded once (`roundInexact`).
  if n.inexact: roundInexact(n.value, max(n.places, inexactPlaces))
  else: n.value

proc peek(p: MathParser): char =
  if p.pos < p.src.len: p.src[p.pos] else: '\0'

proc skipSpaces(p: var MathParser) =
  # Any CSS whitespace: Raw CSS text may break an expression over lines.
  while p.pos < p.src.len and p.src[p.pos] in {' ', '\t', '\n', '\r', '\f'}:
    inc p.pos

proc parseExpr(p: var MathParser): Option[ExactNumber]
proc parsePower(p: var MathParser): Option[ExactNumber]
proc parseSigned(p: var MathParser): Option[ExactNumber]

proc parseNumber(p: var MathParser): Option[ExactNumber] =
  ## An unsigned number; a sign before it is an operator (``parseSigned``).
  skipSpaces(p)
  let start = p.pos
  var sawDigit = false
  while p.pos < p.src.len and p.src[p.pos].isDigit:
    inc p.pos
    sawDigit = true
  if p.peek == '.':
    inc p.pos
    while p.pos < p.src.len and p.src[p.pos].isDigit:
      inc p.pos
      sawDigit = true
  if not sawDigit:
    return none(ExactNumber)
  if p.peek in {'e', 'E'} and p.pos + 1 < p.src.len and
      p.src[p.pos + 1] in {'0'..'9', '+', '-'}:
    inc p.pos
    if p.peek in {'+', '-'}: inc p.pos
    let exponentStart = p.pos
    while p.peek in {'0'..'9'}: inc p.pos
    if exponentStart == p.pos: return none(ExactNumber)
  try:
    # A literal is exact as authored: its places are its own.
    let value = parseFloat(p.src[start ..< p.pos])
    return some((value, decimalPlaces(value), false))
  except ValueError:
    return none(ExactNumber)

proc parsePrimary(p: var MathParser): Option[ExactNumber] =
  skipSpaces(p)
  if p.peek == '(':
    inc p.pos
    let inner = parseExpr(p)
    skipSpaces(p)
    if p.peek != ')': return none(ExactNumber)
    inc p.pos
    return inner
  parseNumber(p)

proc parsePower(p: var MathParser): Option[ExactNumber] =
  ## `^`, right-associative, binding tighter than `*` and `/`.
  ##
  ## Figma's fields accept it (help.figma.com, "Adjust alignment, rotation,
  ## position and dimensions": the operators are `+ - * / ^` and
  ## parentheses), and a designer typing `2^4` for a spacing step is doing
  ## something the field should understand rather than reject.
  let base = parsePrimary(p)
  if base.isNone: return base
  skipSpaces(p)
  if p.peek != '^': return base
  inc p.pos
  # Right-associative: `2^3^2` is 2^(3^2), which is what every other
  # calculator does.
  # The exponent may be signed: `2^-1` and `2^-(1)` are 0.5.
  let exponent = parseSigned(p)
  if exponent.isNone: return none(ExactNumber)
  try:
    let value = pow(base.get.value, exponent.get.value)
    if value != value: return none(ExactNumber)  # NaN, e.g. (-8) ^ 0.5
    let n = exponent.get.value
    if not exponent.get.inexact and n >= 0.0 and n == floor(n) and n <= 22.0:
      # A whole-number power of a decimal terminates.
      combined(base.get, exponent.get, value, base.get.places * int(n))
    else:
      quotientLike(base.get, exponent.get, value)
  except CatchableError:
    none(ExactNumber)

proc parseSigned(p: var MathParser): Option[ExactNumber] =
  ## A sign before an operand negates (or keeps) it, whether the operand is
  ## a number or a parenthesised group (editor spec "Numeric Inputs"):
  ## `-(2+3)` is -5 and `-(-(1/3))*3` is 1. The sign applies after a power,
  ## as in arithmetic, so `-2^2` and `-(2)^2` are -4, and it may follow
  ## one: `2^-1` and `2^-(1)` are 0.5.
  ##
  ## One sign per operand. A chain (`--1`, `-+-1`) is refused, as CSS
  ## refuses it in `calc()`: a `<calc-value>` is a number, a dimension, a
  ## percentage or a parenthesised `<calc-sum>`, and a sign exists only as
  ## part of a number token (https://www.w3.org/TR/css-values-4/#calc-syntax,
  ## https://www.w3.org/TR/css-syntax-3/#consume-number). A binary operator
  ## followed by a signed operand stays valid (`5 - -3` is 8).
  skipSpaces(p)
  if p.peek in {'+', '-'}:
    let negative = p.peek == '-'
    inc p.pos
    skipSpaces(p)
    if p.peek in {'+', '-'}: return none(ExactNumber)
    let operand = parsePower(p)
    if operand.isNone or not negative: return operand
    let n = operand.get
    # Negation is exact: the places and the inexact mark carry over.
    return some((-n.value, n.places, n.inexact))
  parsePower(p)

proc parseMulDiv(p: var MathParser): Option[ExactNumber] =
  var left = parseSigned(p)
  if left.isNone: return left
  while true:
    skipSpaces(p)
    let op = p.peek
    if op != '*' and op != '/': break
    inc p.pos
    let right = parseSigned(p)
    if right.isNone: return none(ExactNumber)
    let (a, b) = (left.get, right.get)
    case op
    of '*': left = combined(a, b, a.value * b.value, a.places + b.places)
    of '/':
      if b.value == 0.0: return none(ExactNumber)
      left = quotientLike(a, b, a.value / b.value)
    else: discard
  left

proc parseExpr(p: var MathParser): Option[ExactNumber] =
  var left = parseMulDiv(p)
  if left.isNone: return left
  while true:
    skipSpaces(p)
    let op = p.peek
    if op != '+' and op != '-': break
    inc p.pos
    let right = parseMulDiv(p)
    if right.isNone: return none(ExactNumber)
    let (a, b) = (left.get, right.get)
    let places = max(a.places, b.places)
    case op
    of '+': left = combined(a, b, a.value + b.value, places)
    of '-': left = combined(a, b, a.value - b.value, places)
    else: discard
  left

const numericInputUnits* = ["", "px", "em", "rem", "%", "vw", "vh", "vmin",
  "vmax", "deg", "rad", "grad", "turn", "s", "ms", "fr", "ch", "ex"]
  ## The units a numeric field reads after its expression.

proc parseLeading(raw: string): tuple[value: Option[float], rest: string] =
  ## The longest leading expression of ``raw`` and the text after it. The
  ## value is the expression's final value (an inexact one rounded once),
  ## none for unmatched syntax or a non-finite result.
  var p = MathParser(src: raw.strip(), pos: 0)
  let parsed = parseExpr(p)
  if parsed.isNone: return
  skipSpaces(p)
  let value = finalValue(parsed.get)
  if classify(value) in {fcNan, fcInf, fcNegInf}: return
  result = (some(value), p.src[p.pos ..< p.src.len])

proc parseNumericInput*(raw: string): tuple[value: Option[float], unit: string] =
  ## Parse the entire expression, retaining an explicit CSS unit for validation
  ## by the row. Arbitrary suffixes, unmatched syntax and infinities are refused.
  let parsed = parseLeading(raw)
  if parsed.value.isNone or parsed.rest notin numericInputUnits: return
  result = (parsed.value, parsed.rest)

proc evaluateNumericExpression*(raw: string): Option[float] =
  ## The value of ``raw`` read whole as one expression with no unit, or none
  ## when it is not one (unmatched syntax, a unit or other text left over, a
  ## division by zero, a non-finite result).
  let parsed = parseLeading(raw)
  if parsed.value.isSome and parsed.rest.len == 0: parsed.value
  else: none(float)

proc evalMathExpr*(raw: string): Option[float] =
  parseNumericInput(raw).value

func hasArithmetic*(expr: string): bool =
  ## Whether ``expr`` (a number's text without its unit) holds arithmetic:
  ## an operator or a parenthesis other than the sign of a number token
  ## (CSS Syntax 3 §4.3.12: a sign immediately before a digit or `.`, and an
  ## exponent's sign after `e`). `+2`, `-0`, `1e-2` and `+1.` are numbers
  ## typed without arithmetic, written exactly as typed (editor spec
  ## "Numeric Inputs"); `- 5`, `-(2)`, `2^2` and `1e2+5` are arithmetic.
  let text = expr.strip()
  for i, c in text:
    case c
    of '*', '/', '^', '(', ')':
      return true
    of '+', '-':
      let nextIsNumber = i + 1 < text.len and text[i + 1] in {'0'..'9', '.'}
      if i == 0 and nextIsNumber: continue
      let exponentSign = i >= 2 and text[i - 1] in {'e', 'E'} and
        text[i - 2] in {'0'..'9', '.'} and nextIsNumber
      if exponentSign: continue
      return true
    else: discard
  false
