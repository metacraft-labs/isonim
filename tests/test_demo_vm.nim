## ViewModel tests for the IsoNim demo task store.
## Tests the pure reactive logic without any DOM, using createRoot.
## Ported from the SolidJS demo's taskStore.test.ts (14 tests).

import unittest
import isonim/core/[signals, computation, owner]
import task_store

suite "IsoNim Task Store ViewModel":
  setup:
    resetIdCounter()

  test "starts with an empty task list":
    createRoot do (dispose: proc()):
      let store = createTaskStore()
      check store.tasks.val.len == 0
      check store.filteredTasks.val.len == 0
      check store.activeCount.val == 0
      check store.completedCount.val == 0
      dispose()

  test "adds a task":
    createRoot do (dispose: proc()):
      let store = createTaskStore()
      store.addTask("Buy milk")
      check store.tasks.val.len == 1
      check store.tasks.val[0].text == "Buy milk"
      check store.tasks.val[0].done == false
      dispose()

  test "ignores blank tasks":
    createRoot do (dispose: proc()):
      let store = createTaskStore()
      store.addTask("")
      store.addTask("   ")
      check store.tasks.val.len == 0
      dispose()

  test "toggles a task":
    createRoot do (dispose: proc()):
      let store = createTaskStore()
      store.addTask("Task A")
      let id = store.tasks.val[0].id

      store.toggleTask(id)
      check store.tasks.val[0].done == true

      store.toggleTask(id)
      check store.tasks.val[0].done == false
      dispose()

  test "removes a task":
    createRoot do (dispose: proc()):
      let store = createTaskStore()
      store.addTask("Task A")
      store.addTask("Task B")
      check store.tasks.val.len == 2
      let id = store.tasks.val[0].id

      store.removeTask(id)
      check store.tasks.val.len == 1
      check store.tasks.val[0].text == "Task B"
      dispose()

  test "removes task deselects if that task was selected":
    createRoot do (dispose: proc()):
      let store = createTaskStore()
      store.addTask("Task A")
      let id = store.tasks.val[0].id
      store.setSelectedId(id)
      check store.selectedId.val == id

      store.removeTask(id)
      check store.selectedId.val == -1
      dispose()

  test "filters tasks by active":
    createRoot do (dispose: proc()):
      let store = createTaskStore()
      store.addTask("Task A")
      store.addTask("Task B")
      check store.tasks.val.len == 2
      store.toggleTask(store.tasks.val[0].id)

      store.setFilter(fActive)
      check store.filteredTasks.val.len == 1
      check store.filteredTasks.val[0].text == "Task B"
      dispose()

  test "filters tasks by completed":
    createRoot do (dispose: proc()):
      let store = createTaskStore()
      store.addTask("Task A")
      store.addTask("Task B")
      check store.tasks.val.len == 2
      store.toggleTask(store.tasks.val[0].id)

      store.setFilter(fCompleted)
      check store.filteredTasks.val.len == 1
      check store.filteredTasks.val[0].text == "Task A"
      dispose()

  test "shows all tasks with all filter":
    createRoot do (dispose: proc()):
      let store = createTaskStore()
      store.addTask("Task A")
      store.addTask("Task B")
      store.toggleTask(store.tasks.val[0].id)

      store.setFilter(fAll)
      check store.filteredTasks.val.len == 2
      dispose()

  test "counts active and completed correctly":
    createRoot do (dispose: proc()):
      let store = createTaskStore()
      store.addTask("A")
      store.addTask("B")
      store.addTask("C")
      check store.tasks.val.len == 3
      store.toggleTask(store.tasks.val[0].id)

      check store.activeCount.val == 2
      check store.completedCount.val == 1
      dispose()

  test "clears completed tasks":
    createRoot do (dispose: proc()):
      let store = createTaskStore()
      store.addTask("A")
      store.addTask("B")
      store.addTask("C")
      check store.tasks.val.len == 3
      store.toggleTask(store.tasks.val[0].id)
      store.toggleTask(store.tasks.val[2].id)

      store.clearCompleted()
      check store.tasks.val.len == 1
      check store.tasks.val[0].text == "B"
      dispose()

  test "clears completed deselects if selected task was completed":
    createRoot do (dispose: proc()):
      let store = createTaskStore()
      store.addTask("A")
      let id = store.tasks.val[0].id
      store.toggleTask(id)
      store.setSelectedId(id)

      store.clearCompleted()
      check store.selectedId.val == -1
      dispose()

  test "effect fires on task count change":
    createRoot do (dispose: proc()):
      var effectLog: seq[int] = @[]
      let tasks = createSignal[seq[Task]](@[])

      createEffect do:
        effectLog.add tasks.val.len

      # Initial effect should have run with 0
      check effectLog.len >= 1
      check effectLog[0] == 0

      tasks.update proc(prev: seq[Task]): seq[Task] =
        result = prev
        result.add Task(id: 1, text: "A", done: false)

      # Effect should have fired again
      check effectLog.len >= 2
      check effectLog[effectLog.len - 1] > 0
      dispose()

  test "memo recomputes only when dependencies change":
    createRoot do (dispose: proc()):
      var memoCallCount = 0
      let tasks = createSignal[seq[Task]](@[])
      let filter = createSignal(fAll)

      let filtered = createMemo[seq[Task]](proc(): seq[Task] =
        inc memoCallCount
        let f = filter.val
        let all = tasks.val
        case f
        of fAll: return all
        of fActive:
          result = @[]
          for t in all:
            if not t.done:
              result.add t
        of fCompleted:
          result = @[]
          for t in all:
            if t.done:
              result.add t
      )

      # Initial computation
      discard filtered.val
      check memoCallCount == 1

      # Reading again without changes should not recompute
      discard filtered.val
      check memoCallCount == 1

      # Changing filter triggers recomputation
      filter.val = fActive
      discard filtered.val
      check memoCallCount == 2
      dispose()
