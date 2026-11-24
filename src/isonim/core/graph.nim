## isonim/core/graph.nim
##
## Dependency tracking and topological update propagation.
## Manages the reactive graph edges between signals and computations.
## Also defines the Owner tree for cleanup and disposal.
##
## Port of SolidJS signal.ts dependency graph traversal.

import types
when defined(isonimRecordable): import checkpoint_registry
import platform

type ContextTable* = HashMapRef[int, RootRef]

type
  SignalStateBase* = ref object of RootObj
    ## Type-erased base for signals in the dependency graph.
    ## Allows computations to track dependencies without knowing T.
    when defined(isonimRecordable):
      checkpointLease*: SignalLease
    observers*: seq[ComputationBase]
    observerSlots*: seq[int]
    memoComputation*: ComputationBase
      ## For a memo's signal: the computation that produces its value, so a
      ## reader can bring it up to date before reading (pull). Nil for a
      ## plain signal.

  OwnerBase* = ref object of RootObj
    ## Base of the disposal tree. Owner tracks child computations and cleanup callbacks.
    when defined(isonimRecordable):
      checkpointSignals*: seq[SignalRegistration]
        ## Metadata only: the owner tree must never keep a signal alive.
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
    memoSignal*: SignalStateBase      ## When non-nil, this computation acts as a memo
    errored*: bool
      ## Its last run ended in an error that went to a handler (or was
      ## reported as unhandled). The next run that succeeds tells the
      ## handlers above it that it recovered (see `computation.handleError`).

  ErrorHandler* = proc(err: ref CatchableError)
    ## Receives an error raised by a computation (or one of its cleanups)
    ## under the owner the handler is registered on.

  ErrorBox* = ref object of RootObj
    ## The error handling registered on an owner, kept in its context table
    ## under `errorHandlerKey`, so owners without a handler pay nothing.
    handler*: proc(err: ref CatchableError; source: ComputationBase)
      ## Never nil. Called with the error and the computation it came from;
      ## with `err` nil, `source`, whose last run had failed, has just run
      ## successfully (an error boundary shows its content again).

const errorHandlerKey* = 0
  ## Context ids start at 1 (`context.createContext`), so 0 is free.

proc setErrorBox*(node: OwnerBase; box: ErrorBox) =
  ## Registers `box` on `node`, replacing an earlier one.
  if node.contextTable.isNil:
    node.contextTable = newHashMapRef[int, RootRef]()
  node.contextTable[errorHandlerKey] = box

proc errorBox*(handler: ErrorHandler): ErrorBox =
  ## A box that passes errors to `handler` and ignores recoveries.
  ErrorBox(handler: proc(err: ref CatchableError; source: ComputationBase) =
    if err != nil: handler(err))

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

proc isComputationNode*(node: OwnerBase): bool {.inline.} =
  ## True when `node` is a computation (not a bare root owner).
  ##
  ## A browser hot reload retains these owners but re-evaluates Nim's
  ## generated RTTI declarations, so on JS `of` no longer identifies a
  ## retained computation. The stable computation fields identify our own
  ## graph nodes instead; native targets use Nim's normal runtime type check.
  when defined(js):
    {.emit: [result, " = ", node, " != null && Object.prototype.hasOwnProperty.call(", node,
      ", 'sources') && Object.prototype.hasOwnProperty.call(", node,
      ", 'sourceSlots');"].}
  else:
    result = node != nil and node of ComputationBase

proc asComputation*(node: OwnerBase): ComputationBase {.inline.} =
  ## Converts a node `isComputationNode` accepted. Unchecked on JS, for the
  ## same hot-reload reason.
  when defined(js):
    {.emit: [result, " = ", node, ";"].}
  else:
    result = ComputationBase(node)

proc cleanNode*(node: OwnerBase; dispose: bool = false) =
  ## Removes a node from the reactive graph.
  ## For computations: unlinks from sources' observer lists.
  ## For all owners: runs cleanup callbacks and recursively cleans owned nodes.
  if isComputationNode(node):
    let comp = asComputation(node)
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
  when defined(isonimRecordable):
    for entry in node.checkpointSignals: entry.active = false
    node.checkpointSignals.setLen(0)

  for cleanup in node.cleanups:
    try:
      cleanup()
    except Exception:
      if firstCleanupError == nil: firstCleanupError = getCurrentException()
  node.cleanups.setLen(0)
  if firstCleanupError != nil:
    raise firstCleanupError
