## isonim/server/render_stream.nim
##
## Renders IsoNim components directly to a FastStreams OutputStream
## without intermediate string allocation.
##
## The `renderComponentToStream` macro uses the `uiStreamImpl` proc to emit
## `stream.write()` calls directly — no string concatenation, no intermediate
## string allocation. Each HTML fragment is written to the stream as it is
## generated at compile time.

import faststreams/outputs as fsOutputs
import ../dsl/ui

proc renderToStream*(output: fsOutputs.OutputStream, htmlContent: string) =
  ## Write pre-rendered HTML content to the output stream.
  ## This is the simplest integration -- takes an already-built string
  ## and writes it to the stream.
  fsOutputs.write(output, htmlContent)

macro renderComponentToStream*(output: untyped, body: untyped): untyped =
  ## Render a ui DSL block directly to an OutputStream.
  ## Uses the streaming SSR codegen — no intermediate string allocation.
  ## Each HTML fragment is written via stream.write() as it is generated.
  result = uiStreamImpl(output, body)
