## Compile the actual Real backend together with a component using the seam.
## No mocks: this is a compile boundary test, not a runtime timer assertion.
## The tag ceilings also reject RawNondet leaking through public seams.
import isonim/core/nondet
import nim_everywhere/platform
proc component() {.tags: [ClockEffect].} =
  discard scheduleAt(0, proc() = discard)
  discard now()
proc networkComponent() {.tags: [NetEffect].} =
  discard fetch(HttpRequest(url: "/"))
install(newRealBackend(1))
component()
