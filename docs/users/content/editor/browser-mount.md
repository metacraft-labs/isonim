---
title: Editor Browser Mount Contract
description: How to mount the IsoNim editor into a real DOM element.
section: editor
order: 3
---
# Editor Browser Mount Contract

The editor's browser entry point is `isonim/editor/browser`, a JS-target-only
module (it hard-errors if compiled with `nim c`) -- there is no separate
editor-specific renderer or DOM abstraction from the rest of IsoNim.

## mountEditor

```nim
import isonim/editor
import isonim/editor/browser

let vm = mountEditor(myWorkspace, root = document.body)
```

```nim
proc mountEditor*(workspace: EditorWorkspace;
                  root: Element = document.body;
                  useHashRoute = true;
                  injectStyles = true): EditorVM
```

- `workspace` is the project's own [`EditorWorkspace`](./workspace.md).
- `root` is any real DOM element the editor shell should fill --
  `document.body` by default.
- `useHashRoute` wires the editor's internal view (storyboard, canvas,
  inspector) to `window.location.hash`, so browser back/forward and
  deep links to a specific story work without any router integration
  from the host app.
- `injectStyles` injects the editor's own base responsive styles as a
  `<style>` tag; set it to `false` if the host app already loads them.

`mountEditor` returns the live `EditorVM`, not `void` -- the same VM
[Editor Workspace Model](./workspace.md)'s `applyWorkspace` updates, and
the value host-app tests and integrations use to drive the editor
programmatically after mount.

## The DOM contract

The editor mounts through `isonim/editor/dom_renderer`'s `DomRenderer`,
the same `WebRenderer`/DOM-backed renderer contract every other IsoNim
component in this site mounts through -- there is no editor-specific
renderer to learn. The shell element itself is inserted with fixed,
full-viewport positioning (`position: fixed; inset: 0;`), so a host page
embedding the editor should mount it into a dedicated container rather
than expecting it to flow inline with surrounding content.

:::note
`mountEditor` is JS-target-only by design -- the editor is an inherently
interactive, browser-only surface (canvas manipulation, live component
preview, drag-driven layout), unlike the rest of this site's pages,
which render identically under SSR and JS mount.
:::

See [Consumer Integration](./integration.md) for how a host project wires
`mountEditor` into its own app shell. Back to
[the site index](../index.md).
