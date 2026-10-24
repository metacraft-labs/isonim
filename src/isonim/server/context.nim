## isonim/server/context.nim
##
## The request context: what a server function, a route handler and a
## renderer know about the request they serve.
##
## ```nim
## proc likePost(ctx: RequestContext; postId: int): Future[int] {.server.} =
##   if ctx.session.isNil: raise newException(ValueError, "signed out")
##   ...
## ```
##
## A `RequestContext` holds
##
## * `request`: the `SsrRequest` (method, path, query, headers, cookies,
##   `Host`, client address, body), the same object renderers receive;
## * `response`: the `SsrResponse` the handler may shape (status, headers,
##   cookies, redirect) before the server sends it;
## * `session`: the caller's session, as the application's session resolver
##   found it (nil when there is none);
## * `csrf`: the result of the CSRF verification the server ran before the
##   handler (`cvVerified`, `cvSafeMethod`, `cvExempt`, or why it failed);
## * `clientContext`: the `X-Isonim-Context` header the generated client
##   sent (URL-Schema.md §5.4);
## * `pathParams`: the parameters the route pattern matched.
##
## The application plugs in what only it can know through `serverHooks`:
## how to find the session of a request, how to verify a signed request,
## the instance's current incarnation and the origins it serves.
##
## On the JS target `RequestContext` is an empty placeholder, so a server
## function keeps one signature on both targets: the browser stub ignores
## the context argument (pass `nil`), the server fills it.

import policy
export policy

when defined(js):
  type
    RequestContext* = ref object
      ## The browser has no server request context; server-function stubs
      ## accept one (usually `nil`) and ignore it.

else:
  import std/[asyncdispatch, strutils, sysrand, base64, json]
  import request, response
  export request, response

  type
    Session* = ref object of RootObj
      ## A signed-in session, as the application's resolver returns it.
      ## Applications subclass it to carry their own fields.
      subject*: string     ## who: the user or account identifier
      staff*: bool         ## may use `aStaff` routes
      admin*: bool         ## may use `aAdmin` (and `aStaff`) routes
      csrfToken*: string   ## the token `csrfSession` requests must carry
                           ## (isonim-auth.md §2.5: derived from the session)

    CsrfVerdict* = enum
      cvNotChecked = "not-checked"   ## the server did not check (yet)
      cvSafeMethod = "safe-method"   ## GET / HEAD / OPTIONS: nothing to check
      cvVerified = "verified"        ## token, Origin and Sec-Fetch-Site good
      cvExempt = "exempt"            ## a §2.5 exemption
      cvBadOrigin = "bad-origin"     ## Origin missing or foreign
      cvBadFetchSite = "bad-fetch-site"  ## Sec-Fetch-Site missing or cross-site
      cvMissingToken = "missing-token"   ## no X-CSRF-Token / _csrf, or no
                                         ## anonymous CSRF cookie
      cvBadToken = "bad-token"       ## the token does not match
      cvNoSession = "no-session"     ## csrfSession without a session

    PageVariant* = enum
      ## The representation of a route-manifest page a request gets
      ## (isonim-routing-server-functions.md, "JSON Variants of a Page").
      pvHtml        ## the page's HTML with its data embedded
      pvJsonSuffix  ## `Page.data` as JSON: the last path parameter ended
                    ## in `.json` (removed before decoding and the hook)
      pvJsonAccept  ## `Page.data` as JSON: `Accept` preferred it

    RouteNotFound* = object of CatchableError
      ## Raised by a route handler (or the canonicalization hook) whose
      ## target is gone or no longer visible; the dispatch answers it as the
      ## hook's `coNotFound` (404, nothing the hook or handler set is kept).

    ClientContextHeader* = object
      ## The parsed `X-Isonim-Context: <incarnation_id>:<account_generation>`.
      present*: bool        ## the header was sent
      valid*: bool          ## and parsed
      incarnationId*: string
      accountGeneration*: int

    RequestContext* = ref object
      request*: SsrRequest
      response*: SsrResponse
      session*: Session
      sessionResolved*: bool
      csrf*: CsrfVerdict
      clientContext*: ClientContextHeader
      pathParams*: seq[(string, string)]
      responseBody*: string
        ## The body a handler produced (`write`, `respondJson`); the server
        ## sends it after the handler's future completes.
      failure*: ref CatchableError
        ## What a handler raised, when the server answered 500 for it; the
        ## server logs it.
      pageVariant*: PageVariant
        ## Which representation of a page the dispatch answers with (always
        ## `pvHtml` outside pages with a JSON variant).
      cachePolicy: CachePolicy
        ## The cache policy of this response (`responseCachePolicy`): the
        ## entry's, or a stricter one `setCachePolicy` accepted.  The
        ## default, `cpPrivateNoStore`, is the strictest, so a context the
        ## route dispatch did not set up accepts no weakening either.
      cacheChoices: seq[CachePolicy]
        ## The policies `setCachePolicy` may pick: the entry's `cache` and
        ## its `cacheOverrides`.

    RequestHandler* = proc(ctx: RequestContext): Future[void]
      ## A server-side request handler: reads `ctx.request`, leaves the
      ## response (status, headers, body) in `ctx`.  ngx-isonim runs one at
      ## an `isonim_rpc` location (`registerAsyncApp`), and
      ## `routeManifest` generates one (`manifestApp`).

    SessionResolver* = proc(req: SsrRequest): Future[Session]
      ## Finds the session of a request (cookie, bearer token); nil when
      ## there is none.  Asynchronous, because it usually asks a database.

    SignatureVerifier* = proc(ctx: RequestContext; route: string): Future[bool]
      ## Verifies a signed request (`aSignature`) for the named route or
      ## server function.

    ServerHooks* = object
      ## What the application tells the server.  Every field is optional.
      resolveSession*: SessionResolver
        ## Without one, no request has a session.
      verifySignature*: SignatureVerifier
        ## Without one, every `aSignature` request is refused (401).
      currentIncarnation*: proc(): string
        ## The instance's current incarnation id.  When set, a
        ## state-changing request whose `X-Isonim-Context` names another
        ## incarnation is refused with 409 `context_stale`.
      allowedOrigins*: seq[string]
        ## The origins (`scheme://host[:port]`) state-changing requests may
        ## come from.  Empty: the origin's host must equal the request's
        ## `Host` header.
      onCachePolicyRefused*: proc(ctx: RequestContext;
                                  requested, kept: CachePolicy)
        ## Told of every `setCachePolicy` that was refused (a policy weaker
        ## than the response's, or one the entry does not declare):
        ## `requested` was asked for, `kept` is what the response keeps.

  var serverHooks* {.threadvar.}: ServerHooks
    ## The application's hooks.  Set once at startup (ngx-isonim: from the
    ## app module's registration proc).

  proc parseContextHeader*(value: string): ClientContextHeader =
    ## Parses `<incarnation_id>:<account_generation>`.
    result.present = true
    let colon = value.rfind(':')
    if colon <= 0:
      return
    try:
      result.accountGeneration = parseInt(value[colon + 1 .. ^1].strip())
      result.incarnationId = value[0 ..< colon].strip()
      result.valid = result.incarnationId.len > 0
    except ValueError:
      result.valid = false

  proc newRequestContext*(req: SsrRequest;
                          resp: SsrResponse = nil): RequestContext =
    ## A context for `req`.  The session is not resolved yet
    ## (`resolveSession`), and CSRF is `cvNotChecked`.
    result = RequestContext(request: req,
                            response: if resp.isNil: newSsrResponse() else: resp,
                            csrf: cvNotChecked)
    if req.hasHeader(contextHeaderName):
      result.clientContext = parseContextHeader(req.header(contextHeaderName))

  proc resolveSession*(ctx: RequestContext): Future[void] {.async.} =
    ## Runs the application's session resolver once per request.
    if ctx.sessionResolved:
      return
    ctx.sessionResolved = true
    let resolver = serverHooks.resolveSession
    if resolver != nil:
      ctx.session = await resolver(ctx.request)

  proc pathParam*(ctx: RequestContext; name: string; default = ""): string =
    for (k, v) in ctx.pathParams:
      if k == name:
        return v
    default

  # ------------------------------------------------------------------------
  # CSRF (isonim-auth.md §2.5)
  # ------------------------------------------------------------------------

  proc constantTimeEquals*(a, b: string): bool =
    ## Compares two tokens without an early exit on the first difference.
    if a.len != b.len:
      return false
    var diff = 0
    for i in 0 ..< a.len:
      diff = diff or (ord(a[i]) xor ord(b[i]))
    diff == 0

  proc originAuthority(origin: string): string =
    ## `https://host:port` -> `host:port`; "" when it is not an origin.
    let sep = origin.find("://")
    if sep <= 0:
      return ""
    result = origin[sep + 3 .. ^1]
    if result.len == 0 or '/' in result:
      return ""

  proc originAllowed*(ctx: RequestContext): bool =
    ## Whether the request's `Origin` is one the instance serves.
    let origin = ctx.request.header("Origin")
    if origin.len == 0 or origin == "null":
      return false
    if serverHooks.allowedOrigins.len > 0:
      for o in serverHooks.allowedOrigins:
        if cmpIgnoreCase(o, origin) == 0:
          return true
      return false
    let authority = originAuthority(origin)
    authority.len > 0 and cmpIgnoreCase(authority, ctx.request.host) == 0

  proc requestCsrfToken*(ctx: RequestContext; formToken = ""): string =
    ## The token the request carries: the `X-CSRF-Token` header, else the
    ## `_csrf` form field.
    result = ctx.request.header(csrfHeaderName)
    if result.len == 0:
      result = formToken

  proc verifyCsrf*(ctx: RequestContext; policy: CsrfPolicy;
                   formToken = ""): CsrfVerdict =
    ## Checks a request against `policy` and records the verdict in
    ## `ctx.csrf`.  On a state-changing request: `Origin` must be one the
    ## instance serves, `Sec-Fetch-Site` must be `same-origin` or
    ## `same-site`, and the token (header or `_csrf` field) must equal the
    ## session's token (`csrfSession`) or the anonymous CSRF cookie
    ## (`csrfAnon`), compared in constant time.  Call `resolveSession`
    ## first.
    result =
      if not isStateChanging(ctx.request.httpMethod): cvSafeMethod
      elif policy.kind == ckExempt: cvExempt
      elif policy.kind == ckNone: cvMissingToken
      elif not ctx.originAllowed(): cvBadOrigin
      elif ctx.request.header("Sec-Fetch-Site") notin ["same-origin", "same-site"]:
        cvBadFetchSite
      else:
        let token = ctx.requestCsrfToken(formToken)
        if policy.kind == ckSession:
          if ctx.session.isNil or ctx.session.csrfToken.len == 0: cvNoSession
          elif token.len == 0: cvMissingToken
          elif constantTimeEquals(token, ctx.session.csrfToken): cvVerified
          else: cvBadToken
        else:
          let cookie = ctx.request.cookie(anonCsrfCookieName)
          if token.len == 0 or cookie.len == 0: cvMissingToken
          elif constantTimeEquals(token, cookie): cvVerified
          else: cvBadToken
    ctx.csrf = result

  proc csrfPassed*(v: CsrfVerdict): bool =
    v in {cvSafeMethod, cvVerified, cvExempt}

  proc anonCsrfToken*(ctx: RequestContext): string =
    ## The anonymous CSRF token of this visitor: the `__Host-Anon-CSRF`
    ## cookie, issued now (256 random bits, HttpOnly, SameSite=Lax, Secure)
    ## if the request has none.  Render it into the page (meta tag or
    ## `_csrf` field); it is never readable from script.
    result = ctx.request.cookie(anonCsrfCookieName)
    if result.len == 0:
      result = base64.encode(urandom(32), safe = true).strip(
        leading = false, chars = {'='})
      ctx.response.setCookie(anonCsrfCookieName, result, CookieOptions(
        path: "/", secure: true, httpOnly: true, sameSite: sameSiteLax))
      # Later reads in this request see the cookie too.
      ctx.request.cookies.add((anonCsrfCookieName, result))

  proc csrfTokenFor*(ctx: RequestContext): string =
    ## The token the page should carry: the session's, else the anonymous
    ## one.
    if ctx.session != nil and ctx.session.csrfToken.len > 0:
      ctx.session.csrfToken
    else:
      ctx.anonCsrfToken()

  # ------------------------------------------------------------------------
  # Authentication
  # ------------------------------------------------------------------------

  proc checkAuth*(ctx: RequestContext; policy: AuthPolicy;
                  route: string): Future[int] {.async.} =
    ## 0 when the request may proceed under `policy`, otherwise the status
    ## to refuse it with: 401 (no session, bad signature) or 403 (a session
    ## without the role).
    case policy
    of aPublic:
      return 0
    of aOptional:
      await ctx.resolveSession()
      return 0
    of aSession, aStaff, aAdmin:
      await ctx.resolveSession()
      if ctx.session.isNil:
        return 401
      if policy == aStaff and not (ctx.session.staff or ctx.session.admin):
        return 403
      if policy == aAdmin and not ctx.session.admin:
        return 403
      return 0
    of aSignature:
      let verifier = serverHooks.verifySignature
      if verifier.isNil:
        return 401
      let ok = await verifier(ctx, route)
      return (if ok: 0 else: 401)

  # ------------------------------------------------------------------------
  # Client context (URL-Schema.md §5.4)
  # ------------------------------------------------------------------------

  proc contextIsStale*(ctx: RequestContext): bool =
    ## A state-changing request whose `X-Isonim-Context` names an
    ## incarnation other than the instance's current one.
    let current = serverHooks.currentIncarnation
    current != nil and isStateChanging(ctx.request.httpMethod) and
      ctx.clientContext.present and
      (not ctx.clientContext.valid or ctx.clientContext.incarnationId != current())

  proc echoContextHeader*(ctx: RequestContext) =
    if ctx.request.hasHeader(contextHeaderName):
      ctx.response.setHeader(contextHeaderName,
                             ctx.request.header(contextHeaderName))

  proc isNoJsFormSubmission*(ctx: RequestContext): bool =
    ## A form the browser submitted by itself: a form-encoded `POST` that
    ## carries no `X-Isonim-Context` (generated clients always send it).
    ctx.request.httpMethod == "POST" and
      not ctx.request.hasHeader(contextHeaderName) and
      ctx.request.mediaType in ["application/x-www-form-urlencoded",
                                "multipart/form-data"]

  # ------------------------------------------------------------------------
  # The response's cache policy and representation
  # (isonim-routing-server-functions.md, "Per-Response Cache Policy",
  # "JSON Variants of a Page" and "Not Found")
  # ------------------------------------------------------------------------

  proc beginCachePolicy*(ctx: RequestContext; entry: CachePolicy;
                         overrides: openArray[CachePolicy]) =
    ## Called by the route dispatch before the hook and the handler run:
    ## the response starts with the entry's policy, and may be given one of
    ## `overrides` (each at least as strict as `entry`; the manifest checks
    ## that at compile time).
    ctx.cachePolicy = entry
    ctx.cacheChoices = @[entry]
    for p in overrides:
      if p notin ctx.cacheChoices:
        ctx.cacheChoices.add p

  proc responseCachePolicy*(ctx: RequestContext): CachePolicy =
    ## The cache policy the dispatch writes on this response.
    ctx.cachePolicy

  proc setCachePolicy*(ctx: RequestContext; policy: CachePolicy): bool =
    ## Gives this response `policy` instead of the entry's.  Accepted (true)
    ## when `policy` is at least as strict as the response's current policy
    ## and is the entry's `cache` or one of its `cacheOverrides`.  Refused
    ## (false) otherwise: the response keeps its current policy and the
    ## refusal goes to `serverHooks.onCachePolicyRefused`.  So a response
    ## can only be made stricter, never weaker.
    if isAtLeastAsStrict(policy, ctx.cachePolicy) and policy in ctx.cacheChoices:
      ctx.cachePolicy = policy
      return true
    let report = serverHooks.onCachePolicyRefused
    if report != nil:
      report(ctx, policy, ctx.cachePolicy)
    false

  proc routeNotFound*() {.noreturn.} =
    ## Raises `RouteNotFound`: the handler's target is gone or no longer
    ## visible, and the dispatch answers 404 exactly as for the
    ## canonicalization hook's `coNotFound`.
    raise newException(RouteNotFound, "not found")

  proc keepPageVariant*(ctx: RequestContext; location: string): string =
    ## `location` with `.json` appended to its path (before any `?` or `#`)
    ## when this request named the JSON variant by its suffix: the
    ## canonicalization hook builds its redirect with it, so the variant
    ## survives the redirect.  Unchanged for any other request.
    if ctx.pageVariant != pvJsonSuffix:
      return location
    var cut = location.len
    for i, c in location:
      if c in {'?', '#'}:
        cut = i
        break
    location[0 ..< cut] & ".json" & location[cut .. ^1]

  # ------------------------------------------------------------------------
  # The response body
  # ------------------------------------------------------------------------

  proc write*(ctx: RequestContext; data: string) =
    ctx.responseBody.add data

  proc respondJson*(ctx: RequestContext; status: int; body: string) =
    ## Sets the status and `application/json`, replaces the body.
    ctx.response.status = status
    ctx.response.contentType = "application/json"
    ctx.responseBody = body

  proc respondError*(ctx: RequestContext; status: int; error: string;
                     detail = "") =
    ## An error the server produced before (or instead of) the handler:
    ## `{"error": ..., "detail": ...}` with `Cache-Control: private,
    ## no-store`.
    var body = "{\"error\":" & escapeJson(error)
    if detail.len > 0:
      body.add ",\"detail\":" & escapeJson(detail)
    body.add "}"
    ctx.response.setHeader("Cache-Control", errorCacheControl)
    ctx.respondJson(status, body)

  proc applyCachePolicy*(ctx: RequestContext; policy: CachePolicy) =
    ## Writes the headers of `policy` on the response.
    for (k, v) in cacheHeaders(policy):
      ctx.response.setHeader(k, v)
