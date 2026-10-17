## Retained CLI test processes; preserve separate complete stdout/stderr.
import std/[os, osproc, strtabs, tempfiles, strutils]
import owned_cli_pg_fixture

const OwnedSplitExec* = "stderr=$1; shift; exec \"$@\" 2> \"$stderr\""

proc runOwnedSplitCapture*(executable: string; args: seq[string];
    workingDir = ""; env: StringTableRef = nil):
    tuple[exitCode: int; stdout, stderr: string] =
  let temporary = createTempFile("isonim-cli-stderr-", ".log")
  temporary.cfile.close()
  let stderrIdentity = getFileInfo(temporary.path).id
  let bash = findExe("bash", followSymlinks = false)
  if bash.len == 0:
    raise newException(IOError, "Declared cached Bash role is missing")
  # No invented timeout: the original caller is unbounded. The retained outer
  # still enforces its actual phase limit and complete descendant cleanup.
  try:
    let response = runOwnedCapture(bash, workingDir = workingDir,
      args = @["-p", "-c", OwnedSplitExec, "isonim-owned-cli-split", temporary.path,
        executable] & args, env = env)
    if symlinkExists(temporary.path) or getFileInfo(temporary.path).kind != pcFile or
        getFileInfo(temporary.path).id != stderrIdentity:
      raise newException(IOError, "Owned stderr log identity changed")
    result = (response.code, response.output, readFile(temporary.path))
    removeFile(temporary.path)
  except Exception:
    let original = getCurrentException()
    try:
      stderr.writeLine("Retained failed CLI stderr: " & temporary.path)
      if not symlinkExists(temporary.path) and getFileInfo(temporary.path).id == stderrIdentity:
        stderr.write(readFile(temporary.path))
        stderr.flushFile()
    except Exception: discard
    raise original

proc fixtureCliEnvironment*(port: int): StringTableRef =
  result = newStringTable(modeCaseSensitive)
  for pair in envPairs(): result[pair.key] = pair.value
  for key in ["PGSERVICE", "PGSERVICEFILE"]: result.del(key)
  result["PGHOSTADDR"] = "127.0.0.1"
  result["ISONIM_REVIEW_DB"] = "postgresql://127.0.0.1:" & $port &
    "/isonim_design_review?hostaddr=127.0.0.1"
  result["ISONIM_REVIEW_PGHOST"] = "127.0.0.1"
  result["ISONIM_REVIEW_PGPORT"] = $port

proc explicitConfigCliEnvironment*(): StringTableRef =
  ## The original --config file owns this test's DB port and role URI.
  result = newStringTable(modeCaseSensitive)
  for pair in envPairs(): result[pair.key] = pair.value
  for key in ["ISONIM_REVIEW_DB", "ISONIM_REVIEW_PGHOST", "ISONIM_REVIEW_PGPORT",
      "PGSERVICE", "PGSERVICEFILE"]: result.del(key)
  result["PGHOSTADDR"] = "127.0.0.1"

proc finishOwnedDaemon*(child: OwnedChild) =
  ## Always drain/reap before close; keep an initiating test error unchanged.
  let original = getCurrentException()
  var failure: ref Exception
  var reaped = false
  try:
    discard drainDirectChild(child)
    reaped = true
  except Exception:
    failure = getCurrentException()
  if reaped:
    try: child.close()
    except Exception:
      if failure == nil: failure = getCurrentException()
  if failure != nil:
    if original == nil: raise failure
    try: stderr.writeLine("Secondary retained daemon cleanup failure: " & failure.msg)
    except Exception: discard
