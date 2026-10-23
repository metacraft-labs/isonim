## Native process boundary shared by optional content renderers. Arguments are
## passed directly to exec, never through a shell; temporary paths are private
## invocation scratch and cannot leak into successful content output.
when defined(js): {.error: "Content CLI adapters run at native build time only".}
import std/[os, osproc, streams, tempfiles, strutils, strtabs]
import ../markdown

proc checkedExecutable*(path, name: string; location: SourceLocation): string =
  if path.len == 0: raise contentError(location, name & " not configured")
  if not path.isAbsolute or not fileExists(path):
    raise contentError(location, name & " executable must be an existing absolute path: " & path)
  path

proc renderWithTool*(path, name, source, extension: string; location: SourceLocation;
    arguments: proc(input, output: string): seq[string] {.closure.}): string =
  let executable = checkedExecutable(path, name, location)
  let work = createTempDir("isonim-content-", "")
  defer: removeDir(work)
  let input = work / ("input." & extension)
  let output = work / "output.svg"
  writeFile(input, source)
  try:
    let process = startProcess(executable, workingDir = work,
      args = arguments(input, output), options = {poStdErrToStdOut},
      env = newStringTable({"PATH": parentDir(executable), "LANG": "C.UTF-8",
        "LC_ALL": "C.UTF-8", "TZ": "UTC"}))
    defer: process.close()
    let diagnostics = process.outputStream.readAll()
    let status = process.waitForExit()
    if status != 0:
      raise contentError(location, name & " exited with status " & $status & ": " & diagnostics.strip())
    if not fileExists(output):
      raise contentError(location, name & " produced no output: " & diagnostics.strip())
    result = readFile(output)
  except OSError as error:
    raise contentError(location, name & " could not run: " & error.msg)
