## TBAR-M5 — orchestration helper for browser tests that need a real
## Postgres cluster.
##
## Spawns a ``PgFixture`` (the same helper the Nim integration tests
## use), prints the cluster's port to ``stdout`` as JSON, and blocks
## until ``stdin`` closes (the parent — typically a Node ``--test``
## process — closes stdin during teardown, signalling us to shut down
## the cluster cleanly).
##
## Usage from JS:
##
##   const proc = spawn(helperPath, [], { stdio: ['pipe','pipe','pipe'] });
##   const line = await readUntilNewline(proc.stdout);
##   const { pgPort } = JSON.parse(line);
##   // … run tests against pgPort …
##   proc.stdin.end();   // teardown
##   await processExit(proc);
##
## This file does NOT depend on httpclient or any of the daemon's
## modules — only the Nim PgFixture helper.  The daemon is spawned
## by JS directly using ``build/bin/isonim-review``.

import std/json

import ../../helpers/design_review_pg_fixture

proc main() =
  let pg = newPgFixture(applyMigrations = false)
  let payload = $(%* {
    "pgPort": pg.port,
  })
  stdout.writeLine(payload)
  stdout.flushFile()
  # Wait for the parent to close stdin (signals teardown).
  try:
    discard stdin.readLine()
  except EOFError, IOError:
    discard
  pg.shutdown()

when isMainModule:
  main()
