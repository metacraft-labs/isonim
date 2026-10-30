## Required native FastStreams boundary controls; no mock stream or sink.
## FastStreams uses native memory primitives. The C/JS companion tests exercise
## the framework's actual string OutputStream on both compiler targets.
import isonim/dsl/private/input_privacy
import isonim/ssr/escape
import faststreams/outputs

var expressions, conversions, stringifications: int
type Converted = object
  assigned: string
converter asString(value: Converted): string =
  inc conversions
  value.assigned
proc `$`(value: Converted): string =
  inc stringifications
  "password"
proc authored(value: string): Converted =
  inc expressions
  Converted(assigned: value)
proc reset() =
  expressions = 0
  conversions = 0
  stringifications = 0
proc once() =
  doAssert expressions == 1
  doAssert conversions == 1
  doAssert stringifications == 0

for value in ["text", "SEARCH", "email", "tel", "url", "checkbox"]:
  reset()
  let stream = memoryOutput()
  writeEscapedAttr(stream.s, requirePublicInputType(authored(value)))
  once()
  doAssert stream.s.getOutput(string) == value, "exact checked FastStreams type bytes"

for value in ["name email", "name\"&email", "x\vcc-number", "x\u00a0cc-number"]:
  reset()
  let stream = memoryOutput()
  writeEscapedAttr(stream.s, requirePublicAutocomplete(authored(value)))
  once()
  doAssert stream.s.getOutput(string) == escapeAttr(value), "exact checked FastStreams autocomplete bytes"

for kind in 0..1:
  reset()
  let stream = memoryOutput()
  stream.s.write("prefix")
  var refused = false
  try:
    if kind == 0:
      writeEscapedAttr(stream.s, requirePublicInputType(authored("password")))
    else:
      writeEscapedAttr(stream.s, requirePublicAutocomplete(authored("cc-number")))
  except ValueError as exception:
    refused = exception.msg == "credential input cannot be public"
  once()
  doAssert refused, "credential must be refused before FastStreams write"
  doAssert stream.s.getOutput(string) == "prefix", "refused FastStreams write emitted bytes"

let original = newException(ValueError, "original FastStreams authored exception")
proc throws(): string = raise original
let stream = memoryOutput()
stream.s.write("prefix")
var caught = false
try:
  writeEscapedAttr(stream.s, requirePublicInputType(throws()))
except ValueError as exception:
  caught = exception == original
doAssert caught, "FastStreams must preserve original authored exception identity"
doAssert stream.s.getOutput(string) == "prefix"
echo "private input policy FastStreams: PASS"
