## isonim/core/owner.nim
##
## Owner — the reactive scope tree that manages cleanup and disposal.
## Implements createRoot, createDetachedRoot, onCleanup, onError, getOwner,
## and runWithOwner.
##
## Every root and computation has an owner: the root or computation that was
## current when it was created. Disposing an owner unwinds what it owns: its
## children first (each exactly once), then its own cleanups, in the order
## they were registered. A computation that re-runs disposes what its
## previous run created before it runs again. The order among siblings is
## not guaranteed to be their creation order (a root released by hand takes
## the last sibling into its place). Errors travel the same chain: an
## ordinary error raised by a computation goes to the nearest owner that
## handles errors (see `onError`).
##
## Port of SolidJS signal.ts owner/root management.

import graph

proc createRoot*(fn: proc(dispose: proc())) =
  ## Creates a new reactive root and runs `fn` in it, untracked. `fn`
  ## receives the root's `dispose`.
  ##
  ## Created under an owner (another root, or a computation that is
  ## running), the root is one of that owner's children: disposing the
  ## owner, or re-running it when it is a computation, disposes the root
  ## too, before the owner's own cleanups run. `dispose` releases it early,
  ## and calling it again, or after the owner has disposed it, does nothing.
  ## A root that must outlive its creator is made with `createDetachedRoot`.
  ## Created with no current owner, the root lives until its own `dispose`.
  ##
  ## Disposal unwinds: the root's children first (nested roots and
  ## computations, each disposed exactly once), then the cleanups registered
  ## on the root itself, in registration order. The order among siblings is
  ## not their creation order once a root has been released by hand.
  ## (Owned nested roots are not yet a stable API.)
  let prevOwner = Owner
  let prevListener = Listener
  let root = OwnerBase(owner: prevOwner)
  if prevOwner != nil:
    root.ownerSlot = prevOwner.owned.len
    prevOwner.owned.add(root)

  Owner = root
  Listener = nil
  try:
    fn(proc() =
      unlinkRoot(root)
      cleanNode(root))
  finally:
    Owner = prevOwner
    Listener = prevListener

proc createDetachedRoot*(fn: proc(dispose: proc())) =
  ## `createRoot` for a root whose lifetime its creator manages by hand: it
  ## is not disposed with the owner it was created under, only by its own
  ## `dispose`. It still sees that owner's context values and error
  ## handlers. Not yet a stable API.
  ##
  ## Use it for content whose lifetime is decided somewhere other than the
  ## code that creates it: a page an outlet keeps across re-runs, a mount
  ## requested from an effect. Created by an effect as a plain `createRoot`,
  ## such content would end when the effect re-runs. Unlike running the
  ## code with no owner (`runWithOwner(nil, ...)`), a detached root keeps
  ## both the context lookup and the error routing of its creator.
  ##
  ## Limits: a detached root that is never disposed leaks, with everything
  ## created under it; and its parent link keeps the creator object alive
  ## while it lives.
  createRoot(proc(dispose: proc()) =
    unlinkRoot(Owner)
    fn(dispose))

proc onCleanup*(fn: proc()) =
  ## Registers a cleanup callback on the current owner. It runs once, when
  ## the owner is disposed, or before the owner runs again when it is a
  ## computation; after the owner's children have been disposed, and in
  ## registration order among the owner's cleanups. Ignored when there is no
  ## current owner.
  if Owner != nil:
    Owner.cleanups.add(fn)

proc onError*(handler: ErrorHandler) =
  ## Handles the errors of the computations under the current owner
  ## (provisional API). A `CatchableError` raised by a computation's run or
  ## cleanup goes to the nearest owner with a handler, and the rest of the
  ## flush still runs; a handler that raises passes its error to the next
  ## one above. Without any handler, the outermost flush rethrows the first
  ## error once it has finished; outside a flush, the error is raised at
  ## once. Registering again replaces the handler. A nil handler is ignored.
  ##
  ## The nearest handler is looked for from the failing computation upwards,
  ## so an effect's own error arm (`createEffectWithErrorArm`) gets the error
  ## before an `onError` above it. A handler runs untracked, with its own
  ## owner as the current owner. A handler above several readers of one
  ## failing memo is called once per reader, with the same error object. A
  ## service failure inside an async value is that value's `failed` state
  ## and reaches no handler.
  ##
  ## Only ordinary errors are routed. A `Defect` (and, on the JS backend, an
  ## exception that is not a Nim exception, such as a `TypeError` from a host
  ## API) is never passed to a handler: it abandons the rest of the flush
  ## and reaches the code that wrote the signal or ran the batch, as the
  ## same object. The graph stays usable afterwards: the next change queues
  ## the abandoned readers again. A host that must survive a defect, such as
  ## an editor's live preview, catches it outside the flush
  ## and discards and rebuilds the ViewModel. Why: a defect is a programming
  ## error, and Nim does not let code catch one portably (with
  ## `--panics:on` it cannot be caught at all), so routing defects would make
  ## the behaviour depend on the build.
  if Owner != nil and handler != nil:
    setErrorBox(Owner, errorBox(handler))

proc getOwner*(): OwnerBase =
  ## Returns the current owner.
  Owner

proc runWithOwner*(owner: OwnerBase; fn: proc()) =
  ## Executes fn in the context of the given owner, untracked: what `fn`
  ## creates belongs to `owner`, sees its context values and routes its
  ## errors through it. With a nil `owner`, what `fn` creates has no owner:
  ## nothing disposes it with anything else.
  let prevOwner = Owner
  let prevListener = Listener
  Owner = owner
  Listener = nil
  try:
    fn()
  finally:
    Owner = prevOwner
    Listener = prevListener
