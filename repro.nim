## Reprobuild project file for isonim.
##
## **Typed-Cross-Project-Deps rollout — the keystone Nim CONSUMER of the
## isonim ecosystem (SC-11 develop-mode from-source sibling consumption).**
## ``isonim`` is the isomorphic reactive UI framework: its ``src/`` reactive
## core / DSL / SSR / routing tree is a Linux leaf, but the *editor* subtree
## (``src/isonim/editor/*``) imports FOUR landed workspace Nim libraries
## directly at build time (plus a fifth, ``nim_agent_harbor``, pulled in
## transitively — see the fifth bullet):
##
##   * ``isonim_render_serve`` — ``src/isonim/editor/preview_canvas.nim``,
##     ``streaming_preview.nim``, ``design_review/bridge_client.nim``
##     (``import isonim_render_serve`` + ``/ws_frame`` + ``/packet``).
##     Producer: ``isonim-render-serve/repro.nim`` → ``library
##     isonim_render_serve``.
##   * ``nim_acp`` — ``src/isonim/editor/agent_context.nim`` +
##     ``design_review/agent_routes.nim`` (``import nim_acp``). Producer:
##     ``nim-acp/repro.nim`` → ``library nim_acp``.
##   * ``nim_agents`` — ``src/isonim/editor/agent_harbor.nim`` +
##     ``design_review/agent_routes.nim`` (``import nim_agents``). Producer:
##     ``nim-agents/repro.nim`` → ``library nim_agents``.
##   * ``nim_everywhere`` — the cross-target platform seams consumed
##     pervasively (``src/isonim/editor/agent_context.nim`` and the async /
##     time / http facade the reactive core + SSR pull in). Producer:
##     ``nim-everywhere/repro.nim`` → ``library nim_everywhere``.
##   * ``nim_agent_harbor`` — NOT imported by isonim directly, but required
##     TRANSITIVELY: ``nim_agents`` ``import``s + re-``export``s it
##     (``nim-agents/src/nim_agents.nim`` + ``.../client.nim`` reference
##     ``nim_agent_harbor.HarborContentBlock``), so every edge that imports
##     ``nim_agents`` needs ``nim_agent_harbor`` on ``--path:`` too — dropping
##     the ``uses:`` edge makes ``nim_agents`` fail to compile with ``cannot
##     open file: nim_agent_harbor``. Producer:
##     ``nim-agent-harbor/repro.nim`` → ``library nim_agent_harbor``.
##
## The repo's own ``tests/config.nims`` resolves these with hand-maintained
## ``--path:../../nim-*/src`` / ``--path:../../isonim-render-serve/src``
## flags (and the ``Justfile`` recipes repeat them inline). This recipe
## expresses those five sibling dependencies the reprobuild-native way
## instead: ``uses: "<sibling>"`` names each PRODUCER project by its
## workspace directory name; reprobuild builds each from source (its
## ``library`` edge) and threads its ``src/`` root onto THIS repo's
## ``nim c --path:`` via the SC-11 ``nimPathDirs`` aux channel
## (Cross-Repo-Source-Consumption.md §4.2a) — replacing the hardcoded
## ``../../nim-*/src`` literals. Editing a sibling's ``src/`` invalidates +
## rebuilds this repo's affected test compiles (the reused SC-4 fold).
##
## All five siblings are in the rollout's AVAILABLE set (each ships a landed
## ``repro.nim`` with a ``library`` export), so this is proper SC-11
## develop-mode consumption — NOT a SKIP and NOT a hardcoded path.
##
## A Mode 1 / Mode 3 hybrid (per
## ``reprobuild-specs/Three-Mode-Convention-System.md``) modelled on the
## canonical Nim-consumer recipes ``nim-agents/repro.nim`` (four-sibling
## consumer) and ``nim-agent-harbor/repro.nim`` (single-sibling consumer):
##
## * Declares the toolchain floor via ``uses:`` (``nim`` + ``gcc``) plus the
##   five sibling ``uses:`` edges. Mirrors the nimble file's
##   ``requires "nim >= 2.0.0"``.
## * Declares ``library isonim`` — the importable umbrella
##   (``src/isonim.nim``) so the downstream isonim renderer repos
##   (isonim-tui / isonim-freya / isonim-gpui / isonim-android /
##   isonim-cocoa / ngx-isonim / isonim-examples) can consume it with
##   ``uses: "isonim"``. The exported path is ``src`` (convention default).
## * Emits, per HEADLESS-runnable test file under ``tests/``, a BUILD edge
##   (``buildNimUnittest.build``) that compiles ``build/test-bin/<stem>`` and
##   an EXECUTE edge (``edge.testBinary.run``) that runs it — the two-edge
##   test template from ``reprobuild-specs/Package-Model.md`` §"The test
##   template". BUILD halves collect into ``test-builds``; EXECUTE halves
##   into ``test`` so ``repro build test`` / ``repro test`` materialise the
##   runnable closure (each execute edge transitively depends on its build
##   edge).
##
## **Third-party / vendored deps (NOT ``uses:``).** The repo's non-SC-11
## dependencies are threaded via the edge ``paths:`` slot, mirroring exactly
## how ``tests/config.nims`` + the ``Justfile`` recipes resolve them — they
## are ordinary Nim source trees, not workspace ``library`` producers, so
## they are NOT ``uses:`` edges:
##
##   * Vendored under ``isonim/vendor/`` (on ``--path`` per ``config.nims``):
##     ``vendor/chronicles`` (the house logger; ``requires`` in the nimble
##     file), ``vendor/serialization``, ``vendor/json_serialization``,
##     ``vendor/db_connector/src`` (the moved-out-of-std ``db_postgres``).
##   * Workspace sibling source trees that are NOT SC-11 library producers
##     (no ``repro.nim``): ``../nim-faststreams`` (the nimble ``requires
##     "faststreams"`` dep) and ``../nim-stew``. Resolved by ``--path`` just
##     like ``config.nims`` does (its ``../../nim-faststreams`` becomes
##     ``../nim-faststreams`` from this repo root). If/when those land a
##     ``repro.nim`` with a ``library`` export they can be promoted to
##     ``uses:`` edges.
##
## **Chronicles defines.** ``config.nims`` sets ``-d:nimOldCaseObjects``
## and the three ``chronicles_*`` knobs
## (``chronicles_sinks=textlines[stderr]``, ``chronicles_runtime_filtering=on``,
## ``chronicles_log_level=TRACE``) on every compile. The engine build is
## hermetic (it does NOT read the repo's ``config.nims`` — the compile is
## driven by the explicit ``nim c`` argv the wrapper records), so every BUILD
## edge below passes those defines explicitly via the ``defines:`` slot to
## reproduce the repo's own compile.
##
## **C + JS back-end corpus.** The engine's ``nim.c`` typed-tool models the
## ``nim c`` (native / C back-end) compile; the ``nim.js`` typed-tool models
## the ``nim js`` (JavaScript back-end) compile, run under ``node`` (set (A),
## FUP-E2, below). The repo's Playwright browser (``.mjs`` / real-DOM) suites
## remain a separate surface neither edge can model. Every native edge
## compiles + runs to exit 0 under ``nim c``; every JS edge compiles under
## ``nim js`` + runs to exit 0 under ``node`` — both verified headless.
##
## ==========================================================================
## Test sets: JS-backend PROVISIONED (A); others documented-deferred (B/C)
## ==========================================================================
##
## (A) **JS-backend tests — PROVISIONED HEADLESS (FUP-E2) and RE-INCLUDED.**
##     Previously deferred wholesale ("the ``nim.c`` edge cannot model the JS
##     back-end"). Now modelled the reprobuild-native way: a ``nim.js`` BUILD
##     edge compiles each to ``build/js-test/<stem>.js`` and a ``node``
##     EXECUTE edge runs the emitted JS under node (keyed on exit status — Nim
##     ``unittest`` exits non-zero on failure). The runner is provisioned from
##     the flake dev shell: ``node`` (declared in ``uses:``) + ``nim js``
##     (the already-declared ``nim``). The re-included set is the repo's own
##     ``Justfile`` ``test-js`` list + the ``{.error.}``-headed
##     ``test_custom_elements`` (see ``isonimJsTestSpecs``); each is folded
##     into the ``test`` target AND a dedicated ``js-test`` target, verified
##     GREEN headless via ``repro build js-test`` under the automatic monitor
##     (43 actions asSucceeded, exit=0 — 1 tailwind extract + 21 ``nim js``
##     compiles + 21 node runs).
##
##     **Compile-time prerequisite (provisioned):** ``src/isonim/dsl/
##     tailwind.nim`` ``staticRead``s ``build/tailwind-styles.json`` on the JS
##     back-end (the native path guards it behind ``when fileExists`` and
##     tolerates absence; the JS ``staticRead``'s missing-file failure is an
##     UNCATCHABLE compile error). Modelled as an ``isonim.tailwind_extract``
##     ``node`` BUILD edge (``node tools/tailwind-extract.mjs`` → the real
##     Tailwind v4 CLI) that every JS compile depends on; node_modules
##     (``@tailwindcss/cli``) is a bootstrap prerequisite the same way the
##     flake toolchain is (``just build-tailwind`` runs ``[ -d node_modules ]
##     || yarn install`` first; the extract itself is then offline).
##
##     STILL DEFERRED (documented, reproduced — NOT weakened, NOT re-included):
##       - ``tests/test_app_e2e.nim`` — pre-existing product bug: a non-void
##         trailing expression (``appendChild(section, ul): Node``) inside a
##         ``createRenderEffect do:`` block → compile-time ``type mismatch``
##         under the repo's OWN ``nim js`` (``:522``); provisioning-independent.
##       (FUP-J RE-INCLUDED: ``tests/test_editor_public_browser_imports.nim``
##       is no longer deferred. It was blocked by the same set-(C)
##       ``agent_harbor.nim(109)`` enum-skew product bug; the FUP-J fix to
##       ``agent_harbor.nim`` makes it compile clean on the JS back-end. As a
##       ``nim js`` COMPILE-ONLY recipe entry (``-o:`` without ``-r``) it is
##       modelled as a BUILD-only edge — see ``isonimJsCompileOnlySpecs``.)
##       - **Real browser / DOM** (un-runnable under headless node): the HMR
##         fixtures (``test_hmr*.nim`` build to JS bundles for Playwright), the
##         ``poc_datatable_host`` / ``poc_terminal_host`` browser hosts, and
##         the ``tests/*.mjs`` Playwright gallery/editor-chat suites — these
##         need a real browser/DOM, not a node runtime.
##
## (B) **Design-review external-service suite — PROVISIONED HEADLESS
##     (FUP-E1) and RE-INCLUDED.** Previously deferred wholesale as
##     "genuinely un-provisionable headless"; that claim is now falsified.
##     All three services come up headless with no display and no external
##     network, so the corpus is re-included as ``isonimDesignReviewSpecs``:
##       - **PostgreSQL** via the REV-M3 ``PgFixture``
##         (``tests/helpers/design_review_pg_fixture.nim``): an ephemeral
##         ``initdb`` cluster on a loopback port, migrations applied, torn
##         down per test. ``initdb``/``postgres``/``psql``/``pg_isready``/
##         ``createdb``/``pg_dump`` are on ``PATH`` from the flake dev shell
##         (``flake.nix`` ``postgresql_16``); ``process-compose`` boots the
##         same cluster for ``e2e_design_review_pg_process_compose``.
##       - the **render-serve bridge** via the in-process ``FakeBridge`` —
##         a real RFC-6455 ``Sec-WebSocket-Accept`` handshake +
##         ``isonim_render_serve/{packet,ws_frame,bridge}`` framing — so the
##         capture pipeline runs against a real ``ws://127.0.0.1:<port>``
##         endpoint with no external server.
##       - the **ACP agent** via ``tests/helpers/fake_acp_agent.nim`` — a
##         deterministic stdio JSON-RPC ACP server the daemon spawns through
##         ``ISONIM_ACP_AGENT_CMD`` (``NativeStdioAcpTransport``); no network,
##         no credentials.
##     The daemon/CLI/bench tests spawn three prerequisite tool binaries
##     (``build/bin/isonim-review``, ``build/bin/fake-acp-agent``,
##     ``build/bin/design_review_bench``); each is modelled as a BUILD edge
##     and wired to the execute edges via ``requiredBinaries`` (the
##     Bootstrap-And-Self-Build B3 channel), so the engine builds them first.
##     Every re-included design-review execute edge is routed through the
##     capacity-1 serial pool ``isonim.design-review-serial`` because each
##     spawns an ephemeral cluster + binds loopback ports (the fixture itself
##     warns that parallel files race on ports/PGDATA). The re-included set
##     was verified GREEN headless via the repo's own ``just
##     test-design-review-*`` recipes with the real services; ``repro build
##     test`` itself is not executed here because the ``repro`` binary is not
##     provisioned in this workspace (the same limitation recorded for
##     FUP-D), so these edges are modelled + recipe-verified, not
##     repro-executed.
##
##     STILL DEFERRED (documented, reproduced — NOT weakened):
##       - **Real remote ACP** (network + credentials):
##         ``e2e_design_review_chat_real_acp`` /
##         ``e2e_design_review_chat_real_codex_acp`` — ``skip()`` at runtime
##         unless ``claude-agent-acp``/``codex-acp`` + Anthropic/OpenAI creds
##         are present; un-exercisable on a headless, network-isolated host
##         (``codex-acp`` is on ``PATH`` from the flake, but no creds exist).
##       - **Real cross-repo backend binary**:
##         ``test_design_review_backend_launcher`` /
##         ``e2e_design_review_capture_web_real_bridge`` — each
##         ``require``s ``../isonim-examples/build/backends/
##         isonim-examples-web`` (hard-fails when absent); needs the sibling
##         isonim-examples web backend built, which is not staged here.
##       - **Browser / JS backend** (set A scope):
##         ``test_design_review_browser_agent_client_compiles`` (``nim js``)
##         + the ``tests/*.mjs`` Playwright gallery/editor-chat suites — a
##         separate backend the ``nim.c`` edge cannot model.
##       - the four **pre-existing broken files** listed in set (C), which
##         fail under the repo's own ``nim c -r`` on a clean tree — NOT a
##         provisioning gap.
##
## (B2) **Live-service editor tests — COMPILE-ONLY (BUILD edge kept, EXECUTE
##      edge deferred).** Three ``test-editor`` files COMPILE cleanly against
##      the SC-11 sibling library edges (so their BUILD edge is a genuine
##      compile-verification of the ``uses:`` edge) but cannot RUN headless in
##      the sandbox — they need a live service / sibling checkout the work-root
##      does not carry. They are emitted with their BUILD half ONLY (folded
##      into ``test-builds``); the EXECUTE half is deferred (documented), NOT
##      weakened:
##        - ``tests/test_editor_real_preview.nim`` — spawns the REAL
##          ``isonim-render-serve`` binary via ``startProcess`` and opens a
##          real WebSocket (``connect("127.0.0.1", Port(...))``) against its
##          bridge. Needs the bridge binary on PATH + live sockets — the same
##          live-bridge class as (B). Compile PROVES the
##          ``import isonim_render_serve`` SC-11 edge.
##        - ``tests/test_editor_streaming_preview.nim`` — likewise spawns the
##          real ``isonim-render-serve`` child + a real WebSocket handshake.
##          Compile PROVES the ``import isonim_render_serve/ws_frame`` SC-11
##          edge. (The pure-delta ``test_streaming_preview_element_tree_delta``
##          — no spawn — stays a FULL build+execute edge and passes.)
##        - ``tests/test_editor_release_gate.nim`` — a cross-repo RELEASE-GATE
##          meta-test: ``dirExists("../metacraft-web")`` hard-fails (by its own
##          design) when the sibling ``metacraft-web`` repo is not checked out
##          in the workspace (it is not here), and it ``readFile``s /
##          ``walkDirRec``s repo-relative paths (``docs/``, ``tests/``) that the
##          sandbox work-root does not stage. Compile-only.
##
## (C) **Pre-existing broken tests at HEAD — the FUP-J four are now FIXED +
##     RE-INCLUDED; the remainder stay deferred for OTHER reasons** (each
##     fails under the repo's OWN ``nim c -r`` on a clean tree — NOT
##     provisioning-blocked, NOT reprobuild-specific; NOT weakened here):
##       - **FUP-J product fix (RE-INCLUDED):**
##         ``tests/test_design_review_editor_agent_adapter_vm.nim`` reaches
##         ``src/isonim/editor/agent_harbor.nim``, whose ``applyAgentEvent``
##         ``case event.kind`` did NOT cover the ``aekMilestoneProgress`` /
##         ``aekWorkspaceReady`` variants that the LANDED ``nim_agents`` sibling
##         defines (``nim-agents/src/nim_agents/client.nim:52-53``) → compile
##         error ``agent_harbor.nim(109,3)`` "not all cases are covered". FIXED
##         by adding both case branches (progress → context note + loading;
##         workspace-ready → connected state + note) and qualifying the
##         now-ambiguous ``types.AgentFileDiff`` (the sibling grew a colliding
##         ``AgentFileDiff``). Re-included in ``isonimDesignReviewSpecs``.
##         (``tests/test_editor_agent_harbor.nim`` +
##         ``tests/test_editor_viewmodels.nim`` reach the same enum fix and now
##         COMPILE, but each has a SEPARATE unrelated failure — a runtime
##         ``KeyError: workingCopyMode`` and a test-file-level ``AgentFileDiff``
##         ambiguity at ``:4725`` respectively — so they stay deferred, out of
##         FUP-J scope.)
##       - **FUP-J stale-assertion fix (RE-INCLUDED):**
##         ``tests/test_design_review_cli_init.nim`` hardcoded
##         ``countMigrations(f) == 8`` / "applied 8 migration(s)" /
##         ``after == 7|8`` but the repo ships NINE migrations
##         (``db/migrations/009_design_review_campaign_restart.sql``, CMP-M7).
##         Provisioning SUCCEEDS (postgres applies all 9); the product is
##         correct — the TEST expectations were bumped to 9. Re-included.
##       - **FUP-J stale-assertion fix (RE-INCLUDED):**
##         ``tests/test_migrated_chrome_briefs_parse.nim`` —
##         ``parsedBriefs.len == ExpectedSlugs.len`` failed: the migrated
##         chrome-brief corpus grew from 12 to 18 (``gallery-*`` + ``spec-pane-*``
##         added). The parser works; ``ExpectedSlugs`` was updated to the
##         current 18. Re-included.
##       - **FUP-J stale-assertion fix (RE-INCLUDED):**
##         ``tests/test_design_review_cli_campaign.nim`` — its three
##         ``inject_*`` subtests were CMP-M4-era and expected
##         inject-after-``start`` to SUCCEED (202 + an ``operator_injection``
##         note). CMP-M6/CMP-M7 made the campaign a single ACP turn whose
##         session is torn down (``dropSession`` + ``shutdownAndRelease``)
##         when the turn ends, and ``start --no-tail`` drains the SSE to that
##         ``end`` event before returning — so inject deterministically hits a
##         session-less campaign. The AUTHORITATIVE, documented CMP-M7 route
##         contract (``tests/test_design_review_campaign_routes.nim`` ::
##         ``test_inject_after_turn_end_returns_404`` /
##         ``test_inject_after_turn_end_does_not_record_event``) is: inject
##         after the single-turn teardown returns 404 ``no_active_session``
##         and records NO note ("be honest about session lifetime rather than
##         pretend at queueing"). The CMP-M4-era ``cli_campaign`` inject_*
##         assertions (expect success) are therefore STALE. Resolution: the
##         three subtests were updated to assert that same CMP-M7 outcome
##         end-to-end through the CLI (exit 5 / ``no_active_session`` in
##         stderr / no ``operator_injection`` note recorded), and renamed to
##         ``inject_after_turn_end_*_returns_404``. The product is UNCHANGED —
##         both the 202 (session live) and 404 (session gone) paths already
##         exist in ``campaign_routes.nim``; only the stale test expectations
##         moved to the current CMP-M7 contract. Re-included. (Exercising the
##         in-flight-inject success path is left to a future milestone: the
##         fake-ACP fixture exits too fast to hold a session open reliably.)
##       - **Same-root-cause (9-migration) stale assertions, FIXED alongside
##         cli_init (already in the DR set, RE-INCLUDED):**
##         ``tests/e2e_design_review_cli_init.nim`` (``count == 8`` → 9) and
##         ``tests/test_design_review_cli_db_health.nim`` (``schemaVersion == 8``
##         → 9, plus the "detects stale schema" case now injects a fake v10
##         beyond the shipped v9). FUP-E1 re-included both but only executed a
##         subset under repro, so their 9-migration staleness surfaced only under
##         this milestone's full cold ``repro build test``. Product correct; tests
##         bumped to the current state.
##       - **Concurrency race in multi-agent review — RESOLVED (FUP-N).**
##         ``tests/e2e_design_review_run_review.nim`` ::
##         ``e2e_concurrent_two_agent_reports_one_run`` spawns two ``run-review``
##         processes against one run and asserts BOTH record (2 reports). The
##         earlier flake was a genuine PRODUCT gap, not a test defect: whichever
##         agent finishes first transitions the run to ``complete``, after which
##         ``record_agent_report``'s guard rejected the second reviewer
##         (``run … in status complete not in allowed set``), so only one report
##         persisted. Fixed in migration 010
##         (``010_design_review_multi_agent_report.sql``) by adding the terminal
##         ``complete`` to ``record_agent_report``'s allowed-status set (and the
##         matching ``dispatchReview`` gate); ``complete`` stays terminal, no new
##         transition, the second report simply lands with its own audit event.
##         The test was already correct and is byte-identical to HEAD. Now 100%
##         over the review determinism loops; no longer a flake.
##       - ``tests/test_corner_cases.nim`` — a duplicate ``var sum`` in one
##         ``test`` block (lines 237 + 254) → "redefinition of 'sum'". Fails
##         under plain ``nim c`` too (it is in the ``Justfile`` ``test-c``
##         list, so ``just test-c`` is itself red at HEAD).
##     NOTE: ``test_flexbox`` was previously excluded here as "needs the
##     uninitialised ``src/isonim/layout/yoga`` C++ submodule". The submodule
##     being uninitialised was the defect, not a property of the test: nothing
##     in the repo ever provisioned it (no ``submodules:`` on
##     ``actions/checkout``, no setup recipe, README said only ``nimble
##     install``), and excluding its only consumer from every recipe is what
##     kept CI green over it. Provisioning now exists (``just setup``,
##     ``just check-submodules``, ``submodules: recursive`` in the workflows)
##     and ``test_flexbox`` compiles and passes, so it IS in ``test-c`` and
##     gets a normal edge pair.
##     Still out of the sanctioned scope: ``test_branded_ui`` (real API drift —
##     ``branded_ui.nim:212`` calls a two-arg ``textContent`` that no longer
##     exists) and ``test_faststreams_ssr`` (references the removed
##     ``renderToOutputStream``) — genuinely stale, so they get no edge.
##
## **Tool provisioning.** ``defaultToolProvisioning "path"`` matches the
## canonical recipes: the nix dev shell puts ``nim`` + ``gcc`` on ``PATH``,
## so the weak-local PATH resolver is the right default. It is also required
## for the ``uses:`` declarations to resolve at all ("typed tool provisioning
## is required for uses declarations").

import repro_project_dsl

# ``ct_test_nim_unittest`` supplies the ``buildNimUnittest.build(...)``
# typed-tool used by every test BUILD edge and the ``edge.testBinary.run(...)``
# UFCS dispatch for the EXECUTE edges. It re-exports ``repro_project_dsl`` so
# the import order is unimportant. Like the other consumer sibling recipes
# this file does NOT import ``ct_test_runner_install`` (engine-coupled,
# reprobuild-internal): the execute edges route through the engine's default
# direct-binary runner (run the binary, key on exit status), which is exactly
# the exit-0 verification this corpus needs — Nim ``unittest`` prints
# per-suite results and exits non-zero on failure.
import ct_test_nim_unittest

type
  IsonimTestSpec = object
    ## One entry per HEADLESS-runnable native test file. ``source`` is the
    ## repo-relative ``.nim`` path; ``binary`` is the
    ## ``build/test-bin/<stem>`` output.
    source: string
    binary: string

proc spec(stem: string): IsonimTestSpec =
  IsonimTestSpec(source: "tests/" & stem & ".nim",
    binary: "build/test-bin/" & stem)

# The HEADLESS native corpus — every entry compiles + runs to exit 0 under
# ``nim c`` on this Linux host (verified by a direct ``nim c -c`` sweep with
# the same paths + defines the edges below use). The JS-backend-only tests,
# the external-service design-review suites, and the two pre-existing broken
# files are DEFERRED per the module docstring (sets A / B / C); none is run
# off its backend and none is weakened.
const isonimTestSpecs: seq[IsonimTestSpec] = @[
  # --- Reactive core: signals / effects / clock / context / rxcore ---
  spec("test_signals"),
  spec("test_effects"),
  spec("test_clock"),
  spec("test_context"),
  spec("test_rxcore"),
  spec("test_resource_async"),      # imports nim_everywhere + /async_compat
  # --- DSL / SSR / streaming / round-trip ---
  spec("test_dsl"),
  spec("test_dsl_ssr"),
  spec("test_ssr"),
  spec("test_ssr_routing"),
  spec("test_streaming"),
  spec("test_streaming_stress"),
  spec("test_round_trip"),
  spec("test_benchmark"),
  # --- Renderers / native / DOM-model / accessibility / theming ---
  spec("test_native_renderer"),
  spec("test_nginx_module"),
  spec("test_terminal"),
  spec("test_accessibility"),
  spec("test_theme"),
  # --- Routing / server functions / data-loading / HTTP ---
  spec("test_router"),
  spec("test_server_functions"),
  spec("test_data_loading"),
  spec("test_file_routes"),
  spec("test_http_types"),
  spec("test_form_actions"),
  spec("test_third_party"),
  spec("test_viewmodel"),
  spec("test_demo_vm"),
  # --- Editor / ViewModel (headless) — no PG / bridge / agent ---
  spec("test_editor_workspace"),
  spec("test_editor_public_api"),
  spec("test_editor_shell_views"),
  spec("test_editor_task_views"),
  spec("test_editor_interactivity"),
  spec("test_editor_responsive"),
  spec("test_editor_chrome_layout"),
  spec("test_editor_in_pane_mode_row_removed"),
  spec("test_editor_no_document_html_for_non_web"),
  spec("test_editor_user_project"),
  spec("test_editor_vendor_dist_check"),
  spec("test_editor_viewport_resize_publisher"),
  spec("test_editor_widget_property_row"),
  spec("test_editor_surface_toggle_vm"),
  spec("test_editor_chat_tabs_vm"),
  spec("test_editor_choice_group_vm"),
  spec("test_editor_choice_group_no_setstyle"),
  spec("test_editor_variable_binding_vm"),
  spec("test_editor_variable_chip"),
  spec("test_editor_variable_picker_vm"),
  spec("test_editor_spec_comment_vm"),
  spec("test_editor_spec_pane_vm"),
  spec("test_editor_spec_pane_edit_vm"),
  spec("test_editor_spec_toolbar_vm"),
  spec("test_editor_section_appearance"),
  spec("test_editor_section_collapse_vm"),
  spec("test_editor_section_component_props"),
  spec("test_editor_section_effects"),
  spec("test_editor_section_export"),
  spec("test_editor_section_fill"),
  spec("test_editor_section_layout"),
  spec("test_editor_section_position"),
  spec("test_editor_section_selection_colors"),
  spec("test_editor_section_source"),
  spec("test_editor_section_state"),
  spec("test_editor_section_stroke"),
  spec("test_editor_section_typography"),
  # --- SC-11 sibling-exercising editor tests (the reason for the five
  #     ``uses:`` edges — each compiles a sibling ``src/`` root threaded via
  #     the ``nimPathDirs`` channel), FULL build+execute (headless-runnable):
  spec("test_editor_agent_context"),          # import nim_acp
  spec("test_streaming_preview_element_tree_delta"),  # import isonim_render_serve
]

# Compile-only edges (set B2 in the docstring): these COMPILE against the
# SC-11 sibling library edges — so their BUILD half is a real compile-
# verification of the ``uses:`` edge — but cannot RUN headless (live
# ``isonim-render-serve`` bridge / sibling ``metacraft-web`` checkout). Only
# the BUILD half is emitted (into ``test-builds``); the EXECUTE half is
# DEFERRED per the docstring, not weakened.
const isonimCompileOnlySpecs: seq[IsonimTestSpec] = @[
  spec("test_editor_real_preview"),           # import isonim_render_serve — spawns bridge
  spec("test_editor_streaming_preview"),      # import isonim_render_serve/ws_frame — spawns bridge
  spec("test_editor_release_gate"),           # dirExists("../metacraft-web") hard-fail
]

# --- JS-backend suite (set (A), FUP-E2) ------------------------------------
# The repo's ``nim js`` matrix (``Justfile`` ``test-js``) runs each of these
# on the JavaScript back-end under node (``nim js -r`` shells out to ``node``).
# Provisioned + re-included headless here: a ``nim.js`` BUILD edge compiles
# each to ``build/js-test/<stem>.js`` and a ``node`` EXECUTE edge runs it
# under node, keyed on exit status (Nim ``unittest`` exits non-zero on
# failure). Every stem below compiles + runs to exit 0 under ``nim js -r`` on
# this Linux host with ``node`` from the flake dev shell — verified by a
# direct ``nim js -r`` sweep of the whole ``test-js`` list + ``test-js``-only
# ``test_custom_elements`` (its ``{.error.}`` head requires the JS back-end).
#
# ``test_app_e2e`` stays DEFERRED (documented, reproduced, NOT weakened —
# set (A) tail in the docstring): a pre-existing non-void
# ``createRenderEffect do:`` block → compile-time ``type mismatch`` under the
# repo's own ``nim js``.
#
# FUP-J — ``test_editor_public_browser_imports`` is now RE-INCLUDED (see
# ``isonimJsCompileOnlySpecs`` below). It was previously blocked by the same
# set-(C) ``agent_harbor.nim`` ``aekMilestoneProgress``/``aekWorkspaceReady``
# enum-skew product bug; the FUP-J fix to ``agent_harbor.nim`` (plus the
# ``types.AgentFileDiff`` qualification) makes it compile clean on the JS
# back-end. It is a ``nim js`` COMPILE-ONLY recipe entry (``-o:`` without
# ``-r``), so it is modelled as a BUILD-only edge (no node run).
const isonimJsTestSpecs: seq[string] = @[
  # Reactive core (dual-backend; also in the native corpus above).
  "test_signals", "test_effects", "test_clock", "test_context", "test_rxcore",
  # DSL / SSR-hydration / web-component / router / server-fn / data-loading.
  "test_dsl", "test_web", "test_demo_vm", "test_benchmark", "test_viewmodel",
  "test_terminal", "test_hydration", "test_ssr_hydration_e2e",
  "test_web_components_advanced", "test_third_party", "poc_monaco_host",
  "test_accessibility", "test_router", "test_server_functions",
  "test_data_loading",
  # JS-back-end-only (``{.error.}`` head unless ``defined(js)``).
  "test_custom_elements",
]

# FUP-J — JS COMPILE-ONLY stems: the ``Justfile`` ``test-editor`` recipe
# checks these compile on the JS back-end (``nim js ... -o:<out>`` with no
# ``-r``) rather than running them under node. Modelled as a ``nim.js``
# BUILD-only edge (folded into ``test-builds`` / ``js-test-builds``); there is
# no ``node`` EXECUTE edge because the recipe never runs the emitted JS.
const isonimJsCompileOnlySpecs: seq[string] = @[
  "test_editor_public_browser_imports",
]

# --- Design-review external-service suite (set (B), FUP-E1) -----------------
# Re-included: provisioned headless (PgFixture ephemeral cluster + in-process
# FakeBridge + fake-acp-agent stdio). Each execute edge runs in the capacity-1
# serial pool ``isonim.design-review-serial`` (per-test ephemeral clusters +
# loopback ports must not race). ``needs`` names the prerequisite tool
# binaries the test subprocess spawns at runtime — threaded to the execute
# edge via ``requiredBinaries`` (Bootstrap-And-Self-Build B3) so the engine
# builds them first. Verified green headless via ``just test-design-review-*``.
type
  DrNeed = enum
    drNeedsReview   ## spawns ``build/bin/isonim-review`` (CLI / serve daemon)
    drNeedsFakeAcp  ## spawns ``build/bin/fake-acp-agent`` (stdio ACP agent)
    drNeedsBench    ## spawns ``build/bin/design_review_bench``
  DrSpec = object
    stem:  string
    needs: set[DrNeed]

proc dr(stem: string; needs: set[DrNeed] = {}): DrSpec =
  DrSpec(stem: stem, needs: needs)

const isonimDesignReviewSpecs: seq[DrSpec] = @[
  # PostgreSQL fixture (initdb ephemeral cluster) — self-provisioning, no bin.
  dr("test_design_review_pg_schema"),
  dr("test_design_review_pg_routines"),
  dr("test_design_review_pg_roles"),
  dr("smoke_design_review_pg_dump_restore"),
  dr("e2e_design_review_pg_process_compose"),  # via process-compose on PATH
  # Pure parse / ViewModel (MockRenderer / git / fs) — no service, no bin.
  dr("test_design_review_brief_format"),
  dr("test_design_review_brief_index"),
  dr("test_design_review_reviewer_output"),
  dr("test_design_review_brief_at_revision"),
  dr("test_design_review_gallery_vm"),
  dr("test_design_review_gallery_no_setstyle"),
  dr("test_design_review_gallery_drag_rearrange_vm"),
  dr("test_design_review_gallery_side_by_side_vm"),
  # FUP-J — product fix: ``src/isonim/editor/agent_harbor.nim`` now covers
  # the ``aekMilestoneProgress`` / ``aekWorkspaceReady`` variants the landed
  # ``nim_agents`` sibling defines (and qualifies the newly-ambiguous
  # ``types.AgentFileDiff``). Pure VM test, no service.
  dr("test_design_review_editor_agent_adapter_vm"),
  dr("test_migrated_task_app_brief_parses"),
  dr("test_migrated_settings_app_brief_parses"),
  # FUP-J — stale-assertion fix: the migrated chrome-brief corpus grew to
  # 18 (``gallery-*`` + ``spec-pane-*`` added); ``ExpectedSlugs`` updated
  # to match. Pure parse test, no service.
  dr("test_migrated_chrome_briefs_parse"),
  dr("test_no_dangling_references_to_old_brief_path"),
  dr("test_design_review_cli_config"),
  # Capture pipeline — in-process FakeBridge + PgFixture, no CLI subprocess.
  dr("test_design_review_clean_tree"),
  dr("test_design_review_manifest_hash"),
  dr("test_design_review_capture_store"),
  dr("test_design_review_bridge_client"),
  dr("test_design_review_capture_native_dimensions"),
  dr("test_design_review_record_capture_idempotent"),
  # CLI + serve-daemon over PgFixture — spawn the isonim-review binary.
  dr("test_design_review_isonim_review_cli",      {drNeedsReview}),
  dr("test_design_review_cli_db_health",          {drNeedsReview}),
  dr("test_design_review_cli_serve_smoke",        {drNeedsReview}),
  dr("test_design_review_cli_seed_run",           {drNeedsReview}),
  dr("test_design_review_config_agent_backend",   {drNeedsReview}),
  # FUP-J — stale-assertion fix: the repo ships NINE migrations
  # (``009_design_review_campaign_restart.sql``, CMP-M7); the test's
  # hardcoded ``== 8`` counts were updated to ``9``.
  dr("test_design_review_cli_init",               {drNeedsReview}),
  dr("e2e_design_review_cli_init",                {drNeedsReview}),
  dr("e2e_design_review_cli_serve_lifecycle",     {drNeedsReview}),
  # HTTP API routes over the serve daemon + PgFixture.
  dr("test_design_review_api_list_history",       {drNeedsReview}),
  dr("test_design_review_api_fetch_run",          {drNeedsReview}),
  dr("test_design_review_api_get_capture_png",    {drNeedsReview}),
  dr("test_design_review_api_brief_has_history",  {drNeedsReview}),
  dr("test_design_review_api_save_layout",        {drNeedsReview}),
  dr("test_design_review_api_promote_layout",     {drNeedsReview}),
  dr("test_design_review_api_list_layouts",       {drNeedsReview}),
  dr("test_design_review_gallery_fetch_on_open",  {drNeedsReview}),
  dr("test_design_review_daemon_discovery",       {drNeedsReview}),
  dr("test_design_review_brief_has_history_signal", {drNeedsReview}),
  dr("test_design_review_list_history_e2e",       {drNeedsReview}),
  dr("test_design_review_save_brief_route",       {drNeedsReview}),
  # run-review + capture e2e — real CLI subprocess + PgFixture (+ FakeBridge).
  dr("test_design_review_agent_dispatch",         {drNeedsReview}),
  dr("e2e_design_review_run_review",              {drNeedsReview}),
  dr("e2e_design_review_capture_fullsweep",       {drNeedsReview}),
  dr("e2e_full_pipeline_run_through_task_app_brief", {drNeedsReview}),
  dr("e2e_full_pipeline_round_trip_two_runs_visible_in_gallery", {drNeedsReview}),
  dr("e2e_pipeline_refuses_dirty_workspace",      {drNeedsReview}),
  # Chat / agent-routes / campaigns — serve daemon + fake-acp-agent stdio.
  dr("test_design_review_daemon_agent_routes",    {drNeedsReview, drNeedsFakeAcp}),
  dr("test_design_review_cli_chat",               {drNeedsReview, drNeedsFakeAcp}),
  dr("test_design_review_streaming_sse",          {drNeedsReview, drNeedsFakeAcp}),
  dr("test_design_review_chat_priming",           {drNeedsReview, drNeedsFakeAcp}),
  dr("test_design_review_campaign_routes",        {drNeedsReview, drNeedsFakeAcp}),
  # FUP-J — stale-assertion fix (RE-INCLUDED): the three ``inject_*``
  # subtests were CMP-M4-era and expected ``campaign inject`` after
  # ``start`` to SUCCEED (202 + an ``operator_injection`` note). CMP-M7's
  # single-turn model tears the ACP session down when the turn ends, and
  # ``start --no-tail`` drains the SSE to that ``end`` event before it
  # returns — so inject now deterministically hits a session-less
  # campaign. The authoritative CMP-M7 route contract (enshrined by
  # ``test_design_review_campaign_routes`` above:
  # ``test_inject_after_turn_end_returns_404`` /
  # ``_does_not_record_event``) is 404 ``no_active_session`` + no note.
  # The subtests were updated to assert that CMP-M7 outcome end-to-end
  # through the CLI (exit 5 / ``no_active_session`` / no note recorded);
  # the product is unchanged. Re-included.
  dr("test_design_review_cli_campaign",           {drNeedsReview, drNeedsFakeAcp}),
  dr("e2e_campaign_start_and_tick",               {drNeedsReview, drNeedsFakeAcp}),
  # Benchmark threshold suite — design_review_bench binary + PgFixture.
  dr("test_design_review_bench_thresholds_respected", {drNeedsBench}),
  dr("e2e_design_review_bench_runner",            {drNeedsBench}),
  dr("e2e_design_review_bench_regression",        {drNeedsBench}),
  dr("e2e_design_review_bench_published",         {drNeedsBench}),
]

package isonim:
  defaultToolProvisioning "path"

  uses:
    # Toolchain floor — the PATH-resolvable binaries the build needs.
    # ``nim`` compiles every test binary (the ``buildNimUnittest.build``
    # edges below, matching the nimble file's ``requires "nim >= 2.0.0"``);
    # ``gcc`` is the C back-end ``nim c`` shells out to. Sufficient for the
    # path-mode resolver under ``nix develop``.
    "nim >=2.0"
    "gcc >=12"

    # FUP-E2 JS-backend suite: ``node`` runs the ``nim js`` output (the
    # ``build/js-test/<stem>.js`` files) and drives the Tailwind extract
    # (``tools/tailwind-extract.mjs``). Declaring it here makes the engine
    # provision it (path-mode: resolve ``node`` on PATH from the flake dev
    # shell) AND injects the ``node`` typed-tool into this project file — the
    # same mechanism ``codetracer/reprobuild.nim`` uses (``"node >=20"`` in
    # its ``uses:`` block powers its ``node(...)`` webpack/stylus edges). The
    # ``nim.js`` typed-tool comes from the already-declared ``nim`` above.
    "node >=20"

    # The five landed sibling Nim-library producers (SC-11 develop-mode
    # from-source consumption). ``src/isonim/editor/*`` import each of these;
    # naming the workspace project here makes reprobuild build the sibling
    # from source (its ``library`` edge) and thread its ``src/`` root onto
    # this repo's ``nim c --path:`` via the ``nimPathDirs`` aux channel —
    # replacing ``tests/config.nims``'s hardcoded ``--path:../../nim-*/src``
    # / ``--path:../../isonim-render-serve/src``.
    "isonim-render-serve"   # library isonim_render_serve
    "nim-acp"               # library nim_acp
    "nim-agents"            # library nim_agents
    "nim-agent-harbor"      # library nim_agent_harbor — needed transitively:
                            # ``nim_agents`` ``import``s + ``export``s
                            # ``nim_agent_harbor`` (nim_agents.nim / client.nim),
                            # so every edge importing nim_agents needs it on
                            # ``--path:`` (dropping it breaks nim_agents compile).
    "nim-everywhere"        # library nim_everywhere

  # Library declaration — the ``src/`` tree is importable when this package
  # is consumed via ``uses: "isonim"``. The umbrella is ``src/isonim.nim``
  # (consumers ``import isonim``); the submodules under ``src/isonim/``
  # (``core/*``, ``dsl/*``, ``ssr/*``, ``editor/*``, …) are importable too.
  # The exported path is ``src`` (convention default). This is the anchor
  # the downstream isonim renderer repos (isonim-tui / isonim-freya /
  # isonim-gpui / isonim-android / isonim-cocoa / ngx-isonim /
  # isonim-examples) consume.
  library isonim

  build:
    # Two-edge test template (Package-Model.md §"The test template"): one
    # compile-only BUILD edge + one EXECUTE edge per test file. BUILD halves
    # collect into ``test-builds`` (compile-only verification); EXECUTE
    # halves collect into ``test`` so ``repro test`` / ``repro build test``
    # materialise the runnable closure (each execute edge transitively
    # depends on its build edge).
    #
    # ``paths`` reproduces exactly what ``tests/config.nims`` + the
    # ``Justfile`` recipes put on ``--path`` for the native corpus, MINUS
    # the five sibling ``src`` roots (those are threaded by the SC-11
    # ``nimPathDirs`` channel off the ``uses:`` edges):
    #   * ``src`` + ``.``               — the repo's own module roots.
    #   * ``vendor/{chronicles,serialization,json_serialization}`` +
    #     ``vendor/db_connector/src`` — the vendored third-party trees.
    #   * ``../nim-faststreams`` + ``../nim-stew`` — workspace sibling
    #     source trees that are NOT SC-11 ``library`` producers (no
    #     ``repro.nim``), so resolved by ``--path`` (config.nims's
    #     ``../../nim-*`` → ``../nim-*`` from this repo root).
    #
    # ``defines`` reproduces the four ``-d:`` knobs ``config.nims`` bakes
    # into every compile (the engine build does not read ``config.nims``).
    const isonimPaths = @[
      "src", ".",
      "vendor/chronicles",
      "vendor/serialization",
      "vendor/json_serialization",
      "vendor/db_connector/src",
      "../nim-faststreams",
      "../nim-stew",
    ]
    const isonimDefines = @[
      "nimOldCaseObjects",
      "chronicles_sinks=textlines[stderr]",
      "chronicles_runtime_filtering=on",
      "chronicles_log_level=TRACE",
    ]

    var testBuildActions: seq[BuildActionDef] = @[]
    var testExecuteActions: seq[BuildActionDef] = @[]

    proc emitTest(source, binary: string; executeToo: bool;
                  buildActions, executeActions: var seq[BuildActionDef]) =
      var lastSlash = -1
      for i in 0 ..< binary.len:
        if binary[i] == '/' or binary[i] == '\\':
          lastSlash = i
      let stem =
        if lastSlash >= 0: binary[lastSlash + 1 .. ^1]
        else: binary
      let edge = buildNimUnittest.build(
        source = source,
        binary = binary,
        defines = isonimDefines,
        paths = isonimPaths,
        actionId = "isonim.test_build." & stem,
        # ``src`` + the nimble file are declared inputs so the monitor
        # tracks the transitively imported ``src/isonim/**`` module tree
        # (the reactive core / DSL / editor modules the tests pull in).
        extraInputs = @["src", "isonim.nimble"])
      buildActions.add(edge.action)
      # ``registerImplicitName = false``: the BUILD edge already owns the
      # binary basename as the implicit target name; the explicit
      # ``actionId`` is the execute edge's selector (two-edge shape).
      if executeToo:
        let executeEdge = edge.testBinary.run(
          actionId = "isonim.test_execute." & stem,
          registerImplicitName = false)
        executeActions.add(executeEdge)

    # Full build+execute edges — the headless-runnable corpus.
    for s in isonimTestSpecs:
      emitTest(s.source, s.binary, executeToo = true,
        testBuildActions, testExecuteActions)
    # Compile-only edges — BUILD half only (set B2); EXECUTE deferred.
    for s in isonimCompileOnlySpecs:
      emitTest(s.source, s.binary, executeToo = false,
        testBuildActions, testExecuteActions)

    # --- Design-review external-service suite (set (B), FUP-E1) ------------
    # Prerequisite tool binaries the design-review daemon/CLI/bench tests
    # spawn at runtime. Modelled as BUILD edges (folded into ``test-builds``)
    # and wired to the execute edges below via ``requiredBinaries`` so the
    # engine builds them first. They compile with the same paths/defines as
    # the test corpus (the ``uses:`` siblings supply the sibling ``src``
    # roots via the ``nimPathDirs`` channel).
    const drReviewBin = "build/bin/isonim-review"
    const drFakeAcpBin = "build/bin/fake-acp-agent"
    const drBenchBin = "build/bin/design_review_bench"

    let reviewToolEdge = buildNimUnittest.build(
      source = "tools/isonim_review/main.nim",
      binary = drReviewBin,
      defines = isonimDefines,
      paths = isonimPaths,
      actionId = "isonim.tool_build.isonim_review",
      extraInputs = @["src", "tools", "db", "isonim.nimble"])
    testBuildActions.add(reviewToolEdge.action)

    let fakeAcpToolEdge = buildNimUnittest.build(
      source = "tests/helpers/fake_acp_agent.nim",
      binary = drFakeAcpBin,
      defines = isonimDefines,
      paths = isonimPaths,
      actionId = "isonim.tool_build.fake_acp_agent",
      extraInputs = @["src", "tests/helpers", "isonim.nimble"])
    testBuildActions.add(fakeAcpToolEdge.action)

    let benchToolEdge = buildNimUnittest.build(
      source = "bench/design_review_bench.nim",
      binary = drBenchBin,
      defines = isonimDefines,
      paths = isonimPaths,
      actionId = "isonim.tool_build.design_review_bench",
      extraInputs = @["src", "bench", "db", "isonim.nimble"])
    testBuildActions.add(benchToolEdge.action)

    # Per design-review test: a BUILD edge (into ``test-builds``) + an
    # EXECUTE edge routed through the capacity-1 serial pool, declaring the
    # tool binaries it spawns via ``requiredBinaries``.
    const designReviewPool = "isonim.design-review-serial"
    for s in isonimDesignReviewSpecs:
      let source = "tests/" & s.stem & ".nim"
      let binary = "build/test-bin/" & s.stem
      let edge = buildNimUnittest.build(
        source = source,
        binary = binary,
        defines = isonimDefines,
        paths = isonimPaths,
        actionId = "isonim.dr_build." & s.stem,
        # ``db`` (migrations SQL) + ``tests/helpers`` (the PgFixture /
        # FakeBridge / fake-acp helpers) are declared inputs alongside
        # ``src`` so a fixture/migration edit invalidates the affected
        # design-review edges.
        extraInputs = @["src", "db", "tests/helpers", "isonim.nimble"])
      testBuildActions.add(edge.action)
      var req: seq[string] = @[]
      if drNeedsReview in s.needs: req.add drReviewBin
      if drNeedsFakeAcp in s.needs: req.add drFakeAcpBin
      if drNeedsBench in s.needs: req.add drBenchBin
      let executeEdge = edge.testBinary.run(
        actionId = "isonim.dr_execute." & s.stem,
        pool = designReviewPool,
        poolUnits = 1'u32,
        requiredBinaries = req,
        registerImplicitName = false)
      testExecuteActions.add(executeEdge)

    # --- JS-backend suite (set (A), FUP-E2) --------------------------------
    # Two edges per JS test: a ``nim.js`` BUILD edge (compile the JS back-end
    # to ``build/js-test/<stem>.js``) + a ``node`` EXECUTE edge (run the
    # emitted JS under node). BUILD halves fold into ``test-builds``; EXECUTE
    # halves into ``test``. The JS compiles reuse the SAME ``isonimPaths`` +
    # ``isonimDefines`` as the C corpus — ``tests/config.nims`` applies both
    # sets to ``nim js -r`` too, so the edge reproduces the repo's own JS
    # compile environment (the engine build does not read ``config.nims``).
    #
    # Compile-time prerequisite: ``src/isonim/dsl/tailwind.nim`` ``staticRead``s
    # ``build/tailwind-styles.json`` on the JS back-end. The native back-end
    # guards that read behind ``when fileExists`` and tolerates the file's
    # absence (empty style map); the JS/nimscript path uses a bare
    # ``staticRead`` whose missing-file failure is an UNCATCHABLE compile
    # error (the ``try/except`` around it does not catch it). So the file must
    # exist before any JS compile. The repo generates it with ``just
    # build-tailwind`` (``node tools/tailwind-extract.mjs`` → the real Tailwind
    # v4 CLI); modelled here as a ``node`` BUILD edge that every JS compile
    # depends on via ``after``. node_modules (``@tailwindcss/cli`` + deps) is a
    # bootstrap prerequisite the same way the flake dev shell is — the repo's
    # own ``build-tailwind`` recipe runs ``[ -d node_modules ] || yarn
    # install`` before the extract; once installed the extract is offline
    # (``npx`` resolves the local install, no network).
    let tailwindStylesEdge = node(
      args = @["tools/tailwind-extract.mjs"],
      actionId = "isonim.tailwind_extract",
      extraInputs = @["tools/tailwind-extract.mjs", "package.json", "src"],
      extraOutputs = @["build/tailwind-styles.json", "build/tailwind.css"])
    testBuildActions.add(tailwindStylesEdge)

    # JS execute/build halves are ALSO folded into a dedicated ``js-test`` /
    # ``js-test-builds`` target so ``repro build js-test`` materialises just
    # the JS-backend closure (tailwind extract + ``nim js`` compiles + node
    # runs) — the reprobuild-native analogue of the ``Justfile`` ``test-js``
    # recipe — without pulling the native + design-review corpus.
    var jsBuildActions: seq[BuildActionDef] = @[tailwindStylesEdge]
    var jsExecuteActions: seq[BuildActionDef] = @[]
    for stem in isonimJsTestSpecs:
      let jsSource = "tests/" & stem & ".nim"
      let jsOut = "build/js-test/" & stem & ".js"
      let jsCompileEdge = nim.js(
        source = jsSource,
        output = jsOut,
        # ``nodejs``: ``nim js`` defaults to the BROWSER target, where Nim's
        # ``quit(1)`` (emitted by a failing ``unittest`` ``check``) is a no-op,
        # so ``node`` would exit 0 even on an assertion failure. The repo's own
        # ``nim js -r`` sweep escapes this because ``-r`` auto-adds
        # ``-d:nodejs`` (emits ``process.exit``); this compile-only edge has no
        # ``-r``, so it must add ``-d:nodejs`` itself for ``node`` to propagate
        # the failing exit code to the ``isonim.js_execute.<stem>`` edge.
        defines = isonimDefines & @["nodejs"],
        paths = isonimPaths,
        hintsOff = true,
        warningsOff = true,
        actionId = "isonim.js_build." & stem,
        after = @[tailwindStylesEdge],
        extraInputs = @["src", "build/tailwind-styles.json", "isonim.nimble"])
      testBuildActions.add(jsCompileEdge)
      jsBuildActions.add(jsCompileEdge)
      let jsExecuteEdge = node(
        args = @[jsOut],
        actionId = "isonim.js_execute." & stem,
        after = @[jsCompileEdge],
        extraInputs = @[jsOut])
      testExecuteActions.add(jsExecuteEdge)
      jsExecuteActions.add(jsExecuteEdge)

    # FUP-J — JS compile-only stems: a ``nim.js`` BUILD edge with NO node
    # execute edge (the ``test-editor`` recipe compiles but never runs these).
    for stem in isonimJsCompileOnlySpecs:
      let jsSource = "tests/" & stem & ".nim"
      let jsOut = "build/js-test/" & stem & ".js"
      let jsCompileOnlyEdge = nim.js(
        source = jsSource,
        output = jsOut,
        defines = isonimDefines & @["nodejs"],
        paths = isonimPaths,
        hintsOff = true,
        warningsOff = true,
        actionId = "isonim.js_build." & stem,
        after = @[tailwindStylesEdge],
        extraInputs = @["src", "build/tailwind-styles.json", "isonim.nimble"])
      testBuildActions.add(jsCompileOnlyEdge)
      jsBuildActions.add(jsCompileOnlyEdge)

    discard collect("test", testExecuteActions)
    discard collect("test-builds", testBuildActions)
    discard collect("js-test", jsExecuteActions)
    discard collect("js-test-builds", jsBuildActions)
