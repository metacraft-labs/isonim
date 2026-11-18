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
    element = boxElement(); alsoMapped: seq[string] = @[];
    orderless = false): EditorVM =
  let vector = new(string)
  vector[] = "<svg/>"
  let story = StoryRef(group: "DestinationCard", name: "Default",
    kind: skComponent, index: 0)
  var schema = demoDesignSystemSchema()
  var adapter = demoVectorEditAdapter(vector, foundation)
  # A writer that does not report its rules' declarations.
  if orderless:
    adapter.ruleDeclarations = nil
    adapter.editRule = nil
  if mapSides:
    for property in @MappedSides & alsoMapped:
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
    # A step is exact to the finer of the value's and the step's precision:
    # binary64 noise is dropped and authored digits finer than any fixed
    # rounding are kept.
    check boxModelSteppedValue("1.1", 0.1) == "1.2px"
    check boxModelSteppedValue("0.7rem", 0.1) == "0.8rem"
    check boxModelSteppedValue("0.3", -0.1) == "0.2px"
    check boxModelSteppedValue("-0.7px", -0.1) == "-0.8px"
    check boxModelSteppedValue("10.1", -10.0) == "0.1px"
    check boxModelSteppedValue("-0.1rem", 0.1) == "0rem"
    check boxModelSteppedValue("1.23456rem", 1.0) == "2.23456rem"
    check boxModelSteppedValue("1.234567px", 0.1) == "1.334567px"
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

const CardRule = ".destination-card { padding: 18px; }"

proc withCardRule(body: string): string =
  ## The example's foundation source with the card's rule set to ``body``.
  DemoFoundationInitialSource.replace(CardRule,
    ".destination-card { " & body & " }")

proc commitField(r: MockRenderer; panel: MockNode; label, value: string) =
  let node = panel.field(label)
  check node != nil
  if node == nil: return
  node.fireEvent("focus")
  r.typeInto(node, value)
  node.press("Enter")

proc sides(vm: EditorVM; prefix: string): seq[string] =
  for side in Sides: result.add vm.value(prefix & side)

proc followers(vm: EditorVM): seq[(string, string)] =
  ## What the preview sets after the last edit's own declaration.
  let history = vm.inspector.undoStack.val
  if history.len > 0: history[^1].sideFollowersAfter else: @[]

const BaseCard = ".destination-card"
const MediaCard = "@media (max-width: 640px) .destination-card"

proc measuredCard(sides: openArray[(string, (string, string))];
    padding = "18px"; matched = @[BaseCard, MediaCard]): ElementRef =
  ## The card as a capture that measured its sides reports it: each side's
  ## computed value and the declaration block that decides it
  ## (`decidingRule`), as the preview bridge's probe names it. ``padding`` is
  ## the shorthand as the rule authors it.
  result = boxElement()
  result.matchedRules = matched
  for prop in result.properties.mitems:
    if prop.name == "padding": prop.value = padding
    for (name, measured) in sides:
      if prop.name == name:
        prop.value = measured[0]
        prop.decidingRule = measured[1]

proc recaptured(vm: EditorVM; values: openArray[(string, string)]) =
  ## Select the card again as a fresh preview capture reports it: computed
  ## values, no provenance, nothing remembered from earlier edits.
  var element = boxElement()
  for prop in element.properties.mitems:
    for (name, value) in values:
      if prop.name == name: prop.value = value
  discard vm.selectInspectorElement(ElementRef())
  check vm.selectInspectorElement(element)

suite "shorthand sides follow the rule's declaration order":
  ## CSS cascade within one declaration block: an `!important` declaration
  ## over a normal one, otherwise the later one wins
  ## (https://www.w3.org/TR/css-cascade-4/#cascade-sort). Editor spec
  ## "Native project source capabilities": sides "respect declaration
  ## order"; "Visual box model": an all-sides field is `Mixed` when the sides
  ## differ. isonim-pm issue 2026-10-23-a-shorthand-edit-is-shown-on-sides-a-
  ## later-longhand-still-overrides. The writer is the example's own; each
  ## case asserts the file it wrote, so the expected sides are read off the
  ## real declaration order.
  test "a side declared after the shorthand keeps its value; undo, redo and recapture agree":
    createRoot proc(dispose: proc()) =
      let r = MockRenderer()
      let foundation = new(string)
      foundation[] = DemoFoundationInitialSource
      let vm = boxVm(foundation)
      let panel = renderInspectorPanel[MockRenderer, MockNode](r, vm)
      r.commitField(panel, "Padding top", "24")
      vm.write()
      check foundation[] == withCardRule("padding: 18px; padding-top: 24px;")
      r.commitField(panel, "Padding, all sides", "20")
      check vm.value("padding") == "20px"
      check vm.sides("padding-") == @["24px", "20px", "20px", "20px"]
      check r.inputOf(panel.field("Padding top")) == "24"
      check r.inputOf(panel.padRowInput("top")) == "24"
      check r.inputOf(panel.field("Padding, all sides")) == ""
      check panel.field("Padding, all sides").attr("placeholder") == "Mixed"
      check vm.followers == @[("padding-top", "24px"), ("padding-right", "20px"),
        ("padding-bottom", "20px"), ("padding-left", "20px")]
      vm.write()
      check foundation[] == withCardRule("padding: 20px; padding-top: 24px;")
      check vm.runEditorCommand(eckUndo).status == ecsSucceeded
      check vm.sides("padding-") == @["24px", "18px", "18px", "18px"]
      check vm.runEditorCommand(eckRedo).status == ecsSucceeded
      check vm.sides("padding-") == @["24px", "20px", "20px", "20px"]
      vm.write()
      # Captured again: nothing from the earlier edits is on the selection,
      # and the file still decides.
      vm.recaptured({"padding": "20px", "padding-top": "24px", "padding-right": "20px",
        "padding-bottom": "20px", "padding-left": "20px"})
      r.commitField(panel, "Padding, all sides", "22")
      check vm.sides("padding-") == @["24px", "22px", "22px", "22px"]
      vm.write()
      check foundation[] == withCardRule("padding: 22px; padding-top: 24px;")
      # Reset of the later side: the shorthand decides it again.
      check vm.editCssProperty("padding-top", "", pesShared).status == pesAccepted
      check vm.value("padding-top") == "22px"
      vm.write()
      check foundation[] == withCardRule("padding: 22px;")
      dispose()

  test "a margin shorthand inserted after its side reaches it":
    createRoot proc(dispose: proc()) =
      let r = MockRenderer()
      let foundation = new(string)
      foundation[] = DemoFoundationInitialSource
      let vm = boxVm(foundation)
      let panel = renderInspectorPanel[MockRenderer, MockNode](r, vm)
      r.commitField(panel, "Margin top", "10")
      r.commitField(panel, "Margin, all sides", "6")
      check vm.sides("margin-") == @["6px", "6px", "6px", "6px"]
      check r.inputOf(panel.field("Margin, all sides")) == "6"
      vm.write()
      check foundation[] == withCardRule("padding: 18px; margin-top: 10px; margin: 6px;")
      check vm.runEditorCommand(eckUndo).status == ecsSucceeded
      check vm.sides("margin-") == @["10px", "8px", "4px", "8px"]
      dispose()

  test "after Reset, a side set before the shorthand is overridden by it":
    createRoot proc(dispose: proc()) =
      let r = MockRenderer()
      let foundation = new(string)
      foundation[] = DemoFoundationInitialSource
      let vm = boxVm(foundation)
      let panel = renderInspectorPanel[MockRenderer, MockNode](r, vm)
      check vm.editCssProperty("padding", "", pesShared).status == pesAccepted
      vm.write()
      r.commitField(panel, "Padding top", "24")
      r.commitField(panel, "Padding, all sides", "20")
      vm.write()
      check foundation[] == withCardRule("padding-top: 24px; padding: 20px;")
      check vm.sides("padding-") == @["20px", "20px", "20px", "20px"]
      check r.inputOf(panel.field("Padding, all sides")) == "20"
      dispose()

  test "a side a later shorthand in the same rule overrides is refused at the act":
    ## Operator decision of 2026-11-05 (overridden side, option B): an edit of
    ## a side that a later or `!important` shorthand in the same rule still
    ## overrides would change nothing that renders, so it is refused at the
    ## act with that reason, and nothing changes (editor spec "Saving": a
    ## refusal the editor can know at the act is made at the act).
    createRoot proc(dispose: proc()) =
      let r = MockRenderer()
      let foundation = new(string)
      let declared = withCardRule("padding-top: 24px; padding: 18px;")
      foundation[] = declared
      let vm = boxVm(foundation)
      let panel = renderInspectorPanel[MockRenderer, MockNode](r, vm)
      r.commitField(panel, "Padding top", "30")
      check vm.stacks == (0, 0)
      check vm.inspector.pendingSourceEdits.val.len == 0
      check vm.value("padding-top") == "18px"
      check r.inputOf(panel.field("Padding top")) == "18"
      check textOf(panel.boxMessage) == "Padding top: A later `padding` " &
        "declaration in `.destination-card` overrides padding-top, so this " &
        "edit would not change it. Nothing was changed."
      check foundation[] == declared
      # The shorthand itself can still be set, and reaches the side.
      r.commitField(panel, "Padding, all sides", "20")
      check vm.sides("padding-") == @["20px", "20px", "20px", "20px"]
      dispose()

  test "a corner radius declared after border-radius keeps its value":
    createRoot proc(dispose: proc()) =
      let foundation = new(string)
      foundation[] = withCardRule("padding: 18px; border-radius: 14px;")
      var element = boxElement()
      for prop in element.properties.mitems:
        if prop.name == "border-radius":
          prop = cardProperty("border-radius", "14px")
      for corner in ["border-top-left-radius", "border-top-right-radius",
          "border-bottom-right-radius", "border-bottom-left-radius"]:
        element.properties.add cardProperty(corner, "14px")
      let vm = boxVm(foundation, element = element, alsoMapped = @[
        "border-radius", "border-top-left-radius"])
      check vm.editCssProperty("border-top-left-radius", "8px",
        pesShared).status == pesAccepted
      check vm.editCssProperty("border-radius", "12px",
        pesShared).status == pesAccepted
      vm.write()
      check foundation[] == withCardRule(
        "padding: 18px; border-radius: 12px; border-top-left-radius: 8px;")
      check vm.value("border-top-left-radius") == "8px"
      check vm.value("border-top-right-radius") == "12px"
      check vm.value("border-bottom-left-radius") == "12px"
      dispose()

  test "a side an @media rule decides is not moved by the base rule's shorthand":
    createRoot proc(dispose: proc()) =
      let r = MockRenderer()
      let foundation = new(string)
      foundation[] = DemoFoundationInitialSource.replace(
        ".destination-card { font-size: 13px; }",
        ".destination-card { font-size: 13px; padding-top: 30px; }")
      var element = boxElement()
      for prop in element.properties.mitems:
        if prop.name == "padding-top": prop.value = "30px"
      let vm = boxVm(foundation, element = element)
      let panel = renderInspectorPanel[MockRenderer, MockNode](r, vm)
      r.commitField(panel, "Padding, all sides", "20")
      check vm.sides("padding-") == @["30px", "20px", "20px", "20px"]
      check vm.followers == @[("padding-right", "20px"),
        ("padding-bottom", "20px"), ("padding-left", "20px")]
      dispose()

  test "!important decides over declaration order, on either declaration":
    createRoot proc(dispose: proc()) =
      let r = MockRenderer()
      let foundation = new(string)
      foundation[] = withCardRule("padding-top: 24px !important; padding: 18px;")
      var element = boxElement()
      for prop in element.properties.mitems:
        if prop.name == "padding-top": prop.value = "24px"
      let vm = boxVm(foundation, element = element)
      let panel = renderInspectorPanel[MockRenderer, MockNode](r, vm)
      r.commitField(panel, "Padding, all sides", "20")
      check vm.sides("padding-") == @["24px", "20px", "20px", "20px"]
      check vm.followers[0] == ("padding-top", "24px !important")
      vm.write()
      check foundation[] == withCardRule("padding-top: 24px !important; padding: 20px;")
      # The shorthand important, the side after it: the shorthand decides.
      foundation[] = withCardRule("padding: 18px !important; padding-top: 24px;")
      vm.recaptured({"padding": "18px !important", "padding-top": "18px"})
      r.commitField(panel, "Padding top", "30")
      check vm.value("padding-top") == "18px"
      check vm.inspector.pendingSourceEdits.val.len == 0
      check textOf(panel.boxMessage) == "Padding top: The `!important` " &
        "`padding` declaration in `.destination-card` overrides padding-top, " &
        "so this edit would not change it. Nothing was changed."
      dispose()

  test "a side an @media rule decides keeps its value when the base rule is not in pixels":
    ## Issue 2026-11-04-a-shorthand-edit-moves-a-side-another-rule-decides-
    ## when-units-differ, case 1: `1rem` against a captured 30px top cannot be
    ## compared; the capture's measurement of which rule decides the side can.
    createRoot proc(dispose: proc()) =
      let r = MockRenderer()
      let foundation = new(string)
      foundation[] = withCardRule("padding: 1rem;").replace(
        ".destination-card { font-size: 13px; }",
        ".destination-card { font-size: 13px; padding-top: 30px; }")
      let vm = boxVm(foundation, element = measuredCard({
        "padding-top": ("30px", MediaCard), "padding-right": ("16px", BaseCard),
        "padding-bottom": ("16px", BaseCard), "padding-left": ("16px", BaseCard)},
        padding = "1rem"))
      let panel = renderInspectorPanel[MockRenderer, MockNode](r, vm)
      r.commitField(panel, "Padding, all sides", "20")
      check vm.sides("padding-") == @["30px", "20px", "20px", "20px"]
      check vm.followers == @[("padding-right", "20px"),
        ("padding-bottom", "20px"), ("padding-left", "20px")]
      check r.inputOf(panel.field("Padding, all sides")) == ""
      dispose()

  test "a side an @media rule decides with the base rule's own value is not moved":
    ## Case 3: the values coincide (18px both), so only the capture's
    ## measurement can say the @media rule decides the top.
    createRoot proc(dispose: proc()) =
      let r = MockRenderer()
      let foundation = new(string)
      foundation[] = DemoFoundationInitialSource.replace(
        ".destination-card { font-size: 13px; }",
        ".destination-card { font-size: 13px; padding-top: 18px; }")
      let vm = boxVm(foundation, element = measuredCard({
        "padding-top": ("18px", MediaCard), "padding-right": ("18px", BaseCard),
        "padding-bottom": ("18px", BaseCard), "padding-left": ("18px", BaseCard)}))
      let panel = renderInspectorPanel[MockRenderer, MockNode](r, vm)
      r.commitField(panel, "Padding, all sides", "20")
      check vm.sides("padding-") == @["18px", "20px", "20px", "20px"]
      check vm.followers.len == 3
      dispose()

  test "a side nothing declared is decided by the rule once it declares it":
    createRoot proc(dispose: proc()) =
      let r = MockRenderer()
      let foundation = new(string)
      foundation[] = DemoFoundationInitialSource
      let vm = boxVm(foundation, element = measuredCard({
        "margin-top": ("4px", "none"), "margin-right": ("8px", "none"),
        "margin-bottom": ("4px", "none"), "margin-left": ("8px", "none")}))
      let panel = renderInspectorPanel[MockRenderer, MockNode](r, vm)
      r.commitField(panel, "Margin, all sides", "6")
      check vm.sides("margin-") == @["6px", "6px", "6px", "6px"]
      dispose()

  test "a side an edit declares is the rule's for the next edit, before any capture":
    ## The measurement on the selection follows the editor's own edits: the
    ## side Margin top declared is the rule's when Margin, all sides is
    ## inserted after it, so its undo puts the side back in the preview.
    createRoot proc(dispose: proc()) =
      let r = MockRenderer()
      let foundation = new(string)
      foundation[] = DemoFoundationInitialSource
      let vm = boxVm(foundation, element = measuredCard({
        "margin-top": ("4px", "none"), "margin-right": ("8px", "none"),
        "margin-bottom": ("4px", "none"), "margin-left": ("8px", "none")}))
      let panel = renderInspectorPanel[MockRenderer, MockNode](r, vm)
      r.commitField(panel, "Margin top", "10")
      r.commitField(panel, "Margin, all sides", "6")
      let history = vm.inspector.undoStack.val
      check history[^1].sideFollowersBefore == @[("margin-top", "10px")]
      check vm.runEditorCommand(eckUndo).status == ecsSucceeded
      check vm.value("margin-top") == "10px"
      dispose()

  test "a writer's rule the capture does not know by name is compared by value":
    ## The capture named the card's rule `article.destination-card`; the
    ## writer names it `.destination-card`. Trusting the measurement would
    ## say no side is the writer's and move nothing; the value comparison
    ## moves the sides the rule gave their values.
    createRoot proc(dispose: proc()) =
      let r = MockRenderer()
      let foundation = new(string)
      foundation[] = DemoFoundationInitialSource
      const Spelled = "article.destination-card"
      let vm = boxVm(foundation, element = measuredCard({
        "padding-top": ("18px", Spelled), "padding-right": ("18px", Spelled),
        "padding-bottom": ("18px", Spelled), "padding-left": ("18px", Spelled)},
        matched = @[Spelled]))
      let panel = renderInspectorPanel[MockRenderer, MockNode](r, vm)
      r.commitField(panel, "Padding, all sides", "20")
      check vm.sides("padding-") == @["20px", "20px", "20px", "20px"]
      check vm.followers.len == 4
      dispose()

  test "a var() shorthand before the edit: the rule after it decides every side":
    ## Case 2: the shorthand before the edit does not expand, but the rule the
    ## write produces does, and a later side still decides its own.
    createRoot proc(dispose: proc()) =
      let r = MockRenderer()
      let foundation = new(string)
      foundation[] = withCardRule("padding: var(--wl-space-card); padding-top: 24px;")
      var element = boxElement()
      for prop in element.properties.mitems:
        case prop.name
        of "padding": prop.value = "var(--wl-space-card)"
        of "padding-top": prop.value = "24px"
        of "padding-right", "padding-bottom", "padding-left": prop.value = "16px"
        else: discard
      let vm = boxVm(foundation, element = element)
      let panel = renderInspectorPanel[MockRenderer, MockNode](r, vm)
      r.commitField(panel, "Padding, all sides", "20")
      vm.write()
      check foundation[] == withCardRule("padding: 20px; padding-top: 24px;")
      check vm.sides("padding-") == @["24px", "20px", "20px", "20px"]
      check vm.followers[0] == ("padding-top", "24px")
      dispose()

  test "a shorthand whose sides its text does not say still lets a later side decide":
    ## A multi-value list with `var()` gives the sides values its text does
    ## not spell out; each side is read on its own, so the later
    ## `padding-top` still decides the top after the edit.
    createRoot proc(dispose: proc()) =
      let r = MockRenderer()
      let foundation = new(string)
      foundation[] = withCardRule("padding: var(--wl-space-card) 4px; padding-top: 24px;")
      var element = boxElement()
      for prop in element.properties.mitems:
        case prop.name
        of "padding": prop.value = "var(--wl-space-card) 4px"
        of "padding-top": prop.value = "24px"
        of "padding-right", "padding-left": prop.value = "4px"
        of "padding-bottom": prop.value = "16px"
        else: discard
      let vm = boxVm(foundation, element = element)
      let panel = renderInspectorPanel[MockRenderer, MockNode](r, vm)
      r.commitField(panel, "Padding, all sides", "20")
      check vm.sides("padding-") == @["24px", "20px", "20px", "20px"]
      dispose()

  test "a shorthand set to a variable shows the variable on every side":
    ## isonim-pm issue 2026-10-23-a-shorthand-set-to-a-variable-leaves-the-
    ## box-model-sides-stale; "Visual box model": a field shows a function
    ## as written, and the all-sides field the value the sides agree on.
    createRoot proc(dispose: proc()) =
      let r = MockRenderer()
      let foundation = new(string)
      foundation[] = DemoFoundationInitialSource
      let vm = boxVm(foundation)
      let panel = renderInspectorPanel[MockRenderer, MockNode](r, vm)
      r.commitField(panel, "Padding, all sides", "1.5rem")
      check vm.sides("padding-") == @["1.5rem", "1.5rem", "1.5rem", "1.5rem"]
      r.commitField(panel, "Padding, all sides", "var(--wl-space-card)")
      # The editor normalises a typed variable to the project's token
      # reference, and the shorthand's own row shows that; so do its sides.
      const token = "token(wl-space-card)"
      check vm.value("padding") == token
      for side in Sides:
        check vm.value("padding-" & side) == token
        check r.inputOf(panel.field("Padding " & side)) == token
      check r.inputOf(panel.field("Padding, all sides")) == token
      # A canvas handle reads the side as shown: not a number, so a press is
      # refused rather than scaled from the earlier length.
      check vm.boxCanvasDragRefusal("padding-top") ==
        "Padding top: Type a numeric value to replace " & token & "."
      check vm.runEditorCommand(eckUndo).status == ecsSucceeded
      check vm.sides("padding-") == @["1.5rem", "1.5rem", "1.5rem", "1.5rem"]
      dispose()

  test "a shorthand set to a variable without a writer's order shows it too":
    ## The same through `withShorthandSides` alone (no `ruleDeclarations`).
    createRoot proc(dispose: proc()) =
      let foundation = new(string)
      foundation[] = DemoFoundationInitialSource
      let vm = boxVm(foundation, orderless = true)
      check vm.editCssProperty("padding", "var(--wl-space-card)",
        pesShared).status == pesAccepted
      check vm.sides("padding-") == @["token(wl-space-card)",
        "token(wl-space-card)", "token(wl-space-card)", "token(wl-space-card)"]
      dispose()

  test "`! important` with a space is a priority":
    createRoot proc(dispose: proc()) =
      let r = MockRenderer()
      let foundation = new(string)
      foundation[] = withCardRule("padding-top: 24px ! important; padding: 18px;")
      var element = boxElement()
      for prop in element.properties.mitems:
        if prop.name == "padding-top": prop.value = "24px"
      let vm = boxVm(foundation, element = element)
      let panel = renderInspectorPanel[MockRenderer, MockNode](r, vm)
      r.commitField(panel, "Padding, all sides", "20")
      check vm.sides("padding-") == @["24px", "20px", "20px", "20px"]
      check vm.followers[0] == ("padding-top", "24px !important")
      dispose()

  test "a value edit keeps the declaration's !important in the file; undo and redo restore it exactly":
    ## isonim-pm issue 2026-11-15-a-value-edit-writes-the-declaration-without-
    ## its-important-while-the-preview-keeps-it. The preview keeps the
    ## declaration's priority and adds none, so the written file does too
    ## (editor spec "Visual box model": the preview shows the same values
    ## before the write and after it, and through undo and redo).
    createRoot proc(dispose: proc()) =
      let r = MockRenderer()
      let foundation = new(string)
      # The shorthand, important; a side, important with a spaced, upper-case
      # priority; a side with none.
      let declared = withCardRule("padding: 18px !important; " &
        "padding-left: 6px ! IMPORTANT; margin-top: 4px;")
      foundation[] = declared
      var element = boxElement()
      for prop in element.properties.mitems:
        if prop.name == "padding-left": prop.value = "6px"
      let vm = boxVm(foundation, element = element)
      let panel = renderInspectorPanel[MockRenderer, MockNode](r, vm)
      r.commitField(panel, "Padding, all sides", "20")
      vm.write()
      let shorthand = withCardRule("padding: 20px !important; " &
        "padding-left: 6px ! IMPORTANT; margin-top: 4px;")
      check foundation[] == shorthand
      r.commitField(panel, "Padding left", "9")
      vm.write()
      let longhand = withCardRule("padding: 20px !important; " &
        "padding-left: 9px ! IMPORTANT; margin-top: 4px;")
      check foundation[] == longhand
      # No priority is manufactured on a declaration that has none.
      r.commitField(panel, "Margin top", "7")
      vm.write()
      let plain = withCardRule("padding: 20px !important; " &
        "padding-left: 9px ! IMPORTANT; margin-top: 7px;")
      check foundation[] == plain
      # Undo, written each time, puts back exactly what each write replaced.
      check vm.runEditorCommand(eckUndo).status == ecsSucceeded
      vm.write()
      check foundation[] == longhand
      check vm.runEditorCommand(eckUndo).status == ecsSucceeded
      vm.write()
      check foundation[] == shorthand
      check vm.runEditorCommand(eckUndo).status == ecsSucceeded
      vm.write()
      check foundation[] == declared
      # Redo, written each time, puts every edit back with its priority.
      for expected in [shorthand, longhand, plain]:
        check vm.runEditorCommand(eckRedo).status == ecsSucceeded
        vm.write()
        check foundation[] == expected
      dispose()

  test "the example writer reads an unquoted url() whole and refuses an unterminated comment":
    ## Round-2 review residual R5: `url(a/*b)` is one token in CSS Syntax, so
    ## an edit replaces it whole, and a value whose comment never closes is
    ## refused at the writer with the reason, nothing written.
    ## (Round 3, R6: such a comment runs to the end of the file, so the rule
    ## it sits in is not a closed rule and the writer says so.)
    let vector = new(string)
    vector[] = "<svg/>"
    let foundation = new(string)
    let adapter = demoVectorEditAdapter(vector, foundation)
    var entry: WorkspaceEditableSchemaEntry
    for candidate in adapter.schema:
      if candidate.key == "classes.destination-card.padding": entry = candidate
    check entry.key.len > 0
    let plan = SourceEditPlan(file: DemoFoundationSource, property: "padding",
      schemaKey: entry.key, newValue: "url(c)")
    let url = adapter.patchFile(plan, withCardRule("padding: url(a/*b) !important;"), entry)
    check url.ok
    check url.patch.afterContent == withCardRule("padding: url(c) !important;")
    let open = adapter.patchFile(plan, withCardRule("padding: 18px /* open;"), entry)
    check not open.ok
    check open.diagnostics.len == 1
    # The comment never closes, so it runs to the end of the file and
    # swallows the rule's `}` (CSS Syntax): there is no closed rule to write.
    check "has no .destination-card rule" in open.diagnostics[0].message
    check "No source was changed." in open.diagnostics[0].message

  test "the example writer finds its rule and declarations past a }, ; or name inside a comment, string or url()":
    ## Round-3 review R6: the example writer's own rule finder read a `}` in
    ## a comment, string or unquoted url() as the rule's end, so a value set
    ## with no expected old value (as after Reset) was written inside the
    ## comment or string. It now reads them as CSS Syntax does
    ## (`css_patch.skipCssOpaque`).
    let vector = new(string)
    vector[] = "<svg/>"
    let foundation = new(string)
    let adapter = demoVectorEditAdapter(vector, foundation)
    var entry: WorkspaceEditableSchemaEntry
    for candidate in adapter.schema:
      if candidate.key == "classes.destination-card.padding": entry = candidate
    let plan = SourceEditPlan(file: DemoFoundationSource, property: "padding",
      schemaKey: entry.key, newValue: "20px")
    for (before, after) in [
        ("/* } */ padding: 18px;", "/* } */ padding: 20px;"),
        ("content: \"}\"; padding: 18px;", "content: \"}\"; padding: 20px;"),
        ("background: url(a}b); padding: 18px;", "background: url(a}b); padding: 20px;"),
        ("content: \"padding: 1px;\"; padding: 18px;", "content: \"padding: 1px;\"; padding: 20px;"),
        # The append path, as after Reset: no padding declared yet.
        ("/* } */ color: red;", "/* } */ color: red; padding: 20px;"),
        ("content: \"}\";", "content: \"}\"; padding: 20px;"),
        ("background: url(a}b);", "background: url(a}b); padding: 20px;")]:
      let written = adapter.patchFile(plan, withCardRule(before), entry)
      check written.ok
      check written.patch.afterContent == withCardRule(after)
    # Reset removes the one real declaration, not a name inside a string.
    var reset = plan
    reset.planKind = cspPropertyRemoval
    reset.newValue = ""
    let removed = adapter.patchFile(reset,
      withCardRule("content: \"padding: 1px;\"; padding: 18px;"), entry)
    check removed.ok
    check removed.patch.afterContent == withCardRule("content: \"padding: 1px;\";")

  test "without writer order, a side whose value the capture read still follows the shorthand":
    ## Approved wording: "Without either, every side follows the shorthand."
    ## A capture that read `var(--wl-space-card)` off the preview keeps it as
    ## the side's authored value (shown, and refusing a canvas drag), but that
    ## is no statement that the side is its own declaration
    ## (`authoredFromCapture`).
    createRoot proc(dispose: proc()) =
      let foundation = new(string)
      foundation[] = DemoFoundationInitialSource
      var element = boxElement()
      for prop in element.properties.mitems:
        if prop.name in ["padding-top", "padding-right", "padding-bottom",
            "padding-left"]:
          prop.value = "16px"
          prop.authoredValue = "var(--wl-space-card)"
          prop.authoredFromCapture = true
      let vm = boxVm(foundation, element = element, orderless = true)
      check vm.boxCanvasDragRefusal("padding-top") ==
        "Padding top: Type a numeric value to replace var(--wl-space-card)."
      check vm.editCssProperty("padding", "20px", pesShared).status == pesAccepted
      for prop in vm.inspector.selectedElement.val.properties:
        if prop.name in ["padding-top", "padding-right", "padding-bottom",
            "padding-left"]:
          check prop.value == "20px"
          check prop.authoredValue == "20px"
      dispose()

  test "a native catalog's owners decide which sides a shorthand edit moves":
    ## Case 4: the catalog states, per side, the declaration that decides it
    ## (`sourceDeclarations`, read into `sourceOwner`). Sides the shorthand
    ## owns follow it, authored value included, before the catalog is
    ## published again; a side its own later declaration owns does not.
    createRoot proc(dispose: proc()) =
      let foundation = new(string)
      foundation[] = DemoFoundationInitialSource
      var element = boxElement()
      for prop in element.properties.mitems:
        case prop.name
        of "padding": prop.authoredValue = "18px"
        of "padding-top":
          prop.value = "24px"; prop.authoredValue = "24px"
          prop.sourceOwner = "padding-top"
        of "padding-right", "padding-bottom", "padding-left":
          prop.authoredValue = "18px"; prop.sourceOwner = "padding"
        else: discard
      let vm = boxVm(foundation, element = element, orderless = true)
      check vm.editCssProperty("padding", "20px", pesShared).status == pesAccepted
      for prop in vm.inspector.selectedElement.val.properties:
        case prop.name
        of "padding-top":
          check prop.value == "24px"
          check prop.authoredValue == "24px"
        of "padding-right", "padding-bottom", "padding-left":
          check prop.value == "20px"
          check prop.authoredValue == "20px"
        else: discard
      dispose()

  test "a corner radius's order is read from the rule, with `!important`":
    createRoot proc(dispose: proc()) =
      let foundation = new(string)
      foundation[] = withCardRule(
        "padding: 18px; border-top-left-radius: 8px ! important; border-radius: 14px;")
      var element = boxElement()
      for prop in element.properties.mitems:
        if prop.name == "border-radius":
          prop = cardProperty("border-radius", "14px")
      for corner in ["border-top-left-radius", "border-top-right-radius",
          "border-bottom-right-radius", "border-bottom-left-radius"]:
        element.properties.add cardProperty(corner,
          if corner == "border-top-left-radius": "8px" else: "14px")
      let vm = boxVm(foundation, element = element, alsoMapped = @[
        "border-radius", "border-top-left-radius"])
      check vm.editCssProperty("border-radius", "12px",
        pesShared).status == pesAccepted
      check vm.value("border-top-left-radius") == "8px"
      check vm.value("border-top-right-radius") == "12px"
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
    # Another unit keeps its authored digits: a drag that returns to the
    # start gives back the authored value, however many decimals it has.
    check boxCanvasDragValue("padding-top", 19.75296, 0, 0, "1.23456rem") == "1.23456rem"
    check boxCanvasDragValue("padding-top", 16, 0, 1, "1.00001rem") == "1.06251rem"
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

suite "the preview reload an unshown edit needs":
  test "an unshown edit keeps its reload across a write that fails after the patch stage":
    # Editor spec "Saving": an edit the preview could not show is shown by the
    # next write's reload, even when other edits written with it were shown.
    # Here the first write fails at formatting, after its files were patched;
    # the edits stay pending, and the write that then succeeds must still
    # reload the preview although a later commit was shown. The failure is
    # injected through the example writer's own `formatFiles` step (no mock:
    # the writer, the journal and the pipeline are the real ones).
    createRoot proc(dispose: proc()) =
      let foundation = new(string)
      foundation[] = DemoFoundationInitialSource
      let vm = boxVm(foundation)
      var failFormat = true
      vm.workspaceEditAdapter.formatFiles = proc(files: seq[string]): WorkspaceOperationResult =
        if failFormat:
          WorkspaceOperationResult(ok: false, message: "The formatter refused.")
        else:
          WorkspaceOperationResult(ok: true)
      check commitInspectorValue(vm, "padding", "20px", sskSharedClass).ok
      # As `commitInspectorValue` records a commit the preview could not show.
      vm.previewMissesPendingEdits.val = true
      let generation = vm.livePreviewReloadGeneration.val
      let failed = vm.applyWorkspaceFileEdits()
      check not failed.ok
      check vm.inspector.pendingSourceEdits.val.len == 1
      check vm.previewMissesPendingEdits.val
      check vm.livePreviewReloadGeneration.val == generation
      # A later commit the preview did show, then the write that succeeds.
      check commitInspectorValue(vm, "margin", "6px", sskSharedClass).ok
      check vm.previewShowsPendingEdits.val
      failFormat = false
      check vm.applyWorkspaceFileEdits().ok
      check vm.inspector.pendingSourceEdits.val.len == 0
      check vm.livePreviewReloadGeneration.val == generation + 1
      check not vm.previewMissesPendingEdits.val
      check not vm.previewShowsPendingEdits.val
      dispose()

# --- An accepted agent proposal for a shorthand ---------------------------

proc paddingProposal(source, value: string): SourceEditPlan =
  ## The plan the "Padding, all sides" field makes at the shared class scope
  ## over ``source``, taken from an identical editor, owned by no history
  ## entry: an agent proposal carries it so.
  let scratch = new(string)
  scratch[] = source
  let vm = boxVm(scratch)
  doAssert vm.editCssProperty("padding", value, pesShared).status ==
    pesAccepted
  result = vm.inspector.pendingSourceEdits.val[^1]
  result.historyId = 0

proc inspectorPadding(value: string; topWritten: bool): CSSPropertyEditTransaction =
  ## The same edit committed through the inspector after the same history
  ## (padding-top 24px, written or still pending), on an identical editor:
  ## the sides and the preview followers a commit settles.
  let scratch = new(string)
  scratch[] = DemoFoundationInitialSource
  let vm = boxVm(scratch)
  doAssert vm.editCssProperty("padding-top", "24px", pesShared).status ==
    pesAccepted
  if topWritten:
    doAssert vm.applyWorkspaceFileEdits().ok
  doAssert vm.editCssProperty("padding", value, pesShared).status ==
    pesAccepted
  vm.inspector.undoStack.val[^1]

# Templates, so their checks belong to the test that expands them.
template acceptPadding(vm: EditorVM; plan: SourceEditPlan) =
  block:
    let id = vm.chat.addAgentEditProposal(AgentEditProposal(title: "Padding",
      summary: "Set the padding", sourceEdits: @[plan],
      selectedEditIndexes: @[0], validity: aepvCurrent))
    check vm.acceptAgentProposedEdit(id).ok

template previewShows(vm: EditorVM; want: string;
    settled: CSSPropertyEditTransaction) =
  block:
    let request = vm.inspector.previewValueRequest.val
    check request.property == "padding"
    check request.value == want
    check request.followers == settled.sideFollowersAfter
    check request.followers.len > 0
    check request.rule == settled.previewRule
    check request.rule.len > 0

suite "a written agent proposal for a shorthand settles its sides as a commit does":
  ## isonim-pm issue 2026-11-15-after-an-accepted-agent-proposal-replaces-a-
  ## pending-edit-the-inspector-shows-a-value-the-file-does-not-hold, review
  ## RV-1/RV-2. A proposal belongs to no history entry, but once written the
  ## inspector's sides and the preview's followers are exactly what the same
  ## edit committed through the inspector gives (the rule's declaration
  ## order, above), and an undo of an edit it superseded shows that state.
  test "after a written padding-top, a proposal for padding keeps the top":
    createRoot proc(dispose: proc()) =
      let foundation = new(string)
      foundation[] = DemoFoundationInitialSource
      let vm = boxVm(foundation)
      check vm.editCssProperty("padding-top", "24px", pesShared).status ==
        pesAccepted
      vm.write()
      let expected = inspectorPadding("20px", topWritten = true)
      vm.acceptPadding(paddingProposal(foundation[], "20px"))
      check foundation[] == withCardRule("padding: 20px; padding-top: 24px;")
      check vm.value("padding") == "20px"
      check vm.sides("padding-") == @["24px", "20px", "20px", "20px"]
      # The inspector commit of the same edit settles the same sides.
      var committed: seq[string] = @[]
      for side in Sides:
        for prop in expected.afterElement.properties:
          if prop.name == "padding-" & side: committed.add prop.value
      check vm.sides("padding-") == committed
      vm.previewShows("20px", expected)
      dispose()

  test "with a pending padding-top, a proposal for padding keeps the top":
    createRoot proc(dispose: proc()) =
      let foundation = new(string)
      foundation[] = DemoFoundationInitialSource
      let vm = boxVm(foundation)
      let plan = paddingProposal(foundation[], "20px")
      check vm.editCssProperty("padding-top", "24px", pesShared).status ==
        pesAccepted
      vm.acceptPadding(plan)
      check foundation[] == withCardRule("padding: 20px; padding-top: 24px;")
      check vm.sides("padding-") == @["24px", "20px", "20px", "20px"]
      vm.previewShows("20px", inspectorPadding("20px", topWritten = false))
      dispose()

  test "undoing a superseded padding edit shows the state the proposal left, and redo the edit's":
    createRoot proc(dispose: proc()) =
      let foundation = new(string)
      foundation[] = DemoFoundationInitialSource
      let vm = boxVm(foundation)
      check vm.editCssProperty("padding-top", "24px", pesShared).status ==
        pesAccepted
      vm.write()
      let topWritten = foundation[]
      let plan = paddingProposal(topWritten, "20px")
      check vm.editCssProperty("padding", "22px", pesShared).status ==
        pesAccepted
      vm.acceptPadding(plan)
      let accepted = withCardRule("padding: 20px; padding-top: 24px;")
      check foundation[] == accepted
      check vm.inspector.undoStack.val[^1].superseded
      let at20 = inspectorPadding("20px", topWritten = true)
      let at22 = inspectorPadding("22px", topWritten = true)
      # Undo of the superseded 22px edit: nothing moves, and the preview is
      # told the proposal's state -- not the sides the 22px edit found.
      check vm.runEditorCommand(eckUndo).status == ecsSucceeded
      check foundation[] == accepted
      check vm.value("padding") == "20px"
      check vm.sides("padding-") == @["24px", "20px", "20px", "20px"]
      vm.previewShows("20px", at20)
      check vm.inspector.historyNotice.val.startsWith("Undone:")
      # Redo writes 22px over the proposal, with the 22px edit's sides.
      check vm.runEditorCommand(eckRedo).status == ecsSucceeded
      check vm.inspector.historyNotice.val == ""
      check vm.sides("padding-") == @["24px", "22px", "22px", "22px"]
      vm.previewShows("22px", at22)
      vm.write()
      check foundation[] == withCardRule("padding: 22px; padding-top: 24px;")
      # Its own undo returns to the proposal's state.
      check vm.runEditorCommand(eckUndo).status == ecsSucceeded
      check vm.sides("padding-") == @["24px", "20px", "20px", "20px"]
      vm.previewShows("20px", at20)
      vm.write()
      check foundation[] == accepted
      dispose()

proc cardRuleText(foundation: ref string): string =
  let at = foundation[].find(".destination-card {")
  foundation[][at .. foundation[].find("}", at)]

template previewAsks(vm: EditorVM; asked, want: string;
    sideFollowers: seq[(string, string)]) =
  block:
    let request = vm.inspector.previewValueRequest.val
    check request.property == asked
    check request.value == want
    check request.followers == sideFollowers

suite "an undo or redo under a written proposal shows what the rule renders":
  ## Review RV2-1/RV2-2 of isonim-pm issue 2026-11-15-after-an-accepted-agent-
  ## proposal-replaces-a-pending-edit-the-inspector-shows-a-value-the-file-
  ## does-not-hold. On a rule written over several lines the example writer
  ## appends a side to the last declaration's line, and a proposal rewrites
  ## only the shorthand's line, so the side edit's own undo still runs. When
  ## that undo removes the side's declaration, the shorthand the proposal
  ## wrote decides the side; the inspector and the preview show that, settled
  ## by the rule's declaration order, whichever element was selected.
  const Lines = ".destination-card {\n  padding: 18px;\n  color: red;\n}"
  const TopAdded = ".destination-card {\n  padding: 18px;\n  color: red; padding-top: 24px; }"
  const Proposed = ".destination-card {\n  padding: 20px;\n  color: red; padding-top: 24px; }"
  const TopUndone = ".destination-card {\n  padding: 20px;\n  color: red;\n}"

  proc linesSource(rule: string): string =
    DemoFoundationInitialSource.replace(CardRule, rule)

  test "M4 undoing a side edit the proposal's shorthand now decides":
    createRoot proc(dispose: proc()) =
      let foundation = new(string)
      foundation[] = linesSource(Lines)
      let vm = boxVm(foundation)
      check vm.editCssProperty("padding-top", "24px", pesShared).status ==
        pesAccepted
      vm.write()
      check foundation.cardRuleText == TopAdded
      vm.acceptPadding(paddingProposal(foundation[], "20px"))
      check foundation.cardRuleText == Proposed
      check vm.sides("padding-") == @["24px", "20px", "20px", "20px"]
      check vm.runEditorCommand(eckUndo).status == ecsSucceeded
      check vm.sides("padding-") == @["20px", "20px", "20px", "20px"]
      vm.previewAsks("padding-top", "20px", @[("padding-top", "20px")])
      vm.write()
      check foundation.cardRuleText == TopUndone
      check vm.runEditorCommand(eckRedo).status == ecsSucceeded
      check vm.sides("padding-") == @["24px", "20px", "20px", "20px"]
      vm.previewAsks("padding-top", "24px", @[("padding-top", "24px")])
      vm.write()
      check foundation.cardRuleText == Proposed
      check vm.runEditorCommand(eckUndo).status == ecsSucceeded
      check vm.sides("padding-") == @["20px", "20px", "20px", "20px"]
      vm.write()
      check foundation.cardRuleText == TopUndone
      dispose()

  test "M5 control: a side declared on its own line is restored in place":
    createRoot proc(dispose: proc()) =
      let foundation = new(string)
      let own = ".destination-card {\n  padding: 18px;\n  padding-top: 18px;\n}"
      foundation[] = linesSource(own)
      let vm = boxVm(foundation)
      check vm.editCssProperty("padding-top", "24px", pesShared).status ==
        pesAccepted
      vm.write()
      check foundation.cardRuleText == own.replace("padding-top: 18px", "padding-top: 24px")
      vm.acceptPadding(paddingProposal(foundation[], "20px"))
      let proposed = ".destination-card {\n  padding: 20px;\n  padding-top: 24px;\n}"
      check foundation.cardRuleText == proposed
      check vm.sides("padding-") == @["24px", "20px", "20px", "20px"]
      check vm.runEditorCommand(eckUndo).status == ecsSucceeded
      check vm.sides("padding-") == @["18px", "20px", "20px", "20px"]
      vm.previewAsks("padding-top", "18px", @[("padding-top", "18px")])
      vm.write()
      check foundation.cardRuleText == proposed.replace("padding-top: 24px", "padding-top: 18px")
      check vm.runEditorCommand(eckRedo).status == ecsSucceeded
      check vm.sides("padding-") == @["24px", "20px", "20px", "20px"]
      vm.previewAsks("padding-top", "24px", @[("padding-top", "24px")])
      vm.write()
      check foundation.cardRuleText == proposed
      dispose()

  test "M6 the proposal is accepted while another element is selected":
    createRoot proc(dispose: proc()) =
      let foundation = new(string)
      foundation[] = linesSource(Lines)
      let vm = boxVm(foundation)
      check vm.editCssProperty("padding-top", "24px", pesShared).status ==
        pesAccepted
      vm.write()
      let plan = paddingProposal(foundation[], "20px")
      check vm.selectInspectorElement(ElementRef(id: "other", tag: "p",
        sourceKey: "other", sourceFile: DemoFoundationSource, sourceLine: 1))
      vm.acceptPadding(plan)
      check foundation.cardRuleText == Proposed
      # The card's latest snapshot is settled by the rule's declaration
      # order, not spread over every side.
      var recorded: seq[string] = @[]
      for side in Sides:
        for prop in vm.inspector.undoStack.val[^1].afterElement.properties:
          if prop.name == "padding-" & side: recorded.add prop.value
      check recorded == @["24px", "20px", "20px", "20px"]
      check vm.runEditorCommand(eckUndo).status == ecsSucceeded
      check vm.sides("padding-") == @["20px", "20px", "20px", "20px"]
      vm.previewAsks("padding-top", "20px", @[("padding-top", "20px")])
      vm.write()
      check foundation.cardRuleText == TopUndone
      check vm.runEditorCommand(eckRedo).status == ecsSucceeded
      check vm.sides("padding-") == @["24px", "20px", "20px", "20px"]
      vm.previewAsks("padding-top", "24px", @[("padding-top", "24px")])
      vm.write()
      check foundation.cardRuleText == Proposed
      dispose()

suite "an edit of a rule another declaration decides for the element":
  # isonim-pm issue 2026-11-15-an-accepted-edit-of-a-shared-class-changes-
  # nothing-when-another-rule-decides-the-property; editor spec "Saving": an
  # edit changes the one declaration that owns the property for the selected
  # element, and a refusal the editor can know at the act is made there. The
  # element carries what the preview's cascade resolver measured when the
  # selection was captured (`PropertyInfo.cascadeDecider`, `cascadeHomes`,
  # `cascadeConditions`); the browser half is
  # `tests/test_editor_shorthand_order_gui.mjs`.
  proc decided(decider: string; conditions = ""; homes: seq[string] = @[];
      matched = @[".destination-card", "#wl-card"]): ElementRef =
    result = boxElement()
    result.matchedRules = matched
    for prop in result.properties.mitems:
      if prop.name == "padding":
        prop.cascadeDecider = decider
        prop.cascadeConditions = conditions
        prop.cascadeHomes = homes

  proc paddingOf(vm: EditorVM): PropertyInfo =
    for prop in vm.inspector.selectedElement.val.properties:
      if prop.name == "padding": return prop

  proc sharedChoice(vm: EditorVM): SourceScopeChoice =
    for choice in vm.sourceScopeChoices(vm.paddingOf()):
      if choice.kind == sskSharedClass: return choice

  test "refused at the act, naming the deciding rule, at every scope the writer puts in that rule":
    createRoot proc(dispose: proc()) =
      let foundation = new(string)
      foundation[] = DemoFoundationInitialSource
      let vm = boxVm(foundation, element = decided("#wl-card"))
      const why = "`#wl-card` decides padding for this element ahead of " &
        "`.destination-card`, so changing it in `.destination-card` would " &
        "not change what this element renders"
      # The row's shared scope is shown disabled with the reason and is not
      # the default.
      let shared = vm.sharedChoice()
      check not shared.editable
      check why in shared.reason
      let refused = vm.editSharedDesignProperty("padding", "20px", sskSharedClass)
      check refused.status == pesRejected
      check refused.diagnostics.len == 1 and why in refused.diagnostics[0].message
      # The editor example's writer puts a local edit of the card's padding
      # in the same rule: refused too, with the same reason, through the
      # row's commit.
      let local = commitInspectorValue(vm, "padding", "20px", sskLocalInstance)
      check not local.ok
      check why in local.message
      # And the multi-edit admission (a section's raw CSS) answers the same.
      check why in vm.propertyValueCommitRefusal("padding", "20px", sskSharedClass)
      check vm.inspector.pendingSourceEdits.val.len == 0
      check vm.inspector.undoStack.val.len == 0
      check foundation[] == DemoFoundationInitialSource
      check vm.paddingOf().value == "18px"
      dispose()

  test "the element's inline style is named":
    createRoot proc(dispose: proc()) =
      let foundation = new(string)
      foundation[] = DemoFoundationInitialSource
      let vm = boxVm(foundation, element = decided("style"))
      let refused = vm.editSharedDesignProperty("padding", "20px", sskSharedClass)
      check refused.status == pesRejected
      check refused.diagnostics.len == 1 and
        "The element's inline style decides padding for this element" in
          refused.diagnostics[0].message
      check foundation[] == DemoFoundationInitialSource
      dispose()

  test "accepted where the written rule decides, or would by a normal declaration":
    createRoot proc(dispose: proc()) =
      for element in [decided(".destination-card"),
          decided("#wl-card", homes = @[".destination-card"]),
          # Nothing measured: an unsound or missing answer refuses nothing.
          decided("")]:
        let foundation = new(string)
        foundation[] = DemoFoundationInitialSource
        let vm = boxVm(foundation, element = element)
        check vm.sharedChoice().editable
        check commitInspectorValue(vm, "padding", "20px", sskSharedClass).ok
        check vm.inspector.pendingSourceEdits.val.len == 1
      dispose()

  test "not refused when the capture cannot speak for the written rule":
    createRoot proc(dispose: proc()) =
      # The written rule is not among the rules the capture saw match, or it
      # saw two by that name; or the writer does not name its rule.
      for (element, orderless) in [
          (decided("#wl-card", matched = @["#wl-card"]), false),
          (decided("#wl-card", matched = @[".destination-card",
            ".destination-card", "#wl-card"]), false),
          (decided("#wl-card"), true)]:
        let foundation = new(string)
        foundation[] = DemoFoundationInitialSource
        let vm = boxVm(foundation, element = element, orderless = orderless)
        check commitInspectorValue(vm, "padding", "20px", sskSharedClass).ok
      dispose()

  test "a deciding rule under a condition the written rule does not share is not refused":
    createRoot proc(dispose: proc()) =
      # The edit still changes what renders wherever the condition does not
      # hold (another width).
      let foundation = new(string)
      foundation[] = DemoFoundationInitialSource
      let vm = boxVm(foundation, element = decided(
        "@media (min-width: 1000px) #wl-card", "@media (min-width: 1000px)",
        matched = @[".destination-card", "@media (min-width: 1000px) #wl-card"]))
      check commitInspectorValue(vm, "padding", "20px", sskSharedClass).ok
      dispose()

  test "a removal is not refused":
    createRoot proc(dispose: proc()) =
      let foundation = new(string)
      foundation[] = DemoFoundationInitialSource
      let vm = boxVm(foundation, element = decided("#wl-card"))
      # Reset removes a declaration nothing renders: allowed at the row's
      # default scope (the local instance, as the shared one is disabled for
      # a value edit), where this writer removes it from the card rule.
      check vm.propertyResetRefusal("padding", sskLocalInstance) == ""
      check commitInspectorValue(vm, "padding", "", sskLocalInstance).ok
      check vm.inspector.pendingSourceEdits.val.len == 1
      dispose()

suite "a canvas gesture is refused at the act where a row's commit would be":
  # isonim-pm issue 2026-11-18-a-canvas-drag-in-a-read-only-workspace-is-
  # staged-instead-of-refused-at-the-act; editor spec "Saving": a refusal the
  # editor can know at the act is made at the act, so a refused change never
  # reaches the preview, the history or the journal. The canvas stages
  # through `applyDirectCanvasOperation`; the frame puts a refused release
  # back and shows this reason (the canvas resize GUI's read-only cases).
  const readOnly = "This workspace is read-only for source changes."

  proc staged(vm: EditorVM): (int, int) =
    (vm.inspector.undoStack.val.len, vm.inspector.pendingSourceEdits.val.len)

  test "a read-only workspace refuses every staging gesture with the row's reason":
    createRoot proc(dispose: proc()) =
      let foundation = new(string)
      foundation[] = DemoFoundationInitialSource
      let vm = boxVm(foundation, writable = false)
      # The row refuses with this reason too.
      let row = commitInspectorValue(vm, "padding", "20px", sskSharedClass)
      check not row.ok
      check row.message == readOnly
      for operation in [
          DirectCanvasOperation(kind: dcokResize, property: "width", value: "280px"),
          DirectCanvasOperation(kind: dcokResize, property: "height", value: "80px"),
          DirectCanvasOperation(kind: dcokSpacing, property: "padding", value: "20px"),
          DirectCanvasOperation(kind: dcokSpacing, property: "gap", value: "12px"),
          DirectCanvasOperation(kind: dcokReorder, property: "order", value: "1"),
          DirectCanvasOperation(kind: dcokInlineText, property: "text", value: "Hello"),
          DirectCanvasOperation(kind: dcokContextCommand, command: dcccReset,
            property: "padding"),
          DirectCanvasOperation(kind: dcokContextCommand, command: dcccPasteStyles,
            property: "padding", value: "20px"),
          DirectCanvasOperation(kind: dcokContextCommand, command: dcccDetach,
            property: "padding", value: "18px"),
          DirectCanvasOperation(kind: dcokContextCommand, command: dcccPromote,
            property: "padding", value: "18px"),
          DirectCanvasOperation(kind: dcokContextCommand, command: dcccWrap,
            property: "padding", value: "18px")]:
        let outcome = vm.applyDirectCanvasOperation(operation)
        check not outcome.ok
        check outcome.diagnostics.len == 1 and
          outcome.diagnostics[0].message == readOnly
        check vm.staged() == (0, 0)
      check foundation[] == DemoFoundationInitialSource
      # A command that stages nothing is not a source change.
      check vm.applyDirectCanvasOperation(DirectCanvasOperation(
        kind: dcokContextCommand, command: dcccCopyStyles)).ok
      check vm.staged() == (0, 0)
      # Commands that run another editor command are that command's to
      # refuse (here the workspace grants none of them); they stage nothing.
      for command in [dcccCreateVariant, dcccDuplicate, dcccDelete]:
        let ran = vm.applyDirectCanvasOperation(DirectCanvasOperation(
          kind: dcokContextCommand, command: command))
        check not ran.ok
        check ran.commandState.diagnostic.len > 0
        check vm.staged() == (0, 0)
      dispose()

  test "a canvas gesture asks the row's other act-time questions of the plan it stages":
    createRoot proc(dispose: proc()) =
      # The card's padding is decided by `#wl-card` (as the preview's cascade
      # measured it): a row commit of padding at the card rule is refused, and
      # so is the spacing handle's, with the same reason, before staging.
      var element = boxElement()
      element.matchedRules = @[".destination-card", "#wl-card"]
      for prop in element.properties.mitems:
        if prop.name == "padding": prop.cascadeDecider = "#wl-card"
      let foundation = new(string)
      foundation[] = DemoFoundationInitialSource
      let vm = boxVm(foundation, element = element)
      let row = commitInspectorValue(vm, "padding", "20px", sskSharedClass)
      check not row.ok
      let outcome = vm.applyDirectCanvasOperation(DirectCanvasOperation(
        kind: dcokSpacing, property: "padding", value: "20px"))
      check not outcome.ok
      check outcome.diagnostics.len == 1 and
        "`#wl-card` decides padding for this element" in outcome.diagnostics[0].message
      check vm.staged() == (0, 0)
      check foundation[] == DemoFoundationInitialSource
      dispose()

  test "a writable workspace stages the same gesture":
    createRoot proc(dispose: proc()) =
      let foundation = new(string)
      foundation[] = DemoFoundationInitialSource
      let vm = boxVm(foundation)
      check vm.applyDirectCanvasOperation(DirectCanvasOperation(
        kind: dcokSpacing, property: "padding", value: "20px")).ok
      check vm.staged() == (1, 1)
      dispose()
