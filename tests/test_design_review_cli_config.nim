## REV-M4 — config-loader unit tests.
##
## Covers ``test_cli_config_resolution_env_overrides_toml`` from the
## milestone's Verification block.  Exercises the in-process loader
## directly (no need to spawn the CLI binary — the env-vs-TOML
## precedence is decided inside ``loadConfig``).

import std/[os, osproc, streams, strutils, unittest]

# Tools live outside ``src/``; we add the ``tools/`` parent to the path
# via the test runner's ``--path`` flag.  Use a relative import here
# so the file works whether the runner adds ``tools`` or
# ``tools/isonim_review`` to the search path.
import tools/isonim_review/config

const FixtureDir = currentSourcePath().parentDir() / "fixtures" /
    "design_review_cli_config"

proc writeTomlFixture(path, body: string) =
  createDir(path.parentDir)
  writeFile(path, body)

suite "REV-M4 isonim-review config":

  test "test_cli_config_resolution_env_overrides_toml":
    ## TOML asserts port 5533; env override asserts port 5599.
    ## ``loadConfig`` must honour the env override.
    let tomlPath = FixtureDir / "config.toml"
    writeTomlFixture(tomlPath, """
[db]
host = "127.0.0.1"
port = 5533
database = "isonim_design_review"
app_user = "design_review_app"
migrator_user = "design_review_migrator"

[server]
bind = "127.0.0.1"
port = 8113
""")
    defer:
      try: removeFile(tomlPath)
      except OSError: discard

    # Baseline: TOML alone → port 5533.
    delEnv("ISONIM_REVIEW_DB")
    delEnv("ISONIM_REVIEW_PORT")
    delEnv("ISONIM_REVIEW_PGPORT")
    delEnv("ISONIM_REVIEW_PGHOST")
    let baseline = loadConfig(tomlPath)
    check baseline.db.port == 5533

    # Env override: full URL wins.
    putEnv("ISONIM_REVIEW_DB",
      "postgres://design_review_migrator@127.0.0.1:5599/isonim_design_review")
    let overridden = loadConfig(tomlPath)
    check overridden.db.port == 5599
    check overridden.db.url.contains(":5599/")

    delEnv("ISONIM_REVIEW_DB")

  test "test_cli_config_defaults_when_no_toml_and_no_env":
    ## Both TOML and env absent → built-in defaults stand.  This is
    ## the regression guard the existing ``briefs check`` flow relies
    ## on (zero-config invocations must still produce a usable
    ## ``ReviewConfig``).
    let missing = FixtureDir / "nonexistent-config.toml"
    delEnv("ISONIM_REVIEW_DB")
    delEnv("ISONIM_REVIEW_PORT")
    delEnv("ISONIM_REVIEW_PGPORT")
    delEnv("ISONIM_REVIEW_PGHOST")
    let cfg = loadConfig(missing)
    check cfg.db.host == DefaultDbHost
    check cfg.db.port == DefaultDbPort
    check cfg.db.database == DefaultDbName
    check cfg.server.port == DefaultServerPort

  test "test_cli_config_env_port_only":
    ## ``ISONIM_REVIEW_PORT`` (HTTP) is honoured independently of the
    ## DB env override.
    delEnv("ISONIM_REVIEW_DB")
    putEnv("ISONIM_REVIEW_PORT", "8200")
    defer: delEnv("ISONIM_REVIEW_PORT")
    let cfg = loadConfig("")
    check cfg.server.port == 8200

  test "test_cli_briefs_check_still_works":
    ## Regression guard for REV-M1.  Adding the M4 subcommands must
    ## not break ``briefs check``.  We spawn the built binary against
    ## the existing valid-briefs fixture and assert the same output
    ## the REV-M1 CLI test does.
    let cli = currentSourcePath().parentDir().parentDir() /
        "build" / "bin" / "isonim-review"
    let fixtureRoot = currentSourcePath().parentDir() / "fixtures" /
        "design_review" / "briefs_valid"
    if not fileExists(cli):
      # ``just isonim-review-build`` must precede this test; flag it
      # rather than silently skipping so a missing binary is visible.
      check fileExists(cli)
    else:
      let p = startProcess(cli,
        args = @["briefs", "check", "--project", fixtureRoot],
        options = {poUsePath})
      defer: p.close()
      let stdoutText = p.outputStream.readAll()
      let rc = p.waitForExit()
      check rc == 0
      check "3 briefs OK" in stdoutText
