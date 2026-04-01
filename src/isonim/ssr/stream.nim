## isonim/ssr/stream.nim
##
## OutputStream abstraction for streaming SSR.
##
## Provides three backends:
##   - `newStringOutputStream()` — simple string accumulator (no deps)
##   - `newCallbackOutputStream(cb)` — forwards writes to a callback
##   - `newFastOutputStream()` — backed by nim-faststreams (compile with -d:useFaststreams)
##
## The API is the same for all backends: `write`, `flush`, `getOutput`.

when defined(useFaststreams):
  import faststreams/outputs as fsOutputs

type
  StreamKind = enum
    skString
    skCallback
    skFast

  WriteProc* = proc(data: string)

  OutputStream* = ref object
    case kind: StreamKind
    of skString:
      buffer: string
    of skCallback:
      writeProc: WriteProc
      cbBuffer: string
    of skFast:
      when defined(useFaststreams):
        fastStream: fsOutputs.OutputStream
      else:
        discard
    flushed: bool

proc newStringOutputStream*(): OutputStream =
  ## Creates an OutputStream that collects output into an internal string buffer.
  ## Retrieve the result with getOutput().
  OutputStream(kind: skString, buffer: "", flushed: false)

proc newCallbackOutputStream*(cb: WriteProc): OutputStream =
  ## Creates an OutputStream that forwards all writes to a callback.
  OutputStream(kind: skCallback, writeProc: cb, cbBuffer: "", flushed: false)

when defined(useFaststreams):
  proc newFastOutputStream*(): OutputStream =
    ## Creates an OutputStream backed by nim-faststreams' memory output.
    ## This provides high-performance buffered I/O with zero-copy page
    ## management. The accumulated output can be retrieved with getOutput().
    let handle = fsOutputs.memoryOutput()
    OutputStream(kind: skFast, fastStream: handle.s, flushed: false)

proc write*(s: OutputStream, data: string) =
  ## Writes data to the stream.
  case s.kind
  of skString:
    s.buffer.add data
  of skCallback:
    s.writeProc(data)
    s.cbBuffer.add data
  of skFast:
    when defined(useFaststreams):
      fsOutputs.write(s.fastStream, data)

proc flush*(s: OutputStream) =
  ## Flushes the stream. For faststreams, delegates to its flush.
  ## For callback streams this is a no-op since data is already forwarded.
  ## For string streams, signals that the current buffer content is a complete chunk.
  s.flushed = true
  when defined(useFaststreams):
    if s.kind == skFast:
      fsOutputs.flush(s.fastStream)

proc getOutput*(s: OutputStream): string =
  ## Returns the accumulated output.
  case s.kind
  of skString:
    s.buffer
  of skCallback:
    s.cbBuffer
  of skFast:
    when defined(useFaststreams):
      fsOutputs.getOutput(s.fastStream, string)
    else:
      ""

when defined(useFaststreams):
  proc close*(s: OutputStream) =
    ## Closes the underlying faststreams stream (if applicable).
    ## For non-faststreams backends this is a no-op.
    if s.kind == skFast:
      fsOutputs.close(s.fastStream)
