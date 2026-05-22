## Shared READY-handshake helper for ``isonim-review serve`` test
## fixtures.
##
## Replaces the old ``pickFreePort + curl /health`` TOCTOU pattern.
## The daemon (see ``tools/isonim_review/cmd_serve.nim::runReviewServer``)
## prints ``READY <port>`` to stderr as soon as its listening socket is
## bound and the OS-assigned port (when ``ISONIM_REVIEW_PORT=0``) is
## resolved.  This module:
##
##   1. Lets the caller spawn the daemon with stderr piped (NOT merged
##      with stdout).
##   2. Starts a background thread that reads stderr line-by-line,
##      appends every line into a lock-guarded queue, and keeps
##      draining for the lifetime of the daemon so the stderr pipe
##      never fills up while we wait.
##   3. Provides ``waitForReady`` which pulls lines off the queue
##      until a ``READY <port>`` line arrives, the daemon dies, or a
##      deadline elapses.
##
## Lines arrive in the order the daemon wrote them; the drainer never
## interprets chronicles output beyond newline framing.

import std/[locks, osproc, parseutils, streams, strutils, times, os, posix]

type
  StderrInbox = ref object
    lock*: Lock
    closed*: bool
    queue*: seq[string]

  DrainerArg = object
    p: Process
    inbox: StderrInbox

  DaemonStderrDrainer* = ref object
    p*: Process
    thread*: Thread[ptr DrainerArg]
    arg*: ptr DrainerArg
    inbox*: StderrInbox
    preReadyLines*: seq[string]
      ## Lines observed before the READY signal; included verbatim in
      ## error messages when the handshake fails.

proc drainerThreadProc(arg: ptr DrainerArg) {.thread.} =
  {.gcsafe.}:
    let stream = arg.p.errorStream
    if stream == nil:
      acquire(arg.inbox.lock)
      arg.inbox.closed = true
      release(arg.inbox.lock)
      return
    var line = ""
    while true:
      var ok = false
      try:
        ok = stream.readLine(line)
      except IOError:
        ok = false
      except OSError:
        ok = false
      if not ok:
        acquire(arg.inbox.lock)
        arg.inbox.closed = true
        release(arg.inbox.lock)
        return
      acquire(arg.inbox.lock)
      arg.inbox.queue.add line
      release(arg.inbox.lock)

proc startStderrDrainer*(p: Process): DaemonStderrDrainer =
  ## Spawn the drainer thread bound to ``p.errorStream``.  Caller
  ## must keep the returned object alive for the daemon's lifetime
  ## so the pipe stays drained.
  let inbox = StderrInbox(queue: @[])
  initLock(inbox.lock)
  let arg = cast[ptr DrainerArg](allocShared0(sizeof(DrainerArg)))
  arg.p = p
  arg.inbox = inbox
  result = DaemonStderrDrainer(p: p, arg: arg, inbox: inbox)
  createThread(result.thread, drainerThreadProc, arg)

proc popLine(d: DaemonStderrDrainer): tuple[ok: bool; line: string; closed: bool] =
  acquire(d.inbox.lock)
  defer: release(d.inbox.lock)
  if d.inbox.queue.len > 0:
    let line = d.inbox.queue[0]
    d.inbox.queue.delete(0)
    return (ok: true, line: line, closed: false)
  return (ok: false, line: "", closed: d.inbox.closed)

proc parseReadyPort*(line: string): int =
  ## ``READY <port>`` → port (int).  Returns ``-1`` when the line
  ## doesn't match the expected shape.
  let s = line.strip()
  if not s.startsWith("READY "):
    return -1
  var port: int
  let tail = s[6 .. ^1].strip()
  if parseutils.parseInt(tail, port, 0) > 0 and port >= 0:
    return port
  return -1

proc waitForReady*(d: DaemonStderrDrainer; timeoutSecs: float = 15.0):
    int =
  ## Block until the drainer reports a ``READY <port>`` line, the
  ## daemon exits, or the deadline elapses.  Returns the bound port
  ## on success; raises IOError otherwise.
  let deadline = epochTime() + timeoutSecs
  while epochTime() < deadline:
    let r = popLine(d)
    if r.ok:
      let port = parseReadyPort(r.line)
      if port >= 0:
        return port
      d.preReadyLines.add r.line
      continue
    if not d.p.running() or r.closed:
      # Drain any straggler lines that landed between our last pop
      # and the death notification so the diagnostic is complete.
      while true:
        let r2 = popLine(d)
        if not r2.ok: break
        d.preReadyLines.add r2.line
      var dump = "\n--- daemon stderr (pre-exit) ---\n"
      for line in d.preReadyLines:
        dump.add line & "\n"
      raise newException(IOError,
        "daemon exited before printing READY <port> on stderr" & dump)
    sleep(20)
  # Timed out.
  try: discard kill(d.p.processID.Pid, SIGKILL)
  except: discard
  while true:
    let r2 = popLine(d)
    if not r2.ok: break
    d.preReadyLines.add r2.line
  var dump = "\n--- daemon stderr (pre-timeout) ---\n"
  for line in d.preReadyLines:
    dump.add line & "\n"
  raise newException(IOError,
    "daemon failed to print READY <port> on stderr within " &
    $timeoutSecs & "s" & dump)

proc shutdown*(d: DaemonStderrDrainer) =
  ## Free shared storage.  The drainer thread exits on its own when
  ## the daemon closes stderr; we don't join it (a hung daemon would
  ## block teardown).  ``arg`` and the lock are leaked intentionally
  ## — the test process is about to exit anyway.
  if d == nil: return
  d.arg = nil
