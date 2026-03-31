## Transitions for IsoNim.
## Allows deferring state updates until async work completes.

import signals, batch

type
  TransitionState* = object
    pending*: Signal[bool]

proc startTransition*(fn: proc()) =
  ## Executes fn in a transition context.
  ## For now, this is equivalent to batch (full transition support later).
  batch proc() =
    fn()

proc useTransition*(): tuple[pending: proc(): bool, start: proc(fn: proc())] =
  ## Returns a pending signal and a start function.
  var pendingSig = createSignal(false)
  let pending = proc(): bool = pendingSig.val
  let start = proc(fn: proc()) =
    pendingSig.val = true
    batch proc() =
      fn()
      pendingSig.val = false
  (pending, start)
