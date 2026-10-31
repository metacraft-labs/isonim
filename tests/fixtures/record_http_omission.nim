## Ordinary public graph must not retain deliberately unused private defines.
import isonim/core/nondet
import isonim/core/scheduler
proc selected():bool {.exportc:"rhOrdinary".} = currentClock != nil
