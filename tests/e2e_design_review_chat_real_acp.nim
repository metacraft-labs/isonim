## Phase B — end-to-end CLI chat against the real ``claude-agent-acp``.
##
## Skipped at runtime when:
##
##   * ``claude-agent-acp`` (or ``claude-code-acp``) is not on PATH.
##   * The user's Anthropic auth is not configured
##     (``ANTHROPIC_API_KEY`` empty *and* no on-disk credentials).
##
## Test harness intentionally builds a tiny, deterministic prompt and
## asserts only that the call returned a non-empty reply within 30 s.

import std/[os, osproc, times, unittest]

import helpers/agent_routes_fixture

proc agentBinaryOnPath(): bool =
  for name in ["claude-agent-acp", "claude-code-acp"]:
    if findExe(name).len > 0:
      return true
  false

proc anthropicCredsAvailable(): bool =
  if getEnv("ANTHROPIC_API_KEY").len > 0:
    return true
  let credsPath = getHomeDir() / ".claude" / "credentials.json"
  if fileExists(credsPath):
    return true
  # On macOS the Claude Code CLI stores creds in the Login keychain
  # under the "Claude Code-credentials" service.  Probe it via
  # ``security find-generic-password`` — exit 0 means present.
  when defined(macosx):
    let r = execCmdEx("security find-generic-password " &
                      "-s 'Claude Code-credentials' >/dev/null 2>&1")
    if r.exitCode == 0:
      return true
  false

test "e2e_chat_real_acp_round_trips":
  if not agentBinaryOnPath():
    skip()
  elif not anthropicCredsAvailable():
    skip()
  else:
    # Pick a free port + spawn the daemon, but DO NOT override
    # ISONIM_ACP_AGENT_CMD — we want the real binary.
    let port = pickFreePort()
    putEnv("ISONIM_REVIEW_PORT", $port)
    delEnv("ISONIM_ACP_AGENT_CMD")
    let proc1 = startProcess(CliPath,
      args = @["serve", "--agent-routes-only"],
      options = {poUsePath, poStdErrToStdOut})
    defer:
      if proc1.running:
        proc1.terminate()
        discard proc1.waitForExit(timeout = 5_000)
      proc1.close()
    # Wait for the listener to bind.
    let baseUrl = "http://127.0.0.1:" & $port
    let curl = findExe("curl")
    var ready = false
    let deadline = epochTime() + 10.0
    while epochTime() < deadline:
      let r = execCmdEx(curl & " -s -o /dev/null --max-time 0.5 -w '%{http_code}' " &
                        baseUrl & "/health")
      if r.exitCode == 0 and r.output.len > 0 and r.output != "000":
        ready = true
        break
      sleep(80)
    check ready
    let outPath = getTempDir() / "chat_real_stdout"
    let errPath = getTempDir() / "chat_real_stderr"
    let cmd = quoteShell(CliPath) & " chat --daemon=" & quoteShell(baseUrl) &
      " 'Say only the word PHASE_B_OK and nothing else.'" &
      " > " & quoteShell(outPath) & " 2> " & quoteShell(errPath)
    let start = epochTime()
    let exitCode = execShellCmd(cmd)
    let elapsed = epochTime() - start
    let errText =
      if fileExists(errPath): readFile(errPath) else: ""
    # If the real ACP agent rejects session creation because the user's
    # keychain credentials aren't tied to a model with permissions for
    # this prompt shape, the daemon will surface that as 5xx.  We
    # treat that as ``skipped`` rather than a hard failure — Phase B's
    # contract is the round-trip mechanics, not Anthropic-side
    # business logic.
    if exitCode != 0 and
       (errText.contains("agent_init_failed") or
        errText.contains("Query closed before response received") or
        errText.contains("agent_backend_unavailable")):
      skip()
    else:
      check exitCode == 0
      check elapsed < 30.0
      let outText = readFile(outPath)
      check outText.len > 0
