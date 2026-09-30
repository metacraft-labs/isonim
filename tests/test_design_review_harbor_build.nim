## Build-selection integration tests use real Reprobuild processes, source
## files and executable outputs. The small producer is a build fixture, not a
## mocked Repro runner: it lets us mutate/fail a producer without editing the
## developer's private Harbor checkout. No build, filesystem or process calls
## are mocked. A separate deployment check builds and runs the real Harbor CLI.
import std/[os, osproc, tempfiles, unittest, strtabs, strutils]
import ../tools/isonim_review/local_harbor

proc main() =
  let root = createTempDir("isonim-repro-test-", "")
  defer: removeDir(root)
  let producer = root / "agent-harbor"
  let consumer = root / "consumer"
  createDir(producer)
  createDir(consumer)
  let env = newStringTable(modeCaseSensitive)
  for key, value in envPairs(): env[key] = value
  env.del("IN_NIX_SHELL")
  writeFile(producer / "repro.nim", """
import repro_project_dsl
import repro_dsl_stdlib/packages/sh
package testHarbor:
  defaultToolProvisioning "path"
  uses:
    "sh"
  executable ah:
    name: "ah"
  build:
    discard shell(command = "mkdir -p build/bin && sh build.sh",
      extraInputs = @["build.sh", "main.sh"],
      extraOutputs = @["build/bin/ah"], cacheable = false)
""")
  writeFile(producer / "build.sh",
    "set -eu\ncmp -s main.sh build/bin/ah || cp main.sh build/bin/ah\nchmod +x build/bin/ah\n")
  writeFile(producer / "main.sh", "#!/bin/sh\nprintf 'LOCAL_V1\\n'\n")
  # A poison installed binary must never satisfy selected-local admission.
  let ambient = root / "ambient"
  createDir(ambient)
  writeFile(ambient / "ah", "#!/bin/sh\nprintf 'INSTALLED_POISON\\n'\n")
  setFilePermissions(ambient / "ah", {fpUserRead, fpUserWrite, fpUserExec})
  env["PATH"] = ambient & $PathSep & env["PATH"]
  suite "Repro source-built Harbor selection":
    test "builds missing output and preserves idempotent producer output":
      check not fileExists(producer / "build/bin/ah")
      let binary = buildLocalHarbor(producer, consumer, env)
      check binary == producer / "build/bin/ah"
      check execProcess(binary).strip() == "LOCAL_V1"
      let mtime = getLastModificationTime(binary)
      let recipeMtime = getLastModificationTime(consumer / "repro.nim")
      let overrideMtime = getLastModificationTime(consumer / ".repro/develop-overrides.toml")
      check buildLocalHarbor(producer, consumer, env) == binary
      check getLastModificationTime(binary) == mtime
      check getLastModificationTime(consumer / "repro.nim") == recipeMtime
      check getLastModificationTime(consumer / ".repro/develop-overrides.toml") == overrideMtime
    test "uncommitted producer source edits change the executed artifact":
      writeFile(producer / "main.sh", "#!/bin/sh\nprintf 'LOCAL_V2\\n'\n")
      let binary = buildLocalHarbor(producer, consumer, env)
      check execProcess(binary).strip() == "LOCAL_V2"
    test "failed selected build refuses stale and installed binaries":
      writeFile(producer / "build.sh", "exit 42\n")
      expect IOError:
        discard buildLocalHarbor(producer, consumer, env)
    test "successful producer with missing declared output is rejected":
      removeFile(producer / "build/bin/ah")
      writeFile(producer / "build.sh", "exit 0\n")
      expect IOError:
        discard buildLocalHarbor(producer, consumer, env)
main()
