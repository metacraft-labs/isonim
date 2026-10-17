## MockRenderer checks portable control refusal and unchanged selected properties;
## it does not claim browser, filesystem or compiler persistence. The mounted
## inspector compound suite covers those real boundaries and physical input.
## The recording inspectorSourceCommit callback is an admission-only spy that
## must receive zero calls for unsupported controls; it never proves persistence.
## Phase G — section_stroke widget unit test.

import std/[options, tables, unittest]

import isonim/core/[signals, computation, owner]
import isonim/editor/types
import isonim/editor/viewmodels
import isonim/editor/views/widgets/section_stroke
import isonim/testing/mock_dom

proc findByAttr(node: MockNode; attr, value: string): MockNode =
  if node == nil: return nil
  if node.kind == mnkElement and node.attributes.getOrDefault(attr) == value:
    return node
  for c in node.children:
    let hit = findByAttr(c, attr, value)
    if hit != nil: return hit
  return nil

suite "Phase G section_stroke":

  test "mounts color + width + style + position rows":
    createRoot do (dispose: proc()):
      let r = MockRenderer()
      let root = r.createElement("div")
      let vm = createEditorVM()
      mountSectionStroke[MockRenderer, MockNode](r, root, vm)

      check findByAttr(root, "data-property-row", "color") != nil
      check findByAttr(root, "data-property-row", "width") != nil
      check findByAttr(root, "data-property-row", "style") != nil
      check findByAttr(root, "data-property-row", "position") != nil
      check findByAttr(root, "data-stroke-dash-host", "true") != nil
      dispose()

  test "dash host hides when style is solid":
    createRoot do (dispose: proc()):
      let r = MockRenderer()
      let root = r.createElement("div")
      let vm = createEditorVM()
      mountSectionStroke[MockRenderer, MockNode](r, root, vm)

      let host = findByAttr(root, "data-stroke-dash-host", "true")
      check host != nil
      check host.styles.getOrDefault("display") == "none"
      dispose()

  test "unsupported stroke position and dash edits remain inspectable without local success":
    createRoot do (dispose: proc()):
      let r = MockRenderer()
      let root = r.createElement("div")
      let vm = createEditorVM()
      vm.inspector.selectedElement.val = ElementRef(id: "action", properties: @[
        PropertyInfo(name: "border-style", value: "dashed")])
      let original = vm.inspector.selectedElement.val
      var submissions = 0
      vm.inspectorSourceCommit = proc(element: ElementRef; property, value: string;
          scope: SourceScopeChoiceKind; done: proc(ok: bool; diagnostic: string) {.closure.}) =
        inc submissions
        done(true, "")
      mountSectionStroke[MockRenderer, MockNode](r, root, vm)
      let position = findByAttr(root, "data-property-row", "position")
      let inside = findByAttr(position, "data-choice-group-option", "0")
      require inside != nil
      fireEvent(inside, "click")
      check textContent(findByAttr(position, "data-choice-group-trigger-label", "true")) == "Center"
      check position.attributes.getOrDefault("data-property-row-readonly") == "true"
      check position.attributes.getOrDefault("data-property-row-readonly-reason").len > 0
      let positionMessage = findByAttr(position, "data-property-row-message", "true")
      require positionMessage != nil
      check positionMessage.styles.getOrDefault("display") == "block"
      check textContent(positionMessage) == "Stroke position cannot be edited in the inspector yet."
      let dash = findByAttr(root, "data-property-row", "dash-pattern")
      let input = findByAttr(dash, "data-property-row-input", "true")
      r.setInputValue(input, "4 8")
      fireEvent(input, "change")
      fireEvent(input, "blur")
      check r.inputValue(input) == ""
      check dash.attributes.getOrDefault("data-property-row-readonly") == "true"
      check input.attributes.hasKey("readonly")
      let dashMessage = findByAttr(dash, "data-property-row-message", "true")
      require dashMessage != nil
      check dashMessage.styles.getOrDefault("display") == "block"
      check textContent(dashMessage) == "Dash patterns cannot be edited in the inspector yet."
      check submissions == 0
      check vm.inspector.selectedElement.val == original
      check vm.inspector.undoStack.val.len == 0
      check vm.inspector.redoStack.val.len == 0
      dispose()
