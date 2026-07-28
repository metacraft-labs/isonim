---
title: Welcome to the IsoNim docs
description: IsoNim is an isomorphic reactive UI framework for Nim; isonim-docs builds documentation sites on top of it.
---

# Welcome to the IsoNim docs

:::hero title="Welcome to the IsoNim docs" subtitle="IsoNim is an isomorphic reactive UI framework for Nim — write one component tree that renders identically under server-side rendering and in the browser."
:::button href="/getting-started" variant="primary"
Get Started
:::button href="https://github.com/metacraft-labs/codetracer/issues" variant="secondary"
Support
:::

## Overview

isonim-docs is the documentation-site framework these pages are built with. It
renders every page twice from a single source: once as static HTML at build
time (`nim c`, for fast first paint and search-engine indexing) and once in the
browser (`nim js`, for client-side navigation) — so what you are reading is
served pre-rendered and then hydrated in place, with no content forked between
the two targets.

Use the sidebar to set up a local checkout, learn the reactive core (signals,
effects, and the `ui` DSL), understand how server-side rendering and routing
fit together, and explore the IsoNim editor package.

## Start here

:::cards
:::card title="Getting Started" icon="/assets/img/icon__support.svg" href="/getting-started"
Set up a sibling checkout inside the IsoNim dev shell and render your first page.
:::card title="Guide" icon="/assets/img/icon__faq.svg" href="/guide/install-setup"
Install & setup, signals & effects, the `ui` DSL, SSR basics, and the testing strategy.
:::card title="Editor" icon="/assets/img/icon__github.svg" href="/editor/overview"
The IsoNim editor package: its workspace model, browser-mount contract, and integration.
:::

## Popular articles

:::cards
:::card title="Install & Setup" href="/guide/install-setup"
Guide
:::card title="Signals & Effects" href="/guide/signals-effects"
Guide
:::card title="The ui DSL" href="/guide/dsl"
Guide
:::card title="SSR Basics" href="/guide/ssr-basics"
Guide
:::card title="Editor Overview" href="/editor/overview"
Editor
:::card title="Testing Strategy" href="/guide/testing-strategy"
Guide
:::
