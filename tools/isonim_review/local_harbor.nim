## Optional workspace-local Agent Harbor runtime for every editor daemon.
## Detect the sibling relative to this editor binary, build via the producer's
## entry point, and use its reported output path. No checkout is required for
## standalone installations or developers without access to Agent Harbor.
import std/[os, osproc, strutils, strtabs, net, httpclient, tempfiles, json, times]
when defined(posix): import std/posix
import ./config

type LocalHarbor* = object
  process*: Process
  stateDir*: string
  executable*: string
  processGroup*: int

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

proc stop*(runtime: var LocalHarbor) =
  if runtime.process != nil:
    when defined(posix):
      if runtime.processGroup > 0:
        # Repro's exec runner waits for its child. Signal the owned group so
        # stopping the wrapper cannot orphan the Harbor server.
        discard posix.kill(Pid(-runtime.processGroup), SIGTERM)
        for attempt in 0 ..< 50:
          if posix.kill(Pid(-runtime.processGroup), 0) != 0: break
          sleep(100)
        discard posix.kill(Pid(-runtime.processGroup), SIGKILL)
      elif runtime.process.running:
        runtime.process.terminate()
    else:
      if runtime.process.running:
        let killer = startProcess("taskkill", args = @["/PID", $runtime.process.processID,
          "/T", "/F"], options = {poUsePath, poParentStreams})
        discard killer.waitForExit()
        killer.close()
    if runtime.process.waitForExit(5000) == -1:
      runtime.process.kill()
      discard runtime.process.waitForExit()
    runtime.process.close()
    runtime.process = nil
    runtime.processGroup = 0
  # Keep the state directory and log for postmortem inspection.

proc startOwnedProcess*(runtime: var LocalHarbor; command: string;
    args: seq[string]; workingDir = ""; env: StringTableRef = nil) =
  when defined(posix):
    # osproc.poDaemon does not create a group on Nim's fork backend. Create
    # the session before exec instead; no child can escape before ownership.
    runtime.process = startProcess("python3", workingDir = workingDir, env = env,
      args = @["-c", "import os,sys; os.setsid(); os.execvp(sys.argv[1],sys.argv[1:])",
        command] & args, options = {poUsePath, poParentStreams})
    let pid = Pid(runtime.process.processID)
    for attempt in 0 ..< 100:
      if posix.getpgid(pid) == pid:
        runtime.processGroup = int(pid)
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

proc buildLocalHarbor*(repo, buildDir: string; env: StringTableRef): string =
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
  let build = startProcess("repro", workingDir = buildDir, args = @["build", "--daemon=off"],
    env = env, options = {poUsePath, poParentStreams})
  let code = build.waitForExit()
  build.close()
  if code != 0:
    raise newException(IOError, "Local Agent Harbor build failed; refusing an installed fallback")
  let artifactFile = buildDir / "harbor-executable"
  if not fileExists(artifactFile):
    raise newException(IOError, "Reprobuild did not report an Agent Harbor executable")
  let binary = readFile(artifactFile).strip()
  # Repro owns the output layout. The selected executable must still belong
  # to the selected source tree, so an ambient installed ah cannot pass.
  let relative = relativePath(binary, repo)
  if not binary.isAbsolute or relative == ".." or
      relative.startsWith(".." & $DirSep) or not fileExists(binary):
    raise newException(IOError, "Reprobuild selected an unexpected Harbor executable: " & binary)
  result = binary

proc prepareLocalHarbor*(cfg: var ReviewConfig): LocalHarbor =
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
  result.stateDir = createTempDir("isonim-harbor-", "")
  let binary = buildLocalHarbor(repo, repo / ".repro" / "isonim-runtime", env)
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
