---
title: Signals & Effects
description: How IsoNim's reactive core tracks state and reacts to changes.
section: guide
order: 2
---
# Signals & Effects

IsoNim's reactive core is built on two primitives: **signals**, which hold a
piece of state, and **effects**, which re-run automatically whenever a signal
they read from changes. Together they give isonim-docs (and every IsoNim app)
fine-grained updates without a virtual DOM diff.

## Creating a signal

A signal is created with `createSignal(initialValue)` and read/written
through its `.val` accessor. Renderers and consuming code import the
reactive core through `isonim/rxcore` -- the one stable adapter seam,
never `isonim/core/*` directly:

```nim runnable
import isonim/rxcore

let count = createSignal(0)
echo count.val # 0
count.val = count.val + 1
echo count.val # 1
```

## Reacting with effects

`createRenderEffect` (or the lower-level `effect` proc) re-runs its body
every time a signal it reads changes value:

```nim runnable
import isonim/rxcore

let count = createSignal(0)
createRenderEffect(proc() =
  echo "count is now ", count.val)
```

:::tip
Effects track their dependencies automatically -- there is no manual
subscription list to maintain. Reading `count.val` inside the effect body is
what registers the dependency.
:::

:::warning
Don't mutate a signal from inside its own effect without a guard condition;
it will re-trigger the effect and can loop forever.
:::

## Primitive cheat sheet

| Primitive | Purpose |
| --- | --- |
| `createSignal` | Holds one piece of reactive state. |
| `effect` | Re-runs a side effect when its dependencies change. |
| `createRenderEffect` | The render-focused effect the `ui` DSL wires up automatically. |

See the [DSL guide](./dsl.md) for how `ui(r): ...` blocks turn signal reads
inside `text`/attribute expressions into these effects automatically, and
[SSR basics](./ssr-basics.md) for how the same components render without any
reactivity at all on the server. Back to [the site index](../index.md).
