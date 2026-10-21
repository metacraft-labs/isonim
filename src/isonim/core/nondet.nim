## Platform boundaries. ClockBase owns timer ordering; scripted reads never
## silently fall back to browser globals or the network.
## Each tagged seam encapsulates platform effects and replaces them with its
## specific boundary tag; the casts do not expose RawNondet to callers.
import std/[times, monotimes, json, tables, random]
when not defined(js): import std/sysrand
when defined(js): import std/jsffi
import ./clock
import nim_everywhere/[backend, async_compat, platform]
import nim_everywhere/http as neHttp
import nim_everywhere/raw_nondet
export raw_nondet
export clock, async_compat

type
  ClockEffect* = object of RootEffect
  RandomEffect* = object of RootEffect
  NetEffect* = object of RootEffect
  StorageEffect* = object of RootEffect
  LayoutEffect* = object of RootEffect
  DomEventEffect* = object of RootEffect
  Rect* = object
    x*, y*, width*, height*: float64
  NondetBackend* = ClockBase

const seamTable* = ["now", "wallNow", "scheduleAt", "scheduleEvery",
  "requestFrame", "cancel", "random", "randomFloat", "fetch",
  "storageGet", "storageSet", "cookieGet", "measure", "viewport",
  "matchMedia", "location", "pushState", "replaceState", "env"]

proc install*(b: NondetBackend)

proc clock*(b: NondetBackend): ClockBase = b

proc newRealBackend*(seed: int64): NondetBackend =
  ## Bootstrap supplies the hydration seed when present.
  result = newRealClock()
  result.randomState = initRand(seed)
proc newTestBackend*(startMs = 0.0; seed = 1'i64): NondetBackend =
  result = newTestClock(startMs)
  result.randomState = initRand(seed)
when defined(js):
  proc pageSeed(): int64 {.importjs: "(function(){var hy=globalThis['_'+String.fromCharCode(36)+'HY']||(globalThis['_'+String.fromCharCode(36)+'HY']={});if(hy.seed===undefined){var a=new Uint32Array(1);crypto.getRandomValues(a);hy.seed=a[0];}return BigInt(hy.seed);})()", tags: [RawNondet].}
else:
  proc pageSeed(): int64 =
    var bytes: array[4, byte]
    if not urandom(bytes): raise newException(IOError, "cannot seed page randomness")
    for i, value in bytes: result = result or (int64(value) shl (i * 8))
proc backend*(): NondetBackend =
  if currentClock == nil: install(newRealBackend(pageSeed()))
  currentClock
template note(name: string) =
  # Coverage counters are absent from normal builds, including their table
  # state and per-call lookup/allocation. Dispatch ordering remains universal.
  when defined(isonimNondetCoverage):
    let selected = backend()
    selected.seamCalls[name] = selected.seamCalls.getOrDefault(name) + 1
proc script*(b: NondetBackend; name: string; values: seq[JsonNode]) =
  if not b.scripted: raise newException(ValueError, "not a scripted backend")
  b.reads[name] = values
proc read(b: NondetBackend; name: string): JsonNode =
  if name notin b.reads or b.reads[name].len == 0:
    raise newException(ValueError, "missing scripted boundary: " & name)
  result = b.reads[name][0]
  b.reads[name].delete(0)
proc now*(): MonoTime {.tags: [ClockEffect].} =
  {.cast(tags: []).}:
    note("now")
    block:
      var epoch: MonoTime
      epoch + initDuration(nanoseconds = int64(backend().now() * 1_000_000))
proc wallNow*(): Time {.tags: [ClockEffect].} =
  {.cast(tags: []).}:
    note("wallNow")
    let b = backend()
    if b.scripted: return fromUnixFloat(b.read("wallNow").getFloat())
    getTime()
proc scheduleAt*(afterMs: float64; cb: proc()): int {.tags: [ClockEffect].} =
  ## Schedule after a delay, matching nim-everywhere's time facade.
  ## Effects of deferred callbacks belong to their later dispatch slot.
  {.cast(tags: []).}:
    note("scheduleAt")
    let b = backend()
    inc b.nextHandle
    let id = b.nextHandle
    b.seamTimers[id] = b.schedule(proc() =
      b.seamTimers.del(id)
      cb(), afterMs)
    id
proc cancel*(id: int) {.tags: [ClockEffect].} =
  {.cast(tags: []).}:
    note("cancel")
    let b = backend()
    if id in b.frameCancels:
      b.frameCancels[id]()
      b.frameCancels.del(id)
    if id in b.seamTimers:
      b.cancel(b.seamTimers[id])
      b.seamTimers.del(id)
proc scheduleEvery*(intervalMs: float64; cb: proc()): int {.tags: [ClockEffect].} =
  {.cast(tags: []).}:
    note("scheduleEvery")
    if intervalMs <= 0: raise newException(ValueError, "interval must be positive")
    let b = backend()
    inc b.nextHandle
    let id = b.nextHandle
    var arm: proc()
    arm = proc() =
      b.seamTimers[id] = b.schedule(proc() =
        if id notin b.seamTimers: return
        cb()
        if id in b.seamTimers: arm(), intervalMs)
    arm()
    id
when defined(js):
  proc rawFrame(cb: proc()): int {.importjs: "requestAnimationFrame(function(){#();})", tags: [RawNondet].}
  proc rawCancelFrame(id: int) {.importjs: "cancelAnimationFrame(#)", tags: [RawNondet].}
proc requestFrame*(cb: proc()): int {.tags: [ClockEffect].} =
  {.cast(tags: []).}:
    note("requestFrame")
    let b = backend()
    when defined(js):
      if not b.scripted:
        inc b.nextHandle
        let id = b.nextHandle
        let nativeId = rawFrame(proc() =
          b.frameCancels.del(id)
          inc b.dispatchSequence
          cb())
        b.frameCancels[id] = proc() = rawCancelFrame(nativeId)
        return id
    scheduleAt(16, cb)
proc random*(): uint64 {.tags: [RandomEffect].} =
  {.cast(tags: []).}:
    note("random")
    let b = backend()
    if b.scripted: return uint64(b.read("random").getBiggestInt())
    b.randomState.next()
proc randomFloat*(): float64 {.tags: [RandomEffect].} =
  {.cast(tags: []).}:
    note("randomFloat")
    let b = backend()
    if b.scripted: return b.read("randomFloat").getFloat()
    b.randomState.rand(1.0)
when defined(js):
  proc settled[T](future: Future[T]; cb: proc()): Future[T]
      {.importjs: "(function(f,cb){return f.then(function(v){cb();return v;},function(e){cb();throw e;});})(#,#)".}
proc fetch*(request: HttpRequest): PlatformFuture[HttpResponse] {.tags: [NetEffect].} =
  {.cast(tags: []).}:
    note("fetch")
    let b = backend()
    if b.scripted and b.fetchResponse == nil:
      raise newException(ValueError, "missing scripted fetch")
    let pending = if b.fetchResponse != nil: b.fetchResponse(request)
      else: neHttp.fetchHttpRaw(rawBackendAccess, request)
    when defined(js):
      return settled(pending, proc() = inc b.dispatchSequence)
    else:
      let wrapped = newFuture[HttpResponse]("nondet fetch settlement")
      pending.onComplete(
        proc(value: HttpResponse) =
          inc b.dispatchSequence
          wrapped.complete(value),
        proc(message: string) =
          inc b.dispatchSequence
          wrapped.fail(newException(CatchableError, message)))
      wrapped
proc install*(b: NondetBackend) =
  currentClock = b
  if b == nil: installBackendHook(nil)
  else:
    installBackendHook(PlatformBackendHook(
      monotonicNowMs: proc(): int64 = backend().now().int64,
      schedule: proc(ms: int; cb: proc()): proc() =
        # currentClock remains the public selector, including scoped test clocks.
        # Cancellation must retain the clock that owns this particular timer.
        let selected = backend()
        let id = selected.schedule(cb, ms.float64)
        result = proc() = selected.cancel(id),
      fetch: proc(request: HttpRequest): PlatformFuture[HttpResponse] = fetch(request)))

when defined(js):
  proc rawRead(name, arg: cstring; el: JsObject): cstring {.importjs: "JSON.stringify((function(n,a,e){switch(n){case 'storageGet':return localStorage.getItem(a)||'';case 'cookieGet':return document.cookie;case 'location':return window.location.pathname;case 'measure':var r=e.getBoundingClientRect();return {x:r.x,y:r.y,width:r.width,height:r.height};case 'viewport':return {x:0,y:0,width:innerWidth,height:innerHeight};case 'matchMedia':return matchMedia(a).matches;case 'env':return {url:location.href,ua:navigator.userAgent,browserMajor:(navigator.userAgent.match(new RegExp('(?:Chrome|Firefox|Version|Edg)/([0-9]+)'))||[])[1]||'',language:navigator.language,timezoneOffset:new Date().getTimezoneOffset(),viewport:{width:innerWidth,height:innerHeight},dpr:devicePixelRatio,prefersDark:matchMedia('(prefers-color-scheme: dark)').matches,prefersReducedMotion:matchMedia('(prefers-reduced-motion: reduce)').matches,buildId:globalThis['_'+String.fromCharCode(36)+'HY']?.buildId||'',assignment:globalThis['_'+String.fromCharCode(36)+'HY']?.assignment||{},traceparent:document.querySelector('meta[name=traceparent]')?.content||''};}})(#,#,#))", tags: [RawNondet].}
  proc rawWrite(name, key, value: cstring) {.importjs: "(function(n,k,v){if(n==='storageSet')localStorage.setItem(k,v);else window.history[n](null,'',v);})(#,#,#)", tags: [RawNondet].}

proc readValue(name: string; arg = ""): JsonNode =
  let b = backend()
  if b.scripted: return b.read(name)
  when defined(js):
    return parseJson($rawRead(name.cstring, arg.cstring, nil))
  else:
    raise newException(ValueError, "browser boundary unavailable on native: " & name)

proc storageGet*(key: string): string {.tags: [StorageEffect].} =
  {.cast(tags: []).}:
    note("storageGet")
    readValue("storageGet", key).getStr()
proc storageSet*(key, value: string) {.tags: [StorageEffect].} =
  {.cast(tags: []).}:
    note("storageSet")
    let b = backend()
    if b.scripted: b.storage[key] = value
    else:
      when defined(js): rawWrite("storageSet", key.cstring, value.cstring)
      else: raise newException(ValueError, "browser storage unavailable on native")
proc cookieGet*(): string {.tags: [StorageEffect].} =
  {.cast(tags: []).}:
    note("cookieGet")
    readValue("cookieGet").getStr()
proc location*(): string {.tags: [DomEventEffect].} =
  {.cast(tags: []).}:
    note("location")
    readValue("location").getStr()
proc pushState*(url: string) {.tags: [DomEventEffect].} =
  {.cast(tags: []).}:
    note("pushState")
    let b = backend()
    if b.scripted: b.nativeLocation = url
    else:
      when defined(js): rawWrite("pushState", "", url.cstring)
      else: raise newException(ValueError, "browser history unavailable on native")
proc replaceState*(url: string) {.tags: [DomEventEffect].} =
  {.cast(tags: []).}:
    note("replaceState")
    let b = backend()
    if b.scripted: b.nativeLocation = url
    else:
      when defined(js): rawWrite("replaceState", "", url.cstring)
      else: raise newException(ValueError, "browser history unavailable on native")
proc asRect(value: JsonNode): Rect =
  Rect(x: value["x"].getFloat(), y: value["y"].getFloat(), width: value["width"].getFloat(), height: value["height"].getFloat())
proc viewport*(): Rect {.tags: [LayoutEffect].} =
  {.cast(tags: []).}:
    note("viewport")
    asRect(readValue("viewport"))
proc matchMedia*(query: string): bool {.tags: [LayoutEffect].} =
  {.cast(tags: []).}:
    note("matchMedia")
    readValue("matchMedia", query).getBool()
when defined(js):
  proc measure*(el: JsObject): Rect {.tags: [LayoutEffect].} =
    {.cast(tags: []).}:
      note("measure")
      let b = backend()
      if b.scripted: return asRect(b.read("measure"))
      asRect(parseJson($rawRead("measure", "", el)))
else:
  proc measure*(el: pointer): Rect {.tags: [LayoutEffect].} =
    {.cast(tags: []).}:
      note("measure")
      asRect(readValue("measure"))
proc env*(): JsonNode {.tags: [DomEventEffect].} =
  {.cast(tags: []).}:
    note("env")
    ## Snapshot once; callers cannot mutate the stored snapshot through aliases.
    let b = backend()
    if b.bootEnv == nil: b.bootEnv = readValue("env")
    b.bootEnv.copy()

when defined(js):
  proc rawBrowserFetch(httpMethod, url, body: cstring; csrf, context: cstring;
                contentType: cstring; signal: JsObject): Future[JsObject] {.tags: [RawNondet].} =
    ## Resolves with `{status, text}`; never rejects.  A network failure is
    ## status 0; an abort is status -1 wherever in the chain it lands: before
    ## the response headers (`fetch` rejects) or after them, while the body
    ## is read (`text()` rejects).  The final `catch` covers the whole chain,
    ## so an `AbortError` never reaches the caller as an exception.
    {.cast(tags: []).}:
     {.emit: """
    var headers = {"X-CSRF-Token": `csrf`, "X-Isonim-Context": `context`};
    if (`contentType` !== "") headers["Content-Type"] = `contentType`;
    var init = {method: `httpMethod`, headers: headers, credentials: "same-origin"};
    if (`body` !== null) init.body = `body`;
    if (`signal`) init.signal = `signal`;
    `result` = fetch(`url`, init)
      .then(function (r) {
        return r.text().then(function (t) { return {status: r.status, text: t}; });
      })
      .catch(function (e) {
        var aborted = (e && e.name === "AbortError") || (`signal` && `signal`.aborted);
        return {status: aborted ? -1 : 0, text: String(e)};
      });
     """.}

when defined(js):
  proc rpcResult(status: int; body: cstring): JsObject
      {.importjs: "({status:#,text:#})".}
  proc scriptedRpc(future: Future[HttpResponse]): Future[JsObject] {.async.} =
    let response = await future
    return rpcResult(response.status, response.body.cstring)
  proc browserFetch*(httpMethod, url, body: cstring; csrf, context: cstring;
      contentType: cstring; signal: JsObject): Future[JsObject] {.tags: [NetEffect].} =
    {.cast(tags: []).}:
      note("fetch")
      let b = backend()
      if b.scripted:
        if b.fetchResponse == nil: raise newException(ValueError, "missing scripted fetch")
        var req = HttpRequest(url: $url, body: $body)
        req.headers = @[
          HttpHeader(name: "X-CSRF-Token", value: $csrf),
          HttpHeader(name: "X-Isonim-Context", value: $context)]
        if contentType != "":
          req.headers.add(HttpHeader(name: "Content-Type", value: $contentType))
        for m in HttpMethod:
          if m.httpMethodName() == $httpMethod: req.httpMethod = m
        return settled(scriptedRpc(b.fetchResponse(req)), proc() = inc b.dispatchSequence)
      settled(rawBrowserFetch(httpMethod, url, body, csrf, context, contentType, signal),
        proc() = inc b.dispatchSequence)

when defined(js):
  proc hasBrowserWindow(): bool {.importjs: "(typeof window !== 'undefined')".}
  if hasBrowserWindow():
    # Install before application code reads a boundary, and freeze boot
    # environment before navigation or later viewport changes can alter it.
    discard backend()
    discard env()
