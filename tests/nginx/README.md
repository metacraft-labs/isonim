# The nginx fixture

Server functions over HTTP and the typed route manifest, tested against real
nginx with the real `ngx-isonim` module (milestone IFP-M2 of
`isonim-specs/milestones/2026-10-02-isonim-forum-prerequisites.milestones.org`).

| File | What |
| --- | --- |
| `fixture_rpc.nim` | server functions (`{.server.}`, one `{.action.}`), compiled for both targets |
| `fixture_manifest.nim` | a route manifest with every CSRF, cache and auth policy, a progressive action and the `rpc` mount |
| `fixture_app.nim` | the server side: hooks (sessions, signatures, incarnation) and the manifest's dispatch as the async app `fixture`; compiled into the module with `-d:ngxIsonimAppModule` |
| `fixture_client.nim` | the browser client: calls through the generated clients only, exposes `window.fx` |
| `fixture_conf.sh` | the nginx configuration (one worker; `isonim_rpc on; isonim_rpc_app fixture;`; with `ISONIM_FIXTURE_UPSTREAM_PORT`, `/api/v1/slow-body` proxied to the spec-run slow-body server) |
| `build_fixture.sh` | builds `build/nginx-fixture/` (module, client, `env.sh` with the nginx binary) |
| `serve_fixture.sh` | runs it in the foreground (Playwright's web server for `nginx-rpc`) |
| `run_mutants.sh` | the falsifying mutations of the browser specs |

Everything is built with `-d:isonimRpcPrefix=/api/v1/rpc`, the forum's mount.

```sh
repro exec -- just build-nginx-fixture   # needs ../ngx-isonim and nix
repro exec -- just test-nginx            # route manifest + nginx-rpc + mutants
```

The tests:

* `tests/test_route_manifest.nim`: each entry's dispatch, client, form and
  policy tests; the generated policy tests run against the fixture
  (including authentication before canonicalization for the staff-only,
  canonicalized `rTopic`); the no-JS form submission ends in a 303; a
  state-changing entry with `csrfNone` does not compile.  It runs against
  `ISONIM_NGINX_MODULE` when set (run_mutants.sh's `canonical-first`).
* `tests/browser/specs/rpc-over-nginx.spec.ts`: async server functions from
  the browser (typed results, a 1 MB body, 413 over the limit, a request
  served while a slow server function is suspended, no XMLHttpRequest).
* `tests/browser/specs/request-context-generation.spec.ts`: responses that
  arrive after an account switch, an incarnation change or a navigation are
  dropped without touching signals, caches or storage, including a
  navigation while the body is read (a test-run server behind nginx holds
  the body back) and one after the body was read (only the
  navigation-generation check can drop it).

Playwright needs a Chromium: `PLAYWRIGHT_CHROMIUM_EXECUTABLE`, or `chromium`
on `PATH` (the dev shell has one).
