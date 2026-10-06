## Daemon-owned optional Harbor preparation. Expensive producer work runs in an
## isolated process; only the main async loop touches its Process and future.
import std/[asyncdispatch, json, os, osproc, posix, strtabs, strutils, sysrand,
            tempfiles, uri]
import ./config
import ./local_harbor
import ../../src/isonim/editor/design_review/agent_routes

const EpochEnvironment = "ISONIM_INTERNAL_HARBOR_EPOCH"

type HarborPreparation* = ref object
  cfg: ReviewConfig
  runtime: LocalHarbor
  future: Future[string]
  directory, epoch, repository: string
  stopping: bool

proc localSelectionEnabled(cfg: ReviewConfig): bool =
  not cfg.agent.backendExplicit and cfg.agent.command.len == 0 and
    cfg.agent.args.len == 0 and getEnv("ISONIM_ACP_AGENT_CMD").len == 0 and
    getEnv("ISONIM_LOCAL_HARBOR") != "0" and cfg.agent.harborUrl.len == 0

proc normalizeExplicitHarbor*(cfg: var ReviewConfig) =
  # Preserve the existing URL-only selection contract without doing producer IO.
  if not cfg.agent.backendExplicit and cfg.agent.command.len == 0 and
      cfg.agent.args.len == 0 and getEnv("ISONIM_ACP_AGENT_CMD").len == 0 and
      getEnv("ISONIM_LOCAL_HARBOR") != "0" and cfg.agent.harborUrl.len > 0:
    cfg.agent.backend = "harbor"

proc newHarborPreparation*(cfg: ReviewConfig): HarborPreparation =
  if localSelectionEnabled(cfg): HarborPreparation(cfg: cfg) else: nil

proc privateDirectory(path: string) =
  var info: Stat
  if lstat(path, info) != 0 or not S_ISDIR(info.st_mode) or
      info.st_uid != getuid() or (info.st_mode and Mode(0o777)) != Mode(0o700):
    raise newException(IOError, "Invalid private Harbor preparation directory")

proc resultPath(preparation: HarborPreparation): string =
  preparation.directory / "ready.json"

proc readyUrl(preparation: HarborPreparation): string =
  privateDirectory(preparation.directory)
  let path = preparation.resultPath()
  var info: Stat
  if lstat(path, info) != 0 or not S_ISREG(info.st_mode) or
      info.st_uid != getuid() or info.st_nlink != 1 or
      (info.st_mode and Mode(0o777)) != Mode(0o600):
    raise newException(IOError, "Invalid Harbor preparation result")
  let data = parseJson(readFile(path))
  if data.kind != JObject or data.len != 4:
    raise newException(IOError, "Stale or malformed Harbor preparation result")
  for key in ["epoch", "pid", "url", "executable"]:
    if not data.hasKey(key):
      raise newException(IOError, "Stale or malformed Harbor preparation result")
  if data.kind != JObject or data.len != 4 or
      data["epoch"].kind != JString or data["epoch"].getStr != preparation.epoch or
      data["pid"].kind != JInt or data["pid"].getInt != preparation.runtime.process.processID or
      data["url"].kind != JString or data["executable"].kind != JString:
    raise newException(IOError, "Stale or malformed Harbor preparation result")
  let url = data["url"].getStr
  let parsed = parseUri(url)
  var port: int
  try: port = parseInt(parsed.port)
  except ValueError: raise newException(IOError, "Invalid local Harbor endpoint")
  if parsed.scheme != "http" or parsed.hostname != "127.0.0.1" or
      parsed.username.len > 0 or parsed.password.len > 0 or
      parsed.path.len > 0 or parsed.query.len > 0 or parsed.anchor.len > 0 or
      port notin 1 .. 65535:
    raise newException(IOError, "Invalid local Harbor endpoint")
  let executable = data["executable"].getStr
  let relative = relativePath(executable, preparation.repository)
  if not executable.isAbsolute or relative == ".." or
      relative.startsWith(".." & $DirSep) or not fileExists(executable):
    raise newException(IOError, "Unexpected local Harbor executable")
  result = url

proc prepare(preparation: HarborPreparation): Future[string] {.async, gcsafe.} =
  if preparation.stopping:
    raise newException(AgentBackendUnavailableError, "Editor is closing")
  let repo = findHarborSibling(getAppFilename(), getEnv("ISONIM_AGENT_HARBOR_SIBLING"))
  if repo.len == 0: return ""           # Optional private checkout absent.
  preparation.repository = repo
  preparation.epoch = ""
  for byte in urandom(32): preparation.epoch.add toHex(byte, 2)
  var environment = newStringTable(modeCaseSensitive)
  for key, value in envPairs(): environment[key] = value
  environment.del("ISONIM_EDITOR_BROWSER_BOOTSTRAP")
  environment[EpochEnvironment] = preparation.epoch
  preparation.directory = createPrivateDirectory("isonim-harbor-prepare-")
  try:
    preparation.runtime.startOwnedProcess(getAppFilename(),
      args = @["--internal-harbor-runtime", repo, preparation.directory],
      env = environment)
    while true:
      if preparation.stopping:
        raise newException(AgentBackendUnavailableError, "Editor is closing")
      if not preparation.runtime.process.running():
        raise newException(AgentBackendUnavailableError,
          "Local agent preparation failed; inspect the daemon's startup diagnostics")
      if fileExists(preparation.resultPath()):
        return preparation.readyUrl()
      await sleepAsync(40)
  except CatchableError as failure:
    try: preparation.runtime.stop()
    except CatchableError as cleanupFailure:
      stderr.writeLine("Local agent preparation cleanup failed: " & cleanupFailure.msg)
    if preparation.directory.len > 0:
      try: removeDir(preparation.directory)
      except CatchableError as cleanupFailure:
        stderr.writeLine("Local agent result cleanup failed: " & cleanupFailure.msg)
      preparation.directory = ""
    raise failure

proc ensureReady*(preparation: HarborPreparation): Future[string] {.async, gcsafe.} =
  if preparation == nil: return ""
  if preparation.stopping:
    raise newException(AgentBackendUnavailableError, "Editor is closing")
  if preparation.future != nil and preparation.future.finished and
      not preparation.future.failed and preparation.future.read().len > 0 and
      (preparation.runtime.process == nil or not preparation.runtime.process.running()):
    # Reusing a completed URL requires its authenticated owned generation alive.
    # Existing session clients retain their own endpoint; only new admission retries.
    preparation.runtime.stop()
    if preparation.directory.len > 0: removeDir(preparation.directory)
    preparation.directory = ""
    preparation.future = nil
  if preparation.future == nil: preparation.future = prepare(preparation)
  let pending = preparation.future
  try: return await pending
  except CatchableError:
    if preparation.future == pending: preparation.future = nil
    raise

proc stop*(preparation: HarborPreparation) =
  if preparation == nil or preparation.stopping: return
  preparation.stopping = true
  preparation.runtime.stop()
  if preparation.directory.len > 0: removeDir(preparation.directory)

proc runHarborPreparationChild*(repo, directory: string;
    shouldStop: proc(): bool): int =
  let epoch = getEnv(EpochEnvironment)
  delEnv(EpochEnvironment)              # Never passed into producer/providers.
  delEnv("ISONIM_EDITOR_BROWSER_BOOTSTRAP")
  if epoch.len != 64:
    raise newException(IOError, "Missing Harbor preparation authority")
  for ch in epoch:
    if ch notin {'0' .. '9', 'A' .. 'F'}:
      raise newException(IOError, "Invalid Harbor preparation authority")
  privateDirectory(directory)
  retainPreparationSession()
  putEnv("ISONIM_AGENT_HARBOR_SIBLING", repo)
  var cfg = defaults()
  var harbor = prepareLocalHarbor(cfg, shouldStop)
  defer: harbor.stop()
  if shouldStop() or cfg.agent.backend != "harbor": return 2
  let temporary = createTempFile("ready-", ".tmp", directory)
  try:
    try:
      temporary.cfile.write($(%* {"epoch": epoch, "pid": getCurrentProcessId(),
        "url": cfg.agent.harborUrl, "executable": harbor.executable}))
    finally: temporary.cfile.close()
    moveFile(temporary.path, directory / "ready.json")
  finally:
    if fileExists(temporary.path): removeFile(temporary.path)
  while not shouldStop():
    if harbor.process == nil or not harbor.process.running(): return 2
    sleep(40)
  0
