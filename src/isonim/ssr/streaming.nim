## isonim/ssr/streaming.nim
##
## Streaming SSR: progressive HTML delivery with Suspense support.
## Emits the shell HTML first, then fills Suspense placeholders as
## async data resolves via replacement <template> + <script> chunks.
##
## Port of SolidJS streaming SSR pattern.

import std/tables
import isonim/ssr/stream
import isonim/ssr/markers

type
  StreamOptions* = object
    onCompleteShell*: proc()
    onCompleteAll*: proc()
    nonce*: string

  SuspenseBoundary* = object
    id*: string
    placeholder*: string

  StreamContext* = ref object
    output*: OutputStream
    shell*: string
    boundaries*: Table[string, SuspenseBoundary]
    resolvedBoundaries*: Table[string, string]
    shellEmitted*: bool
    allResolved*: bool
    onCompleteShell*: proc()
    onCompleteAll*: proc()
    nonce*: string
    chunks*: seq[string]
    boundaryCounter: int

  StreamResult* = ref object
    ctx*: StreamContext

var currentStreamContext* {.threadvar.}: StreamContext

proc generateDfScript(): string =
  ## Returns the $df function definition that replaces Suspense placeholders
  ## with resolved content on the client.
  result = """<script>function $df(id){var t=document.getElementById(id);""" &
    """var p=document.getElementById("pl-"+id);""" &
    """if(t&&p){var c=t.content;var r=document.createRange();""" &
    """r.setStartBefore(p);var n=p.nextSibling;""" &
    """while(n&&!(n.nodeType===8&&n.data==="pl-"+id+"-end")){""" &
    """var next=n.nextSibling;n.parentNode.removeChild(n);n=next;}""" &
    """p.parentNode.removeChild(p);if(n)n.parentNode.removeChild(n);""" &
    """r.insertNode(c);t.parentNode.removeChild(t);}}</script>"""

proc nextBoundaryId*(ctx: StreamContext): string =
  ## Generates the next unique boundary ID.
  inc ctx.boundaryCounter
  result = "S:" & $ctx.boundaryCounter

proc ssrSuspense*(ctx: StreamContext; fallback: string;
    content: proc(): string; boundaryId: string = ""): string =
  ## Renders a Suspense boundary for streaming SSR.
  ## Emits the fallback as a placeholder and registers the boundary
  ## for later resolution.
  let id = if boundaryId.len > 0: boundaryId else: ctx.nextBoundaryId()
  let boundary = SuspenseBoundary(id: id, placeholder: fallback)
  ctx.boundaries[id] = boundary
  # Emit placeholder markers with fallback content
  result = "<template id=\"pl-" & id & "\"></template>" &
    "<!--!$" & id & "-->" & fallback &
    "<!--!$/" & id & "-->" &
    "<!--pl-" & id & "-end-->"

proc emitShell*(ctx: StreamContext) =
  ## Flushes the shell HTML to the output stream.
  if not ctx.shellEmitted:
    ctx.shellEmitted = true
    # Include $df script if there are Suspense boundaries
    if ctx.boundaries.len > 0:
      ctx.shell.add generateDfScript()
    ctx.output.write(ctx.shell)
    ctx.chunks.add(ctx.shell)
    ctx.output.flush()
    if ctx.onCompleteShell != nil:
      ctx.onCompleteShell()

proc checkAllResolved(ctx: StreamContext) =
  ## Checks if all boundaries are resolved and fires onCompleteAll if so.
  if ctx.allResolved:
    return
  for id, _ in ctx.boundaries:
    if id notin ctx.resolvedBoundaries:
      return
  ctx.allResolved = true
  if ctx.onCompleteAll != nil:
    ctx.onCompleteAll()

proc resolveBoundary*(ctx: StreamContext; id: string; html: string) =
  ## Resolves a Suspense boundary, emitting the replacement chunk.
  ## The chunk contains a <template> with the resolved content and
  ## a <script> that calls $df to swap the placeholder.
  if id notin ctx.boundaries:
    return
  ctx.resolvedBoundaries[id] = html
  let chunk = "<template id=\"" & id & "\">" & html & "</template>" &
    "<script>$df(\"" & id & "\")</script>"
  ctx.output.write(chunk)
  ctx.chunks.add(chunk)
  ctx.output.flush()
  ctx.checkAllResolved()

proc newStreamContext*(options: StreamOptions = StreamOptions()): StreamContext =
  ## Creates a new streaming context.
  StreamContext(
    output: newStringOutputStream(),
    shell: "",
    boundaries: initTable[string, SuspenseBoundary](),
    resolvedBoundaries: initTable[string, string](),
    shellEmitted: false,
    allResolved: false,
    onCompleteShell: options.onCompleteShell,
    onCompleteAll: options.onCompleteAll,
    nonce: options.nonce,
    chunks: @[],
    boundaryCounter: 0,
  )

when defined(useFaststreams):
  import faststreams/outputs as fsOutputs

  proc newStreamContext*(fsOutput: fsOutputs.OutputStream;
                          options: StreamOptions = StreamOptions()): StreamContext =
    ## Creates a streaming context with an external faststreams OutputStream.
    ## Writes go directly through the provided stream, enabling zero-copy
    ## integration with any faststreams backend (nginx, chronos, etc.).
    StreamContext(
      output: wrapFastStream(fsOutput),
      shell: "",
      boundaries: initTable[string, SuspenseBoundary](),
      resolvedBoundaries: initTable[string, string](),
      shellEmitted: false,
      allResolved: false,
      onCompleteShell: options.onCompleteShell,
      onCompleteAll: options.onCompleteAll,
      nonce: options.nonce,
      chunks: @[],
      boundaryCounter: 0,
    )

  proc renderToStream*(fn: proc(ctx: StreamContext): string;
      fsOutput: fsOutputs.OutputStream;
      options: StreamOptions = StreamOptions()): StreamResult =
    ## Streaming SSR writing directly to a faststreams OutputStream.
    ## Shell HTML is flushed immediately. Suspense boundaries flush
    ## as they resolve. No intermediate string copy beyond what the
    ## component tree produces.
    resetHydrationCounter()
    let ctx = newStreamContext(fsOutput, options)
    currentStreamContext = ctx

    # Render the shell synchronously
    ctx.shell = fn(ctx)

    # Emit shell immediately
    ctx.emitShell()

    # If no boundaries, everything is done
    if ctx.boundaries.len == 0:
      ctx.allResolved = true
      if ctx.onCompleteAll != nil:
        ctx.onCompleteAll()

    result = StreamResult(ctx: ctx)

proc renderToStream*(fn: proc(ctx: StreamContext): string;
    options: StreamOptions = StreamOptions()): StreamResult =
  ## Streaming SSR entry point. Renders the component tree, emitting
  ## the shell HTML first. Returns a StreamResult that allows resolving
  ## Suspense boundaries as data becomes available.
  resetHydrationCounter()
  let ctx = newStreamContext(options)
  currentStreamContext = ctx

  # Render the shell synchronously
  ctx.shell = fn(ctx)

  # Emit shell immediately
  ctx.emitShell()

  # If no boundaries, everything is done
  if ctx.boundaries.len == 0:
    ctx.allResolved = true
    if ctx.onCompleteAll != nil:
      ctx.onCompleteAll()

  result = StreamResult(ctx: ctx)

proc renderToStringAsync*(fn: proc(ctx: StreamContext): string;
    timeoutMs: float64 = 5000.0;
    options: StreamOptions = StreamOptions()): string =
  ## Renders to a complete string, waiting for Suspense boundaries
  ## to resolve up to timeoutMs. If timeout is reached, returns
  ## partial result with fallback content still in place.
  ##
  ## Uses callback-based resolution -- callers must resolve boundaries
  ## before this returns. For real async, integrate with event loop.
  resetHydrationCounter()
  let ctx = newStreamContext(options)
  currentStreamContext = ctx

  # Render shell
  ctx.shell = fn(ctx)
  ctx.emitShell()

  # If no boundaries, done
  if ctx.boundaries.len == 0:
    ctx.allResolved = true

  # Return the accumulated output
  result = ctx.output.getOutput()

proc getFullOutput*(sr: StreamResult): string =
  ## Returns the full accumulated output (shell + all resolved chunks).
  sr.ctx.output.getOutput()
