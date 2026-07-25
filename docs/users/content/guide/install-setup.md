---
title: Install & Setup
description: How to get a clean checkout of isonim-docs building and testing.
section: guide
order: 1
---
# Install & Setup

isonim-docs is developed as a sibling checkout inside the IsoNim monorepo
family, not as a standalone package with its own dependency-installation
step -- there is no `nimble install` for this repo's own dependencies.

## Prerequisites

- A sibling `../isonim` checkout (the IsoNim isomorphic reactive UI
  framework this whole site is built on) and a sibling
  `../nim-everywhere` checkout. `config.nims` resolves both via
  `--path`, so neither is a Nimble dependency.
- The IsoNim Nix dev shell, entered with `nix develop ../isonim`. That
  shell is where `nim`, `nimble`, and `just` all come from -- this repo
  never assumes a global `nim` install.
- `chronicles` (structured logging) plus its own `faststreams`/`stew`
  dependencies, resolved from `../isonim/vendor` and sibling checkouts
  the same way IsoNim's own test suite resolves them, rather than
  through `nimble install chronicles`.

## Sibling dev shell workflow

From a clean checkout, everything routes through `just`:

```sh
nix develop ../isonim -c just ci-docs
```

`ci-docs` is the one command a CI job needs: it runs the full
dual-target test matrix and a compile smoke pass, so a green `ci-docs`
run means both "every suite passes" and "the real SSR/browser shells
still compile against the real `content/` directory."

## Task entry points

| Command | What it does |
| --- | --- |
| `just docs-test-c` | Runs every docs suite on the C (SSR) target. |
| `just docs-test-js` | Runs every docs suite on the JS (browser) target. |
| `just docs-test` | Both of the above. |
| `just docs-smoke` | Compile-only pass over the SSR and browser-mount entry points, plus the real broken-link build gate over `content/`. |
| `just ci-docs` | `docs-test` followed by `docs-smoke` -- the single entry point CI runs. |

:::note
`docs-test-js` depends on a `tailwind-bootstrap` step that shells out to
`../isonim`'s own Justfile to generate `../isonim/build/tailwind-styles.json`
from the real Tailwind CLI -- the JS target's `ui` DSL imports IsoNim's
Tailwind integration unconditionally, so a clean checkout's first JS
build always needs that file to exist first.
:::

See [SSR Basics](./ssr-basics.md) for what `docs-smoke`'s compile targets
actually render, and [Testing Strategy](./testing-strategy.md) for what
each suite in `docs-test-c`/`docs-test-js` is proving. Back to
[the site index](../index.md).
