## isonim/server/rpc.nim
##
## Server functions over HTTP.
##
## Every `{.server.}` / `{.action.}` proc is an endpoint at
## `<rpcPrefix>/<module>/<proc>`, where `<module>` is the Nim module that
## declares it and `rpcPrefix` is set at compile time with
## `-d:isonimRpcPrefix=/api/v1/rpc` (default `/api`).  Actions share the
## namespace.
##
## **C target (the server).**  Module initialization registers each
## endpoint in `rpcRegistry` with its policies (auth, CSRF, context scope,
## and for actions the no-JS redirect target).  A server hands requests
## under the prefix to `dispatchRpc`, which runs, in order:
##
## 1. the endpoint lookup (`404 unknown_endpoint`) and the method (`POST`
##    only, else `405` with `Allow: POST`);
## 2. decoding the body: a JSON object, or a form (`application/x-www-form-
##    urlencoded`) whose fields are the arguments (`400 bad_request`);
## 3. authentication (`401 unauthenticated`, `403 forbidden`);
## 4. CSRF (`403 csrf`, with the verdict as `detail`);
## 5. the client context: a stale incarnation is `409 context_stale`
##    (URL-Schema.md §5.4); `X-Isonim-Context` is echoed;
## 6. the handler, whose result is the JSON response body (`200`), with
##    `Cache-Control: private, no-cache, no-store, must-revalidate`.  An
##    action submitted by a browser form without JavaScript answers `303`
##    to its target instead (redirect-after-POST).  A handler that raises
##    gives `500 internal` (the error is kept on the context for the server
##    to log).
##
## Handlers are asynchronous (`Future[JsonNode]`), so a server function
## that awaits I/O does not hold up the server (ngx-isonim runs the
## dispatch on the nginx worker's event loop).
##
## **JS target (the browser).**  The `{.server.}` macro replaces each body
## with `rpcCall` (rpc_client.nim): a `fetch` that returns `Future[T]`.

import std/[json, options]
import context, policy

export json, options, context, policy

const rpcPrefix* {.strdefine: "isonimRpcPrefix".} = "/api"
  ## The mount point of server functions.  IsoNim Forum builds with
  ## `-d:isonimRpcPrefix=/api/v1/rpc` (URL-Schema.md §5.5).

proc rpcUrl*(name: string): string =
  ## The URL of the endpoint `<module>/<proc>`.
  rpcPrefix & "/" & name

when defined(js):
  import rpc_client
  export rpc_client

else:
  import std/[asyncdispatch, strutils, tables, algorithm]
  import form_action
  export asyncdispatch

  type
    RpcHandler* = proc(ctx: RequestContext; args: JsonNode): Future[JsonNode]
      ## Decodes the arguments, runs the server function, encodes its
      ## result.

    RpcEndpoint* = ref object
      name*: string          ## `<module>/<proc>`
      handler*: RpcHandler
      params*: seq[string]   ## the argument names (the context excluded)
      isAction*: bool        ## an `{.action.}`: no-JS forms get a 303
      target*: string        ## where an action's no-JS form redirects to;
                             ## "" = the same-origin `Referer`, else "/"
      auth*: AuthPolicy
      csrf*: CsrfPolicy
      contextScope*: ContextScope
      sample*: proc(): JsonNode
        ## Arguments of the right types (each parameter's default value),
        ## for the generated policy tests.

    RpcBadRequest* = object of CatchableError
      ## The arguments do not match the server function's parameters.

  var rpcRegistry* {.threadvar.}: Table[string, RpcEndpoint]
    ## Endpoints by name (`<module>/<proc>`), filled at module init.

  proc url*(ep: RpcEndpoint): string = rpcUrl(ep.name)

  proc registerRpc*(ep: RpcEndpoint) =
    ## Registers an endpoint.  Two server functions with the same module
    ## and proc name are a startup error.
    if rpcRegistry.hasKey(ep.name):
      raise newException(ValueError,
        "two server functions are named " & ep.name)
    rpcRegistry[ep.name] = ep

  proc lookupRpc*(name: string): RpcEndpoint =
    ## The endpoint `<module>/<proc>`, or nil.
    rpcRegistry.getOrDefault(name, nil)

  proc rpcEndpoints*(): seq[RpcEndpoint] =
    ## Every registered endpoint, by name.
    for ep in rpcRegistry.values:
      result.add ep
    result.sort(proc(a, b: RpcEndpoint): int = cmp(a.name, b.name))

  # ------------------------------------------------------------------------
  # Arguments
  # ------------------------------------------------------------------------

  proc badArg(name, why: string): ref RpcBadRequest =
    newException(RpcBadRequest, "argument '" & name & "': " & why)

  proc fromArg*[T](n: JsonNode; name: string): T =
    ## Decodes one argument.  Form fields arrive as strings, so a string is
    ## also accepted for numbers, booleans and enums.
    try:
      when T is string:
        if n.kind != JString: raise badArg(name, "expected a string")
        result = n.getStr
      elif T is bool:
        if n.kind == JString:
          case n.getStr.toLowerAscii
          of "true", "on", "1", "yes": result = true
          of "false", "off", "0", "no", "": result = false
          else: raise badArg(name, "expected a boolean")
        else:
          result = to(n, T)
      elif T is SomeInteger:
        if n.kind == JString: result = T(parseBiggestInt(n.getStr.strip))
        else: result = to(n, T)
      elif T is SomeFloat:
        if n.kind == JString: result = T(parseFloat(n.getStr.strip))
        else: result = to(n, T)
      elif T is enum:
        if n.kind == JString: result = parseEnum[T](n.getStr)
        else: result = to(n, T)
      else:
        result = to(n, T)
    except RpcBadRequest as e:
      raise e
    except CatchableError as e:
      raise badArg(name, e.msg)

  proc rpcArg*[T](args: JsonNode; name: string): T =
    ## The argument `name` of a call, decoded as `T`.  An `Option[T]`
    ## argument may be missing (or null).
    let present = args != nil and args.kind == JObject and args.hasKey(name)
    when T is Option:
      if present and args[name].kind != JNull:
        result = some(fromArg[typeof(result.get)](args[name], name))
      else:
        result = none(typeof(result.get))
    else:
      if not present:
        raise badArg(name, "missing")
      result = fromArg[T](args[name], name)

  proc rpcResultJson*[T](f: Future[T]): Future[JsonNode] {.async.} =
    ## The JSON a server function's result travels as.
    let value = await f
    return %value

  proc rejectUnknownArgs*(args: JsonNode; known: openArray[string]) =
    ## Unknown arguments are an error (URL-Schema.md §5.1: unknown body
    ## fields are rejected).
    if args.isNil or args.kind != JObject:
      return
    for k in args.keys:
      if k notin known:
        raise newException(RpcBadRequest, "unknown argument '" & k & "'")

  proc decodeRpcBody*(req: SsrRequest): tuple[args: JsonNode, formToken: string] =
    ## The arguments of a call: a JSON object, or the fields of a form.
    ## The form field `_csrf` is the CSRF token, not an argument.
    case req.mediaType
    of "application/x-www-form-urlencoded":
      let form = parseFormData(req.body)
      result.args = newJObject()
      for k, v in form:
        if k == csrfFieldName:
          result.formToken = v
        else:
          result.args[k] = newJString(v)
    of "application/json", "":
      if req.body.strip.len == 0:
        result.args = newJObject()
      else:
        try:
          result.args = parseJson(req.body)
        except CatchableError as e:
          raise newException(RpcBadRequest, "the body is not JSON: " & e.msg)
        if result.args.kind != JObject:
          raise newException(RpcBadRequest,
            "the body must be a JSON object of arguments")
    else:
      raise newException(RpcBadRequest,
        "unsupported Content-Type " & req.mediaType)

  proc sameOriginRefererPath*(ctx: RequestContext): string =
    ## The path (and query) of a `Referer` on this host, or "".
    let referer = ctx.request.header("Referer")
    let sep = referer.find("://")
    if sep <= 0:
      return ""
    let rest = referer[sep + 3 .. ^1]
    let slash = rest.find('/')
    let authority = if slash < 0: rest else: rest[0 ..< slash]
    if cmpIgnoreCase(authority, ctx.request.host) != 0:
      return ""
    result = if slash < 0: "/" else: rest[slash .. ^1]
    let hash = result.find('#')
    if hash >= 0:
      result.setLen(hash)

  # ------------------------------------------------------------------------
  # The policy pipeline, shared with the route manifest's dispatch
  # ------------------------------------------------------------------------

  proc refuseAuth*(ctx: RequestContext; status: int) =
    if status == 401:
      ctx.respondError(401, "unauthenticated")
    else:
      ctx.respondError(403, "forbidden")

  proc enforcePolicies*(ctx: RequestContext; route: string; auth: AuthPolicy;
                        csrf: CsrfPolicy;
                        formToken: string): Future[bool] {.async.} =
    ## Authentication, CSRF and the client context, in that order.  False
    ## when the request was refused (the response is set).
    let authStatus = await ctx.checkAuth(auth, route)
    if authStatus != 0:
      ctx.refuseAuth(authStatus)
      return false
    if csrf.kind == ckSession:
      # The session token is needed even when the route lets anonymous
      # callers in.
      await ctx.resolveSession()
    let verdict = ctx.verifyCsrf(csrf, formToken)
    if not verdict.csrfPassed:
      ctx.respondError(403, "csrf", $verdict)
      return false
    if ctx.contextIsStale():
      ctx.respondError(409, "context_stale")
      return false
    return true

  proc redirectAfterPost*(ctx: RequestContext; target: string) =
    ## `303 See Other` to `target` (or the same-origin Referer, or "/").
    var location = target
    if location.len == 0:
      location = ctx.sameOriginRefererPath()
    if location.len == 0:
      location = "/"
    ctx.responseBody.setLen(0)
    ctx.response.redirect(location, 303)

  # ------------------------------------------------------------------------
  # Dispatch
  # ------------------------------------------------------------------------

  proc dispatchRpc*(ctx: RequestContext;
                    mount = rpcPrefix): Future[void] {.async.} =
    ## Serves one request for a server function mounted at `mount`.  The
    ## response (status, headers, body) is left in `ctx`.
    let req = ctx.request
    ctx.echoContextHeader()
    let prefix = mount & "/"
    if not req.path.startsWith(prefix):
      ctx.respondError(404, "unknown_endpoint", req.path)
      return
    let name = req.path[prefix.len .. ^1]
    let ep = lookupRpc(name)
    if ep.isNil:
      ctx.respondError(404, "unknown_endpoint", req.path)
      return
    if req.httpMethod != "POST":
      ctx.response.setHeader("Allow", "POST")
      ctx.respondError(405, "method_not_allowed")
      return
    var args: JsonNode
    var formToken = ""
    try:
      (args, formToken) = decodeRpcBody(req)
    except RpcBadRequest as e:
      ctx.respondError(400, "bad_request", e.msg)
      return
    if not await ctx.enforcePolicies(ep.name, ep.auth, ep.csrf, formToken):
      return
    var resultNode: JsonNode
    try:
      rejectUnknownArgs(args, ep.params)
      resultNode = await ep.handler(ctx, args)
    except RpcBadRequest as e:
      ctx.respondError(400, "bad_request", e.msg)
      return
    except CatchableError as e:
      ctx.failure = e
      ctx.responseBody.setLen(0)
      ctx.respondError(500, "internal")
      return
    ctx.applyCachePolicy(cpPrivateNoStore)
    if ctx.response.isRedirect:
      return
    if ep.isAction and ctx.isNoJsFormSubmission():
      ctx.redirectAfterPost(ep.target)
      return
    ctx.response.contentType = "application/json"
    ctx.responseBody = $resultNode
