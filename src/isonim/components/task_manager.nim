## Task manager component types — pure data, no platform imports.

import std/[sequtils, hashes]

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

proc hash*(t: TaskData): Hash =
  ## Hash by id for use as table key in forEachKeyed reconciliation.
  hash(t.id)

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

# ===========================================================================
# Signal-based TaskStore — for reactive rendering via ui DSL
# ===========================================================================

import isonim/core/[signals, computation]

type
  TaskStore* = ref object
    tasks*: Signal[seq[TaskData]]
    filter*: Signal[FilterMode]
    filteredTasks*: Memo[seq[TaskData]]
    activeCount*: Memo[int]
    completedCount*: Memo[int]
    nextId: int

proc createTaskStore*(): TaskStore =
  ## Create a signal-based task store. Must be called inside createRoot.
  let tasks = createSignal[seq[TaskData]](@[])
  let filter = createSignal(fmAll)

  let filteredTasks = createMemo[seq[TaskData]](proc(): seq[TaskData] =
    let f = filter.val
    let all = tasks.val
    case f
    of fmAll: all
    of fmActive: all.filterIt(not it.completed)
    of fmCompleted: all.filterIt(it.completed)
  )

  let activeCount = createMemo[int](proc(): int =
    tasks.val.countIt(not it.completed)
  )

  let completedCount = createMemo[int](proc(): int =
    tasks.val.countIt(it.completed)
  )

  TaskStore(
    tasks: tasks,
    filter: filter,
    filteredTasks: filteredTasks,
    activeCount: activeCount,
    completedCount: completedCount,
    nextId: 1,
  )

proc addTask*(store: TaskStore; text: string) =
  if text.len > 0:
    let id = store.nextId
    inc store.nextId
    store.tasks.update proc(prev: seq[TaskData]): seq[TaskData] =
      result = prev
      result.add TaskData(id: id, text: text, completed: false)

proc toggleTask*(store: TaskStore; id: int) =
  store.tasks.update proc(prev: seq[TaskData]): seq[TaskData] =
    result = newSeq[TaskData](prev.len)
    for i, t in prev:
      if t.id == id:
        result[i] = TaskData(id: t.id, text: t.text, completed: not t.completed)
      else:
        result[i] = t

proc deleteTask*(store: TaskStore; id: int) =
  store.tasks.update proc(prev: seq[TaskData]): seq[TaskData] =
    result = @[]
    for t in prev:
      if t.id != id:
        result.add t

proc clearCompleted*(store: TaskStore) =
  store.tasks.update proc(prev: seq[TaskData]): seq[TaskData] =
    result = @[]
    for t in prev:
      if not t.completed:
        result.add t

proc setFilter*(store: TaskStore; f: FilterMode) =
  store.filter.val = f
