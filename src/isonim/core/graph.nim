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
    resourceStates*: seq[SignalStateBase]
      ## State signals of the resources created while this node was the
      ## current owner (every `createResource` / `createDeferredResource`
      ## overload registers here). Empty, and allocation-free, for owners
      ## that create none. Cleared with the node, so a computation that
      ## re-runs drops what its previous run created. Enumerated through
      ## `resource.ownedResourceStates`.

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

proc cleanNode*(node: OwnerBase; dispose: bool = false) =
  ## Removes a node from the reactive graph.
  ## For computations: unlinks from sources' observer lists.
  ## For all owners: runs cleanup callbacks and recursively cleans owned nodes.

  # A browser hot reload retains these owners but re-evaluates Nim's generated
  # RTTI declarations. Their object identities no longer identify the old
  # computation. The stable computation fields identify our own graph nodes;
  # native targets continue using Nim's normal runtime type check.
  var isComputation: bool
  when defined(js):
    {.emit: [isComputation, " = Object.prototype.hasOwnProperty.call(", node,
      ", 'sources') && Object.prototype.hasOwnProperty.call(", node,
      ", 'sourceSlots');"].}
  else:
    isComputation = node of ComputationBase
  if isComputation:
    var comp: ComputationBase
    when defined(js):
      {.emit: [comp, " = ", node, ";"].}
    else:
      comp = ComputationBase(node)
    for i in 0 ..< comp.sources.len:
      let source = comp.sources[i]
      let obsSlot = comp.sourceSlots[i]
      removeSourceObserver(source, obsSlot)
    comp.sources.setLen(0)
    comp.sourceSlots.setLen(0)
    if dispose:
      # A replaced child may already be in the scheduler's captured queue.
      # Unlinking its dependencies alone leaves it stale and able to resurrect
      # subscriptions after the parent has discarded its ownership. Current
      # computations remain callable when cleaning before their own rerun.
      comp.state = csClean
      comp.fn = nil

  # An exceptional cleanup must not strand later child scopes or callbacks.
  # Drain every established resource once, then propagate the first failure.
  var firstCleanupError: ref Exception
  for child in node.owned:
    try:
      cleanNode(child, dispose = true)
    except Exception:
      if firstCleanupError == nil: firstCleanupError = getCurrentException()
  node.owned.setLen(0)
  node.resourceStates.setLen(0)

  for cleanup in node.cleanups:
    try:
      cleanup()
    except Exception:
      if firstCleanupError == nil: firstCleanupError = getCurrentException()
  node.cleanups.setLen(0)
  if firstCleanupError != nil:
    raise firstCleanupError

proc notifyObservers*(signal: SignalStateBase) =
  ## Marks all observers as stale. Called after a signal value changes.
  for obs in signal.observers:
    obs.state = csStale
