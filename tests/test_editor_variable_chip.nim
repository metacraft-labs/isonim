## Phase E.2 — ViewModel + headless mount tests for the variable chip
## widget (``src/isonim/editor/views/widgets/variable_chip.nim``).
##
## Six scenarios cover the chip's contract:
##
##   1. Mount stamps ``data-variable-chip="true"`` + key + state on
##      the root and renders the leading diamond, name, chevron, and
##      detach affordance.
##   2. ``vbsBound`` state lights the leading glyph in the accent
##      colour; ``vbsBoundMissing`` colours it red.
##   3. Detach affordance is hidden by default and surfaces on
##      ``mouseenter`` via the ``data-variable-chip-hover`` flip.
##   4. Clicking the chevron fires ``onChevronClick``.
##   5. Clicking the name fires ``onNameClick``.
##   6. Clicking the detach button fires ``onDetach``.
##   7. ``extraRootAttr`` / ``extraNameAttr`` propagate to the root +
##      name nodes (the legacy property-row selector contract).

import std/[tables, unittest]

import isonim/core/[signals, computation, owner]
import isonim/editor/types
import isonim/editor/views/widgets/variable_chip
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
  if node.kind == mnkElement and
      node.attributes.getOrDefault(attr) == value:
    return node
  for c in node.children:
    let hit = findByAttr(c, attr, value)
    if hit != nil:
      return hit
  return nil

proc findByAttrPresent(node: MockNode; attr: string): MockNode =
  if node == nil:
    return nil
  if node.kind == mnkElement and attr in node.attributes:
    return node
  for c in node.children:
    let hit = findByAttrPresent(c, attr)
    if hit != nil:
      return hit
  return nil

const SampleBinding = VariableBinding(
  state: vbsBound,
  variableKey: "color/surface",
  resolvedValue: "#0F172A",
  sourceFileRef: "foundations/colour.nim",
  sourceLineRef: 12)

const MissingBinding = VariableBinding(
  state: vbsBoundMissing,
  variableKey: "color/ghost",
  resolvedValue: "",
  sourceFileRef: "",
  sourceLineRef: 0)

# --------------------------------------------------------------------------- #
#  Suite
# --------------------------------------------------------------------------- #

suite "Phase E.2 variable_chip mount":

  test "chip mount exposes the contract data attributes":
    createRoot do (dispose: proc()):
      let (r, root) = mkRoot()
      let cfg = variableChipConfig(binding = SampleBinding,
                                    usageCount = 17)
      discard r.mountVariableChip(root, cfg)

      let chip = findByAttr(root, "data-variable-chip", "true")
      check chip != nil
      check chip.attributes.getOrDefault("data-variable-chip-key") ==
        "color/surface"
      check chip.attributes.getOrDefault("data-variable-chip-state") ==
        "bound"
      check chip.attributes.getOrDefault("data-variable-chip-resolved") ==
        "#0F172A"
      check chip.attributes.getOrDefault("data-variable-chip-usage-count") ==
        "17"

      let nameNode = findByAttr(root, "data-variable-chip-name", "true")
      check nameNode != nil
      check textContent(nameNode) == "color/surface"

      let chevron = findByAttr(root, "data-variable-chip-chevron", "true")
      check chevron != nil

      let detach = findByAttr(root, "data-variable-chip-detach", "true")
      check detach != nil
      dispose()

  test "bound-missing state colours the leading glyph red":
    createRoot do (dispose: proc()):
      let (r, root) = mkRoot()
      let cfg = variableChipConfig(binding = MissingBinding)
      discard r.mountVariableChip(root, cfg)

      let chip = findByAttr(root, "data-variable-chip", "true")
      check chip != nil
      check chip.attributes.getOrDefault("data-variable-chip-state") ==
        "bound-missing"
      let glyph = findByAttr(root, "data-variable-chip-glyph", "true")
      check glyph != nil
      check glyph.styles.getOrDefault("color") == "#F87171"
      dispose()

  test "detach affordance hidden by default and surfaces on hover":
    createRoot do (dispose: proc()):
      let (r, root) = mkRoot()
      let cfg = variableChipConfig(binding = SampleBinding)
      discard r.mountVariableChip(root, cfg)

      let chip = findByAttr(root, "data-variable-chip", "true")
      check chip != nil
      check chip.attributes.getOrDefault("data-variable-chip-hover") ==
        "false"

      let detach = findByAttr(root, "data-variable-chip-detach", "true")
      check detach != nil
      check detach.styles.getOrDefault("display") == "none"

      fireEvent(chip, "mouseenter")
      check chip.attributes.getOrDefault("data-variable-chip-hover") ==
        "true"
      check detach.styles.getOrDefault("display") == "inline-flex"

      fireEvent(chip, "mouseleave")
      check chip.attributes.getOrDefault("data-variable-chip-hover") ==
        "false"
      check detach.styles.getOrDefault("display") == "none"
      dispose()

  test "clicking the chevron fires onChevronClick":
    createRoot do (dispose: proc()):
      let (r, root) = mkRoot()
      var chevronFired = 0
      let cfg = variableChipConfig(
        binding = SampleBinding,
        onChevronClick = proc() = inc chevronFired)
      discard r.mountVariableChip(root, cfg)

      let chevron = findByAttr(root, "data-variable-chip-chevron", "true")
      check chevron != nil
      fireEvent(chevron, "click")
      check chevronFired == 1
      dispose()

  test "clicking the name fires onNameClick":
    createRoot do (dispose: proc()):
      let (r, root) = mkRoot()
      var nameFired = 0
      let cfg = variableChipConfig(
        binding = SampleBinding,
        onNameClick = proc() = inc nameFired)
      discard r.mountVariableChip(root, cfg)

      let nameNode = findByAttr(root, "data-variable-chip-name", "true")
      check nameNode != nil
      fireEvent(nameNode, "click")
      check nameFired == 1
      dispose()

  test "clicking the detach affordance fires onDetach":
    createRoot do (dispose: proc()):
      let (r, root) = mkRoot()
      var detachFired = 0
      let cfg = variableChipConfig(
        binding = SampleBinding,
        onDetach = proc() = inc detachFired)
      discard r.mountVariableChip(root, cfg)

      let chip = findByAttr(root, "data-variable-chip", "true")
      check chip != nil
      fireEvent(chip, "mouseenter")
      let detach = findByAttr(root, "data-variable-chip-detach", "true")
      check detach != nil
      fireEvent(detach, "click")
      check detachFired == 1
      dispose()

  test "extraRootAttr + extraNameAttr stamp legacy selectors":
    createRoot do (dispose: proc()):
      let (r, root) = mkRoot()
      let cfg = variableChipConfig(
        binding = SampleBinding,
        extraRootAttr = "data-property-row-linked-chip=true",
        extraNameAttr = "data-property-row-linked-variable=color/surface")
      discard r.mountVariableChip(root, cfg)

      let legacyRoot = findByAttr(root, "data-property-row-linked-chip",
        "true")
      check legacyRoot != nil
      check legacyRoot.attributes.getOrDefault("data-variable-chip") ==
        "true"

      let legacyName = findByAttr(root,
        "data-property-row-linked-variable", "color/surface")
      check legacyName != nil
      check textContent(legacyName) == "color/surface"
      dispose()
