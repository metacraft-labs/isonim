## One authored tree for C SSR and the real browser; no mock renderer.
import isonim/dsl/ui
when defined(js):
  import isonim/web/[dom_api, web_renderer, hydration]
else:
  import isonim/ssr/[renderer, escape, markers]

proc leaf(r: auto): auto =
  isomorphicUi(r):
    button(onclick = proc() = discard): text "leaf"

proc branch(r: auto): auto =
  isomorphicUi(r):
    tdiv:
      raw leaf(r)
      raw leaf(r)

proc instances(r: auto): auto =
  isomorphicUi(r):
    section:
      raw branch(r)
      raw branch(r)
      tdiv(key = "anchored"):
        raw leaf(r)

when defined(js):
  hydrate(proc(): Node = Node(instances(WebRenderer())), document.getElementById("root"))
  proc inspect() {.importjs: "globalThis.instanceClaims = [...document.querySelectorAll('[data-iid]')].map(el=>({iid:el.getAttribute('data-iid'),same:globalThis.__isonimIids.get(el.getAttribute('data-iid')).deref()===el}));".}
  when defined(isonimStableIds): inspect()
else:
  echo renderToString(proc(): string = instances(0))
  echo generateHydrationScript()
