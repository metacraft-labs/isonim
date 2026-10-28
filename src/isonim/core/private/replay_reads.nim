## Internal, incomplete Replay preparation. Deliberate private imports only.
## Context is supplied by the trusted caller, NOT reconstructed from the log.
## No owner module, global or platform patch is installed by importing this file.
## The internal define is preparation-only. Normal/dormant builds omit even
## private RTTI/state and the guard calls; no runtime feature switch is added.
when defined(js) and defined(isonimInternalReplayReads):
  import std/[json, times, math, tables, options]
  import ../clock
  import std/jsffi

  type ReadReplayClock = ref object of ClockBase
    cursor: JsObject
    nextTimerId: int
    timerTasks: Table[int, JsObject]
    frameTasks: Table[int, JsObject]
    activeCallbacks: int
    disposed: bool

  # Weak keys preserve one framework namespace per actual cursor without
  # retaining completed sessions. Timers and frames share this one namespace;
  # allocate only at the first private task, never from the log's next record.
  var timerNamespaces: JsObject
  proc newTimerNamespaces(): JsObject {.importjs: "new WeakMap()".}
  proc nextTimerTask(namespaces, cursor: JsObject): JsObject {.importjs: "(function(m,r){var n=m.get(r);if(n===undefined)n=1n;m.set(r,n+1n);return n;})(#,#)".}
  proc registerTimer(cursor, task: JsObject; delay: int) {.importjs: "#.registerTask(#,1,#)".}
  proc registerFrame(cursor, task: JsObject) {.importjs: "#.registerTask(#,3,0)".}
  proc onTimer(cursor, task: JsObject; callback: proc()) {.importjs: "#.onTask(#,#)".}
  proc offTimer(cursor, task: JsObject) {.importjs: "#.offTask(#)".}
  proc timerSessionFinished(cursor: JsObject): bool {.importjs: "(function(r){var s=r.status().state;return s==='done'||s==='diverged';})(#)".}

  proc isReadReplay*(clock: ClockBase): bool = clock != nil and clock of ReadReplayClock

  proc refuseReadReplay*(clock: ClockBase; operation: string) =
    ## A negative type check leaves every existing Real/Test/custom clock alone.
    if clock.isReadReplay:
      raise newException(ValueError, "internal read Replay does not support " & operation)

  proc actualCursor(): JsObject {.importjs: "(function(){var r=globalThis.__ctReplay;if(!r||r.protocol!==1||typeof r.next!=='function')throw new Error('internal read Replay requires actual __ctReplay protocol 1');for(var k of ['registerTask','onTask','offTask','status'])if(typeof r[k]!=='function')throw new Error('internal read Replay requires owner '+k);return r;})()".}
  proc captureQueueLive(): bool {.importjs: "(globalThis['_'+String.fromCharCode(36)+'HY']!=null&&globalThis['_'+String.fromCharCode(36)+'HY'].events!=null)".}
  proc guardCollision(): bool {.importjs: "Object.getOwnPropertyDescriptor(globalThis,'__isonimInternalReadReplaySelected')!==undefined".}
  var guardInstalled = false
  proc installSelectionGuard(selected: proc(): bool) {.importjs: "Object.defineProperty(globalThis,'__isonimInternalReadReplaySelected',{value:Object.freeze({internalReadReplay:true,selected:#})})".}
  proc clockRead[T: SomeNumber](cursor: JsObject; source: int): T {.importjs: "(function(r,s){var c=r.next('Clock',{src:s}),d=new DataView(new ArrayBuffer(8));d.setBigUint64(0,c.bits,true);return d.getFloat64(0,true);})(#,#)".}
  proc storageRead(cursor: JsObject; area: int; key: cstring): cstring {.importjs: "(function(r,a,k){var s=r.next('StorageRead',{area:a,key:k});return JSON.stringify(s.present===0?null:s.value);})(#,#,#)".}

  # Navigation shares a cursor's checked URL across clock instances. Keep the
  # real unholed URL; the owner's hole token belongs only to checked arguments.
  var navigationStates: JsObject
  proc requireNavigationLevel(cursor: JsObject) {.importjs: "(function(r){if(r.level!==0)throw new Error('internal navigation Replay requires actual owner level 0');})(#)".}
  proc navigationState(states, cursor: JsObject; bootUrl: cstring): JsObject {.importjs: "(function(m,r,u){var s=m.get(r);if(s){if(s.initial!==u)throw new Error('internal navigation Replay boot URL disagreement');if(!s.valid)throw new Error('internal navigation Replay URL state unavailable');return s;}var parsed=new URL(u);s={initial:u,current:parsed.href,pathname:parsed.pathname,valid:true};m.set(r,s);return s;})(#,#,#)".}
  proc loadNavigationOwner(): JsObject {.importjs: "(function(){var o;try{o=require('\\x40codetracer/runtime-browser/dist/sensitive.js');}catch(e){throw new Error('internal navigation Replay requires bundled owner URL helpers');}for(var k of ['sensitiveState','currentSensitiveValues','holeText'])if(typeof o[k]!=='function')throw new Error('internal navigation Replay requires owner '+k);return o;})()".}
  proc checkedNavigation(cursor, owner, state: JsObject; kind: int; url: cstring) {.importjs: "(function(r,o,s,k,u){var parsed;try{parsed=new URL(u);}catch(e){s.valid=false;throw new Error('internal navigation Replay reflected URL unavailable');}try{var sensitive=o.sensitiveState(window);r.next('Navigation',{kind:k,url:o.holeText(u,o.currentSensitiveValues(window,sensitive))});s.current=u;s.pathname=parsed.pathname;}catch(e){if(!r.failed)s.valid=false;throw e;}})(#,#,#,#,#)".}
  proc invalidateNavigation(state: JsObject) {.importjs: "#.valid=false".}
  proc navigationPath(cursor, state: JsObject): cstring {.importjs: "(function(r,s){if(r.failed)r.next('Navigation');return s.pathname;})(#,#)".}

  proc readReplayNavigationState(clock: ClockBase): JsObject =
    let selected = ReadReplayClock(clock)
    requireNavigationLevel(selected.cursor)
    if not selected.bootEnv.hasKey("url") or selected.bootEnv["url"].kind != JString:
      raise newException(ValueError, "internal navigation Replay requires genuine boot URL")
    if navigationStates.isNil: navigationStates = newTimerNamespaces()
    navigationState(navigationStates, selected.cursor, selected.bootEnv["url"].getStr().cstring)

  proc forwardNavigationFailure(cursor: JsObject) {.importjs: "(function(r){if(r.failed)r.next('Navigation');})(#)".}
  proc readReplayLocation*(clock: ClockBase): string =
    let selected = ReadReplayClock(clock)
    requireNavigationLevel(selected.cursor)
    # A later owner latch takes precedence even after a private URL failure.
    forwardNavigationFailure(selected.cursor)
    let state = readReplayNavigationState(clock)
    $navigationPath(selected.cursor, state)

  proc prepareReadReplayNavigation*(clock: ClockBase): JsObject =
    ## Validate all linkage before allowing a native mutation. Merely importing
    ## this module never evaluates owner code or creates its sensitive state.
    discard readReplayNavigationState(clock)
    loadNavigationOwner()

  proc completeReadReplayNavigation*(clock: ClockBase; owner: JsObject;
      kind: int; url: Option[string]) =
    let state = readReplayNavigationState(clock)
    if url.isNone:
      invalidateNavigation(state)
      raise newException(ValueError, "internal navigation Replay reflected URL unavailable")
    checkedNavigation(ReadReplayClock(clock).cursor, owner, state, kind, url.get().cstring)

  proc newInternalReadReplay*(bootContext: JsonNode): ClockBase =
    ## Internal constructor only. No archive availability or RNG mapping claim.
    ## Reject live capture before publishing a guard or selecting any clock.
    if bootContext == nil or bootContext.kind != JObject:
      raise newException(ValueError, "internal read Replay requires genuine boot context")
    let cursor = actualCursor()
    if captureQueueLive():
      raise newException(ValueError, "internal read Replay cannot adopt live prehydration capture")
    if not guardInstalled and guardCollision():
      raise newException(ValueError, "internal read Replay guard name collision")
    result = ReadReplayClock(cursor: cursor, bootEnv: bootContext.copy())
    # The emitted SSR script cannot import Nim. This private query exists only
    # after deliberate construction and tracks selection, including switch-away.
    if not guardInstalled:
      installSelectionGuard(proc(): bool = currentClock.isReadReplay)
      guardInstalled = true

  method now(clock: ReadReplayClock): float64 = clockRead[float64](clock.cursor, 2)

  proc readReplayWall*(clock: ClockBase): Time =
    ## Match the stock Date-millisecond integer type and public unit conversion.
    ## In particular, retain its genuine range failures; this does not normalize
    ## negative remainders or widen the library's accepted seconds domain.
    let millis = clockRead[int](ReadReplayClock(clock).cursor, 3)
    initTime(convert(Milliseconds, Seconds, millis),
      convert(Milliseconds, Nanoseconds,
        millis mod convert(Seconds, Milliseconds, 1).int))
  method schedule(clock: ReadReplayClock; callback: proc(); delayMs: float64): int =
    if clock.disposed:
      raise newException(ValueError, "internal read Replay timer clock is disposed")
    inc clock.nextTimerId
    let id = clock.nextTimerId
    # Preserve RealClock conversion and its error-before-registration order.
    let delay = max(0, ceil(delayMs).int)
    if timerNamespaces.isNil: timerNamespaces = newTimerNamespaces()
    let task = nextTimerTask(timerNamespaces, clock.cursor)
    registerTimer(clock.cursor, task, delay)
    clock.timerTasks[id] = task
    onTimer(clock.cursor, task, proc() =
      # A timeout is no longer live even when its callback throws or rearms.
      offTimer(clock.cursor, task)
      clock.timerTasks.del(id)
      inc clock.activeCallbacks
      try:
        when defined(isonimRecordable): beginDispatch(clock)
        else: inc clock.dispatchSequence
        callback()
      finally:
        dec clock.activeCallbacks)
    id
  method cancel(clock: ReadReplayClock; id: int) =
    if id in clock.timerTasks:
      offTimer(clock.cursor, clock.timerTasks[id])
      clock.timerTasks.del(id)

  proc readReplayFrame*(clock: ClockBase; callback: proc(ts: float64)): int =
    ## Fixed private frame bridge. The public facade still erases timestamps;
    ## the original logged delivery is retained for its private observation.
    let selected = ReadReplayClock(clock)
    if selected.disposed:
      raise newException(ValueError, "internal read Replay frame clock is disposed")
    inc selected.nextHandle
    let id = selected.nextHandle
    if timerNamespaces.isNil: timerNamespaces = newTimerNamespaces()
    let task = nextTimerTask(timerNamespaces, selected.cursor)
    registerFrame(selected.cursor, task)
    selected.frameTasks[id] = task
    selected.frameCancels[id] = proc() =
      offTimer(selected.cursor, task)
      selected.frameTasks.del(id)
    onTimer(selected.cursor, task, proc() =
      # One-shot ownership ends before decoding or calling application code.
      offTimer(selected.cursor, task)
      selected.frameTasks.del(id)
      selected.frameCancels.del(id)
      inc selected.activeCallbacks
      try:
        let timestamp = clockRead[float64](selected.cursor, 4)
        when defined(isonimRecordable): beginDispatch(selected)
        else: inc selected.dispatchSequence
        callback(timestamp)
      finally:
        dec selected.activeCallbacks)
    id

  proc disposeInternalReadReplay*(clock: ClockBase) =
    ## Explicit internal lifecycle only: the actual owner has finished, and no
    ## callback is on the stack. Selection changes preserve pending ownership.
    if not clock.isReadReplay:
      raise newException(ValueError, "internal read Replay disposal requires its clock")
    let selected = ReadReplayClock(clock)
    if selected.disposed: return
    if selected.activeCallbacks != 0 or not timerSessionFinished(selected.cursor):
      raise newException(ValueError, "internal read Replay disposal requires completed owner outside callbacks")
    for task in selected.timerTasks.values:
      offTimer(selected.cursor, task)
    selected.timerTasks.clear()
    for task in selected.frameTasks.values:
      offTimer(selected.cursor, task)
    selected.frameTasks.clear()
    selected.frameCancels.clear()
    selected.seamTimers.clear()
    selected.disposed = true

  proc readReplayStorage*(clock: ClockBase; area: int; key: string): JsonNode =
    ## Fixed read bridge, not an observer/provider extension point. Original
    ## owner errors are never caught or wrapped; divergence identity survives.
    parseJson($storageRead(ReadReplayClock(clock).cursor, area, key.cstring))

  proc viewportRead(cursor: JsObject): cstring {.importjs: "(function(r){var w=JSON.parse(r.next('LayoutRead',{target:'win',prop:'innerWidth'}).value);var h=JSON.parse(r.next('LayoutRead',{target:'win',prop:'innerHeight'}).value);return JSON.stringify({x:0,y:0,width:w,height:h});})(#)".}
  proc readReplayViewport*(clock: ClockBase): JsonNode =
    ## Preserve the original width-then-height observations. No platform layout
    ## or boot snapshot can substitute for these dynamic, checked owner reads.
    parseJson($viewportRead(ReadReplayClock(clock).cursor))

  proc mediaRead(cursor: JsObject; query: cstring): bool {.importjs: "(function(r,q){var media=new CSSStyleSheet({media:q}).media.mediaText;if(typeof media!=='string')throw new TypeError('internal read Replay requires media serialization');var value=JSON.parse(r.next('LayoutRead',{target:'win',prop:'matchMedia:'+media}).value);if(value===null||typeof value.matches!=='boolean')throw new TypeError('internal read Replay requires logged media boolean');return value.matches;})(#,#)".}
  proc readReplayMedia*(clock: ClockBase; query: string): JsonNode =
    ## Native CSSOM parses syntax in an unadopted sheet, without creating a live
    ## media query list or consulting layout. Only the checked log supplies the
    ## result. Keep parser/owner exceptions intact; never default missing data.
    %mediaRead(ReadReplayClock(clock).cursor, query.cstring)

  when defined(isonimStableIds):
    import ./iid_lookup
    proc measureIid(el: JsObject): cstring {.importjs: "(function(e){if(typeof Element==='undefined'||!(e instanceof Element))throw new TypeError('internal read Replay does not support measure: requires a registered element');var iid=e.getAttribute('data-iid');if(typeof iid!=='string'||!iid)throw new TypeError('internal read Replay does not support measure: requires a stable iid');return iid;})(#)".}
    proc sameElement(el: JsObject; resolved: JsObject): bool {.importjs: "(# === #)".}
    proc measureRead(cursor: JsObject; iid: cstring): cstring {.importjs: "JSON.stringify(JSON.parse(#.next('LayoutRead',{target:'iid:'+#,prop:'getBoundingClientRect'}).value))".}

  proc readReplayMeasure*(clock: ClockBase; el: JsObject): JsonNode =
    ## Trust the existing registered node identity, never an attribute alone.
    ## This preserves synchronous duplicate checks, detached successor choice
    ## and genuine weak lookup Refusal behavior. No raw geometry is consulted.
    when defined(isonimStableIds):
      let iid = measureIid(el)
      if not sameElement(el, resolveIidLookup(iid)):
        raise newException(ValueError, "internal read Replay does not support measure: requires the registered iid element")
      parseJson($measureRead(ReadReplayClock(clock).cursor, iid))
    else:
      raise newException(ValueError, "internal read Replay does not support measure without stable ids")
