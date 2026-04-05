import unittest
import isonim/routing/[match, file_routes, router]
import isonim/core/[signals, computation, owner]

# Import component procs so they are in scope for the fileRoutes macro.
# In a real app, these would come from individual page modules. Here we
# use a helper because bracket-named files ([id].nim) cannot be imported
# as Nim modules directly.
import fixtures/page_components

suite "pathFromFile — route path derivation":
  test "index.nim maps to /":
    check pathFromFile("pages", "pages/index.nim") == "/"

  test "about.nim maps to /about":
    check pathFromFile("pages", "pages/about.nim") == "/about"

  test "users/index.nim maps to /users":
    check pathFromFile("pages", "pages/users/index.nim") == "/users"

  test "[id].nim maps to /users/:id":
    check pathFromFile("pages", "pages/users/[id].nim") == "/users/:id"

  test "[id]/posts.nim maps to /users/:id/posts":
    check pathFromFile("pages", "pages/users/[id]/posts.nim") == "/users/:id/posts"

  test "_id.nim (underscore convention) maps to /users/:id":
    check pathFromFile("pages", "pages/users/_id.nim") == "/users/:id"

  test "_id/posts.nim (underscore convention) maps to /users/:id/posts":
    check pathFromFile("pages", "pages/users/_id/posts.nim") == "/users/:id/posts"

  test "deeply nested bracket params":
    check pathFromFile("app/pages", "app/pages/org/[orgId]/team/[teamId].nim") == "/org/:orgId/team/:teamId"

  test "deeply nested underscore params":
    check pathFromFile("app/pages", "app/pages/org/_orgId/team/_teamId.nim") == "/org/:orgId/team/:teamId"

  test "root index with trailing slash in base":
    check pathFromFile("pages/", "pages/index.nim") == "/"

suite "componentNameFromFile — proc name derivation":
  test "about.nim → AboutPage":
    check componentNameFromFile("pages/about.nim") == "AboutPage"

  test "index.nim → IndexPage":
    check componentNameFromFile("pages/index.nim") == "IndexPage"

  test "[id].nim → IdPage":
    check componentNameFromFile("pages/users/[id].nim") == "IdPage"

  test "_id.nim → IdPage":
    check componentNameFromFile("pages/users/_id.nim") == "IdPage"

  test "posts.nim → PostsPage":
    check componentNameFromFile("pages/users/[id]/posts.nim") == "PostsPage"

suite "fileRoutes macro — compile-time directory scan":
  # The macro scans tests/fixtures/pages at compile time via staticExec.
  # Component procs (IndexPage, AboutPage, IdPage, PostsPage) are in
  # scope from the page_components import above.
  let routes = fileRoutes("fixtures/pages")

  test "generates correct number of routes":
    check routes.len == 5

  test "generates correct route paths":
    var paths: seq[string]
    for r in routes:
      paths.add(r.pattern.path)
    check "/" in paths
    check "/about" in paths
    check "/users" in paths
    check "/users/:id" in paths
    check "/users/:id/posts" in paths

  test "routes match expected URLs via router":
    createRoot proc(dispose: proc()) =
      let r = createRouter(routes, "/")
      check r.hasMatch()

      r.navigate("/about")
      check r.hasMatch()
      check r.matchedRoute().pattern.path == "/about"

      r.navigate("/users")
      check r.hasMatch()
      check r.matchedRoute().pattern.path == "/users"

      r.navigate("/users/42")
      check r.hasMatch()
      check r.matchedRoute().pattern.path == "/users/:id"
      check r.routeParams.get("id").val == "42"

      r.navigate("/users/42/posts")
      check r.hasMatch()
      check r.matchedRoute().pattern.path == "/users/:id/posts"
      check r.routeParams.get("id").val == "42"

      dispose()

  test "route components are callable":
    for r in routes:
      r.component()
