## Task store — pure ViewModel layer for the IsoNim demo app.
## Contains signals, memos, and actions for task management.
## No DOM dependencies — importable from both browser and tests.

import std/strutils
import isonim/core/[signals, computation, context, batch]

type
  Task* = object
    id*: int
    text*: string
    done*: bool

  Filter* = enum
    fAll = "all"
    fActive = "active"
    fCompleted = "completed"

  TaskStore* = ref object
    tasks*: Signal[seq[Task]]
    filter*: Signal[Filter]
    selectedId*: Signal[int]  ## -1 means no selection
    filteredTasks*: Memo[seq[Task]]
    activeCount*: Memo[int]
    completedCount*: Memo[int]
    log*: Signal[seq[string]]

var nextId {.threadvar.}: int

proc generateId*(): int =
  inc nextId
  result = nextId

proc resetIdCounter*() =
  ## For testing: reset the ID counter between tests.
  nextId = 0

proc addTask*(store: TaskStore; text: string) =
  let trimmed = text.strip()
  if trimmed.len == 0:
    return
  store.tasks.update proc(prev: seq[Task]): seq[Task] =
    result = prev
    result.add Task(id: generateId(), text: trimmed, done: false)

proc toggleTask*(store: TaskStore; id: int) =
  store.tasks.update proc(prev: seq[Task]): seq[Task] =
    result = newSeq[Task](prev.len)
    for i, t in prev:
      if t.id == id:
        result[i] = Task(id: t.id, text: t.text, done: not t.done)
      else:
        result[i] = t

proc removeTask*(store: TaskStore; id: int) =
  store.tasks.update proc(prev: seq[Task]): seq[Task] =
    result = @[]
    for t in prev:
      if t.id != id:
        result.add t
  if store.selectedId.val == id:
    store.selectedId.val = -1

proc clearCompleted*(store: TaskStore) =
  var completedIds: seq[int] = @[]
  for t in store.tasks.val:
    if t.done:
      completedIds.add t.id
  for cid in completedIds:
    if store.selectedId.val == cid:
      store.selectedId.val = -1
      break
  store.tasks.update proc(prev: seq[Task]): seq[Task] =
    result = @[]
    for t in prev:
      if not t.done:
        result.add t

proc setFilter*(store: TaskStore; f: Filter) =
  store.filter.val = f

proc setSelectedId*(store: TaskStore; id: int) =
  store.selectedId.val = id

proc createTaskStore*(): TaskStore =
  ## Creates the task store with all signals, memos, and the effect log.
  ## Must be called inside a reactive root.
  var tasks = createSignal[seq[Task]](@[])
  var filter = createSignal(fAll)
  var selectedId = createSignal(-1)
  var log = createSignal[seq[string]](@[])

  let filteredTasks = createMemo[seq[Task]](proc(): seq[Task] =
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

  let activeCount = createMemo[int](proc(): int =
    result = 0
    for t in tasks.val:
      if not t.done:
        inc result
  )

  let completedCount = createMemo[int](proc(): int =
    result = 0
    for t in tasks.val:
      if t.done:
        inc result
  )

  # Side-effect: log task count changes
  createEffect proc() =
    let count = tasks.val.len
    log.update proc(prev: seq[string]): seq[string] =
      result = prev
      result.add "Task count changed to " & $count

  result = TaskStore(
    tasks: tasks,
    filter: filter,
    selectedId: selectedId,
    filteredTasks: filteredTasks,
    activeCount: activeCount,
    completedCount: completedCount,
    log: log,
  )

# Context for the provider pattern
var TaskContext* = createContext[TaskStore]()

proc provideTaskStore*(store: TaskStore) =
  provide(TaskContext, store)

proc useTaskStore*(): TaskStore =
  useContext(TaskContext)
