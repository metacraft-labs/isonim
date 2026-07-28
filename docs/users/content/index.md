# Welcome to isonim-docs

:::hero title="Welcome to CodeTracer Docs" subtitle="Record, replay and understand your program's execution."
:::button href="getting-started.md" variant="primary"
Get Started
:::button href="guide/install-setup.md" variant="secondary"
Support
:::

isonim-docs is a documentation-site framework built on top of IsoNim, the
isomorphic reactive UI framework for Nim. This page is the M0 proof-of-life
route: it is loaded from a real file in content/, rendered through the same
docs shell component under SSR (nim c) and in the browser (nim js), and its
exact title and body text are asserted by the MockRenderer, SSR, and
JS-mount test tiers alike.

## Start here

:::cards
:::card title="Getting Started" icon="/assets/img/icon__github.svg" href="getting-started.md"
Install the toolchain and render your first page.
:::card title="Guide" icon="/assets/img/icon__faq.svg" href="guide/install-setup.md"
Install & setup, the DSL, signals & effects, SSR basics and testing.
:::card title="Editor" icon="/assets/img/icon__support.svg" href="editor/overview.md"
The editor integration, workspace and browser-mount overview.
:::

:::button href="getting-started.md" variant="primary"
Read the guide

:::

## Frequently asked questions

:::faq
:::q title="What is isonim-docs?"
A documentation-site framework built on IsoNim that renders the same content
under SSR and in the browser.
:::q title="Do the content components require JavaScript?"
No. The FAQ accordion uses native `<details>`/`<summary>`, so it expands and
collapses with zero JavaScript.
:::
