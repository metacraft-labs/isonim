## Real SSR and Chromium hydration ownership; no substitute renderer.
import isonim/dsl/ui
when defined(js):
  import isonim/web/[web_renderer, dom_api, hydration]
  import isonim/rxcore
  var release: proc()
  proc content(): Node =
    onCleanup(proc() =
      {.emit: "globalThis.hydrationCleanups++;".})
    let r = WebRenderer()
    let root = ui(r):
      h1: text "Owned hydration"
    Node(root)
  createRoot proc(dispose: proc()) =
    release = dispose
    hydrate(content, document.getElementById("root"))
  proc disposeApp() = release()
  {.emit: "globalThis.hydrationCleanups=0; globalThis.releaseHydration=`disposeApp`; globalThis.hydrationReady=true;".}
else:
  import isonim/ssr/[renderer, escape, markers]
  proc content(): string =
    ui:
      h1: text "Owned hydration"
  echo "<!doctype html><body><main id='root'>"
  echo renderToString(content)
  echo "</main>"
  echo generateHydrationScript()
