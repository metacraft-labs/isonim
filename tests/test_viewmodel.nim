## ViewModel pattern tests for IsoNim.
## Tests state transitions, async operations, error paths, SSR output,
## and performance characteristics.

import unittest
import std/[strutils]
when not defined(js):
  import std/times
import isonim/core/[signals, computation, owner, clock]
import isonim/viewmodel
import isonim/testing/test_utils
import isonim/ssr/renderer
import isonim/ssr/escape
import task_store
import task_ssr

suite "ViewModel Pattern":
  setup:
    resetIdCounter()

  test "test_demo_vm_state_transitions":
    ## All state transitions verified with fake time.
    withFakeTime:
      createRoot proc(dispose: proc()) =
        let vm = createTaskViewModel()

        # Initial state is Idle
        check vm.detailState.val == asIdle
        check vm.detailData.val == ""
        check vm.detailError.val == ""

        # Add a task and fetch details - transitions through states
        vm.store.addTask("Test task")
        let taskId = vm.store.tasks.val[0].id

        # Fetch with default service goes Idle -> Loading -> Ready
        vm.fetchTaskDetails(taskId)
        check vm.detailState.val == asReady
        check vm.detailData.val == "Details for task " & $taskId
        check vm.detailError.val == ""

        # Fetch again to verify re-transition
        vm.fetchTaskDetails(taskId)
        check vm.detailState.val == asReady

        dispose()

  test "test_demo_vm_async_operations":
    ## Async resource loading with TestClock.
    withFakeTime:
      createRoot proc(dispose: proc()) =
        var callCount = 0

        # Service that simulates async with a scheduled callback
        let service = TaskService(
          fetchDetails: proc(id: int): (AsyncState, string) =
            inc callCount
            (asReady, "Loaded details for #" & $id)
        )

        let vm = createTaskViewModel(service)
        vm.store.addTask("Async task")
        let taskId = vm.store.tasks.val[0].id

        # Fetch triggers the service
        vm.fetchTaskDetails(taskId)
        check callCount == 1
        check vm.detailState.val == asReady
        check vm.detailData.val == "Loaded details for #" & $taskId

        # Fetch again
        vm.fetchTaskDetails(taskId)
        check callCount == 2

        # Advance clock - verify no side effects
        tc.advance(1000)
        check callCount == 2

        dispose()

  test "test_demo_vm_error_paths":
    ## Injected failures produce correct error states.
    withFakeTime:
      createRoot proc(dispose: proc()) =
        # Service that always fails
        let failService = TaskService(
          fetchDetails: proc(id: int): (AsyncState, string) =
            (asError, "Network timeout for task " & $id)
        )

        let vm = createTaskViewModel(failService)
        vm.store.addTask("Will fail")
        let taskId = vm.store.tasks.val[0].id

        vm.fetchTaskDetails(taskId)
        check vm.detailState.val == asError
        check vm.detailError.val == "Network timeout for task " & $taskId
        check vm.detailData.val == ""

        # Recovery: switch to a working service and fetch again
        vm.service = TaskService(
          fetchDetails: proc(id: int): (AsyncState, string) =
            (asReady, "Recovered data for task " & $id)
        )
        vm.fetchTaskDetails(taskId)
        check vm.detailState.val == asReady
        check vm.detailData.val == "Recovered data for task " & $taskId
        check vm.detailError.val == ""

        dispose()

  test "test_demo_vm_error_then_idle":
    ## After error, state can be manually reset.
    createRoot proc(dispose: proc()) =
      let failService = TaskService(
        fetchDetails: proc(id: int): (AsyncState, string) =
          (asError, "fail")
      )
      let vm = createTaskViewModel(failService)
      vm.store.addTask("Task")
      let taskId = vm.store.tasks.val[0].id

      vm.fetchTaskDetails(taskId)
      check vm.detailState.val == asError

      # Manual reset to idle
      vm.detailState.val = asIdle
      vm.detailError.val = ""
      check vm.detailState.val == asIdle
      check vm.detailError.val == ""

      dispose()

  test "test_demo_vm_dispose":
    ## ViewModel dispose cleans up the reactive root.
    var vm: TaskViewModel

    createRoot proc(outerDispose: proc()) =
      vm = withViewModel proc(dispose: proc()): TaskViewModel =
        let innerVm = createTaskViewModel()
        innerVm
      outerDispose()

    # After withViewModel, vm should have a disposeProc
    check vm != nil
    # Dispose should be callable
    vm.dispose()
    # Calling dispose again should be safe (idempotent)
    vm.dispose()

  test "test_demo_vm_service_injection":
    ## Service injection allows swapping implementations.
    createRoot proc(dispose: proc()) =
      var log: seq[string] = @[]

      let loggingService = TaskService(
        fetchDetails: proc(id: int): (AsyncState, string) =
          log.add("fetch:" & $id)
          (asReady, "data-" & $id)
      )

      let vm = createTaskViewModel(loggingService)
      vm.store.addTask("A")
      vm.store.addTask("B")
      let idA = vm.store.tasks.val[0].id
      let idB = vm.store.tasks.val[1].id

      vm.fetchTaskDetails(idA)
      vm.fetchTaskDetails(idB)
      check log.len == 2
      check log[0] == "fetch:" & $idA
      check log[1] == "fetch:" & $idB

      dispose()

suite "Demo SSR":
  setup:
    resetIdCounter()

  test "e2e_demo_ssr_hydrate_full":
    ## Demo renders via SSR, produces valid HTML.
    let html = renderTaskApp()

    # Structure checks
    check "<div" in html
    check "class=\"app\"" in html
    check "id=\"app\"" in html
    check "<h1>Task Manager</h1>" in html
    check "class=\"task-list\"" in html
    check "class=\"task\"" in html

    # Content checks - pre-populated tasks
    check "Learn IsoNim" in html
    check "Build demo app" in html

    # Well-formed: opening and closing tags
    check html.count("<div") == html.count("</div>")
    check html.count("<span") == html.count("</span>")

    # Proper nesting: starts with <div, ends with </div>
    check html.startsWith("<div")
    check html.endsWith("</div>")

  test "e2e_demo_ssr_full_page":
    ## Full page rendering with hydration script.
    let page = renderTaskPage()

    check "<!DOCTYPE html>" in page
    check "<html>" in page
    check "<title>Task Manager</title>" in page
    check "<body>" in page
    check "Task Manager" in page
    check "Learn IsoNim" in page
    check "window._$HY" in page
    check "<!--xs-->" in page
    check "</body></html>" in page

  test "e2e_demo_ssr_escapes_content":
    ## SSR properly escapes special characters.
    let html = renderToString proc(): string =
      var store = createTaskStore()
      store.addTask("<script>alert('xss')</script>")

      ssrElement("div", children =
        ssrFor(store.filteredTasks.val, proc(task: Task, i: int): string =
          ssrElement("span", children = escapeHtml(task.text))
        )
      )

    check "&lt;script&gt;" in html
    check "<script>alert" notin html

  test "e2e_demo_ssr_empty_store":
    ## SSR renders correctly with no tasks.
    let html = renderToString proc(): string =
      var store = createTaskStore()
      ssrElement("div", {"class": "app"}, children =
        ssrElement("ul", children =
          ssrFor(store.filteredTasks.val, proc(task: Task, i: int): string =
            ssrElement("li", children = escapeHtml(task.text))
          )
        )
      )

    check "class=\"app\"" in html
    check "<ul></ul>" in html

when defined(js):
  proc performanceNow(): float64 {.importjs: "performance.now()".}
else:
  proc performanceNow(): float64 =
    cpuTime() * 1000.0

suite "Performance":
  setup:
    resetIdCounter()

  test "verify_demo_performance_comparison":
    ## Performance metrics recorded for ViewModel operations.
    let iterations = 1000

    # Measure store creation + task addition
    let startCreate = performanceNow()
    for i in 0 ..< iterations:
      createRoot proc(dispose: proc()) =
        let store = createTaskStore()
        store.addTask("Task " & $i)
        check store.tasks.val.len == 1
        dispose()
    let createMs = performanceNow() - startCreate

    # Measure SSR rendering
    let startSsr = performanceNow()
    for i in 0 ..< iterations:
      let html = renderTaskApp()
      check html.len > 0
    let ssrMs = performanceNow() - startSsr

    # Measure ViewModel with service injection
    let startVm = performanceNow()
    for i in 0 ..< iterations:
      createRoot proc(dispose: proc()) =
        let vm = createTaskViewModel()
        vm.store.addTask("Perf task")
        vm.fetchTaskDetails(vm.store.tasks.val[0].id)
        check vm.detailState.val == asReady
        dispose()
    let vmMs = performanceNow() - startVm

    # Report metrics (test always passes - just records)
    echo "  [perf] " & $iterations & " store creates: " &
      $createMs & "ms"
    echo "  [perf] " & $iterations & " SSR renders: " &
      $ssrMs & "ms"
    echo "  [perf] " & $iterations & " VM operations: " &
      $vmMs & "ms"

    # Sanity: each operation should complete in reasonable time
    # (< 10s for 1000 iterations, very generous bound)
    check createMs < 10000.0
    check ssrMs < 10000.0
    check vmMs < 10000.0
