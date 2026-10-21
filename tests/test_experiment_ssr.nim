## Real render roots and nginx-independent handler cores. No mocks.
import std/[tables, strutils]
import isonim/experiments
import isonim/routing/[ssr, match]
import isonim/ssr_nginx/[module_glue, config]
import fixtures/experiments/first
let assignment = newExperimentAssignment()
assignment.assign["home-cta"] = 1
var roots = 0
let routes = @[SsrRouteEntry(pattern: parsePattern("/"), component: proc(): string = $first())]
doAssert renderRoute(routes, "/", setup = proc() =
  inc roots
  beginExperiments(assignment)) == "estimate"
doAssert roots == 1
doAssert assignment.exposed.len == 1
doAssert first() == control
doAssert renderRoute(routes, "/") == "control"
let request = RequestInfo(uri: "/?test=1", httpMethod: "GET", headers: @[("X-Arm", "1")])
var calls = 0
let app: AppRendererReq = proc(req: RequestInfo): string =
  inc calls
  doAssert req == request
  withExperiments(assignment): $first()
let conf = parseLocConf(true, "experiments", hydrationEnabled=false)
let buffered = handleSsrRequest(conf, request, app)
var chunks: seq[string]
let streamed = handleStreamingSsrRequest(conf, request, app, proc(chunk: string) = chunks.add(chunk))
doAssert buffered.statusCode == 200 and buffered.body == "estimate"
doAssert streamed.statusCode == 200 and streamed.body == buffered.body
doAssert chunks.join("") == buffered.body
doAssert calls == 2 and assignment.exposed.len == 1
doAssert first() == control
echo "experiment SSR/request forwarding passed"
