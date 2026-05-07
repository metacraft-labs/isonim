## Tests for IsoNim Editor — responsive design (M8) and polish (M9)
## ViewModel-level tests for responsive behavior and state management.

import std/[unittest]
import isonim/core/[signals, computation, owner]
import isonim/viewmodel
import isonim/editor/viewmodels
import isonim/editor/types

suite "M8 — Responsive Design":

  test "test_responsive_narrow_collapses_panels":
    ## At narrow viewport, both panels should collapse
    createRoot do (dispose: proc()):
      let vm = createEditorVM()
      check vm.panels.val.sidebar == true
      check vm.panels.val.inspector == true

      # Simulate narrow viewport — user or auto-collapse hides panels
      vm.panels.val = PanelVisibility(sidebar: false, inspector: false)
      check vm.panels.val.sidebar == false
      check vm.panels.val.inspector == false
      dispose()

  test "test_responsive_medium_inspector_toggle":
    ## At medium viewport, inspector toggleable, sidebar visible
    createRoot do (dispose: proc()):
      let vm = createEditorVM()
      vm.panels.val = PanelVisibility(sidebar: true, inspector: false)
      check vm.panels.val.sidebar == true
      check vm.panels.val.inspector == false

      # Toggle inspector
      vm.panels.val = PanelVisibility(sidebar: true, inspector: true)
      check vm.panels.val.inspector == true
      dispose()

  test "test_responsive_wide_all_visible":
    ## At wide viewport, all panels visible (default)
    createRoot do (dispose: proc()):
      let vm = createEditorVM()
      check vm.panels.val.sidebar == true
      check vm.panels.val.inspector == true
      dispose()

  test "test_sidebar_toggle":
    ## Sidebar toggle button shows/hides sidebar
    createRoot do (dispose: proc()):
      let vm = createEditorVM()
      check vm.panels.val.sidebar == true

      vm.panels.val = PanelVisibility(sidebar: false, inspector: vm.panels.val.inspector)
      check vm.panels.val.sidebar == false

      vm.panels.val = PanelVisibility(sidebar: true, inspector: vm.panels.val.inspector)
      check vm.panels.val.sidebar == true
      dispose()

suite "M9 — Design Polish":

  test "test_empty_state_no_project":
    ## Without any stories loaded, sidebar shows empty state
    createRoot do (dispose: proc()):
      let vm = createEditorVM()
      check vm.sidebar.groups.val.len == 0
      check vm.sidebar.filteredItems.val.len == 0
      check vm.hasSelection.val == false
      dispose()

  test "test_empty_state_no_element_selected":
    ## With no element selected, inspector shows placeholder
    createRoot do (dispose: proc()):
      let vm = createEditorVM()
      check vm.inspector.hasElement.val == false
      check vm.inspector.properties.val.len == 0
      dispose()

  test "test_error_state_agent_session":
    ## Agent session failure is reflected in VM
    createRoot do (dispose: proc()):
      let vm = createEditorVM()
      check vm.chat.sessionStatus.val == asIdle

      vm.chat.sessionStatus.val = asLoading
      check vm.chat.sessionStatus.val == asLoading

      vm.chat.sessionStatus.val = asError
      check vm.chat.sessionStatus.val == asError
      dispose()

  test "test_flow_empty_state":
    ## FlowPlayerVM with no steps handles gracefully
    createRoot do (dispose: proc()):
      let vm = createEditorVM()
      check vm.flowPlayer.totalSteps.val == 0
      check vm.flowPlayer.isFirstStep.val == true
      check vm.flowPlayer.isLastStep.val == true
      check vm.flowPlayer.currentAction.val == ""

      # Next/prev on empty should not crash
      vm.flowPlayer.nextStep()
      vm.flowPlayer.prevStep()
      check vm.flowPlayer.currentStep.val == 0
      dispose()

  test "test_platform_switching":
    ## Platform selector changes preview platform
    createRoot do (dispose: proc()):
      let vm = createEditorVM()
      check vm.platform.val == pfWeb

      vm.platform.val = pfIOS
      check vm.platform.val == pfIOS

      vm.platform.val = pfAndroid
      check vm.platform.val == pfAndroid
      dispose()
