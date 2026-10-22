## isonim/core/signals.nim
##
## Signal[T] — the fundamental reactive primitive.
## A typed container whose reads are tracked and whose writes notify observers.
##
## Port of SolidJS signal.ts signal creation and write propagation.

import types, graph, batch
when defined(isonimRecordable):
  import checkpoint_registry
  import std/typetraits
  when defined(js): import std/jsffi

proc storeReactiveValue[T](dest: var T; value: T) {.inline.} =
  ## Keep reactive storage as the exact value produced by the caller on JS.
  ## The JS backend's generated deep-copy path can corrupt seqs of value
  ## objects by materialising empty array placeholders for object entries.
  when defined(js):
    shallowCopy(dest, value)
  else:
    dest = value

type
  SignalState*[T] = ref object of SignalStateBase
    value*: T
    comparator*: EqualityFn[T]

  Signal*[T] = SignalState[T]
    ## Signal is just the ref state — no wrapper object, no nimCopy on assignment.

proc notifySignalWrite(state: SignalStateBase) =
  ## Non-generic: notify all observers that the signal changed.
  ## Called after the value has been updated.
  if state.observers.len > 0:
    runUpdates proc() =
      for i in 0 ..< state.observers.len:
        let obs = state.observers[i]
        obs.state = csStale
        if obs.pure:
          Updates.add(obs)
        else:
          Effects.add(obs)

proc writeSignal[T](state: SignalState[T]; value: T) =
  ## Write a new value and notify observers if the value changed.
  ## Uses runUpdates to queue observer execution when batching.
  if state.comparator != nil:
    if state.comparator(state.value, value):
      return
  elif state.value == value:
    return
  storeReactiveValue(state.value, value)
  when defined(isonimRecordable):
    inc state.checkpointLease.registration.writes
  notifySignalWrite(state)

when defined(isonimRecordable):
  when defined(js):
    proc signalContribution[T](value: JsObject): string =
      var signal: Signal[T]
      {.emit: [signal, " = ", value, ";"].}
      stableContribution(signal.value)
  else:
    proc signalContribution[T](value: pointer): string {.nimcall.} =
      # A serializer/hash may drop the last application reference while Nim
      # borrows this object's value storage. Pin only for this call, including
      # exception unwinding; the registry itself still owns no Signal reference.
      let signal {.cursor.} = cast[Signal[T]](value)
      GC_ref(signal)
      defer: GC_unref(signal)
      stableContribution(signal.value)

proc createSignal*[T](value: T; equals: EqualityFn[T] = nil): Signal[T] =
  ## Creates a new signal with the given initial value.
  ## With -d:isonimRecordable a weak registration contributes its creation
  ## ordinal and type. Existing custom hash overloads and identity-free standard
  ## value hashes observe values. A type may declare checkpointSerialize(value):
  ## string (highest priority) or checkpointHash(value): uint32. Custom functions
  ## must be deterministic. Otherwise only accepted write count is
  ## observed (identity hashes are never used). Equality-suppressed writes do
  ## not count. Owner disposal excludes the registration even if retained.
  ## All registration state and work compile out in ordinary builds.
  result = SignalState[T](
    comparator: equals,
    observers: @[],
    observerSlots: @[]
  )
  storeReactiveValue(result.value, value)
  when defined(isonimRecordable):
    when defined(js):
      var jsValue: JsObject
      {.emit: [jsValue, " = ", result, ";"].}
      let entry = registerSignal(jsValue, name(T), signalContribution[T])
    else:
      let entry = registerSignal(cast[pointer](result), name(T), signalContribution[T])
    when defined(js):
      result.checkpointLease.registration = entry
    else:
      bindSignalLease(result.checkpointLease, entry)
    if Owner != nil:
      Owner.checkpointSignals.add(entry)

proc val*[T](s: Signal[T]): T {.inline.} =
  ## Reads the signal value. Tracked if inside a computation.
  trackRead(s)
  s.value

proc `val=`*[T](s: Signal[T]; newVal: T) {.inline.} =
  ## Writes the signal value. Notifies observers if value changed.
  writeSignal(s, newVal)

proc update*[T](s: Signal[T]; fn: proc(prev: T): T) =
  ## Functional update: applies fn to the current value and writes the result.
  writeSignal(s, fn(s.value))
