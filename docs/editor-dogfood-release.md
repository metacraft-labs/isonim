# IsoNim Editor Maturity Gate Guide

This document is the maturity gate companion for
`docs/editor-feature-matrix.json`. The matrix is machine checked by
`tests/test_editor_release_gate.nim`; update both when editor functionality or
required coverage changes.

M45 promotes the core editor workflows to a mature dogfood release gate for the
IsoNim example project and the metacraft-web consumer workspace. A row marked
`functional` means the behavior is real and tested; it does not mean the
workflow is Figma-grade. A row may only be marked `figma_grade` after it has
dense and discoverable UI, keyboard coverage, browser tests for
pointer/focus/iframe/canvas behavior, visual assertions, no placeholder UI, no
mock-only completion, and no weak skipped/only tests. `validated_in_metacraft`
is reserved for Figma-grade workflows that also pass the metacraft-web consumer
matrix for the same behavior.

## Launch

Framework contributors can launch the packaged example editor with:

```sh
direnv exec /home/zahary/metacraft/isonim just editor-build
direnv exec /home/zahary/metacraft/isonim just editor-serve
```

Metacraft runs the same editor package with a consumer-owned workspace:

```sh
direnv exec /home/zahary/metacraft/metacraft-web just build-back-office-editor
direnv exec /home/zahary/metacraft/metacraft-web just run-back-office-editor-dev
```

The metacraft-web editor test matrix is project-owned and can be run directly:

```sh
direnv exec /home/zahary/metacraft/metacraft-web just run-back-office-editor-test-matrix
```

## Public Imports

Native and build-time workspace code should import only:

```nim
import isonim/editor
```

Browser entry points can additionally import:

```nim
import isonim/editor/browser
```

Consumer projects should not import `isonim/editor/viewmodels`,
`isonim/editor/types`, `isonim/editor/workspace`, editor view modules, or
browser adapter modules directly. Those remain framework internals or public
exports of `isonim/editor`.

## Workspace Schema

Consumers own the workspace definition, story catalog, design-system schema,
preview renderers, file paths, and source edit adapters. The framework owns the
editor ViewModels, command state, browser shell, source edit transaction
protocol, vector backend bridge, and agent event mapping.

Editable properties should be described with source-map and schema entries that
identify:

- the file and range or structured field to edit;
- whether the edit is local, shared, token-backed, or schema-backed;
- validation rules and allowed units;
- preview reload behavior after a successful write.

Component edit mode must use the same project-owned preview document shown in
the component detail view. The editor may inject generic selection metadata and
event handlers into that iframe, but project-specific source files, line
numbers, schema keys, and patch behavior belong to the consumer workspace.

### Add a design-system schema

Define `WorkspaceEditableSchemaEntry` values in the consumer workspace adapter,
using stable schema keys, owned files, paths, and source-map metadata. Then add
headless coverage that maps DOM properties to schema ownership and consumer
coverage that proves the public `isonim/editor` API can load the workspace.
Metacraft keeps this in
`apps/back-office/src/backoffice_editor/workspace.nim`.

### Add a token category

Add typed token metadata to the workspace schema, expose usage and impact data
through the source map, and route token edits through reversible source plans.
Token categories need contrast or validation diagnostics, a save/revert path,
and either a dedicated browser workflow or evidence through the style/token
manager before promotion.

### Add a component variant

Declare the variant property, allowed values, state coverage, and fixture/story
ownership in the consumer schema. Add ViewModel tests for source-plan
generation and missing-story diagnostics, then add browser coverage that edits
the real component preview and saves or reverts the generated plan.

### Add a property editor

Extend the typed property/value model first, including parsing, normalization,
validation, source-plan selection, undo/redo, and dirty/save state. Browser
controls are required when the editor depends on pointer, focus, iframe,
canvas, keyboard, or layout measurement behavior.

### Add a direct manipulation command

Model the command as a source-backed editor action with deterministic
availability diagnostics. The browser handler may update the live preview
optimistically, but completion requires a reversible source plan and adapter
save/revert coverage. Add Playwright coverage for drag, keyboard, context-menu,
or focus behavior as appropriate.

### Add an AI proposal scope

Add the selectable scope to the shared prompt context, include source and
design-system metadata, and represent proposed edits as reviewable source
plans. Browser coverage must prove the user can include/exclude the scope,
accept or reject the proposal, and keep comment/review state synchronized.

## Source Edits

All source writes flow through the workspace edit adapter introduced by M27.
The editor stages source plans, validates conflicts, calls the consumer adapter,
rolls back failed transactions, and clears dirty state only after the adapter
reports success.

CSS, foundation token, component variant, SVG/vector, and accepted agent edits
all use this path. Direct browser DOM mutation is not a completed edit until the
ViewModel has received the source change and the adapter has saved it.

The metacraft-web browser dogfood workspace currently persists edits to its
project-owned adapter state so the end-to-end editor flow can be tested in a
static browser build. Writing those edits to host files requires a local dev
server/API adapter owned by the consumer workspace.

## Agent Adapters

The editor talks to agents through the shared `nim-agents` abstraction. IsoNim
maps ACP/Agent Harbor events into editor prompt context, messages, permission
requests, proposed file edits, diagnostics, cancellation, and completion state.

The assistant panel starts empty. Example fake responses are produced only by
an explicit prompt in the example workspace; production consumers should provide
their own `agentPromptAdapter` and `agentCancelAdapter`.

## Quality Bar

The matrix records the acceptance heuristics that future milestones must turn
into automated checks: sidebar and inspector density, control discoverability,
keyboard operation, panel resizing, selection latency, and no layout jumping.
Screenshot assertions are intentionally tracked per feature because DOM checks
alone are not enough to claim visual-editor maturity.

## Tests

Run the maturity gate through `direnv` from the owning repository:

```sh
direnv exec /home/zahary/metacraft/isonim nim c -r tests/test_editor_release_gate.nim
direnv exec /home/zahary/metacraft/isonim just test-editor
direnv exec /home/zahary/metacraft/isonim just editor-build
direnv exec /home/zahary/metacraft/isonim just test-browser-editor-example
direnv exec /home/zahary/metacraft/isonim just test-browser-editor-consumer
direnv exec /home/zahary/metacraft/isonim just test-editor-visual-gates
direnv exec /home/zahary/metacraft/metacraft-web just build-back-office-editor
direnv exec /home/zahary/metacraft/metacraft-web nim c -r apps/back-office/tests/test_backoffice_editor_workspace.nim
direnv exec /home/zahary/metacraft/metacraft-web just run-back-office-editor-test-matrix
direnv exec /home/zahary/metacraft/nim-agents just test
```

Headless ViewModel tests are required for editor state, source plans,
validation, adapters, and package boundaries. Playwright tests are required
when the feature owns pointer, focus, iframe, or canvas behavior. Screenshot and
visual assertions are required before any UI workflow can be promoted to
`figma_grade`.
