## The JS half uses the exact real renderer import graph with an UNUSED flag.
## Native uses an ordinary supported graph; JS-only renderer errors prove nothing.
when defined(js):
  import isonim/web/[web_renderer, dom_api]
  import isonim/core/clock
  import std/jsffi
  import nim_everywhere/backend
  import isonim/rxcore
  proc omittedClock(): JsObject = cast[JsObject](currentClock)
  proc omittedSharedConfig(): JsObject =
    {.emit: [result, " = ", sharedConfig, ";"].}
  proc omittedPublic(tag:cstring):Element = WebRenderer().createElement($tag)
  proc omittedHook(): JsObject = cast[JsObject](currentBackendHook)
  {.emit: "globalThis.omittedClock=`omittedClock`; globalThis.omittedHook=`omittedHook`; globalThis.omittedSharedConfig=`omittedSharedConfig`; globalThis.omittedPublic=`omittedPublic`; globalThis.omissionReady=true;".}
else:
  import isonim/core/clock
  let original = currentClock
  doAssert currentClock == original
  echo "native ordinary graph passes"
