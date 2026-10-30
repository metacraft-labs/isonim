## test_csrf_binding_enforced_at_runtime (isonim-auth.md §2.5): the
## signature binding of the CSRF exemptions is enforced at runtime too,
## behind the compile-time checks of the route manifest and the server
## pragma, so a build that slips a bound exemption past them (a `when nimvm`
## spelling: the compile-time evaluation sees one policy, the program
## another) cannot serve the route:
##   * `compileRoute` refuses, at startup, a manifest entry whose evaluated
##     policy is a bound exemption without `aSignature` (the `when nimvm`
##     manifest below compiles; its route is refused when compiled);
##   * `registerRpc` refuses such a server function at registration;
##   * `enforcePolicies` answers 500 `policy_binding` for such a pair, per
##     request, before authentication or CSRF run.
## NEGATIVE CONTROL: the same three accept the exemption with `aSignature`
## (compileRoute and registerRpc succeed; enforcePolicies goes on to the
## signature check, whose refusal is 401, not 500).
##
## MOCKS: none (in-process request contexts, as t_manifest_mapped_exceptions).

import std/[unittest, asyncdispatch, json, strutils]
import isonim/routing/[manifest, route_dispatch]
import isonim/server/[context, rpc, policy]

type
  XRequest* = object
    a*: string
  XResponse* = object
    ok*: bool

proc pick(): CsrfPolicy =
  ## The `when nimvm` spelling: csrfSession to the compile-time check,
  ## the bound exemption to the program.
  when nimvm: csrfSession
  else: csrfExempt("email-webhook")

routeManifest Evade:
  post rEvade, "/evade", XRequest, XResponse, auth = aSession, csrf = pick()
  post rSigned, "/signed", XRequest, XResponse, auth = aSignature, csrf = csrfExempt("email-webhook")

proc newCtx(httpMethod, path: string): RequestContext =
  newRequestContext(newSsrRequest(httpMethod, path, path, "", @[("Content-Type", "application/json")],
                                  "127.0.0.1", "{}"))

suite "the CSRF binding at runtime":
  test "test_csrf_binding_enforced_at_runtime":
    let specs = routeSpecs(Evade)
    check specs[0].csrf.kind == ckExempt and specs[0].csrf.exemption == "email-webhook"   # vacuity: the evasion worked at compile time
    check specs[0].auth == aSession
    var refused = ""
    try: discard compileRoute(specs[0], nil)
    except ValueError as e: refused = e.msg
    check "rEvade" in refused and "aSignature" in refused
    discard compileRoute(specs[1], nil)                   # the control compiles
    var rpcRefused = ""
    try:
      registerRpc(RpcEndpoint(name: "t_csrf_binding_runtime/evade", auth: aSession,
                              csrf: CsrfPolicy(kind: ckExempt, exemption: "email-webhook")))
    except ValueError as e: rpcRefused = e.msg
    check "evade" in rpcRefused and "aSignature" in rpcRefused
    registerRpc(RpcEndpoint(name: "t_csrf_binding_runtime/signed", auth: aSignature,
                            csrf: CsrfPolicy(kind: ckExempt, exemption: "email-webhook")))
    let ctx = newCtx("POST", "/evade")
    let ok = waitFor ctx.enforcePolicies("rEvade", aSession, specs[0].csrf, "")
    check not ok
    check ctx.response.status == 500
    check "policy_binding" in ctx.responseBody
    let ctl = newCtx("POST", "/signed")
    let ok2 = waitFor ctl.enforcePolicies("rSigned", aSignature, specs[1].csrf, "")
    check not ok2
    check ctl.response.status != 500                      # refused by the signature check, not the binding
