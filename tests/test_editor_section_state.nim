## MockRenderer checks portable State row admission, change-handler lifetime
## and selected-property preservation only. Synthetic transactions check preview
## request scope routing; none of these prove browser CSS or source/compiler output. Synthetic retained inline metadata isolates the native
## read-only guard when authoredValue is already present; it does not establish
## real State provenance or source/compiler success. The remaining GUI suite
## compiles genuine DSL inline provenance and checks actual source refusal.
## Phase G — section_state widget unit test.

import std/[options, strutils, tables, unittest]

import isonim/core/[signals, computation, owner]
import isonim/editor/types
import isonim/editor/viewmodels
import isonim/editor/views/widgets/section_state
import isonim/editor/views/widgets/property_commit
import isonim/testing/mock_dom

proc findByAttr(node: MockNode; attr, value: string): MockNode =
  if node == nil: return nil
  if node.kind == mnkElement and node.attributes.getOrDefault(attr) == value:
    return node
  for c in node.children:
    let hit = findByAttr(c, attr, value)
    if hit != nil: return hit
  return nil

suite "Phase G section_state":

  test "renders empty-state when no reactive properties present":
    createRoot do (dispose: proc()):
      let r = MockRenderer()
      let root = r.createElement("div")
      let vm = createEditorVM()
      mountSectionState[MockRenderer, MockNode](r, root, vm)

      check findByAttr(root, "data-state-section-body", "true") != nil
      let empty = findByAttr(root, "data-state-empty", "true")
      check empty != nil
      check empty.styles.getOrDefault("display") == "block"
      dispose()

  test "isReactiveStateProperty flags setStyle origin + signal: marker":
    check isReactiveStateProperty(PropertyInfo(name: "color",
      value: "#fff", origin: poSetStyle))
    check isReactiveStateProperty(PropertyInfo(name: "value",
      value: "1", origin: poInherited, originDetail: "signal:counter"))
    check not isReactiveStateProperty(PropertyInfo(name: "color",
      value: "#fff", origin: poTailwindClass))

  test "reactive properties populate the row list":
    createRoot do (dispose: proc()):
      let r = MockRenderer()
      let root = r.createElement("div")
      let vm = createEditorVM()
      mountSectionState[MockRenderer, MockNode](r, root, vm)

      vm.inspector.selectedElement.val = ElementRef(tag: "div",
        properties: @[
          PropertyInfo(name: "count", value: "3",
            origin: poInherited, originDetail: "signal:count"),
          PropertyInfo(name: "padding", value: "16px")])
      check findByAttr(root, "data-property-row", "count") != nil
      check findByAttr(root, "data-property-row", "padding") == nil
      let empty = findByAttr(root, "data-state-empty", "true")
      check empty.styles.getOrDefault("display") == "none"
      dispose()

  test "native inline State stays readonly with retained authored value":
    createRoot do (dispose: proc()):
      let r = MockRenderer()
      let root = r.createElement("div")
      let vm = createEditorVM()
      vm.workspacePermissions.val = EditorWorkspacePermissions(readSource: true, writeSource: true)
      vm.hasAsyncSourceProject = true
      vm.sourceAdapterReady.val = true
      vm.inspector.selectedElement.val = ElementRef(id: "state", tag: "p",
        properties: @[PropertyInfo(name: "width", value: "44px",
          authoredValue: "44px", origin: poSetStyle,
          originDetail: "style-attr:width")])
      let original = vm.inspector.selectedElement.val
      let wiring = vm.inspectorRowWiring("width")
      check wiring.authoredValue() == "44px"
      check wiring.readOnlyReason().len > 0
      let prop = PropertyInfo(name: "width", value: "44px",
        authoredValue: "44px", origin: poSetStyle,
        sourceFile: "stories.nim", sourceLine: 12,
        directStyleAllowed: true)
      let generic = sourceScopeChoices(vm.designSystemSchema.val, original, prop)
      require generic.len > 0
      check generic[0].editable
      let native = vm.sourceScopeChoices(prop)
      check native.len == generic.len
      for i, choice in native:
        check not choice.editable
        check choice.sourceFile == generic[i].sourceFile
        check choice.sourceLine == generic[i].sourceLine
        check choice.schemaKey == generic[i].schemaKey
        check choice.reason.contains("inline")
      vm.hasAsyncSourceProject = false
      check vm.sourceScopeChoices(prop) == generic
      vm.hasAsyncSourceProject = true
      var owned = prop
      owned.origin = poTailwindClass
      check vm.sourceScopeChoices(owned) == sourceScopeChoices(
        vm.designSystemSchema.val, original, owned)
      mountSectionState[MockRenderer, MockNode](r, root, vm)
      let row = findByAttr(root, "data-property-row", "width")
      require row != nil
      check row.attributes.getOrDefault("data-property-row-readonly") == "true"
      check vm.inspector.selectedElement.val == original
      check vm.inspector.undoStack.val.len == 0
      dispose()

  test "preview undo redo requests preserve declaration source scope":
    # This headless transaction test checks request routing only. The real
    # compiled GUI verifies inline/cascade/priority/replay and physical edits.
    createRoot do (dispose: proc()):
      let vm = createEditorVM()
      let before = ElementRef(id: "actual", tag: "p", domPath: "#actual",
        properties: @[PropertyInfo(name: "width", value: "44px", origin: poSetStyle)])
      var after = before
      after.properties = @[PropertyInfo(name: "width", value: "48px", origin: poSetStyle)]
      for scope in [sskLocalInstance, sskSharedClass, sskSemanticToken]:
        vm.inspector.undoStack.val = @[CSSPropertyEditTransaction(
          beforeElement: before, afterElement: after,
          sourceEdit: SourceEditPlan(property: "width", oldValue: "44px",
            newValue: "48px", sourceScope: scope))]
        vm.inspector.redoStack.val = @[]
        let generation = vm.inspector.previewValueRequest.val.generation
        check vm.inspector.undoCssPropertyEdit()
        let undo = vm.inspector.previewValueRequest.val
        check undo.sourceScope == scope
        check undo.property == "width"
        check undo.value == "44px"
        check undo.domPath == "#actual"
        check undo.generation == generation + 1
        check vm.inspector.redoCssPropertyEdit()
        let redo = vm.inspector.previewValueRequest.val
        check redo.sourceScope == scope
        check redo.value == "48px"
        check redo.generation == generation + 2
      dispose()

  test "catalog-only State text commit reaches writer before list replacement":
    # MockRenderer exposes the portable change handler and transaction boundary;
    # real compiled GUI proves natural Enter/blur, focus, actual CSS and files.
    createRoot do (dispose: proc()):
      let r = MockRenderer()
      let root = r.createElement("div")
      let vm = createEditorVM()
      vm.workspacePermissions.val = EditorWorkspacePermissions(readSource: true, writeSource: true)
      vm.sourceAdapterReady.val = true
      vm.inspector.selectedElement.val = ElementRef(id: "state", tag: "p",
        sourceFile: "stories.nim", sourceLine: 1,
        properties: @[PropertyInfo(name: "width", value: "44px",
          origin: poSetStyle, originDetail: "style-attr:width",
          directStyleAllowed: true)])
      mountSectionState[MockRenderer, MockNode](r, root, vm)
      let input = findByAttr(root, "data-property-row-input", "true")
      require input != nil
      r.setInputValue(input, "48px")
      input.fireEvent("change")
      check vm.inspector.undoStack.val.len == 1
      check vm.inspector.selectedElement.val.properties[0].value == "48px"
      check r.inputValue(findByAttr(root, "data-property-row-input", "true")) == "48px"
      dispose()

  test "State focus target cannot carry focus across story or selection identity":
    # Portable guard for the actual DOM restoration predicate; the GUI proves
    # same-target usable focus and natural keyboard continuation.
    let story = StoryRef(group: "Card", name: "Ready", kind: skComponent)
    let element = ElementRef(id: "state", domPath: "#state")
    let target = stateFocusTarget(story, element)
    check target == stateFocusTarget(story, element)
    for other in [StoryRef(group: "Other", name: "Ready", kind: skComponent),
        StoryRef(group: "Card", name: "Other", kind: skComponent),
        StoryRef(group: "Card", name: "Ready", kind: skPage)]:
      check target != stateFocusTarget(other, element)
    check target != stateFocusTarget(story, ElementRef(id: "other", domPath: "#state"))
    check target != stateFocusTarget(story, ElementRef(id: "state", domPath: "#other"))
    check stateFocusTarget(StoryRef(group: "a / b", name: "c"), element) !=
      stateFocusTarget(StoryRef(group: "a", name: "b / c"), element)
    check stateFocusTarget(story, ElementRef(id: "p|q", domPath: "r")) !=
      stateFocusTarget(story, ElementRef(id: "p", domPath: "q|r"))
