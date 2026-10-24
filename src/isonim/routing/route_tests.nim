## isonim/routing/route_tests.nim
##
## Runs the policy tests `routeManifest` generates (route_policy.nim)
## against a running server, over HTTP (C target; for test programs).
##
## ```nim
## let env = PolicyEnv(baseUrl: "http://127.0.0.1:8080",
##   cookies: proc(c: Credentials): string = ...,
##   sessionCsrfToken: proc(c: Credentials): string = ...)
## for t in policyTests(ForumRoute):
##   let failure = env.runPolicyTest(t)
##   doAssert failure.len == 0, failure
## ```
##
## The environment supplies what only the application knows: the cookie
## of a session at each role and its CSRF token, and the headers of a
## signed request.  An anonymous CSRF token is made up by the runner (the
## `__Host-Anon-CSRF` cookie and the matching header or field).

import std/[httpclient, strutils, uri, json]
import ../server/policy
import route_policy

export route_policy

type
  PolicyEnv* = object
    baseUrl*: string
      ## e.g. `http://127.0.0.1:8080`; its authority is the `Origin` sent.
    cookies*: proc(c: Credentials): string
      ## The `Cookie` header of a session with these credentials.
    sessionCsrfToken*: proc(c: Credentials): string
      ## That session's CSRF token.
    signatureHeaders*: proc(t: RoutePolicyTest): seq[(string, string)]
      ## The headers that make `t` a validly signed request.
    contextHeader*: string
      ## The `X-Isonim-Context` a generated client would send
      ## (`<incarnation>:<account generation>`); "" sends none.
    cacheOverridePath*: proc(t: RoutePolicyTest): string
      ## For `pcCacheOverride`: the path (and query) of a request to
      ## `t.route` that the application answers with `t.overridePolicy`.
      ## Only the application knows which targets get which policy; a test
      ## with no path ("" or no proc) fails.

  PolicyResponse* = object
    status*: int
    headers*: HttpHeaders
    body*: string

const anonTestToken = "policy-test-anon-csrf-token"

proc send*(env: PolicyEnv; t: RoutePolicyTest): PolicyResponse =
  ## Sends the request of `t` and returns the response (redirects are not
  ## followed).
  let client = newHttpClient(maxRedirects = 0, timeout = 30_000)
  defer: client.close()
  var headers = newHttpHeaders()
  let origin = if t.foreignOrigin: "https://attacker.invalid" else: env.baseUrl
  headers["Origin"] = origin
  headers["Sec-Fetch-Site"] = (if t.foreignOrigin: "cross-site" else: "same-origin")
  if not t.asForm and env.contextHeader.len > 0:
    headers[contextHeaderName] = env.contextHeader
  if t.contentType.len > 0:
    headers["Content-Type"] = t.contentType
  if t.accept.len > 0:
    headers["Accept"] = t.accept
  var cookies: seq[string]
  if t.credentials in {crUser, crStaff, crAdmin} and env.cookies != nil:
    let c = env.cookies(t.credentials)
    if c.len > 0: cookies.add c
  var body = t.body
  if t.sendCsrfToken and isStateChanging(t.httpMethod):
    var token = ""
    case t.csrf.kind
    of ckSession:
      if env.sessionCsrfToken != nil:
        token = env.sessionCsrfToken(t.credentials)
    of ckAnon:
      token = anonTestToken
      cookies.add anonCsrfCookieName & "=" & anonTestToken
    else: discard
    if token.len > 0:
      if t.asForm:
        body.add (if body.len > 0: "&" else: "") & csrfFieldName & "=" &
          encodeUrl(token)
      else:
        headers[csrfHeaderName] = token
  elif t.csrf.kind == ckAnon:
    # The cookie alone, without the matching token.
    cookies.add anonCsrfCookieName & "=" & anonTestToken
  if cookies.len > 0:
    headers["Cookie"] = cookies.join("; ")
  if t.credentials == crSignature and env.signatureHeaders != nil:
    for (k, v) in env.signatureHeaders(t):
      headers[k] = v
  let resp = client.request(env.baseUrl & t.path, httpMethod = t.httpMethod,
                            body = body, headers = headers)
  result.status = resp.code.int
  result.headers = resp.headers
  result.body = resp.body

proc headerText(r: PolicyResponse; name: string): string =
  ## The header's value ("" when absent; repeated fields joined with ", ").
  if not r.headers.hasKey(name):
    return ""
  seq[string](r.headers.getOrDefault(name)).join(", ")

proc fieldsOf(value: string): seq[string] =
  ## The lower-cased field names of a list header such as `Vary`.
  for f in value.split(','):
    if f.strip.len > 0:
      result.add f.strip.toLowerAscii

proc varyNames(r: PolicyResponse; field: string): bool =
  let fields = fieldsOf(r.headerText("Vary"))
  field.toLowerAscii in fields or "*" in fields

proc isRedirectStatus(status: int): bool =
  status in [301, 302, 303, 307, 308]

proc runPolicyTest*(env: PolicyEnv; t: RoutePolicyTest): string =
  ## "" when the server answers `t` as the policy requires, else what was
  ## wrong.
  var t = t
  if t.check == pcCacheOverride:
    if env.cacheOverridePath != nil:
      t.path = env.cacheOverridePath(t)
    if t.path.len == 0:
      return $t & ": the environment names no request answered with " &
        $t.overridePolicy & " (PolicyEnv.cacheOverridePath)"
  let r = env.send(t)
  let fail = proc(msg: string): string =
    $t & ": " & msg & " (status " & $r.status & ", body " &
      r.body[0 ..< min(r.body.len, 200)] & ")"
  let cc = r.headerText("Cache-Control")
  let mediaType = r.headerText("Content-Type").split(';')[0].strip.toLowerAscii
  if t.expectStatus.len > 0:
    if r.status notin t.expectStatus:
      return fail("expected status " & $t.expectStatus)
  elif r.status < 200 or r.status > 299:
    return fail("expected a 2xx status")
  case t.check
  of pcMethod:
    let allow = r.headers.getOrDefault("Allow").toString
    var listed = false
    for m in allow.split(','):
      if m.strip == t.expectAllow: listed = true
    if not listed:
      return fail("Allow '" & allow & "' does not list " & t.expectAllow)
  of pcCache:
    if cc != t.expectCacheControl:
      return fail("Cache-Control '" & cc & "', expected '" &
        t.expectCacheControl & "'")
    if t.jsonVariant and r.status in 200 .. 299:
      if mediaType != "text/html":
        return fail("Content-Type '" & mediaType & "': the page's HTML " &
          "request was not answered with its HTML")
      if not r.varyNames("Accept"):
        return fail("Vary '" & r.headerText("Vary") & "' does not name " &
          "Accept, though the page also answers JSON")
  of pcJsonSuffix, pcJsonAccept:
    if cc != t.expectCacheControl:
      return fail("Cache-Control '" & cc & "', expected '" &
        t.expectCacheControl & "'")
    if r.status.isRedirectStatus:
      if t.expectLocationSuffix.len > 0:
        let loc = r.headerText("Location").split({'?', '#'})[0]
        if not loc.endsWith(t.expectLocationSuffix):
          return fail("Location '" & r.headerText("Location") &
            "' drops the " & t.expectLocationSuffix & " of the JSON variant")
    else:
      if mediaType != "application/json":
        return fail("Content-Type '" & mediaType & "', expected " &
          "application/json for the JSON variant")
      try:
        discard parseJson(r.body)
      except CatchableError:
        return fail("the JSON variant's body is not JSON")
      if not r.varyNames("Accept"):
        return fail("Vary '" & r.headerText("Vary") & "' does not name Accept")
  of pcCacheOverride:
    # Exactly the policy's headers: Cache-Control, Pragma and Expires as
    # the policy has them (or not), and Vary naming the policy's fields.
    let want = cacheHeaders(t.overridePolicy)
    proc wanted(name: string): string =
      for (k, v) in want:
        if cmpIgnoreCase(k, name) == 0: return v
      ""
    for name in ["Cache-Control", "Pragma", "Expires"]:
      if r.headerText(name) != wanted(name):
        return fail(name & " '" & r.headerText(name) & "', expected '" &
          wanted(name) & "' (" & $t.overridePolicy & ")")
    for f in fieldsOf(wanted("Vary")):
      if not r.varyNames(f):
        return fail("Vary '" & r.headerText("Vary") & "' does not name " &
          f & " (" & $t.overridePolicy & ")")
  of pcNoJsForm:
    let loc = r.headers.getOrDefault("Location").toString
    if loc != t.expectLocation:
      return fail("Location '" & loc & "', expected '" & t.expectLocation & "'")
  of pcCsrf, pcOrigin:
    if "\"csrf\"" notin r.body:
      return fail("the refusal is not a CSRF refusal")
  of pcAuthBeforeCanonical:
    if r.headers.hasKey("Location"):
      return fail("Location '" & r.headers.getOrDefault("Location").toString &
        "': the canonicalization hook answered before authentication")
  of pcAuth, pcRole:
    discard
  ""
