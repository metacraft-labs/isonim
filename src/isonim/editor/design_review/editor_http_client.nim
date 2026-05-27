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
  # CHRM-M6 Wave A — the JS ``fetch`` response body is a native JS
  # ``String``, but the Nim ``HttpCallbackResult.body`` field is declared
  # as ``string`` (the Nim JS representation is an Array of char codes,
  # NOT a native JS String). Earlier revisions assigned ``out.body``
  # straight into the result object, which left a native JS String in
  # the field — every downstream ``strutils.find`` / ``.contains`` then
  # index-failed inside ``nsuFindStrA`` because ``jsString[i]`` returns
  # a 1-char string instead of a byte/char code, the bounds check on
  # the skip-table lookup blows up with ``SyntaxError: Cannot convert
  # i to a BigInt`` (the error-message construction calls ``BigInt`` on
  # the offending index char), the catch-handler in the fetch chain
  # re-invokes the callback with ``kind=hcError``, and the gallery
  # never sees a real run. Convert the JS String to a Nim string via
  # ``cstringToNimstr`` (the same helper Nim's own JS-target codegen
  # uses when crossing this boundary) BEFORE handing the body back to
  # the caller.
  proc invokeCb(cb: HttpCallback; kind: HttpCallbackKind;
                body: cstring; statusCode: int) =
    var r = HttpCallbackResult(kind: kind, body: $body, statusCode: statusCode)
    cb(r)

  proc getJs(url: string; cb: HttpCallback) =
    let u: cstring = url
    let cb2 = cb
    let invoke = invokeCb
    {.emit: ["""
      try {
        fetch(""", u, """, { method: 'GET', credentials: 'omit' })
          .then(function(resp) {
            return resp.text().then(function(body) {
              return { code: resp.status, body: body };
            });
          })
          .then(function(out) {
            var k = 0;
            if (out.code === 409) k = 2;
            else if (out.code >= 200 && out.code < 300) k = 0;
            else k = 1;
            """, invoke, """(""", cb2, """, k, out.body, out.code);
          })
          .catch(function(err) {
            """, invoke, """(""", cb2, """, 1, String(err), 0);
          });
      } catch (e) {
        """, invoke, """(""", cb2, """, 1, String(e), 0);
      }
    """].}

  proc postJs(url, body: string; cb: HttpCallback) =
    let u: cstring = url
    let b: cstring = body
    let cb2 = cb
    let invoke = invokeCb
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
            var k = 0;
            if (out.code === 409) k = 2;
            else if (out.code >= 200 && out.code < 300) k = 0;
            else k = 1;
            """, invoke, """(""", cb2, """, k, out.body, out.code);
          })
          .catch(function(err) {
            """, invoke, """(""", cb2, """, 1, String(err), 0);
          });
      } catch (e) {
        """, invoke, """(""", cb2, """, 1, String(e), 0);
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

# ---------------------------------------------------------------------------
# TBAR-M5 — save-brief helper.  Mirrors the existing GET / POST helpers
# above: same-origin POST to ``/api/design-review/save-brief`` with a
# JSON body carrying ``briefId`` + ``markdown``.  The daemon writes the
# markdown to disk at the brief's ``sourceFile`` (refusing paths outside
# the configured workspace root) and returns
# ``{briefId, path, bytesWritten}`` on success.
# ---------------------------------------------------------------------------

proc jsonStringEscape*(s: string): string =
  ## Minimal JSON string escape — only the chars JSON requires to be
  ## escaped (``"``, ``\``, control chars).  We hand-roll this instead
  ## of pulling in ``std/json`` because the JS backend would otherwise
  ## drag the whole ``std/json`` module into the editor bundle just to
  ## build one POST body.
  result = newStringOfCap(s.len + 16)
  for ch in s:
    case ch
    of '"': result.add "\\\""
    of '\\': result.add "\\\\"
    of '\b': result.add "\\b"
    of '\f': result.add "\\f"
    of '\n': result.add "\\n"
    of '\r': result.add "\\r"
    of '\t': result.add "\\t"
    else:
      let o = ord(ch)
      if o < 0x20:
        const hexChars = "0123456789abcdef"
        result.add "\\u00"
        result.add hexChars[(o shr 4) and 0xF]
        result.add hexChars[o and 0xF]
      else:
        result.add ch

proc saveBrief*(client: EditorHttpClient; briefId, markdown: string;
                cb: HttpCallback) =
  if briefId.len == 0:
    cb(HttpCallbackResult(kind: hcError, body: "empty briefId",
                          statusCode: 0))
    return
  let bodyJson = "{\"briefId\":\"" & jsonStringEscape(briefId) &
                 "\",\"markdown\":\"" & jsonStringEscape(markdown) & "\"}"
  httpPost(client, "/api/design-review/save-brief", bodyJson, cb)
