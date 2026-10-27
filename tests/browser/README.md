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

The focused environment metadata gate (`python3 tools/test_environment_metadata.py`,
also in `just test-nondet`) uses the real browser platform directly. The separate
strict owner-library integration gate is `just test-environment-owner`: set
`CT_ARTIFACT` to the installed recorder package's `lib/codetracer-js-recorder`
directory. Missing owner artifacts fail this explicit integration gate; they
are never skipped. That gate imports the actual generated environment helper
without activating recording or changing framework toolchain/dependency pins.

The same-instance boot Date controls run in `test-nondet` without an owner
artifact. `just test-boot-date-owner` is the separate strict integration gate:
with the same `CT_ARTIFACT` setting, it requires the actual owner's IEEE bit
conversion and strict Clock3 codec. Missing artifacts fail this gate.

`test-nondet` also exercises lazy backend forwarding on C, proper windowless
Node and Chromium, including supported TestClock/FakeAsyncContext scheduling,
transport routing, explicit hooks/clearing and source-restoration controls.
`just test-nondet-bridge-owner` is its separate strict actual-owner integration
(requires `CT_ARTIFACT`). It uses the real Recorder/runtime/cursor to verify both
Clock2 reads, not a fake replay provider. The intentionally incomplete probe
backends leave storage visibly unconsumed; this is bridge preparation, not a
recording/replay/conformance qualification or active framework declaration.

### Internal ordinary-read foundation

`just test-nondet` includes artifact-free C/windowless-JS custom-clock guard
compatibility. Acceptance of the internal partial backend additionally REQUIRES
`CT_ARTIFACT=<installed recorder package root> just test-replay-reads-owner`.
Missing artifact fails closed; it is never an optional skip. This separate gate
uses actual Recorder→strict codec→installed runtime/cursor in Chromium, both default
and directly recordable builds, and a storage-dispatch inverse with unchanged
positive clock/context controls. Explicit prior public env snapshot is internal
constructor configuration, NOT reconstructed archive data or a public API. Only
Clock2/wall Clock3, storage/cookie, viewport, media queries and validated registered-IID measurement
are supported; all other paths refuse. Measurement requires stable IDs and the
existing renderer registry to resolve the exact passed element. Unknown, missing,
forged and superseded identities refuse before any layout or cursor read.
The same mandatory owner gate checks viewport through logged window width then
height, using genuine browser observations after a resize, zero platform reads
on replay, first/second-read mismatch latching and a source-restoration control
that exposes raw getters plus an unconsumed log record. Unregistered and other target forms still
refuse. No automatic replay,
protocol declaration, RNG mapping, active recording or complete replay support follows.

The wall clock gate compares all 20 native Date inputs against the current stock
Time projection: 10 exact Time values and 10 preserved genuine RangeDefects.
Replay consumes Clock3 without reading Date or another clock; existing negative
and seconds-range library failures are not normalized away. All full exception
traces are retained. Raw-Date, wrong-source and normalization source inverses
must fail specifically while ordinary clock/context controls stay positive.

The private implementation is additionally compiled only by the INTERNAL
`isonimInternalReplayReads` preparation define; this is not a supported public
build flag/API. Ordinary/default and recordable artifacts omit its private
RTTI/state/guards entirely. The explicit owner driver alone enables the private
constructor; artifact-free custom compatibility also checks its negative guards.

`test-replay-ssr-guard` is a mandatory artifact-free dependency of both
`test-nondet` and `test-replay-reads-owner`. It compiles the ACTUAL native capture
generator with ordinary, recordable and explicit internal defines. Ordinary and
recordable output must match the exact published capture-body hash and perform
no private selector lookup/callback/getter in controlled collision hosts. The
internal generator retains refusal/switch-away controls; restoring unconditional
emission must fail BOTH ordinary and recordable oracles independently. These VM
script-registration checks supplement the mandatory real-owner Chromium tests.

The mandatory owner gate also checks media-query serialization through native
unadopted CSSOM syntax objects and logged booleans. It traps live matching and
layout, covers repeated reads and exact owner divergence, and rejects both raw
matching restoration and authored-query serialization mutations. Missing owner
artifacts fail this gate rather than skipping it.

`test-replay-measure-owner` is the separate mandatory registered-node geometry
gate, also included by `test-replay-reads-owner`. One compiled runtime sets up
genuine DSL nodes before deliberate private selection. Actual browser rect
samples retain eight fields privately and project four publicly; changed geometry
and traps prove values come from checked log records. Live/detached/replaced and
duplicate identities retain existing resolver semantics. Raw restoration and
identity-bypass source mutations must fail distinct oracles. Early stable-ID
selection must initialize no renderer registry. The actual generic recorder's
weak-reference Refusal stays observable; this preparation does not qualify that
factory path for recording or settle weak-reference replay compatibility.

`test-replay-timers-owner` checks the private timeout preparation through actual
native RealClock callback observations, the recorder's strict codec and its owned
replay scheduler. It covers new timeout registration for each repeating arm,
cancellation, callback/microtask order, errors, delay conversion and explicit
completion-only disposal. Cancellation has no log record. Tests compare genuine
DOM checkpoints and reject raw-timer, missing-unregister, interval-kind and
identity-reset source mutations. This remains internal preparation: it installs
no automatic recording, protocol declaration or supported public build API.
Missing owner artifacts fail the gate. Ordinary/dormant artifacts omit its
private timer state entirely.
