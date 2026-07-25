---
title: Editor Consumer Integration
description: How a host IsoNim app depends on and embeds the editor package.
section: editor
order: 4
---
# Editor Consumer Integration

The IsoNim editor is a regular, published IsoNim package -- integrating
it into a host app is an import and a mount call, not a special build
mode or a separate deployment target.

## Importing the editor package

```nim
import isonim/editor          # types, view models, workspace -- any target
import isonim/editor/browser  # mountEditor -- JS target only
```

`isonim/editor` re-exports `isonim/editor/types`, `isonim/editor/viewmodels`,
and `isonim/editor/workspace`, so most consuming code needs exactly that
one import. `isonim/editor/browser` is imported separately, and only
from a browser entry point, since it hard-requires the JS target.

## Project-owned data

The package boundary is explicit: the editor package owns the framework,
the view models, and rendering; the consuming project owns its own story
groups, canvas/flow data, design-token schema, and initial selection
state -- all supplied through the project's own
[`EditorWorkspace`](./workspace.md) value, never hardcoded in the editor
package itself.

## A minimal host integration

```nim
import isonim/editor
import isonim/editor/browser

proc main() =
  let workspace = newEditorWorkspace(
    title = "My Design System",
    storyGroups = myProjectStoryGroups())
  let vm = mountEditor(workspace, root = document.getElementById("editor-root"))
  # `vm` is the live EditorVM -- read its signals, or call
  # `applyWorkspace(vm, ...)` later to push updated project data in.

main()
```

## Where the editor's own state comes from

A host app doesn't need to reimplement editor UI state -- everything the
editor shell renders (the active story, the current canvas selection,
inspector panel visibility) lives on the returned `EditorVM` as regular
IsoNim signals, exactly the same `ViewModel` contract this whole site's
own pages use for their content. A host app that wants to react to
editor state (a "story changed" indicator in its own chrome, for
example) subscribes to those signals directly instead of polling.

See [Editor Overview](./overview.md) for how these three editor pages
fit together, and [the ui DSL](../guide/dsl.md) for the markup layer the
editor's own components (and any host-app chrome around it) are built
with. Back to [the site index](../index.md).
