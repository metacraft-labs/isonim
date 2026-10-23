## The compound CSS values the inspector's specialized editors edit
## (`css_compound_values`): gradients, shadow lists and timing functions.
##
## Editor spec "Editing Controls (Figma-Grade Affordances)" -> "Specialized
## Editors" (gradient, shadow and Bezier curve editors) and the clause under
## it that says what each editor reads and writes. Pure functions: no
## renderer, no editor, no mocks.

import std/[math, strutils, unittest]

import isonim/editor/css_compound_values

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
        ("red 1PX 2PX", "1PX 2PX red"),
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
    check serializeCssShadowLayer(layer.shadowLayerWithOffset(-4.4, 7.6)) ==
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
    check serializeTimingFunction(CubicBezier(x1: 0.3333333, y1: 0.0,
      x2: 0.6666667, y2: 1.0)) == "cubic-bezier(0.333, 0, 0.667, 1)"
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
