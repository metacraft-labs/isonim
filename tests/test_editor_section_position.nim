## MockRenderer isolates property/control seeding; it supplies no source/compiler
## outcome. A recording callback below is an admission-only spy for the full
## serialized transform; it cannot prove browser keys, source writes or undo.
## Genuine mounted keyboard/pointer/compiler/history persistence is covered by
## the existing source/gesture GUI owning suites.
## Phase G — section_position widget unit test.
##
## Verifies:
##   1. The section body mounts X / Y / Rotation property rows with
##      the expected ``data-property-row`` slugs.
##   2. The alignment + flip control rows render the data attributes
##      the visual review pipeline pins.
##   3. The empty-state placeholder visibility tracks
##      ``vm.inspector.hasElement``.

import std/[options, tables, unittest, math]

import isonim/core/[signals, computation, owner]
import isonim/editor/types
import isonim/editor/viewmodels
import isonim/editor/source_style_values
import isonim/editor/views/widgets/section_position
import isonim/testing/mock_dom

proc findByAttr(node: MockNode; attr, value: string): MockNode =
  if node == nil: return nil
  if node.kind == mnkElement and node.attributes.getOrDefault(attr) == value:
    return node
  for c in node.children:
    let hit = findByAttr(c, attr, value)
    if hit != nil: return hit
  return nil

suite "Phase G section_position":

  test "section_position mounts X / Y / Rotation property rows":
    createRoot do (dispose: proc()):
      let r = MockRenderer()
      let root = r.createElement("div")
      let vm = createEditorVM()
      mountSectionPosition[MockRenderer, MockNode](r, root, vm)

      check findByAttr(root, "data-property-row", "x") != nil
      check findByAttr(root, "data-property-row", "y") != nil
      check findByAttr(root, "data-property-row", "rotation") != nil
      check findByAttr(root, "data-position-alignment-row", "true") != nil
      check findByAttr(root, "data-position-flip-row", "true") != nil
      dispose()

  test "alignment row carries horizontal + vertical + distribute clusters":
    createRoot do (dispose: proc()):
      let r = MockRenderer()
      let root = r.createElement("div")
      let vm = createEditorVM()
      mountSectionPosition[MockRenderer, MockNode](r, root, vm)

      check findByAttr(root, "data-position-alignment-cluster",
        "horizontal") != nil
      check findByAttr(root, "data-position-alignment-cluster",
        "vertical") != nil
      check findByAttr(root, "data-position-alignment-cluster",
        "distribute") != nil
      check findByAttr(root, "data-position-distribute", "spacing") != nil
      for slug in ["left", "center", "right"]:
        check findByAttr(root, "data-position-align", slug) != nil
      for slug in ["top", "middle", "bottom"]:
        check findByAttr(root, "data-position-valign", slug) != nil
      for slug in ["horizontal", "vertical"]:
        check findByAttr(root, "data-position-flip", slug) != nil
      dispose()

  test "empty-state hides when an element is selected":
    createRoot do (dispose: proc()):
      let r = MockRenderer()
      let root = r.createElement("div")
      let vm = createEditorVM()
      mountSectionPosition[MockRenderer, MockNode](r, root, vm)

      let empty = findByAttr(root, "data-position-empty", "true")
      check empty != nil
      check empty.attributes.getOrDefault("data-position-empty-visible") ==
        "true"

      vm.inspector.selectedElement.val = ElementRef(tag: "div",
        properties: @[
          PropertyInfo(name: "left", value: "24px"),
          PropertyInfo(name: "top", value: "12px")])
      check empty.attributes.getOrDefault("data-position-empty-visible") ==
        "false"
      dispose()

  test "X / Y seed values reflect the current selection":
    createRoot do (dispose: proc()):
      let r = MockRenderer()
      let root = r.createElement("div")
      let vm = createEditorVM()
      vm.inspector.selectedElement.val = ElementRef(tag: "div",
        properties: @[
          PropertyInfo(name: "left", value: "48px"),
          PropertyInfo(name: "top", value: "32px")])
      mountSectionPosition[MockRenderer, MockNode](r, root, vm)

      let xInput = findByAttr(findByAttr(root, "data-property-row", "x"),
        "data-property-row-input", "true")
      check xInput != nil
      check r.inputValue(xInput) == "48"

      let yInput = findByAttr(findByAttr(root, "data-property-row", "y"),
        "data-property-row-input", "true")
      check yInput != nil
      check r.inputValue(yInput) == "32"
      dispose()

  test "leading authored exponents seed finite coordinates and reject nonfinite values":
    check parseLeadingFloat("1e-1em", 9) == 0.1
    check parseLeadingFloat("-2.5e2px", 9) == -250
    check parseLeadingFloat("1em", 9) == 1
    check parseLeadingFloat("1e309px", 9) == 9
    check parseLeadingFloat("NaN", 9) == 9
    check parseLeadingFloat("rotate(20deg)", 9) == 9


suite "Rotation literal source adapter":
  test "literal angles retain units and preserve exact 2D sibling text":
    let source = "translate(8px, 12px)  rotate(0.25turn) scale(1.5)"
    let rotation = rotationLiteral(source)
    check rotation.supported
    check rotation.value == 0.25
    check rotation.unit == "turn"
    check rotation.degrees == 90
    check patchRotationLiteral(source,"90deg") == source
    check patchRotationLiteral(source,"0.5turn") == "translate(8px, 12px)  rotate(0.5turn) scale(1.5)"
    check patchRotationLiteral("translateX(8px) scale(2)","0deg") == "translateX(8px) scale(2)"
    check patchRotationLiteral("translateX(8px) scale(2)","45deg") == "translateX(8px) scale(2) rotate(45deg)"
    check patchRotationLiteral("none","0deg") == "none"
    check patchRotationLiteral("none","45deg") == "rotate(45deg)"
    check rotationAngle("200grad").degrees == 180
    check abs(rotationAngle("3.141592653589793rad").degrees - 180) < 1e-12

  test "ambiguous dynamic 3D matrix invalid and nonfinite forms refuse destructive editing":
    for source in ["rotate(10deg) rotate(20deg)","matrix(1,0,0,1,0,0)","rotateX(10deg)",
        "translateZ(1px)","rotate(var(--angle))","rotate(calc(10deg + 1deg))",
        "rotate(infdeg)","rotate(1e999deg)","rotate(10px)","scale(bogus)","translate(1px,,2px)"]:
      check not rotationLiteral(source).supported
      check rotationLiteral(source).reason.len > 0
      check patchRotationLiteral(source,"45deg") == ""

  test "numeric row reads authored angle and submits whole transform while unsupported selection is readonly":
    createRoot do (dispose: proc()):
      let r = MockRenderer()
      let root = r.createElement("div")
      let vm = createEditorVM()
      var received: seq[string]
      vm.workspacePermissions.val = EditorWorkspacePermissions(readSource:true,writeSource:true)
      vm.inspector.selectedElement.val = ElementRef(id:"rotation-owner", properties: @[
        PropertyInfo(name:"transform",value:"rotate(20deg)",authoredValue:"translateX(8px) rotate(20deg) scale(2)",directStyleAllowed:true)])
      vm.inspectorSourceCommit = proc(element: ElementRef; property,value: string;
          scope: SourceScopeChoiceKind; done: proc(ok: bool; diagnostic: string)) =
        check property == "transform"
        received.add value
        done(true, "")
      mountSectionPosition[MockRenderer,MockNode](r,root,vm)
      let row = findByAttr(root,"data-property-row","rotation")
      let input = findByAttr(row,"data-property-row-input","true")
      check r.inputValue(input) == "20"
      setInputValue(r,input,"2^3deg")
      fireEvent(input,"change")
      check received == @["translateX(8px) rotate(8deg) scale(2)"]
      vm.inspector.selectedElement.val = ElementRef(id:"opaque-owner",properties: @[
        PropertyInfo(name:"transform",value:"matrix(1,0,0,1,0,0)",authoredValue:"matrix(1,0,0,1,0,0)",directStyleAllowed:true)])
      let opaqueRow = findByAttr(root,"data-property-row","rotation")
      let opaqueInput = findByAttr(opaqueRow,"data-property-row-input","true")
      check r.inputValue(opaqueInput) == "matrix(1,0,0,1,0,0)"
      check opaqueRow.attributes.getOrDefault("data-property-row-readonly") == "true"
      check findByAttr(opaqueRow,"data-property-row-message","true").textContent.len > 0
      setInputValue(r,opaqueInput,"45deg")
      fireEvent(opaqueInput,"change")
      check received.len == 1
      dispose()
