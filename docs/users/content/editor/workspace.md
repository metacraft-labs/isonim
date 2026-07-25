---
title: Editor Workspace Model
description: The EditorWorkspace data contract a consuming project supplies to the IsoNim editor.
section: editor
order: 2
---
# Editor Workspace Model

The IsoNim editor package owns the framework, view models, and
rendering; a consuming project owns its own **workspace**: the data
contract that tells the editor what to show and how it may be edited.

## EditorWorkspace

`EditorWorkspace` (from `isonim/editor/workspace`) is a plain object, not
a signal or a live view model -- it's the project-supplied snapshot the
editor's own live `EditorVM` is built from:

```nim
type
  EditorWorkspace* = object
    id*, title*, version*, description*: string
    storyGroups*: seq[StoryGroup]
    canvasItems*: seq[CanvasItem]
    connections*: seq[FlowConnection]
    flowSteps*: seq[FlowStep]
    vectorSymbols*: seq[VectorSymbol]
    foundationTokens*: seq[FoundationTokenEntry]
    componentVariants*: seq[ComponentVariantDefinition]
    designSystemSchema*: DesignSystemSchema
    initialView*: EditorView
    permissions*: EditorWorkspacePermissions
    panels*: PanelVisibility
    # ... plus initial-selection and agent-adapter fields.
```

`storyGroups`/`canvasItems`/`connections`/`flowSteps` are the project's
own component stories, canvas layout, and flow-diagram data; `permissions`
and `panels` control what the mounted editor allows an end user to do
(source read/write, story/variant creation, deletion) and which chrome
panels start visible.

## Building a workspace

Two constructors cover the common cases:

```nim runnable
import isonim/editor

let empty = emptyEditorWorkspace()          # production defaults, no content
let mine = newEditorWorkspace(
  title = "My Design System",
  storyGroups = empty.storyGroups)          # everything else defaults
```

`newEditorWorkspace` takes every field as a named default parameter, so
a project only ever states the fields it actually owns.

## Updating a live workspace

`applyWorkspace(vm, workspace)` pushes a new `EditorWorkspace` snapshot
into an already-mounted `EditorVM` -- the same signal-backed update path
every other IsoNim ViewModel uses, not a re-mount:

```nim
applyWorkspace(vm, newEditorWorkspace(title = "My Design System",
                                       storyGroups = updatedGroups))
```

Consumers read the mounted VM's own signal-backed state (e.g. the active
story, the current canvas selection) the same way they'd read any other
IsoNim `ViewModel` -- see [Browser Mount Contract](./browser-mount.md)
for how that VM comes to exist in the first place. Back to
[the site index](../index.md).
