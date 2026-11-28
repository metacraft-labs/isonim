## Actions on lanes (`isonim/services/actions`), under fake time: `queue`
## runs one at a time in the order asked; `coalesce` keeps one waiting run
## whose argument a later ask replaces, and every asker receives the outcome
## of the run that carried it; `refuse` settles `refused` at once while the
## lane is busy and runs when it is free; a failure (a failed future, a run
## that raises, a run that returns nil) settles that run only and cancels
## nothing; a running run is never cancelled by a later ask; `lane.busy`
## and `inFlight` change in the batch that runs the settle hook, and the
## lane stays busy between two runs; an action asked from a hook takes its
## place after the runs already waiting; disposal (the action's own, its
## owner's, the lane's owner's) drops waiting runs, whose askers receive
## `interrupted`, silences the hooks and leaves a running run to settle; a
## hook that raises is an error of the graph and the lane still moves on.
##
## The outcome of `call` travels through a platform future, which on JS is
## a promise whose callbacks run on a microtask a synchronous `unittest`
## case cannot wait for, so these cases are asynchronous scenarios on both
## backends (the shape of `tests/test_callbacks.nim`); each reports its own
## `[OK]` / `[FAILED]` line, and the process fails unless every scenario
## reported success.
##
## MOCK POLICY (workspace rule: every mock justified in the header). One
## recording write service, `WriteService`: each write answers with a real
## `Deferred` settled by a timer on the nim-everywhere clock (driven by
## `FakeAsyncContext`) after a chosen latency, or fails on cue. It records
## every write it received and when, and how many writes were running at
## once, which a real service would not report and which are what these
## tests assert ("one at a time", "the latest argument was written"). The
## action module, its lanes, the signals, effects, owners, error handlers and
## futures are the real ones.

import std/tables

import nim_everywhere
import nim_everywhere/async_compat
import isonim/core/[signals, owner, computation]
import isonim/services/[actions, deferred]

import helpers/async_recording_service

type
  WriteService = ref object
    latencyMs: int
    latencies: Table[string, int]    ## Per argument.
    failures: Table[string, string]  ## Arguments whose write fails.
    started: seq[string]             ## Every write received, in order.
    startedAt: seq[int64]            ## The fake time each one started.
    running: int
    maxRunning: int                  ## Most writes running at once.

  Scenario = ref object
    name: string
    failures: seq[string]

proc newWriteService(latencyMs = 10): WriteService =
  WriteService(latencyMs: latencyMs)

proc write(svc: WriteService; ctx: FakeAsyncContext; arg: string):
    PlatformFuture[string] =
  ## Answers "saved:<arg>" (or fails with the scripted message) after the
  ## argument's latency.
  svc.started.add arg
  svc.startedAt.add ctx.now
  inc svc.running
  svc.maxRunning = max(svc.maxRunning, svc.running)
  let d = newDeferred[string]("write")
  let failure = svc.failures.getOrDefault(arg, "")
  discard scheduleAt(svc.latencies.getOrDefault(arg, svc.latencyMs), proc() =
    dec svc.running
    if failure.len > 0: d.reject(failure)
    else: d.resolve("saved:" & arg))
  d.future

proc writer(svc: WriteService; ctx: FakeAsyncContext):
    proc(arg: string): PlatformFuture[string] =
  result = proc(arg: string): PlatformFuture[string] = svc.write(ctx, arg)

proc describe(o: Outcome[string]): string =
  case o.kind
  of OutcomeKind.answered: "answered " & o.value
  of OutcomeKind.failed: "failed " & o.error
  of OutcomeKind.interrupted: "interrupted"
  of OutcomeKind.refused: "refused"

type Askers = ref object
  ## What each asker received, by the name the test gave the ask.
  got: Table[string, string]

proc ask(askers: Askers; action: Action[string, string]; name, arg: string) =
  ## `call`, recording the outcome under `name` when it arrives.
  action.call(arg).onComplete(
    proc(o: Outcome[string]) = askers.got[name] = o.describe,
    proc(message: string) = askers.got[name] = "the future failed: " & message)

proc expect(s: Scenario; ok: bool; what: string) =
  if not ok: s.failures.add what

proc report(s: Scenario): bool =
  if s.failures.len == 0:
    echo "  [OK] ", s.name
  else:
    echo "  [FAILED] ", s.name
    for f in s.failures: echo "    Check failed: ", f
  s.failures.len == 0

when not defined(js):
  proc stepAsync(ctx: FakeAsyncContext; ms: int) {.async.} =
    ## On C a future's callback runs at the next poll, which `step` does.
    ctx.step(ms)

proc hookLog(log: ref seq[string]): proc(arg: string; o: Outcome[string]) =
  result = proc(arg: string; o: Outcome[string]) =
    log[].add arg & ": " & o.describe

# --------------------------------------------------------------------------
# The three policies.
# --------------------------------------------------------------------------

proc queueKeepsOrder(s: Scenario) {.async.} =
  let ctx = newFakeAsyncContext()
  ctx.install()
  defer: ctx.uninstall()
  let svc = newWriteService(latencyMs = 10)
  svc.latencies["a"] = 15
  svc.latencies["c"] = 5
  let settled = new seq[string]
  let save = createAction(svc.writer(ctx), whenBusy = WhenBusy.queue,
                          onSettled = settled.hookLog)
  let askers = Askers()
  s.expect(not save.inFlight, "idle before the first ask")
  askers.ask(save, "1", "a")
  askers.ask(save, "2", "b")
  askers.ask(save, "3", "c")
  s.expect(svc.started == @["a"], "only the first runs at once: " & $svc.started)
  s.expect(save.inFlight and save.lane.busy, "in flight and busy")
  await ctx.stepAsync(14)
  s.expect(svc.started == @["a"], "b waits while a runs: " & $svc.started)
  await ctx.stepAsync(1)
  s.expect(svc.started == @["a", "b"], "b starts when a settles: " & $svc.started)
  await ctx.stepAsync(30)
  s.expect(svc.started == @["a", "b", "c"], "in the order asked: " & $svc.started)
  s.expect(svc.startedAt == @[0'i64, 15, 25], "each after the one before: " &
           $svc.startedAt)
  s.expect(svc.maxRunning == 1, "never two at once: " & $svc.maxRunning)
  s.expect(settled[] == @["a: answered saved:a", "b: answered saved:b",
                          "c: answered saved:c"], "one hook per run, in order: " &
           $settled[])
  s.expect(askers.got.len == 3 and askers.got["1"] == "answered saved:a" and
           askers.got["2"] == "answered saved:b" and
           askers.got["3"] == "answered saved:c",
           "each asker gets its own run's outcome: " & $askers.got)
  s.expect(not save.inFlight and not save.lane.busy, "idle after the last")
  save.dispose()

proc coalesceKeepsLatest(s: Scenario) {.async.} =
  let ctx = newFakeAsyncContext()
  ctx.install()
  defer: ctx.uninstall()
  let svc = newWriteService(latencyMs = 10)
  let settled = new seq[string]
  let save = createAction(svc.writer(ctx), whenBusy = WhenBusy.coalesce,
                          onSettled = settled.hookLog)
  let askers = Askers()
  askers.ask(save, "first", "v1")
  await ctx.stepAsync(2)
  askers.ask(save, "second", "v2")
  askers.ask(save, "third", "v3")
  await ctx.stepAsync(2)
  askers.ask(save, "fourth", "v4")
  s.expect(svc.started == @["v1"], "the waiting run has not started: " &
           $svc.started)
  await ctx.stepAsync(30)
  s.expect(svc.started == @["v1", "v4"],
           "one waiting run, carrying the latest argument: " & $svc.started)
  s.expect(settled[] == @["v1: answered saved:v1", "v4: answered saved:v4"],
           "one hook per run, with the argument it carried: " & $settled[])
  s.expect(askers.got.len == 4 and askers.got["first"] == "answered saved:v1",
           "the running run answers its asker: " & $askers.got)
  for name in ["second", "third", "fourth"]:
    s.expect(askers.got.getOrDefault(name) == "answered saved:v4",
             name & " gets the outcome of the run that carried it: " &
             $askers.got)
  # Free again: the next ask runs at once, and coalescing starts over.
  askers.ask(save, "fifth", "v5")
  s.expect(svc.started.len > 0 and svc.started[^1] == "v5",
           "a free lane runs at once: " & $svc.started)
  askers.ask(save, "sixth", "v6")
  await ctx.stepAsync(30)
  s.expect(svc.started == @["v1", "v4", "v5", "v6"], "then v6: " & $svc.started)
  s.expect(svc.maxRunning == 1, "never two at once: " & $svc.maxRunning)
  save.dispose()

proc refuseWhileBusy(s: Scenario) {.async.} =
  let ctx = newFakeAsyncContext()
  ctx.install()
  defer: ctx.uninstall()
  let svc = newWriteService(latencyMs = 10)
  let builds = newWriteService(latencyMs = 10)
  let settled = new seq[string]
  let workspace = newLane()
  let save = createAction(svc.writer(ctx), lane = workspace,
                          whenBusy = WhenBusy.coalesce)
  let build = createAction(builds.writer(ctx), lane = workspace,
                           whenBusy = WhenBusy.refuse,
                           onSettled = settled.hookLog)
  var buildInFlight: seq[bool]
  var stop: proc()
  createRoot proc(d: proc()) =
    stop = d
    createEffect proc() = buildInFlight.add build.inFlight
  let askers = Askers()
  askers.ask(save, "save", "doc")
  askers.ask(build, "build while saving", "app")
  s.expect(settled[] == @["app: refused"],
           "refused at once, in the call: " & $settled[])
  s.expect(builds.started.len == 0, "a refused build never runs")
  s.expect(buildInFlight == @[false], "a refused ask is never in flight: " &
           $buildInFlight)
  await ctx.stepAsync(1)
  s.expect(askers.got.getOrDefault("build while saving") == "refused",
           "the asker receives refused before the save settles: " & $askers.got)
  await ctx.stepAsync(10)
  s.expect(askers.got.getOrDefault("save") == "answered saved:doc",
           "the save is not disturbed: " & $askers.got)
  # The lane is free: the build runs, and a second build is refused while it
  # does (it refuses its own repeat too).
  askers.ask(build, "build", "app")
  askers.ask(build, "build again", "app2")
  s.expect(builds.started == @["app"], "a free lane runs the build: " &
           $builds.started)
  s.expect(settled[] == @["app: refused", "app2: refused"],
           "a second build is refused while the first runs: " & $settled[])
  # A save asked while the build runs waits for it (save coalesces).
  askers.ask(save, "save during build", "doc2")
  s.expect(svc.started == @["doc"], "the save waits for the build: " &
           $svc.started)
  await ctx.stepAsync(30)
  s.expect(svc.started == @["doc", "doc2"], "then it runs: " & $svc.started)
  s.expect(askers.got.getOrDefault("build") == "answered saved:app",
           "the build answers: " & $askers.got)
  s.expect(settled[].len > 0 and settled[][^1] == "app: answered saved:app",
           "its hook ran: " & $settled[])
  s.expect(buildInFlight == @[false, true, false],
           "in flight only while the build ran: " & $buildInFlight)
  stop()
  save.dispose()
  build.dispose()
  # An ask made from an effect is untracked, including the hook a refused
  # ask runs at once: what that hook reads does not make the effect ask
  # again when it changes.
  let held = newWriteService(latencyMs = 10)
  let note = createSignal("")
  let probeLane = newLane()
  let hold = createAction(held.writer(ctx), lane = probeLane)
  let probe = createAction(held.writer(ctx), lane = probeLane,
    whenBusy = WhenBusy.refuse,
    onSettled = proc(arg: string; o: Outcome[string]) = discard note.val)
  discard hold.call("hold")
  var asks = 0
  var stopProbe: proc()
  createRoot proc(d: proc()) =
    stopProbe = d
    createEffect proc() =
      inc asks
      discard probe.call("probe")
  note.val = "changed"
  s.expect(asks == 1, "the refused ask's hook read nothing for the effect: " &
           $asks & " asks")
  await ctx.stepAsync(20)
  stopProbe()
  hold.dispose()
  probe.dispose()

proc refusedAndCoalescedAskersGetAnotherArgument(s: Scenario) {.async.} =
  # Refuse settles at once even when the action has its own lane and only
  # its own run is busy, so a caller can tell "my ask did nothing".
  let ctx = newFakeAsyncContext()
  ctx.install()
  defer: ctx.uninstall()
  let svc = newWriteService(latencyMs = 10)
  let build = createAction(svc.writer(ctx), whenBusy = WhenBusy.refuse)
  let askers = Askers()
  askers.ask(build, "1", "x")
  askers.ask(build, "2", "y")
  await ctx.stepAsync(20)
  s.expect(svc.started == @["x"], "only the first ran: " & $svc.started)
  s.expect(askers.got.getOrDefault("1") == "answered saved:x" and
           askers.got.getOrDefault("2") == "refused", "outcomes: " & $askers.got)
  build.dispose()

# --------------------------------------------------------------------------
# Failures, and a running run is never cancelled.
# --------------------------------------------------------------------------

proc failureCancelsNothing(s: Scenario) {.async.} =
  let ctx = newFakeAsyncContext()
  ctx.install()
  defer: ctx.uninstall()
  let svc = newWriteService(latencyMs = 10)
  svc.failures["bad"] = "disk full"
  let settled = new seq[string]
  # A run that fails its future, one that raises, one that returns nil:
  # each fails only itself.
  let run = proc(arg: string): PlatformFuture[string] =
    if arg == "raises": raise newException(IOError, "no connection")
    if arg == "nil": return nil
    svc.write(ctx, arg)
  let save = createAction(run, whenBusy = WhenBusy.queue,
                          onSettled = settled.hookLog)
  let askers = Askers()
  askers.ask(save, "1", "bad")
  askers.ask(save, "2", "raises")
  askers.ask(save, "3", "nil")
  askers.ask(save, "4", "good")
  await ctx.stepAsync(30)
  s.expect(settled[] == @["bad: failed disk full",
                          "raises: failed no connection",
                          "nil: failed the action returned no future",
                          "good: answered saved:good"],
           "every run settled, in order: " & $settled[])
  s.expect(askers.got.getOrDefault("1") == "failed disk full" and
           askers.got.getOrDefault("2") == "failed no connection" and
           askers.got.getOrDefault("3") ==
             "failed the action returned no future" and
           askers.got.getOrDefault("4") == "answered saved:good",
           "the futures carry the failures, never fail: " & $askers.got)
  s.expect(not save.inFlight and not save.lane.busy, "idle afterwards")
  save.dispose()
  # The same with coalesce: a failing run leaves the waiting run in place.
  let svc2 = newWriteService(latencyMs = 10)
  svc2.failures["v1"] = "conflict"
  let save2 = createAction(svc2.writer(ctx), whenBusy = WhenBusy.coalesce)
  let askers2 = Askers()
  askers2.ask(save2, "first", "v1")
  askers2.ask(save2, "second", "v2")
  askers2.ask(save2, "third", "v3")
  await ctx.stepAsync(30)
  s.expect(svc2.started == @["v1", "v3"],
           "the waiting run still runs after a failure: " & $svc2.started)
  s.expect(askers2.got.getOrDefault("first") == "failed conflict" and
           askers2.got.getOrDefault("second") == "answered saved:v3" and
           askers2.got.getOrDefault("third") == "answered saved:v3",
           "outcomes: " & $askers2.got)
  save2.dispose()

proc runningRunNeverCancelled(s: Scenario) {.async.} =
  # Under each policy, an ask made while a run runs leaves that run alone:
  # its write completes and its asker receives its own answer.
  let ctx = newFakeAsyncContext()
  ctx.install()
  defer: ctx.uninstall()
  for policy in [WhenBusy.queue, WhenBusy.coalesce, WhenBusy.refuse]:
    let svc = newWriteService(latencyMs = 10)
    let action = createAction(svc.writer(ctx), whenBusy = policy)
    let askers = Askers()
    askers.ask(action, "running", "a")
    await ctx.stepAsync(5)
    askers.ask(action, "later", "b")
    askers.ask(action, "latest", "c")
    await ctx.stepAsync(40)
    s.expect(askers.got.getOrDefault("running") == "answered saved:a",
             $policy & ": the running run answered its asker: " & $askers.got)
    s.expect(svc.started.len > 0 and svc.started[0] == "a" and
             svc.maxRunning == 1,
             $policy & ": a ran alone and to its end: " & $svc.started)
    action.dispose()

# --------------------------------------------------------------------------
# The state: busy, inFlight, and the frame the hook writes into.
# --------------------------------------------------------------------------

proc stateShowsWithTheHook(s: Scenario) {.async.} =
  let ctx = newFakeAsyncContext()
  ctx.install()
  defer: ctx.uninstall()
  let svc = newWriteService(latencyMs = 10)
  let message = createSignal("")
  let workspace = newLane()
  let save = createAction(svc.writer(ctx), lane = workspace,
    whenBusy = WhenBusy.queue,
    onSettled = proc(arg: string; o: Outcome[string]) =
      message.val = "settled " & arg)
  let other = createAction(svc.writer(ctx), lane = workspace,
                           whenBusy = WhenBusy.queue)
  var frames: seq[string]
  var stop: proc()
  createRoot proc(d: proc()) =
    stop = d
    createEffect proc() =
      frames.add $workspace.busy & "/" & $save.inFlight & "/" &
        $other.inFlight & "/" & message.val
  discard save.call("a")
  discard save.call("b")
  discard other.call("c")
  await ctx.stepAsync(40)
  # Busy from the first ask to the last settle, with no idle frame between
  # runs; save stays in flight while its second run waits; each change of
  # inFlight shows in the same frame as what the hook wrote.
  s.expect(frames == @["false/false/false/",
                       "true/true/false/",
                       "true/true/true/",
                       "true/true/true/settled a",
                       "true/false/true/settled b",
                       "false/false/false/settled b"],
           "frames: " & $frames)
  stop()
  save.dispose()
  other.dispose()

proc askedFromAHookWaitsItsTurn(s: Scenario) {.async.} =
  # When a run settles, the runs already waiting keep their places: an ask
  # made from the hook queues after them, and a refusing one is refused.
  let ctx = newFakeAsyncContext()
  ctx.install()
  defer: ctx.uninstall()
  let svc = newWriteService(latencyMs = 10)
  let builds = newWriteService(latencyMs = 10)
  let workspace = newLane()
  let askers = Askers()
  var build: Action[string, string]
  var publish: Action[string, string]
  let save = createAction(svc.writer(ctx), lane = workspace,
    whenBusy = WhenBusy.queue,
    onSettled = proc(arg: string; o: Outcome[string]) =
      if arg == "a":
        askers.ask(build, "build from hook", "app")
        askers.ask(publish, "publish from hook", "site"))
  build = createAction(builds.writer(ctx), lane = workspace,
                       whenBusy = WhenBusy.refuse)
  publish = createAction(builds.writer(ctx), lane = workspace,
                         whenBusy = WhenBusy.queue)
  askers.ask(save, "a", "a")
  askers.ask(save, "b", "b")
  await ctx.stepAsync(40)
  s.expect(svc.started == @["a", "b"], "saves: " & $svc.started)
  s.expect(builds.started == @["site"], "publish after b, build refused: " &
           $builds.started)
  s.expect(builds.startedAt == @[20'i64], "publish started after b: " &
           $builds.startedAt)
  s.expect(askers.got.getOrDefault("build from hook") == "refused",
           "b was waiting, so the lane was busy: " & $askers.got)
  save.dispose()
  build.dispose()
  publish.dispose()

# --------------------------------------------------------------------------
# Disposal.
# --------------------------------------------------------------------------

proc disposalDropsWaitingRuns(s: Scenario) {.async.} =
  let ctx = newFakeAsyncContext()
  ctx.install()
  defer: ctx.uninstall()
  let svc = newWriteService(latencyMs = 10)
  let settled = new seq[string]
  let workspace = newLane()
  let save = createAction(svc.writer(ctx), lane = workspace,
                          whenBusy = WhenBusy.queue,
                          onSettled = settled.hookLog)
  let other = createAction(svc.writer(ctx), lane = workspace,
                           whenBusy = WhenBusy.queue,
                           onSettled = settled.hookLog)
  var inFlightFrames: seq[bool]
  var stop: proc()
  createRoot proc(d: proc()) =
    stop = d
    createEffect proc() = inFlightFrames.add save.inFlight
  let askers = Askers()
  askers.ask(save, "running", "a")
  askers.ask(save, "waiting", "b")
  askers.ask(save, "waiting too", "c")
  await ctx.stepAsync(3)
  save.dispose()
  s.expect(save.isDisposed, "disposed")
  askers.ask(other, "other", "d")
  askers.ask(save, "after dispose", "e")
  await ctx.stepAsync(1)
  s.expect(askers.got.getOrDefault("waiting") == "interrupted" and
           askers.got.getOrDefault("waiting too") == "interrupted",
           "waiting runs are dropped at once: " & $askers.got)
  s.expect(askers.got.getOrDefault("after dispose") == "interrupted",
           "a call after dispose is interrupted: " & $askers.got)
  s.expect(not askers.got.hasKey("running"), "the running run still runs")
  s.expect(workspace.busy, "the running run keeps the lane busy")
  s.expect(svc.started == @["a"], "other waits for the running write: " &
           $svc.started)
  await ctx.stepAsync(30)
  s.expect(askers.got.getOrDefault("running") == "answered saved:a",
           "the running run's asker receives its real outcome: " & $askers.got)
  s.expect(svc.started == @["a", "d"], "dropped runs never ran: " & $svc.started)
  s.expect(settled[] == @["d: answered saved:d"],
           "the disposed action runs no hook: " & $settled[])
  s.expect(inFlightFrames == @[false, true],
           "a disposed action's inFlight is not written again: " &
           $inFlightFrames)
  s.expect(not workspace.busy, "the lane is free once both settled")
  stop()
  other.dispose()

proc ownerDisposalEndsActionsAndLane(s: Scenario) {.async.} =
  let ctx = newFakeAsyncContext()
  ctx.install()
  defer: ctx.uninstall()
  let svc = newWriteService(latencyMs = 10)
  let settled = new seq[string]
  var save, build: Action[string, string]
  var workspace: Lane
  var disposeOwner: proc()
  createRoot proc(d: proc()) =
    disposeOwner = d
    workspace = newLane()
    save = createAction(svc.writer(ctx), lane = workspace,
                        whenBusy = WhenBusy.coalesce,
                        onSettled = settled.hookLog)
    build = createAction(svc.writer(ctx), lane = workspace,
                         whenBusy = WhenBusy.queue,
                         onSettled = settled.hookLog)
  var busyFrames: seq[bool]
  var stop: proc()
  createRoot proc(d: proc()) =
    stop = d
    createEffect proc() = busyFrames.add workspace.busy
  let askers = Askers()
  askers.ask(save, "running", "a")
  askers.ask(save, "waiting", "b")
  askers.ask(build, "build waiting", "c")
  await ctx.stepAsync(2)
  disposeOwner()
  s.expect(save.isDisposed and build.isDisposed, "both actions ended")
  await ctx.stepAsync(30)
  s.expect(askers.got.getOrDefault("waiting") == "interrupted" and
           askers.got.getOrDefault("build waiting") == "interrupted",
           "waiting runs dropped: " & $askers.got)
  s.expect(askers.got.getOrDefault("running") == "answered saved:a",
           "the running run settles for its asker: " & $askers.got)
  s.expect(svc.started == @["a"], "nothing else ran: " & $svc.started)
  s.expect(settled[].len == 0, "no hook after the owner ended: " & $settled[])
  s.expect(busyFrames == @[false, true],
           "an ended lane's busy is not written again: " & $busyFrames)
  askers.ask(save, "later", "d")
  await ctx.stepAsync(1)
  s.expect(askers.got.getOrDefault("later") == "interrupted",
           "a call after the owner ended: " & $askers.got)
  stop()

# --------------------------------------------------------------------------
# A hook that raises.
# --------------------------------------------------------------------------

proc raisingHookIsAGraphError(s: Scenario) {.async.} =
  let ctx = newFakeAsyncContext()
  ctx.install()
  defer: ctx.uninstall()
  let svc = newWriteService(latencyMs = 10)
  var handled: seq[string]
  var save: Action[string, string]
  var stop: proc()
  createRoot proc(d: proc()) =
    stop = d
    onError proc(e: ref CatchableError) = handled.add e.msg
    save = createAction(svc.writer(ctx), whenBusy = WhenBusy.queue,
      onSettled = proc(arg: string; o: Outcome[string]) =
        if arg == "a": raise newException(ValueError, "hook bug on " & arg))
  let askers = Askers()
  askers.ask(save, "1", "a")
  askers.ask(save, "2", "b")
  await ctx.stepAsync(30)
  s.expect(handled == @["hook bug on a"],
           "the handler above the action got the hook's error: " & $handled)
  s.expect(svc.started == @["a", "b"], "the lane moved on: " & $svc.started)
  s.expect(askers.got.getOrDefault("1") == "answered saved:a" and
           askers.got.getOrDefault("2") == "answered saved:b",
           "every asker received its outcome: " & $askers.got)
  stop()

when defined(js):
  {.emit: "process.exitCode = 1;".}

proc main() {.async.} =
  var ok = true
  proc run(name: string; body: proc(s: Scenario): Future[void]) {.async.} =
    let s = Scenario(name: name)
    await body(s)
    if not s.report(): ok = false
  echo "[Suite] actions_lane_policies"
  await run("queue runs one at a time, in the order asked",
    proc(s: Scenario): Future[void] = queueKeepsOrder(s))
  await run("coalesce keeps one waiting run with the latest argument and answers every asker",
    proc(s: Scenario): Future[void] = coalesceKeepsLatest(s))
  await run("refuse settles refused at once while the lane is busy, and runs when it is free",
    proc(s: Scenario): Future[void] = refuseWhileBusy(s))
  await run("refuse on an action's own lane refuses its own repeat",
    proc(s: Scenario): Future[void] = refusedAndCoalescedAskersGetAnotherArgument(s))
  await run("a failure settles that run only and cancels nothing",
    proc(s: Scenario): Future[void] = failureCancelsNothing(s))
  await run("a running run is never cancelled by a later ask",
    proc(s: Scenario): Future[void] = runningRunNeverCancelled(s))
  await run("busy and inFlight change in the frame the hook writes into",
    proc(s: Scenario): Future[void] = stateShowsWithTheHook(s))
  await run("an action asked from a hook waits behind the runs already waiting",
    proc(s: Scenario): Future[void] = askedFromAHookWaitsItsTurn(s))
  await run("disposal drops waiting runs and silences hooks; a running run settles",
    proc(s: Scenario): Future[void] = disposalDropsWaitingRuns(s))
  await run("the owner's end ends its actions and its lane",
    proc(s: Scenario): Future[void] = ownerDisposalEndsActionsAndLane(s))
  await run("a hook that raises is an error of the graph, and the lane moves on",
    proc(s: Scenario): Future[void] = raisingHookIsAGraphError(s))
  when defined(js):
    if ok:
      {.emit: "process.exitCode = 0;".}
  else:
    if not ok: quit(1)

when defined(js):
  discard main()
else:
  waitFor main()
