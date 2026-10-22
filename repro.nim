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
##         ELH-M3 re-includes ``tests/test_editor_agent_harbor.nim`` as native
##         and JS build+execute edges: its three adapter/wire/ViewModel tests
##         pass on both backends, including neutral typed human input state.
##         ``tests/test_editor_viewmodels.nim`` remains deferred: the current
##         full native run has 73 passes and one pre-existing presentation-string
##         guard failure (``flex-`` / ``text-`` in unchanged ViewModel source).
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
##     ``renderToOutputStream``) — genuinely stale, so they get no edge. Both
##     re-verified against a fully provisioned checkout while fixing the sibling
##     gap below: the stated reasons are the actual compiler errors, so these
##     two exclusions stand.
##     The same sweep found the yoga pattern once more, in the tests that reach
##     the CROSS-REPO siblings rather than the submodule. Three tests were in no
##     ``Justfile`` recipe:
##       - ``test_faststreams_ssr`` — genuinely stale, as above.
##       - ``test_resource_async`` — no recorded reason, and none holds. It
##         compiles and passes 10/10 on the C target and is now in ``test-c``
##         (C only: it calls ``newFuture``, absent on the JS backend). It
##         reaches ``nim_everywhere`` through ``src/isonim/core/resource.nim``.
##       - ``test_editor_real_preview`` — no recorded reason either, but this
##         one has a real environmental dependency rather than a false
##         justification: it launches ``../isonim-examples/build/backends/
##         isonim-examples-tui`` and fails ``[FAILED] real launcher feeds a
##         manifest the VM hit-tests back to a task row`` without it. Note
##         ``isonim-examples`` is a member of the isonim project manifest but is
##         NOT in ``tests/config.nims`` (it is a runtime, not a compile-time,
##         dependency), so ``.github/sibling-repos`` does not declare it and
##         ``check-siblings`` does not ask for it. Bringing this test into scope
##         means declaring that sibling and building its backend first; left
##         alone here, recorded so the exclusion is a decision and not an
##         accident.
##
## **Cross-repo siblings.** ``tests/config.nims`` resolves 8 sibling repos
## through ``$projectDir/../../``; ``.github/sibling-repos`` declared 4 and
## ``ci.yml`` ran no ``setup-dev-env`` at all, so CI had none of them. All 8 are
## load-bearing — three only transitively (``nim-agent-harbor`` via
## ``nim-agents``, ``isonim-cocoa`` via ``isonim-render-serve``, ``nim-stew`` via
## ``nim-faststreams``), which is why they were the ones omitted. ``just
## check-siblings`` now fails on either half: a declared sibling missing from
## disk, or a ``config.nims`` path missing from the declaration file.
##
## **Tool provisioning.** ``defaultToolProvisioning "path"`` matches the
## canonical recipes: the nix dev shell puts ``nim`` + ``gcc`` on ``PATH``,
## so the weak-local PATH resolver is the right default. It is also required
## for the ``uses:`` declarations to resolve at all ("typed tool provisioning
## is required for uses declarations").

import std/strutils
import repro_project_dsl
import repro_dsl_stdlib/foreign_env

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
import repro_dsl_stdlib/packages/python_unittest_runner
import repro_dsl_stdlib/packages/sh as sh

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
  spec("test_editor_control"),
  spec("test_editor_control_routes"),
  spec("test_editor_agent_launch_cleanup"),
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
  # Shared content parsers, renderers and token loader.
  spec("test_content_markdown"),
  spec("test_content_frontmatter"),
  spec("test_content_anchors"),
  spec("test_content_highlight"),
  spec("test_content_directives"),
  spec("test_content_prose"),
  spec("test_theming_dtcg"),
  # --- isonim/static: static export, sitemap, robots, head, script policy ---
  spec("test_static_export"),
  spec("test_static_script_policy"),
  spec("test_static_metadata"),
  spec("test_http_types"),
  spec("test_form_actions"),
  spec("test_third_party"),
  spec("test_viewmodel"),
  spec("test_demo_vm"),
  # --- Editor / ViewModel (headless) — no PG / bridge / agent ---
  spec("test_editor_workspace"),
  spec("test_editor_workspace_refresh"),
  spec("test_editor_public_api"),
  spec("test_editor_source_scope_labels"),
  spec("test_editor_renderer_boundaries"),
  spec("test_editor_preview_mount"),
  spec("test_editor_shell_views"),
  spec("test_editor_loop_handlers"),
  spec("test_loop_accessors"),
  spec("test_choice_row_activation"),
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
  spec("test_editor_color_popover"),
  spec("test_editor_color_picker"),
  spec("test_editor_surface_toggle_vm"),
  spec("test_editor_chat_activity"),
  spec("test_editor_chat_tabs_vm"),
  spec("test_editor_chat_view_lifetime"),
  spec("test_editor_shell_chat_lifetime"),
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
  spec("test_editor_source_scope_row"),
  spec("test_editor_source_style_bindings"),
  spec("test_editor_source_markup"),
  spec("test_editor_section_layout"),
  spec("test_editor_section_position"),
  spec("test_editor_section_selection_colors"),
  spec("test_editor_section_source"),
  spec("test_editor_section_state"),
  spec("test_editor_source_write_receipts"),
  spec("test_editor_save_pipeline"),
  spec("test_editor_act_time_refusals"),
  spec("test_editor_inspector_controls"),
  spec("test_editor_reset_removal"),
  spec("test_editor_section_raw_css"),
  spec("test_editor_section_stroke"),
  spec("test_editor_section_typography"),
  # --- SC-11 sibling-exercising editor tests (the reason for the five
  #     ``uses:`` edges — each compiles a sibling ``src/`` root threaded via
  #     the ``nimPathDirs`` channel), FULL build+execute (headless-runnable):
  spec("test_editor_agent_context"),          # import nim_acp
  spec("test_editor_agent_harbor"),           # common wire + production ViewModel
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
  "test_editor_chat_view_lifetime",
  "test_editor_renderer_boundaries",
  "test_editor_preview_mount",
  "test_editor_shell_views",
  "test_editor_source_markup",
  "test_editor_section_source",
  "test_editor_section_appearance", "test_editor_section_component_props", "test_editor_section_layout", "test_editor_section_position",
  "test_editor_color_popover",
  "test_editor_color_picker",
  "test_editor_widget_property_row", "test_editor_section_fill", "test_editor_source_scope_row",
  "test_editor_chat_activity",
  "test_editor_control",
  "test_editor_workspace_refresh",
  "test_editor_source_write_receipts",
  "test_editor_save_pipeline",
  "test_editor_act_time_refusals",
  "test_editor_inspector_controls",
  "test_editor_reset_removal",
  "test_editor_section_raw_css",
  "test_editor_agent_harbor",
  "test_browser_agent_lifecycle",
  # Reactive core (dual-backend; also in the native corpus above).
  "test_signals", "test_effects", "test_clock", "test_context", "test_rxcore",
  # DSL / SSR-hydration / web-component / router / server-fn / data-loading.
  "test_dsl", "test_web", "test_demo_vm", "test_benchmark", "test_viewmodel",
  "test_terminal", "test_hydration", "test_ssr_hydration_e2e",
  "test_web_components_advanced", "test_third_party", "poc_monaco_host",
  "test_accessibility", "test_router", "test_server_functions",
  "test_data_loading",
  # Pure shared content suites run on both backends.
  "test_content_markdown",
  "test_content_frontmatter",
  "test_content_anchors",
  "test_content_highlight",
  "test_content_directives",
  "test_content_prose",
  # isonim/static: the script policy and SEO head are pure (dual-backend).
  "test_static_script_policy",
  "test_static_metadata",
  # Per-item captures and activation are contracts on both backends.
  "test_choice_row_activation", "test_loop_accessors",
  # JS-back-end-only (``{.error.}`` head unless ``defined(js)``).
  "test_custom_elements",
  "test_editor_section_stroke", "test_editor_section_effects",
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
  # Optional local-runtime selection and actual public Repro producer fixtures.
  # The private-repository live acceptance target is explicit in the Justfile.
  dr("test_daemon_ready_handshake"),
  dr("test_design_review_local_harbor"),
  dr("test_design_review_harbor_build"),
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
  dr("test_design_review_class_quota"),
  dr("test_migrated_task_app_brief_parses"),
  dr("test_migrated_settings_app_brief_parses"),
  # FUP-J — stale-assertion fix: the migrated chrome-brief corpus grew to
  # 18 (``gallery-*`` + ``spec-pane-*`` added); ``ExpectedSlugs`` updated
  # to match. Pure parse test, no service.
  dr("test_migrated_chrome_briefs_parse"),
  dr("test_no_dangling_references_to_old_brief_path"),
  dr("test_design_review_cli_config"),
  # Capture pipeline — in-process FakeBridge + PgFixture, no CLI subprocess.
  # The clean-tree gate, workspace-pin and brief_at_revision tests build
  # hermetic reprobuild workspaces and read them through ``repro``
  # (``repro workspace status`` / ``list``), which must be on PATH or
  # named by ``ISONIM_REVIEW_REPRO``.
  dr("test_design_review_clean_tree"),
  dr("test_design_review_workspace_pin"),
  # Campaign start / round pins (migration 012): the same gate + pin as
  # capture over hermetic reprobuild workspaces, and the pin routines
  # against an ephemeral PgFixture.
  dr("test_design_review_campaign_pins"),
  dr("test_design_review_campaign_pins_pg"),
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
  dr("test_editor_agent_route_ownership",         {}),
  dr("test_editor_scenario_protocol",             {}),
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
  devEnv:
    when not defined(windows):
      useFlakeDevShell()

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
    "python3 >=3.9"

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
    var sourceLabelActions: seq[BuildActionDef] = @[]
    var currentShellActions: seq[BuildActionDef] = @[]
    var rendererBoundaryActions: seq[BuildActionDef] = @[]
    var previewMountActions: seq[BuildActionDef] = @[]
    var inspectorFoundationActions: seq[BuildActionDef] = @[]
    var chatLifetimeActions: seq[BuildActionDef] = @[]
    var testExecuteActions: seq[BuildActionDef] = @[]
    var contentNativeActions: seq[BuildActionDef] = @[]
    var contentJsActions: seq[BuildActionDef] = @[]
    var popupHeadlessActions: seq[BuildActionDef] = @[]
    var c2HeadlessActions: seq[BuildActionDef] = @[]
    var c3HeadlessActions: seq[BuildActionDef] = @[]
    var c4aHeadlessActions: seq[BuildActionDef] = @[]

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
        extraInputs = @["src", "isonim.nimble"] & (if stem == "test_editor_renderer_boundaries": @["tests/test_editor_source_scope_labels.nim", "tests/test_editor_shell_chat_lifetime.nim", "tests/helpers/editor_source_scope_label_cases.nim"] else: @[]) & (if stem == "test_editor_source_scope_labels": @["tests/helpers/editor_source_scope_label_cases.nim"] else: @[]) & (if stem == "test_static_export": @["tests/fixtures/static-export"] else: @[]))
      buildActions.add(edge.action)
      # ``registerImplicitName = false``: the BUILD edge already owns the
      # binary basename as the implicit target name; the explicit
      # ``actionId`` is the execute edge's selector (two-edge shape).
      if executeToo:
        let executeEdge = edge.testBinary.run(
          actionId = "isonim.test_execute." & stem,
          extraInputs = (if stem == "test_theming_dtcg": @["../codetracer-design-system/brand/brand.json", "../codetracer-design-system/alias/alias.json", "../codetracer-design-system/mapped/mapped.json"] else: @[]),
          registerImplicitName = false)
        executeActions.add(executeEdge)
        if stem.startsWith("test_content_") or stem == "test_theming_dtcg":
          contentNativeActions.add(executeEdge)
        if stem == "test_editor_shell_views": currentShellActions.add(executeEdge)
        if stem == "test_editor_renderer_boundaries": rendererBoundaryActions.add(executeEdge)
        if stem == "test_editor_preview_mount": previewMountActions.add(executeEdge)
        if stem in ["test_editor_source_markup", "test_editor_source_style_bindings", "test_editor_control_routes"]: inspectorFoundationActions.add(executeEdge)
        if stem in ["test_editor_chat_view_lifetime", "test_editor_shell_chat_lifetime", "test_editor_chat_tabs_vm", "test_editor_chat_activity"]: chatLifetimeActions.add(executeEdge)
        if stem in ["test_editor_section_source", "test_editor_source_scope_labels", "test_editor_source_scope_row", "test_editor_section_component_props"]: sourceLabelActions.add(executeEdge)
        if stem in ["test_editor_section_appearance", "test_editor_section_component_props", "test_editor_section_layout", "test_editor_section_position", "test_editor_section_stroke", "test_editor_section_effects"]: c4aHeadlessActions.add(executeEdge)
        if stem in ["test_editor_color_picker", "test_editor_color_popover"]:
          c3HeadlessActions.add(executeEdge)
        if stem in ["test_effects", "test_editor_widget_property_row", "test_editor_color_popover", "test_editor_section_fill", "test_editor_source_scope_row"]:
          c2HeadlessActions.add(executeEdge)
        if source in ["tests/test_editor_color_popover.nim", "tests/test_signals.nim"]:
          popupHeadlessActions.add(executeEdge)

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
    let sourceMetadataEdge = sh.shell(
      command = "python3 tests/test_editor_source_metadata_transactions.py", cacheable = false,
      actionId = "isonim.source_metadata_execute",
      after = @[reviewToolEdge.action],
      extraInputs = @["tests/test_editor_source_metadata_transactions.py", "tests/fixtures/editor_inspector_project",
        "tools/build_source_catalog.py", "tools/editor_server.py", "tools/isonim_review/source_project_lock.nim", drReviewBin])
    testExecuteActions.add(sourceMetadataEdge)

    var inspectorNativeSourceActions: seq[BuildActionDef] = @[]
    for stem in ["test_editor_inspector_source", "test_editor_source_style_provider"]:
      let edge = sh.shell(
        command = "python3 tests/" & stem & ".py", cacheable = false,
        actionId = "isonim.inspector_native_execute." & stem,
        after = @[reviewToolEdge.action],
        extraInputs = @["tests/" & stem & ".py", "tests/fixtures/editor_inspector_project",
          "tools/build_source_catalog.py", "tools/isonim_review", "src", drReviewBin])
      inspectorNativeSourceActions.add(edge)
      testExecuteActions.add(edge)
    let sourceBindingsGuiEdge = sh.shell(
      command = "timeout --signal=TERM --kill-after=15s 180s node tests/test_editor_source_bindings_gui.mjs", cacheable = false,
      actionId = "isonim.inspector_bindings_gui_execute", after = @[reviewToolEdge.action],
      extraInputs = @["tests/test_editor_source_bindings_gui.mjs", "tests/fixtures/editor_inspector_project",
        "examples/source_project/editor.nim", "tools/editor_server.py", "tools/build_source_catalog.py", "src", drReviewBin])
    inspectorNativeSourceActions.add(sourceBindingsGuiEdge)
    testExecuteActions.add(sourceBindingsGuiEdge)
    discard collect("test-editor-inspector-native-source", inspectorNativeSourceActions)

    let controlCliEdge = sh.shell(
      command = "cp build/bin/isonim-review build/bin/isonim",
      actionId = "isonim.tool_build.isonim",
      after = @[reviewToolEdge.action],
      extraInputs = @[drReviewBin], extraOutputs = @["build/bin/isonim"])
    testBuildActions.add(controlCliEdge)
    let controlBrowserEdge = sh.shell(
      command = "just editor-control-build",
      actionId = "isonim.control_build.browser",
      extraInputs = @["src", "tests/helpers/editor_control_workspace.nim", "Justfile", "package.json"],
      extraOutputs = @["build/editor-control"])
    testBuildActions.add(controlBrowserEdge)
    let chatBrowserEdge = sh.shell(
      command = "just editor-chat-build",
      actionId = "isonim.chat_activity_build.browser",
      extraInputs = @["src", "tests/helpers/editor_chat_workspace.nim", "Justfile", "package.json"],
      extraOutputs = @["build/editor-chat"])
    testBuildActions.add(chatBrowserEdge)
    testExecuteActions.add(node(
      args = @["tests/test_editor_chat_activity_gui.mjs"],
      actionId = "isonim.chat_activity_execute.gui",
      after = @[chatBrowserEdge],
      extraInputs = @["tests/test_editor_chat_activity_gui.mjs", "tests/fixtures/chat-session-events.json", "build/editor-chat"]))
    let admissionGuiEdge = sh.shell(
      command = "node tests/test_editor_admission_gui.mjs", cacheable = false,
      actionId = "isonim.chat_activity_execute.admission_gui",
      after = @[chatBrowserEdge],
      extraInputs = @["tests/test_editor_admission_gui.mjs", "build/editor-chat"])
    testExecuteActions.add(admissionGuiEdge)
    discard collect("test-editor-admission", @[admissionGuiEdge])
    let popupBrowserEdge = sh.shell(
      command = "just editor-popup-build",
      actionId = "isonim.popup_build.browser",
      extraInputs = @["src", "tests/helpers/editor_popup_workspace.nim", "tests/helpers/core_owner_hmr.nim", "Justfile", "package.json"],
      extraOutputs = @["build/editor-popup"])
    testBuildActions.add(popupBrowserEdge)
    # The frontend compiler reads the generated Tailwind input.
    let tailwindStylesEdge = node(
      args = @["tools/tailwind-extract.mjs"],
      actionId = "isonim.tailwind_extract",
      extraInputs = @["tools/tailwind-extract.mjs", "package.json", "src"],
      extraOutputs = @["build/tailwind-styles.json", "build/tailwind.css"])
    testBuildActions.add(tailwindStylesEdge)

    let inspectorBrowserEdge = sh.shell(
      command = "just editor-inspector-build", actionId = "isonim.c2_build.inspector",
      after = @[tailwindStylesEdge],
      extraInputs = @["src", "tests/helpers/editor_popup_workspace.nim", "Justfile", "package.json", "build/tailwind-styles.json"],
      extraOutputs = @["build/editor-inspector"])
    testBuildActions.add(inspectorBrowserEdge)
    let c3GuiEdge = sh.shell(
      command = "\"${ISONIM_SCENARIO_NODE:-node}\" tests/test_editor_color_picker_gui.mjs", cacheable = false,
      actionId = "isonim.c3_execute.color_picker_gui",
      after = @[inspectorBrowserEdge, reviewToolEdge.action],
      extraInputs = @["tests/test_editor_color_picker_gui.mjs", "tests/helpers/editor_control_peer.py",
        "tests/fixtures/editor_inspector_project", "tools/editor_server.py", "tools/build_source_catalog.py",
        "build/editor-inspector", drReviewBin])
    testExecuteActions.add(c3GuiEdge)
    let c2GuardEdge = sh.shell(
      command = "python3 tests/test_nim_js_guard.py", cacheable = false,
      actionId = "isonim.c2_execute.js_guard_controls",
      extraInputs = @["tests/test_nim_js_guard.py", "tools/run_nim_js_test.py"])
    testExecuteActions.add(c2GuardEdge)
    c2HeadlessActions.add(c2GuardEdge)
    var c2SourceActions: seq[BuildActionDef] = @[]
    for stem in ["test_editor_fill_readonly_gui", "test_editor_inspector_source_gui", "test_editor_native_reset_gui", "test_editor_native_compiled_reset_gui", "test_editor_native_compiled_scope_sides_gui"]:
      let edge = sh.shell(
        command = "\"${ISONIM_SCENARIO_NODE:-node}\" tests/" & stem & ".mjs", cacheable = false,
        actionId = "isonim.c2_execute." & stem,
        after = @[inspectorBrowserEdge, reviewToolEdge.action],
        extraInputs = @["tests/" & stem & ".mjs", "tests/helpers/editor_control_peer.py",
          "tests/fixtures/editor_inspector_project", "tools/editor_server.py", "tools/build_source_catalog.py",
          "build/editor-inspector", drReviewBin])
      c2SourceActions.add(edge)
      testExecuteActions.add(edge)

    let popupGeometryEdge = sh.shell(
      command = "\"${ISONIM_SCENARIO_NODE:-node}\" tests/test_editor_popover_geometry.mjs", cacheable = false,
      actionId = "isonim.popup_execute.geometry",
      extraInputs = @["tests/test_editor_popover_geometry.mjs", "src/isonim/editor/views/widgets/anchored_popover.js"])
    let popupOwnerHmrEdge = sh.shell(
      command = "\"${ISONIM_SCENARIO_NODE:-node}\" tests/test_core_owner_hmr.mjs", cacheable = false,
      actionId = "isonim.popup_execute.owner_hmr",
      after = @[popupBrowserEdge],
      extraInputs = @["tests/test_core_owner_hmr.mjs", "tests/helpers/core_owner_hmr.nim", "build/editor-popup/core-owner-hmr.js"])
    let popupGuiEdge = sh.shell(
      command = "\"${ISONIM_SCENARIO_NODE:-node}\" tests/test_editor_popup_gui.mjs", cacheable = false,
      actionId = "isonim.popup_execute.gui",
      after = @[popupBrowserEdge, reviewToolEdge.action],
      extraInputs = @["tests/test_editor_popup_gui.mjs", "examples/source_project", "build/editor-popup"])
    let popupSelectionRestoreEdge = sh.shell(
      command = "\"${ISONIM_SCENARIO_NODE:-node}\" tests/test_editor_selection_restore_gui.mjs", cacheable = false,
      actionId = "isonim.popup_execute.selection_restore",
      after = @[popupBrowserEdge, reviewToolEdge.action],
      extraInputs = @["tests/test_editor_selection_restore_gui.mjs", "tests/helpers/editor_control_peer.py",
        "tools/editor_server.py", "tools/build_source_catalog.py", "examples/source_project",
        "build/editor-popup", drReviewBin])
    testExecuteActions.add(popupOwnerHmrEdge)
    testExecuteActions.add(popupGeometryEdge)
    testExecuteActions.add(popupSelectionRestoreEdge)
    testExecuteActions.add(popupGuiEdge)
    # Explicit integration with the real metacraft-web consumer adapter. It is
    # outside default tests: public developers need not have the private repo.
    # An explicit invocation fails if its required sibling/import is absent.
    let colorSourceEdge = sh.shell(
      command = "just test-editor-color-source", cacheable = false,
      actionId = "isonim.popup_execute.consumer_source",
      extraInputs = @["tests/test_editor_color_source.nim", "Justfile"])
    discard collect("test-editor-color-source", @[colorSourceEdge])
    let sourceBrowserEdge = sh.shell(
      command = "just source-editor-build",
      actionId = "isonim.source_build.browser",
      extraInputs = @["src", "examples/source_project", "tools/build_source_catalog.py", "Justfile", "package.json"],
      extraOutputs = @["build/editor-source", "examples/source_project/.isonim/catalog.json"])
    testBuildActions.add(sourceBrowserEdge)
    # Explicit real-account acceptance target: no automatic availability skip and
    # no model playback. Keep account-dependent inference out of the default suite.
    let authoringBrowserEdge = sh.shell(
      command = "just editor-authoring-build",
      actionId = "isonim.authoring_build.browser",
      extraInputs = @["src", "tests/helpers/editor_authoring_workspace.nim", "Justfile", "package.json"],
      extraOutputs = @["build/editor-authoring"])
    let preparationClockPythonEdge = pythonUnittest.run(
      source = "tests/test_editor_preparation_clock.py",
      actionId = "isonim.scenario_execute.preparation_clock_python",
      extraInputs = @["tests/test_editor_preparation_clock.py", "tests/helpers/editor_preparation_clock.py"])
    # Honor the same host-selected Node used by the official browser/scenario
    # runners. Tests always execute; an unsupported selected runtime fails.
    let preparationClockNodeEdge = sh.shell(
      command = "\"${ISONIM_SCENARIO_NODE:-node}\" tests/test_editor_preparation_clock.mjs", cacheable = false,
      actionId = "isonim.scenario_execute.preparation_clock_node",
      extraInputs = @["tests/test_editor_preparation_clock.mjs", "tests/helpers/editor_preparation_clock.mjs"])
    testExecuteActions.add(preparationClockPythonEdge)
    testExecuteActions.add(preparationClockNodeEdge)
    discard collect("test-editor-preparation-clock", @[preparationClockPythonEdge, preparationClockNodeEdge])
    let authoringEvidenceEdge = pythonUnittest.run(
      source = "tests/test_editor_authoring_evidence.py",
      actionId = "isonim.authoring_execute.evidence",
      extraInputs = @["tests/test_editor_authoring_evidence.py", "tests/helpers/editor_authoring_evidence.py"])
    testExecuteActions.add(authoringEvidenceEdge)
    let scenarioCleanupEdge = pythonUnittest.run(
      source = "tests/test_editor_scenario_cleanup.py",
      actionId = "isonim.authoring_execute.cleanup",
      extraInputs = @["tests/helpers/editor_scenario_runtime.py", "tests/helpers/editor_preparation_clock.py", "tests/helpers/editor_preparation_clock.mjs", "tests/helpers/editor_process_observer.py"])
    let closeAckEdge = node(
      args = @["tests/test_editor_close_ack.mjs"],
      actionId = "isonim.authoring_execute.close_ack",
      extraInputs = @["tests/test_editor_close_ack.mjs", "tests/helpers/editor_close_ack.mjs"])
    testExecuteActions.add(scenarioCleanupEdge)
    testExecuteActions.add(closeAckEdge)
    let authoringResponsesEdge = pythonUnittest.run(
      source = "tests/test_editor_authoring_responses.py",
      actionId = "isonim.authoring_execute.responses",
      extraInputs = @["tests/helpers/editor_authoring_responses.py"])
    let assistantEvidenceEdge = pythonUnittest.run(
      source = "tests/test_editor_authoring_assistant_evidence.py",
      actionId = "isonim.authoring_execute.assistant_text",
      extraInputs = @["tests/helpers/editor_authoring_assistant_evidence.py", "tests/helpers/editor_authoring_evidence.py"])
    testExecuteActions.add(assistantEvidenceEdge)
    let providerClosureEdge = pythonUnittest.run(
      source = "tests/test_editor_provider_closure.py",
      actionId = "isonim.authoring_execute.provider_closure",
      extraInputs = @["tests/helpers/editor_provider_closure.py", "tests/helpers/editor_provider_wire.py"])
    testExecuteActions.add(providerClosureEdge)
    let sdkProtocolEdge = node(
      args = @["tests/test_editor_sdk_protocol_observer.mjs"],
      actionId = "isonim.authoring_execute.sdk_protocol",
      extraInputs = @["tests/test_editor_sdk_protocol_observer.mjs", "tests/helpers/editor_sdk_native_observer.mjs"])
    let sdkKernelEdge = node(
      args = @["tests/test_editor_sdk_kernel_evidence.mjs"],
      actionId = "isonim.authoring_execute.sdk_kernel",
      extraInputs = @["tests/test_editor_sdk_kernel_evidence.mjs", "tests/helpers/editor_sdk_kernel_evidence.mjs"])
    testExecuteActions.add(sdkKernelEdge)
    testExecuteActions.add(authoringResponsesEdge)
    testExecuteActions.add(sdkProtocolEdge)
    discard collect("test-editor-authoring-evidence", @[preparationClockPythonEdge, preparationClockNodeEdge, authoringEvidenceEdge, scenarioCleanupEdge, closeAckEdge, authoringResponsesEdge, assistantEvidenceEdge, sdkProtocolEdge, sdkKernelEdge, providerClosureEdge])
    # Runtime selection is a fresh host fact, never a cached pass. The consumer
    # actually authenticates this declared output and every selected package byte.
    # Explicit provider selection stays caller-owned; missing/incompatible fails.
    let sdkRuntimeEdge = sh.shell(
      command = "python3 tests/helpers/editor_sdk_runtime.py build/editor-sdk-runtime.json",
      actionId = "isonim.authoring_runtime.sdk_closure", cacheable = false,
      extraInputs = @["tests/helpers/editor_sdk_runtime.py"],
      extraOutputs = @["build/editor-sdk-runtime.json"])
    let sdkRuntimeValidationEdge = sh.shell(
      command = "python3 tests/test_editor_sdk_runtime.py",
      actionId = "isonim.authoring_execute.sdk_runtime_validation", cacheable = false,
      after = @[sdkRuntimeEdge],
      extraInputs = @["build/editor-sdk-runtime.json", "tests/test_editor_sdk_runtime.py", "tests/helpers/editor_sdk_runtime.py"])
    let sdkNativeEdge = sh.shell(
      command = "python3 tests/test_editor_sdk_native_controls.py",
      actionId = "isonim.authoring_execute.sdk_native", cacheable = false,
      after = @[sdkRuntimeValidationEdge, sdkProtocolEdge, sdkKernelEdge],
      extraInputs = @["build/editor-sdk-runtime.json", "tests/test_editor_sdk_native_controls.py",
        "tests/helpers/editor_sdk_native_initialization.mjs", "tests/helpers/editor_sdk_runtime.py",
        "tests/helpers/editor_sdk_native_observer.mjs", "tests/helpers/editor_sdk_delivery_evidence.mjs", "tests/helpers/editor_sdk_kernel_evidence.mjs",
        "tests/helpers/editor_real_provider.py", "tests/helpers/editor_provider_wire.py", "tests/helpers/editor_provider_closure.py", "tools/agent_session_launcher.py", "prompts/ai-assistant.md"])
    discard collect("editor-authoring-runtime", @[sdkRuntimeEdge])
    discard collect("test-editor-sdk-native", @[sdkNativeEdge])
    let responseSequencingEdge = sh.shell(
      command = "python3 tests/test_editor_authoring_response_sequencing.py",
      actionId = "isonim.authoring_execute.response_sequencing", cacheable = false,
      after = @[controlCliEdge, authoringBrowserEdge, authoringResponsesEdge, assistantEvidenceEdge],
      extraInputs = @["tests/test_editor_authoring_response_sequencing.py", "tests/test_editor_scripted_terminal_fence.py", "tests/test_editor_authoring_real_gui.mjs",
        "tests/scenarios/agent-harbor/authoring-response-sequencing.yaml", "tests/helpers/editor_authoring_operations.py",
        "tests/helpers/editor_authoring_responses.py", "tests/helpers/editor_authoring_assistant_evidence.py", "tests/helpers/editor_close_ack.mjs",
        "tests/helpers/editor_scenario_runtime.py", "tests/helpers/editor_preparation_clock.py", "tests/helpers/editor_preparation_clock.mjs", "tests/helpers/editor_scenario_provider.py", "tests/helpers/editor_provider_wire.py", "tests/helpers/editor_provider_closure.py",
        "tests/helpers/editor_sdk_runtime.py", "tests/helpers/editor_process_observer.py", "tests/helpers/editor_scenario_barrier.py",
        "tools/editor_agent_env.py", "tools/editor_server.py", "build/bin/isonim", "build/editor-authoring",
        "../web-site-prototypes/grip/isonim/src", "../web-site-prototypes/grip/isonim/tools",
        "../web-site-prototypes/grip/isonim/.isonim/source-project.json"])
    discard collect("test-editor-authoring-response-sequencing", @[responseSequencingEdge])
    let authoringRealEdge = sh.shell(
      command = "python3 tests/test_editor_authoring_real.py", cacheable = false,
      actionId = "isonim.authoring_execute.real_claude",
      after = @[controlCliEdge, authoringBrowserEdge, authoringEvidenceEdge, scenarioCleanupEdge, closeAckEdge, authoringResponsesEdge, assistantEvidenceEdge, sdkNativeEdge],
      extraInputs = @["build/editor-sdk-runtime.json", "tests/test_editor_authoring_real.py", "tests/test_editor_authoring_real_gui.mjs",
        "tests/helpers/editor_sdk_runtime.py", "tests/helpers/editor_sdk_native_observer.mjs", "tests/helpers/editor_sdk_delivery_evidence.mjs", "tests/helpers/editor_sdk_kernel_evidence.mjs",
        "tests/helpers/editor_authoring_operations.py", "tests/helpers/editor_authoring_responses.py", "tests/helpers/editor_authoring_assistant_evidence.py",
        "tests/helpers/editor_authoring_evidence.py", "tests/helpers/editor_close_ack.mjs",
        "tests/helpers/editor_real_provider.py", "tests/helpers/editor_provider_wire.py", "tests/helpers/editor_provider_closure.py", "tests/helpers/editor_scenario_runtime.py", "tests/helpers/editor_preparation_clock.py", "tests/helpers/editor_preparation_clock.mjs",
        "tests/helpers/editor_process_observer.py", "prompts/ai-assistant.md",
        "tools/agent_session_launcher.py", "tools/editor_agent_env.py", "tools/editor_server.py",
        "build/bin/isonim", "build/editor-authoring", "../web-site-prototypes/grip/isonim/src",
        "../web-site-prototypes/grip/isonim/tools", "../web-site-prototypes/grip/isonim/.isonim/source-project.json"])
    discard collect("test-editor-authoring-real", @[authoringRealEdge])
    # Official private Harbor scenarios: absence of the sibling is optional;
    # provider/build/runtime failure when present remains a real failed test.
    let scenarioHostEdge = buildNimUnittest.build(
      source = "tests/test_editor_scenario_host.nim",
      binary = "build/bin/editor-scenario-host",
      defines = isonimDefines,
      paths = isonimPaths,
      actionId = "isonim.scenario_build.native_host",
      extraInputs = @["src", "tests/test_editor_scenario_host.nim"])
    testBuildActions.add(scenarioHostEdge.action)
    let scenarioNativeEdge = pythonUnittest.run(
      source = "tests/test_editor_scenarios.py",
      actionId = "isonim.scenario_execute.native",
      after = @[controlCliEdge, sourceBrowserEdge, scenarioHostEdge.action, preparationClockPythonEdge, preparationClockNodeEdge],
      extraInputs = @["tests/test_editor_scenarios.py", "tests/helpers/editor_context_evidence.py", "tests/helpers/editor_scenario_runtime.py", "tests/helpers/editor_preparation_clock.py", "tests/helpers/editor_preparation_clock.mjs",
        "tests/helpers/editor_scenario_provider.py", "tests/helpers/editor_scenario_barrier.py",
        "tests/helpers/editor_scenario_network_probe.py", "tests/helpers/editor_scenario_filesystem_probe.py", "tests/helpers/editor_scenario_registration.py", "repro.nim",
        "tests/scenarios/agent-harbor/editor-workflows.yaml", "tests/scenarios/agent-harbor/README.md", "tools/editor_server.py",
        "tools/editor_agent_env.py", "tools/agent_session_launcher.py", "prompts/ai-assistant.md", "examples/source_project", "build/bin/editor-scenario-host",
        "build/bin/isonim", "build/editor-source"])
    testExecuteActions.add(scenarioNativeEdge)
    let harborOutputModesEdge = pythonUnittest.run(
      source = "tests/test_editor_harbor_output_modes.py",
      actionId = "isonim.scenario_execute.harbor_output_modes",
      after = @[controlCliEdge, sourceBrowserEdge, preparationClockPythonEdge],
      extraInputs = @["tests/test_editor_harbor_output_modes.py", "tests/helpers/editor_scenario_runtime.py",
        "tests/helpers/editor_process_observer.py", "tests/helpers/editor_preparation_clock.py",
        "tests/helpers/editor_scenario_registration.py", "tests/helpers/editor_sdk_runtime.py",
        "tests/helpers/editor_scenario_provider.py", "tests/helpers/editor_scenario_barrier.py",
        "tests/helpers/editor_scenario_network_probe.py", "tests/helpers/editor_scenario_filesystem_probe.py",
        "tests/scenarios/agent-harbor/editor-workflows.yaml", "tools/editor_server.py", "tools/editor_agent_env.py",
        "tools/agent_session_launcher.py", "tools/build_source_catalog.py", "examples/source_project",
        "prompts/ai-assistant.md", drReviewBin, "build/bin/isonim", "build/editor-source", "repro.nim"])
    testExecuteActions.add(harborOutputModesEdge)
    discard collect("test-editor-harbor-output-modes", @[harborOutputModesEdge])
    let scenarioStressEdge = pythonUnittest.run(
      source = "tests/test_editor_scenario_stress.py",
      actionId = "isonim.scenario_execute.stream_ownership",
      after = @[controlCliEdge, sourceBrowserEdge, scenarioHostEdge.action, preparationClockPythonEdge, preparationClockNodeEdge],
      extraInputs = @["tests/test_editor_scenario_stress.py", "tests/helpers/editor_scenario_runtime.py", "tests/helpers/editor_preparation_clock.py", "tests/helpers/editor_preparation_clock.mjs",
        "tests/helpers/editor_scenario_provider.py", "tests/helpers/editor_scenario_barrier.py",
        "tests/helpers/editor_scenario_network_probe.py", "tests/helpers/editor_scenario_filesystem_probe.py", "tests/helpers/editor_scenario_registration.py", "repro.nim", "tests/scenarios/agent-harbor/editor-workflows.yaml",
        "tests/scenarios/agent-harbor/README.md", "tools/editor_server.py", "tools/editor_agent_env.py", "tools/agent_session_launcher.py", "prompts/ai-assistant.md",
        "examples/source_project", "build/bin/editor-scenario-host", "build/bin/isonim", "build/editor-source"])
    testExecuteActions.add(scenarioStressEdge)
    let scenarioGuiEdge = pythonUnittest.run(
      source = "tests/run_editor_scenarios_gui.py",
      actionId = "isonim.scenario_execute.gui",
      after = @[controlCliEdge, sourceBrowserEdge, preparationClockPythonEdge, preparationClockNodeEdge],
      extraInputs = @["tests/run_editor_scenarios_gui.py", "tests/test_editor_scenarios_gui.mjs",
        "tests/helpers/editor_scenario_runtime.py", "tests/helpers/editor_preparation_clock.py", "tests/helpers/editor_preparation_clock.mjs", "tests/helpers/editor_scenario_provider.py", "tests/helpers/editor_provider_wire.py", "tests/helpers/editor_provider_closure.py",
        "tests/helpers/editor_scenario_barrier.py", "tests/helpers/editor_scenario_network_probe.py", "tests/helpers/editor_scenario_filesystem_probe.py", "tests/helpers/editor_scenario_registration.py", "repro.nim",
        "tests/scenarios/agent-harbor/editor-workflows.yaml", "tests/scenarios/agent-harbor/README.md",
        "tools/editor_server.py", "tools/editor_agent_env.py", "tools/agent_session_launcher.py", "prompts/ai-assistant.md", "examples/source_project",
        "build/bin/isonim", "build/editor-source"])
    testExecuteActions.add(scenarioGuiEdge)

    testExecuteActions.add(pythonUnittest.run(
      source = "tests/test_editor_source_project.py",
      actionId = "isonim.source_execute.native",
      after = @[controlCliEdge],
      extraInputs = @["tests/test_editor_source_project.py", "examples/source_project", "tools/build_source_catalog.py", "build/bin/isonim"]))
    testExecuteActions.add(pythonUnittest.run(
      source = "tests/test_editor_native_acp_shutdown.py",
      actionId = "isonim.source_execute.native_acp_shutdown",
      after = @[controlCliEdge],
      extraInputs = @["tests/test_editor_native_acp_shutdown.py", "tests/helpers/editor_control_peer.py",
        "tools/editor_agent_env.py", "build/bin/isonim"]))
    testExecuteActions.add(node(
      args = @["tests/test_editor_source_gui.mjs"],
      actionId = "isonim.source_execute.gui_cli",
      after = @[controlCliEdge, sourceBrowserEdge],
      extraInputs = @["tests/test_editor_source_gui.mjs", "tests/helpers/editor_control_peer.py", "examples/source_project",
        "tools/editor_server.py", "build/bin/isonim", "build/editor-source"]))

    testExecuteActions.add(pythonUnittest.run(
      source = "tests/test_editor_agent_env.py",
      actionId = "isonim.control_execute.agent_env",
      after = @[reviewToolEdge.action],
      extraInputs = @["tools/editor_agent_env.py", "tests/test_editor_agent_env.py", drReviewBin]))
    testExecuteActions.add(pythonUnittest.run(
      source = "tests/test_editor_cli_wait.py",
      actionId = "isonim.control_execute.cli_wait",
      after = @[controlCliEdge],
      extraInputs = @["tests/test_editor_cli_wait.py", "tools/isonim_review/cmd_editor.nim", "build/bin/isonim"]))
    testExecuteActions.add(node(
      args = @["tests/test_editor_control_gui.mjs"],
      actionId = "isonim.control_execute.gui_cli",
      after = @[controlCliEdge, controlBrowserEdge],
      extraInputs = @["tests/test_editor_control_gui.mjs", "tests/helpers/editor_control_peer.py",
        "tools/editor_server.py", "tools/editor_agent_env.py", "build/bin/isonim", "build/editor-control"]))

    testExecuteActions.add(pythonUnittest.run(
      source = "tests/test_editor_server.py",
      actionId = "isonim.chat_execute.editor_server",
      after = @[reviewToolEdge.action],
      extraInputs = @["tests/test_editor_server.py", "tools/editor_server.py", "tools/editor_shutdown.json", drReviewBin]))
    testExecuteActions.add(pythonUnittest.run(
      source = "tests/test_agent_session_launcher.py",
      actionId = "isonim.chat_execute.launcher",
      extraInputs = @["tests/test_agent_session_launcher.py", "tools/agent_session_launcher.py"]))
    testExecuteActions.add(pythonUnittest.run(
      source = "tests/test_harbor_route_lifecycle.py",
      actionId = "isonim.chat_execute.route_lifecycle",
      after = @[reviewToolEdge.action],
      extraInputs = @["tests/test_harbor_route_lifecycle.py", "tests/helpers/editor_context_snapshot.nim",
        "tests/helpers/editor_context_evidence.py", "tests/helpers/editor_context_wire.nim",
        "tests/test_design_review_class_quota.nim", "tools/tailwind-extract.mjs", "package.json", "src", drReviewBin]))
    testExecuteActions.add(pythonUnittest.run(
      source = "tests/test_editor_process_observer.py",
      actionId = "isonim.chat_execute.process_observer",
      extraInputs = @["tests/test_editor_process_observer.py", "tests/helpers/editor_process_observer.py",
        "tests/helpers/editor_context_evidence.py", "tests/test_editor_harbor_scenario.py",
        "tests/helpers/editor_scenario_runtime.py", "tests/helpers/editor_sdk_runtime.py",
        "tests/helpers/editor_preparation_clock.py", "tests/helpers/editor_scenario_registration.py"]))
    # Optional private producer acceptance. With the sibling present, the built
    # official scenario provider must be configured and all real boundaries run.
    # The script delegates producer compilation/environment to the local launcher.
    testExecuteActions.add(pythonUnittest.run(
      source = "tests/test_design_review_harbor_preparation.py",
      actionId = "isonim.chat_execute.harbor_preparation",
      after = @[controlCliEdge],
      extraInputs = @["tests/test_design_review_harbor_preparation.py", "tools/isonim_review", drReviewBin, "build/bin/isonim"]))

    testExecuteActions.add(pythonUnittest.run(
      source = "tests/test_editor_harbor_scenario.py",
      actionId = "isonim.chat_execute.harbor_scenario",
      after = @[reviewToolEdge.action],
      extraInputs = @["tests/test_editor_harbor_scenario.py",
        "tests/helpers/editor_context_evidence.py",
        "tests/helpers/editor_process_observer.py",
        "tests/scenarios/agent-harbor/editor-session-continuity.yaml", drReviewBin]))

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
        # The Harbor build test imports the editor's local_harbor consumer
        # module directly, so its sources are a declared input of that edge.
        extraInputs = @["src", "db", "tests/helpers", "isonim.nimble"] &
          (if s.stem == "test_design_review_harbor_build":
            @["tools/isonim_review"] else: @[]))
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

    # Production flex-direction selection metadata prerequisite. No source/ACK
    # substitution; standard Just entries execute the strict JS guard.
    let flexMetadataHeadlessEdge = sh.shell(
      command = "just test-editor-flex-metadata-headless", cacheable = false,
      actionId = "isonim.flex_metadata_execute.headless",
      after = @[tailwindStylesEdge],
      extraInputs = @["src", "tests/test_editor_flex_metadata.nim", "tools/run_nim_js_test.py",
        "Justfile", "tests/config.nims", "config.nims", "build/tailwind-styles.json"])
    let flexMetadataBrowserEdge = sh.shell(
      command = "just editor-flex-metadata-build",
      actionId = "isonim.flex_metadata_build.browser",
      after = @[tailwindStylesEdge],
      extraInputs = @["src", "tests/helpers/editor_flex_metadata_workspace.nim",
        "tests/helpers/editor_popup_workspace.nim", "Justfile", "build/tailwind-styles.json"],
      extraOutputs = @["build/editor-flex-metadata"])
    let flexMetadataGuiEdge = sh.shell(
      command = "timeout --signal=TERM --kill-after=15s 180s \"${ISONIM_SCENARIO_NODE:-node}\" tests/test_editor_flex_metadata_gui.mjs",
      cacheable = false, actionId = "isonim.flex_metadata_execute.gui",
      after = @[flexMetadataBrowserEdge, reviewToolEdge.action],
      extraInputs = @["tests/test_editor_flex_metadata_gui.mjs", "tests/helpers/editor_control_peer.py",
        "tests/fixtures/editor_inspector_project", "tools/editor_server.py", "tools/build_source_catalog.py",
        "build/editor-flex-metadata", drReviewBin])
    testBuildActions.add(flexMetadataBrowserEdge)
    testExecuteActions.add(flexMetadataHeadlessEdge)
    testExecuteActions.add(flexMetadataGuiEdge)
    discard collect("test-editor-flex-metadata", @[flexMetadataHeadlessEdge, flexMetadataGuiEdge])
    discard collect("test-editor-flex-metadata-headless", @[flexMetadataHeadlessEdge])
    discard collect("test-editor-flex-metadata-source", @[flexMetadataGuiEdge])

    # JS execute/build halves are ALSO folded into a dedicated ``js-test`` /
    # ``js-test-builds`` target so ``repro build js-test`` materialises just
    # the JS-backend closure (tailwind extract + ``nim js`` compiles + node
    # runs) — the reprobuild-native analogue of the ``Justfile`` ``test-js``
    # recipe — without pulling the native + design-review corpus.

    # Remaining section/source parity: real source/compiler/browser boundaries.
    let c4aCompoundEdge = sh.shell(
      command = "timeout --signal=TERM --kill-after=15s 180s \"${ISONIM_SCENARIO_NODE:-node}\" tests/test_editor_inspector_compounds_gui.mjs",
      cacheable = false, actionId = "isonim.c4a_execute.compounds",
      after = @[inspectorBrowserEdge, reviewToolEdge.action],
      extraInputs = @["tests/test_editor_inspector_compounds_gui.mjs", "tests/helpers/editor_control_peer.py",
        "tests/fixtures/editor_inspector_project", "tools/editor_server.py", "tools/build_source_catalog.py",
        "build/editor-inspector", drReviewBin])
    let c4aGestureEdge = sh.shell(
      command = "timeout --signal=TERM --kill-after=15s 180s \"${ISONIM_SCENARIO_NODE:-node}\" tests/test_editor_inspector_gestures_gui.mjs",
      cacheable = false, actionId = "isonim.c4a_execute.gestures",
      after = @[inspectorBrowserEdge, reviewToolEdge.action],
      extraInputs = @["tests/test_editor_inspector_gestures_gui.mjs", "tests/helpers/editor_control_peer.py",
        "tests/fixtures/editor_inspector_project", "tools/editor_server.py", "tools/build_source_catalog.py",
        "build/editor-inspector", drReviewBin])
    let c4aColorEdge = sh.shell(
      command = "timeout --signal=TERM --kill-after=15s 180s \"${ISONIM_SCENARIO_NODE:-node}\" tests/test_editor_color_parity.mjs",
      cacheable = false, actionId = "isonim.c4a_execute.color_parity",
      after = @[tailwindStylesEdge],
      extraInputs = @["src", "tests/test_editor_color_parity.mjs", "tests/helpers/editor_color_validation.nim",
        "config.nims", "tests/config.nims", "build/tailwind-styles.json"])
    var c4aGuiActions = @[c4aCompoundEdge, c4aGestureEdge, c4aColorEdge]
    for name in ["test_editor_source_style_gui", "test_editor_source_style_values_gui"]:
      let gripEdge = sh.shell(
        command = "timeout --signal=TERM --kill-after=15s 180s \"${ISONIM_SCENARIO_NODE:-node}\" tests/" & name & ".mjs",
        cacheable = false, actionId = "isonim.c4a_execute." & name,
        after = @[tailwindStylesEdge, reviewToolEdge.action],
        extraInputs = @["src", "tests/" & name & ".mjs", "tests/helpers/editor_source_style_workspace.nim",
          "tests/helpers/editor_control_peer.py", "tools/editor_server.py", "tools/build_source_catalog.py",
          "../web-site-prototypes/grip/isonim", "build/tailwind-styles.json", drReviewBin])
      c4aGuiActions.add(gripEdge)
    for action in c4aGuiActions: testExecuteActions.add(action)

    var jsBuildActions: seq[BuildActionDef] = @[tailwindStylesEdge]
    var jsExecuteActions: seq[BuildActionDef] = @[]
    for stem in isonimJsTestSpecs:
      let jsSource = "tests/" & stem & ".nim"
      let jsOut = "build/js-test/" & stem & ".js"
      let pureContent = stem.startsWith("test_content_")
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
        after = (if pureContent: @[] else: @[tailwindStylesEdge]),
        extraInputs = @["src", "isonim.nimble"] & (if pureContent: @[] else: @["build/tailwind-styles.json"]) & (if stem == "test_editor_renderer_boundaries": @["tests/test_editor_source_scope_labels.nim", "tests/test_editor_shell_chat_lifetime.nim", "tests/helpers/editor_source_scope_label_cases.nim"] else: @[]))
      testBuildActions.add(jsCompileEdge)
      jsBuildActions.add(jsCompileEdge)
      let guardedC2 = stem in ["test_effects", "test_editor_widget_property_row", "test_editor_color_popover", "test_editor_section_fill", "test_editor_source_scope_row"]
      let jsExecuteEdge =
        if stem in ["test_editor_shell_views", "test_editor_renderer_boundaries", "test_editor_preview_mount", "test_editor_source_markup", "test_editor_workspace_refresh", "test_editor_source_write_receipts", "test_editor_save_pipeline", "test_editor_act_time_refusals", "test_editor_inspector_controls", "test_editor_reset_removal", "test_editor_section_raw_css"] or guardedC2 or stem in ["test_editor_chat_view_lifetime", "test_editor_chat_tabs_vm", "test_editor_chat_activity"] or stem == "test_editor_color_picker" or stem in ["test_editor_section_source", "test_editor_section_appearance", "test_editor_section_component_props", "test_editor_section_layout", "test_editor_section_position", "test_editor_section_stroke", "test_editor_section_effects"]:
          sh.shell(command = "python3 tools/run_nim_js_test.py " & jsOut, cacheable = false,
            actionId = "isonim.js_execute." & stem, after = @[jsCompileEdge],
            extraInputs = @[jsOut, "tools/run_nim_js_test.py"])
        else:
          node(args = @[jsOut], actionId = "isonim.js_execute." & stem,
            after = @[jsCompileEdge], extraInputs = @[jsOut])
      if stem == "test_editor_shell_views": currentShellActions.add(jsExecuteEdge)
      if stem == "test_editor_renderer_boundaries": rendererBoundaryActions.add(jsExecuteEdge)
      if stem == "test_editor_preview_mount": previewMountActions.add(jsExecuteEdge)
      if stem == "test_editor_source_markup": inspectorFoundationActions.add(jsExecuteEdge)
      if guardedC2: c2HeadlessActions.add(jsExecuteEdge)
      if stem in ["test_editor_color_picker", "test_editor_color_popover"]:
        c3HeadlessActions.add(jsExecuteEdge)
      testExecuteActions.add(jsExecuteEdge)
      if stem in ["test_editor_chat_view_lifetime", "test_editor_chat_tabs_vm", "test_editor_chat_activity"]: chatLifetimeActions.add(jsExecuteEdge)
      if stem in ["test_editor_section_source", "test_editor_source_scope_row", "test_editor_section_component_props"]: sourceLabelActions.add(jsExecuteEdge)
      if stem in ["test_editor_section_appearance", "test_editor_section_component_props", "test_editor_section_layout", "test_editor_section_position", "test_editor_section_stroke", "test_editor_section_effects"]: c4aHeadlessActions.add(jsExecuteEdge)
      jsExecuteActions.add(jsExecuteEdge)
      if pureContent: contentJsActions.add(jsExecuteEdge)
      if stem in ["test_editor_color_popover", "test_signals"]: popupHeadlessActions.add(jsExecuteEdge)

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

    let sourceLabelsBrowserEdge = sh.shell(
      command = "just editor-source-labels-build", cacheable = false,
      actionId = "isonim.source_labels_build.browser", after = @[tailwindStylesEdge],
      extraInputs = @["src", "tests/helpers/editor_source_scope_browser.nim", "Justfile", "build/tailwind-styles.json"],
      extraOutputs = @["build/editor-source-labels"])
    let sourceLabelsGuiEdge = sh.shell(
      command = "timeout --signal=TERM --kill-after=15s 180s \"${ISONIM_SCENARIO_NODE:-node}\" tests/test_editor_source_scope_gui.mjs",
      cacheable = false, actionId = "isonim.source_labels_execute.gui", after = @[sourceLabelsBrowserEdge],
      extraInputs = @["tests/test_editor_source_scope_gui.mjs", "build/editor-source-labels"])
    testBuildActions.add(sourceLabelsBrowserEdge)
    testExecuteActions.add(sourceLabelsGuiEdge)
    discard collect("test-editor-source-labels-gui", @[sourceLabelsGuiEdge])
    let previewMountBrowserEdge = sh.shell(
      command = "just editor-preview-mount-build", cacheable = false,
      actionId = "isonim.preview_mount_build.browser", after = @[tailwindStylesEdge],
      extraInputs = @["src", "tests/helpers/editor_preview_mount_browser.nim", "Justfile", "build/tailwind-styles.json"],
      extraOutputs = @["build/editor-preview-mount"])
    let previewMountGuiEdge = sh.shell(
      command = "timeout --signal=TERM --kill-after=15s 180s \"${ISONIM_SCENARIO_NODE:-node}\" tests/test_editor_preview_mount_gui.mjs",
      cacheable = false, actionId = "isonim.preview_mount_execute.gui", after = @[previewMountBrowserEdge],
      extraInputs = @["tests/test_editor_preview_mount_gui.mjs", "build/editor-preview-mount"])
    testBuildActions.add(previewMountBrowserEdge)
    testExecuteActions.add(previewMountGuiEdge)
    discard collect("test-editor-preview-mount", previewMountActions)
    discard collect("test-editor-preview-mount-gui", @[previewMountGuiEdge])
    let rendererBoundaryBrowserEdge = sh.shell(
      command = "just editor-renderer-boundaries-build", cacheable = false,
      actionId = "isonim.renderer_boundary_build.browser", after = @[tailwindStylesEdge],
      extraInputs = @["src", "tests/helpers/editor_renderer_boundary_browser.nim", "Justfile", "build/tailwind-styles.json"],
      extraOutputs = @["build/editor-renderer-boundaries"])
    let rendererBoundaryGuiEdge = sh.shell(
      command = "timeout --signal=TERM --kill-after=15s 180s \"${ISONIM_SCENARIO_NODE:-node}\" tests/test_editor_renderer_boundary_gui.mjs",
      cacheable = false, actionId = "isonim.renderer_boundary_execute.gui", after = @[rendererBoundaryBrowserEdge],
      extraInputs = @["tests/test_editor_renderer_boundary_gui.mjs", "build/editor-renderer-boundaries"])
    testBuildActions.add(rendererBoundaryBrowserEdge)
    testExecuteActions.add(rendererBoundaryGuiEdge)
    discard collect("test-editor-shell-current", currentShellActions)
    discard collect("test-editor-renderer-boundaries", rendererBoundaryActions)
    discard collect("test-editor-renderer-boundaries-gui", @[rendererBoundaryGuiEdge])
    let chatLifetimeBrowserEdge = sh.shell(
      command = "just editor-chat-lifetime-build", cacheable = false,
      actionId = "isonim.chat_lifetime_build.browser", after = @[tailwindStylesEdge],
      extraInputs = @["src", "tests/helpers/editor_chat_lifetime_browser.nim", "Justfile", "build/tailwind-styles.json"],
      extraOutputs = @["build/editor-chat-lifetime"])
    let chatLifetimeGuiEdge = sh.shell(
      command = "timeout --signal=TERM --kill-after=15s 180s \"${ISONIM_SCENARIO_NODE:-node}\" tests/test_editor_chat_lifetime_gui.mjs",
      cacheable = false, actionId = "isonim.chat_lifetime_execute.gui", after = @[chatLifetimeBrowserEdge],
      extraInputs = @["tests/test_editor_chat_lifetime_gui.mjs", "build/editor-chat-lifetime"])
    testBuildActions.add(chatLifetimeBrowserEdge)
    testExecuteActions.add(chatLifetimeGuiEdge)
    discard collect("test-editor-chat-lifetime-headless", chatLifetimeActions)
    discard collect("test-editor-chat-lifetime-gui", @[chatLifetimeGuiEdge])
    discard collect("test-editor-source-labels", sourceLabelActions)
    discard collect("test-editor-c4a-headless", c4aHeadlessActions)
    discard collect("test-editor-c4a-compounds", @[c4aCompoundEdge])
    discard collect("test-editor-c4a-gestures", @[c4aGestureEdge])
    discard collect("test-editor-c4a-color", @[c4aColorEdge])
    discard collect("test-editor-c4a-grip", c4aGuiActions[3 .. ^1])
    discard collect("test-editor-c4a", c4aHeadlessActions & c4aGuiActions)
    discard collect("test-editor-c3-headless", c3HeadlessActions)
    discard collect("test-editor-c3-source", @[c3GuiEdge])
    discard collect("test-editor-c3", c3HeadlessActions & @[c3GuiEdge, popupGuiEdge])
    discard collect("test-editor-c2-headless", c2HeadlessActions)
    discard collect("test-editor-c2-source", c2SourceActions)
    discard collect("test-editor-c2-lifetime", @[popupOwnerHmrEdge, popupGeometryEdge, popupSelectionRestoreEdge])
    discard collect("test-editor-c2", c2HeadlessActions & c2SourceActions & @[popupOwnerHmrEdge, popupGeometryEdge, popupSelectionRestoreEdge, popupGuiEdge])
    discard collect("test-editor-popup", popupHeadlessActions & @[popupOwnerHmrEdge, popupGeometryEdge, popupSelectionRestoreEdge, popupGuiEdge])
    discard collect("test-editor-inspector", currentShellActions & popupHeadlessActions & inspectorNativeSourceActions & inspectorFoundationActions & c2HeadlessActions & c3HeadlessActions & c4aHeadlessActions & c2SourceActions & c4aGuiActions & sourceLabelActions & chatLifetimeActions & rendererBoundaryActions & previewMountActions & @[flexMetadataHeadlessEdge, flexMetadataGuiEdge, sourceLabelsGuiEdge, chatLifetimeGuiEdge, rendererBoundaryGuiEdge, previewMountGuiEdge, c3GuiEdge, popupOwnerHmrEdge, popupGeometryEdge, popupSelectionRestoreEdge, popupGuiEdge, sourceMetadataEdge])
    # Keep the original inventory order/action IDs. This additional real
    # resource case is a separate required execute edge, never a shell rebuild.
    # Repro fixtures compile outside private /tmp; Just handles temporary
    # compiler checkouts before its own build recipes begin.
    let scenarioResourcesEdge = pythonUnittest.run(
      source = "tests/test_editor_scenario_resources.py",
      actionId = "isonim.scenario_execute.resource_visibility",
      after = @[controlCliEdge, sourceBrowserEdge, scenarioHostEdge.action, preparationClockPythonEdge, preparationClockNodeEdge],
      extraInputs = @["tests/test_editor_scenario_resources.py", "tests/helpers/editor_scenario_runtime.py",
        "tests/helpers/editor_preparation_clock.py", "tests/helpers/editor_preparation_clock.mjs",
        "tests/helpers/editor_process_observer.py", "tests/helpers/editor_context_evidence.py",
        "tests/helpers/editor_scenario_provider.py", "tests/helpers/editor_scenario_barrier.py",
        "tests/helpers/editor_scenario_network_probe.py", "tests/helpers/editor_scenario_filesystem_probe.py", "tests/helpers/editor_scenario_registration.py", "repro.nim",
        "tests/scenarios/agent-harbor/editor-workflows.yaml", "tools/editor_server.py",
        "tools/editor_agent_env.py", "tools/agent_session_launcher.py", "prompts/ai-assistant.md",
        "examples/source_project", "build/bin/editor-scenario-host", "build/bin/isonim", "build/editor-source"])
    testExecuteActions.add(scenarioResourcesEdge)
    discard collect("test-editor-scenarios-native", @[scenarioNativeEdge, scenarioResourcesEdge])
    discard collect("test-editor-scenarios-stress", @[scenarioStressEdge])
    discard collect("test-editor-scenarios-gui", @[scenarioGuiEdge])
    discard collect("test-editor-scenarios", @[scenarioNativeEdge, scenarioResourcesEdge, scenarioStressEdge, scenarioGuiEdge])
    # The mutation gate intentionally compiles a disposable modified source
    # tree at runtime, so it is a test boundary rather than a build prerequisite.
    let proseMutation = sh.shell(
      command = "bash tests/test_content_prose_mutation.sh", cacheable = false,
      actionId = "isonim.content_prose_mutation",
      extraInputs = @["tests/test_content_prose_mutation.sh", "tests/test_content_prose.nim",
        "src/isonim/content/markdown.nim", "src/isonim/content/anchors.nim",
        "src/isonim/content/prose.nim", "src/isonim/ssr/escape.nim"])
    testExecuteActions.add(proseMutation)
    discard collect("test-content-prose-mutation", @[proseMutation])
    discard collect("test-content", contentNativeActions & contentJsActions & @[proseMutation])
    discard collect("test-content-c", contentNativeActions)
    discard collect("test-content-js", contentJsActions)
    discard collect("test", testExecuteActions)
    discard collect("test-builds", testBuildActions)
    discard collect("js-test", jsExecuteActions)
    discard collect("js-test-builds", jsBuildActions)
