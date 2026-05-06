## Tests for IsoNim Editor ViewModels (M0)

import std/[options, unittest, strutils, sequtils, os]
import nim_agents
import isonim/core/[signals, computation, owner]
import isonim/viewmodel
import isonim/editor/agent_context
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
        if kind in {eckOpenCommandPalette, eckToggleSidebar,
            eckToggleInspector, eckFocusInspector}:
          check state.status == ecsAvailable
        else:
          check state.status == ecsDisabled
          check state.diagnostic.len > 0

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

suite "Editor ViewModels (M44 keyboard accessibility performance)":

  func keyboardStory(): StoryRef =
    StoryRef(group: "DestinationCard", name: "Default",
      kind: skComponent, index: 0)

  proc installKeyboardStory(vm: EditorVM) =
    vm.sidebar.groups.val = @[
      StoryGroup(name: "DestinationCard", kind: skComponent,
        description: "Card component", expanded: true, items: @[
          StoryItem(name: "Default", description: "Default state",
            kind: skComponent, group: "DestinationCard")
      ])
    ]
    check vm.selectStory(keyboardStory())

  proc installLayerTree(vm: EditorVM) =
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

  test "editor_shortcut_map_and_command_palette_cover_all_commands":
    createRoot proc(dispose: proc()) =
      let vm = createEditorVM()
      let bindings = allEditorShortcutBindings()
      check bindings.len == allEditorCommandKinds().len
      check duplicateEditorShortcuts(bindings).len == 0
      for kind in allEditorCommandKinds():
        check bindings.anyIt(it.kind == kind and it.shortcut.len > 0 and
          it.description.len > 0 and it.scope.len > 0)

      let emptyEntries = vm.commandPaletteEntries()
      check emptyEntries.len == allEditorCommandKinds().len
      check emptyEntries.anyIt(it.kind == eckOpenCommandPalette and
        it.status == ecsAvailable and it.shortcut == "Mod+K")
      check emptyEntries.anyIt(it.kind == eckSave and
        it.status == ecsDisabled and it.diagnostic.len > 0)

      vm.installKeyboardStory()
      vm.installLayerTree()
      check vm.runEditorCommand(eckOpenCommandPalette).status == ecsSucceeded
      check vm.commandPaletteOpen.val
      vm.closeCommandPalette()
      check not vm.commandPaletteOpen.val

      check vm.runEditorCommand(eckSelectNext).status == ecsSucceeded
      check vm.inspector.selectedElement.val.id == "title"
      check vm.runEditorCommand(eckSelectParent).status == ecsSucceeded
      check vm.inspector.selectedElement.val.id == "header"
      check vm.runEditorCommand(eckToggleSidebar).status == ecsSucceeded
      check vm.panels.val.sidebar == false
      check vm.runEditorCommand(eckFocusInspector).status == ecsSucceeded
      check vm.panels.val.inspector
      check vm.inspector.focusedControlId.val == "section-search"
      dispose()

  test "editor_interaction_performance_budgets":
    createRoot proc(dispose: proc()) =
      let vm = createEditorVM()
      let budgets = defaultEditorPerformanceBudgets()
      check budgets.len == 6
      for kind in [epbkStorySelection, epbkElementSelection, epbkModeSwitch,
          epbkPropertyEditPreview, epbkSaveReload, epbkLargeSidebarSearch]:
        check budgets.anyIt(it.kind == kind and it.label.len > 0 and
          it.maxMs > 0)

      for budget in budgets:
        vm.recordEditorTiming(budget.kind, max(0, budget.maxMs - 1),
          "within " & budget.label)
      check performanceBudgetsPass(vm.telemetryEvents.val)

      vm.recordEditorTiming(epbkModeSwitch, budgets.filterIt(
        it.kind == epbkModeSwitch)[0].maxMs + 1, "forced regression")
      check not performanceBudgetsPass(vm.telemetryEvents.val)
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

  test "long_tail_property_schema_and_source_plans":
    createRoot proc(dispose: proc()) =
      let matrix = defaultLongTailPropertyEvidenceMatrix()
      for family in [
        "typography",
        "color_and_background",
        "border_shadow_and_effects",
        "filters",
        "transforms_and_transitions",
        "grid_and_flex",
        "overflow_position_and_sizing",
        "responsive_variants",
        "pseudo_state_variants",
        "container_queries"
      ]:
        check matrix.anyIt(it.family == family and
          it.representativeProperties.len > 0 and
          it.implementationReferences.len > 0)

      for row in matrix:
        if row.status == ltpesValidated:
          for property in row.representativeProperties:
            check property in ["letter-spacing", "background-size", "filter",
              "transform", "transition-duration", "aspect-ratio"]
          check row.sourceWrite
          check row.headlessValidation
          check row.browserBehavior
          check row.visualEvidence
          check row.metacraftEvidence
        if row.status == ltpesReadOnly:
          check not row.sourceWrite
          check row.limitations.contains("read-only")
        if row.family == "pseudo_state_variants":
          check row.status == ltpesReadOnly
          check not row.sourceWrite
          check not row.headlessValidation
          check not row.browserBehavior
          check not row.visualEvidence
          check not row.metacraftEvidence

      let vm = createEditorVM()
      check vm.selectInspectorElement(cssElement(@[
        cssProp("letter-spacing", "0px", poConstant,
          "schema:type.card.letterSpacing",
          schemaKey = "type.card.letterSpacing"),
        cssProp("text-transform", "none", poConstant,
          "schema:type.card.transform", schemaKey = "type.card.transform"),
        cssProp("background-image",
          "linear-gradient(90deg, #3B82F6 0%, #22C55E 100%)", poConstant,
          "schema:surface.hero.gradient", schemaKey = "surface.hero.gradient"),
        cssProp("background-size", "cover", poConstant,
          "schema:surface.hero.backgroundSize",
          schemaKey = "surface.hero.backgroundSize"),
        cssProp("outline-offset", "2px", poConstant,
          "schema:a11y.focus.offset", schemaKey = "a11y.focus.offset"),
        cssProp("border-style", "solid", poConstant,
          "schema:a11y.focus.borderStyle",
          schemaKey = "a11y.focus.borderStyle"),
        cssProp("box-shadow", "0 1px 2px rgba(15, 23, 42, 0.18)",
          poConstant, "schema:elevation.panel", schemaKey = "elevation.panel"),
        cssProp("filter", "blur(0px)", poConstant,
          "schema:effects.filter", schemaKey = "effects.filter"),
        cssProp("backdrop-filter", "blur(2px)", poConstant,
          "schema:effects.backdrop", schemaKey = "effects.backdrop"),
        cssProp("transform", "translateX(0px)", poConstant,
          "schema:motion.transform", schemaKey = "motion.transform"),
        cssProp("transition-duration", "120ms", poConstant,
          "schema:motion.fast", schemaKey = "motion.fast"),
        cssProp("flex-wrap", "nowrap", poConstant,
          "schema:layout.wrap", schemaKey = "layout.wrap"),
        cssProp("grid-auto-flow", "row", poConstant,
          "schema:layout.grid.flow", schemaKey = "layout.grid.flow"),
        cssProp("overflow-x", "hidden", poConstant,
          "schema:layout.overflowX", schemaKey = "layout.overflowX"),
        cssProp("overscroll-behavior", "auto", poConstant,
          "schema:layout.overscroll", schemaKey = "layout.overscroll"),
        cssProp("aspect-ratio", "16 / 9", poConstant,
          "schema:size.aspect", schemaKey = "size.aspect"),
        cssProp("gap", "16px", poThemeToken,
          "schema:layout.responsive.sm.gap", sharedCount = 4,
          schemaKey = "layout.responsive.sm.gap",
          tokenName = "space.cardGap", variantKey = "sm")
      ]))

      let editors = vm.inspector.propertyEditors.val
      check editors.anyIt(it.property == "letter-spacing" and
        it.category == cpcTypography and it.value.kind == cvkLength)
      check editors.anyIt(it.property == "background-size" and
        it.category == cpcSize and cvkKeyword in it.allowedValueKinds)
      check editors.anyIt(it.property == "box-shadow" and
        it.category == cpcEffects and it.value.kind == cvkShadow)
      check editors.anyIt(it.property == "filter" and
        it.category == cpcEffects and it.value.kind == cvkFilter)
      check editors.anyIt(it.property == "transform" and
        it.category == cpcTransforms and it.value.kind == cvkTransform)
      check editors.anyIt(it.property == "overflow-x" and
        it.category == cpcOverflow and it.value.kind == cvkOverflow)
      check editors.anyIt(it.property == "aspect-ratio" and
        it.category == cpcSize)
      check editors.anyIt(it.property == "gap" and
        it.supportsSharedScope and it.sourcePlanKind == cspTokenUpdate)

      for (property, value) in [
        ("letter-spacing", "0.03em"),
        ("text-transform", "uppercase"),
        ("background-size", "contain"),
        ("outline-offset", "4px"),
        ("border-style", "dashed"),
        ("box-shadow", "0 8px 24px rgba(15, 23, 42, 0.20)"),
        ("filter", "brightness(1.08) contrast(1.1)"),
        ("backdrop-filter", "blur(6px)"),
        ("transform", "translateX(8px) scale(1.02)"),
        ("transition-duration", "180ms"),
        ("flex-wrap", "wrap"),
        ("grid-auto-flow", "row dense"),
        ("overflow-x", "auto"),
        ("overscroll-behavior", "contain"),
        ("aspect-ratio", "4 / 3")
      ]:
        let edit = vm.editCssProperty(property, value, pesLocal)
        check edit.status == pesAccepted
        check edit.sourceEdit.property == property
        check edit.sourceEdit.reversible

      let shared = vm.editCssProperty("gap", "token(space.cardGapCompact)",
        pesShared)
      check shared.status == pesAccepted
      check shared.sourceEdit.planKind == cspTokenUpdate
      check shared.sourceEdit.variantKey == "sm"
      check shared.sourceEdit.conflictKey.contains(":sm")

      let reset = vm.editCssProperty("filter", "", pesLocal)
      check reset.status == pesAccepted
      check reset.sourceEdit.planKind == cspPropertyRemoval

      for (property, value) in [
        ("text-transform", "shout"),
        ("background-size", "gigantic"),
        ("filter", "glow(4px)"),
        ("transform", "spin(20deg)"),
        ("transition-duration", "-10ms"),
        ("overflow-x", "sideways"),
        ("aspect-ratio", "wide")
      ]:
        let rejected = vm.editCssProperty(property, value, pesLocal)
        check rejected.status == pesRejected
        check rejected.diagnostics.anyIt(it.kind == pedInvalidCssValue)
      dispose()

  test "primitive_controls_parse_normalize_validate_and_source_plan":
    createRoot proc(dispose: proc()) =
      let vm = createEditorVM()
      check vm.selectInspectorElement(cssElement(@[
        cssProp("padding", "12px", poTailwindClass, "class:p-3"),
        cssProp("color", "#334155", poThemeToken,
          "schema:semantic.text.primary", tokenName = "semantic.text.primary"),
        cssProp("background-image",
          "linear-gradient(90deg, #3B82F6 0%, #22C55E 100%)", poConstant,
          "schema:gradient.hero", schemaKey = "gradient.hero"),
        cssProp("box-shadow", "0 2px 8px rgba(0,0,0,.2)", poConstant,
          "schema:elevation.card", schemaKey = "elevation.card"),
        cssProp("font-size", "16px", poConstant,
          "schema:type.body.size", schemaKey = "type.body.size"),
        cssProp("border-radius", "8px", poConstant,
          "schema:radius.card", schemaKey = "radius.card"),
        cssProp("transition-duration", "150ms", poConstant,
          "schema:motion.fast", schemaKey = "motion.fast"),
        cssProp("transition-timing-function", "ease", poConstant,
          "schema:motion.easing", schemaKey = "motion.easing")
      ]))

      let numeric = primitiveControlModel(
        vm.inspector.selectedElement.val.properties[0], "8+4px")
      check numeric.family == pcfNumeric
      check numeric.canonical == "12px"
      check pccMathExpression in numeric.capabilities
      check pccUnitCycle in numeric.capabilities
      check numeric.sourcePlanKind == cspTailwindClassReplacement
      check numeric.valid

      let color = primitiveControlModel(
        vm.inspector.selectedElement.val.properties[1],
        "token(semantic.text.secondary)")
      check color.family == pcfColor
      check color.tokenName == "semantic.text.secondary"
      check pccSwatches in color.capabilities
      check pccContrastPreview in color.capabilities
      check color.sourcePlanKind == cspTokenUpdate

      let gradient = primitiveControlModel(
        vm.inspector.selectedElement.val.properties[2],
        "linear-gradient(135deg, #3B82F6 0%, token(semantic.accent) 48%, #22C55E 100%)")
      check gradient.family == pcfGradient
      check pccGradientStops in gradient.capabilities
      check pccGradientAngle in gradient.capabilities
      check gradient.sourceSerialized.contains("linear-gradient")
      check gradient.sourcePlanKind == cspStructuredSchemaUpdate

      let shadow = primitiveControlModel(
        vm.inspector.selectedElement.val.properties[3],
        "0 1px 2px rgba(15, 23, 42, 0.18), 0 12px 32px rgba(15, 23, 42, 0.16)")
      check shadow.family == pcfShadow
      check pccShadowLayers in shadow.capabilities
      check pccElevationToken in shadow.capabilities

      let typography = primitiveControlModel(
        vm.inspector.selectedElement.val.properties[4], "18px")
      check typography.family == pcfTypography
      check pccTypographyStyle in typography.capabilities
      check pccResponsiveText in typography.capabilities

      let radius = primitiveControlModel(
        vm.inspector.selectedElement.val.properties[5], "10px")
      check radius.family == pcfBorderRadiusStroke
      check pccLinkedCorners in radius.capabilities
      check pccCanvasHandle in radius.capabilities

      let motion = primitiveControlModel(
        vm.inspector.selectedElement.val.properties[6], "200ms")
      check motion.family == pcfMotion
      check motion.unit == "ms"
      check pccBezierCurve in motion.capabilities
      check pccReducedMotionDiagnostic in motion.capabilities

      let easing = primitiveControlModel(
        vm.inspector.selectedElement.val.properties[7], "ease-in-out")
      check easing.family == pcfMotion
      check easing.canonical == "ease-in-out"
      check pccBezierCurve in easing.capabilities
      check easing.sourcePlanKind == cspStructuredSchemaUpdate

      let invalidMotion = vm.editCssProperty("transition-duration", "-20ms",
        pesLocal)
      check invalidMotion.status == pesRejected
      check invalidMotion.diagnostics.anyIt(it.kind == pedInvalidCssValue)

      let edit = vm.editCssProperty("padding", "6*4px", pesLocal)
      check edit.status == pesAccepted
      check edit.sourceEdit.newValue == "24px"
      check edit.sourceEdit.previewAfter.contains("padding: 24px")
      dispose()

  test "primitive_controls_undo_redo_and_live_preview":
    createRoot proc(dispose: proc()) =
      let vm = createEditorVM()
      check vm.selectInspectorElement(cssElement(@[
        cssProp("padding", "12px", poTailwindClass, "class:p-3"),
        cssProp("color", "#334155", poConstant,
          "schema:semantic.text.primary", schemaKey = "semantic.text.primary"),
        cssProp("background-image", "linear-gradient(90deg, #3B82F6 0%, #22C55E 100%)",
          poConstant, "schema:gradient.hero", schemaKey = "gradient.hero"),
        cssProp("box-shadow", "none", poConstant,
          "schema:elevation.card", schemaKey = "elevation.card"),
        cssProp("font-weight", "600", poConstant,
          "schema:type.heading.weight", schemaKey = "type.heading.weight"),
        cssProp("border-radius", "8px", poConstant,
          "schema:radius.card", schemaKey = "radius.card"),
        cssProp("transition-timing-function", "ease", poConstant,
          "schema:motion.easing", schemaKey = "motion.easing")
      ]))

      let preview = primitiveControlModel(
        vm.inspector.selectedElement.val.properties[0], "10+6px")
      check preview.livePreviewValue == "16px"
      check preview.valid

      check vm.editCssProperty("padding", "10+6px", pesLocal).status ==
        pesAccepted
      check vm.editCssProperty("color", "#F8FAFC", pesLocal).status ==
        pesAccepted
      check vm.editCssProperty("background-image",
        "linear-gradient(135deg, #3B82F6 0%, #22C55E 100%)", pesLocal).status ==
        pesAccepted
      check vm.editCssProperty("box-shadow",
        "0 8px 24px rgba(15, 23, 42, 0.18)", pesLocal).status ==
        pesAccepted
      check vm.editCssProperty("font-weight", "700", pesLocal).status ==
        pesAccepted
      check vm.editCssProperty("border-radius", "12px", pesLocal).status ==
        pesAccepted
      check vm.editCssProperty("transition-timing-function", "ease-in-out",
        pesLocal).status == pesAccepted
      check vm.inspector.undoStack.val.len == 7
      check vm.inspector.pendingSourceEdits.val.len == 7
      check vm.inspector.sourcePreviews.val.anyIt(
        it.plan.property == "padding" and it.afterText.contains("16px"))
      check vm.inspector.sourcePreviews.val.anyIt(
        it.plan.property == "background-image" and
          it.afterText.contains("135deg"))
      check vm.inspector.sourcePreviews.val.anyIt(
        it.plan.property == "border-radius" and it.afterText.contains("12px"))
      check vm.inspector.sourcePreviews.val.anyIt(
        it.plan.property == "transition-timing-function" and
          it.afterText.contains("ease-in-out"))

      check vm.inspector.undoCssPropertyEdit()
      check vm.inspector.selectedElement.val.properties.anyIt(
        it.name == "transition-timing-function" and it.value == "ease")
      check vm.inspector.redoStack.val.len == 1
      check vm.inspector.redoCssPropertyEdit()
      check vm.inspector.selectedElement.val.properties.anyIt(
        it.name == "transition-timing-function" and it.value == "ease-in-out")
      check vm.inspector.pendingSourceEdits.val.anyIt(
        it.property == "transition-timing-function" and
          it.newValue == "ease-in-out")

      var savedPlans: seq[SourceEditPlan] = @[]
      check vm.inspector.saveCssPropertyEdits(proc(plan: SourceEditPlan): bool =
        savedPlans.add plan
        true)
      check savedPlans.len == 7
      check savedPlans.anyIt(it.property == "background-image")
      check savedPlans.anyIt(it.property == "border-radius")
      check savedPlans.anyIt(it.property == "transition-timing-function")
      check vm.inspector.pendingSourceEdits.val.len == 0
      check vm.inspector.undoStack.val.len == 0

      discard vm.editCssProperty("padding", "18px", pesLocal)

      vm.inspector.discardCssPropertyEdits()
      check vm.inspector.pendingSourceEdits.val.len == 0
      check vm.inspector.undoStack.val.len == 0
      check vm.inspector.selectedElement.val.properties.anyIt(
        it.name == "padding" and it.value == "16px")
      dispose()

  test "layout_controls_plan_structured_flex_grid_constraint_edits":
    createRoot proc(dispose: proc()) =
      func span(file: string; line: int): SourceSpan =
        SourceSpan(file: file, line: line, column: 1,
          endLine: line, endColumn: 24)

      let tokenFile = "design/layout-tokens.schema"
      let cssFile = "components/card.css"
      let styleFile = "components/card.layout.schema"
      let fixtureFile = "stories/card.fixture"
      let schema = DesignSystemSchema(
        schemaVersion: 1,
        projectId: "layout-fixture",
        ownerPackage: "isonim-tests",
        frameworkContract: "isonim-editor-design-schema-v1",
        nodes: @[
          DesignSchemaNode(key: "tokens.card.gap",
            kind: dsnComponentToken, component: "Card", property: "gap",
            value: "12px", sourceSpan: span(tokenFile, 4)),
          DesignSchemaNode(key: "classes.card.grid",
            kind: dsnClassDefinition, component: "Card",
            property: "grid-template-columns",
            value: "1fr", sourceSpan: span(cssFile, 8)),
          DesignSchemaNode(key: "styles.card.aspect",
            kind: dsnStyleDefinition, component: "Card",
            property: "aspect-ratio",
            value: "auto", sourceSpan: span(styleFile, 12)),
          DesignSchemaNode(key: "fixtures.card.child-order",
            kind: dsnStoryFixture, component: "Card", property: "order",
            value: "0", sourceSpan: span(fixtureFile, 2))
        ],
        sourceOwnership: @[
          DesignSourceOwnership(elementSourceKey: "card.root",
            property: "gap", schemaKey: "tokens.card.gap",
            nodeKey: "tokens.card.gap", sourceSpan: span(tokenFile, 4)),
          DesignSourceOwnership(elementSourceKey: "card.root",
            property: "grid-template-columns",
            schemaKey: "classes.card.grid",
            nodeKey: "classes.card.grid",
            sourceSpan: span(cssFile, 8),
            cssModuleFile: cssFile, cssModuleClass: "card",
            tailwindUtilities: @["grid-cols-1"]),
          DesignSourceOwnership(elementSourceKey: "card.root",
            property: "aspect-ratio", schemaKey: "styles.card.aspect",
            nodeKey: "styles.card.aspect",
            sourceSpan: span(styleFile, 12)),
          DesignSourceOwnership(elementSourceKey: "card.child",
            property: "order", schemaKey: "fixtures.card.child-order",
            nodeKey: "fixtures.card.child-order",
            sourceSpan: span(fixtureFile, 2))
        ])

      let vm = createEditorVM()
      vm.designSystemSchema.val = schema
      check vm.selectInspectorElement(ElementRef(
        id: "card-root",
        sourceKey: "card.root",
        schemaKey: "components.card",
        tag: "article",
        sourceFile: "components/card.nim",
        sourceLine: 30,
        properties: @[
          cssProp("display", "flex", poConstant, "schema:layout.display",
            file = styleFile, line = 3, schemaKey = "styles.card.display"),
          cssProp("gap", "12px", poConstant, "schema:tokens.card.gap",
            file = tokenFile, line = 4, schemaKey = "tokens.card.gap"),
          cssProp("grid-template-columns", "1fr", poTailwindClass,
            "class:grid-cols-1", file = cssFile, line = 8,
            schemaKey = "classes.card.grid"),
          cssProp("aspect-ratio", "auto", poConstant,
            "schema:styles.card.aspect", file = styleFile, line = 12,
            schemaKey = "styles.card.aspect")
        ]))

      let flexCapabilities = layoutControlCapabilities(lcfFlexAutoLayout)
      for capability in [
        lccFlexDirection, lccFlexWrap, lccGap, lccPadding, lccAlign,
        lccJustify, lccDistribution, lccHugFillFixedSizing, lccChildOrder,
        lccPerChildAlignment
      ]:
        check capability in flexCapabilities
      let gridCapabilities = layoutControlCapabilities(lcfGrid)
      for capability in [
        lccGridTemplateTracks, lccGridGap, lccGridPlacement,
        lccGridAutoFlow, lccGridNamedAreas
      ]:
        check capability in gridCapabilities
      let constraintCapabilities = layoutControlCapabilities(lcfConstraints)
      for capability in [
        lccConstraints, lccMinMax, lccIntrinsicContentSizing,
        lccAspectRatio, lccOverflowStrategy
      ]:
        check capability in constraintCapabilities
      let guideCapabilities = layoutControlCapabilities(lcfCanvasGuide)
      for capability in [
        lccSpacingMeasurement, lccGapOverlay, lccAlignHandle,
        lccResizeHandle, lccSnapLine, lccLayoutDiagnostic
      ]:
        check capability in guideCapabilities

      let gapPlan = vm.planLayoutControlEdit(layoutCommand(
        lcfFlexAutoLayout, "gap", "24px"))
      check gapPlan.ok
      check gapPlan.sourceEdit.planKind == cspTokenUpdate
      check gapPlan.sourceEdit.file == tokenFile
      check gapPlan.sourceEdit.originDetail.startsWith("layout-token:")

      let gridPlan = vm.planLayoutControlEdit(layoutCommand(
        lcfGrid, "grid-template-columns",
        "repeat(2, minmax(0, 1fr))"))
      check gridPlan.ok
      check gridPlan.sourceEdit.planKind == cspTailwindClassReplacement
      check gridPlan.sourceEdit.originDetail.startsWith("layout-class:")

      let aspectPlan = vm.planLayoutControlEdit(layoutCommand(
        lcfConstraints, "aspect-ratio", "16 / 9"))
      check aspectPlan.ok
      check aspectPlan.sourceEdit.planKind == cspStructuredSchemaUpdate
      check aspectPlan.sourceEdit.originDetail.startsWith("layout-style:")

      check vm.selectInspectorElement(ElementRef(
        id: "card-child",
        sourceKey: "card.child",
        schemaKey: "components.card.child",
        tag: "section",
        sourceFile: "components/card.nim",
        sourceLine: 42,
        properties: @[
          cssProp("order", "0", poConstant,
            "schema:fixtures.card.child-order", file = fixtureFile, line = 2,
            schemaKey = "fixtures.card.child-order")
        ]))
      let orderPlan = vm.planLayoutControlEdit(layoutCommand(
        lcfFlexAutoLayout, "order", "1", childSourceKey = "card.child"))
      check orderPlan.ok
      check orderPlan.sourceEdit.originDetail.startsWith("layout-fixture:")

      let unsupported = vm.planLayoutControlEdit(layoutCommand(
        lcfConstraints, "translate", "12px"))
      check not unsupported.ok
      check unsupported.diagnostics.anyIt(it.kind == pedSchemaViolation)
      dispose()

  test "responsive_overrides_are_scoped_to_selected_viewport_mode":
    createRoot proc(dispose: proc()) =
      func span(file: string; line: int): SourceSpan =
        SourceSpan(file: file, line: line, column: 1,
          endLine: line, endColumn: 20)

      let sourceFile = "components/responsive-card.layout.schema"
      let schema = DesignSystemSchema(
        schemaVersion: 1,
        projectId: "responsive-layout-fixture",
        ownerPackage: "isonim-tests",
        frameworkContract: "isonim-editor-design-schema-v1",
        nodes: @[
          DesignSchemaNode(key: "modes.desktop.gap",
            kind: dsnResponsiveMode, name: "Desktop", property: "gap",
            value: "12px", sourceSpan: span(sourceFile, 4)),
          DesignSchemaNode(key: "modes.tablet.gap",
            kind: dsnResponsiveMode, name: "Tablet", property: "gap",
            value: "16px", sourceSpan: span(sourceFile, 8)),
          DesignSchemaNode(key: "modes.mobile.gap",
            kind: dsnResponsiveMode, name: "Mobile", property: "gap",
            value: "20px", sourceSpan: span(sourceFile, 12)),
          DesignSchemaNode(key: "modes.compact-dashboard.gap",
            kind: dsnResponsiveMode, name: "Compact dashboard",
            property: "gap", value: "10px", sourceSpan: span(sourceFile, 16))
        ],
        sourceOwnership: @[
          DesignSourceOwnership(elementSourceKey: "card.root",
            property: "gap", schemaKey: "modes.desktop.gap",
            nodeKey: "modes.desktop.gap", sourceSpan: span(sourceFile, 4)),
          DesignSourceOwnership(elementSourceKey: "card.root",
            property: "gap", schemaKey: "modes.tablet.gap",
            nodeKey: "modes.tablet.gap", sourceSpan: span(sourceFile, 8)),
          DesignSourceOwnership(elementSourceKey: "card.root",
            property: "gap", schemaKey: "modes.mobile.gap",
            nodeKey: "modes.mobile.gap", sourceSpan: span(sourceFile, 12)),
          DesignSourceOwnership(elementSourceKey: "card.root",
            property: "gap", schemaKey: "modes.compact-dashboard.gap",
            nodeKey: "modes.compact-dashboard.gap",
            sourceSpan: span(sourceFile, 16))
        ])

      let vm = createEditorVM()
      vm.designSystemSchema.val = schema
      check responsiveEditModes(schema).anyIt(it.key == "desktop")
      check responsiveEditModes(schema).anyIt(
        it.key == "modes.compact-dashboard.gap" and
          it.kind == rmkProjectDefined)
      check layoutModeKey(pvMobile) == "mobile"
      check vm.selectInspectorElement(ElementRef(
        id: "card-root",
        sourceKey: "card.root",
        schemaKey: "components.card",
        tag: "article",
        sourceFile: "components/responsive-card.nim",
        sourceLine: 21,
        properties: @[
          cssProp("gap", "8px", poConstant, "schema:modes.desktop.gap",
            file = sourceFile, line = 3, schemaKey = "modes.desktop.gap"),
          cssProp("gap", "12px", poConstant, "schema:modes.desktop.gap",
            file = sourceFile, line = 4, schemaKey = "modes.desktop.gap",
            variantKey = "desktop"),
          cssProp("gap", "16px", poConstant, "schema:modes.tablet.gap",
            file = sourceFile, line = 8, schemaKey = "modes.tablet.gap",
            variantKey = "tablet"),
          cssProp("gap", "20px", poConstant, "schema:modes.mobile.gap",
            file = sourceFile, line = 12, schemaKey = "modes.mobile.gap",
            variantKey = "mobile"),
          cssProp("gap", "10px", poConstant,
            "schema:modes.compact-dashboard.gap",
            file = sourceFile, line = 16,
            schemaKey = "modes.compact-dashboard.gap",
            variantKey = "modes.compact-dashboard.gap")
        ]))

      let mobile = vm.applyResponsiveLayoutOverride("mobile", "gap", "28px")
      check mobile.ok
      check mobile.sourceEdit.variantKey == "mobile"
      check mobile.sourceEdit.conflictKey.endsWith(":mobile")
      check mobile.sourceEdit.expectedOldValue == "20px"
      check vm.inspector.selectedElement.val.properties.anyIt(
        it.name == "gap" and it.variantKey == "mobile" and it.value == "28px")
      check vm.inspector.selectedElement.val.properties.anyIt(
        it.name == "gap" and it.variantKey == "tablet" and it.value == "16px")
      check vm.inspector.selectedElement.val.properties.anyIt(
        it.name == "gap" and it.variantKey == "desktop" and it.value == "12px")
      check vm.inspector.selectedElement.val.properties.anyIt(
        it.name == "gap" and it.variantKey.len == 0 and it.value == "8px")

      let custom = vm.applyResponsiveLayoutOverride(
        "modes.compact-dashboard.gap", "gap", "14px")
      check custom.ok
      check custom.sourceEdit.variantKey == "modes.compact-dashboard.gap"
      check vm.inspector.pendingSourceEdits.val.len == 2
      check vm.inspector.pendingSourceEdits.val.anyIt(
        it.variantKey == "mobile" and it.newValue == "28px")
      check vm.inspector.pendingSourceEdits.val.anyIt(
        it.variantKey == "modes.compact-dashboard.gap" and
          it.newValue == "14px")
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
        "",
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
      fullReload = false; generatedArtifacts: seq[string] = @[];
      requiredTestCommands: seq[string] = @[];
      reviewDiagnostics: seq[WorkspaceEditDiagnostic] = @[]): WorkspaceOperationResult =
    WorkspaceOperationResult(ok: true, message: message,
      affectedStories: affectedStories, fullReload: fullReload,
      generatedArtifacts: generatedArtifacts,
      requiredTestCommands: requiredTestCommands,
      reviewDiagnostics: reviewDiagnostics)

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
      sourceScope: sskSharedClass,
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

  test "m44_telemetry_exercises_selection_preview_save_and_bridge_error_paths":
    createRoot proc(dispose: proc()) =
      let root = tempWorkspaceDir("m44-telemetry")
      defer: removeDir(root)
      let schemaFile = root / "component.schema"
      atomicWrite(schemaFile, "padding=16px")
      let story = writeStory
      let schema = @[
        WorkspaceEditableSchemaEntry(key: "components.card.padding",
          kind: wskSourceMap, file: schemaFile, path: "card.padding",
          story: story, property: "padding")
      ]
      let recorder = WorkspaceEditRecorder()
      let workspace = newEditorWorkspace(
        title = "M44 telemetry workspace",
        storyGroups = @[StoryGroup(name: story.group, kind: story.kind,
          expanded: true, items: @[StoryItem(name: story.name,
            kind: story.kind, group: story.group)])],
        permissions = EditorWorkspacePermissions(readSource: true,
          writeSource: true, createStory: false, createVariant: false,
          duplicate: false, delete: false),
        editAdapter = adapterFor(root, schema, recorder = recorder))
      let vm = createEditorVM(workspace)
      check vm.selectStory(story)
      vm.inspector.setSelectionTree(@[
        ElementLayerRow(id: "card", label: "article", tag: "article",
          sourceKey: "components.card", schemaKey: "components.card.padding",
          sourceFile: schemaFile, sourceLine: 1, depth: 0,
          childCount: 1, expanded: true),
        ElementLayerRow(id: "title", parentId: "card", label: "h2", tag: "h2",
          sourceKey: "components.card.title", schemaKey: "components.card.title",
          sourceFile: schemaFile, sourceLine: 2, depth: 1)
      ])
      check vm.selectInspectorElement(ElementRef(id: "card",
        sourceKey: "components.card",
        schemaKey: "components.card.padding",
        tag: "article",
        sourceFile: schemaFile,
        sourceLine: 1,
        properties: @[PropertyInfo(name: "padding", value: "16px",
          origin: poTailwindClass, originDetail: "schema:components.card.padding",
          sourceFile: schemaFile, sourceLine: 1,
          schemaKey: "components.card.padding")]))

      check vm.runEditorCommand(eckSelectNext).status == ecsSucceeded
      check vm.runEditorCommand(eckSelectPrevious).status == ecsSucceeded
      let edit = vm.editInspectorProperty(PropertyEditRequest(
        property: "padding", newValue: "24px", kind: pekCss,
        scope: pesShared, origin: peoInspector))
      check edit.status == pesAccepted
      check vm.inspector.pendingSourceEdits.val.len == 1
      check vm.runEditorCommand(eckUndo).status == ecsSucceeded
      check vm.inspector.pendingSourceEdits.val.len == 0
      check vm.runEditorCommand(eckRedo).status == ecsSucceeded
      check vm.inspector.pendingSourceEdits.val.len == 1

      let saved = vm.runEditorCommand(eckSave)
      check saved.status == ecsSucceeded
      check vm.workspaceEditStage.val == wesClean
      check vm.inspector.pendingSourceEdits.val.len == 0
      check recorder.reloadedStories.anyIt(it == story)

      vm.inspector.pendingSourceEdits.val = @[planFor(schemaFile, "padding",
        "24px", "32px", "components.card.padding")]
      vm.workspaceEditStage.val = wesDirty
      vm.workspaceEditAdapter = WorkspaceEditAdapter(schema: schema)
      vm.sourceAdapterReady.val = true
      let failed = vm.runEditorCommand(eckSave)
      check failed.status == ecsFailed
      check vm.workspaceEditDiagnostics.val.anyIt(
        it.kind == wedMissingOperation)

      check vm.telemetryEvents.val.anyIt(
        it.budgetKind == epbkStorySelection and
        it.detail.contains("story-selection:"))
      check vm.telemetryEvents.val.anyIt(
        it.budgetKind == epbkElementSelection and
        it.detail.contains("element-selection:"))
      check vm.telemetryEvents.val.anyIt(
        it.budgetKind == epbkPropertyEditPreview and
        it.detail == "source-plan:padding")
      check vm.telemetryEvents.val.anyIt(
        it.budgetKind == epbkSaveReload and
        it.detail.contains("preview-reload:"))
      check vm.telemetryEvents.val.anyIt(
        it.budgetKind == epbkSaveReload and
        it.detail.contains("bridge-error:"))
      dispose()

  test "workspace_dev_server_applies_transactional_source_writes":
    createRoot proc(dispose: proc()) =
      let root = tempWorkspaceDir("dev-server")
      defer: removeDir(root)
      let schemaFile = root / "component.schema"
      let generatedFile = root / "generated/component_view.nim"
      atomicWrite(schemaFile, "padding=16px\ncolor=#111827")
      createDir(root / "generated")

      let schema = @[
        WorkspaceEditableSchemaEntry(key: "components.card.padding",
          kind: wskSourceMap, file: schemaFile, path: "card.padding",
          story: writeStory, property: "padding"),
        WorkspaceEditableSchemaEntry(key: "components.card.color",
          kind: wskSourceMap, file: schemaFile, path: "card.color",
          story: writeStory, property: "color")
      ]
      let recorder = WorkspaceEditRecorder()
      var adapter = adapterFor(root, schema, recorder = recorder)
      let bridgeArtifact = root / "dist/back-office-editor/editor.js"
      adapter.writeFile = proc(file, content: string): WorkspaceOperationResult =
        atomicWrite(file, content)
        okOp(
          affectedStories = @[StoryRef(group: "Operational components",
            name: "Topbar", kind: skComponent)],
          fullReload = true,
          generatedArtifacts = @[bridgeArtifact],
          requiredTestCommands = @[
            "node tools/serve_editor_dev_bridge.mjs"
          ],
          reviewDiagnostics = @[WorkspaceEditDiagnostic(
            kind: wedReviewFailed,
            message: "bridge write review evidence preserved",
            file: file)])
      adapter.regenerate = proc(keys: seq[string]): WorkspaceOperationResult =
        atomicWrite(generatedFile, keys.join("\n"))
        okOp(affectedStories = @[writeStory],
          generatedArtifacts = @[generatedFile],
          reviewDiagnostics = @[WorkspaceEditDiagnostic(
            kind: wedReviewFailed,
            message: "review info: generated schema artifact inspected",
            file: generatedFile)])
      adapter.compile = proc(stories: seq[StoryRef]): WorkspaceOperationResult =
        okOp(requiredTestCommands = @[
          "direnv exec /home/zahary/metacraft/isonim nim c -r tests/test_editor_viewmodels.nim",
          "direnv exec /home/zahary/metacraft/isonim just test-browser-editor-consumer"
        ])

      let vm = createEditorVM(newEditorWorkspace(
        title = "M42 dev server transaction",
        storyGroups = @[StoryGroup(name: "DestinationCard", kind: skComponent,
          items: @[StoryItem(name: "Default", kind: skComponent,
            group: "DestinationCard")])],
        permissions = EditorWorkspacePermissions(readSource: true,
          writeSource: true),
        editAdapter = adapter,
        initialStory = some(writeStory)))
      vm.inspector.pendingSourceEdits.val = @[
        planFor(schemaFile, "padding", "16px", "24px",
          "components.card.padding"),
        planFor(schemaFile, "color", "#111827", "#F8FAFC",
          "components.card.color")
      ]
      vm.workspaceEditStage.val = wesDirty

      let saved = vm.applyWorkspaceFileEdits()
      check saved.ok
      check readFile(schemaFile) == "padding=24px\ncolor=#F8FAFC"
      check readFile(generatedFile).contains("components.card.padding")
      check saved.patches.len == 2
      check saved.patches[0].beforeContent.contains("padding=16px")
      check saved.patches[0].afterContent.contains("padding=24px")
      check bridgeArtifact in saved.generatedArtifacts
      check generatedFile in saved.generatedArtifacts
      check saved.requiredTestCommands.anyIt(it.contains(
        "serve_editor_dev_bridge.mjs"))
      check saved.requiredTestCommands.anyIt(it.contains("test_editor_viewmodels.nim"))
      check saved.reviewDiagnostics.anyIt(
        it.message == "bridge write review evidence preserved")
      check saved.reviewDiagnostics.anyIt(it.file == generatedFile)
      check saved.affectedStories.anyIt(it.group == "Operational components" and
        it.name == "Topbar")
      check saved.fullReload
      check vm.workspaceEditAffectedStories.val.len == 2
      check vm.workspaceEditAffectedStories.val.anyIt(
        it.group == "Operational components" and it.name == "Topbar")
      check vm.workspaceEditFullReload.val
      check recorder.reloadedStories.len == 2
      check recorder.reloadedStories.anyIt(
        it.group == "Operational components" and it.name == "Topbar")
      check recorder.fullReloadSeen
      check vm.livePreviewReloadGeneration.val == 1

      vm.inspector.pendingSourceEdits.val = @[
        planFor(schemaFile, "padding", "24px", "32px",
          "components.card.padding")
      ]
      atomicWrite(schemaFile, "padding=28px\ncolor=#F8FAFC")
      let conflicted = vm.applyWorkspaceFileEdits()
      check not conflicted.ok
      check conflicted.diagnostics.anyIt(it.kind == wedSourceConflict)
      check readFile(schemaFile).contains("padding=28px")
      dispose()

  test "bridge_client_state_machine_and_protocol_contract":
    let contract = negotiatedWriteBridgeContract(
      "isonim.write-bridge.v1",
      @["status", "read", "dry-run", "apply", "save", "revert",
        "conflict-detection", "atomic-write", "rollback", "path-allowlist",
        "symlink-denial", "structured-logs"],
      maxFileBytes = 1024 * 1024)
    check contract.supportsStructuredDiagnostics
    check contract.maxFileBytes == 1024 * 1024
    check "rollback" in contract.capabilities
    check contract.missingCapabilities.len == 0
    check contract.canRead
    check contract.canWrite

    let degraded = negotiatedWriteBridgeContract(
      "isonim.write-bridge.v1",
      @["status", "read", "apply", "structured-logs"])
    check not degraded.canRead
    check not degraded.canWrite
    check "atomic-write" in degraded.missingCapabilities
    let degradedDiagnostics = writeBridgeContractDiagnostics(degraded)
    check degradedDiagnostics.len == 1
    check writeBridgeStateFromSignals(true, true, false, true, false,
      wesClean, degradedDiagnostics) == wbcsDegraded

    let unsupported = negotiatedWriteBridgeContract(
      "isonim.write-bridge.v0", requiredWriteBridgeCapabilities())
    check not unsupported.canRead
    check not unsupported.canWrite
    check writeBridgeContractDiagnostics(unsupported)[0].kind ==
      wedBridgeUnavailable

    check writeBridgeStateFromSignals(false, false, false, false, false,
      wesClean, @[]) == wbcsReadOnly
    check writeBridgeStateFromSignals(true, false, false, false, false,
      wesClean, @[]) == wbcsOffline
    check writeBridgeStateFromSignals(true, true, false, false, false,
      wesClean, @[]) == wbcsConnecting
    check writeBridgeStateFromSignals(true, true, false, false, false,
      wesClean, @[WorkspaceEditDiagnostic(kind: wedBridgeUnavailable,
        message: "health check failed")]) == wbcsDegraded
    check writeBridgeStateFromSignals(true, true, true, false, false,
      wesClean, @[]) == wbcsStaged
    check writeBridgeStateFromSignals(true, true, false, true, false,
      wesClean, @[]) == wbcsWritable
    check writeBridgeStateFromSignals(true, true, false, true, false,
      wesApplying, @[]) == wbcsSaving
    check writeBridgeStateFromSignals(true, true, false, true, false,
      wesClean, @[WorkspaceEditDiagnostic(kind: wedExternalChange,
        message: "stale revision")]) == wbcsConflict
    check writeBridgeStateFromSignals(true, true, false, true, false,
      wesFailed, @[]) == wbcsFailed
    check writeBridgeStateFromSignals(true, true, false, true, true,
      wesClean, @[]) == wbcsRecovered

  test "bridge_client_recovers_after_failed_save_retry":
    createRoot proc(dispose: proc()) =
      let root = tempWorkspaceDir("bridge-recovered")
      defer: removeDir(root)
      let schemaFile = root / "component.schema"
      atomicWrite(schemaFile, "padding=16px")
      let schema = @[
        WorkspaceEditableSchemaEntry(key: "components.card.padding",
          kind: wskSourceMap, file: schemaFile, path: "card.padding",
          story: writeStory, property: "padding")
      ]
      let recorder = WorkspaceEditRecorder()
      var failWrite = true
      let adapter = adapterFor(root, schema, recorder = recorder)
      adapter.writeFile = proc(file, content: string): WorkspaceOperationResult =
        if failWrite:
          return failOp(wedWriteFailed, "simulated bridge failure", file)
        atomicWrite(file, content)
        okOp()
      let vm = createEditorVM(newEditorWorkspace(
        title = "M48 bridge recovery",
        storyGroups = @[StoryGroup(name: "DestinationCard", kind: skComponent,
          items: @[StoryItem(name: "Default", kind: skComponent,
            group: "DestinationCard")])],
        permissions = EditorWorkspacePermissions(readSource: true,
          writeSource: true),
        editAdapter = adapter,
        initialStory = some(writeStory)))
      check vm.writeBridgeClientState() == wbcsWritable

      vm.inspector.pendingSourceEdits.val = @[
        planFor(schemaFile, "padding", "16px", "24px",
          "components.card.padding")
      ]
      vm.workspaceEditStage.val = wesDirty
      let failed = vm.applyWorkspaceFileEdits()
      check not failed.ok
      check vm.writeBridgeClientState() == wbcsFailed
      check readFile(schemaFile) == "padding=16px"

      failWrite = false
      let saved = vm.applyWorkspaceFileEdits()
      check saved.ok
      check readFile(schemaFile) == "padding=24px"
      check vm.writeBridgeClientState() == wbcsRecovered
      dispose()

  test "live_preview_restores_selection_after_real_file_write":
    createRoot proc(dispose: proc()) =
      let root = tempWorkspaceDir("selection-reload")
      defer: removeDir(root)
      let schemaFile = root / "component.schema"
      atomicWrite(schemaFile, "display=grid")
      let recorder = WorkspaceEditRecorder()
      let adapter = adapterFor(root, @[
        WorkspaceEditableSchemaEntry(key: "components.topbar.display",
          kind: wskSourceMap, file: schemaFile, path: "topbar.display",
          story: writeStory, property: "display")
      ], recorder = recorder)
      let selected = ElementRef(id: "component-topbar",
        sourceKey: "component-topbar", schemaKey: "components.topbar",
        tag: "header", sourceFile: schemaFile, sourceLine: 1,
        ancestorIds: @["component-topbar"], ancestors: @["header"],
        properties: @[PropertyInfo(name: "display", value: "grid",
          origin: poConstant, originDetail: "schema:components.topbar.display",
          sourceFile: schemaFile, sourceLine: 1,
          schemaKey: "components.topbar.display")])
      let vm = createEditorVM(newEditorWorkspace(
        title = "M42 selection restore",
        storyGroups = @[StoryGroup(name: "DestinationCard", kind: skComponent,
          items: @[StoryItem(name: "Default", kind: skComponent,
            group: "DestinationCard")])],
        permissions = EditorWorkspacePermissions(readSource: true,
          writeSource: true),
        editAdapter = adapter,
        initialStory = some(writeStory),
        initialInspectorElement = some(selected)))

      check vm.inspector.selectedElement.val.id == "component-topbar"
      vm.inspector.pendingSourceEdits.val = @[
        planFor(schemaFile, "display", "grid", "flex",
          "components.topbar.display")
      ]
      let saved = vm.applyWorkspaceFileEdits()
      check saved.ok
      check readFile(schemaFile) == "display=flex"
      check vm.inspector.selectedElement.val.id == "component-topbar"
      check vm.inspector.selectedElement.val.sourceKey == "component-topbar"
      check vm.livePreviewReloadGeneration.val == 1
      check recorder.reloadedStories.len == 1
      dispose()

  test "canvas_direct_manipulation_routes_to_owned_source_edits":
    createRoot proc(dispose: proc()) =
      func span(file: string; line: int): SourceSpan =
        SourceSpan(file: file, line: line, column: 1,
          endLine: line, endColumn: 30)
      func prop(name, value, file, key: string; line: int): PropertyInfo =
        PropertyInfo(name: name, value: value, origin: poConstant,
          originDetail: "schema:" & key, sourceFile: file, sourceLine: line,
          schemaKey: key)

      let root = tempWorkspaceDir("direct-canvas")
      defer: removeDir(root)
      let layoutFile = root / "card.layout.schema"
      let tokenFile = root / "tokens.schema"
      let fixtureFile = root / "card.fixture"
      let copyFile = root / "card.copy"
      atomicWrite(layoutFile, "width=320px")
      atomicWrite(tokenFile, "gap=12px")
      atomicWrite(fixtureFile, "order=0")
      atomicWrite(copyFile, "title=Old title")

      let schema = DesignSystemSchema(
        schemaVersion: 1,
        projectId: "direct-canvas-fixture",
        ownerPackage: "isonim-tests",
        frameworkContract: "isonim-editor-design-schema-v1",
        nodes: @[
          DesignSchemaNode(key: "components.card.width",
            kind: dsnStyleDefinition, component: "Card", property: "width",
            value: "320px", sourceSpan: span(layoutFile, 1)),
          DesignSchemaNode(key: "tokens.card.gap",
            kind: dsnComponentToken, component: "Card", property: "gap",
            value: "12px", sourceSpan: span(tokenFile, 1)),
          DesignSchemaNode(key: "fixtures.card.order",
            kind: dsnStoryFixture, component: "Card", property: "order",
            value: "0", sourceSpan: span(fixtureFile, 1)),
          DesignSchemaNode(key: "fixtures.card.title",
            kind: dsnStoryFixture, component: "Card", property: "text",
            value: "Old title", sourceSpan: span(copyFile, 1))
        ],
        sourceOwnership: @[
          DesignSourceOwnership(elementSourceKey: "card.root",
            property: "width", schemaKey: "components.card.width",
            nodeKey: "components.card.width", sourceSpan: span(layoutFile, 1)),
          DesignSourceOwnership(elementSourceKey: "card.root",
            property: "gap", schemaKey: "tokens.card.gap",
            nodeKey: "tokens.card.gap", sourceSpan: span(tokenFile, 1)),
          DesignSourceOwnership(elementSourceKey: "card.item",
            property: "order", schemaKey: "fixtures.card.order",
            nodeKey: "fixtures.card.order", sourceSpan: span(fixtureFile, 1)),
          DesignSourceOwnership(elementSourceKey: "card.title",
            property: "text", schemaKey: "fixtures.card.title",
            nodeKey: "fixtures.card.title", sourceSpan: span(copyFile, 1))
        ])
      let recorder = WorkspaceEditRecorder()
      let adapter = adapterFor(root, @[
        WorkspaceEditableSchemaEntry(key: "components.card.width",
          kind: wskSourceMap, file: layoutFile, path: "card.width",
          story: writeStory, property: "width"),
        WorkspaceEditableSchemaEntry(key: "tokens.card.gap",
          kind: wskToken, file: tokenFile, path: "card.gap",
          story: writeStory, property: "gap"),
        WorkspaceEditableSchemaEntry(key: "fixtures.card.order",
          kind: wskStoryFixture, file: fixtureFile, path: "card.items.order",
          story: writeStory, property: "order"),
        WorkspaceEditableSchemaEntry(key: "fixtures.card.title",
          kind: wskStoryFixture, file: copyFile, path: "card.title",
          story: writeStory, property: "text")
      ], recorder = recorder)
      let vm = createEditorVM(newEditorWorkspace(
        title = "M40 direct canvas workspace",
        storyGroups = @[StoryGroup(name: "DestinationCard", kind: skComponent,
          items: @[StoryItem(name: "Default", kind: skComponent,
            group: "DestinationCard")])],
        permissions = EditorWorkspacePermissions(readSource: true,
          writeSource: true, createVariant: true, duplicate: true,
          delete: true),
        sourceAdapterReady = true,
        initialStory = some(writeStory),
        editAdapter = adapter,
        designSystemSchema = schema))

      check vm.selectInspectorElement(ElementRef(id: "root",
        sourceKey: "card.root", schemaKey: "components.card", tag: "article",
        sourceFile: layoutFile, sourceLine: 1,
        properties: @[
          prop("width", "320px", layoutFile, "components.card.width", 1),
          prop("gap", "12px", tokenFile, "tokens.card.gap", 1)
        ]))
      let resized = vm.applyDirectCanvasOperation(DirectCanvasOperation(
        kind: dcokResize, property: "width", value: "360px",
        handle: "se", measurement: "width=360px"))
      check resized.ok
      check resized.sourceEdit.schemaKey == "components.card.width"
      check resized.sourceEdit.originDetail.startsWith("layout-style:")
      check resized.sourceEdit.planKind == cspStructuredSchemaUpdate

      let spaced = vm.applyDirectCanvasOperation(DirectCanvasOperation(
        kind: dcokSpacing, property: "gap", value: "24px",
        handle: "spacing", measurement: "gap=24px"))
      check spaced.ok
      check spaced.sourceEdit.schemaKey == "tokens.card.gap"
      check spaced.sourceEdit.planKind == cspTokenUpdate

      check vm.selectInspectorElement(ElementRef(id: "item",
        sourceKey: "card.item", schemaKey: "components.card.item",
        tag: "li", sourceFile: fixtureFile, sourceLine: 1,
        properties: @[prop("order", "0", fixtureFile,
          "fixtures.card.order", 1)]))
      let reordered = vm.applyDirectCanvasOperation(DirectCanvasOperation(
        kind: dcokReorder, property: "order", oldValue: "0",
        value: "2", fromIndex: 0, toIndex: 2,
        sourceKey: "card.item", measurement: "order=2"))
      check reordered.ok
      check reordered.sourceEdit.schemaKey == "fixtures.card.order"
      check reordered.sourceEdit.originDetail.startsWith("layout-fixture:")

      check vm.selectInspectorElement(ElementRef(id: "title",
        sourceKey: "card.title", schemaKey: "components.card.title",
        tag: "h2", sourceFile: copyFile, sourceLine: 1,
        properties: @[prop("text", "Old title", copyFile,
          "fixtures.card.title", 1)]))
      let editedText = vm.applyDirectCanvasInlineText("New title")
      check editedText.ok
      check editedText.sourceEdit.schemaKey == "fixtures.card.title"
      check editedText.sourceEdit.originDetail.startsWith("direct-inline-text:")
      check vm.inspector.pendingSourceEdits.val.len == 4
      check vm.inspector.undoStack.val.len == 4
      check vm.workspaceEditStage.val == wesDirty

      check vm.inspector.undoCssPropertyEdit()
      check vm.inspector.pendingSourceEdits.val.len == 3
      check vm.inspector.redoCssPropertyEdit()
      check vm.inspector.pendingSourceEdits.val.len == 4

      let saved = vm.runEditorCommand(eckSave)
      check saved.status == ecsSucceeded
      check readFile(layoutFile).contains("360px")
      check readFile(tokenFile).contains("24px")
      check readFile(fixtureFile).contains("2")
      check readFile(copyFile).contains("New title")
      check vm.inspector.pendingSourceEdits.val.len == 0
      check vm.workspaceEditStage.val == wesClean
      check recorder.reviewCount == 1

      check vm.selectInspectorElement(ElementRef(id: "root",
        sourceKey: "card.root", schemaKey: "components.card", tag: "article",
        sourceFile: layoutFile, sourceLine: 1,
        properties: @[
          prop("width", "360px", layoutFile, "components.card.width", 1),
          prop("gap", "24px", tokenFile, "tokens.card.gap", 1)
        ]))

      let copied = vm.applyDirectCanvasOperation(DirectCanvasOperation(
        kind: dcokContextCommand, command: dcccCopyStyles))
      check copied.ok
      check copied.operation.property == "width"
      check copied.operation.value == "360px"
      check vm.inspector.pendingSourceEdits.val.len == 0

      proc checkContextPlan(command: DirectCanvasContextCommand;
          value: string) =
        let planned = vm.applyDirectCanvasOperation(DirectCanvasOperation(
          kind: dcokContextCommand, command: command, property: "width",
          value: value, oldValue: "360px", sourceKey: "card.root"))
        check planned.ok
        check planned.sourceEdit.schemaKey == "components.card.width"
        check planned.sourceEdit.originDetail.startsWith("direct-context:")
        check planned.sourceEdit.reversible
        check vm.inspector.pendingSourceEdits.val.len == 1
        check vm.inspector.undoStack.val.len >= 1

      checkContextPlan(dcccPasteStyles, "380px")
      check vm.inspector.undoCssPropertyEdit()
      check vm.inspector.pendingSourceEdits.val.len == 0
      check vm.inspector.redoCssPropertyEdit()
      check vm.inspector.pendingSourceEdits.val.len == 1
      checkContextPlan(dcccReset, "320px")
      checkContextPlan(dcccDetach, "360px")
      checkContextPlan(dcccPromote, "360px")
      checkContextPlan(dcccWrap, "360px")

      for command in [dcccCreateVariant, dcccDuplicate, dcccDelete,
          dcccOpenSource]:
        let ran = vm.applyDirectCanvasOperation(DirectCanvasOperation(
          kind: dcokContextCommand, command: command, sourceKey: "card.root"))
        check ran.ok
        check ran.commandState.status == ecsSucceeded

      let asked = vm.applyDirectCanvasOperation(DirectCanvasOperation(
        kind: dcokContextCommand, command: dcccAskAi,
        sourceKey: "card.root"))
      check asked.ok
      check vm.editMode.val == emComment
      check vm.chat.inputText.val.contains("Ask AI about selection:")

      let reverted = vm.runEditorCommand(eckRevert)
      check reverted.status == ecsSucceeded
      check vm.inspector.pendingSourceEdits.val.len == 0
      check vm.inspector.undoStack.val.len == 0
      check vm.workspaceEditStage.val == wesClean
      dispose()

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
      check adapter.hasCapability(vacPathEditing)
      check adapter.hasCapability(vacPathDataEditing)
      check adapter.unsupportedAdvancedOperations.anyIt(
        it.contains("clipping"))
      let result = vm.unsupportedVectorOperation("SVG filter and mask editing")
      check not result.ok
      check result.diagnostics.len == 1
      check result.diagnostics[0].kind == vdkUnsupportedOperation
      check result.diagnostics[0].message.contains("mature supplemental path library")
      check vm.vectorEditor.diagnostics.val[0].kind == vdkUnsupportedOperation
      dispose()

  test "vector_path_viewmodel_commands_and_export_fidelity":
    createRoot proc(dispose: proc()) =
      let root = tempWorkspaceDir("vector-m47")
      defer: removeDir(root)

      let svgFile = root / "symbols.schema"
      atomicWrite(svgFile,
        "<svg xmlns=\"http://www.w3.org/2000/svg\" viewBox=\"0 0 48 48\"><path id=\"path-1\" d=\"M6 10 L18 22 L35 7\" /></svg>")
      let recorder = WorkspaceEditRecorder()
      let schema = @[
        WorkspaceEditableSchemaEntry(key: "symbols.polished.svg",
          kind: wskSvgSymbol, file: svgFile, path: "symbols.polished.svg",
          story: writeStory, property: "svgContent")
      ]
      let vm = createEditorVM(newEditorWorkspace(
        title = "M47 vector path workspace",
        storyGroups = @[],
        vectorSymbols = @[
          VectorSymbol(name: "Polished", category: "Icons",
            svgContent: "<svg xmlns=\"http://www.w3.org/2000/svg\" viewBox=\"0 0 48 48\"><path id=\"path-1\" d=\"M6 10 L18 22 L35 7\" /></svg>",
            width: 48, height: 48)
        ],
        permissions = EditorWorkspacePermissions(readSource: true,
          writeSource: true),
        editAdapter = adapterFor(root, schema, recorder = recorder)))

      check vm.selectVectorSymbol(0)
      let importedPath = vm.vectorEditor.document.val.objects[0]
      check importedPath.pathData == "M6 10 L18 22 L35 7"
      check importedPath.pathNodes.len == 3
      check importedPath.pathNodes[0].x == 6
      check importedPath.pathNodes[0].y == 10
      check importedPath.pathNodes[1].x == 18
      check importedPath.pathNodes[1].y == 22
      check importedPath.pathNodes[2].x == 35
      check importedPath.pathNodes[2].y == 7
      check importedPath.pathNodes != defaultCheckPathNodes()
      check vm.vectorEditor.document.val.exportVectorDocumentSvg.contains(
        "M6 10 L18 22 L35 7")
      check vm.selectVectorPathNodes("path-1", @["node-0"]).ok
      check vm.selectVectorPathNodes("path-1", @["node-1"], append = true).ok
      check vm.vectorEditor.document.val.objects[0].pathNodes.countIt(it.selected) == 2
      check vm.moveVectorPathNodes("path-1", @["node-0"], 2, 3).ok
      check vm.insertVectorPathNode("path-1", "node-1", 14, 15).ok
      check vm.convertVectorPathNodes("path-1", @["node-1"], ntSmooth).ok
      check vm.dragVectorPathHandle("path-1", "node-1", vhkOut, 19, 12).ok
      check vm.deleteVectorPathNodes("path-1", @["node-3"]).ok
      let editedPath = vm.vectorEditor.document.val.objects[0]
      check editedPath.pathNodes.len == 3
      check editedPath.pathNodes.anyIt(it.id == "node-1" and it.nodeType == ntSmooth)
      check editedPath.pathData.contains("C")
      check vm.undoVectorEdit()
      check vm.vectorEditor.document.val.objects[0].pathNodes.len == 4
      check vm.redoVectorEdit()
      check vm.vectorEditor.document.val.objects[0].pathNodes.len == 3

      var doc = vm.vectorEditor.document.val
      for item in [
        VectorObject(id: "rect-a", name: "A", kind: vskRect, layerId: "base",
          x: 3, y: 9, width: 10, height: 8, fill: "none",
          stroke: "currentColor", strokeWidth: 1, source: doc.source,
          a11y: doc.a11y),
        VectorObject(id: "rect-b", name: "B", kind: vskRect, layerId: "base",
          x: 30, y: 14, width: 10, height: 8, fill: "none",
          stroke: "currentColor", strokeWidth: 1, source: doc.source,
          a11y: doc.a11y),
        VectorObject(id: "rect-c", name: "C", kind: vskRect, layerId: "base",
          x: 60, y: 21, width: 10, height: 8, fill: "none",
          stroke: "currentColor", strokeWidth: 1, source: doc.source,
          a11y: doc.a11y)
      ]:
        doc.objects.add item
        doc.layers[0].objectIds.add item.id
      doc.selectedIds = @["rect-a", "rect-b", "rect-c"]
      vm.vectorEditor.document.val = doc

      check vm.alignVectorSelection(vaTop).ok
      check vm.vectorEditor.document.val.objects.filterIt(it.id in
        @["rect-a", "rect-b", "rect-c"]).allIt(it.y == 9)
      check vm.distributeVectorSelection(vdaHorizontal).ok
      check vm.reorderVectorSelection(vzoBringToFront).ok
      check vm.vectorEditor.document.val.layers[0].objectIds[^1] == "rect-c"
      check vm.nudgeVectorSelection(1.5, 2.5).ok
      check vm.snapVectorSelection(4).ok
      check vm.vectorEditor.document.val.objects.anyIt(it.id == "rect-a" and
        it.x == 4 and it.y == 12)
      check vm.groupVectorSelection().ok
      let groupId = vm.vectorEditor.document.val.selectedIds[0]
      check vm.vectorEditor.document.val.objects.anyIt(it.id == groupId and
        it.kind == vskGroup)
      check vm.ungroupVectorSelection().ok
      check vm.vectorEditor.document.val.selectedIds.len == 3

      let curvedSvg =
        "<svg xmlns=\"http://www.w3.org/2000/svg\" viewBox=\"0 0 80 40\"><path id=\"curve\" d=\"M5 10 C15 2 30 2 40 10 L60 20\" fill=\"none\" stroke=\"#123456\" /></svg>"
      let curved = importVectorDocumentSvg(VectorSymbol(name: "Curve",
        category: "Icons", svgContent: curvedSvg, width: 80, height: 40),
        curvedSvg)
      let curve = curved.objects.filterIt(it.id == "curve")[0]
      check curve.pathData == "M5 10 C15 2 30 2 40 10 L60 20"
      check curve.pathNodes.len == 3
      check curve.pathNodes[0].x == 5
      check curve.pathNodes[0].y == 10
      check curve.pathNodes[0].outX == 15
      check curve.pathNodes[0].outY == 2
      check curve.pathNodes[1].inX == 30
      check curve.pathNodes[1].inY == 2
      check curve.pathNodes[1].x == 40
      check curve.pathNodes[1].y == 10
      check curve.pathNodes[2].x == 60
      check curve.pathNodes[2].y == 20
      check curve.pathNodes != defaultCheckPathNodes()

      let representative =
        "<svg xmlns=\"http://www.w3.org/2000/svg\" viewBox=\"0 0 100 80\" width=\"100\" height=\"80\"><defs><linearGradient id=\"paint\"><stop offset=\"0%\" stop-color=\"#60A5FA\"/></linearGradient><clipPath id=\"clip\"><rect x=\"0\" y=\"0\" width=\"80\" height=\"60\"/></clipPath></defs><path id=\"compound\" d=\"M1.25 2.5C10 20 30 20 42.75 4Z M50 10L70 30\" fill=\"url(#paint)\" stroke=\"#123456\" stroke-width=\"1.5\" stroke-dasharray=\"2 3\" stroke-linecap=\"round\" stroke-linejoin=\"bevel\" transform=\"rotate(12 20 20)\" clip-path=\"url(#clip)\"/></svg>"
      let imported = importVectorDocumentSvg(VectorSymbol(name: "Fidelity",
        category: "Icons", svgContent: representative, width: 100, height: 80),
        representative)
      check imported.viewBox == "0 0 100 80"
      var compoundIndex = -1
      for i, obj in imported.objects:
        if obj.id == "compound":
          compoundIndex = i
      check compoundIndex >= 0
      let compound = imported.objects[compoundIndex]
      check compound.pathData.contains("42.75")
      check compound.pathNodes.len == 0
      check compound.strokeWidth == 1.5
      check compound.dashArray == "2 3"
      check compound.strokeCap == scRound
      check compound.strokeJoin == sjBevel
      check compound.rotation == 12
      let compoundSvg = imported.exportVectorDocumentSvg
      check compoundSvg.contains("M1.25 2.5C10 20 30 20 42.75 4Z M50 10L70 30")
      check not compoundSvg.contains("M4.0 12.0L9.0 17.0L20.0 6.0")
      let pathDiagnostics = imported.diagnoseUnsupportedVectorPathEditing()
      check pathDiagnostics.anyIt(it.kind == vdkUnsupportedOperation and
        it.objectId == "compound" and it.message.contains("pathData is preserved"))
      vm.vectorEditor.document.val = imported
      let rejectedPathEdit = vm.moveVectorPathNodes("compound", @["node-0"], 1, 1)
      check not rejectedPathEdit.ok
      check rejectedPathEdit.diagnostics.anyIt(it.kind == vdkUnsupportedOperation)
      check vm.vectorEditor.document.val.objects[compoundIndex].pathData ==
        compound.pathData
      check imported.symbols[0].svgContent.contains("linearGradient")
      let unsupported = representative.diagnoseUnsupportedVectorSvgFeatures(
        "symbols.fidelity.svg")
      check unsupported.anyIt(it.kind == vdkUnsupportedOperation and
        it.message.contains("clip"))
      let rejected = vm.commitBrowserVectorSvg(representative)
      check not rejected.ok
      check rejected.diagnostics.anyIt(it.kind == vdkUnsupportedOperation)
      check vm.vectorEditor.undoStack.val.len > 0
      check vm.inspector.pendingSourceEdits.val.len > 0
      dispose()

  test "vector_editor_rejects_headless_commits_for_unsupported_svg_sources":
    createRoot proc(dispose: proc()) =
      let root = tempWorkspaceDir("vector-unsupported-source")
      defer: removeDir(root)

      let svgFile = root / "symbols.schema"
      let unsupportedSvg =
        "<svg xmlns=\"http://www.w3.org/2000/svg\" viewBox=\"0 0 64 64\"><defs><clipPath id=\"clip\"><rect id=\"clip-rect\" x=\"0\" y=\"0\" width=\"48\" height=\"48\" /></clipPath><mask id=\"fade\"><rect id=\"mask-rect\" width=\"64\" height=\"64\" fill=\"white\" /></mask><filter id=\"blur\"><feGaussianBlur stdDeviation=\"2\" /></filter><pattern id=\"dots\" width=\"4\" height=\"4\"><circle id=\"dot\" cx=\"1\" cy=\"1\" r=\"1\" /></pattern></defs><foreignObject id=\"html\" width=\"10\" height=\"10\"></foreignObject><rect id=\"painted\" x=\"4\" y=\"4\" width=\"20\" height=\"20\" fill=\"url(#dots)\" clip-path=\"url(#clip)\" mask=\"url(#fade)\" filter=\"url(#blur)\" /></svg>"
      atomicWrite(svgFile, unsupportedSvg)
      let recorder = WorkspaceEditRecorder()
      let schema = @[
        WorkspaceEditableSchemaEntry(key: "symbols.unsafe.svg",
          kind: wskSvgSymbol, file: svgFile, path: "symbols.unsafe.svg",
          story: writeStory, property: "svgContent")
      ]
      let vm = createEditorVM(newEditorWorkspace(
        title = "M47 unsupported vector workspace",
        storyGroups = @[],
        vectorSymbols = @[
          VectorSymbol(name: "Unsafe", category: "Icons",
            svgContent: unsupportedSvg, width: 64, height: 64)
        ],
        permissions = EditorWorkspacePermissions(readSource: true,
          writeSource: true),
        editAdapter = adapterFor(root, schema, recorder = recorder)))

      check vm.selectVectorSymbol(0)
      check vm.vectorEditor.diagnostics.val.anyIt(
        it.kind == vdkUnsupportedOperation and it.message.contains("clip"))
      check vm.vectorEditor.diagnostics.val.anyIt(
        it.kind == vdkUnsupportedOperation and it.message.contains("mask"))
      check vm.vectorEditor.diagnostics.val.anyIt(
        it.kind == vdkUnsupportedOperation and it.message.contains("filter"))
      check vm.vectorEditor.diagnostics.val.anyIt(
        it.kind == vdkUnsupportedOperation and it.message.contains("pattern"))
      check vm.vectorEditor.diagnostics.val.anyIt(
        it.kind == vdkUnsupportedOperation and
        it.message.contains("foreignobject"))

      let beforeSvg = vm.vectorEditor.document.val.exportVectorDocumentSvg
      let rejectedFill = vm.setVectorObjectProperty(VectorPropertyEditRequest(
        objectId: "painted", kind: vpkFill, value: "#EF4444"))
      check not rejectedFill.ok
      check rejectedFill.diagnostics.anyIt(
        it.kind == vdkUnsupportedOperation and it.message.contains("clip"))
      check vm.vectorEditor.document.val.exportVectorDocumentSvg == beforeSvg
      check vm.inspector.pendingSourceEdits.val.len == 0
      check vm.vectorEditor.undoStack.val.len == 0
      check vm.workspaceEditStage.val == wesClean
      check not vm.commandAvailable(eckSave)

      let rejectedViewBox = vm.setVectorDocumentViewBox("0 0 128 128")
      check not rejectedViewBox.ok
      check vm.vectorEditor.document.val.viewBox == "0 0 64 64"
      check vm.inspector.pendingSourceEdits.val.len == 0

      check vm.selectVectorObjects(@["painted"])
      let rejectedNudge = vm.nudgeVectorSelection(4, 5)
      check not rejectedNudge.ok
      check rejectedNudge.diagnostics.anyIt(
        it.kind == vdkUnsupportedOperation and it.message.contains("mask"))
      check vm.inspector.pendingSourceEdits.val.len == 0

      let beforeBrowserDoc = vm.vectorEditor.document.val
      let beforeBrowserUndo = vm.vectorEditor.undoStack.val.len
      let beforeBrowserPending = vm.inspector.pendingSourceEdits.val.len
      let beforeBrowserStage = vm.workspaceEditStage.val
      let fabricDroppedUnsupported =
        "<svg xmlns=\"http://www.w3.org/2000/svg\" viewBox=\"0 0 64 64\"><rect id=\"fabric-clean\" x=\"4\" y=\"4\" width=\"20\" height=\"20\" fill=\"#EF4444\" /></svg>"
      let rejectedBrowser = vm.commitBrowserVectorSvg(fabricDroppedUnsupported)
      check not rejectedBrowser.ok
      check rejectedBrowser.diagnostics.anyIt(
        it.kind == vdkUnsupportedOperation and it.message.contains("clip"))
      check rejectedBrowser.diagnostics.anyIt(
        it.kind == vdkUnsupportedOperation and it.message.contains("mask"))
      check vm.vectorEditor.document.val == beforeBrowserDoc
      check vm.vectorEditor.undoStack.val.len == beforeBrowserUndo
      check vm.inspector.pendingSourceEdits.val.len == beforeBrowserPending
      check vm.workspaceEditStage.val == beforeBrowserStage
      check not vm.commandAvailable(eckSave)
      check readFile(svgFile) == unsupportedSvg
      dispose()

  test "vector_editor_allows_headless_commits_for_supported_svg_sources":
    createRoot proc(dispose: proc()) =
      let root = tempWorkspaceDir("vector-supported-source")
      defer: removeDir(root)

      let svgFile = root / "symbols.schema"
      let supportedSvg =
        "<svg xmlns=\"http://www.w3.org/2000/svg\" viewBox=\"0 0 32 32\"><rect id=\"box\" x=\"4\" y=\"4\" width=\"12\" height=\"12\" fill=\"#111827\" /></svg>"
      atomicWrite(svgFile, supportedSvg)
      let recorder = WorkspaceEditRecorder()
      let schema = @[
        WorkspaceEditableSchemaEntry(key: "symbols.safe.svg",
          kind: wskSvgSymbol, file: svgFile, path: "symbols.safe.svg",
          story: writeStory, property: "svgContent")
      ]
      let vm = createEditorVM(newEditorWorkspace(
        title = "M47 supported vector workspace",
        storyGroups = @[],
        vectorSymbols = @[
          VectorSymbol(name: "Safe", category: "Icons",
            svgContent: supportedSvg, width: 32, height: 32)
        ],
        permissions = EditorWorkspacePermissions(readSource: true,
          writeSource: true),
        editAdapter = adapterFor(root, schema, recorder = recorder)))

      check vm.selectVectorSymbol(0)
      atomicWrite(svgFile,
        vm.vectorEditor.document.val.exportVectorDocumentSvg.optimizeVectorSvg)
      check not vm.vectorEditor.diagnostics.val.anyIt(
        it.kind == vdkUnsupportedOperation)
      let edited = vm.setVectorObjectProperty(VectorPropertyEditRequest(
        objectId: "box", kind: vpkFill, value: "#22C55E"))
      check edited.ok
      check vm.setVectorDocumentViewBox("0 0 64 64").ok
      check vm.inspector.pendingSourceEdits.val.len == 2
      check vm.commandAvailable(eckSave)

      let saved = vm.runEditorCommand(eckSave)
      check saved.status == ecsSucceeded
      let savedSvg = readFile(svgFile)
      check savedSvg.contains("#22C55E")
      check savedSvg.contains("viewBox=\"0 0 64 64\"")
      check vm.inspector.pendingSourceEdits.val.len == 0
      check vm.workspaceEditStage.val == wesClean
      check recorder.fullReloadSeen
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

  test "foundations_page_viewmodel_state_and_source_plans":
    createRoot proc(dispose: proc()) =
      let root = tempWorkspaceDir("foundations_page")
      defer: removeDir(root)

      let tokenFile = root / "foundations.tokens"
      atomicWrite(tokenFile,
        "color.primary=#2563EB\n" &
        "semantic.action=token(color.primary)\n" &
        "type.body=16px\n" &
        "space.card=16px\n" &
        "radius.card=12px\n" &
        "shadow.card=0 8px 24px #0F172A\n" &
        "motion.fast=120ms\n" &
        "breakpoint.compact=640px\n")
      let story = StoryRef(group: "Foundations", name: "Colors",
        kind: skFoundation, index: 0)
      let schema = @[
        WorkspaceEditableSchemaEntry(key: "tokens.color.primary",
          kind: wskToken, file: tokenFile, path: "color.primary",
          story: story, property: "color.primary"),
        WorkspaceEditableSchemaEntry(key: "tokens.semantic.action",
          kind: wskToken, file: tokenFile, path: "semantic.action",
          story: story, property: "semantic.action"),
        WorkspaceEditableSchemaEntry(key: "tokens.type.body",
          kind: wskToken, file: tokenFile, path: "type.body",
          story: story, property: "type.body"),
        WorkspaceEditableSchemaEntry(key: "tokens.space.card",
          kind: wskToken, file: tokenFile, path: "space.card",
          story: story, property: "space.card"),
        WorkspaceEditableSchemaEntry(key: "tokens.radius.card",
          kind: wskToken, file: tokenFile, path: "radius.card",
          story: story, property: "radius.card"),
        WorkspaceEditableSchemaEntry(key: "tokens.shadow.card",
          kind: wskToken, file: tokenFile, path: "shadow.card",
          story: story, property: "shadow.card"),
        WorkspaceEditableSchemaEntry(key: "tokens.motion.fast",
          kind: wskToken, file: tokenFile, path: "motion.fast",
          story: story, property: "motion.fast"),
        WorkspaceEditableSchemaEntry(key: "tokens.breakpoint.compact",
          kind: wskToken, file: tokenFile, path: "breakpoint.compact",
          story: story, property: "breakpoint.compact")
      ]
      let recorder = WorkspaceEditRecorder()
      let adapter = adapterFor(root, schema, recorder = recorder)
      let tokens = @[
        FoundationTokenEntry(key: "color.primary", kind: ftkColorPalette,
          value: "#2563EB", sourceFile: tokenFile, sourceLine: 1,
          schemaKey: "tokens.color.primary", property: "color.primary",
          affectedStories: @[story]),
        FoundationTokenEntry(key: "semantic.action", kind: ftkSemanticColor,
          value: "token(color.primary)", aliasOf: "color.primary",
          foreground: "#FFFFFF", background: "#2563EB", minContrast: 4.5,
          sourceFile: tokenFile, sourceLine: 2,
          schemaKey: "tokens.semantic.action", property: "semantic.action",
          affectedStories: @[story]),
        FoundationTokenEntry(key: "type.body", kind: ftkTypographyScale,
          value: "16px", sourceFile: tokenFile, sourceLine: 3,
          schemaKey: "tokens.type.body", property: "type.body",
          affectedStories: @[story]),
        FoundationTokenEntry(key: "space.card", kind: ftkSpacingScale,
          value: "16px", sourceFile: tokenFile, sourceLine: 4,
          schemaKey: "tokens.space.card", property: "space.card",
          affectedStories: @[story]),
        FoundationTokenEntry(key: "radius.card", kind: ftkRadiusScale,
          value: "12px", sourceFile: tokenFile, sourceLine: 5,
          schemaKey: "tokens.radius.card", property: "radius.card",
          affectedStories: @[story]),
        FoundationTokenEntry(key: "shadow.card", kind: ftkShadow,
          value: "0 8px 24px #0F172A", sourceFile: tokenFile,
          sourceLine: 6, schemaKey: "tokens.shadow.card",
          property: "shadow.card", affectedStories: @[story]),
        FoundationTokenEntry(key: "motion.fast", kind: ftkMotion,
          value: "120ms", sourceFile: tokenFile, sourceLine: 7,
          schemaKey: "tokens.motion.fast", property: "motion.fast",
          affectedStories: @[story]),
        FoundationTokenEntry(key: "breakpoint.compact", kind: ftkBreakpoint,
          value: "640px", sourceFile: tokenFile, sourceLine: 8,
          schemaKey: "tokens.breakpoint.compact",
          property: "breakpoint.compact", affectedStories: @[story])
      ]
      let vm = createEditorVM(newEditorWorkspace(
        title = "M46 foundations page workspace",
        storyGroups = @[StoryGroup(name: "Foundations", kind: skFoundation,
          items: @[StoryItem(name: "Colors", kind: skFoundation,
            group: "Foundations")])],
        foundationTokens = tokens,
        permissions = EditorWorkspacePermissions(readSource: true,
          writeSource: true, createStory: false, createVariant: false,
          duplicate: false, delete: false),
        editAdapter = adapter,
        initialView = evFoundationsPage,
        initialStory = some(story)))

      check vm.activeView.val == evFoundationsPage
      for kind in [ftkColorPalette, ftkSemanticColor, ftkTypographyScale,
          ftkSpacingScale, ftkRadiusScale, ftkShadow, ftkMotion,
          ftkBreakpoint]:
        check vm.setFoundationCategory(kind)
        check vm.foundations.filteredTokens.val.len == 1
        check vm.foundations.selectedToken.val.kind == kind

      vm.setFoundationSearch("radius")
      check vm.foundations.filteredTokens.val.len == 0
      check vm.foundations.selectedTokenKey.val == ""
      check vm.setFoundationCategory(ftkRadiusScale)
      check vm.foundations.filteredTokens.val[0].key == "radius.card"
      vm.setFoundationSearch("")

      check vm.selectFoundationToken("space.card")
      let edit = vm.editFoundationToken("space.card", "24px")
      check edit.status == pesAccepted
      check edit.sourceEdit.planKind == cspTokenUpdate
      check edit.sourceEdit.schemaKey == "tokens.space.card"
      check edit.sourceEdit.expectedOldValue == "16px"
      check vm.foundations.isDirty.val
      check vm.foundations.undoStack.val.len == 1
      check vm.inspector.pendingSourceEdits.val.len == 1
      check vm.workspaceEditStage.val == wesDirty
      check vm.undoFoundationTokenEdit()
      check vm.foundations.selectedToken.val.value == "16px"
      check not vm.foundations.isDirty.val
      check vm.inspector.pendingSourceEdits.val.len == 0
      check vm.redoFoundationTokenEdit()
      check vm.foundations.selectedToken.val.value == "24px"

      let invalidColor = vm.editFoundationToken("color.primary", "blue")
      check invalidColor.status == pesRejected
      check invalidColor.diagnostics.anyIt(it.kind == fedInvalidTokenValue)
      let invalidSpacing = vm.editFoundationToken("space.card", "large")
      check invalidSpacing.status == pesRejected
      check invalidSpacing.diagnostics.anyIt(it.kind == fedInvalidTokenValue)

      let saved = vm.applyWorkspaceFileEdits()
      check saved.ok
      check readFile(tokenFile).contains("space.card=24px")
      check vm.workspaceEditStage.val == wesClean
      check not vm.foundations.isDirty.val

      discard vm.editFoundationToken("space.card", "16px")
      discard vm.runEditorCommand(eckRevert)
      check vm.foundations.selectedToken.val.value == "24px"
      check vm.inspector.pendingSourceEdits.val.len == 0
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

  test "component_property_controls_update_schema_and_story_fixtures":
    createRoot proc(dispose: proc()) =
      let root = tempWorkspaceDir("component-properties")
      defer: removeDir(root)

      let schemaFile = root / "button.schema"
      let fixtureFile = root / "button.fixtures"
      atomicWrite(schemaFile,
        "size=md\nselected=false\nlabel=Run report\nicon=play\n" &
        "content=Run report\nfixture=ops-ready\ndensity=comfortable\n" &
        "platform=pfWeb\nariaLabel=Run report\n")
      atomicWrite(fixtureFile, "title=Paris\n")
      let story = StoryRef(group: "Button", name: "Default",
        kind: skComponent, index: 0)
      let schema = @[
        WorkspaceEditableSchemaEntry(key: "components.button.properties.size",
          kind: wskComponentVariant, file: schemaFile,
          path: "Button.default.size", story: story, property: "size"),
        WorkspaceEditableSchemaEntry(key: "components.button.properties.selected",
          kind: wskComponentVariant, file: schemaFile,
          path: "Button.default.selected", story: story, property: "selected"),
        WorkspaceEditableSchemaEntry(key: "components.button.properties.label",
          kind: wskComponentVariant, file: schemaFile,
          path: "Button.default.label", story: story, property: "label"),
        WorkspaceEditableSchemaEntry(key: "components.button.properties.icon",
          kind: wskComponentVariant, file: schemaFile,
          path: "Button.default.icon", story: story, property: "icon"),
        WorkspaceEditableSchemaEntry(key: "components.button.properties.content",
          kind: wskComponentVariant, file: schemaFile,
          path: "Button.default.content", story: story, property: "content"),
        WorkspaceEditableSchemaEntry(key: "fixtures.button.title",
          kind: wskStoryFixture, file: fixtureFile,
          path: "fixtures.button.title", story: story, property: "titleFixture"),
        WorkspaceEditableSchemaEntry(key: "components.button.properties.density",
          kind: wskComponentVariant, file: schemaFile,
          path: "Button.default.density", story: story, property: "density"),
        WorkspaceEditableSchemaEntry(key: "components.button.properties.platform",
          kind: wskComponentVariant, file: schemaFile,
          path: "Button.default.platform", story: story, property: "platform"),
        WorkspaceEditableSchemaEntry(key: "components.button.properties.ariaLabel",
          kind: wskComponentVariant, file: schemaFile,
          path: "Button.default.ariaLabel", story: story, property: "ariaLabel")
      ]
      let recorder = WorkspaceEditRecorder()
      let adapter = adapterFor(root, schema, recorder = recorder)

      proc prop(name: string; kind: ComponentPropertyKind; value: string;
          options: seq[string] = @[]; line = 1;
          fixtureKey = ""): ComponentPropertyDefinition =
        ComponentPropertyDefinition(
          name: name,
          kind: kind,
          value: value,
          options: options,
          sourceFile: if fixtureKey.len > 0: fixtureFile else: schemaFile,
          sourceLine: line,
          schemaKey: "components.button.properties." & name,
          fixtureKey: fixtureKey,
          constructor:
            if fixtureKey.len > 0: "buttonFixture"
            else: "buttonSchema",
          documentation: "Button " & name & " documentation.",
          usageGuidance: "Route " & name & " through the component schema.")

      var states: seq[ComponentStateControl] = @[]
      for key in requiredComponentStateKeys():
        states.add ComponentStateControl(
          key: key,
          kind:
            if key == "size": cskSize
            elif key == "emphasis": cskEmphasis
            elif key == "tone": cskTone
            elif key == "selected": cskSelected
            elif key == "disabled": cskDisabled
            elif key == "hover": cskHover
            elif key == "focus": cskFocus
            elif key == "pressed": cskPressed
            elif key == "loading": cskLoading
            elif key == "empty": cskEmpty
            elif key == "error": cskError
            else: cskSuccess,
          label: key,
          value: if key == "size": "md" else: "false",
          options: if key == "size": @["sm", "md", "lg"] else: @["false", "true"],
          story: story,
          fixtureName: "button." & key,
          sourceFile: schemaFile,
          sourceLine: 20,
          schemaKey: "components.button.states." & key)
      states.add ComponentStateControl(
        key: "billing-paused",
        kind: cskProjectSpecific,
        label: "billing paused",
        value: "false",
        options: @["false", "true"],
        story: story,
        fixtureName: "button.billing-paused",
        sourceFile: schemaFile,
        sourceLine: 40,
        schemaKey: "components.button.states.billing-paused",
        projectSpecific: true)

      let vm = createEditorVM(newEditorWorkspace(
        title = "M38 property workspace",
        storyGroups = @[StoryGroup(name: "Button", kind: skComponent,
          items: @[StoryItem(name: "Default", kind: skComponent,
            group: "Button")])],
        componentVariants = @[ComponentVariantDefinition(
          component: "Button",
          variantKey: "default",
          story: story,
          fixtureName: "button.default",
          metadataName: "Default",
          properties: @[
            prop("size", cpkEnum, "md", @["sm", "md", "lg"], 1),
            prop("selected", cpkBoolean, "false", @["false", "true"], 2),
            prop("label", cpkText, "Run report", @[], 3),
            prop("icon", cpkIcon, "play", @["play", "pause"], 4),
            prop("content", cpkSlotContent, "Run report", @[], 5),
            prop("titleFixture", cpkDataFixture, "Paris", @[], 1,
              "fixtures.button.title"),
            prop("density", cpkDensity, "comfortable",
              @["compact", "comfortable"], 7),
            prop("platform", cpkPlatform, "pfWeb",
              @["pfWeb", "pfIOS", "pfAndroid"], 8),
            prop("ariaLabel", cpkAccessibilityLabel, "Run report", @[], 9)
          ],
          stateControls: states,
          usageExamples: @[UsageExample(
            description: "Use schema-backed Button properties.",
            isDo: true)])],
        permissions = EditorWorkspacePermissions(readSource: true,
          writeSource: true, createStory: true, createVariant: true,
          duplicate: false, delete: false),
        editAdapter = adapter,
        initialStory = some(story)))

      check vm.componentVariantsForComponent("Button")[0].properties.mapIt(
        it.kind).contains(cpkEnum)
      check vm.componentVariantsForComponent("Button")[0].properties.mapIt(
        it.kind).contains(cpkAccessibilityLabel)

      let sizeEdit = vm.editComponentProperty("Button", "default", "size", "lg")
      check sizeEdit.status == pesAccepted
      check sizeEdit.sourceEdit.planKind == cspStructuredSchemaUpdate
      check sizeEdit.sourceEdit.schemaKey ==
        "components.button.properties.size"
      check sizeEdit.sourceEdit.originDetail.contains("component-property:manual")
      check sizeEdit.sourceEdit.regeneratorHook == "buttonSchema"

      let fixtureEdit = vm.editComponentProperty("Button", "default",
        "titleFixture", "Sofia")
      check fixtureEdit.status == pesAccepted
      check fixtureEdit.sourceEdit.schemaKey == "fixtures.button.title"
      check fixtureEdit.sourceEdit.regeneratorHook == "buttonFixture"
      check vm.inspector.pendingSourceEdits.val.len == 2

      let saved = vm.applyWorkspaceFileEdits()
      check saved.ok
      check readFile(schemaFile).contains("size=lg")
      check readFile(fixtureFile).contains("title=Sofia")

      let aiEdit = vm.editComponentProperty("Button", "default", "ariaLabel",
        "Run operations report", cpemAi)
      check aiEdit.status == pesAccepted
      check aiEdit.sourceEdit.originDetail.contains("component-property:ai")
      let context = vm.buildAgentPromptContext()
      check context.designSystemSchema.anyIt(
        it.key == "components.button.properties.ariaLabel")
      check context.sourceMap.anyIt(
        it.schemaKey == "components.button.properties.ariaLabel" and
          it.originDetail.contains("component-property:ai"))
      check context.accumulatedEdits.anyIt(
        it.property == "ariaLabel" and it.editOrigin == peoAgent)
      dispose()

  test "component_state_coverage_diagnostics_are_actionable":
    createRoot proc(dispose: proc()) =
      let root = tempWorkspaceDir("component-state-coverage")
      defer: removeDir(root)

      let schemaFile = root / "badge.schema"
      atomicWrite(schemaFile, "tone=neutral\nhover=false\n")
      let defaultStory = StoryRef(group: "StatusBadge", name: "Neutral",
        kind: skComponent, index: 0)
      let variants = @[
        ComponentVariantDefinition(
          component: "StatusBadge",
          variantKey: "neutral",
          story: defaultStory,
          fixtureName: "badge.neutral",
          metadataName: "Neutral",
          stateControls: @[
            ComponentStateControl(key: "tone", kind: cskTone,
              label: "tone", value: "neutral",
              options: @["neutral", "success", "error"],
              story: defaultStory,
              fixtureName: "badge.neutral",
              sourceFile: schemaFile,
              sourceLine: 1,
              schemaKey: "components.badge.states.tone"),
            ComponentStateControl(key: "hover", kind: cskHover,
              label: "hover", value: "false",
              options: @["false", "true"],
              story: StoryRef(),
              fixtureName: "",
              sourceFile: schemaFile,
              sourceLine: 2,
              schemaKey: "components.badge.states.hover"),
            ComponentStateControl(key: "hover", kind: cskHover,
              label: "hover duplicate", value: "false",
              options: @["false", "true"],
              story: StoryRef(),
              fixtureName: "",
              sourceFile: schemaFile,
              sourceLine: 3,
              schemaKey: "components.badge.states.hover.duplicate"),
            ComponentStateControl(key: "billing-paused",
              kind: cskProjectSpecific,
              label: "billing paused", value: "false",
              options: @["false", "true"],
              story: StoryRef(),
              fixtureName: "",
              sourceFile: schemaFile,
              sourceLine: 4,
              schemaKey: "components.badge.states.billing-paused",
              projectSpecific: true)
          ])
      ]
      let vm = createEditorVM(newEditorWorkspace(
        title = "M38 state coverage workspace",
        storyGroups = @[StoryGroup(name: "StatusBadge", kind: skComponent,
          items: @[StoryItem(name: "Neutral", kind: skComponent,
            group: "StatusBadge")])],
        componentVariants = variants,
        initialStory = some(defaultStory)))

      let diagnostics = vm.stateCoverageDiagnostics("StatusBadge")
      check diagnostics.anyIt(it.kind == cscdMissingStory and
        it.stateKey == "hover" and it.command.startsWith("create-story:"))
      check diagnostics.anyIt(it.kind == cscdMissingFixture and
        it.stateKey == "billing-paused" and it.suggestion.contains("fixture"))
      check diagnostics.anyIt(it.kind == cscdDuplicateState and
        it.stateKey == "hover")
      check diagnostics.anyIt(it.kind == cscdMissingStory and
        it.stateKey == "size")

      let matrix = vm.variantMatrixPreviews("StatusBadge")
      check matrix.anyIt(it.stateKey == "tone" and it.covered)
      check matrix.anyIt(it.stateKey == "hover" and not it.covered and
        it.missingStorySuggestion.contains("Create story"))
      check matrix.anyIt(it.stateKey == "billing-paused" and
        it.createStoryCommand.contains("billing-paused"))

      let created = vm.createStoryForComponentState("StatusBadge", "neutral",
        "hover")
      check created.status == pesAccepted
      check created.sourceEdit.property == "story.hover"
      check created.sourceEdit.regeneratorHook == "component-story-constructor"
      check vm.variants.stateDiagnostics.val.anyIt(
        it.kind == cscdMissingStory and it.stateKey == "size")
      check not vm.variants.stateDiagnostics.val.anyIt(
        it.kind == cscdMissingStory and it.stateKey == "hover")
      check vm.inspector.pendingSourceEdits.val.anyIt(
        it.originDetail == "component-state:manual:create-story")
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

  test "style_manager_resolves_class_token_and_cascade_layers":
    createRoot proc(dispose: proc()) =
      let root = tempWorkspaceDir("style-manager-resolve")
      defer: removeDir(root)

      func span(file: string; line: int): SourceSpan =
        SourceSpan(file: file, line: line, column: 1,
          endLine: line, endColumn: 24)

      let tokenFile = root / "design/tokens.schema"
      let cssFile = root / "components/card.css"
      let viewFile = root / "components/card_view.nim"
      createDir(root / "design")
      createDir(root / "components")
      createDir(root / "stories")
      atomicWrite(tokenFile,
        "primitive.surface.base=#ffffff\nsemantic.surface.card=token(primitive.surface.base)\nprimitive.spacing.base=16px\nsemantic.spacing.card=token(primitive.spacing.base)\nsemantic.surface.card.light=#ffffff\nsemantic.surface.card.dark=#0f172a\ncomponents.card.padding=16px")
      atomicWrite(cssFile, ".card { padding: 16px; }\n.card { margin: 8px; }")
      atomicWrite(viewFile, "background-color=#ffffff")
      atomicWrite(root / "stories/card.fixture", "padding=16px")

      let story = writeStory
      let schema = DesignSystemSchema(
        schemaVersion: 1,
        projectId: "metacraft-web-backoffice",
        ownerPackage: "metacraft-web",
        frameworkContract: "isonim-editor-design-schema-v1",
        nodes: @[
          DesignSchemaNode(key: "primitive.surface.base",
            kind: dsnFoundation, name: "Base surface",
            property: "background-color", value: "#ffffff",
            sourceSpan: span(tokenFile, 1), usageCount: 2),
          DesignSchemaNode(key: "semantic.surface.card",
            kind: dsnSemanticToken, name: "Card surface",
            property: "background-color",
            value: "token(primitive.surface.base)",
            sourceSpan: span(tokenFile, 2), stories: @[story],
            components: @["Card"], usageCount: 2,
            foreground: "#cbd5e1", background: "#ffffff",
            minContrast: 4.5, modeValues: @[
              DesignTokenModeValue(kind: dtmkLight, name: "light",
                value: "#ffffff", sourceSpan: span(tokenFile, 5),
                schemaKey: "semantic.surface.card.light"),
              DesignTokenModeValue(kind: dtmkDark, name: "dark",
                value: "#0f172a", sourceSpan: span(tokenFile, 6),
                schemaKey: "semantic.surface.card.dark")
            ]),
          DesignSchemaNode(key: "primitive.spacing.base",
            kind: dsnFoundation, name: "Base spacing",
            property: "padding", value: "16px",
            sourceSpan: span(tokenFile, 3), usageCount: 4),
          DesignSchemaNode(key: "semantic.spacing.card",
            kind: dsnSemanticToken, name: "Card spacing",
            property: "padding", value: "token(primitive.spacing.base)",
            sourceSpan: span(tokenFile, 4), stories: @[story],
            components: @["Card"], usageCount: 4),
          DesignSchemaNode(key: "components.card.padding",
            kind: dsnComponentToken, name: "Card padding",
            component: "Card", property: "padding", value: "16px",
            sourceSpan: span(tokenFile, 7), usageCount: 3),
          DesignSchemaNode(key: "classes.card.primary",
            kind: dsnClassDefinition, name: "card",
            property: "padding", value: "16px",
            sourceSpan: span(cssFile, 1), usageCount: 3),
          DesignSchemaNode(key: "classes.card.duplicate",
            kind: dsnClassDefinition, name: "card",
            property: "margin", value: "8px",
            sourceSpan: span(cssFile, 2), usageCount: 1),
          DesignSchemaNode(key: "fixtures.card.title",
            kind: dsnStoryFixture, name: "Card fixture",
            property: "padding", value: "16px",
            sourceSpan: span(root / "stories/card.fixture", 1),
            stories: @[story]),
          DesignSchemaNode(key: "components.card.schema",
            kind: dsnComponentVariant, name: "Card schema",
            property: "padding", value: "16px",
            sourceSpan: span(root / "components/card.schema", 1),
            stories: @[story])
        ],
        sourceOwnership: @[
          DesignSourceOwnership(elementSourceKey: "card.root",
            property: "background-color",
            schemaKey: "semantic.surface.card",
            nodeKey: "semantic.surface.card",
            sourceSpan: span(tokenFile, 2),
            generatedViewFile: viewFile, generatedViewLine: 1),
          DesignSourceOwnership(elementSourceKey: "card.root",
            property: "padding", schemaKey: "classes.card.primary",
            nodeKey: "classes.card.primary",
            sourceSpan: span(cssFile, 1),
            cssModuleFile: cssFile, cssModuleClass: "card",
            tailwindUtilities: @["card"])
        ])

      let vm = createEditorVM(newEditorWorkspace(
        title = "M39 style manager resolve workspace",
        storyGroups = @[StoryGroup(name: "Card", kind: skComponent,
          items: @[StoryItem(name: "Default", kind: skComponent,
            group: "Card")])],
        foundationTokens = @[
          FoundationTokenEntry(key: "semantic.surface.card",
            kind: ftkSemanticColor,
            value: "token(primitive.surface.base)",
            aliasOf: "primitive.surface.base",
            sourceFile: tokenFile, sourceLine: 2,
            schemaKey: "semantic.surface.card",
            property: "background-color",
            affectedStories: @[story])
        ],
        designSystemSchema = schema,
        initialStory = some(story)))
      check vm.selectInspectorElement(ElementRef(
        id: "card-root",
        sourceKey: "card.root",
        schemaKey: "components.card.schema",
        tag: "article",
        sourceFile: viewFile,
        sourceLine: 1,
        properties: @[
          PropertyInfo(name: "background-color", value: "#ffffff",
            origin: poSetStyle,
            originDetail: "style.background-color",
            sourceFile: viewFile,
            sourceLine: 1,
            schemaKey: "semantic.surface.card",
            tokenName: "semantic.surface.card",
            directStyleAllowed: true),
          PropertyInfo(name: "padding", value: "16px",
            origin: poTailwindClass,
            originDetail: "class:card",
            sourceFile: cssFile,
            sourceLine: 1,
            schemaKey: "classes.card.primary",
            sharedCount: 3),
          PropertyInfo(name: "padding", value: "12px",
            origin: poInherited,
            originDetail: "inherited:.card-shell",
            sourceFile: cssFile,
            sourceLine: 3,
            schemaKey: "classes.card.inherited")
        ]))

      let padding = vm.styleManagerSnapshot("padding", "card")
      check padding.currentClassStack.anyIt(it.className == "card" and it.editable)
      check padding.reusableStyles.len >= 2
      check padding.cascadeLayers.anyIt(it.kind == sclSharedClass and
        it.className == "card" and it.editable and
        it.sourceFile == cssFile and it.sourceLine == 1)
      check padding.cascadeLayers.anyIt(it.kind == sclFinalValue and
        it.finalValue == "16px" and it.sourceFile == cssFile)
      check padding.cascadeLayers.anyIt(it.kind == sclInheritedValue and
        it.inheritedValue == "12px" and it.overridden)
      for kind in [
        sscLocalInstance, sscStoryFixture, sscComponentSchema, sscComponentToken,
        sscSharedClass, sscSemanticToken, sscGlobalPrimitiveToken
      ]:
        check padding.scopeChoices.anyIt(it.kind == kind and it.editable and
          it.sourceFile.len > 0 and it.sourceLine > 0 and
          (kind == sscLocalInstance or it.schemaKey.len > 0))
      check padding.diagnostics.anyIt(it.kind == sdkDuplicateClass)
      check padding.diagnostics.anyIt(it.kind == sdkUnsafeDetachment)

      let color = vm.styleManagerSnapshot("background-color")
      check color.finalValue == "#ffffff"
      check color.cascadeLayers.anyIt(it.kind == sclSemanticToken and
        it.tokenChain == @["semantic.surface.card", "primitive.surface.base"])
      check color.tokenItems.anyIt(it.key == "semantic.surface.card" and
        it.aliasOf == "primitive.surface.base" and it.dependentStories.len == 1)
      check color.tokenItems.anyIt(it.key == "semantic.surface.card" and
        it.modes.len == 2 and it.usages.anyIt(it.name == "background-color") and
        it.contrastRatio > 0 and it.contrastRatio < it.minContrast and
        it.diagnostics.anyIt(it.kind == fedContrastViolation) and
        it.impact.diagnostics.anyIt(it.kind == dsdContrastImpact))
      check color.tokenItems.anyIt(it.key == "semantic.surface.card" and
        it.impact.usageCount >= 1)
      check vm.tokenManagerItems("surface").anyIt(it.key == "semantic.surface.card")
      check color.diagnostics.anyIt(
        it.kind == sdkHardcodedColorMatchingToken and
        it.tokenKey == "primitive.surface.base")
      check color.diagnostics.anyIt(it.kind == sdkOneOffValueShouldBeToken)
      dispose()

  test "style_manager_promote_detach_and_tokenize_are_source_backed":
    createRoot proc(dispose: proc()) =
      let root = tempWorkspaceDir("style-manager-source-backed")
      defer: removeDir(root)

      let viewFile = root / "components/card_view.nim"
      let cssFile = root / "components/card.css"
      let tokenFile = root / "design/tokens.schema"
      createDir(root / "components")
      createDir(root / "design")
      atomicWrite(viewFile, "background-color=#ffffff\nborder-radius=8px")
      atomicWrite(cssFile, ".card { padding: 16px; }")
      atomicWrite(tokenFile, "semantic.surface.raised=#f8fafc")

      let recorder = WorkspaceEditRecorder()
      let schema = @[
        WorkspaceEditableSchemaEntry(key: "semantic.surface.raised",
          kind: wskToken, file: viewFile, path: "semantic.surface.raised",
          story: writeStory, property: "background-color"),
        WorkspaceEditableSchemaEntry(key: "classes.card.padding",
          kind: wskSourceMap, file: cssFile, path: "classes.card.padding",
          story: writeStory, property: "padding"),
        WorkspaceEditableSchemaEntry(key: "classes.card.radius",
          kind: wskSourceMap, file: viewFile, path: "classes.card.radius",
          story: writeStory, property: "border-radius")
      ]
      let adapter = adapterFor(root, schema, recorder = recorder)
      let vm = createEditorVM(newEditorWorkspace(
        title = "M39 style manager source-backed workspace",
        storyGroups = @[StoryGroup(name: "Card", kind: skComponent,
          items: @[StoryItem(name: "Default", kind: skComponent,
            group: "Card")])],
        designSystemSchema = DesignSystemSchema(
          schemaVersion: 1,
          projectId: "metacraft-web-backoffice",
          ownerPackage: "metacraft-web",
          frameworkContract: "isonim-editor-design-schema-v1",
          nodes: @[
            DesignSchemaNode(key: "semantic.surface.raised",
              kind: dsnSemanticToken, name: "Raised surface",
              property: "background-color", value: "#f8fafc",
              sourceSpan: SourceSpan(file: viewFile, line: 1,
                column: 1, endLine: 1, endColumn: 40)),
            DesignSchemaNode(key: "classes.card.padding",
              kind: dsnClassDefinition, name: "card",
              property: "padding", value: "16px",
              sourceSpan: SourceSpan(file: cssFile, line: 1,
                column: 1, endLine: 1, endColumn: 24)),
            DesignSchemaNode(key: "classes.card.radius",
              kind: dsnClassDefinition, name: "card-radius",
              property: "border-radius", value: "8px",
              sourceSpan: SourceSpan(file: viewFile, line: 2,
                column: 1, endLine: 2, endColumn: 24))
          ]),
        initialStory = some(writeStory),
        permissions = EditorWorkspacePermissions(readSource: true,
          writeSource: true),
        editAdapter = adapter))
      check vm.selectInspectorElement(ElementRef(
        id: "card-root",
        sourceKey: "card.root",
        tag: "article",
        sourceFile: viewFile,
        sourceLine: 1,
        properties: @[
          PropertyInfo(name: "background-color", value: "#ffffff",
            origin: poSetStyle, originDetail: "style.background-color",
            sourceFile: viewFile, sourceLine: 1,
            schemaKey: "semantic.surface.raised",
            directStyleAllowed: true),
          PropertyInfo(name: "padding", value: "16px",
            origin: poTailwindClass, originDetail: "class:card",
            sourceFile: cssFile, sourceLine: 1,
            schemaKey: "classes.card.padding",
            sharedCount: 4),
          PropertyInfo(name: "border-radius", value: "8px",
            origin: poSetStyle, originDetail: "style.border-radius",
            sourceFile: viewFile, sourceLine: 2,
            schemaKey: "classes.card.radius",
            directStyleAllowed: true)
        ]))

      let promote = vm.promoteLocalOverride("border-radius", sscSharedClass,
        "classes.card.radius")
      check promote.status == pesAccepted
      check promote.sourceEdit.reversible
      check promote.sourceEdit.schemaKey == "classes.card.radius"
      check promote.sourceEdit.originDetail.startsWith("style-promote:")

      let detach = vm.detachStyleClass("padding")
      check detach.status == pesAccepted
      check detach.sourceEdit.planKind == cspInlineStyleUpdate
      check detach.sourceEdit.originDetail.startsWith("style-class:detach")
      check detach.diagnostics.anyIt(it.kind == sdkUnsafeDetachment)

      let tokenize = vm.tokenizeStyleValue("background-color",
        "semantic.surface.raised")
      check tokenize.status == pesAccepted
      check tokenize.sourceEdit.planKind == cspTokenUpdate
      check tokenize.sourceEdit.tokenName == "semantic.surface.raised"
      check vm.inspector.pendingSourceEdits.val.len == 3

      let saved = vm.applyWorkspaceFileEdits()
      check saved.ok
      check recorder.reviewCount == 1
      check readFile(viewFile).contains("token(semantic.surface.raised)")
      check readFile(cssFile).contains("padding: 16px")
      check vm.inspector.pendingSourceEdits.val.len == 0

      let missingDetach = vm.detachSharedDesignProperty("margin")
      check missingDetach.status == pesRejected
      check missingDetach.diagnostics.anyIt(it.kind == pedUnknownProperty)
      let missingToken = vm.tokenizeSharedDesignProperty("background-color",
        "semantic.surface.missing")
      check missingToken.status == pesRejected
      check missingToken.diagnostics.anyIt(it.kind == pedInvalidTokenReference)

      let classVm = createEditorVM(newEditorWorkspace(
        title = "M39 style class operations workspace",
        storyGroups = @[],
        designSystemSchema = DesignSystemSchema(
          schemaVersion: 1,
          projectId: "metacraft-web-backoffice",
          ownerPackage: "metacraft-web",
          frameworkContract: "isonim-editor-design-schema-v1",
          nodes: @[DesignSchemaNode(key: "classes.card.padding",
            kind: dsnClassDefinition, name: "card",
            property: "padding", value: "16px",
            sourceSpan: SourceSpan(file: cssFile, line: 1,
              column: 1, endLine: 1, endColumn: 24))])))
      check classVm.selectInspectorElement(ElementRef(
        tag: "article",
        sourceFile: cssFile,
        sourceLine: 1,
        properties: @[PropertyInfo(name: "padding", value: "16px",
          origin: poTailwindClass, originDetail: "class:card",
          sourceFile: cssFile, sourceLine: 1,
          schemaKey: "classes.card.padding", sharedCount: 4)]))
      let created = classVm.createStyleClass("cardCompact", "margin", "8px")
      check created.status == pesAccepted
      check created.sourceEdit.reversible
      check created.sourceEdit.originDetail.startsWith("style-class:create")
      let renamed = classVm.renameStyleClass("card", "card-shell")
      check renamed.status == pesAccepted
      check renamed.sourceEdit.originDetail == "style-class:rename"
      let duplicated = classVm.duplicateStyleClass("card", "card-copy")
      check duplicated.status == pesAccepted
      check duplicated.sourceEdit.originDetail == "style-class:duplicate"
      check classVm.inspector.pendingSourceEdits.val.len == 3

      let ambiguousVm = createEditorVM(newEditorWorkspace(
        title = "M39 ambiguous style promotion workspace",
        storyGroups = @[],
        designSystemSchema = DesignSystemSchema(
          schemaVersion: 1,
          projectId: "metacraft-web-backoffice",
          ownerPackage: "metacraft-web",
          frameworkContract: "isonim-editor-design-schema-v1",
          nodes: @[
            DesignSchemaNode(key: "semantic.surface.raised",
              kind: dsnSemanticToken, name: "Raised surface",
              property: "background-color", value: "#f8fafc",
              sourceSpan: SourceSpan(file: tokenFile, line: 1,
                column: 1, endLine: 1, endColumn: 32)),
            DesignSchemaNode(key: "semantic.surface.alt",
              kind: dsnSemanticToken, name: "Alt surface",
              property: "background-color", value: "#ffffff",
              sourceSpan: SourceSpan(file: tokenFile, line: 2,
                column: 1, endLine: 2, endColumn: 32))
          ])))
      check ambiguousVm.selectInspectorElement(ElementRef(
        tag: "article",
        sourceFile: viewFile,
        sourceLine: 1,
        properties: @[PropertyInfo(name: "background-color", value: "#ffffff",
          origin: poSetStyle, originDetail: "style.background-color",
          sourceFile: viewFile, sourceLine: 1,
          directStyleAllowed: true)]))
      let ambiguousPromote = ambiguousVm.promoteLocalOverride(
        "background-color", sscSemanticToken)
      check ambiguousPromote.status == pesRejected
      check ambiguousPromote.diagnostics.anyIt(
        it.message.contains("Multiple semantic token owners"))
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
      check vm.chat.proposedEdits.val[0].sourceEdits[0].sourceScope ==
        sskLocalInstance
      check vm.chat.proposedEdits.val[0].sourceEdits[0].
        sourceScopeChoices.anyIt(it.kind == sskLocalInstance and
          it.impact.summary.len > 0)
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

  test "comment_annotations_are_structured_and_prompt_selectable":
    createRoot proc(dispose: proc()) =
      let root = tempWorkspaceDir("review-annotations")
      defer: removeDir(root)

      let schemaFile = root / "card.schema"
      atomicWrite(schemaFile, "padding=16px\ncolor=#111827\n")
      let schema = DesignSystemSchema(
        schemaVersion: 1,
        projectId: "review-annotation-fixture",
        ownerPackage: "isonim-tests",
        frameworkContract: "isonim-editor-design-schema-v1",
        nodes: @[DesignSchemaNode(key: "components.card.padding",
          kind: dsnComponentVariant, component: "Card", property: "padding",
          sourceSpan: SourceSpan(file: schemaFile, line: 1, column: 1,
            endLine: 1, endColumn: 12))],
        sourceOwnership: @[DesignSourceOwnership(
          elementSourceKey: "card-title",
          domPath: "article > h1",
          property: "padding",
          schemaKey: "components.card.padding",
          nodeKey: "components.card.padding",
          sourceSpan: SourceSpan(file: schemaFile, line: 1, column: 1,
            endLine: 1, endColumn: 12),
          generatedViewFile: root / "generated_card.nim",
          generatedViewLine: 12,
          cssModuleFile: root / "card.css",
          cssModuleClass: "card",
          tailwindUtilities: @["p-4"],
          fallbackAllowed: false)])
      let vm = createEditorVM(newEditorWorkspace(
        title = "M41 review annotation workspace",
        storyGroups = @[],
        initialStory = some(writeStory),
        designSystemSchema = schema,
        permissions = EditorWorkspacePermissions(readSource: true,
          writeSource: true)))
      vm.changeViewport(pvMobile)
      check vm.selectInspectorElement(ElementRef(
        id: "title",
        sourceKey: "card-title",
        domPath: "article > h1",
        schemaKey: "components.card.padding",
        tag: "h1",
        sourceFile: schemaFile,
        sourceLine: 1,
        properties: @[PropertyInfo(name: "padding", value: "16px",
          origin: poConstant, originDetail: "schema:components.card.padding",
          sourceFile: schemaFile, sourceLine: 1,
          schemaKey: "components.card.padding")]))

      let first = vm.addReviewAnnotation(
        "Reduce the visual weight of this heading.",
        selector = "h1.bo-title",
        ancestry = "article > h1",
        domSnapshot = "<h1 class=\"bo-title\">Operations</h1>",
        screenshotRef = "viewport:390x844:h1.bo-title",
        severity = rasWarning,
        suggestedScope = pesShared)
      let second = vm.addReviewAnnotation(
        "Keep this local to the fixture.",
        selector = "article",
        ancestry = "article",
        domSnapshot = "<article></article>",
        severity = rasInfo,
        suggestedScope = pesLocal)
      check first.len > 0
      check second.len > 0
      check vm.review.annotations.val.len == 2
      check vm.review.annotations.val[0].selectedElement.id == "title"
      check vm.review.annotations.val[0].viewport.viewport == pvMobile
      check vm.review.annotations.val[0].ownership.ownerPackage == "isonim-tests"
      check vm.review.annotations.val[0].ownership.schemaKey ==
        "components.card.padding"
      check vm.review.annotations.val[0].includedInPrompt

      check vm.review.setReviewAnnotationPromptIncluded(second, false)
      vm.chat.configureAgentPromptContext(includeScreenshots = true,
        includeDomSnapshots = true)
      let context = vm.buildAgentPromptContext()
      check context.reviewAnnotations.len == 1
      check context.reviewAnnotations[0].id == first
      check context.screenshotRefs == @["viewport:390x844:h1.bo-title"]
      check context.domSnapshots.len == 1
      check context.selectedSchemaNodes.anyIt(
        it.key == "components.card.padding")
      check context.designSystemConstraints.anyIt(it.contains("source schema"))

      check vm.review.resolveReviewAnnotation(first)
      check vm.buildAgentPromptContext().reviewAnnotations.len == 0
      check vm.review.annotations.val.anyIt(
        it.id == first and it.state == ransResolved)
      dispose()

  test "m50_source_scope_choices_cover_property_ownership_contract":
    createRoot proc(dispose: proc()) =
      let root = tempWorkspaceDir("m50-source-scopes")
      defer: removeDir(root)

      func span(file: string; line: int): SourceSpan =
        SourceSpan(file: file, line: line, column: 1,
          endLine: line, endColumn: 20)

      let story = StoryRef(group: "Cards", name: "Default", kind: skComponent)
      let schemaFile = root / "components/card.schema"
      let fixtureFile = root / "stories/card.fixture"
      let classFile = root / "components/card.css"
      let tokenFile = root / "design/tokens.schema"
      createDir(root / "components")
      createDir(root / "stories")
      createDir(root / "design")
      atomicWrite(schemaFile, "padding=16px")
      atomicWrite(fixtureFile, "padding=16px")
      atomicWrite(classFile, ".card { padding: 16px; }")
      atomicWrite(tokenFile,
        "component.card.padding=16px\ncomponent.card.radius=8px\n" &
        "semantic.surface.card=#ffffff\nprimitive.color.surface=#ffffff")

      let schema = DesignSystemSchema(
        schemaVersion: 1,
        projectId: "m50-example",
        ownerPackage: "isonim-example",
        frameworkContract: "isonim-editor-design-schema-v1",
        nodes: @[
          DesignSchemaNode(key: "fixtures.card.padding",
            kind: dsnStoryFixture, name: "Card story fixture",
            property: "padding", value: "16px",
            sourceSpan: span(fixtureFile, 1), stories: @[story],
            usageCount: 1),
          DesignSchemaNode(key: "components.card.padding",
            kind: dsnComponentVariant, name: "Card component API",
            component: "Card", property: "padding", value: "16px",
            sourceSpan: span(schemaFile, 1), stories: @[story],
            components: @["Card"], usageCount: 2),
          DesignSchemaNode(key: "classes.card.padding",
            kind: dsnClassDefinition, name: "card",
            property: "padding", value: "16px",
            sourceSpan: span(classFile, 1), stories: @[story],
            components: @["Card"], usageCount: 7),
          DesignSchemaNode(key: "component.card.padding",
            kind: dsnComponentToken, name: "Card padding token",
            component: "Card", property: "padding", value: "16px",
            sourceSpan: span(tokenFile, 1), stories: @[story],
            components: @["Card"], usageCount: 3),
          DesignSchemaNode(key: "semantic.spacing.card",
            kind: dsnSemanticToken, name: "Card semantic spacing",
            property: "padding", value: "token(primitive.spacing.base)",
            sourceSpan: span(tokenFile, 2), stories: @[story],
            components: @["Card"], usageCount: 4),
          DesignSchemaNode(key: "primitive.spacing.base",
            kind: dsnFoundation, name: "Base spacing",
            property: "padding", value: "16px",
            sourceSpan: span(tokenFile, 3), stories: @[story],
            components: @["Card"], usageCount: 9),
          DesignSchemaNode(key: "components.card.columns",
            kind: dsnComponentVariant, name: "Card grid columns",
            component: "Card", property: "grid-template-columns",
            value: "1fr auto", sourceSpan: span(schemaFile, 2),
            stories: @[story], components: @["Card"], usageCount: 2),
          DesignSchemaNode(key: "component.card.radius",
            kind: dsnComponentToken, name: "Card radius token",
            component: "Card", property: "border-radius", value: "8px",
            sourceSpan: span(tokenFile, 4), stories: @[story],
            components: @["Card"], usageCount: 5),
          DesignSchemaNode(key: "semantic.surface.card",
            kind: dsnSemanticToken, name: "Card semantic surface",
            property: "background", value: "token(primitive.color.surface)",
            sourceSpan: span(tokenFile, 5), stories: @[story],
            components: @["Card"], usageCount: 6),
          DesignSchemaNode(key: "primitive.color.surface",
            kind: dsnFoundation, name: "Surface primitive",
            property: "background", value: "#ffffff",
            sourceSpan: span(tokenFile, 6), stories: @[story],
            components: @["Card"], usageCount: 8)
        ],
        sourceOwnership: @[
          DesignSourceOwnership(
            elementSourceKey: "card.root",
            property: "padding",
            schemaKey: "classes.card.padding",
            nodeKey: "classes.card.padding",
            sourceSpan: span(classFile, 1),
            cssModuleFile: classFile,
            cssModuleClass: "card"),
          DesignSourceOwnership(
            elementSourceKey: "card.root",
            property: "grid-template-columns",
            schemaKey: "components.card.columns",
            nodeKey: "components.card.columns",
            sourceSpan: span(schemaFile, 2)),
          DesignSourceOwnership(
            elementSourceKey: "card.root",
            property: "border-radius",
            schemaKey: "component.card.radius",
            nodeKey: "component.card.radius",
            sourceSpan: span(tokenFile, 4)),
          DesignSourceOwnership(
            elementSourceKey: "card.root",
            property: "background",
            schemaKey: "semantic.surface.card",
            nodeKey: "semantic.surface.card",
            sourceSpan: span(tokenFile, 5))
        ])

      let vm = createEditorVM(newEditorWorkspace(
        title = "M50 source scope example",
        storyGroups = @[StoryGroup(name: "Cards", kind: skComponent,
          items: @[StoryItem(name: "Default", kind: skComponent,
            group: "Cards")])],
        initialStory = some(story),
        designSystemSchema = schema,
        permissions = EditorWorkspacePermissions(readSource: true,
          writeSource: true)))
      check vm.selectInspectorElement(ElementRef(
        id: "card-root",
        sourceKey: "card.root",
        schemaKey: "components.card.padding",
        tag: "article",
        sourceFile: schemaFile,
        sourceLine: 1,
        properties: @[
          PropertyInfo(name: "padding", value: "16px",
            origin: poTailwindClass, originDetail: "class:card",
            sourceFile: classFile, sourceLine: 1,
            schemaKey: "classes.card.padding", sharedCount: 7,
            directStyleAllowed: true),
          PropertyInfo(name: "grid-template-columns", value: "1fr auto",
            origin: poConstant, originDetail: "schema:components.card.columns",
            sourceFile: schemaFile, sourceLine: 2,
            schemaKey: "components.card.columns", sharedCount: 2,
            directStyleAllowed: true),
          PropertyInfo(name: "border-radius", value: "8px",
            origin: poThemeToken, originDetail: "token:component.card.radius",
            sourceFile: tokenFile, sourceLine: 4,
            schemaKey: "component.card.radius",
            tokenName: "component.card.radius", sharedCount: 5,
            directStyleAllowed: true),
          PropertyInfo(name: "background", value: "token(semantic.surface.card)",
            origin: poThemeToken, originDetail: "token:semantic.surface.card",
            sourceFile: tokenFile, sourceLine: 5,
            schemaKey: "semantic.surface.card",
            tokenName: "semantic.surface.card", sharedCount: 6,
            directStyleAllowed: true)
        ]))

      let prop = vm.inspector.selectedElement.val.properties[0]
      let choices = vm.sourceScopeChoices(prop)
      for kind in [
        sskLocalInstance, sskStoryFixture, sskComponentSchemaApi,
        sskSharedClass, sskComponentToken, sskSemanticToken,
        sskGlobalPrimitiveToken
      ]:
        check choices.anyIt(it.kind == kind and it.label.len > 0)

      let sharedClass = choices.filterIt(it.kind == sskSharedClass)[0]
      check sharedClass.ownerLabel.contains("isonim-example")
      check sharedClass.sourceFile == classFile
      check sharedClass.schemaKey == "classes.card.padding"
      check sharedClass.usageCount == 7
      check sharedClass.affectedComponents == @["Card"]
      check sharedClass.affectedStories == @[story]
      check sharedClass.riskLevel in {ssrMedium, ssrHigh}
      check vm.sourceScopeImpacts(prop).anyIt(
        it.schemaKey == "primitive.spacing.base" and it.usageCount == 9)

      let editors = vm.inspector.propertyEditors.val
      let paddingEditor = editors.filterIt(it.property == "padding")[0]
      check paddingEditor.sourceScopeChoices.len >= 7
      check paddingEditor.sourceScopeChoices.anyIt(it.kind == sskSharedClass and
        it.usageCount == 7 and it.riskLevel in {ssrMedium, ssrHigh})
      check paddingEditor.impactSummaries.len > 0
      check paddingEditor.impactSummaries.anyIt(
        it.schemaKey == "classes.card.padding" and it.usageCount == 7)
      check editors.filterIt(it.property == "grid-template-columns")[0].
        sourceScopeChoices.anyIt(it.kind == sskComponentSchemaApi and
          it.schemaKey == "components.card.columns" and it.usageCount == 2)
      check editors.filterIt(it.property == "border-radius")[0].
        sourceScopeChoices.anyIt(it.kind == sskComponentToken and
          it.schemaKey == "component.card.radius" and it.usageCount == 5)
      check editors.filterIt(it.property == "background")[0].
        sourceScopeChoices.anyIt(it.kind == sskSemanticToken and
          it.schemaKey == "semantic.surface.card" and it.usageCount == 6)

      let edit = vm.editInspectorProperty(PropertyEditRequest(
        property: "padding", newValue: "20px", kind: pekCss,
        scope: pesShared, origin: peoInspector))
      check edit.status == pesAccepted
      check edit.sourceEdit.sourceScope == sskSharedClass
      check edit.sourceEdit.sourceScopeChoices.anyIt(
        it.kind == sskSharedClass and it.impact.usageCount == 7)
      check edit.record.sourceScope == sskSharedClass

      let reviewId = vm.addReviewAnnotation("Keep this change shared.",
        suggestedScope = pesShared)
      check reviewId.len > 0
      check vm.review.annotations.val[0].sourceScopeChoices.anyIt(
        it.kind == sskSharedClass)

      let context = vm.buildAgentPromptContext()
      var agentMapHasSharedClass = false
      for entry in context.sourceMap:
        if entry.property == "padding":
          for choice in entry.sourceScopeChoices:
            if choice.kind == sskSharedClass:
              agentMapHasSharedClass = true
      check agentMapHasSharedClass

      let blocks = editorPromptContextToAcpContentBlocks(context,
        "Adjust the shared card padding.")
      let promptText = blocks.mapIt(it.text).join("\n")
      check promptText.contains("sourceScopeChoices:")
      check promptText.contains("kind=sskSharedClass")
      check promptText.contains("sourceScope=sskSharedClass")
      check promptText.contains("impact schema=classes.card.padding")
      check promptText.contains("usage=7")
      check promptText.contains("risk=ssrMedium") or
        promptText.contains("risk=ssrHigh")
      check promptText.contains("reviewAnnotations:")
      check promptText.contains("pendingSourceEdits:")
      dispose()

  test "m50_fallback_shared_count_sets_non_none_scope_risk":
    createRoot proc(dispose: proc()) =
      let vm = createEditorVM()
      check vm.selectInspectorElement(ElementRef(
        id: "fallback-card",
        sourceKey: "fallback.card",
        tag: "article",
        sourceFile: "card.nim",
        sourceLine: 12,
        properties: @[
          PropertyInfo(name: "padding", value: "12px",
            origin: poTailwindClass, originDetail: "class:shared-card",
            sourceFile: "card.css", sourceLine: 4,
            schemaKey: "classes.shared-card.padding", sharedCount: 9,
            directStyleAllowed: true)
        ]))
      let prop = vm.inspector.selectedElement.val.properties[0]
      let shared = vm.sourceScopeChoices(prop).filterIt(
        it.kind == sskSharedClass)[0]
      check shared.usageCount == 9
      check shared.riskLevel != ssrNone
      check shared.impact.riskLevel != ssrNone
      dispose()

  test "m52_shared_design_property_editors_plan_preview_undo_save_and_revert":
    createRoot proc(dispose: proc()) =
      let root = tempWorkspaceDir("m52-shared-design")
      defer: removeDir(root)

      createDir(root / "design")
      createDir(root / "components")
      let tokenFile = root / "design/tokens.schema"
      let classFile = root / "components/card.css"
      atomicWrite(tokenFile,
        "semantic.surface.card=#ffffff\n" &
        "component.card.radius=9px\n" &
        "component.card.fontSize=15px\n" &
        "component.card.shadow=0 8px 24px #0F172A\n" &
        "component.card.motion=120ms\n" &
        "component.card.padding=18px\n")
      atomicWrite(classFile, ".card { padding: 16px; }\nfilter=none\n")

      func sourceSpan(file: string; line: int): SourceSpan =
        SourceSpan(file: file, line: line, column: 1,
          endLine: line, endColumn: 40)

      let story = StoryRef(group: "Card", name: "Default", kind: skComponent,
        index: 0)
      let schema = DesignSystemSchema(
        schemaVersion: 1,
        projectId: "m52-example",
        ownerPackage: "isonim-example",
        frameworkContract: "isonim-editor-design-schema-v1",
        nodes: @[
          DesignSchemaNode(key: "semantic.surface.card",
            kind: dsnSemanticToken, name: "Surface card",
            property: "background-color", value: "#ffffff",
            sourceSpan: sourceSpan(tokenFile, 1), stories: @[story],
            components: @["Card"], usageCount: 6),
          DesignSchemaNode(key: "classes.card.padding",
            kind: dsnClassDefinition, name: "card",
            property: "padding", value: "16px",
            sourceSpan: sourceSpan(classFile, 1), stories: @[story],
            components: @["Card"], usageCount: 7),
          DesignSchemaNode(key: "component.card.padding",
            kind: dsnComponentToken, name: "Card padding token",
            property: "padding", value: "18px",
            sourceSpan: sourceSpan(tokenFile, 6), stories: @[story],
            components: @["Card"], usageCount: 4),
          DesignSchemaNode(key: "component.card.radius",
            kind: dsnComponentToken, name: "Card radius token",
            property: "border-radius", value: "9px",
            sourceSpan: sourceSpan(tokenFile, 2), stories: @[story],
            components: @["Card"], usageCount: 5),
          DesignSchemaNode(key: "component.card.fontSize",
            kind: dsnComponentToken, name: "Card font size token",
            property: "font-size", value: "15px",
            sourceSpan: sourceSpan(tokenFile, 3), stories: @[story],
            components: @["Card"], usageCount: 3),
          DesignSchemaNode(key: "component.card.shadow",
            kind: dsnComponentToken, name: "Card shadow token",
            property: "box-shadow", value: "0 8px 24px #0F172A",
            sourceSpan: sourceSpan(tokenFile, 4), stories: @[story],
            components: @["Card"], usageCount: 3),
          DesignSchemaNode(key: "component.card.motion",
            kind: dsnComponentToken, name: "Card motion token",
            property: "transition-duration", value: "120ms",
            sourceSpan: sourceSpan(tokenFile, 5), stories: @[story],
            components: @["Card"], usageCount: 3),
          DesignSchemaNode(key: "classes.card.filter",
            kind: dsnClassDefinition, name: "card-filter",
            property: "filter", value: "none",
            sourceSpan: sourceSpan(classFile, 2), stories: @[story],
            components: @["Card"], usageCount: 2)
        ])

      let workspaceSchema = @[
        WorkspaceEditableSchemaEntry(key: "semantic.surface.card",
          kind: wskToken, file: tokenFile, path: "semantic.surface.card",
          story: story, property: "background-color"),
        WorkspaceEditableSchemaEntry(key: "classes.card.padding",
          kind: wskSourceMap, file: classFile, path: "classes.card.padding",
          story: story, property: "padding"),
        WorkspaceEditableSchemaEntry(key: "component.card.padding",
          kind: wskToken, file: tokenFile, path: "component.card.padding",
          story: story, property: "padding"),
        WorkspaceEditableSchemaEntry(key: "component.card.radius",
          kind: wskToken, file: tokenFile, path: "component.card.radius",
          story: story, property: "border-radius"),
        WorkspaceEditableSchemaEntry(key: "component.card.fontSize",
          kind: wskToken, file: tokenFile, path: "component.card.fontSize",
          story: story, property: "font-size"),
        WorkspaceEditableSchemaEntry(key: "component.card.shadow",
          kind: wskToken, file: tokenFile, path: "component.card.shadow",
          story: story, property: "box-shadow"),
        WorkspaceEditableSchemaEntry(key: "component.card.motion",
          kind: wskToken, file: tokenFile, path: "component.card.motion",
          story: story, property: "transition-duration"),
        WorkspaceEditableSchemaEntry(key: "classes.card.filter",
          kind: wskSourceMap, file: classFile, path: "classes.card.filter",
          story: story, property: "filter")
      ]
      let recorder = WorkspaceEditRecorder()
      let adapter = adapterFor(root, workspaceSchema, recorder = recorder)
      let vm = createEditorVM(newEditorWorkspace(
        title = "M52 shared design workspace",
        storyGroups = @[StoryGroup(name: "Card", kind: skComponent,
          items: @[StoryItem(name: "Default", kind: skComponent,
            group: "Card")])],
        initialStory = some(story),
        permissions = EditorWorkspacePermissions(readSource: true,
          writeSource: true),
        sourceAdapterReady = true,
        editAdapter = adapter,
        designSystemSchema = schema,
        previewHook = proc(story: StoryRef;
            platform: Platform): ProjectPreview {.closure.} =
          ProjectPreview(status: ppsRendered, story: story,
            title: "Card preview", bodyText: "Card preview " & $platform,
            metadata: StoryRenderMetadata(story: story,
              sourceFile: tokenFile, sourceLine: 1))))
      check vm.selectInspectorElement(ElementRef(
        id: "card-root",
        sourceKey: "card.root",
        tag: "article",
        sourceFile: tokenFile,
        sourceLine: 1,
        properties: @[
          PropertyInfo(name: "background-color", value: "#ffffff",
            origin: poThemeToken, originDetail: "token:semantic.surface.card",
            sourceFile: tokenFile, sourceLine: 1,
            schemaKey: "semantic.surface.card",
            tokenName: "semantic.surface.card", sharedCount: 6,
            directStyleAllowed: true),
          PropertyInfo(name: "padding", value: "16px",
            origin: poTailwindClass, originDetail: "class:card",
            sourceFile: classFile, sourceLine: 1,
            schemaKey: "classes.card.padding", sharedCount: 7,
            directStyleAllowed: true),
          PropertyInfo(name: "border-radius", value: "9px",
            origin: poThemeToken, originDetail: "token:component.card.radius",
            sourceFile: tokenFile, sourceLine: 2,
            schemaKey: "component.card.radius",
            tokenName: "component.card.radius", sharedCount: 5,
            directStyleAllowed: true),
          PropertyInfo(name: "font-size", value: "15px",
            origin: poThemeToken, originDetail: "token:component.card.fontSize",
            sourceFile: tokenFile, sourceLine: 3,
            schemaKey: "component.card.fontSize",
            tokenName: "component.card.fontSize", sharedCount: 3,
            directStyleAllowed: true),
          PropertyInfo(name: "box-shadow", value: "0 8px 24px #0F172A",
            origin: poThemeToken, originDetail: "token:component.card.shadow",
            sourceFile: tokenFile, sourceLine: 4,
            schemaKey: "component.card.shadow",
            tokenName: "component.card.shadow", sharedCount: 3,
            directStyleAllowed: true),
          PropertyInfo(name: "transition-duration", value: "120ms",
            origin: poThemeToken, originDetail: "token:component.card.motion",
            sourceFile: tokenFile, sourceLine: 5,
            schemaKey: "component.card.motion",
            tokenName: "component.card.motion", sharedCount: 3,
            directStyleAllowed: true),
          PropertyInfo(name: "filter", value: "none",
            origin: poTailwindClass, originDetail: "class:card-filter",
            sourceFile: classFile, sourceLine: 2,
            schemaKey: "classes.card.filter", sharedCount: 2,
            directStyleAllowed: true)
        ]))

      let unsupported = vm.planSharedDesignEdit("filter", "blur(2px)",
        sskSharedClass)
      check unsupported.status == pesRejected
      check unsupported.diagnostics.anyIt(it.message.contains("read-only"))

      let cases = @[
        ("background-color", "#f8fafc", sskSemanticToken, sdecColor,
          cspTokenUpdate),
        ("padding", "24px", sskSharedClass, sdecSpacing,
          cspStructuredSchemaUpdate),
        ("border-radius", "12px", sskComponentToken, sdecRadii,
          cspTokenUpdate),
        ("font-size", "16px", sskComponentToken, sdecTypography,
          cspTokenUpdate),
        ("box-shadow", "0 10px 30px #0F172A", sskComponentToken,
          sdecShadowElevation, cspTokenUpdate),
        ("transition-duration", "180ms", sskComponentToken, sdecMotion,
          cspTokenUpdate)
      ]
      for item in cases:
        let planned = vm.planSharedDesignEdit(item[0], " " & item[1] & " ",
          item[2])
        check planned.status == pesAccepted
        check planned.editor.category == item[3]
        check planned.editor.value.canonical == item[1]
        check planned.sourceEdit.planKind == item[4]
        check planned.sourceEdit.sourceScope == item[2]
        check planned.editor.commitPreview.sourceDiff.contains("+ " & item[0])
        check planned.editor.commitPreview.affectedComponents == @["Card"]
        check planned.editor.commitPreview.affectedStories == @[story]
        check planned.editor.commitPreview.livePreviewable
        check planned.editor.commitPreview.dependentExamplesLivePreviewed
        check planned.editor.commitPreview.rebuildRequired
        check planned.editor.commitPreview.regenerationRequired
        check planned.editor.commitPreview.fullReloadRequired
        check planned.editor.commitPreview.reloadRequired
        check planned.editor.commitPreview.previewStateLabel.contains(
          "commit: rebuild + full reload")

        let edited = vm.editSharedDesignProperty(item[0], " " & item[1] & " ",
          item[2])
        check edited.status == pesAccepted
        check vm.inspector.pendingSourceEdits.val.anyIt(
          it.property == item[0] and it.sourceScope == item[2])
        check vm.inspector.undoCssPropertyEdit()
        check vm.inspector.redoCssPropertyEdit()

      check vm.sharedDesignCommitPreviews().len == cases.len
      check vm.sharedDesignCommitPreviews().allIt(
        it.sourceDiff.contains("--- ") and it.affectedStories.len == 1 and
        it.regenerationRequired and it.fullReloadRequired)
      let invalid = vm.planSharedDesignEdit("padding", "-1px",
        sskSharedClass)
      check invalid.status == pesRejected
      check invalid.diagnostics.anyIt(it.kind == pedInvalidCssValue)

      let saved = vm.applyWorkspaceFileEdits()
      check saved.ok
      check readFile(tokenFile).contains("#f8fafc")
      check readFile(tokenFile).contains("12px")
      check readFile(tokenFile).contains("16px")
      check readFile(tokenFile).contains("0 10px 30px #0F172A")
      check readFile(tokenFile).contains("180ms")
      check readFile(classFile).contains("24px")
      check vm.inspector.pendingSourceEdits.val.len == 0
      check recorder.reloadedStories.len >= 1
      check recorder.reloadedStories.anyIt(it.group == "Card" and
        it.name == "Default")

      discard vm.editSharedDesignProperty("padding", "28px", sskSharedClass)
      check vm.inspector.selectedElement.val.properties.anyIt(
        it.name == "padding" and it.value == "28px")
      let reverted = vm.runEditorCommand(eckRevert)
      check reverted.status == ecsSucceeded
      check vm.inspector.selectedElement.val.properties.anyIt(
        it.name == "padding" and it.value == "24px")
      check vm.inspector.pendingSourceEdits.val.len == 0
      dispose()

  test "m53_component_api_variant_fixture_and_css_surfaces_are_explicit":
    createRoot proc(dispose: proc()) =
      let root = tempWorkspaceDir("m53-component-api")
      defer: removeDir(root)

      let componentFile = root / "components/card.schema"
      let fixtureFile = root / "fixtures/card.fixture"
      let classFile = root / "components/card.css"
      createDir(root / "components")
      createDir(root / "fixtures")
      atomicWrite(componentFile,
        "size=md\nhover=false\nresponsive.compact=compact-off\n")
      atomicWrite(fixtureFile, "title=Paris\n")
      atomicWrite(classFile, "padding=16px\n")
      let defaultStory = StoryRef(group: "Card", name: "Default",
        kind: skComponent, index: 0)
      let compactStory = StoryRef(group: "Card", name: "Compact",
        kind: skComponent, index: 1)
      let schemaEntries = @[
        WorkspaceEditableSchemaEntry(key: "components.card.props.size",
          kind: wskComponentVariant, file: componentFile,
          path: "Card.default.size", story: defaultStory, property: "size"),
        WorkspaceEditableSchemaEntry(key: "components.card.states.hover",
          kind: wskComponentVariant, file: componentFile,
          path: "Card.default.state.hover", story: defaultStory,
          property: "state.hover"),
        WorkspaceEditableSchemaEntry(key: "components.card.responsive.compact",
          kind: wskComponentVariant, file: componentFile,
          path: "Card.default.responsive.compact", story: compactStory,
          property: "responsive.compact"),
        WorkspaceEditableSchemaEntry(key: "fixtures.card.title",
          kind: wskStoryFixture, file: fixtureFile,
          path: "fixtures.card.title", story: defaultStory,
          property: "title"),
        WorkspaceEditableSchemaEntry(key: "classes.card.padding",
          kind: wskSourceMap, file: classFile, path: "classes.card.padding",
          story: defaultStory, property: "padding")
      ]
      let designSchema = DesignSystemSchema(
        schemaVersion: 1,
        projectId: "m53-example",
        ownerPackage: "isonim-example",
        frameworkContract: "isonim-editor-design-schema-v1",
        nodes: @[
          DesignSchemaNode(key: "classes.card.padding",
            kind: dsnClassDefinition, name: "card padding",
            component: "Card", property: "padding", value: "16px",
            sourceSpan: SourceSpan(file: classFile, line: 1, column: 1,
              endLine: 1, endColumn: 20),
            stories: @[defaultStory, compactStory],
            components: @["Card", "CardList"], usageCount: 8)
        ])
      let variants = @[
        ComponentVariantDefinition(
          component: "Card",
          variantKey: "default",
          story: defaultStory,
          fixtureName: "card.default",
          metadataName: "Default",
          fields: @[
            ComponentVariantField(name: "responsive.compact",
              kind: cvfkResponsiveBehavior, value: "compact-off",
              sourceFile: componentFile, sourceLine: 3,
              schemaKey: "components.card.responsive.compact")
          ],
          properties: @[
            ComponentPropertyDefinition(name: "size", kind: cpkEnum,
              value: "md", options: @["sm", "md", "lg"],
              sourceFile: componentFile, sourceLine: 1,
              schemaKey: "components.card.props.size",
              constructor: "card-schema"),
            ComponentPropertyDefinition(name: "title", kind: cpkDataFixture,
              value: "Paris", sourceFile: fixtureFile, sourceLine: 1,
              schemaKey: "components.card.props.title",
              fixtureKey: "fixtures.card.title",
              constructor: "card-fixture")
          ],
          stateControls: @[
            ComponentStateControl(key: "hover", kind: cskHover,
              label: "hover", value: "false", options: @["false", "true"],
              story: defaultStory, fixtureName: "card.hover",
              sourceFile: componentFile, sourceLine: 2,
              schemaKey: "components.card.states.hover")
          ]),
        ComponentVariantDefinition(
          component: "Card",
          variantKey: "compact",
          story: compactStory,
          fixtureName: "card.compact",
          metadataName: "Compact",
          properties: @[
            ComponentPropertyDefinition(name: "size", kind: cpkEnum,
              value: "sm", options: @["sm", "md", "lg"],
              sourceFile: componentFile, sourceLine: 1,
              schemaKey: "components.card.props.size",
              constructor: "card-schema")
          ])
      ]
      let recorder = WorkspaceEditRecorder()
      let vm = createEditorVM(newEditorWorkspace(
        title = "M53 component API workspace",
        storyGroups = @[StoryGroup(name: "Card", kind: skComponent,
          items: @[
            StoryItem(name: "Default", kind: skComponent, group: "Card"),
            StoryItem(name: "Compact", kind: skComponent, group: "Card")
          ])],
        componentVariants = variants,
        designSystemSchema = designSchema,
        permissions = EditorWorkspacePermissions(readSource: true,
          writeSource: true),
        editAdapter = adapterFor(root, schemaEntries, recorder = recorder),
        initialStory = some(defaultStory)))
      check vm.selectInspectorElement(ElementRef(
        id: "card-root",
        sourceKey: "card.root",
        schemaKey: "components.card.props.size",
        tag: "article",
        sourceFile: componentFile,
        sourceLine: 1,
        properties: @[
          PropertyInfo(name: "padding", value: "16px",
            origin: poTailwindClass, originDetail: "class:card",
            sourceFile: classFile, sourceLine: 1,
            schemaKey: "classes.card.padding", sharedCount: 8,
            directStyleAllowed: true)
        ]))

      let surfaces = vm.componentPropertySurfaces("Card")
      check surfaces.anyIt(it.surfaceKind == cpskComponentApi and
        it.property == "size" and it.targetKind == cetComponentProp and
        it.impact.blastRadius == cebrAllVariantsOfComponent and
        it.impact.affectedVariantKeys.len == 2)
      check surfaces.anyIt(it.surfaceKind == cpskComponentApi and
        it.property == "title" and it.targetKind == cetFixture and
        it.impact.blastRadius == cebrOneStory)
      check surfaces.anyIt(it.surfaceKind == cpskComponentApi and
        it.property == "state.hover" and it.targetKind == cetPseudoState)
      check surfaces.anyIt(it.surfaceKind == cpskCssOnly and
        it.property == "padding" and it.targetKind == cetSharedDesignSystem and
        it.impact.blastRadius == cebrSharedDesignSystem and
        it.impact.usageCount == 8)

      let propEdit = vm.editComponentProperty("Card", "default", "size", "lg")
      check propEdit.status == pesAccepted
      check propEdit.sourceEdit.sourceScope == sskComponentSchemaApi
      check propEdit.impact.blastRadius == cebrAllVariantsOfComponent
      check propEdit.impact.affectedVariantKeys == @["default", "compact"]

      let fixtureEdit = vm.editComponentProperty("Card", "default", "title",
        "Sofia")
      check fixtureEdit.status == pesAccepted
      check fixtureEdit.sourceEdit.sourceScope == sskStoryFixture
      check fixtureEdit.impact.blastRadius == cebrOneStory

      let stateEdit = vm.editComponentStateControl("Card", "default", "hover",
        "true")
      check stateEdit.status == pesAccepted
      check stateEdit.impact.targetKind == cetPseudoState
      check stateEdit.sourceEdit.schemaKey == "components.card.states.hover"

      let responsiveEdit = vm.editComponentVariantField("Card", "default",
        "responsive.compact", "compact-on")
      check responsiveEdit.status == pesAccepted
      check responsiveEdit.impact.targetKind == cetResponsive
      check responsiveEdit.sourceEdit.sourceScope == sskComponentSchemaApi

      let saved = vm.applyWorkspaceFileEdits()
      check saved.ok
      check readFile(componentFile).contains("lg")
      check readFile(componentFile).contains("true")
      check readFile(fixtureFile).contains("Sofia")
      dispose()

  test "m54_source_edit_journal_covers_local_component_shared_token_and_ai_scopes":
    createRoot proc(dispose: proc()) =
      let root = tempWorkspaceDir("m54-journal")
      defer: removeDir(root)

      let styleFile = root / "card.css"
      let componentFile = root / "card.schema"
      let tokenFile = root / "tokens.schema"
      atomicWrite(styleFile, "color=#111827\npadding=16px\n")
      atomicWrite(componentFile, "size=md\ntitle=Paris\n")
      atomicWrite(tokenFile, "surface=#ffffff\n")
      let story = StoryRef(group: "Card", name: "Default",
        kind: skComponent, index: 0)
      let schema = @[
        WorkspaceEditableSchemaEntry(key: "local.card.color",
          kind: wskSourceMap, file: styleFile, path: "card.color",
          story: story, property: "color"),
        WorkspaceEditableSchemaEntry(key: "classes.card.padding",
          kind: wskSourceMap, file: styleFile, path: "card.padding",
          story: story, property: "padding"),
        WorkspaceEditableSchemaEntry(key: "components.card.props.size",
          kind: wskComponentVariant, file: componentFile,
          path: "Card.default.size", story: story, property: "size"),
        WorkspaceEditableSchemaEntry(key: "fixtures.card.title",
          kind: wskStoryFixture, file: componentFile,
          path: "Card.default.title", story: story, property: "title"),
        WorkspaceEditableSchemaEntry(key: "tokens.surface",
          kind: wskToken, file: tokenFile, path: "tokens.surface",
          story: story, property: "surface")
      ]
      let variants = @[
        ComponentVariantDefinition(component: "Card", variantKey: "default",
          story: story,
          properties: @[ComponentPropertyDefinition(name: "size",
            kind: cpkEnum, value: "md", options: @["sm", "md", "lg"],
            sourceFile: componentFile, sourceLine: 1,
            schemaKey: "components.card.props.size",
            constructor: "card-schema")])
      ]
      let recorder = WorkspaceEditRecorder()
      let vm = createEditorVM(newEditorWorkspace(
        title = "M54 journal workspace",
        storyGroups = @[StoryGroup(name: "Card", kind: skComponent,
          items: @[StoryItem(name: "Default", kind: skComponent,
            group: "Card")])],
        foundationTokens = @[FoundationTokenEntry(key: "surface",
          kind: ftkSemanticColor, value: "#ffffff",
          sourceFile: tokenFile, sourceLine: 1,
          schemaKey: "tokens.surface", property: "surface",
          affectedStories: @[story])],
        componentVariants = variants,
        permissions = EditorWorkspacePermissions(readSource: true,
          writeSource: true),
        editAdapter = adapterFor(root, schema, recorder = recorder),
        initialStory = some(story)))
      check vm.selectInspectorElement(ElementRef(id: "card",
        sourceKey: "card", schemaKey: "local.card.color", tag: "article",
        sourceFile: styleFile, sourceLine: 1,
        properties: @[
          PropertyInfo(name: "color", value: "#111827",
            origin: poConstant, originDetail: "schema:local.card.color",
            sourceFile: styleFile, sourceLine: 1,
            schemaKey: "local.card.color"),
          PropertyInfo(name: "padding", value: "16px",
            origin: poTailwindClass, originDetail: "class:card",
            sourceFile: styleFile, sourceLine: 2,
            schemaKey: "classes.card.padding", sharedCount: 3)
        ]))

      check vm.editCssProperty("color", "#0f172a", pesLocal).status == pesAccepted
      check vm.editSharedDesignProperty("padding", "20px",
        sskSharedClass).status == pesAccepted
      check vm.editFoundationToken("surface", "#f8fafc").status == pesAccepted
      let componentEdit = vm.editComponentProperty("Card", "default", "size",
        "lg")
      check componentEdit.status == pesAccepted
      check vm.inspector.pendingSourceEdits.val.len == 4
      check vm.inspector.sourcePreviews.val.len == 4
      check vm.inspector.sourceJournalOwnershipDiagnostics().len == 0

      check vm.undoComponentVariantEdit()
      check vm.variants.variants.val[0].properties[0].value == "md"
      check vm.inspector.pendingSourceEdits.val.len == 3
      check vm.redoComponentVariantEdit()
      check vm.variants.variants.val[0].properties[0].value == "lg"
      check vm.inspector.pendingSourceEdits.val.len == 4

      let saved = vm.applyWorkspaceFileEdits()
      check saved.ok
      check readFile(styleFile).contains("color=#0f172a")
      check readFile(styleFile).contains("padding=20px")
      check readFile(componentFile).contains("size=lg")
      check readFile(tokenFile).contains("surface=#f8fafc")

      discard vm.chat.addAgentEditProposal(AgentEditProposal(
        title: "Fixture title",
        summary: "Change fixture title",
        sourceEdits: @[planFor(componentFile, "title", "Paris", "Sofia",
          "fixtures.card.title")],
        selectedEditIndexes: @[0],
        validity: aepvCurrent))
      let accepted = vm.acceptAgentProposedEdit("agent-proposal-1")
      check accepted.ok
      check readFile(componentFile).contains("title=Sofia")
      dispose()

  test "m54_conflict_retry_and_stale_source_diagnostics_keep_journal_dirty":
    createRoot proc(dispose: proc()) =
      let root = tempWorkspaceDir("m54-conflict")
      defer: removeDir(root)
      let schemaFile = root / "card.schema"
      atomicWrite(schemaFile, "padding=20px\n")
      let schema = @[WorkspaceEditableSchemaEntry(
        key: "components.card.padding", kind: wskSourceMap,
        file: schemaFile, path: "card.padding", story: writeStory,
        property: "padding")]
      let recorder = WorkspaceEditRecorder()
      let vm = createEditorVM(newEditorWorkspace(
        title = "M54 conflict workspace",
        storyGroups = @[StoryGroup(name: "Card", kind: skComponent,
          items: @[StoryItem(name: "Default", kind: skComponent,
            group: "Card")])],
        permissions = EditorWorkspacePermissions(readSource: true,
          writeSource: true),
        editAdapter = adapterFor(root, schema, recorder = recorder)))
      vm.inspector.journalSourceEdit(planFor(schemaFile, "padding", "16px",
        "24px", "components.card.padding"))
      vm.workspaceEditStage.val = wesDirty

      let conflicted = vm.applyWorkspaceFileEdits()
      check not conflicted.ok
      check conflicted.diagnostics.anyIt(
        it.kind == wedSourceConflict and it.message.contains("retry"))
      check vm.inspector.pendingSourceEdits.val.len == 1
      check vm.workspaceEditStage.val == wesFailed

      atomicWrite(schemaFile, "padding=16px\n")
      let retried = vm.retryWorkspaceFileEdits()
      check retried.ok
      check readFile(schemaFile).contains("padding=24px")
      check vm.inspector.pendingSourceEdits.val.len == 0

      vm.inspector.journalSourceEdit(SourceEditPlan(
        file: schemaFile, property: "opacity", oldValue: "1",
        newValue: "0.8", scope: pesUnspecified,
        schemaKey: "components.card.opacity",
        conflictKey: schemaFile & ":opacity"))
      check vm.inspector.sourceJournalOwnershipDiagnostics().anyIt(
        it.message.contains("explicit ownership scope"))
      dispose()

  test "agent_proposals_target_design_schema_scopes":
    createRoot proc(dispose: proc()) =
      let root = tempWorkspaceDir("agent-proposal-scopes")
      defer: removeDir(root)

      let schemaFile = root / "card.schema"
      atomicWrite(schemaFile, "padding=16px\nmargin=8px\n")
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
        title = "M41 agent proposal workspace",
        storyGroups = @[],
        initialStory = some(writeStory),
        permissions = EditorWorkspacePermissions(readSource: true,
          writeSource: true),
        editAdapter = adapterFor(root, schema, recorder = recorder),
        agentBackend = absAgentHarbor))
      check vm.selectInspectorElement(ElementRef(
        id: "card",
        sourceKey: "components.card.padding",
        schemaKey: "components.card.padding",
        tag: "article",
        sourceFile: schemaFile,
        sourceLine: 1,
        properties: @[PropertyInfo(name: "padding", value: "16px",
          origin: poConstant, originDetail: "schema:components.card.padding",
          sourceFile: schemaFile, sourceLine: 1,
          schemaKey: "components.card.padding")]))

      let proposalId = vm.chat.addAgentEditProposal(AgentEditProposal(
        title: "Scoped spacing proposal",
        summary: "padding shared schema scope",
        sourceEdits: @[planFor(schemaFile, "padding", "16px", "24px",
          "components.card.padding")],
        diffs: @[AgentFileDiff(file: schemaFile, beforeText: "padding=16px",
          afterText: "padding=24px", summary: "padding 16px -> 24px")],
        impact: AgentProposalImpact(summary: "Updates Card default padding.",
          affectedStories: @[writeStory],
          affectedComponents: @["Card"]),
        affectedStories: @[writeStory],
        tests: @["compile DestinationCard/Default",
          "reload affected story preview"]))
      let proposal = vm.chat.proposedEdits.val[^1]
      check proposal.id == proposalId
      check proposal.targetScopes == @[pesShared]
      check proposal.validity == aepvCurrent
      check proposal.impact.summary.contains("Card")
      check proposal.affectedStories == @[writeStory]
      check proposal.tests.len == 2
      check proposal.diffs[0].summary.contains("24px")

      let accepted = vm.acceptAgentProposedEdit(proposalId)
      check accepted.ok
      check readFile(schemaFile).contains("padding=24px")
      check recorder.reviewCount > 0

      let staleId = vm.chat.addAgentEditProposal(AgentEditProposal(
        title: "Stale padding proposal",
        summary: "padding against current schema scope",
        sourceEdits: @[planFor(schemaFile, "padding", "24px", "32px",
          "components.card.padding")],
        diffs: @[AgentFileDiff(file: schemaFile, beforeText: "padding=24px",
          afterText: "padding=32px", summary: "padding 24px -> 32px")],
        tests: @["compile DestinationCard/Default"]))
      let manual = vm.editCssProperty("padding", "28px", pesShared)
      check manual.status == pesAccepted
      check vm.chat.proposedEdits.val.anyIt(
        it.id == staleId and it.validity == aepvNeedsRebase)
      let rejected = vm.acceptAgentProposedEdit(staleId)
      check not rejected.ok
      var rerunPrompt = ""
      vm.chat.configureAgentAdapters(
        proc(prompt: string; context: AgentPromptContext): bool =
          rerunPrompt = prompt
          true,
        nil,
        absAgentHarbor)
      check vm.rebaseAgentProposedEdit(staleId)
      check rerunPrompt.contains("Rebase proposed edit")
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
