---
title: Testing Strategy
description: The three-tier test harness every isonim-docs suite is built on.
section: guide
order: 5
---
# Testing Strategy

Every isonim-docs suite follows the same three-tier IsoNim test pyramid,
run dual-target (`nim c -r` and, where the code under test has no
filesystem dependency, `nim js -r` too) so a passing suite proves the
same behavior on both the server and the browser.

## Three tiers

1. **Tier 1 -- ViewModel/unit.** Pure functions and data transforms (a
   route matcher, a markdown parser, a navigation ViewModel builder) with
   no renderer and no filesystem involved. These are the cheapest tests
   to run and the ones most suites lean on most heavily -- see
   `test_search_vm.nim`, `test_navigation_vm.nim`, `test_references_vm.nim`.
2. **Tier 2 -- MockRenderer.** The same ViewModels rendered through
   `isonim/testing/mock_dom`'s `MockRenderer`, asserted on with plain
   tree-walk helpers (`findByTag`, `findAllByTag`) instead of a real DOM
   or an HTML string -- proves a component's *shape*, independent of
   whichever backend eventually renders it.
3. **Tier 3 -- SSR/browser integration.** `renderRoute` (SSR, C target)
   or `createRouteApp` (browser mount, JS target) driven end to end
   against real fixture content, with SSR output run through HTML
   whitespace normalization before any string assertion, so a snapshot
   check never goes flaky over incidental spacing.

## MockRenderer

MockRenderer component suites never touch a real DOM or generate real
HTML strings -- a component under test renders into an in-memory
`MockNode` tree that both a Tier-2 unit test and the eventual real
SSR/browser renderers agree on, since every isonim-docs component is
itself written generic over its renderer (`proc renderX*[R, N](r: R;
...): N`).

## Fixtures and log capture

- **Fixtures are real, not faked.** Content-loading tests write real
  files into a real, isolated temp directory (`withFixtureDir`) rather
  than mocking the filesystem -- the one exception this harness allows
  is a fake clock for deterministic timestamps; the filesystem, router,
  renderer, and content loader all stay real end to end.
- **Structured logging is asserted on, not just printed.** Route
  resolution and render failures log through `chronicles`; tests that
  need to assert on a specific log line redirect the real OS-level
  stderr file descriptor around the code under test and read back what
  was actually written, rather than swapping in a fake logging sink.
- **The real `content/` directory is exercised directly, too.** Several
  Tier-3 suites (`test_content_loader.nim`, `test_references_renderroute.nim`,
  `test_redirects_renderroute.nim`) load and validate the real, checked-in
  `content/` tree itself, not just hermetic fixtures -- the same
  `validateContentGraph` check `just docs-smoke` runs for real, so a
  broken internal link in this very corpus fails a test locally before
  it ever fails CI.

:::tip
When a change spans more than one subsystem (routing + navigation +
references, for example), look for an existing cross-feature integration
suite (`test_docs_graph_integration.nim` and its `_renderroute`
companion) before writing a new one -- proving subsystems agree with each
other from one shared content graph is exactly what those suites exist
for.
:::

See [Install & Setup](./install-setup.md) for the `just` commands that
run these suites, and [SSR Basics](./ssr-basics.md) for what `renderRoute`
itself does. Back to [the site index](../index.md).
