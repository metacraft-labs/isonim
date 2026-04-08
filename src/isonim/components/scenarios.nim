## Predefined UI scenarios for snapshot testing.
## Each scenario is a TaskAppState that can be rendered by any backend.

import isonim/components/task_manager

proc emptyScenario*(): TaskAppState =
  newTaskAppState()

proc threeTasksScenario*(): TaskAppState =
  result = newTaskAppState()
  result.addTask("Buy groceries")
  result.addTask("Walk the dog")
  result.addTask("Read a book")

proc oneCompletedScenario*(): TaskAppState =
  result = threeTasksScenario()
  result.toggleTask(1)  # Complete "Buy groceries"

proc allCompletedScenario*(): TaskAppState =
  result = threeTasksScenario()
  for task in result.tasks:
    result.toggleTask(task.id)

proc filteredActiveScenario*(): TaskAppState =
  result = oneCompletedScenario()
  result.filter = fmActive

proc filteredCompletedScenario*(): TaskAppState =
  result = oneCompletedScenario()
  result.filter = fmCompleted

proc manyTasksScenario*(): TaskAppState =
  result = newTaskAppState()
  for i in 1..20:
    result.addTask("Task " & $i)
  result.toggleTask(2)
  result.toggleTask(5)
  result.toggleTask(10)
