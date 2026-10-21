## Real isomorphic DSL fixture; differing arms select different DOM structures.
import isonim/dsl/ui
import ./[first, second]
when defined(js):
  import std/json
  import isonim/core/context
  import isonim/web/[web_renderer, dom_api, experiments]
  proc publishExposure(data: cstring) {.importjs: "globalThis.clientExperimentResource = JSON.parse(#)".}
else:
  import std/[tables, json]
  import isonim/ssr/[renderer, escape, markers, experiments]
  import isonim/ssr/serializer
  import isonim/routing/[ssr, match]
proc app(r: auto): auto =
  let arm = first()
  discard useExperiment[Cta]()
  discard second()
  discard color()
  when defined(js): publishExposure(cstring($experimentResource(useContext(ExperimentCtx))))
  isomorphicUi(r):
    tdiv:
      if arm == control:
        span: text "Control"
      else:
        button(onclick = proc() = discard): text "Estimate"
when defined(js):
  when defined(experimentPlainHydrate):
    import isonim/web/hydration
    hydrate(proc(): Node = Node(app(WebRenderer())), document.getElementById("root"))
  else:
    hydrateWithExperiments(proc(): Node = Node(app(WebRenderer())), document.getElementById("root"))
else:
  let assignment = newExperimentAssignment("2026-10-22</script><script>globalThis.experimentInjected=1</script>")
  assignment.assign["home-cta"] = 1
  assignment.assign["__proto__"] = 1
  assignment.assign["</script><script>globalThis.experimentInjected=2</script>"] = 0
  let routes = @[SsrRouteEntry(pattern: parsePattern("/"), component: proc(): string = app(0))]
  echo renderRoute(routes, "/", setup = proc() = beginExperiments(assignment))
  echo generateHydrationScript()
  echo serializeExperiments(assignment)
  echo serializeResources([("__proto__", %*{"sentinel": true})])
