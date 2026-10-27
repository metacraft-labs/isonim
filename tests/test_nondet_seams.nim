## Scripted boundaries make nondeterministic values reproducible. Real timers
## still run on the actual event loop; native browser-only seams must reject.
{.define: isonimNondetCoverage.}
import std/[unittest, json, times, monotimes, tables, strutils]
import nim_everywhere/platform
import isonim/core/nondet {.all.}
import nim_everywhere/time as neTime
import nim_everywhere/http as neHttp
import isonim/testing/test_utils

# Resolve private fields in this module rather than inside unittest's macro.
proc isPresent(observation: StorageObservation): bool = observation.present
proc observedValue(observation: StorageObservation): string = observation.value

suite "nondeterminism boundaries":
  test "scoped clock selects platform time timers and fetch and restores them":
    let outer = newTestBackend(11)
    let inner = newTestClock(42)
    var requests: seq[string]
    outer.fetchResponse = proc(req: HttpRequest): PlatformFuture[HttpResponse] =
      requests.add("outer:" & req.url)
      newCompletedFuture(HttpResponse(status: 200))
    inner.fetchResponse = proc(req: HttpRequest): PlatformFuture[HttpResponse] =
      requests.add("inner:" & req.url)
      newCompletedFuture(HttpResponse(status: 201))
    install(outer)
    defer: nondet.install(NondetBackend(nil))
    var firings: seq[string]
    let outerTimer = neTime.scheduleAt(2, proc() = firings.add("outer"))
    var innerTimer: neTime.TimerHandle
    withTestClock(inner, proc() =
      check backend() == inner
      check neTime.monotonicNowMs() == 42
      innerTimer = neTime.scheduleAt(3, proc() = firings.add("cancelled"))
      discard neTime.scheduleAt(2, proc() = firings.add("inner"))
      discard neHttp.fetchHttp(HttpRequest(url: "/scoped"))
      inner.advance(2)
      check firings == @["inner"]
      # An existing handle must cancel its owning clock across a backend swap.
      neTime.cancelTimer(outerTimer))
    check backend() == outer
    check neTime.monotonicNowMs() == 11
    neTime.cancelTimer(innerTimer)
    discard neTime.scheduleAt(1, proc() = firings.add("restored"))
    discard neHttp.fetchHttp(HttpRequest(url: "/restored"))
    TestClock(outer).advance(5)
    inner.advance(5)
    check firings == @["inner", "restored"]
    check requests == @["inner:/scoped", "outer:/restored"]
    # Direct assignment is a supported clock selector too.
    currentClock = inner
    check neTime.monotonicNowMs() == 49
    nondet.install(NondetBackend(nil))
    withTestClock(inner, proc() =
      check neTime.monotonicNowMs() == 49)
    check currentClock == nil
  test "automatic backend boot uses a valid page seed":
    nondet.install(NondetBackend(nil))
    let automatic = backend()
    check automatic of RealClock
    check automatic == currentClock
    check nondet.now().ticks > 0
    let draw = nondet.random()
    check draw != nondet.random()
    when defined(js):
      proc seedIsSerializable(): bool {.importjs: "(typeof globalThis['_'+String.fromCharCode(36)+'HY'].seed === 'number')".}
      check seedIsSerializable()
    nondet.install(NondetBackend(nil))
  when not defined(js):
    test "native browser-only seams explicitly reject unsupported operations":
      install(newRealBackend(1))
      defer: nondet.install(NondetBackend(nil))
      check nondet.now().ticks > 0
      check wallNow().toUnix() > 0
      expect ValueError: discard storageGet("key")
      expect ValueError: storageSet("key", "value")
      expect ValueError: discard cookieGet()
      expect ValueError: discard measure(nil)
      expect ValueError: discard viewport()
      expect ValueError: discard matchMedia("(min-width: 1px)")
      expect ValueError: discard location()
      expect ValueError: pushState("/new")
      expect ValueError: replaceState("/new")
      expect ValueError: discard env()
  test "storage observations preserve absence and consume one read":
    # Scripted storage permits native checks of browser-only seams. Chromium
    # below exercises the identical helper against actual localStorage.
    let b = newTestBackend()
    install(b)
    defer: nondet.install(NondetBackend(nil))
    b.script("storageGet", @[newJNull(), %"", %"value", %"sentinel"])
    let missing = storageObservation("missing")
    check not isPresent(missing)
    check observedValue(missing) == ""
    let empty = storageObservation("empty")
    check isPresent(empty)
    check observedValue(empty) == ""
    let full = storageObservation("full")
    check isPresent(full)
    check observedValue(full) == "value"
    check storageGet("next") == "sentinel"
    expect ValueError: discard storageGet("exhausted")
    b.script("storageGet", @[newJNull(), %"", %42, JsonNode(nil)])
    check storageGet("missing") == ""
    check storageGet("empty") == ""
    check storageGet("old-kind-fallback") == ""
    check storageGet("old-nil-fallback") == ""
  test "scripted reads and timers":
    let b = newTestBackend()
    install(b)
    defer: nondet.install(NondetBackend(nil))
    b.script("wallNow", @[%123.5])
    b.script("random", @[%7])
    b.script("randomFloat", @[%0.25])
    b.script("storageGet", @[%"value"])
    b.script("cookieGet", @[%"session=x"])
    b.script("location", @[%"/scripted"])
    b.script("matchMedia", @[%true])
    b.script("viewport", @[%*{"x": 0, "y": 0, "width": 800, "height": 600}])
    b.script("measure", @[%*{"x": 1, "y": 2, "width": 3, "height": 4}])
    b.script("env", @[%*{"language": "bg"}])
    check nondet.now().ticks == 0
    check wallNow().toUnixFloat() == 123.5
    check nondet.random() == 7
    check randomFloat() == 0.25
    check storageGet("key") == "value"
    storageSet("key", "new")
    check b.storage["key"] == "new"
    check cookieGet() == "session=x"
    check location() == "/scripted"
    pushState("/new")
    check b.nativeLocation == "/new"
    replaceState("/replace")
    check b.nativeLocation == "/replace"
    check matchMedia("q")
    check viewport().width == 800
    check measure(nil).height == 4
    check env()["language"].getStr() == "bg"
    check env()["language"].getStr() == "bg"
    var order: seq[int]
    var dispatches: seq[uint64]
    proc observe(id: int) =
      order.add(id)
      dispatches.add(b.clock.dispatchSequence)
    discard nondet.scheduleAt(10, proc() = observe(2))
    discard nondet.scheduleAt(5, proc() = observe(1))
    let cancelled = nondet.scheduleAt(1, proc() = order.add(99))
    nondet.cancel(cancelled)
    check order.len == 0
    TestClock(b.clock).advance(10)
    check order == @[1, 2]
    check dispatches == @[1'u64, 2'u64]
    check b.clock.dispatchSequence == 2
    var ticks = 0
    var interval: int
    interval = nondet.scheduleEvery(2, proc() =
      inc ticks
      if ticks == 3: nondet.cancel(interval))
    var frame = false
    discard requestFrame(proc() = frame = true)
    TestClock(b.clock).advance(20)
    check ticks == 3
    check frame
    b.fetchResponse = proc(req: HttpRequest): PlatformFuture[HttpResponse] =
      doAssert req.url == "/script"
      newCompletedFuture(HttpResponse(status: 201, body: "script"))
    var fetched = false
    nondet.fetch(HttpRequest(url: "/script")).onComplete(
      proc(resp: HttpResponse) =
        doAssert resp.status == 201 and resp.body == "script"
        fetched = true,
      proc(message: string) = raise newException(ValueError, message))
    when not defined(js):
      drainPlatformCallbacks()
      check fetched
    var count = 0
    for name in seamTable:
      check b.seamCalls.getOrDefault(name) > 0
      inc count
    check count == seamTable.len
  test "real clock schedules asynchronously in deadline order":
    let b = newRealBackend(123)
    install(b)
    defer: nondet.install(NondetBackend(nil))
    var order: seq[int]
    var dispatches: seq[uint64]
    proc observe(id: int) =
      order.add(id)
      dispatches.add(b.clock.dispatchSequence)
    discard nondet.scheduleAt(10, proc() = observe(2))
    discard nondet.scheduleAt(0, proc() = observe(1))
    check order.len == 0
    when not defined(js):
      waitFor neTime.sleepForRaw(30)
      check order == @[1, 2]
      check dispatches == @[1'u64, 2'u64]
      check b.clock.dispatchSequence == 2

when defined(js):
  # Do not let unittest's missing JS exit status hide asynchronous failures.
  proc verifyRealTimers() {.async.} =
    let b = newRealBackend(1)
    install(b)
    var order: seq[int]
    var dispatches: seq[uint64]
    proc observe(id: int) =
      order.add(id)
      dispatches.add(b.clock.dispatchSequence)
    discard nondet.scheduleAt(10, proc() = observe(2))
    discard nondet.scheduleAt(0, proc() = observe(1))
    doAssert order.len == 0
    await neTime.sleepForRaw(40)
    doAssert order == @[1, 2]
    doAssert dispatches == @[1'u64, 2'u64]
    doAssert b.clock.dispatchSequence == 2
    nondet.install(NondetBackend(nil))
    echo "async-real-timers: PASS"


when defined(js):
  import std/jsffi
  proc inBrowser(): bool {.importjs: "(typeof window !== 'undefined')".}
  proc testElement(): JsObject {.importjs: "(function(){var e=document.createElement('div');e.style.cssText='position:absolute;left:11px;top:13px;width:23px;height:29px';document.body.appendChild(e);return e;})()".}
  proc realBrowserSeams() {.async.} =
    let b = newRealBackend(1)
    install(b)
    let el = testElement()
    doAssert measure(el).width == 23
    doAssert measure(el).height == 29
    doAssert viewport().width > 0
    doAssert matchMedia("(min-width: 1px)")
    {.emit: "localStorage.removeItem('xr-storage-missing'); localStorage.setItem('xr-storage-empty', '');".}
    doAssert storageGet("xr-storage-missing") == ""
    doAssert storageGet("xr-storage-empty") == ""
    let missingStorage = storageObservation("xr-storage-missing")
    doAssert not isPresent(missingStorage), "storage absence must survive the browser read"
    doAssert observedValue(missingStorage) == ""
    let emptyStorage = storageObservation("xr-storage-empty")
    doAssert isPresent(emptyStorage) and observedValue(emptyStorage) == ""
    # Delegate to real Storage.getItem, counting calls without replacing storage.
    {.emit: "var xrStorageGet = Storage.prototype.getItem; var xrStorageReads = 0; Storage.prototype.getItem = function(k) { xrStorageReads++; return xrStorageGet.call(this, k); };".}
    discard storageObservation("xr-storage-missing")
    {.emit: "Storage.prototype.getItem = xrStorageGet;".}
    proc storageReads(): int {.importjs: "(xrStorageReads)".}
    doAssert storageReads() == 1
    # A real access exception must not trigger a fallback read or an empty value.
    {.emit: "Storage.prototype.getItem = function() { xrStorageReads++; throw new Error('xr-storage-denied'); }; xrStorageReads = 0;".}
    var storageError = false
    try: discard storageGet("denied")
    except: storageError = true
    {.emit: "Storage.prototype.getItem = xrStorageGet;".}
    doAssert storageError
    doAssert storageReads() == 1
    storageSet("xr-test", "real")
    doAssert storageGet("xr-test") == "real"
    {.emit: "document.cookie = 'xr-cookie=real; path=/';".}
    doAssert cookieGet().contains("xr-cookie=real")
    pushState("/pushed")
    doAssert location() == "/pushed"
    replaceState("/replaced")
    doAssert location() == "/replaced"
    let snapshot = env()
    doAssert snapshot["url"].getStr().len > 0
    doAssert snapshot["language"].getStr().len > 0
    doAssert snapshot["browserMajor"].getStr().len > 0
    for key in ["ua", "browserMajor", "timezoneOffset", "viewport", "dpr",
        "prefersDark", "prefersReducedMotion", "buildId", "assignment", "traceparent"]:
      doAssert snapshot.hasKey(key)
    doAssert nondet.now().ticks > 0
    doAssert wallNow().toUnix() > 0
    let draw = nondet.random()
    doAssert draw != nondet.random()
    let fraction = randomFloat()
    doAssert fraction >= 0 and fraction <= 1
    var framed = false
    let frameDone = newPromise proc(resolve: proc()) =
      discard requestFrame(proc() =
        framed = true
        resolve())
    var ticks = 0
    let periodicDone = newPromise proc(resolve: proc()) =
      var periodic: int
      periodic = nondet.scheduleEvery(5, proc() =
        inc ticks
        if ticks == 3:
          nondet.cancel(periodic)
          resolve())
    let resp = await nondet.fetch(HttpRequest(url: "/boundary-response", headers: @[HttpHeader(name: "X-XR-Seam", value: "real")]))
    doAssert resp.status == 200
    doAssert resp.body == "real-network"
    doAssert resp.headers.len > 0
    var responseHeader = false
    for header in resp.headers:
      if header.name == "x-xr-response" and header.value == "preserved": responseHeader = true
    doAssert responseHeader
    await frameDone
    await periodicDone
    await neTime.sleepFor(20)
    doAssert framed
    doAssert ticks == 3
    doAssert b.clock.dispatchSequence == 6
    echo "async-browser-seams: PASS"
    {.emit: "window.xrBrowserComplete = true;".}


when defined(js):
  proc verifyRejectedFetch() {.async.} =
    let b = newTestBackend()
    install(b)
    b.fetchResponse = proc(req: HttpRequest): PlatformFuture[HttpResponse] =
      newFailedFuture[HttpResponse]("rejected-boundary")
    var caught = false
    try:
      discard await nondet.fetch(HttpRequest(url: "/failure"))
    except CatchableError:
      caught = true
    doAssert caught
    doAssert b.clock.dispatchSequence == 1
    echo "rejected-fetch: PASS"
    b.fetchResponse = proc(req: HttpRequest): PlatformFuture[HttpResponse] =
      doAssert req.url == "/rpc-script"
      doAssert req.httpMethod == hmPost
      doAssert req.body == "payload"
      doAssert req.headers == @[
        HttpHeader(name: "X-CSRF-Token", value: "csrf"),
        HttpHeader(name: "X-Isonim-Context", value: "ctx"),
        HttpHeader(name: "Content-Type", value: "text/plain")]
      newCompletedFuture(HttpResponse(status: 202, body: "scripted-rpc"))
    let rpc = await browserFetch("POST", "/rpc-script", "payload", "csrf", "ctx", "text/plain", nil)
    doAssert rpc.status.to(int) == 202
    doAssert $rpc.text.to(cstring) == "scripted-rpc"
    doAssert b.clock.dispatchSequence == 2
    echo "scripted-rpc: PASS"

else:
  block:
    let b = newTestBackend()
    install(b)
    b.fetchResponse = proc(req: HttpRequest): PlatformFuture[HttpResponse] =
      newFailedFuture[HttpResponse]("rejected-boundary")
    let failed = nondet.fetch(HttpRequest(url: "/failure"))
    var caught = false
    try: discard waitFor failed
    except CatchableError: caught = true
    doAssert caught
    doAssert b.clock.dispatchSequence == 1
    nondet.install(NondetBackend(nil))

when defined(js):
  proc storageDeniedContext(): bool {.importjs: "(globalThis.xrStorageDeniedContext === true)".}
  proc verifyOpaqueOriginStorage() =
    # An actual opaque-origin browser document denies localStorage access.
    # No replacement getter or synthetic exception supplies this control.
    install(newRealBackend(1))
    var denied = false
    try: discard storageGet("opaque-origin")
    except: denied = true
    doAssert denied, "opaque-origin storage access must propagate its exception"
    {.emit: "window.xrStorageDeniedComplete = true;".}
  proc runAsyncChecks() {.async.} =
    if storageDeniedContext():
      verifyOpaqueOriginStorage()
      return
    await verifyRealTimers()
    await verifyRejectedFetch()
    if inBrowser(): await realBrowserSeams()
  discard runAsyncChecks()
