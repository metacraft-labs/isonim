## Actual module import with absent/native APIs; enabled-unused does not claim.
import isonim/core/nondet
when not defined(js) or not defined(isonimInternalListenerObserver):
  static:
    doAssert not declared(claimInternalListenerObserver)
    doAssert not declared(InternalListenerObserverRelease)
when defined(js):
  {.emit: "globalThis.observerUnusedLoaded=true;".}
else: echo "observer native omission passed"
