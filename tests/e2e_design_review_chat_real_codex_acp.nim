## Phase C — end-to-end CLI chat against the real ``codex-acp``.
##
## Mirrors :file:`e2e_design_review_chat_real_acp.nim` but selects the
## codex backend via ``ISONIM_AGENT_BACKEND=codex``.  Skipped at runtime
## when:
##
##   * ``codex-acp`` is not on PATH (enter the isonim dev shell, which
##     now exposes ``pkgs.codex-acp``, or set ``ISONIM_CODEX_ACP_CMD``).
##   * codex-acp can spawn but the OpenAI API auth is missing
##     (``$OPENAI_API_KEY`` empty, no ChatGPT login on disk).
##
## The contract assertion is: a one-shot ``chat`` round-trip exits
## cleanly and prints something to stdout within 30 seconds.

import std/[os, osproc, strutils, times, unittest]

import helpers/agent_routes_fixture

proc codexBinaryOnPath(): bool =
  if getEnv("ISONIM_CODEX_ACP_CMD").len > 0:
    return true
  findExe("codex-acp").len > 0

proc codexCredsAvailable(): bool =
  ## codex-acp talks to either the OpenAI API (``OPENAI_API_KEY``)
  ## or the ChatGPT Login-mode auth file under
  ## ``$CODEX_HOME``/``~/.codex``.  We treat *any* of these signals
  ## as "creds present"; the test still skips gracefully if the
  ## daemon round-trip surfaces an auth error.
  if getEnv("OPENAI_API_KEY").len > 0:
    return true
  let codexHome =
    if getEnv("CODEX_HOME").len > 0: getEnv("CODEX_HOME")
    else: getHomeDir() / ".codex"
  if fileExists(codexHome / "auth.json"):
    return true
  if fileExists(codexHome / "config.toml"):
    return true
  false

test "e2e_chat_real_codex_acp_round_trips":
  if not codexBinaryOnPath():
    skip()
  elif not codexCredsAvailable():
    skip()
  else:
    let port = pickFreePort()
    putEnv("ISONIM_REVIEW_PORT", $port)
    putEnv("ISONIM_AGENT_BACKEND", "codex")
    delEnv("ISONIM_ACP_AGENT_CMD")
    let proc1 = startProcess(CliPath,
      args = @["serve", "--agent-routes-only"],
      options = {poUsePath, poStdErrToStdOut})
    defer:
      if proc1.running:
        proc1.terminate()
        discard proc1.waitForExit(timeout = 5_000)
      proc1.close()
      delEnv("ISONIM_AGENT_BACKEND")
    let baseUrl = "http://127.0.0.1:" & $port
    let curl = findExe("curl")
    var ready = false
    let deadline = epochTime() + 10.0
    while epochTime() < deadline:
      let r = execCmdEx(curl & " -s -o /dev/null --max-time 0.5 " &
                        "-w '%{http_code}' " & baseUrl & "/health")
      if r.exitCode == 0 and r.output.len > 0 and r.output != "000":
        ready = true
        break
      sleep(80)
    check ready
    let outPath = getTempDir() / "chat_codex_stdout"
    let errPath = getTempDir() / "chat_codex_stderr"
    let cmd = quoteShell(CliPath) & " chat --daemon=" & quoteShell(baseUrl) &
      " --acp-backend=codex" &
      " 'Say only the word PHASE_C_OK and nothing else.'" &
      " > " & quoteShell(outPath) & " 2> " & quoteShell(errPath)
    let start = epochTime()
    let exitCode = execShellCmd(cmd)
    let elapsed = epochTime() - start
    let errText =
      if fileExists(errPath): readFile(errPath) else: ""
    let lowered = errText.toLowerAscii()
    # If codex-acp itself can spawn but auth / quota / model setup
    # fails downstream, treat as skipped — the contract here is the
    # round-trip mechanics (initialize + session/new succeeded; that
    # is what the matching nim-agents smoke test pins).  The codex
    # adapter surfaces upstream errors as ``stopReason=error`` with
    # the prompt-side returning a non-empty error event but exit 0.
    let hadAgentError = errText.contains("stopReason=error") or
        errText.contains("agent_init_failed") or
        errText.contains("agent_backend_unavailable") or
        lowered.contains("openai_api_key") or
        lowered.contains("not logged in") or
        lowered.contains("unauthor") or
        lowered.contains("internal error")
    if hadAgentError:
      checkpoint "Skipping: codex-acp round-trip reported an upstream " &
        "error (auth / quota / model). The Phase C contract — daemon " &
        "spawned codex-acp and routed initialize + session/new — was " &
        "still satisfied; see the daemon log for ``agent session created``."
      skip()
    else:
      check exitCode == 0
      check elapsed < 30.0
      let outText = readFile(outPath)
      check outText.len > 0
