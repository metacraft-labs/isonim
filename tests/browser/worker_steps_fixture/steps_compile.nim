## steps_compile.nim
##
## The worker-steps fixture's computation (tests/browser/specs/worker-steps.spec.ts):
## a run made of steps, each keeping its thread busy for the milliseconds the
## request names; a step can be told to throw a JavaScript error (not a Nim
## exception) instead, the way a deep recursion's RangeError arrives.

type
  StepsRequest* = object
    stepMs*: seq[int]     ## each step's busy time
    throwAt*: int         ## the step that throws a JavaScript error (-1: none)
    tag*: string

  StepsResult* = object
    tag*: string
    steps*: int           ## the steps this run executed

  StepsRun* = object
    req: StepsRequest
    next: int

proc busyFor(ms: int) =
  {.emit: ["var until = performance.now() + ", ms, "; while (performance.now() < until) {}"].}

proc throwJsError() =
  {.emit: "null.notAProperty;".}

proc startSteps*(req: StepsRequest): StepsRun = StepsRun(req: req)

proc stepSteps*(run: var StepsRun): bool =
  ## Runs the next step; true when every step has run.
  if run.next < run.req.stepMs.len:
    if run.next == run.req.throwAt: throwJsError()
    busyFor(run.req.stepMs[run.next])
    inc run.next
  run.next >= run.req.stepMs.len

proc finishSteps*(run: StepsRun): StepsResult =
  StepsResult(tag: run.req.tag, steps: run.next)
