## Selection Colors model/render tests. MockRenderer observes generated nodes,
## row ownership, cleanup and click dispatch without a browser. Picker callbacks
## are admission spies only; they do not simulate persistence or source success.
## Actual keyboard defaults, compiler/source and preview are covered by the
## existing compounds GUI; binding sidecar persistence has its real file e2e.

import std/[options, tables, unittest]

import isonim/core/[signals, computation, owner]
import isonim/editor/types
import isonim/editor/css_color_literal
import isonim/editor/style_provenance_decode
import isonim/editor/viewmodels
import isonim/editor/views/widgets/section_selection_colors
import isonim/testing/mock_dom

proc findByAttr(node: MockNode; attr, value: string): MockNode =
  if node == nil: return nil
  if node.kind == mnkElement and node.attributes.getOrDefault(attr) == value:
    return node
  for c in node.children:
    let hit = findByAttr(c, attr, value)
    if hit != nil: return hit
  return nil

suite "Phase G section_selection_colors":

  test "preview collector exposes every Selection Colors key":
    for name in ["background-color", "color", "border-color", "outline-color",
        "border-top-color", "border-right-color", "border-bottom-color", "border-left-color"]:
      check name in inspectorEditableCssProperties


  test "looksLikeColor accepts hex + rgb / rejects junk":
    check looksLikeColor("#fff")
    check looksLikeColor("#0F172A")
    check looksLikeColor("rgb(10, 20, 30)")
    check looksLikeColor("rgba(0, 0, 0, 0.4)")
    check not looksLikeColor("none")
    # `transparent` is a CSS <color> (editor spec "Section catalogue", "When
    # colours present"; CSS Color 4 §6.3).
    check looksLikeColor("transparent")
    check not looksLikeColor("")
    check not looksLikeColor("auto")

  test "collectSelectionColors de-duplicates and preserves first-seen order":
    let props = @[
      PropertyInfo(name: "background-color", value: "#0F172A"),
      PropertyInfo(name: "color", value: "#FFFFFF"),
      PropertyInfo(name: "border-color", value: "#0F172A"),
      PropertyInfo(name: "outline-color", value: "transparent")]
    let colors = collectSelectionColors(props)
    check colors == @["#0F172A", "#FFFFFF", "transparent"]

  test "section mount renders list + empty-state":
    createRoot do (dispose: proc()):
      let r = MockRenderer()
      let root = r.createElement("div")
      let vm = createEditorVM()
      mountSectionSelectionColors[MockRenderer, MockNode](r, root, vm)

      check findByAttr(root, "data-selection-colors-body", "true") != nil
      check findByAttr(root, "data-selection-colors-list", "true") != nil
      let empty = findByAttr(root, "data-selection-colors-empty", "true")
      check empty != nil
      check empty.styles.getOrDefault("display") == "block"
      dispose()

  test "selection with colors populates the list":
    createRoot do (dispose: proc()):
      let r = MockRenderer()
      let root = r.createElement("div")
      let vm = createEditorVM()
      mountSectionSelectionColors[MockRenderer, MockNode](r, root, vm)

      vm.inspector.selectedElement.val = ElementRef(tag: "div",
        properties: @[
          PropertyInfo(name: "background-color", value: "#1A1B22"),
          PropertyInfo(name: "color", value: "#F1F5F9")])
      check findByAttr(root, "data-selection-color-row", "0") != nil
      check findByAttr(root, "data-selection-color-row", "1") != nil
      let empty = findByAttr(root, "data-selection-colors-empty", "true")
      check empty.styles.getOrDefault("display") == "none"
      dispose()

  test "shared color parser validates alpha forms and rejects malformed colors":
    check looksLikeColor("#1234")
    check looksLikeColor("#12345680")
    check looksLikeColor("hsl(210 50% 40% / 25%)")
    check not looksLikeColor("#ggg")
    check not looksLikeColor("rgba(1, 2, NaN, 0.5)")
    check collectSelectionColors(@[
      PropertyInfo(name: "color", value: "#ffffff"),
      PropertyInfo(name: "background-color", value: "rgb(255, 255, 255)")]) == @["#ffffff"]

  test "actual alpha and unique source owner bind while ambiguity and readonly refuse":
    createRoot do (dispose: proc()):
      let r = MockRenderer()
      let root = r.createElement("div")
      let vm = createEditorVM()
      vm.workspacePermissions.val = EditorWorkspacePermissions(readSource: true, writeSource: true)
      var admitted: seq[string]
      vm.inspector.requestVariablePicker = proc(key: PropertyBindingKey; x,y,w,h: float) =
        admitted.add key.elementId & ":" & key.propertyName
      mountSectionSelectionColors[MockRenderer, MockNode](r, root, vm)
      vm.inspector.selectedElement.val = ElementRef(tag: "div", id: "alpha",
        properties: @[PropertyInfo(name: "background-color", value: "#12345680",
          directStyleAllowed: true)])
      check findByAttr(root, "data-selection-color-hex", "0").textContent == "#123456"
      check findByAttr(root, "data-selection-color-opacity", "0").textContent == "50%"
      let oldBind = findByAttr(root, "data-selection-color-bind", "0")
      fireEvent(oldBind, "click")
      check admitted == @["alpha:background-color"]
      vm.foundations.tokens.val = @[FoundationTokenEntry(key: "color/alpha",
        kind: ftkSemanticColor, value: "#12345680")]
      vm.bindPropertyToVariable(PropertyBindingKey(elementId: "alpha",
        propertyName: "background-color"), "color/alpha")
      vm.workspacePermissions.val = EditorWorkspacePermissions(readSource: true, writeSource: false)
      let readonlyChip = findByAttr(root, "data-selection-color-linked-chip", "true")
      check readonlyChip != nil
      for attr in ["data-variable-chip-name", "data-variable-chip-chevron", "data-variable-chip-detach"]:
        let child = findByAttr(readonlyChip, attr, "true")
        check child.attributes["aria-disabled"] == "true"
        check child.attributes["tabindex"] == "-1"
        check child.attributes["title"].len > 0
        check child.styles["cursor"] == "default"
        fireEvent(child, "click")
      check vm.inspectorBindingFor("background-color").get.variableKey == "color/alpha"
      check vm.inspector.pendingSourceEdits.val.len == 0
      check admitted.len == 1
      vm.workspacePermissions.val = EditorWorkspacePermissions(readSource: true, writeSource: true)
      vm.inspector.selectedElement.val = ElementRef(tag: "div", id: "mixed",
        properties: @[
          PropertyInfo(name: "background-color", value: "#12345680", directStyleAllowed: true),
          PropertyInfo(name: "color", value: "rgba(18,52,86,0.5)", directStyleAllowed: true)])
      let ambiguous = findByAttr(root, "data-selection-color-bind", "0")
      check ambiguous.attributes.getOrDefault("aria-disabled") == "true"
      check findByAttr(root, "data-selection-color-reason", "0").textContent.len > 0
      fireEvent(ambiguous, "click")
      fireEvent(oldBind, "click")
      check admitted.len == 1
      vm.inspector.selectedElement.val = ElementRef(tag: "div", id: "unmapped",
        properties: @[PropertyInfo(name: "color", value: "#123456")])
      let readonly = findByAttr(root, "data-selection-color-bind", "0")
      check readonly.attributes.getOrDefault("aria-disabled") == "true"
      fireEvent(readonly, "click")
      check admitted.len == 1
      check vm.inspector.pendingSourceEdits.val.len == 0
      check vm.inspector.undoStack.val.len == 0
      check vm.inspector.redoStack.val.len == 0
      dispose()
      fireEvent(oldBind, "click")
      check admitted.len == 1

suite "CSS colour syntax (CSS Color 4 and 5)":
  ## Editor spec "Section catalogue", "When colours present": any CSS
  ## <color>, each function by its grammar; a value holding a reference is a
  ## colour only by its resolved value, so the unresolved text is not one.
  test "colour functions follow their grammar, relative syntax included":
    for value in ["lab(50% 40 59.5)", "lab(50% 40 59.5 / 0.5)",
        "lch(52% 72 50deg)", "oklab(0.6 0.1 -0.1)", "oklch(60% 0.15 50 / 50%)",
        "hwb(120deg 10% 20%)", "rgb(none 0 0)", "rgb(calc(255 / 2) 0 0)",
        "rgb(1e2 0 0)", "rgb(from red r g b)", "hsl(from #ff0000 h s l / alpha)",
        "oklch(from red l c h)", "lab(from oklch(60% 0.1 20) l a b)",
        "color(display-p3 1 0.5 0)", "color(xyz-d65 0.4 0.2 0.1 / 0.5)",
        "color(from red srgb r g b)", "color(--brand 1 0 0)",
        "color-mix(in srgb, red 40%, blue)",
        "color-mix(in oklch longer hue, red, blue 30%)",
        "light-dark(white, black)", "rgba(10, 20, 30, 0.5)",
        "hsla(120, 50%, 50%, 0.3)"]:
      check isCssColorValue(value)
    for value in ["lab()", "oklch()", "rgb()", "lab(50%)", "lab(50% 40)",
        "lab(50% 40 59.5 0.5)", "lab(50% 40 59.5 /)", "hwb(10% 10deg 20%)",
        "lch(52% 72% 50deg 1)", "rgb(var(--r) 2 3)", "oklch(var(--l) 0.1 20)",
        "var(--brand)", "color(foo 1 0 0)", "color(srgb 1 0)",
        "rgb(from notacolor r g b)", "rgb(from red)", "rgb(from red q g b)",
        "color-mix(in srgb, red)", "color-mix(srgb, red, blue)",
        "light-dark(white)", "rgb(255, 0 0)", "rgb(10, 20, 30, 40, 50)",
        "rgb(10px 20 30)", "lab(50% 40 59.5", "lab(50% 40 59.5))"]:
      check not isCssColorValue(value)

  test "one colour written several ways is listed once":
    check cssColorKey("red") == cssColorKey("#ff0000")
    check cssColorKey("RED") == cssColorKey("rgb(255, 0, 0)")
    check cssColorKey("hsl(0 100% 50%)") == cssColorKey("red")
    check cssColorKey("transparent") == cssColorKey("rgba(0, 0, 0, 0)")
    check cssColorKey("navy") != cssColorKey("blue")
    check collectSelectionColors(@[
      PropertyInfo(name: "color", value: "red"),
      PropertyInfo(name: "background-color", value: "#ff0000"),
      PropertyInfo(name: "border-color", value: "rgb(255 0 0)")]) == @["red"]
    check namedColorHex("RebeccaPurple") == "#663399"
    check namedCssColorHex.len == 148
    check decodedColorChannels("red").valid
    check not decodedColorChannels("oklch(60% 0.15 50)").valid

  test "legacy syntax and color-mix() follow CSS Color 4 and 5 exactly":
    # Legacy rgb(): all numbers or all percentages; legacy hsl(): a hue and
    # two percentages; no `none` in legacy syntax.
    for value in ["rgb(10%, 20%, 30%)", "rgb(10, 20, 30, 50%)",
        "rgb(calc(10), 20, 30)", "hsl(120deg, 50%, 50%)", "hsl(120, 50%, 50%, 0.5)",
        "color-mix(in srgb, red 0%, blue)", "color-mix(in hsl shorter hue, red, blue)",
        "color-mix(in --mine, red, blue)", "color-mix(in lab, red 100%, blue)",
        "color-mix(in xyz-d50, red 30%, blue 70%)", "color-mix(in oklab, red calc(20%), blue)"]:
      check isCssColorValue(value)
    for value in ["rgb(1,2%,3)", "rgb(1%, 2, 3%)", "hsl(10, 20, 30)",
        "hsl(10, 20%, 30)", "rgb(none, 0, 0)", "hsl(10%, 20%, 30%)",
        "color-mix(in foo, red, blue)", "color-mix(in srgb, red 150%, blue)",
        "color-mix(in srgb, red -10%, blue)", "color-mix(in srgb, red 0%, blue 0%)",
        "color-mix(in srgb longer hue, red, blue)",
        "color-mix(in oklch sideways hue, red, blue)",
        "color-mix(in oklch longer, red, blue)",
        "color-mix(in srgb, red, blue, green)", "color-mix(in srgb, red 10px, blue)"]:
      check not isCssColorValue(value)
