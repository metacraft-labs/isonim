## REV-M8 — production ``GalleryHttpClient`` implementation.
##
## REV-M7 left an abstract ``GalleryHttpClient`` ref-object surface in
## ``views/gallery_overlay.nim``.  Tests pass an in-process subclass;
## the production editor needs a concrete implementation that talks to
## the real daemon.  This module ships two backends:
##
##   * JS path — uses ``window.fetch`` via ``{.emit.}`` shim returning
##     a JsObject promise wrapper.  The editor calls these from
##     reactive effects, so the public API takes a callback.
##   * Native path — uses ``std/httpclient``.  Only native tests
##     consume this; the production editor never hits the native path.
##
## The two backends share the same ``EditorHttpClient`` ref and the
## same call surface.  Compile-time dispatch via ``when defined(js)``
## picks the implementation.

import std/[options, strutils]

when not defined(js):
  import std/[httpclient, json]

import isonim/editor/views/gallery_overlay

type
  EditorHttpClient* = ref object of GalleryHttpClient
    baseUrl*: string

  HttpCallbackKind* = enum
    hcOk, hcError, hcConflict

  HttpCallbackResult* = object
    kind*: HttpCallbackKind
    body*: string
    statusCode*: int

  HttpCallback* = proc(res: HttpCallbackResult) {.closure.}

proc newEditorHttpClient*(baseUrl: string): EditorHttpClient =
  EditorHttpClient(baseUrl: baseUrl)

# ---------------------------------------------------------------------------
# URL joining.  ``baseUrl`` may or may not end in a slash; we normalise
# so callers can pass "/api/design-review/..." literals.
# ---------------------------------------------------------------------------

proc joinUrl*(baseUrl, path: string): string =
  if baseUrl.len == 0: return path
  if baseUrl.endsWith("/") and path.startsWith("/"):
    return baseUrl[0 ..< baseUrl.len - 1] & path
  if not baseUrl.endsWith("/") and not path.startsWith("/"):
    return baseUrl & "/" & path
  return baseUrl & path

# ---------------------------------------------------------------------------
# JS backend.  ``fetch`` returns a Promise — we adapt it to a callback
# by emitting an inline ``.then``/``.catch`` chain.  ``cb`` is invoked
# exactly once.
# ---------------------------------------------------------------------------

when defined(js):
  proc getJs(url: string; cb: HttpCallback) =
    let u: cstring = url
    let cb2 = cb
    {.emit: ["""
      try {
        fetch(""", u, """, { method: 'GET', credentials: 'omit' })
          .then(function(resp) {
            return resp.text().then(function(body) {
              return { code: resp.status, body: body };
            });
          })
          .then(function(out) {
            var r = { kind: 0, body: out.body, statusCode: out.code };
            if (out.code === 409) r.kind = 2;
            else if (out.code >= 200 && out.code < 300) r.kind = 0;
            else r.kind = 1;
            """, cb2, """(r);
          })
          .catch(function(err) {
            """, cb2, """({ kind: 1, body: String(err), statusCode: 0 });
          });
      } catch (e) {
        """, cb2, """({ kind: 1, body: String(e), statusCode: 0 });
      }
    """].}

  proc postJs(url, body: string; cb: HttpCallback) =
    let u: cstring = url
    let b: cstring = body
    let cb2 = cb
    {.emit: ["""
      try {
        fetch(""", u, """, {
          method: 'POST', credentials: 'omit',
          headers: { 'Content-Type': 'application/json' },
          body: """, b, """
        })
          .then(function(resp) {
            return resp.text().then(function(body) {
              return { code: resp.status, body: body };
            });
          })
          .then(function(out) {
            var r = { kind: 0, body: out.body, statusCode: out.code };
            if (out.code === 409) r.kind = 2;
            else if (out.code >= 200 && out.code < 300) r.kind = 0;
            else r.kind = 1;
            """, cb2, """(r);
          })
          .catch(function(err) {
            """, cb2, """({ kind: 1, body: String(err), statusCode: 0 });
          });
      } catch (e) {
        """, cb2, """({ kind: 1, body: String(e), statusCode: 0 });
      }
    """].}

# ---------------------------------------------------------------------------
# Native backend.  ``std/httpclient`` is synchronous, so we invoke the
# callback inline.  Tests are the only consumer.
# ---------------------------------------------------------------------------

when not defined(js):
  proc getNative(url: string; timeoutMs: int = 5000): HttpCallbackResult =
    try:
      let client = newHttpClient(timeout = timeoutMs)
      defer: client.close()
      let resp = client.request(url, httpMethod = HttpGet)
      let code = try: parseInt(resp.status.split(' ')[0]) except ValueError: 0
      let kind =
        if code == 409: hcConflict
        elif code in 200..299: hcOk
        else: hcError
      return HttpCallbackResult(kind: kind, body: resp.body, statusCode: code)
    except CatchableError as e:
      return HttpCallbackResult(kind: hcError, body: e.msg, statusCode: 0)

  proc postNative(url, body: string;
                  timeoutMs: int = 5000): HttpCallbackResult =
    try:
      let client = newHttpClient(timeout = timeoutMs)
      defer: client.close()
      let h = newHttpHeaders([("Content-Type", "application/json")])
      let resp = client.request(url, httpMethod = HttpPost,
                                body = body, headers = h)
      let code = try: parseInt(resp.status.split(' ')[0]) except ValueError: 0
      let kind =
        if code == 409: hcConflict
        elif code in 200..299: hcOk
        else: hcError
      return HttpCallbackResult(kind: kind, body: resp.body, statusCode: code)
    except CatchableError as e:
      return HttpCallbackResult(kind: hcError, body: e.msg, statusCode: 0)

# ---------------------------------------------------------------------------
# Public API.
# ---------------------------------------------------------------------------

proc httpGet*(client: EditorHttpClient; path: string; cb: HttpCallback) =
  let url = joinUrl(client.baseUrl, path)
  when defined(js):
    getJs(url, cb)
  else:
    cb(getNative(url))

proc httpPost*(client: EditorHttpClient; path, body: string;
               cb: HttpCallback) =
  let url = joinUrl(client.baseUrl, path)
  when defined(js):
    postJs(url, body, cb)
  else:
    cb(postNative(url, body))

# ---------------------------------------------------------------------------
# High-level helpers — one per endpoint, so call sites in the editor
# stay terse.
# ---------------------------------------------------------------------------

proc fetchBriefHasHistory*(client: EditorHttpClient; briefId: string;
                           cb: HttpCallback) =
  if briefId.len == 0:
    cb(HttpCallbackResult(kind: hcError, body: "empty briefId",
                          statusCode: 0))
    return
  httpGet(client, "/api/design-review/brief-has-history?briefId=" & briefId,
          cb)

proc fetchListHistory*(client: EditorHttpClient; briefId: string;
                      limit, offset: int; cb: HttpCallback) =
  let path = "/api/design-review/list-history?briefId=" & briefId &
             "&limit=" & $limit & "&offset=" & $offset
  httpGet(client, path, cb)

proc fetchRun*(client: EditorHttpClient; runId: string; cb: HttpCallback) =
  ## Wrapper for ``GET /api/design-review/fetch-run?runId=<uuid>``.  Used
  ## by the production gallery to assemble tiles after ``list-history``
  ## hands back run ids.
  if runId.len == 0:
    cb(HttpCallbackResult(kind: hcError, body: "empty runId",
                          statusCode: 0))
    return
  httpGet(client, "/api/design-review/fetch-run?runId=" & runId, cb)

proc fetchListLayouts*(client: EditorHttpClient; briefId, userId: string;
                      cb: HttpCallback) =
  var path = "/api/design-review/list-layouts?briefId=" & briefId
  if userId.len > 0:
    path.add("&userId=" & userId)
  httpGet(client, path, cb)

proc postSaveLayout*(client: EditorHttpClient; bodyJson: string;
                    cb: HttpCallback) =
  httpPost(client, "/api/design-review/save-layout", bodyJson, cb)

proc postPromoteLayout*(client: EditorHttpClient; bodyJson: string;
                       cb: HttpCallback) =
  httpPost(client, "/api/design-review/promote-layout", bodyJson, cb)
