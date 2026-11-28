## BACKPORT PROBE ONLY (scratch branch rxc-backport-probe, never to be merged): the three core
## entry points the ported `async_value` and `actions` call that the
## pre-campaign core (5a35eb01f8) does not have. Each keeps the old core's
## behaviour; none adds a guarantee the campaign's core stages add.

import isonim/core/[graph, signals]

type ErrorHandler* = proc(err: ref CatchableError)

proc onError*(handler: ErrorHandler) =
  ## The old core routes no errors (a later core change added routing): compile shim only,
  ## the handler is never called.
  discard

proc handleError*(source: ComputationBase; err: ref CatchableError) =
  ## The old core's behaviour for an error a computation raises: it escapes
  ## to whoever wrote the signal or settled the future.
  raise err

proc notifyChanged*[T](s: Signal[T]) =
  ## The old core has no in-place notification (a later core change added it): write the
  ## value onto itself with a comparator that always says "changed".
  let cmp = s.comparator
  s.comparator = proc(a, b: T): bool = false
  s.val = s.value
  s.comparator = cmp
