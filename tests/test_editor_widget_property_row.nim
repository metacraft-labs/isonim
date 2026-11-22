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
import isonim/editor/views/choice_row
import isonim/editor/views/widgets/property_row
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
    # The token form the editor already wrote stays the same:
    # `var(--name)` is written as `token(name)`, now on every property.
    for (p, v, t) in [("width", "var(--a)", "token(a)"), ("width", "var(--a )", "token(a)"),
        ("aspect-ratio", "var(--x)", "token(x)"), ("overflow", "var(--x)", "token(x)"),
        ("width", "var(--\\31 a)", "token(\\31 a)")]:
      accepts(p, v)
      check written(p, v) == t
    # A value the token parser would write as a token form naming no custom
    # property is judged by the property's grammar, as before: it is never
    # written changed.
    for (p, v) in [("filter", "var(--x), var(--y)"), ("overflow", "var(--x), var(--y)"),
        ("aspect-ratio", "var(--x), var(--y)")]:
      refuses(p, v)
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
