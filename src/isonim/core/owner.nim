## isonim/core/owner.nim
##
## Owner — the reactive scope tree that manages cleanup and disposal.
## Implements createRoot, onCleanup, getOwner, and runWithOwner.
##
## Port of SolidJS signal.ts owner/root management.

import graph

proc createRoot*(fn: proc(dispose: proc())) =
  ## Creates a new reactive root with explicit disposal. Void variant.
  let prevOwner = Owner
  let prevListener = Listener
  let root = OwnerBase(owned: @[], cleanups: @[], owner: prevOwner, context: nil)

  Owner = root
  Listener = nil
  try:
    let disposeFn = proc() =
      cleanNode(root)
    fn(disposeFn)
  finally:
    Owner = prevOwner
    Listener = prevListener

proc onCleanup*(fn: proc()) =
  ## Registers a cleanup callback on the current owner.
  if Owner != nil:
    Owner.cleanups.add(fn)

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
