## The compound CSS values the inspector's specialized editors edit
## (`css_compound_values`): gradients, shadow lists and timing functions.
##
## Editor spec "Editing Controls (Figma-Grade Affordances)" -> "Specialized
## Editors" (gradient, shadow and Bezier curve editors) and the clause under
## it that says what each editor reads and writes. Pure functions: no
## renderer, no editor, no mocks.

import std/[math, strutils, unittest]

import isonim/editor/css_compound_values
import isonim/editor/numeric_precision

suite "gradients":
  test "a linear gradient is read with its angle, stops and positions":
    let parsed = parseCssGradient(
      "linear-gradient(135deg, rgb(59, 130, 246) 0%, #22C55E 100%)")
    check parsed.ok
    let g = parsed.gradient
    check g.kind == cgkLinear and not g.repeating
    check g.angle == 135.0 and g.angleWritten
    check g.stops.len == 2
    check g.stops[0].color == "rgb(59, 130, 246)" and g.stops[0].position == "0%"
    check g.stops[1].color == "#22C55E" and g.stops[1].position == "100%"
    check serializeCssGradient(g) ==
      "linear-gradient(135deg, rgb(59, 130, 246) 0%, #22C55E 100%)"

  test "directions, other angle units and the implicit default":
    check parseCssGradient("linear-gradient(to right, red, blue)").gradient.angle == 90.0
    check parseCssGradient("linear-gradient(to top, red, blue)").gradient.angle == 0.0
    let down = parseCssGradient("linear-gradient(red, blue)").gradient
    check down.angle == 180.0 and not down.angleWritten
    check serializeCssGradient(down) == "linear-gradient(red, blue)"
    check parseCssGradient("linear-gradient(0.25turn, red, blue)").gradient.angle == 90.0
    check parseCssGradient("linear-gradient(100grad, red, blue)").gradient.angle == 90.0
    check abs(parseCssGradient("linear-gradient(3.14159rad, red, blue)").gradient.angle - 180.0) < 0.01
    # A corner direction depends on the box; it is refused, not guessed.
    let corner = parseCssGradient("linear-gradient(to top right, red, blue)")
    check not corner.ok and "depends on the box" in corner.reason

  test "radial and conic gradients keep their shape and position":
    let radial = parseCssGradient("radial-gradient(circle at top, red 10%, blue)")
    check radial.ok and radial.gradient.kind == cgkRadial
    check radial.gradient.prelude == "circle at top"
    check serializeCssGradient(radial.gradient) ==
      "radial-gradient(circle at top, red 10%, blue)"
    let plain = parseCssGradient("radial-gradient(red, blue)")
    check plain.ok and plain.gradient.prelude == ""
    let conic = parseCssGradient("conic-gradient(from 45deg at 50% 50%, red, blue)")
    check conic.ok and conic.gradient.kind == cgkConic
    check conic.gradient.angle == 45.0 and conic.gradient.prelude == "at 50% 50%"
    check serializeCssGradient(conic.gradient) ==
      "conic-gradient(from 45deg at 50% 50%, red, blue)"
    let repeating = parseCssGradient("repeating-linear-gradient(45deg, red 0px, blue 12px)")
    check repeating.ok and repeating.gradient.repeating
    check serializeCssGradient(repeating.gradient) ==
      "repeating-linear-gradient(45deg, red 0px, blue 12px)"

  test "what the editor cannot change faithfully is refused with the reason":
    for (text, why) in [
        ("none", "no gradient"),
        ("", "no gradient"),
        ("url(\"a.png\")", "not a gradient"),
        ("linear-gradient(red, blue), url(a.png)", "several image layers"),
        ("linear-gradient(red)", "at least two"),
        ("linear-gradient(red, 30%, blue)", "interpolation hint"),
        ("linear-gradient(red 10% 20%, blue)", "two positions"),
        ("linear-gradient(in oklab, red, blue)", "interpolation colour space"),
        ("conic-gradient(from 10deg in oklch, red, blue)", "interpolation colour space"),
        ("linear-gradient(to left top, red, blue)", "depends on the box"),
        ("element(#x)", "not a gradient"),
        # A position the editor cannot read is not taken into the colour,
        # where a later edit would add a second position after it.
        ("linear-gradient(red calc(50% - 10px), blue)", "cannot read"),
        ("linear-gradient(red var(--at), blue)", "cannot read"),
        ("linear-gradient(10% red, blue)", "cannot read"),
        ("conic-gradient(red 90deg, blue)", "cannot read"),
        ("linear-gradient(calc(10deg + 5deg), red, blue)", "cannot read"),
        ("linear-gradient(red /* brand */, blue)", "comment")]:
      let parsed = parseCssGradient(text)
      check not parsed.ok
      check why in parsed.reason

  test "case, spacing and variables round-trip; length stops are kept, not placed":
    let spaced = parseCssGradient("LINEAR-GRADIENT(  -45DEG ,  var(--from)  0% , #FFF 100% )")
    check spaced.ok
    check spaced.gradient.angle == -45.0
    check spaced.gradient.stops[0].color == "var(--from)"
    check serializeCssGradient(spaced.gradient) ==
      "linear-gradient(-45deg, var(--from) 0%, #FFF 100%)"
    check spaced.gradient.stopPlacementRefusal == ""
    # A bare 0 is 0%.
    let zero = parseCssGradient("linear-gradient(red 0, blue)").gradient
    check zero.stopPercent(0) == 0.0 and zero.stopPlacementRefusal == ""
    # A stop in a length is kept as written; the bar does not place it.
    let lengths = parseCssGradient("linear-gradient(red 0%, blue 12px)")
    check lengths.ok
    check "positioned in a length" in lengths.gradient.stopPlacementRefusal
    check serializeCssGradient(lengths.gradient.gradientWithAngle(45.0)) ==
      "linear-gradient(45deg, red 0%, blue 12px)"

  test "stop places follow CSS colour stop fixup":
    let g = parseCssGradient("linear-gradient(red, green, blue 80%, white)").gradient
    check g.stopPercent(0) == 0.0
    check g.stopPercent(1) == 40.0
    check g.stopPercent(2) == 80.0
    check g.stopPercent(3) == 100.0
    # A position below an earlier one is raised to it.
    let clamped = parseCssGradient("linear-gradient(red 50%, blue 20%)").gradient
    check clamped.stopPercent(1) == 50.0

  test "kind, angle and stop edits":
    let g = parseCssGradient("linear-gradient(135deg, #3B82F6 0%, #22C55E 100%)").gradient
    let radial = g.gradientWithKind(cgkRadial)
    check serializeCssGradient(radial) == "radial-gradient(#3B82F6 0%, #22C55E 100%)"
    check serializeCssGradient(g.gradientWithKind(cgkConic)) ==
      "conic-gradient(from 135deg, #3B82F6 0%, #22C55E 100%)"
    check serializeCssGradient(radial.gradientWithKind(cgkLinear)) ==
      "linear-gradient(180deg, #3B82F6 0%, #22C55E 100%)"
    check serializeCssGradient(g.gradientWithAngle(405.0)) ==
      "linear-gradient(45deg, #3B82F6 0%, #22C55E 100%)"
    check serializeCssGradient(g.gradientWithAngle(-90.0)) ==
      "linear-gradient(270deg, #3B82F6 0%, #22C55E 100%)"
    # A radial gradient has no angle.
    check radial.gradientWithAngle(10.0) == radial
    var added = -1
    let three = g.gradientWithStopAdded(50.0, added)
    check added == 1
    check three.stops.len == 3
    check three.stops[1].position == "50%"
    # Coloured as the gradient is there: halfway between the neighbours.
    check three.stops[1].color == "#2FA4AA"
    check serializeCssGradient(three.gradientWithStopRemoved(1)) == serializeCssGradient(g)
    # A gradient keeps two stops.
    check g.gradientWithStopRemoved(0) == g
    var moved = -1
    let swapped = three.gradientWithStopMoved(0, 75.0, moved)
    check moved == 1
    check serializeCssGradient(swapped) ==
      "linear-gradient(135deg, #2FA4AA 50%, #3B82F6 75%, #22C55E 100%)"
    check serializeCssGradient(g.gradientWithStopMoved(1, 140.0)) ==
      "linear-gradient(135deg, #3B82F6 0%, #22C55E 100%)"
    check serializeCssGradient(g.gradientWithStopColor(1, " red ")) ==
      "linear-gradient(135deg, #3B82F6 0%, red 100%)"
    # Unpositioned stops are given the place they were drawn at once a
    # neighbour moves, so they do not jump.
    let loose = parseCssGradient("linear-gradient(red, green, blue)").gradient
    check serializeCssGradient(loose.gradientWithStopMoved(2, 90.0)) ==
      "linear-gradient(red 0%, green 50%, blue 90%)"
    check gradientBarImage(loose) ==
      "linear-gradient(90deg, red 0%, green 50%, blue 100%)"

  test "the starting gradient":
    check serializeCssGradient(startingGradient()) ==
      "linear-gradient(90deg, #3B82F6 0%, #22C55E 100%)"
    check serializeCssGradient(startingGradient(cgkRadial)) ==
      "radial-gradient(#3B82F6 0%, #22C55E 100%)"
    check serializeCssGradient(startingGradient().gradientWithAngle(135.0)) ==
      "linear-gradient(135deg, #3B82F6 0%, #22C55E 100%)"

suite "shadows":
  test "a list is read in authored and computed order":
    let authored = parseCssShadowList("0 8px 24px rgba(15, 23, 42, 0.18)")
    check authored.ok and authored.layers.len == 1
    check authored.layers[0].x == "0" and authored.layers[0].y == "8px"
    check authored.layers[0].blur == "24px" and authored.layers[0].spread == ""
    check authored.layers[0].color == "rgba(15, 23, 42, 0.18)"
    check serializeCssShadowList(authored.layers) == "0 8px 24px rgba(15, 23, 42, 0.18)"
    # getComputedStyle writes the colour first.
    let computed = parseCssShadowList(
      "rgba(0, 0, 0, 0.04) 0px 1px 2px 0px, rgb(1, 2, 3) 0px 0px 0px 1px inset")
    check computed.ok and computed.layers.len == 2
    check computed.layers[0].color == "rgba(0, 0, 0, 0.04)"
    check computed.layers[0].spread == "0px"
    check computed.layers[1].inset and computed.layers[1].spread == "1px"
    check serializeCssShadowList(computed.layers) ==
      "0px 1px 2px 0px rgba(0, 0, 0, 0.04), inset 0px 0px 0px 1px rgb(1, 2, 3)"
    check parseCssShadowList("none").ok and parseCssShadowList("none").layers.len == 0
    check serializeCssShadowList(newSeq[CssShadowLayer]()) == "none"

  test "what is not a shadow list is refused with the reason":
    for (text, why) in [
        ("8px", "two to four lengths"),
        ("1px 2px 3px 4px 5px", "two to four lengths"),
        ("1px 2px red blue", "not a shadow"),
        ("1px red 2px", "not written together"),
        # inset goes before or after the lengths, not between them.
        ("1px inset 2px", "not written together"),
        ("1px 2px inset 3px red", "not written together"),
        ("1px 2px -3px red", "cannot be negative"),
        ("var(--shadow)", "variable"),
        ("inset inset 1px 2px", "twice"),
        ("0 0 calc(2px + 1px) red", "computed"),
        ("0 4px max(8px, 1em)", "computed"),
        ("0 4px 8px red /* soft */", "comment")]:
      let parsed = parseCssShadowList(text)
      check not parsed.ok
      check why in parsed.reason

  test "inset, a variable colour and negative or zero lengths keep their place":
    for (text, written) in [
        ("0 4px 8px var(--shadow-color)", "0 4px 8px var(--shadow-color)"),
        ("-2px -0px 0 red inset", "inset -2px -0px 0 red"),
        # Lengths are numbers: units in lower case (editor spec "Numeric
        # Inputs", approved 2026-11-03); the colour as authored.
        ("red 1PX 2PX", "1px 2px red"),
        ("inset 0 0 0 1px currentcolor", "inset 0 0 0 1px currentcolor")]:
      let parsed = parseCssShadowList(text)
      check parsed.ok
      check serializeCssShadowList(parsed.layers) == written
    let inner = parseCssShadowList("1px 2px blue inset").layers[0]
    check inner.inset and inner.color == "blue"
    check serializeCssShadowLayer(inner.shadowLayerWithOffset(0, 0)) ==
      "inset 0px 0px blue"

  test "offsets, presets and a new layer":
    let layer = parseCssShadowList("1px 2px 3px red").layers[0]
    # The offset is written as given; the editor's gestures step the authored
    # offset by whole pixels ("Numeric Inputs"), so they pass exact values.
    check serializeCssShadowLayer(layer.shadowLayerWithOffset(-4.4, 7.6)) ==
      "-4.4px 7.6px 3px red"
    check serializeCssShadowLayer(layer.shadowLayerWithOffset(-4.0, 8.0)) ==
      "-4px 8px 3px red"
    check shadowLengthPixels("12px") == 12.0
    check shadowLengthPixels("0") == 0.0
    check shadowLengthPixels("1rem").classify == fcNan
    check serializeCssShadowLayer(newShadowLayer) == "0px 4px 12px 0px rgba(15, 23, 42, 0.16)"
    for (name, value) in shadowPresets:
      check name.len > 0
      check parseCssShadowList(value).ok

suite "timing functions":
  test "keywords and cubic-bezier() are read as curves":
    let keyword = parseTimingFunction("ease-in-out")
    check keyword.ok and keyword.keyword == "ease-in-out"
    check keyword.curve == CubicBezier(x1: 0.42, y1: 0.0, x2: 0.58, y2: 1.0)
    let custom = parseTimingFunction("cubic-bezier(0.1, -0.6, 0.2, 1.4)")
    check custom.ok and custom.keyword == ""
    check custom.curve.y1 == -0.6 and custom.curve.y2 == 1.4
    check serializeTimingFunction(custom.curve) == "cubic-bezier(0.1, -0.6, 0.2, 1.4)"
    check serializeTimingFunction(CubicBezier(x1: 0.25, y1: 0.1, x2: 0.25,
      y2: 1.0)) == "ease"
    # Authored digits are kept; binary residue of a computation is written
    # at three decimals ("Numeric Inputs").
    check serializeTimingFunction(CubicBezier(x1: 0.3333333, y1: 0.0,
      x2: 0.6666667, y2: 1.0)) == "cubic-bezier(0.3333333, 0, 0.6666667, 1)"
    check serializeTimingFunction(CubicBezier(x1: 1.0 / 3.0, y1: 0.0,
      x2: 2.0 / 3.0, y2: 1.0)) == "cubic-bezier(0.333, 0, 0.667, 1)"
    check timingPresetFor(parseTimingFunction("cubic-bezier(0.42, 0, 1, 1)").curve) == "ease-in"

  test "what the curve editor cannot draw is refused with the reason":
    for (text, why) in [
        ("ease, linear", "one timing function per"),
        ("steps(4, end)", "step function"),
        ("step-start", "step function"),
        ("linear(0, 0.25 75%, 1)", "piecewise linear"),
        ("cubic-bezier(1.2, 0, 0.5, 1)", "x values"),
        ("cubic-bezier(0.1, 0.2, 0.3)", "four numbers"),
        ("cubic-bezier(a, b, c, d)", "four numbers"),
        ("cubic-bezier(0.4, 0, 0.2, 1) /* material */", "comment"),
        ("var(--easing)", "not a timing curve"),
        ("bounce", "not a timing curve")]:
      let parsed = parseTimingFunction(text)
      check not parsed.ok
      check why in parsed.reason

  test "the curve's points and the editor's limits":
    let linear = timingPresets[0][1]
    check bezierPoint(linear, 0.0) == (x: 0.0, y: 0.0)
    check bezierPoint(linear, 1.0) == (x: 1.0, y: 1.0)
    check abs(bezierPoint(linear, 0.5).x - 0.5) < 1e-9
    let wild = clampedCurve(CubicBezier(x1: -1.0, y1: 5.0, x2: 3.0, y2: -4.0))
    check wild == CubicBezier(x1: 0.0, y1: 2.0, x2: 1.0, y2: -1.0)

suite "numbers and splitting":
  test "numbers are written the same natively and under JS":
    check compoundNumber(135.0) == "135"
    check compoundNumber(0.4200001) == "0.42"
    check compoundNumber(-0.0001) == "0"
    check compoundNumber(12.5, 2) == "12.5"
    check compoundNumber(-3.25) == "-3.25"
    check splitTopLevel("rgb(1, 2, 3) 10%, blue") == @["rgb(1, 2, 3) 10%", "blue"]
    check splitTopLevel("url(\"a,b.png\"), red") == @["url(\"a,b.png\")", "red"]
    check splitTopLevelWhitespace("rgb(1 2 3)  0px\t4px") == @["rgb(1 2 3)", "0px", "4px"]
    var degrees = 0.0
    check cssAngleDegrees("0", degrees) and degrees == 0.0
    check not cssAngleDegrees("12px", degrees)
    check normalizedDegrees(-45.0) == 315.0
    check normalizedDegrees(720.0) == 0.0

suite "authored precision on rewrite":
  ## Editor spec "Numeric Inputs": a compound value an edit rewrites keeps
  ## every number the edit did not change exactly as authored; a stepped
  ## number follows the step rule; a pointer-computed number is written at
  ## its gesture's resolution, never as binary residue.
  test "authored angles, stops and curves round-trip unchanged":
    for text in ["linear-gradient(33.33333deg, #FFFFFF 12.345%, #000000 100%)",
        "linear-gradient(0.0001deg, red 0.001%, blue 99.999%)",
        "conic-gradient(from 33.33333deg, red 12.345%, blue 100%)"]:
      let parsed = parseCssGradient(text)
      check parsed.ok
      check serializeCssGradient(parsed.gradient) == text
    for text in ["cubic-bezier(0.1234, 0.5678, 0.9012, 1.2345)",
        "cubic-bezier(0.4201, 0, 0.58, 1)", "cubic-bezier(0.333333, -0.5, 1, 1.5)"]:
      let parsed = parseTimingFunction(text)
      check parsed.ok
      check serializeTimingFunction(parsed.curve) == text
    # A curve is a keyword only when its numbers are exactly the keyword's.
    check serializeTimingFunction(parseTimingFunction(
      "cubic-bezier(0.42, 0, 1, 1)").curve) == "ease-in"

  test "tiny and huge numbers are written without an exponent on every target":
    let g = parseCssGradient("linear-gradient(0.0000001deg, red 0.00001%, blue 100%)")
    check g.ok
    check serializeCssGradient(g.gradient) ==
      "linear-gradient(0.0000001deg, red 0.00001%, blue 100%)"
    check serializeCssGradient(g.gradient.gradientWithAngle(1e-7)) ==
      "linear-gradient(0.0000001deg, red 0.00001%, blue 100%)"
    check stopPositionText(1e-7) == "0.0000001%"
    check serializeTimingFunction(CubicBezier(x1: 1e-7, y1: 0.0, x2: 1.0,
      y2: 1e-6)) == "cubic-bezier(0.0000001, 0, 1, 0.000001)"

  test "exponent input is read as a CSS number":
    ## CSS Syntax 3 "consume a number": an exponent follows `e` only when a
    ## digit (or a sign and a digit) does, so `2em` stays two em.
    var number = 0.0
    var unit = ""
    check splitDimension("1e-7deg", number, unit) and number == 1e-7 and unit == "deg"
    check splitDimension("1.5E+2px", number, unit) and number == 150.0 and unit == "px"
    check splitDimension("2em", number, unit) and number == 2.0 and unit == "em"
    check splitDimension("3e", number, unit) and number == 3.0 and unit == "e"
    check not splitDimension("1e-px", number, unit)
    let g = parseCssGradient("linear-gradient(1e-7deg, red 1e1%, blue 100%)")
    check g.ok
    # The untouched angle keeps its authored text (approved 2026-11: "a
    # number the edit did not change is kept as authored").
    check serializeCssGradient(g.gradient.gradientWithStopColor(0, "red")) ==
      "linear-gradient(1e-7deg, red 1e1%, blue 100%)"
    check g.gradient.stopPercent(0) == 10.0
    check serializeTimingFunction(parseTimingFunction(
      "cubic-bezier(1e-1, 0, 5e-1, 1)").curve) == "cubic-bezier(1e-1, 0, 5e-1, 1)"

  test "an edit to one part keeps the other parts' authored digits":
    let g = parseCssGradient(
      "linear-gradient(33.33333deg, #FFFFFF 12.345%, #000000 100%)").gradient
    check serializeCssGradient(g.gradientWithStopColor(1, "#111111")) ==
      "linear-gradient(33.33333deg, #FFFFFF 12.345%, #111111 100%)"
    # The angle control turns 45 degrees and keeps the fraction.
    check serializeCssGradient(g.gradientWithAngle(steppedNumber(g.angle, 45.0))) ==
      "linear-gradient(78.33333deg, #FFFFFF 12.345%, #000000 100%)"
    # Wrapping keeps the angle's precision.
    check numberText(normalizedDegrees(-26.66667), angleResolution) == "333.33333"
    check numberText(normalizedDegrees(steppedNumber(359.9, 0.2)),
      angleResolution) == "0.1"
    # A unit conversion's residue is not written: 0.1turn is 36deg.
    var degrees = 0.0
    check cssAngleDegrees("0.1turn", degrees)
    check serializeCssGradient(g.gradientWithAngle(degrees)) ==
      "linear-gradient(36deg, #FFFFFF 12.345%, #000000 100%)"

  test "a stepped stop is exact and a dragged one is at the bar's resolution":
    let g = parseCssGradient("linear-gradient(90deg, red 12.345%, blue 100%)").gradient
    # ArrowRight (1%), Shift+ArrowLeft (10%) and a 0.1 step on noisy sums.
    check serializeCssGradient(g.gradientWithStopMoved(0,
      steppedNumber(g.stopPercent(0), 1.0))) ==
      "linear-gradient(90deg, red 13.345%, blue 100%)"
    let h = parseCssGradient("linear-gradient(90deg, red 10.1%, blue 100%)").gradient
    check serializeCssGradient(h.gradientWithStopMoved(0,
      steppedNumber(h.stopPercent(0), -10.0))) ==
      "linear-gradient(90deg, red 0.1%, blue 100%)"
    let k = parseCssGradient("linear-gradient(90deg, red 0.7%, blue 100%)").gradient
    check serializeCssGradient(k.gradientWithStopMoved(0,
      steppedNumber(k.stopPercent(0), 0.1))) ==
      "linear-gradient(90deg, red 0.8%, blue 100%)"
    # Unpositioned stops given their drawn place: thirds at two decimals.
    let even = parseCssGradient("linear-gradient(90deg, red, green, teal, blue)").gradient
    check serializeCssGradient(even.gradientWithStopColor(0, "red").
      gradientWithStopMoved(3, 100.0)) ==
      "linear-gradient(90deg, red 0%, green 33.33%, teal 66.67%, blue 100%)"
    check stopPositionText(100.0 / 3.0) == "33.33%"
    check stopPositionText(12.345) == "12.345%"

  test "shadow offsets keep their authored fraction":
    let layers = parseCssShadowList("1.5px 0.25px 4px #000000").layers
    let moved = layers[0].shadowLayerWithOffset(
      steppedNumber(shadowLengthPixels(layers[0].x), 3.0),
      shadowLengthPixels(layers[0].y))
    check serializeCssShadowLayer(moved) == "4.5px 0.25px 4px #000000"
    let stepped = layers[0].shadowLayerWithOffset(
      shadowLengthPixels(layers[0].x), steppedNumber(0.25, -10.0))
    check serializeCssShadowLayer(stepped) == "1.5px -9.75px 4px #000000"
    # Residue of a computation is written as whole pixels.
    check layers[0].shadowLayerWithOffset(0.1 + 0.2, 1.0).x == "0px"

suite "untouched authored numbers in compound values":
  ## Editor spec "Numeric Inputs": numbers the editor computes are written
  ## in plain decimal; a number the edit did not change is kept as authored.
  test "an untouched angle survives every other gradient edit":
    for (text, angle) in [
        ("linear-gradient(0.25turn, red, blue)", "0.25turn"),
        ("linear-gradient(100grad, red 10%, blue)", "100grad"),
        ("linear-gradient(1e1deg, red 1e1%, blue 100%)", "1e1deg"),
        ("linear-gradient(1.5708rad, red, blue)", "1.5708rad"),
        ("linear-gradient(to right, red, blue)", "to right")]:
      let g = parseCssGradient(text).gradient
      for edited in [g.gradientWithStopColor(1, "green"),
          g.gradientWithStopMoved(0, 20.0), g.gradientWithStopRemoved(0),
          g.gradientWithAngle(g.angle)]:
        check serializeCssGradient(edited).startsWith("linear-gradient(" & angle & ", ")
      var added = 0
      check serializeCssGradient(g.gradientWithStopAdded(50.0, added)).startsWith(
        "linear-gradient(" & angle & ", ")
    # Identifiers are written in lower case, as the function name is.
    check serializeCssGradient(parseCssGradient(
      "linear-gradient(0.25TURN, red, blue)").gradient.gradientWithStopColor(0, "red")) ==
      "linear-gradient(0.25turn, red, blue)"
    check serializeCssGradient(parseCssGradient(
      "linear-gradient(To  Right, red, blue)").gradient) == "linear-gradient(to right, red, blue)"
    let conic = parseCssGradient("conic-gradient(from 100grad at 50% 50%, red, blue)").gradient
    check serializeCssGradient(conic.gradientWithStopColor(0, "green")) ==
      "conic-gradient(from 100grad at 50% 50%, green, blue)"
    # A type change keeps the angle's text where the new type can write it.
    let turn = parseCssGradient("linear-gradient(0.25turn, red, blue)").gradient
    check serializeCssGradient(turn.gradientWithKind(cgkConic)) ==
      "conic-gradient(from 0.25turn, red, blue)"
    check serializeCssGradient(turn.gradientWithKind(cgkConic).gradientWithKind(cgkLinear)) ==
      "linear-gradient(0.25turn, red, blue)"
    let side = parseCssGradient("linear-gradient(to right, red, blue)").gradient
    check serializeCssGradient(side.gradientWithKind(cgkConic)) ==
      "conic-gradient(from 90deg, red, blue)"
    check serializeCssGradient(turn.gradientWithKind(cgkRadial).gradientWithKind(cgkLinear)) ==
      "linear-gradient(180deg, red, blue)"

  test "an edited angle is written in plain decimal degrees":
    let turn = parseCssGradient("linear-gradient(0.25turn, red, blue)").gradient
    check serializeCssGradient(turn.gradientWithAngle(steppedNumber(turn.angle, 1.0))) ==
      "linear-gradient(91deg, red, blue)"
    let e = parseCssGradient("linear-gradient(1e1deg, red, blue)").gradient
    check serializeCssGradient(e.gradientWithAngle(steppedNumber(e.angle, 45.0))) ==
      "linear-gradient(55deg, red, blue)"
    check serializeCssGradient(e.gradientWithAngle(1e-7)) ==
      "linear-gradient(0.0000001deg, red, blue)"
    let grad = parseCssGradient("conic-gradient(from 100grad, red, blue)").gradient
    check serializeCssGradient(grad.gradientWithAngle(steppedNumber(grad.angle, -15.0))) ==
      "conic-gradient(from 75deg, red, blue)"
    let side = parseCssGradient("linear-gradient(to right, red, blue)").gradient
    check serializeCssGradient(side.gradientWithAngle(91.0)) ==
      "linear-gradient(91deg, red, blue)"

  test "moving one curve point keeps the other's authored numbers":
    let c = parseTimingFunction("cubic-bezier(1e-1, 0.50, 5e-1, 1E0)").curve
    check serializeTimingFunction(c) == "cubic-bezier(1e-1, 0.50, 5e-1, 1e0)"
    check serializeTimingFunction(clampedCurve(c)) == "cubic-bezier(1e-1, 0.50, 5e-1, 1e0)"
    var second = c
    second.x2 = 0.6
    second.y2 = 1.25
    second.texts[2] = ""
    second.texts[3] = ""
    check serializeTimingFunction(second) == "cubic-bezier(1e-1, 0.50, 0.6, 1.25)"
    var first = c
    first.x1 = 0.2
    first.y1 = 0.3
    first.texts[0] = ""
    first.texts[1] = ""
    check serializeTimingFunction(first) == "cubic-bezier(0.2, 0.3, 5e-1, 1e0)"
    # A field set without clearing its text is written as computed: the text
    # no longer spells the number.
    var stale = c
    stale.x1 = 1.0 / 3.0
    check serializeTimingFunction(stale) == "cubic-bezier(0.333, 0.50, 5e-1, 1e0)"

  test "setting the value already in place keeps the authored text":
    # Angles compare normalised: -45deg and 315deg are one direction.
    let neg = parseCssGradient("LINEAR-GRADIENT(-45DEG, red, blue)").gradient
    for same in [-45.0, 315.0, 675.0]:
      let kept = neg.gradientWithAngle(same)
      check kept.angle == -45.0
      check serializeCssGradient(kept) == "linear-gradient(-45deg, red, blue)"
    check serializeCssGradient(neg.gradientWithAngle(316.0)) ==
      "linear-gradient(316deg, red, blue)"
    let conic = parseCssGradient("conic-gradient(from -0.25turn, red, blue)").gradient
    check serializeCssGradient(conic.gradientWithAngle(270.0)) ==
      "conic-gradient(from -0.25turn, red, blue)"
    check serializeCssGradient(conic.gradientWithAngle(271.0)) ==
      "conic-gradient(from 271deg, red, blue)"
    let side = parseCssGradient("linear-gradient(to left, red, blue)").gradient
    check serializeCssGradient(side.gradientWithAngle(270.0)) ==
      "linear-gradient(to left, red, blue)"
    # A curve point set to its own value keeps its text; a changed number
    # is written as computed and its partner keeps its text.
    let c = parseTimingFunction("cubic-bezier(1e-1, 5E-1, 0.30, 1e0)").curve
    for index in [1, 2]:
      let x = if index == 1: c.x1 else: c.x2
      let y = if index == 1: c.y1 else: c.y2
      check serializeTimingFunction(curveWithPoint(c, index, x, y)) ==
        "cubic-bezier(1e-1, 5e-1, 0.30, 1e0)"
    check serializeTimingFunction(curveWithPoint(c, 1, c.x1, 0.6)) ==
      "cubic-bezier(1e-1, 0.6, 0.30, 1e0)"
    check serializeTimingFunction(curveWithPoint(c, 2, 0.4, c.y2)) ==
      "cubic-bezier(1e-1, 5e-1, 0.4, 1e0)"

  test "stop positions and shadow lengths lower their unit and exponent marker only":
    ## Editor spec "Numeric Inputs": a number the edit did not change is kept
    ## as authored, with its unit, keyword and exponent marker in lower case.
    ## Colours are not numbers and stay as authored.
    let g = parseCssGradient("linear-gradient(90deg, RED 1E1%, #FFF 99.50%, Blue 100PCT)")
    check not g.ok # `pct` is not a unit, so that stop is refused
    let h = parseCssGradient("linear-gradient(90deg, RED 1E1%, #FFF 99.50%, Blue 12PX)").gradient
    check h.stops[0].position == "1e1%"
    check h.stops[1].position == "99.50%"
    check h.stops[2].position == "12px"
    check serializeCssGradient(h.gradientWithStopColor(1, "#FFF")) ==
      "linear-gradient(90deg, RED 1e1%, #FFF 99.50%, Blue 12px)"
    check h.stopPercent(0) == 10.0
    let layers = parseCssShadowList("2PX 1E1PX 4.50Px -1E-1EM RED, INSET 0 0 1Rem #FFF").layers
    check serializeCssShadowList(layers) ==
      "2px 1e1px 4.50px -1e-1em RED, inset 0 0 1rem #FFF"
    check shadowLengthPixels(layers[0].y) == 10.0

  test "radial shape and position and conic positions are written in lower case":
    ## Editor spec "Numeric Inputs": numbers keep their digits with unit and
    ## exponent marker in lower case; keywords are lower case like the
    ## writer's others; functions and custom identifiers stay as authored.
    for (text, written) in [
        ("radial-gradient(CIRCLE 10PX AT 50% 1E1%, red, blue)",
         "radial-gradient(circle 10px at 50% 1e1%, red, blue)"),
        ("RADIAL-GRADIENT(Ellipse Closest-Side At Left 2.50EM, RED, #FFF)",
         "radial-gradient(ellipse closest-side at left 2.50em, RED, #FFF)"),
        ("radial-gradient(10PX 2E1PX at var(--X) TOP, red, blue)",
         "radial-gradient(10px 2e1px at var(--X) top, red, blue)"),
        ("conic-gradient(FROM -0.25TURN AT 50% 50%, red, blue)",
         "conic-gradient(from -0.25turn at 50% 50%, red, blue)"),
        ("conic-gradient(AT 1E1PX Center, red, blue)",
         "conic-gradient(at 1e1px center, red, blue)")]:
      let parsed = parseCssGradient(text)
      check parsed.ok
      check serializeCssGradient(parsed.gradient.gradientWithStopColor(0,
        parsed.gradient.stops[0].color)) == written
