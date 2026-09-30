## Production exported worker/session-close/private filesystem regressions.
## No mocks: real Harbor drafts, control registry, shutdown and worker run against
## an unreachable real HTTP endpoint. Failed launch retries exercise actual
## transport refusal; no provider can be spawned at this endpoint. Tests check
## private files and scoped credentials, including a distinct live sibling.
import std/[json, os, options, tempfiles, strutils, unittest]
import isonim/editor/design_review/[agent_routes, control_routes]
import nim_agents

proc scope(controls: EditorControlRegistry): ControlScope =
  let registered = controls.rpcDispatch(%* {"jsonrpc": "2.0", "id": 1,
    "method": "editor.register", "params": {"workspace": "test", "state": {"revision": 0}}}, "bootstrap")["result"]
  controls.validateBrowserScope(%* {"workspace": "test", "instance": registered["instance"],
    "epoch": registered["epoch"]}, registered["browserToken"].getStr())

suite "Scoped provider launch cleanup":
  test "closed captured draft cannot prepare files or resurrect scope":
    let directory = createTempDir("isonim-control-close-", "")
    let oldTmp = getEnv("TMPDIR")
    putEnv("TMPDIR", directory)
    defer:
      if oldTmp.len > 0: putEnv("TMPDIR", oldTmp)
      else: delEnv("TMPDIR")
      removeDir(directory)
    let controls = newEditorControlRegistry("bootstrap")
    let registry = newAgentRegistry(customCmd = "/bin/true", primerEnabled = false,
      workspaceRoot = directory, harborUrl = "http://127.0.0.1:1")
    registry.controlRegistry = controls
    let browserScope = controls.scope()
    let captured = registry.createAcpSession(controlScope = browserScope)
    registry.shutdownAndRelease(captured.sessionId)
    for attempt in 0 .. 1:
      var rejected = false
      try: discard registry.runAgentTurn(captured, @[], nil)
      except HarborError as error:
        rejected = true
        check "closed before provider launch" in error.msg
      check rejected
      check registry.getState(captured.sessionId).isNone
      check not dirExists(directory / ("isonim-control-" & captured.sessionId))
      expect ControlError:
        discard controls.rebindConversation(captured.controlScope, "resurrected")

  test "preparation failure before ownership transfer removes only aborted private directory":
    let directory = createTempDir("isonim-control-prepare-", "")
    let oldTmp = getEnv("TMPDIR")
    putEnv("TMPDIR", directory)
    defer:
      if oldTmp.len > 0: putEnv("TMPDIR", oldTmp)
      else: delEnv("TMPDIR")
      removeDir(directory)
    let controls = newEditorControlRegistry("bootstrap")
    let registry = newAgentRegistry(customCmd = "/bin/true", primerEnabled = false,
      workspaceRoot = directory, harborUrl = "http://127.0.0.1:1")
    registry.controlRegistry = controls
    let draft = registry.createAcpSession(controlScope = controls.scope())
    let runtime = directory / ("isonim-control-" & draft.sessionId)
    # Real filesystem failure: a directory occupies the handoff file's path.
    createDir(runtime / "environment.json")
    expect IOError: discard registry.runAgentTurn(draft, @[], nil)
    check not dirExists(runtime)
    check registry.getState(draft.sessionId).get().controlEnvFile.len == 0
    check registry.getState(draft.sessionId).get().isDraft
    # This still-open conversation can retry after the failed preparation.
    expect HarborError: discard registry.runAgentTurn(draft, @[], nil)
    check fileExists(runtime / "environment.json")
    registry.shutdownAndRelease(draft.sessionId)
    check not dirExists(runtime)

  test "failed live draft retains retry file and unrelated session cleanup cannot remove it":
    let directory = createTempDir("isonim-control-retry-", "")
    let oldTmp = getEnv("TMPDIR")
    putEnv("TMPDIR", directory)
    defer:
      if oldTmp.len > 0: putEnv("TMPDIR", oldTmp)
      else: delEnv("TMPDIR")
      removeDir(directory)
    let controls = newEditorControlRegistry("bootstrap")
    let registry = newAgentRegistry(customCmd = "/bin/true", primerEnabled = false,
      workspaceRoot = directory, harborUrl = "http://127.0.0.1:1")
    registry.controlRegistry = controls
    let browserScope = controls.scope()
    let live = registry.createAcpSession(controlScope = browserScope)
    let closed = registry.createAcpSession(controlScope = browserScope)
    registry.shutdownAndRelease(closed.sessionId)
    let file = directory / ("isonim-control-" & live.sessionId) / "environment.json"
    for attempt in 0 .. 1:
      expect HarborError: discard registry.runAgentTurn(live, @[], nil)
      check registry.getState(live.sessionId).get().isDraft
      check fileExists(file)
      check getFilePermissions(file) == {fpUserRead, fpUserWrite}
      check parseFile(file)["ISONIM_EDITOR_TOKEN"].getStr() == live.controlScope.token
      let bytes = readFile(file)
      expect HarborError: discard registry.runAgentTurn(closed, @[], nil)
      check readFile(file) == bytes
      check not dirExists(directory / ("isonim-control-" & closed.sessionId))
    registry.shutdownAndRelease(live.sessionId)
    check not fileExists(file)
    check not dirExists(file.parentDir)
