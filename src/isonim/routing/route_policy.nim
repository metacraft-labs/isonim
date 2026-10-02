## isonim/routing/route_policy.nim
##
## The per-route policy tests `routeManifest` generates (C target).
##
## `buildPolicyTests` turns the manifest (and, for its `rpc` entry, every
## registered server function) into HTTP requests with the outcome each
## must have:
##
## | Check | Request | Expected |
## | :--- | :--- | :--- |
## | `pcMethod` | a method no entry serves on the path | `405`, `Allow` naming the entry's method |
## | `pcAuth` | no credentials (`aSession`, `aStaff`, `aAdmin`, `aSignature`) | `401` |
## | `pcRole` | a session one role short (`aStaff`: user, `aAdmin`: staff) | `403` |
## | `pcCsrf` | full credentials, no CSRF token (state-changing, `csrfSession`/`csrfAnon`) | `403` |
## | `pcOrigin` | full credentials and token, a foreign `Origin` | `403` |
## | `pcCache` | a valid request | `2xx`, `Cache-Control` exactly the policy's (absent for `cpNone`) |
## | `pcNoJsForm` | a progressive entry or action submitted as a plain form | `303` to its target |
## | `pcAuthBeforeCanonical` | an entry with a `canonical` policy that needs credentials: none (and, for `aStaff`/`aAdmin`, a session one role short) | `401` (`403`) and no `Location`: authentication ran before the canonicalization hook |
##
## For an entry with a `canonical` policy, `pcCache` also accepts the
## canonical redirect (`301`, `302`, `308`), which carries the entry's
## cache headers: the sample path is not the target's canonical URL, and
## only the application knows that URL.
##
## route_tests.nim runs them against a server.

import std/[json, strutils]
import ../server/policy
import route_spec, match

when not defined(js):
  import ../server/rpc

type
  PolicyCheck* = enum
    pcMethod, pcAuth, pcRole, pcCsrf, pcOrigin, pcCache, pcNoJsForm,
    pcAuthBeforeCanonical

  Credentials* = enum
    crNone       ## nothing
    crUser       ## a signed-in session
    crStaff      ## a staff session
    crAdmin      ## an admin session
    crSignature  ## a valid signature (aSignature)

  RouteSample* = object
    ## A request valid for an entry's request type.
    path*: string     ## the path with sample parameters
    query*: string    ## the required non-path fields, as a query string
    body*: JsonNode   ## the required non-path fields, as a JSON object

  RoutePolicyTest* = object
    route*: string            ## the entry (or `rRpc:<module>/<proc>`)
    check*: PolicyCheck
    httpMethod*: string
    path*: string             ## path and query
    body*: string
    contentType*: string      ## "" for no body
    credentials*: Credentials
    csrf*: CsrfPolicy         ## the policy whose token to send
    sendCsrfToken*: bool
    foreignOrigin*: bool
    asForm*: bool             ## a no-JS form: `_csrf` field, no context header
    expectStatus*: seq[int]   ## acceptable statuses (empty: any 2xx)
    expectCacheControl*: string  ## for pcCache; "" = no Cache-Control
    expectLocation*: string   ## for pcNoJsForm
    expectAllow*: string      ## for pcMethod: a method `Allow` must list

proc credentialsFor*(auth: AuthPolicy): Credentials =
  case auth
  of aPublic, aOptional: crNone
  of aSession: crUser
  of aStaff: crStaff
  of aAdmin: crAdmin
  of aSignature: crSignature

proc methodsServed(specs: seq[RouteSpec]; path: string): tuple[methods: seq[string], anyMethod: bool] =
  for s in specs:
    let p = parsePattern(s.path)
    let m =
      if s.kind == rkRpc: path == s.path or path.startsWith(s.path & "/")
      elif s.prefix: matchPrefix(p, path).matched
      else: matchPath(p, path).matched
    if m:
      if s.kind == rkRpc:
        result.methods.add "POST"
      elif s.httpMethod == "*":
        result.anyMethod = true
      else:
        result.methods.add s.httpMethod
        if s.httpMethod == "GET": result.methods.add "HEAD"

proc formEncode(body: JsonNode): string =
  for k, v in body:
    if result.len > 0: result.add '&'
    let text = if v.kind == JString: v.getStr else: $v
    result.add encodeQueryComponent(k) & "=" & encodeQueryComponent(text)

proc entryTests(specs: seq[RouteSpec]; route, httpMethod, path, query: string;
                body: JsonNode; auth: AuthPolicy; csrf: CsrfPolicy;
                cache: CachePolicy; progressive: bool; target: string;
                isRpc: bool;
                canonical = ccNone): seq[RoutePolicyTest] =
  # A csrfSession mutation needs a session even where anyone may call it.
  let creds =
    if credentialsFor(auth) == crNone and csrf.kind == ckSession and
        isStateChanging(httpMethod): crUser
    else: credentialsFor(auth)
  let target = if target.len == 0: "/" else: target
  let hasBody = httpMethod notin ["GET", "HEAD", "DELETE"]
  let fullPath = if query.len > 0 and not hasBody: path & "?" & query else: path
  let bodyText = if hasBody: $body else: ""
  let ct = if hasBody: "application/json" else: ""
  template base(c: PolicyCheck): RoutePolicyTest =
    RoutePolicyTest(route: route, check: c, httpMethod: httpMethod,
      path: fullPath, body: bodyText, contentType: ct, credentials: creds,
      csrf: csrf, sendCsrfToken: true)

  # Wrong method.
  let served = methodsServed(specs, path)
  if not served.anyMethod:
    for m in ["DELETE", "PATCH", "PUT", "POST", "GET"]:
      if m notin served.methods:
        var t = base(pcMethod)
        t.httpMethod = m
        t.path = path
        t.body = (if m in ["GET", "DELETE"]: "" else: "{}")
        t.contentType = (if m in ["GET", "DELETE"]: "" else: "application/json")
        t.expectStatus = @[405]
        t.expectAllow = httpMethod
        result.add t
        break

  # Authentication and roles.
  if auth in {aSession, aStaff, aAdmin, aSignature}:
    var t = base(pcAuth)
    t.credentials = crNone
    t.expectStatus = @[401]
    result.add t
  if auth in {aStaff, aAdmin}:
    var t = base(pcRole)
    t.credentials = if auth == aStaff: crUser else: crStaff
    t.expectStatus = @[403]
    result.add t

  # CSRF.
  if isStateChanging(httpMethod) and csrf.kind in {ckSession, ckAnon}:
    var t = base(pcCsrf)
    t.sendCsrfToken = false
    t.expectStatus = @[403]
    result.add t
    var o = base(pcOrigin)
    o.foreignOrigin = true
    o.expectStatus = @[403]
    result.add o

  # Authentication before canonicalization (URL-Schema.md §3.1, §5.2 item
  # 4): a caller the entry's auth policy refuses is refused, without a
  # redirect, whatever the canonicalization hook would have answered.
  if canonical != ccNone and auth in {aSession, aStaff, aAdmin, aSignature}:
    var t = base(pcAuthBeforeCanonical)
    t.credentials = crNone
    t.expectStatus = @[401]
    result.add t
    if auth in {aStaff, aAdmin}:
      var r = base(pcAuthBeforeCanonical)
      r.credentials = if auth == aStaff: crUser else: crStaff
      r.expectStatus = @[403]
      result.add r

  # The cache policy of a served response.
  var c = base(pcCache)
  c.expectCacheControl = cacheControl(cache)
  if canonical != ccNone:
    c.expectStatus = @[200, 301, 302, 308]
  result.add c

  # Redirect-after-POST for a no-JS form.
  if progressive and httpMethod == "POST":
    var f = base(pcNoJsForm)
    f.asForm = true
    f.contentType = "application/x-www-form-urlencoded"
    f.body = formEncode(body)
    f.expectStatus = @[303]
    f.expectLocation = target
    result.add f

proc buildPolicyTests*(specs: seq[RouteSpec];
                       samples: seq[RouteSample]): seq[RoutePolicyTest] =
  ## The policy tests of a manifest.  `samples[i]` is a valid request for
  ## `specs[i]` (ignored for `rpc` and `any` entries).  The `rpc` entry
  ## expands to the tests of every registered server function.
  for i, s in specs:
    case s.kind
    of rkAny:
      continue   # a raw handler: its methods and body are its own
    of rkRpc:
      when not defined(js):
        for ep in rpcEndpoints():
          result.add entryTests(specs, s.name & ":" & ep.name, "POST",
            s.path & "/" & ep.name, "",
            (if ep.sample != nil: ep.sample() else: newJObject()),
            ep.auth, ep.csrf, cpPrivateNoStore, ep.isAction, ep.target,
            isRpc = true)
    of rkPage, rkApi:
      result.add entryTests(specs, s.name, s.httpMethod, samples[i].path,
        samples[i].query, samples[i].body, s.auth, s.csrf, s.cache,
        s.progressive, s.target, isRpc = false, canonical = s.canonical)

proc `$`*(t: RoutePolicyTest): string =
  t.route & " " & $t.check & ": " & t.httpMethod & " " & t.path &
    " as " & $t.credentials
