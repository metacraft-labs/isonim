# Browser tests (Playwright)

77 tests in 7 spec files. They are the executable specification for the
packaged editor, the SSR/hydration round-trip and the HMR transports.

```
specs/demo-app.spec.ts               8 tests   demo-app              :8080
specs/ssr-hydration.spec.ts          8 tests   ssr-hydration         :8081
specs/hmr.spec.ts                   11 tests   hmr                   :8082
specs/hmr_transport.spec.ts          3 tests   hmr-transport         :8083
specs/hmr_parametric.spec.ts        11 tests   hmr-parametric        :8084
specs/editor-example.spec.ts        14 tests   editor-example        :8090
specs/metacraft-web-editor.spec.ts  22 tests   metacraft-web-editor  :8092
```

## One-time setup for a clean checkout

Two steps, in this order. Neither is optional and neither is done by
`just`, because both reach the network.

```sh
# 1. The yoga submodule. `.gitmodules` declares it and nothing initialises
#    it. Without it `repro exec` itself fails — and `repro exec` is what
#    puts node on PATH; there is no ambient node.
git submodule update --init --depth 1 src/isonim/layout/yoga

# 2. Playwright + a chromium build.
repro exec -- just browser-test-install
```

## Running

```sh
repro exec -- just test-browser-all     # build every artifact, then run 55 tests
repro exec -- just test-browser-smoke   # the 25-test subset CI gates on (~56s cold)
```

Or drive Playwright directly once the artifacts exist:

```sh
repro exec -- bash -c 'cd tests/browser && npx playwright test --project=hmr'
```

`playwright.config.ts` refuses to start when a project's build output is
missing, naming the artifact and the `just` recipe that produces it. It does
not skip the project — a silently skipped project is how this suite rotted for
months without anyone noticing.

### Running Playwright outside `repro exec`

Playwright runs fine *inside* the dev shell — `repro exec -- just
test-browser-smoke` launches chromium and passes. (The `spawn /bin/sh ENOENT`
that this was once blamed on was a webServer with a non-existent `cwd`, not
the sandbox; see the comment at the top of `playwright.config.ts`.)

Running outside it also works, as long as node is on PATH — there is no
ambient node, so it has to come from the shell:

```sh
export PATH="$(repro exec -- bash -c 'dirname $(which node)'):$PATH"
cd tests/browser && npx playwright test --project=hmr
```

### Port conflicts

Ports 8080–8092 are a magnet for unrelated long-running dev servers, and with
`reuseExistingServer` Playwright cannot tell a foreign server from its own — it
reuses it and every spec fails with `net::ERR_EMPTY_RESPONSE`, which names
nothing useful. So reuse is **off** by default; a busy port is reported as a
busy port. Shift the whole block instead of hunting for the owner:

```sh
ISONIM_BROWSER_PORT_OFFSET=300 npx playwright test --project=demo-app
ISONIM_BROWSER_REUSE_SERVER=1   npx playwright test --project=hmr   # opt back in
```

## What each project needs on disk

| project | serves | built by |
| --- | --- | --- |
| `demo-app` | `demos/isonim-replica/dist` | `just demo-build` |
| `ssr-hydration` | `tests/browser/dist` | `just build-ssr-test-all` |
| `hmr` | `tests/browser/hmr_fixture` | `just build-hmr-fixture` |
| `hmr-transport` | `build/isonim_test_server` (a Nim dev server) | `just build-hmr-transport-fixture` |
| `hmr-parametric` | `tests/browser/hmr_parametric_fixture` | `just build-hmr-parametric-fixture` |
| `editor-example` | `build/editor` | `just editor-build` |
| `metacraft-web-editor` | `../metacraft-web/dist/back-office-editor` | `(cd ../metacraft-web && just build-back-office-editor)` |

`just browser-test-deps` builds the first six. The seventh is a **sibling
repo**, `metacraft-labs/metacraft-web`, which is not part of this checkout and
is not listed in `.github/sibling-repos`; see the note below.

The static file servers are `tools/static_server.mjs` — a dependency-free
stand-in for `npx serve`, which was never a declared dependency of anything
here and so hit the npm registry on every run.

## Known-red and known-blocked

Run `just test-browser-all` and you get the current numbers; these are the
standing ones as of the last sweep.

- **`demo-app › filters tasks`** — red, real product defect. All three filter
  buttons set the filter to `fCompleted`, whichever one is clicked:
  `components.nim`'s `for f in [fAll, fActive, fCompleted]` loop has its
  `let filterVal = f` (and `btn`) hoisted into one closure environment on the
  JS backend, so the three `proc() = store.setFilter(filterVal)` handlers
  share the last value. `createRenderEffect do:` in the same loop is bound
  per-iteration on its first run and shares the environment thereafter, which
  is why only the "completed" button ever shows `.selected`.
- **`ssr-hydration`, 7 of 8** — red. The SSR markup carries no `data-hk`
  attributes (`ui:` emits them only for an element with an explicit
  `hydrate`/`needsId` attribute, and neither `renderFullPageSsr` nor
  `hydrate_entry.nim` sets one), and `hydrate_entry.nim` builds its tree with
  `document.createElement` rather than `getNextElement`, so `hydrate()` cannot
  reuse a single server-rendered node. It renders a second copy instead —
  hence `toHaveCount(3)` seeing 6. This round-trip has never worked; the specs
  were added in 1552585 and the fixture stopped compiling in ddcb5bd, so
  nothing was watching.
- **`metacraft-web-editor`, all 22** — blocked, cannot run here.
  `metacraft-web`'s `build-back-office-editor` does not compile against this
  isonim: `apps/back-office/src/backoffice_editor/workspace.nim:1174` is a
  `case` that does not handle isonim's `skVectorSymbol`, and
  `metacraft-web/nim.cfg` is missing `--path:../isonim-render-serve/src`,
  which `isonim/src/isonim/editor/preview_canvas.nim` needs. Both fixes belong
  in metacraft-web.
