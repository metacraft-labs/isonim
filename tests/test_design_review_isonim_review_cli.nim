## REV-M1: CLI integration tests for ``build/bin/isonim-review``.
##
## Spawns the compiled binary via ``osproc.startProcess`` (the
## milestone's non-negotiable: no in-process function calls).

import std/[unittest, os, osproc, strutils, streams]

const RepoRoot = currentSourcePath().parentDir().parentDir()
const CliPath  = RepoRoot / "build" / "bin" / "isonim-review"
const FixtureDir = RepoRoot / "tests" / "fixtures" / "design_review"

proc runCli(args: openArray[string]):
    tuple[exitCode: int; stdout: string; stderr: string] =
  ## Spawn the CLI with the supplied argv (no ``isonim-review`` prefix
  ## — we feed it directly via ``args``). Captures stdout and stderr
  ## separately so the e2e_..._reports_errors test can assert on
  ## stderr only.
  let p = startProcess(
    command = CliPath,
    args = @args,
    options = {poUsePath}
  )
  defer: p.close()
  let outStream = p.outputStream
  let errStream = p.errorStream
  let exitCode = p.waitForExit()
  result.exitCode = exitCode
  result.stdout = outStream.readAll()
  result.stderr = errStream.readAll()

suite "REV-M1 isonim-review CLI":
  test "cli_binary_exists":
    ## Sanity guard: the binary must be built before running these
    ## tests. ``just isonim-review-build`` produces it.
    check fileExists(CliPath)

  test "e2e_isonim_review_briefs_check_clean":
    ## Run ``isonim-review briefs check --project <valid>`` via
    ## ``osproc``. Exit code 0; stdout contains ``3 briefs OK`` and a
    ## per-brief line with covered preview count.
    let r = runCli(["briefs", "check", "--project",
                    FixtureDir / "briefs_valid"])
    check r.exitCode == 0
    check "3 briefs OK" in r.stdout
    check "chrome.editor-sidebar" in r.stdout
    check "interaction.task-add-flow" in r.stdout
    check "render.task-app" in r.stdout
    # Each per-brief line names the covered preview count.
    check "previews" in r.stdout

  test "e2e_isonim_review_briefs_check_reports_errors":
    ## Same against ``briefs_invalid``. Exit code 1; stderr names each
    ## broken file with its specific error class.
    let r = runCli(["briefs", "check", "--project",
                    FixtureDir / "briefs_invalid"])
    check r.exitCode == 1
    check "missing-briefid.md: MissingRequiredFieldError(briefId)" in r.stderr
    check "missing-coverspreviews.md: MissingRequiredFieldError(coversPreviews)" in r.stderr
    check "mismatched-kind.md: BriefKindMismatchError" in r.stderr
    check "unknown-backend.md: UnknownBackendError" in r.stderr
    check "bad-weights.md: ScoringWeightSumError" in r.stderr
    check "DuplicateBriefIdError" in r.stderr

  test "cli_briefs_check_missing_project_arg_returns_2":
    let r = runCli(["briefs", "check"])
    check r.exitCode == 2
    check "--project" in r.stderr
