## Recordable-only checkpoint hooks. Wire formats and replay are consumers.
when not defined(isonimRecordable):
  {.error: "checkpoints requires -d:isonimRecordable".}
import clock, batch, checkpoint_registry
export checkpoint_registry

type
  SignalCheckpoint* = object
    afterSeq*: uint64
    hash*: string
  CheckpointSession* = ref object
    clock: ClockBase
    hook: proc(checkpoint: SignalCheckpoint)
    every: uint64
    idleMs: float64
    periodicCancel, idleCancel: proc()
    lastEmission: uint64
    emitted: bool
    active: bool

proc stop*(session: CheckpointSession) =
  ## Stop observation and cancel maintenance without modifying dispatch state.
  if not session.active: return
  session.active = false
  session.clock.checkpointDispatch = nil
  if session.periodicCancel != nil: session.periodicCancel()
  if session.idleCancel != nil: session.idleCancel()
  session.periodicCancel = nil
  session.idleCancel = nil
  session.hook = nil

proc emitCheckpoint(session: CheckpointSession) =
  if not session.active: return
  let clock = session.clock
  if session.emitted and session.lastEmission == clock.dispatchSequence: return
  # The maintenance callback is a separate task, after the observed callback
  # and its Promise continuations. Flush before reading any live signal.
  flushUpdates()
  if not session.active: return
  let checkpoint = SignalCheckpoint(afterSeq: clock.dispatchSequence,
    hash: signalStateHash(clock.randomDrawCount))
  if not session.active: return
  session.lastEmission = checkpoint.afterSeq
  session.emitted = true
  session.hook(checkpoint)

proc startCheckpoints*(clock: ClockBase; hook: proc(checkpoint: SignalCheckpoint);
    every = 16; idleMs = 32.0): CheckpointSession =
  ## Observe this backend's dispatches. Periodic/idle tasks share deduplication
  ## by afterSeq. Idle is quiescence for idleMs; maintenance never rearms itself.
  ## One initial idle task observes startup state even without a dispatch.
  ## Stop the returned session before starting another on the same backend.
  if clock == nil or hook == nil or every <= 0 or idleMs <= 0:
    raise newException(ValueError, "invalid checkpoint configuration")
  if clock.checkpointDispatch != nil:
    raise newException(ValueError, "clock already has checkpoint observation")
  if liveSignalCount() == 0: resetSignalOrdinals()
  let session = CheckpointSession(clock: clock, hook: hook,
    every: uint64(every), idleMs: idleMs, active: true)
  proc armIdle() =
    if session.idleCancel != nil: session.idleCancel()
    session.idleCancel = clock.scheduleCheckpointMaintenance(proc() =
      session.idleCancel = nil
      session.emitCheckpoint(), session.idleMs)
  clock.checkpointDispatch = proc() =
    if not session.active: return
    armIdle()
    if clock.dispatchSequence mod session.every == 0 and session.periodicCancel == nil:
      session.periodicCancel = clock.scheduleCheckpointMaintenance(proc() =
        session.periodicCancel = nil
        session.emitCheckpoint(), 0)
  # Do not leave an unreturned session attached when scheduling refuses or
  # fails. Use the same cancellation and observer cleanup as an explicit stop.
  try:
    armIdle()
  except:
    session.stop()
    raise
  session
