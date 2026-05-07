# IsoNim Agent Instructions

IsoNim is an isomorphic reactive UI framework for Nim. It targets both native
Nim and JavaScript, provides a Solid-style reactive core, a Nim DSL for UI
construction, SSR/hydration support, routing/server-function experiments, and
the IsoNim Editor.

## Environment

Run commands through the repo dev shell:

```sh
direnv exec ~/metacraft/isonim <command>
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

Use `direnv exec ~/metacraft/isonim` for all of these:

```sh
just test              # native + JS framework tests
just test-c            # native framework tests
just test-js           # JS framework tests
just test-dsl          # DSL and SSR DSL tests
just test-ssr          # server rendering and round-trip tests
just test-editor       # headless editor/ViewModel/release-gate tests
just editor-build      # build the packaged IsoNim Editor
just editor-serve      # build and serve the editor at localhost:8090
just test-browser-editor-example
just test-browser-editor-consumer
just test-browser-editor
```

Focused editor checks used frequently:

```sh
direnv exec ~/metacraft/isonim nim c -r tests/test_editor_viewmodels.nim
direnv exec ~/metacraft/isonim nim c -r tests/test_editor_shell_views.nim
direnv exec ~/metacraft/isonim bash -lc 'cd tests/browser && npx playwright test --project=metacraft-web-editor'
```

Before running metacraft-web consumer browser tests, rebuild the consumer bundle
from the sibling repo when the editor framework or workspace integration
changed:

```sh
direnv exec ~/metacraft/metacraft-web just build-back-office-editor
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

Repo-local docs may live in `docs`, but cross-project specs, milestones, and
status files should stay in the specs repos. IsoNim Editor specs are maintained
under `codetracer-specs/Front-Ends/IsoNim/`.

When user requests refine editor behavior, check the relevant spec first. If the
request changes the intended behavior, update the spec in the specs repo in the
same change set.
