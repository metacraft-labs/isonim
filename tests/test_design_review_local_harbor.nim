## Optional sibling discovery uses real temporary checkout directories.
## No processes or HTTP transports are mocked. The fixtures contain only the
## repository marker files needed for discovery. Assertions cover the absence
## of a private checkout, workspace isolation, explicit overrides, and an
## explicit agent setting that must prevent any local build or service spawn.
## Cleanup also uses a real copied ps executable and actual missing/nonzero/hung
## replacements to test process ownership failure, without mocking process APIs.
import std/[times, os, osproc, tempfiles, unittest, net, strutils]
when defined(posix): import std/posix
import ../tools/isonim_review/[config, local_harbor]

proc main() =
  let root = createTempDir("isonim-sibling-test-", "")
  defer: removeDir(root)
  let editor = root / "workspace" / "isonim"
  createDir(editor / "build" / "bin")
  writeFile(editor / "isonim.nimble", "# discovery marker\n")
  let binary = editor / "build" / "bin" / "isonim-review"
  suite "optional workspace Harbor":
    test "missing private checkout leaves discovery empty":
      check findHarborSibling(binary) == ""
    test "only this editor's workspace is searched":
      let other = root / "agent-harbor"
      createDir(other)
      writeFile(other / "Cargo.toml", "")
      writeFile(other / "repro.nim", "")
      check findHarborSibling(binary) == ""
      let sibling = editor.parentDir / "agent-harbor"
      createDir(sibling)
      writeFile(sibling / "Cargo.toml", "")
      writeFile(sibling / "repro.nim", "")
      check findHarborSibling(binary) == sibling
      check findHarborSibling(binary, other) == other
    test "invalid explicit checkout fails rather than silently falling back":
      expect IOError:
        discard findHarborSibling(binary, root / "missing")
    test "explicit backend skips local preparation":
      var cfg = defaults()
      cfg.agent.backendExplicit = true
      cfg.agent.backend = "codex"
      let runtime = prepareLocalHarbor(cfg)
      check runtime.process == nil
      check cfg.agent.backend == "codex"
    test "explicit ACP command keeps the installed backend":
      var cfg = defaults()
      cfg.agent.command = "custom-acp"
      check prepareLocalHarbor(cfg).process == nil
      check cfg.agent.backend == "claude"
    test "ACP command environment override skips sibling preparation":
      let old = getEnv("ISONIM_ACP_AGENT_CMD")
      putEnv("ISONIM_ACP_AGENT_CMD", "explicit-acp")
      defer:
        if old.len > 0: putEnv("ISONIM_ACP_AGENT_CMD", old)
        else: delEnv("ISONIM_ACP_AGENT_CMD")
      var cfg = defaults()
      check prepareLocalHarbor(cfg).process == nil
    test "explicit REST URL bypasses even an invalid sibling":
      let old = getEnv("ISONIM_AGENT_HARBOR_SIBLING")
      putEnv("ISONIM_AGENT_HARBOR_SIBLING", root / "missing")
      defer:
        if old.len > 0: putEnv("ISONIM_AGENT_HARBOR_SIBLING", old)
        else: delEnv("ISONIM_AGENT_HARBOR_SIBLING")
      var cfg = defaults()
      cfg.agent.harborUrl = "http://127.0.0.1:8114"
      check prepareLocalHarbor(cfg).process == nil
      check cfg.agent.backend == "harbor"
      check cfg.agent.harborUrl == "http://127.0.0.1:8114"
    when defined(posix):
      test "stopping owned wrapper also stops its server child":
        let childScript = root / "server.py"
        let wrapperScript = root / "wrapper.py"
        let portFile = root / "port"
        writeFile(childScript, "import http.server, pathlib, sys, os\nos.setpgrp()\n" &
          "server=http.server.HTTPServer(('127.0.0.1',0),http.server.BaseHTTPRequestHandler)\n" &
          "pathlib.Path(sys.argv[1]).write_text(str(server.server_port))\nserver.serve_forever()\n")
        writeFile(wrapperScript, "import subprocess, sys\n" &
          "subprocess.run([sys.executable,sys.argv[1],sys.argv[2]],check=True)\n")
        var runtime: LocalHarbor
        runtime.startOwnedProcess("python3", @[wrapperScript, childScript, portFile])
        defer: runtime.stop()
        require posix.getpgid(Pid(runtime.process.processID)) == Pid(runtime.process.processID)
        for attempt in 0 ..< 100:
          if fileExists(portFile): break
          sleep(50)
        require fileExists(portFile)
        let port = Port(parseInt(readFile(portFile)))
        let before = newSocket()
        before.connect("127.0.0.1", port)
        before.close()
        let originalPath = getEnv("PATH")
        putEnv("PATH", root / "empty-path")
        try: runtime.stop()
        finally: putEnv("PATH", originalPath)
        let after = newSocket()
        defer: after.close()
        expect OSError:
          after.connect("127.0.0.1", port)
    when defined(posix):
      test "missing or broken enumeration never abandons a known owned process":
        let originalPath = getEnv("PATH")
        let python = findExe("python3")
        let realPs = findExe("ps")
        let bin = root / "enumeration-bin"
        createDir(bin)
        let ps = bin / "ps"
        var runtime, unrelated: LocalHarbor
        unrelated.startOwnedProcess(python, @["-c", "import time;time.sleep(60)"])
        defer: unrelated.stop()
        defer:
          putEnv("PATH", originalPath)
          runtime.stop()
        putEnv("PATH", bin)
        expect IOError:
          runtime.startOwnedProcess(python, @["-c", "import time;time.sleep(60)"])
        check runtime.process == nil
        # startOwnedProcess uses Python for its POSIX session boundary.
        createSymlink(python, bin / "python3")
        for failure in ["missing", "nonzero", "hung"]:
          copyFile(realPs, ps)
          setFilePermissions(ps, getFilePermissions(realPs))
          runtime.startOwnedProcess(python, @["-c", "import time;time.sleep(60)"])
          let pid = Pid(runtime.process.processID)
          removeFile(ps)
          if failure == "nonzero":
            writeFile(ps, "#!/bin/sh\nexit 19\n")
            setFilePermissions(ps, {fpUserRead, fpUserWrite, fpUserExec})
          elif failure == "hung":
            writeFile(ps, "#!" & python & "\nimport time;time.sleep(60)\n")
            setFilePermissions(ps, {fpUserRead, fpUserWrite, fpUserExec})
          let started = epochTime()
          runtime.stop()
          check epochTime() - started < 10
          check runtime.process == nil
          check posix.kill(pid, 0) != 0
          let marker = root / "must-not-launch"
          expect IOError:
            runtime.startOwnedProcess(python, @["-c", "from pathlib import Path;Path(" & marker.escape() & ").touch()"] )
          check not fileExists(marker)
          check runtime.process == nil
          check unrelated.process.running
          if fileExists(ps): removeFile(ps)

    when defined(posix):
      test "inherited enumeration output cannot extend its total deadline":
        let priorPath = getEnv("PATH")
        let python = findExe("python3")
        let bin = root / "inherited-enumeration"
        createDir(bin)
        let portFile = root / "enumeration-child-port"
        let child = "import socket,time,pathlib; s=socket.socket(); s.bind(('127.0.0.1',0)); s.listen(); pathlib.Path(" & portFile.escape() & ").write_text(str(s.getsockname()[1])); time.sleep(6)"
        writeFile(bin / "ps", "#!" & python & "\nimport subprocess,time\nsubprocess.Popen([" & python.escape() & ",'-c'," & child.escape() & "])\ntime.sleep(60)\n")
        setFilePermissions(bin / "ps", {fpUserRead, fpUserWrite, fpUserExec})
        putEnv("PATH", bin)
        defer: putEnv("PATH", priorPath)
        var runtime: LocalHarbor
        let started = epochTime()
        expect IOError:
          runtime.startOwnedProcess(python, @["-c", "pass"])
        check epochTime() - started < 2.0
        check runtime.process == nil
        require fileExists(portFile)
        let socket = newSocket()
        defer: socket.close()
        expect OSError:
          socket.connect("127.0.0.1", Port(parseInt(readFile(portFile))))

    test "Harbor config names the REST endpoint and software":
      let path = root / "review.toml"
      writeFile(path, "[agent]\nbackend = \"harbor\"\nharbor_url = \"http://127.0.0.1:8114\"\nharbor_agent = \"codex\"\n")
      let cfg = loadConfig(path)
      check cfg.agent.backendExplicit
      check cfg.agent.harborUrl == "http://127.0.0.1:8114"
      check cfg.agent.harborAgent == "codex"

main()
