## REV-M6 — ``isonim-review run-review`` subcommand.
##
## Wires the orchestration in
## ``isonim/editor/design_review/run_review.nim`` to a CLI surface:
##
##   isonim-review run-review --run <run_id>
##                            [--agent-backend canned|claude-code]
##                            [--canned-path <md>]
##                            [--agent-name <name>]
##                            [--agent-version <version>]
##                            [--prompt-template <path>]
##                            [--workspace <path>]
##                            [--project <path>] [--config <path>]
##                            [--dry-run [--dry-run-out <path>]]
##
## The ``canned`` backend reads the file at ``--canned-path`` verbatim
## and feeds it through the reviewer-output parser; the ``claude-code``
## backend spawns the binary on PATH.  All CI tests use ``canned``.
##
## ``--dry-run`` writes the fully-assembled prompt to ``--dry-run-out``
## (or stdout) and exits 0 without contacting the agent or writing to
## the DB — used by the brief-at-revision e2e test to confirm the
## historical brief content is what reaches the agent.

import std/[os]

import db_connector/db_postgres

import isonim/editor/design_review/agent_dispatch
import isonim/editor/design_review/db as dr_db
import isonim/editor/design_review/run_review

import ./config

proc cmdRunReview*(cfg: ReviewConfig;
                   runId, agentBackend, cannedPath,
                   agentName, agentVersion,
                   promptTemplate, workspaceRoot, projectPath,
                   dryRunOut: string;
                   dryRun: bool): int =
  if runId.len == 0:
    stderr.writeLine("isonim-review run-review: --run <run_id> is required")
    return 2

  let resolvedWorkspace =
    if workspaceRoot.len > 0: workspaceRoot
    else: cfg.workspace.root
  let resolvedProject =
    if projectPath.len > 0: projectPath
    else: resolvedWorkspace
  let resolvedAgentBackend =
    if agentBackend.len > 0: agentBackend else: "canned"
  let resolvedAgentName =
    if agentName.len > 0: agentName
    else: (if resolvedAgentBackend == "canned": "canned" else: "claude-code")
  let resolvedAgentVersion =
    if agentVersion.len > 0: agentVersion else: "v1"

  var backend: AgentBackend
  case resolvedAgentBackend
  of "canned":
    if cannedPath.len == 0:
      stderr.writeLine("isonim-review run-review: --canned-path <path> required when --agent-backend canned")
      return 2
    backend = cannedBackend(cannedPath)
  of "daemon":
    let url = daemonBaseUrl(cfg)
    backend = daemonBackend(url)
  of "claude-code":
    # Phase B: ``claude-code`` is now an alias for ``daemon`` — the
    # subprocess path stays available via ``--agent-backend
    # claude-code-subprocess`` for ops that need to bypass the daemon.
    let url = daemonBaseUrl(cfg)
    backend = daemonBackend(url)
  of "claude-code-subprocess":
    backend = legacyClaudeCodeSubprocessBackend()
  else:
    stderr.writeLine("isonim-review run-review: --agent-backend must be one of " &
      "'canned', 'daemon', 'claude-code', 'claude-code-subprocess'")
    return 2

  let connStr = connectionString(cfg, role = "app")
  let conn =
    try: open("", cfg.db.appUser, "", connStr)
    except DbError as e:
      stderr.writeLine("isonim-review run-review: cannot connect to " &
                       connStr & ": " & e.msg)
      return 3
  let db = ReviewDb(conn: conn)
  defer: db.close()

  try:
    let outcome = runReview(
      runId = runId,
      projectPath = resolvedProject,
      workspaceRoot = resolvedWorkspace,
      reviewStorePath = cfg.store.path,
      promptTemplatePath = promptTemplate,
      agentName = resolvedAgentName,
      agentVersion = resolvedAgentVersion,
      backend = backend,
      db = db,
      dryRun = dryRun)
    if dryRun:
      if dryRunOut.len > 0:
        createDir(dryRunOut.parentDir)
        writeFile(dryRunOut, outcome)
        echo "run-review: dry-run prompt written to " & dryRunOut
      else:
        stdout.write(outcome)
      return 0
    echo "run-review: complete (report_id=" & outcome & ")"
    return 0
  except RunNotReadyForReviewError as e:
    stderr.writeLine("isonim-review run-review: " & e.msg)
    return 4
  except AgentDispatchError as e:
    stderr.writeLine("isonim-review run-review: " & e.msg)
    return 5
  except RunReviewError as e:
    stderr.writeLine("isonim-review run-review: " & e.msg)
    return 5
