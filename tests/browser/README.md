# Browser tests (Playwright)

98 tests in 10 spec files. They are the executable specification for the
packaged editor, the SSR/hydration round-trip over real nginx, the HMR
transports, the Web Worker build target, and server functions and request
contexts over real nginx.

```
specs/demo-app.spec.ts               8 tests   demo-app              :8080
specs/ssr-hydration.spec.ts         16 tests   ssr-hydration         :8081 (8 cases x 2 SSR modes)
specs/hmr.spec.ts                   11 tests   hmr                   :8082
specs/hmr_transport.spec.ts          3 tests   hmr-transport         :8083
specs/hmr_parametric.spec.ts        11 tests   hmr-parametric        :8084
specs/web-worker.spec.ts             4 tests   web-worker            :8086
specs/rpc-over-nginx.spec.ts         4 tests   nginx-rpc             :8095
specs/request-context-generation.spec.ts
                                     8 tests   nginx-rpc             :8095 (+ :8096, its slow-body upstream)
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
repro exec -- just test-browser-all     # build every artifact, then run 51 tests
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
| `ssr-hydration` | nginx + the ngx-isonim module with the hydration app, and `build/nginx-fixture/www/hydrate.js` (see `tests/nginx/README.md`) | `just build-nginx-fixture` |
| `hmr` | `tests/browser/hmr_fixture` | `just build-hmr-fixture` |
| `hmr-transport` | `build/isonim_test_server` (a Nim dev server) | `just build-hmr-transport-fixture` |
| `hmr-parametric` | `tests/browser/hmr_parametric_fixture` | `just build-hmr-parametric-fixture` |
| `web-worker` | `build/web-worker-fixture` (a worker chunk, its page script, the in-thread control, `bundle-manifest.json`) | `just build-web-worker-fixture` |
| `nginx-rpc` | nginx + the ngx-isonim module (`build/nginx-fixture`, see `tests/nginx/README.md`) | `just build-nginx-fixture` |
| `editor-example` | `build/editor` | `just editor-build` |
| `metacraft-web-editor` | `../metacraft-web/dist/back-office-editor` | `(cd ../metacraft-web && just build-back-office-editor)` |

`just browser-test-deps` builds the static ones (`demo-app`, the three HMR
projects, `web-worker`, `editor-example`). `nginx-rpc` and `ssr-hydration` share the nginx
fixture, built by `just build-nginx-fixture` (it needs the `ngx-isonim`
sibling and nix) and run by `just test-nginx`. The last is a **sibling
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
- **`metacraft-web-editor`, all 22** — red, and two layers of the failure are
  in the sibling repo rather than here.

  Building the bundle at all needs two metacraft-web-side fixes:
  `metacraft-web/nim.cfg` has no `--path:../isonim-render-serve/src`, which
  `isonim/src/isonim/editor/preview_canvas.nim` imports; and
  `apps/back-office/src/backoffice_editor/workspace.nim:1174` is a `case`
  that does not handle isonim's `skVectorSymbol`. With both worked around,
  all 22 still fail, in two groups:

  * 9 never get a writable bridge — `.editor-statusbar` reads
    `…/mainViewmainIsoNim Editor v0.1.0` where the spec wants
    `write writable`, so `?writeBridge=1` is not engaging.
  * the remaining 13 die on `net::ERR_CONNECTION_REFUSED`: the dev bridge
    (`metacraft-web/tools/serve_editor_dev_bridge.mjs`) logs
    `Editor dev bridge listening`, serves the first few specs, and then exits
    mid-run without a message. Everything after it is collateral.

  This project is not in either CI job. It needs a sibling repo that is not
  in this checkout and is not listed in `.github/sibling-repos`.
