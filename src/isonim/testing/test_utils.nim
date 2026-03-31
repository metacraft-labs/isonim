## Testing utilities for IsoNim.
## Provides withTestClock helper for deterministic testing.

import ../core/clock

proc withTestClock*(tc: TestClock; fn: proc()) =
  ## Executes fn with the given TestClock as the global clock.
  ## Restores the previous clock after fn completes.
  let prevClock = currentClock
  currentClock = tc
  try:
    fn()
  finally:
    currentClock = prevClock

template withFakeTime*(body: untyped) =
  ## Convenience template that creates a TestClock and executes body.
  ## The TestClock is available as `tc` inside the body.
  let tc {.inject.} = newTestClock()
  withTestClock(tc):
    body
