## BACKPORT PROBE ONLY (scratch branch rxc-backport-probe, never to be merged): the three core
## entry points the ported `async_value` and `actions` call that the
## pre-campaign core (5a35eb01f8) does not have. In the port step each kept
## the old core's behaviour (`onError` a no-op, `handleError` a raise); the
## fix for error routing (step 2) made them route these modules' own errors.

import isonim/core/[graph, signals, owner, platform]

type
  ErrorHandler* = proc(err: ref CatchableError)
  ErrorBox = ref object of RootObj
    handler: ErrorHandler

const errorHandlerKey = 0  # context ids start at 1

proc onError*(handler: ErrorHandler) =
  ## Step 2 (stands in for the later core's error routing, only for the errors these modules report):
  ## keep the handler on the current owner.
  if Owner != nil and handler != nil:
    if Owner.contextTable.isNil:
      Owner.contextTable = newHashMapRef[int, RootRef]()
    Owner.contextTable[errorHandlerKey] = ErrorBox(handler: handler)

proc handleError*(source: ComputationBase; err: ref CatchableError) =
  ## Deliver `err` to the nearest handler on `source` or its owners; a
  ## handler that raises passes its error upwards; with none it is raised to
  ## whoever settled the future, as the old core does.
  var err = err
  var o: OwnerBase = source
  while o != nil:
    if not o.contextTable.isNil and errorHandlerKey in o.contextTable:
      let box = ErrorBox(o.contextTable[errorHandlerKey])
      try:
        let e = err
        runWithOwner(o, proc() = box.handler(e))
        return
      except CatchableError as x:
        err = x
    o = o.owner
  raise err

proc notifyChanged*[T](s: Signal[T]) =
  ## The old core has no in-place notification (a later core change added it): write the
  ## value onto itself with a comparator that always says "changed".
  let cmp = s.comparator
  s.comparator = proc(a, b: T): bool = false
  s.val = s.value
  s.comparator = cmp
