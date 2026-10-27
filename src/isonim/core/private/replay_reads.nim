## Internal, incomplete Replay preparation. Deliberate private imports only.
## Context is supplied by the trusted caller, NOT reconstructed from the log.
## No owner module, global or platform patch is installed by importing this file.
## The internal define is preparation-only. Normal/dormant builds omit even
## private RTTI/state and the guard calls; no runtime feature switch is added.
when defined(js) and defined(isonimInternalReplayReads):
  import std/json
  import ../clock
  import std/jsffi

  type ReadReplayClock = ref object of ClockBase
    cursor: JsObject

  proc isReadReplay*(clock: ClockBase): bool = clock != nil and clock of ReadReplayClock

  proc refuseReadReplay*(clock: ClockBase; operation: string) =
    ## A negative type check leaves every existing Real/Test/custom clock alone.
    if clock.isReadReplay:
      raise newException(ValueError, "internal read Replay does not support " & operation)

  proc actualCursor(): JsObject {.importjs: "(function(){var r=globalThis.__ctReplay;if(!r||r.protocol!==1||typeof r.next!=='function')throw new Error('internal read Replay requires actual __ctReplay protocol 1');return r;})()".}
  proc captureQueueLive(): bool {.importjs: "(globalThis['_'+String.fromCharCode(36)+'HY']!=null&&globalThis['_'+String.fromCharCode(36)+'HY'].events!=null)".}
  proc guardCollision(): bool {.importjs: "Object.getOwnPropertyDescriptor(globalThis,'__isonimInternalReadReplaySelected')!==undefined".}
  var guardInstalled = false
  proc installSelectionGuard(selected: proc(): bool) {.importjs: "Object.defineProperty(globalThis,'__isonimInternalReadReplaySelected',{value:Object.freeze({internalReadReplay:true,selected:#})})".}
  proc clockRead(cursor: JsObject): float64 {.importjs: "(function(r){var c=r.next('Clock',{src:2}),d=new DataView(new ArrayBuffer(8));d.setBigUint64(0,c.bits,true);return d.getFloat64(0,true);})(#)".}
  proc storageRead(cursor: JsObject; area: int; key: cstring): cstring {.importjs: "(function(r,a,k){var s=r.next('StorageRead',{area:a,key:k});return JSON.stringify(s.present===0?null:s.value);})(#,#,#)".}

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

  method now(clock: ReadReplayClock): float64 = clockRead(clock.cursor)
  method schedule(clock: ReadReplayClock; callback: proc(); delayMs: float64): int =
    raise newException(ValueError, "internal read Replay does not support schedule")
  method cancel(clock: ReadReplayClock; id: int) =
    raise newException(ValueError, "internal read Replay does not support cancel")

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
