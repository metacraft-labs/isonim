## Protects the `just dev` live-reload server wiring for this site: that it
## serves the THEMED stylesheet (Metacraft token CSS prepended) + branded,
## reload-injected pages over its own content/assets/static, and that a content
## edit fires a live-reload broadcast. Drives the exact `newDocsDevServer` wiring
## `just dev` runs, at the `handleRoute`/`pollForChanges` level (no bound socket),
## the same in-process idiom as the framework's own dev-server suite.

import std/[unittest, os, strutils]
import ../src/dev   # newDocsDevServer + (re-exported) dev_server API

suite "IsoNim docs dev server (themed live-reload wiring)":
  test "serves the themed stylesheet + branded, reload-injected home page":
    let ds = newDocsDevServer()              # real content/ + assets/ + static/
    let (hs, hct, home) = handleRoute(ds, "/")
    check hs == 200
    check hct == "text/html; charset=utf-8"
    check home.contains("IsoNim")            # this site's branding
    check home.contains(defaultLiveReloadPath)  # hot-reload client injected
    let (cs, cct, css) = handleRoute(ds, "/assets/style.css")
    check cs == 200
    check cct == "text/css; charset=utf-8"
    check css.contains("--docs-")            # Metacraft token CSS prepended
    # a font ships under static/ but is served under /assets/ (multi-dir search)
    check handleRoute(ds, "/assets/fonts/Geist-Variable.woff2").status == 200

  test "a content edit fires a live-reload broadcast":
    let tmp = getTempDir() / "isonim_docs_users_devreload"
    removeDir(tmp); createDir(tmp)
    writeFile(tmp / "index.md", "---\ntitle: Home\n---\n# Home\n")
    let ds = newDocsDevServer(contentDir = tmp)
    let q = ds.hub.subscribe()
    check q[].len == 0
    writeFile(tmp / "index.md", "---\ntitle: Home\n---\n# Home edited\n")
    check ds.pollForChanges().len == 1       # the watcher saw the edit
    check q[] == @[reloadMessage]            # and broadcast a reload
