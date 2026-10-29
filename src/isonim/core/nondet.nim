## Platform boundaries. ClockBase owns timer ordering; scripted reads never
## silently fall back to browser globals or the network.
## Each tagged seam encapsulates platform effects and replaces them with its
## specific boundary tag; the casts do not expose RawNondet to callers.
import std/[times, monotimes, json, tables, random, options, strutils]
when not defined(js): import std/sysrand
when defined(js): import std/jsffi
when defined(js): import ./private/rpc_http
import ./clock
when defined(js) and defined(isonimInternalReplayReads):
  import ./private/replay_reads
else:
  template refuseReadReplay(clock, operation: untyped) = discard
import nim_everywhere/[backend, async_compat, platform]
import nim_everywhere/http as neHttp
import nim_everywhere/raw_nondet
export raw_nondet
export clock, async_compat

const directNondet = defined(js) and defined(isonimDirectNondet)
  ## `-d:isonimDirectNondet` (JS target only): the browser seams below call
  ## the browser directly, without the backend (its clock, scripted reads,
  ## dispatch sequence, seam coverage and read replay). For a production
  ## bundle that is never recorded, replayed or scripted and has a size
  ## budget: the clock and its tables are then not in the bundle. A test that
  ## scripts the backend builds without it.

when directNondet:
  when defined(isonimInternalReplayReads):
    {.error: "-d:isonimDirectNondet bypasses the backend; it cannot replay reads".}
  {.emit: """
var isonimDirect = {
  n: 0, c: new Map(), seq: 0,
  add: function (cancel) { var id = ++this.n; this.c.set(id, cancel); return id; },
  at: function (ms, cb) { var self = this, id = ++this.n;
    var t = setTimeout(function () { self.c.delete(id); cb(); }, ms);
    this.c.set(id, function () { clearTimeout(t); }); return id; },
  every: function (ms, cb) { var t = setInterval(cb, ms); return this.add(function () { clearInterval(t); }); },
  frame: function (cb) { var self = this, id = ++this.n;
    var t = requestAnimationFrame(function () { self.c.delete(id); cb(); });
    this.c.set(id, function () { cancelAnimationFrame(t); }); return id; },
  cancel: function (id) { var f = this.c.get(id); if (f) { this.c.delete(id); f(); } }
};
""".}
  proc directAt(ms: float64; cb: proc()): int {.importjs: "isonimDirect.at(#, #)".}
  proc directEvery(ms: float64; cb: proc()): int {.importjs: "isonimDirect.every(#, #)".}
  proc directFrame(cb: proc()): int {.importjs: "isonimDirect.frame(#)".}
  proc directCancel(id: int) {.importjs: "isonimDirect.cancel(#)".}
  proc directNow(): float64 {.importjs: "performance.now(@)".}
  proc directPath(): cstring =
    {.emit: [result, " = window.location.pathname;"].}
  proc directHistory(op, url: cstring) {.importjs: "window.history[#](null, '', #)".}

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
  "matchMedia", "location", "pushState", "replaceState", "env", "randomUuid"]

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
  elif currentBackendHook == nil: install(currentClock)
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
  when directNondet:
    var epoch: MonoTime
    return epoch + initDuration(nanoseconds = int64(directNow() * 1_000_000))
  else:
    {.cast(tags: []).}:
      note("now")
      block:
        var epoch: MonoTime
        epoch + initDuration(nanoseconds = int64(backend().now() * 1_000_000))
proc nowMs*(): float64 {.tags: [ClockEffect].} =
  ## `now()` in milliseconds as a float, without the `MonoTime`/`Duration`
  ## arithmetic (a size-budgeted bundle's clock reads; the same seam).
  when directNondet:
    return directNow()
  else:
    {.cast(tags: []).}:
      note("now")
      return backend().now()
proc wallNow*(): Time {.tags: [ClockEffect].} =
  {.cast(tags: []).}:
    note("wallNow")
    let b = backend()
    when defined(js) and defined(isonimInternalReplayReads):
      if b.isReadReplay: return readReplayWall(b)
    if b.scripted: return fromUnixFloat(b.read("wallNow").getFloat())
    getTime()
proc scheduleAt*(afterMs: float64; cb: proc()): int {.tags: [ClockEffect].} =
  ## Schedule after a delay, matching nim-everywhere's time facade.
  ## Effects of deferred callbacks belong to their later dispatch slot.
  when directNondet:
    return directAt(afterMs, cb)
  else:
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
  when directNondet:
    directCancel(id)
    return
  else:
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
  when directNondet:
    if intervalMs <= 0: raise newException(ValueError, "interval must be positive")
    return directEvery(intervalMs, cb)
  else:
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
  proc rawFrame(cb: proc(ts: float64)): int {.importjs: "requestAnimationFrame(#)", tags: [RawNondet].}
  proc rawCancelFrame(id: int) {.importjs: "cancelAnimationFrame(#)", tags: [RawNondet].}
type FrameObservation = tuple[browserTimestamp: Option[float64]]

proc requestFrameObservation(cb: proc(observation: FrameObservation)): int =
  # Preserve the platform argument before the public no-argument facade erases
  # it. A timer fallback has no browser timestamp; do not sample another clock.
  let b = backend()
  when defined(js):
    when defined(isonimInternalReplayReads):
      if b.isReadReplay:
        return readReplayFrame(b, proc(ts: float64) =
          cb((browserTimestamp: some(ts))))
    if not b.scripted:
      inc b.nextHandle
      let id = b.nextHandle
      let nativeId = rawFrame(proc(ts: float64) =
        b.frameCancels.del(id)
        when defined(isonimRecordable): beginDispatch(b)
        else: inc b.dispatchSequence
        cb((browserTimestamp: some(ts))))
      b.frameCancels[id] = proc() = rawCancelFrame(nativeId)
      return id
  scheduleAt(16, proc() = cb((browserTimestamp: none(float64))))

proc requestFrame*(cb: proc()): int {.tags: [ClockEffect].} =
  when directNondet:
    return directFrame(cb)
  else:
    {.cast(tags: []).}:
      note("requestFrame")
      requestFrameObservation(proc(observation: FrameObservation) = cb())
proc random*(): uint64 {.tags: [RandomEffect].} =
  {.cast(tags: []).}:
    refuseReadReplay(currentClock, "random")
    note("random")
    let b = backend()
    when defined(isonimRecordable):
      result = if b.scripted: uint64(b.read("random").getBiggestInt())
        else: b.randomState.next()
      inc b.randomDrawCount
    else:
      if b.scripted: return uint64(b.read("random").getBiggestInt())
      b.randomState.next()
proc randomFloat*(): float64 {.tags: [RandomEffect].} =
  {.cast(tags: []).}:
    refuseReadReplay(currentClock, "randomFloat")
    note("randomFloat")
    let b = backend()
    when defined(isonimRecordable):
      result = if b.scripted: b.read("randomFloat").getFloat()
        else: b.randomState.rand(1.0)
      inc b.randomDrawCount
    else:
      if b.scripted: return b.read("randomFloat").getFloat()
      b.randomState.rand(1.0)
when defined(js):
  proc rawRandomUuid(): cstring {.importjs: "crypto.randomUUID()", tags: [RawNondet].}
proc randomUuid*(): string {.tags: [RandomEffect].} =
  ## A version 4 UUID from the platform's CSPRNG (RFC 9562 §5.4): the
  ## browser's `crypto.randomUUID()`, the OS's on native. Unlike `random`,
  ## it is not drawn from the page's seeded generator, whose 32-bit seed
  ## makes it unfit for identifiers that must not collide across clients
  ## (an idempotency key, rpc_client.nim). Scripted backends read it; a read
  ## replay refuses it, as it refuses `random`.
  when directNondet:
    {.cast(tags: []).}:
      return $rawRandomUuid()
  else:
    {.cast(tags: []).}:
      refuseReadReplay(currentClock, "randomUuid")
      note("randomUuid")
      let b = backend()
      if b.scripted: return b.read("randomUuid").getStr()
      when defined(js):
        result = $rawRandomUuid()
      else:
        var bytes: array[16, byte]
        if not urandom(bytes): raise newException(IOError, "cannot draw a UUID")
        bytes[6] = (bytes[6] and 0x0f) or 0x40
        bytes[8] = (bytes[8] and 0x3f) or 0x80
        const hexDigits = "0123456789abcdef"
        for i, v in bytes:
          if i in [4, 6, 8, 10]: result.add '-'
          result.add hexDigits[int(v shr 4)]
          result.add hexDigits[int(v and 0x0f)]
when defined(js):
  proc settled[T](future: Future[T]; cb: proc()): Future[T]
      {.importjs: "(function(f,cb){return f.then(function(v){cb();return v;},function(e){cb();throw e;});})(#,#)".}
proc fetch*(request: HttpRequest): PlatformFuture[HttpResponse] {.tags: [NetEffect].} =
  {.cast(tags: []).}:
    refuseReadReplay(currentClock, "fetch")
    note("fetch")
    let b = backend()
    if b.scripted and b.fetchResponse == nil:
      raise newException(ValueError, "missing scripted fetch")
    let pending = if b.fetchResponse != nil: b.fetchResponse(request)
      else: neHttp.fetchHttpRaw(rawBackendAccess, request)
    when defined(js):
      return settled(pending, proc() =
        when defined(isonimRecordable): beginDispatch(b)
        else: inc b.dispatchSequence)
    else:
      let wrapped = newFuture[HttpResponse]("nondet fetch settlement")
      pending.onComplete(
        proc(value: HttpResponse) =
          when defined(isonimRecordable): beginDispatch(b)
          else: inc b.dispatchSequence
          wrapped.complete(value),
        proc(message: string) =
          when defined(isonimRecordable): beginDispatch(b)
          else: inc b.dispatchSequence
          wrapped.fail(newException(CatchableError, message)))
      wrapped
proc installBridge() =
  # The same dynamic forwarding bridge serves eager browser bootstrap and
  # lazy native/windowless imports. Creating it never selects a default clock.
  installBackendHook(PlatformBackendHook(
    monotonicNowMs: proc(): int64 = backend().now().int64,
    schedule: proc(ms: int; cb: proc()): proc() =
      # currentClock remains the public selector, including scoped test clocks.
      # Cancellation must retain the clock that owns this particular timer.
      let selected = backend()
      let id = selected.schedule(cb, ms.float64)
      result = proc() = selected.cancel(id),
    fetch: proc(request: HttpRequest): PlatformFuture[HttpResponse] = fetch(request)))

proc install*(b: NondetBackend) =
  currentClock = b
  if b == nil: installBackendHook(nil)
  else: installBridge()

when defined(js):
  # The boot snapshot (`env`) runs at module initialisation whenever a
  # `window` exists, so it reads only through that object and defaults every
  # absent member: partial hosts (Node fixtures, worker shims) define a
  # `window` without the bare browser globals. The IANA zone is observed once
  # with each raw snapshot; an offset cannot identify it, and missing Intl
  # is explicitly unavailable (empty string), never guessed from another host.
  # Build all legacy fields in their original observation order first. Only
  # then append CT's three-way preference and origin-only referrer metadata;
  # newly unavailable/throwing metadata must not break a successful snapshot.
  # Retain the same Date instance at the original offset observation point;
  # later epoch metadata never samples another clock or changes old failures.
  proc rawRead(name, arg: cstring; el: JsObject): cstring {.importjs: "JSON.stringify((function(n,a,e){switch(n){case 'storageGet':return localStorage.getItem(a);case 'cookieGet':return document.cookie;case 'location':return window.location.pathname;case 'measure':var r=e.getBoundingClientRect();return {x:r.x,y:r.y,width:r.width,height:r.height,top:r.top,right:r.right,bottom:r.bottom,left:r.left};case 'viewport':return {x:0,y:0,width:innerWidth,height:innerHeight};case 'matchMedia':return matchMedia(a).matches;case 'env':var w=window,l=w.location||{},v=w.navigator||{},d=w.document,u=String(v.userAgent||''),hy=globalThis['_'+String.fromCharCode(36)+'HY'],q=function(m){return typeof w.matchMedia==='function'&&w.matchMedia(m)?.matches===true;},t=d&&typeof d.querySelector==='function'?d.querySelector('meta[name=traceparent]'):null,z='',i=w.Intl;if(i&&typeof i.DateTimeFormat==='function'){var f=i.DateTimeFormat();if(f&&typeof f.resolvedOptions==='function'){var o=f.resolvedOptions();if(o&&typeof o.timeZone==='string')z=o.timeZone;}}var bootDate;var snapshot={url:String(l.href||''),ua:u,browserMajor:(u.match(new RegExp('(?:Chrome|Firefox|Version|Edg)/([0-9]+)'))||[])[1]||'',language:String(v.language||''),timezoneOffset:(bootDate=new Date()).getTimezoneOffset(),timeZone:z,viewport:{width:Number(w.innerWidth)||0,height:Number(w.innerHeight)||0},dpr:Number(w.devicePixelRatio)||1,prefersDark:q('(prefers-color-scheme: dark)'),prefersReducedMotion:q('(prefers-reduced-motion: reduce)'),buildId:hy?.buildId||'',assignment:hy?.assignment||{},traceparent:String(t?.content||'')};var dark=snapshot.prefersDark,color=dark?2:0,ref='';if(!dark){try{if(q('(prefers-color-scheme: light)'))color=1;}catch(e){}}try{var r=d&&d.referrer;if(typeof r==='string'&&r){var U=w.URL;if(typeof U==='function'){var origin=new U(r).origin;if(typeof origin==='string')ref=origin;}}}catch(e){}snapshot.colorScheme=color;snapshot.referrerOrigin=ref;var epoch=null;try{var getTime=bootDate&&bootDate.getTime;if(typeof getTime==='function'){var value=getTime.call(bootDate);if(typeof value==='number'&&Number.isFinite(value))epoch=value;}}catch(e){}snapshot.bootDateEpochMs=epoch;return snapshot;}})(#,#,#))", tags: [RawNondet].}
  proc rawStorageWrite(key, value: cstring) {.importjs: "localStorage.setItem(#,#)", tags: [RawNondet].}
  # Catch metadata failures only: an unsuccessful mutation keeps its original
  # exception and must not query location. Partial hosts can mutate history
  # without supplying usable URL metadata; absence is not a guessed URL.
  proc rawHistory(name, url: cstring): cstring {.importjs: "(function(n,u){window.history[n](null,'',u);try{var l=window.location,h=l&&l.href;return typeof h==='string'?h:null;}catch(e){return null;}})(#,#)", tags: [RawNondet].}

proc readValue(name: string; arg = ""): JsonNode =
  let b = backend()
  when defined(js) and defined(isonimInternalReplayReads):
    if b.isReadReplay:
      case name
      of "storageGet": return readReplayStorage(b, 1, arg)
      of "cookieGet": return readReplayStorage(b, 3, "")
      of "location": return %readReplayLocation(b)
      of "viewport": return readReplayViewport(b)
      of "matchMedia": return readReplayMedia(b, arg)
      else: refuseReadReplay(b, name)
  if b.scripted: return b.read(name)
  when defined(js):
    return parseJson($rawRead(name.cstring, arg.cstring, nil))
  else:
    raise newException(ValueError, "browser boundary unavailable on native: " & name)

type StorageObservation = tuple[present: bool, value: string]

proc storageObservation(key: string): StorageObservation =
  # One original read supplies both fields before the public facade erases null.
  let observed = readValue("storageGet", key)
  (present: not observed.isNil and observed.kind != JNull, value: observed.getStr())

proc storageGet*(key: string): string {.tags: [StorageEffect].} =
  {.cast(tags: []).}:
    note("storageGet")
    storageObservation(key).value
proc storageSet*(key, value: string) {.tags: [StorageEffect].} =
  {.cast(tags: []).}:
    when defined(js) and defined(isonimInternalReplayReads):
      requireReadReplayStorageOutput(currentClock)
    note("storageSet")
    let b = backend()
    if b.scripted: b.storage[key] = value
    else:
      when defined(js): rawStorageWrite(key.cstring, value.cstring)
      else: raise newException(ValueError, "browser storage unavailable on native")
proc cookieGet*(): string {.tags: [StorageEffect].} =
  {.cast(tags: []).}:
    note("cookieGet")
    readValue("cookieGet").getStr()
proc location*(): string {.tags: [DomEventEffect].} =
  when directNondet:
    {.cast(tags: []).}:
      return $directPath()
  else:
    {.cast(tags: []).}:
      note("location")
      readValue("location").getStr()
type HistoryObservation = tuple[browserUrl: Option[string]]

proc historyObservation(name, url: string): HistoryObservation =
  let b = backend()
  if b.scripted:
    b.nativeLocation = url
    return (browserUrl: none(string))
  when defined(js):
    let observed = rawHistory(name.cstring, url.cstring)
    (browserUrl: if observed.isNil: none(string) else: some($observed))
  else:
    raise newException(ValueError, "browser history unavailable on native")

proc pushState*(url: string) {.tags: [DomEventEffect].} =
  when directNondet:
    directHistory("pushState", cstring(url))
    return
  else:
    {.cast(tags: []).}:
      note("pushState")
      when defined(js) and defined(isonimInternalReplayReads):
        if currentClock.isReadReplay:
          let selected = currentClock
          let owner = prepareReadReplayNavigation(selected)
          let observed = historyObservation("pushState", url)
          completeReadReplayNavigation(selected, owner, 1, observed.browserUrl)
          return
      discard historyObservation("pushState", url)
proc replaceState*(url: string) {.tags: [DomEventEffect].} =
  when directNondet:
    directHistory("replaceState", cstring(url))
    return
  else:
    {.cast(tags: []).}:
      note("replaceState")
      when defined(js) and defined(isonimInternalReplayReads):
        if currentClock.isReadReplay:
          let selected = currentClock
          let owner = prepareReadReplayNavigation(selected)
          let observed = historyObservation("replaceState", url)
          completeReadReplayNavigation(selected, owner, 2, observed.browserUrl)
          return
      discard historyObservation("replaceState", url)
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
      when defined(isonimInternalReplayReads):
        if currentClock.isReadReplay:
          note("measure")
          return asRect(readReplayMeasure(currentClock, el))
      note("measure")
      let b = backend()
      if b.scripted: return asRect(b.read("measure"))
      asRect(parseJson($rawRead("measure", "", el)))
else:
  proc measure*(el: pointer): Rect {.tags: [LayoutEffect].} =
    {.cast(tags: []).}:
      refuseReadReplay(currentClock, "measure")
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
                contentType: cstring; signal: JsObject;
                extra: JsObject = nil): Future[JsObject] {.tags: [RawNondet].} =
    ## Resolves with `{status, text, retryAfter, commit}` (rpc_http.nim);
    ## never rejects.  A network failure is
    ## status 0; an abort is status -1 wherever in the chain it lands: before
    ## the response headers (`fetch` rejects) or after them, while the body
    ## is read (`text()` rejects).  The final `catch` covers the whole chain,
    ## so an `AbortError` never reaches the caller as an exception.
    let init = buildRpcRequestInitRaw(rawBackendAccess, httpMethod, body, csrf,
      context, contentType, signal, extra)
    let pending = neHttp.fetchBrowserResponseRaw(rawBackendAccess, url, init)
    projectRpcResponseRaw(rawBackendAccess, pending, signal)

when defined(js):
  proc rpcResult(status: int; body, retryAfter, commit: cstring): JsObject
      {.importjs: "({status:#,text:#,retryAfter:#,commit:#})".}
  proc scriptedRpc(future: Future[HttpResponse]): Future[JsObject] {.async.} =
    # The scripted answer carries the same projection as the native one
    # (rpc_http.nim): `Retry-After` and `Isonim-Commit`, "" when absent.
    let response = await future
    var retryAfter, commit = ""
    for h in response.headers:
      if h.name.toLowerAscii == "retry-after": retryAfter = h.value
      elif h.name.toLowerAscii == "isonim-commit": commit = h.value
    return rpcResult(response.status, response.body.cstring, retryAfter.cstring, commit.cstring)
  proc extraHeaderPairs(extra: JsObject): seq[(string, string)] =
    if extra.isNil: return
    var keys: seq[cstring]
    {.emit: [keys, " = Object.keys(", extra, ");"].}
    for k in keys:
      var v: cstring
      {.emit: [v, " = String(", extra, "[", k, "]);"].}
      result.add(($k, $v))
  proc browserFetch*(httpMethod, url, body: cstring; csrf, context: cstring;
      contentType: cstring; signal: JsObject;
      extra: JsObject = nil): Future[JsObject] {.tags: [NetEffect].} =
    ## `{status, text, retryAfter, commit}` of one request (rawBrowserFetch);
    ## `extra` adds request headers (an object of names to values, or nil).
    when directNondet:
      {.cast(tags: []).}:
        return rawBrowserFetch(httpMethod, url, body, csrf, context, contentType, signal, extra)
    else:
      {.cast(tags: []).}:
        refuseReadReplay(currentClock, "browserFetch")
        note("fetch")
        let b = backend()
        if b.scripted:
          if b.fetchResponse == nil: raise newException(ValueError, "missing scripted fetch")
          # Public no-body RPC calls pass nil; the buffered scripted request
          # represents absence with an empty Nim string, not a nil cstring read.
          var req = HttpRequest(url: $url, body: (if body == nil: "" else: $body))
          req.headers = @[
            HttpHeader(name: "X-CSRF-Token", value: $csrf),
            HttpHeader(name: "Isonim-Context", value: $context)]
          if contentType != "":
            req.headers.add(HttpHeader(name: "Content-Type", value: $contentType))
          for (k, v) in extraHeaderPairs(extra):
            req.headers.add(HttpHeader(name: k, value: v))
          for m in HttpMethod:
            if m.httpMethodName() == $httpMethod: req.httpMethod = m
          return settled(scriptedRpc(b.fetchResponse(req)), proc() =
            when defined(isonimRecordable): beginDispatch(b)
            else: inc b.dispatchSequence)
        settled(rawBrowserFetch(httpMethod, url, body, csrf, context, contentType, signal, extra),
          proc() =
            when defined(isonimRecordable): beginDispatch(b)
            else: inc b.dispatchSequence)

when defined(js):
  proc hasBrowserWindow(): bool {.importjs: "(typeof window !== 'undefined')".}
  if hasBrowserWindow():
    # Install before application code reads a boundary, and freeze boot
    # environment before navigation or later viewport changes can alter it.
    # `-d:isonimNoBootEnv` skips the snapshot (a production bundle that
    # neither records nor replays sessions: the snapshot is the recorder's
    # input, and parsing and copying it costs a size-budgeted bundle the
    # JSON tree's code).
    when not directNondet:
      discard backend()
    when not defined(isonimNoBootEnv) and not directNondet:
      discard env()

# A clock-only bootstrap can select currentClock before importing this module,
# and native/windowless callers may select one later. Keep a lazy bridge ready
# without replacing an explicit hook or eagerly allocating/seeding RealClock.
# `-d:isonimDirectNondet` leaves the hook unset, as it leaves the backend
# unselected: its seams never consult the backend, and nim-everywhere's own
# platform defaults then serve any caller of the hook directly.
when not directNondet:
  if currentBackendHook == nil: installBridge()

when defined(js):
  # The listener boundary is typed over the renderer's event object, so core
  # never imports a renderer: the DOM backend instantiates it with its `Event`.
  import ./owner

  # Weak target ownership permits detached trees and their handlers to die.
  # Records contain scalar copies only; the hook never receives a DOM object.
  {.emit: """
  var isonimEventListeners = (function() {
  const isonimListeners = new WeakMap();
  let isonimListenerHook = null;
  function isonimEventSnapshot(ev) {
    const el = ev.target;
    const p = {};
    if ((ev.type === 'input' || ev.type === 'change') && el) {
      const editable = el.localName === 'input' || el.localName === 'textarea' || el.isContentEditable;
      if (editable) {
        const value = String(el.isContentEditable ? el.textContent : el.value);
        p.value = el.getAttribute('data-isonim-record') === 'true' ? value : '*'.repeat(value.length);
      }
      if (typeof el.checked === 'boolean') p.checked = el.checked;
    }
    const original = ev.isonimReplayOf || ev;
    const saved = ev.isonimSnapshot || original;
    for (const key of ['key', 'code', 'ctrlKey', 'shiftKey', 'altKey', 'metaKey', 'clientX', 'clientY', 'button']) {
      const value = saved[key];
      if (typeof value === 'string' || typeof value === 'number' || typeof value === 'boolean') p[key] = value;
    }
    return p;
  }
  function isonimListen(node, type, handler, capture, nextSequence, eventTime, registered) {
    let entries = isonimListeners.get(node);
    if (!entries) isonimListeners.set(node, entries = []);
    const prior = entries.find(e => e.type === type && e.handler === handler && e.capture === capture);
    if (prior) return prior.dispose;
    const entry = {type, handler, capture, targetIid: node === window ? 'win' : node === document ? 'doc' : node.getAttribute('data-iid') || ''};
    entry.wrapped = function(ev) {
      const seq = nextSequence();
      const hook = isonimListenerHook;
      let record;
      if (hook) {
        record = {seq, type, targetIid: entry.targetIid, timeStamp: ev.isonimReplayOf ? ev.isonimReplayOf.timeStamp : eventTime(),
          payload: isonimEventSnapshot(ev), finalized: false};
        if (ev.isonimReplayOf) record.phase = 'prehydration';
        try { hook(record); } catch (error) { console.error('isonim listener hook:', error); }
      }
      try { return handler.call(this, ev); }
      finally { if (record) { record.payload.defaultPrevented = ev.defaultPrevented; record.finalized = true; } }
    };
    let active = true;
    entry.dispose = function() {
      if (!active) return;
      active = false;
      node.removeEventListener(type, entry.wrapped, capture);
      const at = entries.indexOf(entry);
      if (at >= 0) entries.splice(at, 1);
      if (!entries.length) isonimListeners.delete(node);
    };
    entries.push(entry);
    node.addEventListener(type, entry.wrapped, capture);
    registered(entry.dispose);
    return entry.dispose;
  }
  return {listen: isonimListen, setHook: function(hook) { isonimListenerHook = hook; }};
  })();
  """.}
  proc setListenerHook*(hook: proc(record: JsObject)) =
    ## Observe handler entry. Retain records until `finalized` before serializing.
    ## Passing nil disables observation without changing callback semantics.
    refuseReadReplay(currentClock, "setListenerHook")
    {.emit: ["isonimEventListeners.setHook(", hook, ");"].}
  type ListenerDisposer* = proc()
  proc rawListen(node: JsObject; event: cstring; handler: JsObject;
      capture: bool; nextSequence: proc(): int; eventTime: proc(): float64;
      registered: proc(dispose: ListenerDisposer)): ListenerDisposer
      {.importjs: "isonimEventListeners.listen(#,#,#,#,#,#,#)", tags: [RawNondet].}
  proc listen*[E](node: JsObject; event: string; handler: proc(ev: E) {.closure.};
      capture = false): ListenerDisposer {.discardable, tags: [DomEventEffect].} =
    ## Register at the original DOM target; returns idempotent removal.
    ## Native target/currentTarget, propagation and capture semantics survive.
    ## A duplicate shares cancellation but keeps its first reactive owner.
    ## `E` is the event type the handler receives (the web renderer's `Event`);
    ## the handler itself is passed through unchanged, so its identity is the
    ## deduplication key.
    when directNondet:
      {.cast(tags: []).}:
        var sequence = 0
        return rawListen(node, event.cstring, toJs(handler), capture, proc(): int =
          inc sequence
          sequence, proc(): float64 = directNow(),
          proc(dispose: ListenerDisposer) =
            if getOwner() != nil: onCleanup(dispose))
    else:
      {.cast(tags: []).}:
        refuseReadReplay(currentClock, "listen")
        result = rawListen(node, event.cstring, toJs(handler), capture, proc(): int =
          # A retained native registration can outlive a backend selection.
          refuseReadReplay(currentClock, "listen")
          let selected = backend()
          when defined(isonimRecordable): beginDispatch(selected)
          else: inc selected.dispatchSequence
          int(selected.dispatchSequence), proc(): float64 = backend().now(),
          proc(dispose: ListenerDisposer) =
            if getOwner() != nil: onCleanup(dispose))
