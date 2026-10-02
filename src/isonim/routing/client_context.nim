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
## manifest clients) carries `X-Isonim-Context: <incarnation_id>:
## <account_generation>` and captures the context when it is sent.  When the
## response arrives the client drops it if the captured context no longer
## matches the request's scope:
##
## * `csAccount`: the incarnation or the account generation changed;
## * `csNavigation`: that, or the navigation generation changed (and the
##   request is also aborted when the navigation changes);
## * `csNone`: never dropped.
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
