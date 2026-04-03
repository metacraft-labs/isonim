## isonim/core/graph.nim
##
## Dependency tracking and topological update propagation.
## Manages the reactive graph edges between signals and computations.
## Also defines the Owner tree for cleanup and disposal.
##
## Port of SolidJS signal.ts dependency graph traversal.

import types
import platform

type ContextTable* = HashMapRef[int, RootRef]

type
  SignalStateBase* = ref object of RootObj
    ## Type-erased base for signals in the dependency graph.
    ## Allows computations to track dependencies without knowing T.
    observers*: seq[ComputationBase]
    observerSlots*: seq[int]

  OwnerBase* = ref object of RootObj
    ## Base of the disposal tree. Owner tracks child computations and cleanup callbacks.
    owned*: seq[ComputationBase]     ## Child computations
    cleanups*: seq[proc()]            ## Cleanup callbacks
    owner*: OwnerBase                 ## Parent owner
    contextTable*: ContextTable       ## Context values keyed by ContextId

  ComputationBase* = ref object of OwnerBase
    ## Type-erased base for computations.
    ## Used by signals to reference their observers.
    sources*: seq[SignalStateBase]
    sourceSlots*: seq[int]
    state*: ComputationState
    pure*: bool
    fn*: proc()                       ## The computation function (type-erased)
    updatedAt*: int                   ## Execution counter for cycle detection
    memoSignal*: SignalStateBase      ## When non-nil, this computation acts as a memo

# Thread-local tracking context
var Listener* {.threadvar.}: ComputationBase
  ## The currently executing computation (for dependency tracking).
  ## When non-nil, signal reads register as dependencies.

var Owner* {.threadvar.}: OwnerBase
  ## Current owner context. Computations created become children of this owner.

var ExecCount* {.threadvar.}: int
  ## Monotonically increasing execution counter for update cycle detection.

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

proc removeSourceObserver(source: SignalStateBase; obsSlot: int) =
  ## Remove observer at obsSlot from source using swap-and-pop for O(1).
  let lastIdx = source.observers.len - 1
  if obsSlot != lastIdx:
    # Move last observer into the slot being removed
    let movedObs = source.observers[lastIdx]
    let movedCSlot = source.observerSlots[lastIdx]
    source.observers[obsSlot] = movedObs
    source.observerSlots[obsSlot] = movedCSlot
    # Update the moved observer's sourceSlots to reflect its new position
    if movedCSlot < movedObs.sourceSlots.len:
      movedObs.sourceSlots[movedCSlot] = obsSlot
  source.observers.setLen(lastIdx)
  source.observerSlots.setLen(lastIdx)

proc cleanNode*(node: OwnerBase) =
  ## Removes a node from the reactive graph.
  ## For computations: unlinks from sources' observer lists.
  ## For all owners: runs cleanup callbacks and recursively cleans owned nodes.

  # If it's a computation, unlink from all sources
  if node of ComputationBase:
    let comp = ComputationBase(node)
    for i in 0 ..< comp.sources.len:
      let source = comp.sources[i]
      let obsSlot = comp.sourceSlots[i]
      removeSourceObserver(source, obsSlot)
    comp.sources.setLen(0)
    comp.sourceSlots.setLen(0)

  # Recursively clean owned computations
  for child in node.owned:
    cleanNode(child)
  node.owned.setLen(0)

  # Run cleanup callbacks
  for cleanup in node.cleanups:
    cleanup()
  node.cleanups.setLen(0)

proc notifyObservers*(signal: SignalStateBase) =
  ## Marks all observers as stale. Called after a signal value changes.
  for obs in signal.observers:
    obs.state = csStale
