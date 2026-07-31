# IsoNim User Docs — working on the IsoNim framework's user guide

This is the **user-facing documentation for the [IsoNim](../../) framework**
(the reactive Nim UI toolkit). It is itself built with
[isonim-docs](../../../isonim-docs) (the docs SSG), so it dogfoods the framework
and is themed by the shared
[CodeTracer docs design system](../../../codetracer-design-system/docs/codetracer-docs.tokens.json).

> Two different "docs" live nearby — don't confuse them:
> - **this** (`isonim/docs/users/`) documents the **IsoNim UI framework** for its users;
> - [`isonim-docs/site/`](../../../isonim-docs/site/README.md) documents the **isonim-docs SSG framework**;
> - [`codetracer/docs/book-isonim/`](../../../codetracer/docs/book-isonim/README.md) is the **CodeTracer product** book.

## Prerequisites

Every task runs inside the **IsoNim Nix dev shell**. Enter it once…

```bash
cd isonim/docs/users
nix develop ../..            # the IsoNim repo root holds the flake
just dev-docs
```

…or prefix a single recipe:

```bash
nix develop ../.. -c just dev-docs
```

All commands below assume you are in `isonim/docs/users/` and in the dev shell.

## Live preview (hot reload)

```bash
just dev-docs                 # http://127.0.0.1:8000  (loopback only)
just dev-docs-lan             # same, reachable on your private LAN
just open-docs                # open the running server in a browser
```

The first launch compiles the dev server (and the client JS bundle) — give it a
minute — then every content edit live-reloads all open tabs.

## Build, one-shot preview, tests

```bash
just build         # static build into build/
just serve-docs    # one-shot SSR preview (no live reload)
just test          # the full user-docs test suite (build, links, references, landing, theme, dev)
```

## Where things live

| Path | What |
|------|------|
| `content/index.md` | Landing page |
| `content/getting-started.md`, `content/guide/`, `content/editor/`, `content/faq.md` | The guide sections |
| `src/docs_config.nim` | Site config (title, chrome, section order, redirects) |
| `src/{build,dev,ssr}.nim` | Build/serve entry points |
| `assets/style.css` | Site-owned CSS |
| `tests/` | Build, completeness, content-loader, references, redirects, theme-contract, landing, dev tests |

Add a page by dropping a Markdown file with front matter (`title`, `section`,
`order`) into `content/`.

## Changing the look (design system)

Themed by the **shared** `codetracer-docs.tokens.json`. Launch the editor from
here:

```bash
just design                   # http://127.0.0.1:8080  (shared theme editor)
```

Keep `just dev-docs` running: a token you Save in the editor hot-reloads this
site live. The editor lives in
[`isonim-docs/site/design`](../../../isonim-docs/site/design/README.md).
