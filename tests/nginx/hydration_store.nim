## hydration_store.nim
##
## The task store of the hydration fixture (hydration_app.nim): plain
## signals, compiled for the server (C, inside the nginx module)
## and for the browser (JS). Both sides seed it with the same three tasks,
## the third one done, so that they render the same tree.

import isonim/core/signals

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
    nextId: int

proc addTask*(store: TaskStore; text: string) =
  if text.len == 0:
    return
  inc store.nextId
  let id = store.nextId
  store.tasks.update proc(prev: seq[Task]): seq[Task] =
    result = prev
    result.add Task(id: id, text: text)

proc toggleTask*(store: TaskStore; id: int) =
  store.tasks.update proc(prev: seq[Task]): seq[Task] =
    result = prev
    for t in result.mitems:
      if t.id == id: t.done = not t.done

proc removeTask*(store: TaskStore; id: int) =
  store.tasks.update proc(prev: seq[Task]): seq[Task] =
    for t in prev:
      if t.id != id: result.add t

proc clearCompleted*(store: TaskStore) =
  store.tasks.update proc(prev: seq[Task]): seq[Task] =
    for t in prev:
      if not t.done: result.add t

proc visibleTasks*(store: TaskStore): seq[Task] =
  let f = store.filter.val
  for t in store.tasks.val:
    if f == fAll or (f == fActive) == (not t.done):
      result.add t

proc task*(store: TaskStore; id: int): Task =
  for t in store.tasks.val:
    if t.id == id: return t

proc activeCount*(store: TaskStore): int =
  for t in store.tasks.val:
    if not t.done: inc result

proc completedCount*(store: TaskStore): int =
  store.tasks.val.len - store.activeCount

proc countText*(store: TaskStore): string =
  let n = store.activeCount
  $n & " item" & (if n == 1: "" else: "s") & " left"

proc newSeededTaskStore*(): TaskStore =
  ## Must be called inside a reactive root.
  result = TaskStore(tasks: createSignal[seq[Task]](@[]),
                     filter: createSignal(fAll))
  result.addTask("Buy groceries")
  result.addTask("Write tests")
  result.addTask("Deploy app")
  result.toggleTask(3)
