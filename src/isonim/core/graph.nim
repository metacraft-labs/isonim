## isonim/core/graph.nim
##
## Dependency tracking and topological update propagation.
## Manages the reactive graph edges between signals and computations.
##
## Port of SolidJS signal.ts dependency graph traversal.

import types

type
  SignalStateBase* = ref object of RootObj
    ## Type-erased base for signals in the dependency graph.
    ## Allows computations to track dependencies without knowing T.
    observers*: seq[ComputationBase]
    observerSlots*: seq[int]

  ComputationBase* = ref object of RootObj
    ## Type-erased base for computations.
    ## Used by signals to reference their observers.
    sources*: seq[SignalStateBase]
    sourceSlots*: seq[int]
    state*: ComputationState
    pure*: bool

# Thread-local tracking context
var Listener* {.threadvar.}: ComputationBase
  ## The currently executing computation (for dependency tracking).
  ## When non-nil, signal reads register as dependencies.

proc trackRead*(signal: SignalStateBase) =
  ## Called when a signal is read. If Listener is set,
  ## registers bidirectional dependency.
  if Listener != nil:
    let sSlot = signal.observers.len
    let cSlot = Listener.sources.len
    signal.observers.add(Listener)
    signal.observerSlots.add(cSlot)
    Listener.sources.add(signal)
    Listener.sourceSlots.add(sSlot)

proc notifyObservers*(signal: SignalStateBase) =
  ## Marks all observers as stale. Called after a signal value changes.
  for obs in signal.observers:
    obs.state = csStale
