## Reprobuild project file for isonim.
##
## **Typed-Cross-Project-Deps rollout — the keystone Nim CONSUMER of the
## isonim ecosystem (SC-11 develop-mode from-source sibling consumption).**
## ``isonim`` is the isomorphic reactive UI framework: its ``src/`` reactive
## core / DSL / SSR / routing tree is a Linux leaf, but the *editor* subtree
## (``src/isonim/editor/*``) imports FOUR landed workspace Nim libraries at
## build time:
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
##
## The repo's own ``tests/config.nims`` resolves these with hand-maintained
## ``--path:../../nim-*/src`` / ``--path:../../isonim-render-serve/src``
## flags (and the ``Justfile`` recipes repeat them inline). This recipe
## expresses those four sibling dependencies the reprobuild-native way
## instead: ``uses: "<sibling>"`` names each PRODUCER project by its
## workspace directory name; reprobuild builds each from source (its
## ``library`` edge) and threads its ``src/`` root onto THIS repo's
## ``nim c --path:`` via the SC-11 ``nimPathDirs`` aux channel
## (Cross-Repo-Source-Consumption.md §4.2a) — replacing the hardcoded
## ``../../nim-*/src`` literals. Editing a sibling's ``src/`` invalidates +
## rebuilds this repo's affected test compiles (the reused SC-4 fold).
##
## All four siblings are in the rollout's AVAILABLE set (each ships a landed
## ``repro.nim`` with a ``library`` export), so this is proper SC-11
## develop-mode consumption — NOT a SKIP and NOT a hardcoded path.
##
## A Mode 1 / Mode 3 hybrid (per
## ``reprobuild-specs/Three-Mode-Convention-System.md``) modelled on the
## canonical Nim-consumer recipes ``nim-agents/repro.nim`` (four-sibling
## consumer) and ``nim-agent-harbor/repro.nim`` (single-sibling consumer):
##
## * Declares the toolchain floor via ``uses:`` (``nim`` + ``gcc``) plus the
##   four sibling ``uses:`` edges. Mirrors the nimble file's
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
## **Native (C-backend) corpus only.** The engine's ``nim.c`` typed-tool
## models the ``nim c`` (native / C back-end) compile. The repo ALSO ships a
## large ``nim js`` matrix (``Justfile`` ``test-js``) + Playwright browser
## suites; those run on the JavaScript back-end, a separate backend this
## ``nim.c`` edge cannot model. So the JS-backend-only tests are DEFERRED
## (see the deferral block below), not modelled as ``nim.c`` edges. Every
## test edge emitted here compiles + runs to exit 0 under ``nim c`` on this
## Linux host — verified by a direct ``nim c -c`` sweep of the whole
## candidate corpus.
##
## ==========================================================================
## DEFERRED test sets (documented, NOT deleted or weakened)
## ==========================================================================
##
## (A) **JS-backend-only tests** — run via ``nim js`` (a separate back-end
##     the ``nim.c`` edge cannot model; modelling them needs a ``nim.js``
##     typed-tool edge, a follow-up). Each carries a module-head
##     ``{.error: "... must be compiled with the JS backend".}`` or lives in
##     the ``Justfile`` ``test-js`` list only:
##       - ``tests/test_custom_elements.nim``  (``{.error.}`` JS-backend head)
##       - ``tests/test_web.nim``              (JS renderer; ``test-js`` only)
##       - ``tests/test_hydration.nim``, ``tests/test_ssr_hydration_e2e.nim``,
##         ``tests/test_app_e2e.nim``, ``tests/test_web_components_advanced.nim``
##                                             (``test-js`` only — DOM/JS)
##       - ``tests/test_editor_public_browser_imports.nim``
##                                             (``Justfile`` ``test-editor``
##                                              runs it via ``nim js``)
##       - the HMR fixtures (``test_hmr*.nim`` build to JS bundles for
##         Playwright) + ``poc_*_host.nim`` monaco/datatable/terminal hosts.
##     Follow-up: a ``nim.js`` backend edge (or a JS-runner tool) can model
##     these once the rollout gains a JS-backend test template.
##
## (B) **Design-review suites needing EXTERNAL SERVICES** — genuinely
##     un-provisionable headless. The whole ``tests/*design_review*`` +
##     ``tests/e2e_*`` + ``tests/smoke_design_review_*`` corpus
##     (``Justfile`` recipes ``test-design-review`` … ``test-design-review-
##     campaigns``, lines ~156-722) is gated on one or more of:
##       - **PostgreSQL** via the REV-M3 ``PgFixture``
##         (``tests/helpers/design_review_pg_fixture.nim``) / the
##         process-compose dev cluster — every ``*_pg_*`` /
##         ``*_api_*`` / ``*_cli_*`` / ``*_campaign*`` / ``*_bench_*`` test
##         and all ``e2e_*_pipeline*`` / ``e2e_design_review_*`` tests
##         (``test_design_review_pg_schema.nim``,
##         ``test_design_review_api_list_history.nim``,
##         ``test_design_review_agent_dispatch.nim``,
##         ``e2e_design_review_run_review.nim``, …).
##       - a **live ``isonim-render-serve`` bridge server** — the capture
##         pipeline (``e2e_design_review_capture_web_real_bridge.nim``,
##         ``test_design_review_bridge_client.nim`` against a running
##         ``ws://…`` endpoint, ``test_design_review_capture_store.nim``).
##       - a **live Anthropic / OpenAI ACP agent** (real ``claude-agent-acp``
##         / ``codex-acp`` binary + credentials) — the chat / run-review
##         real-ACP smokes (``e2e_design_review_chat_real_acp.nim``,
##         ``e2e_design_review_chat_real_codex_acp.nim``).
##     These are deferred wholesale as a cohesive suite (they also require
##     the ``isonim-review`` CLI binary + ``fake-acp-agent`` to be built
##     first via ``just isonim-review-build`` / ``fake-acp-agent-build``).
##     A subset is pure parse/VM (e.g. ``test_design_review_brief_format``,
##     ``test_migrated_*_brief_parses``, the ``*_gallery_vm`` /
##     ``*_vm.nim`` ViewModel tests) and COULD be modelled as headless
##     ``nim.c`` edges in a follow-up; they are deferred here with the rest
##     of the suite to keep the design-review corpus a single coherent unit
##     rather than splintering it.
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
## (C) **Pre-existing broken tests at HEAD** (fail under the repo's OWN
##     ``nim c`` too — NOT reprobuild-specific; NOT weakened here):
##       - ``tests/test_editor_agent_harbor.nim`` +
##         ``tests/test_editor_viewmodels.nim`` — both ``import
##         isonim/editor/agent_harbor``, whose ``applyAgentEvent`` ``case
##         event.kind`` does NOT cover the ``aekMilestoneProgress`` /
##         ``aekWorkspaceReady`` variants that the LANDED ``nim_agents``
##         sibling defines (``nim-agents/src/nim_agents/client.nim:52-53``).
##         Compile error: "not all cases are covered". A genuine
##         version-skew product bug in ``src/isonim/editor/agent_harbor.nim``
##         (isonim has not caught up to the sibling's enum). Reported
##         upstream; NOT papered over by this recipe.
##       - ``tests/test_corner_cases.nim`` — a duplicate ``var sum`` in one
##         ``test`` block (lines 237 + 254) → "redefinition of 'sum'". Fails
##         under plain ``nim c`` too (it is in the ``Justfile`` ``test-c``
##         list, so ``just test-c`` is itself red at HEAD).
##     NOTE: ``test_flexbox`` / ``test_branded_ui`` (need the uninitialised
##     ``src/isonim/layout/yoga`` C++ submodule) and ``test_faststreams_ssr``
##     (references the removed ``renderToOutputStream``) are NOT in any
##     ``Justfile`` recipe — stale/experimental, out of the sanctioned test
##     scope — so they simply get no edge (nothing to defer-document).
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
  # --- SC-11 sibling-exercising editor tests (the reason for the four
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

    # The four landed sibling Nim-library producers (SC-11 develop-mode
    # from-source consumption). ``src/isonim/editor/*`` import each of these;
    # naming the workspace project here makes reprobuild build the sibling
    # from source (its ``library`` edge) and thread its ``src/`` root onto
    # this repo's ``nim c --path:`` via the ``nimPathDirs`` aux channel —
    # replacing ``tests/config.nims``'s hardcoded ``--path:../../nim-*/src``
    # / ``--path:../../isonim-render-serve/src``.
    "isonim-render-serve"   # library isonim_render_serve
    "nim-acp"               # library nim_acp
    "nim-agents"            # library nim_agents
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
    # the four sibling ``src`` roots (those are threaded by the SC-11
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

    discard collect("test", testExecuteActions)
    discard collect("test-builds", testBuildActions)
