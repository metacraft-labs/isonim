## Tests for IsoNim Editor ViewModels (M0)

import std/[unittest, strutils]
import isonim/core/[signals, computation, owner]
import isonim/viewmodel
import isonim/editor/viewmodels
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
      check vm.activeView.val == evStoryboard
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
