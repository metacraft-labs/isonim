## isonim/server/render_stream.nim
##
## Renders IsoNim components directly to a FastStreams OutputStream
## without intermediate string allocation for the final output.
##
## The `ui` macro's SSR mode still returns a string internally,
## but these helpers write it directly to the stream without building
## a separate response string. A future optimization will have the
## SSR codegen emit `stream.write()` calls instead of string concatenation.

import std/macros
import faststreams/outputs as fsOutputs
import ../dsl/ui

proc renderToStream*(output: fsOutputs.OutputStream, htmlContent: string) =
  ## Write pre-rendered HTML content to the output stream.
  ## This is the simplest integration -- the ui macro still returns a string,
  ## but we write it to the stream without building a response string.
  fsOutputs.write(output, htmlContent)

macro renderComponentToStream*(output: fsOutputs.OutputStream, body: untyped): untyped =
  ## Render a ui DSL block and write the result to an OutputStream.
  ## Currently this still produces an intermediate string from the ui macro,
  ## then writes it to the stream. A future optimization will have the
  ## SSR codegen write directly to the stream.
  let htmlSym = genSym(nskLet, "html")
  let uiCall = newCall(bindSym"ui", body)
  result = newStmtList(
    newLetStmt(htmlSym, uiCall),
    newCall(bindSym"renderToStream", output, htmlSym)
  )
