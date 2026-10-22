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

    test "editor consumer state stays outside the selected producer checkout":
      # The production entry point (prepareLocalHarbor) declares its consumer
      # in harborConsumerDir. Keep it out of Harbor's checkout, stable per
      # canonical checkout, and shared by a symlinked spelling of the same one.
      putEnv("XDG_CACHE_HOME", root / "cache")
      let owned = harborConsumerDir(producer)
      let relative = relativePath(owned, expandFilename(producer))
      check relative == ".." or relative.startsWith(".." & $DirSep)
      check owned == harborConsumerDir(producer)
      check owned != harborConsumerDir(root / "consumer")
      when defined(posix):
        let alias = root / "consumer-alias-workspace" / "agent-harbor"
        createDir(alias.parentDir)
        createSymlink(producer, alias)
        check harborConsumerDir(alias) == owned
      # `owned` stays for the stale-consumer cleanup case below; the whole
      # temporary root (including this redirected cache) is removed at exit.
      let binary = buildLocalHarbor(producer, owned, env)
      check execProcess(binary).strip() == "LOCAL_V2"
      check expandFilename(readFile(owned / "harbor-executable").strip()) == binary
      check not dirExists(producer / ".repro" / "isonim-runtime")

    test "producer without an executable export fails without any fallback":
      # This is the state of a Harbor checkout whose repro.nim declares no
      # `ah` export: the editor must report it rather than build Harbor itself.
      putEnv("XDG_CACHE_HOME", root / "cache")  # Never the developer's cache.
      let bare = root / "bare-harbor"
      createDir(bare / "build" / "bin")
      writeFile(bare / "repro.nim", """
import repro_project_dsl
import repro_dsl_stdlib/packages/sh
package bareHarbor:
  defaultToolProvisioning "path"
  uses:
    "sh"
""")
      # A stale producer-looking output and an installed ah are both present.
      writeFile(bare / "build" / "bin" / "ah", "#!/bin/sh\nprintf 'STALE_POISON\\n'\n")
      setFilePermissions(bare / "build" / "bin" / "ah", {fpUserRead, fpUserWrite, fpUserExec})
      let bareConsumer = harborConsumerDir(bare)
      try:
        discard buildLocalHarbor(bare, bareConsumer, env)
        check false
      except IOError as e:
        # The editor's own message names the missing export, the selected
        # checkout and the opt-out; Reprobuild's diagnostic precedes it.
        check e.msg.startsWith("Local Agent Harbor build failed")
        check "`ah` executable export" in e.msg
        check expandFilename(bare) in e.msg or bare in e.msg
        check "ISONIM_LOCAL_HARBOR=0" in e.msg
        check "No installed or previously built Harbor is used" in e.msg
      check not fileExists(bareConsumer / "harbor-executable")
      check not dirExists(bare / ".repro" / "isonim-runtime")

    test "stale consumer cleanup removes only editor state for vanished checkouts":
      # Self-contained: every consumer below is written by the real
      # buildLocalHarbor path (interrupted before Repro runs to completion,
      # after its override is published), except two foreign directories.
      let area = root / "cleanup"
      let consumers = area / "consumers"
      createDir(consumers)
      proc declare(checkout, consumer: string) =
        try:
          discard buildLocalHarbor(checkout, consumer, env, proc(): bool = true)
          check false
        except IOError as e:
          check e.msg == "Local Agent Harbor build interrupted"
        require fileExists(consumer / ".repro" / "develop-overrides.toml")
      let live = consumers / "live"
      declare(producer, live)
      let extra = StaleConsumerRemovalLimit + 1
      var stale: seq[string]
      for i in 0 ..< extra:
        let checkout = area / ("gone-" & $i)
        createDir(checkout)
        let consumer = consumers / ("stale-" & $i)
        declare(checkout, consumer)
        removeDir(checkout)
        stale.add consumer
      # Foreign directories the editor did not write: one whose override has
      # only a dangling local_path (no schema or `ah` package markers), one
      # with no override at all.
      let foreignDangling = consumers / "foreign-dangling"
      createDir(foreignDangling / ".repro")
      writeFile(foreignDangling / ".repro" / "develop-overrides.toml",
        "local_path = \"/missing\"\n")
      let foreignEmpty = consumers / "foreign-empty"
      createDir(foreignEmpty)
      # Each marker is required on its own: an override for a vanished
      # checkout that lacks either one is not the editor's.
      let foreignNoPackage = consumers / "foreign-no-package"
      createDir(foreignNoPackage / ".repro")
      writeFile(foreignNoPackage / ".repro" / "develop-overrides.toml",
        "schema = \"reprobuild.workspace.develop-overrides.v1\"\n\n" &
        "[[override]]\npackage = \"other\"\nlocal_path = \"/missing\"\n")
      let foreignNoSchema = consumers / "foreign-no-schema"
      createDir(foreignNoSchema / ".repro")
      writeFile(foreignNoSchema / ".repro" / "develop-overrides.toml",
        "[[override]]\npackage = \"ah\"\nlocal_path = \"/missing\"\n")
      check removeStaleHarborConsumers(consumers, removeLimit = 0).len == 0
      check removeStaleHarborConsumers(consumers, keep = stale[0],
        removeLimit = 1) == @[stale[1]]
      # The bound holds per call; sorted visiting reaches every stale entry
      # on later calls.
      let first = removeStaleHarborConsumers(consumers)
      check first.len == StaleConsumerRemovalLimit
      let second = removeStaleHarborConsumers(consumers)
      check first.len + second.len == extra - 1
      check removeStaleHarborConsumers(consumers).len == 0
      for consumer in stale: check not dirExists(consumer)
      check dirExists(live) and dirExists(foreignDangling) and dirExists(foreignEmpty)
      check dirExists(foreignNoPackage) and dirExists(foreignNoSchema)

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
