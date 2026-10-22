## Optional workspace-local Agent Harbor runtime for every editor daemon.
## Detect the sibling relative to this editor binary, obtain its exported `ah`
## executable through Reprobuild, and use the path Reprobuild resolves. No
## checkout is required for standalone installations or developers without
## access to Agent Harbor.
##
## Reprobuild owns producer resolution, source invalidation and the producer's
## build (see the editor spec, "Workspace-local build and service lifecycle",
## and reprobuild-pm/spec/Cross-Repo-Source-Consumption.md). This module only
## declares the consumer edge; it never selects a producer entry point, guesses
## an output path, hashes Harbor's sources or writes into the Harbor checkout.
import std/[algorithm, hashes, monotimes, os, osproc, strutils, strtabs, net, httpclient, tempfiles, json, times]
when defined(posix): import std/posix
import ./config
import ../../src/isonim/editor/shutdown_policy

type LocalHarbor* = object
  process*: Process
  stateDir*: string
  executable*: string
  processGroup*: int
  ownedSessionRoot: int
  psExecutable, enumerationPython: string
  knownMembers: seq[tuple[pid, group: int]]
  enumerationFailed: bool

var startupEnumerationPython {.threadvar.}: string
# Preserve the startup tool provenance when tests or callers later narrow PATH.
# The managed value belongs to this thread; workers never read another thread's
# reference. Each owned runtime retains its own provenance for later teardown.
startupEnumerationPython = findExe("python3")

var preparationSessionRoot: int
  ## Set only in the isolated preparation subprocess. Nested Repro/Harbor
  ## groups stay in this one owned session so its parent can reclaim them.

proc retainPreparationSession*() =
  when defined(posix):
    let pid = posix.getpid()
    if posix.getsid(pid) != pid:
      raise newException(IOError, "Harbor preparation requires its own session")
    preparationSessionRoot = int(pid)

proc createPrivateDirectory*(prefix: string): string =
  when defined(posix):
    for attempt in 0 ..< 100:
      let candidate = genTempPath(prefix, "")
      if posix.mkdir(candidate.cstring, Mode(0o700)) == 0: return candidate
      if errno != EEXIST: raiseOSError(osLastError())
    raise newException(IOError, "Cannot create private editor runtime directory")
  else:
    result = createTempDir(prefix, "")
    setFilePermissions(result, {fpUserRead, fpUserWrite, fpUserExec})

proc findHarborSibling*(editorPath: string; explicitPath = ""): string =
  if explicitPath.len > 0:
    result = absolutePath(explicitPath)
    if not fileExists(result / "Cargo.toml") or not fileExists(result / "repro.nim"):
      raise newException(IOError, "Invalid ISONIM_AGENT_HARBOR_SIBLING: " & result)
    return
  var root = absolutePath(editorPath).parentDir
  while root != root.parentDir:
    if fileExists(root / "isonim.nimble"):
      let candidate = root.parentDir / "agent-harbor"
      if fileExists(candidate / "Cargo.toml") and fileExists(candidate / "repro.nim"):
        return candidate
      return ""
    root = root.parentDir

when defined(posix):
  proc enumeratePids(executable, python: string): string =
    # A regular-file capture has no EOF dependency on inherited child pipes.
    # The bounded supervisor owns a separate ps group and reclaims its children
    # on success or timeout. No reader thread can outlive enumeration.
    let (capture, path) = createTempFile("isonim-ps-", ".txt")
    capture.close()
    defer: removeFile(path)
    let statusPath = path & ".status"
    defer:
      if fileExists(statusPath): removeFile(statusPath)
    let script = "import os,signal,subprocess,sys,pathlib\nos.setsid()\n" &
      "try:\n" &
      " with open(sys.argv[2],'wb') as output:\n" &
      "  p=subprocess.Popen([sys.argv[1],'-e','-o','pid='],stdout=output,stderr=subprocess.STDOUT)\n" &
      "  try:\n   code=p.wait(timeout=float(sys.argv[3]))\n" &
      "  except subprocess.TimeoutExpired:\n   code=124\n" &
      "  pathlib.Path(sys.argv[2]+'.status').write_text(str(code))\n" &
      "finally:\n os.killpg(os.getpid(),signal.SIGKILL)\n"
    let process = startProcess(python,
      args = @["-c", script, executable, path, $(EnumerationTimeoutMs.float / 1000)],
      options = {poParentStreams})
    defer: process.close()
    let deadline = getMonoTime() + initDuration(milliseconds = EnumerationTimeoutMs + 500)
    while process.running and getMonoTime() < deadline: sleep(10)
    if process.running:
      # Signal before wait/reap while the owned leader's PID is still reserved.
      # Also cover an unexpectedly delayed or failed capture supervisor.
      if posix.getsid(Pid(process.processID)) == Pid(process.processID):
        discard posix.kill(Pid(-process.processID), SIGKILL)
      else: process.kill()
    let exitCode = process.waitForExit()
    if not fileExists(statusPath):
      raise newException(IOError, "ps supervisor failed or timed out: " & $exitCode)
    let code = parseInt(readFile(statusPath))
    if code != 0:
      raise newException(IOError, "ps failed or timed out: " & $code)
    result = readFile(path)

  proc ownedSessionGroups(runtime: var LocalHarbor): seq[int] =
    let sessionId = if runtime.ownedSessionRoot > 0: runtime.ownedSessionRoot else: runtime.processGroup
    # Repro action workers can create a PG distinct from their wrapper while
    # remaining in its uniquely owned POSIX session. Enumerate numeric PIDs
    # only, then use kernel identities to avoid touching another instance.
    # Revalidate kernel membership before each signal. A dead group's cached
    # numeric ID may have been reused by an unrelated process.
    for member in runtime.knownMembers:
      if posix.getsid(Pid(member.pid)) == Pid(sessionId) and
          int(posix.getpgid(Pid(member.pid))) == member.group:
        if member.group notin result: result.add(member.group)
    if sessionId != preparationSessionRoot and posix.getsid(Pid(sessionId)) == Pid(sessionId) and sessionId notin result:
      result.add(sessionId)
    if runtime.enumerationFailed: return
    var pids: string
    try:
      pids = enumeratePids(runtime.psExecutable, runtime.enumerationPython)
    except CatchableError as e:
      runtime.enumerationFailed = true
      stderr.writeLine("Local Harbor process enumeration failed; signalling known groups: " & e.msg)
      return
    for line in pids.splitLines():
      var pid: int
      try: pid = parseInt(line.strip())
      except ValueError: continue
      let owner = posix.getsid(Pid(pid))
      if owner < 0 and errno != ESRCH:
        stderr.writeLine("Local Harbor cannot inspect PID " & $pid & ": " & $osLastError())
      if owner == Pid(sessionId):
        let group = int(posix.getpgid(Pid(pid)))
        if group > 0 and group != preparationSessionRoot:
          if group notin result: result.add(group)
          if (pid, group) notin runtime.knownMembers:
            runtime.knownMembers.add((pid, group))

proc stop*(runtime: var LocalHarbor) =
  if runtime.process != nil:
    let teardownDeadline = getMonoTime() + initDuration(milliseconds = HarborTeardownTimeoutMs)
    when defined(posix):
      if runtime.processGroup > 0:
        # Own the whole isolated session, including Repro action worker PGs.
        for group in ownedSessionGroups(runtime):
          discard posix.kill(Pid(-group), SIGTERM)
        let deadline = teardownDeadline - initDuration(milliseconds = HarborTeardownTimeoutMs div 2)
        while getMonoTime() < deadline:
          let groups = ownedSessionGroups(runtime)
          if not runtime.process.running and groups.len == 1: break
          var live = false
          for group in groups:
            if posix.kill(Pid(-group), 0) == 0: live = true
          if not live: break
          sleep(100)
        for group in ownedSessionGroups(runtime):
          discard posix.kill(Pid(-group), SIGKILL)
      elif runtime.process.running:
        runtime.process.terminate()
    else:
      if runtime.process.running:
        let killer = startProcess("taskkill", args = @["/PID", $runtime.process.processID,
          "/T", "/F"], options = {poUsePath, poParentStreams})
        discard killer.waitForExit()
        killer.close()
    if runtime.process.waitForExit(max(1, int((teardownDeadline - getMonoTime()).inMilliseconds))) == -1:
      runtime.process.kill()
      discard runtime.process.waitForExit()
    runtime.process.close()
    runtime.process = nil
    runtime.processGroup = 0
    runtime.ownedSessionRoot = 0
  # Keep the state directory and log for postmortem inspection.

proc startOwnedProcess*(runtime: var LocalHarbor; command: string;
    args: seq[string]; workingDir = ""; env: StringTableRef = nil) =
  when defined(posix):
    runtime.enumerationFailed = false
    runtime.knownMembers = @[]
    runtime.psExecutable = findExe("ps")
    runtime.enumerationPython = startupEnumerationPython
    if runtime.enumerationPython.len == 0: runtime.enumerationPython = findExe("python3")
    if runtime.psExecutable.len == 0:
      raise newException(IOError, "Owned Harbor processes require the POSIX ps executable")
    discard enumeratePids(runtime.psExecutable, runtime.enumerationPython)
    # osproc.poDaemon does not create a group on Nim's fork backend. Create
    # the session before exec instead; no child can escape before ownership.
    let isolate = if preparationSessionRoot > 0: "os.setpgrp()" else: "os.setsid()"
    runtime.process = startProcess("python3", workingDir = workingDir, env = env,
      args = @["-c", "import os,sys; " & isolate & "; os.execvp(sys.argv[1],sys.argv[1:])",
        command] & args, options = {poUsePath, poParentStreams})
    let pid = Pid(runtime.process.processID)
    for attempt in 0 ..< 100:
      if posix.getpgid(pid) == pid:
        runtime.processGroup = int(pid)
        runtime.ownedSessionRoot = if preparationSessionRoot > 0: preparationSessionRoot else: int(pid)
        return
      if not runtime.process.running: break
      sleep(10)
    runtime.stop()
    raise newException(IOError, "Could not isolate local Harbor's process group")
  else:
    runtime.process = startProcess(command, workingDir = workingDir, env = env,
      args = args, options = {poUsePath, poParentStreams})

proc writeBuildInput(path, contents: string) =
  # Concurrent starts write identical source. Publish atomically and preserve
  # unchanged files so Repro can reuse its provider/interface caches.
  if fileExists(path) and readFile(path) == contents: return
  let (file, temporary) = createTempFile("isonim-input-", ".tmp", path.parentDir)
  try:
    try: file.write(contents)
    finally: file.close()
    moveFile(temporary, path)
  finally:
    if fileExists(temporary): removeFile(temporary)

proc resolveSelectedHarborExecutable*(repo, binary: string;
    failureMessage = "Unexpected local Harbor executable"): string =
  # Compare canonical filesystem paths. Repro may report a canonical path for
  # a symlinked sibling. A lexical child can also escape through a symlink.
  if not binary.isAbsolute or not fileExists(binary):
    raise newException(IOError, failureMessage)
  let sourcePath = expandFilename(repo)
  let executablePath = expandFilename(binary)
  let relative = relativePath(executablePath, sourcePath)
  if relative == ".." or relative.startsWith(".." & $DirSep) or relative.isAbsolute:
    raise newException(IOError, failureMessage)
  result = executablePath

const
  HarborConsumerOverride = ".repro" / "develop-overrides.toml"
  HarborOverrideSchema = "schema = \"reprobuild.workspace.develop-overrides.v1\""
  HarborOverridePackage = "package = \"ah\""
    ## The two markers every override this module writes carries. Cleanup
    ## treats a directory as editor-owned only when both are present.
  StaleConsumerRemovalLimit* = 8
    ## Upper bound on stale consumers removed per preparation, so a large
    ## backlog never delays Harbor startup. Entries are visited in sorted order
    ## and removed ones disappear, so every stale entry is reached eventually.

proc consumerCheckout(consumer: string): string =
  ## The checkout an editor-owned consumer directory selects, read back from
  ## the develop override this module wrote there. Empty when the record is
  ## absent, unreadable or lacks the schema and `ah` package markers.
  let path = consumer / HarborConsumerOverride
  if not fileExists(path): return ""
  var lines: seq[string]
  try: lines = readFile(path).splitLines()
  except IOError: return ""
  if HarborOverrideSchema notin lines or HarborOverridePackage notin lines:
    return ""
  for line in lines:
    if line.startsWith("local_path = "):
      try:
        let node = parseJson(line["local_path = ".len .. ^1])
        if node.kind == JString and node.getStr.len > 0:
          return absolutePath(node.getStr, consumer)
      except CatchableError: discard
  ""

proc removeStaleHarborConsumers*(root: string; keep = "";
    removeLimit = StaleConsumerRemovalLimit): seq[string] =
  ## Cleanup of editor-owned consumer state. A consumer is stale only when its
  ## own override (schema and `ah` package markers present) names a checkout
  ## that no longer exists. Consumers whose checkout exists, directories the
  ## editor did not write, unreadable entries and `keep` are left alone.
  ## Inspection reads one small record per entry in sorted order; at most
  ## `removeLimit` stale entries are removed per call, so repeated calls reach
  ## every stale entry. Returns the removed directories.
  if not dirExists(root) or removeLimit <= 0: return
  var entries: seq[string]
  for kind, entry in walkDir(root):
    if kind == pcDir and entry != keep: entries.add entry
  entries.sort()
  for entry in entries:
    if result.len >= removeLimit: break
    let checkout = consumerCheckout(entry)
    if checkout.len == 0 or dirExists(checkout): continue
    try:
      removeDir(entry)
      result.add entry
    except OSError as e:
      stderr.writeLine("IsoNim: could not remove stale Harbor consumer " & entry & ": " & e.msg)

proc harborConsumerDir*(repo: string): string =
  ## Editor-owned Reprobuild consumer project for one selected Harbor checkout.
  ## It lives in the user's cache rather than in either checkout: the producer
  ## checkout belongs to Harbor, and an installed editor may have no checkout of
  ## its own. A stable per-checkout location keeps Repro's provider and
  ## interface caches warm across editor starts. The canonical checkout path is
  ## the key, so a symlinked sibling shares its target's consumer; the readable
  ## basename is only for developers inspecting the cache.
  let canonical = expandFilename(repo)
  result = getCacheDir("isonim") / "harbor-consumer" /
    (canonical.extractFilename & "-" & toHex(hash(canonical).uint64))

proc harborBuildFailure*(repo: string; code: int): string =
  ## Actionable message for a failed Reprobuild build of the selected checkout.
  ## The editor does not parse Reprobuild's diagnostics (they are printed above
  ## this message); it names the contract the checkout must meet and the
  ## opt-out. The commonest cause is a checkout that does not export `ah`.
  "Local Agent Harbor build failed (exit " & $code & "): Reprobuild could not " &
    "obtain the `ah` executable export of the selected Agent Harbor checkout " &
    repo & ". Its repro.nim must declare an `ah` executable export; " &
    "Reprobuild's diagnostics above name the cause. Set ISONIM_LOCAL_HARBOR=0 " &
    "to keep the configured agent instead. No installed or previously built " &
    "Harbor is used as a fallback."

proc buildLocalHarbor*(repo, buildDir: string; env: StringTableRef;
    shouldStop: proc(): bool = nil): string =
  # This private dependency belongs only to the selected runtime, never the
  # public editor package. The build consumer asks Repro to resolve the local
  # producer and materialize its executable export before launching anything.
  createDir(buildDir / ".repro")
  writeBuildInput(buildDir / "repro.nim", """
import repro_project_dsl
import repro_dsl_stdlib/packages/sh
import repro_dsl_stdlib/packages/python3
package editorHarborRuntime:
  defaultToolProvisioning "path"
  uses:
    "sh"
    "python3"
    "ah"
  build:
    let consume = shell(command = "ah --version && python3 publish.py",
      extraInputs = @["publish.py"],
      extraOutputs = @["harbor-executable"],
      cacheable = false)
    appendRegisteredActionToolIdentityRefs(consume.id, ["ah", "python3"])
""")
  writeBuildInput(buildDir / "publish.py", """
import os
import shutil
import tempfile
binary = shutil.which("ah")
if binary is None:
    raise RuntimeError("Repro did not bind ah")
fd, temporary = tempfile.mkstemp(prefix="harbor-executable-", dir=".")
try:
    with os.fdopen(fd, "w") as output:
        output.write(binary + "\n")
    os.replace(temporary, "harbor-executable")
finally:
    if os.path.exists(temporary):
        os.unlink(temporary)
""")
  let overridePath = buildDir / HarborConsumerOverride
  var createdAt = ""
  if fileExists(overridePath):
    for line in readFile(overridePath).splitLines():
      if line.startsWith("created_at = "):
        createdAt = line["created_at = ".len .. ^1]
  if createdAt.len == 0:
    createdAt = $(%(now().utc.format("yyyy-MM-dd'T'HH:mm:ss'Z'")))
  writeBuildInput(overridePath,
    HarborOverrideSchema & "\n\n" &
    "[[override]]\n" & HarborOverridePackage & "\nlocal_path = " &
    $(%relativePath(expandFilename(repo), buildDir)) & "\nstate = \"editable\"\ncreated_at = " & createdAt & "\n")
  stderr.writeLine("IsoNim: building workspace Agent Harbor with Reprobuild from " & repo &
    " (consumer " & buildDir & ")")
  var build: LocalHarbor
  build.startOwnedProcess("repro", workingDir = buildDir,
    args = @["build", "--daemon=off"], env = env)
  defer: build.stop()
  while build.process.running:
    if shouldStop != nil and shouldStop():
      raise newException(IOError, "Local Agent Harbor build interrupted")
    sleep(100)
  let code = build.process.waitForExit()
  if code != 0:
    raise newException(IOError, harborBuildFailure(repo, code))
  let artifactFile = buildDir / "harbor-executable"
  if not fileExists(artifactFile):
    raise newException(IOError, "Reprobuild did not report an Agent Harbor executable")
  let binary = readFile(artifactFile).strip()
  # Repro owns the output layout. The selected executable must still belong
  # to the selected source tree, so an ambient installed ah cannot pass.
  result = resolveSelectedHarborExecutable(repo, binary,
    "Reprobuild selected an unexpected Harbor executable: " & binary)

proc prepareLocalHarbor*(cfg: var ReviewConfig;
    shouldStop: proc(): bool = nil): LocalHarbor =
  if cfg.agent.backendExplicit or cfg.agent.command.len > 0 or
      cfg.agent.args.len > 0 or getEnv("ISONIM_ACP_AGENT_CMD").len > 0 or
      getEnv("ISONIM_LOCAL_HARBOR") == "0": return
  if cfg.agent.harborUrl.len > 0:
    cfg.agent.backend = "harbor"
    return
  let repo = findHarborSibling(getAppFilename(), getEnv("ISONIM_AGENT_HARBOR_SIBLING"))
  if repo.len == 0:
    stderr.writeLine("IsoNim: optional Agent Harbor sibling unavailable; keeping configured agent")
    return
  var env = newStringTable(modeCaseSensitive)
  for k, v in envPairs(): env[k] = v
  env["ISONIM_AGENT_HARBOR_SIBLING"] = repo
  # A consumer's Nix shell is not the producer's pinned environment.
  env.del("IN_NIX_SHELL")
  env.del("CARGO_TARGET_DIR")
  env.del("RUSTC_WORKSPACE_WRAPPER")
  result.stateDir = createPrivateDirectory("isonim-harbor-")
  let consumer = harborConsumerDir(repo)
  for removed in removeStaleHarborConsumers(consumer.parentDir, keep = consumer):
    stderr.writeLine("IsoNim: removed stale Harbor consumer " & removed)
  let binary = buildLocalHarbor(repo, consumer, env, shouldStop)
  if shouldStop != nil and shouldStop():
    raise newException(IOError, "Local Agent Harbor startup interrupted")
  result.executable = binary
  let probe = newSocket()
  probe.bindAddr(Port(0), "127.0.0.1")
  let port = probe.getLocalAddr()[1]
  probe.close()
  # Own daemon state even when the caller has a running Harbor configured.
  # AH_HOME is also Harbor's credential/config root; preserve it and HOME.
  env["AH_DAEMON_DB_PATH"] = result.stateDir / "daemon.sqlite"
  env["AH_RECORDINGS_DIR"] = result.stateDir / "recordings"
  env["AH_DAEMON_PID_FILE"] = result.stateDir / "server.pid"
  env["AH_DAEMON_CONTROL_SOCK"] = result.stateDir / "control.sock"
  env["AH_WEBUI_PID_FILE"] = result.stateDir / "webui.pid"
  env["AH_DEV_MODE"] = "1"
  env["AH_LOG_FILE"] = result.stateDir / "harbor.log"
  result.startOwnedProcess("repro", workingDir = repo, env = env,
    args = @["exec", "--", binary, "server", "start", "--no-access-point-loop", "--rest-host", "127.0.0.1", "--rest-port", $port,
      "--recordings-dir", result.stateDir / "recordings",
      "--webui-pid-file", result.stateDir / "webui.pid",
      "--pid-file", result.stateDir / "server.pid", "--control-sock", result.stateDir / "control.sock",
      "--task-manager-sock", result.stateDir / "tasks.sock", "--no-acp"])
  let url = "http://127.0.0.1:" & $port
  var ready = false
  # The producer environment may need a cold Repro provider compilation.
  for attempt in 0 ..< 6000:
    if shouldStop != nil and shouldStop(): break
    if not result.process.running: break
    let http = newHttpClient(timeout = 500)
    try:
      let resp = http.get(url & "/api/v1/healthz")
      if int(resp.code) == 200:
        ready = true
        break
    except CatchableError: discard
    finally: http.close()
    sleep(100)
  if not ready:
    let log = result.stateDir / "harbor.log"
    result.stop()
    raise newException(IOError, "Local Harbor failed to start; see " & log)
  cfg.agent.backend = "harbor"
  cfg.agent.harborUrl = url
  stderr.writeLine("IsoNim: using " & binary & " via REST at " & url)
