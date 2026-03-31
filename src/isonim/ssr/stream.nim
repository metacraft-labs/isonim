## isonim/ssr/stream.nim
##
## Simple OutputStream abstraction for streaming SSR.
## Can later be backed by faststreams without changing the API.

type
  WriteProc* = proc(data: string)

  OutputStream* = ref object
    writeProc: WriteProc
    buffer: string
    flushed: bool

proc newStringOutputStream*(): OutputStream =
  ## Creates an OutputStream that collects output into an internal string buffer.
  ## Retrieve the result with getOutput().
  OutputStream(writeProc: nil, buffer: "", flushed: false)

proc newCallbackOutputStream*(cb: WriteProc): OutputStream =
  ## Creates an OutputStream that forwards all writes to a callback.
  OutputStream(writeProc: cb, buffer: "", flushed: false)

proc write*(s: OutputStream, data: string) =
  ## Writes data to the stream. If a callback is set, calls it immediately.
  ## Otherwise appends to the internal buffer.
  if s.writeProc != nil:
    s.writeProc(data)
  s.buffer.add data

proc flush*(s: OutputStream) =
  ## Marks the stream as flushed. For callback streams this is a no-op
  ## since data is already forwarded. For string streams, signals that
  ## the current buffer content is a complete chunk.
  s.flushed = true

proc getOutput*(s: OutputStream): string =
  ## Returns the accumulated output for a string stream.
  s.buffer
