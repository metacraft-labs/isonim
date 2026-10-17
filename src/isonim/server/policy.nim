## isonim/server/policy.nim
##
## The per-route policies that server functions (`{.server.}`) and route
## manifest entries (`routeManifest`) declare, and that the server enforces
## before a handler runs.  The values are the ones of the IsoNim Forum URL
## schema (pilot-projects/isonim-forum/URL-Schema.md §5.1):
##
## * `AuthPolicy`: who may call (`aPublic` ... `aSignature`);
## * `CsrfPolicy`: how a state-changing request proves it is not forged
##   (isonim-auth.md §2.5): `csrfNone` (safe methods only), `csrfSession`,
##   `csrfAnon`, or `csrfExempt(reason)` naming one of the §2.5 exemptions;
## * `CachePolicy`: the `Cache-Control` set of the response (URL-Schema.md
##   §6.1);
## * `CanonicalPolicy`: which Stage 4 canonicalization runs (URL-Schema.md
##   §3);
## * `ContextScope`: which client context generation a response must still
##   match when it arrives (URL-Schema.md §5.4).
##
## Shared by both targets: the browser client needs the context scope, and
## the server everything.

type
  AuthPolicy* = enum
    aPublic     ## anyone; the session is not even resolved
    aOptional   ## anyone; the session is resolved when there is one
    aSession    ## a signed-in session is required (else 401)
    aStaff      ## a staff or admin session is required (else 401 / 403)
    aAdmin      ## an admin session is required (else 401 / 403)
    aSignature  ## a signed request (webhook, signed token); the
                ## application's signature verifier decides (else 401)

  CsrfKind* = enum
    ckNone      ## no check; only valid for GET / HEAD
    ckSession   ## `X-CSRF-Token` or `_csrf` equal to the session's token
    ckAnon      ## `X-CSRF-Token` or `_csrf` equal to the anonymous CSRF
                ## cookie (`__Host-Anon-CSRF`)
    ckExempt    ## a named isonim-auth.md §2.5 exemption

  CsrfPolicy* = object
    kind*: CsrfKind
    exemption*: string   ## the §2.5 exemption, for `ckExempt`

  CachePolicy* = enum
    cpPrivateNoStore     ## private, no-cache, no-store, must-revalidate
    cpPrivateRevalidate  ## private, no-cache, must-revalidate + Vary
    cpMediaRevalidate    ## private, no-cache, must-revalidate (ETag by the
                         ## handler)
    cpImmutable          ## public, max-age=31536000, immutable
    cpNone               ## no Cache-Control header

  CanonicalPolicy* = enum
    ccNone, ccTopicSlug, ccCategorySlug, ccShortlink, ccPermalink

  ContextScope* = enum
    csNavigation  ## dropped when the account or the navigation changed
    csAccount     ## dropped when the account (or the incarnation) changed
    csNone        ## never dropped

const
  csrfExemptions* = ["billing-webhook", "csp-report", "rfc8058",
                     "saml-acs", "oidc-backchannel"]
    ## The exemptions isonim-auth.md §2.5 lists: inbound billing webhooks,
    ## CSP violation reports, RFC 8058 one-click unsubscribe, the SAML
    ## assertion consumer service and OIDC back-channel logout.

  csrfNone* = CsrfPolicy(kind: ckNone)
  csrfSession* = CsrfPolicy(kind: ckSession)
  csrfAnon* = CsrfPolicy(kind: ckAnon)

  csrfHeaderName* = "X-CSRF-Token"
  csrfFieldName* = "_csrf"
  anonCsrfCookieName* = "__Host-Anon-CSRF"
  contextHeaderName* = "X-Isonim-Context"
    ## `<incarnation_id>:<account_generation>` on every request a generated
    ## client sends; echoed on the response (URL-Schema.md §5.4).

template csrfExempt*(reason: static string): CsrfPolicy =
  ## A CSRF exemption.  `reason` must name one of `csrfExemptions`; any
  ## other string is a compile-time error.
  when reason notin csrfExemptions:
    {.error: "csrfExempt(\"" & reason & "\") names no isonim-auth.md §2.5 " &
      "exemption; expected one of " & $csrfExemptions.}
  CsrfPolicy(kind: ckExempt, exemption: reason)

proc `$`*(p: CsrfPolicy): string =
  case p.kind
  of ckNone: "csrfNone"
  of ckSession: "csrfSession"
  of ckAnon: "csrfAnon"
  of ckExempt: "csrfExempt(\"" & p.exemption & "\")"

proc isStateChanging*(httpMethod: string): bool =
  ## Every method but GET, HEAD and OPTIONS (RFC 9110 §9.2.1).
  httpMethod notin ["GET", "HEAD", "OPTIONS"]

proc cacheHeaders*(p: CachePolicy): seq[(string, string)] =
  ## The response headers of a cache policy (URL-Schema.md §6.1).
  case p
  of cpPrivateNoStore:
    @[("Cache-Control", "private, no-cache, no-store, must-revalidate"),
      ("Pragma", "no-cache"), ("Expires", "0")]
  of cpPrivateRevalidate:
    @[("Cache-Control", "private, no-cache, must-revalidate"),
      ("Vary", "Cookie, Authorization, Accept-Language, Accept-Encoding")]
  of cpMediaRevalidate:
    @[("Cache-Control", "private, no-cache, must-revalidate")]
  of cpImmutable:
    @[("Cache-Control", "public, max-age=31536000, immutable")]
  of cpNone:
    @[]

proc cacheControl*(p: CachePolicy): string =
  ## The `Cache-Control` value of a policy ("" for `cpNone`).
  for (k, v) in cacheHeaders(p):
    if k == "Cache-Control":
      return v
  ""

const errorCacheControl* = "private, no-store"
  ## What a response the policy pipeline itself produces (401, 403, 404,
  ## 405, 409, 413, ...) carries, so that no cache keeps a denial or an
  ## error around (URL-Schema.md §6.1 point 3).
