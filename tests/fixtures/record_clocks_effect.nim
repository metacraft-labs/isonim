## The internal recording primitive still performs a raw platform observation.
import isonim/core/private/record_clocks
import nim_everywhere/raw_nondet
when defined(recordClockRejectRaw):
  proc observe(clocks: RecordClockPrimitives): float64 {.tags: [].} =
    when defined(recordClockWallEffect): clocks.recordWallEpochMs()
    else: clocks.recordMonotonicMs()
else:
  proc observe(clocks: RecordClockPrimitives): float64 {.tags: [RawNondet].} =
    when defined(recordClockWallEffect): clocks.recordWallEpochMs()
    else: clocks.recordMonotonicMs()
proc keep(clocks: RecordClockPrimitives): float64 {.exportc: "rcEffect".} = observe(clocks)
