## Phase E.3 — ViewModel + headless mount tests for the variable picker
## popover (``src/isonim/editor/views/widgets/variable_picker.nim``).
##
## Suite covers:
##
##   1. ``createVariablePickerState`` defaults: closed, empty search,
##      every category expanded.
##   2. ``matchesPickerQuery`` matches prefix + infix (case-insensitive).
##   3. ``filterPickerTokens`` filters the token sequence by query.
##   4. ``categoriseTokens`` groups tokens into the seven picker
##      categories preserving source order.
##   5. ``toggleCategoryExpansion`` flips the per-category collapsed
##      state.
##   6. ``openVariablePickerWithRect`` flips ``open`` and seeds the
##      anchor rect + target property key.
##   7. Mount: rendered popover lists every available variable grouped
##      by category, with the contract data attributes.
##   8. Mount: typing into the search input filters the visible rows.
##   9. Mount: clicking a row calls ``vm.bindPropertyToVariable`` with
##      the target property key + the row's variable key, then closes
##      the popover.
##  10. Mount: clicking a row's "Edit this variable" affordance calls
##      ``state.onVariableEdit`` with the variable key.
##  11. Mount: empty token set renders the empty-state row.

import std/[options, strutils, tables, unittest]

import isonim/core/[signals, computation, owner]
import isonim/editor/types
import isonim/editor/viewmodels
import isonim/editor/views/widgets/variable_picker
import isonim/editor/views/widgets/variable_inline_editor
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

proc collectByAttr(node: MockNode; attr: string): seq[MockNode] =
  result = @[]
  if node == nil:
    return
  if node.kind == mnkElement and attr in node.attributes:
    result.add node
  for c in node.children:
    for hit in collectByAttr(c, attr):
      result.add hit

proc seedTokens(vm: EditorVM) =
  ## Seed the EditorVM with four foundation tokens covering three
  ## picker categories. ``schemaKey`` + ``sourceFile`` are populated
  ## so ``editFoundationToken`` accepts edits — those fields are
  ## required by ``validateFoundationTokenEdit`` for a foundation
  ## write-back to be allowed.
  vm.foundations.tokens.val = @[
    FoundationTokenEntry(key: "color/surface", kind: ftkSemanticColor,
      value: "#0F172A",
      schemaKey: "color/surface",
      sourceFile: "foundations/colour.nim",
      sourceLine: 12,
      affectedStories: @[
        StoryRef(group: "TaskRow", name: "Active", kind: skComponent),
        StoryRef(group: "Home", name: "Default", kind: skPage)]),
    FoundationTokenEntry(key: "color/accent", kind: ftkSemanticColor,
      value: "#7C7AED",
      schemaKey: "color/accent",
      sourceFile: "foundations/colour.nim",
      sourceLine: 18,
      affectedStories: @[
        StoryRef(group: "TaskRow", name: "Selected", kind: skComponent)]),
    FoundationTokenEntry(key: "spacing/4", kind: ftkSpacingScale,
      value: "16px",
      schemaKey: "spacing/4",
      sourceFile: "foundations/spacing.nim",
      sourceLine: 8,
      affectedStories: @[]),
    FoundationTokenEntry(key: "radius/sm", kind: ftkRadiusScale,
      value: "4px",
      schemaKey: "radius/sm",
      sourceFile: "foundations/radius.nim",
      sourceLine: 4,
      affectedStories: @[])]

const TargetKey = PropertyBindingKey(
  elementId: "frame-1", propertyName: "background-color")

# --------------------------------------------------------------------------- #
#  Pure VM helpers
# --------------------------------------------------------------------------- #

suite "Phase E.3 variable_picker pure helpers":

  test "createVariablePickerState defaults":
    createRoot do (dispose: proc()):
      let state = createVariablePickerState()
      check state.open.val == false
      check state.searchText.val == ""
      check state.anchorRect.val == (0.0, 0.0, 0.0, 0.0)
      let expansion = state.expandedCategories.val
      for cat in [vpcColour, vpcSpacing, vpcTypography, vpcRadius,
                  vpcEffect, vpcNumber, vpcString]:
        check expansion.getOrDefault(cat, false) == true
      dispose()

  test "matchesPickerQuery handles prefix and infix":
    let token = FoundationTokenEntry(key: "color/surface",
                                      kind: ftkSemanticColor,
                                      value: "#0F172A")
    check token.matchesPickerQuery("") == true
    check token.matchesPickerQuery("color") == true
    check token.matchesPickerQuery("surface") == true
    check token.matchesPickerQuery("COLOR") == true
    check token.matchesPickerQuery("Surf") == true
    check token.matchesPickerQuery("spacing") == false

  test "filterPickerTokens drops non-matching entries":
    let tokens = @[
      FoundationTokenEntry(key: "color/surface", kind: ftkSemanticColor,
        value: "#0F172A"),
      FoundationTokenEntry(key: "spacing/4", kind: ftkSpacingScale,
        value: "16px"),
      FoundationTokenEntry(key: "radius/sm", kind: ftkRadiusScale,
        value: "4px")]
    let colour = filterPickerTokens(tokens, "color")
    check colour.len == 1
    check colour[0].key == "color/surface"
    let spacing = filterPickerTokens(tokens, "pac")
    check spacing.len == 1
    check spacing[0].key == "spacing/4"
    let all = filterPickerTokens(tokens, "")
    check all.len == 3

  test "categoriseTokens groups tokens into the seven categories":
    let tokens = @[
      FoundationTokenEntry(key: "color/surface", kind: ftkSemanticColor,
        value: "#0F172A"),
      FoundationTokenEntry(key: "color/accent", kind: ftkSemanticColor,
        value: "#7C7AED"),
      FoundationTokenEntry(key: "spacing/4", kind: ftkSpacingScale,
        value: "16px"),
      FoundationTokenEntry(key: "radius/sm", kind: ftkRadiusScale,
        value: "4px")]
    let grouped = categoriseTokens(tokens)
    check grouped.len == 3
    check grouped[0].category == vpcColour
    check grouped[0].entries.len == 2
    check grouped[0].entries[0].key == "color/surface"
    check grouped[0].entries[1].key == "color/accent"
    check grouped[1].category == vpcSpacing
    check grouped[1].entries.len == 1
    check grouped[2].category == vpcRadius
    check grouped[2].entries.len == 1

  test "toggleCategoryExpansion flips per-category state":
    createRoot do (dispose: proc()):
      let state = createVariablePickerState()
      check state.expandedCategories.val.getOrDefault(vpcColour) == true
      state.toggleCategoryExpansion(vpcColour)
      check state.expandedCategories.val.getOrDefault(vpcColour) == false
      state.toggleCategoryExpansion(vpcColour)
      check state.expandedCategories.val.getOrDefault(vpcColour) == true
      dispose()

  test "openVariablePickerWithRect seeds state":
    createRoot do (dispose: proc()):
      let state = createVariablePickerState()
      state.searchText.val = "stale"
      let key = TargetKey
      openVariablePickerWithRect(state, key, 100.0, 200.0, 24.0, 26.0)
      check state.open.val == true
      check state.anchorRect.val == (100.0, 200.0, 24.0, 26.0)
      check state.searchText.val == ""
      check state.targetPropertyKey.val.elementId == "frame-1"
      check state.targetPropertyKey.val.propertyName == "background-color"
      dispose()

# --------------------------------------------------------------------------- #
#  Mount tests
# --------------------------------------------------------------------------- #

suite "Phase E.3 variable_picker mount":

  test "mounted popover lists every available variable per category":
    createRoot do (dispose: proc()):
      let vm = createEditorVM()
      seedTokens(vm)
      let state = createVariablePickerState()
      let (r, root) = mkRoot()
      discard r.mountVariablePicker(root, vm, state)

      openVariablePickerWithRect(state, TargetKey, 0, 0, 0, 0)

      let picker = findByAttr(root, "data-variable-picker", "true")
      check picker != nil
      check picker.attributes.getOrDefault(
        "data-variable-picker-open") == "true"

      let rows = collectByAttr(picker, "data-variable-picker-row")
      check rows.len == 4
      check rows[0].attributes["data-variable-picker-row"] ==
        "color/surface"
      check rows[1].attributes["data-variable-picker-row"] ==
        "color/accent"

      # Three categories are visible (Colour, Spacing, Radius).
      let categories = collectByAttr(picker,
        "data-variable-picker-category")
      check categories.len == 3
      check categories[0].attributes["data-variable-picker-category"] ==
        "colour"

      # Usage badge surfaces the affectedStories count.
      let usage = findByAttr(picker, "data-variable-picker-row-usage", "2")
      check usage != nil
      dispose()

  test "typing into the search input filters visible rows":
    createRoot do (dispose: proc()):
      let vm = createEditorVM()
      seedTokens(vm)
      let state = createVariablePickerState()
      let (r, root) = mkRoot()
      discard r.mountVariablePicker(root, vm, state)
      openVariablePickerWithRect(state, TargetKey, 0, 0, 0, 0)

      let picker = findByAttr(root, "data-variable-picker", "true")
      check picker != nil

      let search = findByAttr(root, "data-variable-picker-search", "true")
      check search != nil
      r.setInputValue(search, "spacing")
      fireEvent(search, "input")

      let rows = collectByAttr(picker, "data-variable-picker-row")
      check rows.len == 1
      check rows[0].attributes["data-variable-picker-row"] ==
        "spacing/4"
      dispose()

  test "clicking a row binds the target property and closes the picker":
    createRoot do (dispose: proc()):
      let vm = createEditorVM()
      seedTokens(vm)
      let state = createVariablePickerState()
      let (r, root) = mkRoot()
      discard r.mountVariablePicker(root, vm, state)
      openVariablePickerWithRect(state, TargetKey, 0, 0, 0, 0)

      let picker = findByAttr(root, "data-variable-picker", "true")
      check picker != nil

      let surfaceRow = findByAttr(picker,
        "data-variable-picker-row", "color/surface")
      check surfaceRow != nil
      fireEvent(surfaceRow, "click")

      check state.open.val == false
      let binding = vm.propertyBindingFor(TargetKey)
      check binding.isSome
      check binding.get.variableKey == "color/surface"
      check binding.get.resolvedValue == "#0F172A"
      check binding.get.state == vbsBound
      dispose()

  test "clicking 'Edit this variable' invokes onVariableEdit":
    createRoot do (dispose: proc()):
      let vm = createEditorVM()
      seedTokens(vm)
      let state = createVariablePickerState()
      var lastEditedKey = ""
      state.onVariableEdit.val = proc(variableKey: string) =
        lastEditedKey = variableKey
      let (r, root) = mkRoot()
      discard r.mountVariablePicker(root, vm, state)
      openVariablePickerWithRect(state, TargetKey, 0, 0, 0, 0)

      let picker = findByAttr(root, "data-variable-picker", "true")
      check picker != nil

      let editButtons = collectByAttr(picker,
        "data-variable-picker-row-edit")
      check editButtons.len == 4
      fireEvent(editButtons[1], "click")
      check lastEditedKey == "color/accent"
      dispose()

  test "empty token set renders the empty-state row":
    createRoot do (dispose: proc()):
      let vm = createEditorVM()
      let state = createVariablePickerState()
      let (r, root) = mkRoot()
      discard r.mountVariablePicker(root, vm, state)
      openVariablePickerWithRect(state, TargetKey, 0, 0, 0, 0)

      let empty = findByAttr(root, "data-variable-picker-empty", "true")
      check empty != nil
      check textContent(empty) == "No matching variables"
      dispose()

  test "closing the picker hides the popover and resets open flag":
    createRoot do (dispose: proc()):
      let vm = createEditorVM()
      seedTokens(vm)
      let state = createVariablePickerState()
      let (r, root) = mkRoot()
      discard r.mountVariablePicker(root, vm, state)
      openVariablePickerWithRect(state, TargetKey, 0, 0, 0, 0)

      let picker = findByAttr(root, "data-variable-picker", "true")
      check picker != nil

      let closeBtn = findByAttr(root, "data-variable-picker-close", "true")
      check closeBtn != nil
      fireEvent(closeBtn, "click")
      check state.open.val == false
      check picker.attributes.getOrDefault(
        "data-variable-picker-open") == "false"
      dispose()

# --------------------------------------------------------------------------- #
#  Phase E.4 — variable_inline_editor coverage
# --------------------------------------------------------------------------- #

suite "Phase E.4 variable_inline_editor":

  test "createVariableInlineEditorState defaults":
    createRoot do (dispose: proc()):
      let state = createVariableInlineEditorState()
      check state.open.val == false
      check state.targetVariableKey.val == ""
      check state.draftName.val == ""
      check state.draftValue.val == ""
      check state.applyAllModes.val == false
      check state.diagnostic.val == ""
      dispose()

  test "openVariableInlineEditorWithRect seeds the draft from foundations":
    createRoot do (dispose: proc()):
      let vm = createEditorVM()
      seedTokens(vm)
      let state = createVariableInlineEditorState()
      openVariableInlineEditorWithRect(vm, state, "color/surface",
        50.0, 80.0, 240.0, 32.0)
      check state.open.val == true
      check state.targetVariableKey.val == "color/surface"
      check state.draftName.val == "color/surface"
      check state.draftValue.val == "#0F172A"
      check state.applyAllModes.val == true
      check state.anchorRect.val == (50.0, 80.0, 240.0, 32.0)
      dispose()

  test "mount renders heading + name + value + apply-all + buttons":
    createRoot do (dispose: proc()):
      let vm = createEditorVM()
      seedTokens(vm)
      let state = createVariableInlineEditorState()
      let (r, root) = mkRoot()
      discard r.mountVariableInlineEditor(root, vm, state)
      openVariableInlineEditorWithRect(vm, state, "color/surface",
        0, 0, 0, 0)

      let editor = findByAttr(root, "data-variable-inline-editor", "true")
      check editor != nil
      check editor.attributes.getOrDefault(
        "data-variable-inline-editor-open") == "true"

      let heading = findByAttr(root,
        "data-variable-inline-editor-heading", "true")
      check heading != nil
      check textContent(heading).contains("color/surface")
      check textContent(heading).contains("used in")

      let nameInput = findByAttr(root,
        "data-variable-inline-editor-name", "true")
      check nameInput != nil
      check r.inputValue(nameInput) == "color/surface"

      let valueInput = findByAttr(root,
        "data-variable-inline-editor-value", "true")
      check valueInput != nil
      check r.inputValue(valueInput) == "#0F172A"

      let applyAll = findByAttr(root,
        "data-variable-inline-editor-apply-all", "true")
      check applyAll != nil
      check applyAll.attributes.getOrDefault("checked") == "true"

      let saveBtn = findByAttr(root,
        "data-variable-inline-editor-save", "true")
      check saveBtn != nil
      let cancelBtn = findByAttr(root,
        "data-variable-inline-editor-cancel", "true")
      check cancelBtn != nil
      dispose()

  test "commitInlineEdit propagates through foundations.tokens":
    createRoot do (dispose: proc()):
      let vm = createEditorVM()
      seedTokens(vm)
      let state = createVariableInlineEditorState()
      openVariableInlineEditorWithRect(vm, state, "color/surface",
        0, 0, 0, 0)
      state.draftValue.val = "#10182B"
      let result = commitInlineEdit(vm, state)
      check result.status == pesAccepted
      check state.open.val == false
      check state.diagnostic.val == ""
      check vm.resolveVariableValue("color/surface") == "#10182B"
      dispose()

  test "commitInlineEdit rejects an unknown variable":
    createRoot do (dispose: proc()):
      let vm = createEditorVM()
      seedTokens(vm)
      let state = createVariableInlineEditorState()
      openVariableInlineEditorWithRect(vm, state, "does/not/exist",
        0, 0, 0, 0)
      state.draftValue.val = "#10182B"
      let result = commitInlineEdit(vm, state)
      check result.status == pesRejected
      check state.open.val == true
      check state.diagnostic.val.len > 0
      dispose()

  test "mount surfaces high-usage warning above the threshold":
    createRoot do (dispose: proc()):
      let vm = createEditorVM()
      var heavy: seq[StoryRef] = @[]
      for i in 0 ..< 60:
        heavy.add StoryRef(group: "Group", name: $i, kind: skComponent)
      vm.foundations.tokens.val = @[
        FoundationTokenEntry(key: "color/heavy", kind: ftkSemanticColor,
          value: "#FFFFFF", affectedStories: heavy)]
      let state = createVariableInlineEditorState()
      let (r, root) = mkRoot()
      discard r.mountVariableInlineEditor(root, vm, state)
      openVariableInlineEditorWithRect(vm, state, "color/heavy",
        0, 0, 0, 0)

      let warning = findByAttr(root,
        "data-variable-inline-editor-warning", "true")
      check warning != nil
      check warning.styles.getOrDefault("display") == "block"
      check textContent(warning).contains("60 components")
      check textContent(warning).contains("Cmd+Z")
      dispose()

  test "picker → inline-editor bridge through onVariableEdit":
    createRoot do (dispose: proc()):
      let vm = createEditorVM()
      seedTokens(vm)
      let pickerState = createVariablePickerState()
      let inlineState = createVariableInlineEditorState()
      pickerState.onVariableEdit.val =
        proc(variableKey: string) {.closure.} =
          let rect = pickerState.anchorRect.val
          openVariableInlineEditorWithRect(vm, inlineState,
            variableKey, rect.x, rect.y, rect.w, rect.h)
      let (r, root) = mkRoot()
      discard r.mountVariablePicker(root, vm, pickerState)
      discard r.mountVariableInlineEditor(root, vm, inlineState)

      openVariablePickerWithRect(pickerState, TargetKey,
        100.0, 200.0, 24.0, 26.0)

      let picker = findByAttr(root, "data-variable-picker", "true")
      check picker != nil
      let editButtons = collectByAttr(picker,
        "data-variable-picker-row-edit")
      check editButtons.len == 4
      fireEvent(editButtons[0], "click")

      check inlineState.open.val == true
      check inlineState.targetVariableKey.val == "color/surface"
      check inlineState.anchorRect.val == (100.0, 200.0, 24.0, 26.0)
      dispose()
