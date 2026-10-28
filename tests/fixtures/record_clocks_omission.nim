## An ordinary import has no available private object or owner dependency.
import isonim/core/private/record_clocks
when declared(RecordClockPrimitives):
  {.error: "private Record clock type leaked into ordinary build".}
echo "private Record clocks omitted"
