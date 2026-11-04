## Real renderer, completed QA-effective resource, serializer and hydration root.
import std/[json, tables]
import isonim/dsl/ui
import isonim/core/context
import isonim/experiments

type Checkout {.experimentKey: "checkout".} = enum
  control, variant
when defined(js):
  var hostAssignment: ExperimentAssignment
  proc mutateHost() {.exportc: "envMutateExperimentHost".} =
    if hostAssignment != nil:
      hostAssignment.assign["checkout"] = 8
      hostAssignment.qaOverrides["checkout"] = 9
      hostAssignment.exposed.setLen(0)
proc app(r: auto): auto =
  let arm = useExperiment[Checkout]()
  # Retained observed arm wins over later host mutation during the render.
  let active = useContext(ExperimentCtx)
  when defined(js): hostAssignment = active
  if active != nil:
    active.assign["checkout"] = 0
    active.qaOverrides["checkout"] = 0
  discard useExperiment[Checkout]()
  when defined(js):
    proc publish(text: cstring) {.importjs: "globalThis.envClientResource=JSON.parse(#)".}
    publish(cstring($experimentResource(active)))
  isomorphicUi(r):
    tdiv:
      if arm == variant:
        button(onclick = proc() = discard): text "Variant"
      else:
        span: text "Control"
when defined(js):
  import isonim/web/[web_renderer, dom_api, experiments]
  when defined(recordEnvPlainHydrate):
    import isonim/web/hydration
    hydrate(proc(): Node = Node(app(WebRenderer())), document.getElementById("root"))
  else:
    hydrateWithExperiments(proc(): Node = Node(app(WebRenderer())), document.getElementById("root"))
else:
  import isonim/ssr/[renderer, escape, markers, experiments]
  import isonim/routing/[ssr, match]
  let assignment =
    when defined(recordEnvNoResource): ExperimentAssignment(nil)
    else: newExperimentAssignment("2026-11-04", production = false)
  if not assignment.isNil:
    assignment.assign["checkout"] = 0
    assignment.qaOverrides["checkout"] = 1
  let routes = @[SsrRouteEntry(pattern: parsePattern("/"), component: proc(): string = app(0))]
  echo renderRoute(routes, "/", setup = proc() = beginExperiments(assignment))
  echo generateHydrationScript()
  when not defined(recordEnvNoResource): echo serializeExperiments(assignment)
