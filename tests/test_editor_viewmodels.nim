## Tests for IsoNim Editor ViewModels (M0)

import std/[options, unittest, strutils, sequtils]
import isonim/core/[signals, computation, owner]
import isonim/viewmodel
import isonim/editor/viewmodels
import isonim/editor/workspace
import isonim/editor/views/page_preview
import isonim/testing/mock_dom
import examples/wanderlust/stories as wanderlust

suite "Editor ViewModels (M0)":

  test "test_editor_vm_initial_state":
    ## EditorVM starts in view mode with no story selected
    createRoot proc(dispose: proc()) =
      let vm = createEditorVM()
      check vm.editMode.val == emView
      check vm.selectedStory.val.name == ""
      check vm.hasSelection.val == false
      check vm.panels.val.sidebar == true
      check vm.panels.val.inspector == true
      check vm.platform.val == pfWeb
      dispose()

  test "test_sidebar_vm_story_selection":
    ## Selecting a story in SidebarVM updates EditorVM.selectedStory
    createRoot proc(dispose: proc()) =
      let vm = createEditorVM()
      vm.sidebar.groups.val = @[
        StoryGroup(name: "TaskRow", kind: skComponent, items: @[
          StoryItem(name: "Active task", description: "Normal task",
            kind: skComponent, group: "TaskRow"),
        ]),
      ]
      let story = StoryRef(
        group: "TaskRow",
        name: "Active task",
        kind: skComponent,
        index: 0)
      vm.sidebar.selectStory(vm, story)
      check vm.selectedStory.val.name == "Active task"
      check vm.selectedStory.val.group == "TaskRow"
      check vm.hasSelection.val == true
      dispose()

  test "test_inspector_vm_element_selection":
    ## Selecting an element populates InspectorVM with properties
    createRoot proc(dispose: proc()) =
      let vm = createEditorVM()
      check vm.inspector.hasElement.val == false

      let elem = ElementRef(
        tag: "div",
        sourceFile: "branded_controls.nim",
        sourceLine: 42,
        properties: @[
          PropertyInfo(name: "padding", value: "16", origin: poTailwindClass,
            originDetail: "class:p-4", sharedCount: 0),
          PropertyInfo(name: "background-color", value: "#6366F1",
            origin: poThemeToken,
            originDetail: "themeColor(\"primary\")",
            sharedCount: 4),
        ])
      vm.inspector.selectElement(elem)

      check vm.inspector.hasElement.val == true
      check vm.inspector.properties.val.len == 2
      check vm.inspector.properties.val[0].name == "padding"
      check vm.inspector.properties.val[1].sharedCount == 4
      dispose()

  test "test_agent_chat_vm_message_accumulation":
    ## User edits accumulate in AgentChatVM between prompts
    createRoot proc(dispose: proc()) =
      let vm = createEditorVM()
      check vm.chat.messageCount.val == 0
      check vm.chat.accumulatedEdits.val.len == 0

      # Record some inspector edits
      vm.chat.recordEdit(EditRecord(file: "controls.nim", line: 42,
        property: "padding", oldValue: "12", newValue: "16"))
      vm.chat.recordEdit(EditRecord(file: "controls.nim", line: 23,
        property: "background-color", oldValue: "#F8FAFC", newValue: "#FFFFFF"))
      check vm.chat.accumulatedEdits.val.len == 2

      # Send a prompt — edits should be clearable
      vm.chat.addUserMessage("Make the cards more rounded")
      check vm.chat.messageCount.val == 1
      vm.chat.clearAccumulatedEdits()
      check vm.chat.accumulatedEdits.val.len == 0

      # Agent responds
      vm.chat.addAgentResponse("Changed rounded-xl to rounded-2xl")
      check vm.chat.messageCount.val == 2
      dispose()

  test "test_flow_player_vm_step_navigation":
    ## FlowPlayerVM advances through steps, wraps at end
    createRoot proc(dispose: proc()) =
      let vm = createEditorVM()
      vm.flowPlayer.steps.val = @[
        FlowStep(action: "Opens app", description: "Empty state"),
        FlowStep(action: "Types 'Buy groceries'", description: "Input focused"),
        FlowStep(action: "Taps + button", description: "Task added"),
      ]

      check vm.flowPlayer.totalSteps.val == 3
      check vm.flowPlayer.currentStep.val == 0
      check vm.flowPlayer.isFirstStep.val == true
      check vm.flowPlayer.currentAction.val == "Opens app"

      vm.flowPlayer.nextStep()
      check vm.flowPlayer.currentStep.val == 1
      check vm.flowPlayer.isFirstStep.val == false

      vm.flowPlayer.nextStep()
      check vm.flowPlayer.currentStep.val == 2
      check vm.flowPlayer.isLastStep.val == true

      # Wraps to beginning
      vm.flowPlayer.nextStep()
      check vm.flowPlayer.currentStep.val == 0

      # Wraps backward
      vm.flowPlayer.prevStep()
      check vm.flowPlayer.currentStep.val == 2
      dispose()

  test "test_viewmodels_contain_no_presentation":
    ## Grep all VM types for CSS classes, hex colors, Tailwind classes
    # This test reads the source files and verifies no presentation leaks
    let vmFile = readFile("src/isonim/editor/viewmodels.nim")
    let typesFile = readFile("src/isonim/editor/types.nim")

    # No hex color literals (like #FF0000 or #fff)
    for line in vmFile.splitLines:
      if line.strip().startsWith("#") or line.strip().startsWith("##"):
        continue # Skip comments
      check not line.contains("#[0-9a-fA-F]")

    # No Tailwind class strings
    check "class =" notin vmFile
    check "rounded" notin vmFile
    check "flex-" notin vmFile
    check "bg-" notin vmFile
    check "text-" notin vmFile.replace("setTextContent", "").replace("text:", "")

    # Types file also clean
    check "class =" notin typesFile
    check "#[0-9a-fA-F]" notin typesFile

  test "test_sidebar_search_filter":
    ## SidebarVM search filters groups by name/description
    createRoot proc(dispose: proc()) =
      let vm = createEditorVM()
      vm.sidebar.groups.val = @[
        StoryGroup(name: "TaskRow", kind: skComponent, items: @[
          StoryItem(name: "Active task", description: "Normal task",
              kind: skComponent, group: "TaskRow"),
          StoryItem(name: "Completed", description: "Done task",
              kind: skComponent, group: "TaskRow"),
        ]),
        StoryGroup(name: "FilterBar", kind: skComponent, items: @[
          StoryItem(name: "All selected", description: "All filter",
              kind: skComponent, group: "FilterBar"),
        ]),
      ]

      check vm.sidebar.filteredItems.val.len == 2

      vm.sidebar.setSearch("task")
      check vm.sidebar.filteredItems.val.len == 1
      check vm.sidebar.filteredItems.val[0].name == "TaskRow"

      vm.sidebar.setSearch("")
      check vm.sidebar.filteredItems.val.len == 2
      dispose()

  test "test_sidebar_toggle_group":
    ## SidebarVM toggles group expanded state
    createRoot proc(dispose: proc()) =
      let vm = createEditorVM()
      vm.sidebar.groups.val = @[
        StoryGroup(name: "TaskRow", kind: skComponent, expanded: false,
            items: @[]),
      ]

      check vm.sidebar.groups.val[0].expanded == false
      vm.sidebar.toggleGroup("TaskRow")
      check vm.sidebar.groups.val[0].expanded == true
      vm.sidebar.toggleGroup("TaskRow")
      check vm.sidebar.groups.val[0].expanded == false
      dispose()

  test "test_review_results_counts":
    ## ReviewResultsVM correctly counts errors and warnings
    createRoot proc(dispose: proc()) =
      let vm = createEditorVM()
      check vm.review.hasIssues.val == false
      check vm.review.errorCount.val == 0

      vm.review.violations.val = @[
        Violation(severity: vsError, category: vcViewModelBoundary,
                  message: "CSS class in ViewModel", autoFixable: true),
        Violation(severity: vsWarning, category: vcTailwindPreference,
                  message: "Use class instead of setStyle", autoFixable: true),
        Violation(severity: vsError, category: vcDryTokens,
                  message: "Repeated hex color", autoFixable: false),
      ]

      check vm.review.hasIssues.val == true
      check vm.review.errorCount.val == 2
      check vm.review.warningCount.val == 1
      dispose()

suite "Editor ViewModels (M18 headless contracts)":

  func refFrom(groups: seq[StoryGroup]; groupIndex, itemIndex: int): StoryRef =
    let group = groups[groupIndex]
    let item = group.items[itemIndex]
    StoryRef(group: item.group, name: item.name, kind: item.kind,
        index: itemIndex)

  test "editor_vm_select_story_updates_view_and_selection":
    createRoot proc(dispose: proc()) =
      let groups = wanderlust.buildWanderlustStoryboard()
      let vm = createEditorVM()
      vm.sidebar.groups.val = groups

      let componentStory = refFrom(groups, 4, 0)
      check vm.selectStory(componentStory)
      check vm.selectedStory.val.name == componentStory.name
      check vm.selectedStory.val.group == componentStory.group
      check vm.hasSelection.val
      check vm.activeView.val == evComponentDetail

      let pageStory = refFrom(groups, 3, 0)
      check vm.selectStory(pageStory)
      check vm.selectedStory.val.name == pageStory.name
      check vm.activeView.val == evPagePreview

      let flowStory = refFrom(groups, 0, 0)
      check vm.selectStory(flowStory)
      check vm.selectedStory.val.name == flowStory.name
      check vm.activeView.val == evPagePreview
      dispose()

  test "editor_vm_canvas_selection_drives_story_and_flow_state":
    createRoot proc(dispose: proc()) =
      let groups = wanderlust.buildWanderlustStoryboard()
      let firstStep = refFrom(groups, 0, 0)
      let secondStep = refFrom(groups, 0, 1)
      let pageStory = refFrom(groups, 3, 0)
      let vm = createEditorVM()
      vm.sidebar.groups.val = groups
      vm.storyboard.canvasItems.val = @[
        CanvasItem(storyRef: firstStep, x: 0, y: 0, width: 320, height: 200,
          label: "Home"),
        CanvasItem(storyRef: secondStep, x: 360, y: 0, width: 320, height: 200,
          label: "Detail"),
        CanvasItem(storyRef: pageStory, x: 720, y: 0, width: 320, height: 200,
          label: "Page")
      ]
      vm.flowPlayer.steps.val = @[
        FlowStep(screenRef: firstStep, action: "Browse home",
          description: "Starts the trip-planning flow"),
        FlowStep(screenRef: secondStep, action: "Open destination",
          description: "Continues to destination detail")
      ]

      check vm.selectCanvasItem(1)
      check vm.storyboard.selectedItem.val == 1
      check vm.selectedStory.val.name == secondStep.name
      check vm.selectedStory.val.group == secondStep.group
      check vm.flowPlayer.currentStep.val == 1
      check vm.activeView.val == evStoryboard

      check vm.selectCanvasItem(2)
      check vm.storyboard.selectedItem.val == 2
      check vm.selectedStory.val.name == pageStory.name
      check vm.flowPlayer.currentStep.val == 1
      check vm.activeView.val == evPagePreview
      dispose()

  test "editor_vm_empty_workspace_actions_are_safe":
    createRoot proc(dispose: proc()) =
      let vm = createEditorVM()

      vm.setActiveView(evVectorEditor)
      let viewBeforeInvalidSelection = vm.activeView.val
      let storyBeforeInvalidSelection = vm.selectedStory.val
      let canvasBeforeInvalidSelection = vm.storyboard.selectedItem.val
      let flowStepBeforeInvalidSelection = vm.flowPlayer.currentStep.val

      check not vm.selectStory(StoryRef())
      for invalidStory in [
        StoryRef(group: "Missing pages", name: "Dashboard",
          kind: skPage, index: 0),
        StoryRef(group: "Missing components", name: "Button",
          kind: skComponent, index: 3),
        StoryRef(group: "Missing flows", name: "Checkout",
          kind: skFlow, index: 9)
      ]:
        check not vm.selectStory(invalidStory)

      for invalidIndex in [-4, -1, 0, 42]:
        check not vm.selectCanvasItem(invalidIndex)

      check vm.activeView.val == viewBeforeInvalidSelection
      check vm.selectedStory.val == storyBeforeInvalidSelection
      check vm.storyboard.selectedItem.val == canvasBeforeInvalidSelection
      check vm.flowPlayer.currentStep.val == flowStepBeforeInvalidSelection
      check not vm.selectVectorSymbol(0)
      check not vm.selectVectorSymbol(-1)
      check not vm.selectVectorSymbol(99)
      check vm.selectedStory.val.name == ""
      check vm.hasSelection.val == false
      check vm.storyboard.selectedItem.val == -1
      check vm.inspector.hasElement.val == false
      check vm.vectorEditor.selectedSymbol.val == -1
      check vm.chat.messages.val.len == 0
      check vm.chat.sessionStatus.val == asIdle

      vm.togglePanel(epSidebar)
      vm.switchInspectorSection(isFilters)
      vm.changePlatform(pfAndroid)
      vm.setAgentState(asLoading)
      vm.setAgentState(asError)
      vm.setAgentState(asReady)

      check vm.activeView.val == evVectorEditor
      check vm.panels.val.sidebar == false
      check vm.inspector.activeSection.val == isFilters
      check vm.platform.val == pfAndroid
      check vm.chat.sessionStatus.val == asReady
      check vm.selectedStory.val.name == ""
      check vm.hasSelection.val == false
      dispose()

suite "Editor ViewModels (M19 inspector edit engine)":

  func property(name, value: string; origin: PropertyOrigin; detail: string;
      file: string; line: int; sharedCount = 0): PropertyInfo =
    PropertyInfo(
      name: name,
      value: value,
      origin: origin,
      originDetail: detail,
      sourceFile: file,
      sourceLine: line,
      sharedCount: sharedCount)

  test "editor_inspector_edit_records_source_origin":
    createRoot proc(dispose: proc()) =
      let vm = createEditorVM()
      let element = ElementRef(
        tag: "article",
        sourceFile: "examples/wanderlust/components/views.nim",
        sourceLine: 42,
        sourceColumn: 7,
        properties: @[
          property("padding", "16px", poTailwindClass, "class:p-4",
            "examples/wanderlust/components/views.nim", 42),
          property("aria-label", "Destination card", poConstant,
            "const destinationCardLabel",
            "examples/wanderlust/components/views.nim", 43)
      ])

      check vm.selectInspectorElement(element)
      let edit = vm.editCssProperty("padding", "24px", pesLocal)

      check edit.status == pesAccepted
      check vm.inspector.selectedElement.val.properties[0].value == "24px"
      check vm.chat.accumulatedEdits.val.len == 1
      check vm.chat.accumulatedEdits.val[0].file ==
        "examples/wanderlust/components/views.nim"
      check vm.chat.accumulatedEdits.val[0].line == 42
      check vm.chat.accumulatedEdits.val[0].oldValue == "16px"
      check vm.chat.accumulatedEdits.val[0].newValue == "24px"
      check vm.chat.accumulatedEdits.val[0].origin == poTailwindClass
      check vm.chat.accumulatedEdits.val[0].originDetail == "class:p-4"
      check vm.chat.accumulatedEdits.val[0].scope == pesLocal
      check not vm.chat.accumulatedEdits.val[0].isShared
      check vm.inspector.pendingSourceEdits.val.len == 1
      check vm.inspector.pendingSourceEdits.val[0].originDetail == "class:p-4"

      var applied: seq[SourceEditPlan] = @[]
      proc adapter(plan: SourceEditPlan): bool =
        applied.add plan
        true

      check vm.inspector.applyPendingSourceEdits(adapter) == 1
      check applied.len == 1
      check applied[0].file == "examples/wanderlust/components/views.nim"
      check applied[0].property == "padding"
      check applied[0].oldValue == "16px"
      check applied[0].newValue == "24px"
      check vm.inspector.pendingSourceEdits.val.len == 0
      dispose()

  test "editor_inspector_shared_property_requires_scope_choice":
    createRoot proc(dispose: proc()) =
      let vm = createEditorVM()
      vm.selectInspectorElement(ElementRef(
        tag: "main",
        sourceFile: "apps/back-office/src/backoffice_ui/components.nim",
        sourceLine: 38,
        sourceColumn: 13,
        properties: @[
          property("gap", "24px", poThemeToken,
            "Metacraft spacing scale for dashboard bands",
            "apps/back-office/src/backoffice_ui/components.nim", 73,
            sharedCount = 5),
          property("background", "var(--mc-surface)", poThemeToken,
            "metacraft_design/generated/tokens.css",
            "apps/back-office/src/backoffice_ui/components.nim", 13,
            sharedCount = 9),
          property("border-radius", "8px", poSetStyle,
            "setStyle panel radius",
            "apps/back-office/src/backoffice_ui/components.nim", 80)
      ]))

      let missingScope = vm.editLayoutProperty("gap", "32px")
      check missingScope.status == pesNeedsScope
      check vm.inspector.selectedElement.val.properties[0].value == "24px"
      check vm.inspector.editDiagnostics.val.len == 1
      check vm.inspector.editDiagnostics.val[0].kind == pedSharedScopeRequired
      check vm.chat.accumulatedEdits.val.len == 0
      check vm.inspector.pendingSourceEdits.val.len == 0

      let sharedEdit = vm.editLayoutProperty("gap", "32px", pesShared)
      check sharedEdit.status == pesAccepted
      check vm.inspector.selectedElement.val.properties[0].value == "32px"
      check vm.chat.accumulatedEdits.val[0].isShared
      check vm.chat.accumulatedEdits.val[0].scope == pesShared

      let tokenDrift = vm.editCssProperty("background", "#ffffff", pesLocal)
      check tokenDrift.status == pesRejected
      check tokenDrift.diagnostics[0].kind == pedTokenDrift

      let directStyle = vm.editCssProperty("border-radius", "12px", pesLocal)
      check directStyle.status == pesRejected
      check directStyle.diagnostics[0].kind == pedUnsupportedDirectStyle
      dispose()

  test "editor_review_flags_non_idiomatic_isonim_patterns":
    createRoot proc(dispose: proc()) =
      let vm = createEditorVM()
      vm.review.reviewIsoNimSources(@[
        SourceSnapshot(
          file: "examples/wanderlust/components/views.nim",
          content: """
proc destinationCard(): string =
  uiString:
    tdiv:
      showIf(isSaved):
        span: text "Saved"
      forIn(destinations):
        article: text item.name
  result.add "<section>raw</section>"
  button(setStyle = "color: #ffffff")
  img(src = "hero.jpg")
"""),
        SourceSnapshot(
          file: "examples/wanderlust/components/viewmodels.nim",
          content: """
type CardVM = object
  title: string
let leaked = (class = "rounded-xl", background_color = "#ffffff")
""")
      ])

      let violations = vm.review.violations.val
      check violations.anyIt(it.category == vcDeprecatedDsl and
        it.file == "examples/wanderlust/components/views.nim")
      check violations.anyIt(it.category == vcHtmlBuilder and
        it.message.contains("Ad hoc HTML"))
      check violations.anyIt(it.category == vcViewModelBoundary and
        it.file == "examples/wanderlust/components/viewmodels.nim")
      check violations.anyIt(it.category == vcDirectStyle)
      check violations.anyIt(it.category == vcDryTokens)
      check violations.anyIt(it.category == vcAccessibility)
      check vm.review.errorCount.val >= 2
      check vm.review.warningCount.val >= 4
      dispose()

suite "Editor ViewModels (M25 edit commands)":

  func commandStory(): StoryRef =
    StoryRef(group: "DestinationCard", name: "Default",
      kind: skComponent, index: 0)

  func commandElement(sourceFile = "examples/wanderlust/components/views.nim";
      sourceLine = 42): ElementRef =
    ElementRef(
      tag: "article",
      sourceFile: sourceFile,
      sourceLine: sourceLine,
      sourceColumn: 7,
      properties: @[
        PropertyInfo(name: "padding", value: "16px",
          origin: poTailwindClass, originDetail: "class:p-4",
          sourceFile: sourceFile, sourceLine: sourceLine)
      ])

  proc installCommandStory(vm: EditorVM) =
    vm.sidebar.groups.val = @[
      StoryGroup(name: "DestinationCard", kind: skComponent,
        description: "Card component", expanded: true, items: @[
          StoryItem(name: "Default", description: "Default state",
            kind: skComponent, group: "DestinationCard")
      ])
    ]
    check vm.selectStory(commandStory())

  test "editor_commands_require_valid_selection_and_capability":
    createRoot proc(dispose: proc()) =
      let vm = createEditorVM()

      for kind in allEditorCommandKinds():
        let state = vm.evaluateCommand(kind)
        check state.label.len > 0
        check state.status == ecsDisabled
        check state.diagnostic.contains("Select a story")

      vm.installCommandStory()
      check vm.evaluateCommand(eckEdit).status == ecsAvailable
      check vm.runEditorCommand(eckEdit).status == ecsSucceeded
      check vm.editMode.val == emEdit
      check vm.activeView.val == evComponentEdit
      check vm.runEditorCommand(eckInspect).status == ecsSucceeded
      check vm.editMode.val == emView

      let noElementSave = vm.evaluateCommand(eckSave)
      check noElementSave.status == ecsDisabled
      check noElementSave.diagnostic.contains("Select an element")

      check vm.selectInspectorElement(commandElement(sourceFile = "",
        sourceLine = 0))
      let missingSource = vm.evaluateCommand(eckOpenSource)
      check missingSource.status == ecsDisabled
      check missingSource.diagnostic.contains("No source metadata")

      check vm.selectInspectorElement(commandElement())
      let readOnly = vm.evaluateCommand(eckSave)
      check readOnly.status == ecsDisabled
      check readOnly.diagnostic.contains("read-only")

      vm.workspacePermissions.val = EditorWorkspacePermissions(
        readSource: true,
        writeSource: true,
        createStory: true,
        createVariant: true,
        duplicate: true,
        delete: true)
      let adapterMissing = vm.evaluateCommand(eckSave)
      check adapterMissing.status == ecsDisabled
      check adapterMissing.diagnostic.contains("adapter")

      vm.sourceAdapterReady.val = true
      let noPendingEdits = vm.evaluateCommand(eckSave)
      check noPendingEdits.status == ecsDisabled
      check noPendingEdits.diagnostic.contains("pending source edits")

      let edit = vm.editCssProperty("padding", "24px", pesLocal)
      check edit.status == pesAccepted
      for kind in [eckApply, eckSave, eckDuplicate, eckDelete,
          eckCreateVariant, eckCreateStory, eckOpenSource]:
        let state = vm.evaluateCommand(kind)
        check state.status == ecsAvailable
        check state.sourceFile == "examples/wanderlust/components/views.nim"
        check state.sourceLine == 42

      let discardState = vm.runEditorCommand(eckDiscard)
      check discardState.status == ecsSucceeded
      check vm.inspector.pendingSourceEdits.val.len == 0
      check vm.chat.accumulatedEdits.val.len == 0

      dispose()

suite "Editor ViewModels (M26 source-backed CSS property editors)":

  func cssProp(name, value: string; origin: PropertyOrigin; detail: string;
      file = "examples/wanderlust/design/tokens.nim"; line = 12;
      sharedCount = 0; schemaKey = ""; tokenName = ""; variantKey = "";
      directStyleAllowed = false): PropertyInfo =
    PropertyInfo(
      name: name,
      value: value,
      origin: origin,
      originDetail: detail,
      sourceFile: file,
      sourceLine: line,
      sharedCount: sharedCount,
      schemaKey: schemaKey,
      tokenName: tokenName,
      variantKey: variantKey,
      directStyleAllowed: directStyleAllowed)

  func cssElement(properties: seq[PropertyInfo]): ElementRef =
    ElementRef(
      tag: "article",
      sourceFile: "examples/wanderlust/components/destination_card.nim",
      sourceLine: 44,
      sourceColumn: 5,
      properties: properties)

  test "css_property_editors_parse_validate_and_normalize_values":
    createRoot proc(dispose: proc()) =
      let vm = createEditorVM()
      let element = cssElement(@[
        cssProp("padding", "16px", poTailwindClass, "class:p-4"),
        cssProp("background", "token(surface.card)", poThemeToken,
          "schema:colors.surface.card", sharedCount = 4,
          tokenName = "surface.card"),
        cssProp("box-shadow", "0 2px 8px rgba(0,0,0,.2)", poConstant,
          "schema:elevation.card", schemaKey = "elevation.card"),
        cssProp("font-family", "Inter, system-ui", poConstant,
          "schema:typography.body", schemaKey = "typography.body"),
        cssProp("opacity", "1", poTailwindClass, "class:opacity-100"),
        cssProp("transition-timing-function", "ease-out", poConstant,
          "schema:motion.easeOut", schemaKey = "motion.easeOut"),
        cssProp("z-index", "10", poTailwindClass, "class:z-10"),
        cssProp("overflow", "hidden", poTailwindClass, "class:overflow-hidden"),
        cssProp("width", "calc(100% - 2rem)", poConstant,
          "schema:size.card", schemaKey = "size.card"),
        cssProp("color", "#FFAA00", poThemeToken,
          "schema:colors.text.accent", tokenName = "text.accent"),
        cssProp("background", "linear-gradient(#fff, #000)", poConstant,
          "schema:colors.heroGradient", schemaKey = "colors.heroGradient"),
        cssProp("filter", "blur(4px)", poConstant,
          "schema:effects.blur", schemaKey = "effects.blur"),
        cssProp("transition", "opacity 120ms ease-out", poConstant,
          "schema:motion.fade", schemaKey = "motion.fade"),
        cssProp("transform", "translateX(4px)", poConstant,
          "schema:motion.nudge", schemaKey = "motion.nudge"),
        cssProp("cursor", "pointer", poTailwindClass, "class:cursor-pointer"),
        cssProp("outline-offset", "2px", poConstant,
          "schema:a11y.focusRing", schemaKey = "a11y.focusRing")
      ])

      check vm.selectInspectorElement(element)
      let editors = vm.inspector.propertyEditors.val
      check editors.len == 16
      check editors.anyIt(it.property == "padding" and
        it.category == cpcSpacing and it.value.kind == cvkLength and
        it.value.unit == "px" and it.value.numeric == 16)
      check editors.anyIt(it.property == "background" and
        it.value.kind == cvkTokenReference and
        it.value.tokenName == "surface.card" and it.supportsSharedScope)
      check editors.anyIt(it.property == "box-shadow" and
        it.value.kind == cvkShadow)
      check editors.anyIt(it.property == "font-family" and
        it.value.kind == cvkFontStack and
        it.value.canonical == "Inter, system-ui")
      check editors.anyIt(it.property == "transition-timing-function" and
        it.value.kind == cvkTimingFunction)
      check editors.anyIt(it.property == "width" and
        it.value.kind == cvkLengthPercentage)
      check editors.anyIt(it.property == "color" and
        it.value.kind == cvkColor and it.value.canonical == "#ffaa00")
      check editors.anyIt(it.property == "background" and
        it.value.kind == cvkGradient)
      check editors.anyIt(it.property == "filter" and
        it.value.kind == cvkFilter)
      check editors.anyIt(it.property == "transition" and
        it.value.kind == cvkTransition)
      check editors.anyIt(it.property == "transform" and
        it.value.kind == cvkTransform)
      check editors.anyIt(it.property == "cursor" and
        it.category == cpcInteractionState and it.value.kind == cvkKeyword)
      check editors.anyIt(it.property == "outline-offset" and
        it.category == cpcBorder and it.value.kind == cvkLength)

      let validOpacity = vm.editCssProperty("opacity", "75%", pesLocal)
      check validOpacity.status == pesAccepted
      check vm.inspector.selectedElement.val.properties.anyIt(
        it.name == "opacity" and it.value == "0.75")

      let invalidPadding = vm.editCssProperty("padding", "-4px", pesLocal)
      check invalidPadding.status == pesRejected
      check invalidPadding.diagnostics.anyIt(it.kind == pedInvalidCssValue)

      let invalidToken = vm.editCssProperty("background", "token(missing)",
        pesShared)
      check invalidToken.status == pesRejected
      check invalidToken.diagnostics.anyIt(it.kind == pedInvalidTokenReference)

      let invalidUnit = vm.editCssProperty("padding", "12pt", pesLocal)
      check invalidUnit.status == pesRejected
      check invalidUnit.diagnostics.anyIt(it.kind == pedInvalidCssValue)

      let invalidTiming = vm.editCssProperty("transition-timing-function",
        "sproing", pesLocal)
      check invalidTiming.status == pesRejected
      check invalidTiming.diagnostics.anyIt(it.kind == pedInvalidCssValue)
      dispose()

  test "css_property_editors_choose_schema_token_or_source_plan":
    createRoot proc(dispose: proc()) =
      let vm = createEditorVM()
      check vm.selectInspectorElement(cssElement(@[
        cssProp("padding", "16px", poTailwindClass, "class:p-4"),
        cssProp("background", "token(surface.card)", poThemeToken,
          "schema:colors.surface.card", sharedCount = 3,
          tokenName = "surface.card"),
        cssProp("border-radius", "8px", poConstant,
          "schema:radius.card", schemaKey = "radius.card"),
        cssProp("transform", "scale(1)", poSetStyle,
          "style.transform", directStyleAllowed = true),
        cssProp("opacity", "1", poTailwindClass, "class:opacity-100"),
        cssProp("display", "grid", poConstant,
          "schema:components.card.variants.compact.display",
          schemaKey = "components.card.variants.compact.display",
          variantKey = "compact")
      ]))

      let tailwind = vm.editCssProperty("padding", "24px", pesLocal)
      check tailwind.status == pesAccepted
      check tailwind.sourceEdit.planKind == cspTailwindClassReplacement
      check tailwind.sourceEdit.previewBefore.contains("padding: 16px")
      check tailwind.sourceEdit.previewAfter.contains("padding: 24px")
      check tailwind.sourceEdit.reversible

      let token = vm.editCssProperty("background", "token(surface.raised)",
        pesShared)
      check token.status == pesAccepted
      check token.sourceEdit.planKind == cspTokenUpdate
      check token.sourceEdit.tokenName == "surface.raised"
      check token.sourceEdit.regeneratorHook == "regenerate-design-system"

      let schema = vm.editCssProperty("border-radius", "12px", pesLocal)
      check schema.status == pesAccepted
      check schema.sourceEdit.planKind == cspStructuredSchemaUpdate
      check schema.sourceEdit.schemaKey == "radius.card"

      let inline = vm.editCssProperty("transform", "scale(1.1)", pesLocal)
      check inline.status == pesAccepted
      check inline.sourceEdit.planKind == cspInlineStyleUpdate

      let removal = vm.editCssProperty("opacity", "", pesLocal)
      check removal.status == pesAccepted
      check removal.sourceEdit.planKind == cspPropertyRemoval

      let addition = vm.editCssProperty("margin-top", "2rem", pesLocal)
      check addition.status == pesAccepted
      check addition.sourceEdit.planKind == cspPropertyAddition
      let variant = vm.editCssProperty("display", "flex", pesShared)
      check variant.status == pesAccepted
      check variant.sourceEdit.planKind == cspStructuredSchemaUpdate
      check variant.sourceEdit.variantKey == "compact"
      check variant.sourceEdit.scope == pesShared
      check vm.inspector.sourcePreviews.val.len == 7
      dispose()

  test "css_property_editors_support_shared_scope_and_undo_redo":
    createRoot proc(dispose: proc()) =
      let vm = createEditorVM()
      check vm.selectInspectorElement(cssElement(@[
        cssProp("gap", "16px", poThemeToken, "schema:spacing.cardGap",
          sharedCount = 6, tokenName = "spacing.cardGap"),
        cssProp("padding", "16px", poTailwindClass, "class:p-4")
      ]))

      let missingScope = vm.editLayoutProperty("gap", "24px")
      check missingScope.status == pesNeedsScope
      check vm.inspector.pendingSourceEdits.val.len == 0

      let shared = vm.editLayoutProperty("gap", "24px", pesShared)
      check shared.status == pesAccepted
      check shared.sourceEdit.scope == pesShared
      check vm.inspector.isDirty.val
      check vm.inspector.undoStack.val.len == 1
      check vm.inspector.pendingSourceEdits.val.len == 1

      check vm.inspector.undoCssPropertyEdit()
      check vm.inspector.selectedElement.val.properties[0].value == "16px"
      check vm.inspector.pendingSourceEdits.val.len == 0
      check vm.inspector.redoStack.val.len == 1

      check vm.inspector.redoCssPropertyEdit()
      check vm.inspector.selectedElement.val.properties[0].value == "24px"
      check vm.inspector.pendingSourceEdits.val.len == 1

      let conflicts = vm.inspector.detectCssSourceConflicts(@[
        CSSSourceConflict(
          file: shared.sourceEdit.file,
          property: "gap",
          expectedOldValue: "16px",
          actualValue: "20px")
      ])
      check conflicts.len == 1
      check vm.inspector.saveCssPropertyEdits(proc(plan: SourceEditPlan): bool =
        true) == false

      vm.inspector.conflicts.val = @[]
      var savedPlans: seq[SourceEditPlan] = @[]
      check vm.inspector.saveCssPropertyEdits(proc(plan: SourceEditPlan): bool =
        savedPlans.add plan
        true)
      check savedPlans.len == 1
      check vm.inspector.pendingSourceEdits.val.len == 0
      check vm.inspector.undoStack.val.len == 0
      check not vm.inspector.isDirty.val

      let local = vm.editCssProperty("padding", "32px", pesLocal)
      check local.status == pesAccepted
      vm.inspector.discardCssPropertyEdits()
      check vm.inspector.selectedElement.val.properties.anyIt(
        it.name == "padding" and it.value == "16px")
      check not vm.inspector.isDirty.val
      dispose()

suite "Editor ViewModels (M20 story flow preview runtime)":

  func findItem(groups: seq[StoryGroup]; groupName, itemName: string;
      kind: StoryKind): StoryRef =
    for group in groups:
      if group.name == groupName and group.kind == kind:
        for i, item in group.items:
          if item.name == itemName and item.kind == kind:
            return StoryRef(group: item.group, name: item.name,
              kind: item.kind, index: i)

  test "editor_flow_player_selects_current_story":
    createRoot proc(dispose: proc()) =
      let groups = wanderlust.buildWanderlustStoryboard()
      let vm = createEditorVM()
      vm.sidebar.groups.val = groups
      vm.storyboard.canvasItems.val = wanderlust.wanderlustCanvasItems(groups)
      vm.flowPlayer.steps.val = wanderlust.wanderlustFlowSteps(groups)

      check vm.selectFlowStep(0)
      check vm.flowPlayer.currentAction.val ==
        "Browses trending destinations on home"
      check vm.selectedStory.val.name == "Home / Discover"
      check vm.storyboard.selectedItem.val == 0
      check vm.activeView.val == evStoryboard

      check vm.nextFlowStep()
      check vm.flowPlayer.currentStep.val == 1
      check vm.flowPlayer.currentAction.val ==
        "Taps Santorini card to see details"
      check vm.selectedStory.val.name == "Destination Detail"
      check vm.selectedStory.val.kind == skPage
      check vm.storyboard.selectedItem.val == 2
      check vm.activeView.val == evStoryboard

      check vm.prevFlowStep()
      check vm.flowPlayer.currentStep.val == 0
      check vm.selectedStory.val.name == "Home / Discover"
      check vm.storyboard.selectedItem.val == 0
      dispose()

  test "editor_story_filter_preserves_group_metadata":
    createRoot proc(dispose: proc()) =
      let groups = wanderlust.buildWanderlustStoryboard()
      let vm = createEditorVM()
      vm.sidebar.groups.val = groups

      vm.sidebar.setSearch("playfair")
      let foundationGroups = vm.sidebar.filteredItems.val.filterIt(
        it.name == "Foundations")
      check foundationGroups.len == 1
      check foundationGroups[0].kind == skFoundation
      check foundationGroups[0].description ==
        "Design tokens for the Wanderlust travel app"
      check foundationGroups[0].expanded == false
      check foundationGroups[0].items.len == 1
      check foundationGroups[0].items[0].name == "Typography"

      vm.sidebar.setSearch("jardin")
      let flowGroups = vm.sidebar.filteredItems.val.filterIt(
        it.name == "Travel Day")
      check flowGroups.len == 1
      check flowGroups[0].kind == skFlow
      check flowGroups[0].description ==
        "User follows their itinerary during an active trip"
      check flowGroups[0].expanded == true
      check flowGroups[0].items[0].kind == skFlow
      dispose()

  test "editor_preview_hook_contract_renders_project_story":
    createRoot proc(dispose: proc()) =
      var calls: seq[StoryRef] = @[]
      proc previewHook(story: StoryRef;
          platform: Platform): ProjectPreview {.closure.} =
        calls.add story
        ProjectPreview(
          status: ppsRendered,
          story: story,
          title: "Project render: " & story.name,
          bodyText: "Exact project preview for " & story.group &
            " on " & $platform,
          metadata: StoryRenderMetadata(
            story: story,
            title: story.name,
            sourceFile: "examples/wanderlust/pages/views.nim",
            sourceLine: 12,
            fixtureName: "wanderlust.page." & story.name,
            renderKind: "page"))

      let groups = wanderlust.buildWanderlustStoryboard()
      let selected = findItem(groups, "Pages", "Destination Detail", skPage)
      let vm = createEditorVM(newEditorWorkspace(
        title = "Wanderlust",
        storyGroups = groups,
        initialView = evPagePreview,
        initialStory = some(selected),
        previewHook = previewHook,
        platform = pfIOS))

      let preview = vm.preview.current.val
      check calls.len >= 1
      check calls[^1].name == "Destination Detail"
      check preview.status == ppsRendered
      check preview.title == "Project render: Destination Detail"
      check preview.bodyText == "Exact project preview for Pages on pfIOS"
      check preview.metadata.sourceFile ==
        "examples/wanderlust/pages/views.nim"

      let r = MockRenderer()
      let node = renderPagePreview[MockRenderer, MockNode](r, vm)
      check node.textContent.contains("Project render: Destination Detail")
      check node.textContent.contains("Exact project preview for Pages on pfIOS")

      for story in [
        findItem(groups, "Pages", "Home / Discover", skPage),
        findItem(groups, "DestinationCard", "Default", skComponent),
        findItem(groups, "Patterns", "Destination Grid", skPattern),
        findItem(groups, "Foundations", "Colors", skFoundation),
        findItem(groups, "Guidelines", "Accessibility", skGuideline),
        findItem(groups, "Plan a Trip", "Taps Santorini card to see details",
          skFlow)
      ]:
        let projectPreview = wanderlust.wanderlustPreviewHook(story, pfWeb)
        check projectPreview.status == ppsRendered
        check projectPreview.metadata.story.kind == story.kind
        check projectPreview.metadata.renderKind.len > 0
        check projectPreview.bodyText.len > 20
      dispose()
