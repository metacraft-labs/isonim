## Tests for IsoNim Editor — simulated user project ViewModels (M1)

import std/[unittest, strutils, sequtils]
import isonim/core/[signals, computation, owner]
import isonim/viewmodel
import isonim/editor/user_project_vms
import isonim/editor/stories
import isonim/editor/types

suite "User Project ViewModels (M1)":

  test "test_task_row_vm_state_transitions":
    ## TaskRowVM transitions through active/completed/editing/saving/error
    createRoot do (dispose: proc()):
      let vm = createTaskRowVM(TaskData(id: 1, text: "Test", completed: false))
      check vm.displayState.val == tdsActive
      check vm.isCompleted.val == false

      # Complete
      vm.task.val = TaskData(id: 1, text: "Test", completed: true)
      check vm.displayState.val == tdsCompleted
      check vm.isCompleted.val == true

      # Edit mode
      vm.task.val = TaskData(id: 1, text: "Test", completed: false)
      vm.isEditing.val = true
      check vm.displayState.val == tdsEditing

      # Saving overrides editing
      vm.saveStatus.val = asLoading
      check vm.displayState.val == tdsSaving

      # Error
      vm.saveStatus.val = asError
      check vm.displayState.val == tdsError

      dispose()

  test "test_task_list_vm_filtering":
    ## TaskListVM.filteredTasks memo correctly filters
    createRoot do (dispose: proc()):
      let vm = createTaskAppVM()
      vm.store.addTask("Active task")
      vm.store.addTask("Done task")
      vm.store.toggleTask(vm.store.tasks.val[1].id)

      check vm.store.filteredTasks.val.len == 2  # All

      vm.store.setFilter(fmActive)
      check vm.store.filteredTasks.val.len == 1
      check vm.store.filteredTasks.val[0].text == "Active task"

      vm.store.setFilter(fmCompleted)
      check vm.store.filteredTasks.val.len == 1
      check vm.store.filteredTasks.val[0].text == "Done task"

      dispose()

  test "test_task_app_vm_composition":
    ## TaskAppVM composes child VMs and propagates state
    createRoot do (dispose: proc()):
      let vm = createTaskAppVM()
      check vm.hasTasks.val == false
      check vm.hasCompletedTasks.val == false

      vm.store.addTask("Test task")
      check vm.hasTasks.val == true
      check vm.hasCompletedTasks.val == false

      vm.store.toggleTask(vm.store.tasks.val[0].id)
      check vm.hasCompletedTasks.val == true

      # FilterBar reflects store state
      check vm.filterBar.currentFilter.val == fmAll
      check vm.filterBar.options.val.len == 3
      check vm.filterBar.options.val[0].active == true  # All is active

      dispose()

  test "test_story_files_exist_for_all_components":
    ## Every component has stories with ≥3 states
    let taskRowStories = taskRowStories()
    check taskRowStories.len >= 3

    let pages = pageStories()
    check pages.len >= 3

    let flows = userFlows()
    check flows.len >= 1
    for flow in flows:
      check flow.steps.len >= 3

  test "test_mock_provider_covers_all_flows":
    ## Each flow has realistic mock data
    createRoot do (dispose: proc()):
      # Empty provider
      let empty = emptyProvider()
      check empty.tasks.len == 0

      # Active workspace
      let active = activeWorkspaceProvider()
      check active.tasks.len >= 3
      check active.tasks.anyIt(it.completed)
      check active.tasks.anyIt(not it.completed)

      # All completed
      let allDone = allCompletedProvider()
      check allDone.tasks.allIt(it.completed)

      # Heavy usage
      let heavy = heavyUsageProvider()
      check heavy.tasks.len >= 15

      # Apply mock to VM
      let vm = createTaskAppVM()
      vm.applyMock(active)
      check vm.store.tasks.val.len == active.tasks.len

      dispose()

  test "test_user_project_vms_contain_no_presentation":
    ## No CSS, hex colors, or Tailwind classes in VM files
    let vmFile = readFile("src/isonim/editor/user_project_vms.nim")
    let storyFile = readFile("src/isonim/editor/stories.nim")

    for f in [vmFile, storyFile]:
      check "class =" notin f
      check "rounded" notin f
      check "bg-" notin f

  test "test_storyboard_has_four_levels":
    ## buildStoryboard produces all four levels
    let storyboard = buildStoryboard()
    let kinds = storyboard.mapIt(it.kind)
    check skFoundation in kinds
    check skComponent in kinds
    check skPage in kinds
    check skFlow in kinds

  test "test_storyboard_realistic_data":
    ## Page stories use realistic names, not placeholders
    let pages = pageStories()
    for page in pages:
      check "test" notin page.name.toLowerAscii()
      check "foo" notin page.name.toLowerAscii()
      check page.description.len > 10

    let active = activeWorkspaceProvider()
    for task in active.tasks:
      check "test" notin task.text.toLowerAscii()
      check task.text.len > 5
