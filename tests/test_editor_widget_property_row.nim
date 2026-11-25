## MockRenderer is used only to exercise renderer-independent control state and
## callback cardinality without a browser layout engine. Recording submission
## callbacks and rejection counters are admission-only spies, not source writers. Compiler/filesystem
## persistence is verified separately against the production native source worker
## and mounted browser; these widget tests do not stand in for that boundary.
## Phase D — ViewModel + headless mount tests for the property row
## widget (``src/isonim/editor/views/widgets/property_row.nim``).
##
## Eight scenarios covering the five control kinds plus the bound
## state and the scrub-drag / math-expression invariants from the
## spec's "Editing Controls (Figma-Grade Affordances)" section:
##
##   1. ``prkNumeric`` mount exposes the row metadata + an input
##      pre-populated from the signal + a unit chip.
##   2. Scrubbing the label via simulated ``mousedown`` /
##      ``mousemove`` events updates ``numericValue.val``.
##   3. Math expression: typing ``100+50`` + commit sets value to 150.
##   4. ``prkColor`` exposes ``data-property-row-kind="color"`` + a
##      swatch element + a hex input.
##   5. ``prkChoice`` mounts the ChoiceGroup with the expected labels
##      and propagates picks through ``choiceValue``.
##   6. ``prkText`` exposes a text input that round-trips through
##      ``textValue``.
##   7. ``prkBoolean`` exposes a checkbox whose ``checked`` mirror
##      tracks ``booleanValue``.
##   8. ``binding.isSome`` carries ``data-property-row-linked="true"``
##      and renders the Phase E.2 placeholder chip.
##
## The mount tests follow the canonical ``createRoot`` / ``dispose``
## pattern over ``MockRenderer``: build a root, mount the widget,
## drive interactions via the VM OR via ``fireEvent``, and assert
## the resulting attribute / structure invariants.

import std/[math, options, sequtils, strutils, tables, unittest]

import isonim/core/[signals, computation, owner]
import isonim/editor/types
import isonim/editor/viewmodels
import isonim/editor/css_value_grammar
import isonim/editor/numeric_precision
import isonim/editor/numeric_expression
import isonim/editor/views/choice_row
import isonim/editor/views/widgets/property_row
import isonim/editor/views/widgets/property_commit
import isonim/testing/mock_dom

# --------------------------------------------------------------------------- #
#  Helpers
# --------------------------------------------------------------------------- #

proc mkRoot(): tuple[r: MockRenderer; root: MockNode] =
  let r = MockRenderer()
  let root = r.createElement("div")
  (r, root)

proc findByAttr(node: MockNode; attr, value: string): MockNode =
  if node == nil:
    return nil
  if node.kind == mnkElement and node.attributes.getOrDefault(attr) == value:
    return node
  for c in node.children:
    let hit = findByAttr(c, attr, value)
    if hit != nil:
      return hit
  return nil

proc findByAttrPresent(node: MockNode; attr: string): MockNode =
  ## Returns the first node carrying ``attr`` regardless of value.
  if node == nil:
    return nil
  if node.kind == mnkElement and attr in node.attributes:
    return node
  for c in node.children:
    let hit = findByAttrPresent(c, attr)
    if hit != nil:
      return hit
  return nil

const
  pxUnit = PropertyUnitOption(label: "px", code: "px")
  emUnit = PropertyUnitOption(label: "em", code: "em")
  pctUnit = PropertyUnitOption(label: "%", code: "%")

# --------------------------------------------------------------------------- #
#  evalMathExpr smoke tests — exercised here so a regression in the
#  parser shows up alongside the widget assertions.
# --------------------------------------------------------------------------- #

suite "Phase D property_row evalMathExpr":

  test "bare integer parses":
    let r = evalMathExpr("150")
    check r.isSome
    check r.get == 150.0

  test "addition":
    let r = evalMathExpr("100+50")
    check r.isSome
    check r.get == 150.0

  test "multiplication and division precedence":
    let r = evalMathExpr("2+3*4")
    check r.isSome
    check r.get == 14.0
    let r2 = evalMathExpr("200/2")
    check r2.isSome
    check r2.get == 100.0

  test "parenthesised expression":
    let r = evalMathExpr("(2+3)*4")
    check r.isSome
    check r.get == 20.0

  test "malformed returns none":
    check evalMathExpr("").isNone
    # `^`, right-associative and binding tighter than `*` — the operator
    # set Figma's fields accept is `+ - * / ^` with parentheses.
    check evalMathExpr("2^4") == some(16.0)
    check evalMathExpr("2*3^2") == some(18.0)
    check evalMathExpr("2^3^2") == some(512.0)
    check evalMathExpr("(1+1)^3") == some(8.0)
    # A power with no real answer is refused rather than reported as NaN,
    # which would otherwise reach the input as the literal text "nan".
    check evalMathExpr("(0-8)^0.5").isNone
    check evalMathExpr("abc").isNone
    check evalMathExpr("100/0").isNone

# --------------------------------------------------------------------------- #
#  prkNumeric
# --------------------------------------------------------------------------- #

suite "the typed-number reading the box model and compound fields share":
  test "a number typed without arithmetic keeps its spelling; arithmetic is formatted":
    # Editor spec "Numeric Inputs": "A number typed without arithmetic is
    # kept exactly as authored." The row, the box model and the compound
    # number fields spell a typed number by `keptNumberText`.
    check keptNumberText("+2", 2.0, 2.0) == "+2"
    check keptNumberText("1.50", 1.5, 1.5) == "1.50"
    check keptNumberText("1e-2", 0.01, 0.01) == "1e-2"
    check keptNumberText("-0", -0.0, 0.0) == "-0"
    check keptNumberText("1+1", 2.0, 2.0) == ""
    check keptNumberText("-5", -5.0, 0.0) == ""   # a bound moved it
    for (raw, number, unit) in [("+2px", "+2", "px"), ("1.50PX", "1.50", "PX"),
        ("2dvh", "2", "dvh"), ("10/3rem", "3.3333", "rem"), ("1.0+1", "2", "")]:
      let typed = readTypedFieldNumber(raw)
      check typed.isSome
      if typed.isSome:
        check typed.get.number == number
        check typed.get.unit == unit
    for raw in ["2 px", "1px 2px", "auto", "", "px", "1/0"]:
      check readTypedFieldNumber(raw).isNone
    check stepTypedFieldNumber("1.50px", 1.0).get.number == "2.5"
    check stepTypedFieldNumber("0", -1.0, some(0.0)).isNone
    check stepTypedFieldNumber("1e20px", 1.0).isNone

suite "Phase D property_row prkNumeric":

  test "prkNumeric mount exposes row metadata + value + unit chip":
    createRoot do (dispose: proc()):
      let value = createSignal(120.0)
      let unit = createSignal(pxUnit)
      let cfg = propertyRowNumeric(
        name = "Width", value = value, unit = unit,
        units = @[pxUnit, emUnit, pctUnit])
      let (r, root) = mkRoot()
      discard r.mountPropertyRow(root, cfg)

      let row = findByAttr(root, "data-property-row-kind", "numeric")
      check row != nil
      check row.attributes.getOrDefault("data-property-row") == "width"
      check row.attributes.getOrDefault("data-property-row-name") == "Width"
      check row.attributes.getOrDefault("data-property-row-linked") == "false"

      let input = findByAttr(root, "data-property-row-input", "true")
      check input != nil
      check r.inputValue(input) == "120"

      let unitNode = findByAttr(root, "data-property-row-unit", "true")
      check unitNode != nil
      check textContent(unitNode) == "px"
      dispose()

  test "prkNumeric scrub-drag on label updates numericValue":
    createRoot do (dispose: proc()):
      let value = createSignal(50.0)
      let unit = createSignal(pxUnit)
      let cfg = propertyRowNumeric(
        name = "Gap", value = value, unit = unit,
        units = @[pxUnit], step = 2.0)
      let (r, root) = mkRoot()
      discard r.mountPropertyRow(root, cfg)

      let labelNode = findByAttr(root, "data-property-row-slot",
        "label-scrubber")
      check labelNode != nil

      proc drag(node: MockNode; event: string; x, y: float;
                shift = false; alt = false) =
        fireEventWith(node, event, MockEvent(`type`: event, clientX: x,
          clientY: y, shiftKey: shift, altKey: alt))

      # Drag RIGHT increases. 10px at step 2, near the row so the speed is
      # 2x: 50 + 10 * 2 * 2 = 90.
      drag(labelNode, "mousedown", 100.0, 100.0)
      drag(labelNode, "mousemove", 110.0, 100.0)
      check value.val == 90.0

      # Drag LEFT decreases -- the direction the old implementation did not
      # have at all, since it added a step per event whichever way it went.
      drag(labelNode, "mousemove", 90.0, 100.0)
      check value.val == 10.0

      # Absolute, not incremental: back to the start means back to the
      # starting value, however many events happened on the way.
      drag(labelNode, "mousemove", 100.0, 100.0)
      check value.val == 50.0

      drag(labelNode, "mouseup", 100.0, 100.0)
      # Disarmed: a later move is a no-op.
      drag(labelNode, "mousemove", 200.0, 100.0)
      check value.val == 50.0
      dispose()

  test "scrub speed falls off with vertical distance":
    ## Figma's four speeds, picked by how far the pointer has strayed from
    ## the row it started on: 2x near, then 1x, 1/2, 1/4.
    check scrubSpeed(0.0) == 2.0
    check scrubSpeed(15.0) == 2.0
    check scrubSpeed(16.0) == 1.0
    check scrubSpeed(47.0) == 1.0
    check scrubSpeed(48.0) == 0.5
    check scrubSpeed(95.0) == 0.5
    check scrubSpeed(96.0) == 0.25
    check scrubSpeed(400.0) == 0.25
    # Symmetric: dragging above the row is as fine as dragging below it.
    check scrubSpeed(-96.0) == 0.25

  test "scrub honours modifiers and clamps to the row's range":
    let none0 = none(float)
    # Shift is the big nudge: ten times the step.
    check scrubbedValue(0.0, 1.0, 0.0, 1.0, shift = true, alt = false,
      none0, none0) == 20.0   # 1px * (1*10) * 2x
    # Alt is the fine step.
    check scrubbedValue(0.0, 10.0, 0.0, 1.0, shift = false, alt = true,
      none0, none0) == 2.0    # 10px * (1/10) * 2x
    # A step of zero would make a drag inert; treated as 1.
    check scrubbedValue(0.0, 1.0, 0.0, 0.0, false, false, none0, none0) == 2.0
    # Range is respected, so a scrub cannot push opacity past 100.
    check scrubbedValue(90.0, 100.0, 0.0, 1.0, false, false,
      some(0.0), some(100.0)) == 100.0
    check scrubbedValue(10.0, -100.0, 0.0, 1.0, false, false,
      some(0.0), some(100.0)) == 0.0

  test "a scrub commits once, at the end":
    ## It used to commit on every `mousemove`. That was survivable while
    ## saving was manual; with automatic saving a drag across the panel
    ## would stage and write several hundred edits.
    createRoot do (dispose: proc()):
      let value = createSignal(10.0)
      let unit = createSignal(pxUnit)
      var commits = 0
      var cfg = propertyRowNumeric(
        name = "Gap", value = value, unit = unit, units = @[pxUnit])
      cfg.onCommitValue = proc(v: string) = commits += 1

      let (r, root) = mkRoot()
      discard r.mountPropertyRow(root, cfg)
      let labelNode = findByAttr(root, "data-property-row-slot",
        "label-scrubber")

      proc drag(event: string; x, y: float) =
        fireEventWith(labelNode, event, MockEvent(`type`: event,
          clientX: x, clientY: y))

      drag("mousedown", 0.0, 0.0)
      for i in 1 .. 25:
        drag("mousemove", float(i), 0.0)
      # The value tracked the pointer the whole way: 25px at the default
      # step of 1, at the 2x speed, from 10.
      check value.val == 60.0
      # ...and nothing was written yet.
      check commits == 0
      drag("mouseup", 25.0, 0.0)
      check commits == 1
      dispose()

  test "a click on the label with no movement commits nothing":
    createRoot proc(dispose: proc()) =
      let value = createSignal(10.0)
      let unit = createSignal(pxUnit)
      var commits = 0
      var cfg = propertyRowNumeric(
        name = "Gap", value = value, unit = unit, units = @[pxUnit])
      cfg.onCommitValue = proc(v: string) = commits += 1
      let (r, root) = mkRoot()
      discard r.mountPropertyRow(root, cfg)
      let labelNode = findByAttr(root, "data-property-row-slot",
        "label-scrubber")
      fireEventWith(labelNode, "mousedown",
        MockEvent(`type`: "mousedown", clientX: 5.0, clientY: 5.0))
      fireEventWith(labelNode, "mouseup",
        MockEvent(`type`: "mouseup", clientX: 5.0, clientY: 5.0))
      check commits == 0
      check value.val == 10.0
      dispose()

  test "prkNumeric typed math expression commits to numericValue":
    createRoot do (dispose: proc()):
      let value = createSignal(0.0)
      let unit = createSignal(pxUnit)
      let cfg = propertyRowNumeric(
        name = "Height", value = value, unit = unit,
        units = @[pxUnit])
      let (r, root) = mkRoot()
      discard r.mountPropertyRow(root, cfg)

      let input = findByAttr(root, "data-property-row-input", "true")
      check input != nil
      r.setInputValue(input, "100+50")
      fireEvent(input, "change")
      check value.val == 150.0
      check r.inputValue(input) == "150"
      dispose()

# --------------------------------------------------------------------------- #
#  prkColor
# --------------------------------------------------------------------------- #

suite "Phase D property_row prkColor":

  test "prkColor mount exposes swatch + hex input":
    createRoot do (dispose: proc()):
      let value = createSignal("#0F172A")
      let alpha = createSignal(1.0)
      let cfg = propertyRowColor(name = "Fill", value = value,
                                  alpha = alpha)
      let (r, root) = mkRoot()
      discard r.mountPropertyRow(root, cfg)

      let row = findByAttr(root, "data-property-row-kind", "color")
      check row != nil
      let swatch = findByAttr(root, "data-property-row-swatch", "true")
      check swatch != nil
      let input = findByAttr(root, "data-property-row-input", "true")
      check input != nil
      check r.inputValue(input) == "#0F172A"
      dispose()

# --------------------------------------------------------------------------- #
#  prkChoice
# --------------------------------------------------------------------------- #

suite "Phase D property_row prkChoice":

  test "a choice whose pills fit stays a segmented strip":
    createRoot do (dispose: proc()):
      let value = createSignal("on")
      let options = @[(label: "On", value: "on"), (label: "Off", value: "off")]
      let cfg = propertyRowChoice(name = "Wrap", value = value,
                                   options = options)
      let (r, root) = mkRoot()
      discard r.mountPropertyRow(root, cfg)

      check findByAttr(root, "data-property-row-kind", "choice") != nil
      check findByAttr(root, "data-choice-group", "segmented") != nil

      let pillOff = findByAttr(root, "data-choice-group-pill", "1")
      check pillOff != nil
      check pillOff.attributes.getOrDefault("data-choice-group-label") == "Off"
      fireEvent(pillOff, "click")
      check value.val == "off"
      dispose()

  test "a choice whose pills would overflow becomes a chevron popup":
    ## Deliberate behaviour change, not a test rewrite. Display /
    ## Block-Flex-Grid used to render as a segmented strip and now renders as
    ## a popup, because the row writes its own name and the label gutter
    ## takes 88px of the 196px the row has. The alternative was to leave
    ## these rows unlabelled, which is what made decoration, transform and
    ## list style read as three consecutive rows saying **None**.
    ##
    ## What must not happen is the third option: a strip that stays a strip
    ## and gets sliced mid-word. That is what the width test prevents.
    createRoot do (dispose: proc()):
      let value = createSignal("flex")
      let options = @[
        (label: "Block", value: "block"),
        (label: "Flex", value: "flex"),
        (label: "Grid", value: "grid")]
      let cfg = propertyRowChoice(name = "Display", value = value,
                                   options = options)
      let (r, root) = mkRoot()
      discard r.mountPropertyRow(root, cfg)

      check findByAttr(root, "data-property-row-kind", "choice") != nil
      check findByAttr(root, "data-choice-group", "chevron") != nil
      check findByAttr(root, "data-choice-group", "segmented") == nil
      # The row is named even though no pill is showing the name. The name
      # lives INSIDE the field well now, as Figma's does, rather than in an
      # outside gutter -- `data-property-row-field-label`.
      let label = findByAttr(root, "data-property-row-field-label", "true")
      check label != nil
      check textContent(label) == "Display"
      dispose()

# --------------------------------------------------------------------------- #
#  prkText
# --------------------------------------------------------------------------- #

suite "Phase D property_row prkText":

  test "prkText exposes text input round-tripping textValue":
    createRoot do (dispose: proc()):
      let value = createSignal("Inter")
      let cfg = propertyRowText(name = "Font family", value = value)
      let (r, root) = mkRoot()
      discard r.mountPropertyRow(root, cfg)

      let row = findByAttr(root, "data-property-row-kind", "text")
      check row != nil
      check row.attributes.getOrDefault("data-property-row") ==
        "font-family"

      let input = findByAttr(root, "data-property-row-input", "true")
      check input != nil
      check r.inputValue(input) == "Inter"

      r.setInputValue(input, "Roboto")
      fireEvent(input, "change")
      check value.val == "Roboto"
      dispose()

# --------------------------------------------------------------------------- #
#  prkBoolean
# --------------------------------------------------------------------------- #

suite "Phase D property_row prkBoolean":

  test "prkBoolean exposes checkbox mirroring booleanValue":
    createRoot do (dispose: proc()):
      let value = createSignal(false)
      let cfg = propertyRowBoolean(name = "Visible", value = value)
      let (r, root) = mkRoot()
      discard r.mountPropertyRow(root, cfg)

      let row = findByAttr(root, "data-property-row-kind", "boolean")
      check row != nil
      let checkbox = findByAttr(root, "data-property-row-input", "true")
      check checkbox != nil
      check checkbox.attributes.getOrDefault("type") == "checkbox"
      check not checkbox.attributes.hasKey("checked")

      fireEvent(checkbox, "click")
      check value.val == true
      check checkbox.attributes.hasKey("checked")
      fireEvent(checkbox, "change")
      check value.val == true
      fireEvent(checkbox, "click")
      check value.val == false
      check not checkbox.attributes.hasKey("checked")
      dispose()

# --------------------------------------------------------------------------- #
#  Bound state
# --------------------------------------------------------------------------- #

suite "Phase D property_row binding placeholder":

  test "binding.isSome flips data-property-row-linked + renders chip":
    createRoot do (dispose: proc()):
      let value = createSignal("#0F172A")
      let alpha = createSignal(1.0)
      let binding = some(VariableBinding(
        state: vbsBound,
        variableKey: "color/surface",
        resolvedValue: "#0F172A",
        sourceFileRef: "foundations/colour.nim",
        sourceLineRef: 12))
      let cfg = propertyRowColor(name = "Fill", value = value,
                                  alpha = alpha, binding = binding)
      let (r, root) = mkRoot()
      discard r.mountPropertyRow(root, cfg)

      let row = findByAttr(root, "data-property-row-kind", "color")
      check row != nil
      check row.attributes.getOrDefault("data-property-row-linked") == "true"

      let chip = findByAttr(root, "data-property-row-linked-chip", "true")
      check chip != nil
      let varSpan = findByAttr(root, "data-property-row-linked-variable",
        "color/surface")
      check varSpan != nil
      check textContent(varSpan) == "color/surface"

      # The kind-specific value input must NOT be rendered when the
      # row is in the linked state — Phase E.2 owns the entire value
      # slot in that mode.
      let input = findByAttrPresent(root, "data-property-row-input")
      check input == nil
      dispose()

# --------------------------------------------------------------------------- #
#  Reactive value slot survives an unrelated re-run of the binding effect
# --------------------------------------------------------------------------- #

suite "property_row reactive value slot":

  test "numeric input still tracks its signal after the binding effect re-runs":
    # Regression: ``bindingReactive`` builds the value slot inside a render
    # effect, so the input's value bind is a computation OWNED by that
    # effect. ``updateComputation`` disposes owned computations before each
    # re-run, so a guard that skipped the rebuild when the binding signature
    # was unchanged left the row permanently severed from its value signal.
    # In the editor that froze every numeric row (X / Y / W / H / opacity /
    # font size) at its mount-time value on the first selection change.
    createRoot do (dispose: proc()):
      let value = createSignal(0.0)
      let unit = createSignal(PropertyUnitOption(label: "px", code: "px"))
      # Any signal the binding thunk reads: an unrelated selection change
      # in the editor invalidates the effect exactly like this.
      let selectionTick = createSignal(0)
      let cfg = propertyRowNumeric(
        name = "W", value = value, unit = unit,
        units = @[PropertyUnitOption(label: "px", code: "px")],
        bindingReactive = proc(): Option[VariableBinding] =
          discard selectionTick.val
          none(VariableBinding))
      let (r, root) = mkRoot()
      discard r.mountPropertyRow(root, cfg)

      var input = findByAttr(root, "data-property-row-input", "true")
      check input != nil
      check r.inputValue(input) == "0"

      # The binding is unchanged (still unbound) but the effect re-runs.
      selectionTick.val = 1

      # The rebuilt slot has a fresh input node, so re-resolve it.
      input = findByAttr(root, "data-property-row-input", "true")
      check input != nil

      value.val = 110.0
      check r.inputValue(input) == "110"
      dispose()

# --------------------------------------------------------------------------- #
#  A refused commit must not leave the typed value in the control
# --------------------------------------------------------------------------- #

suite "property_row refused commits":
  ## Found by looking at the rendered panel: grip is a read-only workspace,
  ## so typing 42 into Font size produced the right refusal message AND left
  ## 42 sitting in the field while the element stayed at 34. The message is
  ## one quiet line; the stale number is the thing the eye reads. A control
  ## that keeps a value the pipeline rejected is lying about the document.

  test "a refused numeric commit puts the previous value back":
    createRoot do (dispose: proc()):
      let value = createSignal(34.0)
      let unit = createSignal(pxUnit)
      let rejected = createSignal(0)
      var seen: seq[string] = @[]
      var cfg = propertyRowNumeric(
        name = "Font size", value = value, unit = unit, units = @[pxUnit])
      cfg.commitRejected = rejected
      # Stand in for the pipeline: refuse everything, the way a workspace
      # with `writeSource: false` does.
      cfg.onCommitValue = proc(v: string) =
        seen.add v
        rejected.val = rejected.val + 1

      let (r, root) = mkRoot()
      discard r.mountPropertyRow(root, cfg)
      let input = findByAttr(root, "data-property-row-input", "true")
      check r.inputValue(input) == "34"

      r.setInputValue(input, "42")
      fireEvent(input, "change")

      # The pipeline saw the new value -- refusing is its decision, not the
      # row's, so the row must still offer it.
      check seen == @["42px"]
      # ...and the control is back to what the document actually says.
      check value.val == 34.0
      check r.inputValue(input) == "34"
      dispose()

  test "an accepted numeric commit keeps the new value":
    ## The other half: the revert must not fire when nothing was refused.
    createRoot do (dispose: proc()):
      let value = createSignal(34.0)
      let unit = createSignal(pxUnit)
      let rejected = createSignal(0)
      var changed = 0
      var cfg = propertyRowNumeric(
        name = "Font size", value = value, unit = unit, units = @[pxUnit])
      cfg.commitRejected = rejected
      cfg.onCommitValue = proc(v: string) = discard
      cfg.onChange = proc() = changed += 1

      let (r, root) = mkRoot()
      discard r.mountPropertyRow(root, cfg)
      let input = findByAttr(root, "data-property-row-input", "true")

      r.setInputValue(input, "42")
      fireEvent(input, "change")

      check value.val == 42.0
      check r.inputValue(input) == "42"
      # `onChange` is the "this stuck" signal and must not fire on a refusal.
      check changed == 1
      dispose()

  test "a row with no rejection signal behaves exactly as before":
    ## Every non-inspector caller builds a row without wiring. That path must
    ## not start depending on a signal it never supplies.
    createRoot do (dispose: proc()):
      let value = createSignal(10.0)
      let unit = createSignal(pxUnit)
      var changed = 0
      var cfg = propertyRowNumeric(
        name = "Gap", value = value, unit = unit, units = @[pxUnit])
      cfg.onChange = proc() = changed += 1

      let (r, root) = mkRoot()
      discard r.mountPropertyRow(root, cfg)
      let input = findByAttr(root, "data-property-row-input", "true")
      r.setInputValue(input, "25")
      fireEvent(input, "change")

      check value.val == 25.0
      check changed == 1
      dispose()


suite "numeric full-input validation and gesture cancellation":
  test "only complete finite expressions and known suffixes parse":
    for text in ["10garbage", "10px junk", "(2+3", "2+3)", "1 2", "2**4", "2^99999", "10px+4", "NaN", "Infinity"]:
      check evalMathExpr(text).isNone
    check parseNumericInput(" (2+3)*4rem ").value == some(20.0)
    check parseNumericInput(" (2+3)*4rem ").unit == "rem"

  test "explicit supported unit is committed and unsupported unit is refused":
    createRoot proc(dispose: proc()) =
      let value = createSignal(10.0)
      let unit = createSignal(pxUnit)
      var commits: seq[string]
      var cfg = propertyRowNumeric(name="W", value=value, unit=unit, units= @[pxUnit, emUnit, PropertyUnitOption(code:"",label:"number")])
      cfg.onCommitValue = proc(v: string) = commits.add v
      let (r, root) = mkRoot()
      discard r.mountPropertyRow(root,cfg)
      let input = findByAttr(root,"data-property-row-input","true")
      r.setInputValue(input,"2^4em")
      fireEvent(input,"change")
      fireEvent(input,"blur")
      check value.val == 16.0
      check unit.val == emUnit
      check commits == @["16em"]
      r.setInputValue(input,"16")
      fireEvent(input,"change")
      fireEvent(input,"blur")
      check unit.val == emUnit
      check commits == @["16em"]
      r.setInputValue(input,"30rem")
      fireEvent(input,"change")
      check value.val == 16.0
      check commits == @["16em"]
      dispose()

  test "stationary move and returning to start create no transaction; cancellation restores":
    createRoot proc(dispose: proc()) =
      let value = createSignal(10.0)
      let unit = createSignal(pxUnit)
      var commits = 0
      var cfg = propertyRowNumeric(name="W", value=value, unit=unit, units= @[pxUnit])
      cfg.onCommitValue = proc(v: string) = inc commits
      let (r, root) = mkRoot()
      discard r.mountPropertyRow(root,cfg)
      let handle = findByAttr(root,"data-property-row-slot","label-scrubber")
      proc drag(event: string; x: float) =
        fireEventWith(handle,event,MockEvent(`type`:event,clientX:x,clientY:0))
      drag("mousedown",0)
      drag("mousemove",0)
      drag("mouseup",0)
      check commits == 0
      drag("mousedown",0)
      drag("mousemove",10)
      check value.val == 30
      drag("mousemove",0)
      drag("mouseup",0)
      check commits == 0
      drag("mousedown",0)
      drag("mousemove",10)
      fireEvent(handle,"pointercancel")
      drag("mouseup",10)
      check value.val == 10
      check commits == 0
      dispose()

  test "refused scrub and unit edits restore the original value and unit":
    createRoot proc(dispose: proc()) =
      let value = createSignal(10.0)
      let unit = createSignal(pxUnit)
      let rejected = createSignal(0)
      var cfg = propertyRowNumeric(name="W", value=value, unit=unit, units= @[pxUnit,emUnit])
      cfg.commitRejected = rejected
      cfg.onCommitValue = proc(v: string) = rejected.val = rejected.val+1
      let (r, root) = mkRoot()
      discard r.mountPropertyRow(root,cfg)
      let handle = findByAttr(root,"data-property-row-slot","label-scrubber")
      fireEventWith(handle,"mousedown",MockEvent(clientX:0,clientY:0))
      fireEventWith(handle,"mousemove",MockEvent(clientX:10,clientY:0))
      fireEventWith(handle,"mouseup",MockEvent(clientX:10,clientY:0))
      check value.val == 10
      let chip = findByAttr(root,"data-property-row-unit","true")
      fireEvent(chip,"click")
      check unit.val == pxUnit
      check rejected.val == 2
      dispose()

suite "numeric draft lifetime with reactive binding":
  test "draft movement retains the handle; a real selection rebind disposes it":
    createRoot proc(dispose: proc()) =
      let value = createSignal(10.0)
      let unit = createSignal(pxUnit)
      let selection = createSignal(0)
      var commits = 0
      var cfg = propertyRowNumeric(name="W", value=value, unit=unit, units= @[pxUnit],
        bindingReactive=proc(): Option[VariableBinding] =
          discard selection.val
          none(VariableBinding))
      cfg.onCommitValue = proc(v: string) = inc commits
      let (r, root) = mkRoot()
      discard r.mountPropertyRow(root,cfg)
      let original = findByAttr(root,"data-property-row-field-label","true")
      fireEventWith(original,"mousedown",MockEvent(clientX:0,clientY:0))
      fireEventWith(original,"mousemove",MockEvent(clientX:10,clientY:0))
      check value.val == 30
      check findByAttr(root,"data-property-row-field-label","true") == original
      fireEventWith(original,"mouseup",MockEvent(clientX:10,clientY:0))
      check commits == 1
      selection.val = 1
      check findByAttr(root,"data-property-row-field-label","true") != original
      fireEventWith(original,"mousedown",MockEvent(clientX:0,clientY:0))
      fireEventWith(original,"mousemove",MockEvent(clientX:20,clientY:0))
      fireEventWith(original,"mouseup",MockEvent(clientX:20,clientY:0))
      check value.val == 30
      check commits == 1
      dispose()


suite "choice and text refusal and duplicate lifecycle":
  test "choice no-op does not submit and refusal restores the current option":
    createRoot proc(dispose: proc()) =
      let value = createSignal("on")
      let rejected = createSignal(0)
      var calls = 0
      var cfg = propertyRowChoice(name="Wrap", value=value,
        options= @[(label:"On",value:"on"),(label:"Off",value:"off")])
      cfg.commitRejected = rejected
      cfg.onCommitValue = proc(v: string) =
        inc calls
        rejected.val = rejected.val + 1
      let (r, root) = mkRoot()
      discard r.mountPropertyRow(root,cfg)
      findByAttr(root,"data-choice-group-pill","0").fireEvent("click")
      check calls == 0
      findByAttr(root,"data-choice-group-pill","1").fireEvent("click")
      check calls == 1
      check value.val == "on"
      dispose()
  test "text change plus blur submits once and asynchronous refusal restores input":
    createRoot proc(dispose: proc()) =
      let value = createSignal("Inter")
      var calls = 0
      var complete: proc(ok: bool) {.closure.}
      var cfg = propertyRowText(name="Font family",value=value)
      cfg.onAsyncCommitValue = proc(v: string; done: proc(ok: bool) {.closure.}) =
        check v == "Roboto"
        inc calls
        complete = done
      let (r, root) = mkRoot()
      discard r.mountPropertyRow(root,cfg)
      let input = findByAttr(root,"data-property-row-input","true")
      r.setInputValue(input,"Roboto")
      input.fireEvent("change")
      input.fireEvent("blur")
      check calls == 1
      complete(false)
      check value.val == "Inter"
      check r.inputValue(input) == "Inter"
      input.fireEvent("blur")
      check calls == 1
      dispose()


suite "readonly color inspection":
  test "inspection drafts cannot reach synchronous or asynchronous writers":
    for asynchronous in [false, true]:
      createRoot(proc(dispose: proc()) =
        let value = createSignal("#123456")
        let alpha = createSignal(1.0)
        var calls = 0
        var cfg = propertyRowColor(name = "Fill", value = value, alpha = alpha)
        cfg.readOnlyReason = proc(): string = "Read-only: this source value cannot be edited."
        cfg.onCommitValue = proc(next: string) = inc calls
        if asynchronous:
          cfg.onAsyncCommitValue = proc(next: string; completed: proc(ok: bool)) =
            inc calls
            completed(true)
        let (r, root) = mkRoot()
        discard r.mountPropertyRow(root, cfg)
        let swatch = findByAttr(root, "data-property-row-swatch", "true")
        fireEvent(swatch, "click")
        let popup = findByAttr(root, "data-color-popover-open", "true")
        check popup != nil
        let draft = findByAttr(root, "data-color-popover-input", "true")
        r.setInputValue(draft, "#AABBCC")
        fireEvent(draft, "input")
        fireEvent(draft, "change")
        let apply = findByAttr(root, "data-color-popover-apply", "true")
        fireEvent(apply, "click")
        check calls == 0
        check value.val == "#123456"
        check r.inputValue(draft) == "#AABBCC"
        check findByAttr(root, "data-color-popover-open", "true") != nil
        check textContent(findByAttr(root, "data-color-popover-error", "true")) == "The color edit was refused. " & cfg.readOnlyReason()
        dispose()
        fireEvent(apply, "click")
        check calls == 0)

  test "disposed color row ignores its pending acknowledgement without calling onChange":
    var completed: proc(ok: bool)
    var changed = 0
    var value: Signal[string]
    var disposeRow: proc()
    createRoot(proc(dispose: proc()) =
      disposeRow = dispose
      value = createSignal("#123456")
      var cfg = propertyRowColor(name = "Fill", value = value, alpha = createSignal(1.0))
      cfg.onAsyncCommitValue = proc(next: string; callback: proc(ok: bool)) = completed = callback
      cfg.onChange = proc() = inc changed
      let (r, root) = mkRoot()
      discard r.mountPropertyRow(root, cfg)
      fireEvent(findByAttr(root, "data-property-row-swatch", "true"), "click")
      let draft = findByAttr(root, "data-color-popover-input", "true")
      r.setInputValue(draft, "#AABBCC")
      fireEvent(draft, "input")
      fireEvent(findByAttr(root, "data-color-popover-apply", "true"), "click")
      check completed != nil)
    check changed == 0
    disposeRow()
    completed(true)
    check value.val == "#123456"
    check changed == 0


  test "equal readonly reason follows replacement binding inputs and editable restoration":
    createRoot(proc(dispose: proc()) =
      let value = createSignal("#123456")
      let readonly = createSignal(true)
      let bindingTick = createSignal(0)
      var cfg = propertyRowColor(name = "Fill", value = value, alpha = createSignal(1.0),
        bindingReactive = proc(): Option[VariableBinding] =
          discard bindingTick.val
          none(VariableBinding))
      cfg.readOnlyReason = proc(): string =
        if readonly.val: "Read-only source" else: ""
      let (r, root) = mkRoot()
      discard r.mountPropertyRow(root, cfg)
      let oldInput = findByAttr(root, "data-property-row-input", "true")
      check "readonly" in oldInput.attributes
      bindingTick.val = 1
      let newInput = findByAttr(root, "data-property-row-input", "true")
      check newInput != oldInput
      check "readonly" in newInput.attributes
      readonly.val = false
      check "readonly" notin newInput.attributes
      check "readonly" in oldInput.attributes # disposed watcher is inert
      readonly.val = true
      check "readonly" in newInput.attributes
      dispose())

  test "replaced color slot cannot deliver its pending acknowledgement to new controls":
    createRoot(proc(dispose: proc()) =
      let value = createSignal("#123456")
      let bindingTick = createSignal(0)
      var completed: proc(ok: bool)
      var changed = 0
      var cfg = propertyRowColor(name = "Fill", value = value, alpha = createSignal(1.0),
        bindingReactive = proc(): Option[VariableBinding] =
          discard bindingTick.val
          none(VariableBinding))
      cfg.onAsyncCommitValue = proc(next: string; callback: proc(ok: bool)) = completed = callback
      cfg.onChange = proc() = inc changed
      let (r, root) = mkRoot()
      discard r.mountPropertyRow(root, cfg)
      fireEvent(findByAttr(root, "data-property-row-swatch", "true"), "click")
      let oldDraft = findByAttr(root, "data-color-popover-input", "true")
      r.setInputValue(oldDraft, "#AABBCC")
      fireEvent(oldDraft, "input")
      fireEvent(findByAttr(root, "data-color-popover-apply", "true"), "click")
      check completed != nil
      value.val = "#445566"
      bindingTick.val = 1
      let newInput = findByAttr(root, "data-property-row-input", "true")
      completed(true)
      check value.val == "#445566"
      check r.inputValue(newInput) == "#445566"
      check changed == 0
      dispose())

suite "shared numeric source precision":
  test "mounted default row retains precise source through blur same-value math edits and refusal":
    createRoot do (dispose: proc()):
      let value = createSignal(120.125)
      let unit = createSignal(pxUnit)
      var seen: seq[string]
      let rejected = createSignal(0)
      var cfg = propertyRowNumeric(name="W", value=value, unit=unit, units= @[pxUnit])
      cfg.cssProperty = "width"
      cfg.authoredValue = proc(): string = "120.125px"
      cfg.commitRejected = rejected
      cfg.onCommitValue = proc(next: string) = seen.add next
      let (r,root) = mkRoot()
      discard r.mountPropertyRow(root,cfg)
      let input = findByAttr(root,"data-property-row-input","true")
      check r.inputValue(input) == "120.125"
      fireEvent(input,"blur")
      r.setInputValue(input,"120+1/8px")
      fireEvent(input,"change")
      check seen.len == 0
      check r.inputValue(input) == "120.125"
      r.setInputValue(input,"120.126px")
      fireEvent(input,"change")
      check seen == @["120.126px"]
      check value.val == 120.126
      check r.inputValue(input) == "120.126"
      cfg.onCommitValue = proc(next: string) =
        seen.add next
        rejected.val = rejected.val + 1
      # A separately mounted refusing row exercises exact rollback ownership.
      let rejectedRoot = r.createElement("div")
      discard r.mountPropertyRow(rejectedRoot,cfg)
      let refused = findByAttr(rejectedRoot,"data-property-row-input","true")
      r.setInputValue(refused,"121.123456789px")
      fireEvent(refused,"change")
      check seen[^1] == "121.123456789px"
      check r.inputValue(refused) == "120.125"
      dispose()

  test "default mounted rows parse repeated tiny exponent and long-fraction representations":
    for v in [1e-300, 1e20, 0.1234567890123456, -0.1234567890123456]:
      var text = formatExactNumber(v)
      for iteration in 0 .. 3:
        let parsed = parseNumericInput(text & "em")
        check parsed.value.isSome
        check parsed.value.get == v
        text = formatExactNumber(parsed.value.get)
      createRoot do (dispose: proc()):
        let value = createSignal(v)
        var cfg = propertyRowNumeric(name="Spacing", value=value, unit=createSignal(PropertyUnitOption(label:"em",code:"em")))
        let (r,root) = mkRoot()
        discard r.mountPropertyRow(root,cfg)
        let input = findByAttr(root,"data-property-row-input","true")
        check parseNumericInput(r.inputValue(input)).value.get == v
        dispose()

suite "choice actual value projection":
  test "unlisted and empty current values display honestly and restore on refusal":
    for initial in ["650", "var(--choice)", ""]:
      createRoot proc(dispose: proc()) =
        let value = createSignal(initial)
        let rejected = createSignal(0)
        var calls = 0
        var cfg = propertyRowChoice(name = "Current choice", value = value,
          options = @[(label: "First ordinary option", value: "first"),
                      (label: "Second ordinary option", value: "second")])
        cfg.commitRejected = rejected
        cfg.onCommitValue = proc(v: string) =
          inc calls
          check v == "first"
          rejected.val = rejected.val + 1
        let (r, root) = mkRoot()
        discard r.mountPropertyRow(root, cfg)
        let label = findByAttr(root, "data-choice-group-trigger-label", "true")
        let first = findByAttr(root, "data-choice-group-option", "0")
        let second = findByAttr(root, "data-choice-group-option", "1")
        require label != nil
        check textContent(label) == initial
        check first.attributes.getOrDefault("aria-selected") == "false"
        check second.attributes.getOrDefault("aria-selected") == "false"
        check calls == 0
        fireEvent(first, "click")
        check calls == 1
        check value.val == initial
        check textContent(label) == initial
        value.val = "second"
        check textContent(label) == "Second ordinary option"
        check second.attributes.getOrDefault("aria-selected") == "true"
        fireEvent(second, "click")
        check calls == 1
        value.val = "unlisted later"
        check textContent(label) == "unlisted later"
        check first.attributes.getOrDefault("aria-selected") == "false"
        check second.attributes.getOrDefault("aria-selected") == "false"
        dispose()

suite "property_row scope chips":

  test "each scope chip runs its own callback before re-committing":
    ## The row wraps every chip's ``onChoose`` so choosing a scope also
    ## re-commits. The wrappers are built in a loop, and a Nim closure
    ## made in a loop body shares one environment across the
    ## iterations, so a naive wrap makes every chip run the LAST chip's
    ## callback.
    createRoot do (dispose: proc()):
      let value = createSignal("20px")
      var chosen: seq[string] = @[]
      var commits: seq[string] = @[]
      proc option(name: string): CompactChoiceOption =
        CompactChoiceOption(label: name, shortLabel: name,
          ariaLabel: "Apply " & name, enabled: true,
          dataAttrs: @[("data-test-scope", name)],
          onChoose: proc() = chosen.add name)
      var cfg = propertyRowText(name = "Font size", value = value)
      cfg.cssProperty = "font-size"
      cfg.scopeOptions = proc(): seq[CompactChoiceOption] =
        @[option("local"), option("shared"), option("token")]
      cfg.onCommitValue = proc(v: string) = commits.add v

      let (r, root) = mkRoot()
      discard r.mountPropertyRow(root, cfg)
      for name in ["local", "shared", "token"]:
        let chip = findByAttr(root, "data-test-scope", name)
        check chip != nil
        chosen = @[]
        commits = @[]
        fireEvent(chip, "click")
        check chosen == @[name]
        check commits == @["20px"]
      dispose()

suite "stepped numeric precision":
  ## A step or scrub moves an authored decimal by a decimal step; the sum is
  ## exact to the finer of the two precisions, never the binary64 residue of
  ## the addition (`1.1 + 0.1` is `1.2000000000000002` in binary64).
  test "decimal places are those of the shortest round-trip decimal":
    check decimalPlaces(120.0) == 0
    check decimalPlaces(1.1) == 1
    check decimalPlaces(-0.125) == 3
    check decimalPlaces(1.23456) == 5
    check decimalPlaces(0.30000000000000004) == 17
    check decimalPlaces(1e-20) == 20
    check decimalPlaces(1.5e-7) == 8
    check decimalPlaces(1e20) == 0
    check decimalPlaces(NaN) == 0
    check decimalPlaces(Inf) == 0

  test "an inexact result is rounded once, never to zero":
    check roundInexact(1.0 / 3.0, 4) == 0.3333
    check roundInexact(1.0 / 30000.0, 4) == 0.00003333
    check roundInexact(66.66666666666667, 4) == 66.6667
    check roundInexact(0.0, 4) == 0.0
    # Beyond the exact power-of-ten table the mantissa is rounded instead.
    check roundInexact(1e-30, 4) == 1e-30
    check roundInexact(1e-20 / 3.0, 4) == 3.333e-21
    check roundInexact(-2e-25 / 3.0, 4) == -6.667e-26
    check parseNumericInput("1e-20/3").value.get == 3.333e-21

  test "row numbers are spelled the same natively and under JS":
    ## The spelling ECMAScript's Number::toString gives, which the browser
    ## editor has always written: plain decimal from 1e-6 up to 1e21.
    for (value, text) in [(1e20, "100000000000000000000"),
        (1.5e21, "1.5e+21"), (1e21, "1e+21"), (1e-7, "1e-7"),
        (-2.5e-8, "-2.5e-8"), (1e-6, "0.000001"), (123.0, "123"),
        (0.1, "0.1"), (-0.0, "0"), (3.333e-21, "3.333e-21"),
        (1.7976931348623157e308, "1.7976931348623157e+308")]:
      check formatExactNumber(value) == text
      check parseNumericInput(text & "px").value.get == value

  test "plain decimal text is the same natively and under JS":
    for (value, text) in [(1e-7, "0.0000001"), (-1.5e-7, "-0.00000015"),
        (1e20, "100000000000000000000"), (1.5e21, "1500000000000000000000"),
        (0.1, "0.1"), (120.0, "120"), (-0.0, "0"), (33.33333, "33.33333"),
        (1.2345e-5, "0.000012345")]:
      check exactNumberText(value) == text
      check parseFloat(text) == value

  test "significant digits are those of the shortest round-trip decimal":
    check significantDigits(0.00125) == 3
    check significantDigits(120.0) == 2
    check significantDigits(1e20) == 1
    check significantDigits(-1.5) == 2
    check significantDigits(1.0 / 3.0) == 16
    check significantDigits(0.0009765625) == 7
    check significantDigits(1e-20) == 1
    check significantDigits(0.0) == 0
    check significantDigits(NaN) == 0

  test "a step is exact to the finer of the value's and the step's precision":
    # The Arrow (1), Shift (10) and Alt (0.1) steps on values whose binary64
    # sums carry noise, both directions, negative values included.
    for (start, delta, expected) in [(1.1, 0.1, "1.2"), (0.7, 0.1, "0.8"),
        (0.3, -0.1, "0.2"), (-0.7, -0.1, "-0.8"), (-1.1, 0.1, "-1"),
        (10.1, -10.0, "0.1"), (0.2, 0.1, "0.3"), (82.0, 0.1, "82.1"),
        (1.23456, 1.0, "2.23456"), (1.23456, 0.1, "1.33456"),
        (120.125, 0.1, "120.225"), (-0.1, 0.1, "0"), (0.1, -0.1, "0"),
        (1e-20, 1.0, "1"), (1e20, 1.0, formatExactNumber(1e20)),
        (0.125, 0.1, "0.225")]:
      let stepped = steppedNumber(start, delta)
      check formatExactNumber(stepped) == expected
      check parseNumericInput(formatExactNumber(stepped) & "px").value.get == stepped
    # Never -0 (it would be written as `-0px`).
    check formatExactNumber(steppedNumber(-0.1, 0.1)) == "0"
    # Non-finite input passes through unchanged.
    check steppedNumber(Inf, 1.0) == Inf
    check steppedNumber(NaN, 1.0).isNaN

  test "percent and ratio convert at each other's precision":
    check percentToRatio(80.0126) == 0.800126
    check percentToRatio(0.35) == 0.0035
    check percentToRatio(7.0) == 0.07
    check ratioToPercent(0.0035) == 0.35
    check ratioToPercent(0.07) == 7.0
    check ratioToPercent(0.29) == 29.0
    check ratioToPercent(0.07000000000000002) == 7.000000000000002
    # A ratio that is itself binary64 residue keeps the plain product.
    check ratioToPercent(0.8001260000000001) == 0.8001260000000001 * 100.0

  test "typed arithmetic is exact to its operands' precision":
    # Sums, differences and products of decimals terminate; their binary64
    # results (`0.1 + 0.2` is `0.30000000000000004`) do not reach the field.
    for (typed, expected, unit) in [("0.1+0.2px", "0.3", "px"),
        ("1.1*3", "3.3", ""), ("2.5-0.7rem", "1.8", "rem"),
        ("0.7+0.1", "0.8", ""), ("-0.3-0.1em", "-0.4", "em"),
        ("1.1^2", "1.21", ""), ("(0.1+0.2)*3", "0.9", ""),
        ("1.23456+1", "2.23456", ""), ("0.1-0.1", "0", ""),
        # A quotient or fractional power that terminates within 15
        # significant digits is exact; otherwise it is rounded to
        # `inexactPlaces` (4), or to its operands' finer precision.
        ("10/3", "3.3333", ""), ("10/3rem", "3.3333", "rem"),
        ("-2/3px", "-0.6667", "px"), ("120+1/8px", "120.125", "px"),
        ("1/32", "0.03125", ""), ("1/1024turn", "0.0009765625", "turn"),
        ("1.234567/1", "1.234567", ""), ("1.2345678/3", "0.4115226", ""),
        ("2^0.5", "1.4142", ""), ("2^-1", "0.5", ""),
        # An inexact part is carried unrounded and the result rounded once,
        # at the end (not 0.9999 / 99.9999 / 66.6666).
        ("(1/3)*3", "1", ""), ("1/3+1/3+1/3", "1", ""), ("100/3*3", "100", ""),
        ("100/3*2", "66.6667", ""), ("10/3-10/3", "0", ""),
        ("2^0.5*2^0.5", "2", ""), ("1/3*1.23456", "0.41152", ""),
        # A small nonzero result keeps four significant digits.
        ("1/30000", "0.00003333", ""), ("1/30000turn", "0.00003333", "turn"),
        ("1/3000", "0.0003333", ""), ("-1/30000", "-0.00003333", ""),
        # A minus sign negates a parenthesised group (editor spec "Numeric
        # Inputs"), nested, with a unit, and keeping exactness.
        ("-(2+3)", "-5", ""), ("-(2+3)px", "-5", "px"), ("-(-(1/3))*3", "1", ""),
        ("-(0.1+0.2)", "-0.3", ""), ("10*-(1.1)", "-11", ""),
        ("-(2)^2", "-4", ""), ("+(2+3)em", "5", "em"), ("- (4/2)", "-2", ""),
        # A sign applies after a power and may follow one (approved
        # 2026-11); one sign per operand, as in CSS calc().
        ("-2^2", "-4", ""), ("2^-1", "0.5", ""), ("2^-(1)", "0.5", ""),
        ("-2^-2", "-0.25", ""), ("2^-3^2", "0.001953125", ""),
        ("5--3", "8", ""), ("5 - -3px", "8", "px"), ("-0.5em", "-0.5", "em"),
        ("+4", "4", ""), ("-(2+3)", "-5", ""),
        ("3-(-(1.5))", "4.5", ""), ("-(-(-(1)))", "-1", ""), ("-(0)", "0", ""),
        # Negation keeps the inexact mark, so the result is rounded once.
        ("-(1/3)", "-0.3333", ""), ("-(10/3)rem", "-3.3333", "rem"),
        ("-(1/3)+0.1", "-0.2333", ""), ("0.1+-(1/3)", "-0.2333", ""),
        # A literal without arithmetic stays exactly as authored.
        ("0.30000000000000004px", "0.30000000000000004", "px"),
        ("1.23456789px", "1.23456789", "px")]:
      let parsed = parseNumericInput(typed)
      check parsed.value.isSome
      check parsed.unit == unit
      if parsed.value.isSome:
        check formatExactNumber(parsed.value.get) == expected
    check inexactPlaces == 4
    # Still refused: a sign with nothing to negate, or an unclosed group.
    for typed in ["-()", "-(2+3", "-", "-(px", "(-)", "--1", "-+-1", "- -1",
        "+-1", "-+1", "5---3", "2^--1"]:
      check parseNumericInput(typed).value.isNone

  test "a typed expression commits the exact sum with its unit":
    createRoot proc(dispose: proc()) =
      let value = createSignal(10.0)
      let unit = createSignal(pxUnit)
      var seen: seq[string]
      var cfg = propertyRowNumeric(
        name = "W", value = value, unit = unit, units = @[pxUnit])
      cfg.onCommitValue = proc(v: string) = seen.add v
      let (r, root) = mkRoot()
      discard r.mountPropertyRow(root, cfg)
      let input = findByAttr(root, "data-property-row-input", "true")
      r.setInputValue(input, "0.1+0.2px")
      fireEvent(input, "change")
      check seen == @["0.3px"]
      check r.inputValue(input) == "0.3"
      r.setInputValue(input, "10/3")
      fireEvent(input, "change")
      check seen == @["0.3px", "3.3333px"]
      dispose()

  test "scrubbed values are exact to the start value's and the step's precision":
    let none0 = none(float)
    # Alt at 1x speed: 3px of 0.1 from 1.1 (binary64: 1.4000000000000001).
    check scrubbedValue(1.1, 3.0, 20.0, 1.0, false, true, none0, none0) == 1.4
    check formatExactNumber(scrubbedValue(1.1, 3.0, 20.0, 1.0, false, true,
      none0, none0)) == "1.4"
    # Alt at the 2x near speed: 3px of 0.2 from 1.1 (binary64: 1.7000000000000002).
    check scrubbedValue(1.1, 3.0, 0.0, 1.0, false, true, none0, none0) == 1.7
    # Leftward and negative.
    check scrubbedValue(-1.1, -3.0, 20.0, 1.0, false, true, none0, none0) == -1.4
    # Shift's coarse step from a fraction (binary64: 0.09999999999999964).
    check scrubbedValue(10.1, -1.0, 20.0, 1.0, true, false, none0, none0) == 0.1
    # The finest speed (1/4) with Alt moves 0.025 per pixel.
    check scrubbedValue(0.7, 3.0, 100.0, 1.0, false, true, none0, none0) == 0.775
    # Authored precision finer than the step is kept, not rounded to the step.
    check formatExactNumber(scrubbedValue(1.23456, 1.0, 20.0, 1.0, false,
      false, none0, none0)) == "2.23456"
    check formatExactNumber(scrubbedValue(0.125, 1.0, 20.0, 1.0, false, true,
      none0, none0)) == "0.225"
    # A drag that crosses zero writes 0, not -0.
    check formatExactNumber(scrubbedValue(-0.1, 1.0, 20.0, 1.0, false, true,
      none0, none0)) == "0"

  test "a mounted row's Alt scrub previews and commits the exact sum":
    createRoot proc(dispose: proc()) =
      let value = createSignal(1.1)
      let unit = createSignal(pxUnit)
      var seen: seq[string]
      var cfg = propertyRowNumeric(
        name = "W", value = value, unit = unit, units = @[pxUnit])
      cfg.onCommitValue = proc(v: string) = seen.add v
      let (r, root) = mkRoot()
      discard r.mountPropertyRow(root, cfg)
      let labelNode = findByAttr(root, "data-property-row-slot",
        "label-scrubber")
      let input = findByAttr(root, "data-property-row-input", "true")
      proc drag(event: string; x, y: float) =
        fireEventWith(labelNode, event, MockEvent(`type`: event,
          clientX: x, clientY: y, altKey: true))
      drag("mousedown", 0.0, 0.0)
      drag("mousemove", 3.0, 20.0)
      check r.inputValue(input) == "1.4"
      check value.val == 1.4
      drag("mouseup", 3.0, 20.0)
      check seen == @["1.4px"]
      dispose()


suite "property_row shared source impact before scope commit":
  test "shared destination is visible while local, before the real scope click":
    createRoot do (dispose: proc()):
      let local = SourceScopeChoice(kind: sskLocalInstance, label: "Local", editable: true)
      let shared = SourceScopeChoice(kind: sskSharedClass, label: "Shared class",
        editable: true, ownerLabel: "DestinationCard", sourceFile: "src/cards.nim",
        sourceLine: 42, schemaKey: "classes.destination.padding", usageCount: 2,
        affectedComponents: @["DestinationCard", "SearchCard"],
        affectedStories: @[StoryRef(group: "DestinationCard", name: "Default")])
      let choices = createSignal(@[local, shared])
      let selected = createSignal(some(local))
      var commits = 0
      var cfg = propertyRowText(name = "Padding", value = createSignal("18px"))
      cfg.cssProperty = "padding"
      cfg.sourceScopeChoices = proc(): seq[SourceScopeChoice] = choices.val
      cfg.selectedSourceScope = proc(): Option[SourceScopeChoice] = selected.val
      cfg.scopeOptions = proc(): seq[CompactChoiceOption] =
        @[CompactChoiceOption(label: "Shared", shortLabel: "Shared",
          ariaLabel: "Apply shared class scope for padding", enabled: true,
          dataAttrs: @[("data-test-shared-scope", "true")],
          onChoose: proc() = selected.val = some(shared))]
      cfg.onCommitValue = proc(value: string) = inc commits
      let (r, root) = mkRoot()
      discard r.mountPropertyRow(root, cfg)
      let impact = findByAttr(root, "data-property-source-impact", "padding")
      require impact != nil
      check selected.val.get.kind == sskLocalInstance
      check impact.styles.getOrDefault("display") == "block"
      for expected in ["Shared class (available)", "DestinationCard", "src/cards.nim:42",
          "classes.destination.padding", "2 mapped uses", "SearchCard",
          "DestinationCard / Default", "Other uses of this shared source may change."]:
        check expected in textContent(impact)
      check commits == 0
      let chip = findByAttr(root, "data-test-shared-scope", "true")
      require chip != nil
      fireEvent(chip, "click")
      check selected.val.get.kind == sskSharedClass
      check commits == 1
      check "Shared class (selected)" in textContent(impact)
      choices.val = @[local]
      selected.val = some(local)
      check impact.styles.getOrDefault("display") == "none"
      check textContent(impact) == ""
      check commits == 1
      dispose()

suite "a typed value is checked against its property's CSS grammar":
  test "a value valid under CSS is accepted however it is shaped; its invalid neighbours are refused":
    # isonim-pm issue 2026-11-20 "The editor refuses valid CSS values it
    # mistakes for lengths, and some CSS-wide keywords". Editor spec
    # "Planned interaction parity": a value valid for its property is
    # written; invalid values are rejected without changing source. Each
    # class pairs the values CSS accepts with neighbours it does not.
    proc reasons(property, value: string): seq[string] =
      for d in validateCssPropertyValue(PropertyInfo(name: property,
          directStyleAllowed: true),
          PropertyEditRequest(property: property, newValue: value, kind: pekCss),
          parseCssPropertyValue(property, value)):
        result.add d.message
    proc accepts(property, value: string) =
      checkpoint "accepts " & property & ": " & value
      check reasons(property, value).len == 0
    proc refuses(property, value: string) =
      checkpoint "refuses " & property & ": " & value
      check reasons(property, value).len > 0
    # The CSS-wide keywords (CSS Cascade 5 §7.3), also for the properties
    # that check their values with their own grammars.
    for p in ["opacity", "aspect-ratio", "filter", "backdrop-filter",
        "transition-timing-function", "font-family", "transform"]:
      for wide in ["inherit", "initial", "unset", "revert", "revert-layer"]:
        accepts(p, wide)
    # A word ending in a unit's letters is a word, not a length (CSS Syntax 3
    # §4.3.10): CSS Display 3, Box Alignment 3, Sizing 4, Counter Styles 3.
    for (p, v) in [("display", "contents"), ("display", "list-item"),
        ("align-items", "stretch"), ("justify-content", "stretch"),
        ("width", "stretch"), ("list-style-type", "brand-ticks"),
        ("list-style-type", "emoji-px"), ("text-overflow", "ellipsis")]:
      accepts(p, v)
    for (p, v) in [("display", "4px"), ("display", "contentss"),
        ("align-items", "4em"), ("list-style-type", "12px"),
        ("width", "stretchy"), ("height", "list-item")]:
      refuses(p, v)
    # The viewport units' small, large and dynamic forms (CSS Values 4
    # §6.1.2).
    for (p, v) in [("height", "100dvh"), ("height", "50svh"),
        ("width", "10vmin"), ("max-height", "80lvh")]:
      accepts(p, v)
    for (p, v) in [("height", "100dvhx"), ("height", "100dv"),
        ("padding", "-4dvh")]:
      refuses(p, v)
    # Multi-value box properties: each value is one the longhand row takes
    # (CSS Box 4 §3-4, Backgrounds 3 §4.4 and §5, Box Alignment 3 §8.3,
    # Overflow 3 §3.1).
    for (p, v) in [("padding", "4px 8px"), ("padding", "1px 2px 3px 4px"),
        ("padding", "var(--space) 4px"), ("margin", "0 auto"),
        ("margin", "4px auto 0"), ("margin", "-4px 0"), ("gap", "1rem 2rem"),
        ("gap", "normal 4px"), ("border-radius", "4px 8px"),
        ("border-radius", "4px / 8px"), ("border-radius", "1px 2px 3px 4px / 5px 6px"),
        ("border-top-left-radius", "4px 8px"), ("border-width", "1px 2px"),
        ("border-width", "thin 2px medium"), ("inset", "0 auto"),
        ("overflow", "hidden auto"), ("padding", "4px 12pt")]:
      accepts(p, v)
    for (p, v) in [("padding", "1px 2px 3px 4px 5px"), ("padding", "4px -2px"),
        ("padding", "4px auto"), ("padding", "4px 12qq"), ("margin", "0, auto"),
        ("margin", "4px / 2px"), ("gap", "1px 2px 3px"),
        ("border-radius", "4px / 8px / 2px"), ("border-radius", "4px -1px"),
        ("border-top-left-radius", "1px 2px 3px"),
        ("border-width", "1px 2px 3px 4px 5px"), ("border-width", "1px thick-ish"),
        ("overflow", "hidden auto scroll"), ("overflow", "hidden banana")]:
      refuses(p, v)
    # A malformed amount keeps its own reason.
    check "CSS length values must use a numeric amount." in reasons("gap", "12 apples")
    # Positions and sizes of background layers (CSS Backgrounds 3 §3.6,
    # §3.9; object-position is a CSS Values 4 §8.3 <position>, which has no
    # three-value form).
    for (p, v) in [("background-position", "10px 20px"),
        ("background-position", "0% 0%"), ("background-position", "right 10px top 5px"),
        ("background-position", "center top"), ("background-position", "left 10px top"),
        ("background-position", "left top, 10px 20px"),
        ("object-position", "right 10px top 5px"), ("background-size", "100px 50px"),
        ("background-size", "auto, 8px 8px"), ("background-size", "cover, auto"),
        ("background-size", "50% auto")]:
      accepts(p, v)
    for (p, v) in [("background-position", "10px 20px 30px"),
        ("background-position", "left right"), ("background-position", "10px left"),
        ("background-position", "left top center"),
        ("background-position", "center 10px top"),
        ("object-position", "left 10px top"), ("background-size", "-10px 5px"),
        ("background-size", "cover contain"), ("background-size", "1px 2px 3px"),
        ("background-size", "cover 10px")]:
      refuses(p, v)
    # Transition time lists (CSS Transitions 1 §2.2: durations are not
    # negative; §2.4: a delay may be) and math on times.
    for (p, v) in [("transition-duration", "1s, 200ms"),
        ("transition-duration", "calc(100ms * 2)"), ("transition-delay", "0s, 50ms"),
        ("transition-delay", "-1s"), ("transition-delay", "-1s, 2s")]:
      accepts(p, v)
    for (p, v) in [("transition-duration", "-1s"), ("transition-duration", "1s, -2s"),
        ("transition-duration", "1s,"), ("transition-duration", "1s 2s"),
        ("transition-duration", "200"), ("transition-duration", "calc(100ms+2ms)"),
        ("transition-delay", "1px"), ("transition-delay", "0s, , 1s")]:
      refuses(p, v)
    # The text-decoration shorthand (CSS Text Decoration 4 §2.6): line,
    # style, colour and thickness, each once.
    for v in ["underline 2px", "underline wavy red 1px", "line-through from-font"]:
      accepts("text-decoration", v)
    for v in ["underline 2px 3px", "none underline", "underline underline",
        "underline red blue"]:
      refuses("text-decoration", v)
    # Grid track lists (CSS Grid 2 §7.2).
    for v in ["minmax(0, 1fr) 200px", "220px minmax(260px, 1fr) 320px",
        "repeat(2, 1fr) 100px", "[a] 100px [b] 1fr", "fit-content(20em) 1fr"]:
      accepts("grid-template-columns", v)
    for v in ["-10px 1fr", "minmax(1fr, 2fr) 10px", "repeat(0, 1fr) 10px",
        "100px 1fr,", "minmax(0) 10px"]:
      refuses("grid-template-columns", v)
    # Transform functions whose arguments hold commas (CSS Transforms 1
    # §11, Transforms 2 §13), with their counts and types.
    for v in ["translate(4px, 2px) scale(1.2)", "matrix(1, 0, 0, 1, 0, 0)",
        "translate(-50%, -50%)", "rotate3d(1, 0, 0, 45deg)",
        "scale(1.2, 50%) skew(10deg, 0)", "translate(var(--x), 2px)"]:
      accepts("transform", v)
    for v in ["translate(-3 -3)", "translate(4px, 2px, 3px)",
        "matrix(1, 0, 0, 1, 0)", "rotate(45)", "rotate(45) scale(1, 2)", "scale(1, 2, 3) rotate(1deg)",
        "translate(4px, 2px) glow(1)", "translate(4px, 2px), scale(2)"]:
      refuses("transform", v)
    # Math functions (CSS Values 4 §10) and fit-content() (CSS Sizing 4
    # §3.1) where a length goes.
    for (p, v) in [("width", "clamp(10px, 50%, 300px)"), ("width", "min(100%, 40rem)"),
        ("width", "max(10px, 2vw)"), ("font-size", "clamp(1rem, 2vw, 2rem)"),
        ("outline-offset", "calc(1px + 1px)"),
        ("left", "max(-4px, calc(50% - 32px))"), ("height", "fit-content(20em)"),
        ("max-width", "min(92vw, 760px)"), ("padding", "calc(1px + 2px) 4px")]:
      accepts(p, v)
    for (p, v) in [("width", "clamp(1px, 2px)"), ("width", "calc(1px+2px)"),
        ("width", "min()"), ("width", "calc(1px + )"), ("width", "foo(1px)"),
        ("font-family", "calc(1px)"), ("height", "fit-content(-1px)"),
        ("height", "fit-content(1px, 2px)"), ("top", "fit-content(20em)"),
        ("outline-offset", "calc(1px + red)")]:
      refuses(p, v)
    # aspect-ratio: `auto || <ratio>` (CSS Sizing 4 §5.1).
    for v in ["1", "auto 16 / 9", "16 / 9 auto", "1.5"]:
      accepts("aspect-ratio", v)
    for v in ["auto auto", "0", "-1", "16 / 0", "1 2", "16 / 9 / 2"]:
      refuses("aspect-ratio", v)
    # Filter functions and references (Filter Effects 1 §5-6).
    for (p, v) in [("filter", "drop-shadow(0 1px 2px #000)"), ("filter", "url(#f)"),
        ("filter", "var(--f)"), ("filter", "blur(2px) drop-shadow(red 1px 1px)"),
        ("backdrop-filter", "blur(4px) saturate(150%)")]:
      accepts(p, v)
    for (p, v) in [("filter", "drop-shadow(1px)"), ("filter", "drop-shadow(1px red 2px)"),
        ("filter", "drop-shadow(1px 1px -2px)"), ("filter", "blur(-1px)"),
        ("filter", "glow(4px)"), ("backdrop-filter", "brightness(-1)")]:
      refuses(p, v)
    # Easing functions (CSS Easing 2 §2-4).
    for v in ["linear(0, 0.5 50%, 1)", "ease, linear", "steps(2, jump-none)",
        "cubic-bezier(0.1, -2, 0.3, 3)"]:
      accepts("transition-timing-function", v)
    for v in ["linear(0)", "linear(0, 50%)", "cubic-bezier(2, 0, 0, 1)", "steps(0)",
        "steps(1, jump-none)", "sproing", "ease,"]:
      refuses("transition-timing-function", v)
    # font-family (CSS Fonts 4 §2.1): names or quoted strings, comma separated.
    for v in ["Inter, sans-serif", "\"Helvetica Neue\", Arial, sans-serif", "far",
        "foo bar baz", "-apple-system, BlinkMacSystemFont", "'Font, with comma', serif",
        "var(--font), serif"]:
      accepts("font-family", v)
    for v in ["12px", "Arial,", "a, , b", "\"unclosed", "#fff", "!!!",
        "inherit, serif", "\"a\" b", "default"]:
      refuses("font-family", v)
    # A CSS-wide keyword is a whole value, never one part of a multi-part
    # value (CSS Cascade 5 §7.3).
    for (p, v) in [("margin", "inherit 2px"), ("margin", "1px inherit"),
        ("padding", "initial initial"), ("inset", "unset 1px"),
        ("border-width", "revert-layer 1px"), ("gap", "1px inherit"),
        ("overflow", "initial initial"), ("overflow", "unset hidden"),
        ("border-radius", "revert / 2px"), ("border-radius", "2px / inherit"),
        ("border-top-left-radius", "inherit 2px")]:
      refuses(p, v)
    # Math is type-checked (CSS Values 4 §10.9): `+`/`-` need one type, `*`
    # a number side, `/` a number divisor; a zero divisor is not finite and
    # is refused (editor spec: non-finite values are rejected); a time is not
    # a length.
    for (p, v) in [("width", "calc(100% - 2 * 16px)"), ("width", "calc(10px / 2)"),
        ("width", "calc((100% - 2rem) / 3)"), ("line-height", "calc(2 * 3)"),
        ("line-height", "calc(1em + 2px)"), ("font-size", "calc(1rem + 2%)"),
        ("transition-duration", "calc(100ms * 2)"), ("width", "calc(var(--w) * 2)"),
        ("transform", "rotate(calc(10deg + 5deg)) scale(calc(1.5))")]:
      accepts(p, v)
    for (p, v) in [("font-size", "calc(1px * 2px)"), ("font-size", "calc(10px + 5)"),
        ("font-size", "calc(2 * 3)"), ("font-size", "calc(1px / 0)"),
        ("outline-offset", "calc(10px + 5)"), ("outline-offset", "calc(1px / 0)"),
        ("line-height", "calc(1px * 2px)"), ("line-height", "calc(1px / 0)"),
        ("line-height", "clamp(1px, 2px)"), ("line-height", "min(1px, red)"),
        ("width", "calc(1s)"), ("width", "calc(2px / 1px)"), ("width", "calc(1px / 0.0)"),
        ("left", "calc(10px + 5)"), ("padding-top", "calc(2 * 3)"),
        ("transition-duration", "calc(1px)"), ("transition-duration", "calc(1s + 1)"),
        # A divisor that folds to zero, and any folded result that is not
        # finite, is refused (CSS Values 4 §10.10; editor spec: non-finite
        # values are rejected).
        ("width", "calc(1px / (1 - 1))"), ("width", "calc(1px / (2 * 0))"),
        ("width", "calc(1px * 1e999)"), ("width", "calc(1px / min(0, 1))"),
        ("width", "calc(1px / clamp(0, -1, 0))"), ("width", "calc(1e300px * 1e300)"),
        ("line-height", "calc(2 / (3 - 3))"), ("font-size", "calc(1rem / max(-1, 0))")]:
      refuses(p, v)
    # Divisors that fold to a non-zero number stay valid.
    for (p, v) in [("width", "calc(1px / (2 - 1))"), ("width", "calc(100% / min(3, 4))"),
        ("line-height", "calc((1 + 2) / 2)"), ("width", "calc(1px / var(--n))")]:
      accepts(p, v)
    # url() takes one quoted string or an unquoted URL with no whitespace,
    # quotes or parentheses (CSS Values 4 §4.5, CSS Syntax 3 §4.3.6).
    for v in ["url(#f)", "url(a.svg#f)", "url(\"a b.svg#f\")", "url('x')"]:
      accepts("filter", v)
    for v in ["url(a b)", "url(\"a)", "url(a\"b)", "url(a(b))"]:
      refuses("filter", v)
    # An empty url() is a url token resolving to an invalid resource (CSS
    # Values 4 §4.5.1): the value is valid.
    for v in ["url()", "url( )"]:
      accepts("filter", v)
    # Math inside transform arguments is type-checked too, and auto-repeat
    # grid tracks follow CSS Grid 2 §7.2.3.1.
    for v in ["rotate(calc())", "rotate(calc(banana))", "rotate(min(1px))",
        "scale(calc(10px))", "translate(calc(1s), 0)"]:
      refuses("transform", v)
    for v in ["repeat(auto-fill, minmax(100px, 1fr))", "100px repeat(auto-fit, 10px) 20px",
        "repeat(2, 1fr) [a] 10px"]:
      accepts("grid-template-columns", v)
    for v in ["repeat(auto-fill, 1fr)", "repeat(auto-fill, 10px) repeat(auto-fit, 10px)",
        "repeat(auto-fill, 10px) auto", "[a] [b] 1fr", "repeat(auto-fill, 10px) 1fr",
        "repeat(2, repeat(2, 1px))"]:
      refuses("grid-template-columns", v)
    # A priority, a comment or a second declaration is not part of a value.
    for (p, v) in [("padding", "4px 8px !important"), ("margin", "0 auto /* open"),
        ("margin", "/* only a comment */"),
        ("display", "contents !important"), ("transform", "scale(2); color: red")]:
      refuses(p, v)
    # A closed comment is not part of the value (CSS Syntax 3 §4.3.2): the
    # value around it is checked.
    for (p, v) in [("margin", "0 auto /* c */"), ("width", "calc(1px /* c */ + 2px)"),
        ("font-family", "Arial /* c */"), ("font-size", "12px /* compact */")]:
      accepts(p, v)
    refuses("width", "calc(1px /* c */ + 2s)")
    # `/*` inside a string or an unquoted url() is literal, not a comment
    # (CSS Syntax 3 §4.3.5-4.3.6).
    for (p, v) in [("font-family", "\"a/*b\", serif"), ("font-family", "\"a\\\"/*b\""),
        ("filter", "url(\"a/*\") blur(1px)"), ("filter", "url(a/*b*/c)"),
        ("filter", "url(a/*b) blur(1px)")]:
      accepts(p, v)
    # A comment is not the whitespace math needs around `+` and `-` (CSS
    # Values 4 §10.1); real whitespace beside it still counts.
    for v in ["calc(1px/**/+ 2px)", "calc(1px +/**/2px)", "calc(1px/**/-/**/2px)"]:
      refuses("width", v)
    for v in ["calc(1px /**/ + 2px)", "calc(1px + /**/2px)", "calc(1px/**/ + 2px)",
        "calc(2/**/*3px)", "calc(1px */**/-2)", "calc(/**/-1px + 2px)", "max(1px,/**/-2px)"]:
      accepts("width", v)
    # A comment ends a token: `-/**/1px` is a `-` and then `1px`, not a
    # signed number, which math does not take.
    for (p, v) in [("width", "calc(-/**/1px)"), ("width", "calc(+/**/1px)"),
        ("width", "calc(1px + -/**/2px)"), ("width", "calc(1px * -/**/2)"),
        ("width", "min(1px, -/**/2px)"), ("width", "calc(1px/**/- 2px)"),
        ("width", "calc(1px/**/-2px)")]:
      refuses(p, v)
    # Outside math a comment only separates tokens; no operator whitespace
    # rule applies there.
    for (p, v) in [("filter", "drop-shadow(1px/**/-1px 2px red)"),
        ("color", "rgb(10/**/-5 0)"), ("transform", "translate(1px/**/, -2px)"),
        # An identifier may end in `-`; a comment after it ends the token,
        # so `[a-/**/b]` is two line names (CSS Syntax 3 §4.3.11).
        ("grid-template-columns", "repeat(2, [a-/**/b] 1fr)"),
        ("grid-template-columns", "repeat(2, [a-/**/b-] 1fr)"),
        ("grid-template-columns", "repeat(auto-fill, [col-/**/start] 100px)")]:
      accepts(p, v)
    # Math types come from each property's own single-value rule (R5, F7):
    # a property that refuses `10%` refuses percentage math, and one that
    # takes numbers or angles takes math of that type.
    for (p, v) in [("border-width", "calc(10%)"), ("border-width", "calc(1px + 10%)"),
        ("border-width", "min(1px, 10%)"), ("border-top-width", "calc(10%)"),
        ("border-width", "calc(10%) 1px"), ("border-width", "1px min(10%, 2px)"),
        ("outline-offset", "calc(10%)"), ("outline-offset", "calc(1px + 10%)"),
        ("outline-offset", "min(1px, 10%)"), ("opacity", "calc(1px)"),
        ("font-weight", "calc(400px)"), ("font-weight", "1px"), ("rotate", "calc(10px)"),
        ("flex-grow", "calc(1px)"), ("border-color", "1px"), ("z-index", "calc(1px)"),
        ("display", "calc(1px)"), ("font", "calc(12px)")]:
      refuses(p, v)
    for (p, v) in [("border-width", "calc(1px + 1em)"), ("outline-offset", "calc(1px * 2)"),
        ("padding", "calc(10% + 1px)"), ("opacity", "calc(0.5)"), ("opacity", "calc(50%)"),
        ("font-weight", "calc(400)"), ("rotate", "calc(10deg)"), ("z-index", "calc(2)"),
        ("aspect-ratio", "calc(16 / 9)"), ("transition-duration", "calc(1s / 2), 1s"),
        # word-spacing takes a length or percentage like letter-spacing (CSS
        # Text 4 §8.1); outline-width a length (CSS UI 4 §4.2).
        ("word-spacing", "2px"), ("word-spacing", "10%"), ("word-spacing", "calc(1px + 0.1em)"),
        ("word-spacing", "calc(1px + 10%)"), ("outline-width", "2px"),
        ("outline-width", "calc(1px + 1em)")]:
      accepts(p, v)
    for (p, v) in [("outline-width", "10%"), ("outline-width", "calc(10%)"),
        ("outline-width", "clamp(1px, 10%, 3px)"), ("outline-width", "-1px"),
        ("word-spacing", "2s")]:
      refuses(p, v)
    # The numeric constants pi and e are finite numbers; infinity and NaN are
    # not (CSS Values 4 §10.7.2).
    for v in ["calc(pi * 1px)", "calc(e * 1px)", "calc(1px * PI)", "calc(2px / e)"]:
      accepts("width", v)
    for v in ["calc(infinity * 1px)", "calc(NaN * 1px)", "calc(1px * -infinity)",
        "calc(1px * pie)"]:
      refuses("width", v)
    # A length plus a percentage is a length-percentage, never a plain
    # length (R8): length-only arguments refuse it.
    for (p, v) in [("filter", "blur(calc(1px + 10%))"), ("transform", "translateZ(calc(1px + 10%))"),
        ("transform", "perspective(calc(10%))"), ("filter", "drop-shadow(calc(1px + 10%) 1px)")]:
      refuses(p, v)
    accepts("filter", "blur(calc(1px + 1em))")
    # Dimension sums in one unit fold, so one that overflows is refused (F6).
    for v in ["calc(1e308px + 1e308px)", "calc(1e308px * 10)", "min(1e308px + 1e308px, 1px)",
        "calc((1e308px + 1e308px) / 2)"]:
      refuses("width", v)
    accepts("width", "calc(1e307px + 1e307px)")
    # url(): a backslash must escape a character, and never a newline (R6).
    for v in ["url(a\\)", "url(\\)", "url(a\\\nb)", "url(a\\\rb)"]:
      refuses("filter", v)
    # Quotes and escapes hide parentheses and commas from the splitters (F8).
    for (p, v) in [("filter", "url('a)b.svg')"), ("filter", "url(a\\(b.svg)"),
        ("filter", "url(\"a,b.svg\") blur(1px)"), ("background-image", "url('a)b.png')"),
        ("background-position", "calc(10% - 1px) 0"), ("background-position", "left calc(1px + 2px)"),
        ("object-position", "calc(50% + 1px) top"), ("background-size", "calc(100% - 2px) auto"),
        ("background-size", "min(10px, 5%), auto")]:
      accepts(p, v)
    for (p, v) in [("background-position", "calc(10% - 1s) 0"), ("background-size", "calc(1px + 1) auto"),
        ("object-position", "calc(1px) calc(2px) calc(3px)"), ("filter", "url('a)b.svg)")]:
      refuses(p, v)
    # An escaped comma or space belongs to a family name (F5).
    for v in ["a\\, b", "Font\\ Name, serif", "\\31 23", "\\000031x, serif",
        "\\e9t\\E9 , serif"]:
      accepts("font-family", v)
    for v in ["a\\", "a, b\\", "a\\\nb", "a\\\r\nb", "a\\\fb"]:
      refuses("font-family", v)
    # A hex escape ends at one whitespace, and CRLF counts as one.
    for v in ["\\31\r\n23", "\\31\n23", "\\31\t23"]:
      accepts("font-family", v)

  test "one declaration value, non-negative ranges, every length unit, whole CSS-wide keywords, and the transform, font and transition grammars":
    # isonim-pm issues 2026-11-20 "A value containing var() skips
    # validation", "The editor accepts negative values for properties that
    # have none", "Valid CSS length units such as cm, pt and ex are refused",
    # and 2026-11-21 "A CSS-wide keyword is accepted as one part of a list or
    # shorthand value", "Transform, font and transition properties accept
    # almost any single token". Editor spec "Planned interaction parity": a
    # value valid for its property is written; invalid values are rejected
    # without changing source.
    proc reasons(property, value: string): seq[string] =
      for d in validateCssPropertyValue(PropertyInfo(name: property,
          directStyleAllowed: true),
          PropertyEditRequest(property: property, newValue: value, kind: pekCss),
          parseCssPropertyValue(property, value)):
        result.add d.message
    proc accepts(property, value: string) =
      checkpoint "accepts " & property & ": " & value
      check reasons(property, value).len == 0
    proc refuses(property, value: string) =
      checkpoint "refuses " & property & ": " & value
      check reasons(property, value).len > 0
    # A var() may stand for any value (CSS Variables 1 §3.1), but the text
    # around it is one declaration value: no `;` (CSS Syntax 3 §5.4.4), no
    # `!important` (CSS Cascade 5 §6.4), no brace, and nothing left open.
    for (p, v) in [("width", "calc(1px + var(--a))"), ("padding", "var(--a, 1px 2px)"),
        ("width", "var(--a) var(--b)"), ("width", "var(--a,)"),
        ("width", "var(--a, var(--b, 2px))"), ("width", "var(--1)"),
        ("font-family", "var(--font), serif"), ("font-family", "\"a;b\", var(--f)"),
        ("width", "var(--a, \"x;y\")"), ("width", "var(--a /* c */)"),
        ("transform", "translate(var(--x), 2px)"), ("box-shadow", "var(--s)")]:
      accepts(p, v)
    for (p, v) in [("font-family", "var(--x); color: red"), ("width", "var(--a);"),
        ("width", "var(--x); color: var(--y)"), ("width", "var(--a) !important"),
        ("width", "var(--a)!important"), ("width", "var(--a) }"), ("width", "var(--a) {"),
        ("width", "var(--a)} a{color:red"), ("width", "var(--a"), ("width", "var(--a))"),
        ("width", "var(--a, [1px)"), ("width", "var(--a) /* open"),
        ("width", "var(--a, \"x)"), ("transition", "var(--t) !important"),
        ("box-shadow", "var(--s); x"), ("transform", "var(--t) }"),
        # The reference itself: a custom property name, then only a fallback.
        ("width", "var(a)"), ("width", "var(-a)"), ("width", "var(--)"), ("width", "var()"),
        ("width", "var(--a b)"), ("width", "var(--a 1px)"), ("width", "var(--a/**/b)")]:
      refuses(p, v)
    # Properties with no negative values: CSS Sizing 3 §3.1-3.3, Fonts 4
    # §2.5, Inline 3 §4.2, Box Alignment 3 §8.1, Backgrounds 3 §4.3; also as
    # one part of a multi-part value.
    for (p, v) in [("line-height", "-1"), ("line-height", "-1px"), ("font-size", "-1px"),
        ("font-size", "-10%"), ("height", "-100vh"), ("height", "-100dvh"),
        ("width", "-10%"), ("min-width", "-1px"), ("max-height", "-1vh"), ("gap", "-1px"),
        ("row-gap", "-1px"), ("gap", "-1px 2px"), ("gap", "1px -2px"), ("gap", "normal -1px"),
        ("border-width", "-1px"), ("border-width", "-1px 2px"), ("border-width", "1px -2px"),
        ("border-top-width", "-1px"), ("padding", "-1cm")]:
      refuses(p, v)
    for (p, v) in [("height", "0"), ("height", "-0px"), ("line-height", "0"),
        ("line-height", "1.5"), ("font-size", "0"), ("gap", "0 1px"), ("margin", "-1px"),
        ("letter-spacing", "-1px"), ("top", "-10%"), ("width", "calc(-1px)"),
        ("height", "max(-1px, 2px)")]:
      accepts(p, v)
    # The reason a row shows first names the part it refuses.
    check reasons("gap", "-1px 2px")[0] == "In '-1px': gap cannot be negative."
    check reasons("border-width", "1px -1px")[0] == "In '-1px': border-width cannot be negative."
    check reasons("padding", "4px -2px")[0].startsWith("In '-2px': ")
    # Every CSS length unit (CSS Values 4 §6.1-6.2, Containment 3 §6.1),
    # case-insensitive, as a single value and as a part.
    for (p, v) in [("margin", "1cm"), ("padding", "12pt"), ("padding", "1pc"),
        ("width", "10mm"), ("width", "40Q"), ("width", "1in"), ("width", "2ex"),
        ("width", "2rex"), ("width", "2cap"), ("width", "2ic"), ("line-height", "1lh"),
        ("line-height", "1rlh"), ("width", "50vi"), ("width", "50svmin"),
        ("width", "50dvmax"), ("width", "10cqw"), ("width", "50cqmin"), ("width", "1PX"),
        ("padding", "1cm 2mm 3pt 4in"), ("margin", "1ex auto"), ("font-size", "12pt")]:
      accepts(p, v)
    for (p, v) in [("width", "1cmm"), ("width", "1pts"), ("width", "1qq"), ("width", "1c"),
        ("width", "1cq"), ("width", "1.cm"), ("width", "1.px"), ("height", "1.%"),
        ("width", "cm"), ("width", "1 cm"),
        ("width", "1deg")]:
      refuses(p, v)
    # A CSS-wide keyword is the entire value or nothing (CSS Cascade 5 §7.3;
    # no <custom-ident> spells one, CSS Values 4 §4.2).
    for (p, v) in [("font-family", "Arial, inherit"), ("font-family", "inherit, Arial"),
        ("box-shadow", "1px 1px red, inherit"), ("box-shadow", "1px 1px inherit"),
        ("transition", "opacity 1s, inherit"), ("transition", "revert opacity 1s"),
        ("font", "inherit 12px Arial"), ("font", "12px inherit"),
        ("font", "12px serif, inherit")]:
      refuses(p, v)
    # Beside a var() the value is valid at parse time (CSS Variables 1 §3.1).
    for (p, v) in [("font-family", "var(--f), inherit"), ("padding", "inherit var(--x)"),
        ("box-shadow", "inherit var(--x)"), ("transition", "inherit var(--t)"),
        ("width", "inherit var(--a)")]:
      accepts(p, v)
    for (p, v) in [("font-family", "\"inherit\", Arial"), ("font", "inherit"),
        ("transition", "inherit"), ("box-shadow", "unset")]:
      accepts(p, v)
    # The multi-component grammar keeps refusing a CSS-wide part on its own,
    # for any caller, whatever each part's own rule says.
    let anyPart: CssComponentCheck = proc(property, value: string): bool = true
    for v in ["inherit 2px", "1px initial", "unset unset"]:
      checkpoint "grammar refuses margin: " & v
      check not cssValueAcceptedByGrammar("margin", v, anyPart)
    check cssValueAcceptedByGrammar("margin", "1px 2px", anyPart)
    # rotate, translate and scale (CSS Transforms 2 §4) and transform-origin
    # (Transforms 1 §8).
    for (p, v) in [("rotate", "1deg"), ("rotate", "-45deg"), ("rotate", "0.5turn"),
        ("rotate", "x 45deg"), ("rotate", "45deg y"), ("rotate", "1 1 0 45deg"),
        ("rotate", "none"), ("rotate", "calc(10deg + 5deg)"), ("rotate", "0deg"),
        ("rotate", "x 0deg"), ("transform", "rotate(0)"), ("translate", "10px"),
        ("translate", "50% 10px"), ("translate", "10px 20px 30px"),
        ("translate", "calc(1px)"), ("translate", "-10px -2em"), ("scale", "1.5"),
        ("scale", "150%"), ("scale", "1 2 3"), ("scale", "-1"), ("scale", "calc(2)"),
        ("transform-origin", "top left"), ("transform-origin", "50% 50%"),
        ("transform-origin", "right bottom 10px"), ("transform-origin", "calc(50% + 1px) top")]:
      accepts(p, v)
    for (p, v) in [("rotate", "banana"), ("rotate", "45"), ("rotate", "45px"), ("rotate", "x"),
        ("rotate", "x y 45deg"), ("rotate", "1 1 45deg"), ("rotate", "w 45deg"),
        ("rotate", "rotate(45deg)"),
        # The rotate property takes an <angle>, never a bare zero (CSS
        # Transforms 2 §4, CSS Values 4 §7.1).
        ("rotate", "0"), ("rotate", "x 0"), ("rotate", "0 z"), ("rotate", "1 0 0 0"),
        ("rotate", "-0"), ("rotate", "+0"), ("translate", "banana"), ("translate", "10px 20px 30%"),
        ("translate", "1px 2px 3px 4px"), ("translate", "10"), ("translate", "left"),
        ("scale", "banana"), ("scale", "1 2 3 4"), ("scale", "1px"), ("scale", "scale(2)"),
        ("transform-origin", "banana"), ("transform-origin", "left right"),
        ("transform-origin", "10px left"), ("transform-origin", "10px 20px 30%"),
        ("transform-origin", "1")]:
      refuses(p, v)
    # The font shorthand (CSS Fonts 4 §2.8): a size and a family are needed.
    for v in ["12px Arial", "12px/1.5 Arial, sans-serif", "bold 12px Arial",
        "italic small-caps bold condensed 12px/2 serif", "700 12px serif",
        "normal normal 12px serif", "oblique 10deg 12px serif",
        "large \"Helvetica Neue\", serif", "12px/normal serif", "caption", "0 serif"]:
      accepts("font", v)
    for v in ["12px", "bold", "bold Arial", "Arial 12px", "12px/ Arial", "12px/-1 Arial",
        "-12px Arial", "bold bold 12px serif", "italic oblique 12px serif",
        "normal normal normal normal normal 12px serif", "12px serif,", "1001 12px serif",
        "oblique 100deg 12px serif", "calc(12px)"]:
      refuses("font", v)
    # The transition shorthand (CSS Transitions 1 §2.5, Transitions 2 §3.1).
    for v in ["opacity", "opacity 1s", "opacity 1s ease-in 0.5s", "1s opacity",
        "all 200ms linear, color 1s", "none", "opacity 1s -0.5s",
        "opacity 1s steps(2, end)", "--my-prop 1s", "opacity 1s allow-discrete",
        "calc(1s)"]:
      accepts("transition", v)
    for v in ["1px", "-1s", "opacity 1s 2s 3s", "opacity -1s", "opacity color 1s",
        "opacity 1s ease linear", "none, opacity 1s", "opacity 1s,", "opacity 1",
        "default 1s", "opacity 1s steps(0)"]:
      refuses("transition", v)
    # flex-grow and flex-shrink are non-negative numbers (CSS Flexbox 1
    # §7.3.1-7.3.2); order is an integer (CSS Display 3 §5.1).
    for (p, v) in [("flex-grow", "0"), ("flex-grow", "1.5"), ("flex-shrink", "2"),
        ("order", "-3"), ("order", "0"), ("order", "+2")]:
      accepts(p, v)
    for (p, v) in [("flex-grow", "-1"), ("flex-grow", "-0.5"), ("flex-shrink", "-1"),
        ("order", "1.5"), ("order", "2.0"), ("order", "1e2"), ("order", "1px")]:
      refuses(p, v)
    # perspective: `none | <length [0,∞]>` (CSS Transforms 2 §6.1);
    # text-indent: `<length-percentage> && hanging? && each-line?`, negative
    # allowed (CSS Text 3 §8.1).
    for (p, v) in [("perspective", "none"), ("perspective", "0"), ("perspective", "100px"),
        ("perspective", "calc(-1px)"), ("perspective", "2cm"), ("text-indent", "-1em"),
        ("text-indent", "2em hanging"), ("text-indent", "10% each-line hanging"),
        ("text-indent", "0")]:
      accepts(p, v)
    for (p, v) in [("perspective", "-1px"), ("perspective", "10%"), ("perspective", "auto"),
        ("perspective", "1px 2px"), ("text-indent", "hanging"), ("text-indent", "1em 2em"),
        ("text-indent", "1em hanging hanging"), ("text-indent", "auto")]:
      refuses(p, v)
    # <paint> for fill and stroke (CSS Fill and Stroke 3 §2.1, §3.1), `auto |
    # <color>` for caret-color and accent-color (CSS UI 4 §6.2.1, §6.3), and
    # the flex shorthand (CSS Flexbox 1 §7.1).
    for (p, v) in [("fill", "none"), ("stroke", "none"), ("fill", "context-fill"),
        ("fill", "url(#g) red"), ("fill", "#fff"), ("caret-color", "auto"),
        ("accent-color", "auto"), ("caret-color", "red"), ("flex", "1 1 calc(10% + 1px)"),
        ("flex", "2 2 10%"), ("flex", "1"), ("flex", "auto"), ("flex", "none"),
        ("flex", "0 0 auto"), ("flex", "10px 1"), ("flex", "1 30px"), ("flex", "content"),
        ("flex", "0 1 0"), ("flex", "1 1 0"), ("flex", "0px 1 1"), ("flex", "0 0"),
        ("flex", "0")]:
      accepts(p, v)
    for (p, v) in [("fill", "auto"), ("fill", "none red"), ("caret-color", "none"),
        ("accent-color", "invert"), ("flex", "-1"), ("flex", "1 1 -1px"), ("flex", "1 2 3"),
        ("flex", "auto auto"), ("flex", "1 -1"), ("flex", "1px 2px"),
        # A unitless zero not preceded by two factors is a factor (CSS
        # Flexbox 1 §7.1), so the trailing 1 would be a basis.
        ("flex", "0 1 1"), ("flex", "0 0 1")]:
      refuses(p, v)

  test "a var() reference is read as CSS reads it, and written as typed or as its token":
    # isonim-pm issue 2026-11-21 "var() references written in upper case,
    # with spaces or after a comment are refused". CSS Syntax 3 matches a
    # function name ASCII case-insensitively and allows whitespace and
    # comments inside its parentheses; a declaration holding a well-formed
    # var() is valid at parse time whatever stands beside it (CSS Variables
    # 1 §3.1). Editor spec "Planned interaction parity": a valid value is
    # written, an invalid one is rejected without changing source.
    proc reasons(property, value: string): seq[string] =
      for d in validateCssPropertyValue(PropertyInfo(name: property,
          directStyleAllowed: true),
          PropertyEditRequest(property: property, newValue: value, kind: pekCss),
          parseCssPropertyValue(property, value)):
        result.add d.message
    proc accepts(property, value: string) =
      checkpoint "accepts " & property & ": " & value
      check reasons(property, value).len == 0
    proc refuses(property, value: string) =
      checkpoint "refuses " & property & ": " & value
      check reasons(property, value).len > 0
    # The value a source plan carries, which the writer puts in the file.
    proc written(property, value: string): string =
      parseCssPropertyValue(property, value).canonical
    # The four spellings the issue names, each written exactly as typed.
    for v in ["VAR(--a)", "var( --a )", "var(/**/--a)", "var(--a) 1px"]:
      accepts("width", v)
      check written("width", v) == v
    # The function name in any case.
    for v in ["Var(--a)", "vAr(--a)", "VAR(--a, 1px)", "calc(VAR(--a) + 1px)"]:
      accepts("width", v)
      check written("width", v) == v
    for (p, v) in [("color", "VAR(--ink)"), ("padding", "VAR(--space)"),
        ("transform", "translate(VAR(--x), 2px)"), ("font-family", "VAR(--f), serif"),
        ("font-family", "VAR(--F),serif"), ("font-family", "Inter, Var(--Fallback)"),
        ("box-shadow", "0 1px 2px VAR(--c)"), ("box-shadow", "var( --Shadow ), 0 1px red"),
        ("transition", "opacity VAR(--d)"), ("transition", "VAR(--T)")]:
      accepts(p, v)
      check written(p, v) == v
    # A colour holding var() keeps the custom property's case: names are
    # case-sensitive (CSS Variables 1 §2; editor spec "Token names are
    # case-sensitive"), so the whole value is written as typed. A colour
    # without one is still written in lower case, which CSS reads the same.
    for (p, v) in [("color", "rgb(var(--Ink) 0 0)"), ("color", "RGB(var(--Ink) 0 0)"),
        ("outline-color", "rgb(var(--A) var(--B) var(--C))"),
        ("color", "hsl(var(--H) 50% 50%)"), ("color", "HSLA(var(--H) 1% 1% / 1)"),
        ("color", "rgba(var(--R), 0, 0, 0.5)"), ("border-color", "rgb(VAR(--Ink) 0 0)"),
        ("background-color", "#ABCDEF var(--X)")]:
      accepts(p, v)
      check written(p, v) == v
    for (p, v, w) in [("color", "#ABC", "#abc"), ("color", "RGB(1, 2, 3)", "rgb(1, 2, 3)")]:
      accepts(p, v)
      check written(p, v) == w
    # A var() inside a comment is no reference (CSS Syntax 3 §4.3.2): these
    # values keep the written form the editor already gave them.
    for p in ["color", "background-color", "border-color", "outline-color"]:
      accepts(p, "RGB(1, 2, 3) /* var(--A) */")
      check written(p, "RGB(1, 2, 3) /* var(--A) */") == "rgb(1, 2, 3) /* var(--a) */"
    for (p, v, w) in [("color", "#FFF /* var(--x) */", "#fff /* var(--x) */"),
        ("color", "#ABC /* VAR(--x) */", "#abc /* var(--x) */"),
        ("font-family", "Inter,serif /* VAR(--x) */", "Inter, serif /* VAR(--x) */"),
        ("font-family", "/* VAR(--x) */ Inter,serif", "/* VAR(--x) */ Inter, serif")]:
      accepts(p, v)
      check written(p, v) == w
    # Whitespace and comments in each place inside the parentheses.
    for v in ["var( --a)", "var(  --a  )", "var(\t--a)", "var( --a , 1px)",
        "var( --a ,)", "var( --a, var( --b ) )", "var(/* c */--a)",
        "var(/**/ --a /**/)", "var(/**/--a, var(/**/--b))",
        "/**/var(--a)", "var(--a)/**/"]:
      accepts("width", v)
      check written("width", v) == v
    # A var() beside a literal, on a property taking one value and on one
    # taking several.
    for p in ["width", "height", "opacity", "z-index", "letter-spacing",
        "outline-offset", "border-radius", "color", "font-size", "line-height"]:
      accepts(p, "var(--a) 1px")
      check written(p, "var(--a) 1px") == "var(--a) 1px"
    for (p, v) in [("width", "1px var(--a)"), ("width", "var(--a) auto"),
        ("width", "VAR(--a) 1px"), ("width", "var( --a ) 1px"),
        ("width", "var(/**/--a) 1px"), ("width", "var(--a)1px"),
        ("padding", "1px VAR(--a)"), ("margin", "var( --a ) auto"),
        ("gap", "var(/**/--a) 1px"), ("grid-template-columns", "var(--a) 1fr"),
        ("background-position", "var(--x) 0"), ("aspect-ratio", "var(--x) /* c */")]:
      accepts(p, v)
      check written(p, v) == v
    # A name with a hex escape (CSS Syntax 3 §4.3.7): the whitespace ending
    # the escape belongs to the name.
    accepts("width", "var(--\\31 a)")
    # A `var()` reference is written as typed, never in the `token(name)`
    # form no CSS reader understands (isonim-pm issue 2026-11-22-var-values-
    # are-written-in-a-token-form-...): the fallback and every other
    # reference stay. Its token identity is still the custom property.
    for (p, v) in [("width", "var(--a)"), ("width", "var(--a )"),
        ("aspect-ratio", "var(--x)"), ("overflow", "var(--x)"),
        ("width", "var(--\\31 a)"), ("width", "var(--a) var(--b)"),
        ("width", "var(--a, 1px)"), ("width", "var(--a, var(--b, 2px))"),
        ("font-family", "var(--a, \"x,y\")"), ("background-image", "var(--a), url(x.png)"),
        ("margin", "var(--a) auto var(--b)")]:
      accepts(p, v)
      check written(p, v) == v
    check parseCssPropertyValue("width", "var(--a)").tokenName == "a"
    check parseCssPropertyValue("width", "var(--a)").kind == cvkTokenReference
    # Valid at parse time (CSS Variables 1 §3.1) and written as typed, so
    # accepted on every property, whatever its own grammar.
    for (p, v) in [("filter", "var(--x), var(--y)"), ("overflow", "var(--x), var(--y)"),
        ("aspect-ratio", "var(--x), var(--y)"), ("filter", "var(--x, blur(2px))"),
        ("overflow", "var(--x, hidden)"), ("aspect-ratio", "var(--x, 16 / 9)"),
        ("aspect-ratio", "var(--x) / var(--y)")]:
      accepts(p, v)
      check written(p, v) == v
    # The design-schema spellings keep the `token(key)` form their token
    # workflows read; one holding a var() would be written changed, so it is
    # judged by the property's grammar as before.
    check written("width", "token(a)") == "token(a)"
    check written("width", "$a") == "token(a)"
    for (p, v) in [("overflow", "token(a) var(--b)"), ("aspect-ratio", "token(a, var(--b))")]:
      refuses(p, v)
    # `$key` is one key (as `tokenReferenceIn` reads it): `$a var(--b)` is
    # not a token reference, holds a var(), and is written as typed rather
    # than as `token(a var(--b))`.
    for p in ["width", "filter"]:
      accepts(p, "$a var(--b)")
      check written(p, "$a var(--b)") == "$a var(--b)"
    # Nor is `$` with whitespace of any kind in it: no longer written as
    # `token(a)` / `token(a b)`, it is judged by the property's grammar.
    for v in ["$ a", "$a b", "$a\tb"]:
      refuses("width", v)
      refuses("color", v)
    # A custom property is never refused for its name, `missing` included.
    for v in ["var(--missing)", "var(--missing, 1px)"]:
      accepts("width", v)
      check written("width", v) == v
    # The token identity of a var() is the custom property's name alone; its
    # fallback stays in the written text.
    for (v, name) in [("var(--wl-space-card, 4px)", "wl-space-card"),
        ("var(--a,1px)", "a"), ("var(--a , var(--b, 2px))", "a"),
        ("var(--a)", "a"), ("var(--a )", "a"), ("var(--\\31 a)", "\\31 a"),
        ("var(--a) var(--b)", "a")]:
      checkpoint v
      check parseCssPropertyValue("padding", v).tokenName == name
      check written("padding", v) == v
    # Malformed references and near-misses stay refused.
    for v in ["var(-a)", "var(--)", "var(--a b)", "var(--a;)", "vars(--a)", "var(a)",
        "var()", "var( )", "var(--a 1px)", "var(--a/**/b)", "VAR(-a)", "VAR(--)",
        "VAR(--a b)", "var( -- a)", "var(--a", "var(--a))", "var(--a) !important",
        "VAR(--a) !important", "var(--a)}", "var(/* open --a)", "var(,--a)",
        "var(1px)", "var( /**/ )", "var(--a !important)", "var(\"--a\")", "var (--a)"]:
      refuses("width", v)
    for (p, v) in [("padding", "vars(--a)"), ("padding", "var(--a;) 1px"),
        ("color", "var(--)"), ("font-family", "var(--a b), serif"),
        ("margin", "var(-a) 1px")]:
      refuses(p, v)

  test "a quoted family name and a multi-part value are written as typed":
    # isonim-pm issues 2026-11-22 "font-family write-back adds a space after
    # commas inside quoted names" and 2026-11-23 "a flex value is written as
    # the result of arithmetic on its parts". Editor spec "Planned
    # interaction parity": a value is written, or refused with a reason; it
    # is never changed. Typed arithmetic applies to a single numeric value.
    proc reasons(property, value: string): seq[string] =
      for d in validateCssPropertyValue(PropertyInfo(name: property,
          directStyleAllowed: true),
          PropertyEditRequest(property: property, newValue: value, kind: pekCss),
          parseCssPropertyValue(property, value)):
        result.add d.message
    # What an inspector commit writes: the typed text normalised (typed
    # arithmetic), then read as the property's value.
    proc committed(property, value: string): string =
      parseCssPropertyValue(property,
        normalizePrimitiveInputValue(property, value)).canonical
    proc refusedAtCommit(property, value: string): bool =
      let text = normalizePrimitiveInputValue(property, value)
      reasons(property, text).len > 0
    # A quoted family name is a string (CSS Fonts 4 §2.1); its contents,
    # commas and spaces included, are the name. An escaped comma belongs to
    # the name too (CSS Syntax 3 §4.3.7), and a comment is no separator.
    for (v, w) in [("\"A,B\" var(--a)", "\"A,B\" var(--a)"),
        ("\"A,B\"", "\"A,B\""), ("'A,B',serif", "'A,B', serif"),
        ("\"A ,B\" , serif", "\"A ,B\", serif"),
        ("\"a\\\",b\", serif", "\"a\\\",b\", serif"),
        ("'a\\'b,c', serif", "'a\\'b,c', serif"),
        ("\"x,y,z\",Arial,sans-serif", "\"x,y,z\", Arial, sans-serif"),
        ("serif,\"A,B\"", "serif, \"A,B\""), ("\"A,,B\"", "\"A,,B\""),
        ("A\\,B,serif", "A\\,B, serif"), ("\"A;B,C\"", "\"A;B,C\""),
        ("Inter,serif /* a,b */", "Inter, serif /* a,b */"),
        ("var(--f,\"a,b\"), serif", "var(--f, \"a,b\"), serif"),
        # The separating commas of an unquoted list keep their normalisation.
        ("Inter,serif", "Inter, serif"), ("Inter ,  serif", "Inter, serif"),
        ("a,b,c", "a, b, c")]:
      checkpoint "font-family: " & v
      check reasons("font-family", v).len == 0
      check committed("font-family", v) == w
    # A value of several components is never one arithmetic expression: a
    # sign stuck to a number starts a component (CSS Syntax 3 §4.3.12).
    for (p, v) in [("flex", "+1 +1 +1px"), ("flex", "1 +1"), ("flex", "+1 +1"),
        ("flex", "+1 +1 +1PX"), ("margin", "0 -16px"), ("inset", "0 -1px"),
        ("translate", "0 -5px"), ("background-position", "0 -10px"),
        ("scale", "1 -1"), ("transform-origin", "0 -1px"), ("gap", "0 -0"),
        ("box-shadow", "0 -1px"), ("text-shadow", "0 -1px"),
        # A `/` that separates components is no division.
        ("grid-row", "1 / -1"), ("grid-row", "1/3"), ("grid-column", "2/4"),
        ("grid-area", "1 / 2 / 3 / 4"), ("border-radius", "0 / 5px"),
        ("aspect-ratio", "16 / 9")]:
      checkpoint p & ": " & v
      check normalizePrimitiveInputValue(p, v) == v
      check not refusedAtCommit(p, v)
      check committed(p, v) == v
    # Invalid multi-part values are refused, never reduced to a valid one.
    for (p, v) in [("flex", "1 -1"), ("flex", "0 -1"), ("flex", "+.5 -.5"),
        ("z-index", "1 -1"), ("opacity", "1 -1"), ("line-height", "1 +1"),
        ("order", "1 -1"), ("width", "100 -50px"), ("width", "100 +50"),
        ("border-radius", "1/1px")]:
      checkpoint p & ": " & v
      check normalizePrimitiveInputValue(p, v) == v
      check refusedAtCommit(p, v)
    # The text path names that reading when it refuses typed arithmetic
    # that CSS reads as two values and whose result the property would take.
    for (p, v) in [("width", "100 -50px"), ("z-index", "1 -1"), ("opacity", "1 -1")]:
      checkpoint p & ": " & v
      let why = reasons(p, normalizePrimitiveInputValue(p, v))
      check why.len > 0
      if why.len > 0:
        check why[0].startsWith("`" & v & "` was read as 2 values")
    # A refusal with no arithmetic reading keeps its own reason only.
    for (p, v) in [("width", "100px 50px"), ("flex", "1 1 -1px"),
        ("width", "100 +50"), ("accent-color", "0 -1px")]:
      let why = reasons(p, v)
      check why.len > 0
      if why.len > 0:
        check "was read as" notin why[0]
    # A custom property's value is arbitrary tokens (CSS Variables 1 §2): it
    # is never evaluated, whatever it holds.
    for v in ["10/2", "2*3", "1+1", "100 - 50px", "-0px", "+2", "1 -1",
        "+1 +1 +1px", "1 / -1", "6*4px"]:
      for p in ["--x", "--space-card"]:
        checkpoint p & ": " & v
        check normalizePrimitiveInputValue(p, v) == v
    # A single value's typed arithmetic still applies, spaced or not.
    for (p, v, w) in [("width", "100+50px", "150px"), ("width", "100 + 50px", "150px"),
        ("width", "100 - 50px", "50px"), ("width", "6*4px", "24px"),
        ("width", "100/4px", "25px"), ("width", "100 /4px", "25px"),
        ("height", "2.5-0.7px", "1.8px"), ("font-size", "6*4px", "24px"),
        ("padding", "10+6px", "16px"), ("margin", "-2*4px", "-8px"),
        ("line-height", "1+0.5", "1.5"), ("opacity", "1-0.25", "0.75"),
        ("z-index", "2*5", "10"), ("flex", "1+1", "2"), ("gap", "4*2px", "8px"),
        ("letter-spacing", "-1+0.5px", "-0.5px"), ("text-indent", "- 1em", "-1em")]:
      checkpoint p & ": " & v
      check not refusedAtCommit(p, v)
      check committed(p, v) == w
    # A numeric field evaluates what is typed into it and adds its unit.
    createRoot proc(dispose: proc()) =
      let value = createSignal(10.0)
      let unit = createSignal(pxUnit)
      var seen: seq[string]
      var cfg = propertyRowNumeric(
        name = "Width", value = value, unit = unit, units = @[pxUnit])
      cfg.onCommitValue = proc(v: string) = seen.add v
      let (r, root) = mkRoot()
      discard r.mountPropertyRow(root, cfg)
      let input = findByAttr(root, "data-property-row-input", "true")
      r.setInputValue(input, "100+50")
      fireEvent(input, "change")
      check seen == @["150px"]
      check committed("width", seen[^1]) == "150px"
      dispose()

  test "typed arithmetic gives the numeric row's result on the text path":
    # isonim-pm issues 2026-11-24 "the text path's arithmetic evaluator
    # differs from the numeric field's" and "a signed number typed without
    # arithmetic is rewritten on commit". Editor spec "Numeric Inputs" (the
    # arithmetic precision rules; "A number typed without arithmetic is kept
    # exactly as authored") and "Planned interaction parity" ("Typed
    # arithmetic, units and arrow adjustments obey the same property
    # constraints"): one evaluator, whichever path commits the text.
    let units = @[pxUnit, PropertyUnitOption(label: "rem", code: "rem"),
      PropertyUnitOption(label: "turn", code: "turn")]
    proc rowCommit(typed: string): string =
      ## What a mounted numeric row commits for ``typed`` ("" when nothing).
      var got = ""
      createRoot proc(dispose: proc()) =
        let value = createSignal(10.0)
        let unit = createSignal(pxUnit)
        var seen: seq[string]
        var cfg = propertyRowNumeric(name = "Width", value = value,
          unit = unit, units = units)
        cfg.onCommitValue = proc(v: string) = seen.add v
        let (r, root) = mkRoot()
        discard r.mountPropertyRow(root, cfg)
        let input = findByAttr(root, "data-property-row-input", "true")
        r.setInputValue(input, typed)
        fireEvent(input, "change")
        if seen.len > 0: got = seen[^1]
        dispose()
      got
    # Every typed example of the spec, through both paths. The row adds its
    # active unit (px) to a unitless expression; the text path keeps the
    # text unitless, for the property's validation.
    for (typed, expected) in [("100+50", "150"), ("200/2", "100"),
        ("50*3", "150"), ("0.1+0.2px", "0.3px"), ("2.5-0.7", "1.8"),
        ("1.1*3", "3.3"), ("120+1/8", "120.125"),
        ("1/1024turn", "0.0009765625turn"), ("10/3", "3.3333"),
        ("(1/3)*3", "1"), ("1/3+1/3+1/3", "1"), ("100/3*2", "66.6667"),
        ("1/30000", "0.00003333"), ("-(2+3)", "-5"), ("-2^2", "-4"),
        ("2^-(1)", "0.5"), ("10/3rem", "3.3333rem"),
        ("1.23456+1px", "2.23456px"), ("1/30000px", "0.00003333px"),
        ("2^2", "4"), ("1e2+5", "105"), ("-(-(1/3))*3px", "1px"),
        # Parentheses alone are arithmetic: the group is evaluated.
        ("(2)px", "2px"), ("((2))", "2")]:
      checkpoint typed
      check normalizePrimitiveInputValue("width", typed) == expected
      let row = rowCommit(typed)
      if expected[^1].isDigit: check row == expected & "px"
      else: check row == expected
    # A number typed without arithmetic, sign and spelling included, is
    # written exactly as typed; an invalid one is then refused, not reduced.
    for (p, v) in [("width", "+2"), ("width", "+2px"), ("width", "-0px"),
        ("width", "+0"), ("margin", "-.5px"), ("margin", "+1.5px"),
        ("z-index", "+2"), ("z-index", "-0"), ("order", "+3"),
        ("opacity", "+.5"), ("line-height", "+1.5"), ("width", "1e2px"),
        ("width", "1e-2px"), ("width", "+1e2px"), ("width", "1E2px"),
        ("width", "+1.px"), ("width", "1.23456px"), ("flex-grow", "-0"),
        ("transition-duration", "+0.3s")]:
      checkpoint p & ": " & v
      check normalizePrimitiveInputValue(p, v) == v
    for (p, v) in [("width", "+2px"), ("width", "-0px"), ("margin", "-.5px"),
        ("z-index", "+2"), ("opacity", "+.5"), ("line-height", "+1.5")]:
      checkpoint p & ": " & v
      check validateCssPropertyValue(PropertyInfo(name: p, directStyleAllowed: true),
        PropertyEditRequest(property: p, newValue: v, kind: pekCss),
        parseCssPropertyValue(p, v)).len == 0
    # A sign standing apart from its number, or before a group, is arithmetic.
    for (p, v, w) in [("margin", "- 5px", "-5px"), ("z-index", "+(2)", "2"),
        ("margin", "5 - -3px", "8px"), ("letter-spacing", "(-2)^2px", "4px"),
        ("width", "0*-1px", "0px")]:
      checkpoint p & ": " & v
      check normalizePrimitiveInputValue(p, v) == w
    # Not a single expression of one unit: written as typed, for the
    # property's validation (which refuses each of these for width).
    for v in ["10px+5em", "10px+5px", "1rem+1px", "10px*2", "100/0",
        "1/0px", "0/0px", "1**2px", "--5px", "-+5px", "(1+2", "1+2)", "()px",
        "2(3)px", "(0-8)^0.5px", "1e400px", "1e308*10px"]:
      checkpoint "width: " & v
      check normalizePrimitiveInputValue("width", v) == v
      check rowCommit(v) == ""
      check validateCssPropertyValue(PropertyInfo(name: "width",
        directStyleAllowed: true),
        PropertyEditRequest(property: "width", newValue: v, kind: pekCss),
        parseCssPropertyValue("width", v)).len > 0

suite "a numeric row writes what was typed":
  # The DOM is the mock renderer's (the suite's own harness, mkRoot); the
  # row's commit logic, the evaluator and the property validator are real.
  let lengthUnits = @[pxUnit, emUnit, PropertyUnitOption(label: "rem", code: "rem"),
    PropertyUnitOption(label: "%", code: "%")]
  proc chipText(n: MockNode): string =
    if n == nil: return ""
    if n.kind == mnkText: return n.text
    for c in n.children: result.add chipText(c)
  proc accepted(property, value: string): bool =
    let text = normalizePrimitiveInputValue(property, value)
    validateCssPropertyValue(PropertyInfo(name: property, directStyleAllowed: true),
      PropertyEditRequest(property: property, newValue: text, kind: pekCss),
      parseCssPropertyValue(property, text)).len == 0
  type Typed = tuple[commits: seq[string], field, chip, fieldAfterSource,
    chipAfterSource: string]
  proc typeInto(property: string; units: seq[PropertyUnitOption];
      typed: seq[string]; wired = true; minValue = none(float)): Typed =
    ## Type each of ``typed`` into a mounted row (wired to ``property`` when
    ## ``wired``) and commit it with `change`, then `blur`. An accepted commit
    ## becomes the row's authored source, as the pipeline makes it.
    var res: Typed
    createRoot proc(dispose: proc()) =
      let value = createSignal(10.0)
      let unit = createSignal(units[0])
      let source = createSignal("10" & units[0].code)
      var cfg = propertyRowNumeric(name = property, value = value, unit = unit,
        units = units, minValue = minValue,
        wiring = (if wired: InspectorRowWiring(cssProperty: property,
          authoredValue: proc(): string = source.val)
          else: InspectorRowWiring()))
      cfg.onCommitValue = proc(v: string) = res.commits.add v
      let (r, root) = mkRoot()
      discard r.mountPropertyRow(root, cfg)
      let input = findByAttr(root, "data-property-row-input", "true")
      let chip = findByAttr(root, "data-property-row-unit", "true")
      for t in typed:
        let before = res.commits.len
        r.setInputValue(input, t)
        fireEvent(input, "change")
        fireEvent(input, "blur")
        res.field = r.inputValue(input)
        res.chip = chipText(chip)
        if wired and res.commits.len > before and accepted(property, res.commits[^1]):
          source.val = normalizePrimitiveInputValue(property, res.commits[^1])
          fireEvent(input, "blur")
        res.fieldAfterSource = r.inputValue(input)
        res.chipAfterSource = chipText(chip)
      dispose()
    res

  test "a number typed without arithmetic is written exactly as typed":
    # isonim-pm issue 2026-11-24 "the numeric row rewrites a number typed
    # without arithmetic". Editor spec "Numeric Inputs": "A number typed
    # without arithmetic is kept exactly as authored."
    for wired in [false, true]:
      for (typed, written, field) in [("+2", "+2px", "+2"), ("+2px", "+2px", "+2"),
          ("1.50px", "1.50px", "1.50"), ("1e-2px", "1e-2px", "1e-2"),
          ("-0px", "-0px", "-0"), ("1E2px", "1E2px", "1E2"),
          ("-007px", "-007px", "-007"), ("00.10em", "00.10em", "00.10"),
          (".5px", ".5px", ".5"), ("+1e+2px", "+1e+2px", "+1e+2"),
          ("10.0", "10.0px", "10.0"),
          # Arithmetic is written by its value, as before.
          ("1+1", "2px", "2"), ("(2)", "2px", "2"), ("- 2", "-2px", "-2"),
          ("1.50*1px", "1.5px", "1.5"),
          # `1.` is not a CSS number: the row reads it, and writes its value.
          ("1.", "1px", "1")]:
        checkpoint $wired & " " & typed
        let got = typeInto("margin", lengthUnits, @[typed], wired)
        # One commit: the blur after it writes nothing more.
        check got.commits == @[written]
        check got.field == field
        check got.fieldAfterSource == field
    # The bounds change a typed number: it is then written by its value.
    let clamped = typeInto("width", lengthUnits, @["-5px"], minValue = some(0.0))
    check clamped.commits == @["0px"]
    # Retyping the authored text writes nothing; retyping the same value in
    # another spelling writes that spelling.
    check typeInto("margin", lengthUnits, @["+2px", "+2", "+2px"]).commits == @["+2px"]
    check typeInto("margin", lengthUnits, @["+2px", "2"]).commits == @["+2px", "2px"]
    check typeInto("margin", lengthUnits, @["10"]).commits.len == 0
    check typeInto("margin", lengthUnits, @["10.0px"]).commits == @["10.0px"]

  test "the authored spelling survives a unit change and a refused edit":
    createRoot proc(dispose: proc()) =
      let value = createSignal(10.0)
      let unit = createSignal(pxUnit)
      let rejected = createSignal(0)
      var commits: seq[string]
      var refuse = false
      var cfg = propertyRowNumeric(name = "Margin", value = value, unit = unit,
        units = @[pxUnit, emUnit])
      cfg.commitRejected = rejected
      cfg.onCommitValue = proc(v: string) =
        commits.add v
        if refuse: rejected.val = rejected.val + 1
      let (r, root) = mkRoot()
      discard r.mountPropertyRow(root, cfg)
      let input = findByAttr(root, "data-property-row-input", "true")
      let chip = findByAttr(root, "data-property-row-unit", "true")
      r.setInputValue(input, "+1.50")
      fireEvent(input, "change")
      check commits == @["+1.50px"]
      # The chip changes the unit, not the number the edit did not change.
      fireEvent(chip, "click")
      check commits == @["+1.50px", "+1.50em"]
      check r.inputValue(input) == "+1.50"
      # A refused edit restores the value and its spelling.
      refuse = true
      r.setInputValue(input, "3")
      fireEvent(input, "change")
      check r.inputValue(input) == "+1.50"
      check value.val == 1.5
      dispose()

  test "a spaced power or a parenthesised group is one value on the text path, as in the row":
    # isonim-pm issue 2026-11-24 "the text path splits spaced powers and
    # parentheses into several values". Editor spec "Planned interaction
    # parity": a typed expression gives the same result whichever path
    # commits it.
    for (typed, expected) in [("2 ^ 2px", "4px"), ("2^ 2px", "4px"),
        ("2 ^2px", "4px"), ("( 1+2 )px", "3px"), ("(1+2 )px", "3px"),
        ("( 1+2)px", "3px"), ("( 1 + 2 ) * 2px", "6px"), ("2 * ( 3 )px", "6px"),
        ("-( 2 + 3 )px", "-5px"), ("( ( 1 ) )px", "1px"),
        ("2 ^ ( 1 + 1 )px", "4px"), ("10 / ( 2 + 3 )px", "2px"),
        ("2 ^ -1px", "0.5px"), ("( 2 ) ^ 2px", "4px"), ("( 1 - 0.5 )", "0.5")]:
      checkpoint typed
      check normalizePrimitiveInputValue("margin", typed) == expected
      let row = typeInto("margin", lengthUnits, @[typed], wired = false).commits
      check row.len == 1
      if row.len == 1:
        check row[0] == (if expected[^1].isDigit: expected & "px" else: expected)
    # Multi-part neighbours, slash separators, functions and custom
    # properties are kept exactly as they were.
    for (p, v) in [("flex", "1 -1"), ("margin", "0 -16px"), ("grid-row", "1 / -1"),
        ("margin", "0 2 ^ 2px"), ("margin", "( 1+2 )px 0"), ("margin", "0 ( 1+2 )px"),
        ("margin", "2 ^ 2px 0"), ("padding", "( 4 )px ( 8 )px"), ("flex", "2 ^ 2 1"),
        ("width", "( 1 ) ( 2 )px"), ("width", "1 ( 2 )px"), ("width", "(1+2) px"),
        ("grid-row", "( 1 ) / -1"), ("aspect-ratio", "16 / ( 9 )"),
        ("--x", "2 ^ 2px"), ("--x", "( 1+2 )px"), ("--space", "1 -1"),
        ("transform", "translate( 1px , 2px )"), ("width", "calc( 1px + 2px )"),
        ("grid-template-columns", "repeat( 2 , 1fr )"), ("color", "rgb( 0 0 0 )"),
        ("box-shadow", "0 ( 1 )px 2px"), ("translate", "( 1 )px -2px")]:
      checkpoint p & ": " & v
      check normalizePrimitiveInputValue(p, v) == v

  test "a numeric row admits every unit its property accepts":
    # isonim-pm issue 2026-11-24 "the numeric row refuses valid CSS units the
    # property accepts". Editor spec "Planned interaction parity": the same
    # validation on every path. The chip shows a typed unit it does not
    # offer, and keeps cycling through its own units only.
    for (p, typed, written, chip) in [("width", "12dvh", "12dvh", "dvh"),
        ("width", "1cm", "1cm", "cm"), ("width", "12pt", "12pt", "pt"),
        ("width", "2Q", "2Q", "q"), ("width", "5cqw", "5cqw", "cqw"),
        ("width", "1lh", "1lh", "lh"), ("width", "3svmin", "3svmin", "svmin"),
        ("width", "12PX", "12PX", "px"), ("width", "12Em", "12Em", "em"),
        ("width", "12DVH", "12DVH", "dvh"), ("width", "(1+2)PX", "3PX", "px"),
        ("width", "10/4dvh", "2.5dvh", "dvh"), ("width", "+2PX", "+2PX", "px"),
        ("margin", "-5dvh", "-5dvh", "dvh"), ("font-size", "12pt", "12pt", "pt")]:
      checkpoint p & ": " & typed
      let got = typeInto(p, lengthUnits, @[typed])
      check got.commits == @[written]
      check accepted(p, written)
      check got.chip == chip
      check got.chipAfterSource == chip
      check got.fieldAfterSource == got.field
    let angle = @[PropertyUnitOption(label: "deg", code: "deg"),
      PropertyUnitOption(label: "turn", code: "turn")]
    for (typed, written, chip) in [("45rad", "45rad", "rad"), ("45GRAD", "45GRAD", "grad"),
        ("1Turn", "1Turn", "turn"), ("45DEG", "45DEG", "deg")]:
      checkpoint "rotate: " & typed
      let got = typeInto("rotate", angle, @[typed])
      check got.commits == @[written]
      check got.chip == chip
    let time = @[PropertyUnitOption(label: "s", code: "s")]
    for (typed, written, chip) in [("250ms", "250ms", "ms"), ("2MS", "2MS", "ms"),
        ("2S", "2S", "s")]:
      checkpoint "transition-duration: " & typed
      let got = typeInto("transition-duration", time, @[typed])
      check got.commits == @[written]
      check got.chip == chip
    # A unit the property does not accept is refused, and the field and chip
    # are restored.
    for (p, units, typed) in [("width", lengthUnits, "10deg"), ("width", lengthUnits, "10s"),
        ("width", lengthUnits, "10foo"), ("width", lengthUnits, "10e"),
        ("width", lengthUnits, "10fr"), ("rotate", angle, "10px"),
        ("rotate", angle, "10dvh"), ("transition-duration", time, "10deg"),
        ("transition-duration", time, "10sec")]:
      checkpoint p & ": " & typed
      let got = typeInto(p, units, @[typed])
      check got.commits.len == 0
      check got.field == "10"
      check got.chip == units[0].label
    # With no property to validate against, a row takes only its own units,
    # in any case.
    check typeInto("width", lengthUnits, @["12dvh"], wired = false).commits.len == 0
    check typeInto("width", lengthUnits, @["12PX"], wired = false).commits == @["12PX"]
    # The chip cycles its own units, from the first, after a typed one.
    createRoot proc(dispose: proc()) =
      let value = createSignal(10.0)
      let unit = createSignal(pxUnit)
      var commits: seq[string]
      var cfg = propertyRowNumeric(name = "Width", value = value, unit = unit,
        units = @[pxUnit, emUnit], wiring = InspectorRowWiring(cssProperty: "width"))
      cfg.onCommitValue = proc(v: string) = commits.add v
      let (r, root) = mkRoot()
      discard r.mountPropertyRow(root, cfg)
      let input = findByAttr(root, "data-property-row-input", "true")
      let chip = findByAttr(root, "data-property-row-unit", "true")
      r.setInputValue(input, "12dvh")
      fireEvent(input, "change")
      fireEvent(chip, "click")
      check commits == @["12dvh", "12px"]
      check chipText(chip) == "px"
      dispose()

  test "an <integer> property refuses a fraction or an exponent, typed or in the row":
    # CSS Values 4 §5.2: an `<integer>` is an optional sign and digits only;
    # `1.0`, `1e2` and `1e-2` are `<number>`s. z-index (CSS 2.1 §9.9.1),
    # order (CSS Display 3 §5.1), grid lines (CSS Grid 2 §8.3) and counter
    # values (CSS Lists 3 §4) take integers; a number typed without
    # arithmetic is written as typed ("Numeric Inputs"), so an integer
    # property must refuse it rather than reduce it.
    for (p, v) in [("z-index", "1e-2"), ("z-index", "+1e2"), ("z-index", "1.0"),
        ("z-index", "1e0"), ("z-index", "1E2"), ("z-index", ".5"),
        ("order", "1e2"), ("order", "1.0"), ("grid-row", "1.5"),
        ("grid-row", "1e2"), ("grid-row", "span 1.5"), ("grid-row", "1.0 / 3"),
        ("grid-row", "span calc(1px + 1px)"), ("counter-reset", "c calc(1px)"),
        ("grid-column-end", "-1.5"), ("grid-area", "1.5 / 2"),
        ("counter-reset", "c 1e2"), ("counter-reset", "c .5"),
        ("counter-increment", "c 1.5"), ("grid-row", "0.5px"),
        ("grid-row-start", "2%"), ("counter-reset", "c 1px")]:
      checkpoint p & ": " & v
      check not accepted(p, v)
    for (p, v) in [("z-index", "1"), ("z-index", "-3"), ("z-index", "+2"),
        ("z-index", "007"), ("z-index", "0"), ("order", "-1"),
        ("grid-row", "1 / -1"), ("grid-row", "span 2"), ("grid-row", "2 a"),
        ("grid-row", "auto"), ("grid-area", "1 / 2 / 3 / 4"),
        ("counter-reset", "c 1"), ("counter-reset", "c -3 d +2"),
        ("counter-reset", "none"), ("counter-increment", "c"),
        ("font-weight", "1.5"), ("flex-grow", "1.5"),
        # A math function stands for an integer (CSS Values 4 §10.9), spaced
        # arguments and all (review R1).
        ("grid-row", "span calc(1 + 1)"), ("grid-area", "1 / calc(2 + 1)"),
        ("grid-column", "span min(2, 3)"), ("grid-row-start", "span calc(1 + 1)"),
        ("grid-column", "1 / calc(2 + 1)"), ("counter-reset", "c min(1, 2)"),
        ("counter-reset", "c calc(1 + 1)"), ("counter-increment", "c calc(1 + 1)"),
        ("counter-reset", "c var(--n)"), ("counter-reset", "reversed(c) 3"),
        # `auto` is z-index's keyword (CSS 2.1 §9.9.1).
        ("z-index", "auto"), ("z-index", "AUTO")]:
      checkpoint p & ": " & v
      check accepted(p, v)
    # A z-index row writes `1e-2` as typed, and the property refuses it.
    let number = @[PropertyUnitOption(label: "number", code: "")]
    for typed in ["1e-2", "+1e2", "1e0", "2.0"]:
      checkpoint "z-index row: " & typed
      let got = typeInto("z-index", number, @[typed])
      check got.commits == @[typed]
      check not accepted("z-index", got.commits[0])
    check accepted("z-index", typeInto("z-index", number, @["+3"]).commits[0])

  test "a grid placement takes one to four <grid-line>s and nothing else":
    # isonim-pm issue 2026-11-24 "the grid-line validator accepts text that
    # is not a grid line". CSS Grid 2 §8.3: `<grid-line> = auto |
    # <custom-ident> | [ <integer> && <custom-ident>? ] | [ span && [
    # <integer [1,∞]> || <custom-ident> ] ]`, the integer never zero and the
    # name never `span` or `auto`; §8.4: grid-row and grid-column take one
    # or two separated by `/`, grid-area one to four, the -start and -end
    # longhands one. Editor spec "Planned interaction parity": invalid values
    # are rejected without changing source.
    for (p, v) in [("grid-row-start", "auto"), ("grid-row-start", "a"),
        ("grid-row-start", "-1"), ("grid-row-start", "+1"),
        ("grid-row-start", "2 a"), ("grid-row-start", "a 2"),
        ("grid-row-start", "-3 a"), ("grid-row-start", "span 2"),
        ("grid-row-start", "SPAN 2"), ("grid-row-start", "span a"),
        ("grid-row-start", "span 2 a"), ("grid-row-start", "span a 2"),
        ("grid-row-start", "2 span"), ("grid-row-start", "2 a span"),
        ("grid-row-start", "none"), ("grid-row-start", "row"),
        ("grid-row-start", "-a"), ("grid-column-end", "span calc(1 + 1)"),
        ("grid-column-end", "min(1, 2) a"), ("grid-row", "1 / 3"),
        ("grid-row", "1/3"), ("grid-row", "a / span 2"),
        ("grid-row", "Span 2 / Auto"), ("grid-row", "calc(1 + 1) / -1"),
        ("grid-column", "2 span / span a 2"), ("grid-area", "1 / 2 / 3 / 4"),
        ("grid-area", "a / b / c"), ("grid-area", "1/2/3/4"),
        ("grid-area", "span 2 / span 2 / auto / a 3"), ("grid-row", "inherit"),
        # Identifiers as CSS Syntax 3 §4.3.9-4.3.11 reads them: non-ASCII
        # code points and escapes (review R1), and a keyword spelled with an
        # escape is that keyword (`sp\61n 2` is `span 2`).
        ("grid-column-end", "ä"), ("grid-column-end", "名前"),
        ("grid-row-start", "span 名前"), ("grid-row-start", "2 ä"),
        ("grid-row-start", "\\31 a"), ("grid-row-start", "c\\ d"),
        ("grid-row-start", "\\e4 2"), ("grid-row-start", "-ä"),
        ("grid-row-start", "a\\2f b"), ("grid-row", "ä / span 名前"),
        ("grid-area", "ä / 名前 / \\31 a / c\\ d"),
        ("grid-row-start", "sp\\61n 2"), ("grid-row-start", "\\61uto"),
        ("grid-row", "\\69nherit"), ("grid-row-start", "\\31"),
        ("grid-row-start", "2 SPAN"), ("grid-row-start", "2 sp\\61n"),
        ("grid-row-start", "span abs(sign(1px))"), ("grid-row", "abs(sign(1px)) / 3"),
        ("grid-area", "1 / round(up, 2.5) a"), ("grid-row-start", "span sign(1hz)"),
        ("grid-row", "abs(1dppx / 1x) / abs(2px * 2px / 1px / 1px)")]:
      checkpoint p & ": " & v
      check accepted(p, v)
    for (p, v) in [("grid-row", "( 1 ) / ( 3 )"), ("grid-row", "1 / -1 / 2"),
        ("grid-row", "(1) / (3)"), ("grid-row", "1 /"), ("grid-row", "/ 3"),
        ("grid-row", "1 // 3"), ("grid-row", "0 / 3"), ("grid-row", "1 / 0"),
        ("grid-row", "span 0 / 2"), ("grid-row", "a b / 1"),
        ("grid-row", "1 / span"), ("grid-row", "1 / 2 / 3 / 4"),
        ("grid-row", "auto / span default"), ("grid-area", "1 / 2 / 3 / 4 / 5"),
        ("grid-area", "1 / 2 / / 4"), ("grid-area", "( 1 ) / 2"),
        ("grid-row-start", "0"), ("grid-row-start", "-0"), ("grid-row-start", "+0"),
        ("grid-row-start", "span 0"), ("grid-row-start", "span -1"),
        ("grid-row-start", "span"), ("grid-row-start", "span span"),
        ("grid-row-start", "auto 2"), ("grid-row-start", "span auto"),
        ("grid-row-start", "a b"), ("grid-row-start", "2 3"),
        ("grid-row-start", "1 2 a"), ("grid-row-start", "2 span a"),
        ("grid-row-start", "default"), ("grid-row-start", "2 default"),
        ("grid-row-start", "'a'"), ("grid-row-start", "1a"),
        ("grid-row-start", "calc (1)"), ("grid-row-start", "1 / 3"),
        ("grid-column-end", "span calc(1px)"), ("grid-row", "unset 2"),
        # A reserved name stays reserved however it is spelled (CSS Grid 2
        # §8.3, CSS Values 4 §4.2): case and escapes resolved.
        ("grid-row-start", "sp\\61n"), ("grid-row-start", "a 2 sp\\61n b"),
        ("grid-row-start", "sp\\61n sp\\61n"), ("grid-row-start", "2 \\61uto"),
        ("grid-row-start", "\\61uto 2"),
        ("grid-row-start", "2 \\64 efault"), ("grid-row-start", "2 \\69nherit"),
        ("grid-row-start", "\\"), ("grid-row-start", "2 a\\"),
        ("grid-row-start", "1\\61"), ("grid-row-start", "sign()"),
        ("grid-row-start", "span sin(1px)"), ("grid-row", "abs(1px) / 3")]:
      checkpoint p & ": " & v
      check not accepted(p, v)

  test "counter-set takes counter names and integers, as counter-reset does":
    # isonim-pm issue 2026-11-24 "counter-set values are refused". CSS Lists
    # 3 §4.1-4.3: counter-reset, counter-set and counter-increment take
    # `none` or `[ <counter-name> <integer>? ]+`, a counter name being a
    # `<custom-ident>` other than `none`; only counter-reset also takes
    # `reversed(<counter-name>)`. The integer is the 5a35eb0 `<integer>`: a
    # sign and digits, or a math function that resolves to a number.
    for p in ["counter-set", "counter-reset", "counter-increment"]:
      for v in ["none", "NONE", "c", "c 1", "c -1", "c 0", "c +5", "c 1 d",
          "c d", "c 1 d 2", "c calc(1 + 1)", "c min(1, 2)", "c var(--n)",
          "inherit", "ä 1", "c\\ d 1", "名前 -2 ä", "\\31 a 3",
          "n\\6fne", "n\\6f ne", "c round(1.5)", "c abs(-2)", "c sign(1px)",
          "c sin(1deg)", "c pow(2, 3)", "c round(up, 1.5, 1e0)",
          # Math functions are typed by their signatures, arguments typed as
          # calc() types them and nested calls the same way (CSS Values 4
          # §10.3-10.8): sign() is a number whatever its argument's type.
          "c abs(sign(1px))", "c mod(7, 3)",
          "c ROUND(DOWN, 7, 2)", "c sign(calc(1px + 2px))", "c log(8, 2)",
          "c calc(abs(-2) * 2)", "c min(round(1.5), 3)", "c sign(infinity)",
          "c round(-infinity)", "c abs(NaN)", "c cos(pi)", "c tan(1turn)",
          "c hypot(3, 4)", "c abs(6 / 0)", "c abs(2px / 1px)",
          "c abs(round(1.5px, 1px) / 1px)", "c sign(1s / 1ms)",
          # Frequencies and resolutions are dimensions too (review R3a), and
          # unit powers are carried through `*` and `/` to the end of the
          # expression (review R3b, CSS Values 4 §10.9).
          "c sign(1hz)", "c abs(1dppx / 1x)", "c sign(1dppx)",
          "c abs(1hz / 1khz)", "c round(1hz / 1hz)", "c sign(2dpi * 1dpcm)",
          "c abs(2px * 2px / 1px / 1px)", "c abs(2px / 1px * 3s / 1ms)",
          "c calc(1deg * 1deg / (1rad * 1turn))", "c abs(2px * (2px / 1px) / 1px)"]:
        checkpoint p & ": " & v
        check accepted(p, v)
      for v in ["1", "c 1 2", "none c", "c none", "none 1", "c 1.5", "c 1px",
          "c 1e2", "c 50%", "default", "c default", "c, d", "c / 1",
          "c calc(1px)", "'c'", "1c", "c 1.0", "\\6e one 1", "c n\\6f ne",
          "c \\64 efault", "\\69nherit 1", "c\\", "ä 1.5", "c abs(1px)",
          "c round(1.5px)", "c asin(1)", "c hypot(3px, 4px)", "c mod(5%, 2%)",
          "c round(1.5", "c sin(1px)", "c tan(1%)", "c sin()", "c sign()",
          "c sign(foo)", "c sign(1, 2)", "c abs(1, 2)", "c abs(h1)",
          "c round(down)", "c round(1.5px, 1px)", "c round(1px, 1)", "c mod(7)",
          "c pow(2px, 2)", "c abs(sign(1px) * 1px)", "c abs(,1)",
          "c round(1, down)", "c atan2(1, 1)", "c sign(1px +)", "c abs(e1)",
          # No percentage in an `<integer>` slot (CSS Values 4 §10.9).
          "c sign(1%)", "c sign(calc(1px + 2%))", "c calc(1% / 1%)",
          "c abs(2px / 1s)", "c abs(2px * 1px)", "c abs(2 / 1px)",
          "c abs(1hz)", "c abs(1hz / 1s)", "c abs(1dppx / 1hz)",
          "c abs(2px * 2px / 1px)", "c abs(2px * 2px + 1px / 1px)",
          "c round(1x)", "c abs(1foo / 1foo)"]:
        checkpoint p & ": " & v
        check not accepted(p, v)
    for v in ["reversed(c)", "reversed(c) 2", "reversed( c ) -1",
        "c reversed(d) 1"]:
      check accepted("counter-reset", v)
      check not accepted("counter-set", v)
      check not accepted("counter-increment", v)
    check not accepted("counter-reset", "reversed(none)")

  test "a number and its unit separated by a space are refused on every path":
    # isonim-pm issue 2026-11-24 "the numeric row accepts a space before the
    # unit that the text path refuses". CSS Syntax 3 §4.3.3: a dimension is
    # a number immediately followed by its unit, so `2 px` is a number and an
    # identifier, two values. The text path reads it so; the numeric row and
    # the box-model and compound fields (``parseNumericInput``) refuse it the
    # same way, writing nothing (editor spec "Planned interaction parity":
    # the same validation on every path, invalid values rejected without
    # changing source). A unit attached to the expression's last operand is
    # kept, spaced arithmetic and all.
    for typed in ["2 px", "2  px", "2\tpx", "(1+2) px", "( 1+2 ) px",
        "1 + 2 px", "2 ^ 2 px", "-2 px", "2 %", "10 / 3 rem", "2 PX",
        "2 dvh", "0 px", "-(2 + 3) px", "1e2 px"]:
      checkpoint typed
      check not accepted("margin", typed)
      for wired in [false, true]:
        let got = typeInto("margin", lengthUnits, @[typed], wired)
        check got.commits.len == 0
        check got.field == "10"
      check parseNumericInput(typed).value.isNone
      check parseNumericDimension(typed).value.isNone
    for (typed, written) in [("2px", "2px"), ("(1+2)px", "3px"),
        ("( 1+2 )px", "3px"), ("1 + 2px", "3px"), ("2 ^ 2px", "4px"),
        ("10 / 3rem", "3.3333rem"), ("-(2 + 3)px", "-5px"), ("2px ", "2px")]:
      checkpoint typed
      check accepted("margin", typed)
      check typeInto("margin", lengthUnits, @[typed]).commits == @[written]
      check parseNumericInput(typed).value.isSome

  test "a step or scrub that changes the value drops the kept spelling":
    # Review R5/R4: the kept spelling belongs to the value it spells. A scrub
    # that moves the value writes the value; a value that returns is written
    # by its value, not by the old spelling; a chip cycled away and back
    # writes the chip's code.
    for wired in [false, true]:
      checkpoint "wired=" & $wired
      createRoot proc(dispose: proc()) =
        let value = createSignal(10.0)
        let unit = createSignal(pxUnit)
        let source = createSignal("10px")
        var commits: seq[string]
        var cfg = propertyRowNumeric(name = "Margin", value = value, unit = unit,
          units = @[pxUnit, emUnit],
          wiring = (if wired: InspectorRowWiring(cssProperty: "margin",
            authoredValue: proc(): string = source.val) else: InspectorRowWiring()))
        cfg.onCommitValue = proc(v: string) =
          commits.add v
          if wired: source.val = v
        let (r, root) = mkRoot()
        discard r.mountPropertyRow(root, cfg)
        let input = findByAttr(root, "data-property-row-input", "true")
        let handle = findByAttr(root, "data-property-row-slot", "label-scrubber")
        let chip = findByAttr(root, "data-property-row-unit", "true")
        proc drag(dx: float) =
          fireEventWith(handle, "mousedown", MockEvent(clientX: 0, clientY: 0))
          fireEventWith(handle, "mousemove", MockEvent(clientX: dx, clientY: 0))
          fireEventWith(handle, "mouseup", MockEvent(clientX: dx, clientY: 0))
        r.setInputValue(input, "1.50")
        fireEvent(input, "change")
        check commits == @["1.50px"]
        drag(1)
        check commits[^1] == "3.5px"
        check r.inputValue(input) == "3.5"
        drag(-1)
        check commits[^1] == "1.5px"
        check r.inputValue(input) == "1.5"
        # A drag that returns to its start writes nothing and keeps the
        # spelling it had.
        r.setInputValue(input, "+1.50")
        fireEvent(input, "change")
        let before = commits.len
        fireEventWith(handle, "mousedown", MockEvent(clientX: 0, clientY: 0))
        fireEventWith(handle, "mousemove", MockEvent(clientX: 5, clientY: 0))
        fireEventWith(handle, "mousemove", MockEvent(clientX: 0, clientY: 0))
        fireEventWith(handle, "mouseup", MockEvent(clientX: 0, clientY: 0))
        check commits.len == before
        check r.inputValue(input) == "+1.50"
        # A value moved by its caller, then back, is written by its value.
        value.val = 7.0
        value.val = 1.5
        fireEvent(chip, "click")
        check commits[^1] == "1.5em"
        # A typed unit spelling is the chip's only while the chip holds it.
        r.setInputValue(input, "12PX")
        fireEvent(input, "change")
        check commits[^1] == "12PX"
        fireEvent(chip, "click")
        check commits[^1] == "12em"
        # Round the chip's cycle back to px: px, not the typed PX.
        var turns = 0
        while chipText(chip) != "px" and turns < 12:
          fireEvent(chip, "click")
          inc turns
        check chipText(chip) == "px"
        check commits[^1] == "12px"
        dispose()

  test "zero typed with the other sign is written once, as typed":
    # Review R2. Editor spec "Numeric Inputs" (:353-354): "A number typed
    # without arithmetic is kept exactly as authored." `-0` and `0` are the
    # same value in another spelling, so the typed spelling is written, once;
    # retyping it, or the blur after it, writes nothing more.
    for (start, typed, written) in [("0px", "-0", "-0px"), ("-0px", "0", "0px"),
        ("0px", "-0px", "-0px"), ("-0px", "+0", "+0px")]:
      for wired in [false, true]:
        checkpoint start & " <- " & typed & " wired=" & $wired
        createRoot proc(dispose: proc()) =
          let value = createSignal(0.0)
          let unit = createSignal(pxUnit)
          let source = createSignal(start)
          var commits: seq[string]
          var cfg = propertyRowNumeric(name = "Margin", value = value, unit = unit,
            units = @[pxUnit],
            wiring = (if wired: InspectorRowWiring(cssProperty: "margin",
              authoredValue: proc(): string = source.val) else: InspectorRowWiring()))
          cfg.onCommitValue = proc(v: string) =
            commits.add v
            if wired: source.val = v
          let (r, root) = mkRoot()
          discard r.mountPropertyRow(root, cfg)
          let input = findByAttr(root, "data-property-row-input", "true")
          if not wired:
            # An unwired row learns its spelling from what was typed.
            r.setInputValue(input, start)
            fireEvent(input, "change")
            commits.setLen(0)
          r.setInputValue(input, typed)
          fireEvent(input, "change")
          fireEvent(input, "blur")
          r.setInputValue(input, typed)
          fireEvent(input, "change")
          fireEvent(input, "blur")
          check commits == @[written]
          check r.inputValue(input) == written[0 ..< written.len - 2]
          dispose()

  test "an arrow step that changes nothing writes nothing":
    # Review R6: the arrow keys' text is ``numericStepText``. A step binary64
    # cannot take (1e20 + 1 is 1e20) gives "", so no respelling is committed
    # and no history entry is made.
    check numericStepText("1e20px", 1.0) == ""
    check numericStepText("1e20", -1.0) == ""
    check numericStepText("100000000000000000000px", 1.0) == ""
    check numericStepText("1.1px", 0.1) == "1.2px"
    check numericStepText("1e-20px", 1.0) == "1px"
    check numericStepText("+1.50", 1.0) == "2.5"
    check numericStepText("0.125turn", 0.1) == "0.225turn"
    check numericStepText("10PX", 1.0) == "11PX"
    check numericStepText("12dvh", -10.0) == "2dvh"
    check numericStepText("1.", 1.0) == "2"
    for raw in ["", "abc", "calc(1px)", "1px+2", "--1", "1 px", "1px2"]:
      checkpoint raw
      check numericStepText(raw, 1.0) == ""

  test "a value that moves while the row is bound copies its value, not the kept spelling":
    # Review round 2, Q1. While the row is bound to a variable the linked chip
    # replaces the value field, so the field's own effects are not mounted;
    # the value can still move, and More > Copy reads the row's CSS value. A
    # kept spelling belongs to the value it spells (editor spec "Numeric
    # Inputs", :353-354): after `1.50` and a move to 7, Copy gives `7px`, not
    # the stale `1.50px`.
    for wired in [false, true]:
      checkpoint "wired=" & $wired
      createRoot proc(dispose: proc()) =
        let value = createSignal(10.0)
        let unit = createSignal(pxUnit)
        let source = createSignal("10px")
        let bound = createSignal(none(VariableBinding))
        let clipboard = createSignal(PropertyClipboardEntry())
        var commits: seq[string]
        var cfg = propertyRowNumeric(name = "Margin", value = value, unit = unit,
          units = @[pxUnit, emUnit],
          bindingReactive = proc(): Option[VariableBinding] = bound.val,
          wiring = (if wired: InspectorRowWiring(cssProperty: "margin",
            authoredValue: proc(): string = source.val) else: InspectorRowWiring()))
        cfg.cssProperty = "margin"
        cfg.clipboard = clipboard
        cfg.onCommitValue = proc(v: string) =
          commits.add v
          if wired: source.val = v
        let (r, root) = mkRoot()
        let row = r.mountPropertyRow(root, cfg)
        var input = findByAttr(root, "data-property-row-input", "true")
        r.setInputValue(input, "1.50")
        fireEvent(input, "change")
        check commits == @["1.50px"]
        bound.val = some(VariableBinding(state: vbsBound, variableKey: "spacing/4",
          resolvedValue: "7px"))
        # Bound: the linked chip, no value field.
        check findByAttr(root, "data-property-row-linked-chip", "true") != nil
        check findByAttr(root, "data-property-row-input", "true") == nil
        value.val = 7.0
        row.fireEvent("contextmenu")
        let menu = findByAttr(row, "data-property-actions-menu", "true")
        require menu != nil
        let copy = findByAttr(menu, "data-property-action", "copy")
        require copy != nil
        copy.fireEvent("click")
        check clipboard.val.value == "7px"
        # Unbound again (an unwired row has no source to reload): the field
        # shows the value, and a unit change writes it, not the old spelling.
        if not wired:
          bound.val = none(VariableBinding)
          input = findByAttr(root, "data-property-row-input", "true")
          require input != nil
          check r.inputValue(input) == "7"
          fireEvent(findByAttr(root, "data-property-row-unit", "true"), "click")
          check commits[^1] == "7em"
        dispose()
