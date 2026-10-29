## isonim/routing/client_context.nim
##
## Request-context generation (URL-Schema.md §5.4).
##
## The browser holds a context `(instance_id, incarnation_id,
## account_generation, navigation_generation)`:
##
## * `account_generation` increments on login, logout, an account switch
##   (`bumpAccountGeneration`) and whenever the incarnation changes
##   (`setIncarnation`);
## * `navigation_generation` increments on every client navigation
##   (`bumpNavigationGeneration`, which the router's `navigate` and the
##   browser's back/forward call).
##
## Every request a generated client sends (server-function stubs, route
## manifest clients) carries `Isonim-Context: <incarnation_id>:
## <account_generation>` and captures the context when it is sent.  When the
## response arrives the client drops it if the captured context no longer
## matches the request's scope:
##
## * `csAccount`: the incarnation or the account generation changed;
## * `csNavigation`: that, or the navigation generation changed (and the
##   request is also aborted when the navigation changes);
## * `csNone`: never dropped.
##
## Read-your-writes: a successful write's response may carry
## `Isonim-Commit: <cell_id>:<lsn>` (its commit position); the client keeps
## the newest one it received for `afterWindowMs` (`noteCommit`) and sends it
## as `Isonim-After` on every request until then (`afterHeaderValue`;
## IsoNim-Forum.md §3.8.5). A new account generation forgets it. Both are
## hints that grant nothing on the server (server/policy.nim).
##
## A dropped response never reaches the caller: its future never settles,
## so nothing downstream (signals, caches, storage) can change.  The
## dropped-response hook still sees it, which is where an application
## resolves the idempotency record of a dropped mutation.
##
## On the server, `clientContextMeta` renders the meta tags the browser
## reads its initial context from.

import ../server/policy

const
  instanceMetaName* = "isonim-instance"
  incarnationMetaName* = "isonim-incarnation"
  csrfMetaName* = "csrf-token"

when not defined(js):
  import std/strutils
  import ../server/context

  proc escapeAttr(s: string): string =
    s.multiReplace(("&", "&amp;"), ("\"", "&quot;"), ("<", "&lt;"),
                   (">", "&gt;"))

  proc clientContextMeta*(instanceId, incarnationId, csrfToken: string): string =
    ## The `<meta>` tags a page carries so that its scripts start with the
    ## server's context and CSRF token.
    "<meta name=\"" & instanceMetaName & "\" content=\"" &
      escapeAttr(instanceId) & "\">" &
    "<meta name=\"" & incarnationMetaName & "\" content=\"" &
      escapeAttr(incarnationId) & "\">" &
    "<meta name=\"" & csrfMetaName & "\" content=\"" &
      escapeAttr(csrfToken) & "\">"

  proc traceparentMeta*(ctx: RequestContext): string =
    ## The request's trace context for browser environment capture. Render
    ## next to `clientContextMeta`; repeated calls reuse the context's value.
    "<meta name=\"traceparent\" content=\"" & escapeAttr(ctx.traceparent()) & "\">"

else:
  import std/jsffi

  type
    ClientContext* = object
      instanceId*: string
      incarnationId*: string
      accountGeneration*: int
      navigationGeneration*: int

    DroppedResponse* = object
      ## A response that arrived after its context went stale.
      httpMethod*: string
      url*: string
      status*: int           ## -1 when the request was aborted
      scope*: ContextScope
      reason*: string        ## "incarnation", "account" or "navigation"
      body*: string
      idempotencyKey*: string
        ## the `Idempotency-Key` of a dropped state-changing request ("" for
        ## a read): what an application resolves its idempotency record by

  var
    ctxState: ClientContext
    ctxLoaded = false
    droppedHooks: seq[proc(d: DroppedResponse)]
    droppedCount = 0
    navAbort: JsObject       ## the AbortController of the current navigation
    csrfTokenOverride: string

  proc metaContent(name: cstring): string =
    var v: cstring
    {.emit: """
    var el = (typeof document !== "undefined") ?
      document.querySelector('meta[name="' + `name` + '"]') : null;
    `v` = el ? el.getAttribute("content") : "";
    """.}
    $v

  proc load() =
    if not ctxLoaded:
      ctxLoaded = true
      ctxState.instanceId = metaContent(instanceMetaName)
      ctxState.incarnationId = metaContent(incarnationMetaName)

  proc clientContext*(): ClientContext =
    ## The current context (read from the page's meta tags on first use).
    load()
    ctxState

  proc initClientContext*(instanceId, incarnationId: string) =
    ## Sets the context explicitly (instead of from meta tags).
    ctxLoaded = true
    ctxState.instanceId = instanceId
    ctxState.incarnationId = incarnationId

  proc bumpAccountGeneration*() =
    ## Login, logout, account switch: responses to requests sent before
    ## are dropped (`csAccount` and `csNavigation`).
    load()
    inc ctxState.accountGeneration

  proc setIncarnation*(incarnationId: string) =
    ## The instance's incarnation changed (failover, restore): a new
    ## incarnation is also a new account generation.
    load()
    if incarnationId != ctxState.incarnationId:
      ctxState.incarnationId = incarnationId
      inc ctxState.accountGeneration

  proc navigationSignal*(): JsObject =
    ## The abort signal of the current navigation.
    if navAbort.isNil:
      {.emit: "`navAbort` = new AbortController();".}
    navAbort.signal

  proc bumpNavigationGeneration*() =
    ## A client navigation: navigation-scoped requests in flight are
    ## aborted, and their responses dropped.
    load()
    inc ctxState.navigationGeneration
    if not navAbort.isNil:
      {.emit: "`navAbort`.abort();".}
    {.emit: "`navAbort` = new AbortController();".}

  const afterWindowMs* = 60_000.0
    ## How long a commit position is sent back (IsoNim-Forum.md §3.8.5).

  # The kept position, in a plain JS object: these run on every request of
  # a size-budgeted bundle, so they are JS, not Nim strings.
  {.emit: """var isonimAfter = {v: "", t: 0, g: -1};""".}

  proc keepCommitJs(v: cstring; now: float; gen, window: int) {.importjs: """(function (v, n, g, w) {
      var re = /^([^:]+):([0-9A-Fa-f]{1,8})\/([0-9A-Fa-f]{1,8})$$/, x = re.exec(v), a = isonimAfter;
      if (!x) return;
      var y = a.v && a.g === g && n - a.t < w ? re.exec(a.v) : null;
      if (y && y[1] === x[1] && (parseInt(y[2], 16) - parseInt(x[2], 16) ||
                                 parseInt(y[3], 16) - parseInt(x[3], 16)) > 0) return;
      a.v = v; a.t = n; a.g = g;
    })(#, #, #, #)""".}
    ## Keeps `v` (module doc): positions are `<cell_id>:<hi>/<lo>`, pg_lsn's
    ## text, two hexadecimal numbers of at most 8 digits (each exact in a JS
    ## number); a malformed one is ignored, an older one of the same cell
    ## within the window does not replace the kept one.
  proc afterJs(gen: int; now: float; window: int): cstring {.importjs:
    "(isonimAfter.v && isonimAfter.g === # && # - isonimAfter.t < # ? isonimAfter.v : '')" .}

  proc noteCommitC*(value: cstring; nowMs: float) =
    ## `noteCommit` of a JS string (the generated clients' call).
    load()
    keepCommitJs(value, nowMs, ctxState.accountGeneration, int(afterWindowMs))

  proc afterHeaderC*(nowMs: float): cstring =
    ## `afterHeaderValue` as a JS string (the generated clients' call).
    load()
    afterJs(ctxState.accountGeneration, nowMs, int(afterWindowMs))

  proc noteCommit*(value: string; nowMs: float) =
    ## A write's response carried `Isonim-Commit: value` at `nowMs`. It is
    ## kept if it is well formed and not older than the position already
    ## kept for the same cell (responses can arrive out of order); a
    ## position of another cell replaces it.
    noteCommitC(cstring(value), nowMs)

  proc afterHeaderValue*(nowMs: float): string =
    ## The `Isonim-After` to send at `nowMs`, or "" (none received, older
    ## than `afterWindowMs`, or received under another account generation).
    $afterHeaderC(nowMs)

  proc contextHeaderValue*(): string =
    ## `<incarnation_id>:<account_generation>`.
    load()
    ctxState.incarnationId & ":" & $ctxState.accountGeneration

  proc staleReason*(captured: ClientContext; scope: ContextScope): string =
    ## Why a response captured under `captured` must be dropped now under
    ## `scope`, or "" when it may be applied.
    load()
    if scope == csNone:
      return ""
    if captured.incarnationId != ctxState.incarnationId:
      return "incarnation"
    if captured.accountGeneration != ctxState.accountGeneration:
      return "account"
    if scope == csNavigation and
        captured.navigationGeneration != ctxState.navigationGeneration:
      return "navigation"
    ""

  proc onDroppedResponse*(hook: proc(d: DroppedResponse)) =
    ## Adds a hook that sees every dropped response.
    droppedHooks.add hook

  proc reportDropped*(d: DroppedResponse) =
    inc droppedCount
    for h in droppedHooks:
      h(d)

  proc droppedResponseCount*(): int =
    droppedCount

  proc setCsrfToken*(token: string) =
    ## Overrides the CSRF token the page's `csrf-token` meta tag supplies.
    csrfTokenOverride = token

  proc csrfToken*(): string =
    ## The token generated clients send as `X-CSRF-Token`.
    if csrfTokenOverride.len > 0: csrfTokenOverride
    else: metaContent(csrfMetaName)
