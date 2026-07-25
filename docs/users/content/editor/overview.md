---
title: Editor Overview
description: How the IsoNim editor package fits into an IsoNim app.
section: editor
order: 1
---
# Editor Overview

The IsoNim editor (`isonim/editor`) is a separate, published package
that plugs into a host IsoNim app as a regular component tree -- it
doesn't require a special build mode or a different rendering pipeline
from the rest of your app. It's a visual, storyboard-and-canvas
component editor: consuming projects supply their own component
stories, canvas layout, and design-token data, and the package supplies
the framework, view models, and rendering around them.

## The editor docs, page by page

- **[Editor Workspace Model](./workspace.md)** -- the `EditorWorkspace`
  data contract a host project supplies (story groups, canvas items,
  flow data, permissions, panel visibility), and how to build and update
  one.
- **[Editor Browser Mount Contract](./browser-mount.md)** -- `mountEditor`,
  the JS-target-only entry point that mounts the editor shell into a
  real DOM element and returns its live `EditorVM`.
- **[Editor Consumer Integration](./integration.md)** -- the imports a
  host app needs, the project-owned/package-owned data boundary, and a
  minimal end-to-end mount example.

:::note
The editor's browser mount contract is the same `WebRenderer`-family DOM
contract every other IsoNim component uses -- there is no
editor-specific renderer, just an editor-specific mount helper
(`mountEditor`) that wires the shell's routing and keyboard shortcuts
for you.
:::

See [the ui DSL](../guide/dsl.md) for the markup layer the editor's own
components are built with. Back to [the site index](../index.md).
