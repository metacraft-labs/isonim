## Internal policy preparation only, not ui activation or recording privacy.
## Real compiler AST, shipped native renderer and real SSR escape/string stream
## boundaries are used; no renderer, parser or stream mock is introduced.
import std/[tables, strutils]
import isonim/dsl/private/input_privacy
import ./input_privacy_policy_probe
import isonim/renderers/native
import isonim/ssr/escape
import isonim/ssr/stream

doAssert privacyProbe(input(public = true)) == "ipPublic"
doAssert privacyProbe(input(sensitive = true)) == "ipSensitive"
doAssert privacyProbe(input(`type` = "password")) == "ipSensitive"
doAssert privacyProbe(input(`type` = "checkbox")) == "ipNone"
doAssert privacyProbe(tdiv(contenteditable = "FALSE")) == "ipNone"
doAssert privacyProbe(tdiv(contenteditable = false)) == "ipNone"
doAssert privacyProbe(ttype()) == "ipNone" # actual tag alias -> type, not input
doAssert privacyProbe(input(ttype = "password", public = true)) == "ipPublic"

var expressions, conversions, stringifications: int
type Converted = object
  assigned: string
  displayed: string
converter asString(value: Converted): string =
  inc conversions
  value.assigned
proc `$`(value: Converted): string =
  inc stringifications
  value.displayed
proc authored(assigned, displayed: string): Converted =
  inc expressions
  Converted(assigned: assigned, displayed: displayed)
proc reset() =
  expressions = 0
  conversions = 0
  stringifications = 0
proc once() =
  doAssert expressions == 1, "authored expression must run once"
  doAssert conversions == 1, "implicit string converter must run once"
  doAssert stringifications == 0, "$ must not replace the assigned string"

let renderer = NativeRenderer()
let target = renderer.createElement("input")
reset()
renderer.setAttribute(target, "type", authored("search", "password"))
once()
doAssert target.attributes["type"] == "search", "ordinary conversion control"

reset()
renderer.setAttribute(target, "type", checkedProbe(textarea(public = true), "type",
  authored("password", "text")))
once()
doAssert target.attributes["type"] == "password", "textarea type is not input type"
reset()
renderer.setAttribute(target, "type", checkedProbe(
  tdiv(contenteditable = "true", public = true), "type", authored("password", "text")))
once()
doAssert target.attributes["type"] == "password", "editable div type is not input type"

for value in ["text", "SEARCH", "email", "tel", "url", "checkbox"]:
  reset()
  renderer.setAttribute(target, "type", checkedProbe(input(public = true), "type",
    authored(value, "password")))
  once()
  doAssert target.attributes["type"] == value, "exact checked renderer string"

for value in ["password", "PaSsWoRd"]:
  let previous = target.attributes["type"]
  reset()
  var refused = false
  try:
    renderer.setAttribute(target, "type", checkedProbe(input(public = true), "type",
      authored(value, "text")))
  except ValueError as exception:
    refused = exception.msg == "credential input cannot be public"
  once()
  doAssert refused, "credential type must be refused before renderer write"
  doAssert target.attributes["type"] == previous, "refused renderer write changed target"

for value in ["section-shipping CC-number", "current-password", "NEW-PASSWORD",
    "name\tone-time-code", "cc-name\femail", "\rcc-exp\n"]:
  reset()
  var refused = false
  try:
    renderer.setAttribute(target, "autocomplete",
      requirePublicAutocomplete(authored(value, "off")))
  except ValueError as exception:
    refused = exception.msg == "credential input cannot be public"
  once()
  doAssert refused, "credential autocomplete must be refused before renderer write"
  doAssert "autocomplete" notin target.attributes

# Exercise the compile-time autocomplete dispatch itself, retaining the direct
# guard controls above/below. A missing dispatch must fail this original named
# assertion, even though the standalone guard continues to work.
let autocompleteTarget = renderer.createElement("input")
for value in ["off", "name\"&email", "x\vcc-number", "x\u00a0cc-number"]:
  reset()
  renderer.setAttribute(autocompleteTarget, "autocomplete", checkedProbe(
    input(public = true), "autocomplete", authored(value, "cc-number")))
  once()
  doAssert autocompleteTarget.attributes["autocomplete"] == value,
    "autocomplete dispatch must preserve exact assigned renderer bytes"

for value in ["CC-number", "current-password", "name\tone-time-code"]:
  let previous = autocompleteTarget.attributes["autocomplete"]
  reset()
  var refused = false
  try:
    renderer.setAttribute(autocompleteTarget, "autocomplete", checkedProbe(
      input(public = true), "autocomplete", authored(value, "off")))
  except ValueError as exception:
    refused = exception.msg == "credential input cannot be public"
  once()
  doAssert refused, "autocomplete dispatch must refuse credential before renderer write"
  doAssert autocompleteTarget.attributes["autocomplete"] == previous,
    "refused autocomplete dispatch changed the renderer target"

reset()
renderer.setAttribute(autocompleteTarget, "autocomplete", checkedProbe(
  input(public = true), "autocomplete", authored("name email", "cc-number")))
once()
doAssert autocompleteTarget.attributes["autocomplete"] == "name email",
  "autocomplete dispatch must permit legal assignment after refusal"

for value in ["off", "name\"&email", "x\vcc-number", "x\u00a0cc-number"]:
  reset()
  let escaped = escapeAttr(checkedProbe(input(public = true), "autocomplete",
    authored(value, "cc-number")))
  once()
  doAssert escaped == escapeAttr(value), "autocomplete dispatch exact string SSR bytes"
  reset()
  let stream = newStringOutputStream()
  writeEscapedAttr(stream, checkedProbe(input(public = true), "autocomplete",
    authored(value, "cc-number")))
  once()
  doAssert stream.getOutput() == escapeAttr(value),
    "autocomplete dispatch exact framework stream bytes"

for boundary in 0..1:
  reset()
  let stream = newStringOutputStream()
  stream.write("prefix")
  var refused = false
  try:
    if boundary == 0:
      discard escapeAttr(checkedProbe(input(public = true), "autocomplete",
        authored("cc-number", "off")))
    else:
      writeEscapedAttr(stream, checkedProbe(input(public = true), "autocomplete",
        authored("cc-number", "off")))
  except ValueError as exception:
    refused = exception.msg == "credential input cannot be public"
  once()
  doAssert refused, "autocomplete dispatch must refuse credential before SSR write"
  doAssert stream.getOutput() == "prefix", "refused autocomplete dispatch emitted bytes"
  reset()
  writeEscapedAttr(stream, checkedProbe(input(public = true), "autocomplete",
    authored("name\"&email", "cc-number")))
  once()
  doAssert stream.getOutput() == "prefix" & escapeAttr("name\"&email"),
    "autocomplete dispatch must permit legal stream assignment after refusal"

for value in ["off", "name email", "x-current-password", "one-time-code-x",
    "x\vcc-number", "x\u00a0cc-number", "name\"&email"]:
  reset()
  let escaped = escapeAttr(requirePublicAutocomplete(authored(value, "cc-number")))
  once()
  doAssert escaped == escapeAttr(value), "exact checked string SSR bytes"
  reset()
  let stream = newStringOutputStream()
  writeEscapedAttr(stream, requirePublicAutocomplete(authored(value, "cc-number")))
  once()
  doAssert stream.getOutput() == escapeAttr(value), "exact checked streaming SSR bytes"

reset()
renderer.setAttribute(target, "type", requirePublicInputType(authored("text", "password")))
once()
doAssert target.attributes["type"] == "text", "legal update after refused assignment"
reset()
doAssert escapeAttr(requirePublicInputType(authored("SEARCH", "password"))) == "SEARCH"
once()
reset()
let typeStream = newStringOutputStream()
writeEscapedAttr(typeStream, requirePublicInputType(authored("text", "password")))
once()
doAssert typeStream.getOutput() == "text"

for boundary in 0..1:
  reset()
  var refused = false
  let stream = newStringOutputStream()
  stream.write("prefix")
  try:
    if boundary == 0:
      discard escapeAttr(requirePublicInputType(authored("password", "text")))
    else:
      writeEscapedAttr(stream, requirePublicAutocomplete(authored("cc-number", "off")))
  except ValueError as exception:
    refused = exception.msg == "credential input cannot be public"
  once()
  doAssert refused, "credential must be refused before SSR boundary"
  doAssert stream.getOutput() == "prefix", "refused stream emitted bytes"

let original = newException(ValueError, "original authored exception")
var caughtOriginal = false
proc throws(): string = raise original
try:
  renderer.setAttribute(target, "type", requirePublicInputType(throws()))
except ValueError as exception:
  caughtOriginal = exception == original
doAssert caughtOriginal, "original authored exception identity must be preserved"

converter throwingConversion(value: range[0..0]): string = raise original
caughtOriginal = false
try:
  discard requirePublicAutocomplete(range[0..0](0))
except ValueError as exception:
  caughtOriginal = exception == original
doAssert caughtOriginal, "original converter exception identity must be preserved"

echo "private input policy runtime: PASS"
