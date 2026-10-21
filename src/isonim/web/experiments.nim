## Restore server experiment arms before the first hydrating component read.
import std/json
import ../experiments
import ./[hydration, dom_api]
export experiments
proc experimentResourceJson(): cstring =
  {.emit: [result, " = JSON.stringify(globalThis._$HY?.r?.['$exp'] ?? null);"].}
proc hydrateWithExperiments*(code: proc(): Node; element: Element;
    renderId: cstring = cstring"") =
  ## hydrate owns the root; its callback provides the assignment in that root.
  let assignment = assignmentFromResource(parseJson($experimentResourceJson()))
  hydrate(proc(): Node =
    withExperiments(assignment): code(), element, renderId)
