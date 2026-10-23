## Compound CSS values the inspector's specialized editors edit: gradients
## (`background-image`), shadow lists (`box-shadow`) and timing functions
## (`transition-timing-function`).
##
## Editor spec "Editing Controls (Figma-Grade Affordances)" -> "Specialized
## Editors": the gradient editor ("horizontal bar with color stops; drag to
## reposition; click to add; angle scrub-drag; type selector
## (linear/radial/conic)"), the shadow editor ("X/Y offset via 2D crosshair
## drag or numeric inputs; blur/spread as scrub inputs; color picker for
## shadow color; inset toggle; multiple shadows with add/remove") and the
## Bezier curve editor ("for `transition-timing-function`; square with
## draggable control points; preset thumbnails (ease, ease-in, ease-out,
## ease-in-out, linear); custom curve via handle drag").
##
## This module is the values only: parsing the text a property holds into a
## structure an editor can change, and writing the structure back as CSS
## text. It owns no view and commits nothing; every editor commits the text
## it produces through the property row's pipeline. A value the structure
## cannot represent faithfully is refused with a reason (`reason`), so an
## editor never rewrites text it did not understand -- the value can still
## be typed in the property's row.
##
## Grammar references:
## * gradients: https://www.w3.org/TR/css-images-3/#gradients and
##   https://www.w3.org/TR/css-images-4/#conic-gradients;
## * shadows: https://www.w3.org/TR/css-backgrounds-3/#box-shadow;
## * timing functions: https://www.w3.org/TR/css-easing-1/#easing-functions.
##
## The text written is canonical (`linear-gradient(135deg, #3B82F6 0%, ...)`,
## `0px 8px 24px 0px rgba(...)`, `cubic-bezier(0.42, 0, 0.58, 1)`): an editor
## writes only when the user changes the value, and then writes all of it.
## Numbers are written the same way natively and under JS (`compoundNumber`).

import std/[math, strutils]

import isonim/editor/css_color_literal

# --------------------------------------------------------------------------- #
#  Shared text helpers.
# --------------------------------------------------------------------------- #

func splitTopLevel*(text: string; separator = ','): seq[string] =
  ## ``text`` split at each ``separator`` outside brackets and quotes, each
  ## part stripped. `rgb(1, 2, 3) 10%, blue` -> `@["rgb(1, 2, 3) 10%",
  ## "blue"]`. An unbalanced closing bracket is kept as text.
  var depth = 0
  var quote = '\0'
  var current = ""
  for ch in text:
    if quote != '\0':
      current.add ch
      if ch == quote: quote = '\0'
      continue
    case ch
    of '"', '\'':
      quote = ch
      current.add ch
    of '(', '[':
      inc depth
      current.add ch
    of ')', ']':
      if depth > 0: dec depth
      current.add ch
    else:
      if ch == separator and depth == 0:
        result.add current.strip()
        current = ""
      else:
        current.add ch
  result.add current.strip()

func splitTopLevelWhitespace*(text: string): seq[string] =
  ## ``text`` split at whitespace outside brackets: `rgb(1 2 3) 0px 4px` ->
  ## `@["rgb(1 2 3)", "0px", "4px"]`.
  var depth = 0
  var current = ""
  for ch in text:
    case ch
    of '(':
      inc depth
      current.add ch
    of ')':
      if depth > 0: dec depth
      current.add ch
    of ' ', '\t', '\n', '\r':
      if depth == 0:
        if current.len > 0: result.add current
        current = ""
      else:
        current.add ch
    else:
      current.add ch
  if current.len > 0: result.add current

func compoundNumber*(value: float; decimals = 3): string =
  ## ``value`` rounded to ``decimals`` places, without trailing zeros and
  ## without a negative zero: `135.0` -> `135`, `0.4200001` -> `0.42`. The
  ## same text natively and under JS, where `$float` differs.
  let scale = pow(10.0, decimals.float)
  var rounded = round(value * scale) / scale
  if rounded == 0.0: rounded = 0.0
  if abs(rounded - round(rounded)) < 1e-9:
    return $int(round(rounded))
  result = formatFloat(rounded, ffDecimal, decimals)
  while result.endsWith("0"): result.setLen(result.len - 1)
  if result.endsWith("."): result.setLen(result.len - 1)
  if result == "-0": result = "0"

func parseCssNumber(text: string; number: var float): bool =
  ## A plain CSS number (no unit): `0.42`, `-1`, `.5`.
  let raw = text.strip()
  if raw.len == 0: return false
  for ch in raw:
    if ch notin {'0'..'9', '.', '-', '+', 'e', 'E'}: return false
  try:
    number = parseFloat(raw)
  except ValueError:
    return false
  classify(number) notin {fcNan, fcInf, fcNegInf}

func splitDimension*(text: string; number: var float; unit: var string): bool =
  ## A CSS dimension or percentage: `24px` -> (24, "px"), `-2.5rem`,
  ## `50%`, `0` -> (0, ""). False for anything else (`auto`, `calc(...)`).
  let raw = text.strip().toLowerAscii()
  var at = 0
  while at < raw.len and raw[at] in {'0'..'9', '.', '-', '+'}: inc at
  if at == 0: return false
  if not parseCssNumber(raw[0 ..< at], number): return false
  unit = raw[at .. ^1]
  for ch in unit:
    if ch notin {'a'..'z', '%'}: return false
  true

func isCssLength(text: string): bool =
  ## A `<length>` as a shadow's offsets, blur and spread take it: a number
  ## with a length unit, or a bare `0`.
  var number = 0.0
  var unit = ""
  if not splitDimension(text, number, unit): return false
  if unit.len == 0: return number == 0.0
  unit in ["px", "em", "rem", "ex", "ch", "vw", "vh", "vmin", "vmax", "cm",
    "mm", "in", "pt", "pc", "q"]

func isCssLengthPercentage(text: string): bool =
  var number = 0.0
  var unit = ""
  if not splitDimension(text, number, unit): return false
  unit == "%" or isCssLength(text)

func cssAngleDegrees*(text: string; degrees: var float): bool =
  ## A CSS `<angle>` in degrees: `135deg`, `0.25turn`, `1.5708rad`,
  ## `100grad`, and a bare `0`.
  var number = 0.0
  var unit = ""
  if not splitDimension(text, number, unit): return false
  case unit
  of "deg": degrees = number
  of "turn": degrees = number * 360.0
  of "rad": degrees = number * 180.0 / PI
  of "grad": degrees = number * 0.9
  of "": (if number == 0.0: degrees = 0.0 else: return false)
  else: return false
  true

const computedFunctions = ["calc(", "min(", "max(", "clamp(", "env(", "attr("]
  ## Functions whose result the editors cannot read: a value that holds one
  ## is edited as text in its row.

func isComputed(token: string): bool =
  let lowered = token.toLowerAscii()
  for name in computedFunctions:
    if lowered.startsWith(name): return true

func hasComment(text: string): bool =
  ## CSS comments (https://www.w3.org/TR/css-syntax-3/#consume-comment): a
  ## value that holds one is edited as text, so the comment is not lost.
  "/*" in text

func normalizedDegrees*(degrees: float): float =
  ## ``degrees`` in [0, 360).
  result = degrees mod 360.0
  if result < 0.0: result += 360.0
  if result >= 360.0: result -= 360.0

# --------------------------------------------------------------------------- #
#  Gradients.
# --------------------------------------------------------------------------- #

type
  CssGradientKind* = enum
    cgkLinear = "linear"
    cgkRadial = "radial"
    cgkConic = "conic"

  CssGradientStop* = object
    color*: string
      ## The stop's colour as written (`#3B82F6`, `rgb(...)`, `red`,
      ## `var(--x)`).
    position*: string
      ## Its position as written (`40%`, `12px`), or "" for a stop CSS
      ## places itself (https://www.w3.org/TR/css-images-3/#color-stop-fixup).

  CssGradient* = object
    kind*: CssGradientKind
    repeating*: bool
    angle*: float
      ## Degrees, clockwise from "to top": a linear gradient's direction
      ## (default 180, "to bottom") or a conic gradient's `from` angle
      ## (default 0). A radial gradient has none.
    angleWritten*: bool
      ## The source states the angle (or the user set it); otherwise the
      ## default is left implicit when the gradient is written.
    prelude*: string
      ## A radial gradient's shape, size and position (`circle at top`),
      ## or a conic gradient's `at <position>`, as written; "" for none.
    stops*: seq[CssGradientStop]

  CssGradientParse* = object
    ok*: bool
    gradient*: CssGradient
    reason*: string
      ## Why the text is not one gradient this editor can change, when not
      ## ``ok``.

const
  linearSideAngles = [("to top", 0.0), ("to right", 90.0),
    ("to bottom", 180.0), ("to left", 270.0)]

func gradientFunctionName*(gradient: CssGradient): string =
  (if gradient.repeating: "repeating-" else: "") & $gradient.kind & "-gradient"

func parseColorStop(text: string; stop: var CssGradientStop): string =
  ## One `<color-stop>`: a colour followed by up to two positions. Returns
  ## "" or why the text is not a stop.
  let parts = splitTopLevelWhitespace(text)
  if parts.len == 0: return "an empty colour stop"
  var positions: seq[string] = @[]
  var colorEnd = parts.len
  while colorEnd > 1 and positions.len < 2 and
      isCssLengthPercentage(parts[colorEnd - 1]):
    positions.insert(parts[colorEnd - 1], 0)
    dec colorEnd
  if colorEnd == 1 and parts.len == 1 and isCssLengthPercentage(parts[0]):
    return "a colour interpolation hint (" & text & ")"
  if positions.len == 2:
    return "a colour stop with two positions (" & text & ")"
  # A colour is one token (`#3B82F6`, `rgb(...)`, `red`, `var(--x)`). More
  # is a position the editor cannot read -- `calc()`, `var()`, an angle --
  # or a position written before the colour; taking it as part of the colour
  # would place the stop wrongly and write a position after it.
  if colorEnd > 1 or isComputed(parts[0]):
    return "a colour stop it cannot read (" & text & ")"
  stop.color = parts[0]
  stop.position = if positions.len > 0: positions[0] else: ""
  ""

func parseCssGradient*(text: string): CssGradientParse =
  ## ``text`` as one gradient, or the reason it is not one this editor can
  ## change (another image, several layers, a hint or a two-position stop).
  let raw = text.strip()
  let lowered = raw.toLowerAscii()
  if raw.len == 0 or lowered == "none":
    return CssGradientParse(reason: "no gradient is set")
  if hasComment(raw):
    return CssGradientParse(reason: "it has a comment; edit it as text in the row")
  if splitTopLevel(raw).len > 1:
    return CssGradientParse(reason:
      "it has several image layers; edit them as text in the row")
  let open = raw.find('(')
  if open <= 0 or not raw.endsWith(")"):
    return CssGradientParse(reason: "it is not a gradient (" & raw & ")")
  var name = lowered[0 ..< open].strip()
  var gradient = CssGradient()
  if name.startsWith("repeating-"):
    gradient.repeating = true
    name = name["repeating-".len .. ^1]
  case name
  of "linear-gradient":
    gradient.kind = cgkLinear
    gradient.angle = 180.0
  of "radial-gradient": gradient.kind = cgkRadial
  of "conic-gradient": gradient.kind = cgkConic
  else:
    return CssGradientParse(reason: "it is not a gradient (" & raw & ")")
  let args = splitTopLevel(raw[open + 1 ..< raw.len - 1])
  if args.len == 0 or args[0].len == 0:
    return CssGradientParse(reason: "the gradient has no colour stops")
  var first = 0
  # The first argument is the gradient's line, shape or angle when it is not
  # a colour stop.
  let head = args[0]
  let headLower = head.toLowerAscii()
  if headLower.startsWith("in "):
    return CssGradientParse(reason:
      "it names an interpolation colour space; edit it as text in the row")
  case gradient.kind
  of cgkLinear:
    var degrees = 0.0
    if cssAngleDegrees(head, degrees):
      gradient.angle = degrees
      gradient.angleWritten = true
      first = 1
    elif headLower.startsWith("to "):
      var known = false
      let side = headLower.splitWhitespace().join(" ")
      for (keyword, degrees) in linearSideAngles:
        if side == keyword:
          gradient.angle = degrees
          gradient.angleWritten = degrees != 180.0
          known = true
      if not known:
        return CssGradientParse(reason: "its direction (" & head &
          ") depends on the box's shape; type an angle in the row first")
      first = 1
  of cgkRadial:
    var stop = CssGradientStop()
    if parseColorStop(head, stop).len > 0 or
        headLower.splitWhitespace()[0] in ["circle", "ellipse", "closest-side",
          "closest-corner", "farthest-side", "farthest-corner", "at"] or
        isCssLength(splitTopLevelWhitespace(head)[0]):
      gradient.prelude = head
      first = 1
  of cgkConic:
    if headLower.startsWith("from ") or headLower.startsWith("at "):
      var rest = head.strip()
      if headLower.startsWith("from "):
        let words = splitTopLevelWhitespace(rest)
        var degrees = 0.0
        if words.len < 2 or not cssAngleDegrees(words[1], degrees):
          return CssGradientParse(reason: "its from angle (" & head &
            ") is not an angle")
        gradient.angle = degrees
        gradient.angleWritten = true
        rest = words[2 .. ^1].join(" ")
      gradient.prelude = rest.strip()
      first = 1
  if first == 1 and
      (" " & headLower & " ").contains(" in "):
    return CssGradientParse(reason:
      "it names an interpolation colour space; edit it as text in the row")
  for i in first ..< args.len:
    var stop = CssGradientStop()
    let refused = parseColorStop(args[i], stop)
    if refused.len > 0:
      return CssGradientParse(reason: "it has " & refused &
        "; edit it as text in the row")
    gradient.stops.add stop
  if gradient.stops.len < 2:
    return CssGradientParse(reason: "a gradient needs at least two colour stops")
  CssGradientParse(ok: true, gradient: gradient)

func serializeCssGradient*(gradient: CssGradient): string =
  ## The gradient as CSS text.
  var args: seq[string] = @[]
  case gradient.kind
  of cgkLinear:
    if gradient.angleWritten or normalizedDegrees(gradient.angle) != 180.0:
      args.add compoundNumber(gradient.angle) & "deg"
  of cgkRadial:
    if gradient.prelude.len > 0: args.add gradient.prelude
  of cgkConic:
    var head = ""
    if gradient.angleWritten or normalizedDegrees(gradient.angle) != 0.0:
      head = "from " & compoundNumber(gradient.angle) & "deg"
    if gradient.prelude.len > 0:
      head = (if head.len > 0: head & " " else: "") & gradient.prelude
    if head.len > 0: args.add head
  for stop in gradient.stops:
    args.add(if stop.position.len > 0: stop.color & " " & stop.position
             else: stop.color)
  gradient.gradientFunctionName & "(" & args.join(", ") & ")"

func startingGradient*(kind = cgkLinear): CssGradient =
  ## The gradient an editor starts from when the property has none: two
  ## stops across the whole line. Nothing is written until the user edits
  ## it.
  result = CssGradient(kind: kind,
    angle: (if kind == cgkLinear: 90.0 else: 0.0),
    angleWritten: kind == cgkLinear,
    stops: @[CssGradientStop(color: "#3B82F6", position: "0%"),
             CssGradientStop(color: "#22C55E", position: "100%")])

func stopPercent*(gradient: CssGradient; index: int): float =
  ## Where stop ``index`` sits along the gradient line, in percent, as CSS
  ## places it: a percentage as written, the first stop without one at 0,
  ## the last at 100, and stops between unpositioned neighbours spread
  ## evenly (https://www.w3.org/TR/css-images-3/#color-stop-fixup). A bare
  ## `0` is 0%. A stop in another unit (`12px`) is placed by its neighbours,
  ## as if it had none: where it really is depends on the box, so the stop
  ## bar does not edit such a gradient's stops (`stopPlacementRefusal`).
  let count = gradient.stops.len
  if index < 0 or index >= count: return 0.0
  proc written(i: int): float =
    var number = 0.0
    var unit = ""
    if splitDimension(gradient.stops[i].position, number, unit) and
        (unit == "%" or (unit.len == 0 and number == 0.0)):
      number
    else: NaN
  var places = newSeq[float](count)
  for i in 0 ..< count: places[i] = written(i)
  if places[0].isNaN: places[0] = 0.0
  if places[count - 1].isNaN: places[count - 1] = 100.0
  # Each position is at least the largest one before it.
  var greatest = places[0]
  for i in 1 ..< count:
    if not places[i].isNaN:
      if places[i] < greatest: places[i] = greatest
      greatest = places[i]
  var i = 1
  while i < count - 1:
    if places[i].isNaN:
      var j = i
      while j < count and places[j].isNaN: inc j
      let start = places[i - 1]
      let stop = places[j]
      let span = float(j - i + 1)
      for k in i ..< j:
        places[k] = start + (stop - start) * float(k - i + 1) / span
      i = j
    inc i
  places[index]

func stopPlacementRefusal*(gradient: CssGradient): string =
  ## Why the stop bar cannot place or move ``gradient``'s stops, or "". A
  ## stop positioned in a length (`12px`) sits where the box's size puts it,
  ## which a bar in percentages can neither show nor keep: a stop added or
  ## moved next to it would be ordered by a guess, and CSS would move it
  ## (https://www.w3.org/TR/css-images-3/#color-stop-fixup). Its colour, the
  ## angle and the type can still be changed; the stops are kept as written.
  for stop in gradient.stops:
    if stop.position.len == 0: continue
    var number = 0.0
    var unit = ""
    if splitDimension(stop.position, number, unit) and
        (unit == "%" or (unit.len == 0 and number == 0.0)):
      continue
    return "the stop " & stop.color & " " & stop.position &
      " is positioned in a length, which the stop bar cannot place; edit " &
      "its stops as text in the row"
  ""

func gradientWithKind*(gradient: CssGradient; kind: CssGradientKind): CssGradient =
  ## The same stops as a ``kind`` gradient. A linear gradient keeps its
  ## angle as a conic gradient's `from` angle and back; a radial gradient's
  ## shape is kept only while it stays radial.
  result = gradient
  if gradient.kind == kind: return
  result.kind = kind
  case kind
  of cgkRadial:
    result.prelude = ""
    result.angleWritten = false
  of cgkLinear:
    result.prelude = ""
    if gradient.kind == cgkRadial: result.angle = 180.0
    result.angleWritten = true
  of cgkConic:
    result.prelude = ""
    if gradient.kind == cgkRadial: result.angle = 0.0
    result.angleWritten = gradient.kind == cgkLinear

func gradientWithAngle*(gradient: CssGradient; degrees: float): CssGradient =
  ## The gradient pointed at ``degrees`` (normalised to [0, 360)). A radial
  ## gradient has no angle and is returned unchanged.
  result = gradient
  if gradient.kind == cgkRadial: return
  result.angle = normalizedDegrees(degrees)
  result.angleWritten = true

func stopPositionText*(percent: float): string =
  compoundNumber(clamp(percent, 0.0, 100.0), 2) & "%"

func mixedColor(a, b: string; weight: float): string =
  ## ``a`` and ``b`` mixed at ``weight`` (0 = ``a``), as hex, when both are
  ## literal colours; otherwise ``a``.
  let x = literalColorChannels(a)
  let y = literalColorChannels(b)
  if not x.valid or not y.valid: return a
  proc mix(p, q: int): int = int(round(p.float + (q - p).float * weight))
  result = "#" & toHex(mix(x.red, y.red), 2) & toHex(mix(x.green, y.green), 2) &
    toHex(mix(x.blue, y.blue), 2)
  let alpha = mix(x.alpha, y.alpha)
  if alpha != 255: result.add toHex(alpha, 2)

func gradientWithStopAdded*(gradient: CssGradient; percent: float;
    index: var int): CssGradient =
  ## A stop added at ``percent`` along the line, coloured as the gradient
  ## is there between its neighbours (literal colours mixed; otherwise the
  ## colour before it). ``index`` receives the new stop's place.
  result = gradient
  let at = clamp(percent, 0.0, 100.0)
  var place = gradient.stops.len
  for i in 0 ..< gradient.stops.len:
    if gradient.stopPercent(i) > at:
      place = i
      break
  var color = ""
  if place == 0: color = gradient.stops[0].color
  elif place >= gradient.stops.len: color = gradient.stops[^1].color
  else:
    let left = gradient.stopPercent(place - 1)
    let right = gradient.stopPercent(place)
    let weight = if right > left: (at - left) / (right - left) else: 0.0
    color = mixedColor(gradient.stops[place - 1].color,
      gradient.stops[place].color, weight)
  # Every other stop keeps where it is drawn: an unpositioned stop is given
  # the place CSS gave it, since a new neighbour would move it.
  for i in 0 ..< result.stops.len:
    if result.stops[i].position.len == 0:
      result.stops[i].position = stopPositionText(gradient.stopPercent(i))
  result.stops.insert(CssGradientStop(color: color,
    position: stopPositionText(at)), place)
  index = place

func gradientWithStopMoved*(gradient: CssGradient; index: int;
    percent: float; moved: var int): CssGradient =
  ## Stop ``index`` moved to ``percent`` (clamped to 0..100). Unpositioned
  ## stops are given the place they were drawn at, and the stops are put in
  ## the order the bar shows them; ``moved`` receives the moved stop's new
  ## place.
  result = gradient
  moved = index
  if index < 0 or index >= gradient.stops.len: return
  for i in 0 ..< result.stops.len:
    if result.stops[i].position.len == 0:
      result.stops[i].position = stopPositionText(gradient.stopPercent(i))
  let at = clamp(percent, 0.0, 100.0)
  var stop = result.stops[index]
  stop.position = stopPositionText(at)
  result.stops.delete(index)
  var place = result.stops.len
  for i in 0 ..< result.stops.len:
    if result.stopPercent(i) > at:
      place = i
      break
  result.stops.insert(stop, place)
  moved = place

func gradientWithStopMoved*(gradient: CssGradient; index: int;
    percent: float): CssGradient =
  var moved = 0
  gradientWithStopMoved(gradient, index, percent, moved)

func gradientWithStopRemoved*(gradient: CssGradient; index: int): CssGradient =
  ## Stop ``index`` removed; a gradient keeps at least two.
  result = gradient
  if index < 0 or index >= gradient.stops.len or gradient.stops.len <= 2: return
  result.stops.delete(index)

func gradientWithStopColor*(gradient: CssGradient; index: int;
    color: string): CssGradient =
  result = gradient
  if index >= 0 and index < gradient.stops.len:
    result.stops[index].color = color.strip()

func gradientBarImage*(gradient: CssGradient): string =
  ## The gradient's stops drawn left to right, as the editor's stop bar
  ## shows them whatever the gradient's kind and angle.
  var args = @["90deg"]
  for i, stop in gradient.stops:
    args.add stop.color & " " & stopPositionText(gradient.stopPercent(i))
  "linear-gradient(" & args.join(", ") & ")"

# --------------------------------------------------------------------------- #
#  Shadows.
# --------------------------------------------------------------------------- #

type
  CssShadowLayer* = object
    inset*: bool
    x*, y*, blur*, spread*: string
      ## Lengths as written (`8px`, `0`, `0.5rem`); blur and spread are ""
      ## when the source leaves them out.
    color*: string
      ## As written, or "" for `currentcolor` by omission.

  CssShadowParse* = object
    ok*: bool
    layers*: seq[CssShadowLayer]
    reason*: string

func parseCssShadowLayer(text: string; layer: var CssShadowLayer): string =
  ## One `<shadow>`: `inset`, two to four lengths and a colour, in either
  ## order. "" or the reason it is not one.
  var lengths: seq[string] = @[]
  var colorParts: seq[string] = @[]
  var lengthsDone = false
  for token in splitTopLevelWhitespace(text):
    if isComputed(token):
      return "it has a computed value (" & token & ")"
    if token.toLowerAscii() == "inset":
      if layer.inset: return "inset is written twice"
      layer.inset = true
      if lengths.len > 0: lengthsDone = true
    elif isCssLength(token):
      if lengthsDone: return "its lengths are not written together"
      if colorParts.len > 0 and lengths.len == 0: discard
      lengths.add token
    else:
      if lengths.len > 0: lengthsDone = true
      colorParts.add token
  if lengths.len < 2 or lengths.len > 4:
    return "a shadow needs two to four lengths (" & text & ")"
  if colorParts.len > 1:
    return "it is not a shadow (" & text & ")"
  layer.x = lengths[0]
  layer.y = lengths[1]
  layer.blur = if lengths.len > 2: lengths[2] else: ""
  layer.spread = if lengths.len > 3: lengths[3] else: ""
  var blur = 0.0
  var unit = ""
  if layer.blur.len > 0 and splitDimension(layer.blur, blur, unit) and blur < 0:
    return "a shadow's blur cannot be negative"
  layer.color = if colorParts.len == 1: colorParts[0] else: ""
  ""

func parseCssShadowList*(text: string): CssShadowParse =
  ## ``text`` as a list of shadows (`none` is the empty list), or the reason
  ## it is not one this editor can change.
  let raw = text.strip()
  if raw.len == 0 or raw.toLowerAscii() == "none":
    return CssShadowParse(ok: true)
  if raw.toLowerAscii().startsWith("var(") or raw.toLowerAscii().startsWith("token("):
    return CssShadowParse(reason: "it is a variable (" & raw &
      "); detach it or edit the variable")
  if hasComment(raw):
    return CssShadowParse(reason: "it has a comment; edit it as text in the row")
  for part in splitTopLevel(raw):
    var layer = CssShadowLayer()
    let refused = parseCssShadowLayer(part, layer)
    if refused.len > 0:
      return CssShadowParse(reason: refused & "; edit it as text in the row")
    result.layers.add layer
  result.ok = true

func serializeCssShadowLayer*(layer: CssShadowLayer): string =
  var parts: seq[string] = @[]
  if layer.inset: parts.add "inset"
  parts.add(if layer.x.len > 0: layer.x else: "0")
  parts.add(if layer.y.len > 0: layer.y else: "0")
  if layer.blur.len > 0 or layer.spread.len > 0:
    parts.add(if layer.blur.len > 0: layer.blur else: "0")
  if layer.spread.len > 0: parts.add layer.spread
  if layer.color.len > 0: parts.add layer.color
  parts.join(" ")

func serializeCssShadowList*(layers: openArray[CssShadowLayer]): string =
  ## The layers as a `box-shadow` value; `none` for no layers.
  if layers.len == 0: return "none"
  var parts: seq[string] = @[]
  for layer in layers: parts.add serializeCssShadowLayer(layer)
  parts.join(", ")

const
  newShadowLayer* = CssShadowLayer(x: "0px", y: "4px", blur: "12px",
    spread: "0px", color: "rgba(15, 23, 42, 0.16)")
    ## What `Add shadow layer` adds.
  shadowPresets* = [
    ("soft", "0 8px 24px rgba(15, 23, 42, 0.18)"),
    ("raised", "0 1px 2px rgba(15, 23, 42, 0.18), 0 12px 32px rgba(15, 23, 42, 0.16)"),
    ("inner", "inset 0 1px 3px rgba(15, 23, 42, 0.24)")]
    ## The shadow editor's presets: a name and the value it commits.

func shadowLengthPixels*(text: string): float =
  ## A length's number when it is in pixels or `0`; NaN otherwise.
  var number = 0.0
  var unit = ""
  if splitDimension(text, number, unit) and unit in ["", "px"]: number
  else: NaN

func shadowLayerWithOffset*(layer: CssShadowLayer; x, y: float): CssShadowLayer =
  ## The layer offset by (``x``, ``y``) pixels, whole pixels.
  result = layer
  result.x = compoundNumber(round(x), 0) & "px"
  result.y = compoundNumber(round(y), 0) & "px"

# --------------------------------------------------------------------------- #
#  Timing functions.
# --------------------------------------------------------------------------- #

type
  CubicBezier* = object
    x1*, y1*, x2*, y2*: float

  TimingParse* = object
    ok*: bool
    curve*: CubicBezier
    keyword*: string
      ## The keyword the value is written as (`ease-in-out`), or "" for a
      ## `cubic-bezier()`.
    reason*: string

const
  timingPresets* = [
    ("linear", CubicBezier(x1: 0.0, y1: 0.0, x2: 1.0, y2: 1.0)),
    ("ease", CubicBezier(x1: 0.25, y1: 0.1, x2: 0.25, y2: 1.0)),
    ("ease-in", CubicBezier(x1: 0.42, y1: 0.0, x2: 1.0, y2: 1.0)),
    ("ease-out", CubicBezier(x1: 0.0, y1: 0.0, x2: 0.58, y2: 1.0)),
    ("ease-in-out", CubicBezier(x1: 0.42, y1: 0.0, x2: 0.58, y2: 1.0))]
    ## The keyword curves (https://www.w3.org/TR/css-easing-1/#cubic-bezier-easing-functions),
    ## in the order the editor's preset thumbnails show them.

func parseTimingFunction*(text: string): TimingParse =
  ## ``text`` as one cubic Bezier timing function, or why the curve editor
  ## cannot draw it (a list, `steps()`, `linear()` with stops, a variable).
  let raw = text.strip()
  let lowered = raw.toLowerAscii()
  if raw.len == 0:
    return TimingParse(ok: true, curve: timingPresets[1][1], keyword: "ease")
  if hasComment(raw):
    return TimingParse(reason: "it has a comment; edit it as text in the row")
  if splitTopLevel(raw).len > 1:
    return TimingParse(reason: "it lists one timing function per " &
      "transition; edit the list as text in the row")
  for (keyword, curve) in timingPresets:
    if lowered == keyword:
      return TimingParse(ok: true, curve: curve, keyword: keyword)
  if lowered in ["step-start", "step-end"] or lowered.startsWith("steps("):
    return TimingParse(reason: "it is a step function (" & raw &
      "), which is not a curve; edit it as text in the row")
  if lowered.startsWith("linear("):
    return TimingParse(reason: "it is a piecewise linear function (" & raw &
      "); edit it as text in the row")
  if not lowered.startsWith("cubic-bezier(") or not lowered.endsWith(")"):
    return TimingParse(reason: "it is not a timing curve (" & raw & ")")
  let args = splitTopLevel(raw["cubic-bezier(".len ..< raw.len - 1])
  if args.len != 4:
    return TimingParse(reason: "cubic-bezier() takes four numbers (" & raw & ")")
  var numbers: array[4, float]
  for i in 0 ..< 4:
    if not parseCssNumber(args[i], numbers[i]):
      return TimingParse(reason: "cubic-bezier() takes four numbers (" & raw & ")")
  if numbers[0] < 0.0 or numbers[0] > 1.0 or numbers[2] < 0.0 or numbers[2] > 1.0:
    return TimingParse(reason: "a cubic-bezier()'s x values must be from 0 to 1")
  TimingParse(ok: true, curve: CubicBezier(x1: numbers[0], y1: numbers[1],
    x2: numbers[2], y2: numbers[3]))

func clampedCurve*(curve: CubicBezier): CubicBezier =
  ## The control points as the editor allows them: x within 0..1 (CSS
  ## requires it) and y within -1..2 (CSS allows any y; the editor's square
  ## draws -0.5..1.5).
  CubicBezier(x1: clamp(curve.x1, 0.0, 1.0), y1: clamp(curve.y1, -1.0, 2.0),
    x2: clamp(curve.x2, 0.0, 1.0), y2: clamp(curve.y2, -1.0, 2.0))

func sameCurve(a, b: CubicBezier): bool =
  abs(a.x1 - b.x1) < 5e-4 and abs(a.y1 - b.y1) < 5e-4 and
    abs(a.x2 - b.x2) < 5e-4 and abs(a.y2 - b.y2) < 5e-4

func timingPresetFor*(curve: CubicBezier): string =
  ## The keyword that names ``curve``, or "".
  for (keyword, preset) in timingPresets:
    if sameCurve(curve, preset): return keyword
  ""

func serializeTimingFunction*(curve: CubicBezier): string =
  ## ``curve`` as CSS: its keyword when one names it, otherwise
  ## `cubic-bezier(x1, y1, x2, y2)` to three decimals.
  let keyword = timingPresetFor(curve)
  if keyword.len > 0: return keyword
  "cubic-bezier(" & compoundNumber(curve.x1) & ", " & compoundNumber(curve.y1) &
    ", " & compoundNumber(curve.x2) & ", " & compoundNumber(curve.y2) & ")"

func bezierPoint*(curve: CubicBezier; t: float): tuple[x, y: float] =
  ## The point of the curve at parameter ``t`` (0..1), from (0, 0) to (1, 1).
  let u = 1.0 - t
  let a = 3.0 * u * u * t
  let b = 3.0 * u * t * t
  let c = t * t * t
  (x: a * curve.x1 + b * curve.x2 + c, y: a * curve.y1 + b * curve.y2 + c)
