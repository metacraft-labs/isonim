## Dedicated /other entrypoint: only the CTA experiment is a possible read.
import ./second
when defined(js):
  discard second()
else:
  import std/tables
  import isonim/routing/[ssr, match]
  let a = newExperimentAssignment()
  a.assign["home-cta"] = 1
  let routes = @[SsrRouteEntry(pattern: parsePattern("/other"), component: proc(): string = $second())]
  doAssert renderRoute(routes, "/other", setup = proc() = beginExperiments(a)) == "estimate"
  doAssert a.exposed.len == 1 and a.exposed[0].key == "home-cta"
