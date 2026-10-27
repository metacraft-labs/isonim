## Compile-only fixture: real public primitives, no fake raw API declaration.
## The harness selects each binding on both supported compiler backends.
import nim_everywhere/[time, http, platform]
when defined(js): import std/jsffi
proc component() =
  when defined(rawBrowserResponse):
    discard fetchBrowserResponseRaw("/", JsObject{})
  elif defined(rawSleep):
    discard sleepForRaw(0)
  elif defined(rawFetch):
    discard fetchHttpRaw(HttpRequest(url: "/"))
  else:
    discard scheduleAtRaw(0, proc() = discard)
component()
