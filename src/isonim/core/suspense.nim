## Suspense context for IsoNim.
## Tracks pending async operations within a boundary.

import signals

type
  SuspenseContext* = ref object
    pendingCount*: Signal[int]

proc newSuspenseContext*(): SuspenseContext =
  SuspenseContext(pendingCount: createSignal(0))

proc registerPending*(ctx: SuspenseContext) =
  ## Increments the pending count.
  ctx.pendingCount.val = ctx.pendingCount.val + 1

proc resolvePending*(ctx: SuspenseContext) =
  ## Decrements the pending count.
  let current = ctx.pendingCount.val
  if current > 0:
    ctx.pendingCount.val = current - 1

proc inSuspense*(ctx: SuspenseContext): bool =
  ## Returns true if there are pending operations.
  ctx.pendingCount.val > 0
