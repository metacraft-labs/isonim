## Fault injection around the real executable: count invocations, record the
## arguments it was given, change its final exit status, or damage its
## completed output. Positive rendering tests
## pass real Nix executable paths directly. These wrappers never simulate a
## a renderer-positive case. A crafted normalization fixture may replace output
## only after the real CLI ran; its test documents that narrower purpose.
import std/os

proc instrumentTool*(directory, name, executable, afterSuccess: string;
    counter = ""; argumentLog = ""): string =
  ## A bash wrapper at `directory/name` that runs `executable` with the
  ## wrapper's own arguments, then `afterSuccess`. `counter` gains a line per
  ## call; `argumentLog` gains each argument on its own line, so a test can
  ## check what a caller passed to the real tool. Both use only bash
  ## builtins, because callers may run the wrapper with a scrubbed `PATH`.
  result = directory / name
  let shell = findExe("bash")
  doAssert shell.len > 0, "bash not configured for CLI fault injection"
  var source = "#!" & shell & "\nset -eu\n"
  if counter.len > 0: source.add "printf 'call\\n' >> " & quoteShell(counter) & "\n"
  if argumentLog.len > 0:
    source.add "printf '%s\\n' \"$@\" >> " & quoteShell(argumentLog) & "\n"
  source.add quoteShell(executable) & " \"$@\"\n" & afterSuccess & "\n"
  writeFile(result, source)
  setFilePermissions(result, {fpUserRead, fpUserWrite, fpUserExec})
