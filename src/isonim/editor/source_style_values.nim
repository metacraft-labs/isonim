## Narrow, source-preserving CSS literal transformations shared by capability
## discovery and the native writer. Scalar/quad edits exclude token chains and
## elliptical radius syntax. Rotation separately preserves supported literal 2D
## function siblings; ambiguous, dynamic and 3D transforms remain read-only.
import std/[options, strutils, parseutils, math]
import isonim/editor/[types, viewmodels]

func directCssVariable*(raw: string): string =
  let text = raw.strip()
  if not text.startsWith("var(--") or not text.endsWith(")"): return ""
  let name = text[4 ..< text.len - 1]
  if name.len <= 2: return ""
  for ch in name:
    if ch notin {'a'..'z','A'..'Z','0'..'9','-','_'}: return ""
  name

proc cssQuadValues*(property, raw: string): Option[array[4,string]] =
  let parts = raw.splitWhitespace()
  if parts.len < 1 or parts.len > 4: return none(array[4,string])
  for part in parts:
    let parsed = parseCssPropertyValue(property,part)
    if (parsed.kind notin {cvkLength,cvkPercentage} and part != "0") or
        validateCssPropertyValue(PropertyInfo(name:property,directStyleAllowed:true),
          PropertyEditRequest(property:property,newValue:part,kind:pekCss),parsed).len > 0:
      return none(array[4,string])
  let quad = [parts[0], if parts.len > 1: parts[1] else: parts[0],
    if parts.len > 2: parts[2] else: parts[0],
    if parts.len > 3: parts[3] elif parts.len > 1: parts[1] else: parts[0]]
  some(quad)

proc patchCssQuad*(property, raw, value: string; component: int;
    restoreLiteral = ""): string =
  let current = cssQuadValues(property,raw)
  if current.isNone or component notin 0..3: return ""
  let replacement = cssQuadValues(property,value)
  if replacement.isNone or value.splitWhitespace().len != 1: return ""
  var next = current.get
  next[component] = value
  if restoreLiteral.len > 0:
    let restored = cssQuadValues(property,restoreLiteral)
    if restored.isNone or restored.get != next: return ""
    return restoreLiteral
  # Retain the original byte representation for semantic no-ops.
  if next == current.get: return raw
  if next[0] == next[1] and next[0] == next[2] and next[0] == next[3]: return next[0]
  if next[0] == next[2] and next[1] == next[3]: return next[0] & " " & next[1]
  if next[1] == next[3]: return next[0] & " " & next[1] & " " & next[2]
  next.join(" ")


type RotationLiteral* = object
  supported*: bool
  value*: float
  unit*: string
  degrees*: float
  argumentStart*, argumentEnd*: int
  reason*: string

proc rotationAngle*(raw: string): RotationLiteral =
  let text = raw.strip()
  var value: float
  let consumed = parseFloat(text, value)
  if consumed == 0 or classify(value) in {fcNan, fcInf, fcNegInf}: return
  let unit = text[consumed ..< text.len].toLowerAscii()
  if unit notin ["deg", "rad", "grad", "turn"] and not (unit.len == 0 and value == 0): return
  result.supported = true
  result.value = value
  result.unit = if unit.len == 0: "deg" else: unit
  result.degrees = case result.unit
    of "rad": value * 180 / PI
    of "grad": value * 0.9
    of "turn": value * 360
    else: value
  if classify(result.degrees) in {fcNan, fcInf, fcNegInf}: result.supported = false

proc rotationLiteral*(raw: string): RotationLiteral =
  ## Only one literal planar rotation and known flat 2D siblings are editable.
  ## Preserve all surrounding source text; matrices/dynamic/3D forms are opaque.
  result.unit = "deg"
  result.argumentStart = -1
  result.argumentEnd = -1
  result.reason = "Read-only: Rotation requires one literal rotate() and supported 2D transforms."
  if raw.strip().toLowerAscii() == "none":
    result.supported = true
    result.reason = ""
    return
  if raw.strip().len == 0: return
  var pos = 0
  var rotations = 0
  while pos < raw.len:
    while pos < raw.len and raw[pos].isSpaceAscii: inc pos
    if pos == raw.len: break
    let start = pos
    while pos < raw.len and raw[pos] in {'a'..'z','A'..'Z'}: inc pos
    let name = raw[start ..< pos].toLowerAscii()
    if pos == raw.len or raw[pos] != '(' or name notin ["rotate", "translate", "translatex", "translatey", "scale", "scalex", "scaley", "skew", "skewx", "skewy"]: return
    inc pos
    let argumentStart = pos
    while pos < raw.len and raw[pos] != ')':
      if raw[pos] in {'(', ';', '{', '}', '\n', '\r', '\x00', '\'', '"'}: return
      inc pos
    if pos == raw.len: return
    let arguments = raw[argumentStart ..< pos]
    var parts: seq[string]
    if ',' in arguments:
      for part in arguments.split(','):
        if part.strip().len == 0 or part.strip().splitWhitespace().len != 1: return
        parts.add part.strip()
    else: parts = arguments.splitWhitespace()
    if parts.len < 1 or parts.len > (if name in ["translate", "scale", "skew"]: 2 else: 1): return
    if name == "rotate":
      inc rotations
      if rotations > 1: return
      let angle = rotationAngle(parts[0])
      if not angle.supported: return
      result.value = angle.value
      result.unit = angle.unit
      result.degrees = angle.degrees
      result.argumentStart = argumentStart
      result.argumentEnd = pos
    else:
      for part in parts:
        if name.startsWith("skew"):
          if not rotationAngle(part).supported: return
        else:
          var number: float
          let consumed = parseFloat(part,number)
          if consumed == 0 or classify(number) in {fcNan,fcInf,fcNegInf}: return
          let unit = part[consumed ..< part.len].toLowerAscii()
          if name.startsWith("translate"):
            if unit notin ["px","em","rem","vw","vh","ch","%",""]: return
            if unit.len == 0 and number != 0: return
            let parsed = parseCssPropertyValue("left",part)
            if unit.len > 0 and validateCssPropertyValue(PropertyInfo(name:"left",directStyleAllowed:true),
                PropertyEditRequest(property:"left",newValue:part,kind:pekCss),parsed).len > 0: return
          elif unit.len > 0: return
    inc pos
    if pos < raw.len and not raw[pos].isSpaceAscii: return
  result.supported = true
  result.reason = ""

proc patchRotationLiteral*(raw, angle: string): string =
  let current = rotationLiteral(raw)
  let next = rotationAngle(angle)
  if not current.supported or not next.supported: return ""
  if next.degrees == current.degrees: return raw
  if current.argumentStart >= 0:
    return raw[0 ..< current.argumentStart] & angle & raw[current.argumentEnd ..< raw.len]
  if raw.strip().toLowerAscii() == "none": return "rotate(" & angle & ")"
  raw & " rotate(" & angle & ")"
