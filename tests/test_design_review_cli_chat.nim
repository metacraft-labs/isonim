## Phase B — ``isonim-review chat`` CLI tests.
##
## Each test spawns the daemon in agent-routes-only mode with the fake
## ACP agent, then runs ``build/bin/isonim-review chat`` as a real
## subprocess and asserts stdout / stderr separation.

import std/[os, osproc, strutils, times, unittest]

import helpers/agent_routes_fixture

proc invokeChat(baseUrl: string;
                args: openArray[string];
                env: openArray[(string, string)] = @[]):
    tuple[exitCode: int; outText, errText: string] =
  ## Run ``isonim-review chat <args>`` with stdout/stderr captured
  ## separately.  Returns the trio so each test can assert on whatever
  ## stream it cares about.
  let outPath = getTempDir() / "chat_stdout_" &
                $((int(epochTime() * 1000)) mod 1_000_000)
  let errPath = getTempDir() / "chat_stderr_" &
                $((int(epochTime() * 1000)) mod 1_000_000)
  defer:
    try: removeFile(outPath) except OSError: discard
    try: removeFile(errPath) except OSError: discard
  let cmdParts = @[CliPath, "chat", "--daemon=" & baseUrl] & @args
  var envStr = ""
  for kv in env:
    envStr.add kv[0] & "=" & quoteShell(kv[1]) & " "
  let cmd = envStr & "ISONIM_ACP_AGENT_CMD=" & quoteShell(FakeAcpPath) &
    " " & cmdParts.join(" ") &
    " > " & quoteShell(outPath) & " 2> " & quoteShell(errPath)
  let exitCode = execShellCmd(cmd)
  let outText =
    if fileExists(outPath): readFile(outPath) else: ""
  let errText =
    if fileExists(errPath): readFile(errPath) else: ""
  (exitCode, outText, errText)

# --------------------------------------------------------------------------- #
#  One-shot mode.                                                              #
# --------------------------------------------------------------------------- #

test "test_cli_chat_one_shot_against_canned_backend":
  let f = startAgentDaemon()
  defer: f.shutdown()
  let (exitCode, outText, errText) = invokeChat(f.baseUrl, ["hi"])
  check exitCode == 0
  # Agent's canned reply ``PHASE_B_OK`` lands on stdout.
  check outText.contains("PHASE_B_OK")
  # Chronicles logs land on stderr — the chat session announcement
  # is the load-bearing line for diagnostics.
  check errText.contains("cli chat starting") or
        errText.contains("cli chat exited")
  check errText.contains("topics=\"cli\"")
  check errText.contains("stopReason=end_turn")

# --------------------------------------------------------------------------- #
#  Interactive mode.                                                           #
# --------------------------------------------------------------------------- #

test "test_cli_chat_interactive_mode_loops":
  let f = startAgentDaemon()
  defer: f.shutdown()
  # We need to feed stdin three prompts; the helper above doesn't
  # support that, so we run a dedicated invocation here.
  let outPath = getTempDir() / "chat_repl_stdout_" &
                $((int(epochTime() * 1000)) mod 1_000_000)
  let errPath = getTempDir() / "chat_repl_stderr_" &
                $((int(epochTime() * 1000)) mod 1_000_000)
  defer:
    try: removeFile(outPath) except OSError: discard
    try: removeFile(errPath) except OSError: discard
  let cmd = "ISONIM_ACP_AGENT_CMD=" & quoteShell(FakeAcpPath) & " " &
    "printf 'one\\ntwo\\nthree\\n' | " &
    quoteShell(CliPath) & " chat --interactive --daemon=" &
    quoteShell(f.baseUrl) &
    " > " & quoteShell(outPath) & " 2> " & quoteShell(errPath)
  let exitCode = execShellCmd(cmd)
  check exitCode == 0
  let outText = readFile(outPath)
  let errText = readFile(errPath)
  # Three prompts → three PHASE_B_OK replies streamed to stdout.
  check outText.count("PHASE_B_OK") == 3
  # The session id is logged once when ``chat starting`` fires and
  # should be stable across the three prompts — assert it shows up
  # at least three times in the chronicles output.
  let sessionLogs = errText.count("chat session ")
  check sessionLogs >= 3
  # All three round-trips report stopReason=end_turn.
  check errText.count("stopReason=end_turn") >= 3

# --------------------------------------------------------------------------- #
#  --log-level changes stderr verbosity.                                       #
# --------------------------------------------------------------------------- #

test "test_cli_chat_log_level_changes_verbosity":
  let f = startAgentDaemon()
  defer: f.shutdown()
  let defaultRun = invokeChat(f.baseUrl, ["hi"])
  let debugRun = invokeChat(f.baseUrl,
                            ["--log-level=debug", "hi"])
  check defaultRun.exitCode == 0
  check debugRun.exitCode == 0
  # Both runs see PHASE_B_OK on stdout — the change is on stderr.
  check defaultRun.outText.contains("PHASE_B_OK")
  check debugRun.outText.contains("PHASE_B_OK")
  # Debug emits at least one ``agent update`` line that INFO does not.
  check not defaultRun.errText.contains("DBG ")
  check debugRun.errText.contains("DBG ")
  # And the total line count goes up.
  let defaultLines = defaultRun.errText.splitLines.len
  let debugLines = debugRun.errText.splitLines.len
  check debugLines > defaultLines
