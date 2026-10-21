## Resource scripts must remain HTML-safe for untrusted keys and JSON strings.
## No mocks: browser execution is also exercised by the experiments SSR fixture.
import std/[json, strutils]
import isonim/ssr/serializer
let payload = "</script><script>globalThis.injected=1</script>"
for script in [serializeResourceData(payload, %payload), serializeResources([(payload, %payload)])]:
  doAssert script.startsWith("<script>_$HY.r[")
  doAssert script.endsWith(";</script>")
  doAssert script.count("</script>") == 1
  doAssert not script.contains(payload)
  doAssert script.contains("\\u003c/script>")
let quote = serializeResourceData("x\";globalThis.injected=1;//", %"ok")
doAssert quote.contains("x\\\";globalThis.injected=1;//")
echo "SSR resource script safety passed"
