## isonim/core/graph.nim
##
## Dependency tracking and topological update propagation.
## Manages the reactive graph edges between signals and computations.
## Also defines the Owner tree for cleanup and disposal, and the error
## handler an owner can carry.
##
## These are the core's internal building blocks, exported for the other
## core modules, the DSL and the renderers. Application code uses the
## public API built on them (`signals`, `computation`, `owner`, `batch`).
##
## Port of SolidJS signal.ts dependency graph traversal.

import types
when defined(isonimRecordable): import checkpoint_registry
import platform

type ContextTable* = HashMapRef[int, RootRef]
  ## The context values set on an owner, keyed by context id. Nil until the
  ## first value (or error handler) is set, so an owner without one pays
  ## no allocation.

type
  SignalStateBase* = ref object of RootObj
    ## Type-erased base for signals in the dependency graph.
    ## Allows computations to track dependencies without knowing T.
    when defined(isonimRecordable):
      checkpointLease*: SignalLease
        ## The signal's registration with the checkpoint registry (only in
        ## builds with `-d:isonimRecordable`).
    observers*: seq[ComputationBase]
      ## The computations that read this signal in their last run.
    observerSlots*: seq[int]
      ## For each observer, the index of this signal in its `sources`, so
      ## that an edge is removed in constant time.
    memoComputation*: ComputationBase
      ## For a memo's signal: the computation that produces its value, so a
      ## reader can bring it up to date before reading (pull). Nil for a
      ## plain signal.

  OwnerBase* = ref object of RootObj
    ## Base of the disposal tree. Owner tracks child computations and cleanup callbacks.
    when defined(isonimRecordable):
      checkpointSignals*: seq[SignalRegistration]
        ## The checkpoint registrations of the signals created under this
        ## owner (only with `-d:isonimRecordable`), deactivated when it is
        ## cleaned. Metadata only: the owner tree must never keep a signal alive.
    owned*: seq[OwnerBase]
      ## Children disposed with this node: the computations created under
      ## it, and the roots `owner.createRoot` made under it.
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
    ownerSlot*: int
      ## For a root registered in its owner's `owned`: its index there, so
      ## that disposing it by hand takes it out of that list in constant
      ## time (`unlinkRoot`). Stale once the root is out of the list
      ## (detached, released, or disposed with its owner), which
      ## `unlinkRoot` detects by identity. Only roots read it: on a
      ## computation it is written when the computation moves into a
      ## released root's place, and never read.

  ComputationBase* = ref object of OwnerBase
    ## Type-erased base for computations.
    ## Used by signals to reference their observers.
    sources*: seq[SignalStateBase]
      ## The signals and memos read by the last run, in read order.
    sourceSlots*: seq[int]
      ## For each source, the index of this computation in its `observers`.
    state*: ComputationState
      ## Clean, pending (a memo it reads may have changed) or stale (it
      ## must re-run).
    pure*: bool
      ## True for memos and `createComputed` (queued and run before
      ## effects), false for effects.
    fn*: proc()                       ## The computation function (type-erased)
    memoSignal*: SignalStateBase      ## When non-nil, this computation acts as a memo
    errored*: bool
      ## Its last run ended in an error that went to a handler (or was
      ## reported as unhandled). The next run that succeeds tells the
      ## handlers above it that it recovered (see `computation.handleError`).

  ErrorHandler* = proc(err: ref CatchableError)
    ## Receives an error raised by a computation (or one of its cleanups)
    ## under the owner the handler is registered on. Only a
    ## `CatchableError` is ever passed; a `Defect` is not routed.

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
  ## Incremented once per flush.

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
  ## With `dispose`, a computation is also made inert (it never runs again).
  ##
  ## The unwind order: the owned children first, from the last one (each
  ## exactly once), then this node's own cleanups in registration order.
  ## Every child and every cleanup runs even when one of them raises; the
  ## first exception is raised once all have run.
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
  # Children first, from the end of the list (the last created first,
  # until a root released by hand moves the last child into its place),
  # then this node's own cleanups: disposal unwinds. By index from the
  # end, because a child's cleanup may release a sibling root by hand
  # (`unlinkRoot`), which moves the last child into the released one's
  # place: every child is still visited, at worst twice, and cleaning a
  # cleaned node does nothing.
  var firstCleanupError: ref Exception
  var i = node.owned.len
  while i > 0:
    dec i
    if i < node.owned.len:
      try:
        cleanNode(node.owned[i], dispose = true)
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

proc unlinkRoot*(root: OwnerBase) =
  ## Takes `root` out of its owner's children, by moving the last child
  ## into its place, so that its owner no longer disposes it. Does nothing
  ## for a root that is not one of them (detached, made with no current
  ## owner, already taken out, or already disposed with its owner): a root
  ## is never added to a list again once out of it, so the identity test
  ## below is the whole check, and the slot is never reset.
  let p = root.owner
  if p != nil:
    let i = root.ownerSlot
    let last = p.owned.len - 1
    if i <= last and p.owned[i] == root:
      let moved = p.owned[last]
      moved.ownerSlot = i
      p.owned[i] = moved
      when defined(js):
        # Shrinking only: the generic `setLen` would also carry the code
        # that grows a seq.
        {.emit: [p, ".owned.length = ", last, ";"].}
      else:
        p.owned.setLen(last)
