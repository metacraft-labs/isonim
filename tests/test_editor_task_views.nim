## Tests for IsoNim Editor — user project Views (M3)

import std/[unittest, tables]
import isonim/core/[signals, computation, owner]
import isonim/testing/mock_dom
import isonim/viewmodel
import isonim/editor/user_project_vms
import isonim/editor/stories
import isonim/editor/views/task_views
import isonim/components/task_manager

suite "User Project Views (M3)":

  test "test_task_row_view_active_state":
    ## TaskRow renders with full opacity for active task
    createRoot do (dispose: proc()):
      let r = MockRenderer()
      let vm = createTaskRowVM(TaskData(id: 1, text: "Buy groceries", completed: false))
      let row = renderTaskRow[MockRenderer, MockNode](r, vm, proc() = discard, proc() = discard)

      check row.styles["opacity"] == "1"
      # Row has 3 children: checkbox, label, delete button
      check row.children.len == 3
      dispose()

  test "test_task_row_view_completed_state":
    ## TaskRow renders with strikethrough for completed task
    createRoot do (dispose: proc()):
      let r = MockRenderer()
      let vm = createTaskRowVM(TaskData(id: 1, text: "Done task", completed: true))
      let row = renderTaskRow[MockRenderer, MockNode](r, vm, proc() = discard, proc() = discard)

      check row.styles["opacity"] == "0.6"
      let label = row.children[1]
      check label.styles["text-decoration"] == "line-through"
      dispose()

  test "test_task_app_view_empty_state":
    ## TaskApp renders empty state message when no tasks
    createRoot do (dispose: proc()):
      let r = MockRenderer()
      let vm = createTaskAppVM()
      let app = renderTaskApp[MockRenderer, MockNode](r, vm)

      # Should have: title, input row, empty state, filter bar, clear button
      check app.children.len >= 4
      dispose()

  test "test_task_app_view_with_mock_data":
    ## TaskApp renders task rows when mock data is applied
    createRoot do (dispose: proc()):
      let r = MockRenderer()
      let vm = createTaskAppVM()
      vm.applyMock(activeWorkspaceProvider())
      let app = renderTaskApp[MockRenderer, MockNode](r, vm)

      # Should have tasks now (title, input, task list, filter, clear)
      check app.children.len >= 4
      dispose()

  test "test_all_stories_produce_views":
    ## Every component story produces a non-empty rendered tree
    createRoot do (dispose: proc()):
      let r = MockRenderer()

      for story in taskRowStories():
        let vm = story.createVM()
        let row = renderTaskRow[MockRenderer, MockNode](r, vm, proc() = discard, proc() = discard)
        check row.children.len >= 3  # checkbox, label, delete

      for page in pageStories():
        let vm = createTaskAppVM()
        vm.applyMock(page.mock)
        let app = renderTaskApp[MockRenderer, MockNode](r, vm)
        check app.children.len >= 4

      dispose()

  test "test_reactive_update_changes_view":
    ## Completing a task via VM updates the view reactively
    createRoot do (dispose: proc()):
      let r = MockRenderer()
      let vm = createTaskRowVM(TaskData(id: 1, text: "Test", completed: false))
      let row = renderTaskRow[MockRenderer, MockNode](r, vm, proc() = discard, proc() = discard)

      check row.styles["opacity"] == "1"

      # Complete the task via ViewModel
      vm.task.val = TaskData(id: 1, text: "Test", completed: true)

      check row.styles["opacity"] == "0.6"
      check row.children[1].styles["text-decoration"] == "line-through"
      dispose()
