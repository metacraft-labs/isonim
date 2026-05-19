## REV-M1: ``isonim-review`` CLI entry point.
##
## Builds to ``build/bin/isonim-review`` via the Justfile target
## ``isonim-review-build``. Only one subcommand is implemented in this
## milestone — additional commands (``init``, ``db-health``,
## ``start-run``, ``run-review``, ``serve``) land in REV-M3+ as
## documented in the milestones file.
##
## Subcommand layout:
##
##   isonim-review briefs check --project <path>
##
## Discovers ``<path>/briefs/`` (or the ``--project`` path itself if it
## already ends in ``briefs``), walks every brief, and prints a status
## summary. Exit 0 if every brief parses; exit 1 if any error.

import std/[os, strutils, strformat, tables]
import isonim/editor/design_review/brief_format
import isonim/editor/design_review/brief_index

const Usage = """
isonim-review — IsoNim design-review CLI

Usage:
  isonim-review briefs check --project <path>
      Walk <path>/briefs/ and report parse status for every brief.
      Exit 0 if all briefs parse; exit 1 if any error.

  isonim-review --help
      Print this message.
"""

proc resolveBriefsDir(projectPath: string): string =
  ## Accepts either a project root (containing ``briefs/``) or a direct
  ## briefs directory. Returns the directory that should be walked.
  if projectPath.len == 0:
    return ""
  let direct = projectPath / "briefs"
  if dirExists(direct):
    return direct
  return projectPath

proc errorClassName(msg: string; field: string): string =
  ## Map a brief-parse error message back to its error-class name so
  ## the CLI output is machine-readable. The walker only carries
  ## ``BriefIndexError`` (path + message), so we infer the class from
  ## message contents — this mirrors what ``parseBrief`` raises.
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
  ## Pull the field name out of the canonical error message
  ## ``missing required field 'X' in ...``. Returns "" if not found.
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
  else:
    stderr.write(fmt"isonim-review: unknown command '{rawArgs[0]}'" & "\n")
    stderr.write(Usage)
    return 2

when isMainModule:
  quit(main())
