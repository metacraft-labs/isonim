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

import std/[options, tables, unittest]

import isonim/core/[signals, computation, owner]
import isonim/editor/types
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
      # The row is named even though no pill is showing the name.
      let label = findByAttr(root, "data-property-row-slot", "label-scrubber")
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
      check checkbox.attributes.getOrDefault("checked") == "false"

      fireEvent(checkbox, "click")
      check value.val == true
      check checkbox.attributes.getOrDefault("checked") == "true"
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
