## Real RequestContexts and OS entropy; no network or entropy mocks.
import std/[unittest, strutils, sets, asyncdispatch]
import isonim/server/context
import isonim/routing/client_context

const incoming = "00-4bf92f3577b34da6a3ce929d0e0e4736-00f067aa0ba902b7-01"

proc ctx(headers: seq[(string, string)] = @[]): RequestContext =
  newRequestContext(SsrRequest(headers: headers))

proc checkMint(value: string) =
  check value.len == 55
  check value[0 .. 2] == "00-"
  check value[35] == '-'
  check value[52 .. 54] == "-00"
  check value[3 .. 34] != repeat('0', 32)
  check value[36 .. 51] != repeat('0', 16)
  for i, c in value:
    if i notin [2, 35, 52]: check c in {'0'..'9', 'a'..'f'}

suite "SSR trace context metadata":
  test "forward header names in any case, trim only HTTP OWS, preserve flags":
    for name in ["traceparent", "TRACEPARENT", "TraceParent"]:
      for flags in ["00", "01", "02", "fe", "ff"]:
        let value = incoming[0 .. 52] & flags
        let request = ctx(@[(name, " \t" & value & "\t ")])
        check request.traceparent() == value
        check traceparentMeta(request) ==
          "<meta name=\"traceparent\" content=\"" & value & "\">"

  test "future version prefix keeps ids and sampled bit without suffix reflection":
    for version in ["01", "09", "fe"]:
      for flags in ["00", "01", "fe", "ff"]:
        let expected = incoming[0 .. 52] &
          (if flags in ["01", "ff"]: "01" else: "00")
        for suffix in ["", "-opaque-\"<uninterpreted>&"]:
          let request = ctx(@[("traceparent", version & incoming[2 .. 52] & flags & suffix)])
          check request.traceparent() == expected
          check traceparentMeta(request) ==
            "<meta name=\"traceparent\" content=\"" & expected & "\">"

  test "malformed, duplicate and forbidden inputs mint instead of reflecting":
    let bad = @["", "garbage", incoming.toUpperAscii(),
      incoming & "-extension", incoming[0 .. 53], incoming & "\r\n",
      "ff" & incoming[2 .. ^1], "0g" & incoming[2 .. ^1],
      "01" & incoming[2 .. 53], "01" & incoming[2 .. ^1] & "x-suffix",
      "00-" & repeat('0', 32) & incoming[35 .. ^1],
      incoming[0 .. 35] & repeat('0', 16) & "-01",
      incoming[0 .. 34] & ":" & incoming[36 .. ^1],
      incoming[0 .. 51] & ":01", incoming[0 .. 52] & "0G",
      incoming & "," & incoming, "\"/><script>unexpected</script>"]
    for value in bad:
      let request = ctx(@[("traceparent", value)])
      let minted = request.traceparent()
      checkMint(minted)
      check minted != incoming
      check traceparentMeta(request) ==
        "<meta name=\"traceparent\" content=\"" & minted & "\">"
    for other in [incoming, "invalid"]:
      let request = ctx(@[("traceparent", incoming), ("TraceParent", other)])
      checkMint(request.traceparent())
      check request.traceparent() != incoming

  test "request-local reuse survives header changes and interleaved requests":
    var ids = initHashSet[string]()
    var contexts: seq[RequestContext]
    for i in 0 ..< 128:
      let request = ctx()
      let value = request.traceparent()
      checkMint(value)
      check value notin ids
      ids.incl value
      contexts.add request
      request.request.headers.add ("traceparent", incoming)
      check request.traceparent() == value
    for request in contexts:
      check request.traceparent() in ids
      check traceparentMeta(request).contains(request.traceparent())
    check ctx(@[("traceparent", incoming)]).traceparent() == incoming

  test "async interleaving retains each context":
    proc resolve(i: int): Future[string] {.async.} =
      let request = ctx()
      let initial = request.traceparent()
      await sleepAsync(i mod 3)
      check request.traceparent() == initial
      return initial
    var futures: seq[Future[string]]
    for i in 0 ..< 64: futures.add resolve(i)
    var ids = initHashSet[string]()
    for value in waitFor all(futures):
      check value notin ids
      ids.incl value

  test "existing client metadata still escapes all attribute values":
    check clientContextMeta("a\"<>&", "b\"<>&", "c\"<>&") ==
      "<meta name=\"isonim-instance\" content=\"a&quot;&lt;&gt;&amp;\">" &
      "<meta name=\"isonim-incarnation\" content=\"b&quot;&lt;&gt;&amp;\">" &
      "<meta name=\"csrf-token\" content=\"c&quot;&lt;&gt;&amp;\">"
