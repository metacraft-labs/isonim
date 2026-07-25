---
title: SSR Basics
description: How isonim-docs renders pages to HTML on the server.
section: guide
order: 4
---
# SSR Basics

Every isonim-docs page renders through the exact same route manifest and
page ViewModel on both the server (`nim c`, server-side rendering) and the
browser (`nim js`, client-side mount) -- there is no separate SSR-only
templating layer.

## renderRoute

`renderRoute(path, contentDir)` is the single SSR entry point: it resolves
`path` against the site's route manifest, loads the matched route's bound
content file, builds the page's ViewModel, and renders it to a
`(status, html)` pair.

```nim runnable
import ssr

let (status, html) = renderRoute("/guide/ssr-basics")
```

A path that doesn't match any real route still returns a real result: status
`404` and the typed not-found page's HTML, rather than raising.

## Why no virtual DOM diffing on the server

The server never mounts a live component tree, so there is nothing to diff
against a previous render -- `renderRoute` builds one HTML string per
request straight from the ViewModel, which is also why every dynamic value
(page title, body content, link targets) is escaped as it's written rather
than trusted as already-safe HTML.

:::danger
Never build page HTML by concatenating raw, unescaped content-file text --
always go through the ViewModel/rendering pipeline so link targets and body
text get HTML-escaped consistently between the browser and the server.
:::

## Route matching and params

`docsRouteManifest()` is one flat list of typed `RouteEntry` values --
pattern, canonical path, page kind, and the content file it binds to.
`matchRoute(manifest, path)` walks the list in order and returns the
first pattern that matches, with any captured path params alongside it;
an unmatched path falls back to the manifest's own typed not-found
entry rather than raising. Trailing slashes never need special-casing
by an author: `/guide/dsl` and `/guide/dsl/` match the exact same entry,
since matching compares non-empty path segments rather than raw
strings.

## SSR vs. JS mount, side by side

| Aspect | SSR (`nim c`) | JS mount (`nim js`) |
| --- | --- | --- |
| Entry point | `renderRoute` | `createRouteApp` |
| Output | An HTML string | A live DOM node tree |
| Content loading | Real filesystem read | Compile-time embedded content |
| Route manifest | Same `docsRouteManifest()` | Same `docsRouteManifest()` |

See [the ui DSL](./dsl.md) for the markup layer both entry points render
through, and [Signals & Effects](./signals-effects.md) for why the server
render never needs reactivity at all. Back to [the site index](../index.md).
