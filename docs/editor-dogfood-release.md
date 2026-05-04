# IsoNim Editor Dogfood Release Guide

This document is the release gate companion for
`docs/editor-feature-matrix.json`. The matrix is machine checked by
`tests/test_editor_release_gate.nim`; update both when editor functionality or
required coverage changes.

## Launch

Framework contributors can launch the packaged example editor with:

```sh
direnv exec /home/zahary/metacraft/isonim just editor-build
direnv exec /home/zahary/metacraft/isonim just editor-serve
```

Metacraft runs the same editor package with a consumer-owned workspace:

```sh
direnv exec /home/zahary/metacraft/metacraft-web just build-back-office-editor
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

## Source Edits

All source writes flow through the workspace edit adapter introduced by M27.
The editor stages source plans, validates conflicts, calls the consumer adapter,
rolls back failed transactions, and clears dirty state only after the adapter
reports success.

CSS, foundation token, component variant, SVG/vector, and accepted agent edits
all use this path. Direct browser DOM mutation is not a completed edit until the
ViewModel has received the source change and the adapter has saved it.

## Agent Adapters

The editor talks to agents through the shared `nim-agents` abstraction. IsoNim
maps ACP/Agent Harbor events into editor prompt context, messages, permission
requests, proposed file edits, diagnostics, cancellation, and completion state.

The assistant panel starts empty. Example fake responses are produced only by
an explicit prompt in the example workspace; production consumers should provide
their own `agentPromptAdapter` and `agentCancelAdapter`.

## Tests

Run the release gate through `direnv` from the owning repository:

```sh
direnv exec /home/zahary/metacraft/isonim just test-editor
direnv exec /home/zahary/metacraft/isonim just editor-build
direnv exec /home/zahary/metacraft/isonim just test-browser-editor-example
direnv exec /home/zahary/metacraft/isonim just test-browser-editor-consumer
direnv exec /home/zahary/metacraft/metacraft-web just build-back-office-editor
direnv exec /home/zahary/metacraft/metacraft-web nim c -r apps/back-office/tests/test_backoffice_editor_workspace.nim
direnv exec /home/zahary/metacraft/nim-agents just test
```

Headless ViewModel tests are required for editor state, source plans,
validation, adapters, and package boundaries. Playwright tests are required for
browser-only behavior: pointer and keyboard interaction, browser history,
iframe/rendered previews, vector canvas behavior, panel visibility, and visual
integration with consumer workspaces.
