import unittest
import std/[strutils, tables]
import isonim/ssr/stream
import isonim/ssr/streaming
import isonim/ssr/renderer
import isonim/core/clock
import isonim/testing/test_utils

suite "Streaming SSR":
  test "test_stream_shell_first":
    ## renderToStream emits shell before Suspense resolves.
    var shellReceived = false
    var allReceived = false

    let options = StreamOptions(
      onCompleteShell: proc() = shellReceived = true,
      onCompleteAll: proc() = allReceived = true,
    )

    # Render with one pending Suspense boundary
    let sr = renderToStream(proc(ctx: StreamContext): string =
      ssrElement("div", children =
        ssrElement("h1", children = "Page Title") &
        ctx.ssrSuspense(
          fallback = "<p>Loading...</p>",
          content = proc(): string =
            # Content not available yet -- return empty, will resolve later
            return "<p>Loaded data</p>",
          boundaryId = "b1",
        )
      )
    , options)

    # Shell was emitted immediately
    check shellReceived
    # Not all done yet (boundary b1 is still pending)
    check not allReceived

    # Shell contains the placeholder markup
    let shell = sr.ctx.chunks[0]
    check "<h1>Page Title</h1>" in shell
    check "pl-b1" in shell
    check "<p>Loading...</p>" in shell
    check "<!--!$b1-->" in shell
    check "$df" in shell  # $df script included

  test "test_stream_suspense_fill":
    ## After resource resolves, replacement script fills placeholder.
    var shellReceived = false
    var allReceived = false

    let options = StreamOptions(
      onCompleteShell: proc() = shellReceived = true,
      onCompleteAll: proc() = allReceived = true,
    )

    let sr = renderToStream(proc(ctx: StreamContext): string =
      ssrElement("div", children =
        ctx.ssrSuspense(
          fallback = "<span>Loading user...</span>",
          content = proc(): string =
            return "<span>User content</span>",
          boundaryId = "user-1",
        )
      )
    , options)

    check shellReceived
    check not allReceived

    # Resolve the boundary with actual content
    sr.ctx.resolveBoundary("user-1", "<span>Alice, age 30</span>")

    check allReceived

    # The replacement chunk should contain template + script
    let fullOutput = sr.getFullOutput()
    check "<template id=\"user-1\"><span>Alice, age 30</span></template>" in fullOutput
    check "<script>$df(\"user-1\")</script>" in fullOutput

  test "test_stream_multiple_suspense":
    ## Multiple Suspense boundaries fill independently.
    var shellReceived = false
    var allReceived = false
    let options = StreamOptions(
      onCompleteShell: proc() = shellReceived = true,
      onCompleteAll: proc() =
        allReceived = true,
    )

    let sr = renderToStream(proc(ctx: StreamContext): string =
      ssrElement("div", children =
        ctx.ssrSuspense(
          fallback = "<p>Loading A...</p>",
          content = proc(): string = "<p>Content A</p>",
          boundaryId = "a",
        ) &
        ctx.ssrSuspense(
          fallback = "<p>Loading B...</p>",
          content = proc(): string = "<p>Content B</p>",
          boundaryId = "b",
        ) &
        ctx.ssrSuspense(
          fallback = "<p>Loading C...</p>",
          content = proc(): string = "<p>Content C</p>",
          boundaryId = "c",
        )
      )
    , options)

    check shellReceived
    check not allReceived
    check sr.ctx.boundaries.len == 3

    # Resolve in non-sequential order
    sr.ctx.resolveBoundary("b", "<p>Resolved B</p>")
    check not allReceived  # Still waiting for a and c

    sr.ctx.resolveBoundary("a", "<p>Resolved A</p>")
    check not allReceived  # Still waiting for c

    sr.ctx.resolveBoundary("c", "<p>Resolved C</p>")
    check allReceived  # All done!

    # Verify each boundary got its own replacement chunk
    let fullOutput = sr.getFullOutput()
    check "<template id=\"b\"><p>Resolved B</p></template>" in fullOutput
    check "<script>$df(\"b\")</script>" in fullOutput
    check "<template id=\"a\"><p>Resolved A</p></template>" in fullOutput
    check "<script>$df(\"a\")</script>" in fullOutput
    check "<template id=\"c\"><p>Resolved C</p></template>" in fullOutput
    check "<script>$df(\"c\")</script>" in fullOutput

  test "test_render_to_string_async_timeout":
    ## renderToStringAsync returns partial result after timeout.
    ## Since we use callback-based resolution (no real async),
    ## unresolved boundaries keep their fallback content.
    withFakeTime:
      let html = renderToStringAsync(proc(ctx: StreamContext): string =
        ssrElement("div", children =
          ssrElement("p", children = "Static content") &
          ctx.ssrSuspense(
            fallback = "<p>Still loading...</p>",
            content = proc(): string = "<p>Async content</p>",
            boundaryId = "timeout-1",
          )
        )
      , timeoutMs = 1000.0)

      # The result contains the shell with fallback content
      check "<p>Static content</p>" in html
      check "<p>Still loading...</p>" in html
      # The fallback is present since boundary was never resolved
      check "<!--!$timeout-1-->" in html

  test "verify_streaming_ttfb":
    ## Time-to-first-byte measured and recorded.
    ## Verifies that the shell callback fires before boundaries resolve,
    ## demonstrating that TTFB only depends on shell rendering time.
    var events: seq[string] = @[]
    var shellTime: float64 = 0.0
    var allTime: float64 = 0.0

    withFakeTime:
      let options = StreamOptions(
        onCompleteShell: proc() =
          shellTime = tc.currentTime
          events.add("shell"),
        onCompleteAll: proc() =
          allTime = tc.currentTime
          events.add("all"),
      )

      let sr = renderToStream(proc(ctx: StreamContext): string =
        ssrElement("div", children =
          ssrElement("header", children = "Fast shell") &
          ctx.ssrSuspense(
            fallback = "<p>Loading data...</p>",
            content = proc(): string = "<p>Data</p>",
            boundaryId = "ttfb-1",
          )
        )
      , options)

      # Shell fires immediately at time 0
      check events == @["shell"]
      check shellTime == 0.0

      # Simulate data arriving after 200ms
      tc.advance(200.0)
      sr.ctx.resolveBoundary("ttfb-1", "<p>Real data loaded</p>")

      check events == @["shell", "all"]
      # allTime is recorded as the time when the boundary resolved
      # (advance moved time to 200ms before resolveBoundary was called)
      check allTime == 200.0

      # TTFB = shellTime = 0, total time = 200ms
      # This proves shell is delivered before async data
      check shellTime < allTime

suite "OutputStream":
  test "string_output_stream":
    let s = newStringOutputStream()
    s.write("hello ")
    s.write("world")
    check s.getOutput() == "hello world"

  test "callback_output_stream":
    var received: seq[string] = @[]
    let s = newCallbackOutputStream(proc(data: string) =
      received.add(data)
    )
    s.write("chunk1")
    s.write("chunk2")
    check received == @["chunk1", "chunk2"]
    # Also accumulates in buffer
    check s.getOutput() == "chunk1chunk2"

  test "no_suspense_completes_immediately":
    ## When there are no Suspense boundaries, both shell and all
    ## complete callbacks fire during renderToStream.
    var shellReceived = false
    var allReceived = false

    let options = StreamOptions(
      onCompleteShell: proc() = shellReceived = true,
      onCompleteAll: proc() = allReceived = true,
    )

    let sr = renderToStream(proc(ctx: StreamContext): string =
      ssrElement("div", children =
        ssrElement("p", children = "Just static content"))
    , options)

    check shellReceived
    check allReceived
    check sr.ctx.allResolved
    let output = sr.getFullOutput()
    check "<p>Just static content</p>" in output
    # No $df script needed when no Suspense boundaries
    check "$df" notin output
