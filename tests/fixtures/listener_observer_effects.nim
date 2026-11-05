## Checked actual claim/release effects: genuine allowed-tag positive and each
## missing-tag negative. Callback effects are delayed, not falsely inferred.
import std/jsffi
import isonim/core/nondet
when defined(observerMissingRaw):
  proc checked() {.tags: [DomEventEffect].} =
    when defined(observerReleaseOnly):
      var stop: InternalListenerObserverRelease
      stop()
    else:
      let stop = claimInternalListenerObserver(proc(record: JsObject) = discard)
      stop()
elif defined(observerMissingDom):
  proc checked() {.tags: [RawNondet].} =
    when defined(observerReleaseOnly):
      var stop: InternalListenerObserverRelease
      stop()
    else:
      let stop = claimInternalListenerObserver(proc(record: JsObject) = discard)
      stop()
else:
  proc checked() {.tags: [RawNondet, DomEventEffect].} =
    when defined(observerReleaseOnly):
      var stop: InternalListenerObserverRelease
      stop()
    else:
      let stop = claimInternalListenerObserver(proc(record: JsObject) = discard)
      stop()
checked()
