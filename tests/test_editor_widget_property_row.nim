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

      # Mousedown arms; each mousemove nudges by step.
      fireEvent(labelNode, "mousedown")
      fireEvent(labelNode, "mousemove")
      fireEvent(labelNode, "mousemove")
      fireEvent(labelNode, "mousemove")
      check value.val == 56.0
      fireEvent(labelNode, "mouseup")
      # Disarmed: a subsequent mousemove is a no-op.
      fireEvent(labelNode, "mousemove")
      check value.val == 56.0
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

  test "prkChoice mounts ChoiceGroup with expected labels":
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

      let row = findByAttr(root, "data-property-row-kind", "choice")
      check row != nil
      let group = findByAttr(root, "data-choice-group", "segmented")
      check group != nil

      let pillBlock = findByAttr(root, "data-choice-group-pill", "0")
      let pillFlex = findByAttr(root, "data-choice-group-pill", "1")
      let pillGrid = findByAttr(root, "data-choice-group-pill", "2")
      check pillBlock != nil
      check pillFlex != nil
      check pillGrid != nil
      check pillBlock.attributes.getOrDefault("data-choice-group-label") ==
        "Block"
      # ChoiceGroup labels read through ``data-choice-group-label``.

      # Driving a pick through the segmented control's click handler
      # mirrors the value into ``choiceValue``.
      fireEvent(pillGrid, "click")
      check value.val == "grid"
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
