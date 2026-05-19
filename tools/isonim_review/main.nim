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

import ./config
import ./cmd_init
import ./cmd_db_health
import ./cmd_serve
import ./cmd_capture
import ./cmd_run_review

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
      (REV-M5) Drive a full capture sweep against the
      isonim-render-serve bridge.  Refuses to run unless every repo
      in the workspace is clean and pinned.  Stores PNGs under the
      configured store path and writes a row to design_review.captures
      per (preview, viewport).

  isonim-review run-review --run <run_id>
                           [--agent-backend canned|claude-code]
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
  let cfg =
    try: loadConfig(configPath)
    except TomlParseError as e:
      stderr.writeLine("isonim-review: " & e.msg)
      quit(2)
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
  cmdServe(cfg, migDir)

proc dispatchCapture(rest: seq[string]): int =
  let configPath = parseSubArgs(rest, "config")
  let cfg =
    try: loadConfig(configPath)
    except TomlParseError as e:
      stderr.writeLine("isonim-review: " & e.msg)
      quit(2)
  let briefId   = parseSubArgs(rest, "brief")
  let viewport  = parseSubArgs(rest, "viewport")
  let bridgeUrl = parseSubArgs(rest, "bridge")
  let workspace = parseSubArgs(rest, "workspace")
  let project   = parseSubArgs(rest, "project")
  cmdCapture(cfg, briefId, viewport, bridgeUrl, workspace, project)

proc dispatchRunReview(rest: seq[string]): int =
  let configPath = parseSubArgs(rest, "config")
  let cfg =
    try: loadConfig(configPath)
    except TomlParseError as e:
      stderr.writeLine("isonim-review: " & e.msg)
      quit(2)
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

proc main(): int =
  var rawArgs: seq[string] = @[]
  for i in 1 .. paramCount():
    rawArgs.add(paramStr(i))

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
  else:
    stderr.write(fmt"isonim-review: unknown command '{rawArgs[0]}'" & "\n")
    stderr.write(Usage)
    return 2

when isMainModule:
  quit(main())
