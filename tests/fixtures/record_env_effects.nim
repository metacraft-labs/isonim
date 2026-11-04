## Genuine effect controls; removing only the forbidden call accepts this caller.
import std/[json, jsffi]
import isonim/core/private/record_env
import isonim/core/nondet
import nim_everywhere/raw_nondet
proc actualRawUrl(): cstring {.importjs: "(function(){return window.location.href;})(@)", tags: [RawNondet].}
proc strict(cached, resource: JsonNode): JsObject {.tags: [].} =
  when defined(recordEnvEffectEnv): discard env()
  when defined(recordEnvEffectRaw): discard actualRawUrl()
  projectInternalRecordEnv(cached, resource)
