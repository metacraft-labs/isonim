## READY-handshake reader for real daemon subprocesses.
##
## The worker owns duplicated raw descriptors and a POD argument. It never
## accesses a Process, Stream, ref object or managed queue from another thread.
## It drains stderr into a private file; the main thread reads that file through
## its own descriptor. Shutdown stops and joins the worker before releasing its
## argument and before callers close the daemon's Process.
import std/[atomics, osproc, parseutils, strutils, times, os, posix, tempfiles, monotimes]

type
  DrainerArg = object
    sourceFd, outputFd: cint
    stop, closed: Atomic[bool]
    error: Atomic[int]
  DaemonStderrDrainer* = ref object
    p*: Process                       # Main thread only.
    thread: Thread[ptr DrainerArg]
    arg: ptr DrainerArg
    capturePath*: string
    readFd: cint
    buffer: string
    bytesRead: int
    stopped*, workerStopped: bool
    preReadyLines*: seq[string]

proc drainerThreadProc(arg: ptr DrainerArg) {.thread.} =
  defer:
    discard posix.close(arg.sourceFd)
    discard posix.close(arg.outputFd)
    arg.closed.store(true)
  var bytes: array[4096, char]
  while not arg.stop.load():
    var interest = TPollfd(fd: arg.sourceFd, events: POLLIN)
    let ready = posix.poll(addr interest, Tnfds(1), 40)
    if ready < 0:
      if errno == EINTR: continue
      arg.error.store(int(errno))
      return
    if ready == 0: continue
    if (interest.revents and POLLNVAL) != 0:
      arg.error.store(int(EBADF))
      return
    let count = posix.read(arg.sourceFd, addr bytes[0], bytes.len)
    if count < 0:
      if errno == EINTR or errno == EAGAIN: continue
      arg.error.store(int(errno))
      return
    if count == 0: return
    var offset = 0
    while offset < count:
      let written = posix.write(arg.outputFd, addr bytes[offset], count - offset)
      if written < 0:
        if errno == EINTR: continue
        arg.error.store(int(errno))
        return
      if written == 0:
        arg.error.store(int(EIO))
        return
      offset += written

proc startStderrDrainer*(p: Process): DaemonStderrDrainer =
  # osproc leaves the parent pipe handles inheritable; later producer children
  # must not retain them and keep unrelated reader lifetimes open.
  for handle in [p.inputHandle, p.outputHandle, p.errorHandle]:
    if fcntl(cint(handle), F_SETFD, FD_CLOEXEC) < 0:
      raiseOSError(osLastError())
  let source = posix.dup(cint(p.errorHandle))
  if source < 0: raiseOSError(osLastError())
  var output, reader: cint = -1
  var path = ""
  var arg: ptr DrainerArg
  try:
    if fcntl(source, F_SETFD, FD_CLOEXEC) < 0: raiseOSError(osLastError())
    let flags = fcntl(source, F_GETFL)
    if flags < 0 or fcntl(source, F_SETFL, flags or O_NONBLOCK) < 0:
      raiseOSError(osLastError())
    let temporary = createTempFile("isonim-stderr-", ".log")
    path = temporary.path
    temporary.cfile.close()
    output = posix.open(path.cstring, O_WRONLY or O_APPEND)
    reader = posix.open(path.cstring, O_RDONLY)
    if output < 0 or reader < 0: raiseOSError(osLastError())
    for fd in [output, reader]:
      if fcntl(fd, F_SETFD, FD_CLOEXEC) < 0: raiseOSError(osLastError())
    arg = cast[ptr DrainerArg](allocShared0(sizeof(DrainerArg)))
    arg.sourceFd = source
    arg.outputFd = output
    result = DaemonStderrDrainer(p: p, arg: arg, capturePath: path,
      readFd: reader)
    createThread(result.thread, drainerThreadProc, arg)
  except:
    discard posix.close(source)
    if output >= 0: discard posix.close(output)
    if reader >= 0: discard posix.close(reader)
    if arg != nil: deallocShared(arg)
    if path.len > 0: removeFile(path)
    raise

proc popLine(d: DaemonStderrDrainer): tuple[ok: bool; line: string; closed: bool] =
  if d.arg == nil: return (false, "", true)
  let failure = d.arg.error.load()
  if failure != 0:
    raise newException(IOError, "stderr reader failed: " & $failure)
  # Consume buffered lines first; a flood cannot add 4KiB per short line.
  var count = 0
  var newline = d.buffer.find('\n')
  if newline < 0:
    var bytes: array[4096, char]
    count = posix.read(d.readFd, addr bytes[0], bytes.len)
    if count < 0: raiseOSError(osLastError())
    if count > 0:
      d.bytesRead += count
      let start = d.buffer.len
      d.buffer.setLen(start + count)
      copyMem(addr d.buffer[start], addr bytes[0], count)
    newline = d.buffer.find('\n')
  if newline >= 0:
    var line = d.buffer[0 ..< newline]
    if line.endsWith("\r"): line.setLen(line.len - 1)
    d.buffer = d.buffer[newline + 1 .. ^1]
    return (true, line, false)
  let ended = d.arg.closed.load() and count == 0
  if ended and d.buffer.len > 0:
    let line = d.buffer
    d.buffer = ""
    return (true, line, false)
  (false, "", ended)

proc parseReadyPort*(line: string): int =
  let text = line.strip()
  if not text.startsWith("READY "): return -1
  let tail = text[6 .. ^1].strip()
  if tail.len == 0 or tail.len > 5: return -1
  for ch in tail:
    if ch notin {'0' .. '9'}: return -1
  var port: int
  if parseutils.parseInt(tail, port, 0) == tail.len and port in 1 .. 65535:
    return port
  -1

proc stopWorker(d: DaemonStderrDrainer) =
  if d.workerStopped: return
  d.arg.stop.store(true)
  joinThread(d.thread)
  d.workerStopped = true

const DiagnosticByteLimit = 1024 * 1024

proc diagnostic(d: DaemonStderrDrainer; label: string): string =
  result = "\n--- daemon stderr (" & label & ") ---\n"
  for line in d.preReadyLines:
    let available = DiagnosticByteLimit - result.len
    if available <= 0:
      result.add "\n[stderr diagnostic truncated at 1MiB]\n"
      return
    if line.len + 1 > available:
      result.add line[0 ..< available]
      result.add "\n[stderr diagnostic truncated at 1MiB]\n"
      return
    result.add line & "\n"

proc waitForReady*(d: DaemonStderrDrainer; timeoutSecs: float = 15.0): int =
  let deadline = epochTime() + timeoutSecs
  while epochTime() < deadline:
    let item = popLine(d)
    if item.ok:
      let port = parseReadyPort(item.line)
      if port >= 0: return port
      d.preReadyLines.add item.line
      continue
    if item.closed:
      let dump = diagnostic(d, "pre-exit")
      raise newException(IOError,
        "daemon exited before printing READY <port> on stderr" & dump)
    sleep(20)
  try: discard kill(d.p.processID.Pid, SIGKILL)
  except OSError: discard
  # Freeze the captured file before draining diagnostics. A descendant that
  # retains stderr and continuously writes cannot extend this deadline.
  stopWorker(d)
  let readStart = d.bytesRead
  var diagnosticBytes = 0
  while diagnosticBytes < DiagnosticByteLimit and d.bytesRead - readStart < DiagnosticByteLimit:
    let item = popLine(d)
    if not item.ok:
      if item.closed: break
      continue
    d.preReadyLines.add item.line
    diagnosticBytes += item.line.len + 1
  var dump = diagnostic(d, "pre-timeout")
  if diagnosticBytes >= DiagnosticByteLimit or d.bytesRead - readStart >= DiagnosticByteLimit:
    dump.add "\n[remaining captured stderr omitted from bounded timeout diagnostic]\n"
  raise newException(IOError,
    "daemon failed to print READY <port> on stderr within " &
    $timeoutSecs & "s" & dump)

proc shutdown*(d: DaemonStderrDrainer) =
  if d == nil or d.stopped: return
  # Normal EOF drains every byte before stop. A surviving writer is bounded;
  # stopping is cancellation of that reader, not a claim of complete EOF.
  if not d.workerStopped and not d.p.running():
    let deadline = getMonoTime() + initDuration(milliseconds = 200)
    while not d.arg.closed.load() and getMonoTime() < deadline: sleep(5)
  stopWorker(d)
  let failure = d.arg.error.load()
  deallocShared(d.arg)
  d.arg = nil
  discard posix.close(d.readFd)
  d.readFd = -1
  d.stopped = true
  removeFile(d.capturePath)
  if failure != 0:
    raise newException(IOError, "stderr reader failed: " & $failure)

proc closeAfterDrainer*(p: Process; d: DaemonStderrDrainer) =
  ## Reclaim both resources even if reader I/O failed, preserving the first
  ## cleanup failure instead of leaking the Process or hiding that failure.
  var failure: ref CatchableError
  try: d.shutdown()
  except CatchableError as error: failure = error
  try: p.close()
  except CatchableError as error:
    if failure == nil: failure = error
  if failure != nil: raise failure

template retainCleanupFailure*(failure: var ref CatchableError; action: untyped) =
  try: action
  except CatchableError as error:
    if failure == nil: failure = error
    else: stderr.writeLine("additional fixture cleanup failure: " & error.msg)
