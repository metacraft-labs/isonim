## VBIND-M7 — end-to-end through the REAL inspector shell + real workspace.
##
## The prior "live" e2e drove a STANDALONE widget fixture
## (``tests/browser/variable_binding_fixture/harness.nim``) — a single chip +
## picker on a bare page, not the section-based inspector. This test supersedes
## it with the required headless real-shell acceptance gate: it drives the
## ACTUAL inspector section render (``mountSectionStroke`` — the same path
## ``mountInspectorSectionBody`` mounts in the live shell), the ACTUAL variable
## picker mount, and the ACTUAL shell picker-open wiring
## (``requestVariablePicker`` seeding ``compatibleCategories`` +
## ``previouslyLinked`` exactly as ``shell.nim`` does), over a workspace built by
## ``newEditorWorkspace`` and applied through ``createEditorVM``/``applyWorkspace``
## — isonim's headless-first ViewModel philosophy (a real browser Playwright
## pass is a bonus, not the deliverable).
##
## The full loop, asserted end to end:
##   (1) select a bound element  → the section row shows the linked CHIP;
##   (2) UNLINK                   → the row becomes a literal input SEEDED with
##                                  the detached value (local override journaled);
##   (3) open the picker          → COMPATIBLE-ONLY (colour props → colour
##                                  variables) with PREVIOUSLY-LINKED at the top;
##   (4) RE-LINK from that group  → the chip returns;
##   (5) SAVE + LOAD round-trip   → the binding persists through the real
##                                  ``collectWorkspaceBindingMetadata`` →
##                                  ``bindingSidecarJson`` → an on-disk sidecar →
##                                  ``parseBindingSidecar`` → ``loadBindingSidecar``
##                                  → a FRESH ``applyWorkspace`` rehydrates chips.
##
## Plus the backward-compat CONTROL: an EMPTY-metadata workspace renders the
## inspector with NO chip and NO "Previously linked" group — locking the default.
##
## "DTCG source untouched" (framework analogue): the binding metadata flows ONLY
## to the sidecar. The sole source edit the loop produces is the M3 detach LOCAL
## override; LINKING a property stages NO foundation/token source edit, and the
## foundation tokens are byte-identical before and after — so nothing about the
## binding ever reaches the design-token source.

import std/[options, os, strutils, tables, tempfiles, unittest]

import isonim/core/[signals, computation, owner]
import isonim/editor
import isonim/editor/views/widgets/section_stroke
import isonim/editor/views/widgets/variable_picker
import isonim/testing/mock_dom

proc findByAttr(node: MockNode; attr, value: string): MockNode =
  if node == nil: return nil
  if node.kind == mnkElement and node.attributes.getOrDefault(attr) == value:
    return node
  for c in node.children:
    let hit = findByAttr(c, attr, value)
    if hit != nil: return hit
  return nil

proc collectByAttr(node: MockNode; attr: string): seq[MockNode] =
  result = @[]
  if node == nil: return
  if node.kind == mnkElement and attr in node.attributes:
    result.add node
  for c in node.children:
    for hit in collectByAttr(c, attr):
      result.add hit

proc fixtureTokens(): seq[FoundationTokenEntry] =
  @[
    FoundationTokenEntry(key: "color/surface", kind: ftkSemanticColor,
      value: "#0F172A", schemaKey: "color/surface",
      sourceFile: "foundations/colour.nim", sourceLine: 12),
    FoundationTokenEntry(key: "color/accent", kind: ftkSemanticColor,
      value: "#7C7AED", schemaKey: "color/accent",
      sourceFile: "foundations/colour.nim", sourceLine: 18),
    FoundationTokenEntry(key: "spacing/4", kind: ftkSpacingScale,
      value: "16px", schemaKey: "spacing/4",
      sourceFile: "foundations/spacing.nim", sourceLine: 8)]

proc boundElement(): ElementRef =
  ## The selected element the bound row renders over. Carries the source
  ## anchors + directStyleAllowed the M3 detach → local-override path needs.
  ElementRef(tag: "div", id: "frame-1",
    sourceFile: "components/Frame.nim", sourceLine: 10,
    properties: @[PropertyInfo(name: "border-color", value: "#1A1B22",
      origin: poInherited, sourceFile: "components/Frame.nim",
      sourceLine: 10, directStyleAllowed: true)])

const BorderKey = PropertyBindingKey(
  elementId: "frame-1", propertyName: "border-color")

proc wireShellPickerHook(vm: EditorVM; picker: VariablePickerState) =
  ## The EXACT wiring shell.nim installs: seed the compatibility filter +
  ## previously-linked group from the property being linked, then open.
  vm.inspector.requestVariablePicker =
    proc(key: PropertyBindingKey; x, y, w, h: float) {.closure.} =
      picker.compatibleCategories.val = compatibleCategoriesFor(key.propertyName)
      picker.previouslyLinked.val = vm.previouslyLinkedVariables(key)
      openVariablePickerWithRect(picker, key, x, y, w, h)

suite "VBIND-M7 real-shell e2e: select → chip → unlink → relink → save → load":

  test "the full link/unlink/relink loop round-trips through the sidecar file":
    createRoot do (dispose: proc()):
      # An on-disk sidecar makes the SAVE + LOAD go through a real file, exactly
      # as a pilot's save hook does (never the checked-in tree — a temp dir).
      let dir = createTempDir("vbind_e2e_", "_sidecar")
      defer: removeDir(dir)
      let sidecarPath = dir / bindingSidecarRelPath

      # --- Build + apply a workspace SEEDED with a binding + history --------- #
      let ws = newEditorWorkspace(
        title = "VBIND-M7", storyGroups = @[],
        foundationTokens = fixtureTokens(),
        variableBindings = @[
          PersistedPropertyBinding(elementId: "frame-1",
            propertyName: "border-color", variableKey: "color/surface")],
        variableBindingHistory = @[
          PropertyBindingHistoryEntry(elementId: "frame-1",
            propertyName: "border-color",
            variableKeys: @["color/accent", "color/surface"])])
      let vm = createEditorVM(ws)
      let tokensBefore = vm.foundations.tokens.val   # DTCG-source guard baseline

      # The SAVE seam a pilot wires: snapshot → serialize → write the sidecar.
      vm.inspector.onBindingsChanged = proc() {.closure.} =
        let meta = vm.collectWorkspaceBindingMetadata()
        createDir(sidecarPath.parentDir)
        writeFile(sidecarPath, bindingSidecarJson(meta.bindings, meta.history))

      let picker = createVariablePickerState()
      vm.wireShellPickerHook(picker)

      vm.inspector.selectedElement.val = boundElement()

      let r = MockRenderer()
      let root = r.createElement("div")
      mountSectionStroke[MockRenderer, MockNode](r, root, vm)
      discard r.mountVariablePicker(root, vm, picker)

      # (1) SELECT → CHIP: the rehydrated binding renders the linked chip.
      block:
        let colorRow = findByAttr(root, "data-property-row", "color")
        check colorRow != nil
        check colorRow.attributes.getOrDefault("data-property-row-linked") ==
          "true"
        check findByAttr(colorRow, "data-variable-chip-key", "color/surface") !=
          nil
        check findByAttr(colorRow, "data-property-row-input", "true") == nil

      # (2) UNLINK → local literal override, seeded with the resolved value.
      block:
        let colorRow = findByAttr(root, "data-property-row", "color")
        let detach = findByAttr(colorRow, "data-variable-chip-detach", "true")
        check detach != nil
        fireEvent(detach, "click")

      check vm.propertyBindingFor(BorderKey).isNone
      block:
        let edits = vm.inspector.pendingSourceEdits.val
        check edits.len == 1
        check edits[0].property == "border-color"
        check edits[0].scope == pesLocal
        check edits[0].newValue.toLowerAscii() == "#0f172a"
        let colorRow = findByAttr(root, "data-property-row", "color")
        check colorRow.attributes.getOrDefault("data-property-row-linked") ==
          "false"
        let input = findByAttr(colorRow, "data-property-row-input", "true")
        check input != nil
        check r.inputValue(input).toLowerAscii() == "#0f172a"
      # The detach fired the save seam → the sidecar now has zero bindings.
      check fileExists(sidecarPath)
      check parseBindingSidecar(readFile(sidecarPath)).bindings.len == 0

      # (3) OPEN THE PICKER (compatible-only + previously-linked at the top).
      block:
        let colorRow = findByAttr(root, "data-property-row", "color")
        let bindSlot = findByAttr(colorRow, "data-property-row-slot", "bind")
        check bindSlot != nil
        fireEvent(bindSlot, "click")

      check picker.open.val == true
      let pickerNode = findByAttr(root, "data-variable-picker", "true")
      check pickerNode != nil
      # Compatible-only: a colour property lists ONLY colour variables — the
      # spacing token never appears.
      check findByAttr(pickerNode, "data-variable-picker-row", "spacing/4") ==
        nil
      # Previously-linked group present, most-recent-first. The just-unlinked
      # color/surface floated to the front of the history.
      let priorGroup = findByAttr(pickerNode,
        "data-variable-picker-previously-linked", "true")
      check priorGroup != nil
      block:
        let rows = collectByAttr(pickerNode, "data-variable-picker-row")
        check rows.len == 2
        check rows[0].attributes["data-variable-picker-row"] == "color/surface"
        check rows[1].attributes["data-variable-picker-row"] == "color/accent"

      # (4) RE-LINK from the previously-linked group → the chip returns.
      block:
        let priorRow = findByAttr(pickerNode,
          "data-variable-picker-row", "color/surface")
        check priorRow != nil
        fireEvent(priorRow, "click")

      check picker.open.val == false
      block:
        let bound = vm.propertyBindingFor(BorderKey)
        check bound.isSome
        check bound.get.variableKey == "color/surface"
        check bound.get.state == vbsBound
        let colorRow = findByAttr(root, "data-property-row", "color")
        check colorRow.attributes.getOrDefault("data-property-row-linked") ==
          "true"
        check findByAttr(colorRow, "data-variable-chip-key", "color/surface") !=
          nil

      # The re-link fired the save seam → the sidecar carries the binding again.
      block:
        let persisted = parseBindingSidecar(readFile(sidecarPath))
        check persisted.bindings.len == 1
        check persisted.bindings[0].elementId == "frame-1"
        check persisted.bindings[0].propertyName == "border-color"
        check persisted.bindings[0].variableKey == "color/surface"

      # (5) LOAD round-trip: a FRESH workspace loads the sidecar off disk and a
      # fresh VM rehydrates the chip — reload restores from workspace metadata.
      var reloaded = newEditorWorkspace(title = "Reloaded", storyGroups = @[],
        foundationTokens = fixtureTokens())
      reloaded.loadBindingSidecar(readFile(sidecarPath))
      let vm2 = createEditorVM(reloaded)
      block:
        let restored = vm2.propertyBindingFor(BorderKey)
        check restored.isSome
        check restored.get.variableKey == "color/surface"
        check restored.get.state == vbsBound
        check restored.get.resolvedValue == "#0F172A"

      # DTCG-source guard: the foundation tokens are byte-identical to the
      # start — the whole binding loop never wrote the design-token source, and
      # LINKING staged no foundation source edit (only the M3 detach override
      # remains on pendingSourceEdits).
      check vm.foundations.tokens.val == tokensBefore
      block:
        var tokenEdits = 0
        for e in vm.inspector.pendingSourceEdits.val:
          if e.property != "border-color": inc tokenEdits
        check tokenEdits == 0
      dispose()

suite "VBIND-M7 backward-compat control: empty metadata renders as pre-initiative":

  test "an empty-metadata workspace shows no chip and no previously-linked group":
    createRoot do (dispose: proc()):
      let ws = newEditorWorkspace(title = "Empty", storyGroups = @[],
        foundationTokens = fixtureTokens())
      let vm = createEditorVM(ws)
      check vm.inspector.propertyBindings.val.len == 0
      check vm.inspector.variableBindingHistory.val.len == 0

      let picker = createVariablePickerState()
      vm.wireShellPickerHook(picker)
      vm.inspector.selectedElement.val = boundElement()

      let r = MockRenderer()
      let root = r.createElement("div")
      mountSectionStroke[MockRenderer, MockNode](r, root, vm)
      discard r.mountVariablePicker(root, vm, picker)

      # No chip: the row renders exactly as before the initiative (literal input
      # + inert bind slot).
      let colorRow = findByAttr(root, "data-property-row", "color")
      check colorRow != nil
      check colorRow.attributes.getOrDefault("data-property-row-linked") ==
        "false"
      check findByAttr(colorRow, "data-variable-chip", "true") == nil
      check findByAttr(colorRow, "data-property-row-input", "true") != nil

      # Opening the picker offers NO "Previously linked" group (empty history).
      let bindSlot = findByAttr(colorRow, "data-property-row-slot", "bind")
      check bindSlot != nil
      fireEvent(bindSlot, "click")
      let pickerNode = findByAttr(root, "data-variable-picker", "true")
      check pickerNode != nil
      check findByAttr(pickerNode,
        "data-variable-picker-previously-linked", "true") == nil
      dispose()
