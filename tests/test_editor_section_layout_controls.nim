## The Layout section's auto layout, grid, constraint and responsive override
## controls.
##
## Editor spec "Full CSS Property Inspector": the layout section "exposes
## `display`, flex, grid, positioning, sizing, constraints, overflow, and
## responsive overrides as source-backed CSS concepts"; "Section catalogue":
## Layout's "W/H + constraint"; "Contextual sub-panels"; "Behavioural
## invariants": "Layout semantics stay close to CSS"; and the clauses under
## "Layout auto layout, grid, constraint and responsive controls" that say
## what each control is and how it commits. "Saving" for the act-time
## refusals, the automatic write and undo. isonim-pm issue
## 2026-09-26-the-consumer-editor-spec-tests-the-inspector-that-was-demolished.
##
## The writer cases use no mock writer: the editor example's production
## adapter (`demo_workspace.demoVectorEditAdapter`) writes the example's real
## foundation source held in memory -- its `.long-tail-card` rule declares
## the card's layout properties, and its one breakpoint is the
## `@media (max-width: 640px)` block -- and a real EditorVM plans, journals,
## writes and undoes through it. One case builds the same adapter with its
## entries' `breakpointOverrides` cleared, which is how a writer that cannot
## write an override states it.
##
## Mock justification: MockRenderer stands in for the browser DOM so the
## production inspector panel (`shell.renderInspectorPanel`, the Layout
## section and its controls) runs natively and under strict Node JS with real
## signals, owners and EditorVM; events are dispatched to the listeners the
## views registered. One case gives the EditorVM an `inspectorSourceCommit`
## recording callback: it stands for the native source bridge, which the
## inspector calls and does not own; it is asserted to receive nothing. The
## browser, the preview frame's override rule and the example's page are
## exercised by the editor-example Playwright case
## `e2e_layout_controls_auto_grid_constraints_and_responsive_overrides`, and
## the consumer by metacraft-web-editor's
## `e2e_canvas_layout_handles_measurement_and_responsive_overrides`.

import std/[options, strutils, tables, unittest]

import isonim/core/[computation, owner, signals]
import isonim/testing/mock_dom
import isonim/editor
import isonim/editor/css_patch
import isonim/editor/demo_workspace
import isonim/editor/views/shell
import isonim/editor/views/widgets/property_commit
import isonim/editor/views/widgets/section_layout_controls

const Compact = "@media (max-width: 640px)"

proc layoutCard(): ElementRef =
  ## The example's card as the preview capture reports it once selected: its
  ## hand-built properties plus the layout declarations of `.long-tail-card`
  ## (`DemoLayoutValues`), keyed like the long-tail properties.
  result = demoInspectorElement()
  for (property, value) in DemoLayoutValues:
    result.properties.add PropertyInfo(name: property, value: value,
      origin: poTailwindClass, originDetail: "class:long-tail-card",
      sourceFile: DemoFoundationSource, sourceLine: 10,
      schemaKey: "classes.destination-card." & property,
      sharedCount: 4, directStyleAllowed: true)

proc layoutVm(foundation: ref string; writable = true;
    overrides = true; breakpoints = true): EditorVM =
  let vector = new(string)
  vector[] = "<svg/>"
  let story = StoryRef(group: "DestinationCard", name: "Default",
    kind: skComponent, index: 0)
  var adapter = demoVectorEditAdapter(vector, foundation)
  if not overrides:
    for entry in adapter.schema.mitems:
      entry.breakpointOverrides = false
  result = createEditorVM(newEditorWorkspace(
    title = "Wanderlust layout controls fixture",
    storyGroups = @[StoryGroup(name: "DestinationCard", kind: skComponent,
      expanded: true, items: @[StoryItem(name: "Default", kind: skComponent,
        group: "DestinationCard")])],
    initialStory = some(story),
    foundationTokens = demoFoundationTokens(),
    designSystemSchema = demoDesignSystemSchema(),
    responsiveBreakpoints =
      if breakpoints: demoResponsiveBreakpoints(foundation[]) else: @[],
    permissions = EditorWorkspacePermissions(readSource: true,
      writeSource: writable),
    editAdapter = adapter))
  check result.selectInspectorElement(layoutCard())

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

proc row(panel: MockNode; slug: string): MockNode =
  findByAttr(findByAttr(panel, "data-layout-controls", "true"),
    "data-property-row", slug)

proc pick(panel: MockNode; slug: string; index: int) =
  let option = findByAttr(panel.row(slug), "data-choice-group-option", $index)
  check option != nil
  if option != nil: option.fireEvent("click")

proc typeRow(r: MockRenderer; panel: MockNode; slug, value: string) =
  let input = findByAttr(panel.row(slug), "data-property-row-input", "true")
  check input != nil
  if input == nil: return
  r.setInputValue(input, value)
  input.fireEvent("input")
  input.fireEvent("change")

proc longTail(property, value: string): string =
  ## The example's `.long-tail-card` rule text for ``property``.
  " " & property & ": " & value & ";"

proc layoutMessage(panel: MockNode): string =
  textOf(findByAttr(panel, "data-layout-mode-message", "true"))

proc setLayout(panel: MockNode; mode: string) =
  ## The layout mode commits `display`, which has no shared writer
  ## (`sharedDesignCategory`): it is committed at the local instance, which
  ## the example's writer resolves by the property's key to the card's rule.
  let scopes = findByAttr(panel, "data-layout-source-scope-property", "display")
  let local = findByAttr(scopes, "data-source-scope-kind", "sskLocalInstance")
  check local != nil
  if local != nil and attr(local, "aria-pressed") != "true":
    local.fireEvent("click")
  findByAttr(panel, "data-layout-mode", mode).fireEvent("click")

suite "layout control values":
  test "flex wrap, labels and the flex modes":
    check flexWrapPressed("wrap")
    check flexWrapPressed(" wrap-reverse ")
    check not flexWrapPressed("nowrap")
    check flexWrapNext("nowrap") == "wrap"
    check flexWrapNext("wrap") == "nowrap"
    check flexWrapNext("wrap-reverse") == "nowrap"
    check isFlexLayout("vertical") and isFlexLayout("horizontal")
    check not isFlexLayout("grid") and not isFlexLayout("none")
    check responsiveOverrideLabel("Mobile") ==
      "Set responsive override for Mobile mode"

  test "a declaration is written inside a breakpoint and nowhere else":
    let css = ".card { gap: 8px; }\n@media (max-width: 640px) {\n" &
      "  .card { font-size: 13px; }\n}\n"
    # Added after the rule's last declaration, on the rule's layout.
    let added = css.patchCssDeclarationUnder(Compact, ".card", "gap", "4px")
    check added.ok and added.outcome == cpoInserted
    check added.content == ".card { gap: 8px; }\n@media (max-width: 640px) {\n" &
      "  .card { font-size: 13px; gap: 4px; }\n}\n"
    # Replaced, a trailing comment kept; then unchanged.
    let commented = css.replace("13px;", "13px /* compact */;")
    let replaced = commented.patchCssDeclarationUnder(
      "@media  (max-width:  640px)", ".card", "font-size", "12px")
    check replaced.ok and replaced.outcome == cpoReplaced
    check replaced.oldValue == "13px"
    check "font-size: 12px /* compact */;" in replaced.content
    check ".card { gap: 8px; }" in replaced.content
    let same = css.patchCssDeclarationUnder(Compact, ".card", "font-size", "13px")
    check same.ok and same.outcome == cpoUnchanged and same.content == css
    # Removed, leaving the base rule alone.
    let removed = css.patchCssDeclarationUnder(Compact, ".card", "font-size", "")
    check removed.ok and removed.outcome == cpoRemoved
    check removed.content == ".card { gap: 8px; }\n@media (max-width: 640px) {\n" &
      "  .card { }\n}\n"
    # A rule the block has none of is added to the block.
    let other = css.patchCssDeclarationUnder(Compact, ".hero", "gap", "2px")
    check other.ok
    check other.content == ".card { gap: 8px; }\n@media (max-width: 640px) {\n" &
      "  .card { font-size: 13px; }\n  .hero { gap: 2px; }\n}\n"
    # A block the stylesheet has none of is added at the end.
    let fresh = ".card { gap: 8px; }".patchCssDeclarationUnder(
      "@media (max-width: 480px)", ".card", "gap", "2px")
    check fresh.ok
    check fresh.content == ".card { gap: 8px; }\n@media (max-width: 480px) {\n" &
      "  .card { gap: 2px; }\n}\n"

  test "an override the stylesheet cannot hold unambiguously is refused":
    let css = ".card { gap: 8px; }\n@media (max-width: 640px) {\n" &
      "  .card { font-size: 13px; }\n}\n"
    for (condition, selector, property, value, why) in [
        ("@media (prefers-color-scheme: dark)", ".card", "gap", "1px",
          "not a width-based"),
        (Compact, ".card", "gap", "", "no `gap` override to remove"),
        (Compact, ".hero", "gap", "", "No `.hero` rule")]:
      let refused = css.patchCssDeclarationUnder(condition, selector,
        property, value)
      check not refused.ok
      check why in refused.message
      check refused.content.len == 0
    let listed = css.replace("  .card {", "  .card, .hero {")
    check "selector list" in listed.patchCssDeclarationUnder(Compact, ".card",
      "gap", "1px").message
    let twice = css & "@media (max-width: 640px) {\n  .card { gap: 1px; }\n}\n"
    check "2 rules" in twice.patchCssDeclarationUnder(Compact, ".card", "gap",
      "2px").message
    let blocks = ".card { gap: 8px; }\n@media (max-width: 640px) { }\n" &
      "@media (max-width: 640px) { }\n"
    check "2 `@media (max-width: 640px)` blocks" in
      blocks.patchCssDeclarationUnder(Compact, ".card", "gap", "2px").message
    let doubled = css.replace("13px;", "13px; font-size: 12px;")
    check "more than once" in doubled.patchCssDeclarationUnder(Compact,
      ".card", "font-size", "11px").message

  test "the example's writer refuses an override the block does not hold as expected":
    let foundation = new(string)
    foundation[] = DemoFoundationInitialSource.replace(
      "  .destination-card { font-size: 13px; }\n",
      "  .destination-card { font-size: 13px; }\n  .long-tail-card { gap: 12px; }\n")
    let adapter = demoVectorEditAdapter(new(string), foundation)
    var entry: WorkspaceEditableSchemaEntry
    for candidate in adapter.schema:
      if candidate.key == "classes.destination-card.gap": entry = candidate
    check entry.breakpointOverrides
    let plan = SourceEditPlan(file: DemoFoundationSource, property: "gap",
      newValue: "16px", schemaKey: "classes.destination-card.gap",
      sourceScope: sskSharedClass, scope: pesShared,
      breakpointCondition: Compact)
    var stale = plan
    stale.expectedOldValue = "8px"
    let refused = adapter.patchFile(stale, foundation[], entry)
    check not refused.ok
    check refused.diagnostics.len == 1 and refused.diagnostics[0].message ==
      "Refused to set the gap override in " & Compact & ": " &
      DemoFoundationSource & " declares gap: 12px there, not 8px. No source " &
      "was changed."
    var current = plan
    current.expectedOldValue = "12px"
    let accepted = adapter.patchFile(current, foundation[], entry)
    check accepted.ok
    check "  .long-tail-card { gap: 16px; }\n" in accepted.patch.afterContent
    # The base rule is never the override's home.
    check " gap: normal;" in accepted.patch.afterContent

  test "the example's breakpoint is read from its stylesheet":
    let breakpoints = demoResponsiveBreakpoints(DemoFoundationInitialSource)
    check breakpoints.len == 1
    check breakpoints[0].condition == Compact
    check breakpoints[0].maxWidth == 640
    check breakpoints[0].label == "\xE2\x89\xA4 640px"

suite "the Layout section's entry points":
  test "the three entry points and the disclosure, closed until opened":
    createRoot proc(dispose: proc()) =
      let r = MockRenderer()
      let foundation = new(string)
      foundation[] = DemoFoundationInitialSource
      let vm = layoutVm(foundation)
      let panel = renderInspectorPanel[MockRenderer, MockNode](r, vm)
      let layout = findByAttr(panel, "data-inspector-section-body", "layout")
      need(layout)
      for label in [flexWrapToggleLabel, gridTracksLabel, constraintsLabel,
          layoutControlsToggleLabel]:
        let node = layout.labelled(label)
        check node != nil
        check countByAttr(panel, "aria-label", label) == 1
        if node != nil: check node.tag == "button"
      # The placeholder is gone.
      check "Constraints (auto)" notin textOf(layout)
      let toggle = layout.labelled(layoutControlsToggleLabel)
      let controls = findByAttr(layout, "data-layout-controls", "true")
      need(controls)
      check attr(toggle, "aria-expanded") == "false"
      check display(controls) == "none"
      # The responsive mode the preview shows.
      check textOf(findByAttr(toggle, "data-layout-responsive-mode", "true")) ==
        "desktop"
      vm.viewport.val = makeBuiltinViewport(pvkPhone)
      check textOf(findByAttr(toggle, "data-layout-responsive-mode", "true")) ==
        "mobile"
      toggle.fireEvent("click")
      check vm.inspector.layoutControlsShown.val
      check attr(toggle, "aria-expanded") == "true"
      check display(controls) == "flex"
      toggle.fireEvent("click")
      check display(controls) == "none"
      # flex-wrap is no longer a second, generic text row in Layout.
      check findByAttr(layout, "data-exposed-css-property", "flex-wrap") == nil
      check findByAttr(layout, "data-exposed-css-property", "aspect-ratio") != nil
      dispose()

  test "on a block layout flex wrap and grid tracks say why they do not apply":
    createRoot proc(dispose: proc()) =
      let r = MockRenderer()
      let foundation = new(string)
      foundation[] = DemoFoundationInitialSource
      let vm = layoutVm(foundation)
      let panel = renderInspectorPanel[MockRenderer, MockNode](r, vm)
      let wrap = panel.labelled(flexWrapToggleLabel)
      let tracks = panel.labelled(gridTracksLabel)
      need(wrap)
      need(tracks)
      check attr(wrap, "aria-pressed") == "false"
      check attr(wrap, "aria-disabled") == "true"
      check attr(wrap, "title") == flexWrapReason
      check attr(tracks, "aria-disabled") == "true"
      check attr(tracks, "title") == gridTracksReason
      wrap.fireEvent("click")
      check panel.layoutMessage == flexWrapReason
      tracks.fireEvent("click")
      check panel.layoutMessage == gridTracksReason
      check not vm.inspector.layoutControlsShown.val
      check vm.stacks == (0, 0)
      check vm.inspector.pendingSourceEdits.val.len == 0
      check foundation[] == DemoFoundationInitialSource
      dispose()

  test "on a flex layout Enable flex wrap commits flex-wrap through its row":
    createRoot proc(dispose: proc()) =
      let r = MockRenderer()
      let foundation = new(string)
      foundation[] = DemoFoundationInitialSource
      let vm = layoutVm(foundation)
      let panel = renderInspectorPanel[MockRenderer, MockNode](r, vm)
      # The layout becomes horizontal: one `display` commit.
      panel.setLayout("horizontal")
      check vm.value("display") == "flex"
      vm.write()
      check longTail("display", "flex") in foundation[]
      let wrap = panel.labelled(flexWrapToggleLabel)
      need(wrap)
      check attr(wrap, "aria-disabled") == "false"
      let generation = vm.autoSaveGeneration.val
      wrap.fireEvent("click")
      check vm.value("flex-wrap") == "wrap"
      check vm.stacks == (2, 0)
      check vm.autoSaveGeneration.val == generation + 1
      check attr(wrap, "aria-pressed") == "true"
      # The Wrap row is the same property: it shows the value.
      vm.inspector.layoutControlsShown.val = true
      check textOf(findByAttr(panel.row("wrap"),
        "data-choice-group-trigger-label", "true")) == "Wrap"
      vm.write()
      check longTail("flex-wrap", "wrap") in foundation[]
      check longTail("flex-wrap", "nowrap") notin foundation[]
      # Pressed again, it unwraps; undo puts the exact bytes back.
      wrap.fireEvent("click")
      check vm.value("flex-wrap") == "nowrap"
      check attr(wrap, "aria-pressed") == "false"
      vm.write()
      check vm.runEditorCommand(eckUndo).status == ecsSucceeded
      vm.write()
      check longTail("flex-wrap", "wrap") in foundation[]
      check vm.runEditorCommand(eckUndo).status == ecsSucceeded
      vm.write()
      check vm.runEditorCommand(eckUndo).status == ecsSucceeded
      vm.write()
      check foundation[] == DemoFoundationInitialSource
      dispose()

  test "grid tracks and constraints open the controls at their group":
    createRoot proc(dispose: proc()) =
      let r = MockRenderer()
      let foundation = new(string)
      foundation[] = DemoFoundationInitialSource
      let vm = layoutVm(foundation)
      let panel = renderInspectorPanel[MockRenderer, MockNode](r, vm)
      let constraints = panel.labelled(constraintsLabel)
      need(constraints)
      check textOf(findByAttr(panel, "data-layout-constraint-summary", "true")) ==
        "Constraints \xC2\xB7 static"
      constraints.fireEvent("click")
      check vm.inspector.layoutControlsShown.val
      check r.activeElement() ==
        findByAttr(panel, "data-layout-controls-group", "constraints")
      vm.inspector.layoutControlsShown.val = false
      panel.setLayout("grid")
      check vm.value("display") == "grid"
      let tracks = panel.labelled(gridTracksLabel)
      check attr(tracks, "aria-disabled") == "false"
      tracks.fireEvent("click")
      check vm.inspector.layoutControlsShown.val
      check r.activeElement() ==
        findByAttr(panel, "data-layout-controls-group", "grid")
      check panel.layoutMessage == ""
      dispose()

suite "the auto layout, grid and constraint rows":
  test "each group appears for its layout and each row commits through its pipeline":
    createRoot proc(dispose: proc()) =
      let r = MockRenderer()
      let foundation = new(string)
      foundation[] = DemoFoundationInitialSource
      let vm = layoutVm(foundation)
      let panel = renderInspectorPanel[MockRenderer, MockNode](r, vm)
      vm.inspector.layoutControlsShown.val = true
      let auto = findByAttr(panel, "data-layout-controls-group", "auto-layout")
      let grid = findByAttr(panel, "data-layout-controls-group", "grid")
      need(auto)
      need(grid)
      # A block layout: neither sub-panel, a note in each.
      check display(findByAttr(auto, "data-layout-controls-note", "auto-layout")) == "block"
      check display(findByAttr(auto, "data-layout-controls-rows", "auto-layout")) == "none"
      check display(findByAttr(grid, "data-layout-controls-note", "grid")) == "block"
      # Constraints apply to every layout; a property the selection does not
      # expose has no row.
      check display(findByAttr(panel, "data-layout-controls-property", "position")) == "flex"
      check display(findByAttr(panel, "data-layout-controls-property", "min-width")) == "flex"
      check display(findByAttr(panel, "data-layout-controls-property", "max-width")) == "none"
      # Flex: Align and Justify.
      # Each step is written before the next, as the automatic write does
      # between gestures.
      panel.setLayout("horizontal")
      vm.write()
      check display(findByAttr(auto, "data-layout-controls-note", "auto-layout")) == "none"
      panel.pick("align", 1)
      check vm.value("align-items") == "center"
      vm.write()
      panel.pick("justify", 3)
      check vm.value("justify-content") == "space-between"
      vm.write()
      # Grid: track lists as CSS text, and the auto flow.
      panel.setLayout("grid")
      vm.write()
      check display(findByAttr(grid, "data-layout-controls-note", "grid")) == "none"
      r.typeRow(panel, "columns", "repeat(2, minmax(0, 1fr))")
      check vm.value("grid-template-columns") == "repeat(2, minmax(0, 1fr))"
      vm.write()
      r.typeRow(panel, "rows", "auto 1fr")
      vm.write()
      panel.pick("flow", 2)
      check vm.value("grid-auto-flow") == "row dense"
      vm.write()
      # Constraints.
      panel.pick("position", 1)
      check vm.value("position") == "relative"
      vm.write()
      r.typeRow(panel, "min-w", "120px")
      check vm.value("min-width") == "120px"
      vm.write()
      check vm.inspector.undoStack.val.len == 9
      for (property, value) in [("display", "grid"), ("align-items", "center"),
          ("justify-content", "space-between"),
          ("grid-template-columns", "repeat(2, minmax(0, 1fr))"),
          ("grid-template-rows", "auto 1fr"), ("grid-auto-flow", "row dense"),
          ("position", "relative"), ("min-width", "120px")]:
        check longTail(property, value) in foundation[]
      # One undo entry each; every one goes back to the exact bytes.
      for _ in 0 ..< 9:
        check vm.runEditorCommand(eckUndo).status == ecsSucceeded
        vm.write()
      check foundation[] == DemoFoundationInitialSource
      dispose()

  test "a row's value is validated and refused at the act":
    createRoot proc(dispose: proc()) =
      let r = MockRenderer()
      let foundation = new(string)
      foundation[] = DemoFoundationInitialSource
      let vm = layoutVm(foundation, writable = false)
      let panel = renderInspectorPanel[MockRenderer, MockNode](r, vm)
      vm.inspector.layoutControlsShown.val = true
      panel.pick("position", 2)
      check vm.value("position") == "static"
      check "read-only" in textOf(panel.row("position"))
      check vm.stacks == (0, 0)
      check foundation[] == DemoFoundationInitialSource
      dispose()

  test "search finds the controls, and raw CSS covers their rows":
    createRoot proc(dispose: proc()) =
      let r = MockRenderer()
      let foundation = new(string)
      foundation[] = DemoFoundationInitialSource
      let vm = layoutVm(foundation)
      let panel = renderInspectorPanel[MockRenderer, MockNode](r, vm)
      let toggle = panel.labelled(layoutControlsToggleLabel)
      need(toggle)
      check attr(toggle, "data-inspector-search-match") == "false"
      let search = findByAttr(panel, "data-inspector-search-input", "true")
      need(search)
      r.setInputValue(search, "justify")
      search.fireEvent("input")
      check attr(toggle, "data-inspector-search-match") == "true"
      r.setInputValue(search, "")
      search.fireEvent("input")
      # Layout's raw CSS lists the controls' declarations.
      let rawToggle = panel.labelled("Show raw CSS for Layout section")
      need(rawToggle)
      rawToggle.fireEvent("click")
      let field = panel.labelled("Edit raw CSS for Layout section")
      need(field)
      let text = r.inputValue(field)
      for declaration in ["align-items: normal;", "justify-content: normal;",
          "grid-template-columns: none;", "grid-auto-flow: row;",
          "position: static;", "min-width: auto;", "flex-wrap: nowrap;"]:
        check declaration in text
      dispose()

suite "responsive overrides":
  test "each mode below Desktop is written in the project's breakpoint for it":
    createRoot proc(dispose: proc()) =
      let foundation = new(string)
      foundation[] = DemoFoundationInitialSource
      let vm = layoutVm(foundation)
      let targets = vm.responsiveOverrideTargets()
      check targets.len == 2
      check targets[0].modeKey == "tablet" and targets[0].width == 1024
      check targets[0].breakpoint.condition == ""
      check targets[0].refusal == "No breakpoint in the project's stylesheet " &
        "applies to Tablet (1024px wide), so there is nowhere to write its override."
      check targets[1].modeKey == "mobile" and targets[1].width == 390
      check targets[1].breakpoint.condition == Compact
      check targets[1].refusal == ""
      # While the preview shows Mobile, its own width decides.
      vm.viewport.val = makeBuiltinViewport(pvkPhoneXl)
      vm.previewRenderedWidth.val = 700
      check vm.responsiveOverrideTarget("mobile").width == 700
      check "no breakpoint" notin vm.responsiveOverrideTarget("mobile").refusal
      check vm.responsiveOverrideTarget("mobile").breakpoint.condition == ""
      # A breakpoint that also covers Desktop is not an override.
      vm.previewRenderedWidth.val = 0
      vm.viewport.val = makeBuiltinViewport(pvkDesktop)
      vm.responsiveBreakpoints.val = @[ResponsiveBreakpoint(label: "\xE2\x89\xA4 2000px",
        condition: "@media (max-width: 2000px)", minWidth: -1, maxWidth: 2000)]
      check "applies at Desktop (1440px) too" in
        vm.responsiveOverrideTarget("mobile").refusal
      # So is a min-width one that reaches Mobile: it applies at every width
      # above its minimum, Desktop included.
      vm.responsiveBreakpoints.val = @[ResponsiveBreakpoint(label: "\xE2\x89\xA5 320px",
        condition: "@media (min-width: 320px)", minWidth: 320, maxWidth: -1)]
      check vm.responsiveOverrideTarget("mobile").breakpoint.condition ==
        "@media (min-width: 320px)"
      check "applies at Desktop (1440px) too" in
        vm.responsiveOverrideTarget("mobile").refusal
      # A min-width breakpoint that stops below Desktop is the mode's own.
      vm.responsiveBreakpoints.val = @[ResponsiveBreakpoint(label: "320-700px",
        condition: "@media (min-width: 320px) and (max-width: 700px)",
        minWidth: 320, maxWidth: 700)]
      check vm.responsiveOverrideTarget("mobile").refusal == ""
      vm.responsiveBreakpoints.val = @[]
      check vm.responsiveOverrideTarget("tablet").refusal ==
        "The project's stylesheet defines no breakpoints, so there is " &
        "nowhere to write a Tablet override."
      dispose()

  test "an override is written in the breakpoint, undone exactly, and leaves Desktop alone":
    createRoot proc(dispose: proc()) =
      let r = MockRenderer()
      let foundation = new(string)
      foundation[] = DemoFoundationInitialSource
      let vm = layoutVm(foundation)
      let panel = renderInspectorPanel[MockRenderer, MockNode](r, vm)
      vm.inspector.layoutControlsShown.val = true
      let value = findByAttr(panel, "data-layout-override-value", "true")
      let mobile = panel.labelled(responsiveOverrideLabel("Mobile"))
      need(value)
      need(mobile)
      # The property is gap, and the field starts at its value.
      check attr(findByAttr(panel, "data-layout-override-property", "gap"),
        "aria-pressed") == "true"
      check r.inputValue(value) == "normal"
      check textOf(findByAttr(panel, "data-layout-override-breakpoint",
        "mobile")) == "\xE2\x89\xA4 640px"
      check "Writes gap in the class rule" in
        textOf(findByAttr(panel, "data-layout-override-scope", "true"))
      let generation = vm.autoSaveGeneration.val
      r.setInputValue(value, "12px")
      mobile.fireEvent("click")
      check vm.stacks == (1, 0)
      check vm.autoSaveGeneration.val == generation + 1
      # Desktop's value is not the override's.
      check vm.value("gap") == "normal"
      check textOf(findByAttr(panel, "data-layout-override-message", "true")) ==
        "Mobile: gap set to 12px inside " & Compact & "."
      let plan = vm.inspector.pendingSourceEdits.val[0]
      check plan.breakpointCondition == Compact
      check plan.sourceScope == sskSharedClass
      vm.write()
      let written = DemoFoundationInitialSource.replace(
        "  .destination-card { font-size: 13px; }\n",
        "  .destination-card { font-size: 13px; }\n  .long-tail-card { gap: 12px; }\n")
      check foundation[] == written
      # The base rule is untouched.
      check longTail("gap", "normal") in foundation[]
      # Replaced, then removed: each its own undo entry.
      r.setInputValue(value, "16px")
      mobile.fireEvent("click")
      vm.write()
      check "  .long-tail-card { gap: 16px; }\n" in foundation[]
      r.setInputValue(value, "")
      mobile.fireEvent("click")
      check textOf(findByAttr(panel, "data-layout-override-message", "true")) ==
        "Mobile: gap override removed inside " & Compact & "."
      vm.write()
      check "  .long-tail-card { }\n" in foundation[]
      check vm.stacks == (3, 0)
      for expected in ["  .long-tail-card { gap: 16px; }\n",
          "  .long-tail-card { gap: 12px; }\n"]:
        check vm.runEditorCommand(eckUndo).status == ecsSucceeded
        vm.write()
        check expected in foundation[]
      check vm.runEditorCommand(eckUndo).status == ecsSucceeded
      # The preview is asked to take the override back, in the breakpoint.
      let request = vm.inspector.previewValueRequest.val
      check request.property == "gap"
      check request.condition == Compact
      check request.value == ""
      vm.write()
      check foundation[] == DemoFoundationInitialSource
      dispose()

  test "a base edit and an override of one property are separate edits":
    createRoot proc(dispose: proc()) =
      let foundation = new(string)
      foundation[] = DemoFoundationInitialSource
      let vm = layoutVm(foundation)
      check commitInspectorValue(vm, "gap", "8px", sskSharedClass).ok
      check commitResponsiveOverrideValue(vm, "gap", "4px", "mobile").ok
      check vm.inspector.pendingSourceEdits.val.len == 2
      vm.write()
      check longTail("gap", "8px") in foundation[]
      check "  .long-tail-card { gap: 4px; }\n" in foundation[]
      check vm.value("gap") == "8px"
      # With the override's rule inside the block, the base rule is still the
      # class's one rule: a later base edit writes it, and only it.
      check commitInspectorValue(vm, "gap", "10px", sskSharedClass).ok
      vm.write()
      check longTail("gap", "10px") in foundation[]
      check "  .long-tail-card { gap: 4px; }\n" in foundation[]
      dispose()

  test "while the preview shows the mode, the selection takes the override's value":
    createRoot proc(dispose: proc()) =
      let foundation = new(string)
      foundation[] = DemoFoundationInitialSource
      let vm = layoutVm(foundation)
      vm.viewport.val = makeBuiltinViewport(pvkPhone)
      check vm.activeBreakpoint.val.condition == Compact
      check commitResponsiveOverrideValue(vm, "gap", "6px", "mobile").ok
      check vm.value("gap") == "6px"
      check vm.runEditorCommand(eckUndo).status == ecsSucceeded
      check vm.value("gap") == "normal"
      dispose()

  test "an override that cannot be written is refused at the act with the reason":
    createRoot proc(dispose: proc()) =
      let r = MockRenderer()
      let foundation = new(string)
      foundation[] = DemoFoundationInitialSource
      let vm = layoutVm(foundation)
      let panel = renderInspectorPanel[MockRenderer, MockNode](r, vm)
      vm.inspector.layoutControlsShown.val = true
      let tablet = panel.labelled(responsiveOverrideLabel("Tablet"))
      need(tablet)
      # A mode without a breakpoint still answers: it is not aria-disabled.
      check attr(tablet, "aria-disabled") == ""
      check attr(tablet, "data-layout-override-available") == "false"
      check textOf(findByAttr(panel, "data-layout-override-breakpoint",
        "tablet")) == "no breakpoint"
      tablet.fireEvent("click")
      check textOf(findByAttr(panel, "data-layout-override-message", "true")) ==
        "Tablet: No breakpoint in the project's stylesheet applies to " &
        "Tablet (1024px wide), so there is nowhere to write its override."
      check vm.stacks == (0, 0)
      # A property the selection does not expose.
      let absent = commitResponsiveOverrideValue(vm, "max-width", "1px", "mobile")
      check not absent.ok
      check absent.message == "The selected element does not expose max-width."
      # A property no class rule owns for the selection has no rule to
      # repeat: the scope note and the press both say so.
      var unowned = layoutCard()
      for prop in unowned.properties.mitems:
        if prop.name == "gap":
          prop.schemaKey = "dom.card.gap"
          prop.origin = poInherited
          prop.originDetail = "iframe-dom:card:gap"
          prop.sharedCount = 0
      check vm.selectInspectorElement(unowned)
      const unmapped = "No project schema owner is currently mapped for this scope."
      check vm.responsiveOverrideScope("gap").refusal == unmapped
      check textOf(findByAttr(panel, "data-layout-override-scope", "true")) == unmapped
      let unscoped = commitResponsiveOverrideValue(vm, "gap", "2px", "mobile")
      check not unscoped.ok
      check unscoped.message == unmapped
      check vm.selectInspectorElement(layoutCard())
      # An invalid value is the row's refusal.
      let invalid = commitResponsiveOverrideValue(vm, "gap", "12 apples", "mobile")
      check not invalid.ok
      check invalid.message == "CSS length values must use a numeric amount."
      check vm.stacks == (0, 0)
      check vm.inspector.pendingSourceEdits.val.len == 0
      check foundation[] == DemoFoundationInitialSource
      dispose()

  test "a writer that does not state breakpointOverrides is never handed one":
    createRoot proc(dispose: proc()) =
      let foundation = new(string)
      foundation[] = DemoFoundationInitialSource
      let vm = layoutVm(foundation, overrides = false)
      let refused = commitResponsiveOverrideValue(vm, "gap", "4px", "mobile")
      check not refused.ok
      check refused.message == "This project's source writer cannot write a " &
        "gap override inside " & Compact & " in " & DemoFoundationSource & "."
      check vm.stacks == (0, 0)
      # The same commit is still admitted for the base rule.
      check commitInspectorValue(vm, "gap", "4px", sskSharedClass).ok
      dispose()

  test "a read-only workspace and the native source connection refuse overrides":
    createRoot proc(dispose: proc()) =
      let foundation = new(string)
      foundation[] = DemoFoundationInitialSource
      let readOnly = layoutVm(foundation, writable = false)
      check commitResponsiveOverrideValue(readOnly, "gap", "4px", "mobile").message ==
        "This workspace is read-only for source changes."
      let native = layoutVm(foundation)
      var submitted = 0
      native.inspectorSourceCommit = proc(element: ElementRef; property,
          value: string; scope: SourceScopeChoiceKind;
          done: proc(ok: bool; diagnostic: string) {.closure.}) =
        inc submitted
        done(true, "")
      check commitResponsiveOverrideValue(native, "gap", "4px", "mobile").message ==
        "The native source connection does not write responsive overrides."
      check submitted == 0
      check native.stacks == (0, 0)
      check foundation[] == DemoFoundationInitialSource
      dispose()
