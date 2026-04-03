## test_faststreams_ssr.nim
##
## Tests for rendering SSR output to faststreams OutputStreams.
## Compile with: nim c -r -d:useFaststreams -d:isServer tests/test_faststreams_ssr.nim

import unittest
import std/[strutils, tables]
import faststreams/outputs as fsOutputs
import isonim/ssr/stream
import isonim/ssr/renderer
import isonim/ssr/streaming
import isonim/ssr/markers

suite "renderToOutputStream":
  test "renders_html_to_memory_output":
    ## renderToOutputStream writes HTML to a faststreams memoryOutput.
    let handle = fsOutputs.memoryOutput()
    renderToOutputStream(handle.s,
      proc(): string = "<div><h1>Hello</h1></div>",
      hydration = false)
    let output = fsOutputs.getOutput(handle.s, string)
    check output == "<div><h1>Hello</h1></div>"

  test "matches_render_to_string":
    ## renderToOutputStream produces the same output as renderToString.
    let fn = proc(): string =
      ssrElement("div", children =
        ssrElement("h1", children = "Title") &
        ssrElement("p", children = "Body"))

    let stringResult = renderToString(fn)

    let handle = fsOutputs.memoryOutput()
    renderToOutputStream(handle.s, fn, hydration = false)
    let streamResult = fsOutputs.getOutput(handle.s, string)

    check streamResult == stringResult

  test "appends_hydration_script_when_enabled":
    ## renderToOutputStream appends the hydration script when hydration=true.
    let handle = fsOutputs.memoryOutput()
    renderToOutputStream(handle.s,
      proc(): string = "<div>App</div>",
      hydration = true)
    let output = fsOutputs.getOutput(handle.s, string)
    check "<div>App</div>" in output
    check "window._$HY" in output
    check "<!--xs-->" in output

  test "no_hydration_script_when_disabled":
    ## renderToOutputStream omits hydration script when hydration=false.
    let handle = fsOutputs.memoryOutput()
    renderToOutputStream(handle.s,
      proc(): string = "<div>App</div>",
      hydration = false)
    let output = fsOutputs.getOutput(handle.s, string)
    check output == "<div>App</div>"
    check "window._$HY" notin output

  test "hydration_script_includes_nonce":
    ## renderToOutputStream includes nonce attribute when provided.
    let handle = fsOutputs.memoryOutput()
    renderToOutputStream(handle.s,
      proc(): string = "<div>App</div>",
      hydration = true,
      nonce = "abc123")
    let output = fsOutputs.getOutput(handle.s, string)
    check "nonce=\"abc123\"" in output

  test "large_output_works":
    ## renderToOutputStream handles large HTML output.
    let handle = fsOutputs.memoryOutput()
    let bigContent = 'x'.repeat(128 * 1024)
    renderToOutputStream(handle.s,
      proc(): string = "<div>" & bigContent & "</div>",
      hydration = false)
    let output = fsOutputs.getOutput(handle.s, string)
    check output == "<div>" & bigContent & "</div>"

suite "wrapFastStream":
  test "wraps_external_stream":
    ## wrapFastStream creates an isonim OutputStream backed by an external
    ## faststreams OutputStream.
    let handle = fsOutputs.memoryOutput()
    let wrapped = wrapFastStream(handle.s)
    wrapped.write("hello ")
    wrapped.write("world")
    wrapped.flush()
    let output = fsOutputs.getOutput(handle.s, string)
    check output == "hello world"

  test "wrapped_stream_used_in_streaming_ssr":
    ## A wrapped faststreams OutputStream works with the streaming SSR pipeline.
    let handle = fsOutputs.memoryOutput()
    let wrapped = wrapFastStream(handle.s)

    var shellReceived = false
    var allReceived = false

    let options = StreamOptions(
      onCompleteShell: proc() = shellReceived = true,
      onCompleteAll: proc() = allReceived = true,
    )

    # Manually create a stream context with the wrapped output
    let sr = renderToStream(proc(ctx: StreamContext): string =
      ctx.output = wrapped
      ssrElement("div", children =
        ctx.ssrSuspense(
          fallback = "<p>Loading...</p>",
          content = proc(): string = "<p>Content</p>",
          boundaryId = "wrap-1",
        )
      )
    , options)

    check shellReceived
    sr.ctx.resolveBoundary("wrap-1", "<p>Resolved via wrapped stream</p>")
    check allReceived

    let fullOutput = sr.getFullOutput()
    check "<template id=\"wrap-1\"><p>Resolved via wrapped stream</p></template>" in fullOutput
    check "<script>$df(\"wrap-1\")</script>" in fullOutput

suite "renderToStream with faststreams OutputStream":
  test "shell_emitted_to_external_stream":
    ## renderToStream with a faststreams OutputStream emits the shell
    ## directly to the provided stream.
    let handle = fsOutputs.memoryOutput()

    var shellReceived = false
    var allReceived = false
    let options = StreamOptions(
      onCompleteShell: proc() = shellReceived = true,
      onCompleteAll: proc() = allReceived = true,
    )

    let sr = renderToStream(proc(ctx: StreamContext): string =
      ssrElement("div", children =
        ssrElement("h1", children = "Streamed") &
        ctx.ssrSuspense(
          fallback = "<p>Loading...</p>",
          content = proc(): string = "<p>Data</p>",
          boundaryId = "fs-1",
        )
      )
    , handle.s, options)

    check shellReceived
    check not allReceived

    # Shell should be in the faststreams output
    let shellOutput = fsOutputs.getOutput(handle.s, string)
    check "<h1>Streamed</h1>" in shellOutput
    check "pl-fs-1" in shellOutput
    check "$df" in shellOutput

  test "boundary_resolution_writes_to_external_stream":
    ## Resolving a boundary writes replacement chunks to the faststreams stream.
    let handle = fsOutputs.memoryOutput()

    var allReceived = false
    let options = StreamOptions(
      onCompleteAll: proc() = allReceived = true,
    )

    let sr = renderToStream(proc(ctx: StreamContext): string =
      ssrElement("div", children =
        ctx.ssrSuspense(
          fallback = "<p>Loading...</p>",
          content = proc(): string = "<p>Content</p>",
          boundaryId = "fs-resolve",
        )
      )
    , handle.s, options)

    sr.ctx.resolveBoundary("fs-resolve", "<p>Resolved!</p>")
    check allReceived

    let fullOutput = sr.getFullOutput()
    check "<template id=\"fs-resolve\"><p>Resolved!</p></template>" in fullOutput
    check "<script>$df(\"fs-resolve\")</script>" in fullOutput

  test "no_suspense_completes_immediately":
    ## When there are no Suspense boundaries, both callbacks fire during render.
    let handle = fsOutputs.memoryOutput()

    var shellReceived = false
    var allReceived = false
    let options = StreamOptions(
      onCompleteShell: proc() = shellReceived = true,
      onCompleteAll: proc() = allReceived = true,
    )

    let sr = renderToStream(proc(ctx: StreamContext): string =
      ssrElement("div", children =
        ssrElement("p", children = "Static content"))
    , handle.s, options)

    check shellReceived
    check allReceived
    check sr.ctx.allResolved

    let output = fsOutputs.getOutput(handle.s, string)
    check "<p>Static content</p>" in output
    check "$df" notin output

  test "multiple_boundaries_resolve_to_external_stream":
    ## Multiple Suspense boundaries each write their replacement to the stream.
    let handle = fsOutputs.memoryOutput()

    var allReceived = false
    let options = StreamOptions(
      onCompleteAll: proc() = allReceived = true,
    )

    let sr = renderToStream(proc(ctx: StreamContext): string =
      ssrElement("div", children =
        ctx.ssrSuspense(
          fallback = "<p>Loading A...</p>",
          content = proc(): string = "<p>A</p>",
          boundaryId = "a",
        ) &
        ctx.ssrSuspense(
          fallback = "<p>Loading B...</p>",
          content = proc(): string = "<p>B</p>",
          boundaryId = "b",
        )
      )
    , handle.s, options)

    check not allReceived
    sr.ctx.resolveBoundary("b", "<p>Resolved B</p>")
    check not allReceived
    sr.ctx.resolveBoundary("a", "<p>Resolved A</p>")
    check allReceived

    let fullOutput = sr.getFullOutput()
    check "<template id=\"a\"><p>Resolved A</p></template>" in fullOutput
    check "<template id=\"b\"><p>Resolved B</p></template>" in fullOutput
