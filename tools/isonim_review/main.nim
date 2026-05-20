## REV-M1 / REV-M4: ``isonim-review`` CLI entry point.
##
## Builds to ``build/bin/isonim-review`` via the Justfile target
## ``isonim-review-build``.
##
## Subcommand layout:
##
##   isonim-review briefs check --project <path>
##       (REV-M1) Walk <path>/briefs/ and report parse status for
##       every brief.  Exit 0 if all parse; exit 1 if any error.
##
##   isonim-review init [--config <path>] [--migrations <dir>]
##       (REV-M4) Apply db/migrations/*.sql idempotently as the
##       migrator role.  Honors content-hash drift detection.
##
##   isonim-review db-health [--json] [--config <path>] [--migrations <dir>]
##       (REV-M4) Run the five health probes; exit 0 if every DB
##       probe is green.
##
##   isonim-review serve [--config <path>] [--migrations <dir>]
##       (REV-M4) Long-running HTTP daemon.  Currently exposes
##       ``GET /health``; REV-M7/M8 will wire the rest of
##       ``/api/design-review/*``.
##
##   isonim-review --help
##       Print the usage block.

import std/[os, strutils, strformat, tables]

import isonim/editor/design_review/brief_format
import isonim/editor/design_review/brief_index
import isonim/editor/design_review/log_setup

import ./config
import ./cmd_init
import ./cmd_db_health
import ./cmd_serve
import ./cmd_capture
import ./cmd_run_review
import ./cmd_layouts
import ./cmd_chat

const Usage = """
isonim-review — IsoNim design-review CLI

Usage:
  isonim-review briefs check --project <path>
      Walk <path>/briefs/ and report parse status for every brief.
      Exit 0 if all briefs parse; exit 1 if any error.

  isonim-review init [--config <path>] [--migrations <dir>]
      Apply db/migrations/*.sql against the running cluster as the
      migrator role.  Idempotent: already-applied versions are
      skipped; content-hash drift fails loudly.

  isonim-review db-health [--json] [--config <path>] [--migrations <dir>]
      Run five health probes (postgres, app role, migrator role,
      schema version, process-compose).  Exit 0 if all DB probes
      pass; non-zero otherwise.

  isonim-review serve [--config <path>] [--migrations <dir>]
      Start the HTTP daemon (default bind: 127.0.0.1:8113).
      GET /health returns the same JSON as db-health --json.
      REV-M7/M8 will mount /api/design-review/* routes here.

  isonim-review capture --brief <briefId> [--viewport <label>]
                        [--bridge <url>] [--workspace <path>]
                        [--project <path>] [--config <path>]
                        [--backend-binary-dir <path>]
                        [--backends <web,tui,...>]
      (REV-M5) Drive a full capture sweep against the
      isonim-render-serve bridge.  Refuses to run unless every repo
      in the workspace is clean and pinned.  Stores PNGs under the
      configured store path and writes a row to design_review.captures
      per (preview, viewport).
      When --bridge is supplied the pipeline talks to that single
      WebSocket URL for every backend (the original REV-M5 contract,
      still used by the fake-bridge regression suite).  When --bridge
      is omitted the pipeline spawns a per-backend launcher binary
      (`isonim-examples-<backend>`) for each (preview, backend) tuple;
      --backend-binary-dir (or [backend].binary_dir in TOML, or
      $ISONIM_REVIEW_BACKEND_BIN_DIR) selects the search directory.
      --backends limits the sweep to the listed comma-separated set.

  isonim-review run-review --run <run_id>
                           [--agent-backend canned|claude-code]
                           [--acp-backend claude|codex|custom]
                           [--canned-path <md>]
                           [--agent-name <name>] [--agent-version <ver>]
                           [--prompt-template <path>]
                           [--workspace <path>] [--project <path>]
                           [--config <path>]
                           [--dry-run [--dry-run-out <path>]]
      (REV-M6) Drive a review against a completed capture run.
      Resolves the brief at the run's manifest pin via `git show`,
      assembles the reviewer prompt, invokes the configured agent
      backend (canned for CI, claude-code for production), and
      persists the result via design_review.record_agent_report +
      design_review.finish_run.  Idempotent on
      (run_id, agent_name, agent_version).

  isonim-review layouts ls --brief <id> [--user <id>] [--json]
                              [--config <path>]
      (REV-M8) List gallery layouts for the brief.  Workspace-scope
      rows are always included; user-scope rows are included when
      --user <id> matches their owner.

  isonim-review layouts save --brief <id> --name <name>
                              --layout <path-to-json>
                              [--scope user|workspace] [--user <id>]
                              [--layout-id <uuid>] [--expected-version <n>]
                              [--config <path>]
      (REV-M8) Insert or update a layout row.  --layout points at
      a file whose content becomes the layout JSONB.  Returns the
      new row's JSON on stdout.

  isonim-review layouts promote --layout-id <uuid> --actor <name>
                                 [--config <path>]
      (REV-M8) Promote a user-scope layout into a new workspace-
      scope row.  Prints the new layout id on stdout.

  isonim-review chat [--session <id>] [--no-stream] [--interactive]
                      [--daemon <url>] [--agent-backend claude|codex|custom]
                      [<prompt>]
      (Phase B) Drive the daemon's /api/agent/* endpoints from the CLI.
      One-shot: a single positional <prompt> is sent and the agent's
      reply is written to stdout.  --interactive enters a REPL loop
      that reuses the same session id across prompts.  Pass --no-stream
      to suppress live text on stdout (useful in scripts that only
      care about exit codes).  --agent-backend overrides the
      [agent].backend setting from config (claude = claude-agent-acp,
      codex = codex-acp, custom = the binary named in [agent].command).
      The synonym --acp-backend is also accepted; for ``run-review``
      use --acp-backend to avoid colliding with the reviewer-pipeline
      selector.

  isonim-review --log-level <level>
      Set the chronicles runtime log level for any subcommand.
      Valid levels: trace, debug, info (default), warn, error, none.

  isonim-review --help
      Print this message.
"""

# --------------------------------------------------------------------------
# Shared arg parsing helpers.  REV-M1 stayed with hand-rolled flag
# extraction because ``std/parseopt`` doesn't play nicely with
# subcommand-style CLIs; we continue that pattern here.
# --------------------------------------------------------------------------

proc parseSubArgs(args: seq[string]; expectedFlag: string): string =
  ## Tiny argument parser for ``--key value`` or ``--key=value``.
  var i = 0
  while i < args.len:
    let a = args[i]
    if a == "--" & expectedFlag:
      if i + 1 < args.len:
        return args[i + 1]
      return ""
    if a.startsWith("--" & expectedFlag & "="):
      return a[(expectedFlag.len + 3) .. ^1]
    inc i
  return ""

proc hasFlag(args: seq[string]; flag: string): bool =
  for a in args:
    if a == "--" & flag:
      return true
  false

proc applyAgentBackendOverride(cfg: var ReviewConfig; rest: seq[string]) =
  ## Honour ``--agent-backend=claude|codex|custom`` (and the synonym
  ## ``--acp-backend=...`` — used on ``run-review`` where the bare
  ## ``--agent-backend`` already selects the reviewer pipeline,
  ## canned vs daemon vs claude-code) on subcommands that take config.
  ## Overrides ``[agent].backend`` in memory and re-runs
  ## :proc:`validateAgentConfig` so a typo on the CLI is caught here
  ## rather than at session spawn time.
  var override = parseSubArgs(rest, "acp-backend")
  if override.len == 0:
    let agentBackendFlag = parseSubArgs(rest, "agent-backend")
    # Only treat ``--agent-backend`` as the ACP selector when the value
    # is one of the recognised ACP kinds; otherwise it belongs to
    # ``run-review``'s reviewer-pipeline selector.
    if agentBackendFlag.toLowerAscii() in
        ["claude", "codex", "custom",
         "claude-code-acp", "claude-agent-acp", "codex-acp"]:
      override = agentBackendFlag
  if override.len == 0:
    return
  cfg.agent.backend = override
  try:
    validateAgentConfig(cfg)
  except AgentConfigError as e:
    stderr.writeLine("isonim-review: " & e.msg)
    quit(2)

# --------------------------------------------------------------------------
# REV-M1: briefs check
# --------------------------------------------------------------------------

proc resolveBriefsDir(projectPath: string): string =
  if projectPath.len == 0:
    return ""
  let direct = projectPath / "briefs"
  if dirExists(direct):
    return direct
  return projectPath

proc errorClassName(msg: string; field: string): string =
  if msg.contains("duplicate briefId"):
    return "DuplicateBriefIdError"
  if msg.contains("missing required field"):
    let f = if field.len > 0: field else: "?"
    return fmt"MissingRequiredFieldError({f})"
  if msg.contains("does not match directory"):
    return "BriefKindMismatchError"
  if msg.contains("unknown backend"):
    return "UnknownBackendError"
  if msg.contains("weights sum to"):
    return "ScoringWeightSumError"
  return "BriefParseError"

proc inferField(msg: string): string =
  const Needle = "missing required field '"
  let idx = msg.find(Needle)
  if idx < 0: return ""
  let after = msg[idx + Needle.len .. ^1]
  let endIdx = after.find('\'')
  if endIdx < 0: return ""
  return after[0 ..< endIdx]

proc cmdBriefsCheck(project: string): int =
  let briefsDir = resolveBriefsDir(project)
  if briefsDir.len == 0 or not dirExists(briefsDir):
    stderr.write(fmt"isonim-review: briefs directory not found: '{project}'" & "\n")
    return 1
  let idx = buildBriefIndex(briefsDir)
  let okCount = idx.byBriefId.len
  let errCount = idx.errors.len
  if errCount == 0:
    echo fmt"{okCount} briefs OK"
    for briefId, brief in idx.byBriefId.pairs:
      var coveredPreviews = 0
      for cov in brief.coversPreviews:
        coveredPreviews += cov.backends.len
      echo fmt"  {briefId}: {coveredPreviews} previews"
    return 0
  else:
    for err in idx.errors:
      let field = inferField(err.message)
      let cls = errorClassName(err.message, field)
      stderr.write(fmt"{err.path}: {cls}" & "\n")
    stderr.write(fmt"{okCount} briefs OK, {errCount} broken" & "\n")
    return 1

# --------------------------------------------------------------------------
# REV-M4: init / db-health / serve
# --------------------------------------------------------------------------

proc resolveConfigAndDir(rest: seq[string]):
    tuple[cfg: ReviewConfig; migDir: string] =
  let configPath = parseSubArgs(rest, "config")
  let migDirFlag = parseSubArgs(rest, "migrations")
  var cfg =
    try: loadConfig(configPath)
    except TomlParseError as e:
      stderr.writeLine("isonim-review: " & e.msg)
      quit(2)
    except AgentConfigError as e:
      stderr.writeLine("isonim-review: " & e.msg)
      quit(2)
  applyAgentBackendOverride(cfg, rest)
  let migDir =
    if migDirFlag.len > 0: migDirFlag
    else: getCurrentDir() / "db" / "migrations"
  (cfg, migDir)

proc dispatchInit(rest: seq[string]): int =
  let (cfg, migDir) = resolveConfigAndDir(rest)
  cmdInit(cfg, migDir)

proc dispatchDbHealth(rest: seq[string]): int =
  let (cfg, migDir) = resolveConfigAndDir(rest)
  let asJson = hasFlag(rest, "json")
  cmdDbHealth(cfg, asJson, migDir)

proc dispatchServe(rest: seq[string]): int =
  let (cfg, migDir) = resolveConfigAndDir(rest)
  let agentRoutesOnly = hasFlag(rest, "agent-routes-only")
  cmdServe(cfg, migDir, agentRoutesOnly)

proc hasNamedFlag(args: seq[string]; expectedFlag: string): bool =
  ## True iff ``--<expectedFlag>`` or ``--<expectedFlag>=...`` appears
  ## in ``args``.  Distinct from ``hasFlag`` above (which only matches
  ## the bare form): the capture dispatcher needs to know whether the
  ## user gave us a ``--bridge`` *at all*, so an explicit empty value
  ## still counts as "supplied".
  for a in args:
    if a == "--" & expectedFlag:
      return true
    if a.startsWith("--" & expectedFlag & "="):
      return true
  false

proc dispatchCapture(rest: seq[string]): int =
  let configPath = parseSubArgs(rest, "config")
  var cfg =
    try: loadConfig(configPath)
    except TomlParseError as e:
      stderr.writeLine("isonim-review: " & e.msg)
      quit(2)
    except AgentConfigError as e:
      stderr.writeLine("isonim-review: " & e.msg)
      quit(2)
  applyAgentBackendOverride(cfg, rest)
  let briefId         = parseSubArgs(rest, "brief")
  let viewport        = parseSubArgs(rest, "viewport")
  let bridgeUrl       = parseSubArgs(rest, "bridge")
  let bridgeProvided  = hasNamedFlag(rest, "bridge")
  let workspace       = parseSubArgs(rest, "workspace")
  let project         = parseSubArgs(rest, "project")
  let backendBinDir   = parseSubArgs(rest, "backend-binary-dir")
  let backends        = parseSubArgs(rest, "backends")
  # ``cmd_capture`` treats an empty ``bridgeUrl`` as "use the launcher
  # path".  Preserve the original "--bridge with empty value" sentinel
  # by tagging it as the default fixed bridge so the legacy contract
  # still works (REV-M5 tests pass --bridge explicitly).
  let effectiveBridge =
    if bridgeProvided and bridgeUrl.len == 0: DefaultBridgeUrl
    else: bridgeUrl
  cmdCapture(cfg, briefId, viewport, effectiveBridge, workspace, project,
             backendBinDir, backends)

proc dispatchLayouts(rest: seq[string]): int =
  if rest.len == 0:
    stderr.write("isonim-review layouts: missing sub-subcommand (ls / save / promote)\n")
    return 2
  let sub = rest[0]
  let tail = if rest.len > 1: rest[1 .. ^1] else: @[]
  let configPath = parseSubArgs(tail, "config")
  var cfg =
    try: loadConfig(configPath)
    except TomlParseError as e:
      stderr.writeLine("isonim-review: " & e.msg)
      quit(2)
    except AgentConfigError as e:
      stderr.writeLine("isonim-review: " & e.msg)
      quit(2)
  applyAgentBackendOverride(cfg, tail)
  case sub
  of "ls":
    let briefId = parseSubArgs(tail, "brief")
    let userId  = parseSubArgs(tail, "user")
    let asJson  = hasFlag(tail, "json")
    return cmdLayoutsLs(cfg, briefId, userId, asJson)
  of "save":
    let briefId = parseSubArgs(tail, "brief")
    let name    = parseSubArgs(tail, "name")
    let layoutPath = parseSubArgs(tail, "layout")
    let scope   = parseSubArgs(tail, "scope")
    let userId  = parseSubArgs(tail, "user")
    let layoutId = parseSubArgs(tail, "layout-id")
    let expV    = parseSubArgs(tail, "expected-version")
    let (expVal, hasExp) =
      if expV.len == 0: (0, false)
      else:
        try: (parseInt(expV), true)
        except ValueError:
          stderr.writeLine("isonim-review layouts save: --expected-version must be an integer")
          quit(2)
    return cmdLayoutsSave(cfg, briefId, name, layoutPath, scope, userId,
                          layoutId, expVal, hasExp)
  of "promote":
    let layoutId = parseSubArgs(tail, "layout-id")
    let actor    = parseSubArgs(tail, "actor")
    return cmdLayoutsPromote(cfg, layoutId, actor)
  else:
    stderr.write("isonim-review layouts: unknown sub-subcommand: " & sub & "\n")
    return 2

proc dispatchChat(rest: seq[string]): int =
  ## Phase B — ``isonim-review chat``.
  let configPath = parseSubArgs(rest, "config")
  var cfg =
    try: loadConfig(configPath)
    except TomlParseError as e:
      stderr.writeLine("isonim-review: " & e.msg)
      quit(2)
    except AgentConfigError as e:
      stderr.writeLine("isonim-review: " & e.msg)
      quit(2)
  applyAgentBackendOverride(cfg, rest)
  var opts = ChatOptions(streamOutput: true)
  opts.daemonUrl = parseSubArgs(rest, "daemon")
  opts.sessionId = parseSubArgs(rest, "session")
  opts.interactive = hasFlag(rest, "interactive")
  if hasFlag(rest, "no-stream"):
    opts.streamOutput = false
  # Collect the positional prompt — every arg that does not start with
  # ``--`` and is not the value of a recognised ``--flag value`` pair.
  var positionals: seq[string] = @[]
  var i = 0
  while i < rest.len:
    let a = rest[i]
    if a.startsWith("--"):
      # Skip the value of ``--flag value`` (but not ``--flag=value``).
      if not a.contains('='):
        if a in ["--interactive", "--no-stream"]:
          inc i
          continue
        if i + 1 < rest.len and not rest[i + 1].startsWith("--"):
          inc i, 2
          continue
      inc i
      continue
    positionals.add a
    inc i
  opts.promptText = positionals.join(" ")
  return cmdChat(cfg, opts)

proc dispatchRunReview(rest: seq[string]): int =
  let configPath = parseSubArgs(rest, "config")
  var cfg =
    try: loadConfig(configPath)
    except TomlParseError as e:
      stderr.writeLine("isonim-review: " & e.msg)
      quit(2)
    except AgentConfigError as e:
      stderr.writeLine("isonim-review: " & e.msg)
      quit(2)
  applyAgentBackendOverride(cfg, rest)
  let runId        = parseSubArgs(rest, "run")
  let agentBackend = parseSubArgs(rest, "agent-backend")
  let cannedPath   = parseSubArgs(rest, "canned-path")
  let agentName    = parseSubArgs(rest, "agent-name")
  let agentVersion = parseSubArgs(rest, "agent-version")
  let promptTpl    = parseSubArgs(rest, "prompt-template")
  let workspace    = parseSubArgs(rest, "workspace")
  let project      = parseSubArgs(rest, "project")
  let dryRunOut    = parseSubArgs(rest, "dry-run-out")
  let dryRun       = hasFlag(rest, "dry-run") or dryRunOut.len > 0
  cmdRunReview(cfg, runId, agentBackend, cannedPath, agentName,
               agentVersion, promptTpl, workspace, project,
               dryRunOut, dryRun)

# --------------------------------------------------------------------------
# Top-level dispatch
# --------------------------------------------------------------------------

proc extractGlobalFlags(args: var seq[string]):
    tuple[logLevel: string] =
  ## Strip recognised global flags from ``args`` in place and return the
  ## parsed values.  Subcommand dispatchers receive a copy that no
  ## longer contains the global flags, so they don't need to know
  ## about ``--log-level``.
  var kept: seq[string] = @[]
  var i = 0
  while i < args.len:
    let a = args[i]
    if a == "--log-level":
      if i + 1 < args.len:
        result.logLevel = args[i + 1]
        inc i, 2
        continue
      else:
        inc i
        continue
    if a.startsWith("--log-level="):
      result.logLevel = a[("--log-level=").len .. ^1]
      inc i
      continue
    kept.add a
    inc i
  args = kept

proc main(): int =
  var rawArgs: seq[string] = @[]
  for i in 1 .. paramCount():
    rawArgs.add(paramStr(i))

  let globals = extractGlobalFlags(rawArgs)
  try:
    configureLogging(globals.logLevel)
  except InvalidLogLevelError as e:
    stderr.writeLine("isonim-review: " & e.msg)
    return 2

  if rawArgs.len == 0 or rawArgs[0] in ["--help", "-h"]:
    echo Usage
    return 0

  case rawArgs[0]
  of "briefs":
    if rawArgs.len < 2 or rawArgs[1] != "check":
      stderr.write("isonim-review briefs: unknown sub-subcommand\n")
      stderr.write(Usage)
      return 2
    let rest = rawArgs[2 .. ^1]
    let project = parseSubArgs(rest, "project")
    if project.len == 0:
      stderr.write("isonim-review briefs check: --project <path> is required\n")
      return 2
    return cmdBriefsCheck(project)
  of "init":
    return dispatchInit(rawArgs[1 .. ^1])
  of "db-health":
    return dispatchDbHealth(rawArgs[1 .. ^1])
  of "serve":
    return dispatchServe(rawArgs[1 .. ^1])
  of "capture":
    return dispatchCapture(rawArgs[1 .. ^1])
  of "run-review":
    return dispatchRunReview(rawArgs[1 .. ^1])
  of "layouts":
    return dispatchLayouts(rawArgs[1 .. ^1])
  of "chat":
    return dispatchChat(rawArgs[1 .. ^1])
  else:
    stderr.write(fmt"isonim-review: unknown command '{rawArgs[0]}'" & "\n")
    stderr.write(Usage)
    return 2

when isMainModule:
  quit(main())
