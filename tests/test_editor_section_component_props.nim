## MockRenderer tests renderer-independent draft ownership and disposal. A
## recording completion callback isolates submission/lifetime without claiming
## filesystem or compiler persistence; the real mounted compound GUI tests
## those boundaries and captured pointer survival without replacing controls.
## Phase G — section_component_props widget unit test.

import std/[options, tables, unittest, strutils]

import isonim/core/[signals, computation, owner]
import isonim/editor/types
import isonim/editor/viewmodels
import isonim/editor/views/widgets/section_component_props
import isonim/testing/mock_dom

proc findByAttr(node: MockNode; attr, value: string): MockNode =
  if node == nil: return nil
  if node.kind == mnkElement and node.attributes.getOrDefault(attr) == value:
    return node
  for c in node.children:
    let hit = findByAttr(c, attr, value)
    if hit != nil: return hit
  return nil


proc domSelection(testId = ""; className = ""; declared = ""): ElementRef =
  # The real normalizer consumes the production preview payload format. Its
  # generated DOM identity is preserved, not erased to fake absence of schema.
  previewDomElementRef(StoryRenderMetadata(sourceFile:"stories.nim",sourceLine:1),
    tag="button",testId=testId,className=className,role="",elementPath="button",ancestry="",
    sourceFile="stories.nim",sourceLine=1,display="inline-flex",position="static",
    backgroundColor="rgb(17, 34, 51)",color="rgb(255, 255, 255)",padding="8px",
    margin="0px",width="120px",height="48px",borderRadius="4px",borderWidth="0px",
    borderStyle="none",borderColor="rgb(0, 0, 0)",fontSize="16px",fontWeight="400",
    lineHeight="normal",boxShadow="none",opacity="1",rectWidth="120",rectHeight="48",
    textContent="Continue",elementId="action",sourceKey="",schemaKey=declared,
    ancestorIds="",layerTreeJson="",computedStyles="padding-top=16px;flex-direction=row")

suite "Phase G section_component_props":

  test "ratio literals remain text and time fields admit milliseconds":
    createRoot do (dispose: proc()):
      let r = MockRenderer()
      let root = r.createElement("div")
      let vm = createEditorVM()
      var permissions = vm.workspacePermissions.val
      permissions.writeSource = true
      vm.workspacePermissions.val = permissions
      vm.inspector.selectedElement.val = ElementRef(id: "card", tag: "div",
        properties: @[
          PropertyInfo(name: "aspect-ratio", value: "4 / 3",
            schemaKey: "Card.ratio", directStyleAllowed: true),
          PropertyInfo(name: "transition-duration", value: "0s",
            schemaKey: "Card.duration", directStyleAllowed: true)])
      var requests: seq[string]
      vm.inspectorSourceCommit = proc(element: ElementRef; property, value: string;
          scope: SourceScopeChoiceKind; done: proc(ok: bool; diagnostic: string) {.closure.}) =
        requests.add property & ":" & value
        done(true, "")
      mountSectionComponentProps[MockRenderer, MockNode](r, root, vm)
      let ratio = findByAttr(root, "data-property-row-css-property", "aspect-ratio")
      require ratio != nil
      check ratio.attributes["data-property-row-kind"] == "text"
      let ratioInput = findByAttr(ratio, "data-property-row-input", "true")
      check r.inputValue(ratioInput) == "4 / 3"
      r.setInputValue(ratioInput, "16 / 9")
      ratioInput.fireEvent("change")
      check requests == @["aspect-ratio:16 / 9"]
      let duration = findByAttr(root, "data-property-row-css-property", "transition-duration")
      require duration != nil
      let durationInput = findByAttr(duration, "data-property-row-input", "true")
      r.setInputValue(durationInput, "180ms")
      durationInput.fireEvent("change")
      check requests == @["aspect-ratio:16 / 9", "transition-duration:180ms"]
      check r.inputValue(durationInput) == "180"
      dispose()

  test "mounts empty-state when selection is not a component instance":
    createRoot do (dispose: proc()):
      let r = MockRenderer()
      let root = r.createElement("div")
      let vm = createEditorVM()
      mountSectionComponentProps[MockRenderer, MockNode](r, root, vm)

      check findByAttr(root, "data-component-props-body", "true") != nil
      check findByAttr(root, "data-component-props-list", "true") != nil
      let empty = findByAttr(root, "data-component-props-empty", "true")
      check empty != nil
      check empty.styles.getOrDefault("display") == "block"

      vm.inspector.selectedElement.val = ElementRef(tag: "div",
        properties: @[
          PropertyInfo(name: "padding", value: "16px")])
      check empty.styles.getOrDefault("display") == "block"
      dispose()

  test "schema-backed properties populate the list":
    createRoot do (dispose: proc()):
      let r = MockRenderer()
      let root = r.createElement("div")
      let vm = createEditorVM()
      mountSectionComponentProps[MockRenderer, MockNode](r, root, vm)

      vm.inspector.selectedElement.val = ElementRef(tag: "div",
        schemaKey: "Button",
        properties: @[
          PropertyInfo(name: "variant", value: "primary",
            schemaKey: "Button.variant"),
          PropertyInfo(name: "size", value: "md",
            schemaKey: "Button.size"),
          PropertyInfo(name: "padding", value: "16px")])
      check findByAttr(root, "data-property-row", "variant") != nil
      check findByAttr(root, "data-property-row", "size") != nil
      # ``padding`` has no schemaKey — it should not appear.
      check findByAttr(root, "data-property-row", "padding") == nil
      let empty = findByAttr(root, "data-component-props-empty", "true")
      check empty.styles.getOrDefault("display") == "none"
      dispose()

  test "isComponentInstance flags any schema-bound property":
    let withSchema = ElementRef(tag: "div", properties: @[
      PropertyInfo(name: "label", value: "Save", schemaKey: "Btn.label")])
    check isComponentInstance(withSchema)
    let plain = ElementRef(tag: "div", properties: @[
      PropertyInfo(name: "padding", value: "0")])
    check not isComponentInstance(plain)

  test "native declaration identities do not fabricate component schemas":
    let shared = ElementRef(tag:"div",properties: @[
      PropertyInfo(name:"border-radius",value:"4px",schemaKey:"classes.native.rule",nativeSourceShared:true),
      PropertyInfo(name:"background-color",value:"#fff",schemaKey:"tokens.native.panel",nativeSourceToken:true)])
    check not isComponentInstance(shared)
    check not isComponentInstance(ElementRef(schemaKey:"classes.native.rule"))
    check isComponentInstance(ElementRef(schemaKey:"Button"))
    createRoot do (dispose:proc()):
      let r=MockRenderer()
      let root=r.createElement("div")
      let vm=createEditorVM()
      vm.inspector.selectedElement.val=shared
      mountSectionComponentProps[MockRenderer,MockNode](r,root,vm)
      check findByAttr(root,"data-property-row","border-radius") == nil
      check findByAttr(root,"data-property-row","background-color") == nil
      vm.inspector.selectedElement.val=ElementRef(schemaKey:"Button",properties: shared.properties & @[
        PropertyInfo(name:"variant",value:"primary",schemaKey:"Button.variant"),
        PropertyInfo(name:"padding-top",value:"2em",schemaKey:"Button.paddingTop")])
      check findByAttr(root,"data-property-row","variant") != nil
      check findByAttr(root,"data-property-row","padding-top") != nil
      check findByAttr(root,"data-property-row","border-radius") == nil
      check findByAttr(root,"data-property-row","background-color") == nil
      dispose()

  test "numeric drafts retain their row while story and schema replacement dispose callbacks":
    createRoot do (dispose:proc()):
      let r=MockRenderer()
      let root=r.createElement("div")
      let vm=createEditorVM()
      var permissions = vm.workspacePermissions.val
      permissions.writeSource = true
      vm.workspacePermissions.val = permissions
      vm.selectedStory.val=StoryRef(group:"Cards",name:"First",kind:skComponent)
      vm.inspector.selectedElement.val=ElementRef(id:"panel",tag:"div",properties: @[
        PropertyInfo(name:"padding-top",value:"4px",authoredValue:"4px",
          schemaKey:"Panel.padding",directStyleAllowed:true)])
      var requests:seq[string]
      vm.inspectorSourceCommit=proc(element:ElementRef;property,value:string;
          scope:SourceScopeChoiceKind;done:proc(ok:bool;diagnostic:string) {.closure.}) =
        requests.add value
        done(true,"")
      mountSectionComponentProps[MockRenderer,MockNode](r,root,vm)
      let initialObservers = vm.inspector.selectedElement.observers.len
      let original=findByAttr(root,"data-property-row-input","true")
      let handle=findByAttr(root,"data-property-row-field-label","true")
      r.setInputValue(original,"5px")
      fireEvent(original,"change")
      check findByAttr(root,"data-property-row-input","true") == original
      fireEventWith(handle,"mousedown",MockEvent(`type`:"mousedown",clientX:0))
      fireEventWith(handle,"mousemove",MockEvent(`type`:"mousemove",clientX:1))
      check findByAttr(root,"data-property-row-input","true") == original
      fireEventWith(handle,"mouseup",MockEvent(`type`:"mouseup",clientX:1))
      check requests == @["5px","7px"]
      for generation in 1 .. 4:
        vm.inspector.selectedElement.val=ElementRef(id:"panel",tag:"div",properties: @[
          PropertyInfo(name:"padding-top",value: $(generation + 7) & "px",
            authoredValue: $(generation + 7) & "px",schemaKey:"Panel.padding",directStyleAllowed:true)])
        check vm.inspector.selectedElement.observers.len == initialObservers
      vm.selectedStory.val=StoryRef(group:"Cards",name:"Second",kind:skComponent)
      let replacement=findByAttr(root,"data-property-row-input","true")
      check replacement != original
      r.setInputValue(original,"99px")
      fireEvent(original,"change")
      check requests == @["5px","7px"]
      vm.inspector.selectedElement.val=ElementRef(id:"other",tag:"div",properties: @[
        PropertyInfo(name:"width",value:"20px",schemaKey:"Other.width",directStyleAllowed:true)])
      check findByAttr(root,"data-property-row","width") != nil
      check findByAttr(root,"data-property-row","padding-top") == nil
      dispose()
      check vm.inspector.selectedElement.observers.len == 0

  test "production normalized DOM identities keep CSS ownership without declaring components":
    for element in [domSelection(),domSelection(testId="action"),domSelection(className="panel rounded")]:
      check element.schemaKey.startsWith("dom.")
      check not isComponentInstance(element)
      check element.properties.len > 0
      createRoot do (dispose:proc()):
        let r=MockRenderer()
        let root=r.createElement("div")
        let vm=createEditorVM()
        vm.inspector.selectedElement.val=element
        mountSectionComponentProps[MockRenderer,MockNode](r,root,vm)
        check findByAttr(root,"data-property-row","padding-top") == nil
        vm.inspector.selectedElement.val=ElementRef(schemaKey:"Button",properties: element.properties & @[
          PropertyInfo(name:"variant",value:"primary",schemaKey:"Button.variant"),
          PropertyInfo(name:"size",value:"md",schemaKey:"Button.size")])
        check findByAttr(root,"data-property-row","variant") != nil
        check findByAttr(root,"data-property-row","size") != nil
        check findByAttr(root,"data-property-row","padding-top") == nil
        vm.inspector.selectedElement.val=element
        check findByAttr(root,"data-property-row","variant") == nil
        dispose()
  test "explicit DOM component declaration keeps its existing schema identity":
    let explicit=domSelection(declared="Button")
    check explicit.schemaKey == "Button"
    check isComponentInstance(explicit)
