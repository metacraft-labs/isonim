## Actions: writes a ViewModel sends to its services, one at a time, with a
## policy for being asked again while busy.
##
## A read is asked again whenever its question changes, and the newer
## question replaces the older one: an `AsyncValue` drops the answer it no
## longer wants. A write cannot be treated that way. A second "save" while
## one is running must not abort the first (aborting a request does not undo
## what the server already did), and a "build" started while a save runs
## would build the old document. Written by hand, that takes an in-flight
## flag per command, a waiter list, a slot for the newest pending argument,
## and the care to clear all of them on every path.
##
## An `Action` does that once:
##
## .. code-block:: nim
##   # Inside the ViewModel's constructor (`withViewModel`):
##   let workspace = newLane()
##   vm.save = createAction(
##     proc(doc: Document): PlatformFuture[Revision] = services.save(doc),
##     lane = workspace, whenBusy = WhenBusy.coalesce,
##     onSettled = proc(doc: Document; outcome: Outcome[Revision]) =
##       if outcome.kind == OutcomeKind.failed: vm.message.val = outcome.error)
##   vm.build = createAction(
##     proc(target: string): PlatformFuture[BuildReport] =
##       services.build(target),
##     lane = workspace, whenBusy = WhenBusy.refuse)
##   # A View or a command: discard vm.save.call(vm.document.val)
##   # The View reads vm.save.inFlight and workspace.busy.
##
## A *lane* runs the actions that share it one at a time. A *run* is one
## call of an action's `run` procedure; `call(arg)` asks for one. When the
## lane is free, the run starts at once. When it is busy (a run is running
## or waiting), the action's `whenBusy` decides what the ask does:
##
## - `queue` — the run waits and starts after the runs asked before it, in
##   the order asked. Nothing is dropped, so a queue grows with every ask.
## - `coalesce` — the action keeps at most one waiting run. A later ask
##   replaces that run's argument and joins it: the run starts in the place
##   of the first ask, carrying the newest argument, and every asker
##   receives the outcome of that one run. An asker can therefore receive
##   the outcome of an argument it did not pass (the newer document was
##   saved, and its save answers for the older one too).
## - `refuse` — the ask settles `refused` at once and nothing runs. The
##   asker receives an outcome for a run that never started.
##
## Semantics:
##
## - *Outcome.* `call` returns a future of the run's `Outcome`: `answered`
##   with the run's result, `failed` with the message (the service's, or that
##   of the `CatchableError` the run raised, or "the action returned no
##   future" for nil), `refused` (refused while busy) or `interrupted` (a
##   waiting run that was dropped because its action or its lane ended
##   before it started). A failure is an outcome, never an exception: `call`
##   does not raise because the work failed, and the future never fails. A
##   `Defect` raised by `run` propagates.
## - *One at a time, never cancelled.* At most one run of a lane is running.
##   A running run is never cancelled by a later ask, whatever the policy:
##   a later ask waits, joins a waiting run or is refused.
## - *A failure settles that run only.* The next waiting run starts as it
##   would after an answer; nothing waiting is cancelled or refused because
##   an earlier run failed.
## - *Settling* (`onSettled`). Called once per run with the argument the run
##   carried and its outcome, and once per refused ask with that ask's
##   argument and `refused`, inside the batch that updates `inFlight` and
##   `busy`, so what the ViewModel writes there shows in the same frame as
##   the action going idle. Hooks are called in the order the runs settle,
##   which on one lane is the order they ran. When the hook runs, the next
##   waiting run has not started yet, but the lane still counts it as busy,
##   so an action asked from the hook takes its place after the runs already
##   waiting. A hook that raises an ordinary error raises an error of the
##   reactive graph: it goes to the nearest error handler above the action
##   (`onError`), and with none it is raised to the code that settled the
##   run (for a refused ask, or a run that settles at once, that is `call`).
##   The lane still moves on, and every asker still receives the outcome. A
##   `Defect` propagates.
## - *State* (tracked). `action.inFlight` is true from the ask that starts or
##   queues a run until no run of the action is running or waiting (a
##   refused ask never makes it true). `lane.busy` is true while a run of
##   any of its actions is running or waiting. A View draws "saving" from
##   `inFlight` and disables "build" from `busy`.
## - *Ownership.* An action lives in a reactive root created under the
##   current owner, and ends with it (or with `dispose`). Ending it drops
##   its waiting runs, whose askers receive `interrupted`, and silences it:
##   no hook runs and its `inFlight` is not written again. A run already
##   running is not cancelled, because the write may already have reached
##   the service: it keeps the lane busy until it settles, so a write asked
##   on the same lane by another action still waits for it, and its askers
##   receive its real outcome. A lane made under an owner ends with it: its
##   waiting runs are dropped (`interrupted`), `busy` is not written again
##   and a later ask settles `interrupted`. A call to an action that has
##   ended settles `interrupted` at once.
## - *Not an optimistic update.* An action writes nothing to the
##   ViewModel's values; showing a guess before the answer and reverting it
##   on failure is left to the caller.
##
## Asking a run from a reactive computation (an effect) is untracked: what
## `run` reads, and what the hook of a refused ask reads, does not become a
## dependency of the caller. `run` is called under the action's own root.
##
## When an action has a lane of its own (no `lane` given), `whenBusy`
## applies to asks of that action alone. A lane earns its place when two or
## more actions must not overlap.
##
## Not imported by the reactive core, the renderers or the async value
## module: a page that does not use it carries none of its code. Not yet a
## stable API. Works on the C and JS backends; time comes from
## nim-everywhere, so tests drive it with `FakeAsyncContext`.

import nim_everywhere/async_compat

import isonim/core/[signals, computation, owner, batch, graph]
import ./backport_shims  # backport probe
export backport_shims
import ./async_value
import ./deferred

export OutcomeKind, Outcome

type
  WhenBusy* {.pure.} = enum
    ## What an ask does while its lane is busy (see the module
    ## documentation): `queue` (wait in order asked), `coalesce` (join the
    ## action's one waiting run, replacing its argument) or `refuse`
    ## (settle `refused` at once).
    queue, coalesce, refuse

  RunBase = ref object of RootObj
    ## One run, as the lane sees it: the lane holds runs of actions with
    ## different argument and result types, so the typed part (`Run`) is
    ## reached through the two procedures its action stored here. They are
    ## plain procedures rather than closures, so a run holds no closure that
    ## refers back to it.
    action: ActionBase
    startFn: proc(r: RunBase) {.nimcall.}
    dropFn: proc(r: RunBase) {.nimcall.}
    settled: bool

  ActionBase = ref object of RootObj
    ## The untyped part of an action, which the lane compares by identity.
    lane: Lane
    whenBusy: WhenBusy
    count: int          ## Runs of this action running or waiting.
    inFlightSignal: Signal[bool]
    disposed: bool

  Lane* = ref object
    ## Runs the actions that share it one at a time (see the module
    ## documentation). `busy` is a tracked read. Not yet a stable API.
    busySignal: Signal[bool]
    running: RunBase
    waiting: seq[RunBase]
    pumping: bool       ## Starting waiting runs: a nested request to start
                        ## the next one is left to the loop that runs.
    ended: bool

  Action*[A, R] = ref object of ActionBase
    ## A write with argument `A` and result `R`, run on a lane under a
    ## policy for being asked while busy (see the module documentation).
    ## `inFlight` is a tracked read. Not yet a stable API.
    run: proc(arg: A): PlatformFuture[R]
    hook: proc(arg: A; outcome: Outcome[R])
    owner: OwnerBase
    source: ComputationBase
      ## The action's own computation: a settle hook's error is reported as
      ## its error, so it reaches the handlers above the action.
    disposeRoot: proc() {.closure.}

  Run[A, R] = ref object of RunBase
    arg: A
    askers: seq[Deferred[Outcome[R]]]

proc isBusy(lane: Lane): bool =
  lane.running != nil or lane.waiting.len > 0

proc updateBusy(lane: Lane) =
  if not lane.ended: lane.busySignal.val = lane.isBusy

proc updateInFlight(action: ActionBase) =
  if not action.disposed: action.inFlightSignal.val = action.count > 0

proc pump(lane: Lane) =
  ## Start waiting runs while none is running. A run that settles while it
  ## is being started (a service that answers at once) asks for the next one
  ## from inside this loop; the loop starts it, so a long queue of such runs
  ## does not nest.
  if lane.pumping: return
  lane.pumping = true
  try:
    while lane.running == nil and lane.waiting.len > 0 and not lane.ended:
      let r = lane.waiting[0]
      lane.waiting.delete(0)
      lane.running = r
      r.startFn(r)
  finally:
    lane.pumping = false
  lane.updateBusy()

proc endLane(lane: Lane) =
  ## The lane's owner ended: drop the waiting runs and write nothing more.
  if lane.ended: return
  lane.ended = true
  let dropped = lane.waiting
  lane.waiting = @[]
  for r in dropped: r.dropFn(r)

proc newLane*(): Lane =
  ## A lane with nothing running. Made under an owner (a ViewModel's
  ## constructor), it ends with that owner: its waiting runs are dropped,
  ## their askers receive `interrupted`, and `busy` is not written again.
  ## Not yet a stable API.
  let lane = Lane(busySignal: createSignal(false))
  onCleanup proc() = lane.endLane()
  lane

proc busy*(lane: Lane): bool =
  ## A run of one of the lane's actions is running or waiting (tracked).
  lane.busySignal.val

proc runHook[A, R](action: Action[A, R]; arg: A; outcome: Outcome[R]) =
  ## Run the settle hook. An ordinary error it raises is an error of the
  ## graph, reported as the error of the action's own computation; a
  ## `Defect` is not caught.
  if action.hook == nil: return
  try:
    action.hook(arg, outcome)
  except CatchableError as e:
    if action.source != nil: handleError(action.source, e)
    else: raise e

proc finish[A, R](r: Run[A, R]; outcome: Outcome[R]) =
  ## `r` has settled with `outcome`: update the state and run the hook in
  ## one batch, start the next waiting run, then tell every asker.
  if r.settled: return
  r.settled = true
  let action = Action[A, R](r.action)
  let lane = action.lane
  if lane.running == RunBase(r): lane.running = nil
  dec action.count
  let live = not action.disposed
  try:
    batch proc() =
      action.updateInFlight()
      try:
        if live: action.runHook(r.arg, outcome)
      finally:
        # The lane moves on even when the hook raised.
        lane.pump()
  finally:
    for d in r.askers: d.resolve(outcome)

proc startRun[A, R](base: RunBase) {.nimcall.} =
  ## Call the action's `run` for `base`, which the lane has just made its
  ## running run.
  let r = Run[A, R](base)
  let action = Action[A, R](r.action)
  var future: PlatformFuture[R]
  try:
    runWithOwner(action.owner, proc() = future = action.run(r.arg))
  except CatchableError as e:
    r.finish(Outcome[R](kind: OutcomeKind.failed, error: e.msg))
    return
  if future.isNil:
    r.finish(Outcome[R](kind: OutcomeKind.failed,
                        error: "the action returned no future"))
    return
  future.onComplete(
    proc(value: R) =
      r.finish(Outcome[R](kind: OutcomeKind.answered, value: value)),
    proc(message: string) =
      r.finish(Outcome[R](kind: OutcomeKind.failed, error: message)))

proc dropRun[A, R](base: RunBase) {.nimcall.} =
  ## A waiting run that will never start: its askers receive `interrupted`.
  let r = Run[A, R](base)
  if r.settled: return
  r.settled = true
  let action = Action[A, R](r.action)
  dec action.count
  action.updateInFlight()
  for d in r.askers: d.resolve(Outcome[R](kind: OutcomeKind.interrupted))

proc endAction[A, R](action: Action[A, R]) =
  ## The action's owner ended (or `dispose`): drop its waiting runs and
  ## silence it. A running run is left to settle.
  if action.disposed: return
  action.disposed = true
  action.source = nil
  let lane = action.lane
  var kept, dropped: seq[RunBase]
  for r in lane.waiting:
    if r.action == ActionBase(action): dropped.add r
    else: kept.add r
  lane.waiting = kept
  for r in dropped: r.dropFn(r)
  lane.updateBusy()

proc createAction*[A, R](run: proc(arg: A): PlatformFuture[R];
                         lane: Lane = nil;
                         whenBusy = WhenBusy.queue;
                         onSettled: proc(arg: A;
                                         outcome: Outcome[R]) = nil):
    Action[A, R] =
  ## An action that calls `run` for each run asked with `call` (see the
  ## module documentation). Runs of the actions that share `lane` run one at
  ## a time; with no `lane` the action gets one of its own. `whenBusy` says
  ## what an ask does while the lane is busy (`queue` by default, which
  ## drops nothing). `onSettled` is called with each run's argument and
  ## outcome, and with `refused` for a refused ask, in the batch that
  ## updates `inFlight` and `busy`. The action ends with the current owner.
  ## Not yet a stable API.
  ##
  ## `run` raising a `CatchableError`, or returning nil, fails that run; a
  ## `Defect` propagates.
  let action = Action[A, R](lane: (if lane == nil: newLane() else: lane),
                            whenBusy: whenBusy, run: run, hook: onSettled)
  action.inFlightSignal = createSignal(false)
  createRoot proc(dispose: proc()) =
    action.disposeRoot = dispose
    action.owner = getOwner()
    # A computation of its own, so that a hook's error has a place in the
    # graph from which the handlers above the action are found. It reads
    # nothing and runs once.
    createComputed proc() =
      if action.source == nil: action.source = ComputationBase(getOwner())
    onCleanup proc() = action.endAction()
  # Backport probe: the old core does not dispose a nested root with its
  # creator (a later core change added that), so register the disposal by hand.
  onCleanup proc() = action.disposeRoot()
  action

proc call*[A, R](action: Action[A, R]; arg: A): PlatformFuture[Outcome[R]] =
  ## Ask for a run with `arg`. Returns a future of the outcome of the run
  ## that carries the ask (for `coalesce`, the run it joined; for `refuse`,
  ## `refused` when the lane is busy). The future never fails, and `call`
  ## does not raise because the work failed (a settle hook's own error with
  ## no handler above the action is raised to the code that settled, see
  ## the module documentation). On an action that has ended, or whose lane
  ## has, the outcome is `interrupted` at once. Not yet a stable API.
  let d = newDeferred[Outcome[R]]("action outcome")
  result = d.future
  let lane = action.lane
  if action.disposed or lane.ended:
    d.resolve(Outcome[R](kind: OutcomeKind.interrupted))
    return
  if lane.isBusy:
    case action.whenBusy
    of WhenBusy.refuse:
      let outcome = Outcome[R](kind: OutcomeKind.refused)
      try:
        # Untracked, like the rest of an ask: what the hook reads must not
        # become a dependency of an effect that asked.
        batch proc() = untrack(proc() = action.runHook(arg, outcome))
      finally:
        d.resolve(outcome)
      return
    of WhenBusy.coalesce:
      for w in lane.waiting:
        if w.action == ActionBase(action):
          let r = Run[A, R](w)
          r.arg = arg
          r.askers.add d
          return
    of WhenBusy.queue:
      discard
  let r = Run[A, R](action: action, arg: arg, askers: @[d],
                    startFn: startRun[A, R], dropFn: dropRun[A, R])
  inc action.count
  lane.waiting.add r
  batch proc() =
    action.updateInFlight()
    untrack(proc() = lane.pump())

proc inFlight*[A, R](action: Action[A, R]): bool =
  ## A run of `action` is running or waiting (tracked): true from the ask
  ## that starts or queues it until the action's last run settles. A refused
  ## ask does not make it true. Not yet a stable API.
  action.inFlightSignal.val

proc lane*[A, R](action: Action[A, R]): Lane =
  ## The lane `action` runs on (its own when none was given).
  action.lane

proc isDisposed*[A, R](action: Action[A, R]): bool =
  ## True once `action` has ended, by `dispose` or with its owner.
  action.disposed

proc dispose*[A, R](action: Action[A, R]) =
  ## End `action` before its owner does: its waiting runs are dropped
  ## (their askers receive `interrupted`), no hook runs again, and a later
  ## `call` settles `interrupted`. A run already running is not cancelled:
  ## its askers receive its outcome, and it keeps the lane busy until it
  ## settles. Calling it again does nothing.
  if action.disposeRoot != nil:
    # Call, then clear (a local copy could be freed by the clear first
    # under ARC/ORC).
    action.disposeRoot()
    action.disposeRoot = nil
