## Private CLI acceptance cluster. Source draft: Linux owner controls pending;
## complete Darwin descendant ownership is not implemented or accepted.
## Reuses the qualified PGv8 foreground/private-UDS/retained-wait contract.
import std/[json, monotimes, net, options, os, osproc, oserrors, streams, strtabs, strutils,
            tempfiles, times, posix]

when defined(linux):
  proc prctl(option: cint): cint {.importc, varargs, header: "<sys/prctl.h>".}

type OwnedChild* = ref object
  process: Process
  pidfd: cint
  reaped: bool

type OwnedCliPgFixture* = ref object
  root*, dataDir*, socket*: string
  repoRoot: string
  port*: int
  composePort: int
  compose, down: OwnedChild
  composePid, downPid: int
  rootBirth, composeBirth: string
  stopped, cleanupSucceeded: bool

proc allocateOwnedPorts*(count: int): seq[int] =
  var sockets: seq[Socket]
  try:
    for _ in 0 ..< count:
      let socket = newSocket()
      socket.bindAddr(Port(0), "127.0.0.1")
      sockets.add socket
      result.add int(socket.getLocalAddr()[1])
  finally:
    for socket in sockets: socket.close()

when defined(linux):
  {.emit: """
#include <sys/pidfd.h>
#include <sys/wait.h>
#include <unistd.h>
#include <errno.h>
static int pg_owned_child_fd(int pid) {
  int fd = pidfd_open(pid, 0);
  if (fd < 0) return -1;
  siginfo_t info = {0};
  if (waitid(P_PIDFD, fd, &info, WEXITED | WNOHANG | WNOWAIT) < 0) {
    int saved = errno; close(fd); errno = saved; return -1;
  }
  return fd;
}
static int pg_owned_child_exited(int fd) {
  siginfo_t info = {0};
  if (waitid(P_PIDFD, fd, &info, WEXITED | WNOHANG | WNOWAIT) < 0) return -1;
  return info.si_pid != 0;
}
static int pg_owned_signal(int fd, int signal_number) {
  return pidfd_send_signal(fd, signal_number, NULL, 0);
}
""".}
  proc ownedChildFd(pid: cint): cint {.importc: "pg_owned_child_fd", nodecl.}
  proc ownedChildExited(fd: cint): cint {.importc: "pg_owned_child_exited", nodecl.}
  proc ownedSignal(fd, signalNumber: cint): cint {.importc: "pg_owned_signal", nodecl.}

proc startOwnedChild*(executable: string; workingDir = "";
    args: seq[string] = @[]; env: StringTableRef = nil;
    options: set[ProcessOption] = {poStdErrToStdOut}): OwnedChild =
  let process = startProcess(executable, workingDir = workingDir,
    args = args, env = env, options = options)
  # No status probe, wait, helper spawn, or diagnostic occurs between spawn
  # and acquiring the original child's pidfd plus nonreaping wait authority.
  let fd = ownedChildFd(process.processID.cint)
  if fd < 0:
    # No new spawn or PID signal is allowed after capture failure. Keep actual
    # parent wait authority until the original child is naturally reaped; the
    # outer owner can recover a stuck root. Never reopen a late numeric PID.
    let failure = newException(IOError, "Immediate child pidfd capture failed")
    try: discard process.waitForExit()
    finally: process.close()
    raise failure
  OwnedChild(process: process, pidfd: fd)

proc borrowedProcessForDrainer*(child: OwnedChild): Process =
  ## Main-thread view only. The existing stderr drainer duplicates descriptors;
  ## it must join before OwnedChild closes Process descriptors. The owner
  ## performs its actual child wait before that drainer join and close.
  child.process

proc processID*(child: OwnedChild): int = child.process.processID
proc outputStream*(child: OwnedChild): Stream = child.process.outputStream
proc running*(child: OwnedChild): bool =
  result = child.process.running()
  if not result: child.reaped = true
proc waitForExit*(child: OwnedChild): int =
  result = child.process.waitForExit()
  child.reaped = true
proc close*(child: OwnedChild) =
  if not child.reaped: raise newException(IOError, "Refuse closing live owned child")
  let fd = child.pidfd
  child.pidfd = -1
  try: child.process.close()
  finally:
    if fd >= 0: discard posix.close(fd)

proc signalOwnedChild*(child: OwnedChild; signalNumber: cint) =
  if child.reaped or child.pidfd < 0:
    raise newException(IOError, "Original child already reaped; no signal")
  if ownedChildExited(child.pidfd) < 0:
    raise newException(IOError, "Original held child wait authority lost")
  if ownedSignal(child.pidfd, signalNumber) != 0 and osLastError() != OSErrorCode(ESRCH):
    raiseOSError(osLastError())

proc drainDirectChild*(child: OwnedChild): int =
  ## Always use the fd captured at original spawn, never reopen a numeric PID.
  if child.reaped: return child.waitForExit()
  if child.pidfd < 0: raise newException(IOError, "Missing original pidfd")
  var exited = ownedChildExited(child.pidfd)
  if exited < 0: raise newException(IOError, "Original held pidfd wait failed")
  if exited == 0:
    signalOwnedChild(child, SIGTERM)
    let deadline = getMonoTime() + initDuration(milliseconds = 5000)
    while exited == 0 and getMonoTime() < deadline:
      sleep(50)
      exited = ownedChildExited(child.pidfd)
    if exited < 0: raise newException(IOError, "Original held pidfd wait failed")
    if exited == 0: signalOwnedChild(child, SIGKILL)
  # Real wait can block on an uninterruptible child. Actual parent/controller
  # and allocation remain retained; no timeout receipt pretends to reap it.
  child.waitForExit()

proc runOwnedCapture*(executable, workingDir: string; args: seq[string];
                      env: StringTableRef = nil; deadline = none(MonoTime)):
                      tuple[output: string, code: int] =
  var child: OwnedChild
  var reaped = false
  var first: ref Exception
  var captureFd = -1.cint
  try:
    child = startOwnedChild(executable, workingDir = workingDir, args = args,
      env = env, options = {poUsePath, poStdErrToStdOut})
    # Never mix Stream buffering with raw reads from this exclusive pipe.
    let fd = child.process.outputHandle.cint
    let flags = fcntl(fd, F_GETFL)
    if flags < 0 or fcntl(fd, F_SETFL, flags or O_NONBLOCK) < 0:
      raiseOSError(osLastError())
    captureFd = fd # failure-tail reads only after verified O_NONBLOCK
    var eof = false
    var buffer: array[16384, char]
    while true:
      if deadline.isSome and getMonoTime() >= deadline.get():
        raise newException(IOError, "Owned capture exceeded original absolute deadline")
      # A finite batch ensures a continuously writing child cannot starve the
      # deadline/status check. No bytes are discarded or success truncated.
      if not eof:
        for _ in 0 ..< 16:
          let count = posix.read(fd, addr buffer[0], buffer.len)
          if count > 0:
            let offset = result.output.len
            result.output.setLen(offset + count)
            copyMem(addr result.output[offset], addr buffer[0], count)
          elif count == 0:
            eof = true
            break
          else:
            let error = osLastError()
            if error == OSErrorCode(EINTR): continue
            if error == OSErrorCode(EAGAIN) or error == OSErrorCode(EWOULDBLOCK): break
            raiseOSError(error)
      let exited = ownedChildExited(child.pidfd)
      if exited < 0: raise newException(IOError, "Original capture wait authority lost")
      if eof and exited != 0: break
      var waitMs = 50
      if deadline.isSome:
        let remaining = (deadline.get() - getMonoTime()).inMilliseconds
        if remaining <= 0: continue
        waitMs = min(waitMs, int(remaining))
      var event = TPollfd(fd: (if eof: -1.cint else: fd), events: POLLIN)
      if posix.poll(addr event, 1, waitMs.cint) < 0 and osLastError() != OSErrorCode(EINTR):
        raiseOSError(osLastError())
    # EOF and nonreaping pidfd exit are both established before actual wait.
    result.code = child.waitForExit()
    reaped = true
  except Exception:
    first = getCurrentException()
  finally:
    if child != nil:
      try:
        if not reaped:
          result.code = drainDirectChild(child)
          reaped = true
      except Exception:
        if first == nil: first = getCurrentException()
      if first != nil:
        # Retain the observed byte prefix on failures too. After actual direct
        # child drain, collect only a finite nonblocking batch: a descendant
        # may still own the pipe, so this is NEVER a complete-output claim.
        try:
          if captureFd >= 0:
            var tail: array[16384, char]
            for _ in 0 ..< 16:
              let count = posix.read(captureFd, addr tail[0], tail.len)
              if count > 0:
                let offset = result.output.len
                result.output.setLen(offset + count)
                copyMem(addr result.output[offset], addr tail[0], count)
              elif count == 0: break
              else:
                let error = osLastError()
                if error == OSErrorCode(EINTR): continue
                if error == OSErrorCode(EAGAIN) or error == OSErrorCode(EWOULDBLOCK): break
                raiseOSError(error)
        except Exception: discard # preserve the original functional error
        try:
          stderr.write("owned capture failed; observedBytes=" & $result.output.len &
            " complete=false\n")
          stderr.write(result.output) # raw bytes, including NULs; no sanitizing
          stderr.flushFile()
        except Exception: discard # diagnostics cannot replace/skip cleanup
      # Do not release a live process handle merely because drain failed.
      if reaped:
        try: child.close()
        except Exception:
          if first == nil: first = getCurrentException()
  if first != nil: raise first

proc queryProcesses(fixture: OwnedCliPgFixture; args: seq[string]): JsonNode =
  let python = findExe("python3")
  if python.len == 0: raise newException(IOError, "Declared Python is required")
  let response = runOwnedCapture(python, fixture.repoRoot,
    @["-B", fixture.repoRoot / "tests/helpers/owned_cli_pg_processes.py"] & args)
  if response.code != 0:
    raise newException(IOError, "Owned native process query failed: " & response.output)
  parseJson(response.output)

proc newOwnedCliPgFixture*(repoRoot: string; port, composePort: int): OwnedCliPgFixture =
  when defined(linux):
    var enabled: cint
    if prctl(36, 1.culong, 0.culong, 0.culong, 0.culong) != 0 or
        prctl(37, addr enabled, 0.culong, 0.culong, 0.culong) != 0 or enabled != 1:
      raise newException(IOError, "Actual test-root child subreaping is required")
  else:
    raise newException(IOError, "Complete Darwin adopted-owner fixture is not implemented; no acceptance")
  result = OwnedCliPgFixture(repoRoot: repoRoot, port: port, composePort: composePort)
  result.rootBirth = result.queryProcesses(@["identity", $getCurrentProcessId()])["birth"].getStr()
  result.root = createTempDir("isonim-review-e2e-pc-", "")
  result.dataDir = result.root / "postgres"
  result.socket = result.root / "pc.sock"
  createDir(result.dataDir)

proc childEnvironment*(fixture: OwnedCliPgFixture): StringTableRef =
  result = newStringTable(modeCaseSensitive)
  for pair in envPairs(): result[pair.key] = pair.value
  # Bind every private CLI/compose descendant to this fixture. A service
  # profile can otherwise override libpq hostaddr despite explicit -h flags.
  result.del("PGSERVICE")
  result.del("PGSERVICEFILE")
  result["PGHOST"] = "127.0.0.1"
  result["PGHOSTADDR"] = "127.0.0.1"
  result["PGPORT"] = $fixture.port
  result["ISONIM_REVIEW_DB"] = "postgresql://127.0.0.1:" & $fixture.port &
    "/isonim_design_review?hostaddr=127.0.0.1"
  result["ISONIM_REVIEW_PGHOST"] = "127.0.0.1"
  result["ISONIM_REVIEW_PGDATA"] = fixture.dataDir
  result["ISONIM_REVIEW_PGPORT"] = $fixture.port
  result["ISONIM_REVIEW_MIGRATIONS_DIR"] = fixture.repoRoot / "db/migrations"

proc waitOwnedExit(child: OwnedChild; timeoutMs: int): int =
  let deadline = getMonoTime() + initDuration(milliseconds = timeoutMs)
  while child.running() and getMonoTime() < deadline: sleep(50)
  if child.running():
    echo "owned child wait pid=", child.processID, " live-retained=true"
    flushFile(stdout)
    return -1
  result = child.waitForExit()
  try:
    echo "owned child wait pid=", child.processID, " reaped=true exit=", result
    flushFile(stdout)
  except Exception: discard

proc start*(fixture: OwnedCliPgFixture) =
  let executable = findExe("process-compose")
  if executable.len == 0: raise newException(IOError, "Declared process-compose is required")
  fixture.compose = startOwnedChild(executable, workingDir = fixture.repoRoot,
    args = @["up", "--config", fixture.repoRoot / "process-compose.yaml",
      "--port", $fixture.composePort, "--unix-socket", fixture.socket, "--tui=false"],
    env = fixture.childEnvironment(), options = {poUsePath, poParentStreams})
  fixture.composePid = fixture.compose.processID
  let identity = fixture.queryProcesses(@["identity", $fixture.composePid])
  if identity["ppid"].getInt() != getCurrentProcessId():
    raise newException(IOError, "Orchestrator is not the actual retained child")
  fixture.composeBirth = identity["birth"].getStr()
  echo "owned process-compose pid=", fixture.composePid,
    " birth=", fixture.composeBirth, " sid=", identity["sid"].getInt()
  flushFile(stdout)

proc requireOwnPostgres*(fixture: OwnedCliPgFixture) =
  let lines = readFile(fixture.dataDir / "postmaster.pid").splitLines()
  if lines.len < 4 or lines[1] != fixture.dataDir or parseInt(lines[3]) != fixture.port:
    raise newException(IOError, "Readiness does not bind to private PostgreSQL data and port")
  let pid = parseInt(lines[0])
  var row = fixture.queryProcesses(@["identity", $pid])
  let args = row["argv"]
  if args.len < 3 or args[1].getStr() != "-D" or args[2].getStr() != fixture.dataDir:
    raise newException(IOError, "PostgreSQL image does not use private data")
  var ancestor = row["ppid"].getInt()
  var found = false
  for _ in 0 ..< 64:
    if ancestor == fixture.composePid:
      let parent = fixture.queryProcesses(@["identity", $ancestor])
      found = parent["birth"].getStr() == fixture.composeBirth
      break
    if ancestor <= 1: break
    row = fixture.queryProcesses(@["identity", $ancestor])
    ancestor = row["ppid"].getInt()
  if not found: raise newException(IOError, "PostgreSQL is outside retained orchestrator ancestry")

proc orphanProcesses*(fixture: OwnedCliPgFixture): int =
  ## Called only after the daemon's actual retained wait, while PC remains live.
  ## Adoption into the verified Linux subreaper covers child-created sessions.
  let report = fixture.queryProcesses(@["orphans", $getCurrentProcessId(),
     $fixture.composePid, fixture.rootBirth, fixture.composeBirth])
  report["orphans"].len

proc stop*(fixture: OwnedCliPgFixture): bool =
  if fixture.stopped: return fixture.cleanupSucceeded
  var first: ref Exception
  var downCode, composeCode, postgresCode = -1
  var downReaped, composeReaped, adoptedDrained = false
  template attempt(body: untyped) =
    try: body
    except Exception:
      if first == nil: first = getCurrentException()

  # Every step has its own error boundary. A broken CLI, stream, status query,
  # or diagnostic must not skip cleanup of another already-owned child.
  if fixture.compose != nil:
    attempt:
      fixture.down = startOwnedChild(findExe("process-compose"), workingDir = fixture.repoRoot,
        args = @["down", "--unix-socket", fixture.socket],
        options = {poUsePath, poParentStreams})
      fixture.downPid = fixture.down.processID
      downCode = waitOwnedExit(fixture.down, 35_000)
      downReaped = downCode != -1
      if downCode != 0: raise newException(IOError, "Original private down failed or exceeded35s")
    if fixture.down != nil and not downReaped:
      attempt:
        discard drainDirectChild(fixture.down)
        downReaped = true
    if downReaped:
      attempt: fixture.down.close()

    attempt:
      composeCode = waitOwnedExit(fixture.compose, 35_000)
      composeReaped = composeCode != -1
      if composeCode != 0: raise newException(IOError, "Original PC exit failed or exceeded35s")

    if not composeReaped:
      # Authenticate the private live PG process against PGDATA/port and the
      # retained PC birth BEFORE invoking the genuine private pg_ctl recovery.
      # Failure refuses recovery; it never signals a name or arbitrary PID.
      attempt:
        fixture.requireOwnPostgres()
        let recovery = startOwnedChild(findExe("pg_ctl"), workingDir = fixture.repoRoot,
          args = @["-D", fixture.dataDir, "-m", "fast", "-w", "-t", "35", "stop"],
          options = {poUsePath, poParentStreams})
        var recoveryReaped = false
        try:
          let code = waitOwnedExit(recovery, 35_000)
          recoveryReaped = code != -1
          if code != 0: raise newException(IOError, "Private pg_ctl recovery failed")
        finally:
          if not recoveryReaped:
            discard drainDirectChild(recovery)
            recoveryReaped = true
          if recoveryReaped: recovery.close()
      attempt:
        discard drainDirectChild(fixture.compose)
        composeReaped = true
    if composeReaped:
      attempt: fixture.compose.close()

  # The root is an actual Linux subreaper. The helper may only signal current
  # descendants using held pidfds and returns exact direct-child identities.
  # Actual waitpid remains here in their real parent, not in the query helper.
  attempt:
    let deadline = getMonoTime() + initDuration(milliseconds = 5000)
    let terminalDeadline = deadline + initDuration(milliseconds = 5000)
    var empty = false
    while not empty and getMonoTime() < terminalDeadline:
      let recoverySignal = if getMonoTime() < deadline: SIGTERM else: SIGKILL
      let owned = fixture.queryProcesses(@["recover", $getCurrentProcessId(),
        fixture.rootBirth, $recoverySignal])
      let rows = owned["children"]
      if rows.len == 0 and owned["ownedCount"].getInt() == 0:
        empty = true
        break
      for row in rows:
        var status: cint
        let pid = row["pid"].getInt().Pid
        let waited = waitpid(pid, status, WNOHANG)
        if waited == pid:
          # Reaping is already complete before any potentially failing report.
          try:
            echo "adopted owned child wait pid=", pid, " status=", status
            flushFile(stdout)
          except Exception: discard
        elif waited < 0:
          raise newException(IOError, "Actual adopted-child wait refused")
      sleep(50)
    if not empty:
      raise newException(IOError, "Inner adopted recovery incomplete; outer actual subreaper must recover and reap")
    adoptedDrained = true
    # Outer controller retains its actual parent/adopted-wait authority if a
    # query fails or bounded inner recovery is incomplete. No release receipt.

  attempt:
    let status = runOwnedCapture(findExe("pg_ctl"), fixture.repoRoot,
      @["-D", fixture.dataDir, "status"])
    postgresCode = status.code
  fixture.stopped = (fixture.compose == nil or composeReaped) and
    (fixture.down == nil or downReaped) and postgresCode == 3 and adoptedDrained
  fixture.cleanupSucceeded = fixture.stopped and downCode == 0 and composeCode == 0 and first == nil
  if not fixture.stopped:
    # Attribution only; failure to write cannot prevent or stand in for drain.
    attempt:
      writeFile(fixture.root / "retained-owner.json", $(%*{
        "directory": fixture.root, "PGDATA": fixture.dataDir,
        "socket": fixture.socket, "composeBirth": fixture.composeBirth,
        "composePid": fixture.composePid, "downPid": fixture.downPid,
        "rootPID": getCurrentProcessId(), "rootBirth": fixture.rootBirth,
        "downReaped": downReaped, "composeReaped": composeReaped,
        "downExit": downCode, "composeExit": composeCode,
        "postgresStatus": postgresCode}))
  if first != nil: raise first
  fixture.cleanupSucceeded
