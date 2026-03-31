## Cooperative task scheduler for IsoNim.
## Port of SolidJS scheduler.ts.
##
## Uses the pluggable Clock from clock.nim for time-based scheduling.

import std/algorithm
import clock

type
  Task* = ref object
    id*: int
    fn*: proc(didTimeout: bool)
    startTime*: float64
    expirationTime*: float64
    cancelled*: bool

var taskQueue {.threadvar.}: seq[Task]
var nextTaskId {.threadvar.}: int
var isPerformingWork {.threadvar.}: bool

proc requestCallback*(fn: proc(didTimeout: bool); timeoutMs: float64 = 5000.0): Task =
  ## Schedules a task with optional timeout.
  ## Returns a Task handle for cancellation.
  let clock = currentClock
  let startTime = if clock != nil and clock of TestClock:
    TestClock(clock).now()
  elif clock != nil and clock of RealClock:
    RealClock(clock).now()
  else:
    0.0

  inc nextTaskId
  let task = Task(
    id: nextTaskId,
    fn: fn,
    startTime: startTime,
    expirationTime: startTime + timeoutMs,
    cancelled: false
  )
  taskQueue.add(task)
  # Sort by expiration time (earlier deadlines first)
  taskQueue.sort(proc(a, b: Task): int = cmp(a.expirationTime, b.expirationTime))
  return task

proc cancelCallback*(task: Task) =
  ## Cancels a scheduled task.
  task.cancelled = true
  task.fn = nil

proc flushTasks*() =
  ## Processes all pending tasks in priority order.
  ## Called by the clock after time advancement.
  if isPerformingWork: return
  isPerformingWork = true
  try:
    var i = 0
    while i < taskQueue.len:
      let task = taskQueue[i]
      if not task.cancelled and task.fn != nil:
        let didTimeout = false  # simplified; real timeout check uses clock
        task.fn(didTimeout)
      inc i
    taskQueue.setLen(0)
  finally:
    isPerformingWork = false
