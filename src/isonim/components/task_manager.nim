## Task manager component types — pure data, no platform imports.

import std/sequtils

type
  TaskData* = object
    id*: int
    text*: string
    completed*: bool

  FilterMode* = enum
    fmAll, fmActive, fmCompleted

  TaskAppState* = ref object
    tasks*: seq[TaskData]
    filter*: FilterMode
    nextId*: int

proc newTaskAppState*(): TaskAppState =
  TaskAppState(tasks: @[], filter: fmAll, nextId: 1)

proc addTask*(state: TaskAppState; text: string) =
  if text.len > 0:
    state.tasks.add(TaskData(id: state.nextId, text: text, completed: false))
    inc state.nextId

proc toggleTask*(state: TaskAppState; id: int) =
  for i in 0..<state.tasks.len:
    if state.tasks[i].id == id:
      state.tasks[i].completed = not state.tasks[i].completed

proc deleteTask*(state: TaskAppState; id: int) =
  state.tasks.keepIf(proc(t: TaskData): bool = t.id != id)

proc clearCompleted*(state: TaskAppState) =
  state.tasks.keepIf(proc(t: TaskData): bool = not t.completed)

proc filteredTasks*(state: TaskAppState): seq[TaskData] =
  case state.filter
  of fmAll: state.tasks
  of fmActive: state.tasks.filterIt(not it.completed)
  of fmCompleted: state.tasks.filterIt(it.completed)

proc activeCount*(state: TaskAppState): int =
  state.tasks.countIt(not it.completed)

proc completedCount*(state: TaskAppState): int =
  state.tasks.countIt(it.completed)
