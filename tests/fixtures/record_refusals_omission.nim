## An unused private import must leave the ordinary graph unchanged.
import isonim/core/private/record_refusals
import isonim/core/nondet
import isonim/core/scheduler
proc selected(): bool {.exportc: "rfOrdinary".} = currentClock != nil
when isMainModule:
  let ordinary = newTestBackend()
  nondet.install(ordinary)
  doAssert backend() == ordinary
  doAssert backend().dispatchSequence == 0
