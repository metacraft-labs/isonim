## Real library callbacks in a child process. Positive runs must exit cleanly;
## the mutation harness retains this named probe if a native regression faults.
import std/os
import isonim/core/[signals, owner, checkpoints, nondet]
type CallbackValue = object
  content: int
var action: proc()
proc checkpointSerialize(value: CallbackValue): string =
  if action != nil: action()
  $value.content
let mode = paramStr(1)
echo "checkpoint callback probe: " & mode & " begin"
stdout.flushFile()
case mode
of "stop-contribution":
  let backend = newTestBackend()
  var calls, contributions: int
  let session = startCheckpoints(backend, (proc(c: SignalCheckpoint) = inc calls), every=1)
  createRoot proc(dispose: proc()) =
    let trigger = createSignal(CallbackValue(content:1))
    action = proc() =
      inc contributions
      session.stop()
    discard backend.schedule((proc() = discard), 1)
    TestClock(backend).advance(100)
    action = nil
    doAssert calls == 0, "stopped checkpoint session must not emit"
    doAssert contributions == 1
    doAssert trigger.val.content == 1
    dispose()
of "entry-validation":
  createRoot proc(dispose: proc()) =
    let trigger = createSignal(CallbackValue(content:1))
    let expected = signalStateHash(0)
    var release: proc()
    var retained: Signal[int]
    createRoot proc(disposeVictim: proc()) =
      release = disposeVictim
      retained = createSignal(42)
    action = proc() = release()
    let observed = signalStateHash(0)
    action = nil
    doAssert observed == expected, "disposed registration must not contribute"
    doAssert retained.val == 42
    doAssert trigger.val.content == 1
    dispose()
else:
  raise newException(ValueError, "unknown callback probe")
echo "checkpoint callback probe: " & mode & " PASS"
