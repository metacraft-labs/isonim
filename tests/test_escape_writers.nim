## Real shipped SSR streams, plus native FastStreams when explicitly enabled.
## No mock writers or transport substitutes: callbacks are the public backend.
import std/strutils
import isonim/ssr/[escape, stream]
when defined(useFaststreams):
  import faststreams/outputs as fsOutputs

type EscapeCase = tuple[input, expected: string, chunks: seq[string]]
const htmlCases: array[9, EscapeCase] = [
  ("", "", newSeq[string]()),
  ("plain", "plain", @["plain"]),
  ("<first", "&lt;first", @["&lt;", "first"]),
  ("last>", "last&gt;", @["last", "&gt;"]),
  ("<>&", "&lt;&gt;&amp;", @["&lt;", "&gt;", "&amp;"]),
  ("a<b>c&d", "a&lt;b&gt;c&amp;d", @["a", "&lt;", "b", "&gt;", "c", "&amp;", "d"]),
  ("\"'", "\"'", @["\"'"]),
  ("π<雪&🙂", "π&lt;雪&amp;🙂", @["π", "&lt;", "雪", "&amp;", "🙂"]),
  ("\0<&\0", "\0&lt;&amp;\0", @["\0", "&lt;", "&amp;", "\0"])]
const attrCases: array[9, EscapeCase] = [
  ("", "", newSeq[string]()),
  ("plain", "plain", @["plain"]),
  ("\"first", "&quot;first", @["&quot;", "first"]),
  ("last&", "last&amp;", @["last", "&amp;"]),
  ("\"&\"", "&quot;&amp;&quot;", @["&quot;", "&amp;", "&quot;"]),
  ("a\"b&c", "a&quot;b&amp;c", @["a", "&quot;", "b", "&amp;", "c"]),
  ("<>'", "<>'", @["<>'"]),
  ("π\"雪&🙂", "π&quot;雪&amp;🙂", @["π", "&quot;", "雪", "&amp;", "🙂"]),
  ("\0\"&\0", "\0&quot;&amp;\0", @["\0", "&quot;", "&amp;", "\0"])]

proc writeCase(s: stream.OutputStream; value: string; attribute: bool) =
  if attribute: writeEscapedAttr(s, value)
  else: writeEscapedHtml(s, value)

proc checkCases(cases: openArray[EscapeCase]; attribute: bool) =
  for row in cases:
    let accumulated = newStringOutputStream()
    writeCase(accumulated, row.input, attribute)
    doAssert accumulated.getOutput() == row.expected, "string exact escaped bytes"
    var chunks: seq[string]
    let callback = newCallbackOutputStream(proc(data: string) = chunks.add(data))
    writeCase(callback, row.input, attribute)
    doAssert chunks == row.chunks, "callback exact chunk sequence"
    doAssert callback.getOutput() == row.expected, "callback exact escaped bytes"
    doAssert chunks.join("") == row.expected
    for chunk in chunks: doAssert chunk.len > 0, "no empty span writes"
    when defined(useFaststreams):
      let wrapped = newFastOutputStream()
      writeCase(wrapped, row.input, attribute)
      doAssert wrapped.getOutput() == row.expected, "wrapped fast exact escaped bytes"
      let native = fsOutputs.memoryOutput()
      # This is the actual library overload, not a replacement test writer.
      static: doAssert compiles(fsOutputs.write(native.s, row.input.toOpenArray(0, 0)))
      if attribute: writeEscapedAttr(native.s, row.input)
      else: writeEscapedHtml(native.s, row.input)
      doAssert fsOutputs.getOutput(native.s, string) == row.expected,
        "native fast exact escaped bytes"

proc checkExceptions(attribute: bool) =
  let value = if attribute: "before\"after&tail" else: "before<after&tail"
  let entity = if attribute: "&quot;" else: "&lt;"
  let expectedChunks = @["before", entity, "after", "&amp;", "tail"]
  for throwAt in 0 ..< expectedChunks.len:
    let marker = newException(ValueError, "original callback exception")
    var chunks: seq[string]
    let callback = newCallbackOutputStream(proc(data: string) =
      chunks.add(data)
      if chunks.len == throwAt + 1: raise marker)
    var caught = false
    try: writeCase(callback, value, attribute)
    except ValueError as error:
      caught = true
      doAssert error == marker, "callback exception identity"
    doAssert caught, "callback must throw"
    doAssert chunks == expectedChunks[0 .. throwAt], "no chunks after exception"
    let successful = if throwAt == 0: "" else: expectedChunks[0 ..< throwAt].join("")
    doAssert callback.getOutput() == successful, "only successful callback writes retained"

# Ordinary string writes remain legal independently of generic escaping.
let ordinary = newStringOutputStream()
ordinary.write("ordinary <&\" π")
doAssert ordinary.getOutput() == "ordinary <&\" π"
var directChunks: seq[string]
let direct = newCallbackOutputStream(proc(data: string) = directChunks.add(data))
direct.write("ordinary")
doAssert directChunks == @["ordinary"]
doAssert direct.getOutput() == "ordinary"
checkCases(htmlCases, false)
checkCases(attrCases, true)
checkExceptions(false)
checkExceptions(true)
echo "escape writers PASS: 18 exact cases, 10 exception positions, ordinary writes"
