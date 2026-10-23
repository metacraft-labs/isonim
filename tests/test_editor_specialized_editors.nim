## The inspector's specialized editors: Fill's advanced background-image
## controls (the gradient editor, background position and repeat), and the
## Effects section's shadow editor and Bezier curve editor.
##
## Editor spec "Editing Controls (Figma-Grade Affordances)" -> "Specialized
## Editors": "Gradient editor -- horizontal bar with color stops; drag to
## reposition; click to add; angle scrub-drag; type selector
## (linear/radial/conic)", "Shadow editor -- X/Y offset via 2D crosshair drag
## or numeric inputs; blur/spread as scrub inputs; color picker for shadow
## color; inset toggle; multiple shadows with add/remove", "Bezier curve
## editor -- for `transition-timing-function`; square with draggable control
## points; preset thumbnails ...; custom curve via handle drag", and the
## drafted clause under them that says where each editor lives and how it
## commits; "Planned interaction parity" ("Specialized controls use this same
## commit/cancel contract"); "Saving" for the act-time refusals, the
## automatic write and undo. isonim-pm issue
## 2026-09-26-the-consumer-editor-spec-tests-the-inspector-that-was-demolished.
##
## The writer cases use no mock writer: the editor example's production
## adapter (`demo_workspace.demoVectorEditAdapter`) writes the example's real
## foundation source held in memory -- its `.long-tail-card` rule declares
## the card's `background-image`, `box-shadow`, `transition-timing-function`,
## `background-position` and `background-repeat` -- and a real EditorVM
## plans, journals, writes and undoes through it.
##
## Mock justification: MockRenderer stands in for the browser DOM so the
## production inspector panel (`shell.renderInspectorPanel`, the Fill and
## Effects sections and their editors) runs natively and under strict Node
## JS with real signals, owners and EditorVM; events, pointer positions and
## modifiers are dispatched to the listeners the views registered. Some cases
## give the EditorVM an `inspectorSourceCommit` recording callback: it
## stands for the native source bridge, which the inspector calls and does
## not own. Another installs `InspectorVM.requestVariablePicker`, the shell's
## variable picker hook, to record what the bind affordance asks for. The
## browser, the preview frame and the example's page are exercised by the
## editor-example Playwright cases `e2e_specialized_editors_gradient`,
## `e2e_specialized_editors_gradient_stops_and_rows`,
## `e2e_specialized_editors_shadow` and
## `e2e_specialized_editors_timing_curve`, and the consumer by
## metacraft-web-editor's
## `e2e_figma_grade_numeric_color_shadow_typography_controls`.

import std/[options, strutils, tables, unittest]

import isonim/core/[computation, owner, signals]
import isonim/testing/mock_dom
import isonim/editor
import isonim/editor/css_compound_values
import isonim/editor/demo_workspace
import isonim/editor/views/shell
import isonim/editor/views/widgets/advanced_controls
import isonim/editor/views/widgets/gradient_editor
import isonim/editor/views/widgets/property_commit
import isonim/editor/views/widgets/shadow_editor
import isonim/editor/views/widgets/timing_editor

proc effectCard(): ElementRef =
  ## The example's card as the preview capture reports it once selected: its
  ## hand-built properties plus the `.long-tail-card` declarations the
  ## initial element does not carry, keyed like the long-tail properties.
  result = demoInspectorElement()
  for (property, value) in @DemoLayoutValues & @DemoEffectValues:
    result.properties.add PropertyInfo(name: property, value: value,
      origin: poTailwindClass, originDetail: "class:long-tail-card",
      sourceFile: DemoFoundationSource, sourceLine: 10,
      schemaKey: "classes.destination-card." & property,
      sharedCount: 4, directStyleAllowed: true)

proc editorVm(foundation: ref string; writable = true): EditorVM =
  let vector = new(string)
  vector[] = "<svg/>"
  let story = StoryRef(group: "DestinationCard", name: "Default",
    kind: skComponent, index: 0)
  result = createEditorVM(newEditorWorkspace(
    title = "Wanderlust specialized editors fixture",
    storyGroups = @[StoryGroup(name: "DestinationCard", kind: skComponent,
      expanded: true, items: @[StoryItem(name: "Default", kind: skComponent,
        group: "DestinationCard")])],
    initialStory = some(story),
    foundationTokens = demoFoundationTokens(),
    designSystemSchema = demoDesignSystemSchema(),
    permissions = EditorWorkspacePermissions(readSource: true,
      writeSource: writable),
    editAdapter = demoVectorEditAdapter(vector, foundation)))
  check result.selectInspectorElement(effectCard())

proc findByAttr(node: MockNode; name, value: string): MockNode =
  if node == nil: return nil
  if node.kind == mnkElement and node.attributes.getOrDefault(name) == value:
    return node
  for child in node.children:
    let found = findByAttr(child, name, value)
    if found != nil: return found

proc countByAttr(node: MockNode; name, value: string): int =
  if node == nil: return 0
  if node.kind == mnkElement and node.attributes.getOrDefault(name) == value:
    inc result
  for child in node.children:
    result += countByAttr(child, name, value)

proc attr(node: MockNode; name: string): string =
  if node == nil: "" else: node.attributes.getOrDefault(name)

proc display(node: MockNode): string =
  if node == nil: "" else: node.styles.getOrDefault("display")

proc textOf(node: MockNode): string =
  if node == nil: "" else: textContent(node)

template need(node: MockNode) {.dirty.} =
  check node != nil
  if node == nil:
    dispose()
    return

proc value(vm: EditorVM; name: string): string =
  for prop in vm.inspector.selectedElement.val.properties:
    if prop.name == name: return prop.value

proc stacks(vm: EditorVM): (int, int) =
  (vm.inspector.undoStack.val.len, vm.inspector.redoStack.val.len)

proc write(vm: EditorVM) =
  let saved = vm.applyWorkspaceFileEdits()
  check saved.ok
  check vm.inspector.pendingSourceEdits.val.len == 0

proc labelled(panel: MockNode; label: string): MockNode =
  findByAttr(panel, "aria-label", label)

proc longTail(property, value: string): string =
  ## The example's `.long-tail-card` rule text for ``property``.
  " " & property & ": " & value & ";"

proc press(node: MockNode; x = 0.0; y = 0.0; shift = false) =
  node.fireEventWith("pointerdown", MockEvent(`type`: "pointerdown",
    target: node, currentTarget: node, clientX: x, clientY: y, shiftKey: shift))

proc move(node: MockNode; x = 0.0; y = 0.0; shift = false) =
  node.fireEventWith("pointermove", MockEvent(`type`: "pointermove",
    target: node, currentTarget: node, clientX: x, clientY: y, shiftKey: shift))

proc release(node: MockNode; x = 0.0; y = 0.0; shift = false) =
  node.fireEventWith("pointerup", MockEvent(`type`: "pointerup",
    target: node, currentTarget: node, clientX: x, clientY: y, shiftKey: shift))

proc key(node: MockNode; name: string; shift = false) =
  node.fireEventWith("keydown", MockEvent(`type`: "keydown", target: node,
    currentTarget: node, key: name, shiftKey: shift))

proc typeInto(r: MockRenderer; node: MockNode; text: string) =
  r.setInputValue(node, text)
  node.fireEvent("input")
  node.key("Enter")

proc otherCard(): ElementRef =
  ## Another card, with the same properties: another selection.
  result = effectCard()
  result.id = "destination-card-copy"
  result.sourceKey = "destination-card.copy"

proc applyColor(r: MockRenderer; host: MockNode; color: string) =
  ## Type ``color`` into the open colour picker under ``host`` and apply it.
  let input = findByAttr(host, "data-color-popover-input", "true")
  let apply = findByAttr(host, "data-color-popover-apply", "true")
  check input != nil and apply != nil
  if input == nil or apply == nil: return
  r.setInputValue(input, color)
  input.fireEvent("input")
  apply.fireEvent("click")

proc open(panel: MockNode; property: string): MockNode =
  ## Open ``property``'s specialized editor; its panel.
  let toggle = panel.labelled(advancedControlsLabel(property))
  check toggle != nil
  if toggle == nil: return nil
  if attr(toggle, "aria-expanded") != "true": toggle.fireEvent("click")
  findByAttr(panel, "data-advanced-controls", property)

proc message(panel: MockNode; attrName: string): string =
  textOf(findByAttr(panel, attrName, "true"))

suite "the disclosures":
  test "each editor is closed until opened, mounted then, and kept for the session":
    createRoot proc(dispose: proc()) =
      let r = MockRenderer()
      let foundation = new(string)
      foundation[] = DemoFoundationInitialSource
      let vm = editorVm(foundation)
      let panel = renderInspectorPanel[MockRenderer, MockNode](r, vm)
      let fill = findByAttr(panel, "data-inspector-section-body", "fill")
      let effects = findByAttr(panel, "data-inspector-section-body", "effects")
      need(fill)
      need(effects)
      for (section, property, contents) in [
          (fill, gradientProperty, "data-gradient-editor"),
          (effects, shadowProperty, "data-shadow-editor"),
          (effects, timingProperty, "data-timing-editor")]:
        let toggle = section.labelled(advancedControlsLabel(property))
        need(toggle)
        check toggle.tag == "button"
        check countByAttr(panel, "aria-label", advancedControlsLabel(property)) == 1
        check attr(toggle, "aria-expanded") == "false"
        check display(findByAttr(section, "data-advanced-controls", property)) == "none"
        # Nothing is mounted for a closed editor.
        check findByAttr(section, contents, "true") == nil
        toggle.fireEvent("click")
        check vm.inspector.advancedControlsOpen(property)
        check attr(toggle, "aria-expanded") == "true"
        check display(findByAttr(section, "data-advanced-controls", property)) == "flex"
        check findByAttr(section, contents, "true") != nil
        # Each follows the row of the property it edits.
        check display(findByAttr(section, "data-exposed-css-property", property)) == "flex"
      # Kept across selections; a selection without the property hides it.
      check vm.selectInspectorElement(ElementRef(id: "plain", tag: "div",
        properties: @[PropertyInfo(name: "color", value: "red")]))
      check vm.inspector.advancedControlsOpen(gradientProperty)
      check display(findByAttr(fill, "data-advanced-controls-host", gradientProperty)) == "none"
      check vm.selectInspectorElement(effectCard())
      check display(findByAttr(fill, "data-advanced-controls-host", gradientProperty)) == "flex"
      check attr(fill.labelled(advancedControlsLabel(gradientProperty)),
        "aria-expanded") == "true"
      fill.labelled(advancedControlsLabel(gradientProperty)).fireEvent("click")
      check not vm.inspector.advancedControlsOpen(gradientProperty)
      check vm.stacks == (0, 0)
      check foundation[] == DemoFoundationInitialSource
      dispose()

  test "search finds each editor by what it edits, and raw CSS covers its rows":
    createRoot proc(dispose: proc()) =
      let r = MockRenderer()
      let foundation = new(string)
      foundation[] = DemoFoundationInitialSource
      let vm = editorVm(foundation)
      let panel = renderInspectorPanel[MockRenderer, MockNode](r, vm)
      let search = findByAttr(panel, "data-inspector-search-input", "true")
      need(search)
      for (query, property) in [("gradient", gradientProperty),
          ("background-repeat", gradientProperty), ("crosshair", ""),
          ("inset", shadowProperty), ("bezier", timingProperty),
          ("reduced motion", timingProperty)]:
        r.setInputValue(search, query)
        search.fireEvent("input")
        for candidate in [gradientProperty, shadowProperty, timingProperty]:
          check attr(panel.labelled(advancedControlsLabel(candidate)),
            "data-inspector-search-match") ==
              (if candidate == property: "true" else: "false")
      r.setInputValue(search, "")
      search.fireEvent("input")
      # Raw CSS: Fill covers the gradient editor's position and repeat rows
      # before they are mounted; Effects covers the shadow and the timing.
      panel.labelled("Show raw CSS for Fill section").fireEvent("click")
      let fillText = r.inputValue(panel.labelled("Edit raw CSS for Fill section"))
      for declaration in ["background-image: none;", "background-size: auto;",
          "background-position: 0% 0%;", "background-repeat: repeat;"]:
        check declaration in fillText
      panel.labelled("Show raw CSS for Effects section").fireEvent("click")
      check r.inputValue(panel.labelled("Edit raw CSS for Effects section")) ==
        "box-shadow: 0 8px 24px rgba(15, 23, 42, 0.12);\nfilter: none;\n" &
        "transform: none;\ntransition-duration: 0s;\n" &
        "transition-timing-function: ease;\n"
      dispose()

suite "the gradient editor":
  test "the angle, the type buttons and typed angles commit background-image through its row":
    createRoot proc(dispose: proc()) =
      let r = MockRenderer()
      let foundation = new(string)
      foundation[] = DemoFoundationInitialSource
      let vm = editorVm(foundation)
      let panel = renderInspectorPanel[MockRenderer, MockNode](r, vm)
      let editor = panel.open(gradientProperty)
      need(editor)
      check findByAttr(editor, "aria-label", gradientEditorLabel) != nil
      # No gradient yet: a starting gradient, written on the first edit.
      check "starting gradient" in textOf(findByAttr(editor, "data-gradient-note", "true"))
      for kind in CssGradientKind:
        check attr(editor.labelled(gradientTypeLabel(kind)), "aria-pressed") == "false"
      let angle = editor.labelled(gradientAngleScrubLabel())
      need(angle)
      check textOf(angle) == "90\xC2\xB0"
      let generation = vm.autoSaveGeneration.val
      # Pressing the angle without a drag turns the gradient by 45 degrees.
      angle.fireEvent("click")
      let angled = "linear-gradient(135deg, #3B82F6 0%, #22C55E 100%)"
      check vm.value(gradientProperty) == angled
      check vm.stacks == (1, 0)
      # At the row's default scope: the class rule that authors the value.
      check vm.inspector.pendingSourceEdits.val[^1].sourceScope == sskSharedClass
      check vm.autoSaveGeneration.val == generation + 1
      check textOf(angle) == "135\xC2\xB0"
      check attr(editor.labelled(gradientTypeLabel(cgkLinear)), "aria-pressed") == "true"
      # The row shows what the editor committed: it is the same property.
      let row = findByAttr(findByAttr(panel, "data-exposed-css-property",
        gradientProperty), "data-property-row-input", "true")
      check r.inputValue(row) == angled
      vm.write()
      check longTail(gradientProperty, angled) in foundation[]
      check longTail(gradientProperty, "none") notin foundation[]
      # The type buttons keep the stops.
      editor.labelled(gradientTypeLabel(cgkRadial)).fireEvent("click")
      check vm.value(gradientProperty) == "radial-gradient(#3B82F6 0%, #22C55E 100%)"
      check textOf(angle) == "\xE2\x80\x94"
      check attr(angle, "aria-disabled") == "true"
      # A radial gradient has no angle: pressing says so and changes nothing.
      angle.fireEvent("click")
      check panel.message("data-gradient-message") == radialAngleReason
      check vm.stacks == (2, 0)
      vm.write()
      editor.labelled(gradientTypeLabel(cgkConic)).fireEvent("click")
      check vm.value(gradientProperty) == "conic-gradient(#3B82F6 0%, #22C55E 100%)"
      vm.write()
      editor.labelled(gradientTypeLabel(cgkLinear)).fireEvent("click")
      check vm.value(gradientProperty) == "linear-gradient(0deg, #3B82F6 0%, #22C55E 100%)"
      vm.write()
      # A typed angle; arithmetic and other units are degrees too.
      let field = editor.labelled("Edit background-image gradient angle")
      need(field)
      r.typeInto(field, "200+25")
      check vm.value(gradientProperty) == "linear-gradient(225deg, #3B82F6 0%, #22C55E 100%)"
      vm.write()
      r.typeInto(field, "0.5turn")
      check vm.value(gradientProperty) == "linear-gradient(180deg, #3B82F6 0%, #22C55E 100%)"
      vm.write()
      r.typeInto(field, "12px")
      check "type an angle" in panel.message("data-gradient-message")
      check vm.stacks == (6, 0)
      # The arrow keys step one degree, Shift 15.
      angle.key("ArrowRight")
      check vm.value(gradientProperty) == "linear-gradient(181deg, #3B82F6 0%, #22C55E 100%)"
      vm.write()
      angle.key("ArrowLeft", shift = true)
      check vm.value(gradientProperty) == "linear-gradient(166deg, #3B82F6 0%, #22C55E 100%)"
      vm.write()
      check panel.message("data-gradient-message") == ""
      # Every edit is one undo entry back to the exact bytes.
      for _ in 0 ..< 8:
        check vm.runEditorCommand(eckUndo).status == ecsSucceeded
        vm.write()
      check foundation[] == DemoFoundationInitialSource
      check vm.value(gradientProperty) == "none"
      dispose()

  test "an angle drag previews in the editor and commits once on release":
    createRoot proc(dispose: proc()) =
      let r = MockRenderer()
      let foundation = new(string)
      foundation[] = DemoFoundationInitialSource
      let vm = editorVm(foundation)
      let panel = renderInspectorPanel[MockRenderer, MockNode](r, vm)
      let editor = panel.open(gradientProperty)
      need(editor)
      let angle = editor.labelled(gradientAngleScrubLabel())
      let preview = findByAttr(editor, "data-gradient-preview", "true")
      need(angle)
      angle.press(100)
      angle.move(101)
      check textOf(angle) == "90\xC2\xB0"
      angle.move(130)
      check textOf(angle) == "120\xC2\xB0"
      check preview.styles.getOrDefault("background-image") ==
        "linear-gradient(120deg, #3B82F6 0%, #22C55E 100%)"
      check vm.stacks == (0, 0)
      angle.release(130)
      # The release's click is the drag's, not a second turn.
      angle.fireEvent("click")
      check vm.value(gradientProperty) == "linear-gradient(120deg, #3B82F6 0%, #22C55E 100%)"
      check vm.stacks == (1, 0)
      vm.write()
      # Shift snaps to 15 degrees.
      angle.press(0)
      angle.move(43, shift = true)
      check textOf(angle) == "165\xC2\xB0"
      angle.release(43, shift = true)
      angle.fireEvent("click")
      check vm.value(gradientProperty) == "linear-gradient(165deg, #3B82F6 0%, #22C55E 100%)"
      vm.write()
      # Pointer cancellation ends a drag without an edit.
      angle.press(0)
      angle.move(50)
      check textOf(angle) == "215\xC2\xB0"
      angle.fireEvent("pointercancel")
      check textOf(angle) == "165\xC2\xB0"
      angle.release(50)
      check vm.stacks == (2, 0)
      # So does another selection.
      angle.press(0)
      angle.move(20)
      check vm.selectInspectorElement(otherCard())
      check textOf(angle) == "90\xC2\xB0"
      angle.release(20)
      check vm.stacks == (2, 0)
      dispose()

  test "the stop bar adds, moves and removes stops; the stop's fields commit":
    createRoot proc(dispose: proc()) =
      let r = MockRenderer()
      let foundation = new(string)
      foundation[] = DemoFoundationInitialSource
      let vm = editorVm(foundation)
      let panel = renderInspectorPanel[MockRenderer, MockNode](r, vm)
      let editor = panel.open(gradientProperty)
      need(editor)
      let bar = editor.labelled(gradientBarLabel)
      need(bar)
      check countByAttr(bar, "data-gradient-stop", "0") == 1
      check attr(editor.labelled(gradientStopLabel(1, 100.0)), "data-gradient-stop") == "1"
      # A press on the bar between stops adds one there, coloured as the
      # gradient is there; the bar is 200px wide without a layout.
      bar.press(50)
      check vm.value(gradientProperty) ==
        "linear-gradient(90deg, #3B82F6 0%, #3593D0 25%, #22C55E 100%)"
      vm.write()
      let added = editor.labelled(gradientStopLabel(1, 25.0))
      need(added)
      check attr(added, "aria-pressed") == "true"
      # Dragging a stop moves it, previewed and committed on release; the
      # stops keep the bar's order.
      let first = editor.labelled(gradientStopLabel(0, 0.0))
      need(first)
      first.press(0)
      first.move(100)
      check findByAttr(bar, "aria-label", gradientStopLabel(0, 25.0)) != nil
      check vm.stacks == (1, 0)
      first.release(100)
      check vm.value(gradientProperty) ==
        "linear-gradient(90deg, #3593D0 25%, #3B82F6 50%, #22C55E 100%)"
      vm.write()
      # A press on a stop is the stop's, not the bar's.
      let middle = editor.labelled(gradientStopLabel(1, 50.0))
      need(middle)
      middle.press(0)
      bar.press(0)
      middle.release(0)
      check vm.stacks == (2, 0)
      check attr(middle, "aria-pressed") == "true"
      # The keys move the focused stop by 1% (Shift 10%).
      middle.key("ArrowRight", shift = true)
      check vm.value(gradientProperty) ==
        "linear-gradient(90deg, #3593D0 25%, #3B82F6 60%, #22C55E 100%)"
      vm.write()
      # The position field.
      let position = editor.labelled("Gradient stop position")
      need(position)
      check r.inputValue(position) == "60%"
      r.typeInto(position, "40")
      check vm.value(gradientProperty) ==
        "linear-gradient(90deg, #3593D0 25%, #3B82F6 40%, #22C55E 100%)"
      vm.write()
      # The colour picker commits the stop's colour.
      let swatch = editor.labelled("Edit gradient stop color")
      need(swatch)
      swatch.fireEvent("click")
      r.applyColor(findByAttr(editor, "data-gradient-stop-editor", "true"), "#EF4444")
      check vm.value(gradientProperty) ==
        "linear-gradient(90deg, #3593D0 25%, #EF4444 40%, #22C55E 100%)"
      vm.write()
      # Delete removes the focused stop; Remove the selected one; two stay.
      editor.labelled(gradientStopLabel(1, 40.0)).key("Delete")
      check vm.value(gradientProperty) == "linear-gradient(90deg, #3593D0 25%, #22C55E 100%)"
      vm.write()
      let remove = editor.labelled("Remove background-image gradient stop")
      check attr(remove, "aria-disabled") == "true"
      remove.fireEvent("click")
      check "at least two stops" in panel.message("data-gradient-message")
      check vm.stacks == (6, 0)
      # Add puts a stop after the selected one.
      editor.labelled("Add background-image gradient stop").fireEvent("click")
      check vm.value(gradientProperty).count("%") == 3
      vm.write()
      for _ in 0 ..< 7:
        check vm.runEditorCommand(eckUndo).status == ecsSucceeded
        vm.write()
      check foundation[] == DemoFoundationInitialSource
      dispose()

  test "what the editor cannot change is named and only replaced by a type button":
    createRoot proc(dispose: proc()) =
      let r = MockRenderer()
      let foundation = new(string)
      foundation[] = DemoFoundationInitialSource
      let vm = editorVm(foundation)
      let panel = renderInspectorPanel[MockRenderer, MockNode](r, vm)
      let editor = panel.open(gradientProperty)
      need(editor)
      let row = findByAttr(findByAttr(panel, "data-exposed-css-property",
        gradientProperty), "data-property-row-input", "true")
      need(row)
      r.setInputValue(row, "url(\"tile.png\")")
      row.fireEvent("input")
      row.fireEvent("change")
      check vm.value(gradientProperty) == "url(\"tile.png\")"
      vm.write()
      check "not a gradient" in textOf(findByAttr(editor, "data-gradient-note", "true"))
      let angle = editor.labelled(gradientAngleScrubLabel())
      check attr(angle, "aria-disabled") == "true"
      angle.fireEvent("click")
      check "cannot change this background-image" in panel.message("data-gradient-message")
      editor.labelled(gradientBarLabel).press(10)
      check vm.stacks == (1, 0)
      let linear = editor.labelled(gradientTypeLabel(cgkLinear))
      check "Replace" in attr(linear, "title")
      linear.fireEvent("click")
      check vm.value(gradientProperty) == "linear-gradient(90deg, #3B82F6 0%, #22C55E 100%)"
      vm.write()
      for _ in 0 ..< 2:
        check vm.runEditorCommand(eckUndo).status == ecsSucceeded
        vm.write()
      check foundation[] == DemoFoundationInitialSource
      dispose()

  test "stops positioned in a length are kept: the bar neither adds nor moves them":
    createRoot proc(dispose: proc()) =
      let r = MockRenderer()
      let foundation = new(string)
      foundation[] = DemoFoundationInitialSource
      let vm = editorVm(foundation)
      let panel = renderInspectorPanel[MockRenderer, MockNode](r, vm)
      let editor = panel.open(gradientProperty)
      need(editor)
      let row = findByAttr(findByAttr(panel, "data-exposed-css-property",
        gradientProperty), "data-property-row-input", "true")
      need(row)
      let typed = "linear-gradient(90deg, #3B82F6 0%, #22C55E 12px)"
      r.setInputValue(row, typed)
      row.fireEvent("input")
      row.fireEvent("change")
      vm.write()
      let add = editor.labelled("Add " & gradientProperty & " gradient stop")
      check attr(add, "aria-disabled") == "true"
      add.fireEvent("click")
      check "positioned in a length" in panel.message("data-gradient-message")
      editor.labelled(gradientBarLabel).press(40)
      let stop = findByAttr(editor, "data-gradient-stop", "1")
      need(stop)
      stop.press(100)
      stop.move(160)
      stop.release(160)
      stop.key("ArrowLeft")
      check vm.value(gradientProperty) == typed
      check vm.stacks == (1, 0)
      # The angle and the stops' colours still edit; the stops are kept.
      editor.labelled(gradientAngleScrubLabel()).fireEvent("click")
      check vm.value(gradientProperty) ==
        "linear-gradient(135deg, #3B82F6 0%, #22C55E 12px)"
      vm.write()
      for _ in 0 ..< 2:
        check vm.runEditorCommand(eckUndo).status == ecsSucceeded
        vm.write()
      check foundation[] == DemoFoundationInitialSource
      dispose()

  test "the background position and repeat rows commit through the class rule":
    createRoot proc(dispose: proc()) =
      let r = MockRenderer()
      let foundation = new(string)
      foundation[] = DemoFoundationInitialSource
      let vm = editorVm(foundation)
      let panel = renderInspectorPanel[MockRenderer, MockNode](r, vm)
      let editor = panel.open(gradientProperty)
      need(editor)
      let position = findByAttr(findByAttr(editor, "data-gradient-row-property",
        "background-position"), "data-property-row-input", "true")
      need(position)
      check r.inputValue(position) == "0% 0%"
      r.setInputValue(position, "center top")
      position.fireEvent("input")
      position.fireEvent("change")
      check vm.value("background-position") == "center top"
      vm.write()
      check longTail("background-position", "center top") in foundation[]
      let repeat = findByAttr(editor, "data-gradient-row-property", "background-repeat")
      let option = findByAttr(repeat, "data-choice-group-option", "1")
      need(option)
      option.fireEvent("click")
      check vm.value("background-repeat") == "no-repeat"
      vm.write()
      check longTail("background-repeat", "no-repeat") in foundation[]
      check vm.stacks == (2, 0)
      for _ in 0 ..< 2:
        check vm.runEditorCommand(eckUndo).status == ecsSucceeded
        vm.write()
      check foundation[] == DemoFoundationInitialSource
      dispose()

  test "a read-only workspace refuses every edit with the reason":
    createRoot proc(dispose: proc()) =
      let r = MockRenderer()
      let foundation = new(string)
      foundation[] = DemoFoundationInitialSource
      let vm = editorVm(foundation, writable = false)
      let panel = renderInspectorPanel[MockRenderer, MockNode](r, vm)
      let editor = panel.open(gradientProperty)
      need(editor)
      for label in [gradientTypeLabel(cgkLinear), gradientAngleScrubLabel(),
          "Add background-image gradient stop"]:
        let node = editor.labelled(label)
        check attr(node, "aria-disabled") == "true"
        check "read-only" in attr(node, "title")
        node.fireEvent("click")
        check "read-only" in panel.message("data-gradient-message")
      editor.labelled(gradientBarLabel).press(40)
      check vm.stacks == (0, 0)
      check vm.inspector.pendingSourceEdits.val.len == 0
      check foundation[] == DemoFoundationInitialSource
      dispose()

  test "the editor commits at the row's scope, through the native source bridge when there is one":
    createRoot proc(dispose: proc()) =
      let r = MockRenderer()
      let foundation = new(string)
      foundation[] = DemoFoundationInitialSource
      let vm = editorVm(foundation)
      var received: seq[(string, string, SourceScopeChoiceKind)] = @[]
      vm.inspectorSourceCommit = proc(element: ElementRef; property, value: string;
          scope: SourceScopeChoiceKind; done: proc(ok: bool; diagnostic: string) {.closure.}) =
        received.add (property, value, scope)
        done(false, "The native writer refused it.")
      let panel = renderInspectorPanel[MockRenderer, MockNode](r, vm)
      let editor = panel.open(gradientProperty)
      need(editor)
      let rowHost = findByAttr(panel, "data-exposed-css-property", gradientProperty)
      let rowScope = attr(findByAttr(rowHost, "aria-pressed", "true"),
        "data-source-scope-kind")
      editor.labelled(gradientAngleScrubLabel()).fireEvent("click")
      check received.len == 1
      check received[0][0] == gradientProperty
      check received[0][1] == "linear-gradient(135deg, #3B82F6 0%, #22C55E 100%)"
      check $received[0][2] == rowScope
      check panel.message("data-gradient-message") ==
        "Angle: The native writer refused it."
      # An invalid value never reaches the bridge.
      r.typeInto(editor.labelled("Edit background-image gradient angle"), "abc")
      check received.len == 1
      check vm.stacks == (0, 0)
      dispose()

  test "a read-only workspace sends nothing to the native source bridge":
    createRoot proc(dispose: proc()) =
      let r = MockRenderer()
      let foundation = new(string)
      foundation[] = DemoFoundationInitialSource
      let vm = editorVm(foundation, writable = false)
      var received = 0
      vm.inspectorSourceCommit = proc(element: ElementRef; property, value: string;
          scope: SourceScopeChoiceKind; done: proc(ok: bool; diagnostic: string) {.closure.}) =
        inc received
        done(true, "")
      let panel = renderInspectorPanel[MockRenderer, MockNode](r, vm)
      let fill = panel.open(gradientProperty)
      need(fill)
      fill.labelled(gradientTypeLabel(cgkRadial)).fireEvent("click")
      check "read-only" in panel.message("data-gradient-message")
      let effects = panel.open(shadowProperty)
      need(effects)
      effects.labelled(shadowPresetLabel("soft")).fireEvent("click")
      check "read-only" in panel.message("data-shadow-message")
      let timing = panel.open(timingProperty)
      need(timing)
      timing.labelled(timingPresetLabel("linear")).fireEvent("click")
      check "read-only" in panel.message("data-timing-message")
      check received == 0
      check vm.stacks == (0, 0)
      dispose()

  test "the gradient editor commits at the scope chosen on its row":
    createRoot proc(dispose: proc()) =
      let r = MockRenderer()
      let foundation = new(string)
      foundation[] = DemoFoundationInitialSource
      let vm = editorVm(foundation)
      let panel = renderInspectorPanel[MockRenderer, MockNode](r, vm)
      let editor = panel.open(gradientProperty)
      need(editor)
      let rowHost = findByAttr(panel, "data-exposed-css-property", gradientProperty)
      let local = findByAttr(rowHost, "data-source-scope-kind", "sskLocalInstance")
      need(local)
      local.fireEvent("click")
      vm.write()
      let before = vm.inspector.undoStack.val.len
      check "local" in textOf(findByAttr(editor, "data-advanced-controls-scope",
        gradientProperty)).toLowerAscii()
      editor.labelled(gradientAngleScrubLabel()).fireEvent("click")
      check vm.inspector.undoStack.val.len == before + 1
      check vm.inspector.pendingSourceEdits.val.len == 1
      check vm.inspector.pendingSourceEdits.val[^1].sourceScope == sskLocalInstance
      vm.write()
      let undo = vm.inspector.undoStack.val.len
      for _ in 0 ..< undo:
        check vm.runEditorCommand(eckUndo).status == ecsSucceeded
        vm.write()
      check foundation[] == DemoFoundationInitialSource
      dispose()

suite "the shadow editor":
  test "the crosshair, the fields, inset and colour commit the selected layer":
    createRoot proc(dispose: proc()) =
      let r = MockRenderer()
      let foundation = new(string)
      foundation[] = DemoFoundationInitialSource
      let vm = editorVm(foundation)
      let panel = renderInspectorPanel[MockRenderer, MockNode](r, vm)
      let editor = panel.open(shadowProperty)
      need(editor)
      check textOf(editor.labelled(shadowLayerLabel(0))) ==
        "Drop 0 8px 24px rgba(15, 23, 42, 0.12)"
      let pad = editor.labelled(shadowCrosshairLabel)
      need(pad)
      let dot = findByAttr(pad, "data-shadow-crosshair-dot", "true")
      check dot.styles.getOrDefault("left") == "40px"
      check dot.styles.getOrDefault("top") == "48px"
      # A drag moves the offset a pixel per pixel, committed on release.
      pad.press(10, 10)
      pad.move(20, 6)
      check dot.styles.getOrDefault("left") == "50px"
      check vm.stacks == (0, 0)
      pad.release(20, 6)
      check vm.value(shadowProperty) == "10px 4px 24px rgba(15, 23, 42, 0.12)"
      check vm.stacks == (1, 0)
      vm.write()
      check longTail(shadowProperty, "10px 4px 24px rgba(15, 23, 42, 0.12)") in foundation[]
      # The arrow keys move it 1px, Shift 10px.
      pad.key("ArrowLeft", shift = true)
      check vm.value(shadowProperty) == "0px 4px 24px rgba(15, 23, 42, 0.12)"
      vm.write()
      # The fields: typed, stepped, scrubbed.
      let blur = editor.labelled("Shadow blur")
      need(blur)
      check r.inputValue(blur) == "24px"
      r.typeInto(blur, "30")
      check vm.value(shadowProperty) == "0px 4px 30px rgba(15, 23, 42, 0.12)"
      vm.write()
      # A field takes a length; anything else is refused and changes nothing.
      r.typeInto(blur, "soft")
      check panel.message("data-shadow-message") == "Blur: type a length (soft)."
      check vm.value(shadowProperty) == "0px 4px 30px rgba(15, 23, 42, 0.12)"
      check r.inputValue(blur) == "30px"
      let spread = editor.labelled("Shadow spread")
      need(spread)
      spread.key("ArrowUp")
      check vm.value(shadowProperty) == "0px 4px 30px 1px rgba(15, 23, 42, 0.12)"
      vm.write()
      let scrub = findByAttr(editor, "data-compound-scrub", "Shadow blur")
      need(scrub)
      scrub.press(0)
      scrub.move(-40)
      check r.inputValue(blur) == "0px"
      check vm.stacks == (4, 0)
      scrub.release(-40)
      check vm.value(shadowProperty) == "0px 4px 0px 1px rgba(15, 23, 42, 0.12)"
      vm.write()
      # Inset, and the colour picker.
      let inset = editor.labelled("Toggle inset shadow")
      inset.fireEvent("click")
      check attr(inset, "aria-pressed") == "true"
      check vm.value(shadowProperty) == "inset 0px 4px 0px 1px rgba(15, 23, 42, 0.12)"
      vm.write()
      editor.labelled("Edit shadow layer color").fireEvent("click")
      r.applyColor(editor, "#0F172A")
      check vm.value(shadowProperty) == "inset 0px 4px 0px 1px #0F172A"
      vm.write()
      for _ in 0 ..< 7:
        check vm.runEditorCommand(eckUndo).status == ecsSucceeded
        vm.write()
      check foundation[] == DemoFoundationInitialSource
      dispose()

  test "layers are added and removed, presets replace the list, and the token binds":
    createRoot proc(dispose: proc()) =
      let r = MockRenderer()
      let foundation = new(string)
      foundation[] = DemoFoundationInitialSource
      let vm = editorVm(foundation)
      var picked: seq[string] = @[]
      vm.inspector.requestVariablePicker = proc(key: PropertyBindingKey;
          x, y, w, h: float) =
        picked.add key.propertyName
      let panel = renderInspectorPanel[MockRenderer, MockNode](r, vm)
      let editor = panel.open(shadowProperty)
      need(editor)
      editor.labelled("Add shadow layer").fireEvent("click")
      check vm.value(shadowProperty) ==
        "0 8px 24px rgba(15, 23, 42, 0.12), 0px 4px 12px 0px rgba(15, 23, 42, 0.16)"
      check attr(editor.labelled(shadowLayerLabel(1)), "aria-pressed") == "true"
      vm.write()
      editor.labelled(removeShadowLayerLabel(0)).fireEvent("click")
      check vm.value(shadowProperty) == "0px 4px 12px 0px rgba(15, 23, 42, 0.16)"
      vm.write()
      editor.labelled(removeShadowLayerLabel(0)).fireEvent("click")
      check vm.value(shadowProperty) == "none"
      vm.write()
      # No layer: the layer controls say why.
      let pad = editor.labelled(shadowCrosshairLabel)
      check attr(pad, "aria-disabled") == "true"
      pad.press(0, 0)
      check panel.message("data-shadow-message") == noShadowReason
      check vm.stacks == (3, 0)
      editor.labelled(shadowPresetLabel("soft")).fireEvent("click")
      check vm.value(shadowProperty) == "0 8px 24px rgba(15, 23, 42, 0.18)"
      vm.write()
      editor.labelled(shadowPresetLabel("raised")).fireEvent("click")
      check parseCssShadowList(vm.value(shadowProperty)).layers.len == 2
      vm.write()
      editor.labelled("Bind elevation token").fireEvent("click")
      check picked == @[shadowProperty]
      check vm.stacks == (5, 0)
      for _ in 0 ..< 5:
        check vm.runEditorCommand(eckUndo).status == ecsSucceeded
        vm.write()
      check foundation[] == DemoFoundationInitialSource
      dispose()

  test "the editor commits at the scope chosen on the row":
    createRoot proc(dispose: proc()) =
      let r = MockRenderer()
      let foundation = new(string)
      foundation[] = DemoFoundationInitialSource
      let vm = editorVm(foundation)
      let panel = renderInspectorPanel[MockRenderer, MockNode](r, vm)
      let editor = panel.open(shadowProperty)
      need(editor)
      let note = findByAttr(editor, "data-advanced-controls-scope", shadowProperty)
      # The card's shadow is the class rule's: the row's default scope, and
      # so the editor's.
      check "shared class" in textOf(note).toLowerAscii()
      # The local instance chosen on the row is the editor's scope too. (The
      # row re-commits its value at the scope it is given.)
      let rowHost = findByAttr(panel, "data-exposed-css-property", shadowProperty)
      let local = findByAttr(rowHost, "data-source-scope-kind", "sskLocalInstance")
      need(local)
      local.fireEvent("click")
      vm.write()
      check "local" in textOf(note).toLowerAscii()
      editor.labelled(shadowPresetLabel("inner")).fireEvent("click")
      check vm.inspector.pendingSourceEdits.val.len == 1
      check vm.inspector.pendingSourceEdits.val[^1].sourceScope == sskLocalInstance
      check vm.inspector.pendingSourceEdits.val[^1].newValue ==
        "inset 0 1px 3px rgba(15, 23, 42, 0.24)"
      vm.write()
      check longTail(shadowProperty, "inset 0 1px 3px rgba(15, 23, 42, 0.24)") in foundation[]
      let undo = vm.inspector.undoStack.val.len
      for _ in 0 ..< undo:
        check vm.runEditorCommand(eckUndo).status == ecsSucceeded
        vm.write()
      check foundation[] == DemoFoundationInitialSource
      dispose()

  test "a scope chosen on the row after an editor commit re-commits the editor's value there":
    # isonim-pm issue 2026-10-23-choosing-a-scope-on-an-exposed-css-row-
    # after-a-commit-crashes-natively: the native build freed the running
    # scope chip's callback under it. Editor spec "Universal Patterns":
    # choosing a scope re-commits the row's value at that scope.
    createRoot proc(dispose: proc()) =
      let r = MockRenderer()
      let foundation = new(string)
      foundation[] = DemoFoundationInitialSource
      let vm = editorVm(foundation)
      let panel = renderInspectorPanel[MockRenderer, MockNode](r, vm)
      let editor = panel.open(shadowProperty)
      need(editor)
      editor.labelled(shadowPresetLabel("soft")).fireEvent("click")
      check vm.inspector.pendingSourceEdits.val[^1].sourceScope == sskSharedClass
      vm.write()
      let rowHost = findByAttr(panel, "data-exposed-css-property", shadowProperty)
      let local = findByAttr(rowHost, "data-source-scope-kind", "sskLocalInstance")
      need(local)
      local.fireEvent("click")
      check vm.inspector.pendingSourceEdits.val.len == 1
      check vm.inspector.pendingSourceEdits.val[^1].sourceScope == sskLocalInstance
      check vm.inspector.pendingSourceEdits.val[^1].newValue ==
        "0 8px 24px rgba(15, 23, 42, 0.18)"
      check "local" in textOf(findByAttr(editor, "data-advanced-controls-scope",
        shadowProperty)).toLowerAscii()
      vm.write()
      let undo = vm.inspector.undoStack.val.len
      check undo == 2
      for _ in 0 ..< undo:
        check vm.runEditorCommand(eckUndo).status == ecsSucceeded
        vm.write()
      check foundation[] == DemoFoundationInitialSource
      dispose()

  test "a refusal that arrives during a drag refuses the release, and nothing reaches the native bridge":
    # The release commits what the press admitted. A native source project
    # admits its own writes (`propertyValueCommitRefusal` asks it only to
    # validate) and the row's wiring calls its bridge without asking, so the
    # editor's own check is all that stands between a refusal that arrives
    # mid-drag -- the project reloading ("Loading editable properties."), or
    # reporting the declaration as one it does not own -- and the bridge
    # (editor spec "Saving": a refusal at the act changes nothing).
    createRoot proc(dispose: proc()) =
      let r = MockRenderer()
      let foundation = new(string)
      foundation[] = DemoFoundationInitialSource
      let vm = editorVm(foundation)
      var received = 0
      vm.hasAsyncSourceProject = true
      vm.sourceAdapterReady.val = true
      vm.inspectorSourceCommit = proc(element: ElementRef; property, value: string;
          scope: SourceScopeChoiceKind; done: proc(ok: bool; diagnostic: string) {.closure.}) =
        inc received
        done(true, "")
      var owned = effectCard()
      for prop in owned.properties.mitems:
        if prop.name == shadowProperty: prop.authoredValue = prop.value
      check vm.selectInspectorElement(owned)
      let panel = renderInspectorPanel[MockRenderer, MockNode](r, vm)
      let editor = panel.open(shadowProperty)
      need(editor)
      let pad = editor.labelled(shadowCrosshairLabel)
      need(pad)
      check attr(pad, "aria-disabled") == "false"
      # Admitted: the bridge receives the release.
      pad.press(0, 0)
      pad.move(12, 0)
      pad.release(12, 0)
      check received == 1
      proc reloading() = vm.sourceAdapterReady.val = false
      proc disowned() =
        var refused = owned
        for prop in refused.properties.mitems:
          if prop.name == shadowProperty:
            prop.nativeEditRefusal = "the declaration is generated."
        check vm.selectInspectorElement(refused)
      for (refuse, why) in [(reloading, "Loading editable properties"),
          (disowned, "the declaration is generated")]:
        vm.sourceAdapterReady.val = true
        check vm.selectInspectorElement(owned)
        pad.press(0, 0)
        pad.move(12, 0)
        refuse()
        pad.release(12, 0)
        check received == 1
        check why in panel.message("data-shadow-message")
      dispose()

  test "a drag whose layer is undone away ends without an edit":
    createRoot proc(dispose: proc()) =
      let r = MockRenderer()
      let foundation = new(string)
      foundation[] = DemoFoundationInitialSource
      let vm = editorVm(foundation)
      let panel = renderInspectorPanel[MockRenderer, MockNode](r, vm)
      let editor = panel.open(shadowProperty)
      need(editor)
      editor.labelled(removeShadowLayerLabel(0)).fireEvent("click")
      check vm.value(shadowProperty) == "none"
      vm.write()
      editor.labelled("Add shadow layer").fireEvent("click")
      vm.write()
      let pad = editor.labelled(shadowCrosshairLabel)
      need(pad)
      pad.press(0, 0)
      pad.move(12, 0)
      check vm.runEditorCommand(eckUndo).status == ecsSucceeded
      vm.write()
      check vm.value(shadowProperty) == "none"
      pad.release(12, 0)
      let scrub = findByAttr(editor, "data-compound-scrub", "Shadow blur")
      need(scrub)
      scrub.press(0)
      scrub.move(20)
      scrub.release(20)
      check vm.value(shadowProperty) == "none"
      check vm.stacks == (1, 1)
      check vm.runEditorCommand(eckUndo).status == ecsSucceeded
      vm.write()
      check foundation[] == DemoFoundationInitialSource
      dispose()

  test "another selection discards a crosshair drag":
    createRoot proc(dispose: proc()) =
      let r = MockRenderer()
      let foundation = new(string)
      foundation[] = DemoFoundationInitialSource
      let vm = editorVm(foundation)
      let panel = renderInspectorPanel[MockRenderer, MockNode](r, vm)
      let editor = panel.open(shadowProperty)
      need(editor)
      let pad = editor.labelled(shadowCrosshairLabel)
      pad.press(0, 0)
      pad.move(12, 0)
      check vm.selectInspectorElement(otherCard())
      check findByAttr(pad, "data-shadow-crosshair-dot", "true").styles.getOrDefault("left") == "40px"
      pad.release(12, 0)
      check vm.stacks == (0, 0)
      # Escape ends one too.
      pad.press(0, 0)
      pad.move(12, 0)
      pad.key("Escape")
      pad.release(12, 0)
      check vm.stacks == (0, 0)
      dispose()

suite "the timing curve editor":
  test "presets, handle drags and keys commit transition-timing-function":
    createRoot proc(dispose: proc()) =
      let r = MockRenderer()
      let foundation = new(string)
      foundation[] = DemoFoundationInitialSource
      let vm = editorVm(foundation)
      let panel = renderInspectorPanel[MockRenderer, MockNode](r, vm)
      let editor = panel.open(timingProperty)
      need(editor)
      check editor.labelled(timingCurveLabel) != nil
      check textOf(findByAttr(editor, "data-timing-readout", "true")) == "ease"
      check attr(editor.labelled(timingPresetLabel("ease")), "aria-pressed") == "true"
      editor.labelled(timingPresetLabel("ease-in-out")).fireEvent("click")
      check vm.value(timingProperty) == "ease-in-out"
      check attr(editor.labelled(timingPresetLabel("ease-in-out")), "aria-pressed") == "true"
      check attr(editor.labelled(timingPresetLabel("ease")), "aria-pressed") == "false"
      vm.write()
      check longTail(timingProperty, "ease-in-out") in foundation[]
      # Control point 1 (0.42, 0) dragged right 12px and up 60px.
      let first = editor.labelled(controlPointLabel(1))
      need(first)
      first.press(100, 100)
      first.move(112, 40)
      check textOf(findByAttr(editor, "data-timing-readout", "true")) ==
        "cubic-bezier(0.52, 0.5, 0.58, 1)"
      check vm.stacks == (1, 0)
      first.release(112, 40)
      check vm.value(timingProperty) == "cubic-bezier(0.52, 0.5, 0.58, 1)"
      vm.write()
      # x stays within 0..1.
      let second = editor.labelled(controlPointLabel(2))
      second.press(0, 0)
      second.move(400, 0)
      second.release(400, 0)
      check vm.value(timingProperty) == "cubic-bezier(0.52, 0.5, 1, 1)"
      vm.write()
      # Keys move a point 0.01 (Shift 0.1).
      second.key("ArrowDown", shift = true)
      check vm.value(timingProperty) == "cubic-bezier(0.52, 0.5, 1, 0.9)"
      vm.write()
      # A curve a keyword names is written as the keyword.
      first.key("ArrowLeft", shift = true)
      vm.write()
      for _ in 0 ..< 5:
        first.key("ArrowDown", shift = true)
        vm.write()
      second.key("ArrowUp", shift = true)
      check vm.value(timingProperty) == "ease-in"
      check attr(editor.labelled(timingPresetLabel("ease-in")), "aria-pressed") == "true"
      vm.write()
      let undo = vm.inspector.undoStack.val.len
      for _ in 0 ..< undo:
        check vm.runEditorCommand(eckUndo).status == ecsSucceeded
        vm.write()
      check foundation[] == DemoFoundationInitialSource
      dispose()

  test "a value the square cannot draw is named and replaced only by a preset":
    createRoot proc(dispose: proc()) =
      let r = MockRenderer()
      let foundation = new(string)
      foundation[] = DemoFoundationInitialSource
      let vm = editorVm(foundation)
      let panel = renderInspectorPanel[MockRenderer, MockNode](r, vm)
      let editor = panel.open(timingProperty)
      need(editor)
      let row = findByAttr(findByAttr(panel, "data-exposed-css-property",
        timingProperty), "data-property-row-input", "true")
      r.setInputValue(row, "steps(4, end)")
      row.fireEvent("input")
      row.fireEvent("change")
      check vm.value(timingProperty) == "steps(4, end)"
      vm.write()
      check "step function" in textOf(findByAttr(editor, "data-timing-note", "true"))
      let first = editor.labelled(controlPointLabel(1))
      check attr(first, "aria-disabled") == "true"
      first.press(0, 0)
      check "step function" in panel.message("data-timing-message")
      first.key("ArrowUp")
      check vm.stacks == (1, 0)
      editor.labelled(timingPresetLabel("linear")).fireEvent("click")
      check vm.value(timingProperty) == "linear"
      vm.write()
      for _ in 0 ..< 2:
        check vm.runEditorCommand(eckUndo).status == ecsSucceeded
        vm.write()
      check foundation[] == DemoFoundationInitialSource
      dispose()

  test "the reduced-motion diagnostics report the transition and change nothing":
    check reducedMotionReport("0s", "ease", "", true) ==
      "transition-duration is 0s: nothing animates, so reduced motion needs nothing here."
    check reducedMotionReport("180ms", "ease-in-out", "", true) ==
      "Transition 180ms ease-in-out. No prefers-reduced-motion rule changes it: " &
      "people who ask for less motion still see it. Add one to the project's stylesheet."
    check reducedMotionReport("180ms", "cubic-bezier(0.3, 1.6, 0.6, 1)",
      ".card", true) == "Transition 180ms cubic-bezier(0.3, 1.6, 0.6, 1). " &
      "The curve overshoots, which moves past its end and back. The " &
      "prefers-reduced-motion rule .card changes it for people who ask for less motion."
    check "needs the preview" in reducedMotionReport("1s", "", "", false)
    createRoot proc(dispose: proc()) =
      let r = MockRenderer()
      let foundation = new(string)
      foundation[] = DemoFoundationInitialSource
      let vm = editorVm(foundation)
      let panel = renderInspectorPanel[MockRenderer, MockNode](r, vm)
      let editor = panel.open(timingProperty)
      need(editor)
      let run = editor.labelled(reducedMotionLabel)
      need(run)
      run.fireEvent("click")
      check panel.message("data-timing-message") ==
        "transition-duration is 0s: nothing animates, so reduced motion needs nothing here."
      check vm.stacks == (0, 0)
      check foundation[] == DemoFoundationInitialSource
      dispose()
