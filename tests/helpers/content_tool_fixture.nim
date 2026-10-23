## Fault injection around the real executable: count invocations, change its
## final exit status, or damage its completed output. Positive rendering tests
## pass real Nix executable paths directly. These wrappers never simulate a
## a renderer-positive case. A crafted normalization fixture may replace output
## only after the real CLI ran; its test documents that narrower purpose.
import std/os

proc instrumentTool*(directory, name, executable, afterSuccess: string;
    counter = ""): string =
  result = directory / name
  let shell = findExe("bash")
  doAssert shell.len > 0, "bash not configured for CLI fault injection"
  var source = "#!" & shell & "\nset -eu\n"
  if counter.len > 0: source.add "printf 'call\\n' >> " & quoteShell(counter) & "\n"
  source.add quoteShell(executable) & " \"$@\"\n" & afterSuccess & "\n"
  writeFile(result, source)
  setFilePermissions(result, {fpUserRead, fpUserWrite, fpUserExec})
