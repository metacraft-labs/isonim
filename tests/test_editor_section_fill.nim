## Fill-section renderer-neutral selection hydration tests.
## MockRenderer replaces only DOM mounting/events so selection and property
## signals run through the production editor/section. It does not simulate a
## successful source edit or compiler. The mounted compiled-browser suite owns
## actual preview selection, popup reachability/focus and refused edits; the real
## consumer-adapter suite owns filesystem/compiler writeback. Existing add/seed
## checks are retained, with delayed same-element property delivery covered here.
## The deferred commit callback below controls only completion timing/refusal to
## test disposed-row ownership. It does not claim native persistence; real native
## files, compiler rollback and same-ID story switching are covered by GUI tests.

import std/[options, tables, unittest]

import isonim/core/[signals, computation, owner]
import isonim/editor/types
import isonim/editor/viewmodels
import isonim/editor/views/widgets/section_fill
import isonim/testing/mock_dom

proc findByAttr(node: MockNode; attr, value: string): MockNode =
  if node == nil: return nil
  if node.kind == mnkElement and node.attributes.getOrDefault(attr) == value:
    return node
  for c in node.children:
    let hit = findByAttr(c, attr, value)
    if hit != nil: return hit
  return nil

suite "Phase G section_fill":

  test "mounts list + empty-state + add button":
    createRoot do (dispose: proc()):
      let r = MockRenderer()
      let root = r.createElement("div")
      let vm = createEditorVM()
      mountSectionFill[MockRenderer, MockNode](r, root, vm)

      check findByAttr(root, "data-fill-section-body", "true") != nil
      check findByAttr(root, "data-fill-list", "true") != nil
      let empty = findByAttr(root, "data-fill-empty", "true")
      check empty != nil
      check empty.styles.getOrDefault("display") == "block"
      check findByAttr(root, "data-fill-add", "true") != nil
      dispose()

  test "same-ID same-color story replacement rejects detached callbacks and late refusal":
    createRoot do (dispose: proc()):
      let r = MockRenderer()
      let root = r.createElement("div")
      let vm = createEditorVM()
      var permissions = vm.workspacePermissions.val
      permissions.writeSource = true
      vm.workspacePermissions.val = permissions
      vm.selectedStory.val = StoryRef(group:"Cards",name:"First",kind:skComponent)
      vm.inspector.selectedElement.val = ElementRef(id:"shared-id",tag:"div",
        properties: @[PropertyInfo(name:"background-color",value:"#112233",
          authoredValue:"#112233",directStyleAllowed:true)])
      var requests: seq[string]
      var pending: proc(ok:bool;diagnostic:string) {.closure.}
      vm.inspectorSourceCommit = proc(element:ElementRef;property,value:string;
          scope:SourceScopeChoiceKind;done:proc(ok:bool;diagnostic:string) {.closure.}) =
        requests.add value
        pending = done
      mountSectionFill[MockRenderer,MockNode](r,root,vm)
      let oldHex=findByAttr(root,"data-fill-row-hex","0")
      check oldHex != nil
      r.setInputValue(oldHex,"#445566")
      fireEvent(oldHex,"change")
      check requests == @["#445566"]
      check pending != nil
      vm.selectedStory.val = StoryRef(group:"Cards",name:"Second",kind:skComponent)
      let newHex=findByAttr(root,"data-fill-row-hex","0")
      check newHex != nil
      check newHex != oldHex
      check r.inputValue(newHex) == "#112233"
      r.setInputValue(oldHex,"#778899")
      fireEvent(oldHex,"change")
      check requests == @["#445566"]
      pending(false,"Native compiler refused the original target")
      check r.inputValue(newHex) == "#112233"
      check vm.selectedStory.val.name == "Second"
      check vm.inspector.undoStack.val.len == 0
      dispose()

  test "+ Add fill appends a row with swatch + hex + alpha":
    createRoot do (dispose: proc()):
      let r = MockRenderer()
      let root = r.createElement("div")
      let vm = createEditorVM()
      var permissions = vm.workspacePermissions.val
      permissions.writeSource = true
      vm.workspacePermissions.val = permissions
      vm.inspector.selectedElement.val = ElementRef(id: "add-target", tag: "div",
        properties: @[PropertyInfo(name: "background-color", value: "",
          directStyleAllowed: true)])
      mountSectionFill[MockRenderer, MockNode](r, root, vm)

      let addBtn = findByAttr(root, "data-fill-add", "true")
      fireEvent(addBtn, "click")
      check findByAttr(root, "data-fill-row", "0") != nil
      check findByAttr(root, "data-fill-row-swatch", "0") != nil
      check findByAttr(root, "data-fill-row-hex", "0") != nil
      check findByAttr(root, "data-fill-row-alpha", "0") != nil
      check findByAttr(root, "data-fill-row-bind", "0") != nil
      dispose()

  test "selection with background-color seeds a fill row":
    createRoot do (dispose: proc()):
      let r = MockRenderer()
      let root = r.createElement("div")
      let vm = createEditorVM()
      mountSectionFill[MockRenderer, MockNode](r, root, vm)

      vm.inspector.selectedElement.val = ElementRef(tag: "div",
        id: "elem-1",
        properties: @[PropertyInfo(name: "background-color",
          value: "#1A1B22")])
      check findByAttr(root, "data-fill-row", "0") != nil
      let hex = findByAttr(root, "data-fill-row-hex", "0")
      check hex != nil
      check r.inputValue(hex) == "#1A1B22"
      dispose()

  test "late computed fill properties on the same selected element reveal the real swatch":
    createRoot do (dispose: proc()):
      let r = MockRenderer()
      let root = r.createElement("div")
      let vm = createEditorVM()
      mountSectionFill[MockRenderer, MockNode](r, root, vm)
      vm.inspector.selectedElement.val = ElementRef(tag: "button", id: "action")
      check findByAttr(root, "data-fill-row", "0") == nil
      vm.inspector.selectedElement.val = ElementRef(tag: "button", id: "action",
        properties: @[PropertyInfo(name: "background-color", value: "#112233")])
      let hex = findByAttr(root, "data-fill-row-hex", "0")
      check hex != nil
      if hex != nil: check r.inputValue(hex) == "#112233"
      dispose()

  test "updated computed fill value with stable identity follows the actual selection":
    createRoot do (dispose: proc()):
      let r = MockRenderer()
      let root = r.createElement("div")
      let vm = createEditorVM()
      mountSectionFill[MockRenderer, MockNode](r, root, vm)
      vm.inspector.selectedElement.val = ElementRef(tag: "div", id: "same",
        properties: @[PropertyInfo(name: "background-color", value: "#010203")])
      vm.inspector.selectedElement.val = ElementRef(tag: "div", id: "same",
        properties: @[PropertyInfo(name: "background-color", value: "#AABBCC")])
      let hex = findByAttr(root, "data-fill-row-hex", "0")
      check hex != nil
      if hex != nil: check r.inputValue(hex) == "#AABBCC"
      dispose()

  test "text and box fill invokers target their actual fill property":
    for (tag, property) in [("p", "color"), ("div", "background-color")]:
      createRoot do (dispose: proc()):
        let r = MockRenderer()
        let root = r.createElement("div")
        let vm = createEditorVM()
        var requested = PropertyBindingKey()
        # Capture only the renderer-neutral admission request. This does not
        # substitute for selecting a token, editing source or successful I/O.
        vm.inspector.requestVariablePicker = proc(key: PropertyBindingKey; x, y, w, h: float) = requested = key
        mountSectionFill[MockRenderer, MockNode](r, root, vm)
        vm.inspector.selectedElement.val = ElementRef(tag: tag, id: "target",
          properties: @[PropertyInfo(name: "color", value: "#112233"),
            PropertyInfo(name: "background-color", value: "#445566")])
        let invoker = findByAttr(root, "data-fill-row-bind", "0")
        check invoker != nil
        if invoker != nil: invoker.fireEvent("click")
        check requested.elementId == "target"
        check requested.propertyName == property
        dispose()

  test "editable Fill deletion explains unsupported source removal without local or writer mutation":
    createRoot do (dispose: proc()):
      let r = MockRenderer()
      let root = r.createElement("div")
      let vm = createEditorVM()
      var permissions = vm.workspacePermissions.val
      permissions.writeSource = true
      vm.workspacePermissions.val = permissions
      vm.selectedStory.val = StoryRef(group: "Cards", name: "First", kind: skComponent)
      vm.inspector.selectedElement.val = ElementRef(id: "shared-id", tag: "div",
        properties: @[PropertyInfo(name: "background-color", value: "#112233",
          authoredValue: "#112233", directStyleAllowed: true)])
      var calls = 0
      vm.inspectorSourceCommit = proc(element: ElementRef; property, value: string;
          scope: SourceScopeChoiceKind; done: proc(ok: bool; diagnostic: string) {.closure.}) =
        inc calls
        done(false, "Unexpected writer call")
      mountSectionFill[MockRenderer, MockNode](r, root, vm)
      let row = findByAttr(root, "data-fill-row", "0")
      let deleteButton = findByAttr(root, "data-fill-row-delete", "0")
      let message = findByAttr(root, "data-fill-message", "true")
      check row != nil and deleteButton != nil and message != nil
      check deleteButton.attributes.getOrDefault("aria-disabled") == "true"
      check deleteButton.attributes.getOrDefault("title").len > 0
      fireEvent(deleteButton, "click")
      check findByAttr(root, "data-fill-row", "0") == row
      check findByAttr(root, "data-fill-row", "1") == nil
      check message.textContent == "The editor cannot remove this fill from its source yet."
      check message.attributes.getOrDefault("data-fill-message-visible") == "true"
      check r.inputValue(findByAttr(root, "data-fill-row-hex", "0")) == "#112233"
      check calls == 0
      check vm.inspector.undoStack.val.len == 0
      check vm.inspector.pendingSourceEdits.val.len == 0
      vm.selectedStory.val = StoryRef(group: "Cards", name: "Second", kind: skComponent)
      let currentRow = findByAttr(root, "data-fill-row", "0")
      check currentRow != row
      let currentMessage = message.textContent
      fireEvent(deleteButton, "click")
      check findByAttr(root, "data-fill-row", "0") == currentRow
      check message.textContent == currentMessage
      check calls == 0
      dispose()
      fireEvent(deleteButton, "click")
      check calls == 0

  test "readonly Fill discloses draft but refuses Apply literals alpha addition and deletion":
    createRoot do (dispose: proc()):
      let r = MockRenderer()
      let root = r.createElement("div")
      let vm = createEditorVM()
      vm.inspector.selectedElement.val = ElementRef(id: "readonly", tag: "div",
        properties: @[PropertyInfo(name: "background-color", value: "#112233",
          authoredValue: "#112233", directStyleAllowed: true)])
      var calls = 0
      vm.inspectorSourceCommit = proc(element: ElementRef; property, value: string;
          scope: SourceScopeChoiceKind; done: proc(ok: bool; diagnostic: string) {.closure.}) =
        inc calls
        done(false, "Unexpected writer call")
      mountSectionFill[MockRenderer, MockNode](r, root, vm)
      let swatch = findByAttr(root, "data-fill-row-swatch", "0")
      let popup = findByAttr(root, "data-color-popover", "true")
      let input = findByAttr(root, "data-color-popover-input", "true")
      let apply = findByAttr(root, "data-color-popover-apply", "true")
      check swatch != nil and popup != nil and input != nil and apply != nil
      fireEvent(swatch, "click")
      check popup.attributes.getOrDefault("data-color-popover-open") == "true"
      r.setInputValue(input, "#445566")
      fireEvent(input, "input")
      fireEvent(apply, "click")
      check popup.attributes.getOrDefault("data-color-popover-open") == "true"
      check r.inputValue(input) == "#445566"
      check findByAttr(root, "data-color-popover-error", "true").textContent.len > 0
      let hex = findByAttr(root, "data-fill-row-hex", "0")
      let alpha = findByAttr(root, "data-fill-row-alpha", "0")
      r.setInputValue(hex, "#778899"); fireEvent(hex, "change")
      r.setInputValue(alpha, "50"); fireEvent(alpha, "change")
      fireEvent(findByAttr(root, "data-fill-add", "true"), "click")
      fireEvent(findByAttr(root, "data-fill-row-delete", "0"), "click")
      check r.inputValue(hex) == "#112233"
      check r.inputValue(alpha) == "100"
      check findByAttr(root, "data-fill-row", "1") == nil
      check findByAttr(root, "data-fill-row", "0") != nil
      check calls == 0
      check vm.inspector.undoStack.val.len == 0
      check vm.inspector.pendingSourceEdits.val.len == 0
      # Live permission reversal restores real submission, rather than caching
      # the readonly state captured when the inspection popup was mounted.
      var permissions = vm.workspacePermissions.val
      permissions.writeSource = true
      vm.workspacePermissions.val = permissions
      fireEvent(apply, "click")
      check calls == 1
      check popup.attributes.getOrDefault("data-color-popover-open") == "true"
      dispose()
      fireEvent(swatch, "click")
      fireEvent(apply, "click")
      fireEvent(alpha, "change")
      fireEvent(findByAttr(root, "data-fill-add", "true"), "click")
      check calls == 1
