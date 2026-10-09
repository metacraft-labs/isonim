## Build-selection integration tests use real Reprobuild processes, source
## files and executable outputs. The small producer is a build fixture, not a
## mocked Repro runner: it lets us mutate/fail a producer without editing the
## developer's private Harbor checkout. No build, filesystem or process calls
## are mocked. A separate deployment check builds and runs the real Harbor CLI.
import std/[os, osproc, tempfiles, unittest, strtabs, strutils, monotimes, times, net]
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
import repro_dsl_stdlib/packages/python3
package testHarbor:
  defaultToolProvisioning "path"
  uses:
    "sh"
    "python3 >=3.9"
  executable ah:
    name: "ah"
  build:
    discard shell(command = "mkdir -p build/bin && sh build.sh",
      extraInputs = @["build.sh", "main.sh"],
      extraOutputs = @["build/bin/ah"], cacheable = false)
""")
  writeFile(producer / "build.sh",
    "set -eu\npython3 -c 'import time; time.sleep(.3)'\ncmp -s main.sh build/bin/ah || cp main.sh build/bin/ah\nchmod +x build/bin/ah\n")
  writeFile(producer / "main.sh", "#!/bin/sh\nprintf 'LOCAL_V1\\n'\n")
  # A poison installed binary must never satisfy selected-local admission.
  let ambient = root / "ambient"
  createDir(ambient)
  writeFile(ambient / "ah", "#!/bin/sh\nprintf 'INSTALLED_POISON\\n'\n")
  setFilePermissions(ambient / "ah", {fpUserRead, fpUserWrite, fpUserExec})
  env["PATH"] = ambient & $PathSep & env["PATH"]
  suite "Repro source-built Harbor selection":
    test "startup interruption stops the owned build without publishing output":
      var polls = 0
      try:
        discard buildLocalHarbor(producer, consumer, env, proc(): bool =
          inc polls
          polls > 1)
        check false
      except IOError as e:
        check e.msg == "Local Agent Harbor build interrupted"
      check not fileExists(consumer / "harbor-executable")
    test "builds missing output and preserves idempotent producer output":
      check not fileExists(producer / "build/bin/ah")
      let started = getMonoTime()
      let binary = buildLocalHarbor(producer, consumer, env)
      check (getMonoTime() - started).inMilliseconds >= 300
      check binary == producer / "build/bin/ah"
      check execProcess(binary).strip() == "LOCAL_V1"
      let mtime = getLastModificationTime(binary)
      let recipeMtime = getLastModificationTime(consumer / "repro.nim")
      let overrideMtime = getLastModificationTime(consumer / ".repro/develop-overrides.toml")
      check buildLocalHarbor(producer, consumer, env) == binary
      check getLastModificationTime(binary) == mtime
      check getLastModificationTime(consumer / "repro.nim") == recipeMtime
      check getLastModificationTime(consumer / ".repro/develop-overrides.toml") == overrideMtime
    test "cancellation stops a listener launched by the actual producer":
      let original = readFile(producer / "build.sh")
      let listenerFile = producer / "listener-port"
      writeFile(producer / "listener.py", "import socket,time,sys\nfrom pathlib import Path\ns=socket.socket(); s.bind(('127.0.0.1',0)); s.listen()\nPath(sys.argv[1] if len(sys.argv)>1 else 'listener-port').write_text(str(s.getsockname()[1]))\ntime.sleep(120)\n")
      var other: LocalHarbor
      other.startOwnedProcess("python3", @[producer / "listener.py", "unrelated-port"],
        workingDir = producer)
      defer: other.stop()
      for attempt in 0 ..< 100:
        if fileExists(producer / "unrelated-port"): break
        sleep(10)
      require fileExists(producer / "unrelated-port")
      let otherPort = Port(parseInt(readFile(producer / "unrelated-port")))
      writeFile(producer / "build.sh", "set -eu\npython3 listener.py\n")
      defer: writeFile(producer / "build.sh", original)
      var listenerPort = Port(0)
      try:
        discard buildLocalHarbor(producer, consumer, env, proc(): bool =
          if not fileExists(listenerFile): return false
          listenerPort = Port(parseInt(readFile(listenerFile)))
          let before = newSocket()
          before.connect("127.0.0.1", listenerPort)
          before.close()
          true)
        check false
      except IOError as e:
        check e.msg == "Local Agent Harbor build interrupted"
      require listenerPort != Port(0)
      let after = newSocket()
      defer: after.close()
      expect OSError: after.connect("127.0.0.1", listenerPort)
      let unaffected = newSocket()
      unaffected.connect("127.0.0.1", otherPort)
      unaffected.close()
    test "uncommitted producer source edits change the executed artifact":
      writeFile(producer / "main.sh", "#!/bin/sh\nprintf 'LOCAL_V2\\n'\n")
      let binary = buildLocalHarbor(producer, consumer, env)
      check execProcess(binary).strip() == "LOCAL_V2"
    when defined(posix):
      test "symlinked selected source accepts its canonical producer output":
        let alias = root / "workspace" / "agent-harbor"
        createDir(alias.parentDir)
        createSymlink(producer, alias)
        let binary = buildLocalHarbor(alias, root / "alias-consumer", env)
        check getFileInfo(binary).id == getFileInfo(producer / "build/bin/ah").id
        check execProcess(binary).strip() == "LOCAL_V2"
        # Repro can report either spelling. Also admit the canonical path of
        # the real produced file against the selected source's symlink alias.
        let canonicalReport = expandFilename(binary)
        let admitted = resolveSelectedHarborExecutable(alias, canonicalReport)
        check getFileInfo(admitted).id == getFileInfo(binary).id
        check execProcess(admitted).strip() == "LOCAL_V2"

      test "producer output symlinks cannot admit outside or prefix-lookalike executables":
        let original = readFile(producer / "build.sh")
        defer: writeFile(producer / "build.sh", original)
        let lookalike = producer & "-installed"
        createDir(lookalike)
        writeFile(lookalike / "ah", "#!/bin/sh\nprintf 'LOOKALIKE_POISON\\n'\n")
        setFilePermissions(lookalike / "ah", {fpUserRead, fpUserWrite, fpUserExec})
        for outside in [ambient / "ah", lookalike / "ah"]:
          # The real producer deliberately publishes an escaping executable
          # symlink. Its version command succeeds, so admission must reject it.
          writeFile(producer / "build.sh", "set -eu\nrm -f build/bin/ah\nln -s " &
            quoteShell(outside) & " build/bin/ah\n")
          try:
            discard buildLocalHarbor(producer, consumer, env)
            check false
          except IOError as e:
            check e.msg.startsWith("Reprobuild selected an unexpected Harbor executable:")
          check symlinkExists(producer / "build/bin/ah")
          check expandFilename(producer / "build/bin/ah") == outside
        removeFile(producer / "build/bin/ah")
        writeFile(producer / "build.sh", original)
        check execProcess(buildLocalHarbor(producer, consumer, env)).strip() == "LOCAL_V2"

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
