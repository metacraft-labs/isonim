---
title: The ui DSL
description: A tour of IsoNim's Karax-style ui(...) markup DSL.
section: guide
order: 3
---
# The ui DSL

IsoNim's `ui` macro compiles a nested, HTML-shaped block of Nim code into
real element-tree construction calls (client mode) or an HTML string
(server mode) -- the same markup, two different backends.

## Basic elements

```nim
ui(r):
  tdiv(class = "card"):
    h1: text "Hello"
    span: text "World"
```

`tdiv` maps to a real `<div>` tag (`div` is a Nim keyword, so the DSL uses
`tdiv` for it); every other tag name maps straight to its HTML tag.

## Dynamic attributes and text

Any expression that reads a signal -- not just a literal -- can be used as
an attribute value or a `text` argument:

```nim
ui(r):
  span(class = if active.val: "on" else: "off"):
    text $count.val
```

The DSL wraps a dynamic expression like this in a `createRenderEffect`
automatically, so the `<span>`'s class and text content update whenever
`active` or `count` change -- no manual re-render call needed.

## Control flow

`if`, `for`, and `case` all work directly inside a `ui(...)` block and
rewrite their branches' DSL children in place:

```nim
ui(r):
  tdiv:
    if items.val.len == 0:
      span: text "Nothing yet"
    else:
      for item in items.val:
        li: text item
```

:::note
A bare proc call as a loop body (instead of a literal DSL element) is *not*
rewired automatically -- build the child element yourself and append it with
`r.appendChild` outside the `ui(...)` block instead.
:::

## Components

IsoNim ships a small set of built-in **control-flow components** --
`show`, `forEachKeyed`/`indexEach`, and `errorBoundary` -- generic over
both the renderer and the node type, so they work identically under SSR
and JS mount:

```nim
show(r, parent,
  condition = proc(): bool = user.val.isSome,
  body = proc(): Node = renderProfile(r, user.val.get))
```

Beyond those built-ins, an isonim-docs **component** is just a plain,
generic proc that takes a renderer and returns a node -- exactly the
convention this site's own chrome is built with (`renderShell`,
`renderMarkdownPage`, `renderSearchView` under `src/components/`).
There is no separate component-definition macro or class hierarchy:

```nim
proc renderCard*[R, N](r: R; title, body: string): N =
  ui(r):
    tdiv(class = "card"):
      h2: text title
      p: text body
```

Any page (or another component) can call `renderCard(r, ...)` like any
other proc, which is what makes a component tree composable across an
entire site without a plugin system.

Once you're comfortable with the DSL, [SSR basics](./ssr-basics.md) covers
how the exact same block renders to a string on the server, and
[Signals & Effects](./signals-effects.md) covers the reactive primitives
`ui(...)` wires up for you. Back to [the site index](../index.md).
