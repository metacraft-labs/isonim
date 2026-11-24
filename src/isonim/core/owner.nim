## isonim/core/owner.nim
##
## Owner — the reactive scope tree that manages cleanup and disposal.
## Implements createRoot, createDetachedRoot, onCleanup, getOwner, and
## runWithOwner.
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
  createRoot(proc(dispose: proc()) =
    unlinkRoot(Owner)
    fn(dispose))

proc onCleanup*(fn: proc()) =
  ## Registers a cleanup callback on the current owner.
  if Owner != nil:
    Owner.cleanups.add(fn)

proc onError*(handler: ErrorHandler) =
  ## Handles the errors of the computations under the current owner
  ## (provisional API). A `CatchableError` raised by a computation's run or
  ## cleanup goes to the nearest owner with a handler, and the rest of the
  ## flush still runs; a handler that raises passes its error to the next
  ## one above. Without any handler, the outermost flush rethrows the first
  ## error once it has finished. Registering again replaces the handler.
  ## A nil handler is ignored.
  if Owner != nil and handler != nil:
    setErrorBox(Owner, errorBox(handler))

proc getOwner*(): OwnerBase =
  ## Returns the current owner.
  Owner

proc runWithOwner*(owner: OwnerBase; fn: proc()) =
  ## Executes fn in the context of the given owner.
  let prevOwner = Owner
  let prevListener = Listener
  Owner = owner
  Listener = nil
  try:
    fn()
  finally:
    Owner = prevOwner
    Listener = prevListener
