## negotiation_manifest.nim
##
## The route manifest of tests/routing/t_manifest_negotiation.nim (IFP-M26):
## a page's JSON variants, per-response cache policies and a handler-raised
## not-found.  Served by the nginx fixture (tests/nginx/README.md) as the
## async app `negotiation` under `/neg/` (negotiation_app.nim), and shared
## with the test, which runs its generated policy tests.
##
## * `nArticle`: a page with a JSON variant and a `canonical` policy whose
##   hook may make one response `cpPrivateNoStore` (`cacheOverrides`);
## * `nPlain`: a page with a JSON variant and no hook, whose generated JSON
##   tests therefore see the page itself rather than a redirect;
## * `nLocked`: a `cpPrivateNoStore` page whose hook asks for the weaker
##   `cpPrivateRevalidate` (the negative control: refused);
## * `nRaw`: an `any` entry whose handler raises not-found;
## * `nRawCached`: an `any` entry with a declared default
##   (`cpMediaRevalidate`) and two `cacheOverrides` its handler asks for;
## * `nRefusals`: what the server's `onCachePolicyRefused` hook was told.

import isonim/routing/manifest

export manifest

type
  ArticleRequest* = object
    slug*: string
    id*: int

  ArticleResponse* = object
    id*: int
    title*: string

  PlainRequest* = object
    id*: int

  PlainResponse* = object
    id*: int

  LockedRequest* = object
    id*: int

  LockedResponse* = object
    id*: int

  RefusalsRequest* = object

  RefusalsResponse* = object
    refusals*: seq[string]
      ## `<requested> kept <kept> at <path>`, in the order they happened

routeManifest NegotiationRoute:
  page nArticle,  "/neg/a/:slug/:id", ArticleRequest, ArticleResponse,
       json = true, canonical = ccTopicSlug, cacheOverrides = [cpPrivateNoStore]
  page nPlain,    "/neg/p/:id", PlainRequest, PlainResponse, json = true
  page nLocked,   "/neg/locked/:id", LockedRequest, LockedResponse,
       cache = cpPrivateNoStore, canonical = ccPermalink
  any  nRaw,      "/neg/raw/:id", csrf = csrfSession
  any  nRawCached, "/neg/rc/:id", csrf = csrfSession, cache = cpMediaRevalidate,
       cacheOverrides = [cpPrivateRevalidate, cpPrivateNoStore]
  get  nRefusals, "/neg/refusals", RefusalsRequest, RefusalsResponse,
       auth = aPublic, cache = cpPrivateNoStore
