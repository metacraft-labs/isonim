## Handler type and simple router for IsoNim.
##
## HttpHandler is synchronous for now — async variant comes in a later milestone.
## The Router does exact-path and prefix matching against registered routes.

import http_types

type
  HttpHandler* = proc(req: HttpRequest, resp: HttpResponse)
    ## The core handler type. Takes a request and writes to the response.
    ## For now synchronous — async variant comes later.

  Route = object
    httpMethod: HttpMethod
    path: string              # Exact path or prefix pattern
    handler: HttpHandler
    isPrefix: bool            # If true, matches path prefix

  Router* = object
    routes: seq[Route]
    notFoundHandler: HttpHandler

proc newRouter*(): Router =
  result.routes = @[]
  result.notFoundHandler = proc(req: HttpRequest, resp: HttpResponse) =
    resp.statusCode = 404
    resp.writeHeader("Content-Type", "text/plain")
    resp.writeBody("Not Found")

proc addRoute*(router: var Router, httpMethod: HttpMethod, path: string,
              handler: HttpHandler, isPrefix: bool = false) =
  router.routes.add(Route(
    httpMethod: httpMethod,
    path: path,
    handler: handler,
    isPrefix: isPrefix
  ))

proc get*(router: var Router, path: string, handler: HttpHandler) =
  router.addRoute(hmGet, path, handler)

proc post*(router: var Router, path: string, handler: HttpHandler) =
  router.addRoute(hmPost, path, handler)

proc put*(router: var Router, path: string, handler: HttpHandler) =
  router.addRoute(hmPut, path, handler)

proc delete*(router: var Router, path: string, handler: HttpHandler) =
  router.addRoute(hmDelete, path, handler)

proc dispatch*(router: Router, req: HttpRequest, resp: HttpResponse) =
  ## Find a matching route and dispatch the request.
  for route in router.routes:
    if route.httpMethod == req.httpMethod:
      if route.isPrefix:
        if req.pathStartsWith(route.path):
          route.handler(req, resp)
          return
      else:
        if req.pathIs(route.path):
          route.handler(req, resp)
          return
  router.notFoundHandler(req, resp)
