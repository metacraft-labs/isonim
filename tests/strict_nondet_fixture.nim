## Compile-only fixture: real public primitives, no fake raw API declaration.
## The harness selects each binding on both supported compiler backends.
import nim_everywhere/[time, http, platform]
proc component() =
  when defined(rawSleep):
    discard sleepForRaw(0)
  elif defined(rawFetch):
    discard fetchHttpRaw(HttpRequest(url: "/"))
  else:
    discard scheduleAtRaw(0, proc() = discard)
component()
