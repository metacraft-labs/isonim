## The Layout section's visual box model.
##
## Editor spec "Editing Controls (Figma-Grade Affordances)" -> "Specialized
## Editors": "Visual box model -- nested rectangles for margin/padding/
## content; click any segment to type a value; click center to set all sides
## uniformly", and the clause under it that places the box model in Layout and
## says how its fields commit; "Numeric Inputs" and "Planned interaction
## parity" for the field contract; "Saving" for the act-time refusals, the
## automatic write and undo across writes. isonim-pm issue
## 2026-09-26-the-consumer-editor-spec-tests-the-inspector-that-was-demolished,
## "The removed-controls cases are missing features, not stale tests".
##
## The writer cases use no mock writer: the editor example's production
## adapter (`demo_workspace.demoVectorEditAdapter`) writes the example's real
## foundation source held in memory, and a real EditorVM plans, journals,
## writes and undoes through it. The example's schema maps only the card's
## `padding` shorthand (and the long-tail properties); the fixture appends
## schema entries for the sides it edits -- `classes.destination-card.<side>`,
## the same kind of entry the example declares for `padding` -- so the same
## writer inserts a side's declaration into the `.destination-card` rule. That
## extends what the project maps, not how it writes.
##
## Mock justification: MockRenderer stands in for the browser DOM so the
## production inspector panel (`shell.renderInspectorPanel`, the Layout
## section, its rows and the box model) runs natively and under strict Node JS
## with real signals, owners and EditorVM; events are dispatched to the
## listeners the views registered, pointer events with their coordinates. One
## case gives the EditorVM an `inspectorSourceCommit` recording callback: it
## stands for the native source bridge, which the inspector calls and does not
## own, and no write is claimed there. The browser, the example's page and its
## writer are exercised by the editor-example Playwright case
## `e2e_box_model_edits_margin_and_padding_by_keyboard_and_pointer`, and the
## consumer's disclosure by metacraft-web-editor's
## `e2e_inspector_sections_are_keyboard_and_pointer_operable`.

import std/[options, strutils, tables, unittest]

import isonim/core/[computation, owner, signals]
import isonim/testing/mock_dom
import isonim/editor
import isonim/editor/demo_workspace
import isonim/editor/views/shell
import isonim/editor/views/widgets/property_commit
import isonim/editor/views/widgets/section_box_model

const Sides = ["top", "right", "bottom", "left"]

proc cardProperty(name, value: string): PropertyInfo =
  ## A box property as the preview capture reports it: a computed value with
  ## no authored provenance, keyed by the card's schema prefix.
  PropertyInfo(name: name, value: value, origin: poInherited,
    originDetail: "iframe-dom:classes.destination-card:" & name,
    sourceFile: DemoFoundationSource, sourceLine: 9,
    schemaKey: "classes.destination-card." & name, directStyleAllowed: true)

proc boxElement(): ElementRef =
  ## The example's card with its box properties exposed, as the preview
  ## capture exposes them: margins 4px 8px, padding 18px, a 1px border.
  result = demoInspectorElement()
  for (name, value) in [("margin", "4px 8px"), ("margin-top", "4px"),
      ("margin-right", "8px"), ("margin-bottom", "4px"), ("margin-left", "8px"),
      ("padding-top", "18px"), ("padding-right", "18px"),
      ("padding-bottom", "18px"), ("padding-left", "18px"),
      ("border-width", "1px"), ("width", "420px"), ("height", "53px")]:
    result.properties.add cardProperty(name, value)

const MappedSides = ["padding-top", "padding-right", "padding-bottom",
  "padding-left", "margin-top", "margin-right", "margin-bottom", "margin-left",
  "margin"]

proc boxVm(foundation: ref string; writable = true; mapSides = true;
    element = boxElement()): EditorVM =
  let vector = new(string)
  vector[] = "<svg/>"
  let story = StoryRef(group: "DestinationCard", name: "Default",
    kind: skComponent, index: 0)
  var schema = demoDesignSystemSchema()
  var adapter = demoVectorEditAdapter(vector, foundation)
  if mapSides:
    for property in MappedSides:
      schema.nodes.add DesignSchemaNode(
        key: "classes.destination-card." & property,
        kind: dsnClassDefinition, name: "destination-card",
        component: "DestinationCard", property: property, value: "",
        sourceSpan: SourceSpan(file: DemoFoundationSource, line: 9, column: 1,
          endLine: 9, endColumn: 80),
        stories: @[story], components: @["DestinationCard"], usageCount: 4)
      adapter.schema.add WorkspaceEditableSchemaEntry(
        key: "classes.destination-card." & property, kind: wskSourceMap,
        file: DemoFoundationSource,
        path: "classes.destination-card." & property, story: story,
        property: property, removable: true)
  result = createEditorVM(newEditorWorkspace(
    title = "Wanderlust box model fixture",
    storyGroups = @[StoryGroup(name: "DestinationCard", kind: skComponent,
      expanded: true, items: @[StoryItem(name: "Default", kind: skComponent,
        group: "DestinationCard")])],
    initialStory = some(story),
    foundationTokens = demoFoundationTokens(),
    designSystemSchema = schema,
    permissions = EditorWorkspacePermissions(readSource: true,
      writeSource: writable),
    editAdapter = adapter))
  check result.selectInspectorElement(element)

proc findByAttr(node: MockNode; name, value: string): MockNode =
  if node == nil: return nil
  if node.kind == mnkElement and node.attributes.getOrDefault(name) == value:
    return node
  for child in node.children:
    let found = findByAttr(child, name, value)
    if found != nil: return found

proc findAllByAttr(node: MockNode; name: string; into: var seq[MockNode]) =
  if node == nil: return
  if node.kind == mnkElement and name in node.attributes: into.add node
  for child in node.children: findAllByAttr(child, name, into)

proc attr(node: MockNode; name: string): string =
  ## An attribute of ``node``, "" for a missing node: a control that is not
  ## there fails the check instead of crashing the suite.
  if node == nil: "" else: node.attributes.getOrDefault(name)

proc hasAttr(node: MockNode; name: string): bool =
  node != nil and name in node.attributes

proc display(node: MockNode): string =
  if node == nil: "" else: node.styles.getOrDefault("display")

proc textOf(node: MockNode): string =
  if node == nil: "" else: textContent(node)

proc inputOf(r: MockRenderer; node: MockNode): string =
  if node == nil: "" else: r.inputValue(node)

proc press(node: MockNode; key: string; shift = false; alt = false) =
  node.fireEventWith("keydown", MockEvent(`type`: "keydown", target: node,
    currentTarget: node, key: key, shiftKey: shift, altKey: alt))

proc pointer(node: MockNode; event: string; x: float; y = 0.0) =
  node.fireEventWith(event, MockEvent(`type`: event, target: node,
    currentTarget: node, clientX: x, clientY: y))

proc typeInto(r: MockRenderer; node: MockNode; value: string) =
  r.setInputValue(node, value)
  node.fireEvent("input")

template need(node: MockNode) {.dirty.} =
  ## A control the test drives must exist; a missing one fails here and ends
  ## the case instead of crashing on a nil node later.
  check node != nil
  if node == nil:
    dispose()
    return

proc value(vm: EditorVM; name: string): string =
  for prop in vm.inspector.selectedElement.val.properties:
    if prop.name == name: return prop.value

proc stacks(vm: EditorVM): (int, int) =
  (vm.inspector.undoStack.val.len, vm.inspector.redoStack.val.len)

proc field(panel: MockNode; label: string): MockNode =
  findByAttr(panel, "aria-label", label)

proc toggle(panel: MockNode): MockNode =
  findByAttr(panel, "aria-label", "Show box model controls")

proc boxMessage(panel: MockNode): MockNode =
  findByAttr(panel, "data-box-model-message", "true")

proc padRowInput(panel: MockNode; side: string): MockNode =
  findByAttr(findByAttr(panel, "data-property-row", "pad-" & side),
    "data-property-row-input", "true")

proc write(vm: EditorVM) =
  let saved = vm.applyWorkspaceFileEdits()
  check saved.ok
  check vm.inspector.pendingSourceEdits.val.len == 0

suite "box model values":
  test "field names, displayed values, typed values and steps":
    check boxModelFieldLabel("margin-top") == "Margin top"
    check boxModelFieldLabel("padding-left") == "Padding left"
    check boxModelFieldLabel("padding") == "Padding, all sides"
    check boxModelFieldLabel("margin") == "Margin, all sides"
    # Pixels show as a bare number; another unit keeps its unit; a keyword
    # or function is shown as written.
    check boxModelDisplayValue("18px") == "18"
    check boxModelDisplayValue("0") == "0"
    check boxModelDisplayValue("1.5rem") == "1.5rem"
    check boxModelDisplayValue("auto") == "auto"
    check boxModelDisplayValue("var(--wl-space-card)") == "var(--wl-space-card)"
    # A bare number is pixels; arithmetic is evaluated; anything else is
    # committed as typed for the property's validation to judge.
    check boxModelCssValue("24") == "24px"
    check boxModelCssValue(" 10+4 ") == "14px"
    check boxModelCssValue("2rem") == "2rem"
    check boxModelCssValue("6*4px") == "24px"
    check boxModelCssValue("auto") == "auto"
    check boxModelCssValue("") == ""
    check boxModelSteppedValue("18", 1.0) == "19px"
    check boxModelSteppedValue("1.5rem", 0.1) == "1.6rem"
    check boxModelSteppedValue("auto", 1.0) == ""
    # Authored precision is kept: a typed or shown value is not rounded.
    check boxModelCssValue("0.125rem") == "0.125rem"
    check boxModelDisplayValue("0.125rem") == "0.125rem"
    check boxModelDisplayValue("12.345px") == "12.345"
    check boxModelSteppedValue("0.125rem", 1.0) == "1.125rem"
    # A step does not carry binary rounding noise into the source.
    check boxModelSteppedValue("0.2", 0.1) == "0.3px"
    check boxModelStep(false, false) == 1.0
    check boxModelStep(true, false) == 10.0
    check boxModelStep(false, true) == 0.1

suite "the box model disclosure":
  test "Layout has the disclosure, a button that is closed until it is opened":
    createRoot proc(dispose: proc()) =
      let r = MockRenderer()
      let foundation = new(string)
      foundation[] = DemoFoundationInitialSource
      let vm = boxVm(foundation)
      let panel = renderInspectorPanel[MockRenderer, MockNode](r, vm)
      let layout = findByAttr(panel, "data-inspector-section-body", "layout")
      need(layout)
      let toggle = layout.toggle
      need(toggle)
      # One disclosure, in Layout, a real button.
      var all: seq[MockNode] = @[]
      findAllByAttr(panel, "data-box-model-toggle", all)
      check all.len == 1
      check toggle.tag == "button"
      let box = findByAttr(layout, "data-box-model", "true")
      need(box)
      check attr(toggle, "aria-expanded") == "false"
      check display(box) == "none"
      check not vm.inspector.boxModelShown.val
      toggle.fireEvent("click")
      check vm.inspector.boxModelShown.val
      check attr(toggle, "aria-expanded") == "true"
      check display(box) == "flex"
      toggle.fireEvent("click")
      check attr(toggle, "aria-expanded") == "false"
      check display(box) == "none"
      dispose()

  test "the rings show the selection's margin, border, padding and content":
    createRoot proc(dispose: proc()) =
      let r = MockRenderer()
      let foundation = new(string)
      foundation[] = DemoFoundationInitialSource
      let vm = boxVm(foundation)
      let panel = renderInspectorPanel[MockRenderer, MockNode](r, vm)
      for (label, shown) in [("Margin top", "4"), ("Margin right", "8"),
          ("Margin bottom", "4"), ("Margin left", "8"), ("Padding top", "18"),
          ("Padding right", "18"), ("Padding bottom", "18"),
          ("Padding left", "18"), ("Padding, all sides", "18"),
          ("Margin, all sides", "")]:
        let node = panel.field(label)
        check node != nil
        if node != nil:
          check node.tag == "input"
          check r.inputOf(node) == shown
          check "readonly" notin node.attributes
      # Margins that differ are Mixed.
      check attr(panel.field("Margin, all sides"), 
        "placeholder") == "Mixed"
      check textOf(findByAttr(panel, "data-box-model-border", "true")) ==
        "Border 1"
      check textOf(findByAttr(panel, "data-box-model-size", "true")) ==
        "420 \xC3\x97 53"
      dispose()

  test "a side the selection exposes only through its shorthand is shown and read-only":
    createRoot proc(dispose: proc()) =
      let r = MockRenderer()
      let foundation = new(string)
      foundation[] = DemoFoundationInitialSource
      # The example's hand-built card exposes `padding` and no side.
      let vm = boxVm(foundation, element = demoInspectorElement())
      let panel = renderInspectorPanel[MockRenderer, MockNode](r, vm)
      let top = panel.field("Padding top")
      need(top)
      check r.inputOf(top) == "18"
      check attr(top, "readonly") == "true"
      check attr(top, "title") ==
        "The selected element does not expose padding-top."
      check r.inputOf(panel.field("Padding, all sides")) == "18"
      check not panel.field("Padding, all sides").hasAttr("readonly")
      # Typing into it anyway is refused with the reason, and nothing moves.
      r.typeInto(top, "30")
      top.press("Enter")
      check textOf(panel.boxMessage) ==
        "Padding top: The selected element does not expose padding-top."
      check r.inputOf(top) == "18"
      check vm.stacks == (0, 0)
      check foundation[] == DemoFoundationInitialSource
      dispose()

suite "committing box model fields":
  test "a typed side commits through its row's pipeline and is written inside the rule":
    createRoot proc(dispose: proc()) =
      let r = MockRenderer()
      let foundation = new(string)
      foundation[] = DemoFoundationInitialSource
      let vm = boxVm(foundation)
      let panel = renderInspectorPanel[MockRenderer, MockNode](r, vm)
      let top = panel.field("Padding top")
      need(top)
      let generation = vm.autoSaveGeneration.val
      top.fireEvent("focus")
      r.typeInto(top, "24")
      top.press("Enter")
      check vm.value("padding-top") == "24px"
      check vm.stacks == (1, 0)
      check vm.autoSaveGeneration.val == generation + 1
      check r.inputOf(top) == "24"
      # The padding side shares its Layout row's wiring: the row follows.
      check r.inputOf(panel.padRowInput("top")) == "24"
      check display(panel.boxMessage) == "none"
      vm.write()
      check foundation[] == DemoFoundationInitialSource.replace(
        ".destination-card { padding: 18px; }",
        ".destination-card { padding: 18px; padding-top: 24px; }")
      check vm.runEditorCommand(eckUndo).status == ecsSucceeded
      vm.write()
      check foundation[] == DemoFoundationInitialSource
      check r.inputOf(top) == "18"
      # A margin side, and leaving the field commits as Enter does.
      let left = panel.field("Margin left")
      need(left)
      r.typeInto(left, "10+2")
      left.fireEvent("blur")
      check vm.value("margin-left") == "12px"
      check r.inputOf(left) == "12"
      vm.write()
      check foundation[] == DemoFoundationInitialSource.replace(
        ".destination-card { padding: 18px; }",
        ".destination-card { padding: 18px; margin-left: 12px; }")
      dispose()

  test "the centre sets every padding side at once with the shorthand":
    createRoot proc(dispose: proc()) =
      let r = MockRenderer()
      let foundation = new(string)
      foundation[] = DemoFoundationInitialSource
      let vm = boxVm(foundation)
      let panel = renderInspectorPanel[MockRenderer, MockNode](r, vm)
      let centre = panel.field("Padding, all sides")
      need(centre)
      r.typeInto(centre, "20")
      centre.press("Enter")
      check vm.value("padding") == "20px"
      # One declaration, one edit; the sides follow the shorthand.
      check vm.stacks == (1, 0)
      for side in Sides:
        check vm.value("padding-" & side) == "20px"
        check r.inputOf(panel.field("Padding " & side)) == "20"
      vm.write()
      check foundation[] == DemoFoundationInitialSource.replace(
        ".destination-card { padding: 18px; }",
        ".destination-card { padding: 20px; }")
      check vm.runEditorCommand(eckUndo).status == ecsSucceeded
      vm.write()
      check foundation[] == DemoFoundationInitialSource
      check r.inputOf(centre) == "18"
      dispose()

  test "the margin ring's corner sets every margin side at once with the shorthand":
    createRoot proc(dispose: proc()) =
      let r = MockRenderer()
      let foundation = new(string)
      foundation[] = DemoFoundationInitialSource
      let vm = boxVm(foundation)
      let panel = renderInspectorPanel[MockRenderer, MockNode](r, vm)
      let corner = panel.field("Margin, all sides")
      need(corner)
      # The sides differ (4px 8px): Mixed, until it sets them all.
      check r.inputOf(corner) == ""
      r.typeInto(corner, "6")
      corner.press("Enter")
      check vm.value("margin") == "6px"
      check vm.stacks == (1, 0)
      for side in Sides:
        check vm.value("margin-" & side) == "6px"
        check r.inputOf(panel.field("Margin " & side)) == "6"
      check r.inputOf(corner) == "6"
      check attr(corner, "placeholder") == ""
      vm.write()
      check foundation[] == DemoFoundationInitialSource.replace(
        ".destination-card { padding: 18px; }",
        ".destination-card { padding: 18px; margin: 6px; }")
      check vm.runEditorCommand(eckUndo).status == ecsSucceeded
      vm.write()
      check foundation[] == DemoFoundationInitialSource
      check r.inputOf(panel.field("Margin left")) == "8"
      check r.inputOf(corner) == ""
      dispose()

  test "arrow keys step by 1, by 10 with Shift and by 0.1 with Alt, one commit each":
    createRoot proc(dispose: proc()) =
      let r = MockRenderer()
      let foundation = new(string)
      foundation[] = DemoFoundationInitialSource
      let vm = boxVm(foundation)
      let panel = renderInspectorPanel[MockRenderer, MockNode](r, vm)
      let top = panel.field("Padding top")
      need(top)
      top.press("ArrowUp")
      check vm.value("padding-top") == "19px"
      top.press("ArrowUp", shift = true)
      check vm.value("padding-top") == "29px"
      top.press("ArrowDown", alt = true)
      check vm.value("padding-top") == "28.9px"
      check vm.stacks == (3, 0)
      check r.inputOf(top) == "28.9"
      # Padding does not step below zero.
      let bottom = panel.field("Padding bottom")
      need(bottom)
      r.typeInto(bottom, "3")
      bottom.press("Enter")
      bottom.press("ArrowDown", shift = true)
      check vm.value("padding-bottom") == "0px"
      # A margin may be negative.
      let margin = panel.field("Margin top")
      need(margin)
      margin.press("ArrowDown", shift = true)
      check vm.value("margin-top") == "-6px"
      dispose()

  test "a horizontal drag scrubs and commits once; a press without travel only focuses":
    createRoot proc(dispose: proc()) =
      let r = MockRenderer()
      let foundation = new(string)
      foundation[] = DemoFoundationInitialSource
      let vm = boxVm(foundation)
      let panel = renderInspectorPanel[MockRenderer, MockNode](r, vm)
      let top = panel.field("Padding top")
      need(top)
      # A click: no travel, no edit; the field takes focus.
      top.pointer("pointerdown", 100)
      top.pointer("pointermove", 101)
      top.pointer("pointerup", 101)
      check vm.stacks == (0, 0)
      check r.activeElement() == top
      # A drag right increases (two units per pixel near the row), previews in
      # the field while it moves and commits one edit on release.
      top.pointer("pointerdown", 100)
      top.pointer("pointermove", 104)
      top.pointer("pointermove", 110)
      check r.inputOf(top) == "38"
      check vm.value("padding-top") == "18px"
      check vm.stacks == (0, 0)
      top.pointer("pointerup", 110)
      check vm.value("padding-top") == "38px"
      check vm.stacks == (1, 0)
      # Left decreases, and padding stops at zero.
      top.pointer("pointerdown", 100)
      top.pointer("pointermove", 20)
      check r.inputOf(top) == "0"
      top.pointer("pointerup", 20)
      check vm.value("padding-top") == "0px"
      check vm.stacks == (2, 0)
      # Cancelled: the value from before the drag, and no edit.
      top.pointer("pointerdown", 100)
      top.pointer("pointermove", 120)
      check r.inputOf(top) == "40"
      top.fireEvent("pointercancel")
      check r.inputOf(top) == "0"
      top.pointer("pointerup", 120)
      check vm.stacks == (2, 0)
      # Escape during a drag cancels it too.
      top.pointer("pointerdown", 100)
      top.pointer("pointermove", 110)
      top.press("Escape")
      check r.inputOf(top) == "0"
      top.pointer("pointerup", 110)
      check vm.stacks == (2, 0)
      check vm.value("padding-top") == "0px"
      dispose()

  test "Escape restores the committed value and an empty field commits nothing":
    createRoot proc(dispose: proc()) =
      let r = MockRenderer()
      let foundation = new(string)
      foundation[] = DemoFoundationInitialSource
      let vm = boxVm(foundation)
      let panel = renderInspectorPanel[MockRenderer, MockNode](r, vm)
      let right = panel.field("Margin right")
      need(right)
      r.typeInto(right, "40")
      right.press("Escape")
      check r.inputOf(right) == "8"
      right.fireEvent("blur")
      check vm.stacks == (0, 0)
      # Removing a declaration is Reset, in a row's menu.
      r.typeInto(right, "")
      right.press("Enter")
      check vm.stacks == (0, 0)
      check vm.value("margin-right") == "8px"
      check r.inputOf(right) == "8"
      # The value already in place is not an edit.
      r.typeInto(right, "8px")
      right.press("Enter")
      check vm.stacks == (0, 0)
      dispose()

suite "refusals":
  test "an invalid value is refused at the act, and the field is put back":
    createRoot proc(dispose: proc()) =
      let r = MockRenderer()
      let foundation = new(string)
      foundation[] = DemoFoundationInitialSource
      let vm = boxVm(foundation)
      let panel = renderInspectorPanel[MockRenderer, MockNode](r, vm)
      let left = panel.field("Padding left")
      need(left)
      let generation = vm.autoSaveGeneration.val
      for (text, reason) in [
          ("-4", "Padding and corner radius values cannot be negative."),
          ("4s", "This property requires a spatial CSS length unit.")]:
        r.typeInto(left, text)
        left.press("Enter")
        check reason in textOf(panel.boxMessage)
        check attr(panel.boxMessage, "role") == "alert"
        check display(panel.boxMessage) == "block"
        check r.inputOf(left) == "18"
        check vm.value("padding-left") == "18px"
      check vm.stacks == (0, 0)
      check vm.inspector.pendingSourceEdits.val.len == 0
      check vm.autoSaveGeneration.val == generation
      # The next accepted commit clears the reason.
      r.typeInto(left, "6")
      left.press("Enter")
      check vm.value("padding-left") == "6px"
      check display(panel.boxMessage) == "none"
      dispose()

  test "a side no project entry maps is refused with the writer's reason":
    createRoot proc(dispose: proc()) =
      let r = MockRenderer()
      let foundation = new(string)
      foundation[] = DemoFoundationInitialSource
      let vm = boxVm(foundation, mapSides = false)
      let panel = renderInspectorPanel[MockRenderer, MockNode](r, vm)
      let top = panel.field("Margin top")
      need(top)
      r.typeInto(top, "12")
      top.press("Enter")
      check "No project schema or source map entry can safely represent this edit" in
        textOf(panel.boxMessage)
      check r.inputOf(top) == "4"
      check vm.value("margin-top") == "4px"
      check vm.stacks == (0, 0)
      # The mapped shorthand is still written by the centre.
      let centre = panel.field("Padding, all sides")
      need(centre)
      r.typeInto(centre, "22")
      centre.press("Enter")
      check vm.value("padding") == "22px"
      vm.write()
      check foundation[] == DemoFoundationInitialSource.replace(
        ".destination-card { padding: 18px; }",
        ".destination-card { padding: 22px; }")
      dispose()

  test "a read-only workspace makes every field read-only with the reason":
    createRoot proc(dispose: proc()) =
      let r = MockRenderer()
      let foundation = new(string)
      foundation[] = DemoFoundationInitialSource
      let vm = boxVm(foundation, writable = false)
      let panel = renderInspectorPanel[MockRenderer, MockNode](r, vm)
      for label in ["Margin top", "Padding left", "Padding, all sides"]:
        let node = panel.field(label)
        check node != nil
        if node != nil:
          check attr(node, "readonly") == "true"
          check attr(node, "title") ==
            "This workspace is read-only for source changes."
      let top = panel.field("Padding top")
      need(top)
      r.typeInto(top, "30")
      top.press("Enter")
      check textOf(panel.boxMessage) ==
        "Padding top: This workspace is read-only for source changes."
      check r.inputOf(top) == "18"
      top.press("ArrowUp")
      top.pointer("pointerdown", 100)
      top.pointer("pointermove", 130)
      top.pointer("pointerup", 130)
      check vm.value("padding-top") == "18px"
      check vm.stacks == (0, 0)
      dispose()

  test "another selection clears the reason":
    createRoot proc(dispose: proc()) =
      let r = MockRenderer()
      let foundation = new(string)
      foundation[] = DemoFoundationInitialSource
      let vm = boxVm(foundation)
      let panel = renderInspectorPanel[MockRenderer, MockNode](r, vm)
      let left = panel.field("Padding left")
      need(left)
      r.typeInto(left, "-1")
      left.press("Enter")
      check display(panel.boxMessage) == "block"
      var other = boxElement()
      other.id = "destination-card-copy"
      check vm.selectInspectorElement(other)
      check display(panel.boxMessage) == "none"
      dispose()

  test "another selection discards a draft and a drag made on the previous one":
    createRoot proc(dispose: proc()) =
      let r = MockRenderer()
      let foundation = new(string)
      foundation[] = DemoFoundationInitialSource
      let vm = boxVm(foundation)
      let panel = renderInspectorPanel[MockRenderer, MockNode](r, vm)
      let left = panel.field("Padding left")
      need(left)
      var other = boxElement()
      other.id = "destination-card-copy"
      for prop in other.properties.mitems:
        if prop.name == "padding-left": prop.value = "7px"
      # A typed value not yet committed belongs to the element it was typed
      # for: another selection shows its own value, and leaving the field
      # afterwards applies nothing to it.
      r.typeInto(left, "30")
      check vm.selectInspectorElement(other)
      check r.inputOf(left) == "7"
      left.fireEvent("blur")
      left.press("Enter")
      check vm.value("padding-left") == "7px"
      check vm.stacks == (0, 0)
      # So does a drag in progress: released on the new selection, it commits
      # nothing.
      check vm.selectInspectorElement(boxElement())
      check r.inputOf(left) == "18"
      left.pointer("pointerdown", 100)
      left.pointer("pointermove", 110)
      check r.inputOf(left) == "38"
      check vm.selectInspectorElement(other)
      check r.inputOf(left) == "7"
      left.pointer("pointerup", 110)
      check vm.value("padding-left") == "7px"
      check vm.stacks == (0, 0)
      dispose()

  test "a Mixed all-sides field cannot be scrubbed, and says so":
    createRoot proc(dispose: proc()) =
      let r = MockRenderer()
      let foundation = new(string)
      foundation[] = DemoFoundationInitialSource
      let vm = boxVm(foundation)
      let panel = renderInspectorPanel[MockRenderer, MockNode](r, vm)
      let margins = panel.field("Margin, all sides")
      need(margins)
      check r.inputOf(margins) == ""
      margins.pointer("pointerdown", 100)
      margins.pointer("pointermove", 120)
      margins.pointer("pointerup", 120)
      check textOf(panel.boxMessage) == "Margin, all sides: The sides " &
        "differ (Mixed); type a value to set them all."
      check r.inputOf(margins) == ""
      check vm.stacks == (0, 0)
      dispose()

suite "scope, raw CSS, search and native projects":
  test "a padding side commits at the scope chosen on its row, which the box model shows":
    createRoot proc(dispose: proc()) =
      let r = MockRenderer()
      let foundation = new(string)
      foundation[] = DemoFoundationInitialSource
      let vm = boxVm(foundation)
      let panel = renderInspectorPanel[MockRenderer, MockNode](r, vm)
      let top = panel.field("Padding top")
      need(top)
      top.fireEvent("focus")
      # Closed, the box model mounts no scope chips (nor a hidden overflow
      # menu); open, it shows the focused field's.
      check findByAttr(panel, "aria-label",
        "Apply shared class scope for padding-top in the box model") == nil
      panel.toggle.fireEvent("click")
      let note = findByAttr(panel, "data-box-model-scope", "true")
      need(note)
      check textOf(note).startsWith("Padding top (padding-top) · Shared class")
      let boxShared = findByAttr(panel, "aria-label",
        "Apply shared class scope for padding-top in the box model")
      need(boxShared)
      check attr(boxShared, "aria-pressed") == "true"
      # Choose the local instance on the row (which re-commits the row's value
      # there): the box model's field commits there too, and says so.
      let rowLocal = findByAttr(findByAttr(panel, "data-property-row", "pad-top"),
        "aria-label", "Apply local instance scope for padding-top")
      need(rowLocal)
      rowLocal.fireEvent("click")
      check vm.stacks == (1, 0)
      check textOf(note).startsWith("Padding top (padding-top) · Local instance")
      let boxLocal = findByAttr(panel, "aria-label",
        "Apply local instance scope for padding-top in the box model")
      need(boxLocal)
      check attr(boxLocal, "aria-pressed") == "true"
      r.typeInto(top, "26")
      top.press("Enter")
      check vm.value("padding-top") == "26px"
      check vm.stacks == (2, 0)
      check vm.inspector.undoStack.val[^1].record.newValue == "26px"
      check vm.inspector.undoStack.val[^1].record.sourceScope == sskLocalInstance
      # Choosing a scope in the box model re-commits the field's value there,
      # as a row's chip does, and the row follows.
      let shared = findByAttr(panel, "aria-label",
        "Apply shared class scope for padding-top in the box model")
      need(shared)
      shared.fireEvent("click")
      check vm.stacks == (3, 0)
      check vm.inspector.undoStack.val[^1].record.sourceScope == sskSharedClass
      check vm.inspector.undoStack.val[^1].record.newValue == "26px"
      check textOf(note).startsWith("Padding top (padding-top) · Shared class")
      check attr(findByAttr(findByAttr(panel, "data-property-row", "pad-top"),
        "aria-label", "Apply shared class scope for padding-top"),
        "aria-pressed") == "true"
      # Focus follows to the margin: its own scope is shown.
      let margin = panel.field("Margin bottom")
      need(margin)
      margin.fireEvent("focus")
      check textOf(note).startsWith("Margin bottom (margin-bottom) · ")
      dispose()

  test "the margin sides are Layout's raw CSS; the search finds the box model by margin":
    createRoot proc(dispose: proc()) =
      let r = MockRenderer()
      let foundation = new(string)
      foundation[] = DemoFoundationInitialSource
      let vm = boxVm(foundation)
      let panel = renderInspectorPanel[MockRenderer, MockNode](r, vm)
      let raw = findByAttr(panel, "aria-label", "Show raw CSS for Layout section")
      need(raw)
      raw.fireEvent("click")
      let text = r.inputOf(findByAttr(panel, "aria-label",
        "Edit raw CSS for Layout section"))
      for side in Sides:
        check ("margin-" & side & ": " & vm.value("margin-" & side) & ";") in text
      raw.fireEvent("click")
      let layoutRow = findByAttr(panel, "data-inspector-section-row", "layout")
      need(layoutRow)
      let toggle = panel.toggle
      need(toggle)
      vm.inspector.setSectionSearch("margin")
      check display(layoutRow) == "flex"
      check attr(toggle, "data-inspector-search-match") == "true"
      vm.inspector.setSectionSearch("box model")
      check display(layoutRow) == "flex"
      # The border ring is Stroke's to edit: a border property does not list
      # Layout.
      vm.inspector.setSectionSearch("border-width")
      check display(layoutRow) == "none"
      check attr(toggle, "data-inspector-search-match") == "false"
      vm.inspector.setSectionSearch("")
      check display(layoutRow) == "flex"
      check attr(toggle, "data-inspector-search-match") == "false"
      dispose()

  test "a native source project receives the field's commit, and its refusal puts the field back":
    createRoot proc(dispose: proc()) =
      let r = MockRenderer()
      let foundation = new(string)
      foundation[] = DemoFoundationInitialSource
      let vm = boxVm(foundation)
      var sent: seq[(string, string, SourceScopeChoiceKind)] = @[]
      var answer = true
      vm.inspectorSourceCommit = proc(element: ElementRef; property, value: string;
          scope: SourceScopeChoiceKind; done: proc(ok: bool; diagnostic: string) {.closure.}) =
        sent.add (property, value, scope)
        if answer: done(true, "")
        else: done(false, "The project changed padding-right on disk.")
      let panel = renderInspectorPanel[MockRenderer, MockNode](r, vm)
      let right = panel.field("Padding right")
      need(right)
      r.typeInto(right, "2rem")
      right.press("Enter")
      check sent.len == 1
      if sent.len == 1:
        check sent[0][0] == "padding-right"
        check sent[0][1] == "2rem"
      check display(panel.boxMessage) == "none"
      answer = false
      r.typeInto(right, "30")
      right.press("Enter")
      check sent.len == 2
      check textOf(panel.boxMessage) ==
        "Padding right: The project changed padding-right on disk."
      check r.inputOf(right) == "18"
      dispose()

  test "a native source project is not asked to write what the editor can refuse itself":
    ## The native bridge decides its own writes, so the inspector checks what
    ## it can know before calling it: the selection exposes the property and
    ## the workspace is writable.
    createRoot proc(dispose: proc()) =
      let r = MockRenderer()
      let foundation = new(string)
      foundation[] = DemoFoundationInitialSource
      for writable in [true, false]:
        let vm = boxVm(foundation, writable = writable,
          element = if writable: demoInspectorElement() else: boxElement())
        var sent = 0
        vm.inspectorSourceCommit = proc(element: ElementRef; property, value: string;
            scope: SourceScopeChoiceKind; done: proc(ok: bool; diagnostic: string) {.closure.}) =
          inc sent
          done(true, "")
        let panel = renderInspectorPanel[MockRenderer, MockNode](r, vm)
        let top = panel.field("Padding top")
        need(top)
        r.typeInto(top, "30")
        top.press("Enter")
        check sent == 0
        check textOf(panel.boxMessage) == "Padding top: " &
          (if writable: "The selected element does not expose padding-top."
           else: "This workspace is read-only for source changes.")
        check r.inputOf(top) == "18"
      # A declaration the native project says it cannot write is read-only
      # with its reason, and is not sent.
      block:
        var element = boxElement()
        for prop in element.properties.mitems:
          if prop.name == "padding-top":
            prop.authoredValue = "18px"
            prop.nativeEditRefusal = "the declaration is inside an @media rule."
        let vm = boxVm(foundation, element = element)
        vm.hasAsyncSourceProject = true
        vm.sourceAdapterReady.val = true
        var sent = 0
        vm.inspectorSourceCommit = proc(element: ElementRef; property, value: string;
            scope: SourceScopeChoiceKind; done: proc(ok: bool; diagnostic: string) {.closure.}) =
          inc sent
          done(true, "")
        let panel = renderInspectorPanel[MockRenderer, MockNode](r, vm)
        let top = panel.field("Padding top")
        need(top)
        check attr(top, "title") ==
          "Read-only: the declaration is inside an @media rule."
        r.typeInto(top, "30")
        top.press("Enter")
        check sent == 0
        check textOf(panel.boxMessage) ==
          "Padding top: Read-only: the declaration is inside an @media rule."
      # An invalid value is refused by its validation before the bridge.
      let vm = boxVm(foundation)
      var sent = 0
      vm.inspectorSourceCommit = proc(element: ElementRef; property, value: string;
          scope: SourceScopeChoiceKind; done: proc(ok: bool; diagnostic: string) {.closure.}) =
        inc sent
        done(true, "")
      let panel = renderInspectorPanel[MockRenderer, MockNode](r, vm)
      let left = panel.field("Padding left")
      need(left)
      r.typeInto(left, "-3")
      left.press("Enter")
      check sent == 0
      check "Padding and corner radius values cannot be negative." in
        textOf(panel.boxMessage)
      check r.inputOf(left) == "18"
      dispose()

# The selection overlay's margin and padding handles (editor spec "Visual box
# model": "drag handles on canvas for live preview"). The preview frame draws
# them and previews a drag there; these cases drive what the frame asks the
# editor -- `beginBoxCanvasDrag`, `moveBoxCanvasDrag`, `commitBoxCanvasDrag`,
# `cancelBoxCanvasDrag`, exactly the calls `component_edit`'s bridge makes --
# against the mounted production inspector, whose box model shows the drag and
# commits it. The frame side (handles, capture, Escape, the preview rule) is
# the editor-example Playwright case
# `e2e_canvas_box_handles_preview_commit_cancel_and_refusal`.

proc recorder(outcomes: ref seq[BoxModelCommitOutcome]):
    proc(outcome: BoxModelCommitOutcome) {.closure.} =
  result = proc(outcome: BoxModelCommitOutcome) = outcomes[].add outcome

suite "canvas margin and padding handles":
  test "a handle follows the pointer: padding grows into the content, margin away from it":
    check boxCanvasHandles.len == 8
    # A padding handle on the content edge: down for top, up for bottom,
    # right for left, left for right add padding.
    check boxCanvasDragValue("padding-top", 18, 0, 6) == "24px"
    check boxCanvasDragValue("padding-bottom", 18, 0, -6) == "24px"
    check boxCanvasDragValue("padding-left", 18, 6, 0) == "24px"
    check boxCanvasDragValue("padding-right", 18, -6, 0) == "24px"
    # A margin handle on the margin edge: outwards adds margin.
    check boxCanvasDragValue("margin-top", 4, 0, -6) == "10px"
    check boxCanvasDragValue("margin-bottom", 4, 0, 6) == "10px"
    check boxCanvasDragValue("margin-left", 8, -2, 0) == "10px"
    check boxCanvasDragValue("margin-right", 8, 2, 0) == "10px"
    # The other axis is ignored; the value is whole pixels.
    check boxCanvasDragValue("padding-top", 18, 40, 2.6) == "21px"
    check boxCanvasDragValue("padding-top", 18.4, 0, 0) == "18px"
    # Padding stops at zero; a margin may go negative, without "-0".
    check boxCanvasDragValue("padding-top", 18, 0, -40) == "0px"
    check boxCanvasDragValue("margin-top", 4, 0, 10) == "-6px"
    check boxCanvasDragValue("margin-top", 0, 0, 0.2) == "0px"
    # Not a handle, or not a number: no value.
    check boxCanvasDragValue("border-top", 1, 0, 1) == ""
    check boxCanvasDragValue("padding-top", NaN, 0, 1) == ""
    check boxCanvasDragValue("padding-top", 1, Inf, 1) == ""
    # Shift at the press drags every side: the shorthand.
    check boxCanvasDragProperty("padding-left", false) == "padding-left"
    check boxCanvasDragProperty("padding-left", true) == "padding"
    check boxCanvasDragProperty("margin-top", true) == "margin"
    check boxCanvasDragProperty("gap", false) == ""

  test "a side's drag shows in its field as it moves and commits one edit on release":
    createRoot proc(dispose: proc()) =
      let r = MockRenderer()
      let foundation = new(string)
      foundation[] = DemoFoundationInitialSource
      let vm = boxVm(foundation)
      let panel = renderInspectorPanel[MockRenderer, MockNode](r, vm)
      let top = panel.field("Padding top")
      let centre = panel.field("Padding, all sides")
      need(top)
      need(centre)
      let generation = vm.autoSaveGeneration.val
      check vm.beginBoxCanvasDrag("padding-top", false) == "padding-top"
      check vm.moveBoxCanvasDrag(18, 0, 3) == "21px"
      check vm.moveBoxCanvasDrag(18, 0, 6) == "24px"
      # The field shows the drag, the all-sides field sees the sides differ,
      # and nothing is committed yet.
      check r.inputOf(top) == "24"
      check attr(top, "data-box-model-draft") == "true"
      check attr(top, "data-committed-value") == "18"
      check r.inputOf(centre) == ""
      check r.inputOf(panel.field("Padding left")) == "18"
      check r.inputOf(panel.padRowInput("top")) == "18"
      check vm.value("padding-top") == "18px"
      check vm.stacks == (0, 0)
      let outcomes = new(seq[BoxModelCommitOutcome])
      check vm.commitBoxCanvasDrag(recorder(outcomes))
      check outcomes[].len == 1
      check outcomes[][0].ok
      check vm.value("padding-top") == "24px"
      check vm.stacks == (1, 0)
      check vm.autoSaveGeneration.val == generation + 1
      check vm.inspector.boxCanvasDraft.val.property == ""
      check r.inputOf(top) == "24"
      check attr(top, "data-box-model-draft") == "false"
      # Its Layout row shares the wiring, and follows.
      check r.inputOf(panel.padRowInput("top")) == "24"
      check display(panel.boxMessage) == "none"
      vm.write()
      check foundation[] == DemoFoundationInitialSource.replace(
        ".destination-card { padding: 18px; }",
        ".destination-card { padding: 18px; padding-top: 24px; }")
      check vm.runEditorCommand(eckUndo).status == ecsSucceeded
      vm.write()
      check foundation[] == DemoFoundationInitialSource
      check r.inputOf(top) == "18"
      dispose()

  test "a padding side's drag commits at the scope chosen on its Layout row":
    createRoot proc(dispose: proc()) =
      let r = MockRenderer()
      let foundation = new(string)
      foundation[] = DemoFoundationInitialSource
      let vm = boxVm(foundation)
      let panel = renderInspectorPanel[MockRenderer, MockNode](r, vm)
      let rowLocal = findByAttr(findByAttr(panel, "data-property-row", "pad-top"),
        "aria-label", "Apply local instance scope for padding-top")
      need(rowLocal)
      rowLocal.fireEvent("click")
      check vm.stacks == (1, 0)
      let outcomes = new(seq[BoxModelCommitOutcome])
      check vm.beginBoxCanvasDrag("padding-top", false) == "padding-top"
      check vm.moveBoxCanvasDrag(18, 0, 8) == "26px"
      check vm.commitBoxCanvasDrag(recorder(outcomes))
      check outcomes[].len == 1 and outcomes[][0].ok
      check vm.stacks == (2, 0)
      check vm.inspector.undoStack.val[^1].record.newValue == "26px"
      check vm.inspector.undoStack.val[^1].record.sourceScope == sskLocalInstance
      dispose()

  test "Shift at the press drags every side, with the shorthand, as one edit":
    createRoot proc(dispose: proc()) =
      let r = MockRenderer()
      let foundation = new(string)
      foundation[] = DemoFoundationInitialSource
      let vm = boxVm(foundation)
      let panel = renderInspectorPanel[MockRenderer, MockNode](r, vm)
      check vm.beginBoxCanvasDrag("padding-left", true) == "padding"
      check vm.moveBoxCanvasDrag(18, 6, 0) == "24px"
      for label in ["Padding top", "Padding right", "Padding bottom",
          "Padding left", "Padding, all sides"]:
        check r.inputOf(panel.field(label)) == "24"
      check r.inputOf(panel.field("Margin top")) == "4"
      let outcomes = new(seq[BoxModelCommitOutcome])
      check vm.commitBoxCanvasDrag(recorder(outcomes))
      check outcomes[].len == 1 and outcomes[][0].ok
      check vm.value("padding") == "24px"
      check vm.stacks == (1, 0)
      vm.write()
      check foundation[] == DemoFoundationInitialSource.replace(
        ".destination-card { padding: 18px; }",
        ".destination-card { padding: 24px; }")
      dispose()

  test "a margin handle commits its margin side":
    createRoot proc(dispose: proc()) =
      let r = MockRenderer()
      let foundation = new(string)
      foundation[] = DemoFoundationInitialSource
      let vm = boxVm(foundation)
      let panel = renderInspectorPanel[MockRenderer, MockNode](r, vm)
      check vm.beginBoxCanvasDrag("margin-bottom", false) == "margin-bottom"
      check vm.moveBoxCanvasDrag(4, 0, 10) == "14px"
      check r.inputOf(panel.field("Margin bottom")) == "14"
      let outcomes = new(seq[BoxModelCommitOutcome])
      check vm.commitBoxCanvasDrag(recorder(outcomes))
      check outcomes[].len == 1 and outcomes[][0].ok
      check vm.value("margin-bottom") == "14px"
      check vm.stacks == (1, 0)
      vm.write()
      check foundation[] == DemoFoundationInitialSource.replace(
        ".destination-card { padding: 18px; }",
        ".destination-card { padding: 18px; margin-bottom: 14px; }")
      dispose()

  test "cancelling, or releasing without moving, commits nothing and puts the fields back":
    createRoot proc(dispose: proc()) =
      let r = MockRenderer()
      let foundation = new(string)
      foundation[] = DemoFoundationInitialSource
      let vm = boxVm(foundation)
      let panel = renderInspectorPanel[MockRenderer, MockNode](r, vm)
      let right = panel.field("Padding right")
      need(right)
      let outcomes = new(seq[BoxModelCommitOutcome])
      # Escape, pointer cancellation or a lost capture.
      check vm.beginBoxCanvasDrag("padding-right", false) == "padding-right"
      check vm.moveBoxCanvasDrag(18, -12, 0) == "30px"
      check r.inputOf(right) == "30"
      vm.cancelBoxCanvasDrag()
      check r.inputOf(right) == "18"
      check attr(right, "data-box-model-draft") == "false"
      check not vm.commitBoxCanvasDrag(recorder(outcomes))
      # A press that never moved.
      check vm.beginBoxCanvasDrag("padding-right", false) == "padding-right"
      check not vm.commitBoxCanvasDrag(recorder(outcomes))
      # A drag back to where it started commits nothing either.
      check vm.beginBoxCanvasDrag("padding-right", false) == "padding-right"
      check vm.moveBoxCanvasDrag(18, 0, 0) == "18px"
      check vm.commitBoxCanvasDrag(recorder(outcomes))
      check outcomes[].len == 1 and outcomes[][0].ok and not outcomes[][0].changed
      check vm.value("padding-right") == "18px"
      check vm.stacks == (0, 0)
      check foundation[] == DemoFoundationInitialSource
      # Not a handle, or nothing selected: no drag starts.
      check vm.beginBoxCanvasDrag("gap", false) == ""
      vm.clearInspectorSelection()
      check vm.beginBoxCanvasDrag("padding-top", false) == ""
      dispose()

  test "another selection discards a drag started on the previous one":
    createRoot proc(dispose: proc()) =
      let r = MockRenderer()
      let foundation = new(string)
      foundation[] = DemoFoundationInitialSource
      let vm = boxVm(foundation)
      let panel = renderInspectorPanel[MockRenderer, MockNode](r, vm)
      let top = panel.field("Padding top")
      need(top)
      var other = boxElement()
      other.id = "destination-card-copy"
      for prop in other.properties.mitems:
        if prop.name == "padding-top": prop.value = "7px"
      let outcomes = new(seq[BoxModelCommitOutcome])
      check vm.beginBoxCanvasDrag("padding-top", false) == "padding-top"
      check vm.moveBoxCanvasDrag(18, 0, 6) == "24px"
      check vm.selectInspectorElement(other)
      # The new selection's field shows its own value, not the drag.
      check r.inputOf(top) == "7"
      check attr(top, "data-box-model-draft") == "false"
      # The frame's next move learns the drag is over; the release commits
      # nothing, to either element.
      check vm.moveBoxCanvasDrag(18, 0, 8) == ""
      check not vm.commitBoxCanvasDrag(recorder(outcomes))
      # Released straight after the selection changed: the same.
      check vm.selectInspectorElement(boxElement())
      check vm.beginBoxCanvasDrag("padding-top", false) == "padding-top"
      check vm.moveBoxCanvasDrag(18, 0, 6) == "24px"
      check vm.selectInspectorElement(other)
      check not vm.commitBoxCanvasDrag(recorder(outcomes))
      check outcomes[].len == 0
      check vm.value("padding-top") == "7px"
      check vm.stacks == (0, 0)
      check foundation[] == DemoFoundationInitialSource
      dispose()

  test "a refused drag puts the field back and says why":
    createRoot proc(dispose: proc()) =
      let r = MockRenderer()
      let foundation = new(string)
      foundation[] = DemoFoundationInitialSource
      let vm = boxVm(foundation, mapSides = false)
      let panel = renderInspectorPanel[MockRenderer, MockNode](r, vm)
      let top = panel.field("Padding top")
      need(top)
      let outcomes = new(seq[BoxModelCommitOutcome])
      check vm.beginBoxCanvasDrag("padding-top", false) == "padding-top"
      check vm.moveBoxCanvasDrag(18, 0, 12) == "30px"
      check r.inputOf(top) == "30"
      check vm.commitBoxCanvasDrag(recorder(outcomes))
      check outcomes[].len == 1
      check not outcomes[][0].ok
      check "No project schema or source map entry can safely represent this edit" in
        outcomes[][0].message
      check textOf(panel.boxMessage) == "Padding top: " & outcomes[][0].message
      check r.inputOf(top) == "18"
      check vm.value("padding-top") == "18px"
      check vm.stacks == (0, 0)
      check foundation[] == DemoFoundationInitialSource
      dispose()

  test "a read-only workspace refuses a drag with the reason":
    createRoot proc(dispose: proc()) =
      let r = MockRenderer()
      let foundation = new(string)
      foundation[] = DemoFoundationInitialSource
      let vm = boxVm(foundation, writable = false)
      let panel = renderInspectorPanel[MockRenderer, MockNode](r, vm)
      let outcomes = new(seq[BoxModelCommitOutcome])
      check vm.beginBoxCanvasDrag("margin-left", true) == "margin"
      check vm.moveBoxCanvasDrag(8, -4, 0) == "12px"
      check vm.commitBoxCanvasDrag(recorder(outcomes))
      check outcomes[].len == 1
      check not outcomes[][0].ok
      check outcomes[][0].message == "This workspace is read-only for source changes."
      check textOf(panel.boxMessage) ==
        "Margin, all sides: This workspace is read-only for source changes."
      check vm.stacks == (0, 0)
      dispose()

  test "without a mounted box model a release is refused, not lost":
    let foundation = new(string)
    foundation[] = DemoFoundationInitialSource
    var vm: EditorVM
    createRoot proc(dispose: proc()) =
      let r = MockRenderer()
      vm = boxVm(foundation)
      discard renderInspectorPanel[MockRenderer, MockNode](r, vm)
      check vm.inspector.boxCanvasCommit != nil
      dispose()
    # Disposing the panel takes its commit with it.
    check vm.inspector.boxCanvasCommit == nil
    let outcomes = new(seq[BoxModelCommitOutcome])
    check vm.beginBoxCanvasDrag("padding-top", false) == "padding-top"
    check vm.moveBoxCanvasDrag(18, 0, 6) == "24px"
    check vm.commitBoxCanvasDrag(recorder(outcomes))
    check outcomes[].len == 1
    check not outcomes[][0].ok
    check outcomes[][0].message ==
      "The box model is not available to commit padding-top."
    check vm.value("padding-top") == "18px"
    check vm.stacks == (0, 0)

  test "a native source project receives the drag's commit, and its later answer settles it":
    createRoot proc(dispose: proc()) =
      let r = MockRenderer()
      let foundation = new(string)
      foundation[] = DemoFoundationInitialSource
      let vm = boxVm(foundation)
      var asked: seq[(string, string)] = @[]
      var answer: proc(ok: bool; diagnostic: string)
      vm.inspectorSourceCommit = proc(element: ElementRef; property, value: string;
          scope: SourceScopeChoiceKind;
          done: proc(ok: bool; diagnostic: string) {.closure.}) =
        asked.add (property, value)
        answer = done
      let panel = renderInspectorPanel[MockRenderer, MockNode](r, vm)
      let outcomes = new(seq[BoxModelCommitOutcome])
      check vm.beginBoxCanvasDrag("padding-bottom", false) == "padding-bottom"
      check vm.moveBoxCanvasDrag(18, 0, -2) == "20px"
      check vm.commitBoxCanvasDrag(recorder(outcomes))
      check asked == @[("padding-bottom", "20px")]
      # Nothing is settled until the project answers.
      check outcomes[].len == 0
      check answer != nil
      if answer != nil: answer(false, "Refused by the project.")
      check outcomes[].len == 1
      check not outcomes[][0].ok
      check outcomes[][0].message == "Refused by the project."
      check textOf(panel.boxMessage) == "Padding bottom: Refused by the project."
      dispose()

  test "a drag keeps the side's authored unit, as the field's scrub does":
    # Pixels, or no authored value, give whole pixels.
    check boxCanvasDragValue("padding-top", 18, 0, 6, "18px") == "24px"
    check boxCanvasDragValue("padding-top", 18, 0, 6, "18") == "24px"
    check boxCanvasDragValue("padding-top", 18, 0, 6) == "24px"
    # Another unit moves by the whole pixels dragged at its used ratio:
    # 1.5rem used as 24px is 1/16rem per pixel.
    check boxCanvasDragValue("padding-top", 24, 0, 6, "1.5rem") == "1.875rem"
    check boxCanvasDragValue("padding-top", 24, 0, 5.6, "1.5rem") == "1.875rem"
    check boxCanvasDragValue("padding-left", 40, 4, 0, "10%") == "11%"
    check boxCanvasDragValue("margin-top", 16, 0, 32, "1em") == "-1em"
    # A drag back to the start gives back the authored value, at its
    # precision; padding still stops at zero.
    check boxCanvasDragValue("padding-top", 20.8, 0, 0, "1.3rem") == "1.3rem"
    check boxCanvasDragValue("padding-top", 24, 0, -40, "1.5rem") == "0rem"
    # A zero has no ratio: pixels.
    check boxCanvasDragValue("padding-top", 0, 0, 6, "0rem") == "6px"
    createRoot proc(dispose: proc()) =
      let r = MockRenderer()
      let foundation = new(string)
      foundation[] = DemoFoundationInitialSource
      var element = boxElement()
      for prop in element.properties.mitems:
        if prop.name == "padding-top": prop.value = "1.5rem"
      let vm = boxVm(foundation, element = element)
      let panel = renderInspectorPanel[MockRenderer, MockNode](r, vm)
      let top = panel.field("Padding top")
      need(top)
      check r.inputOf(top) == "1.5rem"
      check vm.beginBoxCanvasDrag("padding-top", false) == "padding-top"
      check vm.moveBoxCanvasDrag(24, 0, 6) == "1.875rem"
      check r.inputOf(top) == "1.875rem"
      let outcomes = new(seq[BoxModelCommitOutcome])
      check vm.commitBoxCanvasDrag(recorder(outcomes))
      check outcomes[].len == 1 and outcomes[][0].ok
      check vm.value("padding-top") == "1.875rem"
      check vm.stacks == (1, 0)
      dispose()

  test "a side that is not a number is refused at the press with the field's reason":
    createRoot proc(dispose: proc()) =
      let r = MockRenderer()
      let foundation = new(string)
      foundation[] = DemoFoundationInitialSource
      var element = boxElement()
      for prop in element.properties.mitems:
        if prop.name == "margin-left": prop.value = "auto"
        if prop.name == "padding-top": prop.value = "var(--wl-space-card)"
      let vm = boxVm(foundation, element = element)
      let panel = renderInspectorPanel[MockRenderer, MockNode](r, vm)
      check vm.boxCanvasDragRefusal("margin-left") ==
        "Margin left: Type a numeric value to replace auto."
      check vm.boxCanvasDragRefusal("padding-top") ==
        "Padding top: Type a numeric value to replace var(--wl-space-card)."
      # Shift (every side) starts from the same side, and is refused too.
      for allSides in [false, true]:
        check vm.beginBoxCanvasDrag("margin-left", allSides) == ""
        check vm.beginBoxCanvasDrag("padding-top", allSides) == ""
      check vm.inspector.boxCanvasDraft.val.property == ""
      check vm.moveBoxCanvasDrag(200, -6, 0) == ""
      check r.inputOf(panel.field("Margin left")) == "auto"
      # A numeric side of the same element still drags.
      check vm.boxCanvasDragRefusal("margin-right") == ""
      check vm.beginBoxCanvasDrag("margin-right", false) == "margin-right"
      check vm.moveBoxCanvasDrag(8, 2, 0) == "10px"
      vm.cancelBoxCanvasDrag()
      check vm.boxCanvasDragRefusal("gap") == ""
      check vm.stacks == (0, 0)
      check foundation[] == DemoFoundationInitialSource
      dispose()
