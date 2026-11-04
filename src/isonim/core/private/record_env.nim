## Private, synchronous projection of already frozen boot/render JSON data.
## This module never obtains a snapshot, selects a backend or loads a recorder.
## The trusted coordinator owns provenance and acyclic input lifetime.
when defined(js) and defined(isonimInternalRecordEnv):
  import std/[algorithm, json, jsffi, math]

  proc plainJson(text: cstring): JsObject {.noSideEffect, tags: [], importjs: "JSON.parse(#)".}
  proc utf16Length(text: cstring): int {.noSideEffect, tags: [], importjs: "#.length".}
  proc compareUtf16(a, b: cstring): int
      {.noSideEffect, tags: [], importjs: "(function(a,b){return a<b?-1:a>b?1:0;})(#,#)".}
  proc ownerMajor(ua: cstring): int
      {.noSideEffect, tags: [], importjs: "(function(s){var m=/(?:Chrome|Chromium|Firefox|Version)\\/([0-9]+)/.exec(s);if(!m)return 0;var n=Number(m[1]);return Number.isInteger(n)&&n>=0&&n<=65535?n:0;})(#)".}

  proc invalid(path, reason: string) {.noreturn, tags: [].} =
    raise newException(ValueError, "internal Record Env: " & path & ": " & reason)

  proc kindAt(node: JsonNode; key: string): JsonNode {.tags: [].} =
    ## Nil represents both an absent member and a nil input node.
    if not node.isNil and node.kind == JObject and node.hasKey(key): node[key]
    else: nil

  proc requireKind(node: JsonNode; kind: JsonNodeKind; path, reason: string) {.tags: [].} =
    if node.isNil or node.kind != kind: invalid(path, reason)

  proc stringAt(node: JsonNode; key, path: string): string {.tags: [].} =
    let value = kindAt(node, key)
    requireKind(value, JString, path, "expected string")
    value.getStr()

  proc numberAt(node: JsonNode; key, path: string): float64 {.tags: [].} =
    let value = kindAt(node, key)
    if value.isNil or value.kind notin {JInt, JFloat}:
      invalid(path, "expected number")
    value.getFloat()

  proc finite(value: float64): bool {.tags: [].} =
    classify(value) notin {fcNan, fcInf, fcNegInf}

  proc viewportNumber(value: float64): float64 {.tags: [].} =
    ## Floor before checking the wire u32 range; do not wrap or clamp.
    let integral = floor(value)
    if finite(integral) and integral >= 0 and integral <= 4294967295.0:
      if integral == 0: 0.0 else: integral
    else: 0.0

  proc projectedArms(resource: JsonNode): string {.tags: [].} =
    if resource.isNil or resource.kind == JNull: return "{}"
    requireKind(resource, JObject, "completedExperimentResource", "expected object or null")
    let assignment = kindAt(resource, "assign")
    let path = "completedExperimentResource.assign"
    requireKind(assignment, JObject, path, "expected object")
    if assignment.len > 64: invalid(path, "at most 64 entries")
    var keys: seq[string]
    for key, value in assignment: keys.add(key)
    keys.sort(proc(a, b: string): int = compareUtf16(cstring(a), cstring(b)))
    result = "{"
    for index, key in keys:
      let entryPath = path & "[" & $(%key) & "]"
      let units = utf16Length(cstring(key))
      if units < 1 or units > 256:
        invalid(entryPath, "key length must be 1..256 UTF-16 units")
      let value = assignment[key]
      if value.isNil or value.kind != JInt or value.getBiggestInt() < 0 or
          value.getBiggestInt() > 9007199254740991'i64:
        invalid(entryPath, "expected nonnegative safe integer")
      if index > 0: result.add(',')
      # Direct pairs retain lexical numeric-key order and prototype-named data.
      result.add($( %key ) & ":" & $( %($value.getBiggestInt()) ))
    result.add('}')

  proc projectInternalRecordEnv*(cachedEnv, completedExperimentResource: JsonNode): JsObject {.tags: [].} =
    ## Returns precisely the fourteen Env fields, freshly owned on every call.
    ## Validation order is stable even when several input fields are invalid.
    requireKind(cachedEnv, JObject, "cachedEnv", "expected object")
    let ua = stringAt(cachedEnv, "ua", "cachedEnv.ua")
    let viewport = kindAt(cachedEnv, "viewport")
    requireKind(viewport, JObject, "cachedEnv.viewport", "expected object")
    let width = numberAt(viewport, "width", "cachedEnv.viewport.width")
    let height = numberAt(viewport, "height", "cachedEnv.viewport.height")
    let dpr = numberAt(cachedEnv, "dpr", "cachedEnv.dpr")
    if not finite(dpr): invalid("cachedEnv.dpr", "expected finite number")
    let locale = stringAt(cachedEnv, "language", "cachedEnv.language")
    let timezone = stringAt(cachedEnv, "timeZone", "cachedEnv.timeZone")
    let color = kindAt(cachedEnv, "colorScheme")
    if color.isNil or color.kind != JInt or color.getInt() notin 0..2:
      invalid("cachedEnv.colorScheme", "expected integer 0..2")
    let motion = kindAt(cachedEnv, "prefersReducedMotion")
    requireKind(motion, JBool, "cachedEnv.prefersReducedMotion", "expected boolean")
    let arms = projectedArms(completedExperimentResource)
    let url = stringAt(cachedEnv, "url", "cachedEnv.url")
    let referrer = stringAt(cachedEnv, "referrerOrigin", "cachedEnv.referrerOrigin")
    let traceparent = stringAt(cachedEnv, "traceparent", "cachedEnv.traceparent")
    let fields = %*{
      "ua": ua, "ua_major": ownerMajor(cstring(ua)),
      "viewport_w": viewportNumber(width), "viewport_h": viewportNumber(height),
      "dpr": dpr, "locale": locale, "tz": timezone, "fonts_digest": "",
      "color_scheme": color.getInt(), "reduced_motion": ord(motion.getBool()),
      "arms": arms, "url": url, "referrer_origin": referrer, "traceparent": traceparent}
    plainJson(cstring($fields))
