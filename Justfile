# IsoNim — Isomorphic reactive web framework for Nim

# One-time provisioning for a fresh clone.  `git clone` does not populate
# submodules, and `src/isonim/layout/yoga` (facebook/yoga) is one: without it
# `isonim/layout/{flexbox,layout_engine,yoga_bindings}` — and every downstream
# consumer, notably isonim-tui's `layout/terminal_layout.nim` — cannot compile.
# Nothing else in this repo ran this, which is why fresh clones were broken.
setup:
    git -C "{{justfile_directory()}}" submodule update --init --recursive

# Fail loudly when a declared submodule is not provisioned, instead of letting
# it surface as an opaque Nim error deep inside a consumer's import graph.
# Wired into CI ahead of the test recipes; also runnable by hand.
check-submodules:
    #!/usr/bin/env bash
    set -euo pipefail
    cd "{{justfile_directory()}}"
    # `git submodule status` prefixes uninitialised entries with '-'.
    missing="$(git submodule status --recursive | grep '^-' | awk '{print $2}' || true)"
    if [ -n "$missing" ]; then
      echo "ERROR: git submodule(s) declared in .gitmodules but not initialised:" >&2
      echo "$missing" | sed 's/^/  - /' >&2
      echo "" >&2
      echo "A plain 'git clone' does not populate submodules. Run:" >&2
      echo "    just setup" >&2
      echo "(equivalently: git submodule update --init --recursive)" >&2
      echo "" >&2
      echo "In CI, give actions/checkout 'submodules: recursive'." >&2
      exit 1
    fi
    echo "[check-submodules] all $(git submodule status --recursive | wc -l | tr -d ' ') submodule(s) initialised"

# Fail loudly when a declared cross-repo sibling is not provisioned, and when
# `tests/config.nims` reaches a sibling `.github/sibling-repos` does not
# declare. Same purpose as `check-submodules`, one layer out.
#
# Both halves were broken at once. ci.yml carried no `setup-dev-env`, so NO
# sibling was on disk; and `.github/sibling-repos` named 4 of the 8 that
# `tests/config.nims` resolves, so even adding the step would have provisioned
# half a workspace. Either half surfaces as `cannot open file: <nim module>`
# from inside src/ — a message that names neither this repo's declaration file
# nor the repo the module lives in.
#
# Wired into CI ahead of the test recipes; also runnable by hand.
check-siblings:
    #!/usr/bin/env bash
    set -euo pipefail
    cd "{{justfile_directory()}}"

    decl_file=".github/sibling-repos"
    cfg="tests/config.nims"

    if [ ! -f "$decl_file" ]; then
      echo "ERROR: $decl_file is missing; CI has nothing to provision from." >&2
      exit 1
    fi

    # One repo per line. Strip comments and blanks, then strip the optional
    # `owner/` prefix and the optional `=<rev>` / `!=<rev>` pin, leaving the
    # bare name — which is what the clone is placed at (`../<name>`).
    declared="$(
      sed -e 's/#.*//' -e 's/[[:space:]]*$//' "$decl_file" \
        | sed -e 's/!\{0,1\}=.*$//' -e 's#^.*/##' \
        | grep -v '^$' \
        | sort -u
    )"

    # PART 1 — everything declared must be on disk next to this checkout.
    missing=""
    for repo in $declared; do
      [ -d "../$repo" ] || missing="$missing $repo"
    done
    if [ -n "$missing" ]; then
      echo "ERROR: cross-repo sibling(s) declared in $decl_file but not present:" >&2
      for repo in $missing; do echo "  - ../$repo" >&2; done
      echo "" >&2
      echo "Nim resolves these through 'switch(\"path\", ...)' in $cfg." >&2
      echo "Absent, the compile fails deep inside src/ with 'cannot open file:'" >&2
      echo "naming a module, not a repo — which is what this check replaces." >&2
      echo "" >&2
      echo "Locally: clone each one adjacent to this repo (a workspace checkout" >&2
      echo "already has them), e.g.  git -C .. clone git@github.com:metacraft-labs/<name>" >&2
      echo "In CI: the job must run metacraft-labs/metacraft-github-actions/setup-dev-env," >&2
      echo "which clones every $decl_file entry at its workspace-lock revision." >&2
      exit 1
    fi

    # PART 2 — everything ANY config.nims reaches must be declared. This is the
    # drift that made PART 1 insufficient on its own: a path added without a
    # matching declaration is a sibling CI will never clone.
    #
    # This used to read `tests/config.nims` ALONE, and matched the literal
    # prefix `../../`. Both were too narrow, and the narrowness was not
    # theoretical — the tree already had two configs it could not see:
    #
    #   demos/config.nims                      `$projectDir/../../nim-everywhere/src`
    #   benchmarks/keyed/isonim/src/config.nims  five `..` up, a different prefix
    #
    # so a sibling reached only from a demo or a benchmark was invisible to a
    # guard whose whole purpose is finding exactly that. Every config.nims in
    # the repo is scanned now, and each `$projectDir` path is RESOLVED against
    # its own directory rather than pattern-matched, so the number of `..` no
    # longer has to be guessed. Anything that lands outside the repo root is a
    # sibling reference, whatever depth it was written at.
    #
    # vendor/ and the yoga submodule are excluded: they are third-party trees
    # whose configs describe their own layout, not isonim's siblings.
    root_name="$(basename "$PWD")"
    reached=""
    cfg_count=0
    while IFS= read -r cfgfile; do
      cfg_count=$((cfg_count + 1))
      cfgdir="$(dirname "$cfgfile")"
      while IFS= read -r rel; do
        [ -n "$rel" ] || continue
        # Normalise "<cfgdir>/<rel>" by string, not by realpath: the target need
        # not exist (PART 1 owns existence) and realpath -m is not portable.
        # Anchored at the repo's own directory NAME, so that a path staying
        # inside the repo still begins with it and only an escape does not.
        norm=""
        IFS='/' read -r -a parts <<< "$root_name/${cfgdir#./}/${rel}"
        for p in "${parts[@]}"; do
          case "$p" in
          ""|".") ;;
          "..") norm="${norm% *}" ;;
          *) norm="$norm $p" ;;
          esac
        done
        # Inside the repo -> not a sibling. Outside -> the path was rewritten
        # relative to the repo's PARENT, so it now starts with the repo's own
        # directory name for anything internal; a sibling starts with its own.
        set -- $norm
        [ "$#" -ge 1 ] || continue
        [ "$1" = "$root_name" ] && continue
        reached="$reached $1"
      done < <(grep -o -E '\$projectDir[A-Za-z0-9_./-]*' "$cfgfile" | sed -e 's#^\$projectDir/\{0,1\}##')
    done < <(find . -name 'config.nims' -not -path './vendor/*' -not -path './src/isonim/layout/yoga/*' | sort)

    reached="$(printf '%s\n' $reached | grep -v '^$' | sort -u)"
    undeclared=""
    for repo in $reached; do
      printf '%s\n' "$declared" | grep -q -x -F "$repo" || undeclared="$undeclared $repo"
    done
    if [ -n "$undeclared" ]; then
      echo "ERROR: a config.nims resolves sibling(s) that $decl_file does not declare:" >&2
      for repo in $undeclared; do echo "  - $repo" >&2; done
      echo "" >&2
      echo "setup-dev-env clones exactly what $decl_file names, so an" >&2
      echo "undeclared sibling is one CI silently builds without." >&2
      echo "Add each name to $decl_file (one per line)." >&2
      exit 1
    fi
    echo "[check-siblings] $(printf '%s\n' "$reached" | wc -l | tr -d ' ') sibling(s) reached from $cfg_count config.nims file(s), all declared"

    echo "[check-siblings] all $(printf '%s\n' "$declared" | wc -l | tr -d ' ') declared sibling(s) present"

# Generate build/tailwind.css + build/tailwind-styles.json from the
# isonim source via the real Tailwind CSS CLI.  CodeTracer's
# scripts/build-once.sh invokes this before any Nim compile because
# ui_js.nim's staticRead of build/tailwind-styles.json is uncatchable
# at compile time.
build-tailwind:
    [ -d node_modules ] || yarn install --frozen-lockfile
    node tools/tailwind-extract.mjs

# Run all tests (both JS and C targets)
test: test-c test-js

# Run tests on C target
test-c:
    # C-only (compiles Yoga's C++ sources). Deliberately first: it is the one
    # recipe entry that reaches the `src/isonim/layout/yoga` submodule, so an
    # unprovisioned checkout goes red here with the guard message from
    # `yoga_bindings.nim` instead of building green over a missing dependency.
    nim c -r tests/test_flexbox.nim
    nim c -r tests/test_nimcache_is_worktree_local.nim
    nim c -r tests/test_signals.nim
    nim c -r tests/test_effects.nim
    nim c -r tests/test_clock.nim
    nim c -r tests/test_nondet_seams.nim
    nim c -r tests/test_context.nim
    nim c -r tests/test_rxcore.nim
    nim c -r --out:build/test_keyed_effect_lifetime tests/test_keyed_effect_lifetime.nim
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
    # NH-M1: the shared reactive-root scaffold (`renderNative`).
    nim c -r tests/test_render_native_reactive.nim
    nim c -r tests/test_nginx_module.nim
    nim c -r tests/test_corner_cases.nim
    nim c -r tests/test_accessibility.nim
    nim c -r tests/test_router.nim
    nim c -r tests/test_ssr_routing.nim
    nim c -r tests/test_server_functions.nim
    nim c -r tests/test_form_actions.nim
    nim c -r tests/test_rpc_dispatch.nim
    nim c -r tests/test_static_dist_dev_server.nim
    nim c -r tests/test_data_loading.nim
    nim c -r tests/test_file_routes.nim
    # isonim/content and isonim/theming/dtcg: the content libraries static
    # sites, blogs and HTML email share (Markdown, front matter, anchors,
    # highlighting, directives, DTCG tokens). Pure, so they run on both
    # targets; the DTCG suite reads token files, so it is C-only.
    nim c -r tests/test_content_markdown.nim
    nim c -r tests/test_content_frontmatter.nim
    nim c -r tests/test_content_anchors.nim
    nim c -r tests/test_content_highlight.nim
    nim c -r tests/test_content_directives.nim
    nim c -r tests/test_theming_dtcg.nim
    nim c -r tests/test_http_types.nim
    nim c -r tests/test_streaming_stress.nim
    nim c -r tests/test_third_party.nim
    nim c -r tests/poc_monaco_host.nim
    # Reaches `nim_everywhere/async_compat` through `src/isonim/core/resource.nim`.
    # Was in no recipe at all and named in no exclusion note — the same shape as
    # `test_flexbox` before the yoga fix, where being unreachable from any recipe
    # is what kept the missing provisioning invisible. It compiles and passes
    # 10/10 on the C target, so it gets a normal entry. C only: it calls
    nim c -r tests/test_resource_async.nim
    # Resources register with their owner; a root enumerates the live ones
    # created under it (`ownedResourceStates`).
    nim c -r tests/test_resource_registry.nim
    # NH-M0 & NH-M5 / HX-S-0: Native HCR shim tests (inactive path & active linked path)
    nim c -r tests/test_native_hcr_shim.nim
    # NH-M2: the native HMR runtime, in BOTH its gating configurations.
    # The pair is the point: the flag-on suite proves the machinery works,
    # the flag-off suite proves a production binary still has none of it
    # and still mounts build-once. Each file refuses to compile in the
    # other's configuration, so neither can pass vacuously.
    nim c -r -d:isonimHmr tests/test_native_hmr.nim
    nim c -r tests/test_native_hmr_inactive.nim
    # NH-M3: the {.uiComponent.} native arm. Compiles its own fixture six
    # times (three bodies x two backends), so it is slower than the rest
    # of this recipe — and it is the gate that gives every hash assertion
    # in the two files above a meaning, so it runs in the same lane.
    # No -d:isonimHmr here: the flag belongs to the fixture builds this
    # test performs, not to the test itself.
    nim c -r tests/test_uicomponent_native_arm.nim
    # NH-M3: the shared reconciliation engine, over the real NativeWidget
    # tree. No -d:isonimHmr: the reconciler is independent of the HMR
    # flag by design — a renderer may use it for any tree diff — and a
    # gate that needed the flag could not say so.
    nim c -r tests/test_native_reconciler.nim
    bash tests/test_hx_s0_isonim_link_line_names_something_that_exists.sh

# NH-M2 / NH-M3: native hot module reload, both gating configurations,
# plus the {.uiComponent.} native arm.
test-hmr:
    nim c -r -d:isonimHmr tests/test_native_hmr.nim
    nim c -r tests/test_native_hmr_inactive.nim
    nim c -r tests/test_uicomponent_native_arm.nim

# Run native HCR integration tests (inactive shim & active librepro_hcr_agent linking)
test-hcr:
    nim c -r tests/test_native_hcr_shim.nim
    bash tests/test_hx_s0_isonim_link_line_names_something_that_exists.sh

test-hcr-shim:
    bash tests/test_hx_s0_isonim_link_line_names_something_that_exists.sh

# Run tests on JS target.
#
# `build-tailwind` is a prerequisite, not a convention: on the JS target
# `src/isonim/dsl/tailwind.nim` reaches `build/tailwind-styles.json` through
# `staticRead`, which is uncatchable at compile time — the `try/except` around
# it at tailwind.nim:43 does NOT save it — so `nim js tests/test_dsl.nim` dies
# with `cannot open file: .../build/tailwind-styles.json` unless that file was
# generated first. Third unprovisioned build input of the same family as the
# yoga submodule and the cross-repo siblings, and the one the other two were
# hiding: this lane never got past `test_signals` while the siblings were
# missing, so it had never reached `test_dsl` to fail there.
test-js: build-tailwind
    nim js -d:nodejs --out:build/test_editor_workspace_refresh.js tests/test_editor_workspace_refresh.nim
    python3 tools/run_nim_js_test.py build/test_editor_workspace_refresh.js
    nim js -r --out:build/test_editor_control.js tests/test_editor_control.nim
    nim js -r tests/test_choice_row_activation.nim
    nim js -r tests/test_loop_accessors.nim
    nim js -r --out:build/test_keyed_effect_lifetime.js tests/test_keyed_effect_lifetime.nim
    nim js -r tests/test_signals.nim
    nim js -r tests/test_effects.nim
    nim js -r tests/test_clock.nim
    nim js tests/test_nondet_seams.nim
    python3 tools/run_nim_js_test.py tests/test_nondet_seams.js
    nim js --out:build/nondet_partial_window_boot.js tests/fixtures/nondet_partial_window_boot.nim
    "${ISONIM_SCENARIO_NODE:-node}" tests/test_nondet_partial_window.mjs
    nim js -r tests/test_context.nim
    nim js -r tests/test_resource_registry.nim
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
    nim js -r tests/test_form_actions.nim
    nim js -r tests/test_data_loading.nim
    # isonim/content (see test-c).
    nim js -r tests/test_content_markdown.nim
    nim js -r tests/test_content_frontmatter.nim
    nim js -r tests/test_content_anchors.nim
    nim js -r tests/test_content_highlight.nim
    nim js -r tests/test_content_directives.nim
    # The Web Worker target's message codec and build guard (IFP-M3).
    nim js -r tests/test_web_worker.nim

# Run only signal tests
test-signals:
    nim c -r tests/test_signals.nim
    nim js -r tests/test_signals.nim

# Run only clock/scheduler tests
test-clock:
    nim c -r tests/test_clock.nim
    nim c -r tests/test_nondet_seams.nim
    nim js -r tests/test_clock.nim
    nim js tests/test_nondet_seams.nim
    python3 tools/run_nim_js_test.py tests/test_nondet_seams.js

# Run only context/resource/suspense/transition tests
test-context:
    nim c -r tests/test_context.nim
    nim js -r tests/test_context.nim
    nim c -r tests/test_resource_registry.nim
    nim js -r tests/test_resource_registry.nim

# Run only effect/memo/owner/batch tests
test-effects:
    nim c -r tests/test_effects.nim
    nim js -r tests/test_effects.nim

# Run only rxcore/renderer/mock-dom tests
test-rxcore:
    nim c -r tests/test_rxcore.nim
    nim js -r tests/test_rxcore.nim

# Run only DSL/html/components tests
test-dsl: build-tailwind
    nim c -r tests/test_dsl.nim
    nim js -r tests/test_dsl.nim
    nim c -r tests/test_dsl_ssr.nim
    # Static vocabulary checks. C only: shells out to `nim check`.
    nim c -r tests/test_dsl_vocabulary.nim
    # Backend element hook (a renderer's typed `noteElement` overload), alone
    # and alongside the editor's scene-graph recording, which must both run.
    nim c -r tests/test_dsl_element_hook.nim
    nim c -r -d:isonimEditor tests/test_dsl_element_hook.nim
    # Without --variants the Tailwind extractor's JSON is byte-identical to
    # the pre-variants extractor (vendored under tests/fixtures/), on the
    # auto-scan and --content paths. Needs node_modules (build-tailwind).
    nim c -r tests/test_tailwind_extract_golden.nim
    # Variant-preserving Tailwind expansion, both modes against the fixture
    # map. C only: class expansion to setStyle calls is native-only.
    nim c -r -d:tailwindStylesPathOverride={{justfile_directory()}}/tests/dsl/tailwind/variant-styles.json tests/test_dsl_tailwind_variants.nim
    nim c -r -d:tailwindStylesPathOverride={{justfile_directory()}}/tests/dsl/tailwind/variant-styles.json -d:isonimTailwindVariants tests/test_dsl_tailwind_variants.nim

# Run only server function tests
test-server:
    nim c -r tests/test_server_functions.nim
    nim js -r tests/test_server_functions.nim
    nim c -r tests/test_form_actions.nim
    nim js -r tests/test_form_actions.nim
    nim c -r tests/test_rpc_dispatch.nim
    nim c -r tests/test_static_dist_dev_server.nim

# Run data loading (server resource) tests
test-data-loading:
    nim c -r tests/test_data_loading.nim
    nim js -r tests/test_data_loading.nim

# Run SSR and round-trip tests
test-ssr:
    nim c -r tests/test_ssr.nim
    nim c -r --out:build/test_ssr_serializer_safety tests/test_ssr_serializer_safety.nim
    nim c -r tests/test_streaming.nim
    nim c -r tests/test_dsl_ssr.nim
    nim c -r tests/test_round_trip.nim

# Run only web renderer tests (JS-only)
test-web:
    nim js -r tests/test_web.nim

# --- Tailwind CSS extracts ---

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
    cp build/bin/isonim-review build/bin/isonim
    @echo "Built: build/bin/isonim-review and build/bin/isonim"

# Read-only metadata and recovery across genuine native compiler transactions.
test-editor-source-metadata: isonim-review-build
    python3 tests/test_editor_source_metadata_transactions.py

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
# fake WebSocket servers + ephemeral reprobuild workspaces (the gate and
# the workspace pin read them through `repro`, which must be on PATH or
# named by $ISONIM_REVIEW_REPRO); the idempotency and e2e tests use the
# REV-M3 PgFixture + a real `isonim-review` subprocess.  All paths use
# the same `--path:` set the CLI build uses.
test-design-review-capture: isonim-review-build
    nim c -r --path:. --path:src --path:vendor/db_connector/src --path:../isonim-render-serve/src --path:../nim-everywhere/src --hints:off tests/test_design_review_clean_tree.nim
    nim c -r --path:. --path:src --path:vendor/db_connector/src --path:../isonim-render-serve/src --path:../nim-everywhere/src --hints:off tests/test_design_review_workspace_pin.nim
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
test-design-review-local-harbor:
    mkdir -p build/bin
    nim c -r --out:build/bin/test-design-review-local-harbor --path:src --path:../nim-everywhere/src --path:../nim-acp/src --path:../nim-agent-harbor/src --path:../nim-agents/src --hints:off tests/test_design_review_local_harbor.nim

# Real process/socket/flood/EOF/descriptor ownership boundaries.
test-daemon-ready-handshake:
    mkdir -p build/bin
    nim c -r --threads:on --out:build/bin/test-daemon-ready-handshake tests/test_daemon_ready_handshake.nim

# Actual CLI and cold producer responsiveness, singleflight and teardown.
test-design-review-harbor-preparation: isonim-review-build
    python3 tests/test_design_review_harbor_preparation.py

# Real Repro producer/consumer build, source mutation, and failure boundaries.
test-design-review-harbor-build:
    mkdir -p build/bin
    nim c -r --out:build/bin/test-design-review-harbor-build --path:src --path:../nim-everywhere/src --path:../nim-acp/src --path:../nim-agent-harbor/src --path:../nim-agents/src --hints:off tests/test_design_review_harbor_build.nim

test-design-review-harbor-own-producer: test-design-review-harbor-build
    ISONIM_HARBOR_BUILD_DRIVER="$PWD/build/bin/test-design-review-harbor-build" python3 tests/test_design_review_harbor_own_producer.py


# Private-repository acceptance: explicitly requires the selected local checkout.
test-design-review-harbor-live:
    mkdir -p build/bin
    nim c -r --out:build/bin/test-design-review-harbor-live --path:src --path:../nim-everywhere/src --path:../nim-acp/src --path:../nim-agent-harbor/src --path:../nim-agents/src --hints:off tests/test_design_review_harbor_live.nim


# Opt-in live private Harbor/provider acceptance; the producer CLI must be built.
test-design-review-harbor-persistent provider harbor="../agent-harbor":
    mkdir -p build/bin
    nim c --out:build/bin/test-harbor-persistent-live --path:src --path:../nim-everywhere/src --path:../nim-acp/src --path:../nim-agent-harbor/src --path:../nim-agents/src ../nim-agents/tests/test_harbor_persistent_live.nim
    python3 tests/run_harbor_persistent_live.py --harbor-repo "$(realpath '{{harbor}}')" --ah "$(realpath '{{harbor}}/build/bin/ah')" --provider "{{provider}}" --driver "$(realpath build/bin/test-harbor-persistent-live)"

test-editor-server: isonim-review-build
    python3 tests/test_editor_server.py
    python3 tests/test_editor_native_acp_shutdown.py

# Real editor routes and sibling producer, official deterministic agent only.
# Public workspaces skip only when the optional private checkout is absent.
# Private workspaces set ISONIM_HARBOR_SCENARIO_PROVIDER to built mock-agent.
test-editor-harbor-scenario:
    python3 tests/helpers/editor_scenario_checkout.py _editor-harbor-scenario

_editor-harbor-scenario: isonim-review-build
    python3 tests/test_editor_process_observer.py
    python3 tests/test_editor_harbor_scenario.py

test-design-review-chat: isonim-review-build fake-acp-agent-build
    nim c -r --path:src tests/test_design_review_class_quota.nim
    nim c -r tests/test_editor_scenario_protocol.nim
    nim c -r --path:src --path:vendor/db_connector/src --path:../nim-acp/src --path:../nim-agent-harbor/src --path:../nim-agents/src tests/test_editor_agent_route_ownership.nim
    nim c -r tests/test_editor_agent_harbor.nim
    nim js -r tests/test_editor_agent_harbor.nim
    python3 tests/test_editor_server.py
    python3 tests/test_agent_session_launcher.py
    python3 tests/test_harbor_route_lifecycle.py
    python3 tests/test_editor_process_observer.py
    python3 tests/test_editor_harbor_scenario.py
    nim js -r --path:src tests/test_browser_agent_lifecycle.nim
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
        --hints:off tests/test_design_review_chat_priming.nim

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
    # ``gmFullScreen`` is reachable from the toolbar chip AND from a
    # shift-click.  These tests keep it from regressing back into a
    # state that renders nothing, and keep ESC bound.
    nim c -r --path:src --path:. --path:../nim-everywhere/src --hints:off \
        tests/test_design_review_gallery_full_screen.nim
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
    # Pins the production Save-layout chip to the production HTTP
    # client: mounts ``mountGalleryHostForEditor`` under the
    # MockRenderer and asserts on the bytes that reach a stub daemon
    # socket.  Red if ``onSave`` is ever dropped from the mount site
    # again (the nil-``onSave`` fallback clears the dirty flag without
    # persisting, which is how the chip shipped as a placebo).
    nim c -r --path:. --path:src --path:../nim-everywhere/src \
        --path:../isonim-render-serve/src --hints:off \
        tests/test_design_review_gallery_save_layout_wired.nim
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
    python3 tools/editor_server.py --directory build/editor --project-root examples/wanderlust --port 8090

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

# Coherent synchronous story navigation and ownership, on both targets.
test-editor-story-navigation: build-tailwind
    nim c -r --out:build/test_editor_story_navigation tests/test_editor_story_navigation.nim
    nim js --out:build/test_editor_story_navigation.js tests/test_editor_story_navigation.nim
    python3 tools/run_nim_js_test.py build/test_editor_story_navigation.js

# Real component preview document generations preserve selection restoration.
test-editor-preview-generation: build-tailwind
    mkdir -p build/editor-generation
    nim js --out:build/editor-generation/fixture.js tests/test_editor_component_generation_fixture.nim
    PLAYWRIGHT_CHROMIUM_EXECUTABLE="${PLAYWRIGHT_CHROMIUM_EXECUTABLE:-$(command -v chromium)}" node tests/test_editor_component_generation.mjs
    PLAYWRIGHT_CHROMIUM_EXECUTABLE="${PLAYWRIGHT_CHROMIUM_EXECUTABLE:-$(command -v chromium)}" python3 tools/test_editor_preview_generation_mutants.py

# Run editor ViewModel tests
test-editor: test-design-review-local-harbor test-design-review-harbor-build test-design-review-harbor-own-producer test-editor-control test-editor-source test-editor-chat-activity test-editor-story-navigation test-editor-preview-generation
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
    nim c -r tests/test_editor_loop_handlers.nim
    nim c -r tests/test_loop_accessors.nim
    nim c -r tests/test_choice_row_activation.nim
    nim c -r tests/test_editor_task_views.nim
    nim c -r tests/test_editor_interactivity.nim
    nim c -r tests/test_editor_responsive.nim
    nim c -r tests/test_editor_streaming_preview.nim
    nim c -r tests/test_streaming_preview_element_tree_delta.nim
    nim c -r tests/test_scene_graph_hooks.nim
    nim c -r tests/test_editor_css_patch.nim
    nim c -r tests/test_editor_css_shadow.nim
    # Twice on purpose: the edit regime's claim is that a production build does
    # not emit it, which only the un-flagged run can check.
    nim c -r tests/test_editor_edit_regime.nim
    nim c -r -d:isonimEditor tests/test_editor_edit_regime.nim
    nim c -r tests/test_style_provenance.nim

# Run packaged editor browser tests.
test-browser-editor-example: editor-build
    PLAYWRIGHT_CHROMIUM_EXECUTABLE="${PLAYWRIGHT_CHROMIUM_EXECUTABLE:-$(command -v chromium)}" "${ISONIM_SCENARIO_NODE:-node}" tests/test_editor_example_reset_gui.mjs
    cd tests/browser && npm install && PLAYWRIGHT_CHROMIUM_EXECUTABLE="${PLAYWRIGHT_CHROMIUM_EXECUTABLE:-$(command -v chromium)}" npx playwright test --project=editor-example

# Run the M43 visual screenshot, pixel, layout, and review brief gates.
test-editor-visual-gates: editor-build
    node --test tests/test_editor_visual_review_brief.mjs
    cd tests/browser && npm install && PLAYWRIGHT_CHROMIUM_EXECUTABLE="${PLAYWRIGHT_CHROMIUM_EXECUTABLE:-$(command -v chromium)}" npx playwright test --project=editor-example --grep "e2e_editor_visual_baselines_cover_all_primary_modes|e2e_editor_ui_quality_no_overlap_or_unexpected_scrollbars|e2e_long_tail_css_property_visual_evidence"

# Run live consumer browser contract tests against metacraft-web.
test-browser-editor-consumer:
    cd ../metacraft-web && just build-back-office-editor
    cd tests/browser && npm install && PLAYWRIGHT_CHROMIUM_EXECUTABLE="${PLAYWRIGHT_CHROMIUM_EXECUTABLE:-$(command -v chromium)}" npx playwright test --project=metacraft-web-editor

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

# CMP-M2: Run the campaign storage + route + CLI + e2e tests.  The
# route + CLI + e2e tests spawn a real ``isonim-review serve`` daemon
# against an ephemeral PgFixture and a fake-ACP backend.  The campaign-pin
# tests (migration 012) read hermetic reprobuild workspaces through
# ``repro`` and an ephemeral PgFixture; they need no daemon.
test-design-review-campaigns: isonim-review-build fake-acp-agent-build
    nim c -r --path:. --path:src --path:vendor/db_connector/src \
        --hints:off tests/test_design_review_campaign_pins.nim
    nim c -r --path:. --path:src --path:vendor/db_connector/src \
        --hints:off tests/test_design_review_campaign_pins_pg.nim
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
        --hints:off tests/test_design_review_campaign_routes.nim
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
        --hints:off tests/test_design_review_cli_campaign.nim
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
        --hints:off tests/e2e_campaign_start_and_tick.nim

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

# Build the nginx fixture (tests/nginx/README.md): the sibling ngx-isonim
# module with the fixture's route manifest, server functions and SSR
# hydration app compiled in (built in ngx-isonim's dev shell), and the
# fixture's browser clients. `build-tailwind`: the hydration client is a
# JS build of the DSL (see `test-js`).
build-nginx-fixture: build-tailwind
    bash tests/nginx/build_fixture.sh

# Server functions over HTTP, the typed route manifest (IFP-M2) and the SSR
# -> hydrate -> interact round trip (IFP-M3) against real nginx with the
# real ngx-isonim module: the route-manifest test (its generated policy
# tests run against nginx), the nginx-rpc and ssr-hydration Playwright
# projects, and the falsifying mutations of those projects.  Needs the
# ngx-isonim sibling checkout and nix; not part of `just test`.
test-nginx: build-nginx-fixture
    nim c -r -d:isonimRpcPrefix=/api/v1/rpc tests/test_route_manifest.nim
    cd tests/browser && PLAYWRIGHT_CHROMIUM_EXECUTABLE="${PLAYWRIGHT_CHROMIUM_EXECUTABLE:-$(command -v chromium)}" npx playwright test --project=nginx-rpc --project=ssr-hydration
    bash tests/nginx/run_mutants.sh

# CI: `just test-nginx`, its full output also in test-logs/test-nginx.log
# (.github/workflows/nginx-tests.yml uploads that directory).
ci-test-nginx:
    #!/usr/bin/env bash
    set -euo pipefail
    mkdir -p test-logs
    just test-nginx 2>&1 | tee test-logs/test-nginx.log

# Build the HMR fixture bundle (JS target with -d:isonimHmr).
build-hmr-fixture:
    mkdir -p tests/browser/hmr_fixture
    nim js -d:isonimHmr --path:src --path:../nim-everywhere/src -o:tests/browser/hmr_fixture/main.js tests/browser/hmr_fixture/main.nim

# Run the HMR Playwright spec (requires: just build-hmr-fixture).
test-browser-hmr: build-hmr-fixture
    cd tests/browser && PLAYWRIGHT_CHROMIUM_EXECUTABLE="${PLAYWRIGHT_CHROMIUM_EXECUTABLE:-$(command -v chromium)}" npx playwright test --project=hmr

# Build the parametric-HMR fixture (JS target with -d:isonimHmr). The
# fixture exercises the parametric `{.uiComponent.}` dispatch and
# `mountUiHot` via two independent panel mounts.
build-hmr-parametric-fixture:
    mkdir -p tests/browser/hmr_parametric_fixture
    nim js -d:isonimHmr --path:src --path:../nim-everywhere/src -o:tests/browser/hmr_parametric_fixture/main.js tests/browser/hmr_parametric_fixture/main.nim

# Run the parametric-HMR Playwright spec.
test-browser-hmr-parametric: build-hmr-parametric-fixture
    cd tests/browser && PLAYWRIGHT_CHROMIUM_EXECUTABLE="${PLAYWRIGHT_CHROMIUM_EXECUTABLE:-$(command -v chromium)}" npx playwright test --project=hmr-parametric

# Build the SSE-transport fixture: the dev server, the "before" and
# "after" client bundles, and the seeded main.js. The Playwright
# project triggers a rebuild via the dev server's POST /__isonim/trigger
# endpoint to swap before → after at runtime.
build-hmr-transport-fixture:
    mkdir -p build
    nim c -d:isServer --path:src --path:../nim-everywhere/src --path:../nim-faststreams --path:../nim-stew -o:build/isonim_test_server tests/browser/hmr_transport_fixture/server.nim
    nim js -d:isonimHmr --path:src --path:../nim-everywhere/src -o:tests/browser/hmr_transport_fixture/before.js tests/browser/hmr_transport_fixture/app.nim
    nim js -d:isonimHmr -d:transportFixtureAfter --path:src --path:../nim-everywhere/src -o:tests/browser/hmr_transport_fixture/after.js tests/browser/hmr_transport_fixture/app.nim
    cp tests/browser/hmr_transport_fixture/before.js tests/browser/hmr_transport_fixture/main.js

# Run the SSE-transport Playwright spec.
test-browser-hmr-transport: build-hmr-transport-fixture
    cd tests/browser && PLAYWRIGHT_CHROMIUM_EXECUTABLE="${PLAYWRIGHT_CHROMIUM_EXECUTABLE:-$(command -v chromium)}" npx playwright test --project=hmr-transport

# Run Playwright browser tests (requires: just demo-build && cd tests/browser && npm install)
test-browser: test-browser-demo test-browser-ssr test-browser-hmr test-browser-hmr-parametric test-browser-hmr-transport

# --- Playwright: one-shot entry points ------------------------------------
#
# `playwright.config.ts` refuses to start with a hard error naming the
# missing artifact and the recipe that builds it, so these two targets are
# the supported way in: `browser-test-deps` produces every build input the
# in-repo Playwright projects serve, and `test-browser-all` builds then runs.
#
# The one-time setup that is NOT a build (do it once per checkout):
#
#   git submodule update --init --depth 1 src/isonim/layout/yoga
#   repro exec -- npm --prefix tests/browser install
#   repro exec -- npx --prefix tests/browser playwright install chromium
#
# Without the submodule `repro exec` itself fails, and `repro exec` is what
# puts node on PATH. See tests/browser/README.md.

# Build every artifact the six static in-repo Playwright projects serve.
# (`metacraft-web-editor` is excluded: it serves a bundle from the
# metacraft-web sibling repo — see `test-browser-editor-consumer`;
# `nginx-rpc` and `ssr-hydration` run against real nginx in `test-nginx`.)
#
# `build-tailwind` first, for the reason spelled out above `test-js`: every
# `nim js` compile below reaches `build/tailwind-styles.json` through an
# uncatchable `staticRead`. On a warm working copy that file already exists,
# which is exactly why its absence would only ever have bitten a cold runner.

# Build every artifact the six static in-repo Playwright projects serve.
browser-test-deps: build-tailwind demo-build build-hmr-fixture build-hmr-parametric-fixture build-hmr-transport-fixture build-web-worker-fixture editor-build

# Separate from `browser-test-deps` because it is the only step here that
# touches the network.

# Install the browser-test npm deps + a chromium build.
# On Linux the dev shell provides nixpkgs' chromium, and the suite drives it
# through PLAYWRIGHT_CHROMIUM_EXECUTABLE (the smoke/demo/all recipes below).
# Playwright's own download is a glibc build that cannot start on NixOS hosts
# -- including the NixOS self-hosted CI runners -- so it is fetched only when
# no chromium is on PATH (macOS).
browser-test-install:
    npm --prefix tests/browser install
    if ! command -v chromium >/dev/null 2>&1; then npx --prefix tests/browser playwright install chromium; fi

# Build everything, then run the six static in-repo Playwright projects (51 tests).
test-browser-all: browser-test-deps
    PLAYWRIGHT_CHROMIUM_EXECUTABLE="${PLAYWRIGHT_CHROMIUM_EXECUTABLE:-$(command -v chromium)}" "${ISONIM_SCENARIO_NODE:-node}" tests/test_editor_example_reset_gui.mjs
    cd tests/browser && PLAYWRIGHT_CHROMIUM_EXECUTABLE="${PLAYWRIGHT_CHROMIUM_EXECUTABLE:-$(command -v chromium)}" npx playwright test --project=demo-app --project=hmr --project=hmr-parametric --project=hmr-transport --project=web-worker --project=editor-example

# The gate run on every push: the three HMR projects, 25 tests, ~20s of
# browser time once the Nim fixtures are built.
#
# `demo-app` is deliberately NOT here, and is not skipped either — it runs in
# `test-browser-all`, and it is currently red on a real product defect
# diagnosed in tests/browser/README.md. A permanently red required gate
# teaches people to ignore CI, which is how this suite came to rot in the
# first place. Move it in as soon as it is fixed. (`ssr-hydration` needs
# real nginx and runs in `test-nginx`.)
#
# `editor-example` is out for cost, not colour: its 14 screenshot and layout
# tests take ~4 minutes on their own, against a runner pool that is small and
# permanently saturated. It runs nightly.

# The CI gate: the three HMR Playwright projects, 25 tests, ~56s cold.
test-browser-smoke: build-tailwind build-hmr-fixture build-hmr-parametric-fixture build-hmr-transport-fixture
    cd tests/browser && PLAYWRIGHT_CHROMIUM_EXECUTABLE="${PLAYWRIGHT_CHROMIUM_EXECUTABLE:-$(command -v chromium)}" npx playwright test --project=hmr --project=hmr-parametric --project=hmr-transport

# Run Playwright demo app tests only
test-browser-demo: demo-build
    cd tests/browser && PLAYWRIGHT_CHROMIUM_EXECUTABLE="${PLAYWRIGHT_CHROMIUM_EXECUTABLE:-$(command -v chromium)}" npx playwright test --project=demo-app

# The Web Worker build target's fixture (IFP-M3; IsoNim.md § Web Worker
# Target): a compile module built as a worker chunk (preview.worker.js), the
# page script that drives it through a WorkerBridge (main.js), and the
# negative control with the same module linked into the page script
# (main.inline.js), each recorded in the directory's bundle manifest, whose
# size report closes the recipe.
build-web-worker-fixture:
    rm -rf build/web-worker-fixture
    node tools/isonim-bundle.mjs build --kind worker --minify --entry tests/browser/web_worker_fixture/preview_worker.nim --out build/web-worker-fixture/preview.worker.js -- --path:src --path:../nim-everywhere/src
    node tools/isonim-bundle.mjs build --kind main --minify --entry tests/browser/web_worker_fixture/main.nim --out build/web-worker-fixture/main.js -- --path:src --path:../nim-everywhere/src
    node tools/isonim-bundle.mjs build --kind main --minify --entry tests/browser/web_worker_fixture/main.nim --out build/web-worker-fixture/main.inline.js -- -d:previewInline --path:src --path:../nim-everywhere/src
    cp tests/browser/web_worker_fixture/index.html tests/browser/web_worker_fixture/inline.html tests/browser/web_worker_fixture/beacon.js build/web-worker-fixture/
    node tools/isonim-bundle.mjs report build/web-worker-fixture

# Run the Web Worker target's Playwright spec.
test-browser-web-worker: build-web-worker-fixture
    cd tests/browser && PLAYWRIGHT_CHROMIUM_EXECUTABLE="${PLAYWRIGHT_CHROMIUM_EXECUTABLE:-$(command -v chromium)}" npx playwright test --project=web-worker

# Run the Playwright SSR hydration round trip against real nginx (the nginx
# fixture; needs the ngx-isonim sibling and nix, as `test-nginx` does)
test-browser-ssr: build-nginx-fixture
    cd tests/browser && PLAYWRIGHT_CHROMIUM_EXECUTABLE="${PLAYWRIGHT_CHROMIUM_EXECUTABLE:-$(command -v chromium)}" npx playwright test --project=ssr-hydration

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

# Shared typed command host, native scoped RPC and real mounted browser/CLI gate.
test-editor-control: isonim-review-build editor-control-build
    nim c -r tests/test_editor_control.nim
    nim js -r --out:build/test_editor_control.js tests/test_editor_control.nim
    nim c -r tests/test_editor_control_routes.nim
    nim c -r tests/test_editor_agent_launch_cleanup.nim
    python3 tests/test_editor_agent_env.py
    python3 tests/test_editor_cli_wait.py
    node tests/test_editor_control_gui.mjs

# Isolated mounted control acceptance bundle; does not bake/alter project briefs.
editor-control-build:
    mkdir -p build/editor-control
    nim js --path:src --path:. --path:../nim-everywhere/src --path:../isonim-render-serve/src --path:../nim-acp/src --path:../nim-agent-harbor/src --path:../nim-agents/src -o:build/editor-control/editor.js tests/helpers/editor_control_workspace.nim
    node --check build/editor-control/editor.js
    cp src/isonim/editor/index.html build/editor-control/index.html
    cp node_modules/fabric/dist/index.min.js build/editor-control/fabric.min.js
    cp node_modules/paper/dist/paper-core.min.js build/editor-control/paper-core.min.js
    cp node_modules/svgo/dist/svgo.browser.js build/editor-control/svgo.browser.js

# Real source-project consumer, isolated from all existing editor assets.
source-editor-build:
    mkdir -p build/editor-source
    python3 tools/build_source_catalog.py examples/source_project
    nim js --path:src --path:. --path:../nim-everywhere/src --path:../isonim-render-serve/src --path:../nim-acp/src --path:../nim-agent-harbor/src --path:../nim-agents/src -o:build/editor-source/editor.js examples/source_project/editor.nim
    node --check build/editor-source/editor.js
    cp src/isonim/editor/index.html build/editor-source/index.html
    cp node_modules/fabric/dist/index.min.js build/editor-source/fabric.min.js
    cp node_modules/paper/dist/paper-core.min.js build/editor-source/paper-core.min.js
    cp node_modules/svgo/dist/svgo.browser.js build/editor-source/svgo.browser.js

source-editor-serve: isonim-review-build source-editor-build
    python3 tools/editor_server.py --directory build/editor-source --project-root examples/source_project --port 8095

# Native persistence/compiler and full mounted GUI acceptance, no substitute compiler.
test-editor-source: isonim-review-build source-editor-build
    nim c -r tests/test_editor_workspace_refresh.nim
    nim js -d:nodejs --out:build/test_editor_workspace_refresh.js tests/test_editor_workspace_refresh.nim
    python3 tools/run_nim_js_test.py build/test_editor_workspace_refresh.js
    python3 tests/test_editor_source_project.py
    python3 tests/test_editor_native_acp_shutdown.py
    node tests/test_editor_source_gui.mjs

# Production mounted chat state/keyboard/layout verification, isolated assets.
editor-chat-build:
    mkdir -p build/editor-chat
    nim js --path:src --path:. --path:../nim-everywhere/src --path:../isonim-render-serve/src --path:../nim-acp/src --path:../nim-agent-harbor/src --path:../nim-agents/src -o:build/editor-chat/editor.js tests/helpers/editor_chat_workspace.nim
    node --check build/editor-chat/editor.js
    cp src/isonim/editor/index.html build/editor-chat/index.html
    cp node_modules/fabric/dist/index.min.js build/editor-chat/fabric.min.js
    cp node_modules/paper/dist/paper-core.min.js build/editor-chat/paper-core.min.js
    cp node_modules/svgo/dist/svgo.browser.js build/editor-chat/svgo.browser.js

test-editor-chat-activity: editor-chat-build
    nim c -r tests/test_editor_chat_activity.nim
    nim js -r --out:build/test_editor_chat_activity.js tests/test_editor_chat_activity.nim
    nim c -r tests/test_editor_preview_toolbar.nim
    nim js -r --out:build/test_editor_preview_toolbar.js tests/test_editor_preview_toolbar.nim
    node tests/test_editor_chat_activity_gui.mjs
    node tests/test_editor_admission_gui.mjs

# Optional private Harbor acceptance: absence is the only allowed automatic skip.
# When the sibling exists, missing/broken official provider and builds fail.
test-editor-preparation-clock:
    python3 tests/test_editor_preparation_clock.py
    "${ISONIM_SCENARIO_NODE:-node}" tests/test_editor_preparation_clock.mjs

editor-scenario-host-build:
    nim c --out:build/bin/editor-scenario-host tests/test_editor_scenario_host.nim

# Output-mode compatibility through the owned current sibling and real provider.
test-editor-harbor-output-modes:
    python3 tests/helpers/editor_scenario_checkout.py _editor-harbor-output-modes

_editor-harbor-output-modes: isonim-review-build source-editor-build
    python3 tests/test_editor_harbor_output_modes.py

test-editor-scenarios-native:
    python3 tests/helpers/editor_scenario_checkout.py _editor-scenarios-native

_editor-scenarios-native: test-editor-preparation-clock isonim-review-build source-editor-build editor-scenario-host-build
    python3 tests/test_editor_scenarios.py
    python3 tests/test_editor_scenario_resources.py

test-editor-scenarios-gui:
    python3 tests/helpers/editor_scenario_checkout.py _editor-scenarios-gui

_editor-scenarios-gui: test-editor-preparation-clock isonim-review-build source-editor-build
    python3 tests/run_editor_scenarios_gui.py

test-editor-scenarios-stress:
    python3 tests/helpers/editor_scenario_checkout.py _editor-scenarios-stress

_editor-scenarios-stress: test-editor-preparation-clock isonim-review-build source-editor-build editor-scenario-host-build
    python3 tests/test_editor_scenario_stress.py

test-editor-scenarios: test-editor-scenarios-native test-editor-scenarios-gui test-editor-scenarios-stress


# Opt-in real Claude authoring acceptance; missing credentials/provider FAIL this
# explicitly requested gate. It never substitutes playback for model inference.
editor-authoring-build:
    mkdir -p build/editor-authoring
    nim js --path:src --path:. --path:../nim-everywhere/src --path:../isonim-render-serve/src --path:../nim-acp/src --path:../nim-agent-harbor/src --path:../nim-agents/src -o:build/editor-authoring/editor.js tests/helpers/editor_authoring_workspace.nim
    node --check build/editor-authoring/editor.js
    cp src/isonim/editor/index.html build/editor-authoring/index.html
    cp node_modules/fabric/dist/index.min.js build/editor-authoring/fabric.min.js
    cp node_modules/paper/dist/paper-core.min.js build/editor-authoring/paper-core.min.js
    cp node_modules/svgo/dist/svgo.browser.js build/editor-authoring/svgo.browser.js

test-editor-authoring-evidence: test-editor-preparation-clock
    python3 tests/test_editor_authoring_evidence.py
    python3 tests/test_editor_scenario_cleanup.py
    node tests/test_editor_close_ack.mjs
    python3 tests/test_editor_authoring_responses.py
    python3 tests/test_editor_authoring_assistant_evidence.py
    python3 tests/test_editor_provider_closure.py
    node tests/test_editor_sdk_protocol_observer.mjs
    node tests/test_editor_sdk_kernel_evidence.mjs

# Fresh runtime fact: ambient explicit provider is rederived and hashed. An old
# dev-shell provider is a clear failure; no guessed private store path or skip.
editor-authoring-runtime:
    python3 tests/helpers/editor_sdk_runtime.py build/editor-sdk-runtime.json

test-editor-sdk-native: editor-authoring-runtime
    python3 tests/test_editor_sdk_runtime.py
    python3 tests/test_editor_sdk_native_controls.py

test-editor-authoring-response-sequencing: isonim-review-build editor-authoring-build test-editor-authoring-evidence
    python3 tests/test_editor_authoring_response_sequencing.py

test-editor-authoring-real: isonim-review-build editor-authoring-build test-editor-authoring-evidence test-editor-sdk-native
    python3 tests/test_editor_authoring_real.py

# M7: real production browser bundle, pinned two-process canary before corpus.
# First corpus is a candidate; human baseline acceptance remains a separate gate.
test-editor-chat-visual output="build/chat-visual-campaign": test-editor-chat-contract editor-chat-build
    just test-editor-chat-visual-readiness "{{output}}"
    python3 tools/chat-visual-campaign.py --output "{{output}}"
    python3 tests/test_chat_visual_tools.py --captures "{{output}}"

test-editor-chat-visual-tools output="build/chat-visual-campaign":
    just test-editor-chat-visual-readiness "{{output}}"
    python3 tests/test_chat_visual_tools.py --captures "{{output}}"

test-editor-chat-visual-readiness output="build/chat-visual-readiness":
    mkdir -p "{{output}}"
    rm -f "{{output}}/readiness.cid"
    docker run --rm --cidfile "{{output}}/readiness.cid" --platform linux/amd64 --network none --ipc private --shm-size 1g --user "$(id -u):$(id -g)" -e HOME=/tmp -v "$(pwd):/workspace:ro" -w /workspace mcr.microsoft.com/playwright@sha256:eac9b0a5312cdab40ee8c2429df5bf19bffdccf8f3bf3c42268e173f97541645 node --test tests/test_chat_capture_frames.mjs

# Optional private contract authority; when present malformed DTOs fail.
test-editor-chat-contract:
    python3 tools/validate-chat-event-corpus.py

# Entering the dev shell from another git repository must write nothing there.
# Runs `nix develop`, so it is not part of the in-shell test recipes.
test-dev-shell:
    bash tests/test_dev_shell_writes_nothing_elsewhere.sh
    bash tests/test_dev_shell_linked_worktree.sh

# Functional inspector popup geometry, focus and private-source acceptance.
editor-popup-build:
    mkdir -p build/editor-popup
    nim js -d:isonimCatalogOnlyPopup --path:src --path:. --path:../nim-everywhere/src --path:../isonim-render-serve/src --path:../nim-acp/src --path:../nim-agent-harbor/src --path:../nim-agents/src -o:build/editor-popup/editor.js tests/helpers/editor_popup_workspace.nim
    "${ISONIM_SCENARIO_NODE:-node}" --check build/editor-popup/editor.js
    nim js --path:src --path:. --path:../nim-everywhere/src -o:build/editor-popup/core-owner-hmr.js tests/helpers/core_owner_hmr.nim
    "${ISONIM_SCENARIO_NODE:-node}" --check build/editor-popup/core-owner-hmr.js

test-editor-popup: isonim-review-build editor-popup-build
    nim c -r --out:build/test_editor_color_popover tests/test_editor_color_popover.nim
    nim js -d:nodejs --out:build/test_editor_color_popover.js tests/test_editor_color_popover.nim
    python3 tools/run_nim_js_test.py build/test_editor_color_popover.js
    nim c -r --out:build/test_signals_popup tests/test_signals.nim
    nim js -r --out:build/test_signals_popup.js tests/test_signals.nim
    "${ISONIM_SCENARIO_NODE:-node}" tests/test_core_owner_hmr.mjs
    "${ISONIM_SCENARIO_NODE:-node}" tests/test_editor_popover_geometry.mjs
    "${ISONIM_SCENARIO_NODE:-node}" tests/test_editor_selection_restore_gui.mjs
    "${ISONIM_SCENARIO_NODE:-node}" tests/test_editor_history_focus_resize_gui.mjs
    "${ISONIM_SCENARIO_NODE:-node}" tests/test_editor_popup_gui.mjs

# Sidebar drags that cross onto the preview iframe, and inspector focus across
# browser Back/Forward, in the mounted production editor (also in test-editor-popup).
test-editor-history-focus-resize: isonim-review-build editor-popup-build
    "${ISONIM_SCENARIO_NODE:-node}" tests/test_editor_history_focus_resize_gui.mjs

# Explicit required sibling: metacraft-web's production adapter is imported;
# this never silently skips or substitutes an IsoNim-native writer.
test-editor-color-source:
    test -f ../metacraft-web/apps/back-office/src/backoffice_editor/workspace.nim
    nim c -r --path:../metacraft-web/apps/back-office/src --path:../metacraft-web/packages/metacraft-design/src --out:build/test_editor_color_source tests/test_editor_color_source.nim

# Authoritative native-inspector composition; legacy popup tests opt in above.
editor-inspector-build: build-tailwind
    mkdir -p build/editor-inspector
    nim js --path:src --path:. --path:../nim-everywhere/src --path:../isonim-render-serve/src --path:../nim-acp/src --path:../nim-agent-harbor/src --path:../nim-agents/src -o:build/editor-inspector/editor.js tests/helpers/editor_popup_workspace.nim
    "${ISONIM_SCENARIO_NODE:-node}" --check build/editor-inspector/editor.js

# Only the accepted C2 unittest units use the semantic JS outcome guard.
test-editor-c2-headless:
    #!/usr/bin/env bash
    set -euo pipefail
    python3 tests/test_nim_js_guard.py
    for stem in test_effects test_editor_widget_property_row test_editor_color_popover test_editor_section_fill test_editor_source_scope_row; do
      nim c -r --out:build/"$stem" tests/"$stem".nim
      nim js -d:nodejs --out:build/"$stem".js tests/"$stem".nim
      python3 tools/run_nim_js_test.py build/"$stem".js
    done

# Genuine temporary source, authenticated native transactions/compiler/preview.
test-editor-c2-source: isonim-review-build editor-inspector-build
    "${ISONIM_SCENARIO_NODE:-node}" tests/test_editor_fill_readonly_gui.mjs
    "${ISONIM_SCENARIO_NODE:-node}" tests/test_editor_inspector_source_gui.mjs
    "${ISONIM_SCENARIO_NODE:-node}" tests/test_editor_native_reset_gui.mjs
    "${ISONIM_SCENARIO_NODE:-node}" tests/test_editor_native_compiled_reset_gui.mjs
    "${ISONIM_SCENARIO_NODE:-node}" tests/test_editor_native_compiled_scope_sides_gui.mjs

test-editor-c2-lifetime: isonim-review-build editor-popup-build
    "${ISONIM_SCENARIO_NODE:-node}" tests/test_core_owner_hmr.mjs
    "${ISONIM_SCENARIO_NODE:-node}" tests/test_editor_popover_geometry.mjs
    "${ISONIM_SCENARIO_NODE:-node}" tests/test_editor_selection_restore_gui.mjs

test-editor-c2: test-editor-c2-headless test-editor-c2-source test-editor-c2-lifetime test-editor-popup

# ColorPicker draft coordinates and existing source popup compatibility.
test-editor-c3-headless:
    nim c -r --out:build/test_editor_color_picker tests/test_editor_color_picker.nim
    nim js -d:nodejs --out:build/test_editor_color_picker.js tests/test_editor_color_picker.nim
    python3 tools/run_nim_js_test.py build/test_editor_color_picker.js
    nim c -r --out:build/test_editor_color_popover tests/test_editor_color_popover.nim
    nim js -d:nodejs --out:build/test_editor_color_popover.js tests/test_editor_color_popover.nim
    python3 tools/run_nim_js_test.py build/test_editor_color_popover.js

# Actual default-native ColorPicker/source/compiler acceptance.
test-editor-c3-source: isonim-review-build editor-inspector-build
    "${ISONIM_SCENARIO_NODE:-node}" tests/test_editor_color_picker_gui.mjs

test-editor-c3: test-editor-c3-headless test-editor-c3-source test-editor-popup

# Actual production preview capture and selected metadata normalization.
editor-flex-metadata-build: build-tailwind
    mkdir -p build/editor-flex-metadata
    nim js --path:src --path:. --path:../nim-everywhere/src --path:../isonim-render-serve/src --path:../nim-acp/src --path:../nim-agent-harbor/src --path:../nim-agents/src -o:build/editor-flex-metadata/editor.js tests/helpers/editor_flex_metadata_workspace.nim
    "${ISONIM_SCENARIO_NODE:-node}" --check build/editor-flex-metadata/editor.js

test-editor-flex-metadata-headless: build-tailwind
    nim c -r --out:build/test_editor_flex_metadata tests/test_editor_flex_metadata.nim
    nim js -d:nodejs --out:build/test_editor_flex_metadata.js tests/test_editor_flex_metadata.nim
    python3 tools/run_nim_js_test.py build/test_editor_flex_metadata.js

test-editor-flex-metadata-source: isonim-review-build editor-flex-metadata-build
    timeout --signal=TERM --kill-after=15s 180s "${ISONIM_SCENARIO_NODE:-node}" tests/test_editor_flex_metadata_gui.mjs

test-editor-flex-metadata: test-editor-flex-metadata-headless test-editor-flex-metadata-source

# Remaining approved inspector section parity; real source suites follow.
test-editor-c4a-headless: build-tailwind
    #!/usr/bin/env bash
    set -euo pipefail
    for stem in test_editor_section_appearance test_editor_section_component_props test_editor_section_layout test_editor_section_position test_editor_section_typography test_editor_section_stroke test_editor_section_state test_editor_section_effects; do
      nim c -r --out:build/"$stem" tests/"$stem".nim
      nim js -d:nodejs --out:build/"$stem".js tests/"$stem".nim
      python3 tools/run_nim_js_test.py build/"$stem".js
    done

# Actual source/compiler/preview/undo controls; each original GUI bound retained.
test-editor-c4a-compounds: isonim-review-build editor-inspector-build
    timeout --signal=TERM --kill-after=15s 180s "${ISONIM_SCENARIO_NODE:-node}" tests/test_editor_inspector_compounds_gui.mjs

# Additive bounded ordinary-property matrix: 39 real source/compiler edits,
# undo/redo/reload and refusal. Original compounds/gesture bounds stay 180s.
test-editor-c4a-properties: isonim-review-build editor-inspector-build
    timeout --signal=TERM --kill-after=15s 240s "${ISONIM_SCENARIO_NODE:-node}" tests/test_editor_inspector_properties_gui.mjs

# Remaining ordinary controls and actual DSL schema/state admission:21 source
# edits plus undo/redo/reload/refusal. Existing GUI bounds are unchanged.
test-editor-c4a-remaining: isonim-review-build editor-inspector-build
    timeout --signal=TERM --kill-after=15s 180s "${ISONIM_SCENARIO_NODE:-node}" tests/test_editor_inspector_remaining_gui.mjs

# Catalog-only actual inline declaration ownership and physical State workflow.
# Separate finite180s entry; original source and inspector bounds stay unchanged.
test-editor-inline-preview-headless:
    nim c -r --out:build/test_editor_section_state tests/test_editor_section_state.nim
    nim js -d:nodejs --out:build/test_editor_section_state.js tests/test_editor_section_state.nim
    python3 tools/run_nim_js_test.py build/test_editor_section_state.js

test-editor-inline-preview: test-editor-inline-preview-headless isonim-review-build editor-popup-build
    timeout --signal=TERM --kill-after=15s 180s "${ISONIM_SCENARIO_NODE:-node}" tests/test_editor_inline_preview_gui.mjs

test-editor-c4a-gestures: isonim-review-build editor-inspector-build
    timeout --signal=TERM --kill-after=15s 180s "${ISONIM_SCENARIO_NODE:-node}" tests/test_editor_inspector_gestures_gui.mjs

test-editor-c4a-color: build-tailwind
    timeout --signal=TERM --kill-after=15s 180s "${ISONIM_SCENARIO_NODE:-node}" tests/test_editor_color_parity.mjs

test-editor-c4a-grip: isonim-review-build build-tailwind
    timeout --signal=TERM --kill-after=15s 180s "${ISONIM_SCENARIO_NODE:-node}" tests/test_editor_source_style_gui.mjs
    timeout --signal=TERM --kill-after=15s 180s "${ISONIM_SCENARIO_NODE:-node}" tests/test_editor_source_style_values_gui.mjs

# Undo/redo restores exactly the source lines each written inspector edit
# wrote, refuses unsafe restorations, and never re-targets a sibling edit that
# shares the value text. Native and strict executed Node JS.
test-editor-source-write-receipts:
    nim c -r --out:build/test_editor_source_write_receipts tests/test_editor_source_write_receipts.nim
    nim js -d:nodejs --out:build/test_editor_source_write_receipts.js tests/test_editor_source_write_receipts.nim
    python3 tools/run_nim_js_test.py build/test_editor_source_write_receipts.js

# Every commit path (component property/state, foundation token, vector,
# canvas command) schedules the automatic write, and a write keeps those
# histories: undo after it restores exactly the written lines. Native and
# strict executed Node JS.
test-editor-save-pipeline:
    nim c -r --out:build/test_editor_save_pipeline tests/test_editor_save_pipeline.nim
    nim js -d:nodejs --out:build/test_editor_save_pipeline.js tests/test_editor_save_pipeline.nim
    python3 tools/run_nim_js_test.py build/test_editor_save_pipeline.js

# A refusal happens when the user acts, not at the write: an edit no project
# schema entry can write is refused at the commit (and its scope shown
# disabled), an undo/redo the write transaction would refuse is refused at the
# keystroke, and the Foundations page Undo is the shared undo command. Native
# and strict executed Node JS.
test-editor-act-time-refusals:
    nim c -r --out:build/test_editor_act_time_refusals tests/test_editor_act_time_refusals.nim
    nim js -d:nodejs --out:build/test_editor_act_time_refusals.js tests/test_editor_act_time_refusals.nim
    python3 tools/run_nim_js_test.py build/test_editor_act_time_refusals.js

# Which shared source scope a property row offers, commits at by default and
# lets Reset at, once a project declares an honest shared owner for a value
# captured off the preview: only the element's own owners are offered, a
# captured unauthored value defaults to the local instance, a scope the
# writer refuses is disabled with its reason, and Detach overrides locally.
# Native and strict executed Node JS.
test-editor-shared-scope-ownership: build-tailwind
    nim c -r --out:build/test_editor_shared_scope_ownership tests/test_editor_shared_scope_ownership.nim
    nim js -d:nodejs --out:build/test_editor_shared_scope_ownership.js tests/test_editor_shared_scope_ownership.nim
    python3 tools/run_nim_js_test.py build/test_editor_shared_scope_ownership.js

# The inspector's section search, its property Copy / Paste / Reset menu
# (row More button and right-click) and the colour picker's typed RGB / HSL
# fields committing on Enter. Native and strict executed Node JS.
test-editor-inspector-controls:
    nim c -r --out:build/test_editor_inspector_controls tests/test_editor_inspector_controls.nim
    nim js -d:nodejs --out:build/test_editor_inspector_controls.js tests/test_editor_inspector_controls.nim
    python3 tools/run_nim_js_test.py build/test_editor_inspector_controls.js

# Reset to default: an empty commit removes the declaration that owns the
# property through the editor example's real writer (admission per schema
# entry, act-time refusal, undo through the write receipt); plus the
# inspector-controls review notes (text-field right-click, deliberate Alpha 0%,
# asynchronous Cancel point). Native and strict executed Node JS.
test-editor-reset-removal: build-tailwind
    nim c -r --out:build/test_editor_reset_removal tests/test_editor_reset_removal.nim
    nim js -d:nodejs --out:build/test_editor_reset_removal.js tests/test_editor_reset_removal.nim
    python3 tools/run_nim_js_test.py build/test_editor_reset_removal.js

# Reset, set, undo, undo in the packaged editor example: its real example
# writer, served from build/editor, physical pointer and keyboard input.
test-editor-example-reset-gui: editor-build
    PLAYWRIGHT_CHROMIUM_EXECUTABLE="${PLAYWRIGHT_CHROMIUM_EXECUTABLE:-$(command -v chromium)}" "${ISONIM_SCENARIO_NODE:-node}" tests/test_editor_example_reset_gui.mjs

test-editor-c4a: test-editor-selection-keys test-editor-source-write-receipts test-editor-save-pipeline test-editor-act-time-refusals test-editor-shared-scope-ownership test-editor-inspector-controls test-editor-reset-removal test-editor-c4a-headless test-editor-c4a-compounds test-editor-c4a-properties test-editor-c4a-remaining test-editor-inline-preview test-editor-c4a-gestures test-editor-c4a-color test-editor-c4a-grip

# Source ownership presentation; real native/JS signals and shell, no transports.
test-editor-source-labels: build-tailwind
    #!/usr/bin/env bash
    set -euo pipefail
    for stem in test_editor_section_source test_editor_source_scope_labels test_editor_source_scope_row test_editor_section_component_props; do
      nim c -r --out:build/$stem tests/$stem.nim
    done
    for stem in test_editor_section_source test_editor_source_scope_row test_editor_section_component_props; do
      nim js -d:nodejs --out:build/$stem.js tests/$stem.nim
      python3 tools/run_nim_js_test.py build/$stem.js
    done

editor-source-labels-build: build-tailwind
    mkdir -p build/editor-source-labels
    nim js --path:src --path:. --path:../nim-everywhere/src --path:../isonim-render-serve/src --path:../nim-acp/src --path:../nim-agent-harbor/src --path:../nim-agents/src -o:build/editor-source-labels/editor.js tests/helpers/editor_source_scope_browser.nim
    "${ISONIM_SCENARIO_NODE:-node}" --check build/editor-source-labels/editor.js

test-editor-source-labels-gui: editor-source-labels-build
    timeout --signal=TERM --kill-after=15s 180s "${ISONIM_SCENARIO_NODE:-node}" tests/test_editor_source_scope_gui.mjs

# Captured callback ownership; no provider/worker/filesystem outcomes.
test-editor-chat-lifetime-headless: build-tailwind
    #!/usr/bin/env bash
    set -euo pipefail
    for stem in test_editor_chat_view_lifetime test_editor_shell_chat_lifetime test_editor_chat_tabs_vm test_editor_chat_activity; do
      nim c -r --out:build/$stem tests/$stem.nim
    done
    for stem in test_editor_chat_view_lifetime test_editor_chat_tabs_vm test_editor_chat_activity; do
      nim js -d:nodejs --out:build/$stem.js tests/$stem.nim
      python3 tools/run_nim_js_test.py build/$stem.js
    done

editor-chat-lifetime-build: build-tailwind
    mkdir -p build/editor-chat-lifetime
    nim js --path:src --path:. --path:../nim-everywhere/src --path:../isonim-render-serve/src --path:../nim-acp/src --path:../nim-agent-harbor/src --path:../nim-agents/src -o:build/editor-chat-lifetime/editor.js tests/helpers/editor_chat_lifetime_browser.nim
    "${ISONIM_SCENARIO_NODE:-node}" --check build/editor-chat-lifetime/editor.js

test-editor-chat-lifetime-gui: editor-chat-lifetime-build
    timeout --signal=TERM --kill-after=15s 180s "${ISONIM_SCENARIO_NODE:-node}" tests/test_editor_chat_lifetime_gui.mjs

# Logical renderer mounts execute without browser globals; DOM peers stay real.
test-editor-renderer-boundaries: build-tailwind
    #!/usr/bin/env bash
    set -euo pipefail
    nim c -r --path:src --path:. --path:../nim-everywhere/src --path:../isonim-render-serve/src --path:../nim-acp/src --path:../nim-agent-harbor/src --path:../nim-agents/src tests/test_editor_renderer_boundaries.nim
    nim js -d:nodejs --path:src --path:. --path:../nim-everywhere/src --path:../isonim-render-serve/src --path:../nim-acp/src --path:../nim-agent-harbor/src --path:../nim-agents/src -o:tests/test_editor_renderer_boundaries.js tests/test_editor_renderer_boundaries.nim
    python3 tools/run_nim_js_test.py tests/test_editor_renderer_boundaries.js

editor-renderer-boundaries-build: build-tailwind
    mkdir -p build/editor-renderer-boundaries
    nim js --path:src --path:. --path:../nim-everywhere/src --path:../isonim-render-serve/src --path:../nim-acp/src --path:../nim-agent-harbor/src --path:../nim-agents/src -o:build/editor-renderer-boundaries/editor.js tests/helpers/editor_renderer_boundary_browser.nim
    "${ISONIM_SCENARIO_NODE:-node}" --check build/editor-renderer-boundaries/editor.js

test-editor-renderer-boundaries-gui: editor-renderer-boundaries-build
    timeout --signal=TERM --kill-after=15s 180s "${ISONIM_SCENARIO_NODE:-node}" tests/test_editor_renderer_boundary_gui.mjs

# Current full shell logical controls: native and strict executed Node JS.
test-editor-shell-current: build-tailwind
    #!/usr/bin/env bash
    set -euo pipefail
    nim c -r --out:build/test_editor_shell_views tests/test_editor_shell_views.nim
    nim js -d:nodejs --out:build/test_editor_shell_views.js tests/test_editor_shell_views.nim
    python3 tools/run_nim_js_test.py build/test_editor_shell_views.js

editor-preview-mount-build: build-tailwind
    mkdir -p build/editor-preview-mount
    nim js --path:src --path:. --path:../nim-everywhere/src --path:../isonim-render-serve/src --path:../nim-acp/src --path:../nim-agent-harbor/src --path:../nim-agents/src -o:build/editor-preview-mount/editor.js tests/helpers/editor_preview_mount_browser.nim
    "${ISONIM_SCENARIO_NODE:-node}" --check build/editor-preview-mount/editor.js

test-editor-preview-mount-gui: editor-preview-mount-build
    timeout --signal=TERM --kill-after=15s 180s "${ISONIM_SCENARIO_NODE:-node}" tests/test_editor_preview_mount_gui.mjs

# Requested-document ownership on real reactive roots; strict Node execution.
test-editor-preview-mount: build-tailwind
    #!/usr/bin/env bash
    set -euo pipefail
    nim c -r --path:src --path:. --path:../nim-everywhere/src --path:../isonim-render-serve/src --path:../nim-acp/src --path:../nim-agent-harbor/src --path:../nim-agents/src -o:build/test_editor_preview_mount tests/test_editor_preview_mount.nim
    nim js -d:nodejs --path:src --path:. --path:../nim-everywhere/src --path:../isonim-render-serve/src --path:../nim-acp/src --path:../nim-agent-harbor/src --path:../nim-agents/src -o:build/test_editor_preview_mount.js tests/test_editor_preview_mount.nim
    python3 tools/run_nim_js_test.py build/test_editor_preview_mount.js

# Full committed inspector closure; every prerequisite owning entry remains.
test-editor-inspector: test-editor-shell-current test-editor-inspector-native-source test-editor-c2 test-editor-c3 test-editor-c4a test-editor-flex-metadata test-editor-source-labels test-editor-source-labels-gui test-editor-chat-lifetime-headless test-editor-chat-lifetime-gui test-editor-renderer-boundaries test-editor-renderer-boundaries-gui test-editor-preview-mount test-editor-preview-mount-gui test-editor-source-metadata
    #!/usr/bin/env bash
    set -euo pipefail
    for stem in test_editor_source_markup test_editor_source_style_bindings test_editor_control_routes; do
      nim c -r --out:build/$stem tests/$stem.nim
    done
    nim js -d:nodejs --out:build/test_editor_source_markup.js tests/test_editor_source_markup.nim
    python3 tools/run_nim_js_test.py build/test_editor_source_markup.js

# Real native guarded-source transactions and disposable compiled GRIP provider.
test-editor-inspector-native-source: isonim-review-build
    #!/usr/bin/env bash
    set -euo pipefail
    export PLAYWRIGHT_CHROMIUM_EXECUTABLE="${PLAYWRIGHT_CHROMIUM_EXECUTABLE:-$(command -v chromium)}"
    python3 tests/test_editor_inspector_source.py
    python3 tests/test_editor_source_style_provider.py
    timeout --signal=TERM --kill-after=15s 180s "${ISONIM_SCENARIO_NODE:-node}" tests/test_editor_source_bindings_gui.mjs

# Finite Selection Colors key admission and native bind/unlink/compiler matrix.
# Separate180s entry preserves the original bindings and compounds bounds.
test-editor-selection-keys-headless: build-tailwind
    nim c -r --out:build/test_editor_section_selection_colors tests/test_editor_section_selection_colors.nim
    nim js -d:nodejs --out:build/test_editor_section_selection_colors.js tests/test_editor_section_selection_colors.nim
    python3 tools/run_nim_js_test.py build/test_editor_section_selection_colors.js

test-editor-selection-keys: test-editor-selection-keys-headless isonim-review-build
    timeout --signal=TERM --kill-after=15s 180s "${ISONIM_SCENARIO_NODE:-node}" tests/test_editor_selection_keys_gui.mjs

# Structural IDs and compiler manifest parity, both real backends.
manifest-check: build-tailwind
    bash tools/check_manifest.sh
    bash tools/check_experiments.sh --manifest-only

test-experiments: build-tailwind
    nim c -r --out:build/test_export_permutations tests/test_export_permutations.nim
    nim c -r -d:isServer -d:isNginxTest --out:build/test_experiment_ssr tests/test_experiment_ssr.nim
    bash tools/check_experiments.sh

# Exported HTML JavaScript and canonical links through real HTTP + Chromium.
test-export-permutations-browser:
    nim c -r -d:exportPermutationBrowser --out:build/test_export_permutations_browser tests/test_export_permutations.nim

test-experiment-mutants: build-tailwind
    node tools/test_experiment_mutants.mjs

test-stable-ids: manifest-check
    nim c -r --out:build/test_iid_stability tests/test_iid_stability.nim
    nim c -r --out:build/test_iid_instances tests/test_iid_instances.nim
    nim c -r -d:isonimStableIds --out:build/test_iid_keyed tests/test_iid_keyed.nim
    node tests/test_iid_browser.mjs

test-stable-id-mutants: build-tailwind
    node tools/test_iid_mutants.mjs

# Platform boundaries include real layout and networking under Chromium.
test-nondet:
    nim c -r --out:build/test_nondet_default tests/test_nondet_default.nim
    nim js --out:build/test_nondet_default.js tests/test_nondet_default.nim
    python3 tools/run_nim_js_test.py build/test_nondet_default.js
    python3 tools/test_nondet_mutants.py
    nim c -r tests/test_nondet_seams.nim
    nim js tests/test_nondet_seams.nim
    python3 tools/run_nim_js_test.py tests/test_nondet_seams.js
    nim js --out:build/nondet_partial_window_boot.js tests/fixtures/nondet_partial_window_boot.nim
    "${ISONIM_SCENARIO_NODE:-node}" tests/test_nondet_partial_window.mjs
    PLAYWRIGHT_CHROMIUM_EXECUTABLE="${PLAYWRIGHT_CHROMIUM_EXECUTABLE:-$(command -v chromium)}" node tests/test_nondet_browser.mjs

# Production browser adapter composition, retained chats and control bridge.
test-editor-workspace-adapters-gui: editor-build
    mkdir -p build/editor-workspace-adapters
    nim js --path:src --path:. --path:../nim-everywhere/src --path:../isonim-render-serve/src --path:../nim-acp/src --path:../nim-agent-harbor/src --path:../nim-agents/src -o:build/editor-workspace-adapters/editor.js tests/helpers/editor_workspace_adapters_browser.nim
    cp src/isonim/editor/index.html build/editor-workspace-adapters/index.html
    cp build/editor/fabric.min.js build/editor-workspace-adapters/
    cp build/editor/paper-core.min.js build/editor/svgo.browser.js build/editor-workspace-adapters/
    PLAYWRIGHT_CHROMIUM_EXECUTABLE="${PLAYWRIGHT_CHROMIUM_EXECUTABLE:-$(command -v chromium)}" node tests/test_editor_workspace_adapters_gui.mjs

# Include additional site src/ roots with tools/lint_nondet.py directly.
lint-nondet:
    python3 tools/test_lint_nondet.py
    python3 tools/lint_nondet.py --allowlist tools/nondet_allowlist.json src ../nim-everywhere/src

test-strict-nondet:
    bash tools/check_strict_nondet.sh

# Optional editor preference persistence, including real Chromium denial paths.
test-editor-nondet-storage:
    nim c -r --out:build/test_editor_nondet_storage tests/test_editor_nondet_storage.nim
    nim js -d:nodejs --out:build/test_editor_nondet_storage.js tests/test_editor_nondet_storage.nim
    python3 tools/run_nim_js_test.py build/test_editor_nondet_storage.js
    nim js --out:build/editor_storage_browser_fixture.js tests/editor_storage_browser_fixture.nim
    PLAYWRIGHT_CHROMIUM_EXECUTABLE="${PLAYWRIGHT_CHROMIUM_EXECUTABLE:-$(command -v chromium)}" node tools/check_editor_storage_browser.cjs
# Shared SSR/client event registration and privacy against actual Chromium.
test-listen: build-tailwind
    bash tools/check_listen.sh

# Parent lifecycle owns both SSR adoption and fallback-render roots.
test-hydration-owner: build-tailwind
    bash tools/check_hydration_owner.sh

# Optional signal checkpoints: real native/JS graph, actual Chromium, mutations.
test-signal-checkpoints:
    nim c -r -d:isonimRecordable tests/test_signal_checkpoints.nim
    nim c -r --mm:arc -d:isonimRecordable --out:build/checkpoints_arc tests/test_signal_checkpoints.nim
    nim js -d:isonimRecordable -d:isonimStrictNondet --out:build/test_signal_checkpoints.js tests/test_signal_checkpoints.nim
    python3 tools/run_nim_js_test.py build/test_signal_checkpoints.js
    nim js -d:isonimRecordable -d:isonimStrictNondet --out:build/checkpoints_browser.js tests/fixtures/checkpoints_browser.nim
    PLAYWRIGHT_CHROMIUM_EXECUTABLE="${PLAYWRIGHT_CHROMIUM_EXECUTABLE:-$(command -v chromium)}" node tests/test_signal_checkpoints_browser.mjs
    python3 tools/test_signal_checkpoint_mutants.py

# Exact ordinary-bundle comparison against the checkpoint foundation's parent.
verify_xr_m5_zero_cost_default parent="d2193dc4935039f5faa0836e0a26eed9e15f1a72":
    bash tools/verify_signal_checkpoints_zero_cost.sh {{parent}}
