## Tests for IsoNim Editor ViewModels (M0)

import std/[options, unittest, strutils, sequtils, os]
import nim_agents
import isonim/core/[signals, computation, owner]
import isonim/viewmodel
import isonim/editor/agent_harbor
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
      check vm.rightPanelWidth.val == 320
      check vm.platform.val == pfWeb
      dispose()

  test "inspector_panel_vm_persists_section_and_width_state":
    createRoot proc(dispose: proc()) =
      let vm = createEditorVM()

      vm.setRightPanelWidth(420)
      vm.switchInspectorSection(isFill)
      vm.inspector.setSectionSearch("fill")
      vm.inspector.setSectionExpanded(isFill, true)
      vm.inspector.setSectionExpanded(isLayout, false)
      vm.inspector.rememberInspectorFocus("property-background-color")

      vm.setEditMode(emEdit)
      check vm.editMode.val == emEdit
      check vm.rightPanelWidth.val == 420
      check vm.inspector.activeSection.val == isFill
      check isFill in vm.inspector.expandedSections.val
      check isLayout notin vm.inspector.expandedSections.val
      check vm.inspector.sectionSearch.val == "fill"
      check vm.inspector.focusedControlId.val == "property-background-color"

      vm.setEditMode(emComment)
      check vm.editMode.val == emComment
      check vm.rightPanelWidth.val == 420
      vm.adjustRightPanelWidth(-200)
      check vm.rightPanelWidth.val == 260
      vm.adjustRightPanelWidth(600)
      check vm.rightPanelWidth.val == 520

      vm.inspector.collapseAllSections()
      check vm.inspector.expandedSections.val.len == 0
      vm.inspector.expandRelevantSections()
      check isFill in vm.inspector.expandedSections.val
      check vm.inspector.visibleSections.val == @[isFill]

      vm.setEditMode(emView)
      check vm.editMode.val == emView
      check vm.rightPanelWidth.val == 520
      check vm.inspector.activeSection.val == isFill
      dispose()

  test "inspector_density_contract_rejects_debug_form_layouts":
    createRoot proc(dispose: proc()) =
      let vm = createEditorVM()
      let row = vm.inspector.denseRowContract.val
      check row.rejectsDebugFormLayout
      check row.maxHeightPx <= 30
      for slot in [
        icsLabel, icsScrubValue, icsUnitSelector, icsBindingIndicator,
        icsScopeIndicator, icsReset, icsMoreMenu
      ]:
        check slot in row.slots

      let large = vm.inspector.largeControlContracts.val
      check large.len == 8
      for item in large:
        check item.inlineInDenseRow == false
        check item.container in ["accordion", "popover"]
      check large.anyIt(it.kind == ilcColorPlane and it.container == "accordion")
      check large.anyIt(it.kind == ilcRawCss and it.container == "accordion")
      check large.anyIt(it.kind == ilcSourceCascade and it.container == "popover")
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
      check vm.runEditorCommand(eckComment).status == ecsSucceeded
      check vm.editMode.val == emComment
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

  test "component_dom_selection_bridge_populates_source_backed_inspector":
    createRoot proc(dispose: proc()) =
      let vm = createEditorVM()
      let metadata = StoryRenderMetadata(
        story: StoryRef(group: "Operational components", name: "Topbar",
          kind: skComponent, index: 1),
        title: "Operational components / Topbar",
        sourceFile: "apps/back-office/src/backoffice_ui/components.nim",
        sourceLine: 51,
        renderKind: "component")
      vm.selectedStory.val = StoryRef(
        group: "Operational components",
        name: "Topbar",
        kind: skComponent,
        index: 1)

      let element = previewDomElementRef(metadata,
        "header",
        "component-topbar",
        "bo-topbar",
        "",
        0,
        "rgb(255, 255, 255)",
        "rgb(15, 23, 42)",
        "16px",
        "720px",
        "64px")
      check vm.selectInspectorElement(element)
      check vm.inspector.selectedElement.val.tag == "header"
      check vm.inspector.selectedElement.val.ancestors == @["header"]
      check vm.inspector.selectedElement.val.sourceFile ==
        "apps/back-office/src/backoffice_ui/components.nim"
      check vm.inspector.selectedElement.val.properties.anyIt(
        it.name == "background-color" and it.directStyleAllowed and
          it.schemaKey == "dom.component-topbar.background-color")
      check vm.inspector.selectedElement.val.properties.anyIt(
        it.name == "padding" and it.value == "16px")

      let edit = vm.editCssProperty("background-color", "#F8FAFC", pesLocal)
      check edit.status == pesAccepted
      check edit.sourceEdit.file ==
        "apps/back-office/src/backoffice_ui/components.nim"
      check edit.sourceEdit.schemaKey == "dom.component-topbar.background-color"
      check edit.sourceEdit.planKind in {cspStructuredSchemaUpdate,
        cspInlineStyleUpdate, cspPropertyAddition}
      check vm.workspaceEditStage.val == wesDirty
      check vm.inspector.pendingSourceEdits.val.len == 1
      dispose()

  test "selection_vm_tracks_stable_element_identity":
    createRoot proc(dispose: proc()) =
      let vm = createEditorVM()
      let metadata = StoryRenderMetadata(
        story: StoryRef(group: "Operational components", name: "Topbar",
          kind: skComponent, index: 1),
        title: "Operational components / Topbar",
        sourceFile: "apps/back-office/src/backoffice_ui/components.nim",
        sourceLine: 51,
        renderKind: "component")
      let treeJson = """
[
  {"id":"src:header","parentId":"","label":"header[data-testid=component-topbar]","tag":"header","sourceKey":"components.nim:51:testid:component-topbar","schemaKey":"dom.component-topbar","domPath":"header:nth-of-type(1)","sourceFile":"apps/back-office/src/backoffice_ui/components.nim","sourceLine":51,"depth":0,"childCount":1,"expanded":true},
  {"id":"src:title","parentId":"src:header","label":"h1.bo-title","tag":"h1","sourceKey":"components.nim:52:class:bo-title","schemaKey":"dom.h1","domPath":"header:nth-of-type(1) > h1:nth-of-type(1)","sourceFile":"apps/back-office/src/backoffice_ui/components.nim","sourceLine":52,"depth":1,"childCount":0,"expanded":true}
]
"""
      let element = previewDomElementRef(metadata,
        "h1",
        "",
        "bo-title",
        "",
        "header:nth-of-type(1) > h1:nth-of-type(1)",
        "header[data-testid=component-topbar] > h1.bo-title",
        "apps/back-office/src/backoffice_ui/components.nim",
        52,
        "block",
        "static",
        "",
        "rgb(15, 23, 42)",
        "0px",
        "0px",
        "320px",
        "32px",
        "",
        "",
        "",
        "",
        "20px",
        "700",
        "24px",
        "",
        "1",
        "320",
        "32",
        "src:title",
        "components.nim:52:class:bo-title",
        "dom.h1",
        "src:header > src:title",
        treeJson)

      check vm.selectInspectorElement(element)
      vm.inspector.setSelectionTree(previewDomLayerRows(treeJson, element.id))
      check vm.inspector.selectedElement.val.id == "src:title"
      check vm.inspector.selectedElement.val.sourceKey ==
        "components.nim:52:class:bo-title"
      check vm.inspector.selectedElement.val.ancestorIds ==
        @["src:header", "src:title"]
      check vm.inspector.layers.val.anyIt(it.id == "src:title" and
        it.selected and it.schemaKey == "dom.h1")

      let edit = vm.editCssProperty("color", "#F8FAFC", pesLocal)
      check edit.status == pesAccepted
      check vm.inspector.selectedElement.val.id == "src:title"
      check vm.inspector.selectedElement.val.properties.anyIt(
        it.schemaKey == "dom.h1.color")
      vm.inspector.discardCssPropertyEdits()
      check vm.inspector.selectedElement.val.id == "src:title"
      check vm.selectParentInspectorElement()
      check vm.inspector.selectedElement.val.id == "src:header"
      check vm.inspector.selectedElement.val.ancestors ==
        @["header[data-testid=component-topbar]"]
      dispose()

  test "selection_vm_supports_tree_navigation":
    createRoot proc(dispose: proc()) =
      let vm = createEditorVM()
      vm.inspector.setSelectionTree(@[
        ElementLayerRow(id: "root", label: "main", tag: "main",
          sourceKey: "page:main", schemaKey: "dom.main",
          sourceFile: "page.nim", sourceLine: 10, depth: 0,
          childCount: 2, expanded: true),
        ElementLayerRow(id: "header", parentId: "root", label: "header",
          tag: "header", sourceKey: "page:header", schemaKey: "dom.header",
          sourceFile: "page.nim", sourceLine: 12, depth: 1,
          childCount: 1, expanded: true),
        ElementLayerRow(id: "title", parentId: "header", label: "h1",
          tag: "h1", sourceKey: "page:title", schemaKey: "dom.h1",
          sourceFile: "page.nim", sourceLine: 13, depth: 2),
        ElementLayerRow(id: "content", parentId: "root", label: "section",
          tag: "section", sourceKey: "page:content", schemaKey: "dom.section",
          sourceFile: "page.nim", sourceLine: 20, depth: 1)
      ])

      check vm.selectInspectorElementById("header")
      check vm.inspector.selectedElement.val.id == "header"
      check vm.selectChildInspectorElement()
      check vm.inspector.selectedElement.val.id == "title"
      check vm.selectParentInspectorElement()
      check vm.inspector.selectedElement.val.id == "header"
      check vm.selectNextInspectorElement()
      check vm.inspector.selectedElement.val.id == "title"
      check vm.selectPreviousInspectorElement()
      check vm.inspector.selectedElement.val.id == "header"

      vm.inspector.setLayerSearch("section")
      check vm.inspector.filteredLayers.val.len == 1
      check vm.selectNextInspectorElement()
      check vm.inspector.selectedElement.val.id == "content"
      vm.inspector.setLayerSearch("")
      vm.inspector.toggleLayerExpanded("root")
      check vm.inspector.filteredLayers.val.len == 1
      vm.clearInspectorSelection()
      check not vm.inspector.hasElement.val
      check vm.inspector.layers.val.allIt(not it.selected)
      dispose()

suite "Editor ViewModels (M27 workspace file writes)":

  type WorkspaceEditRecorder = ref object
    reloadedStories: seq[StoryRef]
    fullReloadSeen: bool
    reviewCount: int

  let writeStory = StoryRef(group: "DestinationCard", name: "Default",
    kind: skComponent, index: 0)

  proc tempWorkspaceDir(name: string): string =
    result = getTempDir() / ("isonim_editor_" & name & "_" & $getCurrentProcessId())
    if dirExists(result):
      removeDir(result)
    createDir(result)

  proc okOp(message = ""; affectedStories: seq[StoryRef] = @[];
      fullReload = false): WorkspaceOperationResult =
    WorkspaceOperationResult(ok: true, message: message,
      affectedStories: affectedStories, fullReload: fullReload)

  proc failOp(kind: WorkspaceEditDiagnosticKind; message: string;
      file = ""): WorkspaceOperationResult =
    WorkspaceOperationResult(ok: false, message: message,
      diagnostics: @[WorkspaceEditDiagnostic(kind: kind, message: message,
        file: file)])

  proc planFor(file, property, oldValue, newValue, schemaKey: string;
      planKind = cspStructuredSchemaUpdate): SourceEditPlan =
    SourceEditPlan(
      file: file,
      line: 1,
      property: property,
      oldValue: oldValue,
      newValue: newValue,
      originDetail: "schema:" & schemaKey,
      scope: pesShared,
      planKind: planKind,
      schemaKey: schemaKey,
      reversible: true,
      previewBefore: property & ": " & oldValue,
      previewAfter: property & ": " & newValue,
      formatterHook: "format-test",
      regeneratorHook: "regenerate-test",
      conflictKey: file & ":1:" & property,
      expectedOldValue: oldValue)

  proc atomicWrite(file, content: string) =
    let tmp = file & ".tmp"
    writeFile(tmp, content)
    moveFile(tmp, file)

  proc basicPatch(plan: SourceEditPlan; content: string;
      schema: WorkspaceEditableSchemaEntry): WorkspacePatchResult =
    if plan.expectedOldValue.len > 0 and plan.expectedOldValue notin content:
      return WorkspacePatchResult(ok: false,
        diagnostics: @[WorkspaceEditDiagnostic(
          kind: wedSourceConflict,
          message: "expected value missing",
          file: plan.file,
          schemaKey: schema.key,
          property: plan.property)])
    WorkspacePatchResult(ok: true, patch: WorkspaceFilePatch(
      file: plan.file,
      afterContent: content.replace(plan.expectedOldValue, plan.newValue),
      affectedStory: schema.story,
      fullReload: schema.kind in {wskSvgSymbol, wskJourneyMetadata}))

  proc adapterFor(root: string; schema: seq[WorkspaceEditableSchemaEntry];
      generatedFile = ""; failRegenerate = false;
      recorder: WorkspaceEditRecorder): WorkspaceEditAdapter =
    result = WorkspaceEditAdapter(schema: schema)
    result.readFile = proc(file: string): WorkspaceReadResult =
      try:
        WorkspaceReadResult(ok: true, content: readFile(file))
      except IOError as e:
        WorkspaceReadResult(ok: false,
          diagnostics: @[WorkspaceEditDiagnostic(
            kind: wedReadFailed, message: e.msg, file: file)])
    result.writeFile = proc(file, content: string): WorkspaceOperationResult =
      try:
        atomicWrite(file, content)
        okOp()
      except IOError as e:
        failOp(wedWriteFailed, e.msg, file)
    result.patchFile = basicPatch
    result.formatFiles = proc(files: seq[string]): WorkspaceOperationResult =
      for file in files:
        writeFile(file & ".formatted", "formatted")
      okOp()
    result.regenerate = proc(keys: seq[string]): WorkspaceOperationResult =
      if failRegenerate:
        return failOp(wedRegenerateFailed, "regeneration failed")
      if generatedFile.len > 0:
        var generated = ""
        for entry in schema:
          if fileExists(entry.file):
            generated.add entry.key & "=" & readFile(entry.file).strip() & "\n"
        atomicWrite(generatedFile, generated)
      okOp(affectedStories = @[writeStory])
    result.compile = proc(stories: seq[StoryRef]): WorkspaceOperationResult =
      check stories.len > 0
      okOp()
    result.reloadPreview = proc(stories: seq[StoryRef];
        fullReload: bool): WorkspaceOperationResult =
      recorder.reloadedStories = stories
      recorder.fullReloadSeen = fullReload
      okOp()
    result.review = proc(patches: seq[WorkspaceFilePatch]): WorkspaceReviewResult =
      inc recorder.reviewCount
      for patch in patches:
        if patch.afterContent.contains("unsafe"):
          return WorkspaceReviewResult(ok: false,
            diagnostics: @[WorkspaceEditDiagnostic(
              kind: wedReviewFailed,
              message: "unsafe generated source",
              file: patch.file)])
      WorkspaceReviewResult(ok: true)

  test "workspace_edit_adapter_applies_transactional_file_changes":
    createRoot proc(dispose: proc()) =
      let root = tempWorkspaceDir("transaction")
      defer: removeDir(root)

      let schemaFile = root / "card.schema"
      atomicWrite(schemaFile, "padding=16px\nmargin=8px")
      let recorder = WorkspaceEditRecorder()
      let schema = @[
        WorkspaceEditableSchemaEntry(
          key: "components.card.padding",
          kind: wskComponentVariant,
          file: schemaFile,
          path: "components.card.padding",
          story: writeStory,
          property: "padding"),
        WorkspaceEditableSchemaEntry(
          key: "components.card.margin",
          kind: wskComponentVariant,
          file: schemaFile,
          path: "components.card.margin",
          story: writeStory,
          property: "margin")
      ]
      let adapter = adapterFor(root, schema, recorder = recorder)
      let vm = createEditorVM(newEditorWorkspace(
        title = "M27 temp workspace",
        storyGroups = @[StoryGroup(name: "DestinationCard", kind: skComponent,
          items: @[StoryItem(name: "Default", kind: skComponent,
            group: "DestinationCard")])],
        permissions = EditorWorkspacePermissions(readSource: true,
          writeSource: true, createStory: false, createVariant: false,
          duplicate: false, delete: false),
        editAdapter = adapter,
        initialStory = some(writeStory)))

      check vm.selectInspectorElement(ElementRef(
        tag: "article",
        sourceFile: schemaFile,
        sourceLine: 1,
        properties: @[PropertyInfo(
          name: "padding",
          value: "16px",
          origin: poConstant,
          originDetail: "schema:components.card.padding",
          sourceFile: schemaFile,
          sourceLine: 1,
          schemaKey: "components.card.padding")]))

      let edit = vm.editCssProperty("padding", "24px", pesShared)
      check edit.status == pesAccepted
      check vm.workspaceEditStage.val == wesDirty
      check vm.inspector.isDirty.val

      let saved = vm.applyWorkspaceFileEdits()
      check saved.ok
      check readFile(schemaFile) == "padding=24px\nmargin=8px"
      check fileExists(schemaFile & ".formatted")
      check vm.workspaceEditStage.val == wesClean
      check not vm.inspector.isDirty.val
      check vm.workspaceEditPatches.val.len == 1
      check recorder.reloadedStories.len == 1
      check recorder.reloadedStories[0].name == "Default"
      check not recorder.fullReloadSeen

      atomicWrite(schemaFile, "padding=16px\nmargin=8px")
      vm.inspector.pendingSourceEdits.val = @[
        planFor(schemaFile, "padding", "16px", "32px",
          "components.card.padding"),
        planFor(schemaFile, "margin", "8px", "12px",
          "components.card.margin")
      ]
      let composed = vm.applyWorkspaceFileEdits()
      check composed.ok
      check composed.patches.len == 2
      check readFile(schemaFile) == "padding=32px\nmargin=12px"
      check vm.workspaceEditPatches.val.len == 2

      atomicWrite(schemaFile, "padding=20px\nmargin=8px")
      vm.inspector.pendingSourceEdits.val = @[
        planFor(schemaFile, "padding", "16px", "28px",
          "components.card.padding")
      ]
      let conflicted = vm.applyWorkspaceFileEdits()
      check not conflicted.ok
      check conflicted.diagnostics.anyIt(it.kind == wedSourceConflict)
      check readFile(schemaFile) == "padding=20px\nmargin=8px"
      check vm.inspector.pendingSourceEdits.val.len == 1

      atomicWrite(schemaFile, "padding=16px\nmargin=8px")
      vm.inspector.pendingSourceEdits.val = @[
        planFor(schemaFile, "padding", "16px", "32px",
          "components.card.padding")
      ]
      let failingAdapter = adapterFor(root, schema, failRegenerate = true,
        recorder = recorder)
      vm.workspaceEditAdapter = failingAdapter
      let rolledBack = vm.applyWorkspaceFileEdits()
      check not rolledBack.ok
      check rolledBack.diagnostics.anyIt(it.kind == wedRegenerateFailed)
      check readFile(schemaFile) == "padding=16px\nmargin=8px"
      check vm.inspector.pendingSourceEdits.val.len == 1
      dispose()

  test "workspace_schema_edits_roundtrip_through_generated_views":
    createRoot proc(dispose: proc()) =
      let root = tempWorkspaceDir("roundtrip")
      defer: removeDir(root)

      let tokenFile = root / "tokens.schema"
      let variantFile = root / "variants.schema"
      let fixtureFile = root / "fixtures.schema"
      let svgFile = root / "symbols.schema"
      let pageFile = root / "pages.schema"
      let journeyFile = root / "journeys.schema"
      let generatedFile = root / "generated_views.txt"
      atomicWrite(tokenFile, "surface=#ffffff")
      atomicWrite(variantFile, "compact=grid")
      atomicWrite(fixtureFile, "title=Paris")
      atomicWrite(svgFile, "logo=<path />")
      atomicWrite(pageFile, "hero=Plan trip")
      atomicWrite(journeyFile, "step=Search")
      atomicWrite(generatedFile, "")

      let schema = @[
        WorkspaceEditableSchemaEntry(key: "tokens.surface", kind: wskToken,
          file: tokenFile, path: "tokens.surface", story: writeStory,
          property: "surface"),
        WorkspaceEditableSchemaEntry(key: "components.card.variants.compact.display",
          kind: wskComponentVariant, file: variantFile,
          path: "components.card.variants.compact.display", story: writeStory,
          property: "display"),
        WorkspaceEditableSchemaEntry(key: "fixtures.destination.featured.title",
          kind: wskStoryFixture, file: fixtureFile,
          path: "fixtures.destination.featured.title", story: writeStory,
          property: "title"),
        WorkspaceEditableSchemaEntry(key: "symbols.logo.path", kind: wskSvgSymbol,
          file: svgFile, path: "symbols.logo.path", story: writeStory,
          property: "path"),
        WorkspaceEditableSchemaEntry(key: "pages.home.hero.title",
          kind: wskPageMetadata, file: pageFile, path: "pages.home.hero.title",
          story: writeStory, property: "hero"),
        WorkspaceEditableSchemaEntry(key: "journeys.onboarding.step.search",
          kind: wskJourneyMetadata, file: journeyFile,
          path: "journeys.onboarding.step.search", story: writeStory,
          property: "step")
      ]

      let recorder = WorkspaceEditRecorder()
      let adapter = adapterFor(root, schema, generatedFile = generatedFile,
        recorder = recorder)
      let vm = createEditorVM(newEditorWorkspace(
        title = "M27 generated workspace",
        storyGroups = @[StoryGroup(name: "DestinationCard", kind: skComponent,
          items: @[StoryItem(name: "Default", kind: skComponent,
            group: "DestinationCard")])],
        previewHook = proc(story: StoryRef; platform: Platform): ProjectPreview =
          ProjectPreview(status: ppsRendered, story: story,
            title: "Generated",
            bodyText: readFile(generatedFile)),
        permissions = EditorWorkspacePermissions(readSource: true,
          writeSource: true, createStory: false, createVariant: false,
          duplicate: false, delete: false),
        editAdapter = adapter,
        initialStory = some(writeStory)))

      vm.inspector.pendingSourceEdits.val = @[
        planFor(tokenFile, "surface", "#ffffff", "#f8fafc", "tokens.surface"),
        planFor(variantFile, "display", "grid", "flex",
          "components.card.variants.compact.display"),
        planFor(fixtureFile, "title", "Paris", "Sofia",
          "fixtures.destination.featured.title"),
        planFor(svgFile, "path", "<path />", "<path d=\"M0 0h1\" />",
          "symbols.logo.path"),
        planFor(pageFile, "hero", "Plan trip", "Plan better trips",
          "pages.home.hero.title"),
        planFor(journeyFile, "step", "Search", "Compare",
          "journeys.onboarding.step.search")
      ]
      vm.workspaceEditStage.val = wesDirty

      let saved = vm.applyWorkspaceFileEdits()
      check saved.ok
      let generated = readFile(generatedFile)
      check generated.contains("tokens.surface=surface=#f8fafc")
      check generated.contains("components.card.variants.compact.display=compact=flex")
      check generated.contains("fixtures.destination.featured.title=title=Sofia")
      check generated.contains("symbols.logo.path=logo=<path d=\"M0 0h1\" />")
      check generated.contains("pages.home.hero.title=hero=Plan better trips")
      check generated.contains("journeys.onboarding.step.search=step=Compare")
      check vm.workspaceEditAffectedStories.val.len == 1
      check vm.workspaceEditFullReload.val

      vm.changePlatform(pfIOS)
      check vm.preview.current.val.bodyText.contains("title=Sofia")
      check vm.preview.current.val.bodyText.contains("step=Compare")
      check recorder.reloadedStories.len == 1
      check recorder.fullReloadSeen
      dispose()

  test "vector_editor_library_spike_selects_mature_backend":
    let candidates = vectorLibrarySpike()
    let selected = candidates.filterIt(it.selected)
    check selected.anyIt(it.name == "Fabric.js" and it.license == "MIT")
    check selected.anyIt(it.name == "Paper.js" and it.license == "MIT")
    check selected.anyIt(it.name == "SVGO" and it.license == "MIT")
    let adapter = selectedVectorAdapter()
    check adapter.backend == vbFabric
    check adapter.usesThirdPartyInteraction
    check adapter.hasCapability(vacSelection)
    check adapter.hasCapability(vacHitTesting)
    check adapter.hasCapability(vacTransformControls)
    check adapter.hasCapability(vacGrouping)
    check adapter.hasCapability(vacSvgImport)
    check adapter.hasCapability(vacSvgExport)
    let pathBackend = selectedVectorPathBackend()
    check pathBackend.libraryName == "Paper.js"
    check pathBackend.browserGlobal == "paper"
    check vpboUnite in pathBackend.operations
    check vpboSubtract in pathBackend.operations
    check vpboIntersect in pathBackend.operations
    check vpboExclude in pathBackend.operations
    check vpboMoveSegment in pathBackend.operations
    check pathBackend.sourceBacked
    check adapter.unsupportedAdvancedOperations.len > 0

  test "vector_editor_adapter_contract_is_library_backed":
    createRoot proc(dispose: proc()) =
      let vm = createEditorVM()
      check vm.vectorEditor.adapter.val.libraryName == "Fabric.js"
      check vm.vectorEditor.adapter.val.browserGlobal == "fabric"
      check vm.vectorEditor.adapter.val.adapterModule ==
        "isonim/editor/browser_vector_adapter"
      check vm.vectorEditor.adapter.val.usesThirdPartyInteraction
      check vm.vectorEditor.adapter.val.hasCapability(vacDrawingTools)
      dispose()

  test "vector_editor_model_supports_shapes_paths_layers_and_symbols":
    createRoot proc(dispose: proc()) =
      let vm = createEditorVM()
      vm.vectorEditor.symbols.val = @[
        VectorSymbol(name: "Logo", category: "Icons",
          svgContent: "<path d=\"M0 0h24v24H0z\" />",
          tags: @["brand"], width: 24, height: 24)
      ]
      check vm.selectVectorSymbol(0)
      let doc = vm.vectorEditor.document.val
      check doc.name == "Logo"
      check doc.layers.len == 1
      check doc.objects.len == 1
      check doc.objects[0].kind == vskPath
      check doc.symbols.len == 1
      check doc.a11y.title == "Logo"
      check exportVectorDocumentSvg(doc).contains("<svg")

      var edited = doc
      edited.objects.add VectorObject(id: "rect-1", name: "Rect",
        kind: vskRect, layerId: "base", x: 2, y: 2, width: 10, height: 8,
        fill: "none", stroke: "currentColor", strokeWidth: 1,
        source: doc.source, a11y: doc.a11y)
      edited.layers[0].objectIds.add "rect-1"
      edited.selectedIds = @["path-1", "rect-1"]
      vm.vectorEditor.document.val = edited
      check vm.groupVectorSelection().ok
      check vm.vectorEditor.document.val.objects.anyIt(it.kind == vskGroup)
      check vm.reuseVectorSymbol("logo").ok
      check vm.vectorEditor.document.val.objects.anyIt(it.kind == vskSymbolUse)
      check validateVectorAccessibility(vm.vectorEditor.document.val).len == 0
      dispose()

  test "vector_editor_operations_are_undoable_and_source_backed":
    createRoot proc(dispose: proc()) =
      let root = tempWorkspaceDir("vector")
      defer: removeDir(root)

      let svgFile = root / "symbols.schema"
      atomicWrite(svgFile, "logo=<svg><path id=\"path-1\" /></svg>")
      let recorder = WorkspaceEditRecorder()
      let schema = @[
        WorkspaceEditableSchemaEntry(key: "symbols.logo.svg",
          kind: wskSvgSymbol, file: svgFile, path: "symbols.logo.svg",
          story: writeStory, property: "svgContent")
      ]
      let vm = createEditorVM(newEditorWorkspace(
        title = "M29 vector workspace",
        storyGroups = @[],
        vectorSymbols = @[
          VectorSymbol(name: "Logo", category: "Icons",
            svgContent: "<path id=\"path-1\" d=\"M0 0h24v24H0z\" />",
            width: 24, height: 24)
        ],
        permissions = EditorWorkspacePermissions(readSource: true,
          writeSource: true),
        editAdapter = adapterFor(root, schema, recorder = recorder)))
      check vm.selectVectorSymbol(0)
      atomicWrite(svgFile,
        vm.vectorEditor.document.val.exportVectorDocumentSvg.optimizeVectorSvg)
      check vm.selectVectorObjects(@["path-1"])
      let duplicated = vm.duplicateVectorSelection()
      check duplicated.ok
      check duplicated.sourceEdit.schemaKey == "symbols.logo.svg"
      check duplicated.sourceEdit.formatterHook == "svgo"
      check vm.vectorEditor.undoStack.val.len == 1
      check vm.inspector.pendingSourceEdits.val.len == 1
      check vm.undoVectorEdit()
      check vm.redoVectorEdit()

      let saved = vm.applyWorkspaceFileEdits()
      check saved.ok
      check readFile(svgFile).contains("<svg")
      check recorder.fullReloadSeen
      dispose()

  test "vector_editor_import_properties_shapes_and_viewbox_are_source_backed":
    createRoot proc(dispose: proc()) =
      let root = tempWorkspaceDir("vector-properties")
      defer: removeDir(root)

      let svgFile = root / "symbols.schema"
      atomicWrite(svgFile,
        "badge=<svg viewBox=\"0 0 64 64\"><rect id=\"badge-bg\" x=\"4\" y=\"4\" width=\"56\" height=\"40\" fill=\"#60A5FA\" stroke=\"#1D4ED8\" stroke-width=\"2\" /></svg>")
      let recorder = WorkspaceEditRecorder()
      let schema = @[
        WorkspaceEditableSchemaEntry(key: "symbols.badge.svg",
          kind: wskSvgSymbol, file: svgFile, path: "symbols.badge.svg",
          story: writeStory, property: "svgContent")
      ]
      let vm = createEditorVM(newEditorWorkspace(
        title = "M29 vector import workspace",
        storyGroups = @[],
        vectorSymbols = @[
          VectorSymbol(name: "Badge", category: "Icons",
            svgContent: "<svg viewBox=\"0 0 64 64\"><rect id=\"badge-bg\" x=\"4\" y=\"4\" width=\"56\" height=\"40\" fill=\"#60A5FA\" stroke=\"#1D4ED8\" stroke-width=\"2\" stroke-dasharray=\"4 2\" stroke-linecap=\"round\" stroke-linejoin=\"bevel\" /></svg>",
            width: 64, height: 64)
        ],
        permissions = EditorWorkspacePermissions(readSource: true,
          writeSource: true),
        editAdapter = adapterFor(root, schema, recorder = recorder)))

      check vm.selectVectorSymbol(0)
      atomicWrite(svgFile,
        vm.vectorEditor.document.val.exportVectorDocumentSvg.optimizeVectorSvg)
      check vm.vectorEditor.document.val.viewBox == "0 0 64 64"
      check vm.vectorEditor.document.val.objects.len == 1
      check vm.vectorEditor.document.val.objects[0].id == "badge-bg"
      check vm.vectorEditor.document.val.objects[0].dashArray == "4 2"
      check vm.vectorEditor.document.val.objects[0].strokeCap == scRound
      check vm.vectorEditor.document.val.objects[0].strokeJoin == sjBevel

      check vm.setVectorObjectProperty(VectorPropertyEditRequest(
        objectId: "badge-bg", kind: vpkFill, value: "#EF4444")).ok
      check vm.setVectorObjectProperty(VectorPropertyEditRequest(
        objectId: "badge-bg", kind: vpkStroke, value: "#22C55E")).ok
      check vm.setVectorObjectProperty(VectorPropertyEditRequest(
        objectId: "badge-bg", kind: vpkDashArray, value: "8 4")).ok
      check vm.setVectorObjectProperty(VectorPropertyEditRequest(
        objectId: "badge-bg", kind: vpkStrokeCap, value: "square")).ok
      check vm.setVectorObjectProperty(VectorPropertyEditRequest(
        objectId: "badge-bg", kind: vpkStrokeJoin, value: "round")).ok
      check vm.setVectorObjectProperty(VectorPropertyEditRequest(
        objectId: "badge-bg", kind: vpkOpacity, value: "0.5")).ok
      check vm.setVectorObjectProperty(VectorPropertyEditRequest(
        objectId: "badge-bg", kind: vpkGradient, value: "badge-gradient")).ok
      check vm.setVectorObjectProperty(VectorPropertyEditRequest(
        objectId: "badge-bg", kind: vpkBlendMode, value: "multiply")).ok
      check vm.setVectorObjectProperty(VectorPropertyEditRequest(
        objectId: "badge-bg", kind: vpkTransform, value: "15")).ok
      check vm.setVectorDocumentViewBox("0 0 128 128").ok
      check vm.addVectorPolygon(6).ok
      check vm.addVectorStar(5).ok

      let svg = vm.vectorEditor.document.val.exportVectorDocumentSvg
      check svg.contains("viewBox=\"0 0 128 128\"")
      check svg.contains("stroke=\"#22C55E\"")
      check svg.contains("stroke-dasharray=\"8 4\"")
      check svg.contains("stroke-linecap=\"square\"")
      check svg.contains("stroke-linejoin=\"round\"")
      check svg.contains("opacity=\"0.5\"")
      check svg.contains("<linearGradient id=\"badge-gradient\"")
      check svg.contains("fill=\"url(#badge-gradient)\"")
      check svg.contains("mix-blend-mode:multiply")
      check svg.contains("rotate(15")
      check svg.contains("polygon-")
      check svg.contains("star-")
      check vm.inspector.pendingSourceEdits.val.len >= 9
      let pendingBeforeUndo = vm.inspector.pendingSourceEdits.val.len
      check vm.undoVectorEdit()
      check vm.vectorEditor.document.val.objects.allIt(it.id != "star-3")
      check vm.inspector.pendingSourceEdits.val.len == pendingBeforeUndo - 1
      check vm.workspaceEditStage.val == wesDirty
      check vm.redoVectorEdit()
      check vm.vectorEditor.document.val.objects.anyIt(it.id == "star-3")
      check vm.inspector.pendingSourceEdits.val.len == pendingBeforeUndo
      let saved = vm.applyWorkspaceFileEdits()
      check saved.ok
      let savedSvg = readFile(svgFile)
      check savedSvg.contains("viewBox=\"0 0 128 128\"")
      check savedSvg.contains("stroke=\"#22C55E\"")
      check savedSvg.contains("stroke-linecap=\"square\"")
      check savedSvg.contains("linearGradient")
      check savedSvg.contains("mix-blend-mode:multiply")
      check savedSvg.contains("star-3")
      check vm.inspector.pendingSourceEdits.val.len == 0
      check vm.vectorEditor.undoStack.val.len == 0
      check not vm.vectorEditor.isDirty.val
      check vm.workspaceEditStage.val == wesClean
      check recorder.fullReloadSeen
      dispose()

  test "vector_editor_browser_bridge_commits_fabric_export_to_workspace_save":
    createRoot proc(dispose: proc()) =
      let root = tempWorkspaceDir("vector-browser-bridge")
      defer: removeDir(root)

      let svgFile = root / "symbols.schema"
      atomicWrite(svgFile,
        "<svg xmlns=\"http://www.w3.org/2000/svg\" viewBox=\"0 0 24 24\"><path id=\"path-1\" d=\"M0 0h24v24H0z\" /></svg>")
      let recorder = WorkspaceEditRecorder()
      let schema = @[
        WorkspaceEditableSchemaEntry(key: "symbols.logo.svg",
          kind: wskSvgSymbol, file: svgFile, path: "symbols.logo.svg",
          story: writeStory, property: "svgContent")
      ]
      let adapter = adapterFor(root, schema, recorder = recorder)
      adapter.patchFile = proc(plan: SourceEditPlan; content: string;
          schema: WorkspaceEditableSchemaEntry): WorkspacePatchResult =
        WorkspacePatchResult(ok: true, patch: WorkspaceFilePatch(
          file: schema.file,
          beforeContent: content,
          afterContent: plan.newValue,
          affectedStory: schema.story,
          fullReload: true))
      let vm = createEditorVM(newEditorWorkspace(
        title = "M29 browser bridge workspace",
        storyGroups = @[],
        vectorSymbols = @[
          VectorSymbol(name: "Logo", category: "Icons",
            svgContent: "<svg xmlns=\"http://www.w3.org/2000/svg\" viewBox=\"0 0 24 24\"><path id=\"path-1\" d=\"M0 0h24v24H0z\" /></svg>",
            width: 24, height: 24)
        ],
        permissions = EditorWorkspacePermissions(readSource: true,
          writeSource: true),
        editAdapter = adapter))

      check vm.selectVectorSymbol(0)
      let exported =
        "<svg xmlns=\"http://www.w3.org/2000/svg\" viewBox=\"0 0 24 24\"><rect id=\"fabric-rect\" x=\"2\" y=\"3\" width=\"12\" height=\"9\" fill=\"#EF4444\" stroke=\"#22C55E\" /></svg>"
      let bridged = vm.commitBrowserVectorSvg(exported)
      check bridged.ok
      check bridged.sourceEdit.schemaKey == "symbols.logo.svg"
      check bridged.sourceEdit.property == "svgContent"
      check bridged.sourceEdit.expectedOldValue == ""
      check bridged.sourceEdit.newValue.contains("fabric-rect")
      check vm.inspector.pendingSourceEdits.val.len == 1
      check vm.vectorEditor.undoStack.val.len == 1
      check vm.workspaceEditStage.val == wesDirty
      check vm.commandAvailable(eckSave)

      let saved = vm.runEditorCommand(eckSave)
      check saved.status == ecsSucceeded
      check readFile(svgFile).contains("fabric-rect")
      check readFile(svgFile).contains("#EF4444")
      check vm.inspector.pendingSourceEdits.val.len == 0
      check vm.vectorEditor.undoStack.val.len == 0
      check vm.workspaceEditStage.val == wesClean
      check recorder.fullReloadSeen
      dispose()

  test "vector_editor_paper_path_operations_are_source_backed":
    createRoot proc(dispose: proc()) =
      let root = tempWorkspaceDir("vector-paper")
      defer: removeDir(root)

      let svgFile = root / "symbols.schema"
      atomicWrite(svgFile,
        "<svg xmlns=\"http://www.w3.org/2000/svg\" viewBox=\"0 0 64 64\"><path id=\"left\" d=\"M4 4h32v32H4z\" /></svg>")
      let recorder = WorkspaceEditRecorder()
      let schema = @[
        WorkspaceEditableSchemaEntry(key: "symbols.logo.svg",
          kind: wskSvgSymbol, file: svgFile, path: "symbols.logo.svg",
          story: writeStory, property: "svgContent")
      ]
      let adapter = adapterFor(root, schema, recorder = recorder)
      adapter.patchFile = proc(plan: SourceEditPlan; content: string;
          schema: WorkspaceEditableSchemaEntry): WorkspacePatchResult =
        WorkspacePatchResult(ok: true, patch: WorkspaceFilePatch(
          file: schema.file,
          beforeContent: content,
          afterContent: plan.newValue,
          affectedStory: schema.story,
          fullReload: true))
      let vm = createEditorVM(newEditorWorkspace(
        title = "M29 Paper path workspace",
        storyGroups = @[],
        vectorSymbols = @[
          VectorSymbol(name: "Logo", category: "Icons",
            svgContent: "<svg xmlns=\"http://www.w3.org/2000/svg\" viewBox=\"0 0 64 64\"><path id=\"left\" d=\"M4 4h32v32H4z\" /></svg>",
            width: 64, height: 64)
        ],
        permissions = EditorWorkspacePermissions(readSource: true,
          writeSource: true),
        editAdapter = adapter))

      check vm.selectVectorSymbol(0)
      let unionSvg =
        "<svg xmlns=\"http://www.w3.org/2000/svg\" viewBox=\"0 0 64 64\"><path id=\"paper-unite\" d=\"M4 4h48v32H4z\" fill=\"#EC4899\" /></svg>"
      let result = vm.commitSupplementalVectorPathSvg("unite", unionSvg)
      check result.ok
      check result.operation == vokBooleanPath
      check result.sourceEdit.schemaKey == "symbols.logo.svg"
      check result.sourceEdit.formatterHook == "svgo"
      check result.sourceEdit.newValue.contains("paper-unite")
      check vm.inspector.pendingSourceEdits.val.len == 1
      check vm.commandAvailable(eckSave)

      let movedSvg =
        "<svg xmlns=\"http://www.w3.org/2000/svg\" viewBox=\"0 0 64 64\"><path id=\"paper-moved-segment\" d=\"M4 48 L32 12 L60 48\" fill=\"none\" stroke=\"#A78BFA\" /></svg>"
      let moved = vm.commitSupplementalPathSegmentMoveSvg(movedSvg)
      check moved.ok
      check moved.operation == vokMovePathSegment
      check vm.inspector.pendingSourceEdits.val.len == 2
      check vm.undoVectorEdit()
      check vm.vectorEditor.document.val.symbols[0].svgContent.contains(
        "paper-unite")
      check vm.redoVectorEdit()
      check vm.vectorEditor.document.val.symbols[0].svgContent.contains(
        "paper-moved-segment")

      let saved = vm.runEditorCommand(eckSave)
      check saved.status == ecsSucceeded
      check readFile(svgFile).contains("paper-moved-segment")
      check vm.inspector.pendingSourceEdits.val.len == 0
      check vm.workspaceEditStage.val == wesClean
      dispose()

  test "vector_editor_unbacked_freeform_path_editing_is_diagnosed":
    createRoot proc(dispose: proc()) =
      let vm = createEditorVM()
      let adapter = vm.vectorEditor.adapter.val
      let pathBackend = selectedVectorPathBackend()
      check vpboUnite in pathBackend.operations
      check vpboMoveSegment in pathBackend.operations
      check not adapter.hasCapability(vacPathEditing)
      check adapter.unsupportedAdvancedOperations.anyIt(
        it.contains("Freeform bezier node editing"))
      let result = vm.unsupportedVectorOperation("Freeform bezier editing")
      check not result.ok
      check result.diagnostics.len == 1
      check result.diagnostics[0].kind == vdkUnsupportedOperation
      check result.diagnostics[0].message.contains("mature supplemental path library")
      check vm.vectorEditor.diagnostics.val[0].kind == vdkUnsupportedOperation
      dispose()

  test "foundation_token_edit_updates_dependent_properties":
    createRoot proc(dispose: proc()) =
      let root = tempWorkspaceDir("foundation")
      defer: removeDir(root)

      let tokenFile = root / "tokens.schema"
      atomicWrite(tokenFile, "surface.card=#ffffff\ntext.default=#111827")
      let story = writeStory
      let schema = @[
        WorkspaceEditableSchemaEntry(key: "tokens.surface.card",
          kind: wskToken, file: tokenFile, path: "tokens.surface.card",
          story: story, property: "surface.card"),
        WorkspaceEditableSchemaEntry(key: "tokens.text.default",
          kind: wskToken, file: tokenFile, path: "tokens.text.default",
          story: story, property: "text.default")
      ]
      let recorder = WorkspaceEditRecorder()
      let adapter = adapterFor(root, schema, recorder = recorder)
      let vm = createEditorVM(newEditorWorkspace(
        title = "M28 foundation workspace",
        storyGroups = @[StoryGroup(name: "Foundations", kind: skFoundation,
          items: @[StoryItem(name: "Colors", kind: skFoundation,
            group: "Foundations")])],
        foundationTokens = @[
          FoundationTokenEntry(key: "surface.card", kind: ftkSemanticColor,
            value: "#ffffff", sourceFile: tokenFile, sourceLine: 1,
            schemaKey: "tokens.surface.card", property: "surface.card",
            affectedStories: @[story]),
          FoundationTokenEntry(key: "text.default",
            kind: ftkAccessibilityConstraint, value: "#111827",
            foreground: "#111827", background: "#ffffff", minContrast: 4.5,
            sourceFile: tokenFile, sourceLine: 2,
            schemaKey: "tokens.text.default", property: "text.default",
            affectedStories: @[story])
        ],
        permissions = EditorWorkspacePermissions(readSource: true,
          writeSource: true, createStory: false, createVariant: false,
          duplicate: false, delete: false),
        editAdapter = adapter,
        initialStory = some(StoryRef(group: "Foundations", name: "Colors",
          kind: skFoundation, index: 0))))

      check vm.selectInspectorElement(ElementRef(
        tag: "article",
        sourceFile: tokenFile,
        sourceLine: 1,
        properties: @[PropertyInfo(name: "background",
          value: "token(surface.card)", origin: poThemeToken,
          originDetail: "themeColor(\"surface.card\")",
          sourceFile: tokenFile, sourceLine: 1,
          schemaKey: "tokens.surface.card", tokenName: "surface.card",
          sharedCount: 3)]))

      let edit = vm.editFoundationToken("surface.card", "#f8fafc")
      check edit.status == pesAccepted
      check edit.sourceEdit.planKind == cspTokenUpdate
      check edit.sourceEdit.schemaKey == "tokens.surface.card"
      check edit.impacts.len == 1
      check edit.impacts[0].affectedProperties.len == 1
      check edit.impacts[0].affectedStories.len == 1
      check vm.foundations.impacts.val[0].message.contains("surface.card")
      check vm.inspector.pendingSourceEdits.val.len == 1
      check vm.workspaceEditStage.val == wesDirty

      let saved = vm.applyWorkspaceFileEdits()
      check saved.ok
      check readFile(tokenFile).contains("surface.card=#f8fafc")
      check not vm.inspector.isDirty.val
      check recorder.reloadedStories.len == 1
      check not recorder.fullReloadSeen

      let contrast = vm.editFoundationToken("text.default", "#ffffff")
      check contrast.status == pesRejected
      check contrast.diagnostics.anyIt(it.kind == fedContrastViolation)

      vm.foundations.tokens.val = @[
        FoundationTokenEntry(key: "semantic.a", kind: ftkSemanticColor,
          value: "token(semantic.b)", aliasOf: "semantic.b",
          sourceFile: tokenFile, sourceLine: 1,
          schemaKey: "tokens.semantic.a", property: "semantic.a"),
        FoundationTokenEntry(key: "semantic.b", kind: ftkSemanticColor,
          value: "token(semantic.a)", aliasOf: "semantic.a",
          sourceFile: tokenFile, sourceLine: 2,
          schemaKey: "tokens.semantic.b", property: "semantic.b")
      ]
      let cycle = vm.editFoundationToken("semantic.a", "token(semantic.b)")
      check cycle.status == pesRejected
      check cycle.diagnostics.anyIt(it.kind == fedAliasCycle)
      dispose()

  test "component_variant_editor_updates_story_fixtures":
    createRoot proc(dispose: proc()) =
      let root = tempWorkspaceDir("variant")
      defer: removeDir(root)

      let fixtureFile = root / "fixtures.schema"
      let metadataFile = root / "stories.schema"
      atomicWrite(fixtureFile, "title=Paris\nstate=featured")
      atomicWrite(metadataFile, "story=Default")
      let story = writeStory
      let schema = @[
        WorkspaceEditableSchemaEntry(key: "fixtures.destination.title",
          kind: wskStoryFixture, file: fixtureFile,
          path: "fixtures.destination.title", story: story, property: "title"),
        WorkspaceEditableSchemaEntry(key: "stories.destination.default.name",
          kind: wskComponentVariant, file: metadataFile,
          path: "stories.destination.default.name", story: story,
          property: "story")
      ]
      let recorder = WorkspaceEditRecorder()
      let adapter = adapterFor(root, schema, recorder = recorder)
      let vm = createEditorVM(newEditorWorkspace(
        title = "M28 variant workspace",
        storyGroups = @[StoryGroup(name: "DestinationCard",
          kind: skComponent, items: @[StoryItem(name: "Default",
            kind: skComponent, group: "DestinationCard")])],
        componentVariants = @[ComponentVariantDefinition(
          component: "DestinationCard",
          variantKey: "default",
          story: story,
          fixtureName: "destination.featured",
          metadataName: "Default",
          fields: @[
            ComponentVariantField(name: "title",
              kind: cvfkSampleData, value: "Paris", sourceFile: fixtureFile,
              sourceLine: 1, schemaKey: "fixtures.destination.title"),
            ComponentVariantField(name: "story",
              kind: cvfkStoryMetadata, value: "Default",
              sourceFile: metadataFile, sourceLine: 1,
              schemaKey: "stories.destination.default.name")
          ],
          usageExamples: @[UsageExample(description: "Use for featured destinations.",
            isDo: true)])],
        permissions = EditorWorkspacePermissions(readSource: true,
          writeSource: true, createStory: false, createVariant: false,
          duplicate: false, delete: false),
        editAdapter = adapter,
        initialStory = some(story)))

      let edit = vm.editComponentVariantField("DestinationCard", "default",
        "title", "Sofia")
      check edit.status == pesAccepted
      check edit.sourceEdit.schemaKey == "fixtures.destination.title"
      check edit.affectedStory.name == "Default"
      check vm.variants.variants.val[0].fields[0].value == "Sofia"
      check vm.variants.selectedVariant.val == 0
      check vm.inspector.pendingSourceEdits.val.len == 1

      let saved = vm.applyWorkspaceFileEdits()
      check saved.ok
      check readFile(fixtureFile).contains("title=Sofia")
      check vm.workspaceEditAffectedStories.val.len == 1
      check not vm.workspaceEditFullReload.val

      vm.variants.variants.val = @[ComponentVariantDefinition(
        component: "DestinationCard",
        variantKey: "broken",
        story: story,
        fixtureName: "",
        fields: @[ComponentVariantField(name: "title",
          kind: cvfkSampleData, value: "Paris", sourceFile: fixtureFile,
          sourceLine: 1, schemaKey: "fixtures.destination.title")])]
      let missingFixture = vm.editComponentVariantField("DestinationCard",
        "broken", "title", "Sofia")
      check missingFixture.status == pesRejected
      check missingFixture.diagnostics.anyIt(
        it.kind == cvdMissingVariantFixture)

      vm.variants.variants.val = @[ComponentVariantDefinition(
        component: "DestinationCard",
        variantKey: "metadata-mismatch",
        story: story,
        fixtureName: "destination.featured",
        metadataName: "Other Story",
        fields: @[ComponentVariantField(name: "story",
          kind: cvfkStoryMetadata, value: "Default", sourceFile: metadataFile,
          sourceLine: 1, schemaKey: "stories.destination.default.name")])]
      let mismatch = vm.editComponentVariantField("DestinationCard",
        "metadata-mismatch", "story", "Default")
      check mismatch.status == pesRejected
      check mismatch.diagnostics.anyIt(
        it.kind == cvdInconsistentStoryMetadata)
      dispose()

  test "design_schema_maps_dom_properties_to_source_ownership":
    createRoot proc(dispose: proc()) =
      let root = tempWorkspaceDir("design-schema-map")
      defer: removeDir(root)

      func span(file: string; line: int; column = 1): SourceSpan =
        SourceSpan(file: file, line: line, column: column,
          endLine: line, endColumn: column + 12)

      let tokenFile = root / "design/tokens.schema"
      let componentFile = root / "design/components.schema"
      let cssFile = root / "components/Card.module.css"
      let fixtureFile = root / "stories/card.fixtures.schema"
      let viewFile = root / "generated/card_view.nim"
      createDir(root / "design")
      createDir(root / "components")
      createDir(root / "stories")
      createDir(root / "generated")
      atomicWrite(tokenFile, "surface.card=#ffffff")
      atomicWrite(componentFile, "card.padding=16px")
      atomicWrite(cssFile, ".card { border-radius: 8px; }")
      atomicWrite(fixtureFile, "title=Sofia")
      atomicWrite(viewFile, "ui.div(style = \"box-shadow: 0 1px 2px #000\")")

      let story = writeStory
      let schema = DesignSystemSchema(
        schemaVersion: 1,
        projectId: "metacraft-web-backoffice",
        ownerPackage: "metacraft-web",
        frameworkContract: "isonim-editor-design-schema-v1",
        nodes: @[
          DesignSchemaNode(key: "foundation.color.blue.600",
            kind: dsnFoundation, name: "Blue 600", property: "color",
            value: "#2563eb", sourceSpan: span(tokenFile, 1)),
          DesignSchemaNode(key: "semantic.surface.card",
            kind: dsnSemanticToken, name: "Card surface",
            property: "background", value: "#ffffff",
            sourceSpan: span(tokenFile, 2), stories: @[story],
            components: @["DestinationCard"], usageCount: 1),
          DesignSchemaNode(key: "components.card.padding",
            kind: dsnComponentToken, name: "Card padding",
            component: "DestinationCard", property: "padding",
            value: "16px", sourceSpan: span(componentFile, 4)),
          DesignSchemaNode(key: "components.card.variant.compact",
            kind: dsnComponentVariant, component: "DestinationCard",
            property: "variant", value: "compact",
            sourceSpan: span(componentFile, 8), stories: @[story]),
          DesignSchemaNode(key: "components.card.state.hover",
            kind: dsnComponentState, component: "DestinationCard",
            property: "state", value: "hover",
            sourceSpan: span(componentFile, 12)),
          DesignSchemaNode(key: "modes.density.compact",
            kind: dsnDensityMode, name: "Compact density",
            property: "density", value: "compact",
            sourceSpan: span(tokenFile, 20)),
          DesignSchemaNode(key: "modes.breakpoint.md",
            kind: dsnResponsiveMode, name: "Medium breakpoint",
            property: "breakpoint", value: "768px",
            sourceSpan: span(tokenFile, 24)),
          DesignSchemaNode(key: "classes.card",
            kind: dsnClassDefinition, name: "Card class",
            property: "border-radius", value: "8px",
            sourceSpan: span(cssFile, 1)),
          DesignSchemaNode(key: "styles.card.shadow",
            kind: dsnStyleDefinition, name: "Card shadow",
            property: "box-shadow", value: "0 1px 2px #000",
            sourceSpan: span(viewFile, 1)),
          DesignSchemaNode(key: "fixtures.card.title",
            kind: dsnStoryFixture, name: "Card title",
            property: "title", value: "Sofia",
            sourceSpan: span(fixtureFile, 1), stories: @[story])
        ],
        sourceOwnership: @[
          DesignSourceOwnership(elementSourceKey: "card.root",
            property: "background", schemaKey: "semantic.surface.card",
            nodeKey: "semantic.surface.card", sourceSpan: span(tokenFile, 2),
            generatedViewFile: viewFile, generatedViewLine: 3),
          DesignSourceOwnership(elementSourceKey: "card.root",
            property: "padding", schemaKey: "components.card.padding",
            nodeKey: "components.card.padding",
            sourceSpan: span(componentFile, 4),
            generatedViewFile: viewFile, generatedViewLine: 4,
            tailwindUtilities: @["p-4", "md:p-6"]),
          DesignSourceOwnership(elementSourceKey: "card.root",
            property: "border-radius", schemaKey: "classes.card",
            nodeKey: "classes.card", sourceSpan: span(cssFile, 1),
            cssModuleFile: cssFile, cssModuleClass: "card"),
          DesignSourceOwnership(elementSourceKey: "card.root",
            property: "data-variant",
            schemaKey: "components.card.variant.compact",
            nodeKey: "components.card.variant.compact",
            sourceSpan: span(componentFile, 8)),
          DesignSourceOwnership(elementSourceKey: "card.root",
            property: "data-title", schemaKey: "fixtures.card.title",
            nodeKey: "fixtures.card.title", sourceSpan: span(fixtureFile, 1)),
          DesignSourceOwnership(elementSourceKey: "card.root",
            property: "outline-offset", schemaKey: "styles.card.focus",
            nodeKey: "styles.card.shadow", sourceSpan: span(viewFile, 1),
            fallbackInlineFile: viewFile, fallbackInlineLine: 1,
            fallbackAllowed: true),
          DesignSourceOwnership(elementSourceKey: "card.root",
            property: "box-shadow", schemaKey: "styles.card.shadow",
            nodeKey: "styles.card.shadow", sourceSpan: span(viewFile, 1),
            generatedViewFile: viewFile, generatedViewLine: 1,
            unstructuredViewCode: true)
        ])

      let vm = createEditorVM(newEditorWorkspace(
        title = "M35 project-owned design schema",
        storyGroups = @[StoryGroup(name: "DestinationCard",
          kind: skComponent, items: @[StoryItem(name: "Default",
            kind: skComponent, group: "DestinationCard")])],
        designSystemSchema = schema,
        initialStory = some(story)))
      check vm.designSystemSchema.val.schemaVersion == 1
      for kind in [
        dsnFoundation, dsnSemanticToken, dsnComponentToken,
        dsnComponentVariant, dsnComponentState, dsnDensityMode,
        dsnResponsiveMode, dsnClassDefinition, dsnStyleDefinition,
        dsnStoryFixture
      ]:
        check vm.designSystemSchema.val.nodes.anyIt(it.kind == kind)

      check vm.selectInspectorElement(ElementRef(
        id: "card-root",
        sourceKey: "card.root",
        domPath: "article[data-source-key='card.root']",
        schemaKey: "components.card.variant.compact",
        tag: "article",
        sourceFile: viewFile,
        sourceLine: 1,
        properties: @[
          PropertyInfo(name: "background", value: "#ffffff",
            origin: poThemeToken, schemaKey: "semantic.surface.card",
            tokenName: "semantic.surface.card", sourceFile: viewFile,
            sourceLine: 3),
          PropertyInfo(name: "padding", value: "16px",
            origin: poTailwindClass, schemaKey: "components.card.padding",
            originDetail: "class:p-4", sourceFile: viewFile, sourceLine: 4),
          PropertyInfo(name: "border-radius", value: "8px",
            origin: poConstant, schemaKey: "classes.card",
            sourceFile: cssFile, sourceLine: 1),
          PropertyInfo(name: "data-variant", value: "compact",
            origin: poConstant,
            schemaKey: "components.card.variant.compact",
            sourceFile: componentFile, sourceLine: 8),
          PropertyInfo(name: "data-title", value: "Sofia",
            origin: poConstant, schemaKey: "fixtures.card.title",
            sourceFile: fixtureFile, sourceLine: 1),
          PropertyInfo(name: "outline-offset", value: "2px",
            origin: poSetStyle, schemaKey: "styles.card.focus",
            sourceFile: viewFile, sourceLine: 1,
            directStyleAllowed: true),
          PropertyInfo(name: "box-shadow", value: "0 1px 2px #000",
            origin: poSetStyle, schemaKey: "styles.card.shadow",
            sourceFile: viewFile, sourceLine: 1)
        ]))

      let background = vm.resolveDesignSourceOwnership("background")
      check background.ok
      check background.nodeKey == "semantic.surface.card"
      check background.planKind == cspTokenUpdate
      check background.ownership.generatedViewFile == viewFile

      let padding = vm.resolveDesignSourceOwnership("padding")
      check padding.ok
      check padding.ownership.tailwindUtilities == @["p-4", "md:p-6"]
      check padding.planKind == cspTailwindClassReplacement

      let classOwned = vm.resolveDesignSourceOwnership("border-radius")
      check classOwned.ok
      check classOwned.ownership.cssModuleFile == cssFile
      check classOwned.ownership.cssModuleClass == "card"

      let variant = vm.resolveDesignSourceOwnership("data-variant")
      check variant.ok
      check variant.schemaNode.kind == dsnComponentVariant
      let fixture = vm.resolveDesignSourceOwnership("data-title")
      check fixture.ok
      check fixture.schemaNode.kind == dsnStoryFixture

      let fallback = vm.resolveDesignSourceOwnership("outline-offset")
      check fallback.ok
      check fallback.planKind == cspInlineStyleUpdate
      check fallback.ownership.fallbackInlineFile == viewFile

      let buried = vm.resolveDesignSourceOwnership("box-shadow")
      check not buried.ok
      check buried.diagnostics.anyIt(it.kind == dsdUnstructuredViewCode)
      check validateDesignSystemSchema(schema).anyIt(
        it.kind == dsdUnstructuredViewCode)
      dispose()

  test "design_schema_reports_usage_and_impact":
    createRoot proc(dispose: proc()) =
      let root = tempWorkspaceDir("design-schema-impact")
      defer: removeDir(root)

      func span(file: string; line: int): SourceSpan =
        SourceSpan(file: file, line: line, column: 1,
          endLine: line, endColumn: 16)

      let tokenFile = root / "design/tokens.schema"
      createDir(root / "design")
      atomicWrite(tokenFile, "semantic.text.muted=#9ca3af")
      let storyA = StoryRef(group: "DestinationCard", name: "Default",
        kind: skComponent, index: 0)
      let storyB = StoryRef(group: "SearchPage", name: "Results",
        kind: skPage, index: 1)
      let schema = DesignSystemSchema(
        schemaVersion: 1,
        projectId: "metacraft-web-backoffice",
        ownerPackage: "metacraft-web",
        frameworkContract: "isonim-editor-design-schema-v1",
        nodes: @[
          DesignSchemaNode(key: "semantic.text.muted",
            kind: dsnSemanticToken, name: "Muted text", property: "color",
            value: "#9ca3af", sourceSpan: span(tokenFile, 1),
            stories: @[storyA, storyB],
            components: @["DestinationCard", "SearchResultRow"],
            pages: @["Search", "Dashboard"],
            usageCount: 2,
            foreground: "#9ca3af",
            background: "#ffffff",
            minContrast: 4.5,
            accessibilityImpact: dsaiContrast,
            reviewLevel: dsrlShared,
            modeValues: @[
              DesignTokenModeValue(kind: dtmkLight, name: "light",
                value: "#4b5563", sourceSpan: span(tokenFile, 4),
                schemaKey: "semantic.text.muted.light"),
              DesignTokenModeValue(kind: dtmkDark, name: "dark",
                value: "#d1d5db", sourceSpan: span(tokenFile, 5),
                schemaKey: "semantic.text.muted.dark"),
              DesignTokenModeValue(kind: dtmkDensity, name: "compact",
                value: "#6b7280", sourceSpan: span(tokenFile, 6),
                schemaKey: "semantic.text.muted.compact"),
              DesignTokenModeValue(kind: dtmkPlatform, name: "ios",
                value: "#6b7280", sourceSpan: span(tokenFile, 7),
                schemaKey: "semantic.text.muted.ios"),
              DesignTokenModeValue(kind: dtmkBrand, name: "metacraft",
                value: "#475569", sourceSpan: span(tokenFile, 8),
                schemaKey: "semantic.text.muted.brand"),
              DesignTokenModeValue(kind: dtmkBreakpoint, name: "md",
                value: "#64748b", sourceSpan: span(tokenFile, 9),
                schemaKey: "semantic.text.muted.md")
            ])
        ],
        sourceOwnership: @[
          DesignSourceOwnership(elementSourceKey: "card.title",
            property: "color", schemaKey: "semantic.text.muted",
            nodeKey: "semantic.text.muted", sourceSpan: span(tokenFile, 1)),
          DesignSourceOwnership(elementSourceKey: "search.row",
            property: "color", schemaKey: "semantic.text.muted",
            nodeKey: "semantic.text.muted", sourceSpan: span(tokenFile, 1))
        ])

      let vm = createEditorVM(newEditorWorkspace(
        title = "M35 impact workspace",
        storyGroups = @[],
        designSystemSchema = schema))
      let impact = vm.designSchemaImpact("semantic.text.muted")
      check impact.usageCount == 2
      check impact.affectedStories.len == 2
      check impact.affectedComponents == @["DestinationCard", "SearchResultRow"]
      check impact.affectedPages == @["Search", "Dashboard"]
      check impact.modes.len == 6
      for kind in [
        dtmkLight, dtmkDark, dtmkDensity, dtmkPlatform, dtmkBrand, dtmkBreakpoint
      ]:
        check impact.modes.anyIt(it.kind == kind)
      check impact.contrastRatio > 0
      check impact.contrastRatio < impact.minContrast
      check impact.accessibilityImpact == dsaiContrast
      check impact.reviewLevel == dsrlDesignSystem
      check impact.diagnostics.anyIt(it.kind == dsdContrastImpact)
      dispose()

  test "design_schema_preserves_framework_consumer_boundary":
    createRoot proc(dispose: proc()) =
      let schema = DesignSystemSchema(
        schemaVersion: 1,
        projectId: "metacraft-web-backoffice",
        ownerPackage: "metacraft-web",
        frameworkContract: "isonim-editor-design-schema-v1",
        nodes: @[DesignSchemaNode(key: "semantic.surface.card",
          kind: dsnSemanticToken, name: "Card surface",
          property: "background", value: "#ffffff",
          sourceSpan: SourceSpan(file: "apps/back-office/design/tokens.schema",
            line: 1, column: 1, endLine: 1, endColumn: 24))])
      let vm = createEditorVM(newEditorWorkspace(
        title = "Consumer-owned schema fixture",
        storyGroups = @[],
        designSystemSchema = schema))
      check vm.designSystemSchema.val.ownerPackage == "metacraft-web"
      check validateDesignSystemSchema(vm.designSystemSchema.val).len == 0

      for path in walkDirRec("src/isonim/editor"):
        if not path.endsWith(".nim") or path.endsWith("src/isonim/editor/main.nim"):
          continue
        let text = readFile(path).toLowerAscii()
        check not text.contains("metacraft-web")
        check not text.contains("backoffice_editor")
      dispose()

  test "editor_agent_context_includes_source_and_design_system_state":
    createRoot proc(dispose: proc()) =
      let root = tempWorkspaceDir("agent-context")
      defer: removeDir(root)

      let schemaFile = root / "card.schema"
      atomicWrite(schemaFile, "padding=16px")
      let recorder = WorkspaceEditRecorder()
      let schema = @[
        WorkspaceEditableSchemaEntry(
          key: "components.card.padding",
          kind: wskComponentVariant,
          file: schemaFile,
          path: "components.card.padding",
          story: writeStory,
          property: "padding")
      ]
      let adapter = adapterFor(root, schema, recorder = recorder)
      let vm = createEditorVM(newEditorWorkspace(
        title = "M30 agent context workspace",
        storyGroups = @[StoryGroup(name: "DestinationCard",
          kind: skComponent, items: @[StoryItem(name: "Default",
            kind: skComponent, group: "DestinationCard")])],
        initialStory = some(writeStory),
        permissions = EditorWorkspacePermissions(readSource: true,
          writeSource: true),
        editAdapter = adapter,
        agentBackend = absAcp))

      check vm.selectInspectorElement(ElementRef(
        tag: "article",
        sourceFile: schemaFile,
        sourceLine: 1,
        properties: @[PropertyInfo(
          name: "padding",
          value: "16px",
          origin: poConstant,
          originDetail: "schema:components.card.padding",
          sourceFile: schemaFile,
          sourceLine: 1,
          schemaKey: "components.card.padding",
          directStyleAllowed: true)]))
      let edit = vm.editCssProperty("padding", "24px", pesShared, peoInspector)
      check edit.status == pesAccepted
      vm.workspaceEditDiagnostics.val = @[WorkspaceEditDiagnostic(
        kind: wedSourceConflict,
        message: "pending branch update",
        file: schemaFile,
        schemaKey: "components.card.padding",
        property: "padding")]
      vm.review.violations.val = @[Violation(
        severity: vsWarning,
        category: vcAccessibility,
        message: "padding still passes minimum hit target",
        file: schemaFile,
        line: 1)]

      var captured = AgentPromptContext()
      vm.chat.configureAgentAdapters(
        proc(prompt: string; context: AgentPromptContext): bool =
          captured = context
          true,
        nil,
        absAcp)
      vm.chat.inputText.val = "Make the card easier to scan"
      check vm.sendAgentPrompt()

      check captured.backend == absAcp
      check captured.selectedStory.name == "Default"
      check captured.selectedElement.tag == "article"
      check captured.accumulatedEdits.len == 1
      check captured.sourceMap.anyIt(it.schemaKey == "components.card.padding")
      check captured.designSystemSchema.anyIt(
        it.key == "components.card.padding" and it.file == schemaFile)
      check captured.diagnostics.anyIt(
        it.source == "workspace" and it.category == $wedSourceConflict)
      check captured.diagnostics.anyIt(
        it.source == "review" and it.category == $vcAccessibility)
      check captured.currentFileDiffs.anyIt(
        it.file == schemaFile and it.summary.contains("padding"))
      check vm.chat.lastPromptContext.val.designSystemSchema.len == 1
      dispose()

  test "editor_agent_stream_events_update_review_loop_state":
    createRoot proc(dispose: proc()) =
      let root = tempWorkspaceDir("agent-events")
      defer: removeDir(root)

      let schemaFile = root / "card.schema"
      atomicWrite(schemaFile, "padding=16px")
      let schema = @[
        WorkspaceEditableSchemaEntry(
          key: "components.card.padding",
          kind: wskComponentVariant,
          file: schemaFile,
          path: "components.card.padding",
          story: writeStory,
          property: "padding")
      ]
      let recorder = WorkspaceEditRecorder()
      let vm = createEditorVM(newEditorWorkspace(
        title = "M30 event stream workspace",
        storyGroups = @[],
        initialStory = some(writeStory),
        permissions = EditorWorkspacePermissions(readSource: true,
          writeSource: true),
        editAdapter = adapterFor(root, schema, recorder = recorder),
        agentBackend = absAgentHarbor))

      vm.applyAgentEvents(@[
        AgentEvent(kind: aekConnection, state: acsStreaming),
        AgentEvent(kind: aekPlan, planEntries: @["Inspect schema",
          "Propose spacing"]),
        AgentEvent(kind: aekMessageChunk, text: "I found the card schema."),
        AgentEvent(kind: aekToolCall, toolCallId: "tool-1",
          toolName: "edit", status: "permission_required",
          text: "Need write access to update card.schema"),
        AgentEvent(kind: aekFileEdit, filePath: schemaFile, line: 1,
          linesAdded: 1, linesRemoved: 1, text: "padding=24px"),
        AgentEvent(kind: aekReview, filePath: schemaFile, line: 1,
          reviewSeverity: "warning", reviewCategory: "accessibility",
          text: "Spacing still meets target size"),
        AgentEvent(kind: aekCompleted, stopReason: srEndTurn)
      ])

      check vm.chat.connectionState.val == "completed"
      check vm.chat.stopReason.val == "end_turn"
      check vm.chat.planEntries.val == @["Inspect schema", "Propose spacing"]
      check vm.chat.messages.val.anyIt(
        it.kind == cmkAgent and it.text == "I found the card schema.")
      check vm.chat.permissionRequests.val.len == 1
      check vm.chat.permissionRequests.val[0].status == apsPending
      check vm.chat.proposedEdits.val.len == 1
      check vm.chat.proposedEdits.val[0].status == aepsProposed
      check vm.chat.proposedEdits.val[0].reviewDiagnostics.anyIt(
        it.source == "agent-review" and it.category == "accessibility")
      check vm.review.violations.val.anyIt(
        it.file == schemaFile and it.category == vcAccessibility)

      vm.applyAgentEvent(AgentEvent(kind: aekCancelled,
        stopReason: srCancelled))
      check vm.chat.connectionState.val == "cancelled"
      check vm.chat.stopReason.val == "cancelled"

      vm.applyAgentEvent(AgentEvent(kind: aekError, text: "stream failed",
        stopReason: srError))
      check vm.chat.sessionStatus.val == asError
      check vm.chat.messages.val.anyIt(
        it.kind == cmkError and it.text == "stream failed")
      dispose()

  test "editor_agent_edits_require_review_and_user_acceptance":
    createRoot proc(dispose: proc()) =
      let root = tempWorkspaceDir("agent-review")
      defer: removeDir(root)

      let schemaFile = root / "card.schema"
      atomicWrite(schemaFile, "padding=16px\nmargin=8px")
      let recorder = WorkspaceEditRecorder()
      let schema = @[
        WorkspaceEditableSchemaEntry(
          key: "components.card.padding",
          kind: wskComponentVariant,
          file: schemaFile,
          path: "components.card.padding",
          story: writeStory,
          property: "padding"),
        WorkspaceEditableSchemaEntry(
          key: "components.card.margin",
          kind: wskComponentVariant,
          file: schemaFile,
          path: "components.card.margin",
          story: writeStory,
          property: "margin")
      ]
      let vm = createEditorVM(newEditorWorkspace(
        title = "M30 agent review workspace",
        storyGroups = @[],
        initialStory = some(writeStory),
        permissions = EditorWorkspacePermissions(readSource: true,
          writeSource: true),
        editAdapter = adapterFor(root, schema, recorder = recorder),
        agentBackend = absAgentHarbor))

      let permissionId = vm.chat.addAgentPermissionRequest(
        AgentPermissionRequest(title: "Write source",
          detail: "Agent wants to update card schema.",
          options: @["allow", "deny"]))
      check vm.chat.permissionRequests.val[0].status == apsPending
      check vm.chat.setAgentPermissionStatus(permissionId, apsGranted)
      check vm.chat.permissionRequests.val[0].status == apsGranted
      check vm.chat.setAgentPermissionStatus(permissionId, apsCancelled)
      check vm.chat.permissionRequests.val[0].status == apsCancelled

      let rejectedId = vm.chat.addAgentEditProposal(AgentEditProposal(
        title: "Unsafe proposal",
        summary: "unsafe spacing",
        sourceEdits: @[planFor(schemaFile, "padding", "16px", "unsafe",
          "components.card.padding")]))
      check vm.rejectAgentProposedEdit(rejectedId)
      check readFile(schemaFile).contains("padding=16px")
      check vm.chat.proposedEdits.val[0].status == aepsRejected

      let proposalId = vm.chat.addAgentEditProposal(AgentEditProposal(
        title: "Spacing proposal",
        summary: "padding and margin",
        sourceEdits: @[
          planFor(schemaFile, "padding", "16px", "24px",
            "components.card.padding"),
          planFor(schemaFile, "margin", "8px", "12px",
            "components.card.margin")
        ],
        diffs: @[AgentFileDiff(file: schemaFile, beforeText: "padding=16px",
          afterText: "padding=24px", summary: "padding update")]))

      var rerunPrompt = ""
      vm.chat.configureAgentAdapters(
        proc(prompt: string; context: AgentPromptContext): bool =
          rerunPrompt = prompt
          true,
        nil,
        absAgentHarbor)
      check vm.rerunAgentProposedEdit(proposalId)
      check rerunPrompt.contains("padding and margin")

      check readFile(schemaFile).contains("padding=16px")
      let accepted = vm.acceptAgentProposedEdit(proposalId, @[0])
      check accepted.ok
      check recorder.reviewCount > 0
      check readFile(schemaFile).contains("padding=24px")
      check readFile(schemaFile).contains("margin=8px")
      check vm.chat.proposedEdits.val.anyIt(
        it.id == proposalId and it.status == aepsPartiallyAccepted and
        it.appliedPatches.len == 1)

      let reverted = vm.revertAgentProposedEdit(proposalId)
      check reverted.ok
      check readFile(schemaFile).contains("padding=16px")
      check vm.chat.proposedEdits.val.anyIt(
        it.id == proposalId and it.status == aepsReverted)
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
