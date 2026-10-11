## Phase G — section_appearance widget unit test.
## MockRenderer isolates section/control reactive ownership and submission
## cardinality; captured submissions do not simulate persistence. Real source,
## compiler, preview and pointer gestures are covered by the mounted source suites.

import std/[options, tables, unittest]

import isonim/core/[signals, computation, owner]
import isonim/editor/types
import isonim/editor/viewmodels
import isonim/editor/views/widgets/section_appearance
import isonim/testing/mock_dom

proc findByAttr(node: MockNode; attr, value: string): MockNode =
  if node == nil: return nil
  if node.kind == mnkElement and node.attributes.getOrDefault(attr) == value:
    return node
  for c in node.children:
    let hit = findByAttr(c, attr, value)
    if hit != nil: return hit
  return nil

suite "Phase G section_appearance":

  test "mounts opacity / radius / blend mode / per-corner":
    createRoot do (dispose: proc()):
      let r = MockRenderer()
      let root = r.createElement("div")
      let vm = createEditorVM()
      mountSectionAppearance[MockRenderer, MockNode](r, root, vm)

      check findByAttr(root, "data-property-row", "opacity") != nil
      check findByAttr(root, "data-property-row", "corner-radius") != nil
      check findByAttr(root, "data-property-row", "blend-mode") != nil
      check findByAttr(root, "data-property-row", "per-corner") != nil
      check findByAttr(root, "data-appearance-percorner-host", "true") != nil
      dispose()

  test "per-corner host hides until the toggle is on":
    createRoot do (dispose: proc()):
      let r = MockRenderer()
      let root = r.createElement("div")
      let vm = createEditorVM()
      mountSectionAppearance[MockRenderer, MockNode](r, root, vm)

      let host = findByAttr(root, "data-appearance-percorner-host", "true")
      check host != nil
      check host.styles.getOrDefault("display") == "none"

      let toggle = findByAttr(findByAttr(root, "data-property-row",
        "per-corner"), "data-property-row-input", "true")
      check toggle != nil
      fireEvent(toggle, "click")
      check host.styles.getOrDefault("display") == "flex"
      dispose()

  test "opacity seed converts CSS 0..1 to UI 0..100":
    createRoot do (dispose: proc()):
      let r = MockRenderer()
      let root = r.createElement("div")
      let vm = createEditorVM()
      vm.inspector.selectedElement.val = ElementRef(tag: "div",
        properties: @[PropertyInfo(name: "opacity", value: "0.5")])
      mountSectionAppearance[MockRenderer, MockNode](r, root, vm)

      let opacityInput = findByAttr(findByAttr(root, "data-property-row",
        "opacity"), "data-property-row-input", "true")
      check opacityInput != nil
      check r.inputValue(opacityInput) == "50"
      dispose()

  test "radius source seeding does not overwrite a typed or scrubbed draft":
    createRoot do (dispose: proc()):
      let r = MockRenderer()
      let root = r.createElement("div")
      let vm = createEditorVM()
      var permissions = vm.workspacePermissions.val
      permissions.writeSource = true
      vm.workspacePermissions.val = permissions
      vm.inspector.selectedElement.val = ElementRef(id: "panel", tag: "div",
        properties: @[PropertyInfo(name: "border-radius", value: "4px",
          authoredValue: "4px", directStyleAllowed: true)])
      var submitted: seq[string]
      vm.inspectorSourceCommit = proc(element: ElementRef; property, value: string;
          scope: SourceScopeChoiceKind; done: proc(ok: bool; diagnostic: string) {.closure.}) =
        submitted.add value
        done(true, "")
      mountSectionAppearance[MockRenderer, MockNode](r, root, vm)
      let row = findByAttr(root, "data-property-row", "corner-radius")
      let input = findByAttr(row, "data-property-row-input", "true")
      r.setInputValue(input, "5px")
      fireEvent(input, "change")
      check submitted == @["5px"]
      check r.inputValue(input) == "5"
      let handle = findByAttr(row, "data-property-row-slot", "label-scrubber")
      fireEventWith(handle, "mousedown", MockEvent(`type`: "mousedown", clientX: 0))
      fireEventWith(handle, "mousemove", MockEvent(`type`: "mousemove", clientX: 1))
      fireEventWith(handle, "mouseup", MockEvent(`type`: "mouseup", clientX: 1))
      check submitted == @["5px", "7px"]
      check r.inputValue(input) == "7"
      dispose()

  test "authored percentage and exponent opacity remain percent in the control":
    for (authored, expected) in [("80%", "80"), ("1e-1", "10"), ("0.25", "25")]:
      createRoot do (dispose: proc()):
        let r = MockRenderer()
        let root = r.createElement("div")
        let vm = createEditorVM()
        vm.inspector.selectedElement.val = ElementRef(id: "panel", properties: @[
          PropertyInfo(name: "opacity", value: "0.9", authoredValue: authored)])
        mountSectionAppearance[MockRenderer, MockNode](r, root, vm)
        let input = findByAttr(findByAttr(root, "data-property-row", "opacity"), "data-property-row-input", "true")
        check r.inputValue(input) == expected
        dispose()

  test "each corner retains independent authored units instead of computed pixels":
    createRoot do (dispose: proc()):
      let r = MockRenderer()
      let root = r.createElement("div")
      let vm = createEditorVM()
      vm.inspector.selectedElement.val = ElementRef(id: "panel", properties: @[
        PropertyInfo(name: "border-top-left-radius", value: "32px", authoredValue: "2em"),
        PropertyInfo(name: "border-top-right-radius", value: "8px", authoredValue: "8px"),
        PropertyInfo(name: "border-bottom-right-radius", value: "10px", authoredValue: "10%"),
        PropertyInfo(name: "border-bottom-left-radius", value: "16px", authoredValue: "1rem")])
      mountSectionAppearance[MockRenderer, MockNode](r, root, vm)
      for (name, value, unit) in [("tl", "2", "em"), ("tr", "8", "px"), ("br", "10", "%"), ("bl", "1", "rem")]:
        let row = findByAttr(root, "data-property-row", name)
        check r.inputValue(findByAttr(row, "data-property-row-input", "true")) == value
        check textContent(findByAttr(row, "data-property-row-unit", "true")) == unit
      dispose()

  test "authored fractional opacity projection retains precision without blur submission":
    for (authored,expected) in [("0.800125","80.0125"),("0.125125","12.5125"),("12.5125%","12.5125"),("0.07","7"),("0.29","29"),("0.58","58"),("0.07000000000000002","7.000000000000002"),("7.000000000000001%","7.000000000000001"),("1e-20%","1e-20"),("12.5125123456789%","12.5125123456789")]:
      createRoot do (dispose: proc()):
        let r = MockRenderer()
        let root = r.createElement("div")
        let vm = createEditorVM()
        vm.workspacePermissions.val = EditorWorkspacePermissions(readSource:true,writeSource:true)
        vm.inspector.selectedElement.val = ElementRef(id:"precise-opacity",properties: @[
          PropertyInfo(name:"opacity",value:authored,authoredValue:authored,directStyleAllowed:true)])
        var submitted: seq[string]
        vm.inspectorSourceCommit = proc(element: ElementRef; property,value: string;
            scope: SourceScopeChoiceKind; done: proc(ok: bool; diagnostic: string)) =
          submitted.add value
          done(false,"admission-only refusal")
        mountSectionAppearance[MockRenderer,MockNode](r,root,vm)
        let input = findByAttr(findByAttr(root,"data-property-row","opacity"),"data-property-row-input","true")
        check r.inputValue(input) == expected
        fireEvent(input,"blur")
        check submitted.len == 0
        r.setInputValue(input,"80.0126%")
        fireEvent(input,"change")
        check submitted == @["80.0126%"]
        check r.inputValue(input) == expected
        dispose()
