# IsoNim — Isomorphic reactive web framework for Nim

# Run all tests (both JS and C targets)
test: test-c test-js

# Run tests on C target
test-c:
    nim c -r tests/test_signals.nim
    nim c -r tests/test_effects.nim
    nim c -r tests/test_clock.nim
    nim c -r tests/test_context.nim
    nim c -r tests/test_rxcore.nim
    nim c -r tests/test_dsl.nim
    nim c -r tests/test_ssr.nim
    nim c -r tests/test_streaming.nim
    nim c -r tests/test_dsl_ssr.nim
    nim c -r tests/test_round_trip.nim
    nim c -r tests/test_benchmark.nim
    nim c -r tests/test_viewmodel.nim
    nim c -r tests/test_demo_vm.nim
    nim c -r tests/test_terminal.nim
    nim c -r tests/test_native_renderer.nim
    nim c -r tests/test_nginx_module.nim
    nim c -r tests/test_corner_cases.nim
    nim c -r tests/test_accessibility.nim
    nim c -r tests/test_router.nim
    nim c -r tests/test_ssr_routing.nim
    nim c -r tests/test_server_functions.nim
    nim c -r tests/test_data_loading.nim
    nim c -r tests/test_file_routes.nim
    nim c -r tests/test_http_types.nim
    nim c -r tests/test_streaming_stress.nim
    nim c -r tests/test_third_party.nim
    nim c -r tests/poc_monaco_host.nim

# Run tests on JS target
test-js:
    nim js -r tests/test_signals.nim
    nim js -r tests/test_effects.nim
    nim js -r tests/test_clock.nim
    nim js -r tests/test_context.nim
    nim js -r tests/test_rxcore.nim
    nim js -r tests/test_dsl.nim
    nim js -r tests/test_web.nim
    nim js -r tests/test_demo_vm.nim
    nim js -r tests/test_benchmark.nim
    nim js -r tests/test_viewmodel.nim
    nim js -r tests/test_terminal.nim
    nim js -r tests/test_hydration.nim
    nim js -r tests/test_ssr_hydration_e2e.nim
    nim js -r tests/test_app_e2e.nim
    nim js -r tests/test_web_components_advanced.nim
    nim js -r tests/test_third_party.nim
    nim js -r tests/poc_monaco_host.nim
    nim js -r tests/test_accessibility.nim
    nim js -r tests/test_router.nim
    nim js -r tests/test_server_functions.nim
    nim js -r tests/test_data_loading.nim

# Run only signal tests
test-signals:
    nim c -r tests/test_signals.nim
    nim js -r tests/test_signals.nim

# Run only clock/scheduler tests
test-clock:
    nim c -r tests/test_clock.nim
    nim js -r tests/test_clock.nim

# Run only context/resource/suspense/transition tests
test-context:
    nim c -r tests/test_context.nim
    nim js -r tests/test_context.nim

# Run only effect/memo/owner/batch tests
test-effects:
    nim c -r tests/test_effects.nim
    nim js -r tests/test_effects.nim

# Run only rxcore/renderer/mock-dom tests
test-rxcore:
    nim c -r tests/test_rxcore.nim
    nim js -r tests/test_rxcore.nim

# Run only DSL/html/components tests
test-dsl:
    nim c -r tests/test_dsl.nim
    nim js -r tests/test_dsl.nim
    nim c -r tests/test_dsl_ssr.nim

# Run only server function tests
test-server:
    nim c -r tests/test_server_functions.nim
    nim js -r tests/test_server_functions.nim

# Run data loading (server resource) tests
test-data-loading:
    nim c -r tests/test_data_loading.nim
    nim js -r tests/test_data_loading.nim

# Run SSR and round-trip tests
test-ssr:
    nim c -r tests/test_ssr.nim
    nim c -r tests/test_streaming.nim
    nim c -r tests/test_dsl_ssr.nim
    nim c -r tests/test_round_trip.nim

# Run only web renderer tests (JS-only)
test-web:
    nim js -r tests/test_web.nim

# --- IsoNim Design Review CLI (REV-M1 + REV-M4) ---

# Build the isonim-review CLI. Compiles tools/isonim_review/main.nim to
# build/bin/isonim-review. Used by REV-M1's CLI integration tests and
# by the capture / review loop (REV-M5+).
#
# REV-M4 added imports of ``db_connector/db_postgres`` for ``init`` /
# ``db-health`` / ``serve`` so the binary now links against libpq at
# runtime. The ``--path:vendor/db_connector/src`` switch keeps the
# build hermetic against the vendored copy under ``vendor/``.
isonim-review-build:
    mkdir -p build/bin
    nim c -d:release \
        --path:src \
        --path:vendor/db_connector/src \
        --path:vendor/chronicles \
        --path:vendor/serialization \
        --path:vendor/json_serialization \
        --path:../isonim-render-serve/src \
        --path:../nim-everywhere/src \
        --path:../nim-faststreams \
        --path:../nim-stew \
        --path:../nim-acp/src \
        --path:../nim-agent-harbor/src \
        --path:../nim-agents/src \
        -d:nimOldCaseObjects \
        -d:chronicles_sinks=textlines[stderr] \
        -d:chronicles_runtime_filtering=on \
        -d:chronicles_log_level=TRACE \
        --hints:off --out:build/bin/isonim-review tools/isonim_review/main.nim
    @echo "Built: build/bin/isonim-review"

# Run REV-M1's design-review unit + integration tests.
test-design-review: isonim-review-build
    nim c -r tests/test_design_review_brief_format.nim
    nim c -r tests/test_design_review_brief_index.nim
    nim c -r tests/test_design_review_isonim_review_cli.nim

# REV-M4: run all CLI-layer tests (config loader, init, db-health,
# serve smoke, plus the two e2e tests that drive a real process-compose
# cluster).  PG tests use the REV-M3 ephemeral fixture; the binary
# must be built first via ``isonim-review-build``.
test-design-review-cli: isonim-review-build
    nim c -r --path:. --path:src --path:vendor/db_connector/src tests/test_design_review_cli_config.nim
    nim c -r --path:. --path:src --path:vendor/db_connector/src tests/test_design_review_cli_init.nim
    nim c -r --path:. --path:src --path:vendor/db_connector/src tests/test_design_review_cli_db_health.nim
    nim c -r --path:. --path:src --path:vendor/db_connector/src tests/test_design_review_cli_serve_smoke.nim
    nim c -r --path:. --path:src --path:vendor/db_connector/src tests/e2e_design_review_cli_init.nim
    nim c -r --path:. --path:src --path:vendor/db_connector/src tests/e2e_design_review_cli_serve_lifecycle.nim
    nim c -r --path:. --path:src --path:vendor/db_connector/src --path:vendor/chronicles --path:vendor/serialization --path:vendor/json_serialization --path:../nim-faststreams --path:../nim-stew --path:../nim-acp/src --path:../nim-agent-harbor/src --path:../nim-agents/src -d:nimOldCaseObjects --hints:off tests/test_design_review_cli_seed_run.nim

# REV-M5: run every REV-M5 capture-pipeline test.  Unit tests boot
# fake WebSocket servers + ephemeral git workspaces; the idempotency
# and e2e tests use the REV-M3 PgFixture + a real `isonim-review`
# subprocess.  All paths use the same `--path:` set the CLI build uses.
test-design-review-capture: isonim-review-build
    nim c -r --path:. --path:src --path:vendor/db_connector/src --path:../isonim-render-serve/src --path:../nim-everywhere/src --hints:off tests/test_design_review_clean_tree.nim
    nim c -r --path:. --path:src --path:vendor/db_connector/src --path:../isonim-render-serve/src --path:../nim-everywhere/src --hints:off tests/test_design_review_manifest_hash.nim
    nim c -r --path:. --path:src --path:vendor/db_connector/src --path:../isonim-render-serve/src --path:../nim-everywhere/src --hints:off tests/test_design_review_capture_store.nim
    nim c -r --path:. --path:src --path:vendor/db_connector/src --path:../isonim-render-serve/src --path:../nim-everywhere/src --hints:off tests/test_design_review_bridge_client.nim
    nim c -r --path:. --path:src --path:vendor/db_connector/src --path:../isonim-render-serve/src --path:../nim-everywhere/src --hints:off tests/test_design_review_capture_native_dimensions.nim
    nim c -r --path:. --path:src --path:vendor/db_connector/src --path:../isonim-render-serve/src --path:../nim-everywhere/src --hints:off tests/test_design_review_record_capture_idempotent.nim
    nim c -r --path:. --path:src --path:vendor/db_connector/src --path:../isonim-render-serve/src --path:../nim-everywhere/src --hints:off tests/e2e_design_review_capture_fullsweep.nim

# REV-M5 (follow-up): exercise the per-backend launcher path against
# the real `isonim-examples-web` binary.  Runs the unit tests for
# `backend_launcher` (port allocation, spawn, shutdown idempotency,
# binary lookup) plus the end-to-end test that drives `isonim-review
# capture --backends web` against a real PgFixture + real launcher.
#
# Requires the sibling repo's web launcher binary to exist at
# `../isonim-examples/build/backends/isonim-examples-web`.  Rebuild
# via `direnv exec ~/metacraft/isonim-examples just build-backends`.
test-design-review-real-backend: isonim-review-build
    nim c -r --path:. --path:src --path:vendor/db_connector/src --path:../isonim-render-serve/src --path:../nim-everywhere/src --hints:off tests/test_design_review_backend_launcher.nim
    nim c -r --path:. --path:src --path:vendor/db_connector/src --path:../isonim-render-serve/src --path:../nim-everywhere/src --hints:off tests/e2e_design_review_capture_web_real_bridge.nim

# REV-M5: convenience target — drive a capture against the running
# dev cluster + a user-spawned `isonim-render-serve` bridge.  The
# default bridge URL matches the milestone document.
isonim-review-capture brief="render.fixture" bridge="ws://127.0.0.1:8093": isonim-review-build
    #!/usr/bin/env bash
    set -e
    export ISONIM_REVIEW_PGPORT="${ISONIM_REVIEW_PGPORT:-5533}"
    ./build/bin/isonim-review capture --brief "{{brief}}" --bridge "{{bridge}}"

# REV-M6: run every REV-M6 run-review test (reviewer-output parser,
# brief_at_revision, agent_dispatch with PG, and the e2e CLI tests).
# Same `--path:` set the CLI build uses; PG tests use PgFixture.
test-design-review-run-review: isonim-review-build
    nim c -r --path:. --path:src --path:vendor/db_connector/src --path:../isonim-render-serve/src --path:../nim-everywhere/src --hints:off tests/test_design_review_reviewer_output.nim
    nim c -r --path:. --path:src --path:vendor/db_connector/src --path:../isonim-render-serve/src --path:../nim-everywhere/src --hints:off tests/test_design_review_brief_at_revision.nim
    nim c -r --path:. --path:src --path:vendor/db_connector/src --path:../isonim-render-serve/src --path:../nim-everywhere/src --hints:off tests/test_design_review_agent_dispatch.nim
    nim c -r --path:. --path:src --path:vendor/db_connector/src --path:../isonim-render-serve/src --path:../nim-everywhere/src --hints:off tests/e2e_design_review_run_review.nim

# Phase B — convenience target: drive the chat subcommand against a
# locally-running daemon.  Defaults to the canned-output fake ACP agent
# so a stray ``just isonim-review-chat`` doesn't burn Anthropic credit.
isonim-review-chat prompt='hi' daemon='http://127.0.0.1:8113': isonim-review-build fake-acp-agent-build
    #!/usr/bin/env bash
    set -e
    export ISONIM_ACP_AGENT_CMD="${ISONIM_ACP_AGENT_CMD:-$PWD/build/bin/fake-acp-agent}"
    ./build/bin/isonim-review --log-level=debug chat --daemon='{{daemon}}' '{{prompt}}'

# Phase B — build the deterministic ACP fake server used by the chat /
# agent-routes tests.  Independent of the main binary so a Phase B
# test failure doesn't require a full ``isonim-review`` rebuild.
fake-acp-agent-build:
    mkdir -p build/bin
    nim c -d:release --hints:off -o:build/bin/fake-acp-agent \
        tests/helpers/fake_acp_agent.nim
    @echo "Built: build/bin/fake-acp-agent"

# Phase B — run every chat / agent-route test.  No PG required;
# ``isonim-review serve --agent-routes-only`` is used throughout.
test-design-review-chat: isonim-review-build fake-acp-agent-build
    nim c -r --path:. --path:src \
        --path:vendor/db_connector/src --path:vendor/chronicles \
        --path:vendor/serialization --path:vendor/json_serialization \
        --path:../nim-faststreams --path:../nim-stew \
        --path:../nim-acp/src --path:../nim-agent-harbor/src \
        --path:../nim-agents/src \
        -d:nimOldCaseObjects \
        -d:chronicles_sinks=textlines[stderr] \
        -d:chronicles_runtime_filtering=on \
        -d:chronicles_log_level=TRACE \
        --hints:off tests/test_design_review_daemon_agent_routes.nim
    nim c -r --path:. --path:src \
        --path:vendor/db_connector/src --path:vendor/chronicles \
        --path:vendor/serialization --path:vendor/json_serialization \
        --path:../nim-faststreams --path:../nim-stew \
        --path:../nim-acp/src --path:../nim-agent-harbor/src \
        --path:../nim-agents/src \
        -d:nimOldCaseObjects \
        -d:chronicles_sinks=textlines[stderr] \
        -d:chronicles_runtime_filtering=on \
        -d:chronicles_log_level=TRACE \
        --hints:off tests/test_design_review_cli_chat.nim
    nim c -r --path:. --path:src \
        --path:vendor/db_connector/src --path:vendor/chronicles \
        --path:vendor/serialization --path:vendor/json_serialization \
        --path:../nim-faststreams --path:../nim-stew \
        --path:../nim-acp/src --path:../nim-agent-harbor/src \
        --path:../nim-agents/src \
        -d:nimOldCaseObjects \
        -d:chronicles_sinks=textlines[stderr] \
        -d:chronicles_runtime_filtering=on \
        -d:chronicles_log_level=TRACE \
        --hints:off tests/test_design_review_streaming_sse.nim

# Phase B — optional smoke that requires a real ``claude-agent-acp``
# binary on PATH and Anthropic credentials configured.  Runs in CI
# only when the dev shell + secrets are present; locally it skips
# itself when either prerequisite is missing.
test-design-review-chat-real-acp: isonim-review-build
    nim c -r --path:. --path:src \
        --path:vendor/db_connector/src --path:vendor/chronicles \
        --path:vendor/serialization --path:vendor/json_serialization \
        --path:../nim-faststreams --path:../nim-stew \
        --path:../nim-acp/src --path:../nim-agent-harbor/src \
        --path:../nim-agents/src \
        -d:nimOldCaseObjects \
        -d:chronicles_sinks=textlines[stderr] \
        -d:chronicles_runtime_filtering=on \
        -d:chronicles_log_level=TRACE \
        --hints:off tests/e2e_design_review_chat_real_acp.nim

# Phase C — optional smoke that requires a real ``codex-acp`` binary
# on PATH (now exposed by the dev shell) and OpenAI / ChatGPT auth
# configured.  Skips cleanly when either prerequisite is missing.
test-design-review-chat-real-codex-acp: isonim-review-build
    nim c -r --path:. --path:src \
        --path:vendor/db_connector/src --path:vendor/chronicles \
        --path:vendor/serialization --path:vendor/json_serialization \
        --path:../nim-faststreams --path:../nim-stew \
        --path:../nim-acp/src --path:../nim-agent-harbor/src \
        --path:../nim-agents/src \
        -d:nimOldCaseObjects \
        -d:chronicles_sinks=textlines[stderr] \
        -d:chronicles_runtime_filtering=on \
        -d:chronicles_log_level=TRACE \
        --hints:off tests/e2e_design_review_chat_real_codex_acp.nim

# Phase C — unit tests for the ``[agent].backend`` selector. No
# binaries needed (the CLI-driven test skips when the binary isn't
# built yet, but ``just isonim-review-build`` resolves that too).
test-design-review-config-agent-backend: isonim-review-build
    nim c -r --path:. --path:src \
        --path:vendor/db_connector/src --path:vendor/chronicles \
        --path:vendor/serialization --path:vendor/json_serialization \
        --path:../nim-faststreams --path:../nim-stew \
        --path:../nim-acp/src --path:../nim-agent-harbor/src \
        --path:../nim-agents/src \
        -d:nimOldCaseObjects \
        -d:chronicles_sinks=textlines[stderr] \
        -d:chronicles_runtime_filtering=on \
        -d:chronicles_log_level=TRACE \
        --hints:off tests/test_design_review_config_agent_backend.nim

# REV-M6: convenience target — invoke `isonim-review run-review` against
# the running dev cluster.  Defaults to the canned backend so a typo in
# `claude-code` doesn't kick off a real model call.
isonim-review-run-review run="" cannedPath="canned.md" agentBackend="canned" agentVersion="v1": isonim-review-build
    #!/usr/bin/env bash
    set -e
    export ISONIM_REVIEW_PGPORT="${ISONIM_REVIEW_PGPORT:-5533}"
    if [ -z "{{run}}" ]; then
      echo "usage: just isonim-review-run-review run=<run_id> [cannedPath=...] [agentBackend=canned|claude-code] [agentVersion=...]"
      exit 2
    fi
    ./build/bin/isonim-review run-review --run "{{run}}" \
      --agent-backend "{{agentBackend}}" \
      --canned-path "{{cannedPath}}" \
      --agent-version "{{agentVersion}}"

# REV-M4: invoke the CLI's ``init`` against the running dev cluster.
# Idempotent — re-running this against an already-migrated DB prints
# ``skip ...`` lines and exits 0.  ``ISONIM_REVIEW_PGPORT`` defaults
# to 5533 (the dev cluster's port); override via environment.
isonim-review-init: isonim-review-build
    #!/usr/bin/env bash
    set -e
    export ISONIM_REVIEW_PGPORT="${ISONIM_REVIEW_PGPORT:-5533}"
    ./build/bin/isonim-review init --migrations "$PWD/db/migrations"

# REV-M4: run the layered health probes against the running dev
# cluster.  Exits 0 if every DB probe is green, non-zero otherwise.
# The ``--json`` flag emits machine-readable output.
isonim-review-health *FLAGS: isonim-review-build
    #!/usr/bin/env bash
    set -e
    export ISONIM_REVIEW_PGPORT="${ISONIM_REVIEW_PGPORT:-5533}"
    ./build/bin/isonim-review db-health --migrations "$PWD/db/migrations" {{FLAGS}}

# REV-M4: start the long-running HTTP daemon.  Listens on
# 127.0.0.1:8113 by default; override via ISONIM_REVIEW_PORT.
# ``GET /health`` returns the same JSON as ``isonim-review-health
# --json``; REV-M7/M8 will populate ``/api/design-review/*``.
isonim-review-serve: isonim-review-build
    #!/usr/bin/env bash
    set -e
    export ISONIM_REVIEW_PGPORT="${ISONIM_REVIEW_PGPORT:-5533}"
    export ISONIM_REVIEW_PORT="${ISONIM_REVIEW_PORT:-8113}"
    exec ./build/bin/isonim-review serve --migrations "$PWD/db/migrations"

# --- REV-M3 userspace PostgreSQL dev cluster ---
#
# Defaults come from the dev shell:
#   ISONIM_REVIEW_PGDATA="$PWD/.dev/postgres"
#   ISONIM_REVIEW_PGPORT=5533
# Override in your private ``.env`` or per-command.

# Boot the design-review Postgres cluster (process-compose, detached).
# Defaults are exported by the Nix dev shell; this target re-exports
# them so ``just dev-pg-start`` also works under ``nix-shell -p`` or in
# a non-direnv environment.
dev-pg-start:
    #!/usr/bin/env bash
    set -e
    export ISONIM_REVIEW_PGDATA="${ISONIM_REVIEW_PGDATA:-$PWD/.dev/postgres}"
    export ISONIM_REVIEW_PGPORT="${ISONIM_REVIEW_PGPORT:-5533}"
    export ISONIM_REVIEW_MIGRATIONS_DIR="${ISONIM_REVIEW_MIGRATIONS_DIR:-$PWD/db/migrations}"
    # ``-D`` is process-compose's --detached (NOT --hide-disabled, which
    # is the same letter in lowercase).
    process-compose up -D -f process-compose.yaml --tui=false

# Graceful shutdown.  Leaves $ISONIM_REVIEW_PGDATA intact for next run.
dev-pg-stop:
    #!/usr/bin/env bash
    set -e
    export ISONIM_REVIEW_PGDATA="${ISONIM_REVIEW_PGDATA:-$PWD/.dev/postgres}"
    export ISONIM_REVIEW_PGPORT="${ISONIM_REVIEW_PGPORT:-5533}"
    process-compose down -f process-compose.yaml

# Full wipe: stop + rm -rf the project-local data dir.  Use when the
# migration history is dirty or the cluster won't start.
dev-pg-reset:
    #!/usr/bin/env bash
    export ISONIM_REVIEW_PGDATA="${ISONIM_REVIEW_PGDATA:-$PWD/.dev/postgres}"
    export ISONIM_REVIEW_PGPORT="${ISONIM_REVIEW_PGPORT:-5533}"
    -process-compose down -f process-compose.yaml || true
    rm -rf "$ISONIM_REVIEW_PGDATA"

# Interactive ``psql`` against the running dev cluster.
dev-pg-psql:
    #!/usr/bin/env bash
    psql -h 127.0.0.1 -p "${ISONIM_REVIEW_PGPORT:-5533}" isonim_design_review

# Run every REV-M3 PG integration test.  Each test owns its own
# ephemeral cluster via ``tests/helpers/design_review_pg_fixture.nim``
# so this target can run in CI without any prior ``dev-pg-start``.
test-design-review-pg:
    nim c -r tests/test_design_review_pg_schema.nim
    nim c -r tests/test_design_review_pg_routines.nim
    nim c -r tests/test_design_review_pg_roles.nim
    nim c -r tests/smoke_design_review_pg_dump_restore.nim
    nim c -r tests/e2e_design_review_pg_process_compose.nim

# --- IsoNim Editor ---

# REV-M2: regenerate the baked-in brief index before compiling the JS
# bundle. The default brief path is the sibling
# `isonim-examples/briefs/` if it exists; otherwise the bake produces
# an empty static index. Override via $ISONIM_BRIEFS.
editor-bake-briefs:
    @echo "==> Baking brief index → src/isonim/editor/design_review/brief_index_static.nim"
    nim r --path:src --path:. --path:../nim-everywhere/src --hints:off \
        src/isonim/editor/design_review/brief_index_build.nim \
        --briefs:"${ISONIM_BRIEFS:-../isonim-examples/briefs}" \
        --out:src/isonim/editor/design_review/brief_index_static.nim

# Build the editor (Nim → JS).
# REV-M2: pre-runs `editor-bake-briefs` so the JS bundle contains a
# fresh build-time snapshot of the project's brief index.
editor-build: editor-bake-briefs
    mkdir -p build/editor
    nim js --path:src --path:. --path:../nim-everywhere/src --path:../isonim-render-serve/src --path:../nim-acp/src --path:../nim-agent-harbor/src --path:../nim-agents/src -o:build/editor/editor.js src/isonim/editor/main.nim
    cp src/isonim/editor/index.html build/editor/index.html
    cp node_modules/fabric/dist/index.min.js build/editor/fabric.min.js
    cp node_modules/paper/dist/paper-core.min.js build/editor/paper-core.min.js
    cp node_modules/svgo/dist/svgo.browser.js build/editor/svgo.browser.js
    @echo "Built: build/editor/ — open build/editor/index.html"

# REV-M2: Run the brief-tab VM and source-scan tests.
test-design-review-brief-tab:
    nim c -r --path:src --path:. --path:../nim-everywhere/src --hints:off \
        tests/test_design_review_brief_tab_vm.nim
    nim c -r --path:src --path:. --path:../nim-everywhere/src --hints:off \
        tests/test_design_review_brief_tab_no_setstyle.nim

# Phase C — Editor AI sidebar wired to the daemon's /api/agent/*.
# Runs the VM-level adapter tests, the JS-side compile smoke, and the
# real-browser e2e harness that drives the daemon + editor bundle
# through Playwright.
test-design-review-editor-chat: isonim-review-build fake-acp-agent-build editor-build
    nim c -r --path:. --path:src \
        --path:vendor/db_connector/src --path:vendor/chronicles \
        --path:vendor/serialization --path:vendor/json_serialization \
        --path:../nim-faststreams --path:../nim-stew \
        --path:../nim-acp/src --path:../nim-agent-harbor/src \
        --path:../nim-agents/src --path:../nim-everywhere/src \
        --path:../isonim-render-serve/src \
        -d:nimOldCaseObjects --hints:off \
        tests/test_design_review_editor_agent_adapter_vm.nim
    nim js --compileOnly --path:. --path:src \
        --path:vendor/db_connector/src --path:vendor/chronicles \
        --path:vendor/serialization --path:vendor/json_serialization \
        --path:../nim-faststreams --path:../nim-stew \
        --path:../nim-acp/src --path:../nim-agent-harbor/src \
        --path:../nim-agents/src --path:../nim-everywhere/src \
        --path:../isonim-render-serve/src \
        -d:nimOldCaseObjects --hints:off \
        tests/test_design_review_browser_agent_client_compiles.nim
    NODE_PATH=tests/browser/node_modules \
        node --test tests/e2e_design_review_editor_chat.mjs

# REV-M7: Run every REV-M7 gallery + API test.
#
# The four API tests boot the real ``isonim-review serve`` daemon
# against an ephemeral ``PgFixture`` and exercise the four new
# ``/api/design-review/*`` routes through ``std/httpclient`` — no
# in-process shims.  The ViewModel + source-scan tests run pure-Nim
# under the MockRenderer.  The Playwright e2e spins up the daemon and
# drives Chromium against a minimal mount page.
test-design-review-gallery: isonim-review-build
    nim c -r --path:src --path:. --path:../nim-everywhere/src --hints:off \
        tests/test_design_review_gallery_vm.nim
    nim c -r --path:src --path:. --hints:off \
        tests/test_design_review_gallery_no_setstyle.nim
    nim c -r --path:. --path:src --path:vendor/db_connector/src \
        --path:../nim-everywhere/src --hints:off \
        tests/test_design_review_api_list_history.nim
    nim c -r --path:. --path:src --path:vendor/db_connector/src \
        --path:../nim-everywhere/src --hints:off \
        tests/test_design_review_api_fetch_run.nim
    nim c -r --path:. --path:src --path:vendor/db_connector/src \
        --path:../nim-everywhere/src --hints:off \
        tests/test_design_review_api_get_capture_png.nim
    nim c -r --path:. --path:src --path:vendor/db_connector/src \
        --path:../nim-everywhere/src --hints:off \
        tests/test_design_review_api_brief_has_history.nim
    node --test tests/e2e_design_review_gallery_overlay.mjs

# REV-M8: Layout-persistence API + CLI + drag/multi-select VM tests.
test-design-review-layouts: isonim-review-build
    nim c -r --path:src --path:. --path:../nim-everywhere/src --hints:off \
        tests/test_design_review_gallery_drag_rearrange_vm.nim
    nim c -r --path:src --path:. --path:../nim-everywhere/src --hints:off \
        tests/test_design_review_gallery_side_by_side_vm.nim
    nim c -r --path:. --path:src --path:vendor/db_connector/src \
        --path:../nim-everywhere/src --hints:off \
        tests/test_design_review_api_save_layout.nim
    nim c -r --path:. --path:src --path:vendor/db_connector/src \
        --path:../nim-everywhere/src --hints:off \
        tests/test_design_review_api_promote_layout.nim
    nim c -r --path:. --path:src --path:vendor/db_connector/src \
        --path:../nim-everywhere/src --hints:off \
        tests/test_design_review_api_list_layouts.nim
    nim c -r --path:. --path:src --path:vendor/db_connector/src \
        --path:../nim-everywhere/src --path:../isonim-render-serve/src \
        --hints:off \
        tests/test_design_review_gallery_fetch_on_open.nim
    node --test tests/e2e_design_review_gallery_save_layout.mjs
    node --test tests/e2e_design_review_gallery_promote_layout.mjs
    node --test tests/e2e_design_review_gallery_conflict.mjs
    node --test tests/e2e_design_review_gallery_side_by_side.mjs

# REV-M8: Production-mount (real editor bundle + daemon discovery) tests.
test-design-review-gallery-production: isonim-review-build editor-build
    nim c -r --path:src --path:. --path:../nim-everywhere/src --hints:off \
        tests/test_design_review_daemon_discovery.nim
    nim c -r --path:src --path:. --path:../nim-everywhere/src \
        --path:../isonim-render-serve/src --hints:off \
        tests/test_design_review_brief_has_history_signal.nim
    node --test tests/e2e_design_review_history_button_in_real_editor.mjs

# Build and serve the editor
editor-serve: editor-build
    @echo "Serving editor on http://localhost:8090"
    cd build/editor && python3 -m http.server 8090

# Screenshot all views at all sizes → build/editor/screenshots/
editor-screenshot:
    node tools/editor-screenshot.mjs

# Screenshot a specific view (shell, sidebar-only, inspector-only, preview-only)
editor-screenshot-view view:
    node tools/editor-screenshot.mjs --view {{view}}

# Screenshot at a specific size (wide, laptop, medium, tablet, narrow, mobile)
editor-screenshot-size size:
    node tools/editor-screenshot.mjs --size {{size}}

# Screenshot a specific view at a specific size
editor-shot view size:
    node tools/editor-screenshot.mjs --view {{view}} --size {{size}}

# Quick screenshot — shell at wide, skip rebuild
editor-quick:
    node tools/editor-screenshot.mjs --view shell --size wide --no-build

# List available views and sizes
editor-screenshot-list:
    node tools/editor-screenshot.mjs --list

# Run editor ViewModel tests
test-editor:
    nim c -r tests/test_editor_workspace.nim
    nim c -r tests/test_editor_public_api.nim
    nim js --path:src -o:build/test_editor_public_browser_imports.js tests/test_editor_public_browser_imports.nim
    nim c -r tests/test_editor_release_gate.nim
    node --test tests/test_editor_visual_review_brief.mjs
    nim c -r tests/test_editor_viewmodels.nim
    nim c -r --path:../nim-acp/src tests/test_editor_agent_context.nim
    nim c -r tests/test_editor_agent_harbor.nim
    nim c -r tests/test_editor_user_project.nim
    nim c -r tests/test_editor_shell_views.nim
    nim c -r tests/test_editor_task_views.nim
    nim c -r tests/test_editor_interactivity.nim
    nim c -r tests/test_editor_responsive.nim
    nim c -r tests/test_editor_streaming_preview.nim

# Run packaged editor browser tests.
test-browser-editor-example: editor-build
    cd tests/browser && npm install && npx playwright test --project=editor-example

# Run the M43 visual screenshot, pixel, layout, and review brief gates.
test-editor-visual-gates: editor-build
    node --test tests/test_editor_visual_review_brief.mjs
    cd tests/browser && npm install && npx playwright test --project=editor-example --grep "e2e_editor_visual_baselines_cover_all_primary_modes|e2e_editor_ui_quality_no_overlap_or_unexpected_scrollbars|e2e_long_tail_css_property_visual_evidence"

# Run live consumer browser contract tests against metacraft-web.
test-browser-editor-consumer:
    cd ../metacraft-web && just build-back-office-editor
    cd tests/browser && npm install && npx playwright test --project=metacraft-web-editor

# Run all editor browser tests.
test-browser-editor: test-browser-editor-example test-browser-editor-consumer

# --- Benchmarks ---

# REV-M9: Build the design-review benchmark binary.  Compiles
# ``bench/design_review_bench.nim`` to ``build/bin/design_review_bench``.
# Used by ``just bench-design-review`` and by the four bench threshold
# tests under ``tests/test_design_review_bench_*``.
bench-design-review-build:
    mkdir -p build/bin
    nim c -d:release --path:vendor/db_connector/src --hints:off \
        --out:build/bin/design_review_bench bench/design_review_bench.nim
    @echo "Built: build/bin/design_review_bench"

# REV-M9: Run the four design-review hot-path benchmarks against the
# running process-compose Postgres cluster.  Asserts ``pg_isready``
# first so we fail fast with a clear message if the cluster is down,
# seeds the three idempotent fixtures, runs each routine 1000 times,
# compares against ``bench/thresholds.toml``, and exits non-zero on any
# threshold violation.  Outputs JSON to ``bench-results/<isodate>.json``
# and ``bench-results/benchmark_results.json`` (github-action-benchmark
# format) regardless of pass/fail.
bench-design-review: bench-design-review-build
    #!/usr/bin/env bash
    set -e
    export ISONIM_REVIEW_PGPORT="${ISONIM_REVIEW_PGPORT:-5533}"
    export ISONIM_REVIEW_PGHOST="${ISONIM_REVIEW_PGHOST:-127.0.0.1}"
    if ! pg_isready -h "$ISONIM_REVIEW_PGHOST" -p "$ISONIM_REVIEW_PGPORT" -q; then
      echo "bench-design-review: process-compose Postgres not running on" \
        "$ISONIM_REVIEW_PGHOST:$ISONIM_REVIEW_PGPORT" >&2
      echo "  Start it with 'just dev-pg-start' and retry." >&2
      exit 2
    fi
    exec ./build/bin/design_review_bench --iterations:1000

# REV-M10: Run every REV-M10 acceptance test.  Four parser/scan tests
# (run anywhere; no DB required) plus three e2e tests that spawn the
# real ``isonim-review`` CLI subprocess against an ephemeral
# PgFixture and a fake WebSocket bridge.  The CLI binary must be
# built first via ``isonim-review-build``.
test-design-review-acceptance: isonim-review-build
    nim c -r --path:. --path:src --hints:off \
        tests/test_migrated_task_app_brief_parses.nim
    nim c -r --path:. --path:src --hints:off \
        tests/test_migrated_settings_app_brief_parses.nim
    nim c -r --path:. --path:src --hints:off \
        tests/test_migrated_chrome_briefs_parse.nim
    nim c -r --path:. --path:src --hints:off \
        tests/test_no_dangling_references_to_old_brief_path.nim
    nim c -r --path:. --path:src --path:vendor/db_connector/src \
        --path:../isonim-render-serve/src --path:../nim-everywhere/src \
        --hints:off tests/e2e_full_pipeline_run_through_task_app_brief.nim
    nim c -r --path:. --path:src --path:vendor/db_connector/src \
        --path:../isonim-render-serve/src --path:../nim-everywhere/src \
        --hints:off tests/e2e_full_pipeline_round_trip_two_runs_visible_in_gallery.nim
    nim c -r --path:. --path:src --path:vendor/db_connector/src \
        --path:../isonim-render-serve/src --path:../nim-everywhere/src \
        --hints:off tests/e2e_pipeline_refuses_dirty_workspace.nim

# REV-M9: Run every bench-threshold test.  These tests run the benchmark
# with abbreviated fixtures (--iterations:200) and assert that the
# documented thresholds are satisfied.  They use the same PG cluster as
# ``bench-design-review``; ``just dev-pg-start`` must already be up.
test-design-review-bench: bench-design-review-build
    nim c -r --path:. --path:src --path:vendor/db_connector/src --hints:off \
        tests/test_design_review_bench_thresholds_respected.nim
    nim c -r --path:. --path:src --path:vendor/db_connector/src --hints:off \
        tests/e2e_design_review_bench_runner.nim
    nim c -r --path:. --path:src --path:vendor/db_connector/src --hints:off \
        tests/e2e_design_review_bench_regression.nim
    nim c -r --path:. --path:src --path:vendor/db_connector/src --hints:off \
        tests/e2e_design_review_bench_published.nim

# Build js-framework-benchmark entry. The benchmark imports
# `nim_everywhere/js_collections` transitively; resolve via an
# explicit --path so the build doesn't depend on `nimble develop`
# state. We invoke nim directly here rather than via the
# benchmarks/.../build.sh wrapper because the wrapper is intended to
# stay path-agnostic (so it works whether nimble develop has linked
# nim_everywhere or not).
bench-build:
    mkdir -p benchmarks/keyed/isonim/dist
    nim js -d:danger --path:$PWD/../nim-everywhere/src \
      -o:benchmarks/keyed/isonim/dist/main.raw.js \
      benchmarks/keyed/isonim/src/main.nim
    npx terser benchmarks/keyed/isonim/dist/main.raw.js --compress --mangle \
      -o benchmarks/keyed/isonim/dist/main.js

# Build the HMR-enabled benchmark entry. Same workload as
# bench-build, but compiled with -d:isonimHmr so the HMR runtime is
# linked in. Use this to quantify HMR's bundle-size cost.
bench-build-hmr:
    mkdir -p benchmarks/keyed/isonim-hmr/dist
    nim js -d:danger -d:isonimHmr --path:$PWD/../nim-everywhere/src \
      -o:benchmarks/keyed/isonim-hmr/dist/main.raw.js \
      benchmarks/keyed/isonim-hmr/src/main.nim
    npx terser benchmarks/keyed/isonim-hmr/dist/main.raw.js --compress --mangle \
      -o benchmarks/keyed/isonim-hmr/dist/main.js

# Show benchmark bundle size (raw, minified, gzipped)
bench-size:
    @echo "Raw:      $$(wc -c < benchmarks/keyed/isonim/dist/main.raw.js 2>/dev/null || echo '?') bytes"
    @echo "Minified: $$(wc -c < benchmarks/keyed/isonim/dist/main.js) bytes"
    @echo "Gzipped:  $$(gzip -c benchmarks/keyed/isonim/dist/main.js | wc -c) bytes"

# Run benchmark tests
bench-test:
    nim c -r tests/test_benchmark.nim
    nim js -r tests/test_benchmark.nim

# Set up the krausest benchmark runner (clone + install, one-time)
bench-setup:
    @echo "Setting up benchmark runner..."
    BENCH_SETUP_ONLY=1 bash benchmarks/run-comparison.sh || true
    @echo "Runner ready at benchmarks/runner/"

# Run IsoNim vs SolidJS comparison benchmark. Builds both isonim
# variants (vanilla + HMR-enabled) so the comparison includes the
# HMR overhead measurement alongside the SolidJS reference.
bench-compare: bench-build bench-build-hmr
    bash benchmarks/run-comparison.sh

# Run comparison with fewer iterations (quick check)
bench-compare-quick: bench-build bench-build-hmr
    BENCH_ITERATIONS=3 bash benchmarks/run-comparison.sh

# View benchmark results (starts HTTP server)
bench-results:
    @if [ ! -d benchmarks/runner ]; then echo "Run 'just bench-compare' first"; exit 1; fi
    @echo "Starting server... Open http://localhost:8080/webdriver-ts-results/dist/index.html"
    cd benchmarks/runner && npm start

# Build and report benchmark metrics
bench-framework: bench-build bench-size

# Run headless E2E app tests (Node.js DOM shim)
test-app-e2e:
    nim js -r tests/test_app_e2e.nim

# Build demo app for browser testing
demo-build:
    nim js --path:../nim-everywhere/src -o:demos/isonim-replica/dist/main.js demos/isonim-replica/src/main.nim

# Build SSR test HTML (C target: generates tests/browser/dist/ssr.html)
build-ssr-test:
    mkdir -p tests/browser/dist
    nim c --path:../nim-everywhere/src -d:isServer -r tests/browser/generate_ssr.nim

# Build hydration entry point (JS target: tests/browser/dist/main.js)
build-hydrate:
    mkdir -p tests/browser/dist
    nim js --path:../nim-everywhere/src -o:tests/browser/dist/main.js tests/browser/hydrate_entry.nim

# Build all SSR test assets
build-ssr-test-all: build-ssr-test build-hydrate

# Build the HMR fixture bundle (JS target with -d:isonimHmr).
build-hmr-fixture:
    mkdir -p tests/browser/hmr_fixture
    nim js -d:isonimHmr --path:src --path:../nim-everywhere/src -o:tests/browser/hmr_fixture/main.js tests/browser/hmr_fixture/main.nim

# Run the HMR Playwright spec (requires: just build-hmr-fixture).
test-browser-hmr: build-hmr-fixture
    cd tests/browser && npx playwright test --project=hmr

# Build the parametric-HMR fixture (JS target with -d:isonimHmr). The
# fixture exercises the parametric `{.uiComponent.}` dispatch and
# `mountUiHot` via two independent panel mounts.
build-hmr-parametric-fixture:
    mkdir -p tests/browser/hmr_parametric_fixture
    nim js -d:isonimHmr --path:src --path:../nim-everywhere/src -o:tests/browser/hmr_parametric_fixture/main.js tests/browser/hmr_parametric_fixture/main.nim

# Run the parametric-HMR Playwright spec.
test-browser-hmr-parametric: build-hmr-parametric-fixture
    cd tests/browser && npx playwright test --project=hmr-parametric

# Build the SSE-transport fixture: the dev server, the "before" and
# "after" client bundles, and the seeded main.js. The Playwright
# project triggers a rebuild via the dev server's POST /__isonim/trigger
# endpoint to swap before → after at runtime.
build-hmr-transport-fixture:
    nim c -d:isServer --path:src --path:../nim-everywhere/src --path:../nim-faststreams --path:../nim-stew -o:/tmp/isonim_test_server tests/browser/hmr_transport_fixture/server.nim
    nim js -d:isonimHmr --path:src --path:../nim-everywhere/src -o:tests/browser/hmr_transport_fixture/before.js tests/browser/hmr_transport_fixture/app.nim
    nim js -d:isonimHmr -d:transportFixtureAfter --path:src --path:../nim-everywhere/src -o:tests/browser/hmr_transport_fixture/after.js tests/browser/hmr_transport_fixture/app.nim
    cp tests/browser/hmr_transport_fixture/before.js tests/browser/hmr_transport_fixture/main.js

# Run the SSE-transport Playwright spec.
test-browser-hmr-transport: build-hmr-transport-fixture
    cd tests/browser && npx playwright test --project=hmr-transport

# Run Playwright browser tests (requires: just demo-build && cd tests/browser && npm install)
test-browser: test-browser-demo test-browser-ssr test-browser-hmr test-browser-hmr-parametric test-browser-hmr-transport

# Run Playwright demo app tests only
test-browser-demo:
    cd tests/browser && npx playwright test --project=demo-app

# Run Playwright SSR hydration tests (requires: just build-ssr-test-all)
test-browser-ssr: build-ssr-test-all
    cd tests/browser && npx playwright test --project=ssr-hydration

# Build and serve SolidJS demo
demo-solid:
    @echo "TODO: implement after M9"

# Build and serve IsoNim demo
demo-isonim:
    @echo "TODO: implement after M10"

# Build IsoNim components for Storybook (Nim -> JS)
build-storybook-components:
    mkdir -p demos/isonim-replica/storybook/dist
    nim js --path:../nim-everywhere/src -o:demos/isonim-replica/storybook/dist/components.js demos/isonim-replica/src/storybook_components.nim

# Run Storybook for visual component development (builds components first)
storybook: build-storybook-components
    cd demos/isonim-replica/storybook && npx storybook dev -p 6006

# Build Storybook static site (builds components first)
storybook-build: build-storybook-components
    cd demos/isonim-replica/storybook && npx storybook build

# Build standalone Web Components demo (Nim -> JS)
build-web-components:
    mkdir -p demos/web-components/dist
    nim js --path:../nim-everywhere/src -o:demos/web-components/dist/components.js demos/web-components/src/components.nim

# Build and serve the standalone Web Components demo page
demo-web-components: build-web-components
    @echo "Serving demos/web-components/ on http://localhost:8080"
    cd demos/web-components && python3 -m http.server 8080

# Collect benchmark metrics (sizes + test counts)
bench-metrics:
    ./scripts/collect-metrics.sh --all

# Collect bundle size metrics only
bench-metrics-sizes:
    ./scripts/collect-metrics.sh --sizes

# Collect test count metrics only
bench-metrics-tests:
    ./scripts/collect-metrics.sh --tests

# Build all bundles, collect metrics, and report
bench-all: bench-build demo-build build-web-components
    @echo "=== Bundle Size Metrics ==="
    ./scripts/collect-metrics.sh --sizes
    @echo ""
    @echo "=== Test Count Metrics ==="
    ./scripts/collect-metrics.sh --tests

# Lint hook expected by the workspace pre-commit framework. The IsoNim
# Nim style is enforced by --styleCheck:usages --styleCheck:error inside
# the test recipes; this recipe is a placeholder so pre-commit's
# `just lint` hook resolves. Extend it with nimpretty / nim check when
# the linting story is ready.
lint:
    @echo "isonim: lint placeholder (Nim style enforced inside test recipes)"
