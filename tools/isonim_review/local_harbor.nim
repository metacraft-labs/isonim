## Optional workspace-local Agent Harbor runtime for every editor daemon.
## Detect the sibling relative to this editor binary, build via the producer's
## entry point, and use its reported output path. No checkout is required for
## standalone installations or developers without access to Agent Harbor.
import std/[monotimes, os, osproc, strutils, strtabs, net, httpclient, tempfiles, json, times]
when defined(posix): import std/posix
import ./config
import ./workspace_roles
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

proc workspaceSourceRole(project, name: string;
                         required: bool): tuple[workspace: bool, path: string]

proc findHarborSibling*(editorPath: string; explicitPath = ""): string =
  var root = absolutePath(editorPath).parentDir
  var declared: tuple[workspace: bool, path: string]
  while root != root.parentDir:
    if fileExists(root / "isonim.nimble"):
      declared = workspaceSourceRole(root, "agent-harbor", required = false)
      break
    root = root.parentDir
  if explicitPath.len > 0:
    result = absolutePath(explicitPath)
    if not fileExists(result / "Cargo.toml") or not fileExists(result / "repro.nim"):
      raise newException(IOError, "Invalid ISONIM_AGENT_HARBOR_SIBLING: " & result)
    if declared.workspace and (declared.path.len == 0 or
        expandFilename(result) != expandFilename(declared.path)):
      raise newException(IOError, "Explicit Harbor source differs from its workspace declaration")
    return
  if declared.workspace:
    result = declared.path
  elif fileExists(root / "isonim.nimble"):
    let candidate = root.parentDir / "agent-harbor"
    if fileExists(candidate / "Cargo.toml") and fileExists(candidate / "repro.nim"):
      result = candidate
  if result.len > 0 and (not fileExists(result / "Cargo.toml") or
      not fileExists(result / "repro.nim")):
    raise newException(IOError, "Selected Harbor source lacks its producer declaration: " & result)

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

const WorkspaceRoleScript = staticRead("workspace_roles.py")

proc workspaceSourceRole(project, name: string;
                         required: bool): tuple[workspace: bool, path: string] =
  let root = workspaceRoot(project)
  if root.len == 0: return (false, "")
  let directory = createPrivateDirectory("isonim-workspace-roles-")
  defer: removeDir(directory)
  let output = directory / "report.json"
  var query: LocalHarbor
  let python = if startupEnumerationPython.len > 0: startupEnumerationPython else: findExe("python3")
  query.startOwnedProcess(python, workingDir = project,
    args = @["-c", WorkspaceRoleScript, "report", project, output])
  try:
    let deadline = getMonoTime() + initDuration(milliseconds = 30000)
    while query.process.running:
      if getMonoTime() >= deadline:
        raise newException(IOError, "Repro workspace role query exceeded its bounded lifetime")
      sleep(10)
    if query.process.waitForExit(1) != 0 or not fileExists(output):
      raise newException(IOError, "Repro workspace role query failed")
    result = (true, declaredRole(parseJson(readFile(output)), root, name, required))
  finally:
    query.stop()

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

const HarborProducerScript = staticRead("harbor_producer.py")

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
  let selection = sourcePath / ".repro" / "isonim-runtime" / "producer-interface.json"
  let staged = relative.startsWith(".repro" & $DirSep & "isonim-runtime" & $DirSep & "produced" & $DirSep)
  let selectedOwnProducer = fileExists(selection) and
    parseJson(readFile(selection))["interface"].getStr == "own"
  if staged or selectedOwnProducer:
    # The producer's external cache is never admitted directly. The embedded
    # verifier pins private receipt bytes, source state and canonical stage.
    let python = if startupEnumerationPython.len > 0: startupEnumerationPython else: findExe("python3")
    let verification = execCmdEx(quoteShell(python) & " -c " &
      quoteShell(HarborProducerScript) & " verify " & quoteShell(sourcePath) & " " &
      quoteShell(executablePath))
    if verification.exitCode != 0:
      raise newException(IOError, failureMessage & ": " & verification.output.strip())
  result = executablePath

proc buildLocalHarbor*(repo, buildDir: string; env: StringTableRef;
    shouldStop: proc(): bool = nil): string =
  let canonicalRepo = expandFilename(repo)
  for directory in [canonicalRepo / ".repro",
      canonicalRepo / ".repro" / "isonim-runtime"]:
    if dirExists(directory) and expandFilename(directory) != directory:
      raise newException(IOError, "Escaping Harbor stage parent")
  createDir(buildDir)
  let interfacePath = buildDir / "producer-interface.json"
  if fileExists(interfacePath): removeFile(interfacePath)
  var query: LocalHarbor
  query.startOwnedProcess("python3", workingDir = repo, env = env,
    args = @["-c", HarborProducerScript, "select", repo, interfacePath])
  try:
    while query.process.running:
      if shouldStop != nil and shouldStop():
        raise newException(IOError, "Local Agent Harbor build interrupted")
      sleep(100)
    if query.process.waitForExit() != 0 or not fileExists(interfacePath):
      raise newException(IOError, "Local Agent Harbor producer plan failed; refusing an installed fallback")
  finally: query.stop()
  if parseJson(readFile(interfacePath))["interface"].getStr == "own":
    createDir(buildDir)
    setFilePermissions(buildDir, {fpUserRead, fpUserWrite, fpUserExec})
    let publication = buildDir / "harbor-executable"
    if fileExists(publication): removeFile(publication)
    stderr.writeLine("IsoNim: building workspace Agent Harbor through its own Repro environment from " & repo)
    let stage = expandFilename(repo) / ".repro" / "isonim-runtime" / "produced"
    let reproDirectory = expandFilename(repo) / ".repro"
    if dirExists(reproDirectory) and expandFilename(reproDirectory) != reproDirectory:
      raise newException(IOError, "Escaping Harbor stage root")
    createDir(stage.parentDir)
    if expandFilename(stage.parentDir) != stage.parentDir:
      raise newException(IOError, "Escaping Harbor stage parent")
    if dirExists(stage) and expandFilename(stage) != stage:
      raise newException(IOError, "Escaping Harbor stage")
    # Existing directories must already be private. Never repair a poisoned
    # stage before the owning producer can reject it.
    if dirExists(stage):
      let admission = execCmdEx("python3 -c " & quoteShell(HarborProducerScript) &
        " stage " & quoteShell(repo) & " " & quoteShell(stage), env = env)
      if admission.exitCode != 0:
        raise newException(IOError, admission.output.strip())
    else:
      createDir(stage)
      setFilePermissions(stage, {fpUserRead, fpUserWrite, fpUserExec})
    let transient = createTempDir("pending-", "", stage)
    setFilePermissions(transient, {fpUserRead, fpUserWrite, fpUserExec})
    # The parent knows the exact transient before spawning. Even cancellation
    # reclaims only its own unfinished copy, after the owned descendants stop.
    defer:
      if dirExists(transient): removeDir(transient)
    var producer: LocalHarbor
    producer.startOwnedProcess("python3", workingDir = repo, env = env,
      args = @["-c", HarborProducerScript, "build", repo, publication, transient])
    defer: producer.stop()
    while producer.process.running:
      if shouldStop != nil and shouldStop():
        raise newException(IOError, "Local Agent Harbor build interrupted")
      sleep(100)
    let code = producer.process.waitForExit()
    if code != 0:
      raise newException(IOError, "Local Agent Harbor build failed (exit " & $code & "); refusing an installed fallback")
    if not fileExists(publication):
      raise newException(IOError, "Owning producer did not report an Agent Harbor executable")
    return resolveSelectedHarborExecutable(repo, readFile(publication).strip(),
      "Owning producer selected an unexpected Harbor executable")
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
  let overridePath = buildDir / ".repro" / "develop-overrides.toml"
  var createdAt = ""
  if fileExists(overridePath):
    for line in readFile(overridePath).splitLines():
      if line.startsWith("created_at = "):
        createdAt = line["created_at = ".len .. ^1]
  if createdAt.len == 0:
    createdAt = $(%(now().utc.format("yyyy-MM-dd'T'HH:mm:ss'Z'")))
  writeBuildInput(overridePath,
    "schema = \"reprobuild.workspace.develop-overrides.v1\"\n\n" &
    "[[override]]\npackage = \"ah\"\nlocal_path = " &
    $(%relativePath(repo, buildDir)) & "\nstate = \"editable\"\ncreated_at = " & createdAt & "\n")
  stderr.writeLine("IsoNim: building workspace Agent Harbor with Reprobuild from " & repo)
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
    raise newException(IOError, "Local Agent Harbor build failed (exit " & $code & "); refusing an installed fallback")
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
  let binary = buildLocalHarbor(repo, repo / ".repro" / "isonim-runtime", env, shouldStop)
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
