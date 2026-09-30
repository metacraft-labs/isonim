## Optional sibling discovery uses real temporary checkout directories.
## No processes or HTTP transports are mocked. The fixtures contain only the
## repository marker files needed for discovery. Assertions cover the absence
## of a private checkout, workspace isolation, explicit overrides, and an
## explicit agent setting that must prevent any local build or service spawn.
import std/[os, osproc, tempfiles, unittest, net, strutils]
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
        writeFile(childScript, "import http.server, pathlib, sys\n" &
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
        runtime.stop()
        let after = newSocket()
        defer: after.close()
        expect OSError:
          after.connect("127.0.0.1", port)
    test "Harbor config names the REST endpoint and software":
      let path = root / "review.toml"
      writeFile(path, "[agent]\nbackend = \"harbor\"\nharbor_url = \"http://127.0.0.1:8114\"\nharbor_agent = \"codex\"\n")
      let cfg = loadConfig(path)
      check cfg.agent.backendExplicit
      check cfg.agent.harborUrl == "http://127.0.0.1:8114"
      check cfg.agent.harborAgent == "codex"

main()
