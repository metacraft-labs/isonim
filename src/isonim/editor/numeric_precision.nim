## Decimal precision of the numbers the editor writes to source.
##
## The inspector edits authored decimals (`1.1px`, `0.125turn`, `80.0126%`)
## with binary64 arithmetic, and binary64 cannot represent most decimals:
## `1.1 + 0.1` is `1.2000000000000002`, `80.0126 / 100` is
## `0.8001260000000001`. Written with a shortest round-trip formatter, that
## residue becomes part of the source. Editor spec "Numeric Inputs": a step
## or a scrub is exact to the finer of the authored value's precision and the
## step's, and keeps the authored digits finer than the step.
##
## The helpers are pure and target-independent (native and JS give the same
## results), so the property rows, the box model and the CSS value parser
## share one definition of "the precision a value has".

import std/[math, strutils]

const decimalScales = [1e0, 1e1, 1e2, 1e3, 1e4, 1e5, 1e6, 1e7, 1e8, 1e9,
  1e10, 1e11, 1e12, 1e13, 1e14, 1e15, 1e16, 1e17, 1e18, 1e19, 1e20, 1e21,
  1e22]
  ## The powers of ten binary64 represents exactly. A table rather than
  ## `pow`, whose result is not guaranteed exact on every JS engine.

const maxExactInteger = 9007199254740992.0
  ## 2^53: above it binary64 no longer represents every integer, so a scaled
  ## value cannot carry the decimals being rounded to.

func isFiniteNumber(value: float): bool =
  value.classify notin {fcNan, fcInf, fcNegInf}

func decimalPlaces*(value: float): int =
  ## The number of fractional decimal digits in the shortest decimal that
  ## round-trips to ``value``: 2 for `1.25`, 0 for `120`, 20 for `1e-20`,
  ## 17 for `0.30000000000000004`. 0 for a non-finite value.
  if not value.isFiniteNumber: return 0
  let text = ($value).toLowerAscii()
  var mantissa = text
  var exponent = 0
  let e = text.find('e')
  if e >= 0:
    mantissa = text[0 ..< e]
    try: exponent = parseInt(text[e + 1 .. ^1])
    except ValueError: return 0
  var fraction = 0
  let dot = mantissa.find('.')
  if dot >= 0:
    var last = mantissa.len - 1
    while last > dot and mantissa[last] == '0': dec last
    fraction = last - dot
  max(0, fraction - exponent)

func significantDigits*(value: float): int =
  ## The number of significant digits in the shortest decimal that
  ## round-trips to ``value``, leading and trailing zeros excluded:
  ## `0.00125` is 3, `120` is 2, `1/3` is 16. 0 for zero or a non-finite
  ## value. Trailing zeros are dropped so that native and JS spellings of a
  ## whole number (`120.0`, `120`, `1e+20`) count alike.
  if not value.isFiniteNumber or value == 0.0: return 0
  var text = ($value).toLowerAscii()
  let e = text.find('e')
  if e >= 0: text = text[0 ..< e]
  var digits = ""
  for ch in text:
    if ch in {'0'..'9'}: digits.add ch
  while digits.len > 0 and digits[^1] == '0': digits.setLen(digits.len - 1)
  var first = 0
  while first < digits.len and digits[first] == '0': inc first
  digits.len - first

const maxExactSignificantDigits* = 15
  ## Binary64 holds every decimal of up to 15 significant digits
  ## (DBL_DIG). A computed result whose shortest decimal is that short is
  ## taken as the exact decimal; a longer one is binary residue.

func roundToDecimals*(value: float; places: int): float =
  ## ``value`` rounded to ``places`` fractional decimal digits, as the
  ## binary64 nearest that decimal (so `$` prints the decimal itself).
  ## ``value`` unchanged when it cannot carry that many digits (non-finite,
  ## too large, or more places than binary64 resolves). Never `-0`.
  if places < 0 or places >= decimalScales.len or not value.isFiniteNumber:
    return value
  let scale = decimalScales[places]
  let scaled = value * scale
  if abs(scaled) >= maxExactInteger: return value
  # A correctly rounded division of two exactly represented integers is the
  # binary64 nearest the decimal quotient.
  result = round(scaled) / scale
  if result == 0.0: result = 0.0

func roundInexact*(value: float; places: int): float =
  ## A value with no exact decimal (the result of a non-terminating
  ## quotient), rounded once: to ``places`` decimal places, or to four
  ## significant digits when that keeps more digits, so a small nonzero
  ## result never becomes zero (`1/30000` is `0.00003333`).
  if value == 0.0 or not value.isFiniteNumber: return value
  let significantPlaces = 3 - int(floor(log10(abs(value))))
  let wanted = max(places, significantPlaces)
  if wanted < decimalScales.len:
    return roundToDecimals(value, wanted)
  # Beyond the exact power-of-ten table (|value| below about 1e-19): round
  # the decimal mantissa to four significant digits instead. Both targets
  # format it correctly rounded (C `%.3e`, JS `toExponential(3)`), and
  # parsing gives the binary64 nearest that decimal.
  parseFloat(formatFloat(value, ffScientific, 3))

func steppedNumber*(start, delta, increment: float): float =
  ## ``start`` moved by ``delta``, exact to the finer of the precision of
  ## ``start`` and of ``increment`` (the step the gesture moves by): `1.1`
  ## moved by `0.1` is `1.2`, `1.23456` moved by `1` stays `2.23456`.
  roundToDecimals(start + delta,
    max(decimalPlaces(start), decimalPlaces(increment)))

func steppedNumber*(start, delta: float): float =
  ## ``start`` moved by one step of ``delta``.
  steppedNumber(start, delta, delta)

func percentToRatio*(percent: float): float =
  ## A percentage as a ratio with two more decimals than the percentage:
  ## `80.0126` is `0.800126`, not the binary64 quotient `0.8001260000000001`.
  roundToDecimals(percent / 100.0, decimalPlaces(percent) + 2)

func ratioToPercent*(ratio: float): float =
  ## A ratio as a percentage with two fewer decimals than the ratio (`0.0035`
  ## is `0.35`, not `0.35000000000000003`) when that percentage converts back
  ## to exactly ``ratio`` through `percentToRatio`; otherwise (a ratio that
  ## is itself binary64 residue, such as `0.8001260000000001`) the binary64
  ## product, unrounded.
  let projected = ratio * 100.0
  let rounded = roundToDecimals(projected, max(0, decimalPlaces(ratio) - 2))
  if percentToRatio(rounded) == ratio: rounded else: projected

func exactNumberText*(value: float): string =
  ## ``value`` as the shortest decimal that round-trips to it, in plain
  ## decimal notation (never an exponent, so native and JS write the same
  ## text: `0.0000001`, `100000000000000000000`), without a trailing `.0`
  ## and never `-0`: the text of an authored number, unchanged.
  if value == 0.0 or not value.isFiniteNumber:
    return (if value == 0.0: "0" else: $value)
  var text = ($abs(value)).toLowerAscii()
  var exponent = 0
  let e = text.find('e')
  if e >= 0:
    exponent = parseInt(text[e + 1 .. ^1])
    text = text[0 ..< e]
  let dot = text.find('.')
  var digits = if dot >= 0: text[0 ..< dot] & text[dot + 1 .. ^1] else: text
  var point = (if dot >= 0: dot else: text.len) + exponent
  # Leading zeros carry no value; keep the decimal point's place.
  while digits.len > 1 and digits[0] == '0':
    digits = digits[1 .. ^1]
    dec point
  if point <= 0:
    result = "0." & repeat('0', -point) & digits
  elif point >= digits.len:
    result = digits & repeat('0', point - digits.len)
  else:
    result = digits[0 ..< point] & "." & digits[point .. ^1]
  if '.' in result:
    while result.endsWith("0"): result.setLen(result.len - 1)
    if result.endsWith("."): result.setLen(result.len - 1)
  if value < 0.0: result = "-" & result

func numberText*(value: float; resolution: int): string =
  ## ``value`` as written to source: exactly as authored when its shortest
  ## decimal has at most `maxExactSignificantDigits` significant digits;
  ## otherwise it is binary residue of a computation and is rounded to
  ## ``resolution`` decimal places (editor spec "Numeric Inputs").
  if significantDigits(value) <= maxExactSignificantDigits:
    exactNumberText(value)
  else:
    exactNumberText(roundToDecimals(value, resolution))

func numberTokenText*(value: float): string =
  ## ``value`` as a CSS number token, spelled the same natively and under JS:
  ## the shortest round-trip digits, in plain decimal for 1e-6 <= |value| <
  ## 1e21 and in exponent form outside that range (`1e-20`, `1.5e+21`), as
  ## ECMAScript's Number::toString writes it
  ## (https://tc39.es/ecma262/#sec-numeric-types-number-tostring). CSS reads
  ## both spellings (https://www.w3.org/TR/css-syntax-3/#consume-number).
  ## This is the text the browser editor has always shown and written; the
  ## native build now spells it identically.
  if value == 0.0 or not value.isFiniteNumber:
    return (if value == 0.0: "0" else: $value)
  let magnitude = abs(value)
  if magnitude >= 1e-6 and magnitude < 1e21:
    return exactNumberText(value)
  # Exponent form: shortest digits d1.d2d3... and a signed exponent.
  var text = ($magnitude).toLowerAscii()
  var exponent = 0
  let e = text.find('e')
  if e >= 0:
    exponent = parseInt(text[e + 1 .. ^1])
    text = text[0 ..< e]
  let dot = text.find('.')
  var digits = if dot >= 0: text[0 ..< dot] & text[dot + 1 .. ^1] else: text
  exponent += (if dot >= 0: dot else: text.len) - 1
  while digits.len > 1 and digits[0] == '0':
    digits = digits[1 .. ^1]
    dec exponent
  while digits.len > 1 and digits[^1] == '0': digits.setLen(digits.len - 1)
  result = digits[0 .. 0]
  if digits.len > 1: result.add "." & digits[1 .. ^1]
  result.add "e" & (if exponent < 0: "-" else: "+") & $abs(exponent)
  if value < 0.0: result = "-" & result
