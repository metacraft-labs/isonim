# IsoNim Agent Instructions

IsoNim is an isomorphic reactive UI framework for Nim. It targets both native
Nim and JavaScript, provides a Solid-style reactive core, a Nim DSL for UI
construction, SSR/hydration support, routing/server-function experiments, and
the IsoNim Editor.

## Environment

Run commands through the repo dev shell:

```sh
repro exec -- <command>
```

This repo is used inside the `~/metacraft` multi-repo workspace. Several editor
and browser tests depend on sibling repos such as `metacraft-web`,
`nim-everywhere`, `nim-acp`, `nim-agent-harbor`, and `nim-agents`; do not vendor
or duplicate sibling code.

## Project Structure

- `src/isonim/core` contains the reactive runtime: signals, computations,
  owners, effects, batching, resources, and scheduling.
- `src/isonim/dsl` contains the typed `ui:` DSL. Prefer natural Nim control
  flow (`if`, `for`) inside the DSL. Deprecated helper forms should only remain
  as compatibility shims with strong migration messages.
- `src/isonim/renderers`, `src/isonim/web`, and `src/isonim/ssr` contain target
  renderers, browser bindings, server rendering, and hydration support.
- `src/isonim/routing` and `src/isonim/server` contain routing, file routes,
  server functions, and data-loading experiments.
- `src/isonim/editor` contains the IsoNim Editor framework: ViewModels, shared
  editor types, project workspace contracts, browser views, source-edit
  adapters, vector editor integration, and AI/agent integration hooks.
- `examples/wanderlust` is the built-in example project used by the editor
  tests. Keep it working while changing editor framework behavior.
- `tests` contains Nim unit and integration tests for native and JS targets.
- `tests/browser` contains Playwright tests for the packaged editor and the
  metacraft-web consumer integration.
- `docs` contains repo-local design notes. Cross-project specs and milestones
  live outside this repo, usually in `codetracer-specs`.

## Common Commands

Use `repro exec --` for all of these:

```sh
just test              # native + JS framework tests
just test-c            # native framework tests
just test-js           # JS framework tests
just test-dsl          # DSL and SSR DSL tests
just test-tailwind-loader # C/JS/NimScript map checks; POSIX adds permissions/links
just test-tailwind-loader-nix # explicit pinned Nix sandbox packaging gate
just test-ssr          # server rendering and round-trip tests
just test-editor       # headless editor/ViewModel/release-gate tests
just editor-build      # build the packaged IsoNim Editor
just editor-serve      # build and serve the editor at localhost:8090
just test-browser-editor-example
just test-browser-editor-consumer
just test-browser-editor
just core-bench        # reactive-core micro-benchmark (JS, node), one line per case
just size-check        # benchmark app main.js raw/min/gzip vs benchmarks/baseline.json
just core-gate-bench   # both; run with test-c and test-js when the core changes
just check-design-notes # core doc comments complete, nim doc clean (+ self-test)
just bench-ab <rev-a> <rev-b> # browser suite (js-framework-benchmark), A/B interleaved
```

`just bench-ab` (Linux; the dev shell provides `chromium`) builds the
benchmark app at both revisions in throwaway worktrees, then runs the
CPU, memory and size/first-paint benchmarks of the pinned
js-framework-benchmark runner for both builds and `keyed/solid`, alternating
on one host, and prints median, spread and a noise verdict per benchmark
(rule in `benchmarks/bench_ab_report.py`). A timing or memory metric reads
slower or faster only when its Mann-Whitney p, Holm-Bonferroni adjusted over
all the timing and memory metrics of the run, is below 0.01 and the medians
differ by 5 % or more; the report prints the raw and the adjusted p. Sizes
are compared exactly. It exits 1 when B is slower beyond noise or its bundle
is larger, and 2 when a selected benchmark has no result.
`BENCH_AB_ROUNDS` (6) and `BENCH_AB_COUNT` (5) set the sample counts (30 per
build and metric, 90 for select row); `BENCH_AB_BENCHMARKS` narrows the set
(for example `04_`); `BENCH_AB_PATCH_B=<file>` measures an uncommitted change
on top of B. Results go to `benchmarks/results/ab-*/` (ignored). Example:
`just bench-ab 5a35eb01f8 origin/agents`, or
`repro exec -- just bench-ab 5a35eb01f8 origin/agents` when direnv has not
loaded the dev shell (for example because `.envrc` is blocked). The full
suite has run end to end this way: about 2 h 15 min for the default 6 rounds
on a 32-CPU Linux host. A run of one revision against itself reads noise or
equal on every row, and a busy loop added to select is flagged slower. Under
host load the spreads are wide, so only large differences are detectable;
read the IQRs before reading a "noise" verdict as "equal".

Chromium is launched with its sandbox (no `--no-sandbox`). Start the run
outside any `LD_PRELOAD` tracer that interposes `_exit`, such as a recorded
agent session's command-trace shim: the sandbox's helper is a `clone` child
without thread-local storage, so a hook that reads a thread-local in `_exit`
crashes it, and the zygote aborts every launch
(`zygote_host_impl_linux.cc` "Check failed"). `env -u LD_PRELOAD` does not
help when the tracer re-adds itself to children; use a plain login shell.

Focused editor checks used frequently:

```sh
repro exec -- nim c -r tests/test_editor_viewmodels.nim
repro exec -- nim c -r tests/test_editor_shell_views.nim
repro exec -- bash -lc 'cd tests/browser && npx playwright test --project=metacraft-web-editor'
```

## Server functions, the route manifest and SSR hydration against nginx

`just test-nginx` runs server functions over HTTP, the typed route manifest
and the SSR -> hydrate -> interact round trip against real nginx with the
real `ngx-isonim` module (the sibling checkout, built in its own dev shell,
so it needs nix): the fixture is `tests/nginx` (see its README), the tests
are `tests/test_route_manifest.nim`, the `nginx-rpc` and `ssr-hydration`
Playwright projects and `tests/nginx/run_mutants.sh`. It is not part of
`just test`.

## Browser tests

`tests/browser` holds 98 Playwright tests in 10 spec files. They are runnable
from a clean checkout after two one-time steps, both of which reach the
network and so are not done by `just`:

```sh
git submodule update --init --depth 1 src/isonim/layout/yoga
repro exec -- just browser-test-install
```

The submodule is the load-bearing one: `.gitmodules` declares
`src/isonim/layout/yoga` and nothing initialises it, and without it
`repro exec` itself fails — which is also what puts node on PATH, since there
is no ambient node.

Then:

```sh
repro exec -- just test-browser-all     # build every artifact, run 51 tests
repro exec -- just test-browser-smoke   # the subset CI gates on
```

`playwright.config.ts` fails with a message naming the missing artifact and
the `just` recipe that builds it, rather than skipping the project. Ports,
the `metacraft-web` sibling requirement, and the currently-red tests (with
their diagnoses) are documented in `tests/browser/README.md`. `.github/
workflows/browser-tests.yml` runs a fast subset on every push to `dev`,
`stable` and `main` and on pull requests into them (never on `agents`, which
has no CI), and the full in-repo suite nightly.

Before running metacraft-web consumer browser tests, rebuild the consumer bundle
from the sibling repo when the editor framework or workspace integration
changed:

```sh
(cd ../metacraft-web && repro exec -- just build-back-office-editor)
```

## Development Conventions

- Keep ViewModels and editor contracts headless and testable. Browser views
  should render and bind controls; project behavior belongs in workspace
  contracts or consumer repos.
- Preserve the framework/consumer boundary. Generic editor behavior belongs in
  `isonim`; metacraft-specific stories, schemas, preview metadata, and source
  adapters belong in `metacraft-web`.
- For editor work, prefer headless ViewModel tests first. Use Playwright for
  browser-only behavior such as iframe previews, selection overlays, source
  bridge integration, layout, and visual affordances.
- Do not weaken tests by skipping or loosening assertions to make a milestone
  pass. Fix the behavior or update the spec when requirements change.
- Use real package and sibling-repo mechanisms rather than copying code between
  repos.
- Generated test binaries and browser artifacts should not be committed.

## Specs

Repo-local docs may live in `docs`. Cross-project specs, milestones and
status files live in the specs repo, not here — the workspace root's generated
repo list says which one and what is in it, so this file does not name it.

When user requests refine editor behavior, check the relevant spec first. If the
request changes the intended behavior, update the spec in the specs repo in the
same change set.
