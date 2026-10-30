## Actual explicit-public UI generation across shipped renderers and writers.
## No mocks: native is the shipped NativeRenderer, browser is WebRenderer;
## streaming uses the framework's actual string/callback/optional FastStreams.
import std/[tables, strutils]
import isonim/rxcore
import isonim/dsl/ui
import isonim/ssr/[escape, stream, markers]
when defined(isonimPublicBrowser):
  import isonim/web/[web_renderer, dom_api]
  type Renderer = WebRenderer
  proc attribute(n: Element; name: string): string =
    WebRenderer().getAttribute(n, name)
  proc hasAttribute(n: Element; name: cstring): bool {.importcpp: "#.hasAttribute(#)".}
  proc writes(): int = meter.ops[boSetAttribute]
  meterEnabled = true
else:
  import isonim/renderers/native
  type Renderer = NativeRenderer
  proc attribute(n: NativeWidget; name: string): string =
    n.attributes.getOrDefault(name)
  proc hasAttribute(n: NativeWidget; name: string): bool =
    name in n.attributes

var expressions, conversions, stringifications: int
var throwExpression, throwConversion: bool
let original = newException(ValueError, "original authored metadata exception")
type Converted = object
  assigned: string
converter asString(value: Converted): string =
  inc conversions
  if throwConversion: raise original
  value.assigned
proc `$`(value: Converted): string =
  inc stringifications
  "password"
proc authored(value: string): Converted =
  inc expressions
  if throwExpression: raise original
  Converted(assigned: value)
proc reset() =
  expressions = 0; conversions = 0; stringifications = 0
proc once() =
  doAssert expressions == 1, "public expression executes exactly once"
  doAssert conversions == 1, "public implicit converter executes exactly once"
  doAssert stringifications == 0, "public assignment must not use dollar conversion"

createRoot do (dispose: proc()):
  let r = Renderer()
  let kind = createSignal("text")
  let auto = createSignal("off")
  let target = ui(r):
    input(`type` = authored(kind.val), public = true,
      autocomplete = authored(auto.val), value = "seed")
  doAssert attribute(target, "data-isonim-public") == "true", "public client marker is required"
  doAssert not hasAttribute(target, "public"), "public directive is never an HTML attribute"
  doAssert not hasAttribute(target, "sensitive"), "sensitive directive is never an HTML attribute"
  doAssert attribute(target, "value") == "seed"
  for value in ["search", "EMAIL", "tel", "url", "checkbox"]:
    reset(); kind.val = value; once()
    doAssert attribute(target, "type") == value, "public reactive type preserves exact converted bytes"
  for value in ["password", "PaSsWoRd"]:
    let previous = attribute(target, "type")
    when defined(isonimPublicBrowser):
      let count = writes()
    reset()
    var refused = false
    try: kind.val = value
    except ValueError as e: refused = e.msg == "credential input cannot be public"
    once()
    doAssert refused, "public UI type must refuse credential before renderer assignment"
    doAssert attribute(target, "type") == previous, "refused public type changed renderer"
    when defined(isonimPublicBrowser): doAssert writes() == count, "refused public type reached backend noteOp"
  reset(); kind.val = "text"; once()
  doAssert attribute(target, "type") == "text", "legal public type after refusal"
  for value in ["name email", "x-current-password", "one-time-code-x", "x\vcc-number", "x\u00a0cc-number", "name\"&email"]:
    reset(); auto.val = value; once()
    doAssert attribute(target, "autocomplete") == value, "public reactive autocomplete exact bytes"
  for value in ["CC-number", "current-password", "name\tone-time-code", "cc-name\femail", "\rnew-password\n"]:
    let previous = attribute(target, "autocomplete")
    when defined(isonimPublicBrowser):
      let count = writes()
    reset()
    var refused = false
    try: auto.val = value
    except ValueError as e: refused = e.msg == "credential input cannot be public"
    once()
    doAssert refused, "public UI autocomplete must refuse credential before renderer assignment"
    doAssert attribute(target, "autocomplete") == previous, "refused public autocomplete changed renderer"
    when defined(isonimPublicBrowser): doAssert writes() == count, "refused public autocomplete reached backend noteOp"
  reset(); auto.val = "off"; once()
  doAssert attribute(target, "autocomplete") == "off", "legal public autocomplete after refusal"
  for atConversion in [false, true]:
    throwExpression = not atConversion; throwConversion = atConversion
    when defined(isonimPublicBrowser):
      let count = writes()
    let previous = attribute(target, "type")
    reset()
    var same = false
    try: kind.val = (if atConversion: "email" else: "search")
    except ValueError as e: same = e == original
    doAssert same, "public UI preserves authored exception identity"
    doAssert expressions == 1 and conversions == int(atConversion) and stringifications == 0
    doAssert attribute(target, "type") == previous
    when defined(isonimPublicBrowser): doAssert writes() == count
    throwExpression = false; throwConversion = false
  dispose()

# Noninput type attributes retain their ordinary meaning and converter path.
createRoot do (dispose: proc()):
  let r = Renderer()
  reset()
  let target = ui(r):
    textarea(`type` = authored("password"), public = true)
  once()
  doAssert attribute(target, "type") == "password", "noninput type is not credential input type"
  dispose()

let literal = ui:
  input(`type` = "text", public = true, value = "a\"&b")
doAssert literal == "<input data-isonim-public=\"true\" type=\"text\" value=\"a&quot;&amp;b\" />", "public string SSR marker and directive consumption"
for value in ["search", "EMAIL"]:
  reset()
  let html = ui:
    input(public = true, `type` = authored(value))
  once()
  doAssert html == "<input data-isonim-public=\"true\" type=\"" & value & "\" />", "public dynamic type string SSR exact bytes"
for value in ["off", "x\vcc-number", "x\u00a0cc-number", "name\"&email"]:
  reset()
  let html = ui:
    input(public = true, autocomplete = authored(value))
  once()
  doAssert html == "<input data-isonim-public=\"true\" autocomplete=\"" & escapeAttr(value) & "\" />", "public autocomplete string SSR exact bytes"
for value in ["password", "cc-number"]:
  reset()
  var refused = false
  try:
    if value == "password":
      discard ui:
        input(public = true, `type` = authored(value))
    else:
      discard ui:
        input(public = true, autocomplete = authored(value))
  except ValueError as e: refused = e.msg == "credential input cannot be public"
  once()
  doAssert refused, "public string SSR rejects credentials"
for attributeName in ["type", "autocomplete"]:
  for atConversion in [false, true]:
    throwExpression = not atConversion; throwConversion = atConversion
    reset()
    var same = false
    try:
      if attributeName == "type":
        discard ui:
          input(public = true, `type` = authored("text"))
      else:
        discard ui:
          input(public = true, autocomplete = authored("off"))
    except ValueError as e: same = e == original
    doAssert same, "public string SSR preserves original authored exception identity"
    doAssert expressions == 1 and conversions == int(atConversion) and stringifications == 0
    throwExpression = false; throwConversion = false
    reset()
    let legal = ui:
      input(public = true, autocomplete = authored("name email"))
    once()
    doAssert legal == "<input data-isonim-public=\"true\" autocomplete=\"name email\" />", "public string SSR legal assignment after original exception"

var streams = @[(newStringOutputStream(), false)]
var callbackBytes = ""
streams.add((newCallbackOutputStream(proc(s: string) = callbackBytes.add(s)), false))
when defined(useFaststreams): streams.add((newFastOutputStream(), true))
for (output, consumes) in streams:
  # FastStreams' actual getOutput consumes its buffer. Observe every drained
  # chunk, preserving the full asserted history; string/callback are snapshots.
  # This is an output observer, not a replacement writer or renderer.
  var observed = ""
  proc snapshot(): string =
    if consumes:
      observed.add(output.getOutput())
      observed
    else: output.getOutput()
  uiWrite(output):
    input(`type` = "text", public = true, value = "a\"&b")
  doAssert snapshot() == literal, "public stream marker and directive consumption"
  for value in ["text", "SEARCH", "email", "tel", "url", "checkbox"]:
    let previous = snapshot()
    reset()
    uiWrite(output):
      input(public = true, `type` = authored(value))
    once()
    doAssert snapshot() == previous & "<input data-isonim-public=\"true\" type=\"" & value & "\" />", "public stream legal dynamic type preserves exact bytes"
  for attributeName in ["type", "autocomplete"]:
    let previous = snapshot()
    reset()
    var refused = false
    try:
      if attributeName == "type":
        uiWrite(output):
          input(public = true, `type` = authored("password"))
      else:
        uiWrite(output):
          input(public = true, autocomplete = authored("cc-number"))
    except ValueError as e: refused = e.msg == "credential input cannot be public"
    once()
    doAssert refused, "public stream rejects credentials before escaped writer"
    let prefix = "<input data-isonim-public=\"true\" " & attributeName & "=\""
    doAssert snapshot() == previous & prefix, "public stream refusal preserves exact prior prefix"
    reset()
    uiWrite(output):
      input(public = true, autocomplete = authored("name\"&email"))
    once()
    doAssert snapshot() == previous & prefix & "<input data-isonim-public=\"true\" autocomplete=\"name&quot;&amp;email\" />", "public stream permits legal write after refusal"
  for atConversion in [false, true]:
    let previous = snapshot()
    throwExpression = not atConversion; throwConversion = atConversion
    reset()
    var same = false
    try:
      uiWrite(output):
        input(public = true, `type` = authored("text"))
    except ValueError as e: same = e == original
    doAssert same, "public stream preserves authored exception identity"
    doAssert expressions == 1 and conversions == int(atConversion) and stringifications == 0
    doAssert snapshot() == previous & "<input data-isonim-public=\"true\" type=\""
    throwExpression = false; throwConversion = false
# Bare unknown names with named arguments are elements under the existing
# resolver. Supported generic helper calls remain ordinary Nim expressions.
var helperCalls = 0
proc publicHelper[R](r: R; public: bool): auto =
  doAssert public
  inc helperCalls
  r.createElement("span")
proc publicHtml[T](public: T): string =
  doAssert public
  inc helperCalls
  "<span>helper</span>"
let helperNode = ui(Renderer()):
  publicHelper[Renderer](Renderer(), public = true)
doAssert helperCalls == 1 and not hasAttribute(helperNode, "data-isonim-public"), "named public helper parameter is not a DOM directive"
let helperHtml = ui:
  publicHtml[bool](public = true)
doAssert helperHtml == "<span>helper</span>" and helperCalls == 2
let helperStream = newStringOutputStream()
uiWrite(helperStream):
  publicHtml[bool](public = true)
doAssert helperStream.getOutput() == helperHtml and helperCalls == 3

# Preserve the established hydration/stable metadata order in both SSR paths.
var keyedHtml: string
withHydrationKeys("public-"):
  keyedHtml = ui:
    input(public = true, `type` = "text")
let keyedStream = newStringOutputStream()
withHydrationKeys("public-"):
  uiWrite(keyedStream):
    input(public = true, `type` = "text")
doAssert keyedHtml == "<input data-hk=\"public-1\" data-isonim-public=\"true\" type=\"text\" />"
doAssert keyedStream.getOutput() == keyedHtml, "public string and stream preserve hydration key order"

# Callback exceptions retain the exact thrown object and successful prefix.
let callbackException = newException(ValueError, "original output callback exception")
var written = ""
let failingOutput = newCallbackOutputStream(proc(chunk: string) =
  if chunk == "text": raise callbackException
  written.add(chunk))
var caughtCallback = false
try:
  uiWrite(failingOutput):
    input(public = true, `type` = authored("text"))
except ValueError as e: caughtCallback = e == callbackException
doAssert caughtCallback, "public callback preserves original writer exception identity"
doAssert written == "<input data-isonim-public=\"true\" type=\"" and failingOutput.getOutput() == written,
  "public callback preserves successful prefix before writer exception"
when defined(isonimPublicBrowser):
  {.emit: "globalThis.publicDirectivePassed = true;".}
echo "PASS public directive actual renderer and SSR boundaries"
