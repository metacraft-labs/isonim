## Actual typed API bridge: only JSON decoding and observable result/error capture.
import std/[json, jsffi, math]
import isonim/core/private/record_env
when defined(isonimInternalRecordEnv):
  proc failure(name, message: cstring): JsObject
      {.importjs: "({error:{name:#,message:#}})".}
  proc success(value: JsObject): JsObject {.importjs: "({value:#})".}
  proc project(text, resource: cstring; special: cstring = cstring""): JsObject {.exportc: "envProject".} =
    var cached = parseJson($text)
    let completed = if resource == cstring"nil": nil else: parseJson($resource)
    case $special
    of "nan-dpr": cached["dpr"] = newJFloat(NaN)
    of "inf-dpr": cached["dpr"] = newJFloat(Inf)
    of "neginf-dpr": cached["dpr"] = newJFloat(NegInf)
    of "nil-cached": cached = nil
    of "negative-zero":
      cached["viewport"]["width"] = newJFloat(-0.0)
      cached["viewport"]["height"] = newJFloat(-0.0)
      cached["dpr"] = newJFloat(-0.0)
    of "huge-viewport":
      cached["viewport"]["width"] = newJFloat(1e100)
      cached["viewport"]["height"] = newJFloat(1e100)
    of "huge-dpr": cached["dpr"] = newJFloat(1e100)
    of "unsafe-arm": completed["assign"]["checkout"] = newJInt(9007199254740992'i64)
    of "nan-width": cached["viewport"]["width"] = newJFloat(NaN)
    of "inf-height": cached["viewport"]["height"] = newJFloat(Inf)
    of "float-arm": completed["assign"]["checkout"] = newJFloat(1.0)
    of "float-color": cached["colorScheme"] = newJFloat(1.0)
    else: discard
    try: success(projectInternalRecordEnv(cached, completed))
    except ValueError as error: failure(cstring"ValueError", cstring(error.msg))

  proc projection(cached, resource: JsonNode): JsObject =
    projectInternalRecordEnv(cached, resource)

  proc failureOwnership(text, resource: cstring): JsObject {.exportc: "envFailureOwnership".} =
    let cached = parseJson($text)
    let completed = parseJson($resource)
    let before = $cached & "\n" & $completed
    var outcome: JsObject
    try: outcome = success(projection(cached, completed))
    except ValueError as error: outcome = failure(cstring"ValueError", cstring(error.msg))
    let after = $cached & "\n" & $completed
    proc report(outcome: JsObject; before, after: cstring): JsObject
        {.importjs: "({outcome:#,before:#,after:#})".}
    report(outcome, cstring(before), cstring(after))

  proc ownership(text, resource: cstring): JsObject {.exportc: "envOwnership".} =
    let cached = parseJson($text)
    let completed = parseJson($resource)
    let before = $cached & "\n" & $completed
    let first = projection(cached, completed)
    let second = projection(cached, completed)
    proc mutate(value: JsObject) {.importjs: "(#).url='mutated-result'".}
    mutate(first)
    let after = $cached & "\n" & $completed
    let third = projection(cached, completed)
    cached["url"] = %"mutated-input"
    completed["assign"]["checkout"] = %8
    proc report(first, second, third: JsObject; before, after: cstring): JsObject
        {.importjs: "({first:#,second:#,third:#,before:#,after:#})".}
    report(first, second, third, cstring(before), cstring(after))
else:
  static: doAssert not declared(projectInternalRecordEnv)
  echo "record-env-absent PASS"
