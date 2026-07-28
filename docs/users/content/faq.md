---
title: FAQ
description: Answers to common questions about this documentation site and the IsoNim framework it is built on.
order: 90
---

# FAQ

Answers to common questions about this documentation site and the IsoNim
framework it is built on. Can't find what you need? Reach out through the
Support link in the header.

:::faq
:::q title="What is IsoNim?"
IsoNim is an isomorphic reactive UI framework for Nim. You write a single
component tree with the `ui` DSL and it renders identically as static HTML on
the server (`nim c`) and as a live, reactive UI in the browser (`nim js`) — no
separate templates or client/server forks.

:::q title="What is isonim-docs?"
isonim-docs is the documentation-site framework these pages are built with. It
turns a directory of Markdown content into a statically generated, hydratable
docs site, reusing IsoNim's own rendering core so every page is produced by the
same component code under SSR and in the browser.

:::q title="Do the content components require JavaScript?"
No. The hero, card grids, and this FAQ accordion all render as plain HTML at
build time. The accordion is a native `<details>`/`<summary>` disclosure, so it
expands and collapses with zero JavaScript; client-side scripting only enhances
navigation and search, it is never required to read a page.

:::q title="How do I set up a local checkout?"
isonim-docs is developed as a sibling checkout inside the IsoNim monorepo
family, entered through the IsoNim Nix dev shell (`nix develop ../isonim`).
The Install & Setup page in the guide walks through the required sibling
repositories and how `config.nims` resolves them.

:::q title="How is a page rendered under both SSR and the browser?"
Each route is rendered from one source through the same shell and view-model
code. On the server it is emitted as a string of HTML; in the browser the same
tree is built against the real DOM and reused in place. The SSR Basics and
Testing Strategy pages cover how the two targets are kept in lock-step.

:::q title="Where do I report a problem or ask for help?"
Use the Support link in the header, or open an issue on the project's GitHub.
The "Need some help?" block at the bottom of every page links straight to
support and to this FAQ.
:::
