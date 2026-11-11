## The navigation target (isonim/routing/navigator.nim): global
## `navigate()` reaches whatever navigator is active, `createRouter`
## installs its router as one, an application's own navigator replaces it,
## and the typed route manifest's generated `<name>Navigate` helpers reach
## the application's navigator with the path the manifest builds (browser
## target). Run on both targets (`just test-c`, `just test-js`).
##
## tests/fixtures/navigator_only.nim checks the other half of the contract:
## a program that installs its own navigator and navigates does not compile
## the router in (`just test-js` greps its output).

import unittest
import isonim/core/[computation, owner, signals]
import isonim/routing/[match, router, navigate]
when defined(js):
  import isonim/routing/manifest

  type
    ArticleRequest = object
      slug: string
      id: string
    ArticleData = object
      title: string
    IndexRequest = object
    IndexData = object

  routeManifest SampleRoute:
    page rIndex, "/", IndexRequest, IndexData
    page rArticle, "/articles/:slug/:id", ArticleRequest, ArticleData

var seen: seq[(string, bool)]

proc recorder(path: string; replace: bool) =
  seen.add((path, replace))

suite "the active navigator":
  setup:
    seen.setLen(0)
    setNavigator(nil)

  test "without a navigator, navigate() does nothing":
    navigate("/nowhere")
    check currentNavigator().isNil
    check seen.len == 0

  test "an installed navigator receives navigate() with replace":
    setNavigator(recorder)
    navigate("/a?q=1")
    navigate("/b", replace = true)
    check seen == @[("/a?q=1", false), ("/b", true)]

  test "createRouter installs its router as the navigator":
    createRoot do (dispose: proc()):
      let r = createRouter(@[
        RouteEntry(pattern: parsePattern("/"), component: proc() = discard),
        RouteEntry(pattern: parsePattern("/about"), component: proc() = discard),
      ], "/")
      check not currentNavigator().isNil
      navigate("/about")
      check r.currentPath.val == "/about"
      check r.matchedIndex.val == 1
      dispose()

  test "an application's navigator installed after a router replaces it":
    createRoot do (dispose: proc()):
      let r = createRouter(@[
        RouteEntry(pattern: parsePattern("/"), component: proc() = discard),
        RouteEntry(pattern: parsePattern("/about"), component: proc() = discard),
      ], "/")
      setNavigator(recorder)
      navigate("/about")
      check seen == @[("/about", false)]
      check r.currentPath.val == "/"
      dispose()

  when defined(js):
    test "the generated <name>Navigate helpers reach the application's navigator":
      setNavigator(recorder)
      rArticleNavigate(ArticleRequest(slug: "a b", id: "42"))
      rIndexNavigate(IndexRequest())
      check seen == @[("/articles/a%20b/42", false), ("/", false)]
