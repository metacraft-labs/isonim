## Genuine reactive-owner program for identical-bundle re-evaluation. No mocks.
## It retains actual signals, memo, owner and disposer across the second load.
when not defined(js): {.error: "This fixture is compiled and executed as JavaScript".}
import std/json
import isonim/core/[signals, computation, owner]

type Probe = ref object
  value: Signal[int]
  doubled: Memo[int]
  runs, cleanups: int
  dispose: proc()

var probe: Probe
{.emit: [probe, " = globalThis.__isonimCoreOwnerHmr || null;"].}
if probe == nil:
  probe = Probe(value: createSignal(0))
  let captured = probe
  createRoot proc(dispose: proc()) =
    captured.dispose = dispose
    captured.doubled = createMemo(proc(): int = captured.value.val * 2)
    createEffect proc() =
      discard captured.doubled.val
      captured.runs.inc
      onCleanup proc() = captured.cleanups.inc
  {.emit: ["globalThis.__isonimCoreOwnerHmr = ", probe, ";"].}

proc step() = probe.value.val = probe.value.val + 1
proc dispose() = probe.dispose()
proc snapshot(): cstring =
  cstring($(%*{"value": probe.value.val, "doubled": probe.doubled.val,
    "runs": probe.runs, "cleanups": probe.cleanups,
    "valueObservers": probe.value.observers.len,
    "memoObservers": probe.doubled.signal.observers.len}))
{.emit: ["globalThis.__coreOwnerHmr = {step:", step, ", dispose:", dispose, ", snapshot:", snapshot, "};"].}
