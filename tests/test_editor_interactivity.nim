## Tests for IsoNim Editor — interactivity milestones (M4-M7)
## Verifies ViewModel-level interactivity wiring.
## Playwright-based visual tests will be added when the browser app is running.

import std/[unittest, tables]
import isonim/core/[signals, computation, owner]
import isonim/testing/mock_dom
import isonim/viewmodel
import isonim/editor/viewmodels
import isonim/editor/user_project_vms
import isonim/editor/stories
import isonim/editor/types
import isonim/editor/views/shell
import isonim/editor/views/task_views

suite "M4 — Edit Mode & Selection":

  test "test_edit_mode_toggle":
    createRoot proc(dispose: proc()) =
      let vm = createEditorVM()
      check vm.editMode.val == emView

      vm.editMode.val = emEdit
      check vm.editMode.val == emEdit

      vm.editMode.val = emView
      check vm.editMode.val == emView
      dispose()

  test "test_story_selection_updates_preview":
    createRoot proc(dispose: proc()) =
      let vm = createEditorVM()
      vm.sidebar.groups.val = buildStoryboard()

      check vm.hasSelection.val == false

      let story = StoryRef(group: "TaskRow", name: "Active task", kind: skComponent)
      vm.sidebar.selectStory(vm, story)

      check vm.hasSelection.val == true
      check vm.selectedStory.val.group == "TaskRow"
      dispose()

  test "test_element_selection_populates_inspector":
    createRoot proc(dispose: proc()) =
      let vm = createEditorVM()
      let elem = ElementRef(
        tag: "div",
        sourceFile: "controls.nim", sourceLine: 42,
        properties: @[
          PropertyInfo(name: "padding", value: "16", origin: poTailwindClass,
                       originDetail: "p-4", sharedCount: 0),
        ])

      vm.inspector.selectElement(elem)
      check vm.inspector.hasElement.val == true
      check vm.inspector.properties.val.len == 1
      check vm.inspector.properties.val[0].name == "padding"

      vm.inspector.clearSelection()
      check vm.inspector.hasElement.val == false
      dispose()

  test "test_inspector_section_switching":
    createRoot proc(dispose: proc()) =
      let vm = createEditorVM()
      check vm.inspector.activeSection.val == isLayout

      vm.inspector.setSection(isFill)
      check vm.inspector.activeSection.val == isFill

      vm.inspector.setSection(isTypography)
      check vm.inspector.activeSection.val == isTypography
      dispose()

suite "M5 — Property Editing (Mocked)":

  test "test_property_edit_updates_vm":
    ## Editing a property value in the inspector updates the ViewModel
    createRoot proc(dispose: proc()) =
      let vm = createEditorVM()
      let elem = ElementRef(
        tag: "div", sourceFile: "controls.nim", sourceLine: 42,
        properties: @[
          PropertyInfo(name: "padding", value: "12", origin: poTailwindClass),
        ])
      vm.inspector.selectElement(elem)

      # Simulate inspector edit: change padding from 12 to 16
      var updatedElem = elem
      updatedElem.properties[0].value = "16"
      vm.inspector.selectElement(updatedElem)

      check vm.inspector.properties.val[0].value == "16"

      # Record the edit for agent context
      vm.chat.recordEdit(EditRecord(
        file: "controls.nim", line: 42,
        property: "padding", oldValue: "12", newValue: "16"))
      check vm.chat.accumulatedEdits.val.len == 1
      dispose()

  test "test_shared_property_detection":
    createRoot proc(dispose: proc()) =
      let vm = createEditorVM()
      let elem = ElementRef(
        tag: "div", sourceFile: "controls.nim", sourceLine: 42,
        properties: @[
          PropertyInfo(name: "padding", value: "16", origin: poTailwindClass,
                       sharedCount: 0),
          PropertyInfo(name: "background-color", value: "#6366F1",
                       origin: poThemeToken, originDetail: "themeColor(\"primary\")",
                       sharedCount: 4),
        ])
      vm.inspector.selectElement(elem)

      let props = vm.inspector.properties.val
      check props[0].sharedCount == 0  # local
      check props[1].sharedCount == 4  # shared by 4 elements
      check props[1].origin == poThemeToken
      dispose()

suite "M6 — Flow Playback":

  test "test_flow_step_through":
    createRoot proc(dispose: proc()) =
      let vm = createEditorVM()
      let flows = userFlows()
      let firstFlow = flows[0]  # "First Task"

      vm.flowPlayer.steps.val = firstFlow.steps
      check vm.flowPlayer.totalSteps.val == 3
      check vm.flowPlayer.currentStep.val == 0
      check vm.flowPlayer.currentAction.val == firstFlow.steps[0].action

      vm.flowPlayer.nextStep()
      check vm.flowPlayer.currentStep.val == 1

      vm.flowPlayer.nextStep()
      check vm.flowPlayer.currentStep.val == 2
      check vm.flowPlayer.isLastStep.val == true
      dispose()

  test "test_flow_play_pause_stop":
    createRoot proc(dispose: proc()) =
      let vm = createEditorVM()
      vm.flowPlayer.steps.val = userFlows()[0].steps

      check vm.flowPlayer.playState.val == psStopped

      vm.flowPlayer.play()
      check vm.flowPlayer.playState.val == psPlaying

      vm.flowPlayer.pause()
      check vm.flowPlayer.playState.val == psPaused

      vm.flowPlayer.stop()
      check vm.flowPlayer.playState.val == psStopped
      check vm.flowPlayer.currentStep.val == 0
      dispose()

suite "M7 — Agent Chat":

  test "test_chat_message_flow":
    createRoot proc(dispose: proc()) =
      let vm = createEditorVM()
      check vm.chat.messageCount.val == 0

      # User sends a message
      vm.chat.inputText.val = "Make the cards more rounded"
      vm.chat.addUserMessage(vm.chat.inputText.val)

      check vm.chat.messageCount.val == 1
      check vm.chat.messages.val[0].kind == cmkUser
      check vm.chat.messages.val[0].text == "Make the cards more rounded"
      check vm.chat.inputText.val == ""  # cleared after send

      # Agent responds
      vm.chat.addAgentResponse("Changed rounded-xl to rounded-2xl in branded_controls.nim")
      check vm.chat.messageCount.val == 2
      check vm.chat.messages.val[1].kind == cmkAgent
      dispose()

  test "test_chat_accumulated_edits_sent_with_prompt":
    createRoot proc(dispose: proc()) =
      let vm = createEditorVM()

      # User makes inspector edits
      vm.chat.recordEdit(EditRecord(file: "controls.nim", line: 42,
        property: "padding", oldValue: "12", newValue: "16"))
      vm.chat.recordEdit(EditRecord(file: "controls.nim", line: 23,
        property: "bg", oldValue: "slate-50", newValue: "white"))

      check vm.chat.accumulatedEdits.val.len == 2

      # User sends prompt — edits are available for context
      vm.chat.addUserMessage("Now add a shadow")
      check vm.chat.accumulatedEdits.val.len == 2  # still available

      # After agent processes, edits are cleared
      vm.chat.clearAccumulatedEdits()
      check vm.chat.accumulatedEdits.val.len == 0
      dispose()

  test "test_review_results_in_chat":
    createRoot proc(dispose: proc()) =
      let vm = createEditorVM()

      vm.review.violations.val = @[
        Violation(severity: vsWarning, category: vcTailwindPreference,
                  message: "setStyle(\"padding\",\"16\") — use class=\"p-4\"",
                  file: "controls.nim", line: 42, autoFixable: true),
      ]

      check vm.review.hasIssues.val == true
      check vm.review.warningCount.val == 1
      check vm.review.errorCount.val == 0
      check vm.review.violations.val[0].autoFixable == true
      dispose()
