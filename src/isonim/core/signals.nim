## isonim/core/signals.nim
##
## Signal[T] — the fundamental reactive primitive.
## A typed container whose reads are tracked and whose writes notify observers.
##
## Port of SolidJS signal.ts signal creation and write propagation.

import types, graph, batch

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
  notifySignalWrite(state)

proc createSignal*[T](value: T; equals: EqualityFn[T] = nil): Signal[T] =
  ## Creates a new signal with the given initial value.
  result = SignalState[T](
    comparator: equals,
    observers: @[],
    observerSlots: @[]
  )
  storeReactiveValue(result.value, value)

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
